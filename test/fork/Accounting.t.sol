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
        openMarket(LAUNCH_ETH);
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
            (,, uint80 cost,,,) = g.items(g.promoListing());
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
    ///         paid from capital at the next window and the board is whole again.
    function test_severalHeadlinesWonEarly() public {
        consumeWindow();
        int256 p0 = sys.game.profit();
        for (uint256 i; i < 3; ++i) {
            _win(alice, 0.5 ether);
        }
        sys.game.sync(10);
        int256 p = sys.game.profit();
        assertLt(p - p0, -1.3 ether, "three 0.5 wins against ~0.03 tickets");
        assertEq(sys.game.replacementsOwed(), 3 * 0.501 ether);
        window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100, "replaced from capital");
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
        // trading activity pays fees to the vault (sells stay open through genesis)
        Swapper swapper = new Swapper(IPoolManager(POOL_MANAGER), sys.liquidity.poolKey());
        address trader = makeAddr("trader");
        deal(address(sys.engine), trader, 50_000_000 ether);
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), type(uint256).max);
        swapper.sell(50_000_000 ether, false);
        vm.stopPrank();
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
        assertGe(breakEven, 2 gwei, "ops pays the keeper gas up to at least 2 gwei");
    }

    // ------------------------------------------------------------------ admission

    /// @notice New purchases close when the board cannot be replenished and reopen once capital arrives; requests
    ///         already accepted keep settling while purchases are closed.
    function test_admissionClosesWhenTheBoardCannotRefillAndReopens() public {
        FwaGame.Capital memory c = cfg.capital;
        c.minLiveBps = 9_900;
        _setCapital(c);
        // drain the game's cash (as if capital had run out) and capture two headline prizes
        vm.deal(address(sys.game), 0);
        _win(alice, 0.5 ether);
        _win(alice, 0.5 ether);
        // an accepted request in flight
        uint256 inflight = pull(bob);
        vm.roll(block.number + 3);
        window();
        sys.game.sync(10);
        assertFalse(pool.localPurchasesEnabled(), "98 of 100 live and no cash to refill: closed");
        // direct FWA purchases are refused at FWA, not just on the site
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("AcquisitionsNotEnabled()"));
        pool.acquire{value: total}(bob, fee, 0, 10_000, version, block.timestamp + 1 hours);
        // settlement continues
        deliverWord(inflight, wordFor(inflight, 0.05 ether));
        pool.processAcquisitions(5);
        assertEq(uint8(statusOf(inflight)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        // capital arrives; the next sync refills and reopens
        vm.deal(address(sys.vault), 2 ether);
        sys.vault.fund();
        window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        assertTrue(pool.localPurchasesEnabled(), "reopened");
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

    /// @notice Too many unsettled requests close new purchases; FWA's batch limit is 5 per call and every request in
    ///         a batch is booked on its own.
    function test_outstandingLimitAndMaximumBatches() public {
        FwaGame.Capital memory c = cfg.capital;
        c.maxOutstanding = 5;
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
        uint256 single = pull(bob);
        sys.game.sync(10);
        assertFalse(pool.localPurchasesEnabled(), "6 unsettled above the limit of 5: closed");
        vm.roll(block.number + 3);
        for (uint256 i; i < 5; ++i) {
            deliverWord(batch[i], uint256(keccak256(abi.encode(i))));
        }
        deliverWord(single, 1);
        pool.processAcquisitions(10);
        sys.game.sync(20);
        assertEq(sys.game.pullsBooked(), 6, "every request of the batch booked");
        assertEq(sys.game.userWeight(0, alice), 5 * fee);
        assertTrue(pool.localPurchasesEnabled(), "reopened once settled");
    }

    /// @notice Replacements wait for the maintenance window and FWA's inventory cooldown; a request accepted before a
    ///         relisting still settles against FWA's live pool.
    function test_delayedReplacementsAndCooldown() public {
        IFactoryOwner f = IFactoryOwner(FACTORY);
        vm.prank(f.owner());
        f.setInventoryChangeCooldown(60);
        consumeWindow();
        vm.warp(block.timestamp + 60);
        _win(alice, 0.05 ether);
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 99, "the replacement waits for the window");
        uint256 before = pull(bob); // accepted before the relisting
        window();
        sys.game.sync(10);
        assertEq(sys.game.liveCount(), 100);
        assertEq(pool.purchasesResumeAt(), block.timestamp + 60, "the relisting starts FWA's cooldown");
        vm.roll(block.number + 3);
        deliverWord(before, 5);
        pool.processAcquisitions(5);
        IFWAPool.AcquisitionStatus st = statusOf(before);
        assertTrue(
            st == IFWAPool.AcquisitionStatus.Fulfilled || st == IFWAPool.AcquisitionStatus.Refunded,
            "settled or refunded on drift, never stuck"
        );
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
        openMarket(LAUNCH_ETH);
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
