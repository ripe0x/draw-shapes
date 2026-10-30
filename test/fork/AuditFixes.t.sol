// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {PoolOwner} from "../../src/game/PoolOwner.sol";
import {ProtocolLiquidity} from "../../src/token/ProtocolLiquidity.sol";
import {Lens} from "../../src/Lens.sol";

interface IFactoryPredict {
    function predictPoolAddress(address poolOwner, bytes32 userSalt) external view returns (address);
}

/// @notice Regressions for the findings of the independent audit of 5494c33 (docs/IMPLEMENTOR_DECISIONS.md D53). Each
///         test reproduces the audit's sequence against the fixed code and asserts the right it had violated.
contract AuditFixesGameTest is ForkBase {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
        openGame();
        vm.warp(block.timestamp + 1);
    }

    function _acquire(address payer, address purchaser, uint256 count) internal returns (bool ok) {
        (uint256 fee, uint256 vrf,) = pool.quoteAcquisitionPrice(count);
        uint256 version = pool.inventoryVersion();
        uint256 value = count * (fee + vrf);
        vm.deal(payer, payer.balance + value);
        vm.prank(payer);
        if (count == 1) {
            try pool.acquire{value: value}(purchaser, fee, 0, 10_000, version, block.timestamp + 1 hours) {
                ok = true;
            } catch (bytes memory err) {
                assertEq(bytes4(err), bytes4(keccak256("PurchaseNotAllowed()")), "refused by the gate");
            }
        } else {
            try pool.acquireBatch{value: value}(purchaser, count, fee, 0, 10_000, version, block.timestamp + 1 hours) {
                ok = true;
            } catch (bytes memory err) {
                assertEq(bytes4(err), bytes4(keccak256("PurchaseNotAllowed()")), "refused by the gate");
            }
        }
    }

    function _settleHead(uint256 backing) internal {
        uint256 id = pool.requestIdAtSequence(pool.lastIssuedSequence());
        vm.roll(block.number + 3);
        deliverWord(id, wordFor(id, backing));
        pool.processAcquisitions(10);
    }

    function _promotion(uint256 backing) internal returns (uint256 listingId) {
        vm.deal(address(sys.vault), address(sys.vault).balance + 2 ether);
        vm.startPrank(address(sys.timelock));
        sys.vault.fundPromotion(backing + 0.2 ether);
        sys.game.startPromotion(backing, 9_000, block.number + 10_000);
        vm.stopPrank();
        listingId = sys.game.promoListing();
    }

    /// @notice Finding 1: a purchase naming Shapes or Shape Packs as purchaser would leave the prize undeliverable and
    ///         unrefundable in FWA's escrow; the gate refuses it before any fee.
    function test_gateRefusesPurchasersThatCanNeverReceiveTheirPrize() public {
        assertFalse(sys.poolOwner.canPurchase(SHAPES));
        assertFalse(sys.poolOwner.canPurchase(SHAPE_PACKS));
        assertFalse(sys.poolOwner.canPurchase(address(0)));
        assertTrue(sys.poolOwner.canPurchase(alice));
        assertFalse(_acquire(alice, SHAPES, 1), "Shapes as purchaser: refused");
        assertFalse(_acquire(alice, SHAPE_PACKS, 1), "Shape Packs as purchaser: refused");
        assertEq(pool.lastIssuedSequence(), 0, "no request issued, no fee taken");
        assertTrue(_acquire(alice, bob, 1), "any other purchaser: admitted");
        // the Lens asks the gate for an ordinary purchaser, so the site and keeper see it open
        Lens.Addresses memory a = Lens.Addresses(
            sys.game, sys.farm, sys.keeperFund, sys.buyback, sys.swapPolicy, sys.liquidity, sys.vault, sys.converter
        );
        assertTrue(sys.lens.game(a).gateOpen, "Lens: gate open");
        assertTrue(sys.lens.work(a).gateOpen, "Lens work: gate open");
    }

    /// @notice Finding 2: with a promotion listed, the gate counts only board prizes against the floor, so a batch of
    ///         five can no longer take the board below 80.
    function test_gateDoesNotCountThePromotionAsABoardPrize() public {
        _promotion(1 ether);
        assertEq(pool.activeListingCount(), 101);
        uint256 captures;
        while (_acquire(alice, alice, 1)) {
            _settleHead(0.01 ether);
            ++captures;
            assertGe(pool.activeListingCount() - 1, 80, "board prizes never below the floor");
        }
        // admitted while active >= unsettled + 5 + 80 + 1 (the promotion): the last single starts at 86
        assertEq(captures, 16);
        assertEq(pool.activeListingCount(), 85, "84 board prizes and the promotion");
        assertFalse(_acquire(bob, bob, 5), "the batch that would leave 79 board prizes is refused");
    }

    /// @notice Finding 3: when proceeds were booked below what FWA paid on a promotional win, the true-up returns the
    ///         difference to the promotion budget, never to ordinary revenue or the buyback.
    function test_promotionalTrueUpStaysInThePromotionBudget() public {
        FwaGame.Capital memory c = cfg.capital;
        c.maxEdgeBps = 800; // governance accepts a higher edge: booking at 8% while FWA charges 5%
        vm.prank(address(sys.timelock));
        sys.game.setCapital(c);
        uint256 promo = _promotion(1 ether);
        uint256 budgetBefore = sys.game.promoBudget();
        assertTrue(_acquire(alice, alice, 1));
        _settleHead(1 ether);
        (,,,,,,, IFWAPool.ListingStatus st) = pool.listings(promo);
        assertTrue(st == IFWAPool.ListingStatus.Settled, "the promotion was won");
        uint256 actual = pool.ownerProceeds();
        sys.game.sync(10);
        assertEq(sys.game.proceedsBooked(), actual, "trued up to what FWA paid");
        assertEq(sys.game.revenue(), 0, "no promotional proceeds in ordinary revenue");
        assertEq(sys.game.distributed(), 0, "nothing to the buyback");
        assertEq(sys.game.promoBudget() - budgetBefore, actual, "the whole of FWA's payment is promotion money");
        assertEq(sys.game.promoProceeds(), actual);
    }

    /// @notice Finding 6: `createPool` takes no salt, so a front-run creates exactly the intended pool, owned by the
    ///         PoolOwner; the deploy routine skips a pool that already exists.
    function test_frontRunCreatePoolCreatesTheIntendedPool() public {
        bytes32 salt = keccak256("draw-shapes.audit.salt");
        PoolOwner po2 = new PoolOwner(address(sys.timelock), SHAPES, SHAPE_PACKS, FACTORY, FWA_IMPL, salt);
        FwaGame g2 = new FwaGame(
            FwaGame.Config({
                governance: address(sys.timelock),
                factory: FACTORY,
                poolOwner: address(po2),
                vault: address(sys.vault),
                farm: address(sys.farm),
                buyback: address(sys.buyback),
                keeperFund: address(sys.keeperFund),
                board: address(sys.board),
                pricing: address(sys.pricing),
                buyer: address(sys.buyer),
                capital: cfg.capital,
                marketLead: cfg.marketLead
            })
        );
        po2.wire(address(g2));
        uint256 eth = fwaFeeQuote(FACTORY, POOL_MANAGER, 500);
        vm.deal(address(this), eth);
        sys.feeBuyer.buyTo{value: eth}(address(po2), factory.poolCreationFee());
        address predicted = IFactoryPredict(FACTORY).predictPoolAddress(address(po2), salt);
        vm.prank(makeAddr("frontRunner"));
        address created = po2.createPool();
        assertEq(created, predicted, "the intended address");
        assertEq(IOwnedPool(created).owner(), address(po2));
        assertEq(address(g2.pool()), created);
        vm.expectRevert(PoolOwner.PoolExists.selector);
        po2.createPool();
    }

    /// @notice Finding 8: ETH left in FwaFeeBuyer is not paid to the next caller.
    function test_feeBuyerRefundsOnlyTheCallersEth() public {
        vm.deal(address(sys.feeBuyer), 1 ether);
        address outsider = makeAddr("outsider");
        vm.deal(outsider, 0.01 ether);
        vm.prank(outsider);
        sys.feeBuyer.buyTo{value: 0.01 ether}(outsider, 0);
        assertLe(outsider.balance, 0.01 ether, "no more than its own unspent ETH back");
        assertEq(address(sys.feeBuyer).balance, 1 ether, "the earlier ETH stays");
    }

    /// @notice Finding 7: `shutdown` takes no caller price limit, so the vault's ETH goes into the position; an
    ///         addition that would add nothing reverts instead of stranding ETH.
    function test_shutdownAddsLiquidityAndEmptyAdditionsRevert() public {
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        vm.warp(block.timestamp + 30 days);
        uint256 amount = address(sys.vault).balance;
        uint128 before = sys.liquidity.totalLiquidity();
        sys.vault.shutdown();
        assertGt(sys.liquidity.totalLiquidity(), before, "liquidity added");
        assertEq(address(sys.vault).balance, 0);
        // Positions end at the start, so near it the range absorbs little ETH; the rest stays in ProtocolLiquidity for
        // later additions (protocol-owned, never spent outside the pool).
        assertLe(address(sys.liquidity).balance, amount);
        // governance asking for a limit that admits no swap: nothing would be added, so it reverts
        uint160 current = sys.liquidity.sqrtPriceX96();
        vm.deal(address(sys.timelock), 1 ether);
        vm.prank(address(sys.timelock));
        vm.expectRevert(ProtocolLiquidity.NothingAdded.selector);
        sys.liquidity.addLiquidity{value: 1 ether}(current - 1);
    }
}

