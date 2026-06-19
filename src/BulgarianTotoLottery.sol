// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BulgarianTotoStorage} from "./BulgarianTotoStorage.sol";

/// @title  BulgarianTotoLottery
/// @notice Lottery layer: ticket purchase, draw, tally, claim, refund, sweep, +
///         the lottery-side of LP accounting hooks (totalLpAssets / lpAssetsAtSnap /
///         _snapshotLp). Pure LP entry points live in BulgarianTotoLpVault.
abstract contract BulgarianTotoLottery is
    VRFConsumerBaseV2Plus,
    ReentrancyGuard,
    Pausable,
    BulgarianTotoStorage
{
    using SafeERC20 for IERC20;

    // ============================================================
    // BUY / DONATE / REFUND
    // ============================================================

    /// @notice Buy a ticket for the current open round.
    /// @param game  0 = 5/35, 1 = 6/49.
    /// @param picks K numbers in [1, maxNum]. K determines whether the ticket
    ///              is base, +1 or +2 (for 5/35: K=5/6/7; for 6/49: K=6/7/8).
    /// @return ticketId The newly created ticket's ID.
    function buyTicket(uint8 game, uint8[] calldata picks)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 ticketId)
    {
        if (game > 1) revert InvalidGame();

        uint8 k = uint8(picks.length);
        _validatePickCount(game, k);

        uint256 roundId = currentRoundId;
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Open)) revert WrongRoundState();
        if (block.timestamp + BUY_CUTOFF > r.drawTime) revert PurchaseWindowClosed();

        uint64 picksMask = _picksToMask(game, picks);
        uint256 price = _ticketPrice(game, k);

        usdc.safeTransferFrom(msg.sender, address(this), price);
        availablePool += price;

        // LPs absorb 100% of ticket revenue (and 100% of refunds via the matching debit
        // gated on lpCreditedAtBuy). When no LPs exist the revenue stays as house surplus.
        bool lpCredited = totalLpShares > 0;
        if (lpCredited) {
            totalLpAssets += price;
        }

        ticketId = tickets.length;
        tickets.push(
            Ticket({
                owner: msg.sender,
                roundId: uint32(roundId),
                purchaseTime: uint32(block.timestamp),
                game: game,
                k: k,
                claimed: false,
                refunded: false,
                picksMask: picksMask,
                lpCreditedAtBuy: lpCredited
            })
        );
        _roundTickets[roundId].push(ticketId);
        _userTickets[msg.sender].push(ticketId);

        emit TicketBought(ticketId, roundId, msg.sender, game, k, picksMask, price);
    }

    /// @notice Add USDC directly to the prize pool (anyone can donate).
    /// @param amount The USDC amount to donate (must be > 0).
    function donate(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        availablePool += amount;
        if (totalLpShares > 0) {
            totalLpAssets += amount;
        }
        emit Donation(msg.sender, amount);
    }

    /// @notice Refund a ticket within REFUND_WINDOW of purchase, but only while
    ///         the purchase window for that round is still open.
    /// @dev    Refunds are intentionally allowed even when the contract is paused
    ///         so that buyers cannot be locked into a paused round.
    /// @param ticketId The ticket to refund. Caller must be the ticket owner.
    function refund(uint256 ticketId) external nonReentrant {
        Ticket storage t = tickets[ticketId];
        if (t.owner != msg.sender) revert NotOwner();
        if (t.claimed || t.refunded) revert AlreadySettled();

        uint256 roundId = t.roundId;
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Open)) revert WrongRoundState();
        if (block.timestamp + BUY_CUTOFF > r.drawTime) revert RefundWindowClosed();
        if (block.timestamp > uint256(t.purchaseTime) + REFUND_WINDOW) revert RefundWindowClosed();

        uint256 price = _ticketPrice(t.game, t.k);
        t.refunded = true;
        if (availablePool < price) revert PoolUnderflow();
        availablePool -= price;
        // Mirror the buyTicket credit: only debit LPs if this specific ticket's purchase
        // was credited to LPs. Tickets bought when no LPs existed are refunded out of
        // house surplus and don't touch totalLpAssets.
        if (t.lpCreditedAtBuy) {
            // Should never underflow given monotonic refund semantics, but clamp defensively.
            totalLpAssets = totalLpAssets >= price ? totalLpAssets - price : 0;
        }
        usdc.safeTransfer(msg.sender, price);
        emit TicketRefunded(ticketId, msg.sender, price);
    }

    /// @notice Transfer ownership of a ticket to another address.
    /// @dev    Allowed at any time before the ticket is claimed or refunded.
    ///         Works even when the contract is paused (same rationale as refund).
    /// @param ticketId The ticket to transfer.
    /// @param to       The new owner. Must not be the zero address.
    function transferTicket(uint256 ticketId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Ticket storage t = tickets[ticketId];
        if (t.owner != msg.sender) revert NotOwner();
        if (t.claimed || t.refunded) revert AlreadySettled();

        address from = t.owner;
        t.owner = to;
        _userTickets[to].push(ticketId);

        emit TicketTransferred(ticketId, from, to);
    }

    // ============================================================
    // DRAW / TALLY / CLAIM
    // ============================================================

    /// @notice Permissionless: anyone can request the VRF draw once drawTime has passed.
    /// @dev    Skims TREASURY_BPS from the pool, snapshots the remainder, earmarks the
    ///         maximum possible payout, and opens the next round atomically.
    /// @param roundId The round to draw (must equal currentRoundId).
    /// @return reqId  The Chainlink VRF request ID.
    function requestDraw(uint256 roundId) external nonReentrant returns (uint256 reqId) {
        if (roundId != currentRoundId) revert WrongRound();
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Open)) revert WrongRoundState();
        if (block.timestamp < r.drawTime) revert TooEarly();

        // Skim TREASURY_BPS of the pool for the treasury before snapshotting.
        // LPs absorb the fee pro-rata to their share of availablePool.
        uint256 availablePoolPreFee = availablePool;
        uint256 treasuryFee = availablePoolPreFee * TREASURY_BPS / BPS_DENOM;
        if (treasuryFee > 0) {
            availablePool -= treasuryFee;
            // Pro-rata LP fee debit. availablePoolPreFee > 0 here because treasuryFee > 0.
            if (totalLpAssets > 0) {
                uint256 lpFee = treasuryFee * totalLpAssets / availablePoolPreFee;
                totalLpAssets -= lpFee;
            }
            usdc.safeTransfer(treasury, treasuryFee);
            emit TreasuryFee(roundId, treasuryFee);
        }

        // Snapshot the pool and earmark the maximum possible payout up-front,
        // so refunds / new buys for the next round cannot reduce this round's
        // prize budget while VRF is in flight.
        uint128 snap = uint128(availablePool);
        r.snapshotPool = snap;

        // Record the LP-owned slice of the snapshot for proportional slashing at finalize.
        lpAssetsAtSnap[roundId] = uint128(totalLpAssets);

        uint256 maxEarmark = uint256(snap) * MAX_PAYOUT_BPS / BPS_DENOM;
        availablePool -= maxEarmark;
        earmarkedForRound[roundId] = maxEarmark;

        r.state = uint8(RoundState.AwaitingVRF);
        unfinalizedRounds++;

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: keyHash,
            subId: subId,
            requestConfirmations: requestConfirmations,
            callbackGasLimit: callbackGasLimit,
            numWords: 2,
            extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
        });
        reqId = s_vrfCoordinator.requestRandomWords(req);
        vrfRequestToRound[reqId] = roundId;

        // Open the next round at the same instant so buyers are never locked out.
        uint256 nextId = roundId + 1;
        Round storage nr = rounds[nextId];
        nr.drawTime = r.drawTime + uint64(DRAW_INTERVAL);
        nr.expiryTime = nr.drawTime + uint64(EXPIRY_PERIOD);
        nr.state = uint8(RoundState.Open);
        currentRoundId = nextId;

        // Capture the (assets, shares) snapshot that will price LP withdrawals during
        // the new round. Refreshed again at _finalizeRound / sweepExpired so that any
        // settlement of prior rounds is reflected before withdrawals become possible.
        _snapshotLp(nextId);

        emit DrawRequested(roundId, reqId, snap);
        emit RoundOpened(nextId, nr.drawTime);
    }

    /// @notice Chainlink VRF callback - stores drawn numbers and moves to Tallying.
    /// @dev    If a round has zero tickets, finalization happens immediately.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        uint256 roundId = vrfRequestToRound[requestId];
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.AwaitingVRF)) {
            return; // defensive: ignore stale / unknown
        }
        delete vrfRequestToRound[requestId];

        uint64 mask5 = _drawNumbersToMask(randomWords[0], MAX_NUM_5_35, DRAW_COUNT_5_35);
        uint64 mask6 = _drawNumbersToMask(randomWords[1], MAX_NUM_6_49, DRAW_COUNT_6_49);
        r.drawnMask5 = mask5;
        r.drawnMask6 = mask6;
        r.state = uint8(RoundState.Tallying);
        emit DrawFulfilled(roundId, mask5, mask6);

        if (_roundTickets[roundId].length == 0) {
            _finalizeRound(roundId);
        }
    }

    /// @notice Process up to maxTickets entries in the round to count tier hits.
    /// @dev    Permissionless. Repeat calls until done == true. When the last ticket
    ///         is tallied the round is finalized automatically.
    function tallyBatch(uint256 roundId, uint256 maxTickets)
        external
        nonReentrant
        returns (bool done)
    {
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Tallying)) revert WrongRoundState();

        uint256 cursor = r.tallyCursor;
        uint256 total = _roundTickets[roundId].length;
        uint256 end = cursor + maxTickets;
        if (end > total) end = total;

        uint64 mask5 = r.drawnMask5;
        uint64 mask6 = r.drawnMask6;

        for (uint256 i = cursor; i < end; i++) {
            _tallyOne(roundId, _roundTickets[roundId][i], mask5, mask6);
        }

        r.tallyCursor = uint64(end);
        emit TallyAdvanced(roundId, uint64(end), uint64(total));

        if (end == total) {
            _finalizeRound(roundId);
            done = true;
        }
    }

    function _tallyOne(uint256 roundId, uint256 ticketId, uint64 mask5, uint64 mask6) internal {
        Ticket storage t = tickets[ticketId];
        if (t.refunded) return;

        uint8 game = t.game;
        uint64 drawnMask = game == GAME_5_35 ? mask5 : mask6;
        uint8 R = game == GAME_5_35 ? DRAW_COUNT_5_35 : DRAW_COUNT_6_49;
        uint8 K = t.k;
        uint8 m = uint8(_popcount(uint256(t.picksMask & drawnMask)));

        for (uint8 j = MIN_TIER; j <= R; j++) {
            if (_tierPct(game, j) == 0) continue;
            uint256 hits = _binom(m, j) * _binom(K - m, R - j);
            if (hits > 0) {
                tierState[roundId][game][j].totalHits += hits;
            }
        }
    }

    function _finalizeRound(uint256 roundId) internal {
        Round storage r = rounds[roundId];
        uint256 snap = uint256(r.snapshotPool);
        uint256 used = 0;

        for (uint8 j = MIN_TIER; j <= DRAW_COUNT_5_35; j++) {
            uint16 pct = _tierPct(GAME_5_35, j);
            if (pct == 0) continue;
            TierState storage ts = tierState[roundId][GAME_5_35][j];
            if (ts.totalHits == 0) continue;
            uint256 budget = snap * pct / BPS_DENOM;
            ts.budget = budget;
            ts.remaining = budget;
            used += budget;
        }

        for (uint8 j = MIN_TIER; j <= DRAW_COUNT_6_49; j++) {
            uint16 pct = _tierPct(GAME_6_49, j);
            if (pct == 0) continue;
            TierState storage ts = tierState[roundId][GAME_6_49][j];
            if (ts.totalHits == 0) continue;
            uint256 budget = snap * pct / BPS_DENOM;
            ts.budget = budget;
            ts.remaining = budget;
            used += budget;
        }

        uint256 reserved = earmarkedForRound[roundId];
        if (reserved > used) {
            availablePool += (reserved - used);
        }
        earmarkedForRound[roundId] = used;

        // Slash LPs proportionally to their share of the snapshot pool.
        // The non-LP portion of `used` is absorbed by the implicit house surplus
        // (availablePool - totalLpAssets), which decreases automatically.
        uint128 lpAtSnap = lpAssetsAtSnap[roundId];
        if (used > 0 && lpAtSnap > 0 && snap > 0) {
            uint256 lpLoss = used * uint256(lpAtSnap) / snap;
            if (lpLoss > totalLpAssets) lpLoss = totalLpAssets; // safety clamp
            if (lpLoss > 0) {
                totalLpAssets -= lpLoss;
                emit LpSlashed(roundId, lpLoss);
            }
        }

        if (unfinalizedRounds > 0) unfinalizedRounds--;
        // Refresh the current round's LP snapshot so withdrawals see the post-slash rate.
        _snapshotLp(currentRoundId);

        r.state = uint8(RoundState.Claimable);
        emit RoundFinalized(roundId, used);
    }

    /// @notice Claim a single winning ticket. Pays out to the ticket owner.
    function claim(uint256 ticketId) external nonReentrant returns (uint256 payout) {
        payout = _claimSingle(ticketId);
        if (payout == 0) revert NothingToClaim();
        usdc.safeTransfer(msg.sender, payout);
    }

    /// @notice Claim multiple winning tickets in a single transaction.
    /// @dev    Non-winning tickets in the array are silently skipped (no revert).
    ///         Reverts only if the total payout across all tickets is zero.
    function claimBatch(uint256[] calldata ticketIds) external nonReentrant returns (uint256 totalPayout) {
        for (uint256 i = 0; i < ticketIds.length; i++) {
            totalPayout += _claimSingle(ticketIds[i]);
        }
        if (totalPayout == 0) revert NothingToClaim();
        usdc.safeTransfer(msg.sender, totalPayout);
    }

    /// @dev Shared claim logic for claim() and claimBatch(). Marks the ticket as
    ///      claimed and emits {Claimed}, but does NOT transfer USDC (caller does).
    ///      Returns 0 for non-winning tickets without reverting.
    function _claimSingle(uint256 ticketId) internal returns (uint256 payout) {
        Ticket storage t = tickets[ticketId];
        if (t.owner != msg.sender) revert NotOwner();
        if (t.claimed || t.refunded) revert AlreadySettled();

        uint256 roundId = t.roundId;
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Claimable)) revert WrongRoundState();

        uint8 game = t.game;
        uint8 R = game == GAME_5_35 ? DRAW_COUNT_5_35 : DRAW_COUNT_6_49;
        uint8 K = t.k;
        uint64 drawnMask = game == GAME_5_35 ? r.drawnMask5 : r.drawnMask6;
        uint8 m = uint8(_popcount(uint256(t.picksMask & drawnMask)));

        for (uint8 j = MIN_TIER; j <= R; j++) {
            if (_tierPct(game, j) == 0) continue;
            uint256 hits = _binom(m, j) * _binom(K - m, R - j);
            if (hits == 0) continue;
            TierState storage ts = tierState[roundId][game][j];
            uint256 totalHits = ts.totalHits;
            if (totalHits == 0) continue;
            uint256 share = ts.budget * hits / totalHits;
            if (share > ts.remaining) share = ts.remaining; // rounding-dust safety
            ts.remaining -= share;
            payout += share;
        }

        t.claimed = true;
        if (payout > 0) {
            emit Claimed(ticketId, t.owner, payout);
        }
    }

    /// @notice After EXPIRY_PERIOD, return any unclaimed prize budget to the pool.
    /// @dev    Sets the round state to Expired so that subsequent claim() calls revert.
    function sweepExpired(uint256 roundId) external nonReentrant {
        Round storage r = rounds[roundId];
        if (r.state != uint8(RoundState.Claimable)) revert WrongRoundState();
        if (block.timestamp < r.expiryTime) revert TooEarly();

        uint256 leftover = 0;
        for (uint8 j = MIN_TIER; j <= DRAW_COUNT_5_35; j++) {
            TierState storage ts = tierState[roundId][GAME_5_35][j];
            if (ts.remaining > 0) {
                leftover += ts.remaining;
                ts.remaining = 0;
            }
        }
        for (uint8 j = MIN_TIER; j <= DRAW_COUNT_6_49; j++) {
            TierState storage ts = tierState[roundId][GAME_6_49][j];
            if (ts.remaining > 0) {
                leftover += ts.remaining;
                ts.remaining = 0;
            }
        }

        availablePool += leftover;
        if (earmarkedForRound[roundId] >= leftover) {
            earmarkedForRound[roundId] -= leftover;
        } else {
            earmarkedForRound[roundId] = 0;
        }

        // Mirror image of finalize-time slashing: pro-rata credit unclaimed budget back to LPs
        // using the snapshot ratio captured at requestDraw. Refresh the live LP snapshot so
        // withdrawals during the current round see the credit.
        uint128 lpAtSnap = lpAssetsAtSnap[roundId];
        uint128 snap = r.snapshotPool;
        if (leftover > 0 && lpAtSnap > 0 && snap > 0) {
            uint256 lpCredit = leftover * uint256(lpAtSnap) / uint256(snap);
            if (lpCredit > 0) {
                totalLpAssets += lpCredit;
                emit LpCredited(roundId, lpCredit);
            }
        }
        _snapshotLp(currentRoundId);

        r.state = uint8(RoundState.Expired);
        emit RoundExpired(roundId, leftover);
    }

    /// @dev Capture the current LP (assets, shares) for `roundId`. Called at round open
    ///      from requestDraw, and again at _finalizeRound / sweepExpired so post-settlement
    ///      changes are reflected before LP withdrawals become possible.
    function _snapshotLp(uint256 roundId) internal {
        uint128 a = uint128(totalLpAssets);
        uint128 s = uint128(totalLpShares);
        lpSnapshot[roundId] = LpSnapshot({assets: a, shares: s});
        emit LpSnapshotTaken(roundId, a, s);
    }

    // ============================================================
    // PERMISSIONLESS CATCH-UP
    // ============================================================

    /// @notice Single-call permissionless catch-up. Walks the round range
    ///         [startRoundId .. min(startRoundId + maxRoundsToScan - 1, currentRoundId)]
    ///         and advances each round through the state machine as far as possible
    ///         without external dependencies. Skips rounds that are AwaitingVRF
    ///         (Chainlink callback required) or already in a final state.
    /// @dev    Uses external self-calls with try/catch so a single failing transition
    ///         (e.g. VRF subscription empty, drawTime not yet reached) does NOT abort
    ///         the rest of the batch. Caller may invoke this any number of times;
    ///         the function is idempotent on rounds that are already up-to-date.
    ///
    ///         Per-round actions:
    ///           Open + drawTime reached    → requestDraw  → AwaitingVRF
    ///           Tallying                   → tallyBatch   → Tallying or Claimable
    ///           Claimable + expiryTime past → sweepExpired → Expired
    ///
    /// @param startRoundId    First round to consider (use 0 to scan from genesis).
    /// @param maxRoundsToScan Cap on rounds touched in this call (gas safety).
    /// @param tallyBatchSize  Iterations per inner tallyBatch call (gas safety).
    /// @return actionsExecuted Number of state transitions performed.
    function catchUp(
        uint256 startRoundId,
        uint256 maxRoundsToScan,
        uint256 tallyBatchSize
    ) external returns (uint256 actionsExecuted) {
        if (maxRoundsToScan == 0) return 0;

        uint256 cur = currentRoundId;
        if (startRoundId > cur) return 0;

        uint256 end = startRoundId + maxRoundsToScan;
        if (end > cur + 1) end = cur + 1;

        for (uint256 i = startRoundId; i < end; i++) {
            Round storage r = rounds[i];
            uint8 s = r.state;

            if (s == uint8(RoundState.Open)) {
                // Only the current round is ever Open. Trigger AT MOST ONE requestDraw
                // per call: cascading draws would burn LINK on empty rounds and stack
                // unfinalizedRounds, blocking LP withdrawals. Re-invoke after VRF fulfills.
                if (i == cur && block.timestamp >= r.drawTime) {
                    try this.requestDraw(i) returns (uint256) {
                        actionsExecuted++;
                        // Stop the loop: subsequent rounds (just-opened) should wait
                        // for the next catchUp call to avoid the cascade.
                        break;
                    } catch {
                        // VRF subscription empty, paused, etc. — leave for next time.
                    }
                }
            } else if (s == uint8(RoundState.Tallying)) {
                try this.tallyBatch(i, tallyBatchSize) returns (bool) {
                    actionsExecuted++;
                } catch {
                    // Should not normally fail; defensive.
                }
            } else if (
                s == uint8(RoundState.Claimable) && block.timestamp >= r.expiryTime
            ) {
                try this.sweepExpired(i) {
                    actionsExecuted++;
                } catch {
                    // Defensive.
                }
            }
            // AwaitingVRF, Expired, or Claimable-not-yet-expired → silent skip.
        }

        emit CatchUpExecuted(msg.sender, startRoundId, end == 0 ? 0 : end - 1, actionsExecuted);
    }

    // ============================================================
    // VIEWS
    // ============================================================

    /// @notice Total number of tickets ever created (including refunded).
    function ticketCount() external view returns (uint256) {
        return tickets.length;
    }

    /// @notice Number of tickets sold in a specific round.
    function roundTicketCount(uint256 roundId) external view returns (uint256) {
        return _roundTickets[roundId].length;
    }

    /// @notice Ticket ID at a given index within a round.
    function roundTicketAt(uint256 roundId, uint256 idx) external view returns (uint256) {
        return _roundTickets[roundId][idx];
    }

    /// @notice Look up the price for a given game and pick count.
    function ticketPrice(uint8 game, uint8 k) external pure returns (uint256) {
        return _ticketPrice(game, k);
    }

    /// @notice Look up the prize-pool percentage (in BPS) for a given tier.
    function tierPct(uint8 game, uint8 tier) external pure returns (uint16) {
        return _tierPct(game, tier);
    }

    /// @notice Compute the payout a ticket would receive if claim() were called now.
    function previewClaim(uint256 ticketId) external view returns (uint256 payout) {
        Ticket memory t = tickets[ticketId];
        if (t.claimed || t.refunded) return 0;
        Round memory r = rounds[t.roundId];
        if (r.state != uint8(RoundState.Claimable)) return 0;

        uint8 R = t.game == GAME_5_35 ? DRAW_COUNT_5_35 : DRAW_COUNT_6_49;
        uint64 drawnMask = t.game == GAME_5_35 ? r.drawnMask5 : r.drawnMask6;
        uint8 m = uint8(_popcount(uint256(t.picksMask & drawnMask)));

        for (uint8 j = MIN_TIER; j <= R; j++) {
            if (_tierPct(t.game, j) == 0) continue;
            uint256 hits = _binom(m, j) * _binom(t.k - m, R - j);
            if (hits == 0) continue;
            TierState memory ts = tierState[t.roundId][t.game][j];
            if (ts.totalHits == 0) continue;
            payout += ts.budget * hits / ts.totalHits;
        }
    }

    /// @notice Decode the drawn numbers for a finalized round into uint8 arrays.
    function drawnNumbers(uint256 roundId)
        external
        view
        returns (uint8[] memory five35, uint8[] memory six49)
    {
        Round memory r = rounds[roundId];
        five35 = _maskToNumbers(r.drawnMask5, MAX_NUM_5_35);
        six49 = _maskToNumbers(r.drawnMask6, MAX_NUM_6_49);
    }

    // ============================================================
    // FRONTEND HELPERS
    // ============================================================

    /// @notice Return all round data in a single call (avoids multiple RPC round-trips).
    /// @dev    `ticketCount` reflects ACTIVE tickets - refunded tickets are excluded so the
    ///         number matches what the frontend should show users.
    function getRoundInfo(uint256 roundId) external view returns (RoundInfo memory info) {
        Round memory r = rounds[roundId];
        info.drawTime = r.drawTime;
        info.expiryTime = r.expiryTime;
        info.snapshotPool = r.snapshotPool;
        info.state = RoundState(r.state);
        info.drawn5 = _maskToNumbers(r.drawnMask5, MAX_NUM_5_35);
        info.drawn6 = _maskToNumbers(r.drawnMask6, MAX_NUM_6_49);

        uint256[] storage list = _roundTickets[roundId];
        uint256 len = list.length;
        uint256 active;
        for (uint256 i = 0; i < len; i++) {
            if (!tickets[list[i]].refunded) {
                unchecked { ++active; }
            }
        }
        info.ticketCount = active;
    }

    /// @notice Return tier-level prize data for both games in a round.
    /// @dev    Arrays are indexed 0 = tier 3, 1 = tier 4, etc.
    function getRoundTiers(uint256 roundId)
        external
        view
        returns (TierState[3] memory tiers5, TierState[4] memory tiers6)
    {
        for (uint8 j = 0; j < 3; j++) {
            tiers5[j] = tierState[roundId][GAME_5_35][j + MIN_TIER];
        }
        for (uint8 j = 0; j < 4; j++) {
            tiers6[j] = tierState[roundId][GAME_6_49][j + MIN_TIER];
        }
    }

    /// @notice Return every ticket ID that a user has ever bought or received.
    function getUserTickets(address user) external view returns (uint256[] memory ids) {
        return _userTickets[user];
    }

    /// @notice Check whether a ticket is a winner in its round's draw.
    function isWinner(uint256 ticketId) external view returns (bool) {
        Ticket memory t = tickets[ticketId];
        if (t.claimed || t.refunded) return false;
        Round memory r = rounds[t.roundId];
        if (r.state != uint8(RoundState.Claimable)) return false;

        uint64 drawnMask = t.game == GAME_5_35 ? r.drawnMask5 : r.drawnMask6;
        uint8 m = uint8(_popcount(uint256(t.picksMask & drawnMask)));
        return m >= MIN_TIER;
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /// @dev Revert if k is outside the allowed range for the given game.
    function _validatePickCount(uint8 game, uint8 k) internal pure {
        if (game == GAME_5_35) {
            if (k < MIN_K_5_35 || k > MAX_K_5_35) revert InvalidPickCount();
        } else {
            if (k < MIN_K_6_49 || k > MAX_K_6_49) revert InvalidPickCount();
        }
    }

    /// @dev Convert an array of picked numbers into a bitmask. Validates range and uniqueness.
    function _picksToMask(uint8 game, uint8[] calldata picks) internal pure returns (uint64 mask) {
        uint8 maxNum = game == GAME_5_35 ? MAX_NUM_5_35 : MAX_NUM_6_49;
        for (uint256 i = 0; i < picks.length; i++) {
            uint8 n = picks[i];
            if (n == 0 || n > maxNum) revert InvalidNumber();
            uint64 bit = uint64(1) << n;
            if ((mask & bit) != 0) revert DuplicateNumber();
            mask |= bit;
        }
    }

    /// @dev Deterministically draw `count` unique numbers in [1, maxNum] from a VRF word.
    ///      Uses a partial Fisher-Yates shuffle with keccak256 expansion for independence.
    function _drawNumbersToMask(uint256 randomWord, uint8 maxNum, uint8 count)
        internal
        pure
        returns (uint64 mask)
    {
        uint8[] memory pool = new uint8[](maxNum);
        for (uint8 i = 0; i < maxNum; i++) {
            pool[i] = i + 1;
        }
        for (uint8 i = 0; i < count; i++) {
            uint256 rand = uint256(keccak256(abi.encode(randomWord, i)));
            uint8 j = i + uint8(rand % uint256(uint8(maxNum - i)));
            (pool[i], pool[j]) = (pool[j], pool[i]);
            mask |= (uint64(1) << pool[i]);
        }
    }

    /// @dev Convert a bitmask back into a sorted array of numbers.
    function _maskToNumbers(uint64 mask, uint8 maxNum) internal pure returns (uint8[] memory out) {
        uint256 count;
        for (uint8 i = 1; i <= maxNum; i++) {
            if ((mask & (uint64(1) << i)) != 0) count++;
        }
        out = new uint8[](count);
        uint256 idx;
        for (uint8 i = 1; i <= maxNum; i++) {
            if ((mask & (uint64(1) << i)) != 0) {
                out[idx++] = i;
            }
        }
    }

    /// @dev Count the number of set bits (Brian Kernighan's algorithm).
    function _popcount(uint256 x) internal pure returns (uint256 c) {
        unchecked {
            while (x != 0) {
                x &= (x - 1);
                c++;
            }
        }
    }

    /// @dev C(n,k); n,k <= 8 so the iterative form is exact and cheap.
    function _binom(uint8 n, uint8 k) internal pure returns (uint256) {
        if (k > n) return 0;
        if (k == 0 || k == n) return 1;
        uint8 a = n - k;
        uint8 lo = k < a ? k : a;
        uint256 num = 1;
        uint256 den = 1;
        for (uint256 i = 1; i <= lo; i++) {
            num *= (uint256(n) - i + 1);
            den *= i;
        }
        return num / den;
    }

    /// @dev Return the USDC price for a ticket with the given game and pick count.
    function _ticketPrice(uint8 game, uint8 k) internal pure returns (uint256) {
        if (game == GAME_5_35) {
            if (k == 5) return PRICE_5_35_BASE;
            if (k == 6) return PRICE_5_35_PLUS1;
            if (k == 7) return PRICE_5_35_PLUS2;
        } else if (game == GAME_6_49) {
            if (k == 6) return PRICE_6_49_BASE;
            if (k == 7) return PRICE_6_49_PLUS1;
            if (k == 8) return PRICE_6_49_PLUS2;
        }
        revert InvalidPickCount();
    }

    /// @dev Return the prize-pool BPS for a given game and tier (0 if tier is invalid).
    function _tierPct(uint8 game, uint8 tier) internal pure returns (uint16) {
        if (game == GAME_5_35) {
            if (tier == 5) return PCT_5_35_TIER5;
            if (tier == 4) return PCT_5_35_TIER4;
            if (tier == 3) return PCT_5_35_TIER3;
            return 0;
        } else {
            if (tier == 6) return PCT_6_49_TIER6;
            if (tier == 5) return PCT_6_49_TIER5;
            if (tier == 4) return PCT_6_49_TIER4;
            if (tier == 3) return PCT_6_49_TIER3;
            return 0;
        }
    }
}
