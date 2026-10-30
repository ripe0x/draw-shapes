// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {PoolOwner} from "../../src/game/PoolOwner.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {Governed} from "../../src/Governed.sol";
import {Converter} from "../../src/game/Converter.sol";

interface IOwnable {
    function transferOwnership(address newOwner) external payable;
}

interface IFactoryAdmin {
    function setInventoryChangeCooldown(uint32 cooldown) external;
    function owner() external view returns (address);
    function setGlobalWithdrawOnly(bool enabled) external;
}

/// @notice FwaGame on a pinned mainnet fork: real Shapes, Shape Packs, FWA factory, FWA VRF service.
contract GameForkTest is ForkBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
        openGame();
        vm.warp(block.timestamp + 1);
    }

    function _window() internal {
        window();
    }

    // ------------------------------------------------------------------ pool and listing

    function test_poolCreatedAndPermanentlyOwned() public {
        assertEq(pool.owner(), address(sys.poolOwner));
        assertEq(pool.purchaseOperator(), address(sys.poolOwner), "the gate sees every purchase");
        assertTrue(pool.localPurchasesEnabled());
        vm.prank(address(sys.poolOwner));
        vm.expectRevert();
        IOwnable(address(pool)).transferOwnership(alice);
        vm.expectRevert(PoolOwner.PoolExists.selector);
        sys.poolOwner.createPool();
        // no FWA left behind
        assertEq(IERC20Like(FWA_TOKEN).balanceOf(address(sys.poolOwner)), 0);
    }

    function test_boardListedAtMarkupPrices() public view {
        assertEq(sys.game.liveCount(), 100);
        assertEq(pool.activeListingCount(), 100);
        uint256 id = sys.game.liveAt(0);
        (,,,,, uint256 price,,) = pool.listings(id);
        (, uint72 backing, uint72 cost,, uint16 markup,,,) = sys.game.items(id);
        assertEq(cost, backing + 0.001 ether);
        assertEq(price, uint256(cost) * 10_500 / 10_000);
        assertEq(markup, 500);
        // inventory: 30 × 0.01 + 45 × 0.05 + 25 × 0.5, carried at cost with 100 mint fees
        assertEq(sys.game.inventoryBacking(), 15.05 ether);
        assertEq(sys.game.inventoryCost(), 15.15 ether);
        assertEq(sys.game.capitalIn(), OPENING_CAPITAL);
        assertEq(sys.game.profit(), 0, "the initial fill is capital, not an expense");
        // the reference quote: (backing + mint fee) × 1.05 listing prices, FWA edge 5%
        (uint256 fee,,) = pool.quoteAcquisitionPrice(1);
        assertApproxEqRel(fee, 0.03012685 ether, 1e12);
    }

    function test_listingRespectsInventoryCooldown() public {
        IFactoryAdmin f = IFactoryAdmin(FACTORY);
        vm.prank(f.owner());
        f.setInventoryChangeCooldown(60);
        vm.warp(block.timestamp + 60);
        // a capture frees a row; the replacement listing starts the cooldown
        uint256 id = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(id, 7);
        _window();
        sys.game.sync(10);
        uint256 resume = pool.purchasesResumeAt();
        assertEq(resume, vm.getBlockTimestamp() + 60);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("InventoryChangeCooldownActive(uint256)", resume));
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, block.timestamp + 1 hours);
        vm.warp(resume);
        pull(bob);
    }

    // ------------------------------------------------------------------ pulls and the walk

    struct Lines {
        uint256 proceeds;
        uint256 ops;
    }

    /// @dev Proceeds and operating allocation of a capture whose escrowed payment is `paid`
    ///      (docs/IMPLEMENTOR_DECISIONS.md D31).
    function _lines(uint256 paid, uint256 markupBps) internal view returns (Lines memory l) {
        uint256 base = paid * 10_000 / (10_000 + factory.edgeBps());
        l.proceeds = paid - (paid - base) / 2;
        l.ops = base * 10_000 / (10_000 + markupBps) * 300 / 10_000;
    }

    function test_pullFulfilledBookedToTheWei() public {
        uint256 id = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, 0.01 ether));
        assertEq(uint8(statusOf(id)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        (, uint256 requestBlock, uint256 paid, uint256 listingId,) = pool.acquisitions(id);
        (uint48 tokenId,, uint72 cost,, uint16 markupBps,,,) = sys.game.items(listingId);
        assertEq(shapes.ownerOf(tokenId), alice);
        Lines memory l = _lines(paid, markupBps);
        // FWA's owner split, from its request-time base price, is within 1 wei of the formula (never below it)
        assertApproxEqAbs(pool.ownerProceeds(), l.proceeds, 1, "FWA owner split");
        assertGe(pool.ownerProceeds(), l.proceeds);
        uint256 actual = pool.ownerProceeds();

        uint256 keeperBefore = address(sys.keeperFund).balance;
        vm.txGasPrice(0);
        vm.prank(keeper, keeper);
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 1);
        assertEq(sys.game.turnover(), paid);
        // booked at the booking edge, then trued up to what FWA paid once nothing is outstanding
        assertEq(sys.game.proceedsBooked(), actual, "booked, then trued up");
        assertEq(sys.game.proceedsCollected(), actual);
        assertEq(sys.game.revenue(), actual, "revenue: owner proceeds");
        assertEq(sys.game.prizeExpense(), cost, "expense: the prize's carried cost, once");
        assertEq(sys.game.opsAccrued(), l.ops, "ops: 3% of the expected replacement cost");
        assertEq(sys.game.opsPaid(), l.ops, "paid to KeeperFund");
        assertEq(address(sys.keeperFund).balance + keeper.balance - keeperBefore, l.ops);
        int256 p = int256(actual) - int256(uint256(cost)) - int256(l.ops);
        assertEq(sys.game.profit(), p);
        assertGt(p, 0, "a cheap win is a profit");
        assertEq(sys.game.distributed(), uint256(p), "the whole realised profit is distributable");
        assertEq(sys.buyback.profitReceived(), uint256(p));
        assertEq(address(sys.buyback).balance, uint256(p));
        uint256 epoch = (requestBlock - sys.farm.openBlock()) / 7_200;
        assertEq(sys.game.epochWeight(epoch), paid, "weight: ticket ETH");
        assertEq(sys.game.userWeight(epoch, alice), paid);
        (bool convertible,,) = sys.converter.convertible(listingId);
        assertTrue(convertible);
        // the maintenance window was open (no inventory change since the fill): the replacement listed at once
        assertEq(sys.game.liveCount(), 100);
        assertEq(sys.game.replacementsOwed(), 0);
        assertEq(sys.game.prizeExpense(), cost, "the replacement purchase is not a second expense");
        assertEq(sys.game.inventoryCost(), 15.15 ether);
    }

    function test_walkExpiredAndTimedOut() public {
        uint256 a = pull(alice);
        uint256 b = pull(bob);
        // both words late: `a` never arrives (Expired), `b` arrives after its deadline (TimedOut)
        vm.roll(block.number + pool.selectionTimeoutBlocks() + 1);
        deliverWord(b, 99);
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.TimedOut));
        // the walk stops at the still-Pending `a` until FWA expires it
        sys.game.sync(10);
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.Expired));
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Expired));
        assertEq(sys.game.seenSeq(), 3);
        assertEq(sys.game.pullsBooked(), 0);
        (uint256 accepted, uint256 resolved, uint256 weight) = sys.game.epochTotals(0);
        assertEq(accepted, 2);
        assertEq(resolved, 2);
        assertEq(weight, 0, "refunded draws carry no weight");
        assertEq(sys.game.revenue(), 0);
        assertEq(pool.acquisitionRefundCredit(alice), pool.acquisitionRefundCredit(bob));
    }

    function test_walkTimedOutBeforeFwaProcessesIt() public {
        uint256 a = pull(alice);
        vm.roll(block.number + pool.selectionTimeoutBlocks() + 1);
        deliverWord(a, 5);
        // TimedOut is terminal for the walk even before FWA's processor turns it into Expired
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.TimedOut));
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 2);
        assertEq(sys.game.openCount(), 0);
    }

    function test_walkRefundedOnSlippage() public {
        // `a` captures a 0.5 prize, which lowers the fee; `b` allowed no negative slippage and is refunded.
        uint256 a = pull(alice);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, total);
        vm.prank(bob);
        uint256 b = pool.acquire{value: total}(bob, fee, 0, 0, version, block.timestamp + 1 hours);
        vm.roll(block.number + 3);
        uint256 w = wordFor(a, 0.5 ether);
        deliverWord(a, w);
        deliverWord(b, 1);
        pool.processAcquisitions(10);
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Refunded));
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 3);
        assertEq(sys.game.pullsBooked(), 1);
        assertLt(sys.game.profit(), 0, "a 0.5 capture is a loss, carried");
        assertEq(sys.game.distributed(), 0);
    }

    function _failDelivery(address who) internal returns (uint256 requestId, uint256 listingId) {
        requestId = pull(who);
        vm.roll(block.number + 3);
        uint256 w = wordFor(requestId, 0.01 ether);
        // Force the atomic delivery to fail: the only way a Shapes transferFrom to an address can fail.
        vm.mockCallRevert(SHAPES, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(requestId, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(requestId)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        (,,, listingId,) = pool.acquisitions(requestId);
    }

    function test_deliveryRefundedIsRecoveredAndBurned() public {
        (uint256 a, uint256 listingId) = _failDelivery(alice);
        // a pending delivery does not stall the walk: it is seen (accepted), stays open, and its row is vacated
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 2);
        assertEq(sys.game.openCount(), 1);
        (, uint72 backing, uint72 cost,,,,,) = sys.game.items(listingId);
        (,,,,,,, bool live) = sys.game.items(listingId);
        assertFalse(live, "FWA took it out of the draw; so does the game");
        assertEq(sys.game.liveCount(), 100, "and its row is replaced while the delivery is pending");
        uint256 b = pullAndSettle(bob, 99);
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 3, "later pulls keep being booked");
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        _window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        // after the delivery window the purchaser takes the refund
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.DeliveryRefunded));
        (uint48 tokenId,,,,,,,) = sys.game.items(listingId);
        uint256 expenseBefore = sys.game.prizeExpense();
        uint256 cashBefore = sys.game.cash();
        sys.game.sync(10);
        assertEq(sys.game.openCount(), 0);
        vm.expectRevert();
        shapes.ownerOf(tokenId); // recovered and burned
        assertEq(sys.game.prizeExpense() - expenseBefore, cost - backing, "only the mint fee is written off");
        assertGe(sys.game.cash(), cashBefore + backing - sys.game.opsOwed());
        assertEq(sys.game.liveCount(), 100, "no extra listing: the row was already replaced");
        (uint256 accepted, uint256 resolved, uint256 weight) = sys.game.epochTotals(0);
        assertEq(accepted, 2);
        assertEq(resolved, 2);
        (,, uint256 paidB,,) = pool.acquisitions(b);
        assertEq(weight, paidB, "no weight for the refunded pull");
    }

    function test_neverRefundedDeliveryDoesNotStopTheGame() public {
        (uint256 a, uint256 listingId) = _failDelivery(alice);
        (, uint256 requestBlock,,,) = pool.acquisitions(a);
        sys.game.sync(10);
        (,, uint72 cost,,,,,) = sys.game.items(listingId);
        // the row is replaced; the stuck prize stays carried at cost until FWA settles it
        assertEq(sys.game.liveCount(), 100);
        assertEq(sys.game.replacementsOwed(), 0);
        assertEq(sys.game.inventoryCost(), 15.15 ether + cost, "the quarantined prize is still an asset");
        // the epoch ends; the stuck request keeps it open until the grace period passes
        vm.roll(sys.farm.openBlock() + 7_200);
        pullAndSettle(bob, 5); // epoch 1 keeps progressing
        sys.game.sync(10);
        assertFalse(sys.game.isEpochFinal(0), "open request blocks epoch 0");
        vm.roll(requestBlock + sys.game.DELIVERY_GRACE_BLOCKS() + 1);
        sys.game.sync(10);
        assertTrue(sys.game.isEpochFinal(0), "final after the grace period");
        (uint256 accepted, uint256 resolved, uint256 weight) = sys.game.epochTotals(0);
        assertEq(accepted, 1);
        assertEq(resolved, 1);
        assertEq(weight, 0, "resolved without weight");
        assertEq(sys.game.openCount(), 1, "economics still open until FWA settles it");
        assertTrue(sys.farm.isFinal(0));
        assertTrue(pool.localPurchasesEnabled(), "purchases stay open");
    }

    function test_acceptedComesFromFwaIssuance() public {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = pull(i % 2 == 0 ? alice : bob);
        }
        vm.roll(block.number + 3);
        deliverWord(ids[0], 1);
        pool.processAcquisitions(1);
        sys.game.sync(50);
        (uint256 accepted, uint256 resolved,) = sys.game.epochTotals(0);
        assertEq(accepted, 10, "every issued request is accepted");
        assertEq(resolved, 1);
        vm.roll(sys.farm.openBlock() + 7_200);
        assertFalse(sys.game.isEpochFinal(0), "ten issued, one resolved: not final");
        // the other nine time out and expire; the epoch becomes final
        sys.game.sync(50);
        (accepted, resolved,) = sys.game.epochTotals(0);
        assertEq(resolved, 10);
        assertTrue(sys.game.isEpochFinal(0));
    }

    function _capital(uint256 reserve) internal view returns (FwaGame.Capital memory c) {
        c = cfg.capital;
        c.reserveTarget = reserve;
    }

    function test_reserveTargetBounds() public {
        vm.startPrank(address(sys.timelock));
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(_capital(0.99 ether)); // below twice the 0.5 prize
        FwaGame.Capital memory c = _capital(1 ether);
        c.maintenanceInterval = 1 days + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(c);
        c = _capital(1 ether);
        c.minLiveBps = 4_999;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(c);
        c = _capital(1 ether);
        c.maxEdgeBps = 1_001;
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(c);
        sys.game.setCapital(_capital(1 ether));
        vm.stopPrank();
    }

    function test_syncRevertsWithoutWork() public {
        vm.expectRevert(FwaGame.NoWork.selector);
        sys.game.sync(10);
    }

    // ------------------------------------------------------------------ conversion

    function _winShape(address who) internal returns (uint256 listingId, uint48 tokenId) {
        uint256 a = pull(who);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        sys.game.sync(10);
        (,,, listingId,) = pool.acquisitions(a);
        (tokenId,,,,,,,) = sys.game.items(listingId);
    }

    function test_convertDeliveredShape() public {
        (uint256 listingId, uint48 tokenId) = _winShape(alice);
        uint256 bonusBefore = sys.farm.bonusPool();
        vm.startPrank(alice);
        shapes.approve(address(sys.converter), tokenId);
        (uint256 out, uint256 bonus) = sys.converter.convert(listingId, 1, false);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(bonus, out * 200 / 10_000, "2% bonus at the executed price");
        assertEq(sys.engine.balanceOf(alice), out + bonus);
        assertEq(sys.farm.bonusPool(), bonusBefore - bonus);
        assertTrue(sys.converter.converted(listingId));
        assertEq(sys.converter.conversions(), 1);
        assertEq(sys.converter.totalEthIn(), 0.01 ether, "the redeemed backing, no more");
        assertEq(sys.converter.totalEngineOut(), out);
        vm.prank(alice);
        vm.expectRevert(Converter.NotConvertible.selector);
        sys.converter.convert(listingId, 1, false);
    }

    function test_secondaryHolderConvertsAndBonusCappedBySellFee() public {
        (uint256 listingId, uint48 tokenId) = _winShape(alice);
        vm.prank(alice);
        shapes.transferFrom(alice, bob, tokenId);
        // a sell fee of 1% caps the 2% bonus at 1%
        vm.prank(address(sys.timelock));
        sys.swapPolicy.setFee(100);
        assertEq(sys.converter.bonusBps(), 100);
        vm.startPrank(bob);
        shapes.approve(address(sys.converter), tokenId);
        (uint256 out, uint256 bonus) = sys.converter.convert(listingId, 1, false);
        vm.stopPrank();
        assertEq(bonus, out * 100 / 10_000);
        assertEq(sys.engine.balanceOf(bob), out + bonus);
    }

    function test_convertRejectsListingsNotDelivered() public {
        uint256 id = sys.game.liveAt(0); // still listed, not delivered
        vm.expectRevert(Converter.NotConvertible.selector);
        sys.converter.convert(id, 0, true);
        vm.expectRevert(Converter.NotConvertible.selector);
        sys.converter.convert(999_999, 0, true);
    }

    function test_convertWithoutBonusWhenPoolEmpty() public {
        (uint256 listingId, uint48 tokenId) = _winShape(alice);
        vm.store(address(sys.farm), bytes32(uint256(_slotOfBonusPool())), bytes32(0));
        vm.startPrank(alice);
        shapes.approve(address(sys.converter), tokenId);
        vm.expectRevert(Converter.BonusUnavailable.selector);
        sys.converter.convert(listingId, 1, false);
        (uint256 out, uint256 bonus) = sys.converter.convert(listingId, 1, true);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(bonus, 0);
    }

    function _slotOfBonusPool() internal returns (uint256 slot) {
        for (slot = 0; slot < 30; ++slot) {
            if (uint256(vm.load(address(sys.farm), bytes32(slot))) == sys.farm.bonusPool()) return slot;
        }
        revert("slot");
    }

    // ------------------------------------------------------------------ bounds and access

    function test_markupClampedToHardCap() public {
        // a policy that asks for 20% markup lists at 5%
        MarkupPolicy p = new MarkupPolicy();
        vm.prank(address(sys.timelock));
        sys.game.setModule("pricing", address(p));
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        _window();
        sys.game.sync(10);
        uint256 id = sys.game.liveAt(sys.game.liveCount() - 1);
        (,,,,, uint256 price,,) = pool.listings(id);
        assertEq(price, 0.011 ether * 10_500 / 10_000, "a 20% markup request lists at the 5% cap");
    }

    function test_settersAreTimelockOnly() public {
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.setModule("board", address(sys.board));
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.openGame();
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.setPaused(true);
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.setCapital(cfg.capital);
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.startPromotion(0.5 ether, 9_000, block.number + 100);
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.releasePromotion(0);
        vm.expectRevert(FwaGame.NotVault.selector);
        sys.game.retire();
        vm.expectRevert(FwaGame.NotVault.selector);
        sys.game.receiveFunding{value: 0}();
        vm.expectRevert(FwaGame.NotKeeperFund.selector);
        sys.game.returnOps{value: 0}();
    }

    // ------------------------------------------------------------------ retirement

    function test_stuckDeliveryDoesNotBlockRetirement() public {
        (, uint256 listingId) = _failDelivery(alice);
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        vm.roll(block.number + 40);
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertTrue(sys.game.retired(), "retired with a prize still in delivery quarantine");
        assertEq(sys.vault.activeGame(), address(0));
        assertEq(sys.game.liveCount(), 0, "only the quarantined prize remains, off the board");
        assertGt(sys.game.inventoryBacking(), 0);
        // a week later the purchaser takes the refund; the next step recovers the Shape, burns it and sweeps it
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        uint256 vaultBefore = address(sys.vault).balance;
        sys.game.retireStep(10);
        assertEq(
            address(sys.vault).balance - vaultBefore, 0.01 ether, "the recovered prize's backing reaches the vault"
        );
        assertEq(address(sys.game).balance, 0);
        assertEq(sys.game.liveCount(), 0);
    }

    function test_retireReturnsEverythingToVault() public {
        _retire(false);
    }

    function test_retireWhileFactoryWithdrawOnly() public {
        _retire(true);
    }

    function _retire(bool withdrawOnly) internal {
        uint256 a = pull(alice);
        pull(bob); // left pending: expires during retirement
        vm.roll(block.number + 3);
        deliverWord(a, 11);
        if (withdrawOnly) {
            IFactoryAdmin f = IFactoryAdmin(FACTORY);
            vm.prank(f.owner());
            f.setGlobalWithdrawOnly(true);
        }
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        assertTrue(pool.retired());
        vm.roll(block.number + 40);
        uint256 vaultBefore = address(sys.vault).balance;
        uint256 expected = address(sys.game).balance + sys.game.inventoryBacking();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertTrue(sys.game.retired());
        assertEq(sys.game.liveCount(), 0);
        assertEq(sys.game.inventoryBacking(), 0);
        assertEq(address(sys.game).balance, 0);
        assertEq(sys.vault.activeGame(), address(0));
        // everything but the operating allocation and profit paid during the steps comes back
        assertApproxEqAbs(address(sys.vault).balance - vaultBefore, expected, 0.05 ether);
        assertEq(pool.activeListingCount(), 0);
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract MarkupPolicy {
    function listPrice(uint8, uint256, uint256 cost) external pure returns (uint256) {
        return cost * 12_000 / 10_000;
    }

    function conversionBonusBps() external pure returns (uint256) {
        return 200;
    }

    function opsBps() external pure returns (uint256) {
        return 300;
    }
}
