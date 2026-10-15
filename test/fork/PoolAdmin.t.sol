// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {PoolAdmin} from "../../src/PoolAdmin.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Admin setters, `sweep` and `adminCall` against deployed Shapes, a Draw Packs deployment
///         and a FWA clone created by the pool.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). A 100 ETH deposit builds a board of 7 + 3 items, or 42 + 18
///      items after `recordPulls(60)`. `open` forms the opening five from the GRAIL fund.
contract PoolAdminForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

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
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _openReady() internal {
        vm.prank(alice);
        pool.deposit{value: _openingDeposit(address(pool))}();
        _topUpGrailFund(pool);
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        pool.loseGrailFund(IPool(address(pool)).grail().fund);
        warpPastCooldown(clone);
    }

    function _rows(uint8 first, uint8 second, uint8 third, bool addThird)
        internal
        pure
        returns (PricingLib.MixRow[] memory rows)
    {
        rows = new PricingLib.MixRow[](addThird ? 3 : 2);
        rows[0].rungs = new uint8[](1);
        rows[0].rungs[0] = first;
        rows[0].shareBps = addThird ? 6_000 : 7_000;
        rows[1].rungs = new uint8[](2);
        rows[1].rungs[0] = 0;
        rows[1].rungs[1] = second;
        rows[1].shareBps = addThird ? 2_500 : 3_000;
        if (addThird) {
            rows[2].rungs = new uint8[](1);
            rows[2].rungs[0] = third;
            rows[2].shareBps = 1_500;
        }
    }

    /// @dev The mix `PoolFixture._params` builds with the rungs of `PoolAdminForkTest.setUp`.
    function _currentRows() internal pure returns (PricingLib.MixRow[] memory rows) {
        rows = _rows(2, 0, 0, false);
        rows[1].rungs[1] = 0;
        rows[0].shareBps = 7_000;
        rows[1].shareBps = 3_000;
    }

    function _expectParamSet(bytes4 selector) internal {
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.ParamSet(selector);
    }

    // ---------------------------------------------------------------- access

    function test_revert_everySetterRequiresTheAdmin() public {
        vm.startPrank(stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setFeeSplit(1, 1, 1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setEntryFee(1, 1, 1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setNavCapFloor(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setTurnover(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setFounderWindow(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setMix(_currentRows());
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setGrail(0, 0.25 ether, 1 ether, 7_500);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setGrailTarget(5 ether);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setMaxBatch(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setConcurrency(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setRotateInterval(3_600);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setMinItems(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setGrailProbCap(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setBatch(1, 1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setReplacement(0, 0, 0);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setReserve(0);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setTip(0);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setListWhilePaused(true);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setPaused(true, true);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setAdmin(stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).sweep(SHAPES_ADDR, 1, stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).adminCall(address(clone), "", 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fee split and entry fee

    function test_setFeeSplitStoresTheSplitAndLogsTheSelector() public {
        _expectParamSet(IPool.setFeeSplit.selector);
        vm.prank(admin);
        IPool(address(pool)).setFeeSplit(300, 200, 500);
        (uint16 premium, uint16 maintenance, uint16 feed) = pool.feeSplit();
        assertEq(premium, 300);
        assertEq(maintenance, 200);
        assertEq(feed, 500);
    }

    function test_setFeeSplitBounds() public {
        vm.startPrank(admin);
        IPool(address(pool)).setFeeSplit(400, 300, 300);
        vm.expectRevert(IPoolTypes.FeeSplitTooHigh.selector);
        IPool(address(pool)).setFeeSplit(400, 300, 301);
        vm.stopPrank();
    }

    function test_setEntryFeeStoresTheFeeAndBoundsIt() public {
        vm.startPrank(admin);
        _expectParamSet(IPool.setEntryFee.selector);
        IPool(address(pool)).setEntryFee(500, 3_000, 10);
        (uint32 floorBps, uint32 capBps, uint32 paybackDays) = pool.entryFee();
        assertEq(floorBps, 500);
        assertEq(capBps, 3_000);
        assertEq(paybackDays, 10);

        IPool(address(pool)).setEntryFee(0, 10_000, 1);
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        IPool(address(pool)).setEntryFee(0, 10_001, 1);
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        IPool(address(pool)).setEntryFee(2_501, 2_500, 1);
        vm.expectRevert(IPoolTypes.EntryFeeOutOfRange.selector);
        IPool(address(pool)).setEntryFee(500, 2_500, 0);
        vm.stopPrank();
    }

    function test_setEntryFeeChangesTheNextDeposit() public {
        vm.prank(admin);
        IPool(address(pool)).setEntryFee(0, 0, 1);
        vm.prank(alice);
        pool.deposit{value: 10 ether}();
        assertEq(pool.sharesOf(alice), 10 ether, "no entry contribution at a zero fee");
    }

    function test_setNavCapFloorStoresTheFloor() public {
        _expectParamSet(IPool.setNavCapFloor.selector);
        vm.prank(admin);
        IPool(address(pool)).setNavCapFloor(5 ether);
        assertEq(pool.navCapFloor(), 5 ether);
        assertEq(pool.navCap(), 5 ether);

        vm.prank(alice);
        pool.deposit{value: 6 ether}();
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        pool.deposit{value: 1 ether}();
    }

    function test_setTurnoverStoresTheTurnoverAndBoundsIt() public {
        vm.startPrank(admin);
        _expectParamSet(IPool.setTurnover.selector);
        IPool(address(pool)).setTurnover(2_500);
        assertEq(pool.turnoverBps(), 2_500);
        IPool(address(pool)).setTurnover(10_000);
        IPool(address(pool)).setTurnover(1);
        vm.expectRevert(IPoolTypes.TurnoverOutOfRange.selector);
        IPool(address(pool)).setTurnover(0);
        vm.expectRevert(IPoolTypes.TurnoverOutOfRange.selector);
        IPool(address(pool)).setTurnover(10_001);
        vm.stopPrank();
    }

    function test_setFounderWindowAppliesToTheNextOpenOnly() public {
        _expectParamSet(IPool.setFounderWindow.selector);
        vm.prank(admin);
        IPool(address(pool)).setFounderWindow(7 days);
        assertEq(pool.founderWindowSeconds(), 7 days);
        assertEq(pool.depositsOpenAt(), 0, "unset before open");
    }

    // ---------------------------------------------------------------- mix

    function test_setMixGrowsTheTableAndTheBoardFollows() public {
        _openReady();
        assertEq(IPool(address(pool)).mixLength(), 2);
        PricingLib.MixRow[] memory rows = _rows(2, 0, 1, true);
        rows[0].rungs[0] = 2;
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);

        assertEq(IPool(address(pool)).mixLength(), 3);
        assertEq(IPool(address(pool)).rowCount(2), 0, "new row starts empty");
        assertEq(IPool(address(pool)).listedRowCount(2), 0);
        (uint8[] memory rungs, uint16 share) = IPool(address(pool)).mixRow(2);
        assertEq(rungs.length, 1);
        assertEq(rungs[0], 1);
        assertEq(share, 1_500);

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "the new row fills through replacement draws");
    }

    function test_revert_setMixChangesRungsOfARowWithItems() public {
        _openReady();
        PricingLib.MixRow[] memory rows = _rows(1, 0, 0, false);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.RowInUse.selector);
        IPool(address(pool)).setMix(rows);

        rows = _rows(2, 1, 0, false);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.RowInUse.selector);
        IPool(address(pool)).setMix(rows);
    }

    function test_setMixMayChangeSharesOfRowsWithItems() public {
        _openReady();
        PricingLib.MixRow[] memory rows = _currentRows();
        rows[0].shareBps = 5_000;
        rows[1].shareBps = 5_000;
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);
        (, uint16 share) = IPool(address(pool)).mixRow(0);
        assertEq(share, 5_000);
    }

    function test_revert_setMixDropsARowWithItems() public {
        _openReady();
        PricingLib.MixRow[] memory rows = new PricingLib.MixRow[](1);
        rows[0] = _currentRows()[0];
        rows[0].shareBps = 10_000;
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.RowInUse.selector);
        IPool(address(pool)).setMix(rows);
    }

    function test_setMixMayChangeRowsWithoutItems() public {
        PricingLib.MixRow[] memory rows = _rows(1, 1, 0, false);
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);
        (uint8[] memory rungs,) = IPool(address(pool)).mixRow(0);
        assertEq(rungs[0], 1, "rows without items take new rungs");

        rows = new PricingLib.MixRow[](1);
        rows[0] = _rows(2, 0, 0, false)[0];
        rows[0].shareBps = 10_000;
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);
        assertEq(IPool(address(pool)).mixLength(), 1, "an empty table row can be dropped");
    }

    function test_revert_setMixDropsARowWithAQueuedReplacement() public {
        pool.pushReplacement(1);
        PricingLib.MixRow[] memory rows = new PricingLib.MixRow[](1);
        rows[0] = _currentRows()[0];
        rows[0].shareBps = 10_000;
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.RowInUse.selector);
        IPool(address(pool)).setMix(rows);
    }

    function test_revert_setMixEmptyTableOrBadRung() public {
        vm.startPrank(admin);
        vm.expectRevert(PricingLib.EmptyRow.selector);
        IPool(address(pool)).setMix(new PricingLib.MixRow[](0));
        PricingLib.MixRow[] memory rows = _currentRows();
        rows[0].rungs[0] = 200;
        vm.expectRevert();
        IPool(address(pool)).setMix(rows);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- GRAIL

    function test_setGrailValidations() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        IPool(address(pool)).setGrail(0, 0.25 ether, 1 ether, 0);
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        IPool(address(pool)).setGrail(0, 0.25 ether, 1 ether, 10_001);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 0, 1 ether, 7_500);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 1 ether + 1, 1 ether, 7_500);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 0.25 ether, 0, 7_500);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 0.25 ether, 3.75 ether + 1, 7_500);
        IPool(address(pool)).setGrail(0, 1 ether, 3.75 ether, 7_500);
        vm.stopPrank();
    }

    function test_setGrailStoresTheParametersAndLeavesTheState() public {
        _openReady();
        pool.addGrailFund{value: 5 ether}();
        _warpPastRotateGate(pool);
        assertTrue(pool.stepGrail());
        pool.recordPulls(3);
        IPoolTypes.Grail memory before_ = IPool(address(pool)).grail();
        IPoolTypes.GrailItem[] memory itemsBefore = IPool(address(pool)).grailItems();
        assertEq(itemsBefore.length, 4);
        assertEq(before_.pulls, 3);

        _expectParamSet(IPool.setGrail.selector);
        vm.prank(admin);
        IPool(address(pool)).setGrail(0.002 ether, 0.5 ether, 2 ether, 9_000);
        IPoolTypes.Grail memory after_ = IPool(address(pool)).grail();

        assertEq(after_.decayWeiPerPull, 0.002 ether);
        assertEq(after_.pieceFloorWei, 0.5 ether);
        assertEq(after_.floorWei, 2 ether);
        assertEq(after_.listBps, 9_000);
        assertEq(after_.fund, before_.fund);
        assertEq(after_.receivable, before_.receivable);
        assertEq(after_.targetWei, before_.targetWei);
        assertEq(after_.nextTargetWei, before_.nextTargetWei);
        assertEq(after_.cycleId, before_.cycleId);
        assertEq(keccak256(abi.encode(IPool(address(pool)).grailItems())), keccak256(abi.encode(itemsBefore)));
    }

    function test_setGrailTargetWritesTheNextTargetOnly() public {
        _expectParamSet(IPool.setGrailTarget.selector);
        vm.prank(admin);
        IPool(address(pool)).setGrailTarget(50 ether);
        IPoolTypes.Grail memory g = IPool(address(pool)).grail();
        assertEq(g.nextTargetWei, 50 ether);
        assertEq(g.targetWei, 25 ether, "the running cycle keeps its target");
    }

    function test_revert_setGrailTargetOffTheLadder() public {
        uint256[4] memory bad = [uint256(0), 1 ether, 20 ether, 25 ether + 1];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(IPoolTypes.GrailTargetInvalid.selector);
            IPool(address(pool)).setGrailTarget(bad[i]);
        }
        uint256[5] memory good = [uint256(5 ether), 10 ether, 25 ether, 50 ether, 100 ether];
        for (uint256 i; i < good.length; ++i) {
            vm.prank(admin);
            IPool(address(pool)).setGrailTarget(good[i]);
            assertEq(IPool(address(pool)).grail().nextTargetWei, good[i]);
        }
    }

    // ---------------------------------------------------------------- limits

    function test_setMaxBatchBounds() public {
        uint256 live = factory.maxAcquisitionsPerTx();
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setMaxBatch(0);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setMaxBatch(live + 1);
        _expectParamSet(IPool.setMaxBatch.selector);
        IPool(address(pool)).setMaxBatch(2);
        assertEq(IPool(address(pool)).maxBatch(), 2);
        IPool(address(pool)).setMaxBatch(live);
        assertEq(IPool(address(pool)).maxBatch(), live);
        vm.stopPrank();
    }

    function test_setMaxBatchLimitsPulls() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setMaxBatch(1);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(2);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(alice, total);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.InvalidCount.selector);
        pool.acquireBatch{value: total}(alice, 2, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_setConcurrencyBounds() public {
        uint256 live = factory.maxOutstandingRequestsPerPool();
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setConcurrency(live + 1);
        _expectParamSet(IPool.setConcurrency.selector);
        IPool(address(pool)).setConcurrency(0);
        assertEq(IPool(address(pool)).concurrency(), 0);
        IPool(address(pool)).setConcurrency(live);
        assertEq(IPool(address(pool)).concurrency(), live);
        vm.stopPrank();
    }

    function test_setConcurrencyChangesTheBoardThinGuard() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(alice, 3 * total);
        uint64 last = clone.lastIssuedSequence();
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.prank(alice);
        pool.acquireBatch{value: total}(alice, 1, fee, 0, slip, version, block.timestamp + 1 hours);
        uint256 requestId = clone.requestIdAtSequence(last + 1);
        fulfill(clone, requestId, wordFor(clone, pool.listedIds(0)[0]));
        pool.settle(20);
        assertEq(pool.listedCount(), 9);

        (slip, version) = poolArgs(clone);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.BoardTooThin.selector);
        pool.acquireBatch{value: total}(alice, 1, fee, 0, slip, version, block.timestamp + 1 hours);

        vm.prank(admin);
        IPool(address(pool)).setConcurrency(9);
        (slip, version) = poolArgs(clone);
        vm.prank(alice);
        pool.acquireBatch{value: total}(alice, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_setRotateIntervalBounds() public {
        uint256 cooldown = factory.inventoryChangeCooldown();
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setRotateInterval(cooldown - 1);
        _expectParamSet(IPool.setRotateInterval.selector);
        IPool(address(pool)).setRotateInterval(cooldown);
        assertEq(pool.rotateInterval(), cooldown);
        vm.stopPrank();
    }

    function test_setMinItemsAndGrailProbCap() public {
        vm.startPrank(admin);
        _expectParamSet(IPool.setMinItems.selector);
        IPool(address(pool)).setMinItems(25);
        assertEq(pool.minItems(), 25);

        vm.expectRevert(IPoolTypes.GrailProbCapOutOfRange.selector);
        IPool(address(pool)).setGrailProbCap(0);
        vm.expectRevert(IPoolTypes.GrailProbCapOutOfRange.selector);
        IPool(address(pool)).setGrailProbCap(10_001);
        _expectParamSet(IPool.setGrailProbCap.selector);
        IPool(address(pool)).setGrailProbCap(10_000);
        assertEq(IPool(address(pool)).grailProbCapBps(), 10_000);
        IPool(address(pool)).setGrailProbCap(1);
        assertEq(IPool(address(pool)).grailProbCapBps(), 1);
        vm.stopPrank();
    }

    function test_setBatchBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setBatch(0, 1);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setBatch(1, 0);
        _expectParamSet(IPool.setBatch.selector);
        IPool(address(pool)).setBatch(3, 600);
        assertEq(IPool(address(pool)).batchMin(), 3);
        assertEq(IPool(address(pool)).batchMaxAge(), 600);
        vm.stopPrank();
    }

    function test_setTipBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setTip(0.01 ether + 1);
        _expectParamSet(IPool.setTip.selector);
        IPool(address(pool)).setTip(0.01 ether);
        assertEq(IPool(address(pool)).tipWei(), 0.01 ether);
        IPool(address(pool)).setTip(0);
        assertEq(IPool(address(pool)).tipWei(), 0);
        vm.stopPrank();
    }

    function test_setTipIsAdminOnly() public {
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setTip(1);
        assertEq(IPool(address(pool)).tipWei(), 0.0002 ether);
    }

    function test_setReplacementBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setReplacement(10_001, 8, 3_000);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setReplacement(200, 101, 3_000);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setReplacement(200, 8, 100_001);
        _expectParamSet(IPool.setReplacement.selector);
        IPool(address(pool)).setReplacement(10_000, 100, 100_000);
        assertEq(IPool(address(pool)).surpriseBps(), 10_000);
        assertEq(IPool(address(pool)).restoreK(), 100);
        assertEq(IPool(address(pool)).bandBps(), 100_000);
        IPool(address(pool)).setReplacement(0, 0, 0);
        assertEq(IPool(address(pool)).surpriseBps(), 0);
        assertEq(IPool(address(pool)).restoreK(), 0);
        assertEq(IPool(address(pool)).bandBps(), 0);
        vm.stopPrank();
    }

    function test_setReserveBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setReserve(10_001);
        _expectParamSet(IPool.setReserve.selector);
        IPool(address(pool)).setReserve(10_000);
        assertEq(IPool(address(pool)).reserveBps(), 10_000);
        IPool(address(pool)).setReserve(0);
        assertEq(IPool(address(pool)).reserveBps(), 0);
        vm.stopPrank();
    }

    function test_setListWhilePaused() public {
        assertFalse(IPool(address(pool)).listWhilePaused());
        vm.startPrank(admin);
        _expectParamSet(IPool.setListWhilePaused.selector);
        IPool(address(pool)).setListWhilePaused(true);
        assertTrue(IPool(address(pool)).listWhilePaused());
        IPool(address(pool)).setListWhilePaused(false);
        assertFalse(IPool(address(pool)).listWhilePaused());
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- pause and admin

    function test_setPausedClosesPullsAndDeposits() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setPaused(true, true);
        assertTrue(pool.pullsPaused());
        assertTrue(pool.depositsPaused());

        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(alice, total + 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(IPoolTypes.PullsPaused.selector);
        pool.acquireBatch{value: total}(alice, 1, fee, 0, slip, version, block.timestamp + 1 hours);
        vm.expectRevert(IPoolTypes.DepositsPaused.selector);
        pool.deposit{value: 1 ether}();
        vm.stopPrank();

        vm.prank(admin);
        IPool(address(pool)).setPaused(false, false);
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
    }

    function test_setAdminTransfersTheRole() public {
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        IPool(address(pool)).setAdmin(address(0));
        _expectParamSet(IPool.setAdmin.selector);
        IPool(address(pool)).setAdmin(stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setNavCapFloor(1);
        vm.stopPrank();
        assertEq(pool.admin(), stranger);
        vm.prank(stranger);
        IPool(address(pool)).setNavCapFloor(1);
    }

    // ---------------------------------------------------------------- sweep

    function test_sweepSendsAStrayShape() public {
        uint256 id = mintShapes(address(pool), 0.05 ether, 1);
        assertEq(shapes.ownerOf(id), address(pool));
        vm.prank(admin);
        IPool(address(pool)).sweep(SHAPES_ADDR, id, recipient);
        assertEq(shapes.ownerOf(id), recipient);
    }

    function test_revert_sweepOfAHeldOrListedItem() public {
        _openReady();
        uint256[] memory listed = pool.listedIds(0);
        IPoolTypes.Item memory it = pool.listedItem(listed[0]);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        IPool(address(pool)).sweep(it.collection, it.tokenId, recipient);

        // A held item: the replacement mint of a settled capture stays unlisted until `rotate`.
        pool.addItem(SHAPES_ADDR, 0, 9_999_999, 0.1 ether, 0);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        IPool(address(pool)).sweep(SHAPES_ADDR, 9_999_999, recipient);
    }

    function test_revert_sweepOfAGrailItem() public {
        _openReady();
        IPoolTypes.GrailItem memory it = IPool(address(pool)).grailItems()[0];
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        IPool(address(pool)).sweep(it.collection, it.tokenId, recipient);
    }

    // ---------------------------------------------------------------- adminCall

    function test_adminCallRunsAsThePoolOnTheFwaClone() public {
        _openReady();
        assertTrue(clone.localPurchasesEnabled());
        vm.prank(admin);
        IPool(address(pool)).adminCall(address(clone), abi.encodeCall(IFWAClone.setBool, (41, false)), 0);
        assertFalse(clone.localPurchasesEnabled());
    }

    function test_adminCallForwardsTheAdminsValue() public {
        _openReady();
        uint256 poolBefore = address(pool).balance;
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        IPool(address(pool)).adminCall{value: 1 ether}(recipient, "", 1 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(address(pool).balance, poolBefore, "the call is funded by msg.value");
    }

    function test_revert_adminCallValueMismatch() public {
        vm.deal(admin, 2 ether);
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.AdminValueMismatch.selector);
        IPool(address(pool)).adminCall{value: 1 ether}(recipient, "", 0);
        vm.expectRevert(IPoolTypes.AdminValueMismatch.selector);
        IPool(address(pool)).adminCall{value: 1 ether}(recipient, "", 2 ether);
        vm.expectRevert(IPoolTypes.AdminValueMismatch.selector);
        IPool(address(pool)).adminCall(recipient, "", 1);
        vm.stopPrank();
    }

    function test_adminCallBubblesTheTargetsRevert() public {
        _openReady();
        bytes memory data = abi.encodeCall(IFWAClone.updatePrice, (999_999, 1 ether));
        vm.prank(address(pool));
        (bool direct, bytes memory expected) = address(clone).call(data);
        assertFalse(direct);
        assertGt(expected.length, 0);

        vm.prank(admin);
        (bool ok, bytes memory returned) =
            address(pool).call(abi.encodeCall(IPool.adminCall, (address(clone), data, 0)));
        assertFalse(ok);
        assertEq(returned, expected);
    }

    function test_revert_adminCallThatDropsTrackedEthBelowTheBuckets() public {
        _openReady();
        uint256 spare = address(pool).balance - pool.cash() - pool.maintenance();
        spare -= IPool(address(pool)).grail().fund;
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.InvariantBroken.selector);
        IPool(address(pool)).adminCall(address(pool), abi.encodeCall(PoolHarness.leak, (spare + 1)), 0);

        vm.prank(admin);
        IPool(address(pool)).adminCall(address(pool), abi.encodeCall(PoolHarness.leak, (spare)), 0);
    }

    function test_revert_adminCallThatBreaksBacking() public {
        _openReady();
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.InvariantBroken.selector);
        IPool(address(pool)).adminCall(address(pool), abi.encodeCall(PoolHarness.bumpBacking, (1)), 0);
    }

    function test_adminCallCannotReenterThePool() public {
        _openReady();
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert();
        IPool(address(pool)).adminCall{value: 1 ether}(address(pool), abi.encodeCall(Pool.deposit, ()), 1 ether);
    }

    // ---------------------------------------------------------------- admin module

    function test_revert_directCallToTheModuleIsRejected() public {
        address module = pool.adminModule();
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        IPool(module).setPaused(true, true);
        vm.expectRevert(IPoolTypes.NotDelegated.selector);
        IPool(module).canImport(SHAPES_ADDR, 1);
        vm.stopPrank();
        assertEq(PoolAdmin(module).admin(), address(0), "module storage is empty");
        assertFalse(PoolAdmin(module).pullsPaused());
        assertFalse(pool.pullsPaused());
    }

    function test_moduleRevertDataBubblesThroughTheFallback() public {
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.ZeroAddress.selector);
        IPool(address(pool)).setAdmin(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PoolHarness.Preview.selector, uint256(0), uint256(0), uint256(0)));
        IPool(address(pool)).adminCall(address(pool), abi.encodeCall(PoolHarness.previewSynced, ()), 0);
    }

    function test_payableModuleFunctionReceivesValueThroughTheFallback() public {
        address old = makeAddr("old");
        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.oldPool = old;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        PoolHarness successor = new PoolHarness(p);

        vm.deal(old, 2 ether);
        vm.prank(old);
        IPool(address(successor)).importCash{value: 2 ether}();
        assertEq(successor.cash(), 2 ether);
        assertEq(successor.importedNav(), 2 ether);
        assertEq(address(successor).balance, 2 ether);
        assertEq(old.balance, 0);
    }

    function test_moduleViewIsReachableThroughTheFallback() public view {
        assertFalse(IPool(address(pool)).canImport(address(0), 1));
    }

    function test_revert_unknownSelector() public {
        (bool ok, bytes memory ret) = address(pool).call(abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1)));
        assertFalse(ok);
        assertEq(ret.length, 0);
        (ok,) = address(pool).call(hex"01");
        assertFalse(ok);
    }
}
