// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";

/// @notice Pool with test-only entrypoints that move value between buckets.
contract PoolHarness is Pool {
    address internal constant SINK = address(0xdead);

    constructor(Params memory p) Pool(p) {}

    /// @dev Moves `amount` from `cash` to `backing` and sends the ETH out, as a mint does.
    function spendOnBacking(uint256 amount) external {
        cash -= amount;
        backing += amount;
        SafeTransferLib.safeTransferETH(SINK, amount);
    }

    /// @dev Moves `msg.value` from `backing` to `cash`, as a redemption does.
    function releaseBacking() external payable {
        backing -= msg.value;
        cash += msg.value;
    }

    /// @dev Credits `msg.value` to `cash`, as harvested proceeds do.
    function bookProceeds() external payable {
        cash += msg.value;
    }

    function pauseDeposits() external {
        depositsPaused = true;
    }

    function setLifecycle(Lifecycle state) external {
        lifecycle = state;
    }
}

abstract contract PoolFixture is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _params() internal returns (Pool.Params memory p) {
        p.shapes = makeAddr("shapes");
        p.drawPacks = makeAddr("drawPacks");
        p.fwaFactory = makeAddr("fwaFactory");
        p.admin = admin;
        p.mix = new PricingLib.MixRow[](2);
        p.mix[0].rungs = new uint8[](1);
        p.mix[0].rungs[0] = 2;
        p.mix[0].shareBps = 7_000;
        p.mix[1].rungs = new uint8[](2);
        p.mix[1].rungs[0] = 1;
        p.mix[1].rungs[1] = 2;
        p.mix[1].shareBps = 3_000;
        p.feeSplit = Pool.FeeSplit({premiumBps: 200, maintenanceBps: 100, feedBps: 400, minorShareBps: 4_000});
        p.minor = Pool.GrailParams({
            targetWei: 10 ether, stepWei: 0.1 ether, listBps: 10_000, decayWeiPerPull: 0.001 ether, floorWei: 0.5 ether
        });
        p.major = Pool.GrailParams({
            targetWei: 100 ether, stepWei: 1 ether, listBps: 9_000, decayWeiPerPull: 0.01 ether, floorWei: 5 ether
        });
        p.navCap = 1_000 ether;
        p.curve = Pool.EntryCurve({baseBps: 1_100, slopeBps: 2_000, capBps: 2_500, referenceWei: 55 ether});
        p.rotateInterval = 3_600;
        p.openingDeadline = 24 hours;
    }

    function _deploy(Pool.Params memory p) internal returns (PoolHarness) {
        return new PoolHarness(p);
    }
}

