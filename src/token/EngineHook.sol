// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ISwapPolicy} from "../interfaces/IDrawShapes.sol";

/// @title EngineHook
/// @notice Uniswap v4 hook of the ETH/ENGINE pool. On every swap it asks the `SwapPolicy` module whether the
///         swap is allowed and what fee to charge, and takes that fee from the ETH side straight to the
///         Treasury. It holds nothing.
/// @dev Rigid on purpose (the trust surface): the fee caps, sells always allowed, exact-output sells rejected,
///      fee placement, and the one-time initialisation by ProtocolLiquidity. Fee placement, all in ETH
///      (currency0):
///      - buy, exact input: `beforeSwap` takes the fee out of the ETH input;
///      - buy, exact output: `afterSwap` adds the fee to the ETH the swapper pays;
///      - sell, exact input: `afterSwap` takes the fee out of the ETH output;
///      - sell, exact output: reverts `ExactOutputSellUnsupported`.
///      The fee is capped at `MAX_FEE_BPS`, except within `LAUNCH_WINDOW` of initialisation, where the
///      anti-snipe fee may reach `MAX_LAUNCH_FEE_BPS`. A policy can block buys; it can never block a sell:
///      a disallowed or reverting policy answer on a sell proceeds with the capped fee, or no fee.
contract EngineHook is BaseHook {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant MAX_LAUNCH_FEE_BPS = 9_500;
    uint256 public constant LAUNCH_WINDOW = 3 hours;
    int24 public constant TICK_SPACING = 200;

    address public immutable engine;
    address public immutable launcher;
    address public immutable treasury;
    address public immutable governance;

    ISwapPolicy public policy;
    uint64 public launchedAt;

    event PolicySet(address policy);
    event FeeTaken(address indexed sender, bool buy, uint256 fee);

    error NotGovernance();
    error NotLauncher();
    error AlreadyInitialized();
    error WrongPool();
    error ExactOutputSellUnsupported();
    error SwapNotAllowed();
    error ZeroAddress();

    constructor(
        IPoolManager manager,
        address engine_,
        address launcher_,
        address treasury_,
        address governance_,
        address policy_
    ) BaseHook(manager) {
        if (
            engine_ == address(0) || launcher_ == address(0) || treasury_ == address(0) || governance_ == address(0)
                || policy_ == address(0)
        ) revert ZeroAddress();
        engine = engine_;
        launcher = launcher_;
        treasury = treasury_;
        governance = governance_;
        policy = ISwapPolicy(policy_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setPolicy(address policy_) external {
        if (msg.sender != governance) revert NotGovernance();
        if (policy_ == address(0)) revert ZeroAddress();
        policy = ISwapPolicy(policy_);
        emit PolicySet(policy_);
    }

    /// @notice The fee cap in force now.
    function feeCap() public view returns (uint256) {
        return launchedAt != 0 && block.timestamp < uint256(launchedAt) + LAUNCH_WINDOW ? MAX_LAUNCH_FEE_BPS : MAX_FEE_BPS;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != launcher) revert NotLauncher();
        if (launchedAt != 0) revert AlreadyInitialized();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != engine || key.fee != 0
                || key.tickSpacing != TICK_SPACING
        ) revert WrongPool();
        launchedAt = uint64(block.timestamp);
        return BaseHook.beforeInitialize.selector;
    }

    /// @dev Policy answer for this swap with the hook's rules applied: buys may be refused; sells never.
    function _fee(address sender, bool isBuy) internal view returns (uint256 feeBps) {
        bool allowed;
        try policy.check(sender, isBuy) returns (bool a, uint256 f) {
            allowed = a;
            feeBps = f;
        } catch {
            if (isBuy) revert SwapNotAllowed();
            return 0;
        }
        if (isBuy && !allowed) revert SwapNotAllowed();
        uint256 cap = feeCap();
        if (feeBps > cap) feeBps = cap;
    }

    function _beforeSwap(address sender, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        if (!params.zeroForOne && !exactIn) revert ExactOutputSellUnsupported();
        uint256 feeBps = _fee(sender, params.zeroForOne);
        assembly ("memory-safe") {
            tstore(0, add(feeBps, 1))
        }
        if (!params.zeroForOne || !exactIn) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // Buy with exact ETH input: the fee is part of the input; the rest is swapped.
        uint256 fee = uint256(-params.amountSpecified) * feeBps / BPS;
        if (fee != 0) {
            poolManager.take(Currency.wrap(address(0)), treasury, fee);
            emit FeeTaken(sender, true, fee);
        }
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _afterSwap(address sender, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint256 feeBps;
        assembly ("memory-safe") {
            feeBps := sub(tload(0), 1)
            tstore(0, 0)
        }
        bool exactIn = params.amountSpecified < 0;
        uint256 fee;
        if (params.zeroForOne && !exactIn) {
            // Buy with exact ENGINE output: the fee is added to the ETH paid.
            fee = uint256(int256(-delta.amount0())) * feeBps / BPS;
        } else if (!params.zeroForOne && exactIn) {
            // Sell with exact ENGINE input: the fee comes out of the ETH output.
            fee = uint256(int256(delta.amount0())) * feeBps / BPS;
        }
        if (fee != 0) {
            poolManager.take(Currency.wrap(address(0)), treasury, fee);
            emit FeeTaken(sender, params.zeroForOne, fee);
        }
        return (BaseHook.afterSwap.selector, int128(int256(fee)));
    }
}
