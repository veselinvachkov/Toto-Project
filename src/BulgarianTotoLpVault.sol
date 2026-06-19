// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BulgarianTotoLottery} from "./BulgarianTotoLottery.sol";

/// @title  BulgarianTotoLpVault
/// @notice LP entry points: deposit, withdraw, and read-only previews.
/// @dev    Lottery-side hooks (intra-buy/donate/refund/finalize/sweep accounting and
///         _snapshotLp) live in BulgarianTotoLottery.
abstract contract BulgarianTotoLpVault is BulgarianTotoLottery {
    using SafeERC20 for IERC20;

    /// @notice Deposit USDC as a Liquidity Provider. Mints shares at the *live* asset/share
    ///         rate (with virtual-offset inflation protection). Shares are locked through
    ///         the next LP_LOCKUP_ROUNDS rounds and then withdrawable at the current round's
    ///         snapshot rate.
    /// @dev    Live-rate minting prevents an LP from depositing late in a round at the
    ///         round-start snapshot rate after intra-round ticket revenue has accrued.
    /// @param amount USDC amount to deposit (must be > 0).
    /// @return shares The number of LP shares minted.
    function depositLp(uint256 amount) external nonReentrant whenNotPaused returns (uint128 shares) {
        if (amount == 0) revert LpAmountZero();
        // Bootstrap gate: only accept LP capital once the prize pool has been
        // seeded by ticket revenue / donations to LP_MIN_POOL.
        if (availablePool < LP_MIN_POOL) revert LpPoolBelowThreshold();

        uint256 sharesU = amount * (totalLpShares + LP_VIRTUAL_SHARES) / (totalLpAssets + 1);
        if (sharesU == 0) revert LpSharesZero();
        shares = uint128(sharesU);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        availablePool += amount;
        totalLpAssets += amount;
        totalLpShares += sharesU;

        uint64 unlockRoundId = uint64(currentRoundId) + LP_LOCKUP_ROUNDS;
        _lpTranches[msg.sender].push(LpTranche({shares: shares, unlockRoundId: unlockRoundId}));

        emit LpDeposited(msg.sender, amount, shares, unlockRoundId);
    }

    /// @notice Burn LP shares from a specific tranche and receive USDC at the current
    ///         round's snapshot rate.
    /// @dev    Withdrawals are guarded so LPs cannot front-run pending prize payouts:
    ///           - the current round must be Open (not awaiting VRF or tallying);
    ///           - the tranche must have passed its lockup;
    ///           - no prior rounds may be unfinalized (their slash hasn't been applied yet).
    ///         Allowed even when the contract is paused, mirroring refund/claim semantics.
    /// @param trancheIndex Index into the caller's tranche array.
    /// @param sharesToBurn Number of shares to burn from that tranche.
    /// @return amount      USDC paid to the caller.
    function withdrawLp(uint256 trancheIndex, uint128 sharesToBurn)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (sharesToBurn == 0) revert LpSharesZero();

        LpTranche[] storage tranches = _lpTranches[msg.sender];
        if (trancheIndex >= tranches.length) revert InvalidTranche();
        LpTranche storage tranche = tranches[trancheIndex];
        if (sharesToBurn > tranche.shares) revert InsufficientShares();

        Round storage cr = rounds[currentRoundId];
        if (cr.state != uint8(RoundState.Open)) revert WrongRoundState();
        if (currentRoundId < tranche.unlockRoundId) revert TrancheLocked();
        if (unfinalizedRounds > 0) revert PreviousRoundNotSettled();

        LpSnapshot memory snap = lpSnapshot[currentRoundId];
        amount = uint256(sharesToBurn) * (uint256(snap.assets) + 1)
            / (uint256(snap.shares) + LP_VIRTUAL_SHARES);
        if (amount == 0) revert LpSharesZero();
        if (amount > totalLpAssets) amount = totalLpAssets;          // safety clamp
        if (amount > availablePool) revert InsufficientLiquidity();

        tranche.shares -= sharesToBurn;
        totalLpShares -= uint256(sharesToBurn);
        totalLpAssets -= amount;
        availablePool -= amount;

        usdc.safeTransfer(msg.sender, amount);
        emit LpWithdrawn(msg.sender, trancheIndex, sharesToBurn, amount);
    }

    /// @notice Preview shares minted for a deposit at the current live rate.
    function previewLpDeposit(uint256 amount) external view returns (uint128 shares) {
        shares = uint128(amount * (totalLpShares + LP_VIRTUAL_SHARES) / (totalLpAssets + 1));
    }

    /// @notice Preview USDC paid for burning `shares` at the current round's snapshot rate.
    function previewLpWithdraw(uint128 shares) external view returns (uint256 amount) {
        LpSnapshot memory snap = lpSnapshot[currentRoundId];
        amount = uint256(shares) * (uint256(snap.assets) + 1)
            / (uint256(snap.shares) + LP_VIRTUAL_SHARES);
    }

    /// @notice Number of distinct deposit tranches for an LP.
    function lpTrancheCount(address lp) external view returns (uint256) {
        return _lpTranches[lp].length;
    }

    /// @notice Read a specific tranche by index.
    function lpTrancheAt(address lp, uint256 idx) external view returns (LpTranche memory) {
        return _lpTranches[lp][idx];
    }

    /// @notice Aggregate USDC value of all of an LP's tranches at the current snapshot rate.
    /// @dev    Uses the current round's snapshot - same rate withdrawal would use right now.
    function lpAssetsOf(address lp) external view returns (uint256 totalAssets) {
        LpSnapshot memory snap = lpSnapshot[currentRoundId];
        uint256 denom = uint256(snap.shares) + LP_VIRTUAL_SHARES;
        uint256 num = uint256(snap.assets) + 1;
        LpTranche[] storage tranches = _lpTranches[lp];
        for (uint256 i = 0; i < tranches.length; i++) {
            totalAssets += uint256(tranches[i].shares) * num / denom;
        }
    }
}
