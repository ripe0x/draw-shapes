// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../Governed.sol";
import {IEngineBuyer} from "../interfaces/IDrawShapes.sol";

/// @title EngineBuyer
/// @notice The one place that knows how to buy ENGINE: an exact-ETH-input swap on the ETH/ENGINE v4 pool,
///         with the price move capped at `maxImpactBps` from the current price. Callers are registered by the
///         timelock (FwaGame for prize conversion, the buyback sinks). The swap's sender is this contract,
///         which the swap policy exempts from the fee and the buy gate, so only registered callers may use it.
/// @dev A module: it holds nothing between calls. Unspent ETH (when the impact cap stops the swap early) is
///      returned to the caller in the same call.
contract EngineBuyer is IEngineBuyer, IUnlockCallback, ReentrancyGuard, Governed {
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    int24 internal constant TICK_SPACING = 200;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable hook;
    mapping(address => bool) public isCaller;

    event CallerSet(address indexed caller, bool allowed);
    event Bought(address indexed caller, address indexed to, uint256 ethSpent, uint256 engineOut);

    error NotCaller();
    error NotPoolManager();
    error InsufficientOutput();

    constructor(address governance_, IPoolManager manager, address token_, address hook_) Governed(governance_, true) {
        if (address(manager) == address(0) || token_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        poolManager = manager;
        token = token_;
        hook = hook_;
    }

    /// @notice One-shot wiring by the deployer: the registered callers.
    function wire(address[] calldata callers) external onlyWiring {
        for (uint256 i; i < callers.length; ++i) {
            _setCaller(callers[i], true);
        }
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

    /// @inheritdoc IEngineBuyer
    function buy(uint256 minOut, address to, uint256 maxImpactBps)
        external
        payable
        nonReentrant
        returns (uint256 engineOut, uint256 ethSpent)
    {
        if (!isCaller[msg.sender]) revert NotCaller();
        if (maxImpactBps > BPS) maxImpactBps = BPS;
        (uint160 price,,,) = poolManager.getSlot0(poolKey().toId());
        uint160 limit = uint160(uint256(price) * FPM.sqrt((BPS - maxImpactBps) * 1e18 / BPS) / 1e9);
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        bytes memory r = poolManager.unlock(abi.encode(msg.value, limit, to));
        (engineOut, ethSpent) = abi.decode(r, (uint256, uint256));
        if (engineOut < minOut) revert InsufficientOutput();
        if (ethSpent < msg.value) SafeTransferLib.forceSafeTransferETH(msg.sender, msg.value - ethSpent);
        emit Bought(msg.sender, to, ethSpent, engineOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 ethIn, uint160 limit, address to) = abi.decode(data, (uint256, uint160, address));
        PoolKey memory key = poolKey();
        BalanceDelta d = poolManager.swap(
            key, SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: limit}), ""
        );
        uint256 spent = uint256(int256(-d.amount0()));
        uint256 out = uint256(int256(d.amount1()));
        if (spent != 0) poolManager.settle{value: spent}();
        if (out != 0) poolManager.take(key.currency1, to, out);
        return abi.encode(out, spent);
    }

    function setCaller(address caller, bool allowed) external onlyGovernance {
        _setCaller(caller, allowed);
    }

    function _setCaller(address caller, bool allowed) internal {
        if (caller == address(0)) revert ZeroAddress();
        isCaller[caller] = allowed;
        emit CallerSet(caller, allowed);
    }
}
