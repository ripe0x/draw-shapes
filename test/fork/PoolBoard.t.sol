// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {Pool} from "../../src/Pool.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Board build against deployed Shapes, deployed Shape Packs and a FWA clone created by
///         the pool through the deployed factory.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). `minItems` is 10, so the first targets are 7 and 3 items.
contract PoolBoardForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal stranger = makeAddr("stranger");

    uint256 internal fee;
    uint256 internal row0Cost;
    uint256 internal row1Cost;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        fee = shapes.mintFee();
        row0Cost = 0.1 ether + fee;
        row1Cost = 0.02 ether + 2 * fee;
        vm.deal(alice, 10_000 ether);
        _create(_forkParams());
    }

    function _forkParams() internal returns (IPoolTypes.Params memory p) {
        p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
    }

    /// @dev Clears the purchase operator of the FWA pool from the pool (its owner), the state `adminCall` can produce, so a wallet
    ///      can acquire from the FWA pool directly and the walk books unrecorded captures.
    function _gateOff() internal {
        vm.prank(address(pool));
        clone.setPurchaseOperator(address(0));
    }

    function _create(IPoolTypes.Params memory p) internal {
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
    }

    function _open() internal {
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
    }

    function _depositAndOpen(uint256 value) internal {
        vm.prank(alice);
        pool.deposit{value: value}();
        _open();
    }

    function _expectedPrice(uint256 row, uint256 value) internal view returns (uint256) {
        uint256 rungs = row == 0 ? 1 : 2;
        return PricingLib.listingPrice(value, 200, 100, 400, PricingLib.mintLineBps(fee * rungs, value));
    }

    /// @dev Checks every FWA listing against the registry and returns the registry value sum.
    function _checkListings() internal view returns (uint256 sum, uint256 listedCount) {
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            assertEq(it.listingId, id, "registry id");
            (address collection, address depositor,, uint256 tokenId,, uint256 price,, IFWAClone.ListingStatus status) =
                clone.listings(id);
            assertEq(collection, it.collection, "collection");
            assertEq(depositor, address(pool), "depositor");
            assertEq(tokenId, it.tokenId, "token id");
            assertEq(price, _expectedPrice(it.row, it.value), "list price");
            assertEq(uint8(status), uint8(IFWAClone.ListingStatus.Active), "status");
            assertEq(IERC721(collection).ownerOf(tokenId), address(clone), "escrowed at clone");
            sum += it.value;
            ++listedCount;
        }
    }

    // ---------------------------------------------------------------- createFwaPool

    function test_drawPacksMinimumIsTwoUnits() public view {
        assertEq(drawPacks.MIN_PACK_VALUE(), 2 * shapes.unit());
    }

    function test_createFwaPoolRecordsCloneAndLimits() public view {
        assertTrue(factory.isPool(address(clone)));
        assertEq(clone.owner(), address(pool));
        assertEq(IPool(address(pool)).maxBatch(), factory.maxAcquisitionsPerTx());
        assertEq(IPool(address(pool)).concurrency(), factory.maxOutstandingRequestsPerPool());
        assertEq(IPool(address(pool)).openingDeadlineAt(), block.timestamp + 24 hours);
        assertEq(IPool(address(pool)).openingDeadline(), 24 hours);
        assertTrue(shapes.isApprovedForAll(address(pool), address(clone)));
        assertTrue(IERC721(address(drawPacks)).isApprovedForAll(address(pool), address(clone)));
        assertEq(clone.purchaseOperator(), address(pool));
    }

    function test_createFwaPoolEmitsEvent() public {
        IPoolTypes.Params memory p = _forkParams();
        PoolHarness fresh = new PoolHarness(p);
        address predicted = factory.predictPoolAddress(address(fresh), bytes32(0));
        vm.expectEmit(true, false, false, false, address(fresh));
        emit IPoolTypes.FwaPoolCreated(predicted);
        vm.prank(admin);
        IPool(address(fresh)).createFwaPool(0);
        assertEq(address(fresh.fwaPool()), predicted);
    }

    function test_revert_createFwaPoolTwice() public {
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.FwaPoolExists.selector);
        IPool(address(pool)).createFwaPool(0);
    }

    // ---------------------------------------------------------------- open

    function test_revert_openBeforeDeadline() public {
        vm.warp(IPool(address(pool)).openingDeadlineAt() - 1);
        vm.expectRevert(IPoolTypes.OpeningDeadlineNotReached.selector);
        pool.open();
    }

    function test_openWithNoCashListsNothing() public {
        vm.expectEmit(false, false, false, false, address(pool));
        emit IPoolTypes.Opened();
        _open();
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Live));
        assertEq(clone.nextListingId(), 1);
        assertEq(clone.activeListingCount(), 0);
        assertEq(pool.heldCount(), 0);
        assertEq(pool.backing(), 0);
    }

    function test_revert_openTwice() public {
        _open();
        vm.expectRevert(IPoolTypes.NotOpening.selector);
        pool.open();
    }

    function test_openRepeatsUntilTheBoardIsBuiltThenGoesLive() public {
        IPoolTypes.Params memory p = _forkParams();
        p.minItems = 60;
        _create(p);
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        assertFalse(clone.localPurchasesEnabled());

        vm.recordLogs();
        pool.open();
        assertTrue(clone.localPurchasesEnabled(), "first call enables acquisitions");
        assertEq(pool.listedCount(), 20);
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Opening));

        pool.open();
        assertEq(pool.listedCount(), 40);
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Opening));

        pool.open();
        assertEq(pool.listedCount(), 60, "board at target after 20 mints");
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Opening), "a full batch keeps the pool Opening");

        pool.open();
        assertEq(pool.listedCount(), 60);
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Live));
        assertEq(IPool(address(pool)).rowCount(0), 42);
        assertEq(IPool(address(pool)).rowCount(1), 18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 opened;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Opened.selector) ++opened;
        }
        assertEq(opened, 1, "Opened is emitted on the transition only");

        vm.expectRevert(IPoolTypes.NotOpening.selector);
        pool.open();
    }

    function test_openGoesLiveWhenCashRunsOutBeforeTheBatchFills() public {
        IPoolTypes.Params memory p = _forkParams();
        p.minItems = 60;
        _create(p);
        pool.bookProceeds{value: 3 * row0Cost + row1Cost}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        assertGt(pool.listedCount(), 0);
        assertLt(pool.listedCount(), 20);
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Live));
    }

    function test_restockPaysQueuedClaimsBeforeMinting() public {
        _depositAndOpen(100 ether);
        address saver = makeAddr("saver");
        vm.deal(saver, 10 ether);
        vm.prank(saver);
        pool.deposit{value: 10 ether}();
        pool.spendOnBacking(pool.cash() - 1 ether);
        uint256 shares = pool.sharesOf(saver);
        vm.prank(saver);
        pool.withdraw(shares);
        uint256 queued = pool.claims();
        assertGt(queued, 0);
        assertEq(pool.cash(), 0);

        // Cash of 0.03 ETH covers the 0.0221 ETH replacement. Paying claims first leaves the mint queued.
        pool.pushReplacement(1);
        pool.bookProceeds{value: 0.03 ether}();
        uint256 before = saver.balance;
        pool.restock();

        assertEq(saver.balance - before, 0.03 ether);
        assertEq(pool.claims(), queued - 0.03 ether);
        assertEq(pool.cash(), 0);
        assertEq(pool.replacementLength(), 1);
    }

    function test_openBuildsBoardToMinItemsByRowShare() public {
        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        uint256 cashBefore = pool.cash();
        _open();

        assertEq(IPool(address(pool)).rowCount(0), 7);
        assertEq(IPool(address(pool)).rowCount(1), 3);
        assertEq(pool.heldCount(), 0);
        assertEq(clone.activeListingCount(), 10);

        (uint256 sum, uint256 listedCount) = _checkListings();
        assertEq(listedCount, 10);
        assertEq(sum, 7 * 0.1 ether + 3 * 0.02 ether);
        assertEq(pool.backing(), sum);
        assertEq(pool.cash(), cashBefore - 7 * row0Cost - 3 * row1Cost);
        assertEq(pool.cash() + pool.backing() + 7 * fee + 6 * fee, cashBefore);
        assertGe(address(pool).balance, pool.cash());
    }

    function test_packRowRegistryValueEqualsValueOf() public {
        _depositAndOpen(100 ether);
        uint256 packs;
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            if (it.row != 1) continue;
            ++packs;
            assertEq(it.collection, address(drawPacks));
            assertEq(it.value, IShapePacks(address(drawPacks)).valueOf(it.tokenId));
            assertEq(it.value, 0.02 ether);
        }
        assertEq(packs, 3);
    }

    function test_replacementsMintedBeforeNewInventory() public {
        pool.pushReplacement(1);
        pool.pushReplacement(1);
        // Two replacements, then one row 0 step above the one step reserve.
        pool.bookProceeds{value: 3 * row1Cost + row0Cost}();
        _open();

        // The 2 replacements and 1 row 0 mint are filled. The opening deficit (7 row 0 and 1 row 1
        // entries beyond the 2 queued) stays queued, minus the row 0 mint.
        assertEq(pool.replacementLength(), 7);
        assertEq(IPool(address(pool)).rowCount(1), 2);
        assertEq(IPool(address(pool)).rowCount(0), 1);
        assertEq(pool.cash(), row1Cost);
        _checkListings();
    }

    function test_replacementQueueStopsWhenCashShort() public {
        pool.pushReplacement(1);
        pool.pushReplacement(1);
        pool.bookProceeds{value: 2 * row1Cost - 1}();
        _open();

        assertEq(pool.replacementLength(), 9, "the second replacement and the opening deficit stay queued");
        assertEq(IPool(address(pool)).rowCount(1), 1);
        assertEq(IPool(address(pool)).rowCount(0), 0);
        assertEq(pool.cash(), row1Cost - 1);
    }

    function test_rowCountTracksListedPlusHeld() public {
        _open();
        uint256 first = mintShapes(address(pool), 0.1 ether, 2);
        // mintShapes pranks the recipient, so the pool itself minted to itself.
        pool.addItem(SHAPES_ADDR, 0, first, 0.1 ether, 0);
        pool.addItem(SHAPES_ADDR, 0, first + 1, 0.1 ether, 0);
        assertEq(IPool(address(pool)).rowCount(0), 2);
        assertEq(pool.heldCount(), 2);
        assertEq(pool.backing(), 0.2 ether);

        assertEq(pool.restock(), 2);
        assertEq(IPool(address(pool)).rowCount(0), 2);
        assertEq(pool.heldCount(), 0);
        assertEq(clone.activeListingCount(), 2);
        assertEq(pool.backing(), 0.2 ether);
        _checkListings();
    }

    function test_heldItemsListTwentyPerCallInOneInventoryBatch() public {
        _open();
        uint256 batch = clone.MAX_INVENTORY_BATCH();
        uint256 count = batch + 5;
        uint256 first = mintShapes(address(pool), 0.1 ether, count);
        for (uint256 i; i < count; ++i) {
            pool.addItem(SHAPES_ADDR, 0, first + i, 0.1 ether, 0);
        }
        uint256 versionBefore = clone.inventoryVersion();
        assertEq(pool.restock(), batch, "one FWA batch per call");
        assertEq(pool.heldCount(), 5);
        assertEq(clone.inventoryVersion(), versionBefore + 1);
        assertEq(pool.restock(), 5);
        assertEq(pool.heldCount(), 0);
        assertEq(clone.activeListingCount(), count);
        assertEq(pool.backing(), count * 0.1 ether);
        _checkListings();
    }

    function test_restockWithNothingToDoReportsNoChange() public {
        _open();
        assertEq(pool.restock(), 0);
    }

    function test_strangerTransferIsNotRegistered() public {
        uint256 id = mintShapes(stranger, 0.1 ether, 1);
        vm.prank(stranger);
        shapes.safeTransferFrom(stranger, address(pool), id);
        assertEq(shapes.ownerOf(id), address(pool));
        assertEq(pool.heldCount(), 0);
        assertEq(pool.backing(), 0);
        assertEq(IPool(address(pool)).rowCount(0), 0);

        _depositAndOpen(100 ether);
        assertEq(shapes.ownerOf(id), address(pool));
        assertEq(pool.heldCount(), 0);
        assertEq(pool.backing(), 7 * 0.1 ether + 3 * 0.02 ether);
    }

    /// @dev Exercises the ported acquire and fulfill helpers against the clone the pool created.
    function test_forkHelpersAcquireAndFulfill() public {
        _depositAndOpen(100 ether);
        vm.prank(address(pool));
        clone.setBool(41, true);
        warpPastCooldown(clone);

        uint256 listingId = 1;
        _gateOff();
        uint256 requestId = acquireAs(alice, bob, clone, block.timestamp + 1 hours);
        fulfill(clone, requestId, wordFor(clone, listingId));

        (,,,, IFWAClone.AcquisitionStatus status) = clone.acquisitions(requestId);
        assertEq(uint8(status), uint8(IFWAClone.AcquisitionStatus.Fulfilled));
        (,, address purchaser,,,,,) = clone.listings(listingId);
        assertEq(purchaser, bob);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        assertEq(IERC721(it.collection).ownerOf(it.tokenId), bob);
    }
}
