// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";
import {FwaGame} from "../src/game/FwaGame.sol";

/// @notice Launch values (BUILD_PROMPT section 5, docs/ECONOMICS.md). Addresses and governance come from the
///         environment file; the economic values are fixed here so every environment deploys the same game.
abstract contract LaunchConfig is DeploySystem {
    uint256 internal constant REWARD_VALUE_BPS = 1_000;

    /// @param unit The Shapes ladder unit (0.01 ETH on mainnet, 0.0001 ETH on the Sepolia ladder); every
    ///        backing below is a multiple of it.
    /// @param launchEth ETH governance will pair with the 80% float at `ProtocolLiquidity.launch`. It fixes the genesis
    ///        rate cap: at the launch price a steady epoch pays at most REWARD_VALUE_BPS (10%) of eligible ticket ETH
    ///        in ENGINE (docs/ECONOMICS.md section 7).
    function _launchConfig(
        address governance,
        address shapes,
        address packs,
        address factory,
        address impl,
        address pm,
        uint256 unit,
        uint256 launchEth
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
        c.listBatch = 20;
        c.markupBps = 500;
        c.opsBps = 300;
        c.conversionBonusBps = 200;
        c.hookFeeBps = 300;
        c.snipeStartBps = 5_000;
        c.snipeWindow = 60 minutes;
        c.capital = FwaGame.Capital({
            reserveTarget: 1_200 * unit, // 12 ETH on mainnet: docs/ECONOMICS.md section 5
            maintenanceInterval: 30 minutes,
            minLiveBps: 8_000,
            maxOutstanding: 20,
            maxEdgeBps: 500, // FWA's edge at launch; a higher edge closes purchases until governance accepts it
            maxCooldown: 5 minutes
        });
        c.marketLead = 48 hours;
        c.rateCap = REWARD_VALUE_BPS * LP_FLOAT / 10_000 * 1 ether / launchEth;
        c.sliceWei = 5 * unit;
        c.minSpacing = 1 hours;
        c.maxImpactBps = 300;
        c.maxDeviationBps = 200;
        c.keeper = KeeperFund.Params({
            premiumBps: 2_000,
            basefeeCap: 30 gwei,
            tipCap: 0.01 ether,
            maxBounty: 0.002 ether,
            rampSeconds: 6 hours,
            gasOverhead: 40_000,
            keeperTargetWei: 0.5 ether,
            maintenanceFloor: 0.05 ether
        });
        c.keeperSeed = 0; // set by the environment (KEEPER_SEED)
        c.shutdownDelay = 30 days;
        c.lpMaxImpactBps = 500;
    }
}
