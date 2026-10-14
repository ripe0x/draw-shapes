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
///      after `sizeBoard(60)` and 70 + 30 items after `sizeBoard(100)`. Both GRAIL steps are
///      500 ETH, so no track grows unless a test sets a smaller step. `rotateInterval` is 900. The
///      factory's `inventoryChangeCooldown` is 300 on the fork, so `settle` does not list and the
///      Held trigger does.
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
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _open(uint256 pulls) internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        if (pulls != 0) pool.sizeBoard(pulls);
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

    /// @dev One pooled acquisition fulfilled on the last listed item of `row`, then settled.
    function _pooledCapture(uint256 row) internal {
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        uint256[] memory listed = pool.listedIds(row);
        _capture(ids[0], listed[listed.length - 1]);
        vm.prank(keeper);
        pool.settle(20);
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

    function test_revert_rotateNotDueWhenNoTriggerHolds() public {
        _openReady();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();

        vm.warp(block.timestamp + 365 days);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_revert_rotateTooSoonInsideTheSpacingEvenWithATriggerTrue() public {
        _openReady();
        _pooledCapture(1);
        assertEq(pool.replacementLength(), 1);
        vm.warp(pool.lastRotateAt() + pool.rotateInterval() - 1);
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Held);
        vm.prank(keeper);
        pool.rotate();
    }

    // ---------------------------------------------------------------- one case per trigger

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

    function _enableMajor() internal {
        vm.prank(admin);
        IPool(address(pool)).setGrail(1, 1 ether, 0.15 ether, 9_000, 0.002 ether, 0.01 ether);
    }

    /// @dev `rotate` as the keeper. Returns `Rotated.inventoryChanged`.
    function _rotateInventoryChanged() internal returns (bool inventoryChanged) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Rotated.selector) {
                (, inventoryChanged,) = abi.decode(logs[i].data, (bool, bool, uint256));
                seen = true;
            }
        }
        assertTrue(seen, "Rotated emitted");
    }

    /// @dev Keeper regression: whenever `rotateDue` returns GrailStep, `rotate` changes inventory.
    function test_grailStepDueMeansRotateChangesInventoryWhileBusyAndUnlisted() public {
        _openReady();
        _enableMinor();
        _acquire(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        assertTrue(_rotateInventoryChanged(), "GrailStep due, inventory changed");
        assertGt(_listingOf(0), 0, "the unlisted track grew and listed while busy");
    }

    function test_grailStepIsNotDueWhileBusyForAListedTrack() public {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        warpPastCooldown(clone);
        _acquire(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);
        assertGt(_bucketOf(0), 0.1 ether, "the bucket still covers a step");
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_grailStepDueForTheUnlistedTrackWhileTheListedTrackWaits() public {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        _enableMajor();
        warpPastCooldown(clone);
        _acquire(player, 1);
        uint256 minorListing = _listingOf(0);
        uint256 minorBacking = _backingOf(0);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        assertTrue(_rotateInventoryChanged(), "GrailStep due, inventory changed");
        assertEq(_backingOf(0), minorBacking, "the listed track waits");
        assertEq(_listingOf(0), minorListing, "the listing is untouched");
        assertEq(_backingOf(1), 0.15 ether, "the unlisted track grew");
        assertGt(_listingOf(1), 0);
    }

    function _listingOf(uint256 t) internal view returns (uint256 v) {
        (,,,,,,,,,,, v) = IPool(address(pool)).grail(t);
    }

    function _backingOf(uint256 t) internal view returns (uint256 v) {
        (,, v,,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    /// @dev Grows the minor track to a 0.04 ETH listing, empties both buckets so no GrailStep is due
    ///      and queues one replacement so that `settleDue` is `Thin`.
    function _decayedTrackWithDueSettle() internal {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        pool.loseGrailBucket(0, _bucketOf(0));
        pool.loseGrailBucket(1, _bucketOf(1));
        pool.pushReplacement(1);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
    }

    function _notionalOf(uint256 t) internal view returns (uint256 notional) {
        (,,, notional,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    /// @dev `GrailListed` events (list or reprice of a track) of the last `_settleAs` call.
    uint256 internal grailListedInSettle;
    /// @dev Items listed by the last `_settleAs` call.
    uint256 internal listedInSettle;

    function _settleAs(address who) internal returns (uint256 refund) {
        vm.recordLogs();
        vm.prank(who);
        pool.settle(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        grailListedInSettle = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            if (logs[i].topics[0] == IPoolTypes.GrailListed.selector) ++grailListedInSettle;
            if (logs[i].topics[0] == IPoolTypes.Settled.selector) {
                (listedInSettle, refund) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function test_decayIsNotARotateTrigger() public {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        pool.loseGrailBucket(0, _bucketOf(0));
        pool.loseGrailBucket(1, _bucketOf(1));
        pool.recordPulls(100);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_aDueSettleRepricesAListedTrackAndPaysTheRefund() public {
        _setCooldown(0);
        _decayedTrackWithDueSettle();
        pool.recordPulls(1);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Thin));
        assertEq(_notionalOf(0), 0.04 ether);

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(0), 0.039 ether, "one pull at 0.001 ETH");
        assertGt(refund, 0, "a due settle that repriced pays the refund");
        assertEq(keeper.balance, refund);
        (,,,,,,,,, uint256 pulls,,) = IPool(address(pool)).grail(0);
        assertEq(pulls, 0, "the reprice restarts the pull count");
    }

    function test_aSettleThatIsNotDueDoesNotReprice() public {
        _openReady();
        _enableMinor();
        pool.growTrack(0);
        pool.loseGrailBucket(0, _bucketOf(0));
        pool.loseGrailBucket(1, _bucketOf(1));
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        pool.recordPulls(1);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None), "nothing queued, nothing held");

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(0), 0.04 ether, "the reprice rides on a due settle");
        assertEq(refund, 0);
        (,,,,,,,,, uint256 pulls,,) = IPool(address(pool)).grail(0);
        assertEq(pulls, 1);
    }

    function test_rotateLeavesTheListPriceAlone() public {
        _openReady();
        assertEq(factory.inventoryChangeCooldown(), 300, "settle may not list, so the Held rotation does");
        _enableMinor();
        pool.growTrack(0);
        pool.loseGrailBucket(0, _bucketOf(0));
        pool.loseGrailBucket(1, _bucketOf(1));
        _pooledCapture(1);
        pool.recordPulls(5);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.Held);
        uint256 before_ = _notionalOf(0);
        (,,,,,,,,, uint256 pullsBefore,,) = IPool(address(pool)).grail(0);
        assertEq(pullsBefore, 6, "one booked capture and five recorded pulls");

        vm.prank(keeper);
        pool.rotate();

        assertEq(_notionalOf(0), before_, "rotate lists the queue and does not reprice");
        (,,,,,,,,, uint256 pulls,,) = IPool(address(pool)).grail(0);
        assertEq(pulls, pullsBefore, "the pull count is unchanged");
    }

    function test_aDueSettleDoesNotRepriceUnderANonzeroCooldown() public {
        _decayedTrackWithDueSettle();
        pool.recordPulls(1);
        assertEq(factory.inventoryChangeCooldown(), 300);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Thin));

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(0), 0.04 ether, "no FWA inventory call while the cooldown is nonzero");
        assertEq(grailListedInSettle, 0);
        assertEq(listedInSettle, 0);
        assertEq(refund, 0);
        (,,,,,,,,, uint256 pulls,,) = IPool(address(pool)).grail(0);
        assertEq(pulls, 1, "the pull count keeps running");
    }

    function test_listWhilePausedLetsADueSettleRepriceUnderACooldown() public {
        _decayedTrackWithDueSettle();
        vm.prank(admin);
        IPool(address(pool)).setListWhilePaused(true);
        pool.recordPulls(1);
        assertEq(factory.inventoryChangeCooldown(), 300);

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(0), 0.039 ether);
        assertEq(grailListedInSettle, 1);
        assertGt(refund, 0);
    }

    function test_aDueSettleStopsAtTheFloor() public {
        _setCooldown(0);
        _decayedTrackWithDueSettle();
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);
        pool.recordPulls(100_000);

        _settleAs(keeper);

        (,,, uint256 notional,,,,, uint256 floorWei,,,) = IPool(address(pool)).grail(0);
        assertEq(notional, floorWei);
        assertEq(grailListedInSettle, 1, "the first settle repriced the track to the floor");
        pool.recordPulls(1);
        pool.pushReplacement(1);
        uint256 refund = _settleAs(keeper);
        assertEq(grailListedInSettle, 0, "at the floor a due settle has nothing to reprice");
        assertEq(_notionalOf(0), floorWei);
        assertEq(listedInSettle, 1, "the settle listed the queued replacement");
        assertGt(refund, 0, "the refund covers the listing");
    }

    function test_aDueSettleLiftsThePriceWhenTheProbabilityCapIsExceeded() public {
        _setCooldown(0);
        _decayedTrackWithDueSettle();
        pool.recordPulls(1);
        _settleAs(keeper);
        uint256 decayed = _notionalOf(0);
        assertEq(decayed, 0.039 ether, "one pull at 0.001 ETH");

        // The settle lists the queued replacement before it reprices, which adds FWA weight. A dry
        // run reads the weight outside the track after that listing and is then reverted.
        pool.recordPulls(1);
        pool.pushReplacement(1);
        uint256 snapshot = vm.snapshotState();
        _settleAs(keeper);
        uint256 restWeight = clone.totalWeight() - 1e36 / _notionalOf(0);
        vm.revertToState(snapshot);
        assertEq(_notionalOf(0), decayed, "dry run reverted");

        // A cap that the full price of 0.04 ETH meets and 0.039 ETH exceeds asks for a lift.
        uint256 fullWeight = 1e36 / 0.04 ether;
        uint256 capBps = fullWeight * 10_000 / (restWeight + fullWeight) + 1;
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(capBps);
        _settleAs(keeper);

        uint256 lifted = _notionalOf(0);
        assertGt(lifted, decayed, "the price rose");
        assertLe(lifted, 0.04 ether);
    }

    function test_heldTriggerFiresForAQueuedReplacementWhileTheFactoryCooldownIsNonzero() public {
        _openReady();
        assertGt(factory.inventoryChangeCooldown(), 0);
        _pooledCapture(1);
        assertEq(pool.replacementLength(), 1);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.Held);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Thin));
    }

    function test_heldTriggerIsNoneWhenTheFactoryCooldownIsZero() public {
        _openReady();
        _setCooldown(0);
        _pooledCapture(1);
        assertEq(pool.replacementLength(), 0, "settle listed the replacement");
        assertEq(pool.listedCount(), 10);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None));
    }

    function test_heldTriggerFiresWhenListWhilePausedIsOffAndAHeldItemExists() public {
        _openReady();
        _setCooldown(0);
        vm.prank(admin);
        IPool(address(pool)).setListWhilePaused(false);
        pool.addItem(SHAPES_ADDR, 0, mintShapes(address(pool), 0.1 ether, 1), 0.1 ether, 0);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        _setCooldown(300);
        _assertDue(IPoolTypes.RotateTrigger.Held);
    }

    function test_heldTriggerNeedsCashForTheQueueHead() public {
        _openReady();
        _pooledCapture(0);
        pool.loseCash(pool.cash());
        assertEq(pool.replacementLength(), 1);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
    }

    function test_triggersAreReportedInOrder() public {
        _openReady();
        _enableMinor();
        _pooledCapture(1);
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Claim);
        // Paying the claim from cash leaves the next trigger.
        pool.bookProceeds{value: 1_000 ether}();
        pool.payClaims();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 1_000 ether, 500 ether, 8_000, 0.001 ether, 0.01 ether);
        _assertDue(IPoolTypes.RotateTrigger.Held);
    }

    // ---------------------------------------------------------------- the Held rotation

    function test_heldRotationListsTheQueueAndPaysTheRefund() public {
        _openReady();
        _pooledCapture(1);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.Held);
        uint256 maintenanceBefore = pool.maintenance();

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        (bool rotated, uint256 refund) = _summarize(vm.getRecordedLogs());

        assertTrue(rotated);
        assertEq(pool.replacementLength(), 0);
        assertEq(pool.listedCount(), 10);
        assertGt(refund, 0);
        assertEq(keeper.balance, refund);
        assertEq(maintenanceBefore - pool.maintenance(), refund);
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
        (bucket,,,,,,,,,,,) = IPool(address(pool)).grail(t);
    }

    /// @dev Sets the factory's `inventoryChangeCooldown`, as the factory owner does.
    function _setCooldown(uint32 seconds_) internal {
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(seconds_);
    }
}
