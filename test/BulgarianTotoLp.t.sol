// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BulgarianToto} from "../src/BulgarianToto.sol";
import {BulgarianTotoStorage} from "../src/BulgarianTotoStorage.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

/// @dev LP-vault test suite. Standalone (does not inherit BulgarianTotoTest).
///      `setUp` donates `LP_MIN_POOL` to the pool BEFORE any LP exists so the
///      gate in `depositLp` is open. Because the donation lands while
///      `totalLpShares == 0`, it becomes house surplus and `totalLpAssets`
///      stays at 0 - LP rate math is unaffected.
contract BulgarianTotoLpTest is Test {
    BulgarianToto internal toto;
    MockUSDC internal usdc;
    MockVRFCoordinator internal vrf;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal treasuryAddr = makeAddr("treasury");

    bytes32 constant KEY_HASH = bytes32(uint256(0xDEAD));
    uint256 constant SUB_ID = 1;
    uint16 constant CONFIRMATIONS = 3;
    uint32 constant CALLBACK_GAS = 1_000_000;

    uint64 internal firstDrawTime;

    uint8 constant GAME_5_35 = 0;

    function setUp() public {
        usdc = new MockUSDC();
        vrf = new MockVRFCoordinator();
        firstDrawTime = uint64(block.timestamp + 48 hours);
        toto = new BulgarianToto(
            address(usdc), address(vrf), KEY_HASH, SUB_ID, CONFIRMATIONS, CALLBACK_GAS, firstDrawTime, treasuryAddr
        );

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000 * 1e6);
            vm.prank(users[i]);
            usdc.approve(address(toto), type(uint256).max);
        }
        usdc.mint(address(this), 1_000_000 * 1e6);
        usdc.approve(address(toto), type(uint256).max);

        // Seed pool above LP_MIN_POOL via a pre-LP donation. While totalLpShares == 0
        // the donation goes to house surplus, leaving totalLpAssets at 0.
        toto.donate(toto.LP_MIN_POOL());
    }

    // ============================================================
    // HELPERS (copied from BulgarianTotoTest)
    // ============================================================

    function _expectedDraw(uint256 randomWord, uint8 maxNum, uint8 count)
        internal
        pure
        returns (uint64 mask, uint8[] memory drawn)
    {
        uint8[] memory pool = new uint8[](maxNum);
        for (uint8 i = 0; i < maxNum; i++) {
            pool[i] = i + 1;
        }
        drawn = new uint8[](count);
        for (uint8 i = 0; i < count; i++) {
            uint256 rand = uint256(keccak256(abi.encode(randomWord, i)));
            uint8 j = i + uint8(rand % uint256(uint8(maxNum - i)));
            (pool[i], pool[j]) = (pool[j], pool[i]);
            drawn[i] = pool[i];
            mask |= (uint64(1) << pool[i]);
        }
    }

    function _picks5_35Base(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e)
        internal
        pure
        returns (uint8[] memory p)
    {
        p = new uint8[](5);
        p[0] = a; p[1] = b; p[2] = c; p[3] = d; p[4] = e;
    }

    /// @dev Drive a complete round (request + VRF + tally) for the given roundId.
    ///      Handles both paths: rounds with tickets (need tallyBatch) and zero-ticket
    ///      rounds (auto-finalized inside fulfillRandomWords).
    function _completeRound(uint256 roundId, uint256 seed5, uint256 seed6) internal {
        uint256 reqId = toto.requestDraw(roundId);
        uint256[] memory w = new uint256[](2);
        w[0] = seed5;
        w[1] = seed6;
        vrf.fulfill(reqId, w);
        (,,,,,, uint8 state) = toto.rounds(roundId);
        if (state == 2 /* Tallying */) {
            toto.tallyBatch(roundId, 500);
        }
    }

    // ============================================================
    // DEPOSIT
    // ============================================================

    function test_DepositLp_FirstDepositor_VirtualOffsetApplied() public {
        uint256 amount = 100 * 1e6;
        vm.prank(alice);
        uint128 shares = toto.depositLp(amount);

        assertEq(uint256(shares), amount * toto.LP_VIRTUAL_SHARES());
        assertEq(toto.totalLpAssets(), amount);
        assertEq(toto.totalLpShares(), uint256(shares));
        assertEq(toto.availablePool(), amount + toto.LP_MIN_POOL());
        assertEq(toto.lpTrancheCount(alice), 1);
        BulgarianTotoStorage.LpTranche memory t = toto.lpTrancheAt(alice, 0);
        assertEq(uint256(t.shares), uint256(shares));
        assertEq(uint256(t.unlockRoundId), uint256(toto.LP_LOCKUP_ROUNDS()));
    }

    function test_DepositLp_RevertsOnZero() public {
        vm.expectRevert(BulgarianTotoStorage.LpAmountZero.selector);
        vm.prank(alice);
        toto.depositLp(0);
    }

    function test_DepositLp_RevertsWhenPaused() public {
        toto.pause();
        vm.expectRevert();
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
    }

    function test_DepositLp_SecondDepositor_FairRate() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        uint256 ratePre = toto.totalLpAssets() * 1e18 / toto.totalLpShares();

        vm.prank(bob);
        toto.depositLp(50 * 1e6);
        uint256 ratePost = toto.totalLpAssets() * 1e18 / toto.totalLpShares();

        assertApproxEqAbs(ratePre, ratePost, 1);

        BulgarianTotoStorage.LpTranche memory bobT = toto.lpTrancheAt(bob, 0);
        assertApproxEqAbs(toto.previewLpWithdraw(bobT.shares), 50 * 1e6, 100);
    }

    // ============================================================
    // TICKET BUY / DONATE / REFUND ACCOUNTING
    // ============================================================

    function test_TicketBuy_NoCredit_WhenNoLps() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        assertEq(toto.totalLpAssets(), 0);
        (,,,,,,,, bool lpFlag) = toto.tickets(0);
        assertFalse(lpFlag);
    }

    function test_TicketBuy_CreditsLp_WhenLpsExist() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        uint256 lpBefore = toto.totalLpAssets();

        vm.prank(bob);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        assertEq(toto.totalLpAssets(), lpBefore + 3 * 1e6);

        (,,,,,,,, bool lpFlag) = toto.tickets(0);
        assertTrue(lpFlag);
    }

    function test_Refund_DebitsLp_OnlyIfTagged() public {
        vm.prank(alice);
        uint256 idA = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.prank(bob);
        toto.depositLp(100 * 1e6);
        uint256 lpAfterDeposit = toto.totalLpAssets();

        vm.prank(carol);
        uint256 idB = toto.buyTicket(GAME_5_35, _picks5_35Base(6, 7, 8, 9, 10));
        assertEq(toto.totalLpAssets(), lpAfterDeposit + 3 * 1e6);
        uint256 lpAfterBuyB = toto.totalLpAssets();

        vm.prank(alice);
        toto.refund(idA);
        assertEq(toto.totalLpAssets(), lpAfterBuyB, "LP debited for un-tagged refund");

        vm.prank(carol);
        toto.refund(idB);
        assertEq(toto.totalLpAssets(), lpAfterBuyB - 3 * 1e6, "LP not debited for tagged refund");
    }

    function test_Donate_CreditsLp_WhenLpsExist() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        uint256 lpBefore = toto.totalLpAssets();
        vm.prank(bob);
        toto.donate(50 * 1e6);
        assertEq(toto.totalLpAssets(), lpBefore + 50 * 1e6);
    }

    function test_Donate_NoCredit_WhenNoLps() public {
        vm.prank(alice);
        toto.donate(50 * 1e6);
        assertEq(toto.totalLpAssets(), 0);
    }

    // ============================================================
    // DRAW: TREASURY FEE & SNAPSHOT
    // ============================================================

    function test_RequestDraw_TreasuryFee_AllPoolIsLp() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);

        vm.warp(firstDrawTime);
        toto.requestDraw(0);

        uint256 expectedFee = 100 * 1e6 * uint256(toto.TREASURY_BPS()) / 10000;
        assertEq(toto.totalLpAssets(), 100 * 1e6 - expectedFee);
    }

    function test_RequestDraw_TreasuryFee_WithHouseSurplus() public {
        // setUp() already seeded LP_MIN_POOL as house surplus.
        vm.prank(alice);
        toto.depositLp(100 * 1e6);

        uint256 poolPre = toto.availablePool();
        uint256 lpPre = toto.totalLpAssets();
        uint256 fee = poolPre * uint256(toto.TREASURY_BPS()) / 10000;
        uint256 expectedLpFee = fee * lpPre / poolPre;

        vm.warp(firstDrawTime);
        toto.requestDraw(0);

        assertEq(toto.totalLpAssets(), lpPre - expectedLpFee);
    }

    function test_LpSnapshot_TakenAtNextRoundOpen() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);

        vm.warp(firstDrawTime);
        toto.requestDraw(0);

        (uint128 a, uint128 s) = toto.lpSnapshot(1);
        assertEq(uint256(a), toto.totalLpAssets());
        assertEq(uint256(s), toto.totalLpShares());
    }

    function test_LpAssetsAtSnap_Recorded() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        vm.warp(firstDrawTime);
        toto.requestDraw(0);
        assertEq(uint256(toto.lpAssetsAtSnap(0)), toto.totalLpAssets());
    }

    // ============================================================
    // FINALIZE: SLASHING
    // ============================================================

    function test_Finalize_NoWinners_NoSlash() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        // Pick numbers that are very unlikely to match the seeded draw.
        vm.prank(bob);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.warp(firstDrawTime);
        uint256 lpAtSnapBefore;
        {
            uint256 reqId = toto.requestDraw(0);
            lpAtSnapBefore = toto.totalLpAssets();
            uint256[] memory w = new uint256[](2);
            w[0] = 0xFEED1234;
            w[1] = 0xFEED5678;
            vrf.fulfill(reqId, w);
        }
        toto.tallyBatch(0, 100);

        // totalLpAssets must never grow past the at-snap value during finalize.
        assertLe(toto.totalLpAssets(), lpAtSnapBefore);
    }

    function test_Finalize_Jackpot_SlashesLpProRata() public {
        // Pool has house surplus from setUp() seed plus an LP deposit and a ticket.
        // LPs absorb the prize payout pro-rata to their share of the pool.
        vm.prank(alice);
        toto.depositLp(1_000 * 1e6);

        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);
        vm.prank(bob);
        toto.buyTicket(GAME_5_35, drawn5);

        vm.warp(firstDrawTime);
        uint256 reqId = toto.requestDraw(0);

        uint256 lpAtSnap = uint256(toto.lpAssetsAtSnap(0));
        (,,,, uint128 snap128,,) = toto.rounds(0);
        uint256 snap = uint256(snap128);
        assertLt(lpAtSnap, snap, "with house surplus, lpAtSnap is a strict subset of snap");

        uint256[] memory w = new uint256[](2);
        w[0] = seed5;
        w[1] = seed6;
        vrf.fulfill(reqId, w);
        toto.tallyBatch(0, 100);

        uint256 used = snap * 1500 / 10000;
        // LP loss is pro-rata: used * lpAtSnap / snap.
        uint256 expectedLpAfter = lpAtSnap - (used * lpAtSnap / snap);
        assertEq(toto.totalLpAssets(), expectedLpAfter);

        (uint128 sa, uint128 ss) = toto.lpSnapshot(1);
        assertEq(uint256(sa), expectedLpAfter, "snapshot must refresh post-slash");
        assertEq(uint256(ss), toto.totalLpShares());
    }

    function test_Finalize_Jackpot_HouseAbsorbsNonLpPortion() public {
        toto.donate(500 * 1e6);
        vm.prank(alice);
        toto.depositLp(500 * 1e6);

        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);
        vm.prank(bob);
        toto.buyTicket(GAME_5_35, drawn5);

        vm.warp(firstDrawTime);
        uint256 reqId = toto.requestDraw(0);

        uint256 lpAtSnap = uint256(toto.lpAssetsAtSnap(0));
        (,,,, uint128 snap128,,) = toto.rounds(0);
        uint256 snap = uint256(snap128);
        assertLt(lpAtSnap, snap, "LP slice should be < snap (house surplus exists)");

        uint256[] memory w = new uint256[](2);
        w[0] = seed5;
        w[1] = seed6;
        vrf.fulfill(reqId, w);
        toto.tallyBatch(0, 100);

        uint256 used = snap * 1500 / 10000;
        uint256 expectedLpLoss = used * lpAtSnap / snap;
        assertEq(toto.totalLpAssets(), lpAtSnap - expectedLpLoss);
    }

    // ============================================================
    // WITHDRAWAL GUARDS
    // ============================================================

    function test_WithdrawLp_RevertsBeforeUnlock() public {
        vm.prank(alice);
        uint128 shares = toto.depositLp(100 * 1e6);
        vm.expectRevert(BulgarianTotoStorage.TrancheLocked.selector);
        vm.prank(alice);
        toto.withdrawLp(0, shares);
    }

    function test_WithdrawLp_RevertsWhenPriorRoundNotFinalized() public {
        vm.prank(alice);
        uint128 shares = toto.depositLp(100 * 1e6);

        // Round 0 fully completes.
        vm.warp(firstDrawTime);
        _completeRound(0, 0xABC, 0xDEF);

        // Round 1: requestDraw but DO NOT fulfill/tally.
        vm.warp(firstDrawTime + 48 hours);
        toto.requestDraw(1);

        // Now currentRoundId = 2, round 1 is AwaitingVRF, unfinalizedRounds = 1.
        // Tranche unlock = 2, so the lockup check passes; only the prior-round guard
        // should fire.
        vm.expectRevert(BulgarianTotoStorage.PreviousRoundNotSettled.selector);
        vm.prank(alice);
        toto.withdrawLp(0, shares);
    }

    function test_WithdrawLp_PaysAtSnapshotRate() public {
        vm.prank(alice);
        uint128 shares = toto.depositLp(100 * 1e6);

        vm.warp(firstDrawTime);
        _completeRound(0, 0x9999, 0x8888);
        vm.warp(firstDrawTime + 48 hours);
        _completeRound(1, 0xAAAA, 0xBBBB);

        // Now currentRoundId = 2 (Open), unfinalizedRounds = 0, tranche unlocked.
        uint256 expected = toto.previewLpWithdraw(shares);
        assertGt(expected, 0);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        toto.withdrawLp(0, shares);
        assertEq(usdc.balanceOf(alice) - balBefore, expected);
        BulgarianTotoStorage.LpTranche memory t = toto.lpTrancheAt(alice, 0);
        assertEq(uint256(t.shares), 0);
    }

    function test_WithdrawLp_PartialThenFull() public {
        vm.prank(alice);
        uint128 shares = toto.depositLp(100 * 1e6);

        vm.warp(firstDrawTime);
        _completeRound(0, 0x1, 0x2);
        vm.warp(firstDrawTime + 48 hours);
        _completeRound(1, 0x3, 0x4);

        uint128 half = shares / 2;
        vm.prank(alice);
        toto.withdrawLp(0, half);
        BulgarianTotoStorage.LpTranche memory t = toto.lpTrancheAt(alice, 0);
        assertEq(uint256(t.shares), uint256(shares - half));

        vm.prank(alice);
        toto.withdrawLp(0, t.shares);
        BulgarianTotoStorage.LpTranche memory t2 = toto.lpTrancheAt(alice, 0);
        assertEq(uint256(t2.shares), 0);
    }

    function test_WithdrawLp_RevertsOnZeroShares() public {
        vm.prank(alice);
        toto.depositLp(100 * 1e6);
        vm.expectRevert(BulgarianTotoStorage.LpSharesZero.selector);
        vm.prank(alice);
        toto.withdrawLp(0, 0);
    }

    function test_WithdrawLp_RevertsOnInvalidTranche() public {
        vm.expectRevert(BulgarianTotoStorage.InvalidTranche.selector);
        vm.prank(alice);
        toto.withdrawLp(0, 1);
    }

    function test_WithdrawLp_RevertsOnInsufficientShares() public {
        vm.prank(alice);
        uint128 shares = toto.depositLp(100 * 1e6);
        vm.expectRevert(BulgarianTotoStorage.InsufficientShares.selector);
        vm.prank(alice);
        toto.withdrawLp(0, shares + 1);
    }

    // ============================================================
    // INTEGRATION
    // ============================================================

    function test_Integration_LpGainsOnNoWinnerCycle() public {
        // Donate so house surplus absorbs ticket prizes; LP starts isolated.
        // Simpler: LP funds entire pool, no other tickets. After 2 rounds with no
        // winners, LPs receive their full deposit back minus 2 rounds of treasury fee.
        vm.prank(alice);
        uint128 shares = toto.depositLp(1_000 * 1e6);

        vm.warp(firstDrawTime);
        _completeRound(0, 0xDEADBEEF, 0xCAFEBABE);
        vm.warp(firstDrawTime + 48 hours);
        _completeRound(1, 0x9999, 0x8888);

        uint256 expected = toto.previewLpWithdraw(shares);
        assertGt(expected, 0, "withdraw value must be positive");

        // Two rounds, each took 1% fee from a pool that was 100% LP-owned at the time.
        // After the first fee, LP base shrinks; second fee is 1% of the smaller base.
        // expected ≈ 1000 * 0.99 * 0.99 = 980.1 USDC.
        // Allow some slack for rounding via virtual offset and integer math.
        uint256 lower = 970 * 1e6;
        uint256 upper = 990 * 1e6;
        assertGe(expected, lower);
        assertLe(expected, upper);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        toto.withdrawLp(0, shares);
        assertEq(usdc.balanceOf(alice) - balBefore, expected);
    }
}
