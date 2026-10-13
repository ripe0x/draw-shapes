// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PricingLib} from "../lib/PricingLib.sol";
import {IFWAClone} from "./IFWAClone.sol";

/// @notice Types, errors and events of `Pool` and `PoolAdmin`, defined once for the shared storage
///         layout and for `IPool`.
interface IPoolTypes {
    enum Lifecycle {
        Opening,
        Live,
        Exiting,
        Exported
    }

    struct FeeSplit {
        uint16 premiumBps;
        uint16 maintenanceBps;
        uint16 feedBps;
        uint16 minorShareBps;
    }

    struct EntryCurve {
        uint32 baseBps;
        uint32 slopeBps;
        uint32 capBps;
        uint128 referenceWei;
    }

    struct GrailParams {
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
    }

    struct Grail {
        uint256 bucket;
        uint256 packId;
        uint256 backing;
        uint256 notional;
        uint256 targetWei;
        uint256 stepWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 floorWei;
        uint256 pullsSinceList;
        uint256 receivable;
        uint256 listingId;
    }

    struct Claim {
        address to;
        uint64 requestedAt;
        uint256 amount;
    }

    /// @dev An ordinary token owned or listed by the pool. `value` is its backing. `listingId` is
    ///      the FWA listing id, zero while the token is held unlisted.
    struct Item {
        address collection;
        uint16 row;
        uint256 tokenId;
        uint256 value;
        uint256 listingId;
    }

    /// @dev Pulls recorded in one clock hour. `hour` is `block.timestamp / 1 hours`.
    struct PullSlot {
        uint64 hour;
        uint192 count;
    }

    /// @dev Reason `rotate` is due, in evaluation order. `None` when no reason holds.
    enum RotateTrigger {
        None,
        Weight,
        GrailCap,
        Claim,
        GrailStep,
        Restock,
        Quiet
    }

    struct Params {
        address shapes;
        address drawPacks;
        address fwaFactory;
        address admin;
        address oldPool;
        PricingLib.MixRow[] mix;
        FeeSplit feeSplit;
        GrailParams minor;
        GrailParams major;
        uint256 navCap;
        EntryCurve curve;
        uint256 rotateInterval;
        uint256 openingDeadline;
        uint256 minItems;
        uint256 grailProbCapBps;
        uint256 repriceMinBps;
        uint256 restockTriggerBps;
        uint256 quietIntervalSeconds;
    }

    error ZeroAddress();
    error ZeroAmount();
    error FeeSplitTooHigh();
    error MinorShareTooHigh();
    error CurveCapTooHigh();
    error CurveReferenceZero();
    error ListBpsOutOfRange();
    error GrailStepInvalid();
    error NotAdmin();
    error DepositsPaused();
    error NavCapReached();
    error PoolExiting();
    error ZeroShares();
    error InsufficientShares();
    error GrailProbCapOutOfRange();
    error RepriceBpsOutOfRange();
    error RestockTriggerBpsOutOfRange();
    error NotOpening();
    error FwaPoolExists();
    error FwaPoolMissing();
    error OpeningDeadlineNotReached();
    error PackValueMismatch();
    error NotLive();
    error PullsPaused();
    error InvalidCount();
    error FeeAboveMax(uint256 fee, uint256 maxFee);
    error InsufficientValue(uint256 value, uint256 required);
    error PurchasesCoolingDown();
    error Insolvent();
    error BoardTooThin();
    error PurchaserMismatch();
    error UnknownListing(uint256 listingId);
    error BooksBehind();
    error NavZero();
    error RotateTooSoon();
    error RotateNotDue();
    error RedeemMismatch();
    error GrailNotReady();
    error FwaBusy();
    error NotExiting();
    error InvalidDest();
    error NotOldPool();
    error ImportClosed();
    error ImportNotFinal();
    error NoMatchingRow();
    error TokenNotReceived();
    error AlreadyMigrated();
    error GrailFloorInvalid();
    error LimitOutOfRange();
    error RowInUse();
    error Accounted();
    error InvariantBroken();
    error AdminValueMismatch();
    error ImportInProgress();
    error UseMigrateHolder();
    error AlreadyRegistered();
    error InvalidTrack();
    error NotDelegated();

