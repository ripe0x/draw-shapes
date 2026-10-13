// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice The `rotate` triggers and `rotateDue` against deployed Shapes, a Draw Packs deployment
///         and a FWA clone created by the pool.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). A 100 ETH deposit builds a board of 7 + 3 items, 42 + 18 items
///      after `recordPulls(60)` and 70 + 30 items after `recordPulls(100)`. Both GRAIL steps are
///      500 ETH, so no track grows unless a test sets a smaller step. `rotateInterval` is 900 and
///      `quietIntervalSeconds` 12 hours.
contract PoolTriggersForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal saver = makeAddr("saver");
    address internal exiter = makeAddr("exiter");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        vm.deal(alice, 10_000 ether);

        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.rotateInterval = 900;
        p.minor.stepWei = 500 ether;
        p.minor.targetWei = 1_000 ether;
        p.major.stepWei = 500 ether;
        p.major.targetWei = 1_000 ether;
        pool = new PoolHarness(p);
        vm.prank(admin);
        pool.createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _open(uint256 pulls) internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(pool.openingDeadlineAt());
        if (pulls != 0) pool.recordPulls(pulls);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        warpPastCooldown(clone);
    }

    function _openReady() internal {
        _open(0);
        assertEq(pool.listedCount(), 10);
    }

    function _warpToSpacing() internal {
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
    }

    function _warpToQuiet() internal {
        vm.warp(pool.lastRotateAt() + pool.quietIntervalSeconds());
    }

    function _due() internal view returns (IPoolTypes.RotateTrigger) {
        return pool.rotateDue();
    }

    function _assertDue(IPoolTypes.RotateTrigger expected) internal view {
        assertEq(uint8(_due()), uint8(expected));
    }

    function _acquire(address who, uint256 count) internal returns (uint256[] memory ids) {
        return acquirePooled(address(pool), clone, who, count);
    }

    function _listingOfRow(uint256 row, uint256 nth) internal view returns (uint256) {
        uint256 next = clone.nextListingId();
        uint256 seen;
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            if (it.value != 0 && it.row == row) {
                if (seen == nth) return id;
                ++seen;
            }
        }
        revert("no such listing");
    }

    function _capture(uint256 requestId, uint256 listingId) internal {
        fulfill(clone, requestId, wordFor(clone, listingId));
        (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Fulfilled), "request not fulfilled");
    }

    /// @dev A direct FWA purchase fulfilled on `listingId`. The pool does not book it.
    function _captureDirect(uint256 listingId) internal {
        warpPastCooldown(clone);
        uint256 requestId = acquireAs(alice, alice, clone, block.timestamp + 1 hours);
        _capture(requestId, listingId);
    }

    function _gateOff() internal {
        vm.prank(admin);
        IPool(address(pool)).setPurchaseGate(false);
    }

    /// @dev Deposits `depositWei` as `exiter` and removes ordinary cash down to `cashLeft`.
    function _drainCash(uint256 depositWei, uint256 cashLeft) internal {
        vm.deal(exiter, depositWei);
        vm.prank(exiter);
        pool.deposit{value: depositWei}();
        pool.loseCash(pool.cash() - cashLeft);
    }

    /// @dev `exiter` withdraws every share. Returns the amount queued.
    function _exiterLeaves() internal returns (uint256 queued) {
        uint256 shares = pool.sharesOf(exiter);
        vm.prank(exiter);
        pool.withdraw(shares);
        queued = pool.claims();
        assertGt(queued, 0, "claim queued");
    }

    function _summarize(Vm.Log[] memory logs) internal view returns (bool rotated, uint256 refund) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Rotated.selector) {
                (,, refund) = abi.decode(logs[i].data, (bool, bool, uint256));
                rotated = true;
            }
        }
    }

    function _enableMinor() internal {
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 0.5 ether, 0.05 ether, 8_000, 0.001 ether, 0.01 ether);
    }

    // ---------------------------------------------------------------- spacing and the none state

    function test_rotateDueIsNoneBeforeTheOpen() public view {
        _assertDue(IPoolTypes.RotateTrigger.None);
    }

    function test_snapshotIsTheOrdinaryWeightAtOpen() public {
        _openReady();
        assertEq(pool.ordinaryWeightSnapshot(), clone.totalWeight());
        assertGt(pool.ordinaryWeightSnapshot(), 0);
    }

    function test_revert_rotateNotDueWhenNoTriggerHoldsBeforeTheQuietFloor() public {
        _openReady();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();

        vm.warp(pool.lastRotateAt() + pool.quietIntervalSeconds() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_revert_rotateTooSoonInsideTheSpacingEvenWithATriggerTrue() public {
        _openReady();
        _gateOff();
        _captureDirect(_listingOfRow(1, 0));
        _captureDirect(_listingOfRow(1, 1));
        vm.warp(pool.lastRotateAt() + pool.rotateInterval() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Weight);
        vm.prank(keeper);
        pool.rotate();
    }

    // ---------------------------------------------------------------- one case per trigger

    function test_weightTriggerFiresOnceEnoughOrdinaryWeightIsMissing() public {
        _openReady();
        _gateOff();
        _captureDirect(_listingOfRow(1, 0));
        _warpToSpacing();
        // One pack is about 22 percent of the 7 + 3 board's weight.
        _assertDue(IPoolTypes.RotateTrigger.Weight);
    }

    function test_grailCapTriggerFiresWhenListedGrailWeightExceedsTheCap() public {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        pool.loseGrailBucket(0, _bucketOf(0));
        pool.loseGrailBucket(1, _bucketOf(1));
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);

        (,,, uint256 notional,,,,,,,,) = pool.grail(0);
        uint256 shareBps = (1e36 / notional) * 10_000 / clone.totalWeight();
        assertGt(shareBps, 1);
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(shareBps - 1);
        _assertDue(IPoolTypes.RotateTrigger.GrailCap);
    }

    function test_claimTriggerFiresOnceTheHeadClaimIsOldEnough() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Claim);
    }

    function test_claimTriggerWaitsForTheClaimToAge() public {
        _openReady();
        _warpToSpacing();
        // The spacing is long past when the claim is queued; the claim itself is new.
        pool.setLastRotateAt(block.timestamp - 2 * pool.rotateInterval());
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.warp(block.timestamp + 1);
        _assertDue(IPoolTypes.RotateTrigger.Claim);
    }

    function test_grailStepTriggerFiresWhenABucketCoversAStep() public {
        _openReady();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        _enableMinor();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
    }

    function test_restockTriggerFiresWhenARowIsBelowItsTargetDepth() public {
        _openReady();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.prank(admin);
        IPool(address(pool)).setMinItems(20);
        _assertDue(IPoolTypes.RotateTrigger.Restock);

        // Cash that does not cover the row and the reserve leaves the row unfilled.
        pool.loseCash(pool.cash());
        _assertDue(IPoolTypes.RotateTrigger.None);
    }

    function test_restockTriggerFiresWhenAHeldItemExists() public {
        _open(60);
        assertEq(pool.listedCount(), 60);
        uint256[] memory ids = _acquire(player, 1);
        uint256[] memory listed = pool.listedIds(0);
        fulfill(clone, ids[0], wordFor(clone, listed[listed.length - 1]));
        pool.settle(20);
        warpPastCooldown(clone);
        _acquire(player, 1);
        assertEq(pool.heldCount(), 1, "the second pull mints the replacement and holds it");
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.Restock);
    }

    function test_quietTriggerFiresAfterTheQuietIntervalWithNothingElseDue() public {
        _openReady();
        vm.warp(pool.lastRotateAt() + pool.quietIntervalSeconds() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.warp(block.timestamp + 1);
        _assertDue(IPoolTypes.RotateTrigger.Quiet);
        assertEq(pool.quietIntervalSeconds(), 12 hours);
    }

    function test_triggersAreReportedInOrder() public {
        _openReady();
        _gateOff();
        _captureDirect(_listingOfRow(1, 0));
        _enableMinor();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        _warpToQuiet();
        _assertDue(IPoolTypes.RotateTrigger.Weight);
    }

    // ---------------------------------------------------------------- selection odds drift

    function test_weightTriggerRelistsBeforeAnHourWhenAboutTenPercentOfWeightIsCaptured() public {
        _open(100);
        assertEq(pool.listedCount(), 100, "100 item board");
        uint256 snapshotBefore = pool.ordinaryWeightSnapshot();
        uint256 openedAt = pool.lastRotateAt();
        _gateOff();

        // Each pack is about 2.3 percent of the board's weight. Four packs are about 9 percent.
        for (uint256 i; i < 4; ++i) {
            _captureDirect(_listingOfRow(1, i));
        }
        _warpToSpacing();
        assertLt(clone.totalWeight(), snapshotBefore);
        assertLt(snapshotBefore - clone.totalWeight(), snapshotBefore / 10);
        _assertDue(IPoolTypes.RotateTrigger.None);

        _captureDirect(_listingOfRow(1, 4));
        _warpToSpacing();
        assertGe(snapshotBefore - clone.totalWeight(), snapshotBefore / 10);
        _assertDue(IPoolTypes.RotateTrigger.Weight);
        assertLt(block.timestamp - openedAt, 1 hours, "due inside the hour");

        vm.prank(keeper);
        pool.rotate();

        // The five booked purchases raise the trailing pulls to 105, which deepens the target board.
        assertGe(pool.listedCount(), 100, "the board was restored and relisted");
        assertEq(pool.heldCount(), 0);
        assertEq(pool.ordinaryWeightSnapshot(), clone.totalWeight(), "snapshot follows the relist");
        assertGe(pool.ordinaryWeightSnapshot(), snapshotBefore, "the relist restored the weight");
        assertEq(pool.lastRotateAt(), block.timestamp);
        _assertDue(IPoolTypes.RotateTrigger.None);
    }

    // ---------------------------------------------------------------- claims on a quiet pool

    function test_quietPoolPaysAWithdrawalAboveCashThroughRotateAndRefunds() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256 balanceBefore = exiter.balance;
        uint256 queued = _exiterLeaves();
        uint256 paidNow = exiter.balance - balanceBefore;
        assertEq(paidNow, 0.3 ether);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);

        vm.warp(block.timestamp + pool.rotateInterval() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();

        vm.warp(block.timestamp + 1);
        _assertDue(IPoolTypes.RotateTrigger.Claim);
        assertEq(clone.unsettledAcquisitionCount(), 0, "no purchases");
        uint256 maintenanceBefore = pool.maintenance();

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        (bool rotated, uint256 refund) = _summarize(vm.getRecordedLogs());

        assertTrue(rotated);
        assertEq(pool.claims(), 0, "claim cleared");
        assertGt(exiter.balance - balanceBefore, paidNow, "claimant received the remainder");
        assertLe(exiter.balance - balanceBefore, queued + paidNow);
        assertGt(refund, 0, "inventory changed, so the refund is paid");
        assertEq(keeper.balance, refund);
        assertEq(maintenanceBefore - pool.maintenance(), refund, "the refund came from maintenance");
        assertEq(pool.lastRotateAt(), block.timestamp);
    }

    // ---------------------------------------------------------------- no-op rotations

    function test_rotateAttemptWithoutATriggerRevertsAndLeavesTheFwaPauseAlone() public {
        _openReady();
        _warpToSpacing();
        uint256 lastBefore = pool.lastRotateAt();
        uint256 resumeBefore = clone.purchasesResumeAt();

        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        vm.prank(keeper);
        pool.rotate();

        assertEq(pool.lastRotateAt(), lastBefore);
        assertEq(clone.purchasesResumeAt(), resumeBefore, "no inventory call reached FWA");
    }

    function test_quietRotateThatChangesNothingLeavesTheSpacingAndThePauseAlone() public {
        _openReady();
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToQuiet();
        _assertDue(IPoolTypes.RotateTrigger.Quiet);
        uint256 lastBefore = pool.lastRotateAt();
        uint256 resumeBefore = clone.purchasesResumeAt();
        uint256 snapshotBefore = pool.ordinaryWeightSnapshot();

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        (bool rotated, uint256 refund) = _summarize(vm.getRecordedLogs());

        assertTrue(rotated);
        assertEq(refund, 0, "nothing changed, nothing paid");
        assertEq(keeper.balance, 0);
        assertEq(pool.maintenance(), 1 ether);
        assertEq(pool.lastRotateAt(), lastBefore, "the spacing keeps running");
        assertEq(pool.ordinaryWeightSnapshot(), snapshotBefore);
        assertEq(clone.purchasesResumeAt(), resumeBefore, "the FWA pause did not restart");
        _assertDue(IPoolTypes.RotateTrigger.Quiet);
    }

    function test_claimTriggerWithFwaBusyChangesNothing() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _acquire(player, 1);
        uint256 queued = _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Claim);
        uint256 lastBefore = pool.lastRotateAt();
        uint256 resumeBefore = clone.purchasesResumeAt();
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        (, uint256 refund) = _summarize(vm.getRecordedLogs());

        assertEq(refund, 0);
        assertEq(pool.claims(), queued, "listed items are locked while an acquisition is unsettled");
        assertEq(pool.listedCount(), 10);
        assertEq(pool.lastRotateAt(), lastBefore);
        assertEq(clone.purchasesResumeAt(), resumeBefore);
    }

    function _bucketOf(uint256 t) internal view returns (uint256 bucket) {
        (bucket,,,,,,,,,,,) = pool.grail(t);
    }
}
