// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "../fork/ForkBase.sol";
import {Swapper} from "../utils/Swapper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {PoolOwner} from "../../src/game/PoolOwner.sol";
import {FwaGame} from "../../src/game/FwaGame.sol";
import {Lens} from "../../src/Lens.sol";

/// @notice The full genesis rehearsal on the pinned mainnet fork with block and time manipulation (local only):
///         deploy, 48 h public market, game open with the gate on, 21 epochs of pulls with late deliveries and a
///         timeout, daily sync, profit-funded buybacks, finalization and claims as epochs become final, genesis end
///         (buys reopen by themselves, the bonus retires), post-genesis play with no rewards and no trading fees,
///         a second game after retiring the first, and shutdown into the liquidity position.
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
        try sys.buyback.process(0) {} catch {}
        WorkLike memory w = _work();
        if (w.finalizable.length != 0) sys.farm.finalize(w.finalizable);
        vm.stopPrank();
    }

    struct WorkLike {
        uint256[] finalizable;
    }

    function _work() internal view returns (WorkLike memory w) {
        w.finalizable = sys.lens.work(_addresses()).finalizable;
    }

    function _addresses() internal view returns (Lens.Addresses memory a) {
        a = Lens.Addresses(
            sys.game, sys.farm, sys.keeperFund, sys.buyback, sys.swapPolicy, sys.liquidity, sys.vault, sys.converter
        );
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
        fundAndFill(OPENING_CAPITAL);
        openMarket();
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
        assertGt(sys.vault.tradingFees(), 0, "public-market fees reach the vault");
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

        // genesis end: the gate lifts by itself; the unused bonus retires
        assertGe(block.number, sys.farm.genesisEndBlock());
        assertFalse(sys.swapPolicy.gated());
        vm.prank(trader);
        swapper.buy{value: 0.1 ether}(0.1 ether, false);
        uint256 bonusLeft = sys.farm.bonusPool();
        uint256 supply = sys.engine.totalSupply();
        sys.farm.retireBonus();
        assertEq(sys.engine.totalSupply(), supply - bonusLeft);

        // every pull of every genesis epoch is booked; weight = delivered ticket ETH
        uint256 weight;
        for (uint256 e; e < 21; ++e) {
            assertTrue(sys.farm.isFinal(e), "final");
            assertTrue(sys.farm.isFinalized(e), "finalized");
            weight += sys.game.epochWeight(e);
        }
        assertEq(weight, sys.game.turnover());
        assertEq(sys.game.pullsBooked(), 21 * PULLS_PER_DAY - timeouts, "one timeout, every other pull delivered");
        // at ~0.18 ETH a day the rate cap binds: players get their rate, the rest of each cap is burned
        assertApproxEqAbs(claimedTotal, sys.farm.totalPots(), 1e6, "every pot claimed");
        assertEq(sys.farm.totalPots() + sys.farm.totalBurned() - bonusLeft, 190_000_000 ether, "pots + burns = budget");
        assertEq(sys.farm.reserved(), sys.farm.totalPots() - sys.farm.totalClaimed());

        // after genesis: no rewards, no trading fees; the game keeps settling and replenishing
        uint256 fees = sys.vault.tradingFees();
        uint256 pulls = sys.game.pullsBooked();
        for (uint256 d; d < 3; ++d) {
            _playDay(false);
            _advanceToNextEpoch();
        }
        vm.warp(block.timestamp + sys.game.maintenanceInterval());
        _keeperJobs();
        assertEq(sys.vault.tradingFees(), fees);
        assertGt(sys.game.pullsBooked(), pulls);
        assertEq(sys.farm.rewardOf(sys.farm.currentEpoch() - 1, players[0]), 0, "no post-genesis rewards");
        assertEq(sys.game.liveCount(), 100, "prizes replenished");
        assertGe(sys.game.cash(), sys.game.replacementsOwed());

        // a second game after retiring the first
        _retireGame();
        FwaGame g2 = _secondGame();
        vm.deal(address(this), 0);
        for (uint256 i; i < 10 && g2.liveCount() < 100; ++i) {
            g2.sync(50);
        }
        assertEq(g2.liveCount(), 100, "the returned capital refills the second game");
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
        (,, uint256 paid,,) = pool.acquisitions(r);
        assertEq(sys.farm.epochWeight(e2), sys.game.epochWeight(e2) + paid, "weights summed across ledgers");

        // shutdown into the liquidity position
        vm.prank(address(sys.timelock));
        sys.vault.retireGame();
        _advance(40);
        for (uint256 i; i < 20 && !g2.retired(); ++i) {
            g2.retireStep(50);
        }
        vm.warp(block.timestamp + 31 days);
        uint128 liq = sys.liquidity.totalLiquidity();
        sys.vault.shutdown();
        assertGt(sys.liquidity.totalLiquidity(), liq);
        assertEq(address(sys.vault).balance, 0);
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
        PoolOwner po2 = new PoolOwner(address(sys.timelock), SHAPES, SHAPE_PACKS, FACTORY, FWA_IMPL, keccak256("draw-shapes.fwa-pool.v2"));
        g2 = new FwaGame(
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
        uint256 eth = fwaFeeQuote(FACTORY, POOL_MANAGER, 500);
        vm.deal(address(this), eth);
        po2.wire(address(g2));
        sys.feeBuyer.buyTo{value: eth}(address(po2), factory.poolCreationFee());
        po2.createPool();
        vm.startPrank(address(sys.timelock));
        sys.farm.addLedger(address(g2));
        sys.keeperFund.setPayer(address(g2), true);
        sys.keeperFund.setOverflow(address(g2));
        sys.buyback.setSource(address(g2), true);
        sys.vault.setActiveGame(address(g2));
        vm.stopPrank();
        sys.vault.fund();
    }
}