    event Deposited(address indexed to, uint256 value, uint256 contribution, uint256 shares);
    event Withdrawn(address indexed from, uint256 shares, uint256 paidNow, uint256 enqueued);
    event ClaimPaid(address indexed to, uint256 amount);
    event FwaPoolCreated(address indexed pool);
    event Opened();
    event Pulled(address indexed purchaser, uint256 count, uint256 fee, uint256[] requestIds);
    event Captured(uint256 indexed requestId, uint256 indexed listingId, uint16 row, uint256 value, uint256 proceeds);
    event MarginSplit(uint256 mintLineCover, uint256 premiumShare, uint256 maintenanceShare, uint256 feedShare);
    event Harvested(uint256 received, uint256 surplus);
    /// @dev Emitted when FWA pays out `received` wei of owner proceeds, below the `expected` booked
    ///      receivables. The gap is written off the receivables before the harvest is credited.
    event HarvestShortfall(uint256 received, uint256 expected);
    event SurplusBooked(uint256 surplus);
    event Settled(uint64 nextSequenceToBook);
    event WrittenOff(uint256 indexed requestId, uint256 indexed listingId, uint256 value);
    /// @dev `fee` is the re-mint cost of the redeemed item's row: the mint fees of its Shapes. It is
    ///      deducted from the head claim and stays in `cash`, which funds the re-mint of the row for
    ///      the remaining holders. `listingId` is zero for a held item.
    event Liquidated(uint256 indexed listingId, uint256 value, uint256 fee);
    event Rotated(bool changed, bool inventoryChanged, uint256 refund);
    /// @dev `backing` is the track's backing after the step. `notional` is the list price after it.
    event GrailGrown(uint256 indexed track, uint256 packId, uint256 backing, uint256 notional);
    /// @dev Emitted when a track's pack is listed and when its list price decays.
    event GrailListed(uint256 indexed track, uint256 listingId, uint256 notional);
    /// @dev `proceeds` is zero for a write-off of a pending delivery.
    event GrailCaptured(uint256 indexed track, uint256 indexed requestId, uint256 proceeds);
    event ExitStarted(address indexed dest);
    /// @dev `nav` is `exportedNav`, `shares` is `exportedShares`.
    event Exported(uint256 shares, uint256 nav);
    event GrailEstateTransferred(uint256 indexed track, address indexed to, uint256 packId, uint256 bucket);
    event Imported(uint256 nav, uint256 shares);
    event Migrated(address indexed holder, uint256 shares);
    /// @dev Emitted by every admin setter. `selector` is the setter's function selector.
    event ParamSet(bytes4 selector);
}

/// @notice External interface of a pool: the functions of `Pool` and of `PoolAdmin`, which `Pool`
///         reaches through its `fallback`.
interface IPool is IPoolTypes {
    // ------------------------------------------------------------------ state getters

    function shapes() external view returns (address);
    function drawPacks() external view returns (address);
    function fwaFactory() external view returns (address);
    function oldPool() external view returns (address);
    function adminModule() external view returns (address);
    function admin() external view returns (address);
    function lifecycle() external view returns (Lifecycle);
    function pullsPaused() external view returns (bool);
    function depositsPaused() external view returns (bool);
    function cash() external view returns (uint256);
    function backing() external view returns (uint256);
    function receivable() external view returns (uint256);
    function claims() external view returns (uint256);
    function maintenance() external view returns (uint256);
    function maintenanceReceivable() external view returns (uint256);
    function grail(uint256 track)
        external
        view
        returns (
            uint256 bucket,
            uint256 packId,
            uint256 backing_,
            uint256 notional,
            uint256 targetWei,
            uint256 stepWei,
            uint256 listBps,
            uint256 decayWeiPerPull,
            uint256 floorWei,
            uint256 pullsSinceList,
            uint256 receivable_,
            uint256 listingId
        );
    function totalShares() external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function claimQueue(uint256 index) external view returns (address to, uint64 requestedAt, uint256 amount);
    function claimHead() external view returns (uint256);
    function feeSplit()
        external
        view
        returns (uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps, uint16 minorShareBps);
    function curve() external view returns (uint32 baseBps, uint32 slopeBps, uint32 capBps, uint128 referenceWei);
    function navCap() external view returns (uint256);
    function rotateInterval() external view returns (uint256);
    function openingDeadline() external view returns (uint256);
    function openingDeadlineAt() external view returns (uint256);
    function minItems() external view returns (uint256);
    function grailProbCapBps() external view returns (uint256);
    function repriceMinBps() external view returns (uint256);
    function restockTriggerBps() external view returns (uint256);
    function quietIntervalSeconds() external view returns (uint256);
    function ordinaryWeightSnapshot() external view returns (uint256);
    function fwaPool() external view returns (IFWAClone);
    function maxBatch() external view returns (uint256);
    function concurrency() external view returns (uint256);
    function replacementQueue(uint256 index) external view returns (uint16);
    function replacementHead() external view returns (uint256);
    function nextSequenceToBook() external view returns (uint64);
    function margin() external view returns (int256);
    function mintLineOwed() external view returns (uint256);
    function listedCount() external view returns (uint256);
    function lastRotateAt() external view returns (uint256);
    function lastRotateCallAt() external view returns (uint256);
    function lastRefundAt() external view returns (uint256);
    function exitDest() external view returns (address);
    function exportedShares() external view returns (uint256);
    function exportedNav() external view returns (uint256);
    function importedNav() external view returns (uint256);
    function importedShares() external view returns (uint256);
    function importedFromShares() external view returns (uint256);
    function migrated(address holder) external view returns (bool);
    function registered(address collection, uint256 tokenId) external view returns (bool);

