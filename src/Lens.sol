// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IFWAPool} from "./interfaces/IFWA.sol";
import {FwaGame} from "./game/FwaGame.sol";
import {GenesisFarm} from "./token/GenesisFarm.sol";
import {Treasury} from "./treasury/Treasury.sol";
import {KeeperFund} from "./treasury/KeeperFund.sol";
import {BuybackSink, GrailFund} from "./treasury/Sinks.sol";
import {SwapPolicy} from "./policy/SwapPolicy.sol";
import {ProtocolLiquidity} from "./token/ProtocolLiquidity.sol";

/// @title Lens
/// @notice Read-only aggregation for the site and the keeper. Holds nothing and changes nothing.
contract Lens {
    using StateLibrary for IPoolManager;

    struct Addresses {
        FwaGame game;
        GenesisFarm farm;
        Treasury treasury;
        KeeperFund keeperFund;
        BuybackSink buybackBurn;
        BuybackSink buybackReward;
        GrailFund grailFund;
        SwapPolicy swapPolicy;
        ProtocolLiquidity liquidity;
    }

    struct GameView {
        address pool;
        bool acquisitionsEnabled;
        bool retiring;
        bool retired;
        uint256 liveListings;
        uint256 boardRows;
        uint256 liveRows;
        uint256 bankroll;
        uint256 nav;
        uint256 inventoryBacking;
        uint256 grailReserve;
        uint256 grailListing;
        uint256 pullsBooked;
        uint256 nextSeq;
        uint256 lastIssuedSeq;
        uint256 quoteFee;
        uint256 quoteVrf;
        uint256 inventoryVersion;
        uint256 purchasesResumeAt;
    }

    struct EpochView {
        uint256 epoch;
        uint256 pot;
        uint256 units;
        uint256 userUnits;
        uint256 reward;
        bool isFinal;
        bool claimed;
    }

    struct WorkView {
        uint256 syncable; // terminal pulls waiting to be booked (up to 50 counted)
        uint256 unlistedRows;
        uint256 syncAge;
        uint256 unallocated;
        uint256 distributeAge;
        bool burnReady;
        bool rewardReady;
        uint256 grailOwed;
        bool retireUnearnedReady;
        uint256 keeperFundAvailable;
    }

    struct MarketView {
        bool gated;
        uint256 genesisEndBlock;
        uint256 currentEpoch;
        uint256 feeBps;
        uint256 snipeFeeBps;
        uint160 sqrtPriceX96;
        uint256 enginePerEth; // 18 decimals, spot
    }

    function game(Addresses calldata a) public view returns (GameView memory v) {
        FwaGame g = a.game;
        IFWAPool p = g.pool();
        v.pool = address(p);
        v.retiring = g.retiring();
        v.retired = g.retired();
        v.liveListings = g.liveCount();
        v.boardRows = g.board().rowCount();
        v.liveRows = _popcount(g.liveRows());
        v.bankroll = g.bankroll();
        v.nav = g.nav();
        v.inventoryBacking = g.inventoryBacking();
        v.grailReserve = g.grailReserve();
        v.grailListing = g.grailListing();
        v.pullsBooked = g.pullsBooked();
        v.nextSeq = g.nextSeq();
        if (address(p) != address(0)) {
            v.acquisitionsEnabled = p.localPurchasesEnabled();
            v.lastIssuedSeq = p.lastIssuedSequence();
            if (p.totalWeight() != 0) (v.quoteFee, v.quoteVrf,) = p.quoteAcquisitionPrice(1);
            v.inventoryVersion = p.inventoryVersion();
            v.purchasesResumeAt = p.purchasesResumeAt();
        }
    }

    /// @notice Epoch state for `user` over `[from, to)`.
    function epochs(GenesisFarm farm, address user, uint256 from, uint256 to)
        external
        view
        returns (EpochView[] memory out)
    {
        out = new EpochView[](to - from);
        for (uint256 e = from; e < to; ++e) {
            EpochView memory v = out[e - from];
            v.epoch = e;
            v.pot = farm.potOf(e);
            v.units = farm.epochUnits(e);
            v.userUnits = farm.userUnits(e, user);
            v.reward = farm.rewardOf(e, user);
            v.isFinal = farm.isFinal(e);
            v.claimed = farm.claimed(e, user);
        }
    }

    /// @notice Unclaimed final rewards of `user` over `[from, to)` and the epochs to pass to `claim`.
    function claimable(GenesisFarm farm, address user, uint256 from, uint256 to)
        external
        view
        returns (uint256 total, uint256[] memory epochList)
    {
        uint256[] memory tmp = new uint256[](to - from);
        uint256 n;
        for (uint256 e = from; e < to; ++e) {
            if (farm.claimed(e, user) || !farm.isFinal(e)) continue;
            uint256 r = farm.rewardOf(e, user);
            if (r == 0) continue;
            total += r;
            tmp[n++] = e;
        }
        epochList = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            epochList[i] = tmp[i];
        }
    }

    function market(Addresses calldata a) public view returns (MarketView memory v) {
        v.gated = a.swapPolicy.gated();
        v.genesisEndBlock = a.farm.genesisEndBlock();
        v.currentEpoch = a.farm.currentEpoch();
        v.feeBps = a.swapPolicy.feeBps();
        v.snipeFeeBps = a.swapPolicy.snipeFeeBps();
        if (a.liquidity.launched()) {
            v.sqrtPriceX96 = a.liquidity.sqrtPriceX96();
            v.enginePerEth = FPM.fullMulDiv(uint256(v.sqrtPriceX96) * uint256(v.sqrtPriceX96), 1e18, 1 << 192);
        }
    }

    /// @notice Spot estimate of a conversion of a Shape of `backing`: ENGINE out (before price impact)
    ///         and the bonus at the current bonus rate.
    function conversionQuote(Addresses calldata a, uint256 backing)
        external
        view
        returns (uint256 engineOut, uint256 bonus, bool bonusCovered)
    {
        MarketView memory m = market(a);
        engineOut = backing * m.enginePerEth / 1e18;
        bonus = engineOut * a.game.pricing().conversionBonusBps() / 10_000;
        bonusCovered = a.farm.bonusPool() >= bonus;
    }

    /// @notice Treasury table and allocations.
    function treasuryTable(Treasury t)
        external
        view
        returns (address[] memory sinks, uint16[] memory bps, uint256[] memory owed, uint256 unallocated)
    {
        uint256 n = t.sinkCount();
        sinks = new address[](n);
        bps = new uint16[](n);
        owed = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (sinks[i], bps[i]) = t.sinkAt(i);
            owed[i] = t.owed(sinks[i]);
        }
        unallocated = t.unallocated();
    }

    /// @notice Keeper work available now, with ages in seconds.
    function work(Addresses calldata a) external view returns (WorkView memory w) {
        FwaGame g = a.game;
        IFWAPool p = g.pool();
        if (address(p) != address(0)) {
            uint64 last = p.lastIssuedSequence();
            for (uint64 s = g.nextSeq(); s <= last && w.syncable < 50; ++s) {
                (,,,, IFWAPool.AcquisitionStatus st) = p.acquisitions(p.requestIdAtSequence(s));
                if (st == IFWAPool.AcquisitionStatus.Pending || st == IFWAPool.AcquisitionStatus.DeliveryPending) break;
                ++w.syncable; // Ready counts: sync settles it first
            }
        }
        uint256 rows = g.board().rowCount();
        w.unlistedRows = rows - _popcount(g.liveRows() & ((rows >= 256 ? 0 : (uint256(1) << rows)) - 1));
        w.syncAge = block.timestamp - g.lastSyncAt();
        w.unallocated = a.treasury.unallocated();
        w.distributeAge = block.timestamp - a.treasury.lastDistributeAt();
        w.burnReady = _sinkReady(a.treasury, a.buybackBurn);
        w.rewardReady = _sinkReady(a.treasury, a.buybackReward);
        w.grailOwed = a.treasury.owed(address(a.grailFund));
        GenesisFarm f = a.farm;
        w.retireUnearnedReady = !f.unearnedRetired() && f.openBlock() != 0 && block.number >= f.genesisEndBlock();
        w.keeperFundAvailable = a.keeperFund.available();
    }

    function _sinkReady(Treasury t, BuybackSink s) internal view returns (bool) {
        return t.owed(address(s)) != 0 && block.timestamp >= s.lastRunAt() + s.minSpacing();
    }

    function _popcount(uint256 x) internal pure returns (uint256 c) {
        while (x != 0) {
            x &= x - 1;
            ++c;
        }
    }
}
