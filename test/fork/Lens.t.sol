// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pool} from "../../src/Pool.sol";
import {PoolAdmin} from "../../src/PoolAdmin.sol";
import {PoolListing} from "../../src/PoolListing.sol";
import {Lens} from "../../src/Lens.sol";
import {PricingLib} from "../../src/lib/PricingLib.sol";
import {IFWAClone} from "../../src/interfaces/IFWAClone.sol";
import {ForkBase} from "./ForkBase.sol";
import {PoolHarness, PoolFixture} from "../unit/Pool.t.sol";
import {IPool, IPoolTypes} from "../../src/interfaces/IPool.sol";

/// @notice Every `Lens` view against a pool with a live FWA clone, deployed Shapes and a Draw Packs
///         deployment.
/// @dev Mix: row 0 is a one rung Shape of 0.1 ETH (7,000 bps), row 1 is a two rung pack of
///      2 x 0.01 ETH (3,000 bps). GRAIL: target 25 ETH, list 75 percent. A 100 ETH deposit routes about 11 ETH to
///      the GRAIL fund, and `open` forms the opening five from it.
contract LensForkTest is ForkBase, PoolFixture {
    PoolHarness internal pool;
    IFWAClone internal clone;
    Lens internal lens;
    address internal player = makeAddr("player");
    address internal exiter = makeAddr("exiter");

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
        lens = new Lens(pool);
        vm.prank(admin);
        IPool(address(pool)).createFwaPool(0);
        clone = pool.fwaPool();
        vm.prank(address(pool));
        clone.setBool(41, true);
    }

    // ---------------------------------------------------------------- helpers

    function _open(bool large) internal {
        if (large) pool.sizeBoard(60);
        vm.prank(alice);
        pool.deposit{value: _openingDeposit(address(pool))}();
        _topUpGrailFund(pool);
        vm.warp(IPool(address(pool)).openingDeadlineAt());
        while (pool.lifecycle() == IPoolTypes.Lifecycle.Opening) pool.open();
    }

    function _acquire(address who, uint256 count) internal returns (uint256[] memory ids) {
        return acquirePooled(address(pool), clone, who, count);
    }

    function _price(uint256 listingId) internal view returns (uint256 price) {
        (,,,,, price,,) = clone.listings(listingId);
    }

    // ---------------------------------------------------------------- quote

    function test_quoteIsNotLiveBeforeOpenAndZeroBeforeTheFwaPoolExists() public {
        Pool bare = new Pool(_params(), address(new PoolAdmin()), address(new PoolListing()));
        Lens bareLens = new Lens(bare);
        Lens.Quote memory q = bareLens.quote(1);
        assertEq(q.total, 0);
        assertFalse(q.purchasable);
        assertEq(uint8(q.reason), uint8(Lens.Reason.NotLive));

        q = lens.quote(1);
        assertEq(uint8(q.reason), uint8(Lens.Reason.NotLive));
    }

    function test_quoteMatchesFwaAndFlipsAfterTheCooldown() public {
        _open(false);
        Lens.Quote memory q = lens.quote(2);
        (uint256 fee, uint256 vrf, uint256 total) = clone.quoteAcquisitionPrice(2);
        assertEq(q.fee, fee);
        assertEq(q.vrf, vrf);
        assertEq(q.total, total);
        assertFalse(q.purchasable, "listing the board started the FWA cooldown");
        assertEq(uint8(q.reason), uint8(Lens.Reason.CoolingDown));

        warpPastCooldown(clone);
        q = lens.quote(2);
        assertTrue(q.purchasable);
        assertEq(uint8(q.reason), uint8(Lens.Reason.None));

        (uint256 slip, uint256 version) = poolArgs(clone);
        vm.deal(player, q.total);
        vm.prank(player);
        pool.acquireBatch{value: q.total}(player, 2, q.fee, 0, slip, version, block.timestamp + 1 hours);
    }

    function test_quoteNamesTheFirstFailingGuard() public {
        _open(false);
        warpPastCooldown(clone);

        assertEq(uint8(lens.quote(0).reason), uint8(Lens.Reason.InvalidCount));
        assertEq(uint8(lens.quote(IPool(address(pool)).maxBatch() + 1).reason), uint8(Lens.Reason.InvalidCount));

        vm.prank(admin);
        IPool(address(pool)).setPaused(true, false);
        assertEq(uint8(lens.quote(1).reason), uint8(Lens.Reason.PullsPaused));
        vm.prank(admin);
        IPool(address(pool)).setPaused(false, false);

        pool.loseCash(pool.cash());
        vm.deal(address(pool), 0);
        assertEq(uint8(lens.quote(1).reason), uint8(Lens.Reason.Insolvent));
        vm.deal(address(pool), 1_000 ether);

        vm.prank(admin);
        IPool(address(pool)).startExit(address(pool));
        assertEq(uint8(lens.quote(1).reason), uint8(Lens.Reason.Exiting));
    }

    function test_quoteReportsBoardTooThin() public {
        _open(false);
        warpPastCooldown(clone);
        uint256[] memory ids = _acquire(player, 1);
        fulfill(clone, ids[0], wordFor(clone, pool.listedIds(0)[0]));
        pool.settle(20);
        assertEq(pool.listedCount(), 9);
        assertEq(uint8(lens.quote(1).reason), uint8(Lens.Reason.BoardTooThin));
    }

    // ---------------------------------------------------------------- shares

    function test_navSharePriceAndPosition() public {
        assertEq(lens.sharePrice(), 1e18, "no shares yet");
        Lens.Position memory empty = lens.position(alice);
        assertEq(empty.shares, 0);
        assertEq(empty.valueWei, 0);
        assertFalse(empty.migrated);

        _open(false);
        assertEq(lens.nav(), pool.nav());
        assertEq(lens.sharePrice(), pool.nav() * 1e18 / pool.totalShares());
        Lens.Position memory p = lens.position(alice);
        assertEq(p.shares, pool.sharesOf(alice));
        assertEq(p.valueWei, pool.sharesOf(alice) * pool.nav() / pool.totalShares());
        assertEq(lens.position(player).shares, 0);
    }

    // ---------------------------------------------------------------- board

    function test_boardMatchesTheListingsAndTargetsOfThePool() public {
        _open(true);
        Lens.Row[] memory rows = lens.board();
        assertEq(rows.length, 2);
        for (uint256 i; i < rows.length; ++i) {
            uint256[] memory ids = pool.listedIds(i);
            assertEq(rows[i].listed, ids.length);
            assertEq(rows[i].count, IPool(address(pool)).rowCount(i));
            assertEq(rows[i].target, PricingLib.rowDepth(IPool(address(pool)).boardItems(), rows[i].shareBps));
            assertEq(rows[i].listingPrice, _price(ids[0]), "list price equals the pool's own FWA price");
        }
        assertEq(rows[0].rungs.length, 1);
        assertEq(rows[0].backingWei, 0.1 ether);
        assertEq(rows[0].shareBps, 7_000);
        assertEq(rows[1].rungs.length, 2);
        assertEq(rows[1].backingWei, 0.02 ether);
        assertEq(rows[0].listed + rows[1].listed, 60);
        assertEq(rows[0].target, 42);
        assertEq(rows[1].target, 18);
    }

    // ---------------------------------------------------------------- GRAIL

    function test_grailViewCarriesTheFundTheCycleAndTheItemsWithTheirWeight() public {
        _open(false);
        IPoolTypes.Grail memory stored = IPool(address(pool)).grail();
        IPoolTypes.GrailItem[] memory storedItems = IPool(address(pool)).grailItems();
        Lens.GrailView memory g = lens.grail();
        assertEq(g.fund, stored.fund);
        assertGt(g.fund, 0, "the contribution left a fund after the opening five");
        assertEq(g.receivable, stored.receivable);
        assertEq(g.targetWei, 25 ether);
        assertEq(g.nextTargetWei, 25 ether);
        assertEq(g.cycleId, 1);
        assertEq(g.listBps, 7_500);
        assertEq(g.decayWeiPerPull, 0.001 ether);
        assertEq(g.pieceFloorWei, 0.25 ether);
        assertEq(g.floorWei, 1 ether);
        assertEq(g.items.length, 1);
        assertEq(storedItems.length, 1);
        Lens.GrailItemView memory it = g.items[0];
        assertEq(it.collection, SHAPES_ADDR);
        assertEq(it.tokenId, storedItems[0].tokenId);
        assertEq(it.backing, 5 ether);
        assertEq(it.notional, 5 ether, "the opening five lists at face");
        assertEq(it.listingId, storedItems[0].listingId);
        assertEq(it.listedAtPull, 0);
        assertFalse(it.done);
        assertEq(it.weightBps, PricingLib.weightOf(it.notional) * 10_000 / clone.totalWeight());
        assertGt(it.weightBps, 0);
    }

    function test_grailViewIsEmptyBeforeOpen() public {
        Lens.GrailView memory g = lens.grail();
        assertEq(g.items.length, 0);
        assertEq(g.fund, 0);
        assertEq(g.cycleId, 1);
    }

    // ---------------------------------------------------------------- claims

    function test_claimsListsTheUnpaidQueue() public {
        _open(false);
        Lens.Claims memory empty = lens.claims();
        assertEq(empty.queue.length, 0);
        assertEq(empty.unpaidTotal, 0);

        vm.deal(exiter, 8 ether);
        vm.prank(exiter);
        pool.deposit{value: 8 ether}();
        pool.loseCash(pool.cash());
        uint256 shares = pool.sharesOf(exiter);
        vm.prank(exiter);
        pool.withdraw(shares);
        uint256 first = pool.claims();
        assertGt(first, 0);

        uint256 firstAt = vm.getBlockTimestamp();
        vm.warp(block.timestamp + pool.rotateInterval());
        vm.deal(player, 1 ether);
        vm.prank(player);
        pool.deposit{value: 1 ether}();
        uint256 playerShares = pool.sharesOf(player);
        pool.loseCash(pool.cash());
        vm.prank(player);
        pool.withdraw(playerShares);

        Lens.Claims memory c = lens.claims();
        assertEq(c.head, 0);
        assertEq(c.queue.length, 2);
        assertEq(c.queue[0].to, exiter);
        assertEq(c.queue[0].amount, first);
        assertEq(c.queue[0].requestedAt, firstAt);
        assertEq(c.queue[1].requestedAt, vm.getBlockTimestamp());
        assertEq(c.queue[1].to, player);
        assertEq(c.unpaidTotal, c.queue[0].amount + c.queue[1].amount);
        assertEq(c.claimsBucket, pool.claims());
        assertEq(c.cash, pool.cash());

        pool.bookProceeds{value: first}();
        pool.payClaims();
        Lens.Claims memory after_ = lens.claims();
        assertEq(after_.head, 1, "the head claim was paid in full and the fresh claim waits");
        assertEq(after_.queue.length, 1);
        assertEq(after_.queue[0].to, player);
    }

    // ---------------------------------------------------------------- rotation

    function test_rotateDuePassesThroughThePoolValue() public {
        assertEq(uint8(lens.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "not Live");
        _open(false);
        assertEq(uint8(lens.rotateDue()), uint8(IPoolTypes.RotateTrigger.None), "inside the spacing");
        vm.warp(pool.lastRotateAt() + pool.rotateInterval());
        assertEq(uint8(lens.rotateDue()), uint8(pool.rotateDue()));
        assertEq(uint8(lens.rotateDue()), uint8(IPoolTypes.RotateTrigger.GrailStep), "the fund covers a piece");
    }

    // ---------------------------------------------------------------- reopen guards and parameters

    function test_reopenStatusCarriesEachGuardWithItsNumbers() public {
        _open(false);
        Lens.Reopen memory r = lens.reopenStatus();
        assertTrue(r.live);
        assertTrue(r.pullsOpen);
        assertFalse(r.cooldownPassed);
        assertEq(r.purchasesResumeAt, clone.purchasesResumeAt());
        assertTrue(r.solvent);
        assertEq(r.balance, address(pool).balance);
        assertTrue(r.boardDeep);
        assertEq(r.listedCount, 10);
        assertEq(r.unsettled, 0);
        assertEq(r.concurrency, IPool(address(pool)).concurrency());

        warpPastCooldown(clone);
        assertTrue(lens.reopenStatus().cooldownPassed);
    }

    function test_admissionReportsCapFeeAndWindow() public {
        vm.prank(admin);
        IPool(address(pool)).setFounderWindow(3 days);
        Lens.Admission memory a = lens.admission();
        assertFalse(a.open, "not Live");
        assertEq(a.depositsOpenAt, 0);
        assertEq(a.navCap, 1_000 ether);
        assertEq(a.navCapFloor, 1_000 ether);
        assertEq(a.dailyVolume, 0);
        assertEq(a.headroom, 1_000 ether);
        assertEq(a.contributionBps, 1_100, "entry fee floor with no volume");

        _open(false);
        uint256 openAt = pool.depositsOpenAt();
        assertEq(openAt, vm.getBlockTimestamp() + 3 days);
        a = lens.admission();
        assertEq(a.depositsOpenAt, openAt);
        assertEq(a.headroom, a.navCap - pool.nav());
        assertFalse(a.open, "inside the founder window");

        vm.warp(openAt);
        a = lens.admission();
        assertTrue(a.open);

        vm.prank(admin);
        IPool(address(pool)).setPaused(false, true);
        assertFalse(lens.admission().open, "deposits paused");
        vm.prank(admin);
        IPool(address(pool)).setPaused(false, false);

        uint256 navNow = pool.nav();
        vm.prank(admin);
        IPool(address(pool)).setNavCapFloor(navNow);
        a = lens.admission();
        assertEq(a.headroom, 0, "NAV at the cap");
        assertFalse(a.open);
    }

    function test_parametersMirrorThePool() public {
        _open(false);
        vm.prank(admin);
        IPool(address(pool)).setPaused(true, true);
        Lens.Parameters memory p = lens.parameters();
        assertEq(p.shapes, SHAPES_ADDR);
        assertEq(p.drawPacks, address(drawPacks));
        assertEq(p.fwaFactory, FACTORY_ADDR);
        assertEq(p.fwaPool, address(clone));
        assertEq(p.admin, admin);
        assertEq(p.oldPool, address(0));
        assertEq(p.exitDest, address(0));
        assertEq(uint8(p.lifecycle), uint8(IPoolTypes.Lifecycle.Live));
        assertTrue(p.pullsPaused);
        assertTrue(p.depositsPaused);
        assertEq(p.feeSplit.premiumBps, 200);
        assertEq(p.feeSplit.maintenanceBps, 100);
        assertEq(p.feeSplit.feedBps, 400);
        assertEq(p.floorBps, 1_100);
        assertEq(p.capBps, 2_500);
        assertEq(p.paybackDays, 20);
        assertEq(p.navCapFloor, 1_000 ether);
        assertEq(p.turnoverBps, 1_250);
        assertEq(p.founderWindowSeconds, 0);
        assertEq(p.rotateInterval, 3_600);
        assertEq(p.openingDeadline, 24 hours);
        assertEq(p.openingDeadlineAt, IPool(address(pool)).openingDeadlineAt());
        assertEq(p.minItems, 10);
        assertEq(p.boardItems, IPool(address(pool)).boardItems());
        assertEq(p.grailProbCapBps, 2_000);
        assertEq(p.batchMin, 20);
        assertEq(p.batchMaxAge, 1 hours);
        assertEq(p.surpriseBps, 200);
        assertEq(p.restoreK, 8);
        assertEq(p.bandBps, 3_000);
        assertEq(p.reserveBps, 1_000);
        assertEq(p.tipWei, 0.0002 ether);
        assertFalse(p.listWhilePaused);
        assertEq(p.maxBatch, IPool(address(pool)).maxBatch());
        assertEq(p.concurrency, IPool(address(pool)).concurrency());
        assertEq(p.lastRotateAt, pool.lastRotateAt());
        assertEq(p.lastRefundAt, 0);

        vm.prank(admin);
        IPool(address(pool)).startExit(address(pool));
        assertEq(lens.parameters().exitDest, address(pool));
    }
}
