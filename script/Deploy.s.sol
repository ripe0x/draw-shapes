// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {ShapePacks} from "draw-packs/ShapePacks.sol";
import {ShapePackRenderer} from "draw-packs/ShapePackRenderer.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAdmin} from "../src/PoolAdmin.sol";
import {Lens} from "../src/Lens.sol";
import {PricingLib} from "../src/lib/PricingLib.sol";
import {IPool, IPoolTypes} from "../src/interfaces/IPool.sol";

/// @notice Deploys `PoolAdmin`, `Pool` and `Lens` and checks their constructor state in the same run.
///         Writes the deployment record to `DEPLOYMENT_RECORD`.
/// @dev One script for every chain. `block.chainid` selects the guards: 1 pins the dependency
///      addresses and the launch parameters, 11155111 pins the dependency addresses, 31337 accepts
///      any addresses and deploys Draw Packs when `DRAW_PACKS` is unset. Other chains revert.
///      Every input comes from the environment, exported by `script/deploy.sh` from
///      `script/env/<env>.env`. The FWA pool is created afterwards by `Pool.createFwaPool`.
contract Deploy is Script {
    error UnsupportedChain(uint256 chainId);
    error GuardFailed(string reason);
    error DrawPacksMissing();

    address internal constant MAINNET_SHAPES = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant MAINNET_FWA_FACTORY = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant SEPOLIA_SHAPES = 0x6C2F9c00F44FBBF141dD166979903004b80D5f99;
    address internal constant SEPOLIA_FWA_FACTORY = 0xdF0b2Cf3dCc47B79b42e310c06C98df93f894358;

    uint256 internal constant MAINNET = 1;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant LOCAL = 31337;

    uint256 internal constant MINOR = 0;
    uint256 internal constant MAJOR = 1;

    /// @notice Deploys the pool, verifies it and writes the record.
    function run() external returns (Pool pool, PoolAdmin module, Lens lens) {
        IPoolTypes.Params memory p = _params();
        _guardChain(p);
        _guardDrawPacks(p);

        vm.startBroadcast();
        if (p.drawPacks == address(0)) {
            ShapePackRenderer renderer = new ShapePackRenderer(p.shapes);
            p.drawPacks = address(new ShapePacks(p.shapes, address(renderer), p.admin, "Draw Packs", "DRAW", 2));
        }
        module = new PoolAdmin();
        pool = new Pool(p, address(module));
        lens = new Lens(pool);
        vm.stopBroadcast();

        _postflight(pool, module, lens, p);
        _writeRecord(pool, module, lens, p);
    }

    // ------------------------------------------------------------------ inputs

    function _params() internal view returns (IPoolTypes.Params memory p) {
        p.shapes = vm.envAddress("SHAPES");
        p.drawPacks = vm.envOr("DRAW_PACKS", address(0));
        p.fwaFactory = vm.envAddress("FWA_FACTORY");
        p.admin = vm.envAddress("ADMIN");
        p.oldPool = vm.envOr("OLD_POOL", address(0));
        p.mix = _parseMix(vm.envString("MIX_ROWS"));
        p.feeSplit = IPoolTypes.FeeSplit({
            premiumBps: SafeCastLib.toUint16(vm.envUint("PREMIUM_BPS")),
            maintenanceBps: SafeCastLib.toUint16(vm.envUint("MAINTENANCE_BPS")),
            feedBps: SafeCastLib.toUint16(vm.envUint("FEED_BPS")),
            minorShareBps: SafeCastLib.toUint16(vm.envUint("MINOR_SHARE_BPS"))
        });
        p.minor = IPoolTypes.GrailParams({
            targetWei: vm.envUint("GRAIL_MINOR_TARGET_WEI"),
            stepWei: vm.envUint("GRAIL_MINOR_STEP_WEI"),
            listBps: vm.envUint("GRAIL_MINOR_LIST_BPS"),
            decayWeiPerPull: vm.envUint("GRAIL_MINOR_DECAY_WEI_PER_PULL"),
            floorWei: vm.envUint("GRAIL_MINOR_FLOOR_WEI")
        });
        p.major = IPoolTypes.GrailParams({
            targetWei: vm.envUint("GRAIL_MAJOR_TARGET_WEI"),
            stepWei: vm.envUint("GRAIL_MAJOR_STEP_WEI"),
            listBps: vm.envUint("GRAIL_MAJOR_LIST_BPS"),
            decayWeiPerPull: vm.envUint("GRAIL_MAJOR_DECAY_WEI_PER_PULL"),
            floorWei: vm.envUint("GRAIL_MAJOR_FLOOR_WEI")
        });
        uint256 navCap = vm.envUint("NAV_CAP_WEI");
        p.navCap = navCap == 0 ? type(uint256).max : navCap;
        p.curve = IPoolTypes.EntryCurve({
            baseBps: SafeCastLib.toUint32(vm.envUint("ENTRY_BASE_BPS")),
            slopeBps: SafeCastLib.toUint32(vm.envUint("ENTRY_SLOPE_BPS")),
            capBps: SafeCastLib.toUint32(vm.envUint("ENTRY_CAP_BPS")),
            referenceWei: SafeCastLib.toUint128(vm.envUint("ENTRY_REFERENCE_WEI"))
        });
        p.rotateInterval = vm.envUint("ROTATE_INTERVAL_SECONDS");
        p.openingDeadline = vm.envUint("OPENING_DEADLINE_SECONDS");
        p.minItems = vm.envUint("MIN_ITEMS");
        p.grailProbCapBps = vm.envUint("GRAIL_PROB_CAP_BPS");
        p.repriceMinBps = vm.envUint("REPRICE_MIN_BPS");
        p.restockTriggerBps = vm.envUint("RESTOCK_TRIGGER_BPS");
        p.quietIntervalSeconds = vm.envUint("QUIET_INTERVAL_SECONDS");
    }

    /// @dev Rows are separated by `;`, each row is `rung,rung,...:shareBps`.
    function _parseMix(string memory spec) internal pure returns (PricingLib.MixRow[] memory rows) {
        string[] memory parts = vm.split(spec, ";");
        rows = new PricingLib.MixRow[](parts.length);
        for (uint256 i; i < parts.length; ++i) {
            string[] memory halves = vm.split(parts[i], ":");
            if (halves.length != 2) revert GuardFailed("MIX_ROWS row is not rungs:shareBps");
            string[] memory rungs = vm.split(halves[0], ",");
            rows[i].rungs = new uint8[](rungs.length);
            for (uint256 j; j < rungs.length; ++j) {
                rows[i].rungs[j] = SafeCastLib.toUint8(vm.parseUint(rungs[j]));
            }
            rows[i].shareBps = SafeCastLib.toUint16(vm.parseUint(halves[1]));
        }
    }

    // ------------------------------------------------------------------ guards

    function _guardChain(IPoolTypes.Params memory p) internal view {
        if (p.shapes.code.length == 0) revert GuardFailed("SHAPES has no code");
        if (p.fwaFactory.code.length == 0) revert GuardFailed("FWA_FACTORY has no code");
        if (Denominations.UNIT != IShapes(p.shapes).unit()) {
            revert GuardFailed("ladder unit differs from SHAPES.unit()");
        }

        if (block.chainid == MAINNET) {
            if (p.shapes != MAINNET_SHAPES) revert GuardFailed("SHAPES is not the mainnet Shapes");
            if (p.fwaFactory != MAINNET_FWA_FACTORY) revert GuardFailed("FWA_FACTORY is not the mainnet factory");
            if (p.openingDeadline != 86_400) revert GuardFailed("opening deadline is not 86400");
            if (p.rotateInterval != 900) revert GuardFailed("rotate interval is not 900");
            if (p.feeSplit.premiumBps != 200 || p.feeSplit.maintenanceBps != 100 || p.feeSplit.feedBps != 400) {
                revert GuardFailed("fee split is not 200/100/400");
            }
            if (
                p.curve.baseBps != 1_100 || p.curve.slopeBps != 2_000 || p.curve.capBps != 2_500
                    || p.curve.referenceWei != 55 ether
            ) revert GuardFailed("entry curve is not 1100/2000/2500 at 55 ether");
        } else if (block.chainid == SEPOLIA) {
            if (p.shapes != SEPOLIA_SHAPES) revert GuardFailed("SHAPES is not the Sepolia Shapes");
            if (p.fwaFactory != SEPOLIA_FWA_FACTORY) revert GuardFailed("FWA_FACTORY is not the Sepolia factory");
        } else if (block.chainid != LOCAL) {
            revert UnsupportedChain(block.chainid);
        }
    }

    function _guardDrawPacks(IPoolTypes.Params memory p) internal view {
        if (p.drawPacks == address(0)) {
            if (block.chainid != LOCAL) revert DrawPacksMissing();
            return;
        }
        if (p.drawPacks.code.length == 0) revert GuardFailed("DRAW_PACKS has no code");
        if (ShapePacks(payable(p.drawPacks)).MIN_PACK_VALUE() != 2 * IShapes(p.shapes).unit()) {
            revert GuardFailed("DRAW_PACKS minimum pack value is not 2 units");
        }
        if (ShapePacks(payable(p.drawPacks)).shapes() != p.shapes) {
            revert GuardFailed("DRAW_PACKS wraps a different Shapes");
        }
    }

    // ------------------------------------------------------------------ postflight

    function _postflight(Pool pool, PoolAdmin module, Lens lens, IPoolTypes.Params memory p) internal view {
        require(address(pool).code.length != 0, "pool has no code");
        require(address(module).code.length != 0, "module has no code");
        require(pool.adminModule() == address(module), "adminModule");
        require(!IPool(address(pool)).canImport(address(0), 1), "admin module unreachable");
        require(address(lens).code.length != 0 && address(lens.pool()) == address(pool), "lens");
        require(pool.admin() == p.admin, "admin");
        require(pool.shapes() == p.shapes, "shapes");
        require(pool.drawPacks() == p.drawPacks, "drawPacks");
        require(pool.fwaFactory() == p.fwaFactory, "fwaFactory");
        require(pool.oldPool() == p.oldPool, "oldPool");
        require(pool.lifecycle() == IPoolTypes.Lifecycle.Opening, "lifecycle");
        require(pool.nav() == 0, "nav");
        require(pool.navCap() == p.navCap, "navCap");
        require(pool.rotateInterval() == p.rotateInterval, "rotateInterval");
        require(pool.openingDeadline() == p.openingDeadline, "openingDeadline");
        require(pool.minItems() == p.minItems, "minItems");
        require(pool.grailProbCapBps() == p.grailProbCapBps, "grailProbCapBps");
        require(pool.repriceMinBps() == p.repriceMinBps, "repriceMinBps");
        require(pool.restockTriggerBps() == p.restockTriggerBps, "restockTriggerBps");
        require(pool.quietIntervalSeconds() == p.quietIntervalSeconds, "quietIntervalSeconds");

        (uint16 premium, uint16 maint, uint16 feed, uint16 minorShare) = pool.feeSplit();
        require(
            premium == p.feeSplit.premiumBps && maint == p.feeSplit.maintenanceBps && feed == p.feeSplit.feedBps
                && minorShare == p.feeSplit.minorShareBps,
            "feeSplit"
        );
        (uint32 base, uint32 slope, uint32 cap, uint128 refWei) = pool.curve();
        require(
            base == p.curve.baseBps && slope == p.curve.slopeBps && cap == p.curve.capBps
                && refWei == p.curve.referenceWei,
            "curve"
        );

        for (uint256 i; i < p.mix.length; ++i) {
            require(pool.rowCount(i) == 0, "rowCount");
            (uint8[] memory rungs, uint16 share) = pool.mixRow(i);
            require(
                share == p.mix[i].shareBps
                    && keccak256(abi.encodePacked(rungs)) == keccak256(abi.encodePacked(p.mix[i].rungs)),
                "mixRow"
            );
        }
        _checkGrail(pool, MINOR, p.minor);
        _checkGrail(pool, MAJOR, p.major);
    }

    function _checkGrail(Pool pool, uint256 track, IPoolTypes.GrailParams memory g) internal view {
        (,,,, uint256 target, uint256 step, uint256 listBps, uint256 decay, uint256 floor,,,) = pool.grail(track);
        require(
            target == g.targetWei && step == g.stepWei && listBps == g.listBps && decay == g.decayWeiPerPull
                && floor == g.floorWei,
            "grail"
        );
    }

    // ------------------------------------------------------------------ record

    function _writeRecord(Pool pool, PoolAdmin module, Lens lens, IPoolTypes.Params memory p) internal {
        string memory k = "record";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "pool", _lower(address(pool)));
        vm.serializeString(k, "adminModule", _lower(address(module)));
        vm.serializeString(k, "lens", _lower(address(lens)));
        vm.serializeString(k, "shapes", _lower(p.shapes));
        vm.serializeString(k, "drawPacks", _lower(p.drawPacks));
        vm.serializeString(k, "fwaFactory", _lower(p.fwaFactory));
        vm.serializeString(k, "admin", _lower(p.admin));
        vm.serializeString(k, "oldPool", _lower(p.oldPool));
        vm.serializeString(k, "gitCommit", vm.envOr("GIT_COMMIT", string("unknown")));
        vm.serializeUint(k, "blockNumber", block.number);
        string memory json = vm.serializeUint(k, "deployedAt", block.timestamp);
        vm.writeJson(json, vm.envString("DEPLOYMENT_RECORD"));
    }

    function _lower(address a) internal pure returns (string memory) {
        return vm.toLowercase(vm.toString(a));
    }
}
