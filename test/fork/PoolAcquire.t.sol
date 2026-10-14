// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";

/// @notice The FWA purchase ABI on the pool (`acquire`, `acquireBatch`, `quoteAcquisitionPrice`) and the
///         purchase operator gate, against deployed Shapes, a Draw Packs deployment and a FWA clone
///         created by the pool.
contract PoolAcquireForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal player = makeAddr("player");
    address internal other = makeAddr("other");

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

        vm.prank(alice);
        pool.deposit{value: 100 ether}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        warpPastCooldown(clone);
    }

    function _listingOfRow(uint256 row) internal view returns (uint256) {
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            if (it.value != 0 && it.row == row) return id;
        }
        revert("no such listing");
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    // ---------------------------------------------------------------- gate

    function test_createFwaPoolSetsThePoolAsPurchaseOperator() public view {
        assertEq(clone.purchaseOperator(), address(pool));
    }

    function test_directAcquireRevertsWhileTheGateIsOnAndWorksAfterItIsOff() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice();
        uint256 version = clone.inventoryVersion();
        vm.deal(player, 2 * total);

        vm.prank(player);
        vm.expectRevert(abi.encodeWithSignature("PurchaseNotAllowed()"));
        clone.acquire{value: total}(player, fee, 0, 10_000, version, _deadline());

        vm.prank(admin);
        IPool(address(pool)).setPurchaseGate(false);
        assertEq(clone.purchaseOperator(), address(0));
        vm.prank(player);
        uint256 requestId = clone.acquire{value: total}(player, fee, 0, 10_000, version, _deadline());
        (address purchaser,,,,) = clone.acquisitions(requestId);
        assertEq(purchaser, player);

        vm.prank(admin);
        IPool(address(pool)).setPurchaseGate(true);
        assertEq(clone.purchaseOperator(), address(pool));
    }

    function test_revert_setPurchaseGateNotAdmin() public {
        vm.prank(player);
        vm.expectRevert(IPoolTypes.NotAdmin.selector);
        IPool(address(pool)).setPurchaseGate(false);
    }

    function test_revert_setPurchaseGateBeforeTheFwaPoolExists() public {
        PoolHarness fresh = new PoolHarness(_params());
        vm.prank(admin);
        vm.expectRevert(IPoolTypes.FwaPoolMissing.selector);
        IPool(address(fresh)).setPurchaseGate(true);
    }

    function test_canPurchaseIsFalseOutsideAPoolCall() public {
        assertFalse(pool.canPurchase(player));
        assertFalse(pool.canPurchase(address(0)));

        uint256[] memory ids = acquirePooled(address(pool), clone, player, 1);
        assertEq(ids.length, 1);
        assertFalse(pool.canPurchase(player), "cleared after the forwarding call");
        assertFalse(pool.canPurchase(other));
    }

    function test_bareQuoteMatchesTheFwaPool() public view {
        (uint256 fee, uint256 vrf, uint256 total) = pool.quoteAcquisitionPrice();
        (uint256 cFee, uint256 cVrf, uint256 cTotal) = clone.quoteAcquisitionPrice();
        assertEq(fee, cFee);
        assertEq(vrf, cVrf);
        assertEq(total, cTotal);
        (uint256 fee1,, uint256 total1) = pool.quoteAcquisitionPrice(1);
        assertEq(fee, fee1);
        assertEq(total, total1);
    }

    function test_fwaAsksThePoolWhetherTheCallerMayPurchase() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.expectCall(address(pool), abi.encodeCall(IPool.canPurchase, (player)));
        vm.prank(player);
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, _deadline());
    }

    // ---------------------------------------------------------------- acquireBatch

    function test_acquireBatchForwardsTheCallersArgumentsAndBooksLikeAPull() public {
        uint256 count = 2;
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(count);
        uint256 version = clone.inventoryVersion();
        uint256 minWeighted = clone.weightedBackingTotal();
        uint256 slippageBps = 1_234;
        vm.deal(player, total);
        uint64 last = clone.lastIssuedSequence();

        vm.recordLogs();
        vm.prank(player);
        uint256[] memory ids =
            pool.acquireBatch{value: total}(player, count, fee, minWeighted, slippageBps, version, _deadline());

        assertEq(ids.length, count);
        for (uint256 i; i < count; ++i) {
            assertEq(ids[i], clone.requestIdAtSequence(last + 1 + uint64(i)));
            (address purchaser,,,,) = clone.acquisitions(ids[i]);
            assertEq(purchaser, player);
            (,,,, uint16 maxNegative,) = clone.acquisitionMeta(ids[i]);
            assertEq(maxNegative, slippageBps, "slippage reaches FWA unchanged");
            (, bool recorded) = pool.baseOf(ids[i]);
            assertTrue(recorded, "base recorded");
        }
        uint256 pulledLogs;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Pulled.selector) ++pulledLogs;
        }
        assertEq(pulledLogs, 1);
        assertEq(player.balance, 0);

        uint256 listingId = _listingOfRow(0);
        IPoolTypes.Item memory it = pool.listedItem(listingId);
        uint256 backingBefore = pool.backing();
        fulfill(clone, ids[0], wordFor(clone, listingId));
        pool.bookOnly(5);
        assertEq(IERC721(it.collection).ownerOf(it.tokenId), player);
        assertEq(pool.backing(), backingBefore - it.value);
        assertGt(pool.receivable(), 0, "proceeds booked");
        assertEq(pool.nextSequenceToBook(), 2, "the second request still waits for its word");
        assertGe(address(pool).balance, pool.cash() + pool.maintenance());
    }

    function test_acquireBatchRefundsOverpaymentToTheCaller() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total + 1 ether);
        vm.prank(player);
        pool.acquireBatch{value: total + 1 ether}(player, 1, fee, 0, slip, version, _deadline());
        assertEq(player.balance, 1 ether);
    }

    function test_acquireBatchStaleInventoryVersionRevertsAtFwa() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSignature("InventoryVersionMismatch(uint256,uint256)", version + 1, version));
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version + 1, _deadline());
    }

    function test_acquireBatchExpiredDeadlineRevertsAtFwa() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(abi.encodeWithSignature("TransactionExpired(uint256)", block.timestamp - 1));
        pool.acquireBatch{value: total}(player, 1, fee, 0, slip, version, block.timestamp - 1);
    }

    function test_revert_acquireBatchPurchaserMismatch() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice(1);
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.PurchaserMismatch.selector);
        pool.acquireBatch{value: total}(other, 1, fee, 0, slip, version, _deadline());
    }

    // ---------------------------------------------------------------- acquire

    function test_acquireOpensOneRequestAndReturnsItsId() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice();
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        uint64 last = clone.lastIssuedSequence();

        vm.prank(player);
        uint256 requestId = pool.acquire{value: total}(player, fee, 0, slip, version, _deadline());

        assertEq(requestId, clone.requestIdAtSequence(last + 1));
        assertEq(clone.lastIssuedSequence(), last + 1);
        (address purchaser,,,,) = clone.acquisitions(requestId);
        assertEq(purchaser, player);
        (, bool recorded) = pool.baseOf(requestId);
        assertTrue(recorded);
    }

    function test_revert_acquirePurchaserMismatch() public {
        (uint256 fee,, uint256 total) = clone.quoteAcquisitionPrice();
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(IPoolTypes.PurchaserMismatch.selector);
        pool.acquire{value: total}(other, fee, 0, slip, version, _deadline());
    }

    // ---------------------------------------------------------------- quote and Shapes payment

    function test_quoteAcquisitionPriceForwardsToTheFwaPool() public view {
        for (uint256 count = 1; count <= 3; ++count) {
            (uint256 fee, uint256 vrf, uint256 total) = pool.quoteAcquisitionPrice(count);
            (uint256 cFee, uint256 cVrf, uint256 cTotal) = clone.quoteAcquisitionPrice(count);
            assertEq(fee, cFee);
            assertEq(vrf, cVrf);
            assertEq(total, cTotal);
        }
    }

    function test_pullWithShapesPassesThePoolChosenArguments() public {
        uint256 tokenId = mintShapes(player, 0.1 ether, 1);
        vm.prank(player);
        IERC721(SHAPES_ADDR).approve(address(pool), tokenId);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        (uint256 fee,,) = clone.quoteAcquisitionPrice(1);
        uint64 last = clone.lastIssuedSequence();

        vm.prank(player);
        pool.pullWithShapes(tokenIds, 1, fee, _deadline());

        uint256 requestId = clone.requestIdAtSequence(last + 1);
        (address purchaser,,,,) = clone.acquisitions(requestId);
        assertEq(purchaser, player);
        (,,,, uint16 maxNegative,) = clone.acquisitionMeta(requestId);
        assertEq(maxNegative, clone.selectionSlippageBps());
    }
}
