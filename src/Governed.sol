// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Timelock-only access for setters, plus the one-shot `wire` window of the deploying address.
/// @dev `governance` is the TimelockController. `deployer` may call functions guarded by `onlyWiring`
///      until `_finishWiring()` runs, after which it has no power (docs/IMPLEMENTOR_DECISIONS.md D18).
abstract contract Governed {
    address public immutable governance;
    address public deployer;

    error NotGovernance();
    error NotDeployer();
    error ZeroAddress();
    error OutOfBounds();

    event Wired();

    constructor(address governance_, bool needsWiring) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
        if (needsWiring) deployer = msg.sender;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyWiring() {
        if (msg.sender != deployer || msg.sender == address(0)) revert NotDeployer();
        _;
        deployer = address(0);
        emit Wired();
    }

    function wired() public view returns (bool) {
        return deployer == address(0);
    }
}
