// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";

/// @notice Launch values (BUILD_PROMPT section 5, docs/ECONOMICS.md). Addresses and governance come from the
///         environment file; the economic values are fixed here so every environment deploys the same game.
abstract contract LaunchConfig is DeploySystem {
    /// @param unit The Shapes ladder unit (0.01 ETH on mainnet, 0.0001 ETH on the Sepolia ladder); every
    ///        backing below is a multiple of it.
    function _launchConfig(
        address governance,
        address shapes,
        address packs,
        address factory,
        address impl,
        address pm,
        uint256 unit
    ) internal pure returns (Config memory c) {
        c.governance = governance;
        c.shapes = shapes;
        c.packs = packs;
        c.fwaFactory = factory;
        c.fwaImplementation = impl;
        c.poolManager = pm;
        c.poolSalt = keccak256("draw-shapes.fwa-pool.v1");
        // Shapes-only launch board (docs/IMPLEMENTOR_DECISIONS.md D3, docs/ECONOMICS.md): 80 × 1, 15 × 5, 5 × 10 units
        // (0.01 / 0.05 / 0.1 ETH on mainnet).
        c.boardKinds = new uint8[](100);
        c.boardBackings = new uint96[](100);
        for (uint256 i; i < 100; ++i) {
            c.boardBackings[i] = uint96(i < 80 ? unit : i < 95 ? 5 * unit : 10 * unit);
        }
        c.listBatch = 20;
        c.markupBps = 300;
        c.conversionBonusBps = 200;
        c.grailLadder = new uint256[](3);
        c.grailLadder[0] = 50 * unit;
        c.grailLadder[1] = 100 * unit;
        c.grailLadder[2] = 500 * unit;
        c.grailStartBps = 9_500;
        c.grailFloorBps = 8_000;
        c.grailDecayBps = 100;
        c.grailDecayPulls = 100;
        c.hookFeeBps = 300;
        c.snipeStartBps = 5_000;
        c.snipeWindow = 60 minutes;
        c.reserveTarget = 75 * unit; // 0.75 ETH on mainnet; docs/ECONOMICS.md (adverse-sequence sim)
        c.maintenanceInterval = 30 minutes;
        c.buybackBps = 9_000;
        c.grailBps = 1_000;
        c.burnShareBps = 5_000;
        c.sliceWei = 5 * unit;
        c.minSpacing = 1 hours;
        c.maxImpactBps = 300;
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
