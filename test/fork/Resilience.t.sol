// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {PrizeVault} from "../../src/game/PrizeVault.sol";

interface IPacks721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function approve(address to, uint256 tokenId) external;
    function balanceOf(address owner) external view returns (uint256);
    function MIN_PACK_VALUE() external view returns (uint256);
}

/// @dev A module that reverts on every call.
contract RevertingModule {
    fallback() external {
        revert("module down");
    }
}

/// @notice What the collection-games review asked for (docs/IMPLEMENTOR_DECISIONS.md D45-D52): the purchase gate during
///         a keeper outage, step-by-step recovery when a module reverts, booking that configuration cannot move, Shape
///         Packs end to end, and the keeper top-up's lifetime limit.
contract ResilienceForkTest is ForkBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    IPacks721 packs = IPacks721(SHAPE_PACKS);

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
        openGame();
        vm.warp(block.timestamp + 1);
    }

    function _settle(uint256 id, uint256 backing) internal {
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, backing));
        pool.processAcquisitions(10);
    }

    function _tryPull(address who) internal returns (bool ok, uint256 id) {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(who, who.balance + total);
        vm.prank(who);
        try pool.acquire{value: total}(who, fee, 0, 10_000, version, block.timestamp + 1 hours) returns (uint256 r) {
            (ok, id) = (true, r);
        } catch (bytes memory err) {
            assertEq(bytes4(err), bytes4(keccak256("PurchaseNotAllowed()")), "only the gate refuses");
        }
    }

    // ------------------------------------------------------------------ keeper outage

    /// @notice Nobody syncs for a day while players buy directly at FWA: the gate, reading only live FWA state, stops
    ///         purchases while a full batch and the floor are still in the draw; when a keeper returns, one sync
    ///         books every pull, refills the board and the gate reopens.
    function test_keeperOutageWithDirectPurchasesThenRecovery() public {
        uint256 captures;
        for (uint256 i; i < 40; ++i) {
            (bool ok, uint256 id) = _tryPull(alice);
            if (!ok) break;
            _settle(id, 0.01 ether);
            ++captures;
            assertGe(pool.activeListingCount(), 80, "never below the floor");
        }
        // admitted while live >= unsettled + 5 + 80: the 16th purchase starts at 85 and leaves 84
        assertEq(captures, 16, "16 captures from a full board");
        assertFalse(sys.poolOwner.canPurchase(alice));
        assertEq(sys.game.pullsBooked(), 0, "no keeper: nothing booked");
        // a day later a keeper returns
        vm.warp(block.timestamp + 1 days);
        vm.txGasPrice(1 gwei);
        vm.prank(keeper, keeper);
        sys.game.sync(50);
        assertEq(sys.game.pullsBooked(), 16, "every pull booked in one call");
        assertGt(keeper.balance, 0, "and the keeper paid");
        syncAll();
        assertEq(sys.game.liveCount(), 100, "refilled");
        assertTrue(sys.poolOwner.canPurchase(alice), "the gate reopens");
        assertTrue(pool.localPurchasesEnabled());
    }

    // ------------------------------------------------------------------ module failures

    /// @notice A reverting board or pricing module stops only maintenance and admission: booking, payment and
    ///         tips go on, and restoring the module resumes listing.
    function test_revertingModulesStopOnlyTheirSteps() public {
        RevertingModule bad = new RevertingModule();
        vm.prank(address(sys.timelock));
        sys.game.setModule("board", address(bad));
        for (uint256 i; i < 3; ++i) {
            _settle(pull(alice), 0.01 ether);
        }
        window();
        vm.expectEmit(address(sys.game));
        emit FwaGame.StepFailed("maintenance");
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 3, "booked without the board");
        assertEq(sys.game.liveCount(), 97, "nothing listed");
        assertGt(sys.game.opsPaid(), 0, "operating allocation paid");
        // a broken pricing module, board restored: still no listing, still booking
        vm.startPrank(address(sys.timelock));
        sys.game.setModule("board", address(sys.board));
        sys.game.setModule("pricing", address(bad));
        vm.stopPrank();
        _settle(pull(bob), 0.01 ether);
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 4);
        assertEq(sys.game.liveCount(), 96);
        vm.prank(address(sys.timelock));
        sys.game.setModule("pricing", address(sys.pricing));
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100, "restored: the waiting rows list");
    }

    // ------------------------------------------------------------------ booking

    /// @notice A listing's markup and operating allocation are fixed when it lists, and proceeds are booked at the
    ///         highest FWA edge ever accepted, so later configuration changes cannot move a booked result; the
    ///         true-up then matches the books to what FWA actually paid.
    function test_bookingUnchangedByConfigurationChanges() public {
        uint256 id = pull(alice);
        // configuration moves after the listing and the purchase
        vm.startPrank(address(sys.timelock));
        sys.pricing.set(200, 200, 100);
        FwaGame.Capital memory c = cfg.capital;
        c.maxEdgeBps = 800;
        sys.game.setCapital(c);
        c.maxEdgeBps = 300;
        sys.game.setCapital(c);
        vm.stopPrank();
        assertEq(sys.game.bookingEdgeBps(), 800, "the highest edge ever accepted");
        _settle(id, 0.01 ether);
        (,, uint256 paid, uint256 listingId,) = pool.acquisitions(id);
        (,, uint72 cost,, uint16 markupBps, uint16 opsBps,,) = sys.game.items(listingId);
        assertEq(markupBps, 500, "frozen at listing");
        assertEq(opsBps, 300, "frozen at listing");
        uint256 actual = pool.ownerProceeds();
        sys.game.sync(10);
        uint256 base = paid * 10_000 / 10_800;
        assertEq(sys.game.opsAccrued(), base * 10_000 / 10_500 * 300 / 10_000, "ops at the frozen 3%");
        assertEq(sys.game.revenue(), actual, "booked low at 8%, trued up to FWA's 5%");
        assertEq(sys.game.prizeExpense(), cost);
    }

    // ------------------------------------------------------------------ Shape Packs

    /// @notice Packs end to end on the real Shape Packs contract: the board takes Pack rows as rows vacate, the
    ///         PoolOwner mints and lists them, a winner receives a Pack, converts it (redeemed to ETH, bought into
    ///         ENGINE), a failed Pack delivery is recovered and redeemed, and retirement redeems every Pack listed.
    function test_packsMintListWinConvertRecoverRetire() public {
        assertEq(packs.MIN_PACK_VALUE(), 0.03 ether);
        // the 30 cheapest rows become 0.03 ETH Packs
        uint8[] memory kinds = new uint8[](100);
        uint96[] memory backings = new uint96[](100);
        for (uint256 i; i < 100; ++i) {
            (kinds[i], backings[i]) = sys.board.rowAt(i);
            if (i < 30) (kinds[i], backings[i]) = (1, 0.03 ether);
        }
        vm.prank(address(sys.timelock));
        sys.board.setBoard(kinds, backings, 3);
        uint256 packCost = sys.poolOwner.costOf(1, 0.03 ether);
        assertGt(packCost, 0.03 ether, "backing plus one mint fee per Shape inside");
        // three cheap Shapes captured: three Pack rows list
        for (uint256 i; i < 3; ++i) {
            _settle(pull(alice), 0.01 ether);
        }
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        uint256 packListings;
        for (uint256 i; i < sys.game.liveCount(); ++i) {
            (uint48 t,,,,,, uint8 kind,) = sys.game.items(sys.game.liveAt(i));
            if (kind == 1) {
                ++packListings;
                assertEq(packs.ownerOf(t), address(pool), "escrowed at FWA");
            }
        }
        assertEq(packListings, 3);
        assertEq(packs.balanceOf(address(sys.poolOwner)), 0);

        // win a Pack and convert it
        uint256 id = pull(bob);
        _settle(id, 0.03 ether);
        sys.game.sync(10);
        (,,, uint256 listingId,) = pool.acquisitions(id);
        (uint48 packId, uint72 backing, uint72 cost,,,, uint8 k,) = sys.game.items(listingId);
        assertEq(k, 1);
        assertEq(backing, 0.03 ether);
        assertEq(cost, packCost);
        assertEq(packs.ownerOf(packId), bob);
        (bool convertible, address collection,) = sys.converter.convertible(listingId);
        assertTrue(convertible);
        assertEq(collection, SHAPE_PACKS);
        vm.startPrank(bob);
        packs.approve(address(sys.converter), packId);
        (uint256 out,) = sys.converter.convert(listingId, 1, false);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(sys.converter.totalEthIn(), 0.03 ether, "the Pack redeemed for its backing");

        // a Pack whose delivery fails is recovered and redeemed
        window();
        syncAll();
        id = pull(alice);
        vm.roll(block.number + 3);
        uint256 w = wordFor(id, 0.03 ether);
        vm.mockCallRevert(SHAPE_PACKS, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(id, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(id)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        (,,, listingId,) = pool.acquisitions(id);
        sys.game.sync(10);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        uint256 expenseBefore = sys.game.prizeExpense();
        sys.game.sync(10);
        assertEq(sys.game.openCount(), 0, "recovered");
        assertEq(sys.game.prizeExpense() - expenseBefore, packCost - 0.03 ether, "only the mint fees written off");
        assertEq(address(sys.poolOwner).balance, 0);

        // retirement redeems every Pack still listed
        window();
        syncAll();
        uint256 inv = sys.game.inventoryBacking();
        uint256 vaultBefore = address(sys.vault).balance;
        uint256 expected = address(sys.game).balance + inv;
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        vm.roll(block.number + 40);
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertTrue(sys.game.retired());
        assertEq(sys.game.inventoryBacking(), 0);
        assertEq(packs.balanceOf(address(pool)), 0, "no Pack left at FWA");
        assertEq(packs.balanceOf(address(sys.poolOwner)), 0);
        assertApproxEqAbs(address(sys.vault).balance - vaultBefore, expected, 0.05 ether);
    }

    // ------------------------------------------------------------------ keeper top-ups

    /// @notice The vault refills KeeperFund from trading fees to its floor plus the target, never more than 1 ETH over
    ///         its life; returned top-ups go back to the vault, not to game profit.
    function test_keeperTopUpsFromFeesWithinTheLifetimeLimit() public {
        vm.prank(POOL_MANAGER);
        (bool sent,) = address(sys.vault).call{value: 5 ether}("");
        assertTrue(sent);
        uint256 target = sys.keeperFund.maintenanceFloor() + sys.vault.keeperTopUpTarget();
        assertEq(target, 0.15 ether);
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            vm.deal(address(sys.keeperFund), 0); // as if keepers had spent it
            total += sys.vault.topUpKeeper();
        }
        assertEq(total, 1 ether, "1 ETH over the vault's life");
        assertEq(sys.vault.keeperTopUps(), 1 ether);
        assertEq(sys.vault.topUpKeeper(), 0, "the limit is permanent");
        vm.prank(address(sys.timelock));
        vm.expectRevert();
        sys.vault.setKeeperTopUpTarget(0.5 ether + 1);
    }

    /// @notice A sync tops KeeperFund up as part of its work, so the first keepers are paid from the first fees.
    function test_syncTopsUpTheKeeperFund() public {
        vm.prank(POOL_MANAGER);
        (bool sent,) = address(sys.vault).call{value: 1 ether}("");
        assertTrue(sent);
        vm.deal(address(sys.keeperFund), 0.01 ether);
        _settle(pull(alice), 0.01 ether);
        vm.txGasPrice(1 gwei);
        vm.prank(keeper, keeper);
        sys.game.sync(10);
        assertGt(sys.vault.keeperTopUps(), 0);
        assertGe(address(sys.keeperFund).balance + keeper.balance, 0.15 ether - 0.01 ether);
    }
}
