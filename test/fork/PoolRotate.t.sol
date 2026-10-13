// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Pool} from "../../src/Pool.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice `rotate` and `liquidate` against deployed Shapes, a Draw Packs deployment and a FWA
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

    function _openLarge() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(pool.openingDeadlineAt());
        pool.recordPulls(60);
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

    function _pullAs(address who, uint256 count) internal returns (uint256[] memory ids) {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(count);
        vm.deal(who, who.balance + total);
        uint64 last = clone.lastIssuedSequence();
        vm.prank(who);
        pool.pull{value: total}(count, fee, block.timestamp + 1 hours);
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = clone.requestIdAtSequence(last + 1 + uint64(i));
        }
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
        (uint256 minorBucket,,,,,,,,,,,) = pool.grail(0);
        (uint256 majorBucket,,,,,,,,,,,) = pool.grail(1);
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
            assertEq(pool.rowCount(r), perRow[r] + heldOfRow, "rowCount");
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

    function _liquidateAsKeeper() internal returns (Liq memory s) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.liquidate();
        s = _summarize(vm.getRecordedLogs());
    }

    // ---------------------------------------------------------------- guards

    function test_revert_rotateWhileOpening() public {
        vm.expectRevert(IPoolTypes.NotLive.selector);
        pool.rotate();
    }

    function test_revert_rotateBeforeTheInterval() public {
        _openReady();
        assertEq(pool.lastRotateAt(), pool.openingDeadlineAt(), "open sets lastRotateAt");
        vm.warp(pool.lastRotateAt() + pool.rotateInterval() - 1);
        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        pool.rotate();
    }

    function test_rotateIgnoresPauseFlags() public {
        _openReady();
        pool.setPullsPaused(true);
        pool.pauseDeposits();
        _warpToRotation();
        pool.rotate();
    }

    // ---------------------------------------------------------------- rotate

    function test_rotateSettlesHarvestsRestocksListsAndRefunds() public {
        _openReady();
        uint256[] memory ids = _pullAs(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        assertEq(pool.listedCount(), 10);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();

        uint256 maintenanceBefore = pool.maintenance();
        assertEq(pool.nextSequenceToBook(), 1, "capture not booked");

        Liq memory s = _rotateAsKeeper();

        assertEq(pool.nextSequenceToBook(), 2, "rotate booked the capture");
        assertEq(pool.receivable(), 0, "harvested");
        assertEq(pool.maintenanceReceivable(), 0, "harvested");
        assertEq(pool.replacementLength(), 0, "replacement minted");
        assertEq(pool.heldCount(), 0, "board listed");
        assertEq(pool.listedCount(), 10);
        assertEq(pool.rowCount(1), 3);
        assertEq(pool.lastRotateAt(), block.timestamp);
        assertTrue(s.rotated);

        uint256 maintenanceAfter = pool.maintenance();
        assertGt(s.maintenanceShare, 0, "pack capture booked a maintenance share");
        assertEq(maintenanceBefore + s.maintenanceShare - maintenanceAfter, s.refund, "maintenance fell by the refund");
        assertGt(s.refund, 0);
        assertGe(s.refund, 0.0005 ether, "refund covers the tip");
        assertLe(s.refund, maintenanceBefore + s.maintenanceShare);
        assertEq(keeper.balance, s.refund, "caller received the refund");
        _assertRegistry();
        _assertI1();

        vm.expectRevert(IPoolTypes.RotateTooSoon.selector);
        pool.rotate();
    }

    function test_rotateWithNothingToDoPaysNoRefund() public {
        _openReady();
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();
        uint256 lastBefore = pool.lastRotateAt();

        vm.recordLogs();
        vm.prank(keeper);
        pool.rotate();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "only Rotated");
        (bool changed, bool inventoryChanged, uint256 refund) = abi.decode(logs[0].data, (bool, bool, uint256));
        assertFalse(changed);
        assertFalse(inventoryChanged);
        assertEq(refund, 0);
        assertEq(pool.maintenance(), 1 ether);
        assertEq(keeper.balance, 0);
        assertEq(pool.lastRotateAt(), lastBefore, "interval keeps running");
    }

    function test_rotateAfterHarvestOnlyKeepsLastRotateAt() public {
        _openReady();
        uint256[] memory ids = _pullAs(player, 1);
        _capture(ids[0], _listingOfRow(0, 0));
        // The Shape capture returns less than the replacement costs, and cash is empty.
        pool.loseCash(pool.cash());
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
        _warpToRotation();
        uint256 lastBefore = pool.lastRotateAt();

        Liq memory s = _rotateAsKeeper();

        assertEq(pool.nextSequenceToBook(), 2);
        assertGt(s.refund, 0, "booking a capture changes state");
        assertEq(pool.lastRotateAt(), lastBefore, "inventory unchanged");
        assertEq(pool.replacementLength(), 1, "replacement waits for cash");
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

    function test_liquidateIsBoundedByMaxLiquidateItems() public {
        _openLarge();
        _drainCash(400 ether, 0.3 ether);
        uint256 queued = _exiterLeaves();
        vm.deal(saver, 1 ether);
        vm.prank(saver);
        pool.deposit{value: 0.2 ether}();
        _warpInterval();
        uint256 listedBefore = pool.listedCount();

        Liq memory s = _liquidateAsKeeper();

        assertEq(s.count, 10, "exactly MAX_LIQUIDATE_ITEMS");
        assertEq(pool.listedCount(), listedBefore - 10);
        assertLt(s.firstPaidAt, s.firstLiqAt, "cash pays before any item is liquidated");
        assertEq(pool.claimHead(), 0, "head claim still open");
        (,, uint256 headAmount) = pool.claimQueue(0);
        assertEq(headAmount, pool.claims());
        assertEq(pool.claims(), queued - s.paid - s.fees, "claims fell by payouts and fees");
        assertEq(pool.cash(), 0);
        assertEq(s.refund, 0, "liquidate pays no refund");
        _assertRegistry();
        _assertI1();
    }

    function test_revert_liquidateBeforeTheInterval() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.warp(block.timestamp + pool.rotateInterval() - 1);
        vm.expectRevert(IPoolTypes.ClaimNotDue.selector);
        pool.liquidate();
        vm.warp(block.timestamp + 1);
        pool.liquidate();
        assertEq(pool.claims(), 0);
    }

    function test_liquidateNeedsNoItemsWhenCashCoversTheClaim() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        _exiterLeaves();
        vm.deal(saver, 5 ether);
        vm.prank(saver);
        pool.deposit{value: 5 ether}();
        _warpInterval();
        uint256 listedBefore = pool.listedCount();

        Liq memory s = _liquidateAsKeeper();

        assertEq(s.count, 0);
        assertEq(pool.listedCount(), listedBefore);
        assertEq(pool.claims(), 0);
    }

    function test_liquidateInsideTheRotateIntervalPaysFromCashAndWithdrawsNothing() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256 queued = _exiterLeaves();
        vm.deal(saver, 1 ether);
        vm.prank(saver);
        pool.deposit{value: 0.2 ether}();
        uint256 cashBefore = pool.cash();
        assertGt(cashBefore, 0);
        _warpInterval();
        // A restart of the interval after the head claim became due.
        pool.setLastRotateAt(block.timestamp);
        uint256 rotatedAt = pool.lastRotateAt();
        uint256 listedBefore = pool.listedCount();

        pool.liquidate();

        assertEq(pool.cash(), 0, "cash paid the head claim");
        assertEq(pool.claims(), queued - cashBefore, "claims fell by the cash payment only");
        assertEq(pool.listedCount(), listedBefore, "no FWA withdrawal inside the interval");
        assertEq(pool.lastRotateAt(), rotatedAt);
        _assertRegistry();
        _assertI1();

        _warpInterval();
        pool.liquidate();

        assertLt(pool.listedCount(), listedBefore, "withdraws once the interval has passed");
        assertEq(pool.lastRotateAt(), block.timestamp, "the withdrawal restarts the interval");
        _assertRegistry();
        _assertI1();
    }

    function test_unsettledAcquisitionLocksLiquidationUntilFulfilment() public {
        _openReady();
        _drainCash(400 ether, 0.3 ether);
        uint256[] memory ids = _pullAs(player, 1);
        uint256 queued = _exiterLeaves();
        _warpInterval();
        assertEq(clone.unsettledAcquisitionCount(), 1);

        Liq memory locked = _liquidateAsKeeper();

        assertEq(locked.count, 0, "FWA withdrawals are locked");
        assertEq(pool.listedCount(), 10);
        assertEq(pool.claims(), queued, "nothing to pay from cash");

        _capture(ids[0], _listingOfRow(1, 0));
        Liq memory open_ = _liquidateAsKeeper();

        assertEq(clone.unsettledAcquisitionCount(), 0);
        assertGt(open_.count, 0, "liquidates once the lock lifts");
        assertEq(pool.claims(), 0);
        _assertRegistry();
        _assertI1();
    }
}
