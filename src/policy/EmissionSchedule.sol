// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEmissionSchedule} from "../interfaces/IDrawShapes.sol";

/// @title EmissionSchedule
/// @notice Launch genesis emission: 21 epochs tapering linearly from 1.5× the average epoch to 0.5×, same
///         total. `allocationOf(e, T) = T × (3(N−1) − 2e) / (2N(N−1))` for `e < N`, the last epoch taking the
///         rounding remainder so the 21 allocations sum to `T` exactly.
/// @dev A module. The farm snapshots an epoch's pot at its first claim and caps the snapshotted total at
///      the genesis budget, so a replacement schedule cannot change a settled epoch.
contract EmissionSchedule is IEmissionSchedule {
    uint256 public constant EPOCHS = 21;

    /// @inheritdoc IEmissionSchedule
    function allocationOf(uint256 epoch, uint256 total) public pure returns (uint256) {
        if (epoch >= EPOCHS) return 0;
        uint256 denom = 2 * EPOCHS * (EPOCHS - 1);
        if (epoch < EPOCHS - 1) return total * (3 * (EPOCHS - 1) - 2 * epoch) / denom;
        uint256 sum;
        for (uint256 e; e < EPOCHS - 1; ++e) {
            sum += total * (3 * (EPOCHS - 1) - 2 * e) / denom;
        }
        return total - sum;
    }
}
