// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ABI subset of `FWAFactory` (mainnet 0xf5a3a153164791ab579c3d9ba5DBECf7cDfd300c) used by
///         ShapesPoolCore, the deploy script and the fork harness. See docs/external/fwa-v2.md EXT-01.
interface IFWACloneFactory {
    // ---- pool creation (msg.sender becomes the permanent pool owner)
    function createPool(bytes32 userSalt, uint256 expectedCreationFee) external returns (address pool);
    function createPool(bytes32 userSalt, uint256 expectedCreationFee, address expectedImplementation)
        external
        returns (address pool);
    function predictPoolAddress(address poolOwner, bytes32 userSalt) external view returns (address predicted);
    function poolCreationLimit(address wallet) external view returns (uint256);
    function remainingPoolAllowance(address wallet) external view returns (uint256 remaining);
    function poolCreationEnabled() external view returns (bool);
    function poolCreationFee() external view returns (uint256);
    function betaAccess() external view returns (bool);
    function BETA_ACCESS_ID() external view returns (uint32);
    function fwairPfps() external view returns (address);
    function maxPoolsPerWallet() external view returns (uint32);
    function fwaToken() external view returns (address);
    function isPool(address pool) external view returns (bool);
    function poolImplementation(address pool) external view returns (address implementationAddress);
    function consumerReady(address pool) external view returns (bool);
    function implementation() external view returns (address);
    function vrfService() external view returns (address);
    function owner() external view returns (address);

    // ---- parameters read live by every clone
    function edgeBps() external view returns (uint16);
    function inventoryChangeCooldown() external view returns (uint32);
    function globalPurchasesEnabled() external view returns (bool);
    function globalWithdrawOnly() external view returns (bool);
    function vrfRequestsPaused() external view returns (bool);
    function protocolFeeRecipient() external view returns (address);

    // ---- parameters snapshotted at clone init
    function selectionTimeoutBlocks() external view returns (uint32);
    function maxActivationsPerAcquisition() external view returns (uint16);
    function maxAcquisitionsPerTx() external view returns (uint16);
    function selectionSlippageBps() external view returns (uint16);
    function maxStagedListings() external view returns (uint256);
    function maxOutstandingRequestsPerPool() external view returns (uint256);
    /// @notice The VRF service's own cap on coordinator requests outstanding across every pool
    ///         it serves, mirrored onto the factory by `setRequestLimits` (`FWAFactory.sol`
    ///         `maxOutstandingRequestsGlobal`, around line 610 of the verified mainnet source).
    function maxOutstandingRequestsGlobal() external view returns (uint256);

    // ---- factory owner governance (fork harness pranks these)
    function setPoolCreationConfig(bool enabled, uint256 fee) external;
    function setBetaAccess(bool enabled) external;
    function setMaxPoolsPerWallet(uint32 newLimit) external;
    function setGlobalPurchasesEnabled(bool enabled) external;
    function setVrfRequestsPaused(bool paused) external;
    function setEdgeBps(uint16 newEdgeBps) external;
    function setInventoryChangeCooldown(uint32 newCooldown) external;
}

/// @notice Purchase policy hook called by the pool with the pool itself as `msg.sender`.
interface IPurchaseOperator {
    function canPurchase(address wallet) external view returns (bool allowed);
}

/// @notice The FWA VRF service the clone forwards VRF fees to. Fork tests impersonate it for
///         callbacks.
/// @dev `requestFee()` reads `tx.gasprice`, so a caller pricing it off-chain reproduces
///      `serviceGasEstimate * gasPriceWei * (BPS + serviceMarginBps) / BPS + serviceFlatWei`
///      (FWACloneVRFService.sol, verified source at the mainnet and Sepolia deployment addresses)
///      at the gas price it will send with, rather than reading `requestFee()` through an
///      `eth_call` at gas price zero. `serviceGasEstimate`, `serviceMarginBps` and `serviceFlatWei`
///      are owner-set (`setFeeConfig`, factory-gated) and can change; a caller that needs the exact
///      current fee reads them live rather than assuming the values observed at any one block.
///      `maxReimbursementBaseFeeWei` and `maxReimbursementPriorityFeeWei` bound a separate
///      mechanism, the reimbursement paid to whoever calls the sponsored processor, and play no
///      part in `requestFee()`.
interface IFWAVRFService {
    /// @dev Mirrors `FWACloneVRFService.RequestStatus` exactly (verified Sepolia source,
    ///      0xd2529DB53972C79acD7aa86A97Ad6E456c851620; mainnet bytecode differs only by network
    ///      constants). `WordStored`/`EmptyWordArrayStored` mean a delivery attempt has run and
    ///      left a result stored at the service, undelivered to the pool; `CoordinatorOutstanding`
    ///      means the coordinator callback has not landed at the service yet, or has landed and
    ///      the service missed it.
    enum RequestStatus {
        None,
        CoordinatorOutstanding,
        WordStored,
        EmptyWordArrayStored,
        Delivered,
        CoordinatorCallbackLost
    }

    function requestFee() external view returns (uint256);
    function prepareRequests(uint256 requestCount) external payable;
    function serviceGasEstimate() external view returns (uint256);
    function serviceMarginBps() external view returns (uint256);
    function serviceFlatWei() external view returns (uint256);
    function BPS() external view returns (uint256);
    /// @dev Factory-gated. The fork harness pranks the factory address to exercise a
    ///      reconfiguration the way FWA's own factory would trigger it.
    function setFeeConfig(uint256 gasEstimate, uint256 marginBps, uint256 flatWei) external;

    /// @notice A request's current status at the service (DEC-80 addendum 3).
    function requestStatus(uint256 requestId) external view returns (RequestStatus);
    /// @notice Coordinator requests a pool has outstanding right now: the count `prepareRequests`
    ///         checks against `maxOutstandingPerPool`, and what `reconcileCoordinatorRequest`
    ///         decrements when it releases a stuck one.
    function coordinatorOutstandingFor(address pool) external view returns (uint256);
    /// @notice Coordinator requests outstanding across every pool the service serves right now:
    ///         the count `prepareRequests` checks against `maxOutstandingRequestsGlobal`
    ///         (`FWAFactory.setRequestLimits`/`registerFactory` both read `service.
    ///         totalCoordinatorOutstanding()` to gate factory admin calls, the verified mainnet
    ///         `FWAFactory.sol` around lines 281 and 608; the service does not expose its own
    ///         source in this repo, so this signature is confirmed against the deployed
    ///         contract, not read from its source).
    function totalCoordinatorOutstanding() external view returns (uint256);
    /// @notice Retry delivery of a word already stored for `requestId` to its pool. Permissionless.
    function deliverRandomness(uint256 requestId) external returns (bool delivered);
    /// @notice Release a request whose real coordinator commitment is already consumed but whose
    ///         authenticated callback never stored a word here. Permissionless; reverts unless the
    ///         commitment has actually cleared.
    function reconcileCoordinatorRequest(uint256 requestId) external;
}
