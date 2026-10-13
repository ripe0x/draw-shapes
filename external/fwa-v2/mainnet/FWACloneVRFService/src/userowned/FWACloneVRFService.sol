// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {IVRFCoordinatorV2PlusInternal} from
    "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2PlusInternal.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {IFWACloneFactory, IFWACloneVRFHost} from "./interfaces/IFWACloneFactory.sol";

interface IFWACloneRandomnessReceiver {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @title FWACloneVRFService
/// @notice The sole Chainlink consumer and native-subscription treasury for every factory clone.
/// @dev A clone pays for and prepares each request before calling the coordinator-compatible
///      `requestRandomWords` facade. The service returns the real Chainlink request ID, stores the
///      authenticated result before a failure-isolated delivery attempt, and never re-requests a word.
contract FWACloneVRFService is VRFConsumerBaseV2Plus, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint32 public constant NUM_WORDS = 1;
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;

    /// @dev Gas retained after the bounded clone call for terminal storage and event emission.
    uint256 internal constant DELIVERY_RETURN_GAS_RESERVE = 80_000;

    enum RequestStatus {
        None,
        CoordinatorOutstanding,
        WordStored,
        EmptyWordArrayStored,
        Delivered,
        CoordinatorCallbackLost
    }

    address public immutable factory;
    uint256 public immutable subscriptionId;
    bytes32 public approvedVrfKeyHash;
    uint16 public immutable approvedRequestConfirmations;
    uint32 public immutable approvedCallbackGasLimit;
    uint32 public immutable approvedRouterCallbackGasLimit;
    bytes32 public immutable approvedExtraArgsHash;

    uint256 public serviceGasEstimate = 1_100_000;
    uint256 public serviceMarginBps = 3_000;
    uint256 public serviceFlatWei;

    uint256 public minimumSubscriptionBuffer;
    uint256 public maxFulfillmentCostWei;
    uint256 public coverageFloor;

    /// @notice Zero disables the corresponding explicit request limit; coverage remains mandatory.
    uint256 public maxOutstandingPerPool = 10;
    uint256 public maxOutstandingGlobal = 100;

    /// @notice Addresses approved by factory governance to use the reimbursed processing route.
    ///         Every clone's direct processor remains permissionless and unsubsidized.
    mapping(address operator => bool allowed) public operators;

    uint256 public maxSponsoredCount = 10;
    uint256 public maxReimbursementGas = 2_100_000;
    uint256 public reimbursementGasOverhead = 55_000;
    uint256 public maxReimbursementBaseFeeWei = 5 gwei;
    uint256 public maxReimbursementPriorityFeeWei = 1 gwei;
    uint256 public maxReimbursementWei = 0.02 ether;

    bool public subscriptionActive;
    bool public subscriptionTerminated;
    bool public requestsPaused = true;

    uint256 public totalPrepared;
    uint256 public totalCoordinatorOutstanding;

    mapping(address pool => bool registered) public registeredPool;
    mapping(address pool => uint256 credits) public preparedCredits;
    mapping(address pool => uint256 outstanding) public coordinatorOutstandingFor;

    /// @notice A coordinator migration resets its consumer nonce. Never reusing a gas lane prevents
    ///         the new coordinator from recreating a historical real request ID.
    mapping(bytes32 keyHash => bool used) public usedVrfKeyHash;

    mapping(uint256 requestId => address pool) public requestPool;
    mapping(uint256 requestId => RequestStatus status) public requestStatus;
    mapping(uint256 requestId => uint256 word) public storedRandomWord;

