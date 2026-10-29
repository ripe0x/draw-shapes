// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {EngineBuyer} from "../../src/token/EngineBuyer.sol";
import {Buyback} from "../../src/treasury/Buyback.sol";
import {Converter} from "../../src/game/Converter.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {PrizeVault} from "../../src/game/PrizeVault.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @notice The ENGINE market on the real v4 PoolManager: launch, fees to the vault, the gate and its exact end, router
///         semantics, anti-snipe, profit-funded burn-only buybacks, conversions, liquidity.
contract MarketForkTest is ForkBase {
    Swapper swapper;
    address trader = makeAddr("trader");

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
        swapper = new Swapper(IPoolManager(POOL_MANAGER), sys.liquidity.poolKey());
        vm.deal(trader, 100 ether);
    }

    function _buy(uint256 eth) internal returns (uint256 out) {
        vm.prank(trader);
        (, out) = swapper.buy{value: eth}(eth, false);
    }

    function _sell(uint256 amount) internal returns (uint256 ethOut) {
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), amount);
        (, ethOut) = swapper.sell(amount, false);
        vm.stopPrank();
    }

    function _enginePerEth() internal view returns (uint256) {
        uint256 p = uint256(sys.liquidity.sqrtPriceX96());
        return FPM.fullMulDiv(p, p, 1 << 192);
    }

    /// @notice The single-sided launch: no ETH paired, the whole float in one position below the start price.
    function test_launchPriceAndPosition() public view {
        assertTrue(sys.liquidity.launched());
        assertGt(sys.liquidity.totalLiquidity(), 0);
        // 1.0001^184,200 ≈ 99.84M ENGINE per ETH (FDV ≈ 10.02 ETH)
        assertApproxEqRel(_enginePerEth(), 99_839_959, 1e15);
        assertEq(int256(sys.liquidity.startTick()), int256(START_TICK));
        // the genesis rate cap: 10% of ticket ETH in ENGINE at the start price
        assertEq(sys.farm.rateCap(), rateCapAt(START_TICK));
        assertApproxEqRel(sys.farm.rateCap(), 9_983_996 ether, 1e15);
        // the whole float is in the pool (dust burned), and no ETH was paired
        assertLt(sys.engine.balanceOf(address(sys.liquidity)), 1e18);
        assertEq(address(sys.liquidity).balance, 0);
        assertGt(sys.engine.balanceOf(POOL_MANAGER), LP_FLOAT - 1e18);
    }

    /// @notice Nothing can be sold into the pool before anyone has bought: there is no ETH in it.
    function test_singleSidedNoSaleBeforeAnyBuy() public {
        deal(address(sys.engine), trader, 1_000_000 ether);
        vm.warp(block.timestamp + 2 hours);
        uint256 ethOut;
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), 1_000_000 ether);
        try swapper.sell(1_000_000 ether, false) returns (uint256, uint256 out) {
            ethOut = out;
        } catch {}
        vm.stopPrank();
        assertEq(ethOut, 0, "no ETH to sell into");
        assertGe(_enginePerEth(), uint256(99_839_959) * 999 / 1000, "the price did not move above the start");
    }

    /// @notice Whatever sells, the price never goes above the start (ENGINE per ETH never below it), and sellers can
    ///         take out no more ETH than buyers put in.
    function test_singleSidedPriceNeverAboveStart() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 start = _enginePerEth();
        uint256 poolEthBefore = POOL_MANAGER.balance;
        uint256 got = _buy(2 ether);
        assertLt(_enginePerEth(), start, "a buy raises the ENGINE price");
        uint256 poolEthIn = POOL_MANAGER.balance - poolEthBefore;
        // sell everything bought, plus ENGINE from elsewhere (farm rewards in practice)
        deal(address(sys.engine), trader, got + 50_000_000 ether);
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), type(uint256).max);
        uint256 ethOut;
        try swapper.sell(got + 50_000_000 ether, false) returns (uint256, uint256 out) {
            ethOut = out;
        } catch {
            (, ethOut) = swapper.sell(got, false);
        }
        vm.stopPrank();
        assertGe(_enginePerEth(), start * 9_999 / 10_000, "never above the start");
        assertLe(ethOut, poolEthIn, "sellers take out at most what buyers put in");
    }

    function test_antiSnipeDecaysAndFeeGoesToTheVault() public {
        uint256 t0 = sys.hook.launchedAt();
        assertEq(sys.swapPolicy.snipeFeeBps(), 5_000);
        uint256 before = sys.vault.tradingFees();
        _buy(0.1 ether);
        assertEq(sys.vault.tradingFees() - before, 0.1 ether * 5_300 / 10_000, "53% at open");
        vm.warp(t0 + 30 minutes);
        assertEq(sys.swapPolicy.snipeFeeBps(), 2_500);
        before = sys.vault.tradingFees();
        _buy(0.1 ether);
        assertEq(sys.vault.tradingFees() - before, 0.1 ether * 2_800 / 10_000, "28% at 30 min");
        vm.warp(t0 + 60 minutes);
        assertEq(sys.swapPolicy.snipeFeeBps(), 0);
        before = sys.vault.tradingFees();
        _buy(0.1 ether);
        assertEq(sys.vault.tradingFees() - before, 0.1 ether * 300 / 10_000, "3% after the window");
        assertEq(address(sys.vault).balance, sys.vault.tradingFees(), "every fee is vault capital");
    }

    function test_sellFeeExactOutputSellReverts() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 got = _buy(1 ether);
        uint256 before = sys.vault.tradingFees();
        uint256 ethOut = _sell(got / 2);
        uint256 fee = sys.vault.tradingFees() - before;
        assertApproxEqAbs(fee, (ethOut + fee) * 300 / 10_000, 1, "3% of the ETH output");
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), got);
        vm.expectRevert();
        swapper.sell(0.01 ether, true);
        vm.stopPrank();
    }

    function test_buyExactOutputPaysFeeOnTop() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 before = sys.vault.tradingFees();
        vm.prank(trader);
        (uint256 ethIn, uint256 out) = swapper.buy{value: 1 ether}(1_000_000 ether, true);
        assertEq(out, 1_000_000 ether);
        uint256 fee = sys.vault.tradingFees() - before;
        assertApproxEqAbs(fee, (ethIn - fee) * 300 / 10_000, 1);
    }

    function test_gateClosesPublicBuysExactlyUntilTheEndBlock() public {
        vm.warp(block.timestamp + 2 hours);
        assertFalse(sys.swapPolicy.gated(), "the public market is open both ways");
        uint256 got = _buy(0.5 ether);
        openGame();
        assertTrue(sys.swapPolicy.gated());
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        // sells always work
        assertGt(_sell(got / 4), 0);
        // the exempt buy path works only for registered callers (the buyback)
        vm.deal(address(sys.buyback), 0.1 ether);
        vm.prank(address(sys.buyback));
        (uint256 out,) = sys.buyer.buy{value: 0.1 ether}(1, address(sys.buyback), 10_000);
        assertGt(out, 0);
        // one block before the end: still closed
        uint256 end = sys.farm.genesisEndBlock();
        assertEq(end, sys.farm.openBlock() + 21 * 7_200);
        vm.roll(end - 1);
        assertTrue(sys.swapPolicy.gated());
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        assertGt(_sell(got / 4), 0);
        // at the end block buys reopen by themselves, at the ordinary fee: no owner call, no keeper, no claims
        vm.roll(end);
        assertFalse(sys.swapPolicy.gated());
        uint256 before = sys.vault.tradingFees();
        _buy(0.1 ether);
        assertEq(sys.vault.tradingFees() - before, 0.1 ether * 300 / 10_000, "ordinary 3% fee, no reopening tax");
        vm.roll(end + 1_000_000);
        assertFalse(sys.swapPolicy.gated(), "and stay open");
    }

    /// @notice A shared router is the hook's `sender` for all its users. The exempt set is fixed at wiring and has no
    ///         setter, so no router can be whitelisted; the one exempt buyer serves registered callers only.
    function test_sharedRouterCannotOpenTheGate() public {
        openGame();
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        assertFalse(sys.swapPolicy.exempt(address(swapper)));
        (bool ok,) =
            address(sys.swapPolicy).call(abi.encodeWithSignature("setExempt(address,bool)", address(swapper), true));
        assertFalse(ok, "no exemption setter");
        vm.prank(trader);
        vm.expectRevert(EngineBuyer.NotCaller.selector);
        sys.buyer.buy{value: 0.1 ether}(0, trader, 10_000);
    }

    function test_buyerRejectsUnregisteredCallers() public {
        vm.prank(trader);
        vm.expectRevert(EngineBuyer.NotCaller.selector);
        sys.buyer.buy{value: 0.1 ether}(0, trader, 100);
    }

    function test_hookInitialisesOnlyOnce() public {
        PoolKey memory key = sys.liquidity.poolKey();
        key.tickSpacing = 60;
        vm.expectRevert();
        IPoolManager(POOL_MANAGER).initialize(key, 2 ** 96);
    }

    function _profit(uint256 amount) internal {
        vm.deal(address(sys.game), address(sys.game).balance + amount);
        vm.prank(address(sys.game));
        (bool ok,) = address(sys.buyback).call{value: amount}("");
        assertTrue(ok);
    }

    function test_buybackBurnsEverythingItBuys() public {
        vm.warp(block.timestamp + 2 hours);
        openGame();
        _profit(1 ether);
        assertEq(sys.buyback.profitReceived(), 1 ether);
        uint256 supply = sys.engine.totalSupply();
        uint256 out = sys.buyback.process(1);
        assertEq(sys.engine.totalSupply(), supply - out, "all of it burned");
        assertEq(sys.buyback.totalBurned(), out);
        assertEq(sys.buyback.totalSpent(), 0.05 ether, "one slice of at most 0.05 ETH");
        assertEq(address(sys.buyback).balance, 0.95 ether);
        assertEq(sys.engine.balanceOf(address(sys.buyback)), 0);
        vm.expectRevert(Buyback.TooSoon.selector);
        sys.buyback.process(1);
        vm.warp(block.timestamp + 1 hours);
        assertGt(sys.buyback.process(1), 0);
    }

    function test_buybackTakesProfitOnly() public {
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        (bool ok,) = address(sys.buyback).call{value: 1 ether}("");
        assertFalse(ok, "only the game's profit, or the buyer's change");
    }

    function test_buybackSliceIsAMaximum() public {
        vm.warp(block.timestamp + 2 hours);
        _profit(0.02 ether);
        assertEq(sys.buyback.nextSlice(), 0.02 ether, "a smaller balance is spent whole");
        sys.buyback.process(1);
        assertEq(sys.buyback.totalSpent(), 0.02 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(Buyback.NoWork.selector);
        sys.buyback.process(1);
    }

    function test_buybackImpactCapHoldsWhateverMinOut() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(sys.timelock));
        sys.buyback.setParams(10 ether, 0, 10, 2_000); // 0.1% impact cap, big slice
        _profit(8 ether);
        uint256 slice = sys.buyback.nextSlice();
        sys.buyback.process(0); // a keeper's minOut of zero weakens nothing
        uint256 spent = sys.buyback.totalSpent();
        assertLt(spent, slice, "stopped by the impact cap");
        assertEq(address(sys.buyback).balance, 8 ether - spent, "the rest stays for the next call");
    }

    function test_buybackRefusesAPriceMovedInTheSameBlock() public {
        vm.warp(block.timestamp + 2 hours);
        _profit(0.05 ether);
        assertTrue(sys.buyback.priceOk());
        // a front-runner buys ahead in the same block, moving the price more than 2%
        _buy(1 ether);
        assertFalse(sys.buyback.priceOk());
        vm.expectRevert(Buyback.PriceMoved.selector);
        sys.buyback.process(1);
        // next block, the moved price is the new opening price
        vm.roll(block.number + 1);
        assertTrue(sys.buyback.priceOk());
        assertGt(sys.buyback.process(1), 0);
    }

    function test_buybacksContinueThroughTheGenesisEnd() public {
        openGame();
        _profit(0.2 ether);
        uint256 end = sys.farm.genesisEndBlock();
        vm.roll(end - 1);
        assertGt(sys.buyback.process(1), 0, "during the gate");
        vm.roll(end);
        vm.warp(block.timestamp + 1 hours);
        assertGt(sys.buyback.process(1), 0, "after it");
    }

    /// @notice Conversion spends exactly the redeemed backing: ETH sent alongside cannot top it up, and the converter
    ///         is no gateway for public buys.
    function test_conversionCannotBeToppedUp() public {
        openGame();
        uint256 id = pull(trader);
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, 0.05 ether));
        pool.processAcquisitions(5);
        (,,, uint256 listingId,) = pool.acquisitions(id);
        (uint48 tokenId,,,,,,,) = sys.game.items(listingId);
        // stray ETH in the converter does not join the purchase
        vm.deal(address(sys.converter), 5 ether);
        vm.startPrank(trader);
        shapes.approve(address(sys.converter), tokenId);
        (bool ok,) =
            address(sys.converter).call{value: 1 ether}(abi.encodeCall(Converter.convert, (listingId, 1, true)));
        assertFalse(ok, "convert is not payable");
        sys.converter.convert(listingId, 1, true);
        vm.stopPrank();
        assertEq(sys.converter.totalEthIn(), 0.05 ether, "exactly the backing");
        assertEq(address(sys.converter).balance, 5 ether);
    }

    function test_vaultShutdownToLiquidity() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertEq(sys.vault.activeGame(), address(0));
        vm.expectRevert(PrizeVault.NotReady.selector);
        sys.vault.shutdown(0);
        vm.warp(block.timestamp + 30 days);
        uint128 liqBefore = sys.liquidity.totalLiquidity();
        uint256 bal = address(sys.vault).balance;
        assertGe(bal, OPENING_CAPITAL - 0.5 ether, "the opening capital came back");
        sys.vault.shutdown(0);
        assertEq(address(sys.vault).balance, 0);
        assertGt(sys.liquidity.totalLiquidity(), liqBefore);
    }

    function test_secondGameAfterRetiring() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        // the vault can fund a new game once the old one returned
        address g2 = address(new Dummy());
        vm.prank(address(sys.timelock));
        sys.vault.setActiveGame(g2);
        assertEq(sys.vault.activeGame(), g2);
    }
}

contract Dummy {
    function receiveFunding() external payable {}
}
