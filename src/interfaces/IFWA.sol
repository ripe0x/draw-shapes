// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The subset of the FWA V2 standard pool (`FWAClone`, mainnet implementation
///         0xeaa4d032908a9734a2c7939c0d211c35ad51eb31) that Draw Shapes uses. Enum orders and the tuple
///         order of the public struct getters match `external/fwa-v2/mainnet/FWAClone`.
interface IFWAPool {
    struct ListingInput {
        address collection;
        uint256 tokenId;
        uint256 price;
    }

    enum ListingStatus {
        None,
        Active,
        Allocated,
        Withdrawn,
        Settled,
        Staged,
        DeliveryPending,
        DeliveryRefunded
    }

    enum AcquisitionStatus {
        None,
        Pending,
        Fulfilled,
        Expired,
        Refunded,
        Ready,
        TimedOut,
        DeliveryPending,
        DeliveryRefunded
    }

    function listNFTs(ListingInput[] calldata items) external returns (uint256[] memory listingIds);
    function withdrawListingsTo(uint256[] calldata listingIds, address recipient) external;
    function updatePrice(uint256 listingId, uint256 newPrice) external;
    function recoverRefundedNFT(uint256 listingId) external;
    function setBool(uint256 key, bool value) external;
    function retirePool() external;
    function withdrawOwnerProceeds() external returns (uint256 amount);
    function processAcquisitions(uint256 maxCount) external returns (uint256 processed);

    function acquire(
        address purchaser,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable returns (uint256 requestId);
    function acquireBatch(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable returns (uint256[] memory requestIds);
    function retryNFTDelivery(uint256 listingId) external;
    function refundFailedDelivery(uint256 listingId) external;
    function withdrawAcquisitionRefund() external returns (uint256 amount);

    function owner() external view returns (address);
    function retired() external view returns (bool);
    function localPurchasesEnabled() external view returns (bool);
    function purchaseOperator() external view returns (address);
    function vrfService() external view returns (address);
    function quoteAcquisitionPrice(uint256 count) external view returns (uint256 fee, uint256 vrf, uint256 total);
    function acquisitionFee() external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function weightedBackingTotal() external view returns (uint256);
    function activeListingCount() external view returns (uint256);
    function inventoryVersion() external view returns (uint256);
    function purchasesResumeAt() external view returns (uint256);
    function unsettledAcquisitionCount() external view returns (uint256);
    function lastIssuedSequence() external view returns (uint64);
    function nextSequenceToProcess() external view returns (uint64);
    function requestIdAtSequence(uint64 sequence) external view returns (uint256);
    function ownerProceeds() external view returns (uint256);
    function selectionSlippageBps() external view returns (uint256);
    function selectionTimeoutBlocks() external view returns (uint256);
    function slotToListing(uint256 slot) external view returns (uint256 listingId);
    function acquisitionRefundCredit(address purchaser) external view returns (uint256);

    function listings(uint256 listingId)
        external
        view
        returns (
            address collection,
            address depositor,
            address purchaser,
            uint256 tokenId,
            uint256 weight,
            uint256 price,
            uint256 slot,
            ListingStatus status
        );

    function acquisitions(uint256 requestId)
        external
        view
        returns (
            address purchaser,
            uint256 requestBlock,
            uint256 priceEscrowed,
            uint256 listingId,
            AcquisitionStatus status
        );

    function acquisitionMeta(uint256 requestId)
        external
        view
        returns (
            uint64 sequence,
            uint64 wordDeadlineBlock,
            uint64 rewardEpoch,
            uint16 maxPositiveSlippageBps,
            uint16 maxNegativeSlippageBps,
            uint256 randomWord
        );

    function pendingDeliveries(uint256 listingId) external view returns (uint256 requestId, uint64 deadline);
}

/// @notice The subset of the FWA V2 factory (mainnet 0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c) Draw Shapes uses.
interface IFWAFactory {
    function createPool(bytes32 userSalt, uint256 expectedCreationFee, address expectedImplementation)
        external
        returns (address pool);
    function poolCreationFee() external view returns (uint256);
    function fwaToken() external view returns (address);
    function implementation() external view returns (address);
    function edgeBps() external view returns (uint256);
    function globalWithdrawOnly() external view returns (bool);
    function globalPurchasesEnabled() external view returns (bool);
    function inventoryChangeCooldown() external view returns (uint256);
    function owner() external view returns (address);
    function setGlobalWithdrawOnly(bool enabled) external;
}

/// @dev `FWAConfigKeys.ACQUISITIONS_ENABLED`, the only key the pool's `setBool` accepts.
uint256 constant FWA_ACQUISITIONS_ENABLED = 41;