    event TreasuryFunded(address indexed sender, uint256 amount);
    event SubscriptionActivated(uint256 indexed subscriptionId, address indexed coordinator);
    event PoolRegistered(address indexed pool);
    event RequestFeesReceived(address indexed pool, uint256 requestCount, uint256 amount);
    event RequestsPrepared(
        address indexed pool,
        uint256 requestCount,
        uint256 poolPrepared,
        uint256 poolCoordinatorOutstanding,
        uint256 globalPrepared,
        uint256 globalCoordinatorOutstanding
    );
    event RandomnessRequested(uint256 indexed requestId, address indexed pool);
    event RandomnessStored(uint256 indexed requestId, address indexed pool, uint256 word, bool hasWord);
    event RandomnessDeliveryDeferred(uint256 indexed requestId, address indexed pool);
    event RandomnessDeliveryFailed(uint256 indexed requestId, address indexed pool);
    event RandomnessDelivered(uint256 indexed requestId, address indexed pool);
    event FulfillmentIgnored(uint256 indexed requestId, RequestStatus status, uint256 wordCount);
    event CoordinatorRequestReconciled(uint256 indexed requestId, address indexed pool);
    event SubscriptionFunded(uint256 indexed subscriptionId, uint256 amount, uint256 requiredBalance);
    event SubscriptionTerminated(address indexed recoveryRecipient, uint256 serviceEthRefund);
    event TerminalEthRecovered(address indexed caller, address indexed recoveryRecipient, uint256 amount);
    event RequestsPausedSet(bool paused);
    event RequestLimitsSet(uint256 maxPerPool, uint256 maxGlobal);
    event VrfKeyHashRotated(bytes32 indexed oldKeyHash, bytes32 indexed newKeyHash, uint256 coverageFloor);
    event PoolRequestConfigSynced(address indexed pool, bytes32 indexed keyHash, uint32 callbackGasLimit);
    event FeeConfigSet(uint256 gasEstimate, uint256 marginBps, uint256 flatWei);
    event CoverageConfigSet(uint256 minimumBuffer, uint256 maxFulfillmentCost);
    event OperatorSet(address indexed operator, bool allowed);
    event ReimbursementConfigSet(
        uint256 maxSponsoredCount,
        uint256 maxReimbursementGas,
        uint256 reimbursementGasOverhead,
        uint256 maxReimbursementBaseFeeWei,
        uint256 maxReimbursementPriorityFeeWei,
        uint256 maxReimbursementWei
    );
    event AcquisitionsSponsored(
        address indexed operator,
        address indexed pool,
        uint256 processed,
        uint256 reimbursableGas,
        uint256 reimbursableGasPrice,
        uint256 reimbursement
    );
    event SurplusWithdrawn(address indexed recipient, uint256 amount);

    error OnlyFactory();
    error OnlyOperator();
    error UnknownPool();
    error AlreadyRegistered();
    error InvalidConfig();
    error InvalidRequestTuple();
    error IncorrectRequestFee();
    error PoolConfigMismatch();
    error PoolNotReady();
    error SubscriptionNotActive();
    error SubscriptionAlreadyActive();
    error VrfServiceTerminated();
    error SubscriptionNotOwnedByFactory();
    error SubscriptionNotPristine();
    error SubscriptionConsumerMismatch();
    error RequestsPaused();
    error PerPoolRequestLimitExceeded();
    error GlobalRequestLimitExceeded();
    error MissingPreparedCredit();
    error DuplicateRequestId();
    error InsufficientVrfCoverage();
    error OutstandingCallbacks();
    error InsufficientSurplus();
    error NoProcessorSurplus();
    error RandomnessNotDeliverable();
    error CoordinatorCommitmentCheckFailed();
    error CoordinatorRequestStillPending();
    error VrfKeyHashAlreadyUsed();

