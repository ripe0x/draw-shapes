// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IFWAClone} from "../../../src/interfaces/IFWAClone.sol";
import {IPool, IPoolTypes} from "../../../src/interfaces/IPool.sol";
import {IArtCoinsFactoryV2, IArtCoinsTokenV2} from "../../../src/interfaces/IArtcoins.sol";
import {EngineTreasury} from "../../../src/engine/EngineTreasury.sol";
import {FoundingRound} from "../../../src/engine/FoundingRound.sol";
import {EngineDeployer} from "../../../script/EngineDeployer.sol";
import {ForkBase} from "../ForkBase.sol";

/// @notice Swaps native ETH and an Artcoins coin on their v4 pool for a trader in the tests. A plain
///         router over the deployed PoolManager, like the v4-core `PoolSwapTest` the Artcoins suite
///         uses; it stands in for no deployed contract.
contract CoinSwapper is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(address pm_) {
        pm = IPoolManager(pm_);
    }

    /// @notice Spends exactly `msg.value` ETH on the coin. Returns the coin received.
    function buy(PoolKey memory key) external payable returns (uint256 out) {
        (, out) = abi.decode(pm.unlock(abi.encode(key, true, msg.value, msg.sender)), (uint256, uint256));
    }

    /// @notice Sells exactly `amount` of the coin, pulled from the caller. Returns the ETH received.
    function sell(PoolKey memory key, uint256 amount) external returns (uint256 out) {
        (, out) = abi.decode(pm.unlock(abi.encode(key, false, amount, msg.sender)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool buying, uint256 amount, address trader) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta d = pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: buying,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: buying ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 paid;
        uint256 out;
        if (buying) {
            paid = uint256(uint128(-d.amount0()));
            out = uint256(uint128(d.amount1()));
            pm.settle{value: paid}();
            pm.take(key.currency1, trader, out);
            if (amount > paid) payable(trader).transfer(amount - paid);
        } else {
            paid = uint256(uint128(-d.amount1()));
            out = uint256(uint128(d.amount0()));
            pm.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transferFrom(trader, address(pm), paid);
            pm.settle();
            pm.take(key.currency0, trader, out);
        }
        return abi.encode(paid, out);
    }

    receive() external payable {}
}

