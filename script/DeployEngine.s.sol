// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {ShapePacks} from "draw-packs/ShapePacks.sol";
import {ShapePackRenderer} from "draw-packs/ShapePackRenderer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPool, IPoolTypes} from "../src/interfaces/IPool.sol";
import {IFWACloneFactory} from "../src/interfaces/IFWACloneFactory.sol";
import {IArtCoinsFactoryV2, IArtCoinsHookV2, IArtCoinsTokenV2} from "../src/interfaces/IArtcoins.sol";
import {EngineTreasury} from "../src/engine/EngineTreasury.sol";
import {FoundingRound} from "../src/engine/FoundingRound.sol";
import {PrizeSponsorship} from "../src/engine/PrizeSponsorship.sol";
import {EngineDeployer} from "./EngineDeployer.sol";

/// @notice Step-by-step engine launch. Each step is one `forge script` run, simulated without
///         `--broadcast` (the dry run) and broadcast with it, from the signer the step names. Every
///         step reads its preconditions first and its results back after, and reverts on any
///         mismatch. `script/engine.sh <env> <step>` runs a step with the env file's values.
/// @dev Steps, in order (docs/DEPLOY.md):
///      deploy    DEPLOYER   Draw Packs (when DRAW_PACKS is unset), PoolAdmin, PoolListing, Pool, Lens,
///                           EngineTreasury; pool admin handed to the treasury. Writes the record.
///      round     OWNER      Opens the FoundingRound and names it on the treasury.
///      coin      ARTCOINS   The Artcoins factory owner launches ENGINE with `_coinConfig`.
///      lock      TOKEN_ADMIN Locks the coin's fee recipients.
///      bind      OWNER      Binds the coin on the treasury (checks recipient, fee terms, lock).
///      activate  OWNER      Takes the funded escrow, creates the FWA pool (the pool must already hold
///                           the FWA creation fee in FWA tokens) and seeds the game.
///      open      anyone     Opens the board after the opening deadline and fills it.
///      sponsor   OWNER      Deploys a PrizeSponsorship with SPONSOR_* terms and attaches it.
///      status    anyone     Prints every readback, changes nothing.
contract DeployEngine is Script, EngineDeployer {
    using PoolIdLibrary for PoolKey;

    error Guard(string reason);

    function run(string calldata step) external {
        bytes32 s = keccak256(bytes(step));
        if (s == keccak256("deploy")) _deployStep();
        else if (s == keccak256("round")) _roundStep();
        else if (s == keccak256("coin")) _coinStep();
        else if (s == keccak256("lock")) _lockStep();
        else if (s == keccak256("bind")) _bindStep();
        else if (s == keccak256("activate")) _activateStep();
        else if (s == keccak256("open")) _openStep();
        else if (s == keccak256("sponsor")) _sponsorStep();
        else if (s == keccak256("status")) _status();
        else revert Guard("unknown step");
    }

    // ------------------------------------------------------------------ steps

    function _deployStep() internal {
        _guardChain();
        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envAddress("OWNER");
        uint256 target = vm.envUint("ROUND_TARGET_WEI");
        address drawPacks = vm.envOr("DRAW_PACKS", address(0));
        vm.startBroadcast(deployer);
        if (drawPacks == address(0)) {
            ShapePackRenderer renderer = new ShapePackRenderer(SHAPES);
            drawPacks = address(new ShapePacks(SHAPES, address(renderer), owner, "Draw Packs", "DRAW", 2));
        }
        Deployment memory d = _deployEngine(drawPacks, deployer, owner, target);
        vm.stopBroadcast();
        _postflightDeploy(d, drawPacks, owner, target);
        _writeRecord(d, drawPacks);
    }

    function _roundStep() internal {
        EngineTreasury t = _treasury();
        address owner = vm.envAddress("OWNER");
        uint256 target = vm.envUint("ROUND_TARGET_WEI");
        if (t.owner() != owner) revert Guard("OWNER is not the treasury owner");
        vm.startBroadcast(owner);
        FoundingRound r = _openRound(owner, t, target);
        t.setFoundingRound(r);
        vm.stopBroadcast();
        if (address(t.round()) != address(r) || r.target() != target || r.capBps() != ROUND_CAP_BPS) {
            revert Guard("round readback");
        }
        console2.log("FOUNDING_ROUND", address(r));
        _record("round", address(r));
        console2.log("contributions close at", r.deadline());
        console2.log("launch deadline", r.launchDeadline());
    }

    function _coinStep() internal {
        EngineTreasury t = _treasury();
        IArtCoinsFactoryV2 f = IArtCoinsFactoryV2(ARTCOINS_FACTORY);
        address artOwner = f.owner();
        if (vm.envAddress("ARTCOINS_SIGNER") != artOwner) revert Guard("ARTCOINS_SIGNER is not the factory owner");
        if (!f.enabledHooks(ARTCOINS_HOOK) || !f.enabledLockers(ARTCOINS_LOCKER) || !f.enabledMevModules(ARTCOINS_MEV))
        {
            revert Guard("Artcoins hook, locker or MEV module not enabled");
        }
        if (f.minProtocolSkimShareBps() > 10_000 - COIN_BOUNTY_BPS) revert Guard("bounty share above factory limit");
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c = _coinConfig(
            address(t),
            vm.envAddress("TOKEN_ADMIN"),
            vm.envString("COIN_NAME"),
            vm.envString("COIN_SYMBOL"),
            vm.envBytes32("COIN_SALT")
        );
        uint256 fee = f.deployFee();
        vm.startBroadcast(artOwner);
        address coin = f.deployTokenAsOwner{value: fee}(c, COIN_PROTOCOL_LOCKER_BPS);
        vm.stopBroadcast();
        IArtCoinsHookV2.SkimConfig memory sc =
            IArtCoinsHookV2(ARTCOINS_HOOK).skimConfig(IArtCoinsFactoryV2(ARTCOINS_FACTORY).deploymentInfo(coin).poolId);
        if (
            sc.bountyRecipient != address(t) || sc.baselineSkimBps != COIN_SKIM_BPS || sc.bountyBps != COIN_BOUNTY_BPS
                || sc.lpFeePips != COIN_LP_FEE_PIPS || sc.maxReferralBpsOfVolume != 0
        ) revert Guard("coin fee readback");
        console2.log("COIN", coin);
        _record("coin", coin);
    }

    function _lockStep() internal {
        address coin = vm.envAddress("COIN");
        vm.startBroadcast(vm.envAddress("TOKEN_ADMIN"));
        (bool ok,) = coin.call(abi.encodeWithSignature("lockRecipients()"));
        vm.stopBroadcast();
        if (!ok || !IArtCoinsTokenV2(coin).recipientsLocked()) revert Guard("lockRecipients");
    }

    function _bindStep() internal {
        EngineTreasury t = _treasury();
        address coin = vm.envAddress("COIN");
        vm.startBroadcast(vm.envAddress("OWNER"));
        t.setCoin(coin);
        vm.stopBroadcast();
        if (address(t.coin()) != coin) revert Guard("coin readback");
        console2.log("pool id");
        console2.logBytes32(bytes32(uint256(keccak256(abi.encode(t.poolKey())))));
    }

    function _activateStep() internal {
        EngineTreasury t = _treasury();
        uint8 check = t.activationCheck();
        if (check != 0) {
            console2.log("activationCheck", check);
            revert Guard("not ready");
        }
        IPool pool = t.pool();
        uint256 fee = IFWACloneFactory(FWA_FACTORY).poolCreationFee();
        if (IERC20(FWA_TOKEN).balanceOf(address(pool)) < fee) revert Guard("pool lacks the FWA creation fee");
        vm.startBroadcast(vm.envAddress("OWNER"));
        t.activate(fee);
        vm.stopBroadcast();
        _record("fwaPool", address(pool.fwaPool()));
        console2.log("FWA_POOL", address(pool.fwaPool()));
        console2.log("opening deadline at", pool.openingDeadlineAt());
        if (!t.activated() || pool.totalShares() != pool.sharesOf(address(t)) || !pool.depositsPaused()) {
            revert Guard("activation readback");
        }
        if (pool.navCapFloor() != 0 || pool.boardNavCap() != t.poolTarget()) revert Guard("admission readback");
    }

    function _openStep() internal {
        IPool pool = _treasury().pool();
        vm.startBroadcast();
        for (uint256 i; i < 20 && pool.lifecycle() == IPoolTypes.Lifecycle.Opening; ++i) pool.open();
        for (uint256 i; i < 20 && pool.settleDue() != IPoolTypes.SettleTrigger.None; ++i) pool.settle(20);
        vm.stopBroadcast();
        console2.log("listed", pool.listedCount());
    }

    function _sponsorStep() internal {
        EngineTreasury t = _treasury();
        vm.startBroadcast(vm.envAddress("OWNER"));
        PrizeSponsorship s = new PrizeSponsorship(
            address(t.pool()),
            address(t),
            vm.envAddress("SPONSOR"),
            vm.envOr("SPONSOR_COLLECTION", WRAPPED_PUNKS),
            vm.envUint("SPONSOR_LIST_PRICE_WEI"),
            vm.envUint("SPONSOR_CAP_WEI"),
            vm.envUint("SPONSOR_RECLAIM_DELAY")
        );
        t.setSponsorship(s, uint16(vm.envUint("SPONSOR_SHARE_BPS")));
        vm.stopBroadcast();
        if (address(t.sponsorship()) != address(s) || t.pool().registrar() != address(s)) revert Guard("sponsor readback");
        console2.log("SPONSORSHIP", address(s));
        _record("sponsorship", address(s));
    }

    // ------------------------------------------------------------------ checks

    function _guardChain() internal view {
        if (block.chainid != 1 && block.chainid != 31337) revert Guard("mainnet or a local mainnet fork only");
        if (SHAPES.code.length == 0 || FWA_FACTORY.code.length == 0 || ARTCOINS_FACTORY.code.length == 0) {
            revert Guard("dependency missing: run against mainnet or a mainnet fork");
        }
        if (IShapes(SHAPES).unit() != 0.0001 ether * 100) revert Guard("ladder unit differs from Shapes");
    }

    function _postflightDeploy(Deployment memory d, address drawPacks, address owner, uint256 target) internal view {
        IPool p = IPool(address(d.pool));
        EngineTreasury t = d.treasury;
        if (p.admin() != address(t)) revert Guard("pool admin is not the treasury");
        if (p.adminModule() != address(d.adminModule) || p.listingModule() != address(d.listingModule)) {
            revert Guard("modules");
        }
        if (p.shapes() != SHAPES || p.drawPacks() != drawPacks || p.fwaFactory() != FWA_FACTORY) revert Guard("deps");
        if (p.lifecycle() != IPoolTypes.Lifecycle.Opening || p.totalShares() != 0) revert Guard("lifecycle");
        if (p.navCapFloor() != 0 || p.founderWindowSeconds() != 0) revert Guard("admission");
        (uint32 floorBps, uint32 capBps,) = p.entryFee();
        if (floorBps != 0 || capBps != 0) revert Guard("entry fee");
        if (address(d.lens.pool()) != address(p)) revert Guard("lens");
        if (ShapePacks(payable(drawPacks)).MIN_PACK_VALUE() != 2 * IShapes(SHAPES).unit()) revert Guard("draw packs");
        EngineTreasury.Config memory c = _treasuryConfig(owner, target);
        if (
            t.owner() != owner || address(t.pool()) != address(p) || t.poolTarget() != c.poolTarget
                || t.grailSeed() != c.grailSeed || t.reserveTarget() != c.reserveTarget
                || t.founderTradingBps() != c.founderTradingBps || t.founderEarningsBps() != c.founderEarningsBps
                || t.coinSkimBps() != COIN_SKIM_BPS || t.coinBountyBps() != COIN_BOUNTY_BPS
                || t.artcoinsHook() != ARTCOINS_HOOK || t.artcoinsLocker() != ARTCOINS_LOCKER
                || address(t.poolManager()) != POOL_MANAGER
        ) revert Guard("treasury readback");
    }

    function _status() internal view {
        EngineTreasury t = _treasury();
        IPool p = t.pool();
        console2.log("treasury", address(t));
        console2.log("pool", address(p));
        console2.log("activated", t.activated());
        console2.log("activationCheck", t.activationCheck());
        console2.log("round", address(t.round()));
        console2.log("coin", address(t.coin()));
        console2.log("fwa pool", address(p.fwaPool()));
        console2.log("lifecycle", uint8(p.lifecycle()));
        console2.log("nav / basis", p.nav(), t.basis());
        console2.log("reserve / prizeBudget / buybackFund", t.reserve(), t.prizeBudget(), t.buybackFund());
        console2.log("maintenance / GRAIL fund", p.maintenance(), p.grail().fund);
        if (address(t.round()) != address(0)) {
            FoundingRound r = t.round();
            console2.log("round state / contributed", uint8(r.state()), r.totalContributed());
            console2.log("founders distributed / entitlement", r.totalDistributed(), r.entitlement());
        }
    }

    /// @dev Sets `key` of the deployment record to `value` when `DEPLOYMENT_RECORD` names one. Skipped in
    ///      a dry run, which `script/engine.sh` marks with `DRY_RUN=1`.
    function _record(string memory key, address value) internal {
        string memory path = vm.envOr("DEPLOYMENT_RECORD", string(""));
        if (bytes(path).length == 0 || vm.envOr("DRY_RUN", uint256(0)) == 1) return;
        vm.writeJson(string.concat("\"", vm.toString(value), "\""), path, string.concat(".", key));
    }

    function _treasury() internal view returns (EngineTreasury) {
        return EngineTreasury(payable(vm.envAddress("TREASURY")));
    }

    function _writeRecord(Deployment memory d, address drawPacks) internal {
        string memory path = vm.envOr("DEPLOYMENT_RECORD", string(""));
        if (bytes(path).length == 0 || vm.envOr("DRY_RUN", uint256(0)) == 1) return;
        string memory k = "engine";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "pool", address(d.pool));
        vm.serializeAddress(k, "adminModule", address(d.adminModule));
        vm.serializeAddress(k, "listingModule", address(d.listingModule));
        vm.serializeAddress(k, "lens", address(d.lens));
        vm.serializeAddress(k, "treasury", address(d.treasury));
        vm.serializeAddress(k, "drawPacks", drawPacks);
        vm.serializeAddress(k, "shapes", SHAPES);
        vm.serializeAddress(k, "poolManager", POOL_MANAGER);
        vm.serializeAddress(k, "round", address(0));
        vm.serializeAddress(k, "coin", address(0));
        vm.serializeAddress(k, "fwaPool", address(0));
        vm.serializeAddress(k, "sponsorship", address(0));
        vm.serializeString(k, "gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        string memory json = vm.serializeUint(k, "blockNumber", block.number);
        vm.writeJson(json, path);
    }
}