/// @notice Finding 4, in the open market before the game opens (public buys allowed): a governance addition no longer
///         lets the price return above the start.
contract AuditFixesMarketTest is ForkBase {
    address trader = makeAddr("trader");

    function setUp() public {
        deployLaunch();
        fundAndFill(OPENING_CAPITAL);
        openMarket();
    }

    /// @dev Past the start there is no liquidity, so a sell there trades nothing (v4 still moves the reported price
    ///      through the empty range). The check is on what sales pay: every ENGINE sold gets at least the launch
    ///      valuation's ETH (before the 3% fee), and nothing is paid once the price reaches the start.
    function test_priceCeilingHoldsAfterLiquidityAddition() public {
        uint256 p0 = FPM2.fullMulDiv(TickMath.getSqrtPriceAtTick(START_TICK), TickMath.getSqrtPriceAtTick(START_TICK), 1 << 96);
        vm.warp(block.timestamp + 2 hours);
        Swapper swapper = new Swapper(IPoolManager(POOL_MANAGER), sys.liquidity.poolKey());
        vm.deal(trader, 2 ether);
        vm.prank(trader);
        (, uint256 got) = swapper.buy{value: 2 ether}(2 ether, false);
        vm.deal(address(sys.timelock), 1 ether);
        vm.prank(address(sys.timelock));
        sys.liquidity.addLiquidity{value: 1 ether}(0);
        deal(address(sys.engine), trader, got + 25_000_000 ether);
        vm.startPrank(trader);
        sys.engine.approve(address(swapper), type(uint256).max);
        uint256 left = got + 25_000_000 ether;
        uint256 paidOut;
        for (uint256 i; i < 8; ++i) {
            uint256 amt = left / (8 - i);
            left -= amt;
            uint256 sold = sys.engine.balanceOf(trader);
            uint256 ethOut;
            try swapper.sell(amt, false) returns (uint256, uint256 out) {
                ethOut = out;
            } catch {}
            sold -= sys.engine.balanceOf(trader);
            paidOut += ethOut;
            if (ethOut == 0) continue;
            // ENGINE per ETH paid, grossed up for the 3% fee, never above the launch price (with 0.1% rounding room)
            uint256 grossEth = ethOut * 10_000 / 9_700;
            assertLe(FPM2.fullMulDiv(sold, 1 << 96, grossEth), p0 * 1001 / 1000, "no sale below the launch valuation");
        }
        vm.stopPrank();
        assertGt(paidOut, 1 ether, "the sales reached the added liquidity");
        assertLe(paidOut, 2 ether + 1 ether, "sellers take out at most what buyers and the addition put in");
    }
}

library FPM2 {
    function fullMulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d; // operands here stay far below 2^256
    }
}

interface IOwnedPool {
    function owner() external view returns (address);
}
