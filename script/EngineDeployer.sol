// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "../src/Pool.sol";
import {PoolAdmin} from "../src/PoolAdmin.sol";
import {PoolListing} from "../src/PoolListing.sol";
import {Lens} from "../src/Lens.sol";
import {PricingLib} from "../src/lib/PricingLib.sol";
import {IPool, IPoolTypes} from "../src/interfaces/IPool.sol";
import {IArtCoinsFactoryV2} from "../src/interfaces/IArtcoins.sol";
import {EngineTreasury} from "../src/engine/EngineTreasury.sol";
import {FoundingRound} from "../src/engine/FoundingRound.sol";

/// @notice The one deployment path of the engine, shared by `script/DeployEngine.s.sol` (broadcast)
///         and the fork tests (direct calls), so a fork rehearsal runs the same code the chain will.
/// @dev Launch values live here, once. Environment files carry only addresses and round terms.
///      Every external address is the mainnet value from `deployments/dependencies.json` and the
///      Artcoins manifest `deployments/1.v2.json`, checked against live reads in `docs/MAINNET_READINESS.md`.
abstract contract EngineDeployer {
    address internal constant SHAPES = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    address internal constant FWA_FACTORY = 0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c;
    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant ARTCOINS_FACTORY = 0x9b17bf6f97F5429368E11028BC637479b4667f7b;
    address internal constant ARTCOINS_HOOK = 0x2f7976bf73dE8e1D49D4c687404e527a75b0e8Cc;
    address internal constant ARTCOINS_LOCKER = 0x1e2456861B864B96FFe6b34066b12FBD7EEb23fC;
    address internal constant ARTCOINS_MEV = 0xFbb55b4C13b8517C000e2686efB12F0FAAFc9072;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WRAPPED_PUNKS = 0xb7F7F6C52F2e2fdb1963Eab30438024864c313F6;

    // Coin market terms, immutable at launch (docs/AUTONOMOUS_DECISIONS.md, coin entries).
    uint24 internal constant COIN_LP_FEE_PIPS = 0;
    uint24 internal constant COIN_SKIM_BPS = 500;
    uint16 internal constant COIN_BOUNTY_BPS = 9_000;
    uint16 internal constant COIN_PROTOCOL_LOCKER_BPS = 2_000;
    uint24 internal constant COIN_SNIPER_START_BPS = 6_869;
    uint32 internal constant COIN_SNIPER_WINDOW = 4_140;

    // Founding round terms.
    uint256 internal constant ROUND_DURATION = 48 hours;
    uint256 internal constant ROUND_LAUNCH_WINDOW = 14 days;
    uint256 internal constant ROUND_CAP_BPS = 12_000;
    uint256 internal constant ROUND_MIN_CONTRIBUTION = 0.05 ether;
    /// @dev Five 1 ETH GRAIL pieces and their 0.001 ETH Shapes mint fees.
    uint256 internal constant OPENING_FIVE = 5.005 ether;

    struct Deployment {
        Pool pool;
        PoolAdmin adminModule;
        PoolListing listingModule;
        Lens lens;
        EngineTreasury treasury;
    }

    /// @notice Pool launch values for the protocol-owned game. Admission is closed to everyone but
    ///         the treasury: zero NAV cap floor, no entry fee, no founder window (the treasury
    ///         lifts the floor for its own deposits and keeps deposits paused).
    function _poolParams(address drawPacks, address deployer) internal pure returns (IPoolTypes.Params memory p) {
        p.shapes = SHAPES;
        p.drawPacks = drawPacks;
        p.fwaFactory = FWA_FACTORY;
        p.admin = deployer;
        p.mix = _mix();
        // Premium 300: in the engine the premium is what pays founders and buybacks (D10).
        p.feeSplit = IPoolTypes.FeeSplit({premiumBps: 300, maintenanceBps: 100, feedBps: 400});
        p.grail = IPoolTypes.GrailParams({
            targetWei: 25 ether,
            listBps: 7_500,
            decayWeiPerPull: 0.001 ether,
            pieceFloorWei: 1 ether,
            floorWei: 1 ether,
            stepUpSeconds: 14 days,
            stepDownSeconds: 60 days
        });
        p.navCapFloor = 0;
        p.turnoverBps = 1_250;
        p.entryFee = IPoolTypes.EntryFee({floorBps: 0, capBps: 0, paybackDays: 1});
        p.founderWindowSeconds = 0;
        p.rotateInterval = 900;
        p.openingDeadline = 24 hours;
        p.minItems = 100;
        p.grailProbCapBps = 1_000;
        // One settle lists at most 12 items (EIP-7825 gas cap), so a batch is 12.
        p.batchMin = 12;
        p.batchMaxAge = 1 hours;
        p.surpriseBps = 200;
        p.restoreK = 8;
        p.bandBps = 3_000;
        p.reserveBps = 1_000;
        p.tipWei = 0.0002 ether;
    }

    /// @dev Rungs index the Shapes ladder (0 is 0.01 ETH, 1 is 0.05, 2 is 0.1, 3 is 0.5). Rows of two or
    ///      more rungs are Draw Packs.
    function _mix() internal pure returns (PricingLib.MixRow[] memory rows) {
        rows = new PricingLib.MixRow[](6);
        rows[0] = _row(_rungs(0, 1), 5_000);
        rows[1] = _row(_rungs(0, 2), 2_200);
        rows[2] = _row(_rungs(0, 3), 1_300);
        rows[3] = _row(_rungs(1, 1), 1_000);
        rows[4] = _row(_rungs(2, 1), 400);
        rows[5] = _row(_rungs(3, 1), 100);
    }

    function _rungs(uint8 rung, uint256 count) private pure returns (uint8[] memory r) {
        r = new uint8[](count);
        for (uint256 i; i < count; ++i) {
            r[i] = rung;
        }
    }

    function _row(uint8[] memory rungs, uint16 shareBps) private pure returns (PricingLib.MixRow memory r) {
        r.rungs = rungs;
        r.shareBps = shareBps;
    }

    /// @notice Treasury terms for a round of `roundTarget` wei (docs/AUTONOMOUS_DECISIONS.md).
    function _treasuryConfig(address owner, uint256 roundTarget) internal pure returns (EngineTreasury.Config memory c) {
        c.owner = owner;
        c.poolManager = IPoolManager(POOL_MANAGER);
        c.artcoinsFactory = ARTCOINS_FACTORY;
        c.artcoinsHook = ARTCOINS_HOOK;
        c.artcoinsLocker = ARTCOINS_LOCKER;
        c.coinSkimBps = COIN_SKIM_BPS;
        c.coinBountyBps = COIN_BOUNTY_BPS;
        c.coinLpFeePips = COIN_LP_FEE_PIPS;
        c.founderTradingBps = 6_500;
        c.founderEarningsBps = 5_000;
        c.maxSponsorShareBps = 5_000;
        c.poolTarget = 6 ether;
        c.poolFloorBps = 8_000;
        c.maintenanceTarget = 0.5 ether;
        c.maintenanceFloor = 0.15 ether;
        // Up to 4 ETH of reserve while the GRAIL keeps at least the opening five (5 pieces and their
        // mint fees); the rest of the round seeds the GRAIL fund.
        uint256 afterOpening = roundTarget - c.poolTarget - c.maintenanceTarget - OPENING_FIVE;
        c.reserveTarget = afterOpening < 4 ether ? afterOpening : 4 ether;
        c.grailSeed = roundTarget - c.poolTarget - c.maintenanceTarget - c.reserveTarget;
        c.premiumFloorBps = 200;
        c.maxBuybackPerCall = 0.5 ether;
        c.maxImpactBps = 200;
        c.prizeCollection = WRAPPED_PUNKS;
        c.maxBidWei = 60 ether;
        c.dormancy = 90 days;
    }

    /// @notice Deploys the modules, the pool (admin `deployer`), the Lens and the treasury, then hands
    ///         the pool admin to the treasury. Run from `deployer`.
    function _deployEngine(address drawPacks, address deployer, address owner, uint256 roundTarget)
        internal
        returns (Deployment memory d)
    {
        IPoolTypes.Params memory p = _poolParams(drawPacks, deployer);
        d.adminModule = new PoolAdmin();
        d.listingModule = new PoolListing();
        d.pool = new Pool(p, address(d.adminModule), address(d.listingModule));
        d.lens = new Lens(d.pool);
        EngineTreasury.Config memory c = _treasuryConfig(owner, roundTarget);
        c.pool = IPool(address(d.pool));
        d.treasury = new EngineTreasury(c);
        IPool(address(d.pool)).setAdmin(address(d.treasury));
    }

    /// @notice The founding round for `treasury`, opened now for `ROUND_DURATION`.
    function _openRound(address owner, EngineTreasury treasury, uint256 target) internal returns (FoundingRound) {
        return new FoundingRound(
            owner, address(treasury), target, ROUND_DURATION, ROUND_LAUNCH_WINDOW, ROUND_CAP_BPS, ROUND_MIN_CONTRIBUTION
        );
    }

    /// @notice The ENGINE coin launch config: native ETH pair on the Artcoins v2 hook, a 5 percent
    ///         ETH-side skim with no LP fee, 90 percent of it to the treasury as the bounty leg, no
    ///         referral, the treasury as the only project reward slot, the Artcoins sniper skim, and
    ///         the reference coin-only liquidity layout of `script/v2/launch-configs/example.json`.
    function _coinConfig(address treasury, address tokenAdmin, string memory name, string memory symbol, bytes32 salt)
        internal
        pure
        returns (IArtCoinsFactoryV2.DeploymentConfigV2 memory c)
    {
        c.token = IArtCoinsFactoryV2.TokenConfigV2({
            tokenAdmin: tokenAdmin,
            name: name,
            symbol: symbol,
            salt: salt,
            image: "",
            description: "",
            totalSupply: 0,
            renderer: address(0)
        });
        c.pool = IArtCoinsFactoryV2.PoolConfigV2({
            hook: ARTCOINS_HOOK,
            tickIfToken0IsCoin: -200_000,
            tickSpacing: 200,
            extension: address(0),
            extensionData: ""
        });
        c.fee = IArtCoinsFactoryV2.FeeConfigV2({
            lpFeePips: COIN_LP_FEE_PIPS,
            baselineSkimBps: COIN_SKIM_BPS,
            bountyBps: COIN_BOUNTY_BPS,
            maxReferralBpsOfVolume: 0,
            bountyRecipient: payable(treasury)
        });
        address[] memory recipients = new address[](1);
        recipients[0] = treasury;
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000 - COIN_PROTOCOL_LOCKER_BPS;
        int24[] memory lo = new int24[](3);
        lo[0] = -200_000;
        lo[1] = -160_000;
        lo[2] = -120_000;
        int24[] memory hi = new int24[](3);
        hi[0] = -120_000;
        hi[1] = -100_000;
        hi[2] = -60_000;
        uint16[] memory pos = new uint16[](3);
        pos[0] = 5_000;
        pos[1] = 3_000;
        pos[2] = 2_000;
        c.locker = IArtCoinsFactoryV2.LockerConfigV2({
            locker: ARTCOINS_LOCKER,
            rewardRecipients: recipients,
            rewardBps: rewardBps,
            tickLower: lo,
            tickUpper: hi,
            positionBps: pos
        });
        c.mev = IArtCoinsFactoryV2.MevConfigV2({
            module: ARTCOINS_MEV,
            startingSkimBps: COIN_SNIPER_START_BPS,
            windowSeconds: COIN_SNIPER_WINDOW
        });
        c.restriction = IArtCoinsFactoryV2.RestrictionConfigV2({restricted: false, allowed: new address[](0)});
    }
}
