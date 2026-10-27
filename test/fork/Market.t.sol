// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {EngineBuyer} from "../../src/token/EngineBuyer.sol";
import {Buyback} from "../../src/treasury/Sinks.sol";
import {PrizeVault} from "../../src/game/PrizeVault.sol";

/// @notice The ENGINE market on the real v4 PoolManager: launch, fees, gate, anti-snipe, buybacks, liquidity.
contract MarketForkTest is ForkBase {
    Swapper swapper;
    address trader = makeAddr("trader");

    function setUp() public {
        deployLaunch();
        fundAndFill(3 ether);
        openMarket(10 ether);
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

    function test_launchPriceAndPosition() public view {
        assertTrue(sys.liquidity.launched());
        assertGt(sys.liquidity.totalLiquidity(), 0);
        // 100M ENGINE against 10 ETH: 10M ENGINE per ETH
        uint256 p = uint256(sys.liquidity.sqrtPriceX96());
        uint256 enginePerEth = p * p / (1 << 192);
        assertApproxEqRel(enginePerEth, 10_000_000, 1e15);
        assertLt(sys.engine.balanceOf(address(sys.liquidity)), 1e18);
        assertLt(address(sys.liquidity).balance, 1e15);
    }

    function test_antiSnipeDecaysAndFeeGoesToTreasury() public {
        uint256 t0 = sys.hook.launchedAt();
        assertEq(sys.swapPolicy.snipeFeeBps(), 5_000);
        uint256 before = address(sys.treasury).balance;
        _buy(0.1 ether);
        assertEq(address(sys.treasury).balance - before, 0.1 ether * 5_300 / 10_000, "53% at open");
        vm.warp(t0 + 30 minutes);
        assertEq(sys.swapPolicy.snipeFeeBps(), 2_500);
        before = address(sys.treasury).balance;
        _buy(0.1 ether);
        assertEq(address(sys.treasury).balance - before, 0.1 ether * 2_800 / 10_000, "28% at 30 min");
        vm.warp(t0 + 60 minutes);
        assertEq(sys.swapPolicy.snipeFeeBps(), 0);
        before = address(sys.treasury).balance;
        _buy(0.1 ether);
        assertEq(address(sys.treasury).balance - before, 0.1 ether * 300 / 10_000, "3% after the window");
    }

    function test_sellFeeExactOutputSellReverts() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 got = _buy(1 ether);
        uint256 before = address(sys.treasury).balance;
        uint256 ethOut = _sell(got / 2);
        uint256 fee = address(sys.treasury).balance - before;
        assertApproxEqAbs(fee, (ethOut + fee) * 300 / 10_000, 1, "3% of the ETH output");
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), got);
        vm.expectRevert();
        swapper.sell(0.01 ether, true);
        vm.stopPrank();
    }

    function test_buyExactOutputPaysFeeOnTop() public {
        vm.warp(block.timestamp + 2 hours);
        uint256 before = address(sys.treasury).balance;
        vm.prank(trader);
        (uint256 ethIn, uint256 out) = swapper.buy{value: 1 ether}(1_000_000 ether, true);
        assertEq(out, 1_000_000 ether);
        uint256 fee = address(sys.treasury).balance - before;
        assertApproxEqAbs(fee, (ethIn - fee) * 300 / 10_000, 1);
    }

    function test_gateClosesPublicBuysOnlyUntilGenesisEnd() public {
        vm.warp(block.timestamp + 2 hours);
        assertFalse(sys.swapPolicy.gated(), "pre-market is open both ways");
        uint256 got = _buy(0.5 ether); // pre-market buy works
        openGame();
        assertTrue(sys.swapPolicy.gated());
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        // sells always work
        assertGt(_sell(got / 2), 0);
        // the exempt buy path works (buyback buyer)
        vm.deal(address(sys.buyback), 0.1 ether);
        vm.prank(address(sys.buyback));
        (uint256 out,) = sys.buyer.buy{value: 0.1 ether}(1, address(sys.buyback), 10_000);
        assertGt(out, 0);
        // genesis end re-opens buys
        vm.roll(sys.farm.genesisEndBlock());
        assertFalse(sys.swapPolicy.gated());
        assertGt(_buy(0.1 ether), 0);
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

    function test_buybackOnePurchaseSplitBurnAndReward() public {
        vm.warp(block.timestamp + 2 hours);
        openGame();
        vm.deal(address(sys.treasury), address(sys.treasury).balance + 1 ether);
        uint256 total = sys.treasury.unallocated();
        sys.treasury.distribute();
        assertEq(sys.treasury.owed(address(sys.buyback)), total * 9_000 / 10_000);
        assertEq(sys.treasury.owed(address(sys.grailFund)), total - total * 9_000 / 10_000);
        uint256 supply = sys.engine.totalSupply();
        uint256 e = sys.farm.currentEpoch();
        uint256 out = sys.buyback.process(1);
        uint256 burned = out * 5_000 / 10_000;
        assertEq(sys.engine.totalSupply(), supply - burned, "burn share burned");
        assertEq(sys.farm.deposits(e), out - burned, "the rest deposited in the current epoch");
        assertEq(sys.buyback.totalSpent(), 0.05 ether, "one slice");
        assertEq(address(sys.buyback).balance, 0);
        assertEq(sys.engine.balanceOf(address(sys.buyback)), 0);
        vm.expectRevert(Buyback.TooSoon.selector);
        sys.buyback.process(1);
        uint256 reserve = sys.game.grailReserve();
        uint256 g = sys.grailFund.process();
        assertEq(sys.game.grailReserve(), reserve + g);
        vm.warp(block.timestamp + 1 hours);
        assertGt(sys.buyback.process(1), 0);
    }

    function test_buybackSliceShrinksWithBalance() public {
        vm.warp(block.timestamp + 2 hours);
        vm.deal(address(sys.treasury), 0.08 ether);
        sys.treasury.distribute();
        uint256 owed = sys.treasury.owed(address(sys.buyback));
        assertEq(sys.buyback.nextSlice(), owed / 4, "a quarter of a small allocation");
        sys.buyback.process(1);
        assertEq(sys.buyback.totalSpent(), owed / 4);
    }

    function test_buybackImpactCapLeavesRestInTreasury() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(sys.timelock));
        sys.buyback.setParams(10 ether, 0, 10, 5_000); // 0.1% impact cap, big slice
        vm.deal(address(sys.treasury), 80 ether);
        sys.treasury.distribute();
        uint256 slice = sys.buyback.nextSlice();
        uint256 tBefore = address(sys.treasury).balance;
        uint256 unallocBefore = sys.treasury.unallocated();
        sys.buyback.process(1);
        uint256 spent = sys.buyback.totalSpent();
        assertLt(spent, slice, "stopped by the impact cap");
        assertEq(address(sys.buyback).balance, 0);
        assertEq(address(sys.treasury).balance, tBefore - spent);
        assertEq(sys.treasury.unallocated(), unallocBefore + slice - spent, "unspent back, unallocated");
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
        assertGe(bal, 2.9 ether);
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
