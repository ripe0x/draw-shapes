// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {Governed} from "../../src/Governed.sol";

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
        fundAndFill(3 ether);
        openMarket(10 ether);
        openGame();
        vm.warp(block.timestamp + 1);
    }

    // ------------------------------------------------------------------ pool and listing

    function test_poolCreatedAndPermanentlyOwned() public {
        assertEq(pool.owner(), address(sys.game));
        assertEq(pool.purchaseOperator(), address(0));
        assertTrue(pool.localPurchasesEnabled());
        vm.prank(address(sys.game));
        vm.expectRevert();
        IOwnable(address(pool)).transferOwnership(alice);
        vm.expectRevert(FwaGame.PoolExists.selector);
        sys.game.createPool(bytes32(uint256(1)));
        // no FWA left in the game
        assertEq(IERC20Like(FWA_TOKEN).balanceOf(address(sys.game)), 0);
    }

    function test_boardListedAtMarkupPrices() public view {
        assertEq(sys.game.liveCount(), 100);
        assertEq(pool.activeListingCount(), 100);
        uint256 id = sys.game.liveAt(0);
        (,,,,, uint256 price,,) = pool.listings(id);
        (, uint80 backing, uint80 cost,, uint16 markup,,) = sys.game.items(id);
        assertEq(cost, backing + 0.001 ether);
        assertEq(price, uint256(cost) * 10_300 / 10_000);
        assertEq(markup, 300);
        // inventory: 80 × 0.01 + 15 × 0.05 + 5 × 0.1
        assertEq(sys.game.inventoryBacking(), 2.05 ether);
        assertEq(sys.game.mintFeesPaid(), 0.1 ether);
        assertEq(sys.game.lent(), 3 ether);
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

    function test_pullFulfilledBookedAndSplitToTheWei() public {
        uint256 id = pull(alice);
        (, uint256 requestBlock, uint256 paid,,) = pool.acquisitions(id);
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, 0.01 ether));
        assertEq(uint8(statusOf(id)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        (,,, uint256 listingId,) = pool.acquisitions(id);
        (uint48 tokenId,, uint80 cost,, uint16 markupBps,,) = sys.game.items(listingId);
        assertEq(shapes.ownerOf(tokenId), alice);

        uint256 treasuryBefore = address(sys.treasury).balance;
        uint256 keeperBefore = address(sys.keeperFund).balance;
        uint256 edge = factory.edgeBps();
        uint256 base = paid * 10_000 / (10_000 + edge);
        uint256 proceeds = paid - (paid - base) / 2;
        uint256 markup = base * markupBps / (10_000 + markupBps);
        uint256 margin = proceeds - base;
        uint256 expected = base - markup;

        // FWA's owner split, from its internal request-time base price, is within 1 wei of the formula
        // (docs/IMPLEMENTOR_DECISIONS.md D7); the lines below are exact to the wei against the formula.
        assertApproxEqAbs(pool.ownerProceeds(), proceeds, 1, "FWA owner split");
        assertEq(markup + margin + expected, proceeds);
        vm.txGasPrice(0);
        vm.prank(keeper, keeper);
        sys.game.sync(10);

        assertEq(sys.game.pullsBooked(), 1);
        assertEq(sys.game.markupRouted(), markup, "markup line");
        assertEq(sys.game.marginRouted(), margin, "margin line");
        assertEq(address(sys.treasury).balance - treasuryBefore, margin, "treasury got the margin");
        // KeeperFund got the markup and paid the keeper's tip out of it
        assertEq(address(sys.keeperFund).balance + keeper.balance - keeperBefore, markup, "keeper fund got the markup");
        assertEq(sys.game.bookedGain(), expected > cost ? expected - cost : 0, "gain");
        assertEq(sys.game.bookedLoss(), expected > cost ? 0 : cost - expected, "loss");
        // ledger
        uint256 epoch = (requestBlock - sys.farm.openBlock()) / 7_200;
        assertEq(sys.game.epochUnits(epoch), 1);
        assertEq(sys.game.userUnits(epoch, alice), 1);
        assertEq(sys.game.delivered(tokenId), 1);
        // replacement listed for the same row
        assertEq(sys.game.liveCount(), 100);
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
        assertEq(sys.game.nextSeq(), 3);
        assertEq(sys.game.pullsBooked(), 0);
        uint256 epoch = 0;
        (uint256 booked, uint256 units) = sys.game.epochTotals(epoch);
        assertEq(booked, 2);
        assertEq(units, 0);
        assertEq(pool.acquisitionRefundCredit(alice), pool.acquisitionRefundCredit(bob));
    }

    function test_walkTimedOutBeforeFwaProcessesIt() public {
        uint256 a = pull(alice);
        vm.roll(block.number + pool.selectionTimeoutBlocks() + 1);
        deliverWord(a, 5);
        // TimedOut is terminal for the walk even before FWA's processor turns it into Expired
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.TimedOut));
        sys.game.sync(10);
        assertEq(sys.game.nextSeq(), 2);
    }

    function test_walkRefundedOnSlippage() public {
        // `a` captures a 0.1 prize, which lowers the fee; `b` allowed no negative slippage and is refunded.
        uint256 a = pull(alice);
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, total);
        vm.prank(bob);
        uint256 b = pool.acquire{value: total}(bob, fee, 0, 0, version, block.timestamp + 1 hours);
        vm.roll(block.number + 3);
        uint256 w = wordFor(a, 0.1 ether);
        deliverWord(a, w);
        deliverWord(b, 1);
        pool.processAcquisitions(10);
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Refunded));
        sys.game.sync(10);
        assertEq(sys.game.nextSeq(), 3);
        assertEq(sys.game.pullsBooked(), 1);
        assertGt(sys.game.bookedLoss(), 0, "a 0.1 capture is a booked loss");
    }

    function test_deliveryRefundedIsRecoveredAndRelisted() public {
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        uint256 w = wordFor(a, 0.01 ether);
        // Force the atomic delivery to fail: the only way a Shapes transferFrom to an address can fail.
        vm.mockCallRevert(SHAPES, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(a, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        // DeliveryPending halts the walk
        try sys.game.sync(10) {} catch {}
        assertEq(sys.game.nextSeq(), 1);
        // after the delivery window the purchaser takes the refund
        (,,, uint256 listingId,) = pool.acquisitions(a);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.DeliveryRefunded));
        (uint48 tokenId, uint80 backing,,,,,) = sys.game.items(listingId);
        uint256 backingBefore = sys.game.inventoryBacking();
        sys.game.sync(10);
        assertEq(sys.game.nextSeq(), 2);
        assertEq(sys.game.pullsBooked(), 0, "no unit for a refunded pull");
        // the same token is listed again on the same row
        assertEq(shapes.ownerOf(tokenId), address(pool));
        assertEq(sys.game.liveCount(), 100);
        assertEq(sys.game.inventoryBacking(), backingBefore);
        assertEq(backing, 0.01 ether);
    }

    function test_syncRevertsWithoutWork() public {
        vm.expectRevert(FwaGame.NoWork.selector);
        sys.game.sync(10);
    }

    // ------------------------------------------------------------------ conversion

    function test_convertDeliveredShape() public {
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        sys.game.sync(10);
        (,,, uint256 listingId,) = pool.acquisitions(a);
        (uint48 tokenId,,,,,,) = sys.game.items(listingId);

        uint256 bonusBefore = sys.farm.bonusPool();
        vm.startPrank(alice);
        shapes.approve(address(sys.game), tokenId);
        (uint256 out, uint256 bonus) = sys.game.convert(tokenId, 1, false);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(bonus, out * 200 / 10_000, "2% bonus at the executed price");
        assertEq(sys.engine.balanceOf(alice), out + bonus);
        assertEq(sys.farm.bonusPool(), bonusBefore - bonus);
        assertEq(sys.game.delivered(tokenId), 2);
        // once only
        vm.prank(alice);
        vm.expectRevert(FwaGame.NotConvertible.selector);
        sys.game.convert(tokenId, 1, false);
    }

    function test_convertRejectsShapesNotDeliveredByPool() public {
        uint256 id = sys.game.liveAt(0);
        (uint48 tokenId,,,,,,) = sys.game.items(id);
        vm.expectRevert(FwaGame.NotConvertible.selector);
        sys.game.convert(tokenId, 0, true);
    }

    function test_convertWithoutBonusAfterPoolRetired() public {
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        sys.game.sync(10);
        (,,, uint256 listingId,) = pool.acquisitions(a);
        (uint48 tokenId,,,,,,) = sys.game.items(listingId);
        // drain the bonus pool
        vm.store(address(sys.farm), bytes32(uint256(_slotOfBonusPool())), bytes32(0));
        vm.startPrank(alice);
        shapes.approve(address(sys.game), tokenId);
        vm.expectRevert(FwaGame.BonusUnavailable.selector);
        sys.game.convert(tokenId, 1, false);
        (uint256 out, uint256 bonus) = sys.game.convert(tokenId, 1, true);
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

    // ------------------------------------------------------------------ GRAIL

    function test_grailMintListRepriceCapture() public {
        // fund the GRAIL reserve as the GrailFund sink would
        vm.deal(address(this), 1 ether);
        sys.game.fundGrail{value: 0.6 ether}();
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        sys.game.sync(10);
        uint256 g = sys.game.grailListing();
        assertGt(g, 0, "GRAIL listed");
        (,,,,, uint256 price,,) = pool.listings(g);
        assertEq(price, 0.5 ether * 9_500 / 10_000, "lists at 95% of backing");
        assertEq(sys.game.grailReserve(), 0.6 ether - 0.501 ether);

        // 100 booked pulls later the policy lowers it by 1%
        for (uint256 i; i < 100; ++i) {
            uint256 r = pull(alice);
            vm.roll(block.number + 3);
            deliverWord(r, uint256(keccak256(abi.encode(i))));
            pool.processAcquisitions(5);
            if (sys.game.grailListing() != g) break;
            if (i % 10 == 9) syncAll();
        }
        syncAll();
        if (sys.game.grailListing() == g) {
            (,,,,, price,,) = pool.listings(g);
            assertEq(price, 0.5 ether * 9_400 / 10_000, "decayed one step");
        }
        // capture the GRAIL
        uint256 c = pull(bob);
        vm.roll(block.number + 3);
        deliverWord(c, wordFor(c, 0.5 ether));
        sys.game.sync(10);
        assertEq(sys.game.grailListing(), 0);
        assertEq(sys.game.grailStep(), 1);
        assertEq(sys.game.grailCapturedBacking(), 0.5 ether);
    }

    function test_grailPriceNeverBelowHardFloor() public {
        vm.prank(address(sys.timelock));
        sys.grail.set(new uint256[](1), 10_000, 0, 10_000, 1); // policy asks for price 0
        uint256[] memory ladder = new uint256[](1);
        ladder[0] = 0.5 ether;
        vm.prank(address(sys.timelock));
        sys.grail.set(ladder, 1_000, 1_000, 0, 1); // 10% of backing, below the 50% hard floor
        vm.deal(address(this), 1 ether);
        sys.game.fundGrail{value: 0.6 ether}();
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, 3);
        sys.game.sync(10);
        (,,,, uint256 weight, uint256 price,,) = pool.listings(sys.game.grailListing());
        assertGe(price, 0.25 ether, "hard floor 50%");
        assertLe(weight * 10_000 / pool.totalWeight(), 1_000, "probability <= 10%");
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
        sys.game.sync(10);
        uint256 id = sys.game.liveAt(sys.game.liveCount() - 1);
        (,,,,, uint256 price,,) = pool.listings(id);
        assertEq(price, 0.011 ether * 10_500 / 10_000);
    }

    function test_settersAreTimelockOnly() public {
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.setModule("board", address(sys.board));
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.openGame();
        vm.expectRevert(Governed.NotGovernance.selector);
        sys.game.setAcquisitionsEnabled(false);
        vm.expectRevert(FwaGame.NotVault.selector);
        sys.game.retire();
        vm.expectRevert(FwaGame.NotVault.selector);
        sys.game.receiveFunding{value: 0}();
    }

    // ------------------------------------------------------------------ retirement

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
        // everything but the revenue routed during the steps comes back
        assertApproxEqAbs(address(sys.vault).balance - vaultBefore, expected, 0.02 ether);
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
}
