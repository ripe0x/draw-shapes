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
import {PrizeVault} from "../src/game/PrizeVault.sol";
import {GenesisFarm} from "../src/token/GenesisFarm.sol";
import {EngineToken} from "../src/token/EngineToken.sol";
import {EngineRenderer} from "../src/token/EngineRenderer.sol";
import {EngineHook} from "../src/token/EngineHook.sol";
import {EngineBuyer} from "../src/token/EngineBuyer.sol";
import {ProtocolLiquidity} from "../src/token/ProtocolLiquidity.sol";
import {Treasury} from "../src/treasury/Treasury.sol";
import {KeeperFund} from "../src/treasury/KeeperFund.sol";
import {BuybackBurn, BuybackReward, GrailFund} from "../src/treasury/Sinks.sol";
import {SwapPolicy} from "../src/policy/SwapPolicy.sol";
import {EmissionSchedule} from "../src/policy/EmissionSchedule.sol";
import {BoardPolicy, PricingPolicy, GrailPolicy} from "../src/policy/GamePolicies.sol";
import {FwaFeeBuyer} from "../src/periphery/FwaFeeBuyer.sol";
import {Lens} from "../src/Lens.sol";

/// @notice The one deployment routine, shared by `script/Deploy.s.sol` and the fork tests, so the tests
///         exercise exactly what is broadcast. Every step is followed by readback checks in `postflight`.
abstract contract DeploySystem {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant LP_FLOAT = 100_000_000 ether; // 10%
    uint256 internal constant GENESIS = 100_000_000 ether; // 10%
    uint256 internal constant BONUS = 10_000_000 ether; // 1%
    uint256 internal constant RESERVE = 790_000_000 ether; // 79%

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
        uint256[] grailLadder;
        uint256 grailStartBps;
        uint256 grailFloorBps;
        uint256 grailDecayBps;
        uint256 grailDecayPulls;
        uint256 hookFeeBps;
        uint256 snipeStartBps;
        uint256 snipeWindow;
        // treasury
        uint16 burnBps;
        uint16 rewardBps;
        uint16 grailBps;
        uint256 sliceWei;
        uint256 minSpacing;
        uint256 maxImpactBps;
        KeeperFund.Params keeper;
        uint256 shutdownDelay;
        uint256 lpMaxImpactBps;
    }

    struct System {
        TimelockController timelock;
        Treasury treasury;
        KeeperFund keeperFund;
        EmissionSchedule schedule;
        EngineRenderer renderer;
        GenesisFarm farm;
        ProtocolLiquidity liquidity;
        EngineToken engine;
        SwapPolicy swapPolicy;
        EngineHook hook;
        EngineBuyer buyer;
        BoardPolicy board;
        PricingPolicy pricing;
        GrailPolicy grail;
        PrizeVault vault;
        FwaGame game;
        BuybackBurn buybackBurn;
        BuybackReward buybackReward;
        GrailFund grailFund;
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

        s.treasury = new Treasury(tl);
        s.keeperFund = new KeeperFund(tl, address(s.treasury), c.keeper);
        s.schedule = new EmissionSchedule();
        s.renderer = new EngineRenderer();

        // The token mints to the farm and ProtocolLiquidity, which need its address: predict it.
        uint256 nonce = VM.getNonce(deployer);
        address predicted = VM.computeCreateAddress(deployer, nonce + 2);
        s.farm = new GenesisFarm(tl, predicted, GENESIS, BONUS, RESERVE, address(s.schedule));
        s.liquidity = new ProtocolLiquidity(tl, IPoolManager(c.poolManager), predicted, c.lpMaxImpactBps);
        {
            address[] memory to = new address[](2);
            uint256[] memory amounts = new uint256[](2);
            (to[0], amounts[0]) = (address(s.liquidity), LP_FLOAT);
            (to[1], amounts[1]) = (address(s.farm), GENESIS + BONUS + RESERVE);
            s.engine = new EngineToken(tl, to, amounts, address(s.renderer));
        }
        _check(address(s.engine) == predicted, "engine address");

        s.swapPolicy = new SwapPolicy(tl, address(s.farm), c.hookFeeBps, c.snipeStartBps, c.snipeWindow);
        s.hook = _deployHook(c, s, tl);
        s.buyer = new EngineBuyer(tl, IPoolManager(c.poolManager), address(s.engine), address(s.hook));

        s.board = new BoardPolicy(tl, c.boardKinds, c.boardBackings, c.listBatch);
        s.pricing = new PricingPolicy(tl, c.markupBps, c.conversionBonusBps);
        s.grail = new GrailPolicy(tl, c.grailLadder, c.grailStartBps, c.grailFloorBps, c.grailDecayBps, c.grailDecayPulls);
        s.vault = new PrizeVault(tl, address(s.liquidity), c.shutdownDelay);
        s.game = new FwaGame(
            tl,
            c.shapes,
            c.packs,
            c.fwaFactory,
            c.fwaImplementation,
            address(s.vault),
            address(s.farm),
            address(s.treasury),
            address(s.keeperFund),
            [address(s.board), address(s.pricing), address(s.grail), address(s.buyer)]
        );
        s.buybackBurn = new BuybackBurn(
            tl, address(s.treasury), address(s.keeperFund), address(s.engine), address(s.buyer), c.sliceWei, c.minSpacing, c.maxImpactBps
        );
        s.buybackReward = new BuybackReward(
            tl,
            address(s.treasury),
            address(s.keeperFund),
            address(s.engine),
            address(s.buyer),
            address(s.farm),
            c.sliceWei,
            c.minSpacing,
            c.maxImpactBps
        );
        s.grailFund = new GrailFund(tl, address(s.treasury), address(s.keeperFund), address(s.game));
        s.feeBuyer = new FwaFeeBuyer(IPoolManager(c.poolManager), _fwaToken(c));
        s.lens = new Lens();

        _wire(c, s);

        if (c.createPool) {
            uint256 fee = _poolCreationFee(c);
            if (fee != 0) s.feeBuyer.buyTo{value: c.fwaFeeEth}(address(s.game), fee);
            s.game.createPool(c.poolSalt);
        }
    }

    function _wire(Config memory c, System memory s) internal {
        {
            address[] memory sinks = new address[](3);
            uint16[] memory bps = new uint16[](3);
            (sinks[0], bps[0]) = (address(s.buybackBurn), c.burnBps);
            (sinks[1], bps[1]) = (address(s.buybackReward), c.rewardBps);
            (sinks[2], bps[2]) = (address(s.grailFund), c.grailBps);
            s.treasury.wire(address(s.keeperFund), sinks, bps);
        }
        {
            address[] memory payers = new address[](6);
            payers[0] = address(s.game);
            payers[1] = address(s.treasury);
            payers[2] = address(s.buybackBurn);
            payers[3] = address(s.buybackReward);
            payers[4] = address(s.grailFund);
            payers[5] = address(s.farm);
            s.keeperFund.wire(payers);
        }
        s.farm.wire(address(s.game), address(s.buybackReward), address(s.keeperFund));
        {
            address[] memory exempt = new address[](2);
            exempt[0] = address(s.buyer);
            exempt[1] = address(s.liquidity);
            s.swapPolicy.wire(address(s.hook), exempt);
        }
        s.liquidity.wire(address(s.hook), address(s.vault));
        {
            address[] memory callers = new address[](3);
            callers[0] = address(s.game);
            callers[1] = address(s.buybackBurn);
            callers[2] = address(s.buybackReward);
            s.buyer.wire(callers);
        }
        s.vault.wire(address(s.game));
    }

    function _deployHook(Config memory c, System memory s, address tl) internal returns (EngineHook hook) {
        bytes memory args = abi.encode(
            IPoolManager(c.poolManager), address(s.engine), address(s.liquidity), address(s.treasury), tl, address(s.swapPolicy)
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
            IPoolManager(c.poolManager), address(s.engine), address(s.liquidity), address(s.treasury), tl, address(s.swapPolicy)
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
        _check(s.engine.balanceOf(address(s.farm)) == GENESIS + BONUS + RESERVE, "farm balance");
        _check(s.engine.balanceOf(deployer) == 0, "deployer engine");
        _check(s.farm.genesisBudget() == GENESIS && s.farm.bonusPool() == BONUS && s.farm.reserve() == RESERVE, "farm split");
        // governance everywhere, nothing left to the deploy wallet
        address[13] memory governed = [
            address(s.treasury), address(s.keeperFund), address(s.farm), address(s.liquidity), address(s.engine),
            address(s.swapPolicy), address(s.buyer), address(s.board), address(s.pricing), address(s.grail),
            address(s.vault), address(s.game), address(s.buybackBurn)
        ];
        for (uint256 i; i < governed.length; ++i) {
            _check(IGovernedView(governed[i]).governance() == tl, "governance");
            _check(IGovernedView(governed[i]).deployer() == address(0), "deployer power left");
        }
        _check(s.buybackReward.governance() == tl && s.grailFund.governance() == tl, "sink governance");
        _check(s.hook.governance() == tl, "hook governance");
        // references
        _check(s.hook.engine() == address(s.engine) && s.hook.launcher() == address(s.liquidity), "hook refs");
        _check(s.hook.treasury() == address(s.treasury) && address(s.hook.policy()) == address(s.swapPolicy), "hook refs 2");
        _check(s.liquidity.hook() == address(s.hook) && s.liquidity.isAdder(address(s.vault)), "liquidity refs");
        _check(s.swapPolicy.hook() == address(s.hook), "policy hook");
        _check(s.swapPolicy.exempt(address(s.buyer)) && s.swapPolicy.exempt(address(s.liquidity)), "exempt");
        _check(s.swapPolicy.feeBps() == c.hookFeeBps, "hook fee");
        _check(s.swapPolicy.snipeStartBps() == c.snipeStartBps && s.swapPolicy.snipeWindow() == c.snipeWindow, "snipe");
        _check(s.buyer.isCaller(address(s.game)) && s.buyer.isCaller(address(s.buybackBurn)), "buyer callers");
        _check(s.buyer.isCaller(address(s.buybackReward)), "buyer callers 2");
        _check(s.farm.isLedger(address(s.game)) && s.farm.isDepositor(address(s.buybackReward)), "farm refs");
        _check(address(s.farm.keeperFund()) == address(s.keeperFund), "farm keeper");
        _check(s.farm.genesisEpochs() == 21 && s.farm.EPOCH_BLOCKS() == 7_200, "genesis");
        _check(s.vault.activeGame() == address(s.game), "vault game");
        _check(address(s.vault.liquidity()) == address(s.liquidity), "vault liquidity");
        _check(address(s.game.vault()) == address(s.vault) && address(s.game.farm()) == address(s.farm), "game refs");
        _check(s.game.treasury() == address(s.treasury), "game treasury");
        _check(address(s.game.keeperFund()) == address(s.keeperFund), "game keeper");
        _check(address(s.game.buyer()) == address(s.buyer), "game buyer");
        _check(s.pricing.markupBps() == c.markupBps, "markup");
        _check(s.keeperFund.treasury() == address(s.treasury), "keeper treasury");
        for (uint256 i; i < 6; ++i) {
            address p = [address(s.game), address(s.treasury), address(s.buybackBurn), address(s.buybackReward), address(s.grailFund), address(s.farm)][i];
            _check(s.keeperFund.isPayer(p), "payer");
        }
        // treasury table
        _check(s.treasury.sinkCount() == 3, "sink count");
        (address a0, uint16 b0) = s.treasury.sinkAt(0);
        (address a1, uint16 b1) = s.treasury.sinkAt(1);
        (address a2, uint16 b2) = s.treasury.sinkAt(2);
        _check(a0 == address(s.buybackBurn) && b0 == c.burnBps, "sink 0");
        _check(a1 == address(s.buybackReward) && b1 == c.rewardBps, "sink 1");
        _check(a2 == address(s.grailFund) && b2 == c.grailBps, "sink 2");
        _check(uint256(b0) + b1 + b2 == 10_000, "table sum");
        // FWA pool
        if (c.createPool) {
            address pool = address(s.game.pool());
            _check(pool != address(0), "pool");
            _check(IOwnedView(pool).owner() == address(s.game), "pool owner");
            _check(IPurchaseView(pool).purchaseOperator() == address(0), "purchase operator");
        }
        // gate end follows genesis end (max before the game opens)
        _check(s.farm.genesisEndBlock() == (s.farm.openBlock() == 0 ? type(uint256).max : s.farm.openBlock() + 21 * 7_200), "gate end");
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
