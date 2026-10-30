// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice A plain public router for tests: any user swapping through it is an ordinary, non-exempt sender.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable pm;
    PoolKey internal _key;

    constructor(IPoolManager pm_, PoolKey memory key_) {
        pm = pm_;
        _key = key_;
    }

    /// @dev Buy ENGINE with exact ETH input (`exactOut` false) or for an exact ENGINE output.
    function buy(uint256 amount, bool exactOut) external payable returns (uint256 ethIn, uint256 engineOut) {
        (ethIn, engineOut) = abi.decode(pm.unlock(abi.encode(msg.sender, true, amount, exactOut)), (uint256, uint256));
        if (address(this).balance != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, address(this).balance);
    }

    /// @dev Sell exact ENGINE input (or, for the revert test, exact ETH output). Caller approves first.
    function sell(uint256 amount, bool exactOut) external returns (uint256 engineIn, uint256 ethOut) {
        (engineIn, ethOut) = abi.decode(pm.unlock(abi.encode(msg.sender, false, amount, exactOut)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address user, bool isBuy, uint256 amount, bool exactOut) = abi.decode(data, (address, bool, uint256, bool));
        int256 specified = exactOut ? int256(amount) : -int256(amount);
        BalanceDelta d = pm.swap(
            _key,
            SwapParams({
                zeroForOne: isBuy,
                amountSpecified: specified,
                sqrtPriceLimitX96: isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        if (isBuy) {
            pm.settle{value: uint256(int256(-a0))}();
            pm.take(_key.currency1, user, uint256(int256(a1)));
            return abi.encode(uint256(int256(-a0)), uint256(int256(a1)));
        }
        pm.sync(_key.currency1);
        SafeTransferLib.safeTransferFrom(Currency.unwrap(_key.currency1), user, address(pm), uint256(int256(-a1)));
        pm.settle();
        pm.take(_key.currency0, user, uint256(int256(a0)));
        return abi.encode(uint256(int256(-a1)), uint256(int256(a0)));
    }

    receive() external payable {}
}
