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
///      after `sizeBoard(60)` and 70 + 30 items after `sizeBoard(100)`. `_open` empties the GRAIL
///      fund, so no GRAIL step is due unless a test funds it. The opening five (5 ETH, listed at
///      face) is GRAIL item 0. `rotateInterval` is 900. The
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
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _open(uint256 pulls) internal {
        if (pulls != 0) pool.sizeBoard(pulls);
        vm.prank(alice);
        pool.deposit{value: _openingDeposit(address(pool))}();
        _topUpGrailFund(pool);
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        pool.loseGrailFund(_fundOf());
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

    /// @dev Clears the purchase operator of the FWA pool from the pool (its owner), the state `adminCall` can produce, so a wallet
    ///      can acquire from the FWA pool directly and the walk books unrecorded captures.
    function _gateOff() internal {
        vm.prank(address(pool));
        clone.setPurchaseOperator(address(0));
    }

    /// @dev Deposits `depositWei` as `exiter` and removes ordinary cash down to `cashLeft`.
    function _drainCash(uint256 depositWei, uint256 cashLeft) internal {
        vm.deal(exiter, depositWei);
        vm.prank(exiter);
        pool.deposit{value: depositWei}();
        pool.loseCash(pool.cash() - cashLeft);
        pool.loseGrailFund(IPool(address(pool)).grail().fund);
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

    /// @dev Funds the GRAIL with enough for three pieces.
    function _fundGrail() internal {
        pool.addGrailFund{value: 5 ether}();
    }

    function _pullsSinceList() internal view returns (uint256) {
        return IPool(address(pool)).grail().pulls - _item().listedAtPull;
    }

    function _item() internal view returns (IPoolTypes.GrailItem memory) {
        return IPool(address(pool)).grailItems()[0];
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

    function test_grailStepTriggerFiresWhenTheFundCoversAPiece() public {
        _openReady();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        pool.addGrailFund{value: 1 ether}();
        _assertDue(IPoolTypes.RotateTrigger.None);
        pool.addGrailFund{value: shapes.mintFee()}();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
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
    function test_grailStepDueMeansRotateChangesInventory() public {
        _openReady();
        _fundGrail();
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        assertTrue(_rotateInventoryChanged(), "GrailStep due, inventory changed");
        assertEq(IPool(address(pool)).grailItems().length, 4, "three pieces joined the opening five");
    }

    function test_grailStepIsNotDueWhileBusy() public {
        _openReady();
        _fundGrail();
        _acquire(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_grailStepDueForAnUnlistedItemAndRelistsIt() public {
        _openReady();
        pool.unlistGrail(0);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        assertTrue(_rotateInventoryChanged(), "GrailStep due, inventory changed");
        assertGt(_item().listingId, 0, "listed again");
        assertEq(_item().notional, 5 ether);
    }

    /// @dev The opening five is listed at 5 ETH, the fund is empty and one replacement is queued, so
    ///      that `settleDue` is `Thin`.
    function _decayedItemWithDueSettle() internal {
        _openReady();
        _spareCash(pool, 0.2 ether);
        pool.pushReplacement(1);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
    }

    function _notionalOf() internal view returns (uint256) {
        return _item().notional;
    }

    /// @dev `GrailListed` events (list or reprice of a GRAIL item) of the last `_settleAs` call.
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
        pool.recordPulls(100);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.None);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_aDueSettleRepricesAListedItemAndPaysTheRefund() public {
        _setCooldown(0);
        _decayedItemWithDueSettle();
        pool.recordPulls(100);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Thin));
        assertEq(_notionalOf(), 5 ether);

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(), 4.9 ether, "100 pulls at 0.001 ETH");
        assertGt(refund, 0, "a due settle that repriced pays the refund");
        assertEq(keeper.balance, refund);
        assertEq(_pullsSinceList(), 0, "the reprice restarts the pull count");
    }

    function test_aDecayBelowOnePercentDoesNotReprice() public {
        _setCooldown(0);
        _decayedItemWithDueSettle();
        pool.recordPulls(49);

        _settleAs(keeper);

        assertEq(_notionalOf(), 5 ether, "49 pulls decay 0.049 ETH, under 1 percent of 5 ETH");
        assertEq(grailListedInSettle, 0);
        pool.recordPulls(1);
        pool.pushReplacement(1);
        _settleAs(keeper);
        assertEq(_notionalOf(), 4.95 ether, "50 pulls reach the threshold");
    }

    function test_aSettleThatIsNotDueDoesNotReprice() public {
        _openReady();
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        pool.recordPulls(100);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None), "nothing queued, nothing held");

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(), 5 ether, "the reprice rides on a due settle");
        assertEq(refund, 0);
        assertEq(_pullsSinceList(), 100);
    }

    function test_rotateLeavesTheListPriceAlone() public {
        _openReady();
        assertEq(factory.inventoryChangeCooldown(), 300, "settle may not list, so the Held rotation does");
        _pooledCapture(1);
        pool.recordPulls(5);
        _warpToSpacing();
        _assertDue(IPoolTypes.RotateTrigger.Held);
        uint256 before_ = _notionalOf();
        uint256 pullsBefore = _pullsSinceList();
        assertEq(pullsBefore, 6, "one booked capture and five recorded pulls");

        vm.prank(keeper);
        pool.rotate();

        assertEq(_notionalOf(), before_, "rotate lists the queue and does not reprice");
        assertEq(_pullsSinceList(), pullsBefore, "the pull count is unchanged");
    }

    function test_aDueSettleDoesNotRepriceUnderANonzeroCooldown() public {
        _decayedItemWithDueSettle();
        pool.recordPulls(100);
        assertEq(factory.inventoryChangeCooldown(), 300);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Thin));

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(), 5 ether, "no FWA inventory call while the cooldown is nonzero");
        assertEq(grailListedInSettle, 0);
        assertEq(listedInSettle, 0);
        assertEq(refund, 0);
        assertEq(_pullsSinceList(), 100, "the pull count keeps running");
    }

    function test_listWhilePausedLetsADueSettleRepriceUnderACooldown() public {
        _decayedItemWithDueSettle();
        vm.prank(admin);
        IPool(address(pool)).setListWhilePaused(true);
        pool.recordPulls(100);
        assertEq(factory.inventoryChangeCooldown(), 300);

        uint256 refund = _settleAs(keeper);

        assertEq(_notionalOf(), 4.9 ether);
        assertEq(grailListedInSettle, 1);
        assertGt(refund, 0);
    }

    function test_aDueSettleStopsAtTheFloor() public {
        _setCooldown(0);
        _decayedItemWithDueSettle();
        vm.prank(admin);
        IPool(address(pool)).setGrailProbCap(10_000);
        pool.recordPulls(100_000);

        _settleAs(keeper);

        uint256 floorWei = IPool(address(pool)).grail().floorWei;
        assertEq(_notionalOf(), floorWei);
        assertEq(grailListedInSettle, 1, "the first settle repriced the item to the floor");
        pool.recordPulls(1);
        pool.pushReplacement(1);
        uint256 refund = _settleAs(keeper);
        assertEq(grailListedInSettle, 0, "at the floor a due settle has nothing to reprice");
        assertEq(_notionalOf(), floorWei);
        assertEq(listedInSettle, 1, "the settle listed the queued replacement");
        assertGt(refund, 0, "the refund covers the listing");
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
        _pooledCapture(1);
        _drainCash(400 ether, 0.3 ether);
        _fundGrail();
        _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval());
        _assertDue(IPoolTypes.RotateTrigger.Claim);
        // Paying the claim from cash leaves the next trigger.
        pool.bookProceeds{value: 1_000 ether}();
        pool.payClaims();
        _assertDue(IPoolTypes.RotateTrigger.GrailStep);
        pool.loseGrailFund(_fundOf());
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

    function _fundOf() internal view returns (uint256) {
        return IPool(address(pool)).grail().fund;
    }

    /// @dev Sets the factory's `inventoryChangeCooldown`, as the factory owner does.
    function _setCooldown(uint32 seconds_) internal {
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(seconds_);
    }
}
