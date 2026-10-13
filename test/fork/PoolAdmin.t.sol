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
///      items after `recordPulls(60)`. The GRAIL steps are 500 ETH, so `rotate` does not grow a
///      track until `setGrail` lowers the step.
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

    function _openReady() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(pool.openingDeadlineAt());
        pool.open();
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
        IPool(address(pool)).setFeeSplit(1, 1, 1, 1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setEntryCurve(1, 1, 1, 1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setNavCap(1);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setMix(_currentRows());
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 8_000, 0, 0.1 ether);
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
        IPool(address(pool)).setPaused(true, true);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setAdmin(stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).sweep(SHAPES_ADDR, 1, stranger);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).adminCall(address(clone), "", 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fee split and curve

    function test_setFeeSplitStoresTheSplitAndLogsTheSelector() public {
        _expectParamSet(IPool.setFeeSplit.selector);
        vm.prank(admin);
        IPool(address(pool)).setFeeSplit(300, 200, 500, 2_500);
        (uint16 premium, uint16 maintenance, uint16 feed, uint16 minorShare) = pool.feeSplit();
        assertEq(premium, 300);
        assertEq(maintenance, 200);
        assertEq(feed, 500);
        assertEq(minorShare, 2_500);
    }

    function test_setFeeSplitBounds() public {
        vm.startPrank(admin);
        IPool(address(pool)).setFeeSplit(400, 300, 300, 10_000);
        vm.expectRevert(IPoolTypes.FeeSplitTooHigh.selector);
        IPool(address(pool)).setFeeSplit(400, 300, 301, 0);
        vm.expectRevert(IPoolTypes.MinorShareTooHigh.selector);
        IPool(address(pool)).setFeeSplit(1, 1, 1, 10_001);
        vm.stopPrank();
    }

    function test_setEntryCurveStoresTheCurveAndBoundsIt() public {
        vm.startPrank(admin);
        _expectParamSet(IPool.setEntryCurve.selector);
        IPool(address(pool)).setEntryCurve(500, 1_000, 2_500, 10 ether);
        (uint32 base, uint32 slope, uint32 cap, uint128 ref_) = pool.curve();
        assertEq(base, 500);
        assertEq(slope, 1_000);
        assertEq(cap, 2_500);
        assertEq(ref_, 10 ether);

        vm.expectRevert(IPoolTypes.CurveCapTooHigh.selector);
        IPool(address(pool)).setEntryCurve(500, 1_000, 2_501, 10 ether);
        vm.expectRevert(IPoolTypes.CurveReferenceZero.selector);
        IPool(address(pool)).setEntryCurve(500, 1_000, 2_500, 0);
        vm.stopPrank();
    }

    function test_setEntryCurveChangesTheNextDeposit() public {
        vm.prank(admin);
        IPool(address(pool)).setEntryCurve(0, 0, 0, 1 ether);
        vm.prank(alice);
        pool.deposit{value: 10 ether}();
        assertEq(pool.sharesOf(alice), 10 ether, "no entry contribution at a zero curve");
    }

    function test_setNavCapStoresTheCap() public {
        _expectParamSet(IPool.setNavCap.selector);
        vm.prank(admin);
        IPool(address(pool)).setNavCap(5 ether);
        assertEq(pool.navCap(), 5 ether);

        vm.prank(alice);
        pool.deposit{value: 6 ether}();
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.NavCapReached.selector);
        pool.deposit{value: 1 ether}();
    }

    // ---------------------------------------------------------------- mix

    function test_setMixGrowsTheTableAndTheBoardFollows() public {
        _openReady();
        assertEq(pool.mixLength(), 2);
        PricingLib.MixRow[] memory rows = _rows(2, 0, 1, true);
        rows[0].rungs[0] = 2;
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);

        assertEq(pool.mixLength(), 3);
        assertEq(pool.rowCount(2), 0, "new row starts empty");
        assertEq(pool.listedRowCount(2), 0);
        (uint8[] memory rungs, uint16 share) = pool.mixRow(2);
        assertEq(rungs.length, 1);
        assertEq(rungs[0], 1);
        assertEq(share, 1_500);

        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        pool.recordPulls(20);
        pool.rotate();
        assertGt(pool.rowCount(2), 0, "rotate mints toward the new row target");
        assertGt(pool.listedRowCount(2), 0, "and lists it");
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
        (, uint16 share) = pool.mixRow(0);
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
        (uint8[] memory rungs,) = pool.mixRow(0);
        assertEq(rungs[0], 1, "rows without items take new rungs");

        rows = new PricingLib.MixRow[](1);
        rows[0] = _rows(2, 0, 0, false)[0];
        rows[0].shareBps = 10_000;
        vm.prank(admin);
        IPool(address(pool)).setMix(rows);
        assertEq(pool.mixLength(), 1, "an empty table row can be dropped");
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
        vm.expectRevert(IPoolTypes.InvalidTrack.selector);
        IPool(address(pool)).setGrail(2, 1 ether, 0.1 ether, 8_000, 0, 0.1 ether);
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 0, 0, 0.1 ether);
        vm.expectRevert(IPoolTypes.ListBpsOutOfRange.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 10_001, 0, 0.1 ether);
        vm.expectRevert(IPoolTypes.GrailStepInvalid.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.01 ether, 8_000, 0, 0.1 ether);
        vm.expectRevert(IPoolTypes.GrailStepInvalid.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.025 ether, 8_000, 0, 0.1 ether);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 8_000, 0, 0);
        vm.expectRevert(IPoolTypes.GrailFloorInvalid.selector);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 8_000, 0, 0.8 ether + 1);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 8_000, 0, 0.8 ether);
        vm.stopPrank();
    }

    function _grailWords(uint256 t) internal view returns (uint256[12] memory g) {
        (g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8], g[9], g[10], g[11]) = pool.grail(t);
    }

    function test_setGrailStoresTheParametersAndLeavesTheTrackState() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 0.5 ether, 0.05 ether, 8_000, 0.001 ether, 0.1 ether);
        pool.growGrail(0);
        pool.recordPulls(3);
        uint256[12] memory before_ = _grailWords(0);
        assertGt(before_[1], 0, "pack");
        assertGt(before_[11], 0, "listing");

        _expectParamSet(IPool.setGrail.selector);
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 2 ether, 0.1 ether, 9_000, 0.002 ether, 0.2 ether);
        uint256[12] memory after_ = _grailWords(0);

        assertEq(after_[4], 2 ether, "target");
        assertEq(after_[5], 0.1 ether, "step");
        assertEq(after_[6], 9_000, "listBps");
        assertEq(after_[7], 0.002 ether, "decay");
        assertEq(after_[8], 0.2 ether, "floor");
        uint256[7] memory untouched = [uint256(0), 1, 2, 3, 9, 10, 11];
        for (uint256 k; k < untouched.length; ++k) {
            assertEq(after_[untouched[k]], before_[untouched[k]], "track state untouched");
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
        assertEq(pool.maxBatch(), 2);
        IPool(address(pool)).setMaxBatch(live);
        assertEq(pool.maxBatch(), live);
        vm.stopPrank();
    }

    function test_setMaxBatchLimitsPulls() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setMaxBatch(1);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(2);
        vm.deal(alice, total);
        vm.prank(alice);
        vm.expectRevert(IPoolTypes.InvalidCount.selector);
        pool.pull{value: total}(2, fee, block.timestamp + 1 hours);
    }

    function test_setConcurrencyBounds() public {
        uint256 live = factory.maxOutstandingRequestsPerPool();
        vm.startPrank(admin);
        vm.expectRevert(IPoolTypes.LimitOutOfRange.selector);
        IPool(address(pool)).setConcurrency(live + 1);
        _expectParamSet(IPool.setConcurrency.selector);
        IPool(address(pool)).setConcurrency(0);
        assertEq(pool.concurrency(), 0);
        IPool(address(pool)).setConcurrency(live);
        assertEq(pool.concurrency(), live);
        vm.stopPrank();
    }

    function test_setConcurrencyChangesTheBoardThinGuard() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(alice, 3 * total);
        uint64 last = clone.lastIssuedSequence();
        vm.prank(alice);
        pool.pull{value: total}(1, fee, block.timestamp + 1 hours);
        uint256 requestId = clone.requestIdAtSequence(last + 1);
        fulfill(clone, requestId, wordFor(clone, pool.listedIds(0)[0]));
        pool.settle(20);
        assertEq(pool.listedCount(), 9);

        vm.prank(alice);
        vm.expectRevert(IPoolTypes.BoardTooThin.selector);
        pool.pull{value: total}(1, fee, block.timestamp + 1 hours);

        vm.prank(admin);
        IPool(address(pool)).setConcurrency(9);
        vm.prank(alice);
        pool.pull{value: total}(1, fee, block.timestamp + 1 hours);
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
        assertEq(pool.grailProbCapBps(), 10_000);
        IPool(address(pool)).setGrailProbCap(1);
        assertEq(pool.grailProbCapBps(), 1);
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
        vm.deal(alice, total + 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(IPoolTypes.PullsPaused.selector);
        pool.pull{value: total}(1, fee, block.timestamp + 1 hours);
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
        IPool(address(pool)).setNavCap(1);
        vm.stopPrank();
        assertEq(pool.admin(), stranger);
        vm.prank(stranger);
        IPool(address(pool)).setNavCap(1);
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

    function test_revert_sweepOfAGrailPack() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 0.5 ether, 0.05 ether, 8_000, 0.001 ether, 0.1 ether);
        pool.growGrail(0);
        (, uint256 packId,,,,,,,,,,) = pool.grail(0);
        assertGt(packId, 0);
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.Accounted.selector);
        IPool(address(pool)).sweep(address(drawPacks), packId, recipient);
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
        (uint256 minorBucket,,,,,,,,,,,) = pool.grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = pool.grail(1);
        spare -= minorBucket + majorBucket;
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
        p.minor.stepWei = 500 ether;
        p.minor.targetWei = 1_000 ether;
        p.major.stepWei = 500 ether;
        p.major.targetWei = 1_000 ether;
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
