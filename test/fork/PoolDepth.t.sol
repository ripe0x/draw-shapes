// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Board depth that follows NAV above the reserve, and the `Deep` settle trigger, against
///         deployed Shapes, Shape Packs and a FWA clone created by the pool.
/// @dev Mix: row 0 is a 0.1 ETH Shape (7,000 bps), row 1 a pack of 2 x 0.01 ETH (3,000 bps).
///      `minItems` is 10, `batchMin` 5 and `reserveBps` 1,000. The pool opens with the deposit that
///      makes `boardItems()` equal `minItems`.
contract PoolDepthForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    address internal keeper = makeAddr("keeper");
    uint256 internal fee;

    function setUp() public {
        setUpFork();
        openFactory();
        deployDrawPacks(admin);
        fee = shapes.mintFee();
        vm.deal(alice, 10_000 ether);

        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.batchMin = 5;
        pool = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);

        vm.prank(alice);
        pool.deposit{value: _openingDeposit(address(pool))}();
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        pool.open();
        pool.loseGrailFund(IPool(address(pool)).grail().fund);
        vm.prank(factory.owner());
        factory.setInventoryChangeCooldown(0);
        pool.setMaintenance(1 ether);
        vm.deal(address(pool), address(pool).balance + 1 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _boardItems() internal view returns (uint256) {
        return IPool(address(pool)).boardItems();
    }

    /// @dev Listed, held and queued ordinary items.
    function _count() internal view returns (uint256) {
        return pool.listedCount() + pool.heldCount() + pool.replacementLength();
    }

    function _deposit(uint256 value) internal {
        vm.prank(alice);
        pool.deposit{value: value}();
    }

    function _settle() internal returns (uint256 listed, uint256 refund) {
        vm.recordLogs();
        vm.prank(keeper);
        pool.settle(20);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == IPoolTypes.Settled.selector) {
                (listed, refund) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    /// @dev Settles until `Deep` is no longer due. Returns the calls made.
    function _settleUntilLevel() internal returns (uint256 calls) {
        while (pool.settleDue() == IPoolTypes.SettleTrigger.Deep && calls < 20) {
            (uint256 listed,) = _settle();
            assertLe(listed, 25, "at most 25 listed per settle");
            ++calls;
        }
    }


    /// @dev Pulls one item through the pool and delivers the word that captures `listingId`.
    function _captureListing(uint256 listingId) internal {
        (uint256 feeWei,, uint256 total) = clone.quoteAcquisitionPrice(1);
        uint64 last = clone.lastIssuedSequence();
        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(alice, alice.balance + total);
        vm.prank(alice);
        pool.acquireBatch{value: total}(alice, 1, feeWei, 0, slip, version, block.timestamp + 1 hours);
        uint256 requestId = clone.requestIdAtSequence(last + 1);
        fulfill(clone, requestId, wordFor(clone, listingId));
    }

    function _listingOfRow(uint256 row) internal view returns (uint256) {
        uint256 next = clone.nextListingId();
        for (uint256 id = 1; id < next; ++id) {
            IPoolTypes.Item memory it = pool.listedItem(id);
            if (it.value != 0 && it.row == row) return id;
        }
        revert("no such listing");
    }

    function _rowOverTarget(uint256 row, uint256 share) internal view returns (bool) {
        return IPool(address(pool)).rowCount(row) + pool.queuedOf(row)
            >= PricingLib.rowDepth(_boardItems(), share);
    }

    // ---------------------------------------------------------------- rule

    function test_boardItemsEqualsMinItemsWhenFreeNavBuysFewer() public view {
        assertEq(uint8(pool.lifecycle()), uint8(IPoolTypes.Lifecycle.Live), "open went Live at minItems");
        assertEq(_boardItems(), 10);
        assertEq(pool.listedCount(), 10);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None));
    }

    function test_boardItemsGrowsWithADepositAndDeepBecomesDue() public {
        _deposit(4 ether);
        uint256 nav = pool.nav();
        uint256 meanCost = (7_000 * (0.1 ether + fee) + 3_000 * (0.02 ether + 2 * fee)) / 10_000;
        uint256 expected = (nav - nav * 1_000 / 10_000) / meanCost;
        assertGt(expected, 10 + 5, "the deposit funds a deeper board");
        assertEq(_boardItems(), expected);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.Deep));
    }

    function test_deepIsNotDueWhenTheGapIsBelowBatchMin() public {
        // One more item of free NAV than the board holds is below `batchMin` 5.
        _deposit(0.2 ether);
        assertLt(_boardItems(), _count() + 5);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None));
    }

    // ---------------------------------------------------------------- open

    function test_openGoesLiveAtMinItemsAndDeepFillsTheRest() public {
        IPoolTypes.Params memory p = _params();
        p.shapes = SHAPES_ADDR;
        p.drawPacks = address(drawPacks);
        p.fwaFactory = FACTORY_ADDR;
        p.mix[1].rungs[0] = 0;
        p.mix[1].rungs[1] = 0;
        p.batchMin = 5;
        PoolHarness big = new PoolHarness(p);
        vm.prank(admin);
        IPool(address(big)).createFwaPool(0);
        IFWAClone bigClone = big.fwaPool();
        vm.prank(address(big));
        bigClone.setBool(41, true);

        uint256 minItems = big.minItems();
        vm.prank(alice);
        big.deposit{value: _openingDeposit(address(big)) + 8 ether}();
        assertGe(IPool(address(big)).boardItems(), 3 * minItems, "deep opening deposit");

        vm.warp(IPool(address(big)).openingDeadlineAt());
        uint256 calls;
        while (big.lifecycle() == IPoolTypes.Lifecycle.Opening && calls < 50) {
            big.open();
            ++calls;
        }
        assertEq(uint8(big.lifecycle()), uint8(IPoolTypes.Lifecycle.Live), "Live");
        assertLe(calls, (minItems + 19) / 20 + 2, "open calls to Live");
        assertGe(big.listedCount(), minItems);
        assertLt(big.listedCount(), IPool(address(big)).boardItems());
        assertEq(uint8(big.settleDue()), uint8(IPoolTypes.SettleTrigger.Deep));

        uint256 n;
        while (big.settleDue() == IPoolTypes.SettleTrigger.Deep && n < 100) {
            vm.prank(keeper);
            big.settle(20);
            ++n;
        }
        assertLt(n, 100);
        assertLt(IPool(address(big)).boardItems(), big.listedCount() + big.heldCount() + big.replacementLength() + 5);
    }

    // ---------------------------------------------------------------- settle on Deep

    function test_settleOnDeepQueuesAndListsTwentyFivePerCallUntilTheBoardMatches() public {
        _deposit(4 ether);
        uint256 target = _boardItems();
        uint256 listedBefore = pool.listedCount();
        uint256 keeperBefore = keeper.balance;

        (uint256 listed, uint256 refund) = _settle();
        assertEq(listed, 25, "first call lists 25");
        assertGt(refund, 0, "the refund is paid");
        assertEq(keeper.balance - keeperBefore, refund);
        assertEq(pool.listedCount(), listedBefore + 25);

        uint256 calls = 1 + _settleUntilLevel();
        assertGt(calls, 1, "more than one call");
        assertLt(calls, 20);
        assertLt(target, _count() + 5, "board count is within batchMin of the depth");
        assertGt(pool.listedCount(), listedBefore + 25);
        assertEq(uint8(pool.settleDue()), uint8(IPoolTypes.SettleTrigger.None));
    }

    function test_deepQueuesEachRowAgainstItsTargetDepth() public {
        _deposit(4 ether);
        uint256 depth = _boardItems();
        _settle();
        IPool p = IPool(address(pool));
        // Row order fill: row 0 reaches its target before row 1 receives entries.
        uint256 row0Target = PricingLib.rowDepth(depth, 7_000);
        assertLe(p.rowCount(0) + pool.queuedOf(0), row0Target);
        assertGt(p.rowCount(0) + pool.queuedOf(0), 10 * 7 / 10);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_aWithdrawalBelowTheCountDelistsNothingAndAnOverTargetRowGetsNoReplacement() public {
        _deposit(4 ether);
        _settleUntilLevel();
        uint256 listedBefore = pool.listedCount();
        uint256 activeBefore = clone.activeListingCount();
        assertGt(listedBefore, 10 + 25);

        uint256 shares = pool.sharesOf(alice);
        vm.prank(alice);
        pool.withdraw(shares * 9 / 10);
        assertLt(_boardItems(), _count(), "depth fell below the board count");
        assertEq(pool.listedCount(), listedBefore, "nothing is delisted");
        assertEq(clone.activeListingCount(), activeBefore);
        assertTrue(pool.settleDue() != IPoolTypes.SettleTrigger.Deep);

        // Row 1 is emptied to one item: it sits below its target while row 0 stays far above the band cap.
        uint256[] memory row1 = pool.listedIds(1);
        for (uint256 i = 1; i < row1.length; ++i) {
            pool.removeListed(row1[i]);
        }
        IPool p = IPool(address(pool));
        uint256 depth = _boardItems();
        uint256 target0 = PricingLib.rowDepth(depth, 7_000);
        uint256 cap0 = (target0 * (10_000 + 3_000) + 9_999) / 10_000;
        assertGe(p.rowCount(0) + pool.queuedOf(0), cap0, "row 0 is beyond the band cap");
        assertLt(p.rowCount(1) + pool.queuedOf(1), PricingLib.rowDepth(depth, 3_000), "row 1 is below target");
        for (uint256 i; i < 200; ++i) {
            (uint256 row,) = pool.chooseRow(uint256(keccak256(abi.encode("w", i))), 500 + i, 0);
            assertEq(row, 1, "the over target row is not chosen");
        }

        // Back below target the row is chosen again.
        uint256[] memory row0 = pool.listedIds(0);
        uint256 over = p.rowCount(0) + pool.queuedOf(0) - target0;
        for (uint256 i; i < over + 1; ++i) {
            pool.removeListed(row0[i]);
        }
        assertLt(p.rowCount(0) + pool.queuedOf(0), target0, "row 0 below target");
        uint256 hits0;
        for (uint256 i; i < 200; ++i) {
            (uint256 row,) = pool.chooseRow(uint256(keccak256(abi.encode("w", i))), 500 + i, 0);
            if (row == 0) ++hits0;
        }
        assertGt(hits0, 0, "row 0 is chosen once below target");
    }

    function test_noReplacementWhenEveryRowIsAtTarget() public {
        _deposit(4 ether);
        _settleUntilLevel();
        uint256 shares = pool.sharesOf(alice);
        vm.prank(alice);
        pool.withdraw(shares * 9 / 10);
        assertLt(_boardItems(), _count(), "depth fell below the board count");
        assertTrue(_rowOverTarget(0, 7_000) && _rowOverTarget(1, 3_000), "every row is at or above its target");

        uint256 listedBefore = pool.listedCount();
        uint256 queuedBefore = pool.replacementLength();
        _captureListing(_listingOfRow(0));
        _settle();
        assertEq(pool.replacementLength(), queuedBefore, "no replacement is queued");
        assertEq(pool.listedCount(), listedBefore - 1, "the board shrank by the captured item");

        // Targets rise above the counts: the next capture queues a replacement.
        _deposit(40 ether);
        assertFalse(_rowOverTarget(0, 7_000) && _rowOverTarget(1, 3_000), "a row is below its target");
        queuedBefore = pool.replacementLength();
        _captureListing(_listingOfRow(0));
        pool.bookOnly(5);
        assertEq(pool.replacementLength(), queuedBefore + 1, "a replacement is queued");
    }
}