/// @notice Mainnet fork base for the engine: real Shapes, FWA V2, Artcoins v2 factory, hook, locker,
///         escrow and Uniswap v4 PoolManager at `ENGINE_FORK_BLOCK`. New contracts (Draw Packs, the
///         pool modules, the treasury, the round) are deployed from source through `EngineDeployer`,
///         the path the deploy script broadcasts.
/// @dev Two prank uses stand for actions the real owners take on mainnet, never for a replaced
///      contract: the Artcoins factory owner launches the coin (`deployTokenAsOwner`, the factory is
///      owner only), and a holder of FWA tokens transfers the 50,000 FWA pool creation fee to the pool.
abstract contract EngineBase is ForkBase, EngineDeployer {
    uint256 internal constant ENGINE_FORK_BLOCK = 26_240_000;
    uint256 internal constant TARGET = 20 ether;

    address internal owner = makeAddr("owner");
    address internal f1 = makeAddr("founder1");
    address internal f2 = makeAddr("founder2");
    address internal f3 = makeAddr("founder3");
    address internal player = makeAddr("player");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    Deployment internal d;
    IPool internal ip;
    IFWAClone internal clone;
    EngineTreasury internal treasury;
    FoundingRound internal round;
    IArtCoinsTokenV2 internal coin;
    PoolKey internal key;
    CoinSwapper internal swapper;
    uint256 internal wordNonce;

    function setUpEngine() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://mainnet.gateway.tenderly.co"));
        vm.createSelectFork(rpc, vm.envOr("ENGINE_FORK_BLOCK", ENGINE_FORK_BLOCK));
        deployDrawPacks(owner);
        d = _deployEngine(address(drawPacks), address(this), owner, TARGET);
        ip = IPool(address(d.pool));
        treasury = d.treasury;
        swapper = new CoinSwapper(POOL_MANAGER);
        vm.deal(trader, 1_000 ether);
        vm.deal(player, 1_000 ether);
    }

    // ------------------------------------------------------------------ launch steps

    function _openAndFundRound(uint256 target) internal {
        round = _openRound(owner, treasury, target);
        vm.prank(owner);
        treasury.setFoundingRound(round);
        _contribute(f1, target / 2);
        _contribute(f2, target * 3 / 10);
        _contribute(f3, target - target / 2 - target * 3 / 10);
    }

    function _contribute(address who, uint256 amount) internal {
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        round.contribute{value: amount}();
    }

    /// @dev The Artcoins owner launches ENGINE with `_coinConfig`, the coin admin locks its recipients
    ///      and the treasury owner binds the coin.
    function _launchCoin() internal {
        IArtCoinsFactoryV2 factoryV2 = IArtCoinsFactoryV2(ARTCOINS_FACTORY);
        IArtCoinsFactoryV2.DeploymentConfigV2 memory c =
            _coinConfig(address(treasury), owner, "Draw Shapes Engine", "ENGINE", bytes32(uint256(1)));
        address artOwner = factoryV2.owner();
        uint256 fee = factoryV2.deployFee();
        vm.deal(artOwner, artOwner.balance + fee);
        vm.prank(artOwner);
        coin = IArtCoinsTokenV2(factoryV2.deployTokenAsOwner{value: fee}(c, COIN_PROTOCOL_LOCKER_BPS));
        vm.prank(owner);
        (bool ok,) = address(coin).call(abi.encodeWithSignature("lockRecipients()"));
        require(ok, "lockRecipients");
        vm.prank(owner);
        treasury.setCoin(address(coin));
        key = treasury.poolKey();
    }

    /// @dev Pays the FWA pool creation fee into the pool from a real FWA holder. Returns the fee.
    function _fundFwaFee() internal returns (uint256 fee) {
        fee = factory.poolCreationFee();
        if (fee != 0) {
            vm.prank(factory.owner());
            IERC20(FWA_TOKEN).transfer(address(d.pool), fee);
        }
    }

    /// @dev Round funded, coin launched, treasury activated (which creates the FWA pool), board opened
    ///      and filled.
    function _launch() internal {
        _openAndFundRound(TARGET);
        _launchCoin();
        uint256 fee = _fundFwaFee();
        vm.prank(owner);
        treasury.activate(fee);
        clone = ip.fwaPool();
        vm.warp(ip.openingDeadlineAt());
        while (ip.lifecycle() == IPoolTypes.Lifecycle.Opening) ip.open();
        _settleBoard();
    }

    function _settleBoard() internal {
        for (uint256 i; i < 40 && ip.settleDue() != IPoolTypes.SettleTrigger.None; ++i) {
            vm.prank(keeper);
            ip.settle(20);
        }
    }

    // ------------------------------------------------------------------ play

    /// @dev `n` single pooled draws by `player`, each fulfilled with a fresh word and booked, with the
    ///      keeper settling and rotating between draws as a live keeper would.
    function _draws(uint256 n) internal returns (uint256 paid) {
        for (uint256 i; i < n; ++i) {
            warpPastCooldown(clone);
            (,, uint256 total) = clone.quoteAcquisitionPrice(1);
            uint256[] memory ids = acquirePooled(address(ip), clone, player, 1);
            paid += total;
            fulfill(clone, ids[0], uint256(keccak256(abi.encode("word", ++wordNonce))));
            vm.prank(keeper);
            ip.settle(20);
            if (i % 10 == 9) _keeperTick();
        }
        _keeperTick();
    }

    /// @dev Draws in batches of 50 until ordinary NAV is `amount` above the treasury's basis or
    ///      `maxDraws` were made. The opening board's mint fees are a loss the game earns back first.
    function _drawUntilEarnings(uint256 amount, uint256 maxDraws) internal returns (uint256 paid) {
        uint256 made;
        vm.pauseGasMetering();
        while (made < maxDraws && ip.nav() < treasury.basis() + amount) {
            paid += _draws(50);
            made += 50;
        }
        vm.resumeGasMetering();
        console2.log("draws made", made);
    }

    function _keeperTick() internal {
        vm.warp(vm.getBlockTimestamp() + 901);
        _settleBoard();
        if (ip.rotateDue() != IPoolTypes.RotateTrigger.None) {
            vm.prank(keeper);
            ip.rotate();
        }
    }

    // ------------------------------------------------------------------ market

    function _buy(address who, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(who);
        out = swapper.buy{value: ethIn}(key);
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        IERC20(address(coin)).approve(address(swapper), amount);
        vm.prank(who);
        out = swapper.sell(key, amount);
    }

    /// @dev Waits out the Artcoins anti sniper window so swaps pay the baseline skim.
    function _pastSniperWindow() internal {
        vm.warp(vm.getBlockTimestamp() + 3 hours + 1);
    }

    // ------------------------------------------------------------------ checks

    /// @dev Treasury solvency: its balance covers every booked bucket.
    function _assertTreasuryBooks() internal view {
        assertGe(address(treasury).balance, treasury.booked(), "treasury balance below booked buckets");
    }

    function _assertPoolI1() internal view {
        assertGe(address(d.pool).balance, ip.cash() + ip.maintenance() + ip.grail().fund, "pool I1");
    }

    function _wpunk(uint256 index, address to) internal returns (uint256 id) {
        id = IERC721Enumerable(WRAPPED_PUNKS).tokenByIndex(index);
        address holder = IERC721(WRAPPED_PUNKS).ownerOf(id);
        vm.prank(holder);
        IERC721(WRAPPED_PUNKS).transferFrom(holder, to, id);
    }
}
