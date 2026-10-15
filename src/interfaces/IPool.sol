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
    }

    /// @dev Share of a deposit routed to the GRAIL fund, in bps, between `floorBps` and
    ///      `capBps`. It targets `paybackDays` days of depositor yield.
    struct EntryFee {
        uint32 floorBps;
        uint32 capBps;
        uint32 paybackDays;
    }

    /// @dev Constructor and `setGrail` values. `targetWei` is the first cycle's target and seeds
    ///      `nextTargetWei`. Wei amounts follow the Shapes ladder: the target is 500, 1,000, 2,500,
    ///      5,000 or 10,000 units, a piece is 100 units.
    struct GrailParams {
        uint256 targetWei;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 pieceFloorWei;
        uint256 floorWei;
        uint32 stepUpSeconds;
        uint32 stepDownSeconds;
    }

    /// @dev The GRAIL fund and parameters. `fund` pays mints, `receivable` holds booked proceeds
    ///      of captured GRAIL items and the feed share until harvest credits them to `fund`.
    struct Grail {
        uint256 fund;
        uint256 receivable;
        uint256 targetWei;
        uint256 nextTargetWei;
        uint256 cycleId;
        uint256 listBps;
        uint256 decayWeiPerPull;
        uint256 pieceFloorWei;
        uint256 floorWei;
        uint64 pulls;
        uint64 cycleStartedAt;
        uint32 stepUpSeconds;
        uint32 stepDownSeconds;
    }

    /// @dev A GRAIL item owned by the pool: a piece, an intermediate, or a completed GRAIL.
    ///      `listingId` is the FWA listing id, zero while the item is unlisted. `done` marks the
    ///      completed GRAIL of a cycle, which is not an input to a merge. `listedAtPull` is
    ///      `Grail.pulls` when the item was last listed or repriced.
    struct GrailItem {
        address collection;
        bool done;
        uint256 tokenId;
        uint256 backing;
        uint256 notional;
        uint256 listingId;
        uint256 listedAtPull;
    }

    /// @dev A foreign listing: a token the pool did not mint, listed on the FWA pool for `controller`.
    ///      `listingId` is the FWA listing id the entry is keyed by. `notional` is the list price and
    ///      is zero while the token is held unlisted after a refunded delivery. `lastRepriceAt` is the
    ///      timestamp of the last `repriceForeign`, zero before the first.
    struct ForeignListing {
        address collection;
        uint256 tokenId;
        address controller;
        uint256 listingId;
        uint256 notional;
        uint64 lastRepriceAt;
    }

    /// @dev Proceeds of a captured foreign listing, booked in `foreignReceivable` and paid to
    ///      `controller` when the next harvest withdraws them from FWA.
    struct ForeignDue {
        address controller;
        uint256 listingId;
        uint256 tokenId;
        uint256 proceeds;
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
        Thin,
        Deep
    }

    struct Params {
        address shapes;
        address drawPacks;
        address fwaFactory;
        address admin;
        address oldPool;
        PricingLib.MixRow[] mix;
        FeeSplit feeSplit;
        GrailParams grail;
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
    error EntryFeeOutOfRange();
    error TurnoverOutOfRange();
    error ListBpsOutOfRange();
    error GrailTargetInvalid();
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
    error GrailItemsFull();
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
    error GrailStepInvalid();
    error LimitOutOfRange();
    error RowInUse();
    error Accounted();
    error InvariantBroken();
    error AdminValueMismatch();
    error ImportInProgress();
    error UseMigrateHolder();
    error AlreadyRegistered();
    error NotDelegated();
    error NotSelf();
    error ForeignFull();
    error NotController();
    error ListingNotActive(uint256 listingId);
    error ProbCapExceeded();
    error InsufficientGas();
    error PriceOutOfRange();
    error RepriceTooSmall();
    error RepriceTooSoon();
    error AdminCallDenied();

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
    /// @dev Emitted by `settle`. `reason` is the `SettleTrigger` value of `settleDue()` read after the
    ///      captures are booked, `listed` the number of items listed and `refund` the wei paid to the
    ///      caller from `maintenance`.
    event Settled(uint8 indexed reason, uint256 listed, uint256 refund);
    event MaintenanceFunded(address indexed from, uint256 amount);
    event GrailFunded(address indexed from, uint256 amount);
    /// @dev `rotate` skipped the GRAIL step because it reverted. `selector` is the first four bytes of the revert data.
    event GrailStepSkipped(bytes4 selector);
    /// @dev `chosenRow` is the row queued to replace the capture of `capturedRow`. `surprise` is true
    ///      when the surprise draw selected it.
    event ReplacementChosen(uint256 indexed requestId, uint256 capturedRow, uint256 chosenRow, bool surprise);
    event WrittenOff(uint256 indexed requestId, uint256 indexed listingId, uint256 value);
    /// @dev `fee` is the re-mint cost of the redeemed item's row: the mint fees of its Shapes. It is
    ///      deducted from the head claim and stays in `cash`, which funds the re-mint of the row for
    ///      the remaining holders. `listingId` is zero for a held item.
    event Liquidated(uint256 indexed listingId, uint256 value, uint256 fee);
    event Rotated(bool changed, bool inventoryChanged, uint256 refund);
    /// @dev `quantity` pieces were minted from the GRAIL fund for `cost` wei, the backing plus mint
    ///      fees. The token ids are consecutive from `firstTokenId`.
    event GrailMinted(uint256 indexed firstTokenId, uint256 quantity, uint256 cost);
    /// @dev Emitted when a GRAIL item is listed and when its list price changes.
    event GrailListed(
        uint256 indexed listingId, address collection, uint256 tokenId, uint256 backing, uint256 notional
    );
    /// @dev `inputs` GRAIL items were combined into `tokenId` of `backing`. `completed` is true when
    ///      the output closed the cycle.
    event GrailMerged(uint256 indexed tokenId, uint256 backing, uint256 inputs, bool completed);
    /// @dev Emitted when a cycle completes. `nextTargetWei` is the target of the cycle that starts.
    event GrailCycleCompleted(uint256 indexed cycleId, uint256 nextTargetWei);
    /// @dev `proceeds` is zero for a write-off of a pending delivery.
    event GrailCaptured(uint256 indexed requestId, uint256 indexed listingId, uint256 backing, uint256 proceeds);
    event ForeignRegistered(
        address indexed collection, uint256 indexed tokenId, address indexed controller, uint256 listingId, uint256 price
    );
    event RegistrarSet(address indexed registrar);
    event ForeignRepriced(uint256 indexed listingId, uint256 price);
    /// @dev `to` is the recipient of the token. `exportStep` withdraws to the entry's controller.
    event ForeignWithdrawn(uint256 indexed listingId, address indexed collection, uint256 tokenId, address to);
    /// @dev `delivered` is true when the controller's `onForeignCapture` call succeeded. Otherwise
    ///      `proceeds` joined `cash` as margin. `proceeds` is zero for a capture whose request was
    ///      opened directly at the FWA pool and for a write-off of a pending delivery.
    event ForeignCaptured(uint256 indexed listingId, uint256 tokenId, uint256 proceeds, bool delivered);
    /// @dev `exportStep` could not withdraw or transfer the token of a foreign listing. The entry is
    ///      removed and the token is unregistered. `sweep` sends it to the controller once the pool holds it.
    event ForeignReleaseFailed(uint256 indexed listingId, uint256 tokenId);
    event ExitStarted(address indexed dest);
    /// @dev `nav` is `exportedNav`, `shares` is `exportedShares`.
    event Exported(uint256 shares, uint256 nav);
    event GrailEstateTransferred(address indexed to, uint256 fund, uint256 items);
    event Imported(uint256 nav, uint256 shares);
    event Migrated(address indexed holder, uint256 shares);
    /// @dev Emitted by every admin setter. `selector` is the setter's function selector.
    event ParamSet(bytes4 selector);
}

