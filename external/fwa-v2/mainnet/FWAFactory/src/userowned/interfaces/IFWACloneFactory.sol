// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Read-only factory surface consumed by user-owned FWA pool clones.
/// @dev `vrfCoordinator()` is deliberately the logical coordinator seen by every clone: the singleton
///      router/service. `chainlinkCoordinator()` is the mutable real Chainlink coordinator and is never
///      called directly by a clone.
interface IFWACloneFactory {
    struct PoolInitializationConfig {
        address coordinator;
        uint256 subId;
        bytes32 keyHash;
        uint32 gasLimit;
        uint16 confirmations;
        uint32 timeoutBlocks;
        uint16 activationLimit;
        uint16 acquisitionLimit;
        uint16 slippageBps;
        uint256 maxStagedListings;
        address protocolFeeRecipient;
    }

    function getPoolInitializationConfig() external view returns (PoolInitializationConfig memory config);
    function vrfCoordinator() external view returns (address);
    function chainlinkCoordinator() external view returns (address);
    function vrfSubscriptionId() external view returns (uint256);
    function vrfKeyHash() external view returns (bytes32);
    function callbackGasLimit() external view returns (uint32);
    function routerCallbackGasLimit() external view returns (uint32);
    function requestConfirmations() external view returns (uint16);
    function selectionTimeoutBlocks() external view returns (uint32);
    function maxActivationsPerAcquisition() external view returns (uint16);
    function maxAcquisitionsPerTx() external view returns (uint16);
    function selectionSlippageBps() external view returns (uint16);
    function maxStagedListings() external view returns (uint256);

    function edgeBps() external view returns (uint16);
    function inventoryChangeCooldown() external view returns (uint32);
    function buybackPurchaserBps() external view returns (uint16);
    function buybackOwnerBps() external view returns (uint16);
    function buybackProtocolBps() external view returns (uint16);
    function buybackPurchaserWindow() external view returns (uint32);
    function buybackFinalizationWindow() external view returns (uint32);
    function getBuybackTerms()
        external
        view
        returns (
            uint16 purchaserBps,
            uint16 ownerBps,
            uint16 protocolBps,
            uint32 purchaserWindow,
            uint32 finalizationWindow
        );
    function globalPurchasesEnabled() external view returns (bool);
    function globalWithdrawOnly() external view returns (bool);
    function poolCreationEnabled() external view returns (bool);
    function vrfSubscriptionActive() external view returns (bool);
    function vrfSubscriptionTerminated() external view returns (bool);
    function vrfRecoveryRecipient() external view returns (address);
    function vrfRequestsPaused() external view returns (bool);
    function consumerReady(address pool) external view returns (bool);
    function isPool(address pool) external view returns (bool);
    function protocolFeeRecipient() external view returns (address);
    function maxOutstandingRequestsPerPool() external view returns (uint256);
    function maxOutstandingRequestsGlobal() external view returns (uint256);
}

/// @notice Factory-only control and inspection surface implemented by the singleton VRF router/service.
/// @dev The factory intentionally has no generic executor and no wrapper around the consumer base's
///      `setCoordinator`. Only the old authenticated Chainlink coordinator may change that value during
///      an official subscription migration.
interface IFWACloneVRFServiceAdmin {
    function factory() external view returns (address);
    function coordinator() external view returns (address);
    function subscriptionId() external view returns (uint256);
    function approvedVrfKeyHash() external view returns (bytes32);
    function approvedCallbackGasLimit() external view returns (uint32);
    function routerCallbackGasLimit() external view returns (uint32);
    function requestConfirmations() external view returns (uint16);

    function owner() external view returns (address);
    function acceptOwnership() external;

    function subscriptionActive() external view returns (bool);
    function subscriptionTerminated() external view returns (bool);
    function requestsPaused() external view returns (bool);
    function registeredPool(address pool) external view returns (bool);
    function totalPrepared() external view returns (uint256);
    function totalCoordinatorOutstanding() external view returns (uint256);
    function minimumSubscriptionBuffer() external view returns (uint256);
    function maxFulfillmentCostWei() external view returns (uint256);
    function usedVrfKeyHash(bytes32 keyHash) external view returns (bool);

    function registerPool(address pool) external;
    function activateSubscription() external;
    function terminateSubscription(address payable recoveryRecipient) external returns (uint256 serviceEthRefund);
    function setVrfKeyHash(bytes32 keyHash) external;
    function syncPoolRequestConfig(address pool) external;
    function setRequestLimits(uint256 perPoolLimit, uint256 globalLimit) external;
    function setRequestsPaused(bool paused) external;
    function setFeeConfig(uint256 gasEstimate, uint256 marginBps, uint256 flatWei) external;
    function setCoverageConfig(uint256 minimumBuffer, uint256 maxFulfillmentCost) external;
    function setOperator(address operator, bool allowed) external;
    function setReimbursementConfig(
        uint256 sponsoredCount,
        uint256 reimbursementGas,
        uint256 gasOverhead,
        uint256 maxBaseFeeWei,
        uint256 maxPriorityFeeWei,
        uint256 reimbursementWei
    ) external;
    function withdrawSurplus(address recipient, uint256 amount) external;
}

/// @notice Pool configuration surface used by the singleton router/service when registering clones.
interface IFWACloneVRFHost {
    function processAcquisitions(uint256 maxCount) external returns (uint256 processed);
    function unfulfilledVrfCount() external view returns (uint256);
    function vrfCoordinatorAndSubId() external view returns (address coordinator, uint256 subId);
    function vrfRequestConfig() external view returns (bytes32 keyHash, uint32 gasLimit);
    function vrfService() external view returns (address);
    function configureVrfRequest(bytes32 keyHash, uint32 gasLimit) external;
}
