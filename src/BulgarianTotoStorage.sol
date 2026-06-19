// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  BulgarianTotoStorage
/// @notice Pure data layer: types, constants, state, events, errors.
/// @dev    Abstract base shared by every concrete part of the BulgarianToto contract.
///         All state lives here so the storage layout is fixed in one place.
abstract contract BulgarianTotoStorage {
    // ============================================================
    // ENUMS / STRUCTS
    // ============================================================

    enum RoundState {
        Open,
        AwaitingVRF,
        Tallying,
        Claimable,
        Expired
    }

    struct Round {
        uint64 drawTime;        // earliest moment a draw can be requested
        uint64 expiryTime;      // earliest moment leftover prizes can be swept
        uint64 drawnMask5;      // bitmask of 5/35 drawn numbers
        uint64 drawnMask6;      // bitmask of 6/49 drawn numbers
        uint128 snapshotPool;   // pool size captured at requestDraw
        uint64 tallyCursor;     // next ticket index to tally
        uint8 state;            // RoundState
    }

    struct Ticket {
        // slot 1
        address owner;          // 20
        uint32 roundId;         // 4
        uint32 purchaseTime;    // 4
        uint8 game;             // 1
        uint8 k;                // 1
        bool claimed;           // 1
        bool refunded;          // 1
        // slot 2
        uint64 picksMask;       // 8 (bit n set => number n picked)
        bool lpCreditedAtBuy;   // 1 (true if totalLpShares > 0 when this ticket was bought)
    }

    struct TierState {
        uint256 totalHits;      // sum of sub-ticket hits at this tier (set during tally)
        uint256 budget;         // USDC budget for this tier (frozen at finalize)
        uint256 remaining;      // budget remaining after claims; swept on expiry
    }

    struct LpTranche {
        uint128 shares;         // shares minted in this deposit (decremented on partial withdraw)
        uint64 unlockRoundId;   // first round in which these shares may be withdrawn
    }

    struct LpSnapshot {
        uint128 assets;         // totalLpAssets at the moment the round opened (and refreshed at finalize/sweep)
        uint128 shares;         // totalLpShares at that same moment
    }

    /// @notice Aggregated round data returned by getRoundInfo().
    struct RoundInfo {
        uint64 drawTime;
        uint64 expiryTime;
        uint128 snapshotPool;
        RoundState state;
        uint8[] drawn5;
        uint8[] drawn6;
        uint256 ticketCount;
    }

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint8 public constant GAME_5_35 = 0;
    uint8 public constant GAME_6_49 = 1;

    uint8 public constant MAX_NUM_5_35 = 35;
    uint8 public constant MAX_NUM_6_49 = 49;

    uint8 public constant DRAW_COUNT_5_35 = 5; // R for 5/35
    uint8 public constant DRAW_COUNT_6_49 = 6; // R for 6/49

    uint8 public constant MIN_K_5_35 = 5;
    uint8 public constant MAX_K_5_35 = 7;
    uint8 public constant MIN_K_6_49 = 6;
    uint8 public constant MAX_K_6_49 = 8;

    uint8 public constant MIN_TIER = 3;

    // Prices in USDC base units (USDC has 6 decimals)
    uint256 public constant PRICE_5_35_BASE = 3 * 1e6;
    uint256 public constant PRICE_5_35_PLUS1 = 5 * 1e6;
    uint256 public constant PRICE_5_35_PLUS2 = 7 * 1e6;
    uint256 public constant PRICE_6_49_BASE = 4 * 1e6;
    uint256 public constant PRICE_6_49_PLUS1 = 6 * 1e6;
    uint256 public constant PRICE_6_49_PLUS2 = 9 * 1e6;

    // Tier percentages in basis points (10000 = 100%)
    uint16 public constant PCT_5_35_TIER5 = 1500; // 15%
    uint16 public constant PCT_5_35_TIER4 = 100;  // 1%
    uint16 public constant PCT_5_35_TIER3 = 20;   // 0.2%
    uint16 public constant PCT_6_49_TIER6 = 5500; // 55%
    uint16 public constant PCT_6_49_TIER5 = 300;  // 3%
    uint16 public constant PCT_6_49_TIER4 = 200;  // 2%
    uint16 public constant PCT_6_49_TIER3 = 50;  // 0.5%

    // Sum of every payout slice that could be claimed in one round.
    // Used to earmark prize budget up-front so refunds and next-round buys
    // cannot eat into the snapshot before VRF returns.
    uint16 public constant MAX_PAYOUT_BPS =
        PCT_5_35_TIER5 + PCT_5_35_TIER4 + PCT_5_35_TIER3
            + PCT_6_49_TIER6 + PCT_6_49_TIER5 + PCT_6_49_TIER4 + PCT_6_49_TIER3;
    uint16 public constant BPS_DENOM = 10000;

    uint256 public constant DRAW_INTERVAL = 48 hours;
    uint256 public constant BUY_CUTOFF = 1 hours;
    uint256 public constant REFUND_WINDOW = 1 hours;
    uint256 public constant EXPIRY_PERIOD = 365 days;

    uint16 public constant TREASURY_BPS = 100; // 1.0%

    // LP vault configuration.
    // LP_LOCKUP_ROUNDS: a deposit made during round R may first be withdrawn during round R + LP_LOCKUP_ROUNDS.
    // LP_VIRTUAL_SHARES: ERC4626-style virtual offset that prevents first-depositor share inflation.
    // LP_MIN_POOL: deposits only allowed once the prize pool has reached this size (in USDC base
    //              units), so the protocol bootstraps from ticket / donation revenue before
    //              outside capital is accepted.
    uint64 public constant LP_LOCKUP_ROUNDS = 2;
    uint256 public constant LP_VIRTUAL_SHARES = 1e6;
    uint256 public constant LP_MIN_POOL = 100_000 * 1e6;

    // ============================================================
    // STATE
    // ============================================================
    // NOTE: order is load-bearing for storage layout. Do not reorder.

    IERC20 public immutable usdc;

    bytes32 public keyHash;
    uint256 public subId;
    uint16 public requestConfirmations;
    uint32 public callbackGasLimit;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256[]) internal _roundTickets;
    Ticket[] public tickets;
    mapping(uint256 => uint256) public earmarkedForRound;
    mapping(uint256 => mapping(uint8 => mapping(uint8 => TierState))) public tierState;
    mapping(uint256 => uint256) public vrfRequestToRound;

    uint256 public currentRoundId;
    uint256 public availablePool;

    address public treasury;

    mapping(address => uint256[]) internal _userTickets;

    // LP vault accounting.
    // totalLpAssets is a *separate* counter from availablePool. It tracks USDC value
    // owned by LP shares, while availablePool tracks USDC available for prize payouts.
    // (availablePool - totalLpAssets) is the implicit "house surplus" - funds that
    // arrived before any LP existed, or fees attributed to non-LP portions of the pool.
    uint256 public totalLpShares;
    uint256 public totalLpAssets;
    mapping(address => LpTranche[]) internal _lpTranches;
    mapping(uint256 => LpSnapshot) public lpSnapshot;
    mapping(uint256 => uint128) public lpAssetsAtSnap; // totalLpAssets captured at requestDraw (after fee, before earmark)
    uint64 public unfinalizedRounds;                    // rounds whose earmark has not yet been settled at _finalizeRound

    // ============================================================
    // EVENTS
    // ============================================================

    event RoundOpened(uint256 indexed roundId, uint64 drawTime);
    event TicketBought(
        uint256 indexed ticketId,
        uint256 indexed roundId,
        address indexed owner,
        uint8 game,
        uint8 k,
        uint64 picksMask,
        uint256 price
    );
    event TicketRefunded(uint256 indexed ticketId, address indexed owner, uint256 amount);
    event Donation(address indexed from, uint256 amount);
    event DrawRequested(uint256 indexed roundId, uint256 vrfRequestId, uint256 snapshotPool);
    event DrawFulfilled(uint256 indexed roundId, uint64 mask5, uint64 mask6);
    event TallyAdvanced(uint256 indexed roundId, uint64 cursor, uint64 totalTickets);
    event RoundFinalized(uint256 indexed roundId, uint256 totalEarmarkUsed);
    event Claimed(uint256 indexed ticketId, address indexed owner, uint256 amount);
    event RoundExpired(uint256 indexed roundId, uint256 leftover);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryFee(uint256 indexed roundId, uint256 amount);
    event TicketTransferred(uint256 indexed ticketId, address indexed from, address indexed to);
    event LpDeposited(address indexed lp, uint256 amount, uint128 shares, uint64 unlockRoundId);
    event LpWithdrawn(address indexed lp, uint256 indexed trancheIndex, uint128 shares, uint256 amount);
    event LpSnapshotTaken(uint256 indexed roundId, uint128 assets, uint128 shares);
    event LpSlashed(uint256 indexed roundId, uint256 lpLoss);
    event LpCredited(uint256 indexed roundId, uint256 lpCredit);
    event CatchUpExecuted(
        address indexed caller,
        uint256 fromRoundId,
        uint256 toRoundId,
        uint256 actionsExecuted
    );

    // ============================================================
    // ERRORS
    // ============================================================

    error InvalidGame();
    error InvalidPickCount();
    error InvalidNumber();
    error DuplicateNumber();
    error WrongRoundState();
    error PurchaseWindowClosed();
    error RefundWindowClosed();
    error TooEarly();
    error NotOwner();
    error AlreadySettled();
    error NothingToClaim();
    error WrongRound();
    error AmountZero();
    error PoolUnderflow();
    error FirstDrawTooSoon();
    error LpAmountZero();
    error LpPoolBelowThreshold();
    error LpSharesZero();
    error TrancheLocked();
    error InvalidTranche();
    error InsufficientShares();
    error PreviousRoundNotSettled();
    error InsufficientLiquidity();

    /// @dev Constructor only sets the immutable `usdc`. All other state is initialized
    ///      by the concrete child's constructor.
    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }
}
