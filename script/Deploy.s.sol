// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {LaunchConfig} from "./LaunchConfig.sol";

interface IFactoryPreflight {
    function implementation() external view returns (address);
    function poolCreationEnabled() external view returns (bool);
    function betaAccess() external view returns (bool);
    function poolCreationFee() external view returns (uint256);
    function fwaToken() external view returns (address);
    function globalWithdrawOnly() external view returns (bool);
}

/// @notice Deploys Draw Shapes + ENGINE. Run through `script/deploy.sh <env>`, which sources the values-only
///         `script/env/<env>.env`. Preflight refuses on any dependency mismatch; postflight reads back supply,
///         recipients, ownership (everything governed by the timelock, nothing left to the deploy wallet), the
///         FWA pool owner, the treasury table, the hook configuration and the gate end. Forge simulates the
///         whole script before broadcasting anything, so a failed check stops the run before the first
///         transaction is sent.
contract Deploy is Script, LaunchConfig {
    using stdJson for string;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        Config memory c = _launchConfig(
            vm.envAddress("GOVERNANCE"),
            vm.envAddress("SHAPES"),
            vm.envOr("SHAPE_PACKS", address(0)),
            vm.envAddress("FWA_FACTORY"),
            vm.envAddress("FWA_IMPLEMENTATION"),
            vm.envAddress("POOL_MANAGER"),
            IShapes(vm.envAddress("SHAPES")).unit()
        );
        c.create2Deployer = CREATE2_DEPLOYER;
        bool createPool = vm.envOr("CREATE_FWA_POOL", true);

        _preflight(c, deployer, createPool);
        if (createPool) c.fwaFeeEth = fwaFeeQuote(c.fwaFactory, c.poolManager, vm.envOr("FWA_FEE_MARGIN_BPS", uint256(500)));
        require(deployer.balance > c.fwaFeeEth, "deployer cannot pay the FWA fee purchase");

        vm.startBroadcast(deployer);
        System memory s = _deploySystem(c, deployer);
        vm.stopBroadcast();

        postflight(c, s, deployer);
        _record(c, s);
    }

    function _preflight(Config memory c, address deployer, bool createPool) internal view {
        _check(c.governance != address(0) && c.governance != deployer, "GOVERNANCE must be set and differ from DEPLOYER");
        _check(c.shapes.code.length != 0, "Shapes has no code");
        _check(c.fwaFactory.code.length != 0, "FWA factory has no code");
        _check(c.poolManager.code.length != 0, "PoolManager has no code");
        _check(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");
        _check(c.packs == address(0) || c.packs.code.length != 0, "Shape Packs has no code");
        IFactoryPreflight f = IFactoryPreflight(c.fwaFactory);
        _check(f.implementation() == c.fwaImplementation, "FWA implementation changed");
        _check(!f.globalWithdrawOnly(), "FWA factory is withdraw-only");
        if (createPool) {
            _check(f.poolCreationEnabled(), "FWA pool creation disabled");
            _check(!f.betaAccess(), "FWA beta access gate is on");
        }
    }

    function _record(Config memory c, System memory s) internal {
        string memory k = "deployment";
        k.serialize("chainId", block.chainid);
        k.serialize("blockNumber", block.number);
        k.serialize("gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        k.serialize("governance", c.governance);
        k.serialize("timelock", address(s.timelock));
        k.serialize("treasury", address(s.treasury));
        k.serialize("keeperFund", address(s.keeperFund));
        k.serialize("emissionSchedule", address(s.schedule));
        k.serialize("renderer", address(s.renderer));
        k.serialize("farm", address(s.farm));
        k.serialize("liquidity", address(s.liquidity));
        k.serialize("engine", address(s.engine));
        k.serialize("swapPolicy", address(s.swapPolicy));
        k.serialize("hook", address(s.hook));
        k.serialize("buyer", address(s.buyer));
        k.serialize("boardPolicy", address(s.board));
        k.serialize("pricingPolicy", address(s.pricing));
        k.serialize("grailPolicy", address(s.grail));
        k.serialize("vault", address(s.vault));
        k.serialize("game", address(s.game));
        k.serialize("fwaPool", address(s.game.pool()));
        k.serialize("buybackBurn", address(s.buybackBurn));
        k.serialize("buybackReward", address(s.buybackReward));
        k.serialize("grailFund", address(s.grailFund));
        k.serialize("feeBuyer", address(s.feeBuyer));
        k.serialize("shapes", c.shapes);
        k.serialize("shapePacks", c.packs);
        k.serialize("poolManager", c.poolManager);
        string memory out = k.serialize("lens", address(s.lens));
        vm.writeJson(out, vm.envOr("DEPLOYMENT_RECORD", string.concat("deployments/", vm.toString(block.chainid), ".json")));
    }
}
