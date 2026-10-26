// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";

/// @notice Launch values (BUILD_PROMPT section 5, docs/ECONOMICS.md). Addresses and governance come from the
///         environment file; the economic values are fixed here so every environment deploys the same game.
abstract contract LaunchConfig is DeploySystem {
    function _launchConfig(address governance, address shapes, address packs, address factory, address impl, address pm)
        internal
        pure
        returns (Config memory c)
    {
        c.governance = governance;
        c.shapes = shapes;
        c.packs = packs;
        c.fwaFactory = factory;
        c.fwaImplementation = impl;
        c.poolManager = pm;
        c.poolSalt = keccak256("draw-shapes.fwa-pool.v1");
        // Shapes-only launch board (docs/IMPLEMENTOR_DECISIONS.md D3, docs/ECONOMICS.md): 80 × 0.01, 15 × 0.05, 5 × 0.1.
        c.boardKinds = new uint8[](100);
        c.boardBackings = new uint96[](100);
        for (uint256 i; i < 100; ++i) {
            c.boardBackings[i] = i < 80 ? 0.01 ether : i < 95 ? 0.05 ether : 0.1 ether;
        }
        c.listBatch = 20;
        c.markupBps = 300;
        c.conversionBonusBps = 200;
        c.grailLadder = new uint256[](3);
        c.grailLadder[0] = 0.5 ether;
        c.grailLadder[1] = 1 ether;
        c.grailLadder[2] = 5 ether;
        c.grailStartBps = 9_500;
        c.grailFloorBps = 8_000;
        c.grailDecayBps = 100;
        c.grailDecayPulls = 100;
        c.hookFeeBps = 300;
        c.snipeStartBps = 5_000;
        c.snipeWindow = 60 minutes;
        c.burnBps = 4_500;
        c.rewardBps = 4_500;
        c.grailBps = 1_000;
        c.sliceWei = 0.05 ether;
        c.minSpacing = 1 hours;
        c.maxImpactBps = 300;
        c.keeper = KeeperFund.Params({
            premiumBps: 2_000,
            basefeeCap: 30 gwei,
            tipCap: 0.01 ether,
            maxBounty: 0.002 ether,
            rampSeconds: 6 hours,
            gasOverhead: 40_000,
            keeperTargetWei: 0.5 ether
        });
        c.shutdownDelay = 30 days;
        c.lpMaxImpactBps = 500;
    }
}