contract PoolConstructorTest is PoolFixture {
    function test_constructorStoresParams() public {
        PoolHarness pool = _deploy(_params());
        assertEq(pool.admin(), admin);
        assertEq(uint256(pool.lifecycle()), uint256(Pool.Lifecycle.Opening));
        assertEq(pool.mixLength(), 2);
        assertEq(pool.navCap(), 1_000 ether);
        assertEq(pool.rotateInterval(), 3_600);
        assertEq(pool.openingDeadline(), 24 hours);
        (,,,, uint256 target, uint256 step, uint256 listBps, uint256 decay, uint256 floor,) = pool.grail(1);
        assertEq(target, 100 ether);
        assertEq(step, 1 ether);
        assertEq(listBps, 9_000);
        assertEq(decay, 0.01 ether);
        assertEq(floor, 5 ether);
    }

    function test_revert_adminZero() public {
        Pool.Params memory p = _params();
        p.admin = address(0);
        vm.expectRevert(Pool.ZeroAddress.selector);
        new PoolHarness(p);
    }

    function test_revert_feeSplitTooHigh() public {
        Pool.Params memory p = _params();
        p.feeSplit.feedBps = 701;
        vm.expectRevert(Pool.FeeSplitTooHigh.selector);
        new PoolHarness(p);
    }

    function test_feeSplitAtBoundAccepted() public {
        Pool.Params memory p = _params();
        p.feeSplit.feedBps = 700;
        _deploy(p);
    }

    function test_revert_minorShareTooHigh() public {
        Pool.Params memory p = _params();
        p.feeSplit.minorShareBps = 10_001;
        vm.expectRevert(Pool.MinorShareTooHigh.selector);
        new PoolHarness(p);
    }

    function test_revert_capBpsTooHigh() public {
        Pool.Params memory p = _params();
        p.curve.capBps = 2_501;
        vm.expectRevert(Pool.CurveCapTooHigh.selector);
        new PoolHarness(p);
    }

    function test_revert_referenceZero() public {
        Pool.Params memory p = _params();
        p.curve.referenceWei = 0;
        vm.expectRevert(Pool.CurveReferenceZero.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsZeroMinor() public {
        Pool.Params memory p = _params();
        p.minor.listBps = 0;
        vm.expectRevert(Pool.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_listBpsTooHighMajor() public {
        Pool.Params memory p = _params();
        p.major.listBps = 10_001;
        vm.expectRevert(Pool.ListBpsOutOfRange.selector);
        new PoolHarness(p);
    }

    function test_revert_emptyMixRow() public {
        Pool.Params memory p = _params();
        p.mix[0].rungs = new uint8[](0);
        vm.expectRevert(PricingLib.EmptyRow.selector);
        new PoolHarness(p);
    }
}

contract PoolTest is PoolFixture {
    PoolHarness internal pool;

    function setUp() public {
        pool = _deploy(_params());
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(address(this), 1_000 ether);
    }

    function _deposit(address who, uint256 value) internal {
        vm.prank(who);
        pool.deposit{value: value}();
    }

    function _bucket(uint256 track) internal view returns (uint256 bucket) {
        (bucket,,,,,,,,,) = pool.grail(track);
    }

    function _claim(uint256 index) internal view returns (address to, uint256 requestedAt, uint256 amount) {
        return pool.claimQueue(index);
    }

    // ---------------------------------------------------------------- deposit

    function test_firstDepositIsOneToOneAfterContribution() public {
        _deposit(alice, 10 ether);
        assertEq(pool.sharesOf(alice), 8.9 ether);
        assertEq(pool.totalShares(), 8.9 ether);
        assertEq(pool.cash(), 8.9 ether);
        assertEq(pool.nav(), 8.9 ether);
        assertEq(address(pool).balance, 10 ether);
    }

    function test_secondDepositPricesAtNav() public {
        _deposit(alice, 10 ether);
        pool.bookProceeds{value: 8.9 ether}();
        assertEq(pool.nav(), 17.8 ether);

        uint256 curveBps = PricingLib.entryCurveBps(17.8 ether, 1_100, 2_000, 2_500, 55 ether);
        uint256 contribution = PricingLib.entryContribution(10 ether, curveBps);
        uint256 expected = PricingLib.sharesFor(10 ether - contribution, 17.8 ether, 8.9 ether);

        _deposit(bob, 10 ether);
        assertEq(pool.sharesOf(bob), expected);
        assertEq(pool.totalShares(), 8.9 ether + expected);
        assertEq(pool.cash(), 8.9 ether + 8.9 ether + 10 ether - contribution);
    }

    function test_contributionSplitsBetweenTracks() public {
        _deposit(alice, 10 ether);
        assertEq(_bucket(0), 0.44 ether);
        assertEq(_bucket(1), 0.66 ether);
        assertEq(_bucket(0) + _bucket(1), 1.1 ether);
    }

    function test_emitsDeposited() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit Pool.Deposited(alice, 10 ether, 1.1 ether, 8.9 ether);
        _deposit(alice, 10 ether);
    }

    function test_revert_navCap() public {
        Pool.Params memory p = _params();
        p.navCap = 5 ether;
        pool = _deploy(p);
        _deposit(alice, 10 ether);
        vm.expectRevert(Pool.NavCapReached.selector);
        _deposit(bob, 1 ether);
    }

    function test_revert_depositsPaused() public {
        pool.pauseDeposits();
        vm.expectRevert(Pool.DepositsPaused.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_exiting() public {
        pool.setLifecycle(Pool.Lifecycle.Exiting);
        vm.expectRevert(Pool.PoolExiting.selector);
        _deposit(alice, 1 ether);
        pool.setLifecycle(Pool.Lifecycle.Exported);
        vm.expectRevert(Pool.PoolExiting.selector);
        _deposit(alice, 1 ether);
    }

    function test_revert_zeroValue() public {
        vm.expectRevert(Pool.ZeroAmount.selector);
        _deposit(alice, 0);
    }

    // ---------------------------------------------------------------- withdraw

    function test_withdrawPaysInFullFromCash() public {
        _deposit(alice, 10 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        assertEq(alice.balance - before, 8.9 ether);
        assertEq(pool.sharesOf(alice), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.cash(), 0);
        assertEq(pool.claims(), 0);
    }

    function test_revert_withdrawZero() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Pool.ZeroAmount.selector);
        pool.withdraw(0);
    }

    function test_revert_withdrawMoreThanBalance() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(Pool.InsufficientShares.selector);
        pool.withdraw(8.9 ether + 1);
    }

    function test_withdrawWithCashShortEnqueuesRemainder() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(5 ether);
        assertEq(pool.cash(), 3.9 ether);
        assertEq(pool.nav(), 8.9 ether);

        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(pool));
        emit Pool.Withdrawn(alice, 4.45 ether, 3.9 ether, 0.55 ether);
        vm.prank(alice);
        pool.withdraw(4.45 ether);

        assertEq(alice.balance - before, 3.9 ether);
        assertEq(pool.cash(), 0);
        assertEq(pool.claims(), 0.55 ether);
        assertEq(pool.nav(), 4.45 ether);
        (address to, uint256 requestedAt, uint256 amount) = _claim(0);
        assertEq(to, alice);
        assertEq(requestedAt, block.timestamp);
        assertEq(amount, 0.55 ether);
    }

    // ---------------------------------------------------------------- liquidate

    function test_liquidateNoopWhenQueueEmpty() public {
        pool.liquidate();
        assertEq(pool.claimHead(), 0);
    }

    function test_revert_liquidateBeforeInterval() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(8.9 ether);
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        pool.bookProceeds{value: 1 ether}();

        vm.warp(block.timestamp + 3_599);
        vm.expectRevert(Pool.ClaimNotDue.selector);
        pool.liquidate();
        vm.warp(block.timestamp + 1);
        pool.liquidate();
        assertEq(alice.balance, 1_000 ether - 10 ether + 1 ether);
    }

    function test_liquidatePaysHeadPartially() public {
        _deposit(alice, 10 ether);
        pool.spendOnBacking(8.9 ether);
        vm.prank(alice);
        pool.withdraw(8.9 ether);
        assertEq(pool.claims(), 8.9 ether);
        assertEq(pool.nav(), 0);

        pool.bookProceeds{value: 3 ether}();
        vm.warp(block.timestamp + 3_600);
        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(pool));
        emit Pool.ClaimPaid(alice, 3 ether);
        pool.liquidate();

        assertEq(alice.balance - before, 3 ether);
        assertEq(pool.claimHead(), 0);
        (,, uint256 amount) = _claim(0);
        assertEq(amount, 5.9 ether);
        assertEq(pool.claims(), 5.9 ether);
        assertEq(pool.cash(), 0);
    }

    function test_twoClaimsPaidInOrderAcrossLiquidations() public {
        _deposit(alice, 10 ether);
        _deposit(bob, 10 ether);
        pool.spendOnBacking(pool.cash());
        assertEq(pool.cash(), 0);

        uint256 aliceShares = pool.sharesOf(alice);
        uint256 bobShares = pool.sharesOf(bob);
        vm.prank(alice);
        pool.withdraw(aliceShares);
        vm.prank(bob);
        pool.withdraw(bobShares);
        (,, uint256 claimA) = _claim(0);
        (,, uint256 claimB) = _claim(1);
        assertEq(pool.claims(), claimA + claimB);
        assertEq(pool.nav(), 0);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vm.warp(block.timestamp + 3_600);

        pool.bookProceeds{value: claimA / 2}();
        pool.liquidate();
        assertEq(alice.balance - aliceBefore, claimA / 2);
        assertEq(bob.balance, bobBefore);
        assertEq(pool.claimHead(), 0);

        pool.bookProceeds{value: claimA - claimA / 2 + 1 ether}();
        pool.liquidate();
        assertEq(alice.balance - aliceBefore, claimA);
        assertEq(bob.balance - bobBefore, 1 ether);
        assertEq(pool.claimHead(), 1);
        (,, uint256 headAmount) = _claim(1);
        assertEq(headAmount, claimB - 1 ether);
        assertEq(pool.claims(), claimB - 1 ether);

        pool.bookProceeds{value: claimB}();
        pool.liquidate();
        assertEq(bob.balance - bobBefore, claimB);
        assertEq(pool.claimHead(), 2);
        assertEq(pool.claims(), 0);
        assertEq(pool.cash(), 1 ether);
    }

    function test_liquidateBoundedByItemLimit() public {
        _deposit(alice, 100 ether);
        pool.spendOnBacking(pool.cash());
        uint256 shares = pool.sharesOf(alice);
        for (uint256 i; i < 25; ++i) {
            vm.prank(alice);
            pool.withdraw(shares / 25);
        }
        pool.bookProceeds{value: 100 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.liquidate();
        assertEq(pool.claimHead(), 20);
        pool.liquidate();
        assertEq(pool.claimHead(), 25);
    }

    function test_rejectingRecipientDoesNotStallQueue() public {
        RejectEther rejecter = new RejectEther();
        vm.deal(address(rejecter), 10 ether);
        rejecter.deposit(pool, 10 ether);
        pool.spendOnBacking(pool.cash());
        rejecter.withdrawAll(pool);
        pool.bookProceeds{value: 20 ether}();
        vm.warp(block.timestamp + 3_600);
        pool.liquidate();
        assertEq(pool.claimHead(), 1);
        assertEq(pool.claims(), 0);
        assertEq(address(rejecter).balance, 8.9 ether);
    }
}

contract RejectEther {
    function deposit(Pool pool, uint256 value) external {
        pool.deposit{value: value}();
    }

    function withdrawAll(Pool pool) external {
        pool.withdraw(pool.sharesOf(address(this)));
    }

    receive() external payable {
        revert();
    }
}
