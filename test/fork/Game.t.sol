// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
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
        fundAndFill(3 ether);
        openMarket(10 ether);
        openGame();
        vm.warp(block.timestamp + 1);
    }

    /// @dev Moves past the maintenance interval so the next sync may change inventory.
    function _window() internal {
        vm.warp(block.timestamp + sys.game.maintenanceInterval());
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
        (, uint80 backing, uint80 cost,, uint16 markup,) = sys.game.items(id);
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
        uint256 markup;
        uint256 margin;
        uint256 expected;
    }

    /// @dev The split of a capture whose escrowed payment is `paid`, per docs/IMPLEMENTOR_DECISIONS.md D7.
    function _lines(uint256 paid, uint256 markupBps) internal view returns (Lines memory l) {
        uint256 base = paid * 10_000 / (10_000 + factory.edgeBps());
        l.proceeds = paid - (paid - base) / 2;
        l.markup = base * markupBps / (10_000 + markupBps);
        l.margin = l.proceeds - base;
        l.expected = base - l.markup;
    }

    function test_pullFulfilledBookedAndSplitToTheWei() public {
        uint256 id = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, 0.01 ether));
        assertEq(uint8(statusOf(id)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        (, uint256 requestBlock, uint256 paid, uint256 listingId,) = pool.acquisitions(id);
        (uint48 tokenId,, uint80 cost,, uint16 markupBps,) = sys.game.items(listingId);
        assertEq(shapes.ownerOf(tokenId), alice);
        Lines memory l = _lines(paid, markupBps);
        // FWA's owner split, from its internal request-time base price, is within 1 wei of the formula; the lines
        // below are exact to the wei against the formula.
        assertApproxEqAbs(pool.ownerProceeds(), l.proceeds, 1, "FWA owner split");
        assertEq(l.markup + l.margin + l.expected, l.proceeds);

        uint256 treasuryBefore = address(sys.treasury).balance;
        uint256 keeperBefore = address(sys.keeperFund).balance;
        vm.txGasPrice(0);
        vm.prank(keeper, keeper);
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 1);
        assertEq(sys.game.markupRouted(), l.markup, "markup line");
        assertEq(sys.game.marginRouted(), l.margin, "margin line");
        assertEq(address(sys.treasury).balance - treasuryBefore, l.margin, "treasury got the margin");
        assertEq(address(sys.keeperFund).balance + keeper.balance - keeperBefore, l.markup, "keeper fund got the markup");
        assertEq(sys.game.bookedGain(), l.expected > cost ? l.expected - cost : 0, "gain");
        assertEq(sys.game.bookedLoss(), l.expected > cost ? 0 : cost - l.expected, "loss");
        uint256 epoch = (requestBlock - sys.farm.openBlock()) / 7_200;
        assertEq(sys.game.epochUnits(epoch), 1);
        assertEq(sys.game.userUnits(epoch, alice), 1);
        (bool convertible,,) = sys.converter.convertible(listingId);
        assertTrue(convertible);
        // the replacement waits for the maintenance window, then lists for the same row
        assertEq(sys.game.liveCount(), 99);
        assertEq(sys.game.replacementsOwed(), cost);
        _window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        assertEq(sys.game.replacementsOwed(), 0);
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
        (uint256 accepted, uint256 resolved, uint256 units) = sys.game.epochTotals(0);
        assertEq(accepted, 2);
        assertEq(resolved, 2);
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
        assertEq(sys.game.seenSeq(), 2);
        assertEq(sys.game.openCount(), 0);
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
        assertEq(sys.game.seenSeq(), 3);
        assertEq(sys.game.pullsBooked(), 1);
        assertGt(sys.game.bookedLoss(), 0, "a 0.1 capture is a booked loss");
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

    function test_deliveryRefundedIsRecoveredAndRelisted() public {
        (uint256 a, uint256 listingId) = _failDelivery(alice);
        // a pending delivery does not stall the walk: it is seen (accepted) and stays open
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 2);
        assertEq(sys.game.openCount(), 1);
        uint256 b = pullAndSettle(bob, 99);
        sys.game.sync(10);
        assertEq(sys.game.seenSeq(), 3, "later pulls keep being booked");
        assertEq(uint8(statusOf(b)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        // after the delivery window the purchaser takes the refund
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        assertEq(uint8(statusOf(a)), uint8(IFWAPool.AcquisitionStatus.DeliveryRefunded));
        (uint48 tokenId, uint80 backing,,,,) = sys.game.items(listingId);
        sys.game.sync(10);
        assertEq(sys.game.openCount(), 0);
        assertEq(sys.game.relistCount(), 0, "relisted in the same maintenance window");
        assertEq(shapes.ownerOf(tokenId), address(pool));
        assertEq(backing, 0.01 ether);
        (uint256 accepted, uint256 resolved, uint256 units) = sys.game.epochTotals(0);
        assertEq(accepted, 2);
        assertEq(resolved, 2);
        assertEq(units, 1, "no unit for the refunded pull");
    }

    function test_neverClaimedDeliveryResolvesAfterGrace() public {
        (uint256 a,) = _failDelivery(alice);
        (, uint256 requestBlock,,,) = pool.acquisitions(a);
        sys.game.sync(10);
        // the epoch ends; the stuck request keeps it open until the grace period passes
        vm.roll(sys.farm.openBlock() + 7_200);
        pullAndSettle(bob, 5); // epoch 1 keeps progressing
        sys.game.sync(10);
        assertFalse(sys.game.isEpochFinal(0), "open request blocks epoch 0");
        vm.roll(requestBlock + sys.game.DELIVERY_GRACE_BLOCKS() + 1);
        sys.game.sync(10);
        assertTrue(sys.game.isEpochFinal(0), "final after the grace period");
        (uint256 accepted, uint256 resolved, uint256 units) = sys.game.epochTotals(0);
        assertEq(accepted, 1);
        assertEq(resolved, 1);
        assertEq(units, 0, "resolved without a unit");
        assertEq(sys.game.openCount(), 1, "economics still open until FWA settles it");
        assertTrue(sys.farm.isFinal(0));
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

    function test_capitalProtectedBeforeDistribution() public {
        // a reserve just under cash: an expensive early win must be paid before anything leaves
        vm.prank(address(sys.timelock));
        sys.game.setCapital(0.84 ether, 30 minutes);
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.1 ether));
        sys.game.sync(10);
        assertEq(sys.game.markupRouted() + sys.game.marginRouted(), 0, "nothing distributed below the reserve");
        assertGt(sys.game.pendingMarkup(), 0);
        assertLt(sys.game.cash(), sys.game.replacementsOwed() + sys.game.reserveTarget());
        // the replacement is paid from cash and the reserve
        _window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        assertEq(sys.game.markupRouted() + sys.game.marginRouted(), 0);
        // gains refill the reserve; once above it, the waiting lines go out
        vm.prank(address(sys.timelock));
        sys.game.setCapital(0.2 ether, 30 minutes);
        pullAndSettle(bob, 3);
        sys.game.sync(10);
        assertGt(sys.game.markupRouted(), 0, "distributed once the reserve is covered");
        assertGe(sys.game.cash(), sys.game.replacementsOwed() + sys.game.reserveTarget());
    }

    function test_reserveTargetBounds() public {
        vm.startPrank(address(sys.timelock));
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(0.19 ether, 30 minutes); // below twice the 0.1 prize
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.game.setCapital(1 ether, 1 days + 1);
        sys.game.setCapital(0.2 ether, 0);
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
        (tokenId,,,,,) = sys.game.items(listingId);
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

    function test_packRowsAreNotMinted() public {
        // this game lists Shapes only (docs/IMPLEMENTOR_DECISIONS.md D3): a Pack row is skipped, not minted
        uint8[] memory kinds = new uint8[](100);
        uint96[] memory backings = new uint96[](100);
        for (uint256 i; i < 100; ++i) {
            backings[i] = cfg.boardBackings[i];
        }
        kinds[0] = 1;
        backings[0] = 0.03 ether;
        vm.prank(address(sys.timelock));
        sys.board.setBoard(kinds, backings, 20);
        uint256 row0;
        for (uint256 i; i < sys.game.liveCount(); ++i) {
            (,,, uint16 row,,) = sys.game.items(sys.game.liveAt(i));
            if (row == 0) row0 = sys.game.liveAt(i);
        }
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, _wordForListing(row0));
        _window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 99, "row 0 stays empty");
        assertEq(sys.game.liveRows() & 1, 0);
    }

    function _wordForListing(uint256 listingId) internal view returns (uint256 prefix) {
        for (uint256 slot = 1; slot < 1000; ++slot) {
            uint256 id = pool.slotToListing(slot);
            if (id == 0) continue;
            (,,,, uint256 weight,,, IFWAPool.ListingStatus st) = pool.listings(id);
            if (st != IFWAPool.ListingStatus.Active) continue;
            if (id == listingId) return prefix;
            prefix += weight;
        }
        revert("listing not active");
    }

    function _slotOfBonusPool() internal returns (uint256 slot) {
        for (slot = 0; slot < 30; ++slot) {
            if (uint256(vm.load(address(sys.farm), bytes32(slot))) == sys.farm.bonusPool()) return slot;
        }
        revert("slot");
    }

    function test_grailMintListRepriceCapture() public {
        // fund the GRAIL reserve as the GrailFund sink would
        vm.deal(address(this), 1 ether);
        sys.game.fundGrail{value: 0.6 ether}(); // the owner seeding the first GRAIL directly
        uint256 a = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(a, wordFor(a, 0.01 ether));
        _window();
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
        _window();
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
        _window();
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
        _window();
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
        assertEq(sys.game.liveCount(), 1, "only the quarantined prize remains");
        // a week later the purchaser takes the refund; the next step recovers the Shape, burns it and sweeps it
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        uint256 vaultBefore = address(sys.vault).balance;
        sys.game.retireStep(10);
        assertEq(address(sys.vault).balance - vaultBefore, 0.01 ether, "the recovered prize's backing reaches the vault");
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
