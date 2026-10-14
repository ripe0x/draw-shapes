// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @dev Contract purchaser without `onERC721Received`.
contract NoReceiver {
    function acquire(Pool pool, uint256 maxFee, uint256 slippageBps, uint256 version, uint256 deadline)
        external
        payable
    {
        pool.acquireBatch{value: msg.value}(address(this), 1, maxFee, 0, slippageBps, version, deadline);
    }
}

/// @notice `_splitMargin` against round numbers. Fee split 200 : 100 : 400 bps.
contract PoolSplitMarginTest is PoolFixture {
    PoolHarness internal pool;

    function setUp() public {
        pool = _deploy(_params());
    }

    function test_splitMarginCoversMintLineThenSplitsPro_rata() public {
        pool.setReceivable(1.1 ether);
        pool.setMargin(1.1 ether);
        pool.setMintLineOwed(0.4 ether);

        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.MarginSplit(0.4 ether, 0.2 ether, 0.1 ether, 0.4 ether);
        pool.splitMargin();

        assertEq(IPool(address(pool)).margin(), 0);
        assertEq(IPool(address(pool)).mintLineOwed(), 0);
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0.1 ether);
        assertEq(pool.grailReceivable(), 0.4 ether);
        assertEq(pool.receivable(), 1.1 ether - 0.5 ether);
    }

    function test_splitMarginPartlyCoversMintLine() public {
        pool.setReceivable(0.3 ether);
        pool.setMargin(0.3 ether);
        pool.setMintLineOwed(1 ether);
        pool.splitMargin();
        assertEq(IPool(address(pool)).mintLineOwed(), 0.7 ether);
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0);
        assertEq(pool.receivable(), 0.3 ether);
        assertEq(IPool(address(pool)).margin(), 0);
    }

    function test_splitMarginKeepsNegativeMargin() public {
        pool.setMargin(-1 ether);
        pool.setMintLineOwed(0.1 ether);
        pool.splitMargin();
        assertEq(IPool(address(pool)).margin(), -1 ether);
        assertEq(IPool(address(pool)).mintLineOwed(), 0.1 ether);
    }
}

