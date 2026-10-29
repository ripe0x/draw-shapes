// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";

import {FwaGame} from "../src/game/FwaGame.sol";
import {PoolOwner} from "../src/game/PoolOwner.sol";
import {PrizeVault} from "../src/game/PrizeVault.sol";
import {Converter} from "../src/game/Converter.sol";
import {GenesisFarm} from "../src/token/GenesisFarm.sol";
import {EngineToken} from "../src/token/EngineToken.sol";
import {EngineRenderer} from "../src/token/EngineRenderer.sol";
import {EngineHook} from "../src/token/EngineHook.sol";
import {EngineBuyer} from "../src/token/EngineBuyer.sol";
import {ProtocolLiquidity} from "../src/token/ProtocolLiquidity.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";
import {Buyback} from "../src/treasury/Buyback.sol";
import {SwapPolicy} from "../src/policy/SwapPolicy.sol";
import {BoardPolicy, PricingPolicy} from "../src/policy/GamePolicies.sol";
import {FwaFeeBuyer} from "../src/periphery/FwaFeeBuyer.sol";
import {Lens} from "../src/Lens.sol";
import {IShapePacks} from "../src/interfaces/IDrawShapes.sol";

/// @notice The one deployment routine, shared by `script/Deploy.s.sol` and the fork tests, so the tests
///         exercise exactly what is broadcast. Every step is followed by readback checks in `postflight`.
abstract contract DeploySystem {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant LP_FLOAT = 800_000_000 ether; // 80%
    uint256 internal constant GENESIS = 190_000_000 ether; // 19%
    uint256 internal constant BONUS = 10_000_000 ether; // 1%

    struct Config {
        address governance; // proposer and executor of the timelock
        address shapes;
        address packs;
        address fwaFactory;
        address fwaImplementation;
        address poolManager;
        address create2Deployer; // the address that executes `new X{salt: s}` (CREATE2 factory in scripts)
        bytes32 poolSalt;
        bool createPool; // create the FWA pool during deployment
        uint256 fwaFeeEth; // ETH to spend buying the FWA creation fee (0 when the factory charges none)
        // policies
        uint8[] boardKinds;
        uint96[] boardBackings;
        uint256 listBatch;
        uint256 markupBps;
        uint256 conversionBonusBps;
        uint256 opsBps;
        uint256 hookFeeBps;
        uint256 snipeStartBps;
        uint256 snipeWindow;
        // game capital
        FwaGame.Capital capital;
        uint256 marketLead;
        // genesis and launch
        uint256 rateCap; // ENGINE per 1 ETH of eligible ticket ETH in a steady epoch
        int24 startTick; // the single-sided launch price (ENGINE per ETH = 1.0001^startTick), its highest ever
        // buyback
        uint256 sliceWei;
        uint256 minSpacing;
        uint256 maxImpactBps;
        uint256 maxDeviationBps;
        KeeperFund.Params keeper;
        uint256 keeperSeed; // ETH the deploy wallet seeds KeeperFund with
        uint256 keeperTopUpTarget; // what the vault keeps KeeperFund at above its floor, from trading fees
        uint256 shutdownDelay;
        uint256 lpMaxImpactBps;
    }

    struct System {
        TimelockController timelock;
        KeeperFund keeperFund;
        EngineRenderer renderer;
        GenesisFarm farm;
        ProtocolLiquidity liquidity;
        EngineToken engine;
        SwapPolicy swapPolicy;
        EngineHook hook;
        EngineBuyer buyer;
        BoardPolicy board;
        PricingPolicy pricing;
        PrizeVault vault;
        PoolOwner poolOwner;
        FwaGame game;
        Converter converter;
        Buyback buyback;
        FwaFeeBuyer feeBuyer;
        Lens lens;
    }

    error DeployMismatch(string what);

    function _check(bool ok, string memory what) internal pure {
        if (!ok) revert DeployMismatch(what);
    }

    /// @dev Deploys and wires everything from `deployer` (the address whose CREATE nonce is used).
    function _deploySystem(Config memory c, address deployer) internal returns (System memory s) {
        address[] memory gov = new address[](1);
        gov[0] = c.governance;
        s.timelock = new TimelockController(0, gov, gov, address(0));
        address tl = address(s.timelock);

        s.keeperFund = new KeeperFund{value: c.keeperSeed}(tl, c.keeper);
        s.renderer = new EngineRenderer();

        // The token mints to the farm and ProtocolLiquidity, which need its address: predict it.
        uint256 nonce = VM.getNonce(deployer);
        address predicted = VM.computeCreateAddress(deployer, nonce + 2);
        s.farm = new GenesisFarm(tl, predicted, GENESIS, BONUS, c.rateCap);
        s.liquidity = new ProtocolLiquidity(tl, IPoolManager(c.poolManager), predicted, c.lpMaxImpactBps, c.startTick);
        {
            address[] memory to = new address[](2);
            uint256[] memory amounts = new uint256[](2);
            (to[0], amounts[0]) = (address(s.liquidity), LP_FLOAT);
            (to[1], amounts[1]) = (address(s.farm), GENESIS + BONUS);
            s.engine = new EngineToken(tl, to, amounts, address(s.renderer));
        }
        _check(address(s.engine) == predicted, "engine address");

        s.swapPolicy = new SwapPolicy(tl, address(s.farm), c.hookFeeBps, c.snipeStartBps, c.snipeWindow);
        // The vault receives the hook's trading fees, so it exists before the hook.
        s.vault = new PrizeVault(tl, address(s.liquidity), c.poolManager, c.shutdownDelay);
        s.hook = _deployHook(c, s, tl);
        s.buyer = new EngineBuyer(tl, IPoolManager(c.poolManager), address(s.engine), address(s.hook));

        // Pack rows must meet Shape Packs' minimum; without Shape Packs on the chain there are no Pack rows.
        uint256 minPack = c.packs == address(0) ? type(uint256).max : IShapePacks(c.packs).MIN_PACK_VALUE();
        s.board = new BoardPolicy(tl, minPack, c.boardKinds, c.boardBackings, c.listBatch);
        s.pricing = new PricingPolicy(tl, c.markupBps, c.conversionBonusBps, c.opsBps);
        s.buyback = new Buyback(
            tl,
            address(s.keeperFund),
            address(s.engine),
            address(s.buyer),
            c.sliceWei,
            c.minSpacing,
            c.maxImpactBps,
            c.maxDeviationBps
        );
        s.poolOwner = new PoolOwner(tl, c.shapes, c.packs, c.fwaFactory, c.fwaImplementation);
        s.game = new FwaGame(
            FwaGame.Config({
                governance: tl,
                factory: c.fwaFactory,
                poolOwner: address(s.poolOwner),
                vault: address(s.vault),
                farm: address(s.farm),
                buyback: address(s.buyback),
                keeperFund: address(s.keeperFund),
                board: address(s.board),
                pricing: address(s.pricing),
                buyer: address(s.buyer),
                capital: c.capital,
                marketLead: c.marketLead
            })
        );
        s.converter = new Converter(address(s.game), address(s.farm));
        s.feeBuyer = new FwaFeeBuyer(IPoolManager(c.poolManager), _fwaToken(c));
        s.lens = new Lens();

        _wire(c, s);

        if (c.createPool) {
            uint256 fee = _poolCreationFee(c);
            if (fee != 0) s.feeBuyer.buyTo{value: c.fwaFeeEth}(address(s.poolOwner), fee);
            s.poolOwner.createPool(c.poolSalt);
        }
    }

    function _wire(Config memory c, System memory s) internal {
        {
            address[] memory payers = new address[](3);
            payers[0] = address(s.game);
            payers[1] = address(s.buyback);
            payers[2] = address(s.farm);
            s.keeperFund.wire(payers, address(s.game), address(s.vault));
        }
        s.farm.wire(address(s.game), address(s.converter), address(s.keeperFund));
        {
            address[] memory exempt = new address[](2);
            exempt[0] = address(s.buyer);
            exempt[1] = address(s.liquidity);
            s.swapPolicy.wire(address(s.hook), exempt);
        }
        s.liquidity.wire(address(s.hook), address(s.vault));
        {
            address[] memory callers = new address[](2);
            callers[0] = address(s.converter);
            callers[1] = address(s.buyback);
            s.buyer.wire(callers);
        }
        s.poolOwner.wire(address(s.game));
        s.vault.wire(address(s.game), address(s.keeperFund), c.keeperTopUpTarget);
        s.buyback.wire(address(s.game));
    }

    function _deployHook(Config memory c, System memory s, address tl) internal returns (EngineHook hook) {
        bytes memory args = abi.encode(
            IPoolManager(c.poolManager),
            address(s.engine),
            address(s.liquidity),
            address(s.vault),
            tl,
            address(s.swapPolicy)
        );
        bytes32 initHash = keccak256(abi.encodePacked(type(EngineHook).creationCode, args));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 400_000; ++i) {
            salt = bytes32(i);
            predicted = VM.computeCreate2Address(salt, initHash, c.create2Deployer);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }
        hook = new EngineHook{salt: salt}(
            IPoolManager(c.poolManager),
            address(s.engine),
            address(s.liquidity),
            address(s.vault),
            tl,
            address(s.swapPolicy)
        );
        _check(address(hook) == predicted, "hook address");
    }

    function _fwaToken(Config memory c) internal view returns (address) {
        return IFactoryView(c.fwaFactory).fwaToken();
    }

    function _poolCreationFee(Config memory c) internal view returns (uint256) {
        return IFactoryView(c.fwaFactory).poolCreationFee();
    }

    /// @notice ETH that buys the FWA creation fee at FWA's v4 spot price with `marginBps` on top (covers the
    ///         FWA hook's 1% buy fee and price impact). Any FWA above the fee is burned by `createPool`.
    function fwaFeeQuote(address factory, address poolManager, uint256 marginBps) public view returns (uint256) {
        address fwa = IFactoryView(factory).fwaToken();
        PoolKey memory key = IFwaTokenView(fwa).poolKey();
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(IPoolManager(poolManager), key.toId());
        uint256 fwaPerEth = FPM.fullMulDiv(uint256(sqrtP) * uint256(sqrtP), 1e18, 1 << 192);
        uint256 fee = IFactoryView(factory).poolCreationFee();
        return FPM.fullMulDiv(fee, 1e18, fwaPerEth) * (10_000 + marginBps) / 10_000;
    }

    // ------------------------------------------------------------------ postflight

    /// @notice Reads back every reference, ownership and launch value; reverts `DeployMismatch` on any difference.
    function postflight(Config memory c, System memory s, address deployer) public view {
        address tl = address(s.timelock);
        // timelock
        _check(s.timelock.getMinDelay() == 0, "timelock delay");
        _check(s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), c.governance), "proposer");
        _check(s.timelock.hasRole(s.timelock.EXECUTOR_ROLE(), c.governance), "executor");
        _check(!s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), deployer), "deployer admin");
        _check(!s.timelock.hasRole(s.timelock.PROPOSER_ROLE(), deployer), "deployer proposer");
        // supply and recipients
        _check(s.engine.totalSupply() == SUPPLY, "supply");
        _check(s.engine.balanceOf(address(s.liquidity)) == LP_FLOAT, "lp float");
        _check(s.engine.balanceOf(address(s.farm)) == GENESIS + BONUS, "farm balance");
        _check(s.engine.balanceOf(deployer) == 0, "deployer engine");
        _check(s.farm.genesisBudget() == GENESIS && s.farm.bonusPool() == BONUS, "farm split");
        _check(s.farm.rateCap() == c.rateCap, "rate cap");
        // governance everywhere, nothing left to the deploy wallet
        address[12] memory governed = [
            address(s.keeperFund),
            address(s.farm),
            address(s.liquidity),
            address(s.engine),
            address(s.swapPolicy),
            address(s.buyer),
            address(s.board),
            address(s.pricing),
            address(s.vault),
            address(s.game),
            address(s.buyback),
            address(s.poolOwner)
        ];
        for (uint256 i; i < governed.length; ++i) {
            _check(IGovernedView(governed[i]).governance() == tl, "governance");
            _check(IGovernedView(governed[i]).deployer() == address(0), "deployer power left");
        }
        _check(s.hook.governance() == tl, "hook governance");
        // funding routes: trading fees to the vault (capital), profit to the burn-only buyback, overflow to the game
        _check(s.hook.engine() == address(s.engine) && s.hook.launcher() == address(s.liquidity), "hook refs");
        _check(
            s.hook.feeRecipient() == address(s.vault) && address(s.hook.policy()) == address(s.swapPolicy), "fee route"
        );
        _check(s.vault.poolManager() == c.poolManager, "vault fee intake");
        _check(s.game.buyback() == address(s.buyback) && s.buyback.isSource(address(s.game)), "profit route");
        _check(s.keeperFund.overflow() == address(s.game), "keeper overflow");
        _check(s.liquidity.hook() == address(s.hook) && s.liquidity.isAdder(address(s.vault)), "liquidity refs");
        _check(s.swapPolicy.hook() == address(s.hook), "policy hook");
        _check(s.swapPolicy.exempt(address(s.buyer)) && s.swapPolicy.exempt(address(s.liquidity)), "exempt");
        _check(s.swapPolicy.feeBps() == c.hookFeeBps, "hook fee");
        _check(s.swapPolicy.snipeStartBps() == c.snipeStartBps && s.swapPolicy.snipeWindow() == c.snipeWindow, "snipe");
        _check(s.buyer.isCaller(address(s.converter)) && s.buyer.isCaller(address(s.buyback)), "buyer callers");
        _check(!s.buyer.isCaller(address(s.game)), "the game does not buy");
        _check(s.farm.isBonusPayer(address(s.converter)), "bonus payer");
        _check(address(s.converter.game()) == address(s.game), "converter game");
        _check(s.farm.isLedger(address(s.game)), "farm ledger");
        _check(s.game.reserveTarget() == c.capital.reserveTarget, "reserve");
        _check(s.game.maintenanceInterval() == c.capital.maintenanceInterval, "maintenance");
        _check(
            s.game.minLiveBps() == c.capital.minLiveBps && s.game.maxInFlight() == c.capital.maxInFlight, "admission"
        );
        _check(s.game.bookingEdgeBps() == c.capital.maxEdgeBps, "booking edge");
        _check(
            address(s.game.poolOwner()) == address(s.poolOwner) && address(s.poolOwner.game()) == address(s.game),
            "pool owner refs"
        );
        _check(
            address(s.poolOwner.shapes()) == c.shapes && address(s.poolOwner.packs()) == c.packs, "prize collections"
        );
        _check(s.liquidity.startTick() == c.startTick, "start tick");
        _check(
            s.vault.keeperFund() == address(s.keeperFund) && s.keeperFund.vault() == address(s.vault), "keeper top-up"
        );
        _check(s.vault.keeperTopUpTarget() == c.keeperTopUpTarget, "keeper top-up target");
        _check(s.keeperFund.tipCap() == c.keeper.tipCap && s.keeperFund.flatFee() == c.keeper.flatFee, "keeper pay");
        _check(
            s.game.maxEdgeBps() == c.capital.maxEdgeBps && s.game.maxCooldown() == c.capital.maxCooldown, "fwa range"
        );
        _check(s.game.marketLead() == c.marketLead, "market lead");
        _check(s.buyback.sliceWei() == c.sliceWei && s.buyback.maxImpactBps() == c.maxImpactBps, "buyback limits");
        _check(s.buyback.maxDeviationBps() == c.maxDeviationBps, "buyback deviation");
        _check(address(s.keeperFund).balance >= c.keeperSeed, "keeper seed");
        _check(s.keeperFund.maintenanceFloor() == c.keeper.maintenanceFloor, "keeper floor");
        _check(address(s.farm.keeperFund()) == address(s.keeperFund), "farm keeper");
        _check(s.farm.GENESIS_EPOCHS() == 21 && s.farm.EPOCH_BLOCKS() == 7_200, "genesis");
        _check(s.vault.activeGame() == address(s.game), "vault game");
        _check(address(s.vault.liquidity()) == address(s.liquidity), "vault liquidity");
        _check(address(s.game.vault()) == address(s.vault) && address(s.game.farm()) == address(s.farm), "game refs");
        _check(address(s.game.keeperFund()) == address(s.keeperFund), "game keeper");
        _check(address(s.game.buyer()) == address(s.buyer), "game buyer");
        _check(s.pricing.markupBps() == c.markupBps && s.pricing.opsBps() == c.opsBps, "pricing");
        for (uint256 i; i < 3; ++i) {
            address p = [address(s.game), address(s.buyback), address(s.farm)][i];
            _check(s.keeperFund.isPayer(p), "payer");
        }
        // FWA pool
        if (c.createPool) {
            address pool = address(s.game.pool());
            _check(pool != address(0), "pool");
            _check(IOwnedView(pool).owner() == address(s.poolOwner), "pool owner");
            _check(IPurchaseView(pool).purchaseOperator() == address(s.poolOwner), "purchase operator");
            _check(s.poolOwner.pool() == pool, "pool recorded");
            _check(s.poolOwner.maxInFlight() == c.capital.maxInFlight, "gate in flight");
            _check(
                s.poolOwner.maxEdgeBps() == c.capital.maxEdgeBps && s.poolOwner.maxCooldown() == c.capital.maxCooldown,
                "gate range"
            );
            _check(s.poolOwner.maxBatch() == IFactoryBatch(c.fwaFactory).maxAcquisitionsPerTx(), "gate batch");
        }
        // gate end follows genesis end (max before the game opens)
        _check(
            s.farm.genesisEndBlock() == (s.farm.openBlock() == 0 ? type(uint256).max : s.farm.openBlock() + 21 * 7_200),
            "gate end"
        );
    }
}

interface IFactoryView {
    function fwaToken() external view returns (address);
    function poolCreationFee() external view returns (uint256);
}

interface IFwaTokenView {
    function poolKey() external view returns (PoolKey memory);
}

interface IGovernedView {
    function governance() external view returns (address);
    function deployer() external view returns (address);
}

interface IOwnedView {
    function owner() external view returns (address);
}

interface IPurchaseView {
    function purchaseOperator() external view returns (address);
}

interface IFactoryBatch {
    function maxAcquisitionsPerTx() external view returns (uint16);
}
