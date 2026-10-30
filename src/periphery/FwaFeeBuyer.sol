// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IFWAToken {
    function poolKey() external view returns (PoolKey memory);
}

/// @title FwaFeeBuyer
/// @notice Deploy helper. Buys FWA with ETH on FWA's own Uniswap v4 pool and delivers it straight to
///         `recipient`. FWA is transfer-locked between wallets, but a PoolManager → recipient transfer under
///         the FWA hook's allowance is allowed, so this is how FwaGame receives the pool creation fee
///         (docs/IMPLEMENTOR_DECISIONS.md D4). Stateless; holds nothing.
contract FwaFeeBuyer is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable fwa;

    error NotPoolManager();
    error InsufficientOutput(uint256 out, uint256 minOut);

    constructor(IPoolManager manager, address fwa_) {
        poolManager = manager;
        fwa = fwa_;
    }

    /// @notice Spends all of `msg.value` buying FWA for `recipient`; reverts unless at least `minOut` arrives.
    function buyTo(address recipient, uint256 minOut) external payable returns (uint256 out) {
        uint256 prior = address(this).balance - msg.value; // ETH someone else left here is not this caller's
        uint256 before = SafeTransferLib.balanceOf(fwa, recipient);
        poolManager.unlock(abi.encode(recipient, msg.value));
        out = SafeTransferLib.balanceOf(fwa, recipient) - before;
        if (out < minOut) revert InsufficientOutput(out, minOut);
        uint256 left = address(this).balance - prior;
        if (left != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, left);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address recipient, uint256 ethIn) = abi.decode(data, (address, uint256));
        PoolKey memory key = IFWAToken(fwa).poolKey();
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        poolManager.settle{value: uint256(int256(-d.amount0()))}();
        poolManager.take(key.currency1, recipient, uint256(int256(d.amount1())));
        return "";
    }

    receive() external payable {}
}
