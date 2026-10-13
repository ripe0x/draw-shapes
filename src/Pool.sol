// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IShapes} from "shapes/interfaces/IShapes.sol";
import {Denominations} from "shapes/lib/Denominations.sol";
import {IShapePacks} from "draw-packs/interfaces/IShapePacks.sol";
import {IERC721Value} from "shapes/interfaces/IERC721Value.sol";
import {PricingLib} from "./lib/PricingLib.sol";
import {IFWAClone, FWAConfigKeys} from "./interfaces/IFWAClone.sol";
import {IFWACloneFactory} from "./interfaces/IFWACloneFactory.sol";

/// @title Pool
/// @notice Depositors hold nontransferable shares of ordinary NAV. ETH held by the pool is
///         accounted in buckets: `cash`, `backing`, `receivable`, `claims`, `maintenance` and, per
///         GRAIL track, `grail[t].bucket` and `grail[t].backing`.
/// @dev Ordinary NAV = `cash + backing + receivable - claims`. GRAIL buckets and GRAIL backing are
///      outside ordinary NAV. A deposit routes an entry contribution to the two GRAIL buckets and
///      mints shares for the remainder at NAV before the deposit. A withdrawal burns shares and
///      pays `min(claim, cash)` at once. The remainder is booked in `claims` and appended to
///      `claimQueue`, which is paid in request order from `cash`.
///
///      `claims` is the unpaid part of withdrawn shares. It reduces NAV and is paid from `cash`
///      as `cash` is replenished by deposits and by backing turning into ETH.
///
///      Invariant I1: `address(this).balance >= cash + maintenance + grail[0].bucket +
///      grail[1].bucket`. ETH received outside the accounted paths raises the balance and stays
///      unaccounted, so I1 is an inequality.
///
///      Exit: `startExit(dest)` closes pulls, deposits, rotation and GRAIL growth. `exportStep` moves
///      ordinary items in bounded steps, and GRAIL tracks on migration, then records
///      `exportedShares` and `exportedNav` and sets Exported. A successor imports through functions
///      restricted to its `oldPool` and mints holder shares with `migrateHolder`.
///
///      Tracks are indexed `MINOR = 0` and `MAJOR = 1`. Share, claim and bucket amounts are in wei.
contract Pool is ReentrancyGuard {
    // ------------------------------------------------------------------ types

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
    }

    // ------------------------------------------------------------------ errors

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
    error ClaimNotDue();
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
    error GrailProbTooHigh();
    error UnknownListing(uint256 listingId);
    error HarvestShortfall(uint256 received, uint256 expected);
    error BooksBehind();
    error NavZero();
    error RotateTooSoon();
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
    error GrailOccupied();
    error AlreadyMigrated();

    // ------------------------------------------------------------------ events

    event Deposited(address indexed to, uint256 value, uint256 contribution, uint256 shares);
    event Withdrawn(address indexed from, uint256 shares, uint256 paidNow, uint256 enqueued);
    event ClaimPaid(address indexed to, uint256 amount);
    event FwaPoolCreated(address indexed pool);
    event Opened();
    event Pulled(address indexed purchaser, uint256 count, uint256 fee, uint256[] requestIds);
    event Captured(uint256 indexed requestId, uint256 indexed listingId, uint16 row, uint256 value, uint256 proceeds);
    event MarginSplit(uint256 mintLineCover, uint256 premiumShare, uint256 maintenanceShare, uint256 feedShare);
    event Harvested(uint256 received, uint256 surplus);
    event SurplusBooked(uint256 surplus);
    event Settled(uint64 nextSequenceToBook);
    event WrittenOff(uint256 indexed requestId, uint256 indexed listingId, uint256 value);
    /// @dev `fee` is the amount deducted from the head claim for the mint fees of the redeemed Shapes.
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

    // ------------------------------------------------------------------ constants and immutables

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_CLAIM_ITEMS = 20;
    uint256 internal constant MINOR = 0;
    uint256 internal constant MAJOR = 1;
    uint256 internal constant MAX_FEE_SPLIT_BPS = 1_000;
    uint256 internal constant MAX_CURVE_CAP_BPS = 2_500;
    uint256 internal constant MAX_MINTS_PER_RESTOCK = 20;
    uint256 internal constant PULL_SLOTS = 5;
    uint256 internal constant SETTLE_BUDGET = 3;
    uint256 internal constant MAX_SETTLE_ITEMS = 20;
    uint256 internal constant MAX_LIQUIDATE_ITEMS = 10;
    /// @dev Added to the refund of every `rotate` that changed state.
    uint256 internal constant ROTATE_TIP = 0.0005 ether;
    /// @dev Intrinsic transaction gas plus the refund transfer, added to the measured gas.
    uint256 internal constant ROTATE_GAS_OVERHEAD = 30_000;

    address public immutable shapes;
    address public immutable drawPacks;
    address public immutable fwaFactory;
    /// @notice Pool this one succeeds, or zero. Only `oldPool` may call the import functions.
    address public immutable oldPool;

    // ------------------------------------------------------------------ storage

    address public admin;
    Lifecycle public lifecycle;
    bool public pullsPaused;
    bool public depositsPaused;
    bool internal importFinalized;

    uint256 public cash;
    uint256 public backing;
    uint256 public receivable;
    uint256 public claims;
    uint256 public maintenance;
    /// @notice Maintenance share of booked margin, still held as FWA owner proceeds.
    uint256 public maintenanceReceivable;
    Grail[2] public grail;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    Claim[] public claimQueue;
    uint256 public claimHead;

    PricingLib.MixRow[] internal _mix;
    FeeSplit public feeSplit;
    EntryCurve public curve;
    uint256 public navCap;
    uint256 public rotateInterval;
    /// @notice Duration in seconds from FWA pool creation to the earliest `open()`.
    uint256 public openingDeadline;
    uint256 public openingDeadlineAt;
    uint256 public minItems;
    uint256 public grailProbCapBps;

    IFWAClone public fwaPool;
    uint256 public maxBatch;
    uint256 public concurrency;

    /// @dev Backing of one token of each row, indexed like `_mix`.
    uint256[] internal _rowBackingWei;
    /// @dev Listed plus held ordinary items per row.
    uint256[] internal _rowCount;
    mapping(uint256 listingId => Item) internal _listed;
    Item[] internal _held;

    /// @notice FIFO of row indices awaiting a replacement mint.
    uint16[] public replacementQueue;
    uint256 public replacementHead;

    PullSlot[PULL_SLOTS] internal _pullSlots;

    /// @dev `base + 1` of each pull request id, where `base` is the FWA base price at request time.
    ///      Zero marks a request opened outside `pull`.
    mapping(uint256 requestId => uint256) internal _basePlusOne;
    /// @notice First FWA acquisition sequence the pool has not yet booked.
    uint64 public nextSequenceToBook;
    /// @notice Booked proceeds minus captured backing, netted across captures. Positive margin is
    ///         split at once, negative margin carries forward.
    int256 public margin;
    /// @notice Replacement mint fees of captured items, covered by margin before it is split.
    uint256 public mintLineOwed;
    /// @notice Listed ordinary items.
    uint256 public listedCount;
    /// @notice Timestamp of the last `rotate` that changed inventory, or of `open()` going Live.
    uint256 public lastRotateAt;
    /// @dev FWA listing ids of listed ordinary items, by row.
    uint256[][] internal _listedByRow;
    /// @dev Position of each listing id inside its row's `_listedByRow` array.
    mapping(uint256 listingId => uint256) internal _listedIndex;

    /// @notice Destination of the export: this pool for retirement, a successor for migration.
    address public exitDest;
    /// @notice Share supply at export. On a successor, the share supply of `oldPool` reported by
    ///         `finalizeImport`.
    uint256 public exportedShares;
    /// @notice Ordinary NAV plus maintenance at export, including items already moved to the
    ///         successor.
    uint256 public exportedNav;
    /// @notice Successor side: NAV received from `oldPool`, and the shares minted against it.
    uint256 public importedNav;
    uint256 public importedShares;
    /// @notice Successor side: holders whose `oldPool` shares were converted by `migrateHolder`.
    mapping(address holder => bool) public migrated;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(Params memory p) {
        if (p.shapes == address(0) || p.drawPacks == address(0) || p.fwaFactory == address(0) || p.admin == address(0))
        {
            revert ZeroAddress();
        }
        if (uint256(p.feeSplit.premiumBps) + p.feeSplit.maintenanceBps + p.feeSplit.feedBps > MAX_FEE_SPLIT_BPS) {
            revert FeeSplitTooHigh();
        }
        if (p.feeSplit.minorShareBps > BPS) revert MinorShareTooHigh();
        if (p.curve.capBps > MAX_CURVE_CAP_BPS) revert CurveCapTooHigh();
        if (p.curve.referenceWei == 0) revert CurveReferenceZero();
        if (p.grailProbCapBps == 0 || p.grailProbCapBps > BPS) revert GrailProbCapOutOfRange();

        shapes = p.shapes;
        drawPacks = p.drawPacks;
        fwaFactory = p.fwaFactory;
        oldPool = p.oldPool;
        admin = p.admin;
        feeSplit = p.feeSplit;
        curve = p.curve;
        navCap = p.navCap;
        rotateInterval = p.rotateInterval;
        openingDeadline = p.openingDeadline;
        minItems = p.minItems;
        grailProbCapBps = p.grailProbCapBps;

        _initGrail(MINOR, p.minor);
        _initGrail(MAJOR, p.major);
        _setMix(p.mix);
    }

    // ------------------------------------------------------------------ views

    /// @notice Ordinary NAV: `cash + backing + receivable - claims`, or zero when `claims` exceed
    ///         the assets.
    function nav() public view returns (uint256) {
        uint256 assets = cash + backing + receivable;
        return assets > claims ? assets - claims : 0;
    }

    /// @notice Listed plus held ordinary items of `row`.
    function rowCount(uint256 row) external view returns (uint256) {
        return _rowCount[row];
    }

    /// @notice Rungs and weight share of mix row `i`.
    function mixRow(uint256 i) external view returns (uint8[] memory rungs, uint16 shareBps) {
        uint8[] storage stored = _mix[i].rungs;
        rungs = new uint8[](stored.length);
        for (uint256 j; j < rungs.length; ++j) {
            rungs[j] = stored[j];
        }
        shareBps = _mix[i].shareBps;
    }

    // ------------------------------------------------------------------ opening

    /// @notice Creates the FWA pool through the factory and approves it for both collections.
    ///         Starts the opening deadline. The factory pulls `expectedFee` of its FWA token from
    ///         this contract, so the pool must hold that balance first.
    function createFwaPool(uint256 expectedFee) external onlyAdmin nonReentrant {
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        if (address(fwaPool) != address(0)) revert FwaPoolExists();

        IFWACloneFactory factory = IFWACloneFactory(fwaFactory);
        if (expectedFee != 0) {
            SafeTransferLib.safeApprove(
                address(uint160(_read(fwaFactory, IFWACloneFactory.fwaToken.selector, 0))), fwaFactory, expectedFee
            );
        }
        IFWAClone clone = IFWAClone(factory.createPool(bytes32(0), expectedFee));

        fwaPool = clone;
        maxBatch = _read(fwaFactory, IFWACloneFactory.maxAcquisitionsPerTx.selector, 0);
        concurrency = _read(fwaFactory, IFWACloneFactory.maxOutstandingRequestsPerPool.selector, 0);
        nextSequenceToBook = 1;
        openingDeadlineAt = block.timestamp + openingDeadline;
        _call(shapes, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        _call(drawPacks, IERC721.setApprovalForAll.selector, uint160(address(clone)), 1);
        emit FwaPoolCreated(address(clone));
    }

    /// @notice Enables FWA acquisitions and builds the board after the opening deadline. Each call
    ///         runs one restock. The pool becomes Live on the first call that mints fewer than
    ///         `MAX_MINTS_PER_RESTOCK` tokens, and stays callable while Opening.
    function open() external nonReentrant {
        _notExiting();
        if (lifecycle != Lifecycle.Opening) revert NotOpening();
        IFWAClone fwa = fwaPool;
        if (address(fwa) == address(0)) revert FwaPoolMissing();
        if (block.timestamp < openingDeadlineAt) revert OpeningDeadlineNotReached();
        if (_read(address(fwa), IFWAClone.localPurchasesEnabled.selector, 0) == 0) {
            _call(address(fwa), IFWAClone.setBool.selector, FWAConfigKeys.ACQUISITIONS_ENABLED, 1);
        }
        if (_restock() < MAX_MINTS_PER_RESTOCK) {
            lifecycle = Lifecycle.Live;
            lastRotateAt = block.timestamp;
            emit Opened();
        }
    }

    // ------------------------------------------------------------------ depositor paths

    /// @notice Deposits `msg.value` for shares at ordinary NAV, net of the entry contribution.
    function deposit() external payable nonReentrant {
        _notExiting();
        _sync();
        _deposit(msg.sender, msg.value);
    }

    /// @notice Burns `shares` and pays their claim at ordinary NAV. Pays `min(claim, cash)` now and
    ///         queues the remainder in `claimQueue`.
    function withdraw(uint256 shares) external nonReentrant {
        _sync();
        if (shares == 0) revert ZeroAmount();
        uint256 balance = sharesOf[msg.sender];
        if (shares > balance) revert InsufficientShares();

        uint256 supply = totalShares;
        uint256 claim = PricingLib.claimFor(shares, nav(), supply);
        sharesOf[msg.sender] = balance - shares;
        totalShares = supply - shares;

        uint256 available = cash;
        uint256 paidNow = claim < available ? claim : available;
        uint256 remainder = claim - paidNow;
        cash = available - paidNow;
        if (remainder != 0) {
            claims += remainder;
            claimQueue.push(Claim(msg.sender, uint64(block.timestamp), remainder));
        }
        emit Withdrawn(msg.sender, shares, paidNow, remainder);
        if (paidNow != 0) SafeTransferLib.safeTransferETH(msg.sender, paidNow);
    }

    /// @notice Pays queued claims in request order once the head claim is at least `rotateInterval`
    ///         old. Pays from `cash`, then withdraws and redeems up to `MAX_LIQUIDATE_ITEMS` listed
    ///         items until the head claim is covered. Does nothing when the queue is empty.
    function liquidate() external nonReentrant {
        _sync();
        uint256 head = claimHead;
        if (head == claimQueue.length) return;
        if (block.timestamp < claimQueue[head].requestedAt + rotateInterval) revert ClaimNotDue();
        _clearClaims();
    }

    /// @notice Runs one rotation: settles, harvests, pays or liquidates for queued claims, restocks
    ///         and lists the board, reprices or grows the GRAIL tracks, then refunds the caller
    ///         from `maintenance`. Callable once `rotateInterval` has passed since `lastRotateAt`.
    function rotate() external nonReentrant {
        _requireLive();
        if (block.timestamp < lastRotateAt + rotateInterval) revert RotateTooSoon();
        uint256 gasStart = gasleft();

        bool changed = _settleAndHarvest();
        uint256 claimsBefore = claims;
        bool inventoryChanged = _clearClaims();
        bool heldPending = _held.length != 0;
        bool minted = _restock() != 0;
        bool busy = _busy();
        bool grailChanged = _rotateGrail(MINOR, busy);
        grailChanged = _rotateGrail(MAJOR, busy) || grailChanged;
        inventoryChanged = inventoryChanged || heldPending || minted || grailChanged;
        if (inventoryChanged) lastRotateAt = block.timestamp;
        _refund(gasStart, changed || inventoryChanged || claims != claimsBefore, inventoryChanged);
    }

    /// @notice Adds one `stepWei` of backing to GRAIL track `t` from `grail[t].bucket` and lists
    ///         the pack at `backing * listBps / 10_000`. Books FWA results first. Reverts
    ///         `GrailNotReady` unless the bucket covers the step and its mint fees and `backing`
    ///         is below `targetWei`, and `FwaBusy` while FWA holds unsettled acquisitions.
    function growGrail(uint8 t) external nonReentrant {
        _requireLive();
        if (t > MAJOR) revert GrailNotReady();
        _sync();
        uint256 status = _growGrail(t, _unsettled() != 0);
        if (status == 1) revert GrailNotReady();
        if (status == 2) revert FwaBusy();
    }

    // ------------------------------------------------------------------ player paths

    /// @notice Buys `count` FWA acquisitions for `msg.sender` at the quoted fee. Overpayment is
    ///         refunded. Settles up to `SETTLE_BUDGET` FWA acquisitions, harvests, pays queued
    ///         claims and mints one queued replacement from `cash`.
    function pull(uint256 count, uint256 maxFee, uint256 deadline) external payable nonReentrant {
        _pull(msg.sender, count, maxFee, deadline, msg.value);
    }

    /// @notice Redeems the caller's Shapes `tokenIds` and applies the proceeds and `msg.value` to
    ///         `pull`. The caller must have approved this contract for each token.
    function pullWithShapes(uint256[] calldata tokenIds, uint256 count, uint256 maxFee, uint256 deadline)
        external
        payable
        nonReentrant
    {
        _requireLive();
        _pull(msg.sender, count, maxFee, deadline, msg.value + _redeemShapes(tokenIds));
    }

    /// @notice Redeems the caller's Shape `tokenId` and deposits the proceeds. The caller must have
    ///         approved this contract for the token.
    function redeemAndDeposit(uint256 tokenId) external nonReentrant {
        _notExiting();
        _sync();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        _deposit(msg.sender, _redeemShapes(ids));
    }

    /// @notice Processes up to `maxCount` FWA acquisitions and books their results.
    function settle(uint256 maxCount) external nonReentrant {
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        _processAndSettle(maxCount < MAX_SETTLE_ITEMS ? maxCount : MAX_SETTLE_ITEMS);
    }

    // ------------------------------------------------------------------ exit

    /// @notice Closes pulls, deposits, rotation and GRAIL growth. `dest` is this pool for
    ///         retirement or a successor whose `oldPool` is this pool for migration. Callable in
    ///         Opening and Live once the FWA pool exists.
    function startExit(address dest) external onlyAdmin {
        _notExiting();
        if (address(fwaPool) == address(0)) revert FwaPoolMissing();
        if (dest != address(this) && address(uint160(_read(dest, this.oldPool.selector, 0))) != address(this)) {
            revert InvalidDest();
        }
        exitDest = dest;
        lifecycle = Lifecycle.Exiting;
        emit ExitStarted(dest);
    }

    /// @notice Moves up to `maxItems` ordinary listings, held items and GRAIL tracks out of the
    ///         pool, then settles the exit. Ordinary items are redeemed into `cash` on retirement.
    ///         On migration they go to the successor while `cash` covers `claims`, and are redeemed
    ///         into `cash` until it does. GRAIL tracks move on migration only. The call that moves
    ///         the last item folds `maintenance` into `cash`, records `exportedShares` and
    ///         `exportedNav`, sends `cash - claims` to the successor, sets Exported, retires the FWA
    ///         pool and finalizes the import. Reverts `FwaBusy` while FWA holds unsettled
    ///         acquisitions or the booking walk is behind. Returns whether the export is complete.
    function exportStep(uint256 maxItems) external nonReentrant returns (bool) {
        if (lifecycle != Lifecycle.Exiting) revert NotExiting();
        _processAndSettle(MAX_SETTLE_ITEMS);
        if (_busy()) revert FwaBusy();
        _harvest();

        address dest = exitDest;
        bool migrate = dest != address(this);
        uint256 movedNav;
        while (maxItems != 0 && (listedCount != 0 || _held.length != 0)) {
            --maxItems;
            bool move = migrate && cash >= claims;
            Item memory it;
            if (listedCount != 0) {
                uint256 row;
                while (_listedByRow[row].length == 0) ++row;
                uint256 listingId = _lastListed(row);
                _withdrawListing(listingId, move ? dest : address(this));
                it = _removeListed(listingId);
            } else {
                it = _removeHeld(_held.length - 1);
                if (move) _transfer(it.collection, address(this), dest, it.tokenId);
            }
            if (move) {
                _call(dest, this.importItem.selector, uint160(it.collection), it.tokenId);
                movedNav += it.value;
            } else {
                _redeemItem(it);
            }
        }
        bool pending = listedCount != 0 || _held.length != 0;
        for (uint256 t; migrate && t <= MAJOR; ++t) {
            Grail storage g = grail[t];
            if (g.packId == 0 && g.bucket == 0) continue;
            if (maxItems == 0) {
                pending = true;
            } else {
                --maxItems;
                (uint256 packId, uint256 bucket) = _takeGrail(g, dest);
                _callFull(dest, bucket, this.importGrail.selector, t, packId, 0);
            }
        }
        exportedNav += movedNav;
        if (pending) return false;

        cash += maintenance;
        maintenance = 0;
        uint256 exported = exportedNav + nav();
        uint256 shares = totalShares;
        exportedNav = exported;
        exportedShares = shares;
        lifecycle = Lifecycle.Exported;
        _call(address(fwaPool), IFWAClone.retirePool.selector, 0, 0);
        if (migrate) {
            uint256 out = cash > claims ? cash - claims : 0;
            cash -= out;
            _callFull(dest, out, this.importCash.selector, 0, 0, 0);
            _call(dest, this.finalizeImport.selector, shares, 0);
        }
        emit Exported(shares, exported);
        return true;
    }

    /// @notice Sends track `t`'s pack and bucket to `to` and clears the track. Callable by the
    ///         admin from `Exiting` on. Withdraws the track's FWA listing first, which FWA
    ///         rejects while it holds unsettled acquisitions.
    function transferGrailEstate(uint8 t, address to) external onlyAdmin nonReentrant {
        if (lifecycle < Lifecycle.Exiting) revert NotExiting();
        if (to == address(0)) revert ZeroAddress();
        _sync();
        (uint256 packId, uint256 bucket) = _takeGrail(grail[t], to);
        emit GrailEstateTransferred(t, to, packId, bucket);
        SafeTransferLib.safeTransferETH(to, bucket);
    }

    // ------------------------------------------------------------------ successor import

    /// @dev Restricts a function to `oldPool` while the pool is Opening or Live and the import is
    ///      open.
    modifier onlyOldPool() {
        _checkOldPool();
        _;
    }

    function _checkOldPool() internal view {
        if (msg.sender != oldPool) revert NotOldPool();
        _notExiting();
        if (importFinalized) revert ImportClosed();
    }

    /// @notice Registers a Shape or Draw Pack that `oldPool` transferred to this pool as a held
    ///         ordinary item of the first mix row with the token's value and kind. The next
    ///         `rotate` or `open` lists it.
    function importItem(address collection, uint256 tokenId) external onlyOldPool {
        bool pack = collection == drawPacks;
        if (!pack && collection != shapes) revert NoMatchingRow();
        _requireOwned(collection, tokenId);
        uint256 value = _read(collection, pack ? IERC721Value.valueOf.selector : IShapes.backingOf.selector, tokenId);
        for (uint256 r; r < _mix.length; ++r) {
            if (_rowBackingWei[r] == value && (_mix[r].rungs.length > 1) == pack) {
                _addItem(Item(collection, uint16(r), tokenId, value, 0));
                importedNav += value;
                return;
            }
        }
        revert NoMatchingRow();
    }

    /// @notice Takes track `t`'s pack and bucket from `oldPool`. `packId` is zero when the track
    ///         has no pack. The next `rotate` lists the pack at `listBps` of its backing.
    function importGrail(uint8 t, uint256 packId) external payable onlyOldPool {
        Grail storage g = grail[t];
        if (g.packId != 0) revert GrailOccupied();
        g.bucket += msg.value;
        if (packId != 0) {
            _requireOwned(drawPacks, packId);
            uint256 value = _read(drawPacks, IERC721Value.valueOf.selector, packId);
            g.packId = packId;
            g.backing = value;
            g.notional = PricingLib.grailNotional(value, g.listBps);
        }
    }

    /// @notice Credits `msg.value` from `oldPool` to `cash`. It counts toward `importedNav` and
    ///         bypasses `navCap`.
    function importCash() external payable onlyOldPool {
        cash += msg.value;
        importedNav += msg.value;
    }

    /// @notice Closes the import and mints `importedShares` for `importedNav` at the NAV per share
    ///         before the import. `exportedShares_` is the share supply of `oldPool`.
    function finalizeImport(uint256 exportedShares_) external onlyOldPool {
        uint256 imported = importedNav;
        uint256 minted = PricingLib.sharesFor(imported, nav() - imported, totalShares);
        importedShares = minted;
        totalShares += minted;
        exportedShares = exportedShares_;
        importFinalized = true;
        emit Imported(imported, minted);
    }

    /// @notice Mints `holder` the share of `importedShares` that matches `holder`'s share of
    ///         `oldPool`. Once per holder. The rounding remainder stays in `totalShares`.
    function migrateHolder(address holder) external {
        if (!importFinalized) revert ImportNotFinal();
        if (migrated[holder]) revert AlreadyMigrated();
        migrated[holder] = true;
        uint256 shares = _read(oldPool, this.sharesOf.selector, uint160(holder)) * importedShares / exportedShares;
        sharesOf[holder] += shares;
        emit Migrated(holder, shares);
    }

    /// @notice Accepts ETH from Shapes redemptions and FWA proceeds. The ETH is booked by the
    ///         function that triggered the transfer.
    receive() external payable {}

    /// @notice Accepts Shapes and Draw Packs from mints and FWA listing withdrawals. The calling
    ///         function books the token.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internal

    /// @dev Brings the books level with FWA before share pricing: processes and books up to
    ///      `MAX_SETTLE_ITEMS` acquisitions, requires the booking walk to reach FWA's processing
    ///      queue, then harvests. FWA processes acquisitions permissionlessly, so share pricing
    ///      must follow the books, never lead them. No-op before the FWA pool exists.
    function _sync() internal {
        if (address(fwaPool) == address(0)) return;
        _processAndSettle(MAX_SETTLE_ITEMS);
        if (nextSequenceToBook != _nextToProcess()) revert BooksBehind();
        _harvest();
    }

    /// @dev Reverts `PoolExiting` from `Exiting` on.
    function _notExiting() internal view {
        if (lifecycle >= Lifecycle.Exiting) revert PoolExiting();
    }

    /// @dev Reverts unless the pool is Live: `PoolExiting` from `Exiting` on, `NotLive` before.
    function _requireLive() internal view {
        if (lifecycle != Lifecycle.Live) {
            _notExiting();
            revert NotLive();
        }
    }

    /// @dev Mints shares to `to` for `value`. The entry contribution goes to the GRAIL buckets,
    ///      split by `minorShareBps`. Shares are priced on NAV before the deposit.
    function _deposit(address to, uint256 value) internal {
        if (depositsPaused) revert DepositsPaused();
        if (value == 0) revert ZeroAmount();
        uint256 currentNav = nav();
        if (currentNav == 0 && totalShares != 0) revert NavZero();
        if (currentNav >= navCap) revert NavCapReached();

        EntryCurve memory c = curve;
        uint256 contribution = PricingLib.entryContribution(
            value, PricingLib.entryCurveBps(currentNav, c.baseBps, c.slopeBps, c.capBps, c.referenceWei)
        );
        uint256 net = value - contribution;
        uint256 shares = PricingLib.sharesFor(net, currentNav, totalShares);
        if (shares == 0) revert ZeroShares();

        uint256 minorPart = contribution * feeSplit.minorShareBps / BPS;
        grail[MINOR].bucket += minorPart;
        grail[MAJOR].bucket += contribution - minorPart;
        cash += net;
        totalShares += shares;
        sharesOf[to] += shares;
        emit Deposited(to, value, contribution, shares);
    }

    /// @dev Pays claims from `cash` starting at `claimHead`, at most `MAX_CLAIM_ITEMS` queue entries. A
    ///      partly paid head claim keeps its place with a reduced `amount`. Storage is updated
    ///      before any transfer. Recipients are paid with `forceSafeTransferETH`, so a recipient
    ///      that rejects ETH cannot stall the queue.
    function _payClaims() internal {
        uint256 head = claimHead;
        uint256 pending = claimQueue.length - head;
        uint256 limit = pending < MAX_CLAIM_ITEMS ? pending : MAX_CLAIM_ITEMS;
        address[] memory recipients = new address[](limit);
        uint256[] memory payouts = new uint256[](limit);
        uint256 available = cash;
        uint256 paidTotal;
        uint256 paidCount;
        while (paidCount < limit && available != 0) {
            Claim storage c = claimQueue[head];
            uint256 amount = c.amount;
            uint256 pay = amount < available ? amount : available;
            available -= pay;
            paidTotal += pay;
            recipients[paidCount] = c.to;
            payouts[paidCount] = pay;
            ++paidCount;
            if (pay == amount) {
                ++head;
            } else {
                c.amount = amount - pay;
            }
        }
        claimHead = head;
        cash = available;
        claims -= paidTotal;
        for (uint256 i; i < paidCount; ++i) {
            emit ClaimPaid(recipients[i], payouts[i]);
            SafeTransferLib.forceSafeTransferETH(recipients[i], payouts[i]);
        }
    }

    /// @dev Pays claims from `cash`, then liquidates for the head claim and pays again. Returns
    ///      whether a listing was withdrawn.
    function _clearClaims() internal returns (bool withdrawn) {
        _payClaims();
        withdrawn = _liquidateForClaims(MAX_LIQUIDATE_ITEMS);
        if (withdrawn) _payClaims();
    }

    /// @dev Settles up to `MAX_SETTLE_ITEMS` acquisitions and harvests. Returns whether a booking
    ///      or a harvest happened.
    function _settleAndHarvest() internal returns (bool) {
        uint64 booked = nextSequenceToBook;
        _processAndSettle(MAX_SETTLE_ITEMS);
        bool harvested = _harvest();
        return harvested || nextSequenceToBook != booked;
    }

    /// @dev Pays the caller `min(maintenance, gas cost + ROTATE_TIP)` when the rotation changed
    ///      state. The transfer is the last step.
    function _refund(uint256 gasStart, bool changed, bool inventoryChanged) internal {
        uint256 refund;
        uint256 bucket = maintenance;
        if (changed && bucket != 0) {
            uint256 cost = (gasStart - gasleft() + ROTATE_GAS_OVERHEAD) * block.basefee + ROTATE_TIP;
            refund = cost < bucket ? cost : bucket;
            maintenance = bucket - refund;
        }
        emit Rotated(changed, inventoryChanged, refund);
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);
    }

    /// @dev Withdraws and redeems listed items, at most `maxItems`, while `cash` is below the head
    ///      claim. Each pick is the last listed item of the row most over its share. Does nothing
    ///      while FWA holds unsettled acquisitions, which lock withdrawals, or while the booking
    ///      walk is behind FWA's processing queue, which leaves captured listings in `_listed`.
    ///      Returns whether an item was withdrawn.
    function _liquidateForClaims(uint256 maxItems) internal returns (bool withdrawn) {
        uint256 head = claimHead;
        if (head == claimQueue.length || listedCount == 0) return false;
        if (_busy()) return false;
        uint256 mintFee = _mintFee();
        for (uint256 n; n < maxItems && listedCount != 0 && cash < claimQueue[head].amount; ++n) {
            _liquidateOne(head, mintFee);
            withdrawn = true;
        }
    }

    /// @dev Withdraws the last listed item of the most overweight row, redeems it into `cash` and
    ///      deducts the mint fees of the redeemed Shapes from the claim at `head`. The deducted ETH
    ///      stays in `cash` for the replacement mint.
    function _liquidateOne(uint256 head, uint256 mintFee) internal {
        uint256 listingId = _lastListed(_mostOverweightListedRow());
        _withdrawListing(listingId, address(this));
        Item memory it = _removeListed(listingId);
        _redeemItem(it);

        Claim storage c = claimQueue[head];
        uint256 amount = c.amount;
        uint256 fee = mintFee * _mix[it.row].rungs.length;
        if (fee > amount) fee = amount;
        c.amount = amount - fee;
        claims -= fee;
        emit Liquidated(listingId, it.value, fee);
    }

    /// @dev Last listing id of `row`.
    function _lastListed(uint256 row) internal view returns (uint256) {
        uint256[] storage ids = _listedByRow[row];
        return ids[ids.length - 1];
    }

    /// @dev Withdraws FWA listing `listingId`; the token goes to `to`.
    function _withdrawListing(uint256 listingId, address to) internal {
        _call(address(fwaPool), IFWAClone.withdrawListingTo.selector, listingId, uint160(to));
    }

    /// @dev Redeems ordinary item `it`, which this contract owns, at its collection into `cash`.
    function _redeemItem(Item memory it) internal {
        uint256 balanceBefore = address(this).balance;
        _call(it.collection, IShapes.redeem.selector, it.tokenId, 0);
        if (address(this).balance - balanceBefore != it.value) revert RedeemMismatch();
        cash += it.value;
    }

    /// @dev Withdraws the track's listing, transfers its pack to `to` and clears the track. Returns
    ///      the pack id and the bucket, which the caller sends.
    function _takeGrail(Grail storage g, address to) internal returns (uint256 packId, uint256 bucket) {
        packId = g.packId;
        bucket = g.bucket;
        _unlistGrail(g);
        if (packId != 0) _transfer(drawPacks, address(this), to, packId);
        _resetGrail(g);
        g.bucket = 0;
    }

    /// @dev ERC-721 `transferFrom` of `tokenId` of `collection`.
    function _transfer(address collection, address from, address to, uint256 tokenId) internal {
        _callFull(collection, 0, IERC721.transferFrom.selector, uint160(from), uint160(to), tokenId);
    }

    /// @dev Reverts `TokenNotReceived` unless this contract owns `tokenId` of `collection`.
    function _requireOwned(address collection, uint256 tokenId) internal view {
        if (address(uint160(_read(collection, IERC721.ownerOf.selector, tokenId))) != address(this)) {
            revert TokenNotReceived();
        }
    }

    /// @dev Row with listed items that maximizes `rowCount / shareBps`, compared by cross
    ///      multiplication. A listed row with zero share ranks above every row with a share.
    function _mostOverweightListedRow() internal view returns (uint256 best) {
        uint256 bestCount;
        uint256 bestShare;
        for (uint256 r; r < _mix.length; ++r) {
            if (_listedByRow[r].length == 0) continue;
            uint256 count = _rowCount[r];
            uint256 share = _mix[r].shareBps;
            if (bestCount == 0 || count * bestShare > bestCount * share) {
                best = r;
                bestCount = count;
                bestShare = share;
            }
        }
    }

    // ------------------------------------------------------------------ pull

    /// @dev Buys `count` acquisitions for `purchaser` with `value` wei available. `value` is
    ///      already in the pool balance and outside every bucket.
    function _pull(address purchaser, uint256 count, uint256 maxFee, uint256 deadline, uint256 value) internal {
        _requireLive();
        if (pullsPaused) revert PullsPaused();
        if (count == 0 || count > maxBatch) revert InvalidCount();
        _requirePurchasable(value);

        IFWAClone fwa = fwaPool;
        (uint256 fee, uint256 total) = _quote(count);
        if (fee > maxFee) revert FeeAboveMax(fee, maxFee);
        if (value < total) revert InsufficientValue(value, total);

        uint256[] memory ids = fwa.acquireBatch{value: total}(
            purchaser,
            count,
            maxFee,
            0,
            _read(address(fwa), IFWAClone.selectionSlippageBps.selector, 0),
            _read(address(fwa), IFWAClone.inventoryVersion.selector, 0),
            deadline
        );
        _recordBases(fwa, fee, ids);
        _recordPulls(count);
        emit Pulled(purchaser, count, fee, ids);

        _upkeep();
        if (value > total) SafeTransferLib.safeTransferETH(purchaser, value - total);
    }

    /// @dev Transfers `tokenIds` from the caller and redeems them. Returns the ETH redeemed.
    function _redeemShapes(uint256[] memory tokenIds) internal returns (uint256) {
        for (uint256 i; i < tokenIds.length; ++i) {
            _transfer(shapes, msg.sender, address(this), tokenIds[i]);
        }
        return IShapes(shapes).redeemBatch(tokenIds);
    }

    /// @dev Records the FWA base price of each request opened by one `acquireBatch`. The batch
    ///      reserves staged listings without activating them, so `weightedBackingTotal` and
    ///      `totalWeight` read after the call equal their values at every request.
    function _recordBases(IFWAClone fwa, uint256 fee, uint256[] memory ids) internal {
        uint256 base = _read(address(fwa), IFWAClone.weightedBackingTotal.selector, 0) / _totalWeight();
        if (base > fee) base = fee;
        for (uint256 i; i < ids.length; ++i) {
            _basePlusOne[ids[i]] = base + 1;
        }
    }

    /// @dev Per-pull upkeep: settles up to `SETTLE_BUDGET` acquisitions, harvests, pays queued
    ///      claims from `cash`, then mints one queued replacement when `cash` covers it. The
    ///      replacement stays held. A listing here would start the FWA inventory change cooldown
    ///      and block the next pull.
    function _upkeep() internal {
        _processAndSettle(SETTLE_BUDGET);
        _harvest();
        _payClaims();
        uint256 head = replacementHead;
        if (head == replacementQueue.length) return;
        uint256 mintFee = _mintFee();
        uint256 row = replacementQueue[head];
        if (cash < _rowCost(row, mintFee)) return;
        replacementHead = head + 1;
        _mintRow(row, mintFee);
    }

    /// @dev Reverts unless a pull may open: the FWA cooldown has passed, the balance covers the
    ///      buckets plus the `incoming` wei still outside them, the listed ordinary items exceed
    ///      the unsettled acquisitions by `concurrency`, and the listed GRAIL tracks hold at most
    ///      `grailProbCapBps` of the FWA selection weight.
    function _requirePurchasable(uint256 incoming) internal view {
        IFWAClone fwa = fwaPool;
        if (block.timestamp < _read(address(fwa), IFWAClone.purchasesResumeAt.selector, 0)) revert PurchasesCoolingDown();
        if (address(this).balance < incoming + cash + maintenance + grail[MINOR].bucket + grail[MAJOR].bucket) {
            revert Insolvent();
        }
        if (listedCount < _unsettled() + concurrency) revert BoardTooThin();

        uint256 grailWeight;
        for (uint256 t; t < 2; ++t) {
            Grail storage g = grail[t];
            if (g.listingId != 0) grailWeight += PricingLib.weightOf(g.notional);
        }
        if (grailWeight * BPS > _totalWeight() * grailProbCapBps) revert GrailProbTooHigh();
    }

    // ------------------------------------------------------------------ settlement

    /// @dev Advances FWA's processing queue by `maxItems`, then books the results.
    function _processAndSettle(uint256 maxItems) internal {
        _call(address(fwaPool), IFWAClone.processAcquisitions.selector, maxItems, 0);
        _settle(maxItems);
    }

    /// @dev Books up to `maxItems` FWA acquisitions, then books the owner proceeds of requests
    ///      opened outside `pull` once the walk has reached FWA's processing queue.
    function _settle(uint256 maxItems) internal {
        IFWAClone fwa = fwaPool;
        uint64 end = _nextToProcess();
        if (_walk(fwa, end, maxItems) == end) _bookSurplus(_ownerProceeds());
    }

    /// @dev Books up to `maxItems` FWA acquisitions in sequence order from `nextSequenceToBook`
    ///      to `end`. Returns the new `nextSequenceToBook`. A Fulfilled acquisition is a capture:
    ///      FWA pays the owner `paid - (paid - base) / 2`, and a request without a recorded base
    ///      books zero proceeds, which `_bookSurplus` books from FWA's owner proceeds. A refunded
    ///      delivery returns its token to held items. A DeliveryPending acquisition is written off:
    ///      its item leaves backing and its value is charged to `margin`, with no proceeds and no
    ///      replacement. If the delivery later completes, FWA accrues owner proceeds and
    ///      `_bookSurplus` books them. If the purchaser later refunds, the admin recovers the token
    ///      with `adminCall(recoverRefundedNFT)` and `sweep`. Expired, Refunded and TimedOut
    ///      acquisitions book nothing. The walk stops at any other status.
    function _walk(IFWAClone fwa, uint64 end, uint256 maxItems) internal returns (uint64 seq) {
        seq = nextSequenceToBook;
        if (seq >= end) return seq;

        uint64 start = seq;
        uint256 mintFee = _mintFee();
        for (uint256 n; seq < end && n < maxItems; ++n) {
            uint256 requestId = _read(address(fwa), IFWAClone.requestIdAtSequence.selector, seq);
            (uint256 paid, uint256 listingId, uint256 status) = _acquisition(requestId);
            if (status == uint256(IFWAClone.AcquisitionStatus.Fulfilled)) {
                _capture(requestId, listingId, paid, mintFee);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryRefunded)) {
                _recoverRefunded(fwa, listingId);
            } else if (status == uint256(IFWAClone.AcquisitionStatus.DeliveryPending)) {
                _writeOff(requestId, listingId);
            } else if (
                status != uint256(IFWAClone.AcquisitionStatus.Expired)
                    && status != uint256(IFWAClone.AcquisitionStatus.Refunded)
                    && status != uint256(IFWAClone.AcquisitionStatus.TimedOut)
            ) {
                break;
            }
            ++seq;
        }
        if (seq != start) {
            nextSequenceToBook = seq;
            emit Settled(seq);
        }
    }

    /// @dev Books one Fulfilled acquisition. A GRAIL listing credits its proceeds to the track's
    ///      receivable and resets the track. An ordinary item leaves backing, its proceeds join
    ///      `receivable` and `margin`, and its row is queued for a replacement.
    function _capture(uint256 requestId, uint256 listingId, uint256 paid, uint256 mintFee) internal {
        uint256 stored = _basePlusOne[requestId];
        uint256 proceeds = stored == 0 ? 0 : paid - (paid - (stored - 1)) / 2;
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            _closeGrail(t, requestId, proceeds);
            return;
        }
        Item memory it = _removeListed(listingId);
        receivable += proceeds;
        margin += SafeCastLib.toInt256(proceeds) - SafeCastLib.toInt256(it.value);
        mintLineOwed += mintFee * _mix[it.row].rungs.length;
        replacementQueue.push(it.row);
        emit Captured(requestId, listingId, it.row, it.value, proceeds);
        _splitMargin();
    }

    /// @dev Track whose pack is listed under `listingId`, or 2 when none is.
    function _grailTrack(uint256 listingId) internal view returns (uint256 t) {
        while (t <= MAJOR && grail[t].listingId != listingId) ++t;
    }

    /// @dev Clears track `t` after its pack left the pool. `proceeds` joins the track's receivable.
    function _closeGrail(uint256 t, uint256 requestId, uint256 proceeds) internal {
        Grail storage g = grail[t];
        g.receivable += proceeds;
        _resetGrail(g);
        emit GrailCaptured(t, requestId, proceeds);
    }

    /// @dev Clears the pack fields of a track whose pack left the pool.
    function _resetGrail(Grail storage g) internal {
        g.packId = 0;
        g.backing = 0;
        g.notional = 0;
        g.listingId = 0;
        g.pullsSinceList = 0;
    }

    /// @dev Withdraws the track's FWA listing to this contract when it is listed.
    function _unlistGrail(Grail storage g) internal {
        uint256 id = g.listingId;
        if (id != 0) {
            _withdrawListing(id, address(this));
            g.listingId = 0;
        }
    }

    /// @dev Removes the listed item from backing and charges its value to `margin`. A GRAIL
    ///      listing is cleared with no proceeds.
    function _writeOff(uint256 requestId, uint256 listingId) internal {
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            _closeGrail(t, requestId, 0);
            return;
        }
        Item memory it = _removeListed(listingId);
        margin -= SafeCastLib.toInt256(it.value);
        emit WrittenOff(requestId, listingId, it.value);
    }

    /// @dev Takes back a token that FWA quarantined after a refunded delivery and holds it
    ///      unlisted. Backing is unchanged. A GRAIL pack stays the track's pack and is listed again
    ///      by the next `rotate`.
    function _recoverRefunded(IFWAClone fwa, uint256 listingId) internal {
        uint256 t = _grailTrack(listingId);
        if (t <= MAJOR) {
            grail[t].listingId = 0;
        } else {
            Item memory it = _removeListed(listingId);
            it.listingId = 0;
            _addItem(it);
        }
        _call(address(fwa), IFWAClone.recoverRefundedNFT.selector, listingId, 0);
    }

    /// @dev Splits positive `margin`. The mint line owed is covered first and stays in ordinary
    ///      NAV. The rest divides by `premiumBps : maintenanceBps : feedBps`. The premium share
    ///      stays in ordinary NAV. The maintenance and feed shares move from `receivable` to
    ///      `maintenanceReceivable` and the GRAIL receivables, split by `minorShareBps`.
    function _splitMargin() internal {
        int256 signedMargin = margin;
        if (signedMargin <= 0) return;
        uint256 amount = uint256(signedMargin);
        uint256 cover = amount < mintLineOwed ? amount : mintLineOwed;
        mintLineOwed -= cover;
        uint256 rest = amount - cover;

        FeeSplit memory split = feeSplit;
        uint256 totalBps = uint256(split.premiumBps) + split.maintenanceBps + split.feedBps;
        uint256 maintenanceShare;
        uint256 feedShare;
        if (totalBps != 0) {
            maintenanceShare = rest * split.maintenanceBps / totalBps;
            feedShare = rest * split.feedBps / totalBps;
        }

        receivable -= maintenanceShare + feedShare;
        maintenanceReceivable += maintenanceShare;
        uint256 minorFeed = feedShare * split.minorShareBps / BPS;
        grail[MINOR].receivable += minorFeed;
        grail[MAJOR].receivable += feedShare - minorFeed;
        margin = 0;
        emit MarginSplit(cover, rest - maintenanceShare - feedShare, maintenanceShare, feedShare);
    }

    /// @dev Sum of the four receivables.
    function _bookedReceivables() internal view returns (uint256) {
        return receivable + maintenanceReceivable + grail[MINOR].receivable + grail[MAJOR].receivable;
    }

    /// @dev Books `actual` FWA owner proceeds above the booked receivables as `receivable` and
    ///      `margin`, then splits the margin. The excess is the proceeds of requests opened outside
    ///      `pull`, whose captures booked zero proceeds. Callers pass a value read while the
    ///      booking walk is level with FWA's processing queue. Returns the excess.
    function _bookSurplus(uint256 actual) internal returns (uint256 surplus) {
        uint256 booked = _bookedReceivables();
        if (actual <= booked) return 0;
        surplus = actual - booked;
        receivable += surplus;
        margin += SafeCastLib.toInt256(surplus);
        _splitMargin();
        emit SurplusBooked(surplus);
    }

    /// @dev Withdraws FWA owner proceeds and credits them to the buckets. Returns false when
    ///      the booking walk is behind FWA's processing queue or no proceeds are held. Proceeds
    ///      above the booked receivables enter as margin through `_bookSurplus`.
    function _harvest() internal returns (bool) {
        if (nextSequenceToBook < _nextToProcess() || _ownerProceeds() == 0) return false;

        uint256 received = _call(address(fwaPool), IFWAClone.withdrawOwnerProceeds.selector, 0, 0);
        uint256 expected = _bookedReceivables();
        if (received < expected) revert HarvestShortfall(received, expected);

        uint256 surplus = _bookSurplus(received);
        cash += receivable;
        maintenance += maintenanceReceivable;
        grail[MINOR].bucket += grail[MINOR].receivable;
        grail[MAJOR].bucket += grail[MAJOR].receivable;
        receivable = 0;
        maintenanceReceivable = 0;
        grail[MINOR].receivable = 0;
        grail[MAJOR].receivable = 0;
        emit Harvested(received, surplus);
        return true;
    }

    // ------------------------------------------------------------------ registry

    /// @dev Books `it` as held (`listingId == 0`) or listed. Every registry change goes through
    ///      `_addItem` and `_removeHeld` / `_removeListed`, which keep `backing` equal to the sum
    ///      of `value` over held and listed items (I2), `_rowCount` equal to their number and
    ///      `_listedByRow` equal to the listing ids of the listed items.
    function _addItem(Item memory it) internal {
        if (it.listingId == 0) {
            _held.push(it);
        } else {
            _listed[it.listingId] = it;
            ++listedCount;
            uint256[] storage ids = _listedByRow[it.row];
            _listedIndex[it.listingId] = ids.length;
            ids.push(it.listingId);
        }
        backing += it.value;
        ++_rowCount[it.row];
    }

    function _removeHeld(uint256 index) internal returns (Item memory it) {
        uint256 last = _held.length - 1;
        it = _held[index];
        if (index != last) _held[index] = _held[last];
        _held.pop();
        backing -= it.value;
        --_rowCount[it.row];
    }

    function _removeListed(uint256 listingId) internal returns (Item memory it) {
        it = _listed[listingId];
        if (it.value == 0) revert UnknownListing(listingId);
        delete _listed[listingId];
        uint256[] storage ids = _listedByRow[it.row];
        uint256 lastId = ids[ids.length - 1];
        uint256 index = _listedIndex[listingId];
        ids[index] = lastId;
        _listedIndex[lastId] = index;
        ids.pop();
        backing -= it.value;
        --_rowCount[it.row];
        --listedCount;
    }

    // ------------------------------------------------------------------ pull counter

    /// @dev Adds `count` pulls to the current clock hour. A slot last written in an earlier hour
    ///      is reset first.
    function _recordPulls(uint256 count) internal {
        uint64 hour = uint64(block.timestamp / 1 hours);
        PullSlot storage slot = _pullSlots[hour % PULL_SLOTS];
        uint256 current = slot.hour == hour ? slot.count : 0;
        slot.hour = hour;
        slot.count = SafeCastLib.toUint192(current + count);
        for (uint256 t; t <= MAJOR; ++t) {
            Grail storage g = grail[t];
            if (g.listingId != 0) g.pullsSinceList += count;
        }
    }

    /// @dev Pulls in the current hour and the four hours before it.
    function _trailingPulls() internal view returns (uint256 total) {
        uint256 hour = block.timestamp / 1 hours;
        for (uint256 i; i < PULL_SLOTS; ++i) {
            PullSlot memory slot = _pullSlots[i];
            if (slot.hour + PULL_SLOTS - 1 >= hour) total += slot.count;
        }
    }

    // ------------------------------------------------------------------ restock

    /// @dev Pays queued claims, mints replacements from the queue, then new inventory toward the
    ///      target depth of each row, then lists every held item. At most `MAX_MINTS_PER_RESTOCK`
    ///      mints per call. New inventory is minted only when the queue is empty and only from
    ///      `cash` above one step of the cheapest row. Returns the number of tokens minted.
    function _restock() internal returns (uint256 mints) {
        _payClaims();
        uint256 fee = _mintFee();

        uint256 head = replacementHead;
        uint256 queued = replacementQueue.length;
        while (head < queued && mints < MAX_MINTS_PER_RESTOCK) {
            uint256 row = replacementQueue[head];
            if (cash < _rowCost(row, fee)) break;
            ++head;
            _mintRow(row, fee);
            ++mints;
        }
        replacementHead = head;

        if (head == queued) mints = _mintToDepth(fee, mints);
        _listHeld(fee);
    }

    /// @dev Mints toward each row's target depth. Returns `mints` plus the tokens minted here.
    function _mintToDepth(uint256 fee, uint256 mints) internal returns (uint256) {
        uint256 rows = _mix.length;
        uint256 reserve = type(uint256).max;
        for (uint256 r; r < rows; ++r) {
            uint256 cost = _rowCost(r, fee);
            if (cost < reserve) reserve = cost;
        }
        uint256 pulls = _trailingPulls();
        for (uint256 r; r < rows; ++r) {
            uint256 target = PricingLib.rowDepth(minItems, pulls, _mix[r].shareBps);
            uint256 cost = _rowCost(r, fee);
            while (_rowCount[r] < target && mints < MAX_MINTS_PER_RESTOCK && cash >= reserve + cost) {
                _mintRow(r, fee);
                ++mints;
            }
        }
        return mints;
    }

    /// @dev Row backing plus the mint fee of every Shape the row mints.
    function _rowCost(uint256 row, uint256 fee) internal view returns (uint256) {
        return _rowBackingWei[row] + fee * _mix[row].rungs.length;
    }

    /// @dev Mints one token of `row` to this contract and books it as held. A one rung row is a
    ///      Shape. A row of two or more rungs is a Draw Pack created with one Shape per rung.
    function _mintRow(uint256 row, uint256 fee) internal {
        uint8[] storage rungs = _mix[row].rungs;
        uint256 value = _rowBackingWei[row];
        uint256 cost = value + fee * rungs.length;
        cash -= cost;

        address collection;
        uint256 tokenId;
        if (rungs.length == 1) {
            collection = shapes;
            tokenId = _callFull(collection, cost, IShapes.mintBatchTo.selector, value, 1, uint160(address(this)));
        } else {
            collection = drawPacks;
            uint32[] memory counts = new uint32[](Denominations.COUNT);
            for (uint256 i; i < rungs.length; ++i) {
                ++counts[rungs[i]];
            }
            tokenId = _createPack(new uint256[](0), counts, cost, value);
        }
        _addItem(Item(collection, uint16(row), tokenId, value, 0));
    }

    /// @dev FWA and Shapes reads used at several call sites. Each is one function so the external
    ///      call is compiled once.
    function _mintFee() internal view returns (uint256) {
        return _read(shapes, IShapes.mintFee.selector, 0);
    }

    function _totalWeight() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.totalWeight.selector, 0);
    }

    function _ownerProceeds() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.ownerProceeds.selector, 0);
    }

    function _nextToProcess() internal view returns (uint64) {
        return uint64(_read(address(fwaPool), IFWAClone.nextSequenceToProcess.selector, 0));
    }

    /// @dev True while FWA holds unsettled acquisitions or the booking walk is behind its processing queue.
    function _busy() internal view returns (bool) {
        return _unsettled() != 0 || nextSequenceToBook != _nextToProcess();
    }

    function _unsettled() internal view returns (uint256) {
        return _read(address(fwaPool), IFWAClone.unsettledAcquisitionCount.selector, 0);
    }

    /// @dev `priceEscrowed`, `listingId` and `status` of FWA acquisition `requestId`, which are the
    ///      third to fifth words of `acquisitions(requestId)`.
    function _acquisition(uint256 requestId) internal view returns (uint256 paid, uint256 listingId, uint256 status) {
        address fwa = address(fwaPool);
        bytes4 selector = IFWAClone.acquisitions.selector;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), requestId)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0xa0)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0xa0) { revert(0, 0) }
            paid := mload(add(m, 0x40))
            listingId := mload(add(m, 0x60))
            status := mload(add(m, 0x80))
        }
    }

    /// @dev First and third word of FWA `quoteAcquisitionPrice(count)`: `fee` and `total`.
    function _quote(uint256 count) internal view returns (uint256 fee, uint256 total) {
        address fwa = address(fwaPool);
        bytes4 selector = bytes4(keccak256("quoteAcquisitionPrice(uint256)"));
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), count)
            if iszero(staticcall(gas(), fwa, m, 0x24, m, 0x60)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x60) { revert(0, 0) }
            fee := mload(m)
            total := mload(add(m, 0x40))
        }
    }

    /// @dev Static call of `selector` on `target` with the word argument `a`. The calldata is 36
    ///      bytes: solc-compiled targets ignore arguments a getter does not read. Returns the first
    ///      word of the return data. Reverts with the target's revert data and when the target
    ///      returns less than one word, which includes a target without code.
    function _read(address target, bytes4 selector, uint256 a) internal view returns (uint256 r) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            if iszero(staticcall(gas(), target, m, 0x24, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            if lt(returndatasize(), 0x20) { revert(0, 0) }
            r := mload(0)
        }
    }

    /// @dev Calls `selector` on `target` with the word arguments `a` and `b` and no value. The
    ///      calldata is 68 bytes: solc-compiled targets ignore arguments a function does not read.
    ///      Returns the first word of the return data, zero when there is none. Reverts with the
    ///      target's revert data and when the target has no code.
    function _call(address target, bytes4 selector, uint256 a, uint256 b) internal returns (uint256 r) {
        assembly ("memory-safe") {
            if iszero(extcodesize(target)) { revert(0, 0) }
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            mstore(add(m, 0x24), b)
            mstore(0, 0)
            if iszero(call(gas(), target, 0, m, 0x44, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            r := mload(0)
        }
    }

    /// @dev `_call` with `value` wei and a third word argument `c`. The calldata is 100 bytes.
    function _callFull(address target, uint256 value, bytes4 selector, uint256 a, uint256 b, uint256 c)
        internal
        returns (uint256 r)
    {
        assembly ("memory-safe") {
            if iszero(extcodesize(target)) { revert(0, 0) }
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), a)
            mstore(add(m, 0x24), b)
            mstore(add(m, 0x44), c)
            mstore(0, 0)
            if iszero(call(gas(), target, value, m, 0x64, 0, 0x20)) {
                returndatacopy(m, 0, returndatasize())
                revert(m, returndatasize())
            }
            r := mload(0)
        }
    }

    /// @dev Creates a Draw Pack owned by this contract from the Shapes `shapeIds` it owns and the
    ///      Shapes minted by `counts`, paying `value`. Reverts unless the pack's value is
    ///      `expected`.
    function _createPack(uint256[] memory shapeIds, uint32[] memory counts, uint256 value, uint256 expected)
        internal
        returns (uint256 packId)
    {
        packId = IShapePacks(drawPacks).createPack{value: value}(shapeIds, counts);
        _checkPackValue(packId, expected);
    }

    /// @dev Reverts `PackValueMismatch` unless Draw Pack `packId` holds `expected` wei of backing.
    function _checkPackValue(uint256 packId, uint256 expected) internal view {
        if (_read(drawPacks, IERC721Value.valueOf.selector, packId) != expected) revert PackValueMismatch();
    }

    /// @dev Lists every held item on the FWA pool in chunks of `MAX_INVENTORY_BATCH` and moves
    ///      each to the listed map under its listing id.
    function _listHeld(uint256 fee) internal {
        uint256 listed = _held.length;
        if (listed == 0) return;
        uint256 batch = _read(address(fwaPool), IFWAClone.MAX_INVENTORY_BATCH.selector, 0);
        FeeSplit memory split = feeSplit;
        uint256 remaining = listed;
        while (remaining != 0) {
            uint256 n = remaining < batch ? remaining : batch;
            IFWAClone.InventoryInput[] memory inputs = new IFWAClone.InventoryInput[](n);
            for (uint256 i; i < n; ++i) {
                Item storage it = _held[remaining - 1 - i];
                inputs[i] = IFWAClone.InventoryInput(it.collection, it.tokenId, _listingPrice(it, fee, split));
            }
            uint256[] memory ids = fwaPool.listNFTs(inputs);
            for (uint256 i; i < n; ++i) {
                Item memory it = _removeHeld(remaining - 1 - i);
                it.listingId = ids[i];
                _addItem(it);
            }
            remaining -= n;
        }
    }

    function _listingPrice(Item storage it, uint256 fee, FeeSplit memory split) internal view returns (uint256) {
        uint256 value = it.value;
        return PricingLib.listingPrice(
            value,
            split.premiumBps,
            split.maintenanceBps,
            split.feedBps,
            PricingLib.mintLineBps(fee * _mix[it.row].rungs.length, value)
        );
    }

    // ------------------------------------------------------------------ GRAIL

    /// @dev One rotation step for track `t`: grows it when ready, otherwise lists an unlisted pack
    ///      or lowers the list price by the decay accrued since the last listing or reprice. The
    ///      new price is `PricingLib.decayedNotional`, which is at least `floorWei`; a listed
    ///      track is repriced only when that price is below the current one. Returns whether the
    ///      FWA listing changed. `busy` is true while FWA holds unsettled acquisitions, which lock
    ///      repricing and withdrawal.
    function _rotateGrail(uint256 t, bool busy) internal returns (bool) {
        if (_growGrail(t, busy) == 0) return true;
        Grail storage g = grail[t];
        if (g.packId == 0 || busy) return false;
        uint256 next = PricingLib.decayedNotional(g.notional, g.decayWeiPerPull, g.pullsSinceList, g.floorWei);
        if (g.listingId != 0 && next >= g.notional) return false;
        _priceGrail(t, g, next);
        return true;
    }

    /// @dev Adds `stepWei` of backing to track `t`, paid from `grail[t].bucket` with the mint fees
    ///      of the Shapes in `defaultMakeup(stepWei)`, then lists the pack. The track's FWA listing
    ///      is withdrawn first. Returns 0 on success, 1 when the track is not ready and 2 when
    ///      `busy`. A listing made while acquisitions are unsettled is staged and cannot be
    ///      repriced or withdrawn, so the busy check applies whether or not the pack is listed.
    ///      When the new `backing` equals a native denomination, the pack is opened, its Shapes
    ///      (ids from `contentsOf` before `open`) are composed into the first one, and that Shape
    ///      is packed again.
    function _growGrail(uint256 t, bool busy) internal returns (uint256) {
        Grail storage g = grail[t];
        if (g.backing >= g.targetWei) return 1;
        uint256 step = g.stepWei;
        uint32[] memory counts = IShapePacks(drawPacks).defaultMakeup(step);
        uint256 shapeCount;
        for (uint256 i; i < counts.length; ++i) {
            shapeCount += counts[i];
        }
        uint256 cost = step + _mintFee() * shapeCount;
        if (g.bucket < cost) return 1;
        if (busy) return 2;
        _unlistGrail(g);

        g.bucket -= cost;
        uint256 total = g.backing + step;
        g.backing = total;
        uint256 packId = g.packId;
        uint256[] memory shapeIds = new uint256[](0);
        if (packId != 0) {
            IShapePacks(drawPacks).addToPack{value: cost}(packId, shapeIds, counts);
            if (Denominations.isSupported(total)) {
                shapeIds = _composePack(packId);
                counts = new uint32[](Denominations.COUNT);
                cost = 0;
                packId = 0;
            } else {
                _checkPackValue(packId, total);
            }
        }
        if (packId == 0) g.packId = _createPack(shapeIds, counts, cost, total);

        uint256 notional = PricingLib.grailNotional(total, g.listBps);
        _priceGrail(t, g, notional);
        emit GrailGrown(t, g.packId, total, notional);
        return 0;
    }

    /// @dev Opens pack `packId`, composes its Shapes into the first one and returns that Shape's
    ///      id in a one element array.
    function _composePack(uint256 packId) internal returns (uint256[] memory survivor) {
        IShapePacks packs = IShapePacks(drawPacks);
        uint256[] memory ids = packs.contentsOf(packId);
        packs.open(packId);
        uint256[] memory burn = new uint256[](ids.length - 1);
        for (uint256 i; i < burn.length; ++i) {
            burn[i] = ids[i + 1];
        }
        IShapes(shapes).compose(ids[0], burn);
        _call(shapes, IERC721.approve.selector, uint160(address(packs)), ids[0]);
        survivor = new uint256[](1);
        survivor[0] = ids[0];
    }

    /// @dev Sets track `t`'s FWA list price to `notional`: lists the pack when it is unlisted,
    ///      otherwise reprices the listing. Restarts the decay count.
    function _priceGrail(uint256 t, Grail storage g, uint256 notional) internal {
        uint256 id = g.listingId;
        if (id == 0) {
            id = _callFull(address(fwaPool), 0, IFWAClone.listNFT.selector, uint160(drawPacks), g.packId, notional);
        } else {
            _call(address(fwaPool), IFWAClone.updatePrice.selector, id, notional);
        }
        g.listingId = id;
        g.notional = notional;
        g.pullsSinceList = 0;
        emit GrailListed(t, id, notional);
    }

    function _initGrail(uint256 track, GrailParams memory g) internal {
        if (g.listBps == 0 || g.listBps > BPS) revert ListBpsOutOfRange();
        if (g.stepWei == 0 || g.stepWei % Denominations.UNIT != 0) revert GrailStepInvalid();
        Grail storage t = grail[track];
        t.targetWei = g.targetWei;
        t.stepWei = g.stepWei;
        t.listBps = g.listBps;
        t.decayWeiPerPull = g.decayWeiPerPull;
        t.floorWei = g.floorWei;
    }

    /// @dev Replaces the mix table. Each row must have rungs inside the Shapes ladder.
    function _setMix(PricingLib.MixRow[] memory rows) internal {
        delete _mix;
        delete _rowBackingWei;
        for (uint256 i; i < rows.length; ++i) {
            _rowBackingWei.push(PricingLib.rowBacking(rows[i]));
            if (_rowCount.length < rows.length) {
                _rowCount.push();
                _listedByRow.push();
            }
            _mix.push();
            PricingLib.MixRow storage row = _mix[i];
            row.shareBps = rows[i].shareBps;
            for (uint256 j; j < rows[i].rungs.length; ++j) {
                row.rungs.push(rows[i].rungs[j]);
            }
        }
    }
}