/// @notice Pulls, settlement, harvest, Shapes redemption paths and reopen guards against deployed
///         Shapes, a Draw Packs deployment and a FWA clone created by the pool.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). A 100 ETH deposit builds a board of 7 + 3 items. Listing ids 1 to 3
///      are row 1 and 4 to 10 are row 0.
contract PoolPullForkTest is ForkBase, PoolFixture {
    uint256 internal constant MAINT_BPS = 100;
    uint256 internal constant FEED_BPS = 400;
    uint256 internal constant SPLIT_BPS = 700;

    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    /// @dev Depositor and claimant. `bob` from `PoolFixture` has code on mainnet that forwards ETH.
    address internal saver = makeAddr("saver");
    uint256 internal mintFee;

    /// @dev Expected `Pool` margin state, advanced one capture at a time.
    struct Book {
        uint256 receivable;
        int256 margin;
        uint256 mintLineOwed;
        uint256 maintenanceReceivable;
        uint256 grailReceivable;
    }

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
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Clears the purchase operator of the FWA pool from the pool (its owner), the state `adminCall` can produce, so a wallet
    ///      can acquire from the FWA pool directly and the walk books unrecorded captures.
    function _gateOff() internal {
        vm.prank(address(pool));
        clone.setPurchaseOperator(address(0));
    }

    function _open(uint256 depositWei) internal {
        vm.prank(alice);
        pool.deposit{value: depositWei}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
    }

    function _openReady() internal {
        _open(100 ether);
        warpPastCooldown(clone);
    }

    /// @dev Board of 60 items (42 Shapes, 18 packs). The 10 item board of `_openReady` moves FWA's fee
    ///      by more than the 10% slippage tolerance when two cheap items are captured in one batch.
    function _openLarge() internal {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.sizeBoard(60);
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
        assertEq(pool.listedCount(), 60);
        warpPastCooldown(clone);
    }

    /// @dev FWA base price a request opened now records.
    function _expectedBase(uint256 fee) internal view returns (uint256 base) {
        base = clone.weightedBackingTotal() / clone.totalWeight();
        if (base > fee) base = fee;
    }

    function _proceeds(uint256 paid, uint256 base) internal pure returns (uint256) {
        return paid - (paid - base) / 2;
    }

    /// @dev Pulls `count` through the pool as `who`. Returns the request ids, the per-request fee
    ///      and the base price computed from FWA reads before the call.
    function _acquire(address who, uint256 count) internal returns (uint256[] memory ids, uint256 fee, uint256 base) {
        uint256 total;
        (fee,, total) = clone.quoteAcquisitionPrice(count);
        base = _expectedBase(fee);
        vm.deal(who, who.balance + total);
        uint64 last = clone.lastIssuedSequence();
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.prank(who);
        pool.acquireBatch{value: total}(who, count, fee, 0, slip, version, block.timestamp + 1 hours);
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

    /// @dev Delivers the word that selects `listingId` and checks the request ended Fulfilled.
    function _capture(uint256 requestId, uint256 listingId) internal {
        fulfill(clone, requestId, wordFor(clone, listingId));
        (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Fulfilled), "request not fulfilled");
    }

    function _rungs(uint256 row) internal pure returns (uint256) {
        return row == 0 ? 1 : 2;
    }

    /// @dev Applies one capture to `b` with the settlement rules of `Pool._bookCapture`.
    function _apply(Book memory b, uint256 proceeds, uint256 value, uint256 row) internal view {
        b.receivable += proceeds;
        b.margin += int256(proceeds) - int256(value);
        b.mintLineOwed += mintFee * _rungs(row);
        if (b.margin <= 0) return;
        uint256 amount = uint256(b.margin);
        uint256 cover = amount < b.mintLineOwed ? amount : b.mintLineOwed;
        b.mintLineOwed -= cover;
        uint256 rest = amount - cover;
        uint256 maintenanceShare = rest * MAINT_BPS / SPLIT_BPS;
        uint256 feedShare = rest * FEED_BPS / SPLIT_BPS;
        b.receivable -= maintenanceShare + feedShare;
        b.maintenanceReceivable += maintenanceShare;
        b.grailReceivable += feedShare;
        b.margin = 0;
    }

    function _assertBook(Book memory b) internal view {
        assertEq(pool.receivable(), b.receivable, "receivable");
        assertEq(IPool(address(pool)).margin(), b.margin, "margin");
        assertEq(IPool(address(pool)).mintLineOwed(), b.mintLineOwed, "mintLineOwed");
        assertEq(IPool(address(pool)).maintenanceReceivable(), b.maintenanceReceivable, "maintenanceReceivable");
        assertEq(pool.grailReceivable(), b.grailReceivable, "grail receivable");
    }

    function _grailFund() internal view returns (uint256) {
        return IPool(address(pool)).grail().fund;
    }

    function _assertI1() internal view {
        assertGe(address(pool).balance, pool.cash() + pool.maintenance() + _grailFund(), "I1");
    }

    /// @dev Sum of listed and held item values.
    function _registryValue() internal view returns (uint256 sum) {
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            sum += pool.listedItem(id).value;
        }
        for (uint256 i; i < pool.heldCount(); ++i) {
            sum += pool.heldItem(i).value;
        }
    }

    // ---------------------------------------------------------------- pull and settle

    function test_pullSingleCaptureOfShapeBooksNegativeMargin() public {
        _openReady();
        uint256 listingId = _listingOfRow(0, 0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        uint256 backingBefore = pool.backing();
        uint256 cashBefore = pool.cash();

        vm.recordLogs();
        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics[0] != IPoolTypes.Pulled.selector) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), player);
            (uint256 count, uint256 loggedFee, uint256[] memory loggedIds) =
                abi.decode(logs[i].data, (uint256, uint256, uint256[]));
            assertEq(count, 1);
            assertEq(loggedFee, fee);
            assertEq(loggedIds.length, 1);
            assertEq(loggedIds[0], ids[0]);
        }
        assertTrue(found, "Pulled");

        (uint256 recordedBase, bool recorded) = pool.baseOf(ids[0]);
        assertTrue(recorded);
        assertEq(recordedBase, base);
        assertEq(pool.backing(), backingBefore);

        _capture(ids[0], listingId);
        uint256 proceeds = _proceeds(fee, base);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.Captured(ids[0], listingId, 0, it.value, proceeds);
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.Booked(2);
        pool.bookOnly(5);

        assertEq(pool.backing(), backingBefore - it.value, "backing");
        assertEq(pool.listedItem(listingId).value, 0, "unlisted");
        assertEq(IPool(address(pool)).rowCount(0), 6);
        assertEq(pool.listedCount(), 9);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(pool.replacementLength(), 1);
        assertEq(IPool(address(pool)).replacementQueue(0), 0);
        assertEq(pool.cash(), cashBefore, "cash untouched by settle");
        assertLt(proceeds, it.value, "row 0 capture is a loss");

        Book memory b;
        _apply(b, proceeds, it.value, 0);
        assertEq(b.receivable, proceeds);
        assertEq(b.margin, int256(proceeds) - int256(it.value));
        assertEq(b.mintLineOwed, mintFee);
        _assertBook(b);
        assertEq(pool.backing(), _registryValue(), "I2");
        _assertI1();
    }

    function test_pullSingleCaptureOfPackSplitsPositiveMargin() public {
        _openReady();
        uint256 listingId = _listingOfRow(1, 0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);

        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 1);
        _capture(ids[0], listingId);
        uint256 proceeds = _proceeds(fee, base);
        assertGt(proceeds, it.value, "row 1 capture is a gain");

        uint256 amount = proceeds - it.value;
        uint256 cover = amount < 2 * mintFee ? amount : 2 * mintFee;
        uint256 rest = amount - cover;
        uint256 maintenanceShare = rest * MAINT_BPS / SPLIT_BPS;
        uint256 feedShare = rest * FEED_BPS / SPLIT_BPS;

        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.MarginSplit(cover, rest - maintenanceShare - feedShare, maintenanceShare, feedShare);
        pool.bookOnly(5);

        Book memory b;
        _apply(b, proceeds, it.value, 1);
        assertEq(b.margin, 0);
        assertEq(b.mintLineOwed, 2 * mintFee - cover);
        assertEq(b.maintenanceReceivable, maintenanceShare);
        assertEq(b.grailReceivable, feedShare);
        assertEq(b.receivable, proceeds - maintenanceShare - feedShare);
        _assertBook(b);
    }

    function test_pullBatchOfThreeNetsMarginAcrossCaptures() public {
        _openLarge();
        // Shape, pack, pack. The Shape loss carries until the second pack repays it.
        uint256[3] memory listingIds = [_listingOfRow(0, 0), _listingOfRow(1, 0), _listingOfRow(1, 1)];
        uint256[3] memory rowOf = [uint256(0), 1, 1];

        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 3);
        assertEq(ids.length, 3);
        for (uint256 i; i < 3; ++i) {
            (uint256 recordedBase, bool recorded) = pool.baseOf(ids[i]);
            assertTrue(recorded);
            assertEq(recordedBase, base, "same base across the batch");
            _capture(ids[i], listingIds[i]);
        }

        uint256 proceeds = _proceeds(fee, base);
        Book memory b;
        uint256 valueSum;
        for (uint256 i; i < 3; ++i) {
            uint256 value = pool.listedItem(listingIds[i]).value;
            valueSum += value;
            _apply(b, proceeds, value, rowOf[i]);
            if (i < 2) assertLt(b.margin, 0, "margin carries");
        }
        assertEq(b.margin, 0, "second pack repays the loss and splits the rest");
        assertGt(b.maintenanceReceivable, 0);
        uint256 backingBefore = pool.backing();
        pool.bookOnly(10);

        assertEq(pool.backing(), backingBefore - valueSum);
        assertEq(pool.nextSequenceToBook(), 4);
        assertEq(pool.replacementLength(), 3);
        _assertBook(b);
        assertEq(pool.backing(), _registryValue(), "I2");
        _assertI1();
    }

    function test_settleBudgetBoundsTheWalk() public {
        _openLarge();
        (uint256[] memory ids,,) = _acquire(player, 3);
        _capture(ids[0], _listingOfRow(1, 0));
        _capture(ids[1], _listingOfRow(1, 1));
        _capture(ids[2], _listingOfRow(1, 2));

        pool.bookOnly(2);
        assertEq(pool.nextSequenceToBook(), 3);
        pool.bookOnly(2);
        assertEq(pool.nextSequenceToBook(), 4);
        pool.bookOnly(2);
        assertEq(pool.nextSequenceToBook(), 4);
    }

    function test_harvestMatchesOwnerProceedsAndCreditsBuckets() public {
        _openLarge();
        uint256[3] memory listingIds = [_listingOfRow(1, 0), _listingOfRow(0, 0), _listingOfRow(1, 1)];
        uint256[3] memory rowOf = [uint256(1), 0, 1];
        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 3);
        Book memory b;
        for (uint256 i; i < 3; ++i) {
            _apply(b, _proceeds(fee, base), pool.listedItem(listingIds[i]).value, rowOf[i]);
            _capture(ids[i], listingIds[i]);
        }
        pool.bookOnly(10);

        uint256 owed = clone.ownerProceeds();
        assertEq(owed, 3 * _proceeds(fee, base), "FWA owner proceeds");
        assertEq(b.receivable + b.maintenanceReceivable + b.grailReceivable, owed);
        uint256 cashBefore = pool.cash();
        uint256 balanceBefore = address(pool).balance;
        uint256 fundBefore = _grailFund();

        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.Harvested(owed, 0);
        assertTrue(pool.harvest());

        assertEq(address(pool).balance, balanceBefore + owed);
        assertEq(clone.ownerProceeds(), 0);
        assertEq(pool.cash(), cashBefore + b.receivable);
        assertEq(pool.maintenance(), b.maintenanceReceivable);
        assertEq(_grailFund() - fundBefore, b.grailReceivable);
        assertEq(pool.receivable(), 0);
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0);
        assertEq(pool.grailReceivable(), 0);
        assertEq(IPool(address(pool)).margin(), b.margin);
        _assertI1();
        assertFalse(pool.harvest(), "nothing left to harvest");
    }

    function test_harvestWaitsForTheBookingWalk() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        assertGt(clone.ownerProceeds(), 0);

        assertFalse(pool.harvest(), "walk is behind FWA");
        assertGt(clone.ownerProceeds(), 0);

        pool.bookOnly(5);
        assertTrue(pool.harvest());
        assertEq(clone.ownerProceeds(), 0);
    }

    /// @dev Books one pack capture, then raises the booked receivables by the amounts given so that
    ///      `ownerProceeds` falls short of them by their sum.
    function _shortfallFixture(uint256 ordinary, uint256 maintenanceWei, uint256 grailWei)
        internal
        returns (uint256 owed, uint256 expected)
    {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.bookOnly(5);
        owed = clone.ownerProceeds();
        pool.addReceivables(ordinary, maintenanceWei, grailWei);
        expected = pool.receivable() + IPool(address(pool)).maintenanceReceivable() + pool.grailReceivable();
        assertEq(expected - owed, ordinary + maintenanceWei + grailWei);
    }

    function test_harvestShortfallWritesDownOrdinaryReceivable() public {
        (uint256 owed, uint256 expected) = _shortfallFixture(7, 0, 0);
        uint256 cashBefore = pool.cash();
        uint256 receivableBefore = pool.receivable();
        uint256 maintenanceBefore = IPool(address(pool)).maintenanceReceivable();
        uint256 fundBefore = _grailFund();
        uint256 grailR = pool.grailReceivable();

        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.HarvestShortfall(owed, expected);
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.Harvested(owed, 0);
        assertTrue(pool.harvest());

        assertEq(pool.cash(), cashBefore + receivableBefore - 7, "ordinary receivable written down by the gap");
        assertEq(pool.maintenance(), maintenanceBefore);
        assertEq(_grailFund() - fundBefore, grailR);
        assertEq(pool.receivable(), 0);
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0);
        assertEq(pool.grailReceivable(), 0);
        assertEq(clone.ownerProceeds(), 0);
        _assertI1();
    }

    function test_harvestShortfallSpillsIntoMaintenanceReceivable() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.bookOnly(5);
        uint256 ordinary = pool.receivable();
        uint256 maintenanceR = IPool(address(pool)).maintenanceReceivable();
        pool.addReceivables(0, ordinary + 5, 0);
        uint256 cashBefore = pool.cash();
        uint256 maintenanceBefore = pool.maintenance();

        assertTrue(pool.harvest());

        assertEq(pool.cash(), cashBefore, "ordinary receivable written down to zero");
        assertEq(pool.maintenance(), maintenanceBefore + maintenanceR + ordinary, "5 wei taken from maintenance");
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0);
        _assertI1();
    }

    function test_harvestShortfallSpillsIntoGrailReceivables() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.bookOnly(5);
        uint256 ordinary = pool.receivable();
        uint256 maintenanceR = IPool(address(pool)).maintenanceReceivable();
        uint256 grailR = pool.grailReceivable();
        assertGt(grailR, 3);
        pool.addReceivables(0, 0, ordinary + maintenanceR + 3);
        uint256 cashBefore = pool.cash();
        uint256 maintenanceBefore = pool.maintenance();
        uint256 fundBefore = _grailFund();

        assertTrue(pool.harvest());

        assertEq(pool.cash(), cashBefore);
        assertEq(pool.maintenance(), maintenanceBefore);
        assertEq(_grailFund() - fundBefore, grailR + ordinary + maintenanceR, "the shortfall is cut from the GRAIL receivable last");
        _assertI1();
    }

    function test_withdrawCompletesThroughHarvestShortfall() public {
        (uint256 owed, uint256 expected) = _shortfallFixture(1, 0, 0);
        uint256 shares = pool.sharesOf(alice);
        uint256 supply = pool.totalShares();

        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.HarvestShortfall(owed, expected);
        vm.expectEmit(true, false, false, false, address(pool));
        emit IPoolTypes.Withdrawn(alice, 0, 0, 0);
        vm.prank(alice);
        pool.withdraw(shares / 2);

        assertEq(pool.totalShares(), supply - shares / 2);
        assertEq(pool.receivable(), 0, "harvested");
        assertEq(clone.ownerProceeds(), 0);
        _assertI1();
    }

    function test_walkPassesAnUnhandledStatusAndSettleClearsTheLag() public {
        _openReady();
        // Sequence 0 never exists at FWA, so its status is None.
        pool.setNextSequenceToBook(0);
        assertLt(pool.nextSequenceToBook(), clone.nextSequenceToProcess());

        vm.recordLogs();
        vm.prank(bob);
        pool.settle(5);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 poolEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            ++poolEvents;
            assertTrue(
                logs[i].topics[0] == IPoolTypes.Booked.selector || logs[i].topics[0] == IPoolTypes.Settled.selector,
                "only Booked and Settled"
            );
        }
        assertEq(poolEvents, 2);
        assertEq(pool.nextSequenceToBook(), clone.nextSequenceToProcess());
        assertEq(pool.backing(), _registryValue(), "I2");
        _assertI1();
    }

    function test_syncClearsALaggingWalkWithoutBooksBehind() public {
        _openReady();
        pool.setNextSequenceToBook(0);
        vm.prank(alice);
        pool.deposit{value: 1 ether}();
        assertEq(pool.nextSequenceToBook(), clone.nextSequenceToProcess());
    }

    function test_upkeepSliceBooksHarvestsAndQueuesTheReplacement() public {
        _openReady();
        uint256 listingId = _listingOfRow(0, 0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 1);
        _capture(ids[0], listingId);
        assertEq(pool.nextSequenceToBook(), 1, "pool has not booked yet");

        uint256 cashBefore = pool.cash();
        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.Captured(ids[0], listingId, 0, it.value, _proceeds(fee, base));
        _acquire(player, 1);

        assertEq(pool.nextSequenceToBook(), 2, "slice booked the capture");
        assertEq(pool.replacementLength(), 1, "slice queued the replacement");
        assertEq(pool.heldCount(), 0, "the slice mints and lists nothing");
        assertEq(pool.receivable(), 0, "slice harvested the proceeds");
        assertEq(pool.cash(), cashBefore + _proceeds(fee, base), "cash took the proceeds and paid no mint");
        assertEq(pool.backing(), _registryValue(), "I2");
        _assertI1();
    }

    function test_upkeepSliceNeverMintsWhateverTheCash() public {
        _openLarge();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(0, 0));
        pool.bookOnly(5);
        assertEq(pool.replacementLength(), 1);

        // The slice harvests the capture's proceeds (about 0.05 ETH) before it prices the mint.
        pool.spendOnBacking(pool.cash() - 0.01 ether);
        _acquire(player, 1);
        assertEq(pool.replacementLength(), 1);
        assertEq(pool.heldCount(), 0);
    }

    function test_listingWhileUnsettledStagesAndStartsTheCooldown() public {
        _openReady();
        _acquire(player, 1);
        assertEq(clone.unsettledAcquisitionCount(), 1);

        uint256 tokenId = mintShapes(address(pool), 0.1 ether, 1);
        pool.addItem(SHAPES_ADDR, 0, tokenId, 0.1 ether, 0);
        uint256 versionBefore = clone.inventoryVersion();
        assertEq(pool.restock(), 1);

        (,,,,,,, IFWAClone.ListingStatus status) = clone.listings(pool.listedItem(clone.nextListingId() - 1).listingId);
        assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Staged));
        assertEq(clone.inventoryVersion(), versionBefore + 1);
        assertEq(clone.lastInventoryChangeAt(), block.timestamp);
        assertGt(clone.purchasesResumeAt(), block.timestamp);
    }

    // ---------------------------------------------------------------- direct purchases

    function test_directAcquireBooksValueAndSurplusAtSettle() public {
        _openReady();
        uint256 listingId = _listingOfRow(0, 0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        uint256 navBefore = pool.nav();

        _gateOff();
        uint256 requestId = acquireAs(alice, bob, clone, block.timestamp + 1 hours);
        (, bool recorded) = pool.baseOf(requestId);
        assertFalse(recorded);
        uint256 paid = clone.acquisitionFee();
        _capture(requestId, listingId);
        uint256 owed = clone.ownerProceeds();
        assertGt(owed, 0);
        assertLt(owed, paid + 1);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.Captured(requestId, listingId, 0, it.value, 0);
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.SurplusBooked(owed);
        pool.bookOnly(5);

        assertEq(pool.backing(), _registryValue(), "I2");
        assertEq(pool.receivable(), owed, "surplus booked at settle");
        assertEq(IPool(address(pool)).margin(), int256(owed) - int256(it.value), "surplus repays the margin");
        assertLt(IPool(address(pool)).margin(), 0);
        assertEq(pool.replacementLength(), 1);
        assertEq(pool.nav(), navBefore - it.value + owed, "nav carries the proceeds");

        uint256 cashBefore = pool.cash();
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.Harvested(owed, 0);
        assertTrue(pool.harvest());
        assertEq(pool.cash(), cashBefore + owed);
        assertEq(pool.receivable(), 0);
        assertEq(IPool(address(pool)).maintenanceReceivable(), 0);
        assertEq(pool.nav(), navBefore - it.value + owed, "harvest moves receivable to cash");
        _assertI1();
    }

    function test_directAcquireAdvancesPullsSinceListOfAListedGrail() public {
        _openReady();
        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        assertTrue(pool.stepGrail());
        warpPastCooldown(clone);
        IPoolTypes.GrailItem memory before = IPool(address(pool)).grailItems()[0];
        assertEq(before.pullsSinceList, 0);
        assertTrue(before.listingId != 0);

        _gateOff();
        uint256 requestId = acquireAs(alice, bob, clone, block.timestamp + 1 hours);
        _capture(requestId, _listingOfRow(0, 0));
        pool.bookOnly(5);

        assertEq(IPool(address(pool)).grailItems()[0].pullsSinceList, 1);
    }

    function test_poolPullIsBookedOnce() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        assertEq(pool.nextSequenceToBook(), 1, "not booked at request time");
        _capture(ids[0], _listingOfRow(0, 0));
        pool.bookOnly(5);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(pool.replacementLength(), 1);
        pool.bookOnly(5);
        assertEq(pool.nextSequenceToBook(), 2, "a booked sequence is not booked again");
        assertEq(pool.replacementLength(), 1);
    }

    function test_directAcquireOfPackSplitsSurplusMarginAtSettle() public {
        _openReady();
        uint256 listingId = _listingOfRow(1, 0);
        uint256 value = pool.listedItem(listingId).value;
        uint256 fundBefore = _grailFund();
        _gateOff();
        uint256 requestId = acquireAs(alice, bob, clone, block.timestamp + 1 hours);
        _capture(requestId, listingId);
        uint256 owed = clone.ownerProceeds();
        assertGt(owed, value);
        pool.bookOnly(5);

        uint256 amount = owed - value;
        uint256 cover = amount < 2 * mintFee ? amount : 2 * mintFee;
        uint256 rest = amount - cover;
        uint256 maintenanceShare = rest * MAINT_BPS / SPLIT_BPS;
        uint256 feedShare = rest * FEED_BPS / SPLIT_BPS;
        assertEq(IPool(address(pool)).margin(), 0);
        assertEq(IPool(address(pool)).mintLineOwed(), 2 * mintFee - cover);
        assertEq(IPool(address(pool)).maintenanceReceivable(), maintenanceShare);
        assertEq(pool.grailReceivable(), feedShare);
        assertEq(pool.receivable(), owed - maintenanceShare - feedShare);

        assertTrue(pool.harvest());
        assertEq(pool.maintenance(), maintenanceShare);
        assertEq(_grailFund() - fundBefore, feedShare);
        _assertI1();
    }

    function test_settleBooksNoSurplusWhileTheWalkIsBehind() public {
        _openLarge();
        (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        _gateOff();
        uint256 requestId = acquireAs(alice, bob, clone, block.timestamp + 1 hours);
        _capture(requestId, _listingOfRow(1, 1));
        uint256 owed = clone.ownerProceeds();

        pool.bookOnly(1);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(_bookedReceivables(), _proceeds(fee, base), "recorded capture only");
        assertLt(_bookedReceivables(), owed);

        pool.bookOnly(1);
        assertEq(pool.nextSequenceToBook(), 3);
        assertEq(_bookedReceivables(), owed, "direct capture booked as surplus");
    }

    function _bookedReceivables() internal view returns (uint256) {
        return pool.receivable() + IPool(address(pool)).maintenanceReceivable() + pool.grailReceivable();
    }

    // ---------------------------------------------------------------- Shapes payment paths

    function test_pullWithShapesCoversTicketAndRefundsExcess() public {
        _openReady();
        uint256 first = mintShapes(player, 0.1 ether, 2);
        vm.prank(player);
        IERC721(SHAPES_ADDR).setApprovalForAll(address(pool), true);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = first;
        tokenIds[1] = first + 1;

        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        uint256 playerBefore = player.balance;
        uint256 poolBefore = address(pool).balance;
        uint256 cashBefore = pool.cash();
        uint256 backingBefore = pool.backing();
        uint256 navBefore = pool.nav();
        uint64 last = clone.lastIssuedSequence();

        vm.prank(player);
        pool.pullWithShapes(tokenIds, 1, fee, block.timestamp + 1 hours);

        assertEq(player.balance, playerBefore + 0.2 ether - total, "excess refunded");
        assertEq(address(pool).balance, poolBefore - 0.2 ether, "cash paid the part of the ticket the Shapes cover");
        assertEq(pool.cash(), cashBefore - 0.2 ether, "cash paid for the kept Shapes");
        assertEq(pool.heldCount(), 2, "the Shapes are held");
        assertEq(pool.backing(), backingBefore + 0.2 ether, "backing carries the Shapes");
        assertEq(pool.nav(), navBefore, "nav is unchanged");
        assertEq(clone.lastIssuedSequence(), last + 1);
        assertEq(shapes.ownerOf(first), address(pool));
        assertEq(shapes.ownerOf(first + 1), address(pool));
        _assertI1();
    }

    function test_pullWithShapesAddsMsgValue() public {
        _openReady();
        uint256 tokenId = mintShapes(player, 0.1 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(3);
        assertGt(total, 0.1 ether);
        uint256 topUp = total - 0.1 ether;
        vm.deal(player, player.balance + topUp);
        uint256 playerBefore = player.balance;

        vm.prank(player);
        pool.pullWithShapes{value: topUp}(tokenIds, 3, fee, block.timestamp + 1 hours);
        assertEq(player.balance, playerBefore - topUp);
        assertEq(clone.unsettledAcquisitionCount(), 3);
    }

    function test_revert_pullWithShapesTooLittle() public {
        _openReady();
        uint256 tokenId = mintShapes(player, 0.1 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(3);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.InsufficientValue.selector, 0.1 ether, total));
        pool.pullWithShapes(tokenIds, 3, fee, block.timestamp + 1 hours);
    }

    function test_redeemAndDepositMintsSharesForRedeemedValue() public {
        _openReady();
        uint256 tokenId = mintShapes(player, 0.1 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);

        uint256 navBefore = pool.nav();
        uint256 supplyBefore = pool.totalShares();
        uint256 balanceBefore = address(pool).balance;
        uint256 contribution = pool.contributionFor(0.1 ether, navBefore);
        uint256 expectedShares = PricingLib.sharesFor(0.1 ether - contribution, navBefore, supplyBefore);

        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Deposited(player, 0.1 ether, contribution, expectedShares);
        vm.prank(player);
        pool.redeemAndDeposit(tokenId);

        assertEq(pool.sharesOf(player), expectedShares);
        assertEq(address(pool).balance, balanceBefore, "the Shape is kept, so no ETH arrives");
        assertEq(shapes.ownerOf(tokenId), address(pool));
        assertEq(pool.heldCount(), 1);
        assertEq(pool.nav(), navBefore + 0.1 ether - contribution);
        assertEq(pool.totalShares(), supplyBefore + expectedShares);
        _assertI1();
    }

    function test_revert_redeemAndDepositNotApproved() public {
        _openReady();
        uint256 tokenId = mintShapes(player, 0.1 ether, 1);
        vm.prank(player);
        vm.expectRevert();
        pool.redeemAndDeposit(tokenId);
    }

    // ---------------------------------------------------------------- reopen guards

    function test_revert_purchasesCoolingDownRightAfterOpen() public {
        _open(100 ether);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.PurchasesCoolingDown.selector);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);

        warpPastCooldown(clone);
        (slip, version) = poolArgs(clone);
        vm.prank(player);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_revert_boardTooThin() public {
        _open(0.5 ether);
        warpPastCooldown(clone);
        uint256 concurrency = IPool(address(pool)).concurrency();
        assertGt(concurrency, 0);
        assertGt(pool.listedCount(), 0, "board is built");
        assertLt(pool.listedCount(), concurrency, "board is below concurrency");
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.BoardTooThin.selector);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_boardTooThinCountsUnsettledAcquisitions() public {
        _openReady();
        assertEq(pool.listedCount(), IPool(address(pool)).concurrency());
        _acquire(player, 1);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.BoardTooThin.selector);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_boardStaysThinUntilReplacementIsListed() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.bookOnly(5);
        assertEq(pool.listedCount(), IPool(address(pool)).concurrency() - 1);

        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.BoardTooThin.selector);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    /// @dev On the 10 item board the first capture of a batch moves FWA's fee past the slippage
    ///      tolerance, so later requests of the batch end Refunded and book nothing.
    function test_slippageRefundedRequestsBookNothing() public {
        _openReady();
        uint256[3] memory listingIds = [_listingOfRow(1, 0), _listingOfRow(0, 0), _listingOfRow(1, 1)];
        (uint256[] memory ids, uint256 fee,) = _acquire(player, 3);
        uint256 captures;
        for (uint256 i; i < 3; ++i) {
            fulfill(clone, ids[i], wordFor(clone, listingIds[i]));
            (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(ids[i]);
            if (status == IFWAClone.AcquisitionStatus.Fulfilled) ++captures;
        }
        assertEq(captures, 1);
        uint256 backingBefore = pool.backing();
        pool.bookOnly(10);
        assertEq(pool.nextSequenceToBook(), 4);
        assertEq(pool.replacementLength(), captures);
        assertEq(pool.backing(), backingBefore - 0.02 ether);
        assertEq(pool.backing(), _registryValue(), "I2");
        assertEq(clone.acquisitionRefundCredit(player), 2 * fee);
    }

    function test_revert_feeAboveMax() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.FeeAboveMax.selector, fee, fee - 1));
        pool.acquireBatch{value: total}(player, 1, fee - 1, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_revert_insufficientValue() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.InsufficientValue.selector, total - 1, total));
        pool.acquireBatch{value: total - 1}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_pullRefundsOverpayment() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total + 1 ether);
        vm.prank(player);
        pool.acquireBatch{value: total + 1 ether}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
        assertEq(player.balance, 1 ether);
    }

    function test_revert_countOutOfRange() public {
        _openReady();
        (uint256 fee,,) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.expectRevert(IPoolTypes.InvalidCount.selector);
        pool.acquireBatch(address(this), 0, fee, 0, slip, version, block.timestamp + 1 hours);
        uint256 over = IPool(address(pool)).maxBatch() + 1;
        (slip, version) = poolArgs(clone);
        vm.expectRevert(IPoolTypes.InvalidCount.selector);
        pool.acquireBatch(address(this), over, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_revert_pullBeforeOpenAndWhenPaused() public {
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.expectRevert(IPoolTypes.NotLive.selector);
        pool.acquireBatch(address(this), 1, 1 ether, 0, slip, version, block.timestamp + 1 hours);

        _openReady();
        pool.setPullsPaused(true);
        (slip, version) = poolArgs(clone);
        vm.expectRevert(IPoolTypes.PullsPaused.selector);
        pool.acquireBatch(address(this), 1, 1 ether, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_revert_insolvent() public {
        _openReady();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.deal(address(pool), pool.cash() - 1);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.Insolvent.selector);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_listedGrailWeightAboveTheCapDoesNotBlockAcquisitions() public {
        _openReady();
        (uint256 slip, uint256 version) = poolArgs(clone);
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(player, total);

        // Weight of a 0.01 ETH list price is about half of the board weight, above the 20% cap.
        pool.addGrailItem(SHAPES_ADDR, 1, 1 ether, 0.01 ether, 11, false);
        vm.prank(player);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp + 1 hours);
        assertEq(clone.unsettledAcquisitionCount(), 1);
    }

    function test_revert_settleWithoutFwaPool() public {
        PoolHarness fresh = new PoolHarness(_params());
        vm.expectRevert(IPoolTypes.FwaPoolMissing.selector);
        fresh.settle(1);
    }

    function test_revert_unknownListingRemoval() public {
        vm.expectRevert(abi.encodeWithSelector(IPoolTypes.UnknownListing.selector, 999));
        pool.removeListed(999);
    }

    // ---------------------------------------------------------------- delivery failures

    /// @dev FWA delivers with `transferFrom`, so a contract purchaser without `onERC721Received`
    ///      still receives the token and the capture books normally.
    function test_contractPurchaserWithoutReceiverIsDelivered() public {
        _openReady();
        NoReceiver noReceiver = new NoReceiver();
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        vm.deal(address(noReceiver), total);
        uint256 listingId = _listingOfRow(0, 0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        uint64 last = clone.lastIssuedSequence();
        (uint256 slip, uint256 version) = poolArgs(clone);
        noReceiver.acquire{value: total}(Pool(payable(address(pool))), fee, slip, version, block.timestamp + 1 hours);
        uint256 requestId = clone.requestIdAtSequence(last + 1);

        _capture(requestId, listingId);
        pool.bookOnly(5);
        assertEq(IERC721(it.collection).ownerOf(it.tokenId), address(noReceiver));
        assertEq(pool.nextSequenceToBook(), 2);
    }

    /// @dev Direct acquisition with the Shapes contract as purchaser, delivered to the listing.
    ///      Delivery reverts in `Shapes._update` (self custody), so the acquisition stays
    ///      DeliveryPending.
    function _grief(uint256 listingId) internal returns (uint256 requestId) {
        _gateOff();
        requestId = acquireAs(SHAPES_ADDR, SHAPES_ADDR, clone, block.timestamp + 1 hours);
        fulfill(clone, requestId, wordFor(clone, listingId));
        (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.DeliveryPending));
    }

    function _bookFromPool() internal view returns (Book memory b) {
        b.receivable = pool.receivable();
        b.margin = IPool(address(pool)).margin();
        b.mintLineOwed = IPool(address(pool)).mintLineOwed();
        b.maintenanceReceivable = IPool(address(pool)).maintenanceReceivable();
        b.grailReceivable = pool.grailReceivable();
    }

    function test_griefedDeliveriesAreWrittenOffByTheWalk() public {
        _openLarge();
        uint256 g1 = _listingOfRow(0, 0);
        uint256 g2 = _listingOfRow(0, 1);
        uint256 shapeValue = pool.listedItem(g1).value;
        uint256 backingStart = pool.backing();
        uint256 r1 = _grief(g1);
        uint256 r2 = _grief(g2);

        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.WrittenOff(r1, g1, shapeValue);
        vm.expectEmit(true, true, false, true, address(pool));
        emit IPoolTypes.WrittenOff(r2, g2, shapeValue);
        vm.expectEmit(false, false, false, true, address(pool));
        emit IPoolTypes.Booked(3);
        pool.bookOnly(5);

        assertEq(pool.nextSequenceToBook(), 3, "walk passes both deliveries");
        assertEq(pool.backing(), backingStart - 2 * shapeValue, "backing falls by the written-off values");
        assertEq(pool.backing(), _registryValue(), "I2");
        assertEq(pool.listedItem(g1).value, 0);
        assertEq(pool.listedCount(), 58);
        assertEq(IPool(address(pool)).rowCount(0), 40);
        assertEq(IPool(address(pool)).margin(), -int256(2 * shapeValue), "margin carries the loss");
        assertEq(pool.replacementLength(), 0, "write-off enqueues no replacement");
        assertEq(pool.receivable(), 0);
        _assertI1();

        // Later pulls settle and harvest normally. Pack captures repay the loss before any split.
        Book memory b = _bookFromPool();
        bool repaid;
        for (uint256 i; i < 18 && !repaid; ++i) {
            uint256 listing = _listingOfRow(1, 0);
            (uint256[] memory ids, uint256 fee, uint256 base) = _acquire(player, 1);
            b.receivable = 0; // the pull's slice harvested the receivable booked by the earlier settle
            _capture(ids[0], listing);
            _apply(b, _proceeds(fee, base), pool.listedItem(listing).value, 1);
            pool.bookOnly(5);
            _assertBook(b);
            if (b.margin < 0) {
                assertEq(IPool(address(pool)).maintenanceReceivable() + pool.maintenance(), 0, "no split while margin is negative");
            } else {
                repaid = true;
            }
            if (i == 0) {
                uint256 owed = clone.ownerProceeds();
                assertEq(owed, _proceeds(fee, base), "written-off deliveries accrued no proceeds");
                vm.expectEmit(false, false, false, true, address(pool));
                emit IPoolTypes.Harvested(owed, 0);
                assertTrue(pool.harvest());
                b.receivable = 0;
                _assertBook(b);
            }
        }
        assertTrue(repaid, "margin repaid");
        assertEq(IPool(address(pool)).margin(), 0, "split follows repayment");
        assertEq(pool.backing(), _registryValue(), "I2");
    }

    /// @dev A purchaser that refunds before the pool settles leaves a DeliveryRefunded acquisition for
    ///      the walk. The Shapes contract cannot call `refundFailedDelivery`, so the fork impersonates it.
    function test_refundBeforeTheWalkRecoversTheToken() public {
        _openLarge();
        uint256 listingId = _listingOfRow(0, 0);
        IPoolTypes.Item memory stuck = pool.listedItem(listingId);
        uint256 backingBefore = pool.backing();
        uint256 listedBefore = pool.listedCount();

        (uint256[] memory ids,,) = _acquire(SHAPES_ADDR, 1);
        fulfill(clone, ids[0], wordFor(clone, listingId));
        (, uint64 deadline) = clone.pendingDeliveries(listingId);
        vm.warp(deadline);
        vm.prank(SHAPES_ADDR);
        clone.refundFailedDelivery(listingId);
        pool.bookOnly(5);

        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(shapes.ownerOf(stuck.tokenId), address(pool), "token recovered");
        assertEq(pool.heldCount(), 1);
        assertEq(pool.heldItem(0).tokenId, stuck.tokenId);
        assertEq(pool.heldItem(0).value, stuck.value);
        assertEq(pool.heldItem(0).listingId, 0);
        assertEq(pool.backing(), backingBefore, "refunded item keeps its backing");
        assertEq(IPool(address(pool)).rowCount(0), 42);
        assertEq(pool.listedCount(), listedBefore - 1);
        assertEq(pool.replacementLength(), 0);
        assertEq(IPool(address(pool)).margin(), 0);
        assertEq(pool.backing(), _registryValue(), "I2");
        _assertI1();
    }

    function _pendingDelivery(uint256 listingId) internal view returns (uint256 requestId, uint64 deadline) {
        return clone.pendingDeliveries(listingId);
    }

    function test_expiredAcquisitionBooksNothing() public {
        _openReady();
        (uint256[] memory ids,,) = _acquire(player, 1);
        uint256 backingBefore = pool.backing();
        expire(clone, ids[0]);

        pool.bookOnly(5);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(pool.backing(), backingBefore);
        assertEq(pool.replacementLength(), 0);
        assertEq(IPool(address(pool)).margin(), 0);
        assertEq(clone.acquisitionRefundCredit(player), clone.acquisitionFee());
    }

    // ---------------------------------------------------------------- books before pricing

    /// @dev Entry contribution and shares a deposit of `value` receives at ordinary NAV `atNav`.
    function _depositAt(uint256 value, uint256 atNav) internal view returns (uint256 contribution, uint256 shares) {
        contribution = pool.contributionFor(value, atNav);
        shares = PricingLib.sharesFor(value - contribution, atNav, pool.totalShares());
    }

    /// @dev Pulls one ticket as `player`, fulfils it on `listingId` and lets FWA process it. The pool
    ///      has not booked the capture afterwards.
    function _captureUnbooked(uint256 listingId) internal returns (uint256 fee, uint256 base) {
        uint256[] memory ids;
        (ids, fee, base) = _acquire(player, 1);
        _capture(ids[0], listingId);
        clone.processAcquisitions(1);
        assertEq(pool.nextSequenceToBook(), 1, "pool has not booked");
        assertEq(clone.nextSequenceToProcess(), 2, "FWA has processed");
    }

    /// @dev NAV the books reach after `settle` and `harvest`, measured on a reverted snapshot.
    function _syncedNav() internal returns (uint256 syncedNav) {
        uint256 snapshot = vm.snapshotState();
        pool.bookOnly(20);
        pool.harvest();
        syncedNav = pool.nav();
        vm.revertToState(snapshot);
    }

    function test_withdrawAfterFwaProcessedALossPaysThePostLossNav() public {
        _openReady();
        vm.deal(saver, 10 ether);
        vm.prank(saver);
        pool.deposit{value: 10 ether}();
        uint256 listingId = _listingOfRow(0, 0);
        uint256 value = pool.listedItem(listingId).value;
        (uint256 fee, uint256 base) = _captureUnbooked(listingId);

        uint256 staleNav = pool.nav();
        uint256 postNav = staleNav + _proceeds(fee, base) - value;
        assertLt(postNav, staleNav, "row 0 capture is a loss");
        uint256 shares = pool.sharesOf(saver);
        uint256 supply = pool.totalShares();
        uint256 expected = PricingLib.claimFor(shares, postNav, supply);
        assertLt(expected, PricingLib.claimFor(shares, staleNav, supply));

        uint256 before = saver.balance;
        vm.prank(saver);
        pool.withdraw(shares);

        assertEq(saver.balance - before, expected, "paid the post-loss share");
        assertEq(pool.nextSequenceToBook(), 2, "withdraw booked the capture");
        assertEq(pool.receivable(), 0, "withdraw harvested");
        _assertI1();
    }

    function test_depositAfterFwaProcessedAGainMintsAtThePostCaptureNav() public {
        _openReady();
        (uint256 fee, uint256 base) = _captureUnbooked(_listingOfRow(1, 0));
        assertGt(_proceeds(fee, base), 0);

        uint256 staleNav = pool.nav();
        uint256 postNav = _syncedNav();
        assertGt(postNav, staleNav, "row 1 capture is a gain");
        assertEq(pool.nextSequenceToBook(), 1, "snapshot restored");
        (uint256 contribution, uint256 shares) = _depositAt(10 ether, postNav);
        (, uint256 staleShares) = _depositAt(10 ether, staleNav);
        assertLt(shares, staleShares);

        vm.deal(saver, 10 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Deposited(saver, 10 ether, contribution, shares);
        vm.prank(saver);
        pool.deposit{value: 10 ether}();

        assertEq(pool.sharesOf(saver), shares);
        assertEq(pool.nextSequenceToBook(), 2);
        assertEq(pool.receivable() + IPool(address(pool)).maintenanceReceivable(), 0);
    }

    function test_redeemAndDepositSyncsBeforePricing() public {
        _openReady();
        _captureUnbooked(_listingOfRow(1, 0));
        uint256 postNav = _syncedNav();
        (uint256 contribution, uint256 shares) = _depositAt(0.1 ether, postNav);

        uint256 tokenId = mintShapes(saver, 0.1 ether, 1);
        vm.prank(saver);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Deposited(saver, 0.1 ether, contribution, shares);
        vm.prank(saver);
        pool.redeemAndDeposit(tokenId);
        assertEq(pool.nextSequenceToBook(), 2);
    }

    function test_rotateSyncsAndPaysFromTheHarvest() public {
        _openReady();
        vm.deal(saver, 10 ether);
        vm.prank(saver);
        pool.deposit{value: 10 ether}();
        pool.spendOnBacking(pool.cash() - 1 ether);
        uint256 shares = pool.sharesOf(saver);
        vm.prank(saver);
        pool.withdraw(shares);
        uint256 queued = pool.claims();
        assertGt(queued, 1 ether, "claim queued behind empty cash");
        assertEq(pool.cash(), 0);

        (uint256 fee, uint256 base) = _captureUnbooked(_listingOfRow(1, 0));
        vm.warp(block.timestamp + pool.rotateInterval());
        uint256 balance = saver.balance;
        assertTrue(pool.rotateDue() != IPoolTypes.RotateTrigger.None);
        vm.prank(player);
        pool.rotate();

        assertEq(pool.nextSequenceToBook(), 2, "rotate booked the capture");
        uint256 paid = saver.balance - balance;
        assertGt(paid, _proceeds(fee, base), "claim paid from the harvest, then from liquidated listings");
        assertLe(pool.claims() + paid, queued, "liquidation fees reduce the claim");
        assertEq(pool.cash(), 0);
    }

    function test_directPurchaseSurplusIsPricedByTheNextDeposit() public {
        _openReady();
        uint256 listingId = _listingOfRow(0, 0);
        _gateOff();
        uint256 requestId = acquireAs(alice, saver, clone, block.timestamp + 1 hours);
        _capture(requestId, listingId);
        pool.bookOnly(5);

        uint256 navAfterSettle = pool.nav();
        (uint256 contribution, uint256 shares) = _depositAt(5 ether, navAfterSettle);
        vm.deal(player, 5 ether);
        vm.expectEmit(true, false, false, true, address(pool));
        emit IPoolTypes.Deposited(player, 5 ether, contribution, shares);
        vm.prank(player);
        pool.deposit{value: 5 ether}();
        assertEq(pool.sharesOf(player), shares, "no discount after settle");
        assertEq(pool.receivable(), 0, "deposit harvested the surplus");
        assertEq(pool.nextSequenceToBook(), 2);
    }

    // ---------------------------------------------------------------- claims before mints

    function test_pullSlicePaysQueuedClaimBeforeTheReplacementMint() public {
        _openLarge();
        vm.deal(saver, 10 ether);
        vm.prank(saver);
        pool.deposit{value: 10 ether}();
        pool.spendOnBacking(pool.cash() - 1 ether);
        uint256 shares = pool.sharesOf(saver);
        vm.prank(saver);
        pool.withdraw(shares);
        uint256 queued = pool.claims();
        assertGt(queued, 0, "withdraw enqueued");
        assertEq(pool.cash(), 0);

        (uint256[] memory ids,,) = _acquire(player, 1);
        _capture(ids[0], _listingOfRow(1, 0));
        pool.bookOnly(5);
        uint256 harvested = pool.receivable();
        // The harvest cash covers the replacement mint. Paying claims first leaves the mint queued.
        assertGe(harvested, 0.02 ether + 2 * mintFee);
        assertEq(pool.replacementLength(), 1);

        uint256 balance = saver.balance;
        _acquire(player, 1);

        assertEq(saver.balance - balance, harvested, "claim took the harvested cash");
        assertEq(pool.claims(), queued - harvested);
        assertEq(pool.cash(), 0);
        assertEq(pool.replacementLength(), 1, "mint waited for cash");
        assertEq(pool.heldCount(), 0);
    }
}
