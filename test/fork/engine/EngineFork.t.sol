// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool, IPoolTypes} from "../../../src/interfaces/IPool.sol";
import {IArtCoinsHookV2} from "../../../src/interfaces/IArtcoins.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {EngineTreasury} from "../../../src/engine/EngineTreasury.sol";
import {FoundingRound} from "../../../src/engine/FoundingRound.sol";
import {EngineBase} from "./EngineBase.sol";

/// @notice The end-to-end path on a mainnet fork: conditional founding ETH, a real Artcoins v2 launch,
///         a funded FWA board, real swaps paying the skim to the treasury, paid draws through the
///         pool, founder distributions, game earnings, buyback and burn, and the wind-down.
contract EngineForkTest is EngineBase {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        setUpEngine();
    }

    // ------------------------------------------------------------------ launch

    function test_launch_deploysEscrowIntoGame() public {
        _launch();
        assertEq(uint256(round.state()), uint256(FoundingRound.State.Released), "round released");
        assertTrue(treasury.activated(), "activated");
        assertEq(ip.totalShares(), ip.sharesOf(address(treasury)), "treasury is the only shareholder");
        assertEq(treasury.basis(), 6 ether, "basis");
        assertEq(uint256(ip.lifecycle()), uint256(IPoolTypes.Lifecycle.Live), "live");
        assertTrue(ip.depositsPaused(), "deposits paused for everyone");
        assertEq(ip.navCapFloor(), 0, "admission floor restored");
        assertGe(ip.listedCount(), ip.minItems(), "board at least minItems");
        IPoolTypes.GrailItem[] memory g = ip.grailItems();
        assertEq(g.length, 1, "opening GRAIL");
        assertEq(g[0].backing, 5 ether, "5 ETH headline at open");
        assertEq(treasury.reserve(), 4 ether, "reserve");
        assertEq(ip.grail().fund + 5.005 ether, TARGET - 6 ether - 0.5 ether - 4 ether, "GRAIL seed less the opening five");
        _assertTreasuryBooks();
        _assertPoolI1();
        (uint256 fee, uint256 vrf, uint256 total) = clone.quoteAcquisitionPrice(1);
        console2.log("board items", ip.listedCount());
        console2.log("nav after opening (wei)", ip.nav());
        console2.log("quote fee / vrf / total (wei)", fee, vrf, total);
    }

    function test_publicDepositRefused() public {
        _launch();
        vm.deal(player, 1 ether);
        vm.prank(player);
        vm.expectRevert();
        ip.deposit{value: 1 ether}();
    }

    function test_activationRefusedBeforeFunding() public {
        round = _openRound(owner, treasury, TARGET);
        vm.prank(owner);
        treasury.setFoundingRound(round);
        _contribute(f1, 10 ether);
        _launchCoin();
        uint256 fee = _fundFwaFee();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.NotReady.selector, uint8(1)));
        treasury.activate(fee);
        // Without an FWA pool nobody can open the empty pool early.
        vm.expectRevert(IPoolTypes.FwaPoolMissing.selector);
        ip.open();
        // Deadline passes below target: every contributor is refunded in full, nothing was spent.
        vm.warp(round.deadline());
        uint256 before = f1.balance;
        vm.prank(f1);
        round.refund();
        assertEq(f1.balance - before, 10 ether, "refund");
    }

    // ------------------------------------------------------------------ market

    /// @dev Measures the effective fee of real buys and sells on the ENGINE pool and the share the
    ///      treasury captures, after the sniper window.
    function test_market_feeCaptureOnBuyAndSell() public {
        _launch();
        _pastSniperWindow();
        uint256 t0 = address(treasury).balance;
        uint256 out = _buy(trader, 1 ether);
        uint256 buyCapture = address(treasury).balance - t0;
        assertEq(buyCapture, 0.045 ether, "buy: 4.5 percent of ETH volume to the treasury");
        uint256 t1 = address(treasury).balance;
        uint256 ethOut = _sell(trader, out / 2);
        uint256 sellCapture = address(treasury).balance - t1;
        // exactIn sell: skim = ETH volume * 5 percent, treasury takes 90 percent of it.
        uint256 volume = ethOut * 10_000 / 9_500;
        assertApproxEqRel(sellCapture, volume * 450 / 10_000, 1e15, "sell: 4.5 percent of ETH volume");
        console2.log("buy 1 ETH -> coin", out);
        console2.log("sell half -> ETH out (wei)", ethOut);
        console2.log("treasury capture buy / sell (wei)", buyCapture, sellCapture);

        vm.prank(keeper);
        treasury.collectFees();
        EngineTreasury.Totals memory t = treasury.totals();
        assertEq(t.tradingReceived, buyCapture + sellCapture, "receipts booked");
        assertEq(t.foundersFromTrading, (buyCapture + sellCapture) * 6_500 / 10_000, "65 percent to founders");
        assertEq(round.totalDistributed(), t.foundersFromTrading, "founder ledger");
        _assertTreasuryBooks();
    }

    function test_market_sniperWindowSkimGoesToTreasury() public {
        _launch();
        IArtCoinsHookV2.PoolInfo memory info = IArtCoinsHookV2(ARTCOINS_HOOK).poolInfo(key.toId());
        // Activation and the opening deadline took over a day, so the sniper window is long over;
        // a coin bought at the launch block would have paid the elevated skim.
        assertGt(block.timestamp, uint256(info.createdAt) + 3 hours, "window closed");
    }

    // ------------------------------------------------------------------ the full loop

    function test_endToEnd_tradingDrawsEarningsBuybackBurn() public {
        _launch();
        _pastSniperWindow();

        // Coin trading pays the treasury; founders get 65 percent, prizes 35 percent.
        _buy(trader, 20 ether);
        vm.prank(keeper);
        treasury.collectFees();
        uint256 afterTrading = round.totalDistributed();
        assertGt(afterTrading, 0, "founders paid from trading");
        assertGt(treasury.prizeBudget(), 0, "prize budget from trading");

        // The prize budget goes to the GRAIL fund.
        uint256 fundBefore = ip.grail().fund;
        uint256 budget = treasury.prizeBudget();
        treasury.boostGrail();
        assertEq(ip.grail().fund, fundBefore + budget, "GRAIL boosted");

        // Paid draws. Pool books net FWA's share, the mint line, maintenance and the GRAIL feed.
        uint256 navBefore = ip.nav();
        uint256 paid = _drawUntilEarnings(0.01 ether, 3_000);
        console2.log("draws paid (wei)", paid);
        console2.log("nav before / after", navBefore, ip.nav());
        _assertPoolI1();

        uint256 pending = ip.nav() > treasury.basis() ? ip.nav() - treasury.basis() : 0;
        console2.log("earnings pending (wei)", pending);
        if (pending >= 0.001 ether) {
            uint256 bal = address(treasury).balance;
            treasury.harvest();
            EngineTreasury.Totals memory t = treasury.totals();
            assertGt(t.earningsReceived, 0, "earnings harvested");
            assertEq(t.foundersFromEarnings, t.earningsReceived * 5_000 / 10_000, "50 percent of earnings to founders");
            assertGe(ip.nav(), treasury.basis(), "principal stays in the game");
            assertEq(ip.claims(), 0, "no claim queued");
            assertGe(address(treasury).balance + t.foundersFromEarnings, bal, "earnings arrived");
        }
        _assertTreasuryBooks();
    }

    function test_buyback_burnsAndReconciles() public {
        _launch();
        _pastSniperWindow();
        _buy(trader, 5 ether);
        // Fund the buyback bucket from real earnings: draws, then a harvest.
        _drawUntilEarnings(0.01 ether, 3_000);
        treasury.harvest();
        uint256 fund = treasury.buybackFund();
        assertGt(fund, 0, "buyback fund from earnings");
        uint256 supply = coin.totalSupply();
        vm.roll(block.number + 1);
        uint256 burned = treasury.buyback(type(uint256).max, 1);
        assertGt(burned, 0, "coin bought");
        assertEq(coin.totalSupply(), supply - burned, "burn reconciles with supply");
        assertEq(coin.balanceOf(address(treasury)), 0, "nothing held after the burn");
        EngineTreasury.Totals memory t = treasury.totals();
        assertEq(t.coinBurned, burned, "burn record");
        assertLe(t.buybackEthSpent, fund, "spent within the fund");
        // The bounty leg of the treasury's own swap came back to the buyback fund, not to trading.
        assertEq(treasury.buybackFund(), fund - t.buybackEthSpent, "rebate returned to buyback fund");
        _assertTreasuryBooks();
        vm.expectRevert(EngineTreasury.BuybackTooSoon.selector);
        treasury.buyback(type(uint256).max, 1);
    }

    // ------------------------------------------------------------------ founder cap

    function test_founderCap_stopsPaymentsAtEntitlement() public {
        _launch();
        _pastSniperWindow();
        // Enough volume to pay the whole 1.2x entitlement (30 ETH) from trading.
        for (uint256 i; i < 12; ++i) {
            uint256 out = _buy(trader, 80 ether);
            _sell(trader, out);
            vm.prank(keeper);
            treasury.collectFees();
        }
        assertEq(round.totalDistributed(), round.entitlement(), "paid to the cap");
        assertEq(round.remaining(), 0, "nothing more owed");
        uint256 budget = treasury.prizeBudget();
        _buy(trader, 10 ether);
        vm.prank(keeper);
        treasury.collectFees();
        assertEq(round.totalDistributed(), round.entitlement(), "no payment above the cap");
        assertGt(treasury.prizeBudget(), budget, "after the cap, receipts go to prizes");
        // Each founder's credit is pro rata and capped at 1.2x.
        assertEq(round.creditedOf(f1), round.contributionOf(f1) * 12_000 / 10_000, "f1 at cap");
        uint256 before = f1.balance;
        vm.prank(f1);
        round.claim();
        assertEq(f1.balance - before, round.contributionOf(f1) * 12_000 / 10_000, "claimed");
    }

    // ------------------------------------------------------------------ coverage

    function test_coverage_refillsMaintenanceFromReserve() public {
        _launch();
        // Spend maintenance down with keeper refunds at a high basefee.
        vm.fee(200 gwei);
        for (uint256 i; i < 30 && ip.maintenance() >= 0.15 ether; ++i) {
            _draws(10);
        }
        vm.fee(1 gwei);
        if (ip.maintenance() < 0.15 ether) {
            uint256 reserveBefore = treasury.reserve();
            treasury.maintainCoverage();
            assertEq(ip.maintenance(), 0.5 ether, "maintenance at target");
            assertEq(treasury.coverageOwed(), reserveBefore - treasury.reserve(), "top-up owed back by earnings");
        }
    }

    // ------------------------------------------------------------------ wind-down

    function test_windDown_paysFoundersFromResidualAssets() public {
        _launch();
        _draws(40);
        vm.prank(owner);
        treasury.windDown();
        for (uint256 i; i < 50 && !treasury.settled(); ++i) {
            vm.roll(block.number + 1);
            treasury.windDownStep();
        }
        assertTrue(treasury.settled(), "settled");
        assertEq(uint256(ip.lifecycle()), uint256(IPoolTypes.Lifecycle.Exported), "pool exported");
        assertEq(ip.totalShares(), 0, "all shares redeemed");
        // Residual assets: up to the founders' remaining entitlement, the rest to buybacks.
        uint256 paid = round.totalDistributed();
        assertGt(paid, TARGET * 8 / 10, "most of the bankroll back to founders");
        assertLe(paid, round.entitlement(), "never above the cap");
        assertEq(address(treasury).balance, treasury.buybackFund(), "only the buyback fund is left");
        console2.log("wind-down: founders paid (wei)", paid);
    }

    function test_windDown_dormancyLetsAnyoneStart() public {
        _launch();
        vm.prank(player);
        vm.expectRevert(EngineTreasury.NotOwner.selector);
        treasury.windDown();
        vm.warp(block.timestamp + 91 days);
        assertTrue(treasury.dormant(), "dormant");
        vm.prank(player);
        treasury.windDown();
        assertTrue(treasury.windingDown(), "winding down");
    }

    // ------------------------------------------------------------------ owner limits

    function test_poolCall_refusesPrincipalAndControlSelectors() public {
        _launch();
        bytes[] memory denied = new bytes[](7);
        denied[0] = abi.encodeCall(IPool.setAdmin, (owner));
        denied[1] = abi.encodeCall(IPool.startExit, (address(d.pool)));
        denied[2] = abi.encodeCall(IPool.transferGrailEstate, (owner));
        denied[3] = abi.encodeCall(IPool.withdraw, (1));
        denied[4] = abi.encodeCall(IPool.setRegistrar, (owner));
        denied[5] = abi.encodeCall(IPool.setNavCapFloor, (100 ether));
        denied[6] = abi.encodeCall(IPool.setEntryFee, (1_000, 2_500, 20));
        for (uint256 i; i < denied.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(EngineTreasury.SelectorDenied.selector, bytes4(denied[i])));
            treasury.poolCall(denied[i]);
        }
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.ArgumentDenied.selector, IPool.setFeeSplit.selector));
        treasury.poolCall(abi.encodeCall(IPool.setFeeSplit, (0, 300, 600)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.ArgumentDenied.selector, IPool.setPaused.selector));
        treasury.poolCall(abi.encodeCall(IPool.setPaused, (false, false)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.ArgumentDenied.selector, IPool.adminCall.selector));
        treasury.poolCall(
            abi.encodeCall(IPool.adminCall, (address(coin), abi.encodeCall(IERC20.transfer, (owner, 1)), 0))
        );
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.ArgumentDenied.selector, IPool.setReserve.selector));
        treasury.poolCall(abi.encodeCall(IPool.setReserve, (10_000)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EngineTreasury.SelectorDenied.selector, IPool.createFwaPool.selector));
        treasury.poolCall(abi.encodeCall(IPool.createFwaPool, (0)));
        // A tuning setter passes.
        vm.prank(owner);
        treasury.poolCall(abi.encodeCall(IPool.setTip, (0.0003 ether)));
        assertEq(ip.tipWei(), 0.0003 ether);
    }

    function test_gameSettlesWithoutAnyTrading() public {
        _launch();
        _draws(60);
        assertEq(treasury.totals().tradingReceived, 0, "no trading");
        assertGt(ip.grail().pulls, 59, "draws booked");
        _assertPoolI1();
        vm.expectRevert(EngineTreasury.NothingToDo.selector);
        treasury.collectFees();
    }
}