    // ------------------------------------------------------------------ views

    function nav() external view returns (uint256);
    function rowCount(uint256 row) external view returns (uint256);
    function mixLength() external view returns (uint256);
    function listedRowCount(uint256 row) external view returns (uint256);
    function trailingPulls() external view returns (uint256 total);
    function mixRow(uint256 i) external view returns (uint8[] memory rungs, uint16 shareBps);
    function canImport(address collection, uint256 tokenId) external view returns (bool);

    // ------------------------------------------------------------------ Pool

    function createFwaPool(uint256 expectedFee) external;
    function open() external;
    function deposit() external payable;
    function withdraw(uint256 shares) external;
    function rotate() external;
    function rotateDue() external view returns (RotateTrigger);
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
    function quoteAcquisitionPrice(uint256 count) external view returns (uint256 fee, uint256 vrf, uint256 total);
    function canPurchase(address wallet) external view returns (bool);
    function pullWithShapes(uint256[] calldata tokenIds, uint256 count, uint256 maxFee, uint256 deadline)
        external
        payable;
    function redeemAndDeposit(uint256 tokenId) external;
    function settle(uint256 maxCount) external;
    function payClaims() external;
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4);

    // ------------------------------------------------------------------ PoolAdmin

    function setFeeSplit(uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps, uint16 minorShareBps) external;
    function setEntryCurve(uint32 baseBps, uint32 slopeBps, uint32 capBps, uint128 referenceWei) external;
    function setNavCap(uint256 wei_) external;
    function setMix(PricingLib.MixRow[] memory rows) external;
    function setGrail(
        uint8 t,
        uint256 targetWei,
        uint256 stepWei,
        uint256 listBps,
        uint256 decayWeiPerPull,
        uint256 floorWei
    ) external;
    function setMaxBatch(uint256 n) external;
    function setConcurrency(uint256 n) external;
    function setRotateInterval(uint256 seconds_) external;
    function setMinItems(uint256 n) external;
    function setGrailProbCap(uint256 bps) external;
    function setRepriceMinBps(uint256 bps) external;
    function setRestockTriggerBps(uint256 bps) external;
    function setQuietInterval(uint256 seconds_) external;
    function setPaused(bool pulls, bool deposits) external;
    function setPurchaseGate(bool on) external;
    function setAdmin(address newAdmin) external;
    function sweep(address token, uint256 id, address to) external;
    function adminCall(address target, bytes calldata data, uint256 value) external payable;
    function startExit(address dest) external;
    function exportStep(uint256 maxItems) external returns (bool);
    function transferGrailEstate(uint8 t, address to) external;
    function importItem(address collection, uint256 tokenId) external;
    function importGrail(uint8 t, uint256 packId) external payable;
    function importCash() external payable;
    function finalizeImport(uint256 fromShares) external;
    function migrateHolder(address holder) external;
}
