// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Callback of the controller of a foreign listing (`Pool.registerForeign`).
interface IForeignController {
    /// @notice Called with `proceeds` wei of ETH value when the FWA listing `listingId` of `tokenId`
    ///         is captured. The pool forwards at most `FOREIGN_CALL_GAS` gas. A revert leaves the
    ///         proceeds in the pool as `cash`.
    function onForeignCapture(uint256 listingId, uint256 tokenId, uint256 proceeds) external payable;
}
