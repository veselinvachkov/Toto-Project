// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BulgarianToto} from "../src/BulgarianToto.sol";
import {BulgarianTotoStorage} from "../src/BulgarianTotoStorage.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract BulgarianTotoTest is Test {
    BulgarianToto internal toto;
    MockUSDC internal usdc;
    MockVRFCoordinator internal vrf;

    address internal owner = address(this); // deployer
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
    uint8 constant GAME_6_49 = 1;

    function setUp() public virtual {
        usdc = new MockUSDC();
        vrf = new MockVRFCoordinator();
        firstDrawTime = uint64(block.timestamp + 48 hours);
        toto = new BulgarianToto(
            address(usdc), address(vrf), KEY_HASH, SUB_ID, CONFIRMATIONS, CALLBACK_GAS, firstDrawTime, treasuryAddr
        );

        // Fund users
        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < users.length; i++) {
            usdc.mint(users[i], 1_000_000 * 1e6);
            vm.prank(users[i]);
            usdc.approve(address(toto), type(uint256).max);
        }
        // Donate a starting pool to make payouts non-zero on jackpot tests.
        usdc.mint(address(this), 100_000 * 1e6);
        usdc.approve(address(toto), type(uint256).max);
        toto.donate(100_000 * 1e6);
    }

    // ============================================================
    // HELPERS
    // ============================================================

    /// @dev Mirrors BulgarianToto._drawNumbersToMask so the test can craft
    ///      tickets that match the deterministic VRF output.
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
        p[0] = a;
        p[1] = b;
        p[2] = c;
        p[3] = d;
        p[4] = e;
    }

    function _picks6_49Base(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 f)
        internal
        pure
        returns (uint8[] memory p)
    {
        p = new uint8[](6);
        p[0] = a;
        p[1] = b;
        p[2] = c;
        p[3] = d;
        p[4] = e;
        p[5] = f;
    }

    function _runDraw(uint256 seed5, uint256 seed6) internal returns (uint256 reqId) {
        vm.warp(firstDrawTime);
        reqId = toto.requestDraw(0);
        uint256[] memory words = new uint256[](2);
        words[0] = seed5;
        words[1] = seed6;
        vrf.fulfill(reqId, words);
    }

    function _findNonWinningNumber5_35(uint64 drawnMask) internal pure returns (uint8) {
        for (uint8 i = 1; i <= 35; i++) {
            if ((drawnMask & (uint64(1) << i)) == 0) return i;
        }
        revert("no free");
    }

    // ============================================================
    // BUY / VALIDATION TESTS
    // ============================================================

    function test_BuyTicket_5of35_Base() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        assertEq(id, 0);
        assertEq(toto.availablePool(), 100_000 * 1e6 + 3 * 1e6);
        assertEq(toto.roundTicketCount(0), 1);
    }

    function test_BuyTicket_6of49_Plus2() public {
        uint8[] memory picks = new uint8[](8);
        for (uint8 i = 0; i < 8; i++) {
            picks[i] = i + 1;
        }
        vm.prank(bob);
        toto.buyTicket(GAME_6_49, picks);
        assertEq(toto.availablePool(), 100_000 * 1e6 + 9 * 1e6);
    }

    function test_BuyTicket_Reverts_OnInvalidGame() public {
        vm.expectRevert(BulgarianTotoStorage.InvalidGame.selector);
        vm.prank(alice);
        toto.buyTicket(2, _picks5_35Base(1, 2, 3, 4, 5));
    }

    function test_BuyTicket_Reverts_OnInvalidPickCount() public {
        uint8[] memory picks = new uint8[](4);
        for (uint8 i = 0; i < 4; i++) {
            picks[i] = i + 1;
        }
        vm.expectRevert(BulgarianTotoStorage.InvalidPickCount.selector);
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, picks);
    }

    function test_BuyTicket_Reverts_OnDuplicateNumbers() public {
        uint8[] memory picks = _picks5_35Base(1, 2, 2, 4, 5);
        vm.expectRevert(BulgarianTotoStorage.DuplicateNumber.selector);
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, picks);
    }

    function test_BuyTicket_Reverts_OnOutOfRangeNumber() public {
        uint8[] memory picks = _picks5_35Base(1, 2, 3, 4, 36);
        vm.expectRevert(BulgarianTotoStorage.InvalidNumber.selector);
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, picks);
    }

    function test_BuyTicket_Reverts_OnZeroNumber() public {
        uint8[] memory picks = _picks5_35Base(0, 2, 3, 4, 5);
        vm.expectRevert(BulgarianTotoStorage.InvalidNumber.selector);
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, picks);
    }

    function test_BuyTicket_Reverts_AfterPurchaseCutoff() public {
        vm.warp(firstDrawTime - 30 minutes); // inside the 1h cutoff
        vm.expectRevert(BulgarianTotoStorage.PurchaseWindowClosed.selector);
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
    }

    function test_BuyTicket_Reverts_WhenPaused() public {
        toto.pause();
        vm.expectRevert();
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
    }

    // ============================================================
    // PAUSE TESTS
    // ============================================================

    function test_Pause_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        toto.pause();
    }

    function test_Donate_Works_WhenPaused() public {
        toto.pause();
        vm.prank(alice);
        toto.donate(1e6);
    }

    function test_Refund_WorksWhilePaused() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        uint256 balBefore = usdc.balanceOf(alice);
        toto.pause();
        vm.prank(alice);
        toto.refund(id);
        assertEq(usdc.balanceOf(alice), balBefore + 3 * 1e6);
    }

    // ============================================================
    // REFUND TESTS
    // ============================================================

    function test_Refund_Within1Hour_Succeeds() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        uint256 balBefore = usdc.balanceOf(alice);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(alice);
        toto.refund(id);
        assertEq(usdc.balanceOf(alice), balBefore + 3 * 1e6);
        assertEq(toto.availablePool(), 100_000 * 1e6);
    }

    function test_Refund_AfterWindow_Reverts() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(BulgarianTotoStorage.RefundWindowClosed.selector);
        vm.prank(alice);
        toto.refund(id);
    }

    function test_Refund_AfterPurchaseWindowClosed_Reverts() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.warp(firstDrawTime - 30 minutes); // within 1h-of-purchase yet outside buy window
        vm.expectRevert(BulgarianTotoStorage.RefundWindowClosed.selector);
        vm.prank(alice);
        toto.refund(id);
    }

    function test_Refund_NonOwner_Reverts() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.expectRevert(BulgarianTotoStorage.NotOwner.selector);
        vm.prank(bob);
        toto.refund(id);
    }

    function test_Refund_DoubleRefund_Reverts() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.prank(alice);
        toto.refund(id);
        vm.expectRevert(BulgarianTotoStorage.AlreadySettled.selector);
        vm.prank(alice);
        toto.refund(id);
    }

    // ============================================================
    // DONATE
    // ============================================================

    function test_Donate_GrowsPool() public {
        uint256 before = toto.availablePool();
        vm.prank(alice);
        toto.donate(50 * 1e6);
        assertEq(toto.availablePool(), before + 50 * 1e6);
    }

    function test_Donate_RevertsOnZero() public {
        vm.expectRevert(BulgarianTotoStorage.AmountZero.selector);
        vm.prank(alice);
        toto.donate(0);
    }

    // ============================================================
    // DRAW + VRF FLOW
    // ============================================================

    function test_RequestDraw_TooEarly_Reverts() public {
        vm.expectRevert(BulgarianTotoStorage.TooEarly.selector);
        toto.requestDraw(0);
    }

    function test_RequestDraw_AdvancesRoundAndEarmarks() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.warp(firstDrawTime);
        uint256 poolBefore = toto.availablePool();
        toto.requestDraw(0);

        assertEq(toto.currentRoundId(), 1);
        // Treasury skims TREASURY_BPS first, then earmark is MAX_PAYOUT_BPS of the post-skim pool.
        uint256 postSkim = poolBefore - poolBefore * toto.TREASURY_BPS() / 10000;
        uint256 expectedEarmark = postSkim * toto.MAX_PAYOUT_BPS() / 10000;
        assertEq(toto.earmarkedForRound(0), expectedEarmark);
        assertEq(toto.availablePool(), postSkim - expectedEarmark);
    }

    function test_AnyoneCanRequestDraw() public {
        vm.warp(firstDrawTime);
        vm.prank(alice);
        toto.requestDraw(0);
        assertEq(toto.currentRoundId(), 1);
    }

    function test_NextRoundDrawTimeIsPlus48h() public {
        vm.warp(firstDrawTime);
        toto.requestDraw(0);
        (uint64 dt,,,,,, ) = toto.rounds(1);
        assertEq(dt, firstDrawTime + 48 hours);
    }

    // ============================================================
    // FULL FLOW: 5/35 JACKPOT
    // ============================================================

    function test_HappyPath_5of35_Jackpot() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        // Alice buys the winning 5 numbers.
        vm.prank(alice);
        uint256 ticketId = toto.buyTicket(GAME_5_35, drawn5);

        _runDraw(seed5, seed6);
        (,,,,uint128 snap,,) = toto.rounds(0);
        uint256 poolAtDraw = uint256(snap);

        // Tally and finalize.
        toto.tallyBatch(0, 100);

        uint256 expected = poolAtDraw * 1500 / 10000; // 15% of snapshot pool
        assertEq(toto.previewClaim(ticketId), expected);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        toto.claim(ticketId);
        assertEq(usdc.balanceOf(alice) - balBefore, expected);
    }

    // ============================================================
    // FULL FLOW: 6/49 JACKPOT
    // ============================================================

    function test_HappyPath_6of49_Jackpot() public {
        uint256 seed5 = 0xCAFE;
        uint256 seed6 = 0xBEEF;
        (, uint8[] memory drawn6) = _expectedDraw(seed6, 49, 6);

        vm.prank(bob);
        uint256 ticketId = toto.buyTicket(GAME_6_49, drawn6);

        _runDraw(seed5, seed6);
        (,,,,uint128 snap,,) = toto.rounds(0);
        uint256 poolAtDraw = uint256(snap);
        toto.tallyBatch(0, 100);

        uint256 expected = poolAtDraw * 5500 / 10000; // 55%
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        toto.claim(ticketId);
        assertEq(usdc.balanceOf(bob) - balBefore, expected);
    }

    // ============================================================
    // PRO-RATA SPLIT
    // ============================================================

    function test_ProRata_TwoJackpotWinners_5of35() public {
        uint256 seed5 = 0x1111;
        uint256 seed6 = 0x2222;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        uint256 idA = toto.buyTicket(GAME_5_35, drawn5);
        vm.prank(bob);
        uint256 idB = toto.buyTicket(GAME_5_35, drawn5);

        _runDraw(seed5, seed6);
        (,,,,uint128 snap,,) = toto.rounds(0);
        uint256 poolAtDraw = uint256(snap);
        toto.tallyBatch(0, 100);

        uint256 totalPrize = poolAtDraw * 1500 / 10000;
        uint256 perWinner = totalPrize / 2;

        vm.prank(alice);
        toto.claim(idA);
        vm.prank(bob);
        toto.claim(idB);

        assertEq(usdc.balanceOf(alice), 1_000_000 * 1e6 - 3 * 1e6 + perWinner);
        assertEq(usdc.balanceOf(bob), 1_000_000 * 1e6 - 3 * 1e6 + perWinner);
    }

    // ============================================================
    // SYSTEM TICKET (+2): sub-ticket math
    // ============================================================

    function test_SystemTicket_5of35_Plus2_AllFiveDrawnInside() public {
        uint256 seed5 = 0x9999;
        uint256 seed6 = 0x8888;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        // Build a 7-pick ticket: all 5 drawn numbers + 2 non-drawn extras.
        uint8[] memory picks = new uint8[](7);
        for (uint8 i = 0; i < 5; i++) {
            picks[i] = drawn5[i];
        }
        uint8 extra1 = _findNonWinningNumber5_35(_maskOf(drawn5));
        uint8 extra2 = extra1 + 1;
        // ensure extra2 is also not drawn
        while ((_maskOf(drawn5) & (uint64(1) << extra2)) != 0 || extra2 > 35) {
            extra2++;
        }
        picks[5] = extra1;
        picks[6] = extra2;

        vm.prank(alice);
        uint256 ticketId = toto.buyTicket(GAME_5_35, picks);

        _runDraw(seed5, seed6);
        (,,,,uint128 snap,,) = toto.rounds(0);
        uint256 poolAtDraw = uint256(snap);
        toto.tallyBatch(0, 100);

        // m = 5 hits across 7 picks → sub-ticket distribution:
        // tier 5 hits: C(5,5)*C(2,0) = 1
        // tier 4 hits: C(5,4)*C(2,1) = 5*2 = 10
        // tier 3 hits: C(5,3)*C(2,2) = 10*1 = 10
        // Alice is the only ticket in each tier → she takes the entire tier budget for each.
        uint256 expected =
            poolAtDraw * 1500 / 10000 // tier5 (15%)
                + poolAtDraw * 100 / 10000 // tier4 (1%)
                + poolAtDraw * 20 / 10000; // tier3 (0.2%)
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        toto.claim(ticketId);
        assertEq(usdc.balanceOf(alice) - balBefore, expected);
    }

    function _maskOf(uint8[] memory nums) internal pure returns (uint64 mask) {
        for (uint256 i = 0; i < nums.length; i++) {
            mask |= (uint64(1) << nums[i]);
        }
    }

    // ============================================================
    // CLAIM ERROR PATHS
    // ============================================================

    function test_Claim_NonWinner_Reverts() public {
        uint256 seed5 = 0x4242;
        uint256 seed6 = 0x4343;
        (uint64 mask5,) = _expectedDraw(seed5, 35, 5);

        // Build a losing ticket with 0 hits - first 5 numbers not in drawn mask.
        uint8[] memory picks = new uint8[](5);
        uint256 placed = 0;
        for (uint8 i = 1; i <= 35 && placed < 5; i++) {
            if ((mask5 & (uint64(1) << i)) == 0) {
                picks[placed++] = i;
            }
        }
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, picks);

        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        vm.expectRevert(BulgarianTotoStorage.NothingToClaim.selector);
        vm.prank(alice);
        toto.claim(id);
    }

    function test_Claim_BeforeFinalize_Reverts() public {
        uint256 seed5 = 0x7;
        uint256 seed6 = 0x8;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, drawn5);
        _runDraw(seed5, seed6);
        // tally NOT called → still Tallying, not Claimable
        vm.expectRevert(BulgarianTotoStorage.WrongRoundState.selector);
        vm.prank(alice);
        toto.claim(id);
    }

    // ============================================================
    // SWEEP EXPIRED
    // ============================================================

    function test_Sweep_ReturnsLeftoverToPool() public {
        uint256 seed5 = 0x77;
        uint256 seed6 = 0x88;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, drawn5);

        _runDraw(seed5, seed6);
        (,,,,uint128 snap,,) = toto.rounds(0);
        uint256 poolAtDraw = uint256(snap);
        toto.tallyBatch(0, 100);

        uint256 prize = poolAtDraw * 1500 / 10000;
        uint256 poolAfterFinalize = toto.availablePool();

        // Alice never claims. Warp past expiry.
        vm.warp(uint256(firstDrawTime) + 365 days);
        toto.sweepExpired(0);

        assertEq(toto.availablePool(), poolAfterFinalize + prize);

        // After sweep, claim must revert.
        vm.expectRevert(BulgarianTotoStorage.WrongRoundState.selector);
        vm.prank(alice);
        toto.claim(id);
    }

    function test_Sweep_TooEarly_Reverts() public {
        uint256 seed5 = 0x55;
        uint256 seed6 = 0x66;
        // Buy at least one ticket so the round actually has a tally step.
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);
        vm.expectRevert(BulgarianTotoStorage.TooEarly.selector);
        toto.sweepExpired(0);
    }

    // ============================================================
    // POOL ACCOUNTING INVARIANT
    // ============================================================

    function test_AvailablePool_PlusEarmarks_EqualsContractBalance() public {
        // Buys + donate
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.prank(bob);
        toto.buyTicket(GAME_6_49, _picks6_49Base(1, 2, 3, 4, 5, 6));
        vm.prank(carol);
        toto.donate(123 * 1e6);

        // Draw round 0
        _runDraw(0xABC, 0xDEF);
        toto.tallyBatch(0, 100);

        uint256 sum = toto.availablePool() + toto.earmarkedForRound(0);
        // Some prize budget may have been already removed for tiers with winners,
        // so the live invariant is: contract balance == availablePool + earmarked.
        assertEq(usdc.balanceOf(address(toto)), sum);
    }

    // ============================================================
    // TICKET TRANSFER
    // ============================================================

    function test_TransferTicket_UpdatesOwner() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.prank(alice);
        toto.transferTicket(id, bob);

        (address newOwner,,,,,,,,) = toto.tickets(id);
        assertEq(newOwner, bob);
    }

    function test_TransferTicket_NewOwnerCanClaim() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, drawn5);

        // Alice transfers to bob before the draw.
        vm.prank(alice);
        toto.transferTicket(id, bob);

        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        toto.claim(id);
        assertTrue(usdc.balanceOf(bob) > balBefore);
    }

    function test_TransferTicket_OldOwnerCannotClaim() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, drawn5);
        vm.prank(alice);
        toto.transferTicket(id, bob);

        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        vm.expectRevert(BulgarianTotoStorage.NotOwner.selector);
        vm.prank(alice);
        toto.claim(id);
    }

    function test_TransferTicket_Reverts_NonOwner() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.expectRevert(BulgarianTotoStorage.NotOwner.selector);
        vm.prank(bob);
        toto.transferTicket(id, carol);
    }

    function test_TransferTicket_Reverts_ZeroAddress() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.expectRevert();
        vm.prank(alice);
        toto.transferTicket(id, address(0));
    }

    function test_TransferTicket_Reverts_AlreadyClaimed() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, drawn5);
        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        vm.prank(alice);
        toto.claim(id);

        vm.expectRevert(BulgarianTotoStorage.AlreadySettled.selector);
        vm.prank(alice);
        toto.transferTicket(id, bob);
    }

    function test_TransferTicket_Reverts_AlreadyRefunded() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.prank(alice);
        toto.refund(id);

        vm.expectRevert(BulgarianTotoStorage.AlreadySettled.selector);
        vm.prank(alice);
        toto.transferTicket(id, bob);
    }

    // ============================================================
    // BATCH CLAIM
    // ============================================================

    function test_ClaimBatch_MultipleWinners() public {
        uint256 seed5 = 0x1111;
        uint256 seed6 = 0x2222;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        // Alice buys two identical winning tickets.
        vm.prank(alice);
        uint256 idA = toto.buyTicket(GAME_5_35, drawn5);
        vm.prank(alice);
        uint256 idB = toto.buyTicket(GAME_5_35, drawn5);

        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        uint256[] memory ids = new uint256[](2);
        ids[0] = idA;
        ids[1] = idB;

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 total = toto.claimBatch(ids);
        assertEq(usdc.balanceOf(alice) - balBefore, total);
        assertTrue(total > 0);
    }

    function test_ClaimBatch_Reverts_AllZeroPayout() public {
        uint256 seed5 = 0x4242;
        uint256 seed6 = 0x4343;
        (uint64 mask5,) = _expectedDraw(seed5, 35, 5);

        // Buy a losing ticket (no matching numbers).
        uint8[] memory picks = new uint8[](5);
        uint256 placed = 0;
        for (uint8 i = 1; i <= 35 && placed < 5; i++) {
            if ((mask5 & (uint64(1) << i)) == 0) {
                picks[placed++] = i;
            }
        }

        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, picks);
        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;

        vm.expectRevert(BulgarianTotoStorage.NothingToClaim.selector);
        vm.prank(alice);
        toto.claimBatch(ids);
    }

    // ============================================================
    // FRONTEND HELPERS
    // ============================================================

    function test_GetRoundInfo() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.prank(bob);
        toto.buyTicket(GAME_6_49, _picks6_49Base(1, 2, 3, 4, 5, 6));

        BulgarianTotoStorage.RoundInfo memory info = toto.getRoundInfo(0);
        assertEq(info.drawTime, firstDrawTime);
        assertEq(uint8(info.state), uint8(BulgarianTotoStorage.RoundState.Open));
        assertEq(info.ticketCount, 2);
    }

    function test_GetRoundTiers_AfterFinalize() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        toto.buyTicket(GAME_5_35, drawn5);
        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        (BulgarianTotoStorage.TierState[3] memory t5,) = toto.getRoundTiers(0);
        // Tier 5 (index 2) should have budget > 0 since alice hit the jackpot.
        assertTrue(t5[2].budget > 0);
        assertEq(t5[2].totalHits, 1);
    }

    function test_GetUserTickets() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.prank(alice);
        toto.buyTicket(GAME_6_49, _picks6_49Base(1, 2, 3, 4, 5, 6));

        uint256[] memory ids = toto.getUserTickets(alice);
        assertEq(ids.length, 2);
    }

    function test_GetUserTickets_IncludesTransferred() public {
        vm.prank(alice);
        uint256 id = toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        vm.prank(alice);
        toto.transferTicket(id, bob);

        uint256[] memory bobIds = toto.getUserTickets(bob);
        assertEq(bobIds.length, 1);
        assertEq(bobIds[0], id);
    }

    function test_IsWinner() public {
        uint256 seed5 = 0xAAAA;
        uint256 seed6 = 0xBBBB;
        (, uint8[] memory drawn5) = _expectedDraw(seed5, 35, 5);

        vm.prank(alice);
        uint256 winId = toto.buyTicket(GAME_5_35, drawn5);

        // Non-winning ticket.
        (uint64 mask5,) = _expectedDraw(seed5, 35, 5);
        uint8[] memory losingPicks = new uint8[](5);
        uint256 placed = 0;
        for (uint8 i = 1; i <= 35 && placed < 5; i++) {
            if ((mask5 & (uint64(1) << i)) == 0) {
                losingPicks[placed++] = i;
            }
        }
        vm.prank(bob);
        uint256 loseId = toto.buyTicket(GAME_5_35, losingPicks);

        _runDraw(seed5, seed6);
        toto.tallyBatch(0, 100);

        assertTrue(toto.isWinner(winId));
        assertFalse(toto.isWinner(loseId));
    }

    // ============================================================
    // CATCH-UP
    // ============================================================

    /// @dev Open round whose drawTime has passed → catchUp triggers requestDraw.
    /// @dev catchUp triggers AT MOST ONE requestDraw per call (conservative: avoids
    ///      burning LINK on a cascade of empty rounds when DRAW_INTERVAL is short
    ///      relative to the missed period).
    function test_CatchUp_OpenWithPassedDrawTime_TriggersRequestDraw() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        // Long delay: nobody calls requestDraw for many DRAW_INTERVALs.
        vm.warp(firstDrawTime + 30 days);

        uint256 cur = toto.currentRoundId();
        uint256 actions = toto.catchUp(0, 50, 500);

        assertEq(actions, 1, "exactly one requestDraw per catchUp call");
        // Round 0 should now be AwaitingVRF and round 1 should exist (Open).
        BulgarianTotoStorage.RoundInfo memory r0 = toto.getRoundInfo(0);
        assertEq(uint8(r0.state), uint8(BulgarianTotoStorage.RoundState.AwaitingVRF));
        assertEq(toto.currentRoundId(), cur + 1);
    }

    /// @dev Tallying round → catchUp triggers tallyBatch and finalizes.
    function test_CatchUp_TallyingRound_FinalizesIt() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        // Move to AwaitingVRF then fulfill so state is Tallying.
        _runDraw(0xAAAA, 0xBBBB);

        BulgarianTotoStorage.RoundInfo memory rBefore = toto.getRoundInfo(0);
        // With 1 ticket, fulfillRandomWords moves to Tallying (not auto-finalize).
        assertEq(uint8(rBefore.state), uint8(BulgarianTotoStorage.RoundState.Tallying));

        uint256 actions = toto.catchUp(0, 10, 500);
        assertEq(actions, 1, "should have done 1 action: tallyBatch");

        BulgarianTotoStorage.RoundInfo memory rAfter = toto.getRoundInfo(0);
        assertEq(uint8(rAfter.state), uint8(BulgarianTotoStorage.RoundState.Claimable));
    }

    /// @dev Claimable round past expiry → catchUp triggers sweepExpired.
    function test_CatchUp_ExpiredClaimable_TriggersSweep() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        _runDraw(0xAAAA, 0xBBBB);
        toto.tallyBatch(0, 500);

        // Past expiry now.
        BulgarianTotoStorage.RoundInfo memory r = toto.getRoundInfo(0);
        vm.warp(r.expiryTime + 1);

        // Scope only round 0 to isolate the sweep from round 1's auto-requestDraw.
        uint256 actions = toto.catchUp(0, 1, 500);
        assertEq(actions, 1, "should have done 1 action: sweepExpired");

        BulgarianTotoStorage.RoundInfo memory rAfter = toto.getRoundInfo(0);
        assertEq(uint8(rAfter.state), uint8(BulgarianTotoStorage.RoundState.Expired));
    }

    /// @dev AwaitingVRF round → catchUp leaves it untouched (no VRF available).
    function test_CatchUp_AwaitingVRF_SkipsSilently() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));

        vm.warp(firstDrawTime);
        toto.requestDraw(0);

        BulgarianTotoStorage.RoundInfo memory r0 = toto.getRoundInfo(0);
        assertEq(uint8(r0.state), uint8(BulgarianTotoStorage.RoundState.AwaitingVRF));

        uint256 actions = toto.catchUp(0, 10, 500);
        assertEq(actions, 0, "AwaitingVRF must be skipped");

        BulgarianTotoStorage.RoundInfo memory r0After = toto.getRoundInfo(0);
        assertEq(uint8(r0After.state), uint8(BulgarianTotoStorage.RoundState.AwaitingVRF));
    }

    /// @dev Idempotent: running catchUp on a fully-settled chain does nothing.
    function test_CatchUp_Idempotent() public {
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        _runDraw(0xAAAA, 0xBBBB);
        toto.tallyBatch(0, 500);

        uint256 actions = toto.catchUp(0, 10, 500);
        assertEq(actions, 0, "settled state should not produce actions");
    }

    /// @dev Mixed pipeline in one call: Tallying first, then triggers requestDraw on
    ///      the next-current Open round whose drawTime has also passed.
    function test_CatchUp_HandlesMultipleStatesInOneCall() public {
        // Round 0: get to Tallying with 1 ticket
        vm.prank(alice);
        toto.buyTicket(GAME_5_35, _picks5_35Base(1, 2, 3, 4, 5));
        _runDraw(0xAAAA, 0xBBBB);
        // Round 0 is now Tallying. Round 1 is Open with drawTime = firstDrawTime + INTERVAL.

        // Warp so that round 1's drawTime has also passed.
        BulgarianTotoStorage.RoundInfo memory r1 = toto.getRoundInfo(1);
        vm.warp(r1.drawTime + 1);

        uint256 actions = toto.catchUp(0, 50, 500);
        // Expected: 1) tallyBatch(0) → Claimable. 2) requestDraw(1) → AwaitingVRF.
        assertEq(actions, 2, "should have tallied round 0 AND requested draw on round 1");

        BulgarianTotoStorage.RoundInfo memory r0After = toto.getRoundInfo(0);
        BulgarianTotoStorage.RoundInfo memory r1After = toto.getRoundInfo(1);
        assertEq(uint8(r0After.state), uint8(BulgarianTotoStorage.RoundState.Claimable));
        assertEq(uint8(r1After.state), uint8(BulgarianTotoStorage.RoundState.AwaitingVRF));
    }
}
