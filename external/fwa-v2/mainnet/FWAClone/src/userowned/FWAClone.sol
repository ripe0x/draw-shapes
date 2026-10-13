// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Solady
import {ERC721} from "solady/src/tokens/ERC721.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// Chainlink VRF v2.5 — singleton subscription model. The shared service/router is this pool's logical
// coordinator and is the only caller authorized to forward an authenticated word. The router alone
// inherits Chainlink's official consumer base and is the real subscription's sole consumer.
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {FWAConfigKeys} from "../FWAConfigKeys.sol";
import {IFWACloneFactory} from "./interfaces/IFWACloneFactory.sol";
import {IPurchaseOperator} from "./interfaces/IPurchaseOperator.sol";

interface IFWAVRFService {
    function requestFee() external view returns (uint256);
    function prepareRequests(uint256 requestCount) external payable;
}

/// @title FWAClone
/// @notice A factory-created, user-owned randomized NFT pool. The pool owner is the only inventory
///         supplier and assigns each escrowed NFT an arbitrary notional price. Price determines both
///         the acquisition cost and inverse selection weight (`NUM / price`). A successful ordered
///         Chainlink VRF draw removes the selected listing and delivers its NFT directly to the buyer.
/// @dev Economic design:
///      - Acquisitions are priced at the pool's expected value times a protocol surcharge:
///        `EV = Σ(weightᵢ·priceᵢ) / Σweightᵢ`. With inverse weights this is the harmonic
///        mean of owner-assigned prices. Prices are not appraisals or escrowed backing.
///      - The base acquisition price plus half of the factory edge accrues to the pool owner. The
///        other half of the edge accrues for the factory's live protocol fee recipient.
///      - Owner-driven listing, withdrawal, and repricing changes increment an exact version and
///        start the factory-wide cooldown. Buyers bind requests to that version and a deadline.
///      Selection runs in O(TREE_DEPTH) via a sparse segment tree over active listing slots.
///      Uses Chainlink VRF v2.5 SUBSCRIPTION (native payment): an external `FWAVRFService` receives each
///      purchaser's service fee, pre-funds callback coverage, and may use only proven surplus to sponsor
///      canonical processing. Request IDs, cached callbacks, staging, and ordered settlement retain
///      FWA's original anti-steering behavior.
contract FWAClone is Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum ListingStatus {
        None,
        Active,
        Allocated,
        Withdrawn,
        Settled,
        // A listing made while an acquisition is unresolved: escrowed but NOT yet in the selection
        // pool. A later request may reserve it before asking VRF; otherwise it activates once the
        // sequencer is idle. Appended last so pre-existing numeric listing states remain stable.
        Staged,
        // The selected NFT could not be atomically delivered. Its purchaser and paid price are
        // immutable while permissionless retries remain open.
        DeliveryPending,
        // The delivery deadline elapsed and the purchaser took a refund. The NFT remains quarantined
        // until the pool owner atomically recovers it; it is never reinserted automatically.
        DeliveryRefunded
    }

    enum AcquisitionStatus {
        None,
        Pending, // waiting for an on-time VRF word
        Fulfilled,
        Expired, // skipped in sequence after its word deadline; escrowed fee credited for withdrawal
        Refunded, // no listing / slippage refund; escrowed fee credited for withdrawal
        Ready, // an on-time word is cached and must be settled in request order
        TimedOut, // a callback arrived after its deadline; the request is skipped when it reaches the head
        DeliveryPending, // selected NFT quarantined; acquisition payment remains in delivery escrow
        DeliveryRefunded // delivery deadline elapsed and the purchaser converted escrow to refund credit

    }

    struct ListingInput {
        address collection;
        uint256 tokenId;
        uint256 price;
    }

    struct Listing {
        address collection;
        address depositor;
        address purchaser;
        uint256 tokenId;
        uint256 weight; // selection weight; derived as NUM / price (weight ∝ 1 / price)
        uint256 price; // owner-assigned notional price; no ETH backs this amount
        uint256 slot;
        ListingStatus status;
    }

    struct Acquisition {
        address purchaser;
        uint256 requestBlock;
        uint256 priceEscrowed; // acquisition fee held until the acquisition settles (distributed) or is refunded
        uint256 listingId;
        AcquisitionStatus status;
    }

    /// @dev Sequencing fields are separate so the existing public `acquisitions(requestId)` getter ABI
    ///      remains stable for indexers. Every value is fixed at request time except `randomWord`, which
    ///      the authenticated VRF callback writes exactly once.
    struct AcquisitionMeta {
        uint64 sequence;
        uint64 wordDeadlineBlock;
        uint64 rewardEpoch;
        uint16 maxPositiveSlippageBps;
        uint16 maxNegativeSlippageBps;
        uint256 randomWord;
    }

    struct PendingDelivery {
        uint256 requestId;
        uint64 deadline;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /*
        Supports 2^32 simultaneously active listings.

        This does NOT allocate 2^32 storage slots. The tree is a mapping,
        so only nodes that are actually touched consume storage.

        Each insertion/removal/selection takes roughly TREE_DEPTH steps.
    */
    uint256 internal constant TREE_DEPTH = 32;
    uint256 internal constant CAPACITY = 1 << TREE_DEPTH;

    /*
        Segment tree layout:

                           node 1
                         /        \
                    node 2         node 3
                    / ...           ... \

        Leaves begin at index CAPACITY.

        Listing slot 1           => tree node CAPACITY
        Listing slot 2           => tree node CAPACITY + 1
        Listing slot CAPACITY    => tree node (2 * CAPACITY) - 1
    */
    uint256 internal constant LEAF_BASE = CAPACITY;

    /// @notice Denominator for basis-point math.
    uint256 public constant BPS = 10_000;

    /// @notice Factory compatibility discriminator for standard, unbacked pools.
    uint8 public constant IMPLEMENTATION_KIND = 1;

    /// @notice Maximum listings supplied or withdrawn atomically by one inventory call.
    uint256 public constant MAX_INVENTORY_BATCH = 20;

    /// @notice Fixed-point numerator for the inverse selection weight. A listing's acquisition weight is
    ///         `INVERSE_WEIGHT_NUMERATOR / price`, so selection weight is inversely proportional to price.
    ///         As a shared constant it cancels in the relative selection weight between any two listings and
    ///         only sets the absolute precision of the weights; sized far above any realistic
    ///         price so `NUM / price` never rounds to zero for a sane listing.
    uint256 internal constant INVERSE_WEIGHT_NUMERATOR = 1e36;
    uint256 internal constant NFT_DELIVERY_GAS = 150_000;
    uint256 internal constant PURCHASE_OPERATOR_GAS = 100_000;

    /// @notice Fixed time allowed for permissionless delivery retries before the purchaser may refund.
    uint256 public constant DELIVERY_WINDOW = 7 days;

    /*//////////////////////////////////////////////////////////////
                              VRF CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Logical coordinator: the immutable singleton service/router, which requests from the
    ///         real Chainlink coordinator and forwards only authenticated stored words.
    IVRFCoordinatorV2Plus internal s_vrfCoordinator;

    /// @notice Singleton subscription ID embedded in the exact request tuple validated by the router.
    uint256 internal vrfSubId;

    /// @notice Immutable fee, subscription-funding, request-routing, and callback-forwarding module.
    IFWAVRFService public immutable vrfService;

    /// @notice Factory that deployed and permanently governs the clone's global policy.
    address public immutable FACTORY;

    /// @notice VRF gas lane (key hash) selecting the price ceiling for requests. It can be changed only
    ///         through the immutable service together with the callback coverage underwriting it.
    bytes32 internal vrfKeyHash;

    /// @notice Number of random words requested per acquisition.
    uint32 internal constant NUM_WORDS = 1;

    /// @notice Gas limit for the cache-first VRF callback. With at least
    ///         `MIN_FAST_PATH_CALLBACK_GAS_LIMIT`, an in-order word whose request owns no reserved
    ///         listings gets one failure-isolated settlement attempt; every other word remains cached
    ///         for the public processor. Adjustable only through the immutable service while paused.
    uint32 public callbackGasLimit;
    uint32 public constant MIN_CALLBACK_GAS_LIMIT = 150_000;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;

    /// @dev The fast path forwards a fixed stipend into the existing guarded one-item processor and
    ///      retains enough parent gas to return successfully even if the subcall consumes its stipend.
    uint32 internal constant MIN_FAST_PATH_CALLBACK_GAS_LIMIT = 900_000;
    uint256 internal constant CALLBACK_FAST_PATH_GAS = 700_000;
    uint256 internal constant CALLBACK_RETURN_GAS_RESERVE = 50_000;

    /// @notice Block confirmations the coordinator waits before responding. Constrained to Chainlink's
    ///         supported 3..200 range, with at least `MIN_CALLBACK_SLACK_BLOCKS` before the word deadline.
    uint16 internal requestConfirmations = 3;

    /// @notice Floor on `requestConfirmations`. It is the security axiom — no VRF word can exist before
    ///         this many blocks — so the setters never let it drop below the Chainlink minimum of 3.
    uint256 internal constant MIN_REQUEST_CONFIRMATIONS = 3;
    uint256 internal constant MAX_REQUEST_CONFIRMATIONS = 200;
    uint256 internal constant MIN_CALLBACK_SLACK_BLOCKS = 2;

    /*//////////////////////////////////////////////////////////////
                         ACQUISITION SEQUENCER
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum FIFO staged listings committed to each acquisition before its VRF request.
    ///         The callback never activates them; the canonical processor activates exactly this
    ///         request-time batch immediately before settling that sequence.
    uint256 internal maxActivationsPerAcquisition = 6;
    uint256 internal constant MAX_ACTIVATIONS_PER_ACQUISITION = 16;

    /// @notice Number of requests still waiting for a callback. A cached word reduces this counter but
    ///         remains unresolved until canonical processing advances its sequence.
    uint256 public pendingAcquisitionCount;

    /// @notice Number of issued VRF requests for which the authenticated coordinator callback has not
    ///         yet been observed. Unlike `pendingAcquisitionCount`, local expiry does not reduce this:
    ///         Chainlink may still fulfill and bill the subscription later.
    uint256 public unfulfilledVrfCount;

    /// @dev First-callback marker keeps `unfulfilledVrfCount` duplicate-safe, including after local expiry.
    mapping(uint256 requestId => bool observed) internal callbackObserved;

    /// @notice Number of issued acquisitions not yet terminally processed. This is the pool-mutation
    ///         lock: it remains non-zero after words are cached and only falls as the sequence advances.
    uint256 public unsettledAcquisitionCount;

    /// @notice Absolute per-request word deadline offset. A callback at `requestBlock + timeout` is
    ///         accepted; a callback after it is permanently late. Snapshotted into each acquisition.
    uint256 public selectionTimeoutBlocks = 30;

    /// @notice Upper bound on the configurable word deadline.
    uint256 internal constant MAX_WINDOW_BLOCKS = 7_200;

    /// @notice Max acquisitions a single `acquireBatch` batch may fire, bounding the request-tx loop.
    ///         Owner-adjustable.
    uint256 internal maxAcquisitionsPerTx = 5;

    /// @notice Monotonic request sequence. VRF callbacks may arrive in any order, but only
    ///         `nextSequenceToProcess` may mutate the pool.
    uint64 public lastIssuedSequence;
    uint64 public nextSequenceToProcess = 1;

    /// @notice Gates acquisitions. Starts `false` so the pool deploys in a "loading" phase: listings
    ///         and withdrawals work, but no one can acquisition until the owner opens the game. Owner
    ///         flips it on with `setBool(ACQUISITIONS_ENABLED, true)`.
    bool internal acquisitionsEnabled;

    /// @notice Irreversible owner-selected retirement state. Retirement blocks every new purchase and
    ///         owner configuration/inventory input while preserving all settlement and exit paths.
    bool public retired;

    /// @notice Optional pool-local purchase policy. Zero keeps purchases permissionless; otherwise the
    ///         configured contract must return canonical ABI `true` for the purchaser at request time.
    address public purchaseOperator;

    /*//////////////////////////////////////////////////////////////
                            ECONOMIC CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Protocol maximum positive price drift accepted at ordered settlement. Snapshotted per
    ///         request. Purchasers may separately choose their maximum negative drift, up to 100%.
    uint256 public selectionSlippageBps = 1_000; // 10%

    /// @notice Monotonic version of owner-driven selection changes. Buyers must submit the exact
    ///         version they quoted so a listing, withdrawal, or reprice cannot execute ahead of them.
    uint256 public inventoryVersion;

    /// @notice Timestamp of the latest owner-driven inventory or price mutation in this clone.
    uint64 public lastInventoryChangeAt;

    /*//////////////////////////////////////////////////////////////
                            LISTING STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public nextListingId = 1;

    mapping(uint256 listingId => Listing) public listings;

    /// @notice Request and immutable deadline for a quarantined selected NFT.
    mapping(uint256 listingId => PendingDelivery delivery) public pendingDeliveries;

    /// @notice Acquisition payments held until verified NFT delivery or a purchaser refund.
    uint256 public deliveryEscrowTotal;

    /// @dev One authoritative custody record per collection/token. It remains set across Active,
    ///      Staged, and DeliveryPending/DeliveryRefunded states and is cleared only by a verified exit.
    mapping(address collection => mapping(uint256 tokenId => uint256 listingId)) internal liveNFTListing;

    /*//////////////////////////////////////////////////////////////
                          STAGING QUEUE (FIFO)
    //////////////////////////////////////////////////////////////*/

    /*
        Deposits made while an acquisition is unresolved are parked here — escrowed but excluded from
        every pool total and from the selection tree. Each later acquisition detaches up to
        `maxActivationsPerAcquisition` entries from the FIFO into its immutable reserved batch before
        requesting VRF. The canonical processor activates exactly that batch at the acquisition's turn.
    */
    uint256 internal stagingHead; // first (oldest) staged listing; 0 when empty
    uint256 internal stagingTail; // last (newest) staged listing; 0 when empty
    mapping(uint256 listingId => uint256) internal stagingNext; // toward the tail; 0 = none
    mapping(uint256 listingId => uint256) internal stagingPrev; // toward the head; 0 = none

    /// @notice Unreserved staging-queue length, kept in lockstep with the FIFO.
    uint256 internal stagedCount;

    /// @notice Optional cap on the unreserved staging FIFO (`0` = unlimited, the default). This is
    ///         an operational throttle only; request-time reservation, not queue length, provides the
    ///         anti-steering boundary. Owner-set via `setUint(MAX_STAGED_LISTINGS, ...)`.
    uint256 internal maxStagedListings;

    /// @notice Sequence that owns a detached staged listing; zero means it remains unreserved.
    mapping(uint256 listingId => uint64 sequence) public reservedForSequence;
    uint256 public reservedStagedCount;

    /// @dev Exact request-time activation batch. Its length is bounded by
    ///      `maxActivationsPerAcquisition`, and its entries are removed from the public staging FIFO.
    mapping(uint64 sequence => uint256[]) internal reservedListingsBySequence;

    /*
        Active slot => permanent listing ID.

        A listing ID is never reused.
        A tree slot can be reused after its listing leaves the active pool.
    */
    mapping(uint256 slot => uint256 listingId) public slotToListing;

    uint256 public activeListingCount;
    uint256 public totalWeight;

    /// @notice Σ(weightᵢ · priceᵢ) over active listings. Drives the expected-value acquisition price:
    ///         with inverse weights each term `weightᵢ·priceᵢ ≈ NUM`, so this tracks
    ///         ≈ `activeListingCount · NUM` and `weightedBackingTotal / totalWeight` works out to
    ///         the harmonic mean of the owner-assigned prices. The historical variable name is retained
    ///         in the ABI for compatibility; it does not represent escrowed backing.
    uint256 public weightedBackingTotal;

    /// @notice Purchase proceeds withdrawable by this clone's permanently locked owner.
    uint256 public ownerProceeds;

    /// @notice Half-edge protocol fees awaiting a permissionless push to the factory-wired recipient.
    uint256 public accruedProtocolFees;

    /*//////////////////////////////////////////////////////////////
                          SPARSE SEGMENT TREE
    //////////////////////////////////////////////////////////////*/

    /*
        tree[node] contains the total weight beneath that node.

        This replaces a giant array. Unused nodes simply return zero.
    */
    mapping(uint256 node => uint256 weight) internal tree;

    /*//////////////////////////////////////////////////////////////
                            SLOT FREE LIST
    //////////////////////////////////////////////////////////////*/

    /*
        Slots are initially allocated sequentially.

        When a listing is allocated or withdrawn, its slot is placed into
        a linked-list free pool and can be assigned to another listing.
    */
    uint256 internal nextUnusedSlot = 1;
    uint256 internal freeSlotHead;

    mapping(uint256 slot => uint256 nextFreeSlot) internal nextFreeSlot;

    /*//////////////////////////////////////////////////////////////
                              ACQUISITION STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 requestId => Acquisition) public acquisitions;
    mapping(uint256 requestId => AcquisitionMeta) public acquisitionMeta;
    mapping(uint64 sequence => uint256 requestId) public requestIdAtSequence;

    /// @notice Pull-based acquisition refunds. Ordered processing never calls an untrusted purchaser.
    mapping(address purchaser => uint256 amount) public acquisitionRefundCredit;
    uint256 public acquisitionRefundCreditTotal;
    uint256 public acquisitionEscrowTotal;

    /// @dev The base price is snapshotted at request time so a later global edge change cannot alter
    ///      the already-paid owner/protocol split.
    mapping(uint256 requestId => uint256 basePrice) internal requestBasePrice;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event NFTListed(
        uint256 indexed listingId,
        uint256 indexed slot,
        address indexed depositor,
        address collection,
        uint256 tokenId,
        uint256 weight,
        uint256 price
    );

    /// @param price The listing's notional price, so an indexer can debit the pool's active value
    ///        from this event alone (no join back to `NFTListed`).
    event ListingWithdrawn(uint256 indexed listingId, address indexed depositor, uint256 price);

    /// @dev A listing landed while an acquisition was unresolved (or behind an older FIFO entry), so
    ///      it was parked outside the selection tree. `stagedAtBlock` is informational; a later request
    ///      may reserve the listing before VRF, otherwise it activates after the sequencer becomes idle.
    event ListingStaged(
        uint256 indexed listingId,
        address indexed depositor,
        address collection,
        uint256 tokenId,
        uint256 price,
        uint256 stagedAtBlock
    );

    /// @dev The owner re-priced an active listing. `newWeight` lets an indexer update
    ///      the active pool weight/value from this event alone.
    event PriceUpdated(
        uint256 indexed listingId, address indexed depositor, uint256 oldPrice, uint256 newPrice, uint256 newWeight
    );

    event InventoryChanged(uint256 indexed version, uint64 changedAt);

    event AcquisitionRequested(
        uint256 indexed requestId, address indexed purchaser, uint256 acquisitionFee, uint256 totalWeight
    );

    /// @dev Local sequence and immutable timeout assigned to a VRF request. `reservedCount` is the
    ///      exact FIFO activation batch committed before randomness was requested.
    event AcquisitionSequenced(
        uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 reservedCount
    );

    event RandomnessCached(uint256 indexed requestId, uint64 indexed sequence, uint256 randomWord);
    event RandomnessTimedOut(
        uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 callbackBlock
    );
    event FulfillmentIgnored(uint256 indexed requestId, AcquisitionStatus status);
    event UnfulfilledVrfReconciled(uint256 count);
    /// @dev `processor` is `address(this)` when the failure-isolated callback self-call succeeds;
    ///      otherwise it is the address that called the public processor.
    event AcquisitionProcessed(
        uint256 indexed requestId, uint64 indexed sequence, AcquisitionStatus status, address indexed processor
    );
    event AcquisitionRefundWithdrawn(address indexed purchaser, uint256 amount);

    event AcquisitionExpired(
        uint256 indexed requestId, uint64 indexed sequence, address indexed purchaser, uint256 refund
    );

    /// @dev Ordered processing reached an empty pool, so no listing could be allocated and the
    ///      escrowed acquisition fee became a purchaser pull credit.
    event AcquisitionRefundedNoListing(uint256 indexed requestId, address indexed purchaser, uint256 refund);

    /// @dev Ordered processing found price drift beyond the request's positive / negative tolerances,
    ///      so the acquisition was refunded instead of paid out. Distinct from
    ///      `AcquisitionRefundedNoListing` so the two refund causes are distinguishable off-chain.
    event AcquisitionRefundedSlippage(
        uint256 indexed requestId, address indexed purchaser, uint256 refund, uint256 escrowedFee, uint256 liveFee
    );

    /// @param depositor The pool owner that supplied the listing, and `price` its notional value, so an indexer can
    ///        debit the pool's active value and attribute the deposit duration from this event
    ///        alone (no join back to `NFTListed`).
    event NFTAllocated(
        uint256 indexed requestId,
        uint256 indexed listingId,
        address indexed purchaser,
        address depositor,
        uint256 price,
        uint256 randomWord
    );

    /// @dev A selected NFT could not be atomically delivered. Its payment remains escrowed and anyone
    ///      may retry the same immutable purchaser destination before the refund path is exercised.
    event NFTDeliveryFailed(uint256 indexed listingId, address indexed recipient, address collection, uint256 tokenId);
    event NFTDeliveryCompleted(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser);
    event NFTDeliveryRefunded(
        uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser, uint256 amount
    );
    event RefundedNFTRecovered(uint256 indexed listingId, address indexed owner);

    event OwnerProceedsAccrued(uint256 indexed requestId, uint256 amount, uint256 total);
    event OwnerProceedsWithdrawn(address indexed owner, uint256 amount);

    /// @dev A single-value owner-config change (`setUint`/`setBool`/`setAddr`). `key` is a
    ///      `FWAConfigKeys` constant (globally unique across the three dispatchers); bools encode
    ///      as 0/1, addresses as `uint256(uint160(a))`, the VRF key hash as `uint256(keyHash)`.
    event ConfigSet(uint256 indexed key, uint256 value);
    /// @dev The payer supplied `amount` wei to the immutable external VRF service.
    event VrfServiceFeePaid(address indexed payer, uint256 amount);
    event ProtocolFeesAccrued(uint256 indexed requestId, uint256 amount, uint256 total);
    event ProtocolFeesPaidOut(address indexed to, uint256 amount);

    event FWACloneInitialized(address indexed owner, address indexed factory, uint256 indexed vrfSubId);
    event PurchaseProceedsAccrued(
        uint256 indexed requestId, address indexed owner, uint256 ownerAmount, uint256 protocolAmount
    );
    event PurchaseOperatorSet(address indexed oldOperator, address indexed newOperator);
    event PoolRetired(address indexed owner);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroPrice();
    error PriceTooHigh();
    error InvalidCollection();
    error ListingNotActive();
    error NotDepositor();
    error NoActiveListings();
    error WithdrawLocked();
    error InvalidTreeResult();
    error ActiveListingCapacityReached();
    error StagingQueueFull();
    error NFTTransferFailed();
    error InsufficientPayment();
    error AcquisitionFeeTooHigh();
    error InvalidAcquisitionCount();
    error InvalidInventoryBatch();
    error PoolValueTooLow();
    error InvalidConfig();
    error NoProceeds();
    error DeliveryNotPending();
    error DeliveryNotRefunded();
    error DeliveryWindowNotElapsed();
    error DeliveryWindowElapsed();
    error NotPurchaser();
    error OnlySelf();
    error NFTAlreadyControlled();
    error StaleNFTController();
    error AcquisitionsNotEnabled();
    error NoProtocolFees();
    error OnlyCoordinator();
    error SequenceInvariantBroken();
    error NoAcquisitionRefund();
    error AcquisitionStateLocked();
    error OnlyVrfService();
    error VrfRequestsPending();
    error DuplicateRequestId();
    error OnlyFactory();
    error OwnerOnlyInventory();
    error FactoryPurchasesDisabled();
    error FactoryWithdrawOnly();
    error VrfRequestsPaused();
    error ConsumerNotReady();
    error FactoryManagedConfig();
    error InventoryVersionMismatch(uint256 expected, uint256 actual);
    error InventoryChangeCooldownActive(uint256 purchasesResumeAt);
    error TransactionExpired(uint256 deadline);
    error OwnershipLocked();
    error PoolAlreadyRetired();
    error InvalidPurchaseOperator();
    error PurchaseNotAllowed();
    error PurchaseOperatorCheckFailed();
    // `Unauthorized()` is inherited from Solady's Ownable.

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Constructor state belongs only to the implementation. Every mutable pool default is
    ///      written by `initialize` because factory pools are minimal proxies.
    constructor(address factory_, address service_) {
        if (factory_ == address(0) || factory_.code.length == 0 || service_ == address(0) || service_.code.length == 0)
        {
            revert InvalidConfig();
        }
        FACTORY = factory_;
        vrfService = IFWAVRFService(service_);
        _initializeOwner(address(1));
    }

    modifier onlyFactory() {
        if (msg.sender != FACTORY) revert OnlyFactory();
        _;
    }

    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }

    /// @dev A pool permanently belongs to its factory-recorded creator. This also keeps inventory
    ///      authority and request-snapshotted revenue ownership aligned.
    function _setOwner(address) internal pure override {
        revert OwnershipLocked();
    }

    /// @notice Initialize a deterministic factory clone. Purchases begin locally disabled.
    function initialize(address poolOwner) external onlyFactory {
        if (owner() != address(0) || poolOwner == address(0)) revert InvalidConfig();

        IFWACloneFactory factory = IFWACloneFactory(FACTORY);
        address service = address(vrfService);
        if (factory.vrfCoordinator() != service) revert InvalidConfig();

        uint256 subId = factory.vrfSubscriptionId();
        bytes32 keyHash = factory.vrfKeyHash();
        uint32 gasLimit = factory.callbackGasLimit();
        uint16 confirmations = factory.requestConfirmations();
        uint32 timeoutBlocks = factory.selectionTimeoutBlocks();
        uint16 activationLimit = factory.maxActivationsPerAcquisition();
        uint16 acquisitionLimit = factory.maxAcquisitionsPerTx();
        uint16 slippageBps = factory.selectionSlippageBps();

        if (
            subId == 0 || keyHash == bytes32(0) || gasLimit < MIN_CALLBACK_GAS_LIMIT
                || gasLimit > MAX_CALLBACK_GAS_LIMIT || confirmations < MIN_REQUEST_CONFIRMATIONS
                || confirmations > MAX_REQUEST_CONFIRMATIONS
                || timeoutBlocks < uint256(confirmations) + MIN_CALLBACK_SLACK_BLOCKS || timeoutBlocks > MAX_WINDOW_BLOCKS
                || activationLimit == 0 || activationLimit > MAX_ACTIVATIONS_PER_ACQUISITION || acquisitionLimit == 0
                || slippageBps > BPS
        ) revert InvalidConfig();

        _initializeOwner(poolOwner);

        s_vrfCoordinator = IVRFCoordinatorV2Plus(service);
        vrfSubId = subId;
        vrfKeyHash = keyHash;
        callbackGasLimit = gasLimit;
        requestConfirmations = confirmations;

        maxActivationsPerAcquisition = activationLimit;
        selectionTimeoutBlocks = timeoutBlocks;
        maxAcquisitionsPerTx = acquisitionLimit;
        nextSequenceToProcess = 1;

        acquisitionsEnabled = false;

        selectionSlippageBps = slippageBps;
        maxStagedListings = factory.maxStagedListings();

        nextListingId = 1;
        nextUnusedSlot = 1;
        if (factory.protocolFeeRecipient() == address(0)) revert InvalidConfig();

        emit FWACloneInitialized(poolOwner, FACTORY, subId);
    }

    function localPurchasesEnabled() external view returns (bool) {
        return acquisitionsEnabled;
    }

    /// @notice The live global fee recipient. Factory governance may rotate it for every clone.
    function protocolFeeRecipient() public view returns (address) {
        return IFWACloneFactory(FACTORY).protocolFeeRecipient();
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT AN ERC721
    //////////////////////////////////////////////////////////////*/

    /// @notice Escrow an ERC721 at an owner-assigned notional price. No backing ETH is accepted.
    /// @dev The owner must approve this contract for the token first. Listings created while an
    ///      acquisition is unresolved retain the canonical staging behavior and cannot steer it.
    function listNFT(address collection, uint256 tokenId, uint256 price)
        external
        nonReentrant
        returns (uint256 listingId)
    {
        _requireInventoryInputAllowed();
        listingId = _listNFT(collection, tokenId, price);
        _recordInventoryChange();
    }

    /// @notice Atomically escrow up to `MAX_INVENTORY_BATCH` NFTs and publish one inventory version.
    /// @dev Each item preserves the single-listing FIFO activation and request-reservation rules.
    function listNFTs(ListingInput[] calldata items) external nonReentrant returns (uint256[] memory listingIds) {
        _requireInventoryInputAllowed();
        uint256 length = items.length;
        _validateInventoryBatch(length);
        listingIds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            ListingInput calldata item = items[i];
            listingIds[i] = _listNFT(item.collection, item.tokenId, item.price);
        }
        _recordInventoryChange();
    }

    function _requireInventoryInputAllowed() internal view {
        if (msg.sender != owner()) revert OwnerOnlyInventory();
        if (retired) revert PoolAlreadyRetired();
        if (IFWACloneFactory(FACTORY).globalWithdrawOnly()) revert FactoryWithdrawOnly();
    }

    function _validateInventoryBatch(uint256 length) internal pure {
        if (length == 0 || length > MAX_INVENTORY_BATCH) revert InvalidInventoryBatch();
    }

    function _listNFT(address collection, uint256 tokenId, uint256 price) internal returns (uint256 listingId) {
        if (price == 0) revert ZeroPrice();
        if (collection.code.length == 0) revert InvalidCollection();
        if (liveNFTListing[collection][tokenId] != 0) revert NFTAlreadyControlled();

        uint256 weight = INVERSE_WEIGHT_NUMERATOR / price;
        if (weight == 0) revert PriceTooHigh();

        /*
            Using transferFrom deliberately instead of safeTransferFrom:

            1. The destination is this known contract.
            2. We do not need an ERC721 receiver callback.
            3. Random safe transfers sent directly to this contract revert
               instead of becoming untracked listings.

            The owner must approve this contract first.
        */
        ERC721(collection).transferFrom(msg.sender, address(this), tokenId);

        if (ERC721(collection).ownerOf(tokenId) != address(this)) {
            revert NFTTransferFailed();
        }

        listingId = nextListingId++;
        liveNFTListing[collection][tokenId] = listingId;

        listings[listingId] = Listing({
            collection: collection,
            depositor: msg.sender,
            purchaser: address(0),
            tokenId: tokenId,
            weight: weight,
            price: price,
            slot: 0,
            status: ListingStatus.Active // provisional — set precisely in the branch below
        });
        // With no unresolved acquisition and no older staging backlog, activate immediately. Otherwise
        // append to staging. A request issued later may reserve it, but every already-issued request has
        // already committed its exact batch and can never observe this new input.
        if (unsettledAcquisitionCount == 0 && stagingHead == 0) {
            _activateListing(listingId);
        } else {
            if (maxStagedListings != 0 && stagedCount >= maxStagedListings) revert StagingQueueFull();
            listings[listingId].status = ListingStatus.Staged;
            _stagingPush(listingId);
            emit ListingStaged(listingId, msg.sender, collection, tokenId, price, block.number);

            // Preserve FIFO if an old unreserved tail survived the last acquisition window: a fresh
            // listing never leapfrogs it merely because the pool is currently idle.
            if (unsettledAcquisitionCount == 0) _drainStaging(maxActivationsPerAcquisition);
        }
    }

    /// @notice Earliest timestamp at which a new purchase may execute under the factory's current
    ///         global cooldown. Reading the duration live makes governance changes apply to all clones.
    function purchasesResumeAt() public view returns (uint256) {
        return uint256(lastInventoryChangeAt) + IFWACloneFactory(FACTORY).inventoryChangeCooldown();
    }

    function _recordInventoryChange() internal {
        uint256 version = inventoryVersion + 1;
        inventoryVersion = version;
        uint64 changedAt = uint64(block.timestamp);
        lastInventoryChangeAt = changedAt;
        emit InventoryChanged(version, changedAt);
    }

    /*//////////////////////////////////////////////////////////////
                          STAGING QUEUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionlessly activate up to `maxCount` unreserved FIFO listings while no acquisition
    ///         remains unresolved. During a window, only the ordered processor may activate the exact
    ///         request-time batches.
    function activateListings(uint256 maxCount) external nonReentrant {
        if (unsettledAcquisitionCount != 0) return;
        _drainStaging(maxCount);
    }

    /// @dev Move a listing — fresh, idle-drained, or from a request's reserved batch — into the active
    ///      selection pool. This function intentionally retains the canonical staging activation points.
    function _activateListing(uint256 listingId) internal {
        Listing storage listing = listings[listingId];

        uint256 price = listing.price;
        uint256 weight = listing.weight;

        uint256 slot = _allocateSlot();
        listing.slot = slot;
        slotToListing[slot] = listingId;

        _addTreeWeight(slot, weight);
        totalWeight += weight;
        weightedBackingTotal += weight * price;
        activeListingCount++;

        listing.status = ListingStatus.Active;

        emit NFTListed(listingId, slot, listing.depositor, listing.collection, listing.tokenId, weight, price);
    }

    /// @dev Activate an unreserved FIFO prefix. Only callable through paths that have established there
    ///      is no unresolved acquisition, so block maturity is unnecessary: sequence commitment is the
    ///      anti-steering boundary.
    function _drainStaging(uint256 maxCount) internal {
        uint256 drained = 0;
        while (drained < maxCount) {
            uint256 head = stagingHead;
            if (head == 0) return;

            _stagingUnlink(head);
            _activateListing(head);
            unchecked {
                drained++;
            }
        }
    }

    /// @dev Detach the exact next FIFO batch before requesting randomness. Listings remain `Staged`
    ///      but no public queue operation can reach them; only their owning sequence can activate them.
    function _reserveStagedBatch(uint64 sequence) internal returns (uint256 count) {
        uint256 maxCount = maxActivationsPerAcquisition;
        while (count < maxCount) {
            uint256 head = stagingHead;
            if (head == 0) break;

            _stagingUnlink(head);
            reservedForSequence[head] = sequence;
            reservedListingsBySequence[sequence].push(head);
            unchecked {
                ++reservedStagedCount;
                ++count;
            }
        }
    }

    /// @dev Activate exactly the batch committed by `sequence`. Called on success and every refund /
    ///      expiry path so timeout changes only the missing random removal, never the staged prefix.
    function _activateReservedBatch(uint64 sequence) internal {
        uint256[] storage batch = reservedListingsBySequence[sequence];
        uint256 length = batch.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 listingId = batch[i];
            if (reservedForSequence[listingId] != sequence || listings[listingId].status != ListingStatus.Staged) {
                revert SequenceInvariantBroken();
            }
            delete reservedForSequence[listingId];
            unchecked {
                --reservedStagedCount;
            }
            _activateListing(listingId);
        }
        delete reservedListingsBySequence[sequence];
    }

    function reservedListingCount(uint64 sequence) external view returns (uint256) {
        return reservedListingsBySequence[sequence].length;
    }

    function reservedListingAt(uint64 sequence, uint256 index) external view returns (uint256) {
        return reservedListingsBySequence[sequence][index];
    }

    /// @dev Push a listing onto the tail of the staging FIFO (doubly-linked).
    function _stagingPush(uint256 listingId) internal {
        uint256 tail = stagingTail;
        stagingPrev[listingId] = tail;
        stagingNext[listingId] = 0;
        if (tail == 0) {
            stagingHead = listingId;
        } else {
            stagingNext[tail] = listingId;
        }
        stagingTail = listingId;
        unchecked {
            ++stagedCount;
        }
    }

    /// @dev Unlink a listing from the staging FIFO in O(1), so reservation / idle activation leaves
    ///      no tombstone for a later prefix walk to scan.
    function _stagingUnlink(uint256 listingId) internal {
        uint256 prev = stagingPrev[listingId];
        uint256 next = stagingNext[listingId];
        if (prev == 0) {
            stagingHead = next;
        } else {
            stagingNext[prev] = next;
        }
        if (next == 0) {
            stagingTail = prev;
        } else {
            stagingPrev[next] = prev;
        }
        delete stagingPrev[listingId];
        delete stagingNext[listingId];
        unchecked {
            --stagedCount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW ACTIVE LISTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Withdrawing or repricing could change an
    ///      already-issued draw. Keep them locked until every issued sequence is terminal, including
    ///      after its word has been cached but before the ordered processor reaches it.
    function _requireExitUnlocked() internal view {
        if (unsettledAcquisitionCount != 0) revert WithdrawLocked();
    }

    /// @notice Withdraw an active listing. There is no backing ETH to return.
    /// @dev Load `listingId` and require it Active and supplied by `msg.sender`.
    function _activeOwned(uint256 listingId) internal view returns (Listing storage listing) {
        listing = listings[listingId];
        if (listing.status != ListingStatus.Active) revert ListingNotActive();
        if (listing.depositor != msg.sender) revert NotDepositor();
    }

    /// @notice Withdraw active or unreserved staged inventory to its depositor.
    function withdrawListing(uint256 listingId) external nonReentrant {
        _withdrawListing(listingId, msg.sender);
        _recordInventoryChange();
    }

    /// @notice Withdraw inventory to a receiver chosen by its depositor.
    function withdrawListingTo(uint256 listingId, address recipient) external nonReentrant {
        _validateInventoryRecipient(recipient);
        _withdrawListing(listingId, recipient);
        _recordInventoryChange();
    }

    /// @notice Atomically withdraw up to `MAX_INVENTORY_BATCH` listings and publish one inventory version.
    function withdrawListingsTo(uint256[] calldata listingIds, address recipient) external nonReentrant {
        _validateInventoryRecipient(recipient);
        uint256 length = listingIds.length;
        _validateInventoryBatch(length);
        for (uint256 i; i < length; ++i) {
            _withdrawListing(listingIds[i], recipient);
        }
        _recordInventoryChange();
    }

    function _validateInventoryRecipient(address recipient) internal view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfig();
    }

    function _withdrawListing(uint256 listingId, address recipient) internal {
        Listing storage listing = listings[listingId];
        ListingStatus status = listing.status;
        if (status == ListingStatus.Active) {
            _requireExitUnlocked();
        } else if (status == ListingStatus.Staged) {
            // Only unreserved inventory is outside every already-issued draw commitment.
            if (reservedForSequence[listingId] != 0) revert WithdrawLocked();
        } else {
            revert ListingNotActive();
        }
        if (listing.depositor != msg.sender) revert NotDepositor();

        uint256 price = listing.price;
        address collection = listing.collection;
        uint256 tokenId = listing.tokenId;
        if (status == ListingStatus.Active) _settleAndRemove(listingId);
        else _stagingUnlink(listingId);
        listing.status = ListingStatus.Withdrawn;
        if (liveNFTListing[collection][tokenId] != listingId) revert StaleNFTController();
        delete liveNFTListing[collection][tokenId];

        ERC721(collection).safeTransferFrom(address(this), recipient, tokenId);

        emit ListingWithdrawn(listingId, msg.sender, price);
    }

    /*//////////////////////////////////////////////////////////////
                           UPDATE LISTING PRICE
    //////////////////////////////////////////////////////////////*/

    /// @notice Change an active listing's notional price and inverse selection weight.
    /// @dev Repricing remains locked while any acquisition is unresolved. It also increments the
    ///      exact inventory version and restarts this clone's factory-defined purchase cooldown.
    /// @param listingId The active listing to re-price.
    /// @param newPrice The new owner-assigned notional price.
    function updatePrice(uint256 listingId, uint256 newPrice) external nonReentrant {
        if (retired) revert PoolAlreadyRetired();
        Listing storage listing = _activeOwned(listingId);

        if (IFWACloneFactory(FACTORY).globalWithdrawOnly()) revert FactoryWithdrawOnly();
        if (newPrice == 0) revert ZeroPrice();
        uint256 oldPrice = listing.price;
        if (newPrice == oldPrice) revert InvalidConfig();
        _requireExitUnlocked();

        uint256 newWeight = INVERSE_WEIGHT_NUMERATOR / newPrice;
        if (newWeight == 0) revert PriceTooHigh();

        uint256 oldWeight = listing.weight;
        uint256 slot = listing.slot;
        if (newWeight > oldWeight) {
            _addTreeWeight(slot, newWeight - oldWeight);
        } else if (newWeight < oldWeight) {
            _removeTreeWeight(slot, oldWeight - newWeight);
        }
        totalWeight = totalWeight - oldWeight + newWeight;
        weightedBackingTotal = weightedBackingTotal - oldWeight * oldPrice + newWeight * newPrice;

        listing.price = newPrice;
        listing.weight = newWeight;
        _recordInventoryChange();

        emit PriceUpdated(listingId, msg.sender, oldPrice, newPrice, newWeight);
    }

    /*//////////////////////////////////////////////////////////////
                             REQUEST A ACQUISITION
    //////////////////////////////////////////////////////////////*/

    /// @notice The external VRF service's purchaser charge for one request.
    /// @dev Relies on `tx.gasprice`; quote via an `eth_call` using the intended transaction gas price.
    function vrfServiceFee() public view returns (uint256) {
        return vrfService.requestFee();
    }

    /// @notice The expected-value-based pool price right now. With
    ///         inverse selection weight the EV is the harmonic mean of the pool's values, so a pool of
    ///         richer listings prices cheaper — you're far more likely to acquisition a low-value listing.
    /// @return acquisitionFee The pool price, `EV · (1 + factory edge)`.
    function acquisitionFee() public view returns (uint256) {
        if (totalWeight == 0) return 0;
        uint256 ev = weightedBackingTotal / totalWeight;
        return ev * (BPS + IFWACloneFactory(FACTORY).edgeBps()) / BPS;
    }

    /// @notice Quote one acquisition, including the FIFO inventory that its purchase would activate.
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total) {
        return quoteAcquisitionPrice(1);
    }

    /// @notice Quote a purchase of `count` acquisitions against its hypothetical idle FIFO activation.
    /// @return fee Pool price per acquisition after that activation.
    /// @return vrf VRF service fee per acquisition (quote using the intended transaction gas price).
    /// @return total Full minimum payment, `count * (fee + vrf)`.
    function quoteAcquisitionPrice(uint256 count) public view returns (uint256 fee, uint256 vrf, uint256 total) {
        if (count == 0 || count > maxAcquisitionsPerTx) revert InvalidAcquisitionCount();
        uint256 weight = totalWeight;
        uint256 weightedValue = weightedBackingTotal;
        if (unsettledAcquisitionCount == 0) {
            uint256 remaining = count * maxActivationsPerAcquisition;
            uint256 listingId = stagingHead;
            while (listingId != 0 && remaining != 0) {
                Listing storage listing = listings[listingId];
                weight += listing.weight;
                weightedValue += listing.weight * listing.price;
                listingId = stagingNext[listingId];
                --remaining;
            }
        }
        if (weight != 0) fee = (weightedValue / weight) * (BPS + IFWACloneFactory(FACTORY).edgeBps()) / BPS;
        vrf = vrfServiceFee();
        total = count * (fee + vrf);
    }

    /// @notice Pay for and request a VRF acquisition against an exact published inventory version. Send at least
    ///         `quoteAcquisitionPrice().total`; any excess is refunded to the caller. Requests are fully concurrent,
    ///         while their cached words settle strictly in the local sequence assigned on-chain.
    /// @dev The acquisition fee remains escrowed until ordered processing distributes it or converts it
    ///      to a pull refund. The separate VRF fee is forwarded before requesting randomness, allowing
    ///      the service to fund callback coverage without touching purchase proceeds.
    /// @param purchaser Recipient of the acquisition, including its NFT, rewards and later refund rights.
    /// @param maxAcquisitionFee Slippage guard: revert if the pool fee exceeds this. `0` disables
    ///        the check. Protects the purchaser from a listing front-running the request and
    ///        raising the price under them.
    /// @param minWeightedValue Slippage guard: revert if `weightedBackingTotal` is below this.
    ///        `0` disables the check. Protects the purchaser from a withdrawal front-running the
    ///        request and pulling listing value out of the pool they paid to acquisition against.
    /// @param expectedInventoryVersion Exact owner-mutation version observed by the buyer.
    /// @param deadline Last timestamp at which this transaction may execute.
    function acquire(
        address purchaser,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 requestId) {
        requestId = _acquire(
            purchaser, maxAcquisitionFee, minWeightedValue, maxNegativeSlippageBps, expectedInventoryVersion, deadline
        );
    }

    function _acquire(
        address purchaser,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) internal returns (uint256 requestId) {
        if (purchaser == address(0)) revert InvalidConfig();
        if (retired) revert PoolAlreadyRetired();
        if (maxNegativeSlippageBps > BPS) revert InvalidConfig();
        _validateInventoryCommitment(expectedInventoryVersion, deadline);
        _validatePurchaseOperator(purchaser);
        if (unsettledAcquisitionCount == 0) _drainStaging(maxActivationsPerAcquisition);

        uint256 fee = _validateAcquisition(maxAcquisitionFee, minWeightedValue);

        uint256 vrf = vrfServiceFee();
        uint256 cost = fee + vrf;
        if (msg.value < cost) revert InsufficientPayment();

        // Effects in the service (including any subscription top-up) roll back if the later VRF request fails.
        vrfService.prepareRequests{value: vrf}(1);
        emit VrfServiceFeePaid(msg.sender, vrf);

        requestId = _openAcquisition(purchaser, fee, maxNegativeSlippageBps);

        // Refund any overpayment above the pool fee + VRF service fee.
        _refund(msg.value - cost);
    }

    /// @notice Acquisition `count` times in one call: fires `count` independent VRF requests (one callback
    ///         each), every one priced, escrowed, settled and slippage-checked exactly like a single
    ///         `acquire`. The caller pays `count * (acquisitionFee + vrfFee)` and receives any overpayment. The pool
    ///         is static during this request, so the slippage guards are checked once for all `count`;
    ///         each acquisition re-checks drift at its own ordered processing turn. Note: only the first acquisition of a batch
    ///         earns the cold-gap FWAToken surcharge slice — the rest are "hot" (gap 0), so batching can't farm
    ///         that bonus.
    /// @param purchaser Recipient of every acquisition, including its NFT, rewards and later refund rights.
    function acquireBatch(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory requestIds) {
        requestIds = _acquireBatch(
            purchaser,
            count,
            maxAcquisitionFee,
            minWeightedValue,
            maxNegativeSlippageBps,
            expectedInventoryVersion,
            deadline
        );
    }

    function _acquireBatch(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) internal returns (uint256[] memory requestIds) {
        if (purchaser == address(0)) revert InvalidConfig();
        if (retired) revert PoolAlreadyRetired();
        if (count == 0 || count > maxAcquisitionsPerTx) revert InvalidAcquisitionCount();
        if (maxNegativeSlippageBps > BPS) revert InvalidConfig();
        _validateInventoryCommitment(expectedInventoryVersion, deadline);
        _validatePurchaseOperator(purchaser);

        if (unsettledAcquisitionCount == 0) _drainStaging(count * maxActivationsPerAcquisition);

        uint256 fee = _validateAcquisition(maxAcquisitionFee, minWeightedValue);

        uint256 vrf = vrfServiceFee();
        uint256 cost = count * (fee + vrf);
        if (msg.value < cost) revert InsufficientPayment();

        uint256 vrfTotal = count * vrf;
        // Reserve all batch callbacks before request #1. The whole transaction is atomic if any request fails.
        vrfService.prepareRequests{value: vrfTotal}(count);
        emit VrfServiceFeePaid(msg.sender, vrfTotal);

        requestIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            requestIds[i] = _openAcquisition(purchaser, fee, maxNegativeSlippageBps);
        }

        _refund(msg.value - cost);
    }

    function _validateInventoryCommitment(uint256 expectedInventoryVersion, uint256 deadline) internal view {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
        uint256 currentVersion = inventoryVersion;
        if (expectedInventoryVersion != currentVersion) {
            revert InventoryVersionMismatch(expectedInventoryVersion, currentVersion);
        }
        uint256 resumeAt = purchasesResumeAt();
        if (block.timestamp < resumeAt) revert InventoryChangeCooldownActive(resumeAt);
    }

    /// @dev A bounded, fixed-output staticcall prevents a configured policy from consuming all
    ///      purchase gas or returning an oversized payload. Only an exact ABI bool word of `1` allows
    ///      the purchase; a canonical `0` denies it and every failed or malformed response fails closed.
    function _validatePurchaseOperator(address purchaser) internal view {
        address operator = purchaseOperator;
        if (operator == address(0)) return;

        bytes memory callData = abi.encodeCall(IPurchaseOperator.canPurchase, (purchaser));
        bool checked;
        bool allowed;
        uint256 gasStipend = PURCHASE_OPERATOR_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            checked := staticcall(gasStipend, operator, add(callData, 0x20), mload(callData), ptr, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { checked := 0 }
            if checked {
                let result := mload(ptr)
                // Only the two canonical ABI bool words are well formed.
                if gt(result, 1) { checked := 0 }
                allowed := eq(result, 1)
            }
        }

        if (!checked) revert PurchaseOperatorCheckFailed();
        if (!allowed) revert PurchaseNotAllowed();
    }

    /// @dev Shared acquisition precondition + slippage checks. Returns the current `acquisitionFee()`. Reverts if
    ///      acquisitions are disabled, the pool is empty, the pool value drifted below `minWeightedValue`, or
    ///      the fee exceeds `maxAcquisitionFee`.
    function _validateAcquisition(uint256 maxAcquisitionFee, uint256 minWeightedValue)
        internal
        view
        returns (uint256 fee)
    {
        if (!acquisitionsEnabled) revert AcquisitionsNotEnabled(); // still in the loading phase

        IFWACloneFactory factory = IFWACloneFactory(FACTORY);
        if (factory.globalWithdrawOnly()) revert FactoryWithdrawOnly();
        if (!factory.globalPurchasesEnabled()) revert FactoryPurchasesDisabled();
        if (!factory.consumerReady(address(this))) revert ConsumerNotReady();
        if (factory.vrfRequestsPaused()) revert VrfRequestsPaused();

        if (totalWeight == 0) revert NoActiveListings();

        // Slippage guards: assert the pool the purchaser saw hasn't shifted under them before
        // this request is mined.
        if (minWeightedValue != 0 && weightedBackingTotal < minWeightedValue) revert PoolValueTooLow();

        fee = acquisitionFee();
        if (maxAcquisitionFee != 0 && fee > maxAcquisitionFee) revert AcquisitionFeeTooHigh();
    }

    /// @dev Open one VRF-backed acquisition and commit its local sequence/batch.
    function _openAcquisition(address purchaser, uint256 fee, uint256 maxNegativeSlippageBps)
        internal
        returns (uint256 requestId)
    {
        uint64 sequence = ++lastIssuedSequence;
        uint256 reservedCount = _reserveStagedBatch(sequence);
        uint64 deadline = uint64(block.number + selectionTimeoutBlocks);

        // The sequence and exact staged batch are committed before the external VRF request. If the
        // coordinator reverts, the entire transaction rolls both commitments back.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );
        if (requestId == 0 || acquisitions[requestId].status != AcquisitionStatus.None) {
            revert DuplicateRequestId();
        }

        acquisitions[requestId] = Acquisition({
            purchaser: purchaser,
            requestBlock: block.number,
            priceEscrowed: fee,
            listingId: 0,
            status: AcquisitionStatus.Pending
        });

        acquisitionMeta[requestId] = AcquisitionMeta({
            sequence: sequence,
            wordDeadlineBlock: deadline,
            rewardEpoch: 0,
            maxPositiveSlippageBps: uint16(selectionSlippageBps),
            maxNegativeSlippageBps: uint16(maxNegativeSlippageBps),
            randomWord: 0
        });
        requestIdAtSequence[sequence] = requestId;

        pendingAcquisitionCount += 1;
        unfulfilledVrfCount += 1;
        unsettledAcquisitionCount += 1;
        acquisitionEscrowTotal += fee;

        emit AcquisitionRequested(requestId, purchaser, fee, totalWeight);
        emit AcquisitionSequenced(requestId, sequence, deadline, reservedCount);

        uint256 basePrice = weightedBackingTotal / totalWeight;
        if (basePrice > fee) basePrice = fee;
        requestBasePrice[requestId] = basePrice;
    }

    /// @dev Refund overpayment above the total acquisition cost, if any.
    function _refund(uint256 amount) internal {
        if (amount != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
    }

    /// @notice Logical router and singleton subscription tuple used by registration checks.
    function vrfCoordinatorAndSubId() external view returns (address coordinator, uint256 subId) {
        coordinator = address(s_vrfCoordinator);
        subId = vrfSubId;
    }

    /// @notice Current gas lane and callback budget, used by the immutable service to bind request
    ///         coverage to the exact tuple FWA will send to Chainlink.
    function vrfRequestConfig() external view returns (bytes32 keyHash, uint32 gasLimit) {
        keyHash = vrfKeyHash;
        gasLimit = callbackGasLimit;
    }

    /// @notice Service-only gas-lane synchronization after an official coordinator migration. The
    ///         singleton must be globally paused and this pool must have no issued work; the owner's
    ///         local purchase preference need not be changed merely to follow Chainlink infrastructure.
    function configureVrfRequest(bytes32 keyHash, uint32 gasLimit) external {
        if (msg.sender != address(vrfService)) revert OnlyVrfService();
        IFWACloneFactory factory = IFWACloneFactory(FACTORY);
        if (
            factory.globalPurchasesEnabled() || !factory.vrfRequestsPaused() || unsettledAcquisitionCount != 0
                || unfulfilledVrfCount != 0
        ) {
            revert AcquisitionStateLocked();
        }
        if (keyHash == bytes32(0) || gasLimit < MIN_CALLBACK_GAS_LIMIT || gasLimit > MAX_CALLBACK_GAS_LIMIT) {
            revert InvalidConfig();
        }
        vrfKeyHash = keyHash;
        callbackGasLimit = gasLimit;
        emit ConfigSet(FWAConfigKeys.VRF_KEY_HASH, uint256(keyHash));
        emit ConfigSet(FWAConfigKeys.CALLBACK_GAS_LIMIT, gasLimit);
    }

    /// @notice Clear callback liabilities that the coordinator has already completed (and potentially
    ///         billed) without a successful consumer callback. Safe only for FWA's dedicated subscription.
    /// @dev Permissionless and fail-closed: the coordinator must report that the subscription has no
    ///      remaining request commitment. Acquisition expiry/processing remains a separate ordered step.
    function reconcileUnfulfilledVrfCount() external returns (uint256 reconciled) {
        reconciled = unfulfilledVrfCount;
        if (reconciled == 0) return 0;
        if (s_vrfCoordinator.pendingRequestExists(vrfSubId)) revert VrfRequestsPending();
        unfulfilledVrfCount = 0;
        emit UnfulfilledVrfReconciled(reconciled);
    }

    /*//////////////////////////////////////////////////////////////
                           CHAINLINK CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice VRF v2.5 fulfillment entrypoint. The coordinator is the ONLY authorized caller — this is
    ///         the hand-rolled equivalent of the Chainlink base's `rawFulfillRandomWords` (we don't
    ///         inherit the base; see the contract header). It caches or rejects the delivered word first,
    ///         then may make one failure-isolated attempt to process the canonical head.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(s_vrfCoordinator)) revert OnlyCoordinator();
        fulfillRandomWords(requestId, randomWords);
    }

    /// @dev Coordinator callback: cache an on-time word or permanently classify it late. Unknown,
    ///      duplicate, terminal and malformed fulfillments return without reverting. Fast-path settlement
    ///      is best effort only; its child failure cannot roll back the cached word.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal {
        Acquisition storage acquisition = acquisitions[requestId];

        // Chainlink bills when the authenticated callback is attempted, even if this acquisition already
        // expired locally or the word array is malformed. Release its external coverage exactly once only
        // for a request this FWA actually issued. Unknown and duplicate callbacks remain harmless.
        if (acquisition.status != AcquisitionStatus.None && !callbackObserved[requestId]) {
            callbackObserved[requestId] = true;
            uint256 count = unfulfilledVrfCount;
            if (count != 0) unfulfilledVrfCount = count - 1;
        }

        if (acquisition.status != AcquisitionStatus.Pending) {
            emit FulfillmentIgnored(requestId, acquisition.status);
            return;
        }

        AcquisitionMeta storage meta = acquisitionMeta[requestId];
        if (block.number > meta.wordDeadlineBlock) {
            acquisition.status = AcquisitionStatus.TimedOut;
            pendingAcquisitionCount -= 1;
            emit RandomnessTimedOut(requestId, meta.sequence, meta.wordDeadlineBlock, block.number);
            return;
        }

        if (randomWords.length == 0) {
            emit FulfillmentIgnored(requestId, acquisition.status);
            return;
        }

        meta.randomWord = randomWords[0];
        acquisition.status = AcquisitionStatus.Ready;
        pendingAcquisitionCount -= 1;
        emit RandomnessCached(requestId, meta.sequence, randomWords[0]);

        _tryProcessCallbackHead(meta.sequence);
    }

    /// @dev Best-effort fast path. The word and callback-liability effects are committed in the parent
    ///      frame before this function runs. The child call reuses the exact permissionless processor,
    ///      including its reentrancy guard; any OOG or invariant failure rolls
    ///      back only the child frame and leaves this acquisition `Ready` for a later processor.
    ///      Return data is deliberately not copied, preventing a reverting callee from consuming the
    ///      parent's return reserve with an oversized revert payload.
    function _tryProcessCallbackHead(uint64 sequence) internal {
        if (
            callbackGasLimit < MIN_FAST_PATH_CALLBACK_GAS_LIMIT || sequence != nextSequenceToProcess
                || reservedListingsBySequence[sequence].length != 0
        ) return;

        if (gasleft() < CALLBACK_FAST_PATH_GAS + CALLBACK_RETURN_GAS_RESERVE) {
            return;
        }

        bytes memory callData = abi.encodeCall(this.processAcquisitions, (1));
        uint256 gasStipend = CALLBACK_FAST_PATH_GAS;
        assembly ("memory-safe") {
            pop(call(gasStipend, address(), 0, add(callData, 0x20), mload(callData), 0, 0))
        }
    }

    /// @notice Process the canonical ready/expired acquisition prefix. The caller chooses only a gas
    ///         batching bound; request IDs and ordering are fixed by `nextSequenceToProcess`.
    function processAcquisitions(uint256 maxCount) external nonReentrant returns (uint256 processed) {
        while (processed < maxCount && nextSequenceToProcess <= lastIssuedSequence) {
            uint64 sequence = nextSequenceToProcess;
            uint256 requestId = requestIdAtSequence[sequence];
            Acquisition storage acquisition = acquisitions[requestId];
            AcquisitionMeta storage meta = acquisitionMeta[requestId];
            if (requestId == 0 || meta.sequence != sequence) revert SequenceInvariantBroken();

            AcquisitionStatus status = acquisition.status;
            if (status == AcquisitionStatus.Pending) {
                if (block.number <= meta.wordDeadlineBlock) break;
                pendingAcquisitionCount -= 1;
                _activateReservedBatch(sequence);
                uint256 refund = _creditAcquisitionRefund(acquisition, AcquisitionStatus.Expired);
                emit AcquisitionExpired(requestId, sequence, acquisition.purchaser, refund);
            } else if (status == AcquisitionStatus.TimedOut) {
                _activateReservedBatch(sequence);
                uint256 refund = _creditAcquisitionRefund(acquisition, AcquisitionStatus.Expired);
                emit AcquisitionExpired(requestId, sequence, acquisition.purchaser, refund);
            } else if (status == AcquisitionStatus.Ready) {
                _activateReservedBatch(sequence);
                _settleReadyAcquisition(requestId, acquisition, meta);
            } else {
                revert SequenceInvariantBroken();
            }

            _finishAcquisition(requestId, acquisition, meta, msg.sender);
            unchecked {
                ++nextSequenceToProcess;
                ++processed;
            }
        }
    }

    function _creditAcquisitionRefund(Acquisition storage acquisition, AcquisitionStatus status)
        internal
        returns (uint256 refund)
    {
        refund = acquisition.priceEscrowed;
        acquisition.status = status;
        acquisitionRefundCredit[acquisition.purchaser] += refund;
        acquisitionRefundCreditTotal += refund;
    }

    function _finishAcquisition(
        uint256 requestId,
        Acquisition storage acquisition,
        AcquisitionMeta storage meta,
        address processor
    ) internal {
        // A failed NFT delivery retains its request-time base price until verified delivery or refund,
        // so later governance changes cannot rewrite the already-paid split.
        if (acquisition.status != AcquisitionStatus.DeliveryPending) {
            delete requestBasePrice[requestId];
        }
        acquisitionEscrowTotal -= acquisition.priceEscrowed;
        unsettledAcquisitionCount -= 1;
        emit AcquisitionProcessed(requestId, meta.sequence, acquisition.status, processor);
    }

    /// @dev Settle a cached word against the pool after its immutable activation batch is applied.
    function _settleReadyAcquisition(uint256 requestId, Acquisition storage acquisition, AcquisitionMeta storage meta)
        internal
    {
        /*
            Empty pool: earlier canonical sequences removed every listing, so nothing can be selected.
            Convert the purchaser's escrowed acquisition fee into a pull credit without any external call.
        */
        if (totalWeight == 0) {
            uint256 refund = _creditAcquisitionRefund(acquisition, AcquisitionStatus.Refunded);
            emit AcquisitionRefundedNoListing(requestId, acquisition.purchaser, refund);
            return;
        }

        /*
            Ordered-settlement slippage guard: re-price against the canonical live pool after this
            sequence's immutable reserved batch is activated. Earlier sequences may have removed listings
            and shifted the fee. Drift outside the request's snapshotted tolerances becomes a pull refund;
            the would-be selected listing remains active.
        */
        {
            uint256 liveFee = acquisitionFee();
            uint256 escrowed = acquisition.priceEscrowed;
            uint256 positiveTolerance = escrowed * meta.maxPositiveSlippageBps / BPS;
            uint256 negativeTolerance = escrowed * meta.maxNegativeSlippageBps / BPS;
            if (
                (liveFee > escrowed && liveFee - escrowed > positiveTolerance)
                    || (liveFee < escrowed && escrowed - liveFee > negativeTolerance)
            ) {
                _creditAcquisitionRefund(acquisition, AcquisitionStatus.Refunded);
                emit AcquisitionRefundedSlippage(requestId, acquisition.purchaser, escrowed, escrowed, liveFee);
                return;
            }
        }

        /*
            Selection resolves against the canonical live pool produced by every earlier sequence plus
            this request's reserved activation batch. Find the slot whose cumulative weight range contains
            the target in TREE_DEPTH descents.
        */
        uint256 randomWord = meta.randomWord;
        uint256 target = randomWord % totalWeight;

        uint256 slot = _selectSlot(target);
        uint256 listingId = slotToListing[slot];

        if (listingId == 0) revert InvalidTreeResult();

        Listing storage listing = listings[listingId];

        if (listing.status != ListingStatus.Active) revert InvalidTreeResult();

        _settleAndRemove(listingId);

        listing.purchaser = acquisition.purchaser;
        listing.status = ListingStatus.DeliveryPending;

        acquisition.listingId = listingId;
        acquisition.status = AcquisitionStatus.DeliveryPending;

        pendingDeliveries[listingId] =
            PendingDelivery({requestId: requestId, deadline: uint64(block.timestamp + DELIVERY_WINDOW)});
        deliveryEscrowTotal += acquisition.priceEscrowed;

        if (_tryAtomicNFTDelivery(listingId)) {
            _completeNFTDelivery(listingId);
        } else {
            emit NFTDeliveryFailed(listingId, acquisition.purchaser, listing.collection, listing.tokenId);
        }

        emit NFTAllocated(requestId, listingId, acquisition.purchaser, listing.depositor, listing.price, randomWord);
    }

    /// @notice Pull acquisition fees credited by ordered expiry, empty-pool, or slippage refunds.
    function withdrawAcquisitionRefund() external nonReentrant returns (uint256 amount) {
        amount = acquisitionRefundCredit[msg.sender];
        if (amount == 0) revert NoAcquisitionRefund();
        acquisitionRefundCredit[msg.sender] = 0;
        acquisitionRefundCreditTotal -= amount;
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
        emit AcquisitionRefundWithdrawn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         NFT DELIVERY ESCROW
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionlessly retry the exact selected NFT-to-purchaser delivery without a gas stipend.
    function retryNFTDelivery(uint256 listingId) external nonReentrant {
        if (listings[listingId].status != ListingStatus.DeliveryPending) revert DeliveryNotPending();
        if (block.timestamp >= pendingDeliveries[listingId].deadline) revert DeliveryWindowElapsed();
        this.executeNFTDelivery(listingId);
        _completeNFTDelivery(listingId);
    }

    /// @notice After the fixed delivery window, the immutable purchaser may convert escrow to a pull refund.
    function refundFailedDelivery(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.DeliveryPending) revert DeliveryNotPending();
        if (msg.sender != listing.purchaser) revert NotPurchaser();

        PendingDelivery memory delivery = pendingDeliveries[listingId];
        if (block.timestamp < delivery.deadline) revert DeliveryWindowNotElapsed();

        Acquisition storage acquisition = acquisitions[delivery.requestId];
        uint256 refund = acquisition.priceEscrowed;
        deliveryEscrowTotal -= refund;
        acquisitionRefundCredit[msg.sender] += refund;
        acquisitionRefundCreditTotal += refund;
        listing.status = ListingStatus.DeliveryRefunded;
        acquisition.status = AcquisitionStatus.DeliveryRefunded;

        delete requestBasePrice[delivery.requestId];
        delete pendingDeliveries[listingId];
        emit NFTDeliveryRefunded(listingId, delivery.requestId, msg.sender, refund);
    }

    /// @notice Recover a quarantined NFT only after its purchaser has taken the delivery refund.
    function recoverRefundedNFT(uint256 listingId) external nonReentrant {
        if (msg.sender != owner()) revert OwnerOnlyInventory();
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.DeliveryRefunded) revert DeliveryNotRefunded();
        this.executeNFTDelivery(listingId);
        listing.status = ListingStatus.Withdrawn;
        emit RefundedNFTRecovered(listingId, msg.sender);
    }

    /// @dev Narrow child frame: controller clear, transfer, and ownership verification commit together.
    ///      Only the pool may invoke it, and the listing state fixes the recipient.
    function executeNFTDelivery(uint256 listingId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Listing storage listing = listings[listingId];
        address recipient;
        if (listing.status == ListingStatus.DeliveryPending) {
            recipient = listing.purchaser;
        } else if (listing.status == ListingStatus.DeliveryRefunded) {
            recipient = owner();
        } else {
            revert DeliveryNotPending();
        }

        address collection = listing.collection;
        uint256 tokenId = listing.tokenId;
        if (liveNFTListing[collection][tokenId] != listingId) revert StaleNFTController();
        delete liveNFTListing[collection][tokenId];

        ERC721(collection).transferFrom(address(this), recipient, tokenId);
        if (ERC721(collection).ownerOf(tokenId) != recipient) revert NFTTransferFailed();
    }

    /// @dev Initial ordered processing bounds the entire atomic child and ignores revert data, keeping
    ///      a malicious collection from blocking the canonical queue.
    function _tryAtomicNFTDelivery(uint256 listingId) internal returns (bool success) {
        bytes memory callData = abi.encodeCall(this.executeNFTDelivery, (listingId));
        uint256 gasStipend = NFT_DELIVERY_GAS;
        assembly ("memory-safe") {
            success := call(gasStipend, address(), 0, add(callData, 0x20), mload(callData), 0, 0)
        }
    }

    function _completeNFTDelivery(uint256 listingId) internal {
        Listing storage listing = listings[listingId];
        if (listing.status != ListingStatus.DeliveryPending) revert DeliveryNotPending();
        PendingDelivery memory delivery = pendingDeliveries[listingId];
        Acquisition storage acquisition = acquisitions[delivery.requestId];
        uint256 paid = acquisition.priceEscrowed;
        uint256 basePrice = requestBasePrice[delivery.requestId];
        if (basePrice > paid) basePrice = paid;
        uint256 protocolAmount = (paid - basePrice) / 2;
        uint256 ownerAmount = paid - protocolAmount;

        deliveryEscrowTotal -= paid;
        ownerProceeds += ownerAmount;
        accruedProtocolFees += protocolAmount;
        listing.status = ListingStatus.Settled;
        acquisition.status = AcquisitionStatus.Fulfilled;

        delete requestBasePrice[delivery.requestId];
        delete pendingDeliveries[listingId];

        emit OwnerProceedsAccrued(delivery.requestId, ownerAmount, ownerProceeds);
        emit ProtocolFeesAccrued(delivery.requestId, protocolAmount, accruedProtocolFees);
        emit PurchaseProceedsAccrued(delivery.requestId, owner(), ownerAmount, protocolAmount);
        emit NFTDeliveryCompleted(listingId, delivery.requestId, listing.purchaser);
    }

    /*//////////////////////////////////////////////////////////////
                         PROCEEDS WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function withdrawOwnerProceeds() external onlyOwner nonReentrant returns (uint256 amount) {
        amount = ownerProceeds;
        if (amount == 0) revert NoProceeds();
        ownerProceeds = 0;
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
        emit OwnerProceedsWithdrawn(msg.sender, amount);
    }

    /// @notice Permissionlessly push the protocol's half-edge to the factory's current fee recipient.
    function payoutProtocolFees() external nonReentrant returns (uint256 amount) {
        amount = accruedProtocolFees;
        if (amount == 0) revert NoProtocolFees();
        accruedProtocolFees = 0;
        address to = IFWACloneFactory(FACTORY).protocolFeeRecipient();
        if (to == address(0)) revert InvalidConfig();
        SafeTransferLib.forceSafeTransferETH(to, amount);
        emit ProtocolFeesPaidOut(to, amount);
    }

    /// @dev A listing's notional EV contribution. With inverse weights this is approximately the
    ///      common numerator for every listing.
    function _evOf(Listing storage listing) internal view returns (uint256) {
        return listing.weight * listing.price;
    }

    /// @dev Remove a listing from the active selection tree and release its reusable slot.
    function _settleAndRemove(uint256 listingId) internal {
        Listing storage listing = listings[listingId];

        uint256 slot = listing.slot;

        _removeTreeWeight(slot, listing.weight);
        totalWeight -= listing.weight;
        weightedBackingTotal -= _evOf(listing);
        activeListingCount--;

        delete slotToListing[slot];
        _releaseSlot(slot);

        listing.slot = 0;
    }

    /*//////////////////////////////////////////////////////////////
                      SEGMENT TREE: ADD WEIGHT
    //////////////////////////////////////////////////////////////*/

    function _addTreeWeight(uint256 slot, uint256 amount) internal {
        uint256 node = LEAF_BASE + slot - 1;

        /*
            Update leaf, then every ancestor through the root.
        */
        while (true) {
            tree[node] += amount;

            if (node == 1) break;

            node >>= 1;
        }
    }

    /*//////////////////////////////////////////////////////////////
                     SEGMENT TREE: REMOVE WEIGHT
    //////////////////////////////////////////////////////////////*/

    function _removeTreeWeight(uint256 slot, uint256 amount) internal {
        uint256 node = LEAF_BASE + slot - 1;

        while (true) {
            tree[node] -= amount;

            if (node == 1) break;

            node >>= 1;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    SEGMENT TREE: SELECT LISTING
    //////////////////////////////////////////////////////////////*/

    function _selectSlot(uint256 target) internal view returns (uint256 slot) {
        /*
            target must be in:

                0 <= target < tree[1]

            At each branch:

            - If target is inside the left subtree, descend left.
            - Otherwise subtract the left subtree's range and descend right.
        */
        uint256 node = 1;

        while (node < LEAF_BASE) {
            uint256 leftChild = node << 1;
            uint256 leftWeight = tree[leftChild];

            if (target < leftWeight) {
                node = leftChild;
            } else {
                target -= leftWeight;
                node = leftChild | 1;
            }
        }

        slot = node - LEAF_BASE + 1;
    }

    /*//////////////////////////////////////////////////////////////
                           SLOT ALLOCATION
    //////////////////////////////////////////////////////////////*/

    function _allocateSlot() internal returns (uint256 slot) {
        /*
            Reuse a previously released slot when possible.
        */
        if (freeSlotHead != 0) {
            slot = freeSlotHead;
            freeSlotHead = nextFreeSlot[slot];

            delete nextFreeSlot[slot];

            return slot;
        }

        /*
            Otherwise expand into the next unused logical slot.

            No array is expanded and no storage is preallocated.
        */
        slot = nextUnusedSlot++;

        if (slot > CAPACITY) revert ActiveListingCapacityReached();
    }

    function _releaseSlot(uint256 slot) internal {
        nextFreeSlot[slot] = freeSlotHead;
        freeSlotHead = slot;
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Let the permanently locked pool owner enable or disable local purchases.
    function setBool(uint256 key, bool value) external onlyOwner {
        if (retired) revert PoolAlreadyRetired();
        if (key != FWAConfigKeys.ACQUISITIONS_ENABLED) revert FactoryManagedConfig();
        acquisitionsEnabled = value;
        emit ConfigSet(key, value ? 1 : 0);
    }

    /// @notice Set or clear this pool's optional purchaser-eligibility policy.
    /// @dev Zero disables the hook. Nonzero values must already contain contract code.
    function setPurchaseOperator(address newOperator) external onlyOwner {
        if (retired) revert PoolAlreadyRetired();
        if (newOperator != address(0) && newOperator.code.length == 0) revert InvalidPurchaseOperator();
        address oldOperator = purchaseOperator;
        purchaseOperator = newOperator;
        emit PurchaseOperatorSet(oldOperator, newOperator);
    }

    /// @notice Permanently close this pool to new purchases, inventory, and owner configuration.
    /// @dev Existing callbacks, ordered processing, claims, withdrawals, and VRF synchronization remain
    ///      available. Retirement deliberately does not require issued work or inventory to be empty.
    function retirePool() external onlyOwner {
        if (retired) revert PoolAlreadyRetired();
        retired = true;
        acquisitionsEnabled = false;
        emit ConfigSet(FWAConfigKeys.ACQUISITIONS_ENABLED, 0);
        emit PoolRetired(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              TREE VIEWS
    //////////////////////////////////////////////////////////////*/

    function treeRootWeight() external view returns (uint256) {
        return tree[1];
    }
}