    constructor(
        address factory_,
        address coordinator_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint16 requestConfirmations_,
        uint32 poolCallbackGasLimit_,
        uint32 routerCallbackGasLimit_,
        uint256 minimumBuffer_,
        uint256 maxFulfillmentCost_
    ) VRFConsumerBaseV2Plus(coordinator_) {
        if (
            factory_ == address(0) || factory_.code.length == 0 || coordinator_ == address(0)
                || coordinator_.code.length == 0 || subscriptionId_ == 0 || keyHash_ == bytes32(0)
                || requestConfirmations_ < 3 || requestConfirmations_ > 200 || poolCallbackGasLimit_ == 0
                || routerCallbackGasLimit_ <= poolCallbackGasLimit_ || routerCallbackGasLimit_ > MAX_CALLBACK_GAS_LIMIT
                || minimumBuffer_ == 0 || maxFulfillmentCost_ == 0
        ) revert InvalidConfig();

        factory = factory_;
        subscriptionId = subscriptionId_;
        approvedVrfKeyHash = keyHash_;
        usedVrfKeyHash[keyHash_] = true;
        approvedRequestConfirmations = requestConfirmations_;
        approvedCallbackGasLimit = poolCallbackGasLimit_;
        approvedRouterCallbackGasLimit = routerCallbackGasLimit_;
        approvedExtraArgsHash =
            keccak256(VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true})));

        minimumSubscriptionBuffer = minimumBuffer_;
        maxFulfillmentCostWei = maxFulfillmentCost_;
        coverageFloor = maxFulfillmentCost_;

        // The factory contract must explicitly accept. Governance has no factory method that can call
        // the inherited generic coordinator setter; official coordinator migration remains possible.
        transferOwnership(factory_);

        emit RequestsPausedSet(true);
        emit RequestLimitsSet(maxOutstandingPerPool, maxOutstandingGlobal);
        emit FeeConfigSet(serviceGasEstimate, serviceMarginBps, serviceFlatWei);
        emit CoverageConfigSet(minimumBuffer_, maxFulfillmentCost_);
        emit ReimbursementConfigSet(
            maxSponsoredCount,
            maxReimbursementGas,
            reimbursementGasOverhead,
            maxReimbursementBaseFeeWei,
            maxReimbursementPriorityFeeWei,
            maxReimbursementWei
        );
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender]) revert OnlyOperator();
        _;
    }

    receive() external payable {
        if (subscriptionTerminated) revert VrfServiceTerminated();
        emit TreasuryFunded(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The current real coordinator. It updates only through the official consumer-base path.
    function coordinator() public view returns (address) {
        return address(s_vrfCoordinator);
    }

    function requestConfirmations() external view returns (uint16) {
        return approvedRequestConfirmations;
    }

    function routerCallbackGasLimit() external view returns (uint32) {
        return approvedRouterCallbackGasLimit;
    }

    function maxOutstandingRequestsPerPool() external view returns (uint256) {
        return maxOutstandingPerPool;
    }

    function maxOutstandingRequestsGlobal() external view returns (uint256) {
        return maxOutstandingGlobal;
    }

    function requestFee() public view returns (uint256) {
        return serviceGasEstimate * tx.gasprice * (BPS + serviceMarginBps) / BPS + serviceFlatWei;
    }

    function requiredSubscriptionBalance() public view returns (uint256) {
        return minimumSubscriptionBuffer + (totalPrepared + totalCoordinatorOutstanding) * maxFulfillmentCostWei;
    }

    function subscriptionNativeBalance() public view returns (uint256 nativeBalance) {
        // The coordinator deletes the subscription during terminal cancellation. Keep terminal views
        // usable without querying a record that is guaranteed not to exist.
        if (subscriptionTerminated) return 0;
        (, uint96 balance,,,) = s_vrfCoordinator.getSubscription(subscriptionId);
        nativeBalance = balance;
    }

    /// @notice Liquid ETH not needed to close the subscription's current coverage shortfall.
    function availableSurplus() public view returns (uint256 available) {
        if (subscriptionTerminated) return 0;
        uint256 required = requiredSubscriptionBalance();
        uint256 current = subscriptionNativeBalance();
        uint256 reserved = required > current ? required - current : 0;
        uint256 liquid = address(this).balance;
        if (liquid > reserved) available = liquid - reserved;
    }

    /// @notice Coordinator-compatible, but intentionally scoped to the calling clone.
    function pendingRequestExists(uint256 subId) external view returns (bool) {
        if (!registeredPool[msg.sender]) revert UnknownPool();
        if (subId != subscriptionId) revert InvalidRequestTuple();
        return coordinatorOutstandingFor[msg.sender] != 0;
    }

    /*//////////////////////////////////////////////////////////////
                         ACTIVATION + REGISTRY
    //////////////////////////////////////////////////////////////*/

    function activateSubscription() external onlyFactory {
        if (subscriptionTerminated) revert VrfServiceTerminated();
        if (subscriptionActive) revert SubscriptionAlreadyActive();
        _validateFactoryConfig();
        if (owner() != factory) revert SubscriptionNotOwnedByFactory();

        (, uint96 nativeBalance, uint64 requestCount, address subOwner, address[] memory consumers) =
            s_vrfCoordinator.getSubscription(subscriptionId);
        if (subOwner != factory) revert SubscriptionNotOwnedByFactory();
        if (requestCount != 0 || s_vrfCoordinator.pendingRequestExists(subscriptionId)) {
            revert SubscriptionNotPristine();
        }
        if (consumers.length != 1 || consumers[0] != address(this)) {
            revert SubscriptionConsumerMismatch();
        }
        if (uint256(nativeBalance) < minimumSubscriptionBuffer) revert InsufficientVrfCoverage();

        subscriptionActive = true;
        emit SubscriptionActivated(subscriptionId, address(s_vrfCoordinator));
    }

    /// @notice Irreversibly retire this service and send its complete liquid ETH balance to the factory's
    ///         preconfigured recovery recipient. The factory cancels the coordinator subscription later in
    ///         the same transaction, so a failed coordinator refund rolls this transfer and terminal state
    ///         back atomically.
    /// @dev This deliberately does not touch stored words or delivery state. It also does not query
    ///      `getSubscription`, which is invalid after coordinator cancellation.
    function terminateSubscription(address payable recoveryRecipient)
        external
        onlyFactory
        nonReentrant
        returns (uint256 serviceEthRefund)
    {
        if (subscriptionTerminated) revert VrfServiceTerminated();
        if (!subscriptionActive) revert SubscriptionNotActive();
        if (!requestsPaused) revert RequestsPaused();
        if (totalPrepared != 0 || totalCoordinatorOutstanding != 0) revert OutstandingCallbacks();
        if (s_vrfCoordinator.pendingRequestExists(subscriptionId)) revert OutstandingCallbacks();

        IFWACloneFactory config = IFWACloneFactory(factory);
        if (
            recoveryRecipient == address(0) || recoveryRecipient != config.vrfRecoveryRecipient()
                || !config.vrfSubscriptionTerminated() || !config.vrfSubscriptionActive() || config.globalPurchasesEnabled()
                || config.poolCreationEnabled() || !config.vrfRequestsPaused()
        ) revert InvalidConfig();

        subscriptionTerminated = true;
        subscriptionActive = false;
        serviceEthRefund = address(this).balance;
        if (serviceEthRefund != 0) SafeTransferLib.safeTransferETH(recoveryRecipient, serviceEthRefund);

        emit SubscriptionTerminated(recoveryRecipient, serviceEthRefund);
    }

    /// @notice Permissionlessly forward ETH force-sent after shutdown to the same immutable-in-terminal
    ///         recovery recipient. Ordinary post-terminal transfers are rejected by `receive()`.
    function recoverTerminalEth() external nonReentrant returns (uint256 amount) {
        if (!subscriptionTerminated) revert SubscriptionNotActive();
        address payable recoveryRecipient = payable(IFWACloneFactory(factory).vrfRecoveryRecipient());
        if (recoveryRecipient == address(0) || recoveryRecipient == address(this)) revert InvalidConfig();

        amount = address(this).balance;
        if (amount != 0) SafeTransferLib.safeTransferETH(recoveryRecipient, amount);
        emit TerminalEthRecovered(msg.sender, recoveryRecipient, amount);
    }

    function registerPool(address pool) external onlyFactory {
        if (!subscriptionActive) revert SubscriptionNotActive();
        if (pool == address(0) || pool.code.length == 0) revert InvalidConfig();
        if (registeredPool[pool]) revert AlreadyRegistered();
        if (!IFWACloneFactory(factory).isPool(pool)) revert UnknownPool();
        _validatePoolConfig(pool);
        if (IFWACloneVRFHost(pool).unfulfilledVrfCount() != 0) revert PoolConfigMismatch();

        registeredPool[pool] = true;
        emit PoolRegistered(pool);
    }

    /*//////////////////////////////////////////////////////////////
                         REQUEST FEE + COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve all callback coverage for a single request or complete batch before request #1.
    function prepareRequests(uint256 requestCount) external payable nonReentrant {
        address pool = msg.sender;
        if (!subscriptionActive) revert SubscriptionNotActive();
        if (requestsPaused) revert RequestsPaused();
        if (!registeredPool[pool]) revert UnknownPool();
        if (!IFWACloneFactory(factory).consumerReady(pool)) revert PoolNotReady();
        if (requestCount == 0) revert InvalidConfig();
        if (msg.value != requestFee() * requestCount) revert IncorrectRequestFee();
        _validatePoolConfig(pool);

        uint256 poolPrepared = preparedCredits[pool];
        uint256 poolOutstanding = coordinatorOutstandingFor[pool];
        uint256 newPoolLiability = poolPrepared + poolOutstanding + requestCount;
        uint256 poolLimit = maxOutstandingPerPool;
        if (poolLimit != 0 && newPoolLiability > poolLimit) revert PerPoolRequestLimitExceeded();

        uint256 newGlobalLiability = totalPrepared + totalCoordinatorOutstanding + requestCount;
        uint256 globalLimit = maxOutstandingGlobal;
        if (globalLimit != 0 && newGlobalLiability > globalLimit) revert GlobalRequestLimitExceeded();

        poolPrepared += requestCount;
        preparedCredits[pool] = poolPrepared;
        totalPrepared += requestCount;

        emit RequestFeesReceived(pool, requestCount, msg.value);
        emit RequestsPrepared(
            pool, requestCount, poolPrepared, poolOutstanding, totalPrepared, totalCoordinatorOutstanding
        );
        _ensureSubscriptionCoverage();
    }

    /// @notice Coordinator-compatible request facade called only by a registered clone.
    /// @return requestId The unmodified request ID returned by the real coordinator.
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req)
        external
        nonReentrant
        returns (uint256 requestId)
    {
        address pool = msg.sender;
        if (!subscriptionActive) revert SubscriptionNotActive();
        if (requestsPaused) revert RequestsPaused();
        if (!registeredPool[pool]) revert UnknownPool();
        if (!IFWACloneFactory(factory).consumerReady(pool)) revert PoolNotReady();
        if (preparedCredits[pool] == 0) revert MissingPreparedCredit();
        _validateRequestTuple(req);
        _validatePoolConfig(pool);

        // Convert one prepared liability into one coordinator liability before the external call.
        // A coordinator revert, duplicate ID, or any later pool revert rolls this entire transaction back.
        unchecked {
            preparedCredits[pool] -= 1;
            totalPrepared -= 1;
        }
        coordinatorOutstandingFor[pool] += 1;
        totalCoordinatorOutstanding += 1;

        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: approvedVrfKeyHash,
                subId: subscriptionId,
                requestConfirmations: approvedRequestConfirmations,
                callbackGasLimit: approvedRouterCallbackGasLimit,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
            })
        );

        if (requestId == 0 || requestStatus[requestId] != RequestStatus.None) {
            revert DuplicateRequestId();
        }
        requestPool[requestId] = pool;
        requestStatus[requestId] = RequestStatus.CoordinatorOutstanding;
        emit RandomnessRequested(requestId, pool);
    }

    function topUpSubscription() external nonReentrant returns (uint256 amount) {
        if (!subscriptionActive) revert SubscriptionNotActive();
        amount = _ensureSubscriptionCoverage();
    }

    function _ensureSubscriptionCoverage() internal returns (uint256 amount) {
        if (subscriptionTerminated) revert VrfServiceTerminated();
        uint256 required = requiredSubscriptionBalance();
        uint256 current = subscriptionNativeBalance();
        if (current >= required) return 0;

        amount = required - current;
        if (amount > address(this).balance) revert InsufficientVrfCoverage();
        s_vrfCoordinator.fundSubscriptionWithNative{value: amount}(subscriptionId);
        emit SubscriptionFunded(subscriptionId, amount, required);
    }

    /*//////////////////////////////////////////////////////////////
                         CALLBACK + REDelivery
    //////////////////////////////////////////////////////////////*/

    /// @dev The inherited external entrypoint authenticates `s_vrfCoordinator` before reaching here.
    ///      Unknown, duplicate, terminal, and malformed callbacks deliberately do not revert.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        RequestStatus status = requestStatus[requestId];
        address pool = requestPool[requestId];
        if (status != RequestStatus.CoordinatorOutstanding || pool == address(0)) {
            emit FulfillmentIgnored(requestId, status, randomWords.length);
            return;
        }

        _releaseCoordinatorLiability(pool);

        bool hasWord = randomWords.length != 0;
        if (hasWord) {
            storedRandomWord[requestId] = randomWords[0];
            requestStatus[requestId] = RequestStatus.WordStored;
        } else {
            requestStatus[requestId] = RequestStatus.EmptyWordArrayStored;
        }
        emit RandomnessStored(requestId, pool, hasWord ? randomWords[0] : 0, hasWord);

        _attemptDelivery(requestId, pool);
    }

    /// @notice Retry only the authenticated word already stored for its immutable original pool.
    function deliverRandomness(uint256 requestId) external nonReentrant returns (bool delivered) {
        RequestStatus status = requestStatus[requestId];
        if (status != RequestStatus.WordStored && status != RequestStatus.EmptyWordArrayStored) {
            revert RandomnessNotDeliverable();
        }
        delivered = _attemptDelivery(requestId, requestPool[requestId]);
    }

    function _attemptDelivery(uint256 requestId, address pool) internal returns (bool delivered) {
        RequestStatus status = requestStatus[requestId];
        bool hasWord = status == RequestStatus.WordStored;
        if (!hasWord && status != RequestStatus.EmptyWordArrayStored) return false;
        if (pool.code.length == 0) {
            emit RandomnessDeliveryFailed(requestId, pool);
            return false;
        }

        uint256[] memory words = new uint256[](hasWord ? 1 : 0);
        if (hasWord) words[0] = storedRandomWord[requestId];
        bytes memory callData = abi.encodeCall(IFWACloneRandomnessReceiver.rawFulfillRandomWords, (requestId, words));

        uint256 stipend = approvedCallbackGasLimit;
        uint256 eip150Overhead = (stipend + 62) / 63;
        if (gasleft() < stipend + eip150Overhead + DELIVERY_RETURN_GAS_RESERVE) {
            emit RandomnessDeliveryDeferred(requestId, pool);
            return false;
        }

        assembly ("memory-safe") {
            delivered := call(stipend, pool, 0, add(callData, 0x20), mload(callData), 0, 0)
        }

        if (delivered) {
            requestStatus[requestId] = RequestStatus.Delivered;
            delete storedRandomWord[requestId];
            emit RandomnessDelivered(requestId, pool);
        } else {
            emit RandomnessDeliveryFailed(requestId, pool);
        }
    }

    /// @notice Release a request whose real coordinator commitment is already consumed but whose
    ///         authenticated callback never stored a word here. No replacement randomness is created.
    function reconcileCoordinatorRequest(uint256 requestId) external nonReentrant {
        if (requestStatus[requestId] != RequestStatus.CoordinatorOutstanding) {
            revert RandomnessNotDeliverable();
        }

        (bool checked, bytes32 commitment) = _requestCommitment(requestId);
        if (!checked) revert CoordinatorCommitmentCheckFailed();
        if (commitment != bytes32(0)) revert CoordinatorRequestStillPending();

        address pool = requestPool[requestId];
        requestStatus[requestId] = RequestStatus.CoordinatorCallbackLost;
        _releaseCoordinatorLiability(pool);
        emit CoordinatorRequestReconciled(requestId, pool);
    }

    /// @dev Fixed-size staticcall prevents an unexpected coordinator return payload from being copied.
    function _requestCommitment(uint256 requestId) internal view returns (bool checked, bytes32 commitment) {
        address currentCoordinator = address(s_vrfCoordinator);
        bytes4 selector = IVRFCoordinatorV2PlusInternal.s_requestCommitments.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // Solidity exposes fixed-size bytes to assembly left-aligned, so `selector` already
            // occupies the first four ABI bytes (shifting it would erase it).
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), requestId)
            checked := staticcall(gas(), currentCoordinator, ptr, 0x24, ptr, 0x20)
            if and(checked, eq(returndatasize(), 0x20)) { commitment := mload(ptr) }
            if iszero(eq(returndatasize(), 0x20)) { checked := 0 }
        }
    }

    function _releaseCoordinatorLiability(address pool) internal {
        uint256 poolOutstanding = coordinatorOutstandingFor[pool];
        uint256 globalOutstanding = totalCoordinatorOutstanding;
        if (poolOutstanding != 0 && globalOutstanding != 0) {
            coordinatorOutstandingFor[pool] = poolOutstanding - 1;
            totalCoordinatorOutstanding = globalOutstanding - 1;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         SPONSORED PROCESSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Process one registered clone's canonical prefix and reimburse an approved operator
    ///         from subscription-safe service surplus.
    /// @dev This is only a sponsored wrapper around the clone's existing permissionless processor.
    ///      The operator chooses neither request IDs nor ordering. A failed reimbursement rolls back
    ///      this sponsored call, while the clone's direct processor remains available to everyone.
    function processAcquisitions(address pool, uint256 maxCount)
        external
        nonReentrant
        onlyOperator
        returns (uint256 processed, uint256 reimbursement)
    {
        if (!registeredPool[pool]) revert UnknownPool();
        if (maxCount == 0 || maxCount > maxSponsoredCount) revert InvalidConfig();
        uint256 gasStart = gasleft();

        // Chainlink can bill only subscription-held ETH. Restore the complete coordinator reserve
        // before classifying or paying any liquid treasury balance as processor surplus.
        _ensureSubscriptionCoverage();
        uint256 available = availableSurplus();
        if (available == 0) revert NoProcessorSurplus();

        processed = IFWACloneVRFHost(pool).processAcquisitions(maxCount);
        if (processed == 0) {
            emit AcquisitionsSponsored(msg.sender, pool, 0, 0, 0, 0);
            return (0, 0);
        }

        uint256 gasUnits = gasStart - gasleft() + reimbursementGasOverhead;
        if (gasUnits > maxReimbursementGas) gasUnits = maxReimbursementGas;

        uint256 baseFee = block.basefee;
        if (baseFee > maxReimbursementBaseFeeWei) baseFee = maxReimbursementBaseFeeWei;
        uint256 gasPriceCap = baseFee + maxReimbursementPriorityFeeWei;
        uint256 reimbursableGasPrice = tx.gasprice;
        if (reimbursableGasPrice > gasPriceCap) reimbursableGasPrice = gasPriceCap;

        reimbursement = gasUnits * reimbursableGasPrice;
        if (reimbursement > maxReimbursementWei) reimbursement = maxReimbursementWei;

        // Re-establish and re-read coverage at the exact payment point. Processing does not mutate
        // router liabilities today, but keeping this invariant local makes future changes fail closed.
        _ensureSubscriptionCoverage();
        available = availableSurplus();
        if (reimbursement > available) reimbursement = available;
        if (reimbursement != 0) SafeTransferLib.safeTransferETH(msg.sender, reimbursement);

        emit AcquisitionsSponsored(msg.sender, pool, processed, gasUnits, reimbursableGasPrice, reimbursement);
    }

    /*//////////////////////////////////////////////////////////////
                            FACTORY CONFIG
    //////////////////////////////////////////////////////////////*/

    function setRequestsPaused(bool paused) external onlyFactory {
        if (!paused) {
            if (subscriptionTerminated) revert VrfServiceTerminated();
            if (!subscriptionActive) revert SubscriptionNotActive();
            _validateFactoryConfig();
        }
        requestsPaused = paused;
        emit RequestsPausedSet(paused);
    }

    /// @notice A zero value removes that explicit limit. Existing requests are never affected.
    function setRequestLimits(uint256 maxPerPool, uint256 maxGlobal) external onlyFactory {
        maxOutstandingPerPool = maxPerPool;
        maxOutstandingGlobal = maxGlobal;
        emit RequestLimitsSet(maxPerPool, maxGlobal);
    }

    /// @notice Rotate to a never-before-used gas lane after an official coordinator migration.
    /// @dev Chainlink's migration target resets this consumer's request nonce to zero. Because a real
    ///      request ID hashes the key hash together with this service, subscription, and nonce, key-hash
    ///      uniqueness is what prevents a post-migration request from colliding with historical pool state.
    function setVrfKeyHash(bytes32 newKeyHash) external onlyFactory nonReentrant {
        if (!subscriptionActive) revert SubscriptionNotActive();
        if (!requestsPaused) revert RequestsPaused();
        if (newKeyHash == bytes32(0) || newKeyHash == approvedVrfKeyHash) revert InvalidConfig();
        if (usedVrfKeyHash[newKeyHash]) revert VrfKeyHashAlreadyUsed();
        if (totalPrepared != 0 || totalCoordinatorOutstanding != 0) revert OutstandingCallbacks();
        if (s_vrfCoordinator.pendingRequestExists(subscriptionId)) revert OutstandingCallbacks();

        IFWACloneFactory config = IFWACloneFactory(factory);
        if (config.chainlinkCoordinator() != address(s_vrfCoordinator) || config.vrfKeyHash() != newKeyHash) {
            revert InvalidConfig();
        }

        bytes32 oldKeyHash = approvedVrfKeyHash;
        approvedVrfKeyHash = newKeyHash;
        usedVrfKeyHash[newKeyHash] = true;

        // The current ceiling becomes the non-decreasing floor approved for this new gas lane.
        coverageFloor = maxFulfillmentCostWei;
        emit VrfKeyHashRotated(oldKeyHash, newKeyHash, coverageFloor);
    }

    /// @notice Permissionlessly bring one cleared pool onto the current post-migration request tuple.
    /// @dev The clone itself additionally requires factory request/global purchase pauses and zero local
    ///      unsettled/callback work. An already-synced pool is an idempotent no-op.
    function syncPoolRequestConfig(address pool) external nonReentrant {
        if (!requestsPaused) revert RequestsPaused();
        if (!registeredPool[pool]) revert UnknownPool();
        if (preparedCredits[pool] != 0 || coordinatorOutstandingFor[pool] != 0) {
            revert OutstandingCallbacks();
        }

        IFWACloneVRFHost host = IFWACloneVRFHost(pool);
        (address logicalCoordinator, uint256 configuredSubId) = host.vrfCoordinatorAndSubId();
        (bytes32 keyHash, uint32 gasLimit) = host.vrfRequestConfig();
        if (
            logicalCoordinator != address(this) || configuredSubId != subscriptionId
                || host.vrfService() != address(this) || gasLimit != approvedCallbackGasLimit
        ) revert PoolConfigMismatch();
        if (keyHash == approvedVrfKeyHash) return;

        host.configureVrfRequest(approvedVrfKeyHash, approvedCallbackGasLimit);
        _validatePoolConfig(pool);
        emit PoolRequestConfigSynced(pool, approvedVrfKeyHash, approvedCallbackGasLimit);
    }

    function setFeeConfig(uint256 gasEstimate, uint256 marginBps, uint256 flatWei) external onlyFactory {
        if (gasEstimate == 0) revert InvalidConfig();
        serviceGasEstimate = gasEstimate;
        serviceMarginBps = marginBps;
        serviceFlatWei = flatWei;
        emit FeeConfigSet(gasEstimate, marginBps, flatWei);
    }

    function setCoverageConfig(uint256 minimumBuffer, uint256 maxFulfillmentCost) external onlyFactory nonReentrant {
        if (minimumBuffer == 0 || maxFulfillmentCost < coverageFloor) revert InvalidConfig();
        uint256 liabilities = totalPrepared + totalCoordinatorOutstanding;
        if (
            liabilities != 0
                && (minimumBuffer < minimumSubscriptionBuffer || maxFulfillmentCost < maxFulfillmentCostWei)
        ) revert OutstandingCallbacks();

        minimumSubscriptionBuffer = minimumBuffer;
        maxFulfillmentCostWei = maxFulfillmentCost;
        if (subscriptionActive) _ensureSubscriptionCoverage();
        emit CoverageConfigSet(minimumBuffer, maxFulfillmentCost);
    }

    function setOperator(address operator, bool allowed) external onlyFactory {
        if (operator == address(0)) revert InvalidConfig();
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setReimbursementConfig(
        uint256 sponsoredCount,
        uint256 reimbursementGas,
        uint256 gasOverhead,
        uint256 maxBaseFeeWei,
        uint256 maxPriorityFeeWei,
        uint256 reimbursementWei
    ) external onlyFactory {
        if (sponsoredCount == 0 || reimbursementGas == 0 || maxBaseFeeWei == 0 || reimbursementWei == 0) {
            revert InvalidConfig();
        }
        maxSponsoredCount = sponsoredCount;
        maxReimbursementGas = reimbursementGas;
        reimbursementGasOverhead = gasOverhead;
        maxReimbursementBaseFeeWei = maxBaseFeeWei;
        maxReimbursementPriorityFeeWei = maxPriorityFeeWei;
        maxReimbursementWei = reimbursementWei;
        emit ReimbursementConfigSet(
            sponsoredCount, reimbursementGas, gasOverhead, maxBaseFeeWei, maxPriorityFeeWei, reimbursementWei
        );
    }

    /// @notice Factory-controlled timing and live recipient selection.
    function withdrawSurplus(address recipient, uint256 amount) external onlyFactory nonReentrant {
        if (subscriptionTerminated) revert VrfServiceTerminated();
        if (recipient == address(0) || recipient != IFWACloneFactory(factory).protocolFeeRecipient()) {
            revert InvalidConfig();
        }
        if (amount > availableSurplus()) revert InsufficientSurplus();
        SafeTransferLib.safeTransferETH(recipient, amount);
        emit SurplusWithdrawn(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _validateRequestTuple(VRFV2PlusClient.RandomWordsRequest calldata req) internal view {
        if (
            req.keyHash != approvedVrfKeyHash || req.subId != subscriptionId
                || req.requestConfirmations != approvedRequestConfirmations
                || req.callbackGasLimit != approvedCallbackGasLimit || req.numWords != NUM_WORDS
                || keccak256(req.extraArgs) != approvedExtraArgsHash
        ) revert InvalidRequestTuple();
    }

    function _validatePoolConfig(address pool) internal view {
        IFWACloneVRFHost host = IFWACloneVRFHost(pool);
        (address logicalCoordinator, uint256 configuredSubId) = host.vrfCoordinatorAndSubId();
        (bytes32 keyHash, uint32 gasLimit) = host.vrfRequestConfig();
        if (
            logicalCoordinator != address(this) || configuredSubId != subscriptionId
                || host.vrfService() != address(this) || keyHash != approvedVrfKeyHash
                || gasLimit != approvedCallbackGasLimit
        ) revert PoolConfigMismatch();
    }

    function _validateFactoryConfig() internal view {
        IFWACloneFactory config = IFWACloneFactory(factory);
        if (
            config.chainlinkCoordinator() != address(s_vrfCoordinator) || config.vrfCoordinator() != address(this)
                || config.vrfSubscriptionId() != subscriptionId || config.vrfKeyHash() != approvedVrfKeyHash
                || config.callbackGasLimit() != approvedCallbackGasLimit
                || config.routerCallbackGasLimit() != approvedRouterCallbackGasLimit
                || config.requestConfirmations() != approvedRequestConfirmations
        ) revert InvalidConfig();
    }
}
