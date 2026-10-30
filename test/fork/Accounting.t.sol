// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {Buyback} from "../../src/treasury/Buyback.sol";

interface IFactoryOwner {
    function owner() external view returns (address);
    function setEdgeBps(uint16 newEdgeBps) external;
    function setInventoryChangeCooldown(uint32 cooldown) external;
}

/// @notice Accounting, capital, admission and FWA behaviour of the game on the pinned fork (docs/SPEC.md section 4,
///         docs/IMPLEMENTOR_DECISIONS.md D31-D38). No trading-fee inflow unless a test makes one.
contract AccountingForkTest is ForkBase {
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

    // ------------------------------------------------------------------ helpers

    /// @dev Book identity: cash and inventory at cost equal capital plus realised results, up to the wei FWA's owner
    ///      split rounds in the game's favour.
    function _assertBooks() internal view {
        FwaGame g = sys.game;
        uint256 lhs = address(g).balance + g.inventoryCost();
        uint256 rhs = g.capitalIn() + g.revenue() + g.opsReturned() + g.promoFunded() + g.promoProceeds()
            - g.prizeExpense() - g.opsPaid() - g.distributed() - g.promoSpent() - g.promoReleased();
        // promotion prizes held are carried in the budget's spending, so add back their cost while live
        if (g.promoListing() != 0) {
            (,, uint72 cost,,,,,) = g.items(g.promoListing());
            rhs -= cost;
        }
        assertGe(lhs, rhs, "books: assets below capital plus results");
        assertLe(lhs - rhs, g.pullsBooked() + 1, "books: unexplained surplus");
    }

    /// @dev Captures one listing of `backing` with `who`, settled at once.
    function _win(address who, uint256 backing) internal returns (uint256 id) {
        id = pull(who);
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, backing));
        pool.processAcquisitions(10);
    }

    function _setCapital(FwaGame.Capital memory c) internal {
        vm.prank(address(sys.timelock));
        sys.game.setCapital(c);
    }

    // ------------------------------------------------------------------ FWA: which inventory decides a request

    /// @notice Several requests accepted on one quote; cheap prizes removed first raise the live fee by about 1.52%
    ///         each on the 100-item board, and once the drift passes FWA's 10% positive-slippage guard the next request
    ///         is refunded, not settled. The game books exactly what FWA settled.
    function test_cheapPrizesRemovedFirstAndRequestsOnAnEarlierQuote() public {
        (uint256 fee0,,) = pool.quoteAcquisitionPrice(1);
        uint256[] memory ids = new uint256[](8);
        for (uint256 i; i < 8; ++i) {
            ids[i] = pull(i % 2 == 0 ? alice : bob);
            (,, uint256 escrowed,,) = pool.acquisitions(ids[i]);
            assertEq(escrowed, fee0, "every request escrows the same earlier quote");
        }
        vm.roll(block.number + 3);
        uint256 fulfilled;
        for (uint256 i; i < 8; ++i) {
            uint256 liveFee = pool.acquisitionFee();
            bool refund = liveFee > fee0 && liveFee - fee0 > fee0 / 10;
            deliverWord(ids[i], wordFor(ids[i], 0.01 ether));
            pool.processAcquisitions(1);
            IFWAPool.AcquisitionStatus st = statusOf(ids[i]);
            if (refund) {
                assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Refunded), "drift past 10%: refunded");
            } else {
                assertEq(uint8(st), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
                ++fulfilled;
            }
        }
        assertEq(fulfilled, 6, "after six cheap removals (+10.46%) the 7th and 8th requests are refunded");
        sys.game.sync(20);
        assertEq(sys.game.pullsBooked(), fulfilled);
        assertEq(sys.game.turnover(), fulfilled * fee0);
        assertEq(sys.game.epochWeight(0), fulfilled * fee0, "the refunded request has no weight");
        assertEq(sys.game.prizeExpense(), fulfilled * 0.011 ether);
        _assertBooks();
    }

    /// @notice Headline prizes won early: losses are booked and carried, nothing is distributed, the replacements are
    ///         paid from capital as soon as three rows wait (the restock trigger) and the board is whole again.
    function test_severalHeadlinesWonEarly() public {
        consumeWindow();
        int256 p0 = sys.game.profit();
        for (uint256 i; i < 2; ++i) {
            _win(alice, 0.5 ether);
        }
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 98, "two rows wait for the trigger or the interval");
        assertEq(sys.game.replacementsOwed(), 2 * 0.501 ether);
        _win(alice, 0.5 ether);
        sys.game.sync(10);
        int256 p = sys.game.profit();
        assertLt(p - p0, -1.3 ether, "three 0.5 wins against ~0.03 tickets");
        assertEq(sys.game.liveCount(), 100, "three waiting: replaced from capital at once");
        assertEq(sys.game.replacementsOwed(), 0);
        assertEq(sys.game.profit(), p, "replacing is not a second expense");
        // ordinary wins afterwards recover the loss before anything is distributed
        for (uint256 i; i < 10; ++i) {
            _win(bob, 0.01 ether);
        }
        sys.game.sync(20);
        assertLt(sys.game.profit(), 0);
        assertLe(sys.game.distributed(), uint256(p0 > 0 ? p0 : int256(0)), "no distribution while the loss is carried");
        _assertBooks();
    }

    /// @notice Trading fees after a loss are capital: they fund the game but never turn the carried loss into a
    ///         distribution.
    function test_lossThenTradingFeesThenAttemptedDistribution() public {
        _win(alice, 0.5 ether);
        sys.game.sync(10);
        int256 p = sys.game.profit();
        assertLt(p, 0);
        // trading fees reach the vault (public buys are gated during genesis, so the fee transfer from the PoolManager
        // stands in for trading; the vault counts what the PoolManager sends as trading fees)
        vm.prank(POOL_MANAGER);
        (bool sent,) = address(sys.vault).call{value: 1 ether}("");
        assertTrue(sent);
        uint256 fees = sys.vault.tradingFees();
        assertGt(fees, 0, "sell fees reached the vault");
        sys.vault.fund();
        assertEq(sys.game.capitalIn(), OPENING_CAPITAL + fees);
        assertEq(sys.game.profit(), p, "capital never changes profit");
        assertEq(sys.game.distributable(), 0);
        assertEq(sys.game.distributed(), 0, "a carried loss blocks distribution whatever the cash");
        assertGt(sys.game.cash(), sys.game.protectedCash());
        _assertBooks();
    }

    /// @notice With no trading fees at all, the game keeps settling and replenishing every prize from its own capital
    ///         and results, and distributes only realised profit above protected cash.
    function test_zeroTradingFeesKeepsSettlingAndReplenishing() public {
        playMany(alice, 120, 1);
        assertEq(sys.vault.tradingFees(), 0);
        assertEq(sys.game.capitalIn(), OPENING_CAPITAL);
        assertEq(sys.game.liveCount(), 100, "the board is whole");
        assertEq(sys.game.openCount(), 0, "every request resolved");
        assertEq(sys.game.pullsBooked(), 120);
        int256 p = sys.game.profit();
        if (p > 0) assertLe(sys.game.distributed(), uint256(p), "never more than realised profit");
        else assertEq(sys.game.distributed(), 0);
        assertGe(sys.game.cash(), sys.game.replacementsOwed() + sys.game.opsOwed(), "replacements covered");
        _assertBooks();
    }

    /// @notice Burning distributed profit never reaches replacement capital or the reserve.
    function test_replacementCapitalPreservedAfterBurns() public {
        playMany(bob, 80, 7);
        uint256 d = sys.game.distributed();
        if (d == 0) return; // an adverse sample: nothing to burn, nothing to check
        uint256 supply = sys.engine.totalSupply();
        sys.buyback.process(0);
        assertLt(sys.engine.totalSupply(), supply, "bought and burned");
        assertGe(sys.game.cash(), sys.game.protectedCash(), "protected cash intact after distributions");
        assertEq(sys.game.liveCount(), 100);
        _assertBooks();
    }

    /// @notice Measures the keeper gas of running the game (a sync per 10 pulls, replacements at each window) against
    ///         the operating allocation, and reports the base fee up to which the allocation pays for it. The tips
    ///         themselves are capped by KeeperFund; this measures the raw gas.
    function test_operatingAllocationAgainstMeasuredKeeperGas() public {
        uint256 gasUsed;
        for (uint256 i; i < 120; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode("ops", i))));
            if (i % 10 == 9) {
                window();
                uint256 g0 = gasleft();
                sys.game.sync(50);
                gasUsed += g0 - gasleft();
            }
        }
        uint256 ops = sys.game.opsAccrued();
        uint256 breakEven = ops / (gasUsed + 12 * cfg.keeper.gasOverhead);
        emit log_named_uint("ops accrued over 120 pulls (wei)", ops);
        emit log_named_uint("keeper gas over 12 syncs", gasUsed);
        emit log_named_uint("break-even base fee (wei)", breakEven);
        // Measured with `--isolate` (each call its own transaction, cold storage as on mainnet; forge >= 1.6 isolates by
        // default): about 1.6 gwei. Without isolation warm storage reads about 2.1 gwei.
        assertGe(breakEven, 1.5 gwei, "ops pays the keeper gas up to at least 1.5 gwei");
    }

    // ------------------------------------------------------------------ admission

    /// @notice When the board cannot be replenished the purchase gate refuses new purchases at FWA itself, counting
    ///         requests in flight and a full batch; admission closes as well once the fill is below the floor; requests
    ///         already accepted keep settling; capital reopens both.
    function test_admissionClosesWhenTheBoardCannotRefillAndReopens() public {
        FwaGame.Capital memory c = cfg.capital;
        c.minLiveBps = 9_000; // the gate keeps 90 prizes, plus a batch of 5 and every unsettled request
        _setCapital(c);
        assertEq(sys.poolOwner.minListed(), 90);
        // drain the game's cash (as if capital had run out) and capture headline prizes down to 95 live
        vm.deal(address(sys.game), 0);
        for (uint256 i; i < 5; ++i) {
            _win(alice, 0.5 ether);
        }
        assertTrue(sys.poolOwner.canPurchase(alice), "95 live, nothing in flight: 95 >= 90 + 5");
        // an accepted request in flight
        uint256 inflight = pull(bob);
        assertFalse(sys.poolOwner.canPurchase(alice), "one in flight: 95 < 90 + 5 + 1");
        vm.roll(block.number + 3);
        window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 95, "no cash to refill");
        // direct FWA purchases are refused at FWA, not just on the site, whether or not anyone synced
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PurchaseNotAllowed()"));
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, block.timestamp + 1 hours);
        // settlement continues
        deliverWord(inflight, wordFor(inflight, 0.05 ether));
        pool.processAcquisitions(5);
        assertEq(uint8(statusOf(inflight)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        // a higher floor closes admission too (once the capture is booked)
        sys.game.sync(10);
        c.minLiveBps = 9_600;
        _setCapital(c);
        assertLt(sys.game.liveCount(), 96);
        assertFalse(pool.localPurchasesEnabled(), "below the floor of 96: closed");
        (fee,, total) = pool.quoteAcquisitionPrice(1);
        version = pool.inventoryVersion();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PurchaseNotAllowed()")); // FWA asks the gate before the switch
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, block.timestamp + 1 hours);
        // capital arrives; the next sync refills and reopens
        vm.deal(address(sys.vault), 4 ether);
        sys.vault.fund();
        window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        assertTrue(pool.localPurchasesEnabled(), "reopened");
        assertFalse(sys.poolOwner.canPurchase(alice), "a 96 floor leaves no room for a batch on 100 rows");
        c.minLiveBps = 9_000;
        _setCapital(c);
        assertTrue(sys.poolOwner.canPurchase(alice), "100 >= 90 + 5");
    }

    /// @notice FWA settings moving outside the supported range close new purchases until they return.
    function test_externalSettingsOutsideSupportedRange() public {
        IFactoryOwner f = IFactoryOwner(FACTORY);
        uint256 inflight = pull(alice);
        vm.prank(f.owner());
        f.setEdgeBps(800);
        sys.game.sync(10);
        assertFalse(pool.localPurchasesEnabled(), "edge above 5%: closed");
        vm.roll(block.number + 3);
        deliverWord(inflight, 3);
        pool.processAcquisitions(5);
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 1, "settled and booked while closed");
        vm.prank(f.owner());
        f.setEdgeBps(500);
        vm.prank(f.owner());
        f.setInventoryChangeCooldown(1 hours);
        window();
        try sys.game.sync(10) {} catch {}
        assertFalse(pool.localPurchasesEnabled(), "cooldown above 5 minutes: closed");
        vm.prank(f.owner());
        f.setInventoryChangeCooldown(0);
        sys.game.sync(10);
        assertTrue(pool.localPurchasesEnabled(), "back in range: open");
    }

    /// @notice The gate refuses a purchase once `maxInFlight` requests are unsettled; FWA's batch limit is 5 per call and
    ///         every request in a batch is booked on its own.
    function test_outstandingLimitAndMaximumBatches() public {
        FwaGame.Capital memory c = cfg.capital;
        c.maxInFlight = 5;
        _setCapital(c);
        (uint256 fee, uint256 vrf,) = pool.quoteAcquisitionPrice(5);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("InvalidAcquisitionCount()"));
        pool.acquireBatch{value: 6 * (fee + vrf)}(alice, 6, fee, 0, 10_000, version, block.timestamp + 1 hours);
        vm.prank(alice);
        uint256[] memory batch =
            pool.acquireBatch{value: 5 * (fee + vrf)}(alice, 5, fee, 0, 10_000, version, block.timestamp + 1 hours);
        assertFalse(sys.poolOwner.canPurchase(bob), "5 unsettled, the limit: refused");
        (uint256 fee1,, uint256 total1) = pool.quoteAcquisitionPrice(1);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("PurchaseNotAllowed()"));
        pool.acquire{value: total1}(bob, fee1, 0, 10_000, version, block.timestamp + 1 hours);
        vm.roll(block.number + 3);
        for (uint256 i; i < 5; ++i) {
            deliverWord(batch[i], uint256(keccak256(abi.encode(i))));
        }
        pool.processAcquisitions(10);
        sys.game.sync(20);
        assertEq(sys.game.pullsBooked(), 5, "every request of the batch booked");
        assertEq(sys.game.userWeight(0, alice), 5 * fee);
        assertTrue(sys.poolOwner.canPurchase(bob), "open again once settled");
        pull(bob);
    }

    /// @notice At the launch limit of 10, two full batches may be in flight; a third is refused before any fee, and
    ///         the board keeps a full batch of headroom above its floor whatever settles.
    function test_fullBatchesWithRequestsInFlight() public {
        assertEq(sys.poolOwner.maxInFlight(), 10);
        assertEq(sys.poolOwner.maxBatch(), 5);
        uint256[] memory a = _batch(alice);
        uint256[] memory b = _batch(bob);
        assertEq(pool.unsettledAcquisitionCount(), 10);
        (uint256 fee, uint256 vrf,) = pool.quoteAcquisitionPrice(5);
        uint256 version = pool.inventoryVersion();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("PurchaseNotAllowed()"));
        pool.acquireBatch{value: 5 * (fee + vrf)}(alice, 5, fee, 0, 10_000, version, block.timestamp + 1 hours);
        vm.roll(block.number + 3);
        for (uint256 i; i < 5; ++i) {
            deliverWord(a[i], uint256(keccak256(abi.encode("a", i))));
            deliverWord(b[i], uint256(keccak256(abi.encode("b", i))));
        }
        pool.processAcquisitions(20);
        assertEq(pool.unsettledAcquisitionCount(), 0);
        // Each cheap prize captured raises FWA's live fee; once the drift passes FWA's 10% positive-slippage guard a
        // later request in the queue is refunded rather than settled (the player gets the ticket back). On this board
        // ten in flight settle about 8 and refund the rest (sim/throughput.py measures the rate).
        uint256 fulfilled;
        uint256 refunded;
        for (uint256 i; i < 10; ++i) {
            IFWAPool.AcquisitionStatus st = statusOf(i < 5 ? a[i] : b[i - 5]);
            if (st == IFWAPool.AcquisitionStatus.Fulfilled) ++fulfilled;
            else if (st == IFWAPool.AcquisitionStatus.Refunded) ++refunded;
        }
        assertEq(fulfilled + refunded, 10, "every request settled or refunded");
        assertGe(fulfilled, 5);
        assertGe(pool.activeListingCount(), 90, "ten captures at most from a full board");
        sys.game.sync(50);
        assertEq(sys.game.pullsBooked(), fulfilled);
        assertEq(sys.game.openCount(), 0, "refunds resolved too");
        assertEq(sys.game.liveCount(), 100, "replaced");
        _assertBooks();
    }

    function _batch(address who) internal returns (uint256[] memory ids) {
        (uint256 fee, uint256 vrf,) = pool.quoteAcquisitionPrice(5);
        uint256 version = pool.inventoryVersion();
        vm.deal(who, who.balance + 5 * (fee + vrf));
        vm.prank(who);
        ids = pool.acquireBatch{value: 5 * (fee + vrf)}(who, 5, fee, 0, 10_000, version, block.timestamp + 1 hours);
    }

    /// @notice Replacements wait for the maintenance interval (at least six FWA cooldowns) and, while the board is
    ///         well above the gate's line, for requests in flight to settle, so FWA never stages them; then they list
    ///         and start FWA's cooldown.
    function test_delayedReplacementsAndCooldown() public {
        IFactoryOwner f = IFactoryOwner(FACTORY);
        vm.prank(f.owner());
        f.setInventoryChangeCooldown(60);
        consumeWindow();
        vm.warp(block.timestamp + 60);
        _win(alice, 0.05 ether);
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 99, "the replacement waits for the interval");
        uint256 inflight = pull(bob);
        window();
        vm.warp(block.timestamp + 60); // six cooldowns (6 min) is the longer wait
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 99, "and for the request in flight");
        vm.roll(block.number + 3);
        deliverWord(inflight, wordFor(inflight, 0.01 ether));
        pool.processAcquisitions(5);
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100, "settled: both rows replaced");
        assertEq(pool.activeListingCount(), 100, "listed active, not staged");
        assertEq(pool.purchasesResumeAt(), block.timestamp + 60, "the relisting starts FWA's cooldown");
    }

    // ------------------------------------------------------------------ keepers

    /// @notice Calls with no useful progress revert and pay nothing; tips stop when the fund is empty but settlement
    ///         does not.
    function test_keeperCallsWithoutProgress() public {
        uint256 paid = sys.keeperFund.totalTipsPaid();
        vm.expectRevert(FwaGame.NoWork.selector);
        sys.game.sync(10);
        vm.expectRevert(Buyback.NoWork.selector);
        sys.buyback.process(0);
        assertEq(sys.keeperFund.totalTipsPaid(), paid, "no tip for no progress");
        // an empty keeper fund: the work still happens, unpaid
        vm.deal(address(sys.keeperFund), 0);
        _win(alice, 0.01 ether);
        vm.fee(10 gwei);
        vm.prank(keeper, keeper);
        sys.game.sync(10);
        assertEq(sys.game.pullsBooked(), 1);
        // a repeated call right after finds nothing
        vm.expectRevert(FwaGame.NoWork.selector);
        sys.game.sync(10);
    }

    // ------------------------------------------------------------------ promotions

    /// @notice A promotion is pre-funded, capped at its prize's cost, ends on a win or at its end block, and is
    ///         accounted apart from the ordinary game: its subsidy never touches profit.
    function test_promotionBudgetedAndSeparate() public {
        vm.deal(address(sys.vault), 2 ether);
        vm.prank(address(sys.timelock));
        sys.vault.fundPromotion(1.2 ether);
        assertEq(sys.game.promoBudget(), 1.2 ether);
        vm.prank(address(sys.timelock));
        sys.game.startPromotion(1 ether, 9_000, block.number + 1_000);
        uint256 promo = sys.game.promoListing();
        (,,,,, uint256 price,,) = pool.listings(promo);
        assertEq(price, 1.001 ether * 9_000 / 10_000, "listed below cost: the subsidy");
        assertEq(sys.game.promoBudget(), 1.2 ether - 1.001 ether, "the full cost is reserved up front");
        // one promotion at a time
        vm.prank(address(sys.timelock));
        vm.expectRevert(FwaGame.NotReady.selector);
        sys.game.startPromotion(0.1 ether, 9_000, block.number + 1_000);
        // the promotion prize is won
        _win(alice, 1 ether);
        sys.game.sync(10);
        assertEq(sys.game.promoListing(), 0);
        assertEq(sys.game.promoSpent(), 1.001 ether);
        assertGt(sys.game.promoProceeds(), 0);
        assertEq(sys.game.revenue(), 0, "promotion proceeds are not revenue");
        assertEq(sys.game.prizeExpense(), 0, "the promotion prize is not an ordinary expense");
        assertEq(sys.game.promoTurnover(), sys.game.turnover(), "issued while the promotion was live");
        _assertBooks();
        // a second promotion expires unwon: withdrawn, burned, backing back to the budget less the mint fee
        uint256 budget = sys.game.promoBudget();
        vm.prank(address(sys.timelock));
        sys.game.startPromotion(0.1 ether, 9_000, block.number + 10);
        vm.roll(block.number + 11);
        window();
        sys.game.sync(10);
        assertEq(sys.game.promoListing(), 0, "ended at its end block");
        assertEq(sys.game.promoBudget(), budget - 0.001 ether);
        // the unspent budget returns to the vault as capital
        uint256 vaultBefore = address(sys.vault).balance;
        uint256 left = sys.game.promoBudget();
        vm.prank(address(sys.timelock));
        sys.game.releasePromotion(left);
        assertEq(address(sys.vault).balance, vaultBefore + left);
        assertEq(sys.game.promoBudget(), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------ genesis boundary

    /// @notice A request accepted in the last block of genesis keeps its epoch and its weight when it settles after
    ///         the end; one accepted at the end block earns nothing.
    function test_lateSettlementAcrossTheGenesisEnd() public {
        uint256 end = sys.farm.genesisEndBlock();
        vm.roll(end - 1);
        uint256 last = pull(alice);
        vm.roll(end);
        uint256 after_ = pull(bob);
        vm.roll(end + 3);
        deliverWord(last, 7);
        pool.processAcquisitions(5);
        deliverWord(after_, 9);
        pool.processAcquisitions(5);
        sys.game.sync(10);
        (,, uint256 paid,,) = pool.acquisitions(last);
        assertEq(sys.game.userWeight(20, alice), paid, "epoch 20 keeps the late-settled request");
        assertEq(sys.game.userWeight(21, bob), paid, "the end-block request lands in epoch 21");
        assertEq(sys.farm.allocationCap(21), 0, "which has no allocation");
        vm.roll(end + 7_200);
        assertEq(sys.farm.rewardOf(21, bob), 0);
        assertGt(sys.farm.rewardOf(20, alice), 0);
    }

    // ------------------------------------------------------------------ retirement

    /// @notice Retiring with requests in flight and operating allocation unpaid: requests settle or expire, the
    ///         allocation is paid, players keep their FWA refunds, and the rest returns to the vault.
    function test_retirementWithPendingRequestsAndUnpaidObligations() public {
        _win(alice, 0.05 ether);
        // leave the operating allocation owed: no cash to pay it with replacements outstanding
        uint256 bal = address(sys.game).balance;
        vm.deal(address(sys.game), 0);
        sys.game.sync(10);
        assertGt(sys.game.opsOwed(), 0, "owed while replacements come first");
        vm.deal(address(sys.game), bal);
        uint256 pending = pull(bob); // never fulfilled: expires during retirement
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        vm.roll(block.number + 40);
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertTrue(sys.game.retired());
        assertEq(sys.game.opsOwed(), 0, "obligation paid during retirement");
        assertEq(uint8(statusOf(pending)), uint8(IFWAPool.AcquisitionStatus.Expired));
        uint256 credit = pool.acquisitionRefundCredit(bob);
        assertGt(credit, 0);
        vm.prank(bob);
        pool.withdrawAcquisitionRefund();
        assertEq(address(sys.game).balance, 0);
        assertEq(sys.game.distributed(), 0, "no distribution while retiring");
    }
}

/// @notice `openGame` readiness on a fresh deployment.
contract ReadinessForkTest is ForkBase {
    function setUp() public {
        deployLaunch();
    }

    function test_openGameNeedsMarketBoardAndReserve() public {
        vm.startPrank(address(sys.timelock));
        vm.expectRevert(FwaGame.NotReady.selector);
        sys.game.openGame(); // no market yet
        vm.stopPrank();
        openMarket();
        vm.prank(address(sys.timelock));
        vm.expectRevert(FwaGame.NotReady.selector);
        sys.game.openGame(); // the 48-hour market has not run
        vm.warp(block.timestamp + 48 hours);
        vm.prank(address(sys.timelock));
        vm.expectRevert(FwaGame.NotReady.selector);
        sys.game.openGame(); // no board
        fundAndFill(15.15 ether + 1 ether);
        assertEq(sys.game.liveCount(), 100);
        vm.prank(address(sys.timelock));
        vm.expectRevert(FwaGame.NotReady.selector);
        sys.game.openGame(); // board listed but cash below the 12 ETH reserve target
        vm.deal(address(sys.vault), 11 ether);
        sys.vault.fund();
        vm.prank(address(sys.timelock));
        sys.game.openGame();
        assertTrue(pool.localPurchasesEnabled());
        assertEq(sys.farm.openBlock(), block.number);
        assertEq(sys.farm.genesisEndBlock(), block.number + 21 * 7_200);
    }
}
