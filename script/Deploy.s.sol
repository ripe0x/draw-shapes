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
import {PoolListing} from "../src/PoolListing.sol";
import {Lens} from "../src/Lens.sol";
import {PricingLib} from "../src/lib/PricingLib.sol";
import {IPool, IPoolTypes} from "../src/interfaces/IPool.sol";

/// @notice Deploys `PoolAdmin`, `PoolListing`, `Pool` and `Lens` and checks their constructor state in the same run.
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

    /// @notice Deploys the pool, verifies it and writes the record.
    function run() external returns (Pool pool, PoolAdmin module, PoolListing listing, Lens lens) {
        IPoolTypes.Params memory p = _params();
        _guardChain(p);
        _guardDrawPacks(p);

        vm.startBroadcast();
        if (p.drawPacks == address(0)) {
            ShapePackRenderer renderer = new ShapePackRenderer(p.shapes);
            p.drawPacks = address(new ShapePacks(p.shapes, address(renderer), p.admin, "Draw Packs", "DRAW", 2));
        }
        module = new PoolAdmin();
        listing = new PoolListing();
        pool = new Pool(p, address(module), address(listing));
        lens = new Lens(pool);
        vm.stopBroadcast();

        _postflight(pool, module, listing, lens, p);
        _writeRecord(pool, module, listing, lens, p);
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
            feedBps: SafeCastLib.toUint16(vm.envUint("FEED_BPS"))
        });
        p.grail = IPoolTypes.GrailParams({
            targetWei: vm.envUint("GRAIL_TARGET_WEI"),
            listBps: vm.envUint("GRAIL_LIST_BPS"),
            decayWeiPerPull: vm.envUint("GRAIL_DECAY_WEI_PER_PULL"),
            pieceFloorWei: vm.envUint("GRAIL_PIECE_FLOOR_WEI"),
            floorWei: vm.envUint("GRAIL_FLOOR_WEI")
        });
        uint256 navCapFloor = vm.envUint("NAV_CAP_FLOOR_WEI");
        p.navCapFloor = navCapFloor == 0 ? type(uint256).max : navCapFloor;
        p.turnoverBps = SafeCastLib.toUint16(vm.envUint("TURNOVER_BPS"));
        p.entryFee = IPoolTypes.EntryFee({
            floorBps: SafeCastLib.toUint32(vm.envUint("ENTRY_FLOOR_BPS")),
            capBps: SafeCastLib.toUint32(vm.envUint("ENTRY_CAP_BPS")),
            paybackDays: SafeCastLib.toUint32(vm.envUint("ENTRY_PAYBACK_DAYS"))
        });
        p.founderWindowSeconds = SafeCastLib.toUint32(vm.envUint("FOUNDER_WINDOW_SECONDS"));
        p.rotateInterval = vm.envUint("ROTATE_INTERVAL_SECONDS");
        p.openingDeadline = vm.envUint("OPENING_DEADLINE_SECONDS");
        p.minItems = vm.envUint("MIN_ITEMS");
        p.grailProbCapBps = vm.envUint("GRAIL_PROB_CAP_BPS");
        p.batchMin = vm.envUint("BATCH_MIN");
        p.batchMaxAge = vm.envUint("BATCH_MAX_AGE_SECONDS");
        p.surpriseBps = vm.envUint("SURPRISE_BPS");
        p.restoreK = vm.envUint("RESTORE_K");
        p.bandBps = vm.envUint("BAND_BPS");
        p.reserveBps = vm.envUint("RESERVE_BPS");
        p.tipWei = vm.envUint("TIP_WEI");
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
            if (p.entryFee.floorBps != 1_000 || p.entryFee.capBps != 2_500 || p.entryFee.paybackDays != 20) {
                revert GuardFailed("entry fee is not 1000/2500 bps with 20 payback days");
            }
            if (p.turnoverBps != 1_250) revert GuardFailed("turnover is not 1250");
            if (p.founderWindowSeconds != 2_592_000) revert GuardFailed("founder window is not 2592000");
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

    function _postflight(Pool pool, PoolAdmin module, PoolListing listing, Lens lens, IPoolTypes.Params memory p)
        internal
        view
    {
        require(address(pool).code.length != 0, "pool has no code");
        require(address(module).code.length != 0, "module has no code");
        require(pool.adminModule() == address(module), "adminModule");
        require(address(listing).code.length != 0, "listing module has no code");
        require(pool.listingModule() == address(listing), "listingModule");
        require(!IPool(address(pool)).canImport(address(0), 1), "admin module unreachable");
        require(address(lens).code.length != 0 && address(lens.pool()) == address(pool), "lens");
        require(pool.admin() == p.admin, "admin");
        require(pool.shapes() == p.shapes, "shapes");
        require(pool.drawPacks() == p.drawPacks, "drawPacks");
        require(pool.fwaFactory() == p.fwaFactory, "fwaFactory");
        require(pool.oldPool() == p.oldPool, "oldPool");
        require(pool.lifecycle() == IPoolTypes.Lifecycle.Opening, "lifecycle");
        require(pool.nav() == 0, "nav");
        require(pool.navCapFloor() == p.navCapFloor, "navCapFloor");
        require(pool.navCap() == p.navCapFloor, "navCap");
        require(pool.turnoverBps() == p.turnoverBps, "turnoverBps");
        require(pool.founderWindowSeconds() == p.founderWindowSeconds, "founderWindowSeconds");
        require(pool.depositsOpenAt() == 0, "depositsOpenAt");
        require(pool.rotateInterval() == p.rotateInterval, "rotateInterval");
        require(IPool(address(pool)).openingDeadline() == p.openingDeadline, "openingDeadline");
        require(pool.minItems() == p.minItems, "minItems");
        require(IPool(address(pool)).grailProbCapBps() == p.grailProbCapBps, "grailProbCapBps");
        require(IPool(address(pool)).batchMin() == p.batchMin, "batchMin");
        require(IPool(address(pool)).batchMaxAge() == p.batchMaxAge, "batchMaxAge");
        require(IPool(address(pool)).surpriseBps() == p.surpriseBps, "surpriseBps");
        require(IPool(address(pool)).restoreK() == p.restoreK, "restoreK");
        require(IPool(address(pool)).bandBps() == p.bandBps, "bandBps");
        require(IPool(address(pool)).reserveBps() == p.reserveBps, "reserveBps");
        require(IPool(address(pool)).tipWei() == p.tipWei, "tipWei");

        (uint16 premium, uint16 maint, uint16 feed) = pool.feeSplit();
        require(
            premium == p.feeSplit.premiumBps && maint == p.feeSplit.maintenanceBps && feed == p.feeSplit.feedBps,
            "feeSplit"
        );
        (uint32 floorBps, uint32 capBps, uint32 paybackDays) = pool.entryFee();
        require(
            floorBps == p.entryFee.floorBps && capBps == p.entryFee.capBps && paybackDays == p.entryFee.paybackDays,
            "entryFee"
        );

        for (uint256 i; i < p.mix.length; ++i) {
            require(IPool(address(pool)).rowCount(i) == 0, "rowCount");
            (uint8[] memory rungs, uint16 share) = IPool(address(pool)).mixRow(i);
            require(
                share == p.mix[i].shareBps
                    && keccak256(abi.encodePacked(rungs)) == keccak256(abi.encodePacked(p.mix[i].rungs)),
                "mixRow"
            );
        }
        _checkGrail(pool, p.grail);
    }

    function _checkGrail(Pool pool, IPoolTypes.GrailParams memory g) internal view {
        IPoolTypes.Grail memory s = IPool(address(pool)).grail();
        require(
            s.targetWei == g.targetWei && s.nextTargetWei == g.targetWei && s.cycleId == 1 && s.fund == 0
                && s.listBps == g.listBps && s.decayWeiPerPull == g.decayWeiPerPull
                && s.pieceFloorWei == g.pieceFloorWei && s.floorWei == g.floorWei,
            "grail"
        );
        require(IPool(address(pool)).grailItems().length == 0, "grailItems");
    }

    // ------------------------------------------------------------------ record

    function _writeRecord(Pool pool, PoolAdmin module, PoolListing listing, Lens lens, IPoolTypes.Params memory p)
        internal
    {
        string memory k = "record";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "pool", _lower(address(pool)));
        vm.serializeString(k, "adminModule", _lower(address(module)));
        vm.serializeString(k, "listingModule", _lower(address(listing)));
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