/// @notice External interface of a pool: the functions of `Pool` and of the modules `Pool` reaches
///         through its `fallback`. `PoolListing` serves the listing and GRAIL entrypoints, `setGrail`,
///         `setGrailStep`, `setGrailTarget`, `grail`, `grailItems`, `boardItems`, `chooseRow` and the
///         getters of parameters, rows, queues, held Shapes, migration state and the `margin` and
///         `mintLineOwed` buckets that have no state getter in `Pool`. `PoolAdmin` serves the other
///         admin, exit and import functions.
interface IPool is IPoolTypes {
    // ------------------------------------------------------------------ state getters

    function shapes() external view returns (address);
    function drawPacks() external view returns (address);
    function fwaFactory() external view returns (address);
    function oldPool() external view returns (address);
    function adminModule() external view returns (address);
    function listingModule() external view returns (address);
    function admin() external view returns (address);
    function registrar() external view returns (address);
    function lifecycle() external view returns (Lifecycle);
    function pullsPaused() external view returns (bool);
    function depositsPaused() external view returns (bool);
    function cash() external view returns (uint256);
    function backing() external view returns (uint256);
    function receivable() external view returns (uint256);
    function claims() external view returns (uint256);
    function maintenance() external view returns (uint256);
    function maintenanceReceivable() external view returns (uint256);
    function grail() external view returns (Grail memory);
    function grailItems() external view returns (GrailItem[] memory);
    function foreignListings() external view returns (ForeignListing[] memory);
    function totalShares() external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function claimQueue(uint256 index) external view returns (address to, uint64 requestedAt, uint256 amount);
    function claimHead() external view returns (uint256);
    function feeSplit() external view returns (uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps);
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
    function boardItems() external view returns (uint256);
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
    /// @dev `row` is `type(uint256).max` when no row is below its target and the capture is not replaced.
    function chooseRow(uint256 requestId, uint256 capturedRow) external view returns (uint256 row, bool surprise);
    /// @dev `PoolListing` entrypoints. Callable by the pool itself only, except the view
    ///      `grailReady`.
    function listBatch(uint256 max) external returns (uint256 listed);
    function openBoard() external returns (uint256 listed);
    function queueMissing(uint256 cap) external;
    function grailStep() external returns (bool changed);
    function grailReprice() external returns (bool changed);
    function grailReady() external view returns (bool);
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
    function fundGrail() external payable;
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4);

    // ------------------------------------------------------------------ PoolAdmin

    function setFeeSplit(uint16 premiumBps, uint16 maintenanceBps, uint16 feedBps) external;
    function setEntryFee(uint32 floorBps, uint32 capBps, uint32 paybackDays) external;
    function setNavCapFloor(uint256 wei_) external;
    function setTurnover(uint16 bps) external;
    function setFounderWindow(uint32 seconds_) external;
    function setMix(PricingLib.MixRow[] memory rows) external;
    function setGrail(uint256 decayWeiPerPull, uint256 pieceFloorWei, uint256 floorWei, uint256 listBps) external;

    /// @notice Sets the ladder step thresholds. `stepUpSeconds` is below `stepDownSeconds`.
    function setGrailStep(uint32 stepUpSeconds, uint32 stepDownSeconds) external;
    function setGrailTarget(uint256 targetWei) external;
    /// @dev `PoolListing` entrypoints for foreign listings. `registerForeign` is the admin's or the registrar's, the
    ///      other two are the entry's controller's.
    function registerForeign(address collection, uint256 tokenId, address controller, uint256 priceWei) external;
    function repriceForeign(uint256 listingId, uint256 priceWei) external;
    function withdrawForeign(uint256 listingId, address to) external;
    function setRegistrar(address registrar_) external;
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
    function transferGrailEstate(address to) external;
    function importItem(address collection, uint256 tokenId) external;
    function importGrail(address collection, uint256 tokenId, bool done) external payable;
    function importCash() external payable;
    function finalizeImport(uint256 fromShares) external;
    function migrateHolder(address holder) external;
}
