// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../src/MockUSDC.sol";
import { WagerPool } from "../src/WagerPool.sol";
import { WagerPoolFactory } from "../src/WagerPoolFactory.sol";

contract WagerPoolTest is Test {
    MockUSDC usdc;
    WagerPoolFactory factory;
    WagerPool pool;

    // USDC has 6 decimals: $10 = 10_000_000
    uint256 constant BUY_IN = 10_000_000;
    uint16 constant FEE_BPS = 500; // 5%
    uint8 constant MAX_PLAYERS = 4;
    uint256 constant DISPUTE_WINDOW = 600;   // 10 minutes
    uint256 constant LOBBY_TIMEOUT = 1 hours;
    uint256 constant MATCH_TIMEOUT = 24 hours;

    address keeper = makeAddr("keeper");     // game server
    address treasury = makeAddr("treasury"); // platform fee pocket
    address resolver = makeAddr("resolver"); // NEUTRAL dispute resolver
    address host = makeAddr("host");         // room creator / player 1

    address p2 = makeAddr("p2");
    address p3 = makeAddr("p3");
    address p4 = makeAddr("p4");

    function setUp() public {
        usdc = new MockUSDC();
        factory = new WagerPoolFactory(
            address(usdc),
            keeper,
            treasury,
            resolver,
            DISPUTE_WINDOW,
            LOBBY_TIMEOUT,
            MATCH_TIMEOUT
        );
        // create the pool AS the host, so pool.host() == host
        vm.prank(host);
        pool = factory.createPool(BUY_IN, MAX_PLAYERS, FEE_BPS);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// Give a player test money and approve the pool to spend it.
    function _fundAndApprove(address player) internal {
        usdc.mint(player, 1_000 * 1e6);
        vm.prank(player);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _join(address player) internal {
        _fundAndApprove(player);
        vm.prank(player);
        pool.join();
    }

    /// Everyone joins (4 players), host starts the match.
    function _fullLobby() internal {
        _join(host);
        _join(p2);
        _join(p3);
        _join(p4);
        vm.prank(host);
        pool.start();
    }

    /// Full flow to a settled pool (no dispute): join, start, propose, wait, finalize.
    function _settleWithWinner(address winnerPlayer) internal {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(winnerPlayer);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        pool.finalize();
    }

    // ─────────────────────── 1. Joining the pool ───────────────────────

    function test_JoinCollectsBuyIn() public {
        _join(host);
        _join(p2);
        _join(p3);
        _join(p4);

        assertEq(pool.playerCount(), 4);
        assertEq(pool.poolBalance(), 4 * BUY_IN);
        assertEq(usdc.balanceOf(address(pool)), 4 * BUY_IN);
    }

    function test_JoinTwiceReverts() public {
        _join(host);
        vm.prank(host);
        vm.expectRevert("WagerPool: already joined");
        pool.join();
    }

    function test_JoinWhenFullReverts() public {
        _join(host);
        _join(p2);
        _join(p3);
        _join(p4);

        address p5 = makeAddr("p5");
        _fundAndApprove(p5);
        vm.prank(p5);
        vm.expectRevert("WagerPool: pool full");
        pool.join();
    }

    function test_JoinWithoutApprovalReverts() public {
        usdc.mint(host, 100 * 1e6); // money, but NO approve
        vm.prank(host);
        vm.expectRevert(); // ERC20 insufficient allowance
        pool.join();
    }

    // ─────────────────────── 2. Lobby leave (edge #1) ──────────────────

    function test_LeaveRefundsPlayer() public {
        _join(host);
        _join(p2);
        _join(p3);

        uint256 p2Before = usdc.balanceOf(p2);
        vm.prank(p2);
        pool.leave();

        assertEq(usdc.balanceOf(p2) - p2Before, BUY_IN); // got their $10 back
        assertEq(pool.playerCount(), 2);
        assertEq(pool.isJoined(p2), false);
        assertEq(pool.poolBalance(), 2 * BUY_IN); // pool shrank by exactly one buy-in
    }

    function test_LeaveAfterStartReverts() public {
        _fullLobby();
        vm.prank(p2);
        vm.expectRevert("WagerPool: not open");
        pool.leave();
    }

    function test_LeaveNotAPlayerReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("WagerPool: not a player");
        pool.leave();
    }

    function test_HostCannotLeaveMustRefund() public {
        _join(host);
        _join(p2);
        vm.prank(host);
        vm.expectRevert("WagerPool: host must refund instead");
        pool.leave();
    }

    // ─────────────────── 3. Lobby kick (edge #2) ───────────────────────

    function test_KickRefundsVictimHostGainsNothing() public {
        _join(host);
        _join(p2);
        _join(p3);

        uint256 p2Before = usdc.balanceOf(p2);
        uint256 hostBefore = usdc.balanceOf(host);

        vm.prank(host);
        pool.kickPlayer(p2);

        // victim refunded
        assertEq(usdc.balanceOf(p2) - p2Before, BUY_IN);
        // host gained NOTHING from the kick
        assertEq(usdc.balanceOf(host), hostBefore);
        assertEq(pool.playerCount(), 2);
        assertEq(pool.isJoined(p2), false);
    }

    function test_KickAfterStartReverts() public {
        _fullLobby();
        vm.prank(host);
        vm.expectRevert("WagerPool: not open");
        pool.kickPlayer(p2);
    }

    function test_KickOnlyHost() public {
        _join(host);
        _join(p2);
        vm.prank(p2);
        vm.expectRevert("WagerPool: not host");
        pool.kickPlayer(p3);
    }

    function test_KickCannotKickHost() public {
        _join(host);
        _join(p2);
        vm.prank(host);
        vm.expectRevert("WagerPool: cannot kick host");
        pool.kickPlayer(host);
    }

    function test_KickNonPlayerReverts() public {
        _join(host);
        _join(p2);
        address stranger = makeAddr("stranger");
        vm.prank(host);
        vm.expectRevert("WagerPool: not a player");
        pool.kickPlayer(stranger);
    }

    // ─────────────────── 4. Starting the match ─────────────────────────

    function test_HostStartsMatch() public {
        _join(host);
        _join(p2);
        vm.prank(host);
        pool.start();
        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Locked));
    }

    function test_StartWithOnePlayerReverts() public {
        _join(host);
        vm.prank(host);
        vm.expectRevert("WagerPool: need >= 2 players");
        pool.start();
    }

    function test_StartNotHostReverts() public {
        _join(host);
        _join(p2);
        vm.prank(p2);
        vm.expectRevert("WagerPool: not host");
        pool.start();
    }

    // ───────────────── 5. THE payout math (the important one) ──────────

    function test_FullFlowPayoutMath() public {
        _settleWithWinner(host);

        uint256 winnerBefore = usdc.balanceOf(host);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(host);
        pool.claim();

        // $40 pool, 5% fee → winner $38, treasury $2
        assertEq(usdc.balanceOf(host) - winnerBefore, 38 * 1e6);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 2 * 1e6);
        assertEq(pool.poolBalance(), 0); // pool is drained
    }

    function test_FeeZeroPaysFullPool() public {
        vm.prank(host);
        WagerPool noFeePool = factory.createPool(BUY_IN, MAX_PLAYERS, 0);

        // re-point the pool used by helpers
        pool = noFeePool;

        _settleWithWinner(host);

        uint256 before = usdc.balanceOf(host);
        vm.prank(host);
        pool.claim();
        assertEq(usdc.balanceOf(host) - before, 4 * BUY_IN); // winner gets all $40
    }

    // ─────────────────────── 6. Claiming the payout ────────────────────

    function test_ClaimBeforeSettledReverts() public {
        _fullLobby();
        vm.prank(host);
        vm.expectRevert("WagerPool: not settled");
        pool.claim();
    }

    function test_NonWinnerCannotClaim() public {
        _settleWithWinner(host);
        vm.prank(p2); // p2 is NOT the winner
        vm.expectRevert("WagerPool: not the winner");
        pool.claim();
    }

    function test_DoubleClaimReverts() public {
        _settleWithWinner(host);
        vm.prank(host);
        pool.claim();
        vm.prank(host);
        vm.expectRevert("WagerPool: already claimed");
        pool.claim();
    }

    // ───────────────── 7. Result proposed by the keeper ────────────────

    function test_ProposeResultOnlyKeeper() public {
        _fullLobby();
        vm.prank(p2);
        vm.expectRevert("WagerPool: not keeper");
        pool.proposeResult(p2);
    }

    function test_ProposeWinnerMustHaveJoined() public {
        _fullLobby();
        address stranger = makeAddr("stranger");
        vm.prank(keeper);
        vm.expectRevert("WagerPool: winner did not join");
        pool.proposeResult(stranger);
    }

    function test_ProposeOnlyWhenLocked() public {
        _join(host);
        _join(p2);
        // not started
        vm.prank(keeper);
        vm.expectRevert("WagerPool: not locked");
        pool.proposeResult(host);
    }

    // ───────────────── 8. Dispute — resolved by NEUTRAL resolver ───────

    function test_DisputeThenResolverFixesWinner() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);

        // p2 thinks the result is wrong → disputes
        vm.prank(p2);
        pool.dispute();
        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Disputed));

        // NEUTRAL resolver fixes the winner (NOT the host)
        vm.prank(resolver);
        pool.resolveDispute(p2);
        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Settled));
        assertEq(pool.winner(), p2);

        // corrected winner claims
        uint256 p2Before = usdc.balanceOf(p2);
        vm.prank(p2);
        pool.claim();
        assertEq(usdc.balanceOf(p2) - p2Before, 38 * 1e6); // +$38 exactly
    }

    function test_HostCannotResolveDispute() public {
        // THE security fix: the host (a player) can NOT judge a dispute.
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(p2);

        vm.prank(p2);
        pool.dispute();

        // host tries to steal by resolving himself as winner → REVERT
        vm.prank(host);
        vm.expectRevert("WagerPool: not resolver");
        pool.resolveDispute(host);
    }

    function test_ResolverCannotNameNonPlayer() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);
        vm.prank(p2);
        pool.dispute();

        address stranger = makeAddr("stranger");
        vm.prank(resolver);
        vm.expectRevert("WagerPool: winner did not join");
        pool.resolveDispute(stranger);
    }

    function test_DisputeOnlyByPlayer() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("WagerPool: not a player");
        pool.dispute();
    }

    function test_DisputeAfterWindowReverts() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(p2);
        vm.expectRevert("WagerPool: window over");
        pool.dispute();
    }

    // ─────────────────────── 9. Finalizing result ──────────────────────

    function test_FinalizeAfterWindow() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        pool.finalize();
        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Settled));
    }

    function test_FinalizeBeforeWindowReverts() public {
        _fullLobby();
        vm.prank(keeper);
        pool.proposeResult(host);
        vm.expectRevert("WagerPool: window not over");
        pool.finalize();
    }

    // ─────────────────── 10. Lobby cancel & timeout (edges #3) ─────────

    function test_HostRefundsEveryone() public {
        _join(host);
        _join(p2);
        _join(p3);

        vm.prank(host);
        pool.refund();

        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Refunded));
        assertEq(usdc.balanceOf(host), 1_000 * 1e6); // back to starting amount
        assertEq(usdc.balanceOf(p2), 1_000 * 1e6);
        assertEq(usdc.balanceOf(p3), 1_000 * 1e6);
        assertEq(pool.poolBalance(), 0);
    }

    function test_RefundOnlyHost() public {
        _join(host);
        _join(p2);
        vm.prank(p2);
        vm.expectRevert("WagerPool: not host");
        pool.refund();
    }

    function test_RefundAfterStartReverts() public {
        _fullLobby();
        vm.prank(host);
        vm.expectRevert("WagerPool: not refundable");
        pool.refund();
    }

    function test_AnyoneCanRefundAbandonedLobbyAfterTimeout() public {
        _join(host);
        _join(p2);
        vm.warp(block.timestamp + LOBBY_TIMEOUT + 1);

        // even a stranger can save everyone's money if the host vanished
        pool.refundAfterTimeout();

        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Refunded));
        assertEq(usdc.balanceOf(p2), 1_000 * 1e6);
        assertEq(pool.poolBalance(), 0);
    }

    function test_RefundTimeoutTooEarlyReverts() public {
        _join(host);
        _join(p2);
        vm.expectRevert("WagerPool: lobby timeout not reached");
        pool.refundAfterTimeout();
    }

    // ─────────────── 11. Emergency refund of a stuck match ─────────────

    function test_ResolverVoidsStuckMatch() public {
        _fullLobby(); // locked, but nobody ever proposes a result
        vm.warp(block.timestamp + MATCH_TIMEOUT + 1);

        vm.prank(resolver);
        pool.emergencyRefund();

        assertEq(uint8(pool.status()), uint8(WagerPool.Status.Refunded));
        assertEq(usdc.balanceOf(p2), 1_000 * 1e6);
        assertEq(pool.poolBalance(), 0);
    }

    function test_EmergencyRefundOnlyResolver() public {
        _fullLobby();
        vm.warp(block.timestamp + MATCH_TIMEOUT + 1);

        // host can't void a match to avoid paying the winner
        vm.prank(host);
        vm.expectRevert("WagerPool: not resolver");
        pool.emergencyRefund();
    }

    function test_EmergencyRefundTooEarlyReverts() public {
        _fullLobby();
        vm.prank(resolver);
        vm.expectRevert("WagerPool: match timeout not reached");
        pool.emergencyRefund();
    }

    function test_EmergencyRefundNotInOpen() public {
        _join(host);
        _join(p2);
        vm.warp(block.timestamp + MATCH_TIMEOUT + 1);
        vm.prank(resolver);
        vm.expectRevert("WagerPool: not stuck");
        pool.emergencyRefund();
    }

    // ─────────────────────── 12. Factory behaviour ─────────────────────

    function test_FactoryCreatesDistinctPools() public {
        WagerPool pool2 = factory.createPool(BUY_IN, MAX_PLAYERS, FEE_BPS);
        WagerPool pool3 = factory.createPool(BUY_IN, 3, FEE_BPS);

        assertEq(factory.poolCount(), 3);
        assertTrue(factory.isPool(address(pool)));
        assertTrue(factory.isPool(address(pool2)));
        assertTrue(factory.isPool(address(pool3)));
        assertTrue(address(pool) != address(pool2));
        assertEq(address(pool2.host()), address(this)); // caller becomes host
    }

    function test_FactoryRejectsZeroBuyIn() public {
        vm.expectRevert("Factory: zero buyIn");
        factory.createPool(0, MAX_PLAYERS, FEE_BPS);
    }

    function test_FactoryRejectsBadFee() public {
        vm.expectRevert("Factory: feeBps > 100%");
        factory.createPool(BUY_IN, MAX_PLAYERS, 10_001);
    }

    // ─────────────── 13. The full anti-theft guarantee ────────────────

    function test_HostHasNoMoneyPowerAfterStart() public {
        _fullLobby();
        uint256 balanceBefore = usdc.balanceOf(address(pool));

        // host tries EVERY money move after start → all revert
        vm.prank(host);
        vm.expectRevert("WagerPool: not open");
        pool.leave();

        vm.prank(host);
        vm.expectRevert("WagerPool: not open");
        pool.kickPlayer(p2);

        vm.prank(host);
        vm.expectRevert("WagerPool: not refundable");
        pool.refund();

        // pool untouched
        assertEq(usdc.balanceOf(address(pool)), balanceBefore);
    }
}
