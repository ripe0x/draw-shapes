// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ABI subset of the FWA V2 standard custom pool (`FWAClone`) that ShapesPoolCore uses.
/// @dev Matches the Shapes-used subset of mainnet implementation
///      0xeaa4d032908A9734a2c7939c0D211c35ad51eb31 (docs/external/fwa-v2.md).
///      Enum orders must match the source exactly; getters for public mappings return tuples in
///      struct field order.
interface IFWAClone {
    struct InventoryInput {
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

    // ---- owner inventory
    function listNFT(address collection, uint256 tokenId, uint256 price) external returns (uint256 listingId);
    function listNFTs(InventoryInput[] calldata items) external returns (uint256[] memory listingIds);
    function MAX_INVENTORY_BATCH() external view returns (uint256);
    function withdrawListing(uint256 listingId) external;
    function withdrawListingTo(uint256 listingId, address recipient) external;
    function updatePrice(uint256 listingId, uint256 newPrice) external;
    function activateListings(uint256 maxCount) external;
    function recoverRefundedNFT(uint256 listingId) external;

    // ---- owner config
    function setBool(uint256 key, bool value) external;
    function setPurchaseOperator(address newOperator) external;
    function retirePool() external;
    function withdrawOwnerProceeds() external returns (uint256 amount);
    /// @dev Solady `Ownable.transferOwnership`, inherited unmodified; always reverts `OwnershipLocked`
    ///      because `_setOwner` is overridden to revert unconditionally (dossier fwa-v2.md section 1).
    function transferOwnership(address newOwner) external;

    // ---- purchases
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
    function processAcquisitions(uint256 maxCount) external returns (uint256 processed);
    function withdrawAcquisitionRefund() external returns (uint256 amount);
    function retryNFTDelivery(uint256 listingId) external;
    function refundFailedDelivery(uint256 listingId) external;
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;

    // ---- views
    function owner() external view returns (address);
    function IMPLEMENTATION_KIND() external view returns (uint8);
    function FACTORY() external view returns (address);
    function vrfService() external view returns (address);
    function purchaseOperator() external view returns (address);
    function retired() external view returns (bool);
    function localPurchasesEnabled() external view returns (bool);
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total);
    function quoteAcquisitionPrice(uint256 count)
        external
        view
        returns (uint256 fee, uint256 vrf, uint256 total);
    function acquisitionFee() external view returns (uint256);
    function vrfServiceFee() external view returns (uint256);
    function totalWeight() external view returns (uint256);
    function treeRootWeight() external view returns (uint256);
    function weightedBackingTotal() external view returns (uint256);
    function activeListingCount() external view returns (uint256);
    function inventoryVersion() external view returns (uint256);
    function lastInventoryChangeAt() external view returns (uint64);
    function purchasesResumeAt() external view returns (uint256);
    function unsettledAcquisitionCount() external view returns (uint256);
    function pendingAcquisitionCount() external view returns (uint256);
    function lastIssuedSequence() external view returns (uint64);
    function nextSequenceToProcess() external view returns (uint64);
    function requestIdAtSequence(uint64 sequence) external view returns (uint256);
    function ownerProceeds() external view returns (uint256);
    function accruedProtocolFees() external view returns (uint256);
    function acquisitionRefundCredit(address purchaser) external view returns (uint256);
    function selectionTimeoutBlocks() external view returns (uint32);
    function selectionSlippageBps() external view returns (uint16);
    function nextListingId() external view returns (uint256);

    /// @dev Listing struct: collection, depositor, purchaser, tokenId, weight, price, slot, status.
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

    /// @dev Acquisition struct: purchaser, requestBlock, priceEscrowed, listingId, status.
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

    /// @dev AcquisitionMeta struct: sequence, wordDeadlineBlock, rewardEpoch, maxPositiveSlippageBps,
    ///      maxNegativeSlippageBps, randomWord.
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

    /// @dev PendingDelivery struct: requestId, deadline.
    function pendingDeliveries(uint256 listingId) external view returns (uint256 requestId, uint64 deadline);
}

/// @dev `FWAConfigKeys.ACQUISITIONS_ENABLED`, the only key `setBool` accepts.
library FWAConfigKeys {
    uint256 internal constant ACQUISITIONS_ENABLED = 41;
}
