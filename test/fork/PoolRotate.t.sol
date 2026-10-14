// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice `rotate`, claim liquidation inside it and `payClaims` against deployed Shapes, a Draw Packs deployment and a FWA
///         clone created by the pool.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). A 100 ETH deposit builds a board of 7 + 3 items, or 42 + 18
///      items after `recordPulls(60)`.
contract PoolRotateForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal saver = makeAddr("saver");
    /// @dev Second depositor holding most shares. `alice` has code on mainnet that forwards ETH.
    address internal exiter = makeAddr("exiter");
    address internal keeper = makeAddr("keeper");
    uint256 internal mintFee;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        mintFee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);

        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        // A step above every bucket keeps `rotate` from growing the GRAIL tracks; PoolGrail.t.sol
        // covers growth.
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

    function _openReady() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        warpPastCooldown(clone);
    }

    function _openLarge() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.sizeBoard(60);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        assertEq(pool.listedCount(), 60);
        warpPastCooldown(clone);
    }

    function _warpToRotation() internal {
        uint256 at = pool.lastRotateAt() + pool.rotateInterval();
        if (block.timestamp < at) vm.warp(at);
    }

    function _warpInterval() internal {
        vm.warp(block.timestamp + pool.rotateInterval());
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

    /// @dev Deposits `depositWei` as `exiter`, then removes ordinary cash down to `cashLeft`.
    function _drainCash(uint256 depositWei, uint256 cashLeft) internal {
        vm.deal(exiter, depositWei);
        vm.prank(exiter);
        pool.deposit{value: depositWei}();
        pool.loseCash(pool.cash() - cashLeft);
        assertEq(pool.cash(), cashLeft);
    }

    /// @dev `exiter` withdraws every share. Returns the amount queued.
    function _exiterLeaves() internal returns (uint256 queued) {
        uint256 shares = pool.sharesOf(exiter);
        vm.prank(exiter);
        pool.withdraw(shares);
        queued = pool.claims();
        assertGt(queued, 0, "claim queued");
    }

    function _assertI1() internal view {
        (uint256 minorBucket,,,,,,,,,,,) = IPool(address(pool)).grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = IPool(address(pool)).grail(1);
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + minorBucket + majorBucket, "I1");
    }

    /// @dev I2: `backing` is the value of every held and listed item, `_listedByRow` holds exactly
    ///      the listed ids of each row, and `rowCount` is listed plus held per row.
    function _assertRegistry() internal view {
        uint256 sum;
        uint256 listed;
        uint256[2] memory perRow;
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            if (it.value == 0) continue;
            sum += it.value;
            ++listed;
            ++perRow[it.row];
            (,,,,,,, IFWAClone.ListingStatus status) = clone.listings(id);
            assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active), "listed item is an active listing");
        }
        for (uint256 i; i < pool.heldCount(); ++i) {
            sum += pool.heldItem(i).value;
        }
        assertEq(pool.backing(), sum, "I2 backing");
        assertEq(pool.listedCount(), listed, "listedCount");
        for (uint256 r; r < 2; ++r) {
            uint256[] memory ids = pool.listedIds(r);
            assertEq(ids.length, perRow[r], "listed ids of row");
            for (uint256 i; i < ids.length; ++i) {
                assertEq(pool.listedItem(ids[i]).row, r, "id sits in its row");
            }
            uint256 heldOfRow;
            for (uint256 i; i < pool.heldCount(); ++i) {
                if (pool.heldItem(i).row == r) ++heldOfRow;
            }
            assertEq(IPool(address(pool)).rowCount(r), perRow[r] + heldOfRow, "rowCount");
        }
    }

    struct Liq {
        uint256 count;
        uint256 shapeCount;
        uint256 packCount;
        uint256 fees;
        uint256 value;
        uint256 paid;
        uint256 firstPaidAt;
        uint256 firstLiqAt;
        uint256 refund;
        uint256 maintenanceShare;
        bool rotated;
    }

    function _summarize(Vm.Log[] memory logs) internal view returns (Liq memory s) {
        s.firstPaidAt = type(uint256).max;
        s.firstLiqAt = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == IPoolTypes.Liquidated.selector) {
                (uint256 value, uint256 fee) = abi.decode(logs[i].data, (uint256, uint256));
                ++s.count;
                s.value += value;
                s.fees += fee;
                if (value == 0.1 ether) ++s.shapeCount;
                else ++s.packCount;
                if (s.firstLiqAt == type(uint256).max) s.firstLiqAt = i;
            } else if (topic == IPoolTypes.ClaimPaid.selector) {
                s.paid += abi.decode(logs[i].data, (uint256));
                if (s.firstPaidAt == type(uint256).max) s.firstPaidAt = i;
            } else if (topic == IPoolTypes.MarginSplit.selector) {
                (,, uint256 maintenanceShare,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                s.maintenanceShare += maintenanceShare;
            } else if (topic == IPoolTypes.Rotated.selector) {
                (,, uint256 refund) = abi.decode(logs[i].data, (bool, bool, uint256));
                s.refund = refund;
                s.rotated = true;
            }
        }
    }

    function _rotateAsKeeper() internal returns (Liq memory s) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        s = _summarize(vm.getRecordedLogs());
    }

    // ---------------------------------------------------------------- guards

    function test_revert_rotateWhileOpening() public {
        vm.expectRevert(IPoolTypes.NotLive.selector);
        pool.rotate();
    }

    function test_revert_rotateBeforeTheInterval() public {
        _openReady();
        assertEq(pool.lastRotateAt(), IPool(address(pool)).openingDeadlineAt(), "open sets lastRotateAt");
        vm.warp(pool.lastRotateAt() + pool.rotateInterval() - 1);
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None));
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_rotateIgnoresPauseFlags() public {
        _openReady();
        uint256[] memory ids = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        vm.prank(keeper);
        pool.settle(20);
        pool.setPullsPaused(true);
        pool.pauseDeposits();
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.Held));
        vm.prank(keeper);
        pool.rotate();
        assertEq(pool.replacementLength(), 0);
    }

    // ---------------------------------------------------------------- rotate

    function test_rotateSettlesHarvestsRestocksListsAndRefunds() public {
        _openReady();
        uint256[] memory ids = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        assertEq(pool.listedCount(), 10);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        assertEq(pool.nextSequenceToBook(), 1, "capture not booked");
        vm.prank(keeper);
        pool.settle(20);
        assertEq(pool.nextSequenceToBook(), 2, "settle booked the capture");
        assertEq(pool.replacementLength(), 1, "the cooldown keeps settle from listing");
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.Held));

        uint256 maintenanceBefore = pool.maintenance();
        Liq memory s = _rotateAsKeeper();

        assertEq(pool.receivable(), 0, "harvested");
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0, "harvested");
        assertEq(pool.replacementLength(), 0, "replacement minted");
        assertEq(pool.heldCount(), 0, "board listed");
        assertEq(pool.listedCount(), 10);
        assertEq(IPool(address(pool)).rowCount(1), 3);
        assertEq(pool.lastRotateAt(), block.timestamp);
        assertTrue(s.rotated);

        uint256 maintenanceAfter = pool.maintenance();
        assertGt(maintenanceBefore, 1 ether, "settle credited the maintenance share");
        assertEq(maintenanceBefore - maintenanceAfter, s.refund, "maintenance fell by the refund");
        assertGt(s.refund, 0);
        assertGe(s.refund, IPool(address(pool)).tipWei(), "refund covers the tip");
        assertLe(s.refund, maintenanceBefore);
        assertEq(keeper.balance, s.refund, "caller received the refund");
        _assertRegistry();
        _assertI1();

        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
    }

    function test_rotateRefundCarriesTheAdminTip() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setTip(0.003 ether);
        uint256[] memory ids = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        vm.prank(keeper);
        pool.settle(20);
        _warpToRotation();

        Liq memory s = _rotateAsKeeper();

        assertGe(s.refund, 0.003 ether, "the rotate refund carries the set tip");
        assertEq(keeper.balance, s.refund);
    }

    function test_rotateIsNotDueForAListedTrackWhileAnAcquisitionIsUnsettled() public {
        _openReady();
        vm.prank(admin);
        IPool(address(pool)).setGrail(0, 1 ether, 0.1 ether, 8_000, 0.001 ether, 0.01 ether);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep), "unlisted track grows");
        vm.prank(keeper);
        pool.rotate();
        uint256 lastBefore = pool.lastRotateAt();
        uint256 maintenanceBefore = pool.maintenance();
        uint256 keeperBefore = keeper.balance;

        warpPastCooldown(clone);
        _acquire(player, 1);
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "listed track waits while busy");
        vm.prank(keeper);
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
        assertEq(pool.maintenance(), maintenanceBefore, "no refund");
        assertEq(keeper.balance, keeperBefore, "keeper unpaid");
        assertEq(pool.lastRotateAt(), lastBefore, "interval keeps running");
    }

    function test_aQueuedReplacementThatCashCannotFundDoesNotMakeRotateDue() public {
        _openReady();
        uint256[] memory ids = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(0, 0));
        pool.loseCash(pool.cash());
        pool.settle(20);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(pool.replacementLength(), 1, "replacement waits for cash");
        _warpToRotation();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.None));
        vm.expectRevert(IPoolTypes.RotateNotDue.selector);
        pool.rotate();
    }

    function test_rotateRefundIsCappedByMaintenance() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        _warpInterval();
        pool.setMaintenance(1_000);
        vm.deal(address(pool), address(pool).balance + 1_000);

        Liq memory s = _rotateAsKeeper();

        assertGt(s.count, 0, "liquidated");
        assertEq(s.refund, 1_000, "refund is the whole bucket");
        assertEq(pool.maintenance(), 0, "bucket empty, never negative");
        assertEq(keeper.balance, 1_000);
        _assertI1();
    }

    // ---------------------------------------------------------------- liquidation

    function test_rotateLiquidatesShapesAndPacksForTheHeadClaim() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256 balanceBefore = exiter.balance;
        uint256 queued = _exiterLeaves();
        uint256 paidNow = exiter.balance - balanceBefore;
        assertEq(paidNow, 0.3 ether);
        _warpInterval();
        uint256 backingBefore = pool.backing();

        Liq memory s = _rotateAsKeeper();

        assertGt(s.shapeCount, 0, "Shape path");
        assertGt(s.packCount, 0, "pack path");
        assertEq(s.fees, mintFee * (s.shapeCount + 2 * s.packCount), "fee is mintFee per Shape redeemed");
        assertEq(s.value, s.shapeCount * 0.1 ether + s.packCount * 0.02 ether);
        assertEq(exiter.balance - balanceBefore - paidNow, queued - s.fees, "exiting depositor bears the fees");
        assertEq(s.paid, queued - s.fees);
        assertEq(pool.claims(), 0);
        assertEq(pool.claimHead(), 1);
        assertEq(pool.lastRotateAt(), block.timestamp, "inventory changed");
        assertLe(pool.backing(), backingBefore - s.value + 10 * 0.1 ether, "backing fell by the redeemed items");
        _assertRegistry();
        _assertI1();
    }

    function test_rotateTakesFromTheMostOverweightRowFirst() public {
        _openReady();
        // Board 7 Shapes + 3 packs: both rows sit at their share, the tie goes to row 0. After a
        // Shape leaves, row 1 is the most overweight.
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        _warpInterval();
        vm.recordLogs();
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory values = new uint256[](10);
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Liquidated.selector) {
                (values[n],) = abi.decode(logs[i].data, (uint256, uint256));
                ++n;
            }
        }
        assertGe(n, 2);
        assertEq(values[0], 0.1 ether, "tie goes to row 0");
        assertEq(values[1], 0.02 ether, "then the pack row is overweight");
    }

    function test_rotateLiquidationIsBoundedByMaxLiquidateItems() public {
        _openLarge();
        _drainCash(400 ether, 0.3 ether);
        uint256 queued = _exiterLeaves();
        vm.deal(saver, 1 ether);
        vm.prank(saver);
        pool.deposit{value: 0.2 ether}();
        _warpInterval();
        uint256 listedBefore = pool.listedCount();

        Liq memory s = _rotateAsKeeper();

        assertEq(s.count, 25, "exactly MAX_LIQUIDATE_ITEMS");
        assertEq(pool.listedCount(), listedBefore - 25);
        assertLt(s.firstPaidAt, s.firstLiqAt, "cash pays before any item is liquidated");
        assertEq(pool.claimHead(), 0, "head claim still open");
        (,, uint256 headAmount) = IPool(address(pool)).claimQueue(0);
        assertEq(headAmount, pool.claims());
        assertEq(pool.claims(), queued - s.paid - s.fees, "claims fell by payouts and fees");
        assertEq(pool.cash(), 0);
        assertEq(s.refund, 0, "maintenance is empty");
        _assertRegistry();
        _assertI1();
    }

    function test_rotateNeedsNoItemsWhenCashCoversTheClaim() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.deal(saver, 5 ether);
        vm.prank(saver);
        pool.deposit{value: 5 ether}();
        _warpInterval();
        uint256 listedBefore = pool.listedCount();
        assertEq(uint8(pool.rotateDue()), uint8(IPoolTypes.RotateTrigger.Claim));

        Liq memory s = _rotateAsKeeper();

        assertEq(s.count, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.claims(), 0);
    }

    function test_rotateInsideTheSpacingRevertsAndPayClaimsPaysFromCash() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256 queued = _exiterLeaves();
        vm.deal(saver, 1 ether);
        vm.prank(saver);
        pool.deposit{value: 0.2 ether}();
        uint256 cashBefore = pool.cash();
        assertGt(cashBefore, 0);
        _warpInterval();
        // A restart of the spacing after the head claim became due.
        pool.setLastRotateAt(block.timestamp);
        uint256 rotatedAt = pool.lastRotateAt();
        uint256 listedBefore = pool.listedCount();

        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
        pool.payClaims();

        assertEq(pool.cash(), 0, "cash paid the head claim");
        assertEq(pool.claims(), queued - cashBefore, "claims fell by the cash payment only");
        assertEq(pool.listedCount(), listedBefore, "no FWA withdrawal inside the spacing");
        assertEq(pool.lastRotateAt(), rotatedAt);
        _assertRegistry();
        _assertI1();

        _warpInterval();
        pool.rotate();

        assertLt(pool.listedCount(), listedBefore, "withdraws once the spacing has passed");
        assertEq(pool.lastRotateAt(), block.timestamp, "the withdrawal restarts the spacing");
        _assertRegistry();
        _assertI1();
    }

    function test_unsettledAcquisitionLocksLiquidationUntilFulfilment() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256[] memory ids = _acquire(player, 1);
        uint256 queued = _exiterLeaves();
        _warpInterval();
        assertEq(clone.unsettledAcquisitionCount(), 1);
        uint256 lastBefore = pool.lastRotateAt();
        uint256 resumeBefore = clone.purchasesResumeAt();

        Liq memory locked = _rotateAsKeeper();

        assertEq(locked.count, 0, "FWA withdrawals are locked");
        assertEq(pool.listedCount(), 10);
        assertEq(pool.claims(), queued, "nothing to pay from cash");
        assertEq(pool.lastRotateAt(), lastBefore, "no inventory change");
        assertEq(clone.purchasesResumeAt(), resumeBefore, "the FWA pause did not restart");

        _capture(ids[0], _listingOfRow(1, 0));
        Liq memory open_ = _rotateAsKeeper();

        assertEq(clone.unsettledAcquisitionCount(), 0);
        assertGt(open_.count, 0, "liquidates once the lock lifts");
        assertEq(pool.claims(), 0);
        _assertRegistry();
        _assertI1();
    }
}
