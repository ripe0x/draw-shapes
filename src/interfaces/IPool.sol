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

    /// @dev Share of a deposit routed to the GRAIL buckets, in bps, between `floorBps` and
    ///      `capBps`. It targets `paybackDays` days of depositor yield.
    struct EntryFee {
        uint32 floorBps;
        uint32 capBps;
        uint32 paybackDays;
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

    /// @dev Reason `rotate` is due, in evaluation order. `None` when no reason holds. `Held` lists
    ///      queued replacements and held items while `settle` may not list.
    enum RotateTrigger {
        None,
        Claim,
        GrailStep,
        Held
    }

    /// @dev Reason `settle` lists replacements, in evaluation order. `None` when no reason holds.
    enum SettleTrigger {
        None,
        Batch,
        Age,
        Thin
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
        uint256 navCapFloor;
        uint16 turnoverBps;
        EntryFee entryFee;
        uint32 founderWindowSeconds;
        uint256 rotateInterval;
        uint256 openingDeadline;
        uint256 minItems;
        uint256 grailProbCapBps;
        uint256 batchMin;
        uint256 batchMaxAge;
        uint256 surpriseBps;
        uint256 restoreK;
        uint256 bandBps;
        uint256 reserveBps;
        uint256 tipWei;
    }

    error ZeroAddress();
    error ZeroAmount();
    error FeeSplitTooHigh();
    error MinorShareTooHigh();
    error EntryFeeOutOfRange();
    error TurnoverOutOfRange();
    error ListBpsOutOfRange();
    error GrailStepInvalid();
    error NotAdmin();
    error DepositsPaused();
    error NavCapReached();
    error DepositsClosed();
    error PoolExiting();
    error ZeroShares();
    error InsufficientShares();
    error GrailProbCapOutOfRange();
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
    error NotSelf();

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
    /// @dev Emitted when the booking walk advances. `nextSequenceToBook` is the new walk position.
    event Booked(uint64 nextSequenceToBook);
    /// @dev Emitted by `settle`. `listed` is the number of items listed and `refund` the wei paid to
    ///      the caller from `maintenance`.
    event Settled(uint256 listed, uint256 refund);
    event MaintenanceFunded(address indexed from, uint256 amount);
    event GrailFunded(address indexed from, uint8 indexed track, uint256 amount);
    /// @dev `chosenRow` is the row queued to replace the capture of `capturedRow`. `surprise` is true
    ///      when the surprise draw selected it.
    event ReplacementChosen(uint256 indexed requestId, uint256 capturedRow, uint256 chosenRow, bool surprise);
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
    function listingModule() external view returns (address);
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
    function entryFee() external view returns (uint32 floorBps, uint32 capBps, uint32 paybackDays);
    function navCapFloor() external view returns (uint256);
    function navCap() external view returns (uint256);
    function dailyVolume() external view returns (uint256);
    function turnoverBps() external view returns (uint16);
    function founderWindowSeconds() external view returns (uint32);
    function depositsOpenAt() external view returns (uint64);
    function rotateInterval() external view returns (uint256);
    function openingDeadline() external view returns (uint256);
    function openingDeadlineAt() external view returns (uint256);
    function minItems() external view returns (uint256);
    function grailProbCapBps() external view returns (uint256);
    function batchMin() external view returns (uint256);
    function batchMaxAge() external view returns (uint256);
    function surpriseBps() external view returns (uint256);
    function restoreK() external view returns (uint256);
    function bandBps() external view returns (uint256);
    function reserveBps() external view returns (uint256);
    function tipWei() external view returns (uint256);
    function listWhilePaused() external view returns (bool);
    function oldestQueuedAt() external view returns (uint256);
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
    function heldCount() external view returns (uint256);
    function heldShapes(uint8 denom) external view returns (uint256[] memory tokenIds);
    function mixRow(uint256 i) external view returns (uint8[] memory rungs, uint16 shareBps);
    function canImport(address collection, uint256 tokenId) external view returns (bool);

    // ------------------------------------------------------------------ Pool

    function createFwaPool(uint256 expectedFee) external;
    function open() external;
    function deposit() external payable;
    function withdraw(uint256 shares) external;
    function rotate() external;
    function rotateDue() external view returns (RotateTrigger);
    function settleDue() external view returns (SettleTrigger);
    function chooseRow(uint256 requestId, uint256 capturedRow) external view returns (uint256 row, bool surprise);
    /// @dev `PoolListing` entrypoints. Callable by the pool itself only.
    function listBatch(uint256 max) external returns (uint256 listed);
    function openBoard() external returns (uint256 listed);
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
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total);
    function canPurchase(address wallet) external view returns (bool);
    function pullWithShapes(uint256[] calldata tokenIds, uint256 count, uint256 maxFee, uint256 deadline)
        external
        payable;
    function redeemAndDeposit(uint256 tokenId) external;
    function settle(uint256 maxCount) external;
    function payClaims() external;
    function fundMaintenance() external payable;
    function fundGrail(uint8 t) external payable;
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4);

    // ------------------------------------------------------------------ PoolAdmin

    function setFeeSplit(uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps, uint16 minorShareBps) external;
    function setEntryFee(uint32 floorBps, uint32 capBps, uint32 paybackDays) external;
    function setNavCapFloor(uint256 wei_) external;
    function setTurnover(uint16 bps) external;
    function setFounderWindow(uint32 seconds_) external;
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
    function setBatch(uint256 batchMin_, uint256 batchMaxAge_) external;
    function setReplacement(uint256 surpriseBps_, uint256 restoreK_, uint256 bandBps_) external;
    function setReserve(uint256 reserveBps_) external;
    function setTip(uint256 tipWei_) external;
    function setListWhilePaused(bool on) external;
    function setPaused(bool pulls, bool deposits) external;
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
