// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPurchaseOperator
/// @notice Optional pool-local policy hook that decides whether a wallet may start a new purchase.
/// @dev The calling pool is available as `msg.sender`, allowing one operator to serve multiple pools.
interface IPurchaseOperator {
    function canPurchase(address wallet) external view returns (bool allowed);
}
