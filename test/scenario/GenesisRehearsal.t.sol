// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "../fork/ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";

/// @notice The full genesis rehearsal on the pinned mainnet fork with block and time manipulation (local only):
///         deploy, 48 h pre-market, game open with the gate on, 21 epochs of pulls with late deliveries and a
///         timeout, daily sync, distribute and buybacks, claims as epochs become final, genesis end (gate off,
///         retireUnearned), post-genesis epochs paid from deposits only, a second game after retiring the first,
///         and shutdown into the liquidity position. A second run shortens genesis once.
contract GenesisRehearsal is ForkBase {
    uint256 constant DAY_BLOCKS = 7_200;
    uint256 constant PULLS_PER_DAY = 6;

    Swapper swapper;
    address[5] players;
    address keeper = makeAddr("keeper");
    address trader = makeAddr("trader");
    uint256 nonce;
    uint256 timeouts;
    uint256 claimedTotal;

    function setUp() public {
        deployLaunch();
        for (uint256 i; i < 5; ++i) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
        }
        vm.deal(trader, 100 ether);
    }

    function _day() internal {
        vm.roll(block.number + DAY_BLOCKS);
        vm.warp(block.timestamp + 1 days);
    }

    function _advance(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * 12);
    }

    /// @dev One day of play: pulls spread over the day, some words delivered late in the day after the next
    ///      pull, one timeout when `withTimeout`; then the keeper's daily jobs and claims.
    function _playDay(bool withTimeout) internal {
        uint256 step = DAY_BLOCKS / (PULLS_PER_DAY + 1);
        uint256 lateId;
        for (uint256 p; p < PULLS_PER_DAY; ++p) {
            address who = players[(nonce++) % 5];
            uint256 id = pull(who);
            if (withTimeout && p == 0) {
                // the word arrives after its deadline: TimedOut, then Expired
                _advance(31);
                deliverWord(id, uint256(keccak256(abi.encode(nonce, "late"))));
                ++timeouts;
            } else if (p % 3 == 1) {
                // this word will arrive after the next request's word (out of order, still on time)
                lateId = id;
                _advance(2);
                continue;
            } else {
                _advance(3);
                deliverWord(id, uint256(keccak256(abi.encode(nonce))));
                if (lateId != 0) {
                    _advance(20);
                    deliverWord(lateId, uint256(keccak256(abi.encode(nonce, "l"))));
                    lateId = 0;
                }
            }
            pool.processAcquisitions(10);
            _advance(step);
            vm.prank(keeper);
            try sys.game.sync(50) {} catch {}
        }
        if (lateId != 0) {
            _advance(3);
            deliverWord(lateId, 77);
            pool.processAcquisitions(10);
        }
        _keeperJobs();
        _claimAll();
    }

    function _keeperJobs() internal {
        vm.startPrank(keeper);
        try sys.game.sync(100) {} catch {}
        try sys.treasury.distribute() {} catch {}
        try sys.buyback.process(0) {} catch {}
        try sys.grailFund.process() {} catch {}
        vm.stopPrank();
    }

    function _claimAll() internal {
        uint256 cur = sys.farm.currentEpoch();
        for (uint256 i; i < 5; ++i) {
            (uint256 total, uint256[] memory es) = sys.lens.claimable(sys.farm, players[i], 0, cur + 1);
            if (total == 0) continue;
            vm.prank(players[i]);
            claimedTotal += sys.farm.claim(es);
        }
    }

    function _preMarket() internal {
        fundAndFill(3 ether);
        openMarket(10 ether);
        swapper = new Swapper(IPoolManager(POOL_MANAGER), sys.liquidity.poolKey());
        // 48 h of pre-market trading: buys and sells, anti-snipe decays in the first hour
        for (uint256 h; h < 48; h += 4) {
            vm.warp(block.timestamp + 4 hours);
            vm.roll(block.number + 1_200);
            vm.prank(trader);
            (, uint256 got) = swapper.buy{value: 0.2 ether}(0.2 ether, false);
            vm.startPrank(trader);
            sys.engine.approve(address(swapper), got / 3);
            swapper.sell(got / 3, false);
            vm.stopPrank();
        }
        assertGt(address(sys.treasury).balance, 0, "pre-market fees");
    }

    function test_fullGenesis() public {
        _preMarket();
        openGame();
        assertTrue(sys.swapPolicy.gated());
        vm.prank(trader);
        vm.expectRevert();
        swapper.buy{value: 0.1 ether}(0.1 ether, false);

        for (uint256 d; d < 21; ++d) {
            _playDay(d == 7);
            // the day just ended is final once booked; claims happen the next day
            assertEq(sys.farm.currentEpoch(), d, "epoch tracks days");
            _advanceToNextEpoch();
        }
        _keeperJobs();
        _claimAll();

        // genesis end: the gate lifts, unearned genesis and the unused bonus are burned
        assertGe(block.number, sys.farm.genesisEndBlock());
        assertFalse(sys.swapPolicy.gated());
        vm.prank(trader);
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        uint256 bonusLeft = sys.farm.bonusPool();
        uint256 supply = sys.engine.totalSupply();
        vm.prank(keeper);
        uint256 burned = sys.farm.retireUnearned();
        assertEq(burned, 0, "every genesis epoch had pulls");
        assertEq(sys.engine.totalSupply(), supply - bonusLeft);

        // every pull of every genesis epoch is booked; units = delivered pulls
        uint256 units;
        for (uint256 e; e < 21; ++e) {
            assertTrue(sys.farm.isFinal(e), "final");
            units += sys.game.epochUnits(e);
        }
        assertEq(units, sys.game.pullsBooked());
        assertEq(units, 21 * PULLS_PER_DAY - timeouts, "one timeout, every other pull delivered");
        // genesis paid out (up to rounding) to players
        assertApproxEqAbs(claimedTotal, 100_000_000 ether + sys.farm.totalDeposited(), 1e9, "genesis + deposits claimed");

        // post-genesis epochs: pots come from buyback deposits only
        uint256 e0 = sys.farm.currentEpoch();
        _playDay(false);
        vm.warp(block.timestamp + 1 hours);
        vm.deal(address(sys.treasury), address(sys.treasury).balance + 0.5 ether);
        _keeperJobs();
        uint256 dep = sys.farm.deposits(e0);
        assertGt(dep, 0, "buyback reward deposited");
        _advanceToNextEpoch();
        _keeperJobs();
        assertEq(sys.farm.potOf(e0), dep, "post-genesis pot is deposits only");
        uint256 before = claimedTotal;
        _claimAll();
        assertApproxEqAbs(claimedTotal - before, dep, 1e6, "deposits paid to the epoch's players");

        // a second game after retiring the first
        _retireGame();
        FwaGame g2 = _secondGame();
        vm.deal(address(this), 0);
        for (uint256 i; i < 10 && g2.liveCount() < 100; ++i) {
            g2.sync(50);
        }
        vm.prank(address(sys.timelock));
        g2.openGame();
        assertEq(sys.farm.openBlock() != 0, true, "clock not restarted");
        pool = g2.pool();
        uint256 e2 = sys.farm.currentEpoch();
        uint256 r = pull(players[0]);
        _advance(3);
        deliverWord(r, 4242);
        pool.processAcquisitions(10);
        g2.sync(10);
        assertEq(sys.farm.epochUnits(e2), sys.game.epochUnits(e2) + 1, "units summed across ledgers");

        // shutdown into the liquidity position
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        _advance(40);
        for (uint256 i; i < 20 && !g2.retired(); ++i) {
            g2.retireStep(50);
        }
        vm.warp(block.timestamp + 31 days);
        uint128 liq = sys.liquidity.totalLiquidity();
        sys.vault.shutdown(0);
        assertGt(sys.liquidity.totalLiquidity(), liq);
        assertEq(address(sys.vault).balance, 0);
    }

    function test_shortenOnce() public {
        _preMarket();
        openGame();
        for (uint256 d; d < 5; ++d) {
            _playDay(false);
            _advanceToNextEpoch();
        }
        // at epoch 5, the earliest allowed end is epoch 8 (current + 1 + 2 notice)
        vm.prank(address(sys.timelock));
        vm.expectRevert();
        sys.farm.shorten(7);
        vm.prank(address(sys.timelock));
        sys.farm.shorten(8);
        assertEq(sys.farm.genesisEndBlock(), sys.farm.openBlock() + 8 * DAY_BLOCKS);
        for (uint256 d = 5; d < 8; ++d) {
            assertTrue(sys.swapPolicy.gated());
            _playDay(false);
            _advanceToNextEpoch();
        }
        _keeperJobs();
        assertFalse(sys.swapPolicy.gated(), "gate lifts at the shortened end");
        vm.prank(keeper);
        sys.farm.retireUnearned();
        _claimAll();
        uint256 earned;
        uint256 deposited;
        for (uint256 e; e < 8; ++e) {
            earned += sys.schedule.allocationOf(e, 100_000_000 ether);
            deposited += sys.farm.deposits(e);
        }
        assertApproxEqAbs(claimedTotal, earned + deposited, 1e9, "only the first 8 epochs paid");
        assertEq(sys.farm.totalBurned(), 100_000_000 ether - earned + 10_000_000 ether - sys.farm.totalBonusPaid());
    }

    function _advanceToNextEpoch() internal {
        uint256 next = sys.farm.openBlock() + (sys.farm.currentEpoch() + 1) * DAY_BLOCKS;
        if (block.number < next) _advance(next - block.number);
    }

    function _retireGame() internal {
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        _advance(40);
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            sys.game.retireStep(50);
        }
        assertTrue(sys.game.retired());
        assertEq(sys.vault.activeGame(), address(0));
    }

    function _secondGame() internal returns (FwaGame g2) {
        g2 = new FwaGame(
            FwaGame.Config({
                governance: address(sys.timelock),
                shapes: SHAPES,
                factory: FACTORY,
                expectedImplementation: FWA_IMPL,
                vault: address(sys.vault),
                farm: address(sys.farm),
                treasury: address(sys.treasury),
                keeperFund: address(sys.keeperFund),
                board: address(sys.board),
                pricing: address(sys.pricing),
                grail: address(sys.grail),
                buyer: address(sys.buyer),
                reserveTarget: cfg.reserveTarget,
                maintenanceInterval: cfg.maintenanceInterval
            })
        );
        uint256 eth = fwaFeeQuote(FACTORY, POOL_MANAGER, 500);
        vm.deal(address(this), eth);
        sys.feeBuyer.buyTo{value: eth}(address(g2), factory.poolCreationFee());
        g2.createPool(keccak256("draw-shapes.fwa-pool.v2"));
        vm.startPrank(address(sys.timelock));
        sys.farm.addLedger(address(g2));
        sys.keeperFund.setPayer(address(g2), true);
        sys.grailFund.setGame(address(g2));
        sys.vault.setActiveGame(address(g2));
        vm.stopPrank();
        sys.vault.fund();
    }
}
