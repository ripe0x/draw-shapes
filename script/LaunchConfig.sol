// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";
import {FwaGame} from "../src/game/FwaGame.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

/// @notice Launch values (BUILD_PROMPT section 5, docs/ECONOMICS.md). Addresses and governance come from the
///         environment file; the economic values are fixed here so every environment deploys the same game.
abstract contract LaunchConfig is DeploySystem {
    uint256 internal constant REWARD_VALUE_BPS = 1_000;

    /// @param unit The Shapes ladder unit (0.01 ETH on mainnet, 0.0001 ETH on the Sepolia ladder); every
    ///        backing below is a multiple of it.
    /// @param startTick The single-sided launch price: ENGINE per ETH = 1.0001^startTick, the highest the price can ever
    ///        be (D50). It fixes the genesis rate cap: valued at the start price a steady epoch pays at most
    ///        REWARD_VALUE_BPS (10%) of eligible ticket ETH in ENGINE (docs/ECONOMICS.md section 7). As ENGINE rises the same
    ///        ENGINE is worth more ETH; the epoch pots, not the cap, bound the total.
    function _launchConfig(
        address governance,
        address shapes,
        address packs,
        address factory,
        address impl,
        address pm,
        uint256 unit,
        int24 startTick
    ) internal pure returns (Config memory c) {
        c.governance = governance;
        c.shapes = shapes;
        c.packs = packs;
        c.fwaFactory = factory;
        c.fwaImplementation = impl;
        c.poolManager = pm;
        c.poolSalt = keccak256("draw-shapes.fwa-pool.v1");
        // Shapes-only board, 100 rows: 30 × 1, 45 × 5, 25 × 50 units (0.01 / 0.05 / 0.5 ETH on mainnet), the
        // 100-item form of the 6 / 9 / 5 mix (docs/IMPLEMENTOR_DECISIONS.md D35, docs/ECONOMICS.md section 2).
        c.boardKinds = new uint8[](100);
        c.boardBackings = new uint96[](100);
        for (uint256 i; i < 100; ++i) {
            c.boardBackings[i] = uint96(i < 30 ? unit : i < 75 ? 5 * unit : 50 * unit);
        }
        c.listBatch = 3; // restock trigger: list once 3 rows are missing (D47)
        c.markupBps = 500;
        c.opsBps = 300;
        c.conversionBonusBps = 200;
        c.hookFeeBps = 300;
        c.snipeStartBps = 5_000;
        c.snipeWindow = 60 minutes;
        c.capital = FwaGame.Capital({
            reserveTarget: 1_200 * unit, // 12 ETH on mainnet: docs/ECONOMICS.md section 5
            maintenanceInterval: 5 minutes, // and at least six FWA cooldowns apart (D47)
            minLiveBps: 8_000,
            maxInFlight: 10, // the purchase gate assumes a full batch of 5 on top (D45)
            maxEdgeBps: 500, // FWA's edge at launch; a higher edge closes purchases until governance accepts it
            maxCooldown: 5 minutes
        });
        c.marketLead = 48 hours;
        c.startTick = startTick;
        c.rateCap = rateCapAt(startTick);
        c.sliceWei = 5 * unit;
        c.minSpacing = 1 hours;
        c.maxImpactBps = 300;
        c.maxDeviationBps = 200;
        // keepers (D48): measured gas at the gas price paid (capped per gas and per tip) plus a flat fee at most once
        // an hour per job; seed 0.05 ETH, topped up from trading fees within a 1 ETH lifetime limit
        c.keeper = KeeperFund.Params({
            tipCap: 0.05 ether, // enough to list 20 prizes in one call at up to ~5 gwei
            maxGasPrice: 5 gwei,
            gasOverhead: 70_000,
            flatFee: 0.0003 ether,
            feeInterval: 1 hours,
            keeperTargetWei: 0.5 ether,
            maintenanceFloor: 0.05 ether
        });
        c.keeperSeed = 0.05 ether; // overridden by the environment (KEEPER_SEED)
        c.keeperTopUpTarget = 0.1 ether;
        c.shutdownDelay = 30 days;
        c.lpMaxImpactBps = 500;
    }

    /// @notice The genesis rate cap for a start tick: REWARD_VALUE_BPS of 1 ETH, in ENGINE at the start price.
    function rateCapAt(int24 startTick) public pure returns (uint256) {
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(startTick);
        uint256 priceX128 = FPM.fullMulDiv(sqrtP, sqrtP, 1 << 64); // ENGINE per ETH × 2^128
        return FPM.fullMulDiv(priceX128, REWARD_VALUE_BPS * 1 ether / 10_000, 1 << 128);
    }
}
