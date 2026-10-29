// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../Governed.sol";
import {IBurnable} from "../interfaces/IDrawShapes.sol";

/// @title ProtocolLiquidity
/// @notice Opens the ETH/ENGINE Uniswap v4 pool and holds its protocol-owned liquidity. There is no function that
///         removes liquidity. The pool's LP fee is 0; the hook's ETH fee is its whole fee, so the positions earn nothing
///         to collect.
/// @dev `launch` (timelock, once) needs no ETH and accepts none (D50): it initialises the pool at `startTick`, fixed
///      at deployment (ENGINE per ETH; it sets the opening valuation and, through it, the genesis rate cap), and adds
///      every ENGINE held as one single-sided position over `[TICK_LOWER, startTick)`. As buyers pay ETH the price moves
///      down through it and the position becomes ETH-paired. The pool never holds more ENGINE than at the start, so the
///      price can never return above `startTick`: the ETH sellers can reach is exactly what buyers (and buybacks) put
///      in. ENGINE left over by liquidity rounding is burned. `addLiquidity` (an authorised adder: the vault on
///      shutdown, the timelock) buys ENGINE with about half the ETH, the swap capped at `maxImpactBps` and at the
///      caller's `minSqrtPriceX96`, then adds both full range; leftovers stay for the next addition. Outflows: only
///      into the pool positions (and the rounding burn).
contract ProtocolLiquidity is IUnlockCallback, ReentrancyGuard, Governed {
    using StateLibrary for IPoolManager;

    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;
    uint256 public constant MAX_IMPACT_BPS = 2_000;

    IPoolManager public immutable poolManager;
    address public immutable token;
    int24 public immutable startTick;
    address public hook;
    bool public launched;
    uint128 public totalLiquidity;
    uint256 public maxImpactBps;
    mapping(address => bool) public isAdder;

    event Launched(int24 startTick, uint256 tokens, uint128 liquidity);
    event LiquidityAdded(uint256 ethIn, uint256 ethSwapped, uint256 tokensBought, uint128 liquidity);
    event AdderSet(address indexed adder, bool allowed);
    event MaxImpactSet(uint256 bps);
    event HookSet(address hook);

    error NotAuthorized();
    error AlreadyLaunched();
    error NotLaunched();
    error NotPoolManager();
    error PriceLimit();
    error BadTick();

    enum Action {
        Seed,
        Add
    }

    constructor(address governance_, IPoolManager manager, address token_, uint256 maxImpactBps_, int24 startTick_)
        Governed(governance_, true)
    {
        if (address(manager) == address(0) || token_ == address(0)) revert ZeroAddress();
        if (startTick_ % TICK_SPACING != 0 || startTick_ <= TICK_LOWER + TICK_SPACING || startTick_ >= TICK_UPPER) {
            revert BadTick();
        }
        poolManager = manager;
        token = token_;
        startTick = startTick_;
        _setMaxImpact(maxImpactBps_);
    }

    /// @notice One-shot wiring by the deployer: the hook (mined after this contract exists) and the vault.
    function wire(address hook_, address vault_) external onlyWiring {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
        _setAdder(vault_, true);
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function sqrtPriceX96() public view returns (uint160 price) {
        (price,,,) = poolManager.getSlot0(poolKey().toId());
    }

    /// @notice Initialises the pool at `startTick` and adds every ENGINE held as one single-sided position below it.
    ///         Timelock, once. No ETH.
    function launch() external nonReentrant onlyGovernance returns (uint128 liquidity) {
        if (launched) revert AlreadyLaunched();
        launched = true;
        uint160 price = TickMath.getSqrtPriceAtTick(startTick);
        poolManager.initialize(poolKey(), price);
        uint256 tokens = SafeTransferLib.balanceOf(token, address(this));
        liquidity = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(TICK_LOWER), price, tokens);
        poolManager.unlock(abi.encode(Action.Seed, liquidity, uint256(0), uint160(0)));
        uint256 dust = SafeTransferLib.balanceOf(token, address(this));
        if (dust != 0) IBurnable(token).burn(dust);
        emit Launched(startTick, tokens - dust, liquidity);
    }

    /// @notice Adds `msg.value` plus any ETH and ENGINE already held to the protocol position.
    function addLiquidity(uint160 minSqrtPriceX96) external payable nonReentrant returns (uint128 liquidity) {
        if (!isAdder[msg.sender] && msg.sender != governance) revert NotAuthorized();
        if (!launched) revert NotLaunched();
        bytes memory r = poolManager.unlock(abi.encode(Action.Add, uint128(0), address(this).balance, minSqrtPriceX96));
        liquidity = abi.decode(r, (uint128));
    }

    /// @notice The lowest `sqrtPriceX96` the half-swap of `addLiquidity` may reach from `current`.
    function impactLimit(uint160 current) public view returns (uint160) {
        return uint160(uint256(current) * FPM.sqrt((10_000 - maxImpactBps) * 1e18 / 10_000) / 1e9);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, uint128 liquidity, uint256 ethIn, uint160 limit) =
            abi.decode(data, (Action, uint128, uint256, uint160));
        PoolKey memory key = poolKey();
        uint256 tokensBought;
        uint256 ethSwapped;
        if (action == Action.Add) {
            (uint160 before,,,) = poolManager.getSlot0(key.toId());
            uint160 floor = impactLimit(before);
            if (limit < floor) limit = floor;
            if (limit >= before || limit <= TickMath.MIN_SQRT_PRICE) revert PriceLimit();
            if (ethIn / 2 != 0) {
                // ETH in, ENGINE out: the price (ENGINE per ETH) falls; `limit` bounds how far.
                BalanceDelta s = poolManager.swap(
                    key,
                    SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn / 2), sqrtPriceLimitX96: limit}),
                    ""
                );
                ethSwapped = uint256(int256(-s.amount0()));
                tokensBought = uint256(int256(s.amount1()));
            }
            (uint160 p,,,) = poolManager.getSlot0(key.toId());
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                p,
                TickMath.getSqrtPriceAtTick(TICK_LOWER),
                TickMath.getSqrtPriceAtTick(TICK_UPPER),
                ethIn - ethSwapped,
                tokensBought + SafeTransferLib.balanceOf(token, address(this))
            );
        }
        BalanceDelta delta;
        if (liquidity != 0) {
            (delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: action == Action.Seed ? startTick : TICK_UPPER,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: 0
                }),
                ""
            );
            totalLiquidity += liquidity;
        }
        // Settle the combined debts of the swap and the position.
        int256 eth = int256(delta.amount0()) - int256(ethSwapped);
        int256 tok = int256(delta.amount1()) + int256(tokensBought);
        if (eth < 0) poolManager.settle{value: uint256(-eth)}();
        else if (eth > 0) poolManager.take(key.currency0, address(this), uint256(eth));
        if (tok < 0) {
            poolManager.sync(key.currency1);
            SafeTransferLib.safeTransfer(token, address(poolManager), uint256(-tok));
            poolManager.settle();
        } else if (tok > 0) {
            poolManager.take(key.currency1, address(this), uint256(tok));
        }
        if (action == Action.Add) emit LiquidityAdded(ethIn, ethSwapped, tokensBought, liquidity);
        return abi.encode(liquidity);
    }

    receive() external payable {}

    function setAdder(address adder, bool allowed) external onlyGovernance {
        _setAdder(adder, allowed);
    }

    function setMaxImpact(uint256 bps) external onlyGovernance {
        _setMaxImpact(bps);
    }

    function _setAdder(address adder, bool allowed) internal {
        if (adder == address(0)) revert ZeroAddress();
        isAdder[adder] = allowed;
        emit AdderSet(adder, allowed);
    }

    function _setMaxImpact(uint256 bps) internal {
        if (bps == 0 || bps > MAX_IMPACT_BPS) revert OutOfBounds();
        maxImpactBps = bps;
        emit MaxImpactSet(bps);
    }
}
