# EXT: FWA V2 standard custom pool (FWAClone) and factory

## Current mainnet deployment, observed 2026-09-23

Current Shapes integration surfaces target the deployment used by FWA's community-pool UI. At
block `26040413`, FWA's official deployment page, live UI and runtime reads agree on:

| Contract | Current native address |
| --- | --- |
| FWAFactory | `0xf5a3a153164791ab579c3d9ba5dbecf7cdfd300c` |
| FWACloneVRFService | `0xa4adfc35db18326efb3b5d9bf66a8103ec2d5ee2` |
| FWAClone standard implementation | `0xeaa4d032908a9734a2c7939c0d211c35ad51eb31` |

Live reads from that factory return `maxAcquisitionsPerTx = 5`,
`maxOutstandingRequestsPerPool = 10`, `maxOutstandingRequestsGlobal = 100`,
`selectionSlippageBps = 1000`, `edgeBps = 500`, `maxActivationsPerAcquisition = 6` and
`maxStagedListings = 0`.

The factory was live at the evidence block: pool creation and global purchases were enabled, VRF
requests were not paused, and the subscription was active. `betaAccess` remained enabled, so the
pool-creating address still needs beta-one allowance. Shapes' sponsor PFP flow remains required
while that gate applies.

The current native custom-pool UI defaults negative settlement tolerance to 10%, lets the buyer
choose 10% through 100% in 1% steps, defaults quantity to one and caps a transaction at five or the
active-listing count. It re-reads `quoteAcquisitionPrice(count)` at the intended transaction fee,
then simulates `acquire` for one or `acquireBatch` for more than one before opening the wallet. It
does not impose a lower outstanding-request cap or read pending request room; the preflight
simulation relies on the service's ten-request per-pool cap. One batch snapshots one fee for every
request, and each request settles independently in pool order.

Every standard-pool selector Shapes currently calls remains present. Compared with the retired
implementation, the current ABI adds `IMPLEMENTATION_KIND()`, `MAX_INVENTORY_BATCH()` (20),
`listNFTs(...)`, `quoteAcquisitionPrice(count)`, `withdrawListingTo(...)` and
`withdrawListingsTo(...)`. The factory adds expected-implementation overloads for pool creation,
`poolImplementation(pool)`, `setImplementation`, `getPoolInitializationConfig()` and
`getBuybackTerms()`. Its two-argument creation functions remain.
The current and retired VRF service selector sets are identical, and the fee, request-limit and
reimbursement values Shapes reads are unchanged at the evidence block.

The native community-pool UI calls `acquire` or `acquireBatch` directly from the connected wallet.
Shapes assigns the FWA clone's purchase operator to custody and opens its purchaser authorization
only during a custody pull call. Direct native-UI purchasing therefore fails `PurchaseNotAllowed`.
Renaming custody entrypoints does not bridge this call path; direct compatibility needs an
FWA-supported delegated gateway or a separately approved purchase-gate redesign.

### Sepolia parity check, observed 2026-09-24

FWA's official Sepolia page and its live documented factory still point to the custom-pool stack
deployed on 2026-09-14. The current mainnet factory, service and implementations were deployed on
2026-09-21. The documented Sepolia factory and standard implementation have different runtime
sizes and hashes from current mainnet, Blockscout's verified-contract search exposes no newer
Sepolia generation, the known Sepolia deployer's newest direct transaction is from 2026-09-18, and
the current mainnet deployer has no Sepolia transactions. No public verified matching Sepolia stack
was found. This does not exclude an undocumented, unverified deployment from an unknown address.
Exact addresses, blocks, hashes and discovery reads are recorded in
`evidence/FWA-SEPOLIA-CUSTOM-POOL-RECHECK-2026-09-24.md`.

Etherscan now reports Exact Match source verification for the current factory, standard
implementation and VRF service. The verified source confirms the purchaser/refund ownership,
slippage checks, request limits, unlimited staging default, missing staged-count getter and batch
inventory behavior recorded here. Source hashes and direct pages are in
`evidence/TASK-V62/current-fwa-source-verification.md`. The current runtime also passed the 36-test
fork compatibility gate in `evidence/TASK-V62/current-fwa-migration.md`. Verification makes the
source inspectable; it does not replace the required source-level integration review.

## Retired deployment, retained for source-level historical comparison

Verified 2026-09-10 at mainnet block 25949804. Sources fetched from sourcify (full match, solc 0.8.26) and vendored under `external/fwa-v2/`. Live factory values in `evidence/ext-fwa-factory-live-params-block25949804.txt`.

| Contract | Address | Code hash (keccak of runtime code) |
| --- | --- | --- |
| FWAFactory | 0xa1e8e92609708AbA08E0A66e811C41cdBBF610Fa | 0xb9bf8c80f485dcc6d6427f15dd02006e80b9e3987a10f5c4a9ab9e6cff9ecca7 |
| FWAClone implementation (standard) | 0x2969749Fa2D9618fF08a63F41Be7bF7d018009d7 | 0x6543861e65f396d67260ade12d69fe387cec439d8988f45a70154e382b7ff4c2 |
| FWACloneBuyback implementation (not used) | 0x08183D0D8D927A7f3106ECDd74dC382289f72f10 | 0x76e324ed5648f2e110e4a8fad33e4d229d782ef12481d5a92e194210729f22cb |
| FWA VRF service (logical coordinator for clones) | 0x225f815F2585f6F676243be6944b8A598Db7595A | see evidence file |
| Chainlink VRF v2.5 coordinator | 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a | external |
| FWA token (pool creation fee token) | 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845 | external |
| FWAIR PFP (beta access) | 0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620 | 0xdb16f537890a43aa97c1d7ccbd65274ab479e328c927c98aaaa67b50065a0978 |

## EXT-01 Pool creation (legacy verified source; current ABI compatibility noted above)

`createPool(bytes32 userSalt, uint256 expectedCreationFee) returns (address pool)`. `msg.sender` becomes the permanent pool owner (`initialize(msg.sender)`), so ShapesPoolCore must call `createPool` itself. Address is CREATE2 deterministic: `predictPoolAddress(poolOwner, userSalt)`. Creation fee is paid in FWA token via `safeTransferFrom(msg.sender, 0xdEaD, fee)`; currently 0. Registration with the VRF service and `consumerReady[pool] = true` happen inside `createPool`; no separate registration step.

The retired factory's `implementation` and `vrfService` were set together by `setInfrastructure`
exactly once. The current factory exposes `setImplementation(address)` and records
`poolImplementation(pool)`, so that retired source-level conclusion does not apply to the current
deployment. Shapes pins the expected implementation in deployment configuration and postflight;
adopting the new expected-implementation creation overload is a separate implementation change.

Retired deployment gates at block 25949804 (all factory-owner mutable):
- `poolCreationEnabled = false` (EXT prerequisite: must be true)
- `betaAccess = true`: creation limit per wallet = `FWAIRPFP.walletActivations(BETA_ACCESS_ID, wallet)`; with beta off the limit is `maxPoolsPerWallet = 1`. ShapesPoolCore is a contract; it needs either a PFP activation for its address or beta disabled. (RISK-EXT-01)
- `globalPurchasesEnabled = false`, `vrfRequestsPaused = true`: purchases revert until the FWA team enables.
- `edgeBps = 500`, `inventoryChangeCooldown = 300s`, `selectionTimeoutBlocks = 30`, `maxActivationsPerAcquisition = 6`, `maxAcquisitionsPerTx = 5`, `selectionSlippageBps = 1000`, `maxStagedListings = 0` (unlimited), `maxOutstandingRequestsPerPool = 10`, `maxOutstandingRequestsGlobal = 100`.

Read live by every clone (not snapshotted): `edgeBps`, `inventoryChangeCooldown`, `globalPurchasesEnabled`, `globalWithdrawOnly`, `vrfRequestsPaused`, `consumerReady`, `protocolFeeRecipient`. Snapshotted at clone init: VRF config, `selectionTimeoutBlocks`, `maxActivationsPerAcquisition`, `maxAcquisitionsPerTx`, `selectionSlippageBps`, `maxStagedListings`.

### FWAIR PFP beta lock

The verified FWAIR PFP has a 30-day `LOCK_SAFETY_PERIOD`. Only the immediate token holder may call
`lock(tokenId)`. Locking transfers the NFT into the PFP contract, records the caller as its holder,
and increments the historical `walletActivations[betaId][holder]` count. After the beta ends, only
that recorded holder may call `withdraw`; the NFT is returned to it. The factory reads beta ID 1's
historical activation count for the exact pool-creating address. Therefore Core can receive an
approved sponsor NFT, lock it itself, create the pool as owner, and later return the NFT to the
original sponsor. Source: verified contract at
`https://etherscan.io/address/0x29f1cBC8eccD64B0cE777f5Da45c72C47383a620#code`.

Source review, sourcify full match, solc 0.8.26, vendored read-only at `external/fwair-pfps/FWAIRPFPs.sol`:

- Fixed supply 111, ids 1 to 111. Solady ERC721 plus Ownable.
- `lock(tokenId)` requires `betaActive()`, `activationCount < maxActivations`, an unlocked token, and `ownerOf(tokenId) == msg.sender`. It records `tokenLocks[tokenId] = {holder, betaId}`, increments `walletActivations[betaId][holder]`, and transfers the token into the PFP contract.
- `withdraw(tokenId)` requires `msg.sender` to be the recorded holder and the lock's beta to be over (`betaId != currentBetaId || !betaActive()`).
- `_beforeTokenTransfer` admits transfers into the contract through `lock` and transfers out to the recorded holder. Transfers between ordinary addresses are unrestricted.
- Beta lifecycle: the owner calls `startBeta`; a beta ends at `betaEndsAt = start + 30 days` or on `betaOver()`. `betaActive()` is `currentBetaId != 0 && block.timestamp < betaEndsAt`.
- `FWAFactory.BETA_ACCESS_ID == 1`, and `poolCreationLimit(wallet) = walletActivations(1, wallet)` while `betaAccess` is on. The mapping persists past the beta, so an allowance earned in beta 1 keeps working.
- Read live 2026-09-11: `currentBetaId 1`, `betaActive true`, `betaEndsAt 1791563267`, `activationCount 12 / 111`, `poolCreationEnabled false`, `poolCreationFee 0`.
- Custom errors: InvalidOwner, InvalidRecipient, InvalidMaxActivations, BetaAlreadyActive, NoActiveBeta, ActivationLimitReached, NotTokenHolder, TokenAlreadyLocked, NotLockHolder, LockStillActive(uint256 unlockAt), DirectTransferToContract, InvalidEscrowTransfer, NoETHToRecover.

## FWAClone dossier (source review)

## 1. Initialization and ownership

- Contract is `Ownable, ReentrancyGuard` (Solady). Deployed as a minimal-proxy clone; constructor only sets immutables (FWAClone.sol:572-580).
- Constructor: `constructor(address factory_, address service_)` (line 572). Requires both `factory_` and `service_` to be nonzero and have code, else `InvalidConfig()`. Sets `FACTORY` (immutable) and `vrfService` (immutable, `IFWAVRFService`). Calls `_initializeOwner(address(1))` — a placeholder owner so the implementation contract itself is never usable as a live pool (real clones re-init via `initialize`).
- `_guardInitializeOwner()` returns `true` (line 587-589), i.e. Solady's guard against re-init is disabled — `initialize` performs its own idempotency check instead.
- `initialize(address poolOwner) external onlyFactory` (line 598): callable ONLY by `FACTORY` (`onlyFactory` modifier, line 582-585, checks `msg.sender == FACTORY`). Reverts `InvalidConfig()` if `owner() != address(0)` (already initialized) or `poolOwner == address(0)`.
  - Pulls VRF/economic config from the factory (`vrfCoordinator`, `vrfSubscriptionId`, `vrfKeyHash`, `callbackGasLimit`, `requestConfirmations`, `selectionTimeoutBlocks`, `maxActivationsPerAcquisition`, `maxAcquisitionsPerTx`, `selectionSlippageBps`, `maxStagedListings`) and validates bounds (lines 601-643); reverts `InvalidConfig()` on any out-of-range value or if `factory.protocolFeeRecipient() == address(0)`.
  - Sets owner via `_initializeOwner(poolOwner)` (line 623). **Owner can be a contract — there is no EOA check anywhere in `initialize` or on `poolOwner`.**
  - `acquisitionsEnabled` starts `false` — pool is "loading", owner must explicitly enable via `setBool(ACQUISITIONS_ENABLED, true)` (line 636, 754).
  - Emits `FWACloneInitialized(poolOwner, FACTORY, subId)` (line 645).
- **Ownership can never change after init.** `_setOwner(address) internal pure override` unconditionally `revert OwnershipLocked()` (lines 593-595). Solady's `Ownable` normally allows `transferOwnership`/`renounceOwnership`; both are neutralized here — any call path into `_setOwner` reverts. So the game contract (owner) is permanently bound to this clone; there is no transfer/rescue path.
- No `consumerReady`/registration step is called by the clone itself in `initialize`; `consumerReady(address(this))` is checked defensively later at every `acquire`/`acquireBatch` call (line 1159) against the factory — i.e. the factory must separately register/ready the clone as a VRF consumer before purchases work, but that is a factory-side action, not something the clone calls.
- **`purchaseOperator`** (line 262): `address public purchaseOperator`. Zero (default) = permissionless. Set via `setPurchaseOperator(address newOperator) external onlyOwner` (line 1763-1769): owner-only, reverts if `retired` or if `newOperator != 0` and has no code (`InvalidPurchaseOperator()`). **Can be changed any number of times post-init**, including back to `address(0)`. Emits `PurchaseOperatorSet(old, new)`. When set, every `acquire`/`acquireBatch` staticcalls `IPurchaseOperator(operator).canPurchase(purchaser)` (see §11) before payment is validated.

## 2. Full external/public function list

| Signature | Access | Payable | Behavior |
|---|---|---|---|
| `initialize(address poolOwner)` (598) | `onlyFactory` | no | One-time init, see §1. |
| `localPurchasesEnabled() view returns (bool)` (648) | anyone | no | Returns `acquisitionsEnabled`. |
| `protocolFeeRecipient() view returns (address)` (653) | anyone | no | Live value read from factory. |
| `listNFT(address collection, uint256 tokenId, uint256 price) returns (uint256 listingId)` (664) | owner only (checked inline, not `onlyOwner` modifier) | no | Escrow an ERC721 at a notional price; activates immediately or stages (§9). |
| `purchasesResumeAt() view returns (uint256)` (729) | anyone | no | `lastInventoryChangeAt + factory.inventoryChangeCooldown()`. |
| `activateListings(uint256 maxCount)` (748) | anyone (permissionless) | no | Drains up to `maxCount` staged listings into the active pool, only if `unsettledAcquisitionCount == 0`. |
| `reservedListingCount(uint64 sequence) view returns (uint256)` (829) | anyone | no | Length of a sequence's reserved staged-listing batch. |
| `reservedListingAt(uint64 sequence, uint256 index) view returns (uint256)` (833) | anyone | no | One entry of that batch. |
| `withdrawListing(uint256 listingId)` (894) | depositor (= owner, enforced via `_activeOwned`) | no | Remove an Active listing, return NFT via `safeTransferFrom`. Blocked while any acquisition unsettled. |
| `updatePrice(uint256 listingId, uint256 newPrice)` (925) | depositor (= owner) | no | Reprice an Active listing; updates weight/tree/version. Blocked while retired or unsettled/withdraw-only. |
| `vrfServiceFee() view returns (uint256)` (961) | anyone | no | `vrfService.requestFee()` — gas-price dependent. |
| `acquisitionFee() view returns (uint256)` (969) | anyone | no | Harmonic-mean EV price plus factory edge (§7). |
| `quoteAcquisitionPrice() view returns (uint256 fee, uint256 vrf, uint256 total)` (979) | anyone | no | `fee=acquisitionFee()`, `vrf=vrfServiceFee()`, `total=fee+vrf`. |
| `acquire(address purchaser, uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps, uint256 expectedInventoryVersion, uint256 deadline) returns (uint256 requestId)` (1000) | anyone (subject to `purchaseOperator` gate) | **yes** | Single VRF-backed acquisition request; see §7/§8. |
| `acquireBatch(address purchaser, uint256 count, uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps, uint256 expectedInventoryVersion, uint256 deadline) returns (uint256[] requestIds)` (1052) | anyone (subject to `purchaseOperator` gate) | **yes** | `count` independent VRF requests in one tx, capped by `maxAcquisitionsPerTx`. |
| `vrfCoordinatorAndSubId() view returns (address, uint256)` (1234) | anyone | no | Logical coordinator + subId. |
| `vrfRequestConfig() view returns (bytes32 keyHash, uint32 gasLimit)` (1241) | anyone | no | Current gas lane + callback gas limit. |
| `configureVrfRequest(bytes32 keyHash, uint32 gasLimit)` (1249) | `vrfService` only | no | Sync gas lane after Chainlink coordinator migration; requires factory globally paused and no outstanding work. |
| `reconcileUnfulfilledVrfCount() returns (uint256)` (1271) | anyone (permissionless) | no | Zeroes `unfulfilledVrfCount` if coordinator reports no pending request for the subscription. |
| `rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)` (1287) | `s_vrfCoordinator` only | no | VRF fulfillment entrypoint (§13). |
| `processAcquisitions(uint256 maxCount) returns (uint256 processed)` (1358) | anyone (permissionless) | no | Ordered settlement/expiry processor (§8). |
| `withdrawAcquisitionRefund() returns (uint256 amount)` (1492) | purchaser (pull, `msg.sender`) | no | Claim credited acquisition refunds. |
| `retryNFTDelivery(uint256 listingId)` (1506) | anyone (permissionless) | no | Retry a failed atomic NFT delivery within the delivery window. |
| `refundFailedDelivery(uint256 listingId)` (1514) | listing's `purchaser` only | no | After `DELIVERY_WINDOW` elapses, convert escrow to a pull refund credit. |
| `recoverRefundedNFT(uint256 listingId)` (1536) | owner only | no | Recover an NFT whose delivery was refunded; sends NFT back to owner. |
| `executeNFTDelivery(uint256 listingId)` (1547) | `address(this)` only (self-call) | no | Narrow internal-only transfer executor, invoked via low-level self-call from `_tryAtomicNFTDelivery`/`retryNFTDelivery`/`recoverRefundedNFT`. |
| `withdrawOwnerProceeds() returns (uint256 amount)` (1608) | `onlyOwner` | no | Pull all `ownerProceeds`. |
| `payoutProtocolFees() returns (uint256 amount)` (1617) | anyone (permissionless) | no | Push `accruedProtocolFees` to `factory.protocolFeeRecipient()`. |
| `setBool(uint256 key, bool value)` (1754) | `onlyOwner` | no | Only accepts `FWAConfigKeys.ACQUISITIONS_ENABLED`; else `FactoryManagedConfig()`. Reverts if retired. |
| `setPurchaseOperator(address newOperator)` (1763) | `onlyOwner` | no | See §1. |
| `retirePool()` (1774) | `onlyOwner` | no | Irreversible retirement (§15). |
| `treeRootWeight() view returns (uint256)` (1786) | anyone | no | `tree[1]` — total weight at the segment-tree root (should equal `totalWeight`). |

Public storage getters (auto-generated, all views, no access control) an integrator should know about:
`listings(uint256)` (285), `pendingDeliveries(uint256)` (288), `deliveryEscrowTotal` (291), `nextListingId` (283), `slotToListing(uint256)` (334), `activeListingCount` (336), `totalWeight` (337), `weightedBackingTotal` (344), `ownerProceeds` (347), `accruedProtocolFees` (350), `acquisitions(uint256)` (382), `acquisitionMeta(uint256)` (383), `requestIdAtSequence(uint64)` (384), `acquisitionRefundCredit(address)` (387), `acquisitionRefundCreditTotal` (388), `acquisitionEscrowTotal` (389), `pendingAcquisitionCount` (221), `unfulfilledVrfCount` (226), `unsettledAcquisitionCount` (233), `selectionTimeoutBlocks` (237), `lastIssuedSequence` (248), `nextSequenceToProcess` (249), `retired` (258), `purchaseOperator` (262), `selectionSlippageBps` (270), `inventoryVersion` (274), `lastInventoryChangeAt` (277), `callbackGasLimit` (189), `BPS` (147, constant), `DELIVERY_WINDOW` (159, constant), `MIN_CALLBACK_GAS_LIMIT`/`MAX_CALLBACK_GAS_LIMIT` (190-191, constants), `vrfService` (173, immutable), `FACTORY` (176, immutable).

## 3. Structs and enums (verbatim)

```solidity
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

struct Listing {
    address collection;
    address depositor;
    address purchaser;
    uint256 tokenId;
    uint256 weight;
    uint256 price;
    uint256 slot;
    ListingStatus status;
}

struct Acquisition {
    address purchaser;
    uint256 requestBlock;
    uint256 priceEscrowed;
    uint256 listingId;
    AcquisitionStatus status;
}

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
```
(FWAClone.sol:48-113)

Storage mappings/arrays an integrator reads (beyond the public getters in §2):
- `mapping(address collection => mapping(uint256 tokenId => uint256 listingId)) liveNFTListing` — internal, no getter (line 295). Custody record; not directly readable, but `listings[listingId].status` reflects the same info.
- `reservedForSequence(uint256 listingId) => uint64` — public getter (321).
- `reservedStagedCount` — public (322).
- `tree[node]` — internal, no getter except `treeRootWeight()` for the root.
- `stagingHead/stagingTail/stagingNext/stagingPrev/stagedCount/maxStagedListings` — all internal, no getters (307-318). Not directly queryable on-chain.
- `callbackObserved(uint256 requestId) => bool` — internal, no getter (229).
- `requestBasePrice(uint256 requestId) => uint256` — internal, no getter (393).

## 4. Events (exact signatures)

```solidity
event NFTListed(uint256 indexed listingId, uint256 indexed slot, address indexed depositor, address collection, uint256 tokenId, uint256 weight, uint256 price);
event ListingWithdrawn(uint256 indexed listingId, address indexed depositor, uint256 price);
event ListingStaged(uint256 indexed listingId, address indexed depositor, address collection, uint256 tokenId, uint256 price, uint256 stagedAtBlock);
event PriceUpdated(uint256 indexed listingId, address indexed depositor, uint256 oldPrice, uint256 newPrice, uint256 newWeight);
event InventoryChanged(uint256 indexed version, uint64 changedAt);
event AcquisitionRequested(uint256 indexed requestId, address indexed purchaser, uint256 acquisitionFee, uint256 totalWeight);
event AcquisitionSequenced(uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 reservedCount);
event RandomnessCached(uint256 indexed requestId, uint64 indexed sequence, uint256 randomWord);
event RandomnessTimedOut(uint256 indexed requestId, uint64 indexed sequence, uint64 wordDeadlineBlock, uint256 callbackBlock);
event FulfillmentIgnored(uint256 indexed requestId, AcquisitionStatus status);
event UnfulfilledVrfReconciled(uint256 count);
event AcquisitionProcessed(uint256 indexed requestId, uint64 indexed sequence, AcquisitionStatus status, address indexed processor);
event AcquisitionRefundWithdrawn(address indexed purchaser, uint256 amount);
event AcquisitionExpired(uint256 indexed requestId, uint64 indexed sequence, address indexed purchaser, uint256 refund);
event AcquisitionRefundedNoListing(uint256 indexed requestId, address indexed purchaser, uint256 refund);
event AcquisitionRefundedSlippage(uint256 indexed requestId, address indexed purchaser, uint256 refund, uint256 escrowedFee, uint256 liveFee);
event NFTAllocated(uint256 indexed requestId, uint256 indexed listingId, address indexed purchaser, address depositor, uint256 price, uint256 randomWord);
event NFTDeliveryFailed(uint256 indexed listingId, address indexed recipient, address collection, uint256 tokenId);
event NFTDeliveryCompleted(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser);
event NFTDeliveryRefunded(uint256 indexed listingId, uint256 indexed requestId, address indexed purchaser, uint256 amount);
event RefundedNFTRecovered(uint256 indexed listingId, address indexed owner);
event OwnerProceedsAccrued(uint256 indexed requestId, uint256 amount, uint256 total);
event OwnerProceedsWithdrawn(address indexed owner, uint256 amount);
event ConfigSet(uint256 indexed key, uint256 value);
event VrfServiceFeePaid(address indexed payer, uint256 amount);
event ProtocolFeesAccrued(uint256 indexed requestId, uint256 amount, uint256 total);
event ProtocolFeesPaidOut(address indexed to, uint256 amount);
event FWACloneInitialized(address indexed owner, address indexed factory, uint256 indexed vrfSubId);
event PurchaseProceedsAccrued(uint256 indexed requestId, address indexed owner, uint256 ownerAmount, uint256 protocolAmount);
event PurchaseOperatorSet(address indexed oldOperator, address indexed newOperator);
event PoolRetired(address indexed owner);
```
(FWAClone.sol:399-509)

## 5. Custom errors (verbatim)

```solidity
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
// Unauthorized() inherited from Solady's Ownable
```
(FWAClone.sol:515-564)

## 6. Selection math

- Weight from price: `weight = INVERSE_WEIGHT_NUMERATOR / price`, where `INVERSE_WEIGHT_NUMERATOR = 1e36` (constant, line 154, computed at listing/reprice time, lines 676, 935). If `weight == 0` (price too large), reverts `PriceTooHigh()`. Integer division truncates toward zero — no explicit rounding mode beyond Solidity's default truncation.
- Total weight: `totalWeight` (337) is a running sum, incremented in `_activateListing` (766) and decremented in `_settleAndRemove` (1640).
- Segment tree: sparse mapping `tree[node] => weight` over a binary tree of depth `TREE_DEPTH = 32` (`CAPACITY = 1<<32` slots, line 127-128). `LEAF_BASE = CAPACITY` (144). Leaf for slot `s` is node `LEAF_BASE + s - 1` (139-143). `_addTreeWeight`/`_removeTreeWeight` walk leaf→root updating every ancestor (1654-1683), O(32) per op.
- Random word → listing: `target = randomWord % totalWeight` (line 1459); `_selectSlot(target)` (1689-1715) descends the tree: at each internal node, if `target < tree[leftChild]` descend left, else `target -= tree[leftChild]` and descend right; resolves to a leaf slot, then `slotToListing[slot]`.
- Tie/rounding: no explicit tie handling needed — the tree descent is deterministic given `target`; ties are structurally impossible because each leaf occupies a disjoint weight range `[cumulative, cumulative+weight)`.
- Bounds: no explicit min/max *price* bound beyond `price != 0` (`ZeroPrice()`) and the weight not truncating to zero (`PriceTooHigh()`, i.e. `price > INVERSE_WEIGHT_NUMERATOR` roughly makes weight 0 — exact ceiling is `price > 1e36` truncates to 0, but truncation to 0 can happen slightly below that boundary for non-power-of-2 divisors; the check `weight == 0` is exact regardless).
- Slot capacity: `CAPACITY = 2^32` active slots (`ActiveListingCapacityReached()` if exceeded, line 1741); slots are recycled via a free-list (`_allocateSlot`/`_releaseSlot`, 1721-1747) so listing IDs (never reused, line 331-332) and slots (reused) are distinct namespaces.

## 7. Pricing math

- `acquisitionFee()` (969-973): if `totalWeight == 0` returns `0`; else `ev = weightedBackingTotal / totalWeight` (harmonic mean of active listing prices, since weights are inverse-proportional to price — see comment lines 339-344), then `acquisitionFee = ev * (BPS + factory.edgeBps()) / BPS`. `edgeBps` is read live from the factory every call — not snapshotted except at request time (`requestBasePrice`, see §8).
- `msg.value` required for `acquire`/`acquireBatch`: `cost = fee + vrf` per request (`vrf = vrfServiceFee() = vrfService.requestFee()`, gas-price dependent). For `acquireBatch(count, ...)`: `cost = count * (fee + vrf)`, with `fee` computed once for the whole batch (pool is treated as static across the batch, line 1048).
- Excess handling: `_refund(msg.value - cost)` (1041, 1106) uses `SafeTransferLib.forceSafeTransferETH(msg.sender, amount)` (1230) — refunds the **caller** (`msg.sender`), not necessarily `purchaser` if they differ (see §16).
- Slippage/tolerance params on `acquire`/`acquireBatch`:
  - `maxAcquisitionFee`: if nonzero, request-time revert `AcquisitionFeeTooHigh()` if live `fee > maxAcquisitionFee` (line 1169).
  - `minWeightedValue`: if nonzero, request-time revert `PoolValueTooLow()` if `weightedBackingTotal < minWeightedValue` (line 1166).
  - `maxNegativeSlippageBps` (caller-supplied, must be `<= BPS` else `InvalidConfig()`, line 1023/1084): snapshotted into `acquisitionMeta.maxNegativeSlippageBps` (1210).
  - `selectionSlippageBps` (factory-seeded pool default, 1_000 = 10%, line 270): snapshotted into `acquisitionMeta.maxPositiveSlippageBps` at request time (1209).
  - At settlement (`_settleReadyAcquisition`, 1419), the request's **escrowed** fee is compared to the **live** `acquisitionFee()` at settlement time: `positiveTolerance = escrowed * maxPositiveSlippageBps / BPS`, `negativeTolerance = escrowed * maxNegativeSlippageBps / BPS`. If `liveFee - escrowed > positiveTolerance` (price rose too much) or `escrowed - liveFee > negativeTolerance` (price fell too much), the request is refunded via `AcquisitionRefundedSlippage` instead of filled (lines 1438-1451); the listing that would have been selected stays active.
- Owner/protocol split of the paid fee happens at **delivery completion**, not at request time (`_completeNFTDelivery`, 1578-1602): `basePrice = min(requestBasePrice[requestId], paid)`; `protocolAmount = (paid - basePrice) / 2` (integer division — protocol may round down by 1 wei, owner gets the remainder); `ownerAmount = paid - protocolAmount`. `requestBasePrice[requestId]` is snapshotted at request-open time as `min(weightedBackingTotal/totalWeight, fee)` (line 1223-1225) — i.e. the base EV price at request time, capped at the actually-escrowed fee, so a later edge/price change cannot alter the split of an in-flight request.

## 8. Acquisition lifecycle

**States** (`AcquisitionStatus`, §3): `None → Pending → {Ready | TimedOut | Expired}`; `Ready → {Fulfilled | Refunded | DeliveryPending}`; `DeliveryPending → {Fulfilled | DeliveryRefunded}`.

- **Sequence assignment**: every `_openAcquisition` (1173-1226) increments `lastIssuedSequence` and assigns `sequence = lastIssuedSequence` (1177); `requestIdAtSequence[sequence] = requestId` (1213). `nextSequenceToProcess` starts at 1 and only advances in `processAcquisitions` (1359-1389), strictly in order — a VRF word for a later sequence cannot settle before all earlier sequences are terminal.
- **Out-of-order VRF words**: `fulfillRandomWords` (internal, called only from `rawFulfillRandomWords`, 1295-1331) caches the word into `acquisitionMeta[requestId].randomWord` and flips status to `Ready` regardless of sequence order, as long as `block.number <= meta.wordDeadlineBlock` (else `TimedOut`). It does NOT mutate the pool — settlement is deferred to `processAcquisitions` which only ever touches `nextSequenceToProcess`.
- **`processAcquisitions(uint256 maxCount)`** (1358, permissionless, `nonReentrant`): loops while `processed < maxCount && nextSequenceToProcess <= lastIssuedSequence`. For the head sequence:
  - `Pending` and `block.number <= wordDeadlineBlock`: `break` (not yet resolvable — stops the whole loop, not just this entry).
  - `Pending` and deadline passed: treated as expired inline — decrement `pendingAcquisitionCount`, activate reserved batch, credit refund, emit `AcquisitionExpired`.
  - `TimedOut` (word arrived after deadline): activate reserved batch, credit refund, emit `AcquisitionExpired`.
  - `Ready`: activate reserved batch, call `_settleReadyAcquisition` (selection + delivery attempt).
  - Any other status: `revert SequenceInvariantBroken()`.
  - After handling: `_finishAcquisition` decrements `acquisitionEscrowTotal`/`unsettledAcquisitionCount`, emits `AcquisitionProcessed`, advances `nextSequenceToProcess`.
- **Fast path**: on a fresh `Ready` word for the current head sequence (and only if `callbackGasLimit >= MIN_FAST_PATH_CALLBACK_GAS_LIMIT=900_000` and the sequence has no reserved staged batch), `_tryProcessCallbackHead` (1339-1354) makes a bounded self-call (`CALLBACK_FAST_PATH_GAS=700_000` gas) to `this.processAcquisitions(1)` directly from the VRF callback. Failure of this self-call is swallowed (`pop(call(...))`) — the request stays `Ready` for a later permissionless `processAcquisitions` call.
- **Refund paths** (all convert to a pull credit via `_creditAcquisitionRefund`, 1392-1400, `acquisitionRefundCredit[purchaser] += amount`):
  1. No selection: `totalWeight == 0` at settlement → `AcquisitionStatus.Refunded`, event `AcquisitionRefundedNoListing` (1426-1429).
  2. Slippage: live fee drifted beyond tolerance → `AcquisitionStatus.Refunded`, event `AcquisitionRefundedSlippage` (1438-1451).
  3. Expiry/timeout: word never arrived in time, or arrived late → `AcquisitionStatus.Expired`, event `AcquisitionExpired` (1371-1376).
  4. Delivery-window refund: NFT selected but delivery failed and the purchaser waits out `DELIVERY_WINDOW` then calls `refundFailedDelivery` themselves (see below).
- **Pending delivery handling**: on selection, `_settleReadyAcquisition` calls `_settleAndRemove` (removes listing from tree/pool), sets `listing.status = DeliveryPending`, `acquisition.status = DeliveryPending`, records `pendingDeliveries[listingId] = {requestId, deadline: now + DELIVERY_WINDOW}` (7 days, line 159), adds `acquisition.priceEscrowed` to `deliveryEscrowTotal`. Then attempts `_tryAtomicNFTDelivery` (bounded self-call, `NFT_DELIVERY_GAS=150_000` gas) — on success calls `_completeNFTDelivery` immediately (accrues proceeds, see §7); on failure emits `NFTDeliveryFailed` and leaves it pending. Anyone may call `retryNFTDelivery(listingId)` (permissionless, no gas stipend limit) before the deadline. After the deadline, only the listing's `purchaser` may call `refundFailedDelivery(listingId)` (1514-1533): converts `deliveryEscrowTotal` → `acquisitionRefundCredit[purchaser]`, sets `listing.status = DeliveryRefunded`, `acquisition.status = DeliveryRefunded`. The owner may then call `recoverRefundedNFT(listingId)` (owner-only) to reclaim the NFT — it is never auto-relisted.
- **Purchaser refund claim**: `withdrawAcquisitionRefund()` (1492-1499) pulls the caller's entire `acquisitionRefundCredit[msg.sender]` balance via `SafeTransferLib.forceSafeTransferETH`.
- **Where ETH sits at each step**: acquisition fee + VRF fee arrive with `acquire`/`acquireBatch`. VRF fee is forwarded immediately to `vrfService.prepareRequests{value: vrf}(...)` (1035/1098) — leaves the clone's balance right away. The pool fee (`priceEscrowed`) sits in the clone's own balance, tracked by `acquisitionEscrowTotal` (389) while `Pending`/`Ready`/being processed, then either: (a) moves conceptually into `deliveryEscrowTotal` while `DeliveryPending` (still same clone balance, just re-labeled), (b) becomes `acquisitionRefundCredit` (pull-claimable, still same balance) on any refund path, or (c) splits into `ownerProceeds` + `accruedProtocolFees` on successful delivery (line 1590-1591) — **only at delivery completion, not at selection**.
- **`selectionTimeoutBlocks` behavior**: set at init from `factory.selectionTimeoutBlocks()` (237, 632), default value shown in source is `30` blocks pre-init (line 237) but this is overwritten by `initialize`. Snapshotted per-request as `wordDeadlineBlock = block.number + selectionTimeoutBlocks` at request time (1179, 1207). If the VRF callback observes `block.number > wordDeadlineBlock`, the word is rejected and the acquisition becomes `TimedOut` in the callback itself (1313-1318) — the callback still caches nothing and callback liability accounting still fires. If ordered processing reaches a still-`Pending` request past its deadline before any callback arrived, it expires it inline (1367-1372) rather than waiting further.

## 9. Inventory rules

- **Staging vs active**: `listNFT` (664) activates the listing immediately via `_activateListing` if `unsettledAcquisitionCount == 0 && stagingHead == 0` (line 711); otherwise it is pushed to the staging FIFO with `ListingStatus.Staged` (event `ListingStaged`, 717) and, if there's no unresolved acquisition, `_drainStaging(maxActivationsPerAcquisition)` is immediately attempted to preserve FIFO order against any surviving old tail (719-721).
- **`inventoryVersion` increments** on every owner-driven mutation via `_recordInventoryChange()` (733-739): called from `listNFT` (724), `withdrawListing` (909), `updatePrice` (950). Each call increments `inventoryVersion` and sets `lastInventoryChangeAt = block.timestamp`, emits `InventoryChanged(version, changedAt)`.
- **`lastInventoryChangeAt`**: `uint64 public`, set only inside `_recordInventoryChange` (736-737).
- **Cooldown formula**: `purchasesResumeAt() = lastInventoryChangeAt + factory.inventoryChangeCooldown()` (729-731), read live from factory each call (so a factory governance change to the cooldown duration applies retroactively/immediately to all clones). Enforced in `_validateInventoryCommitment` (1109-1117): reverts `InventoryChangeCooldownActive(resumeAt)` if `block.timestamp < resumeAt`. **Stacking**: any subsequent owner mutation restarts the cooldown from that new timestamp (no cap on cooldown extension by repeated listing changes) — the cooldown clock is a single scalar, so rapid owner actions keep pushing `purchasesResumeAt` forward indefinitely.
- **Blocked while acquisitions unsettled** (`unsettledAcquisitionCount != 0`, enforced via `_requireExitUnlocked()`, 882-884, `WithdrawLocked()`): `withdrawListing` (897) and `updatePrice` (933) are locked. `listNFT` is NOT blocked — it is always allowed but routes to staging instead of activating (§ above). `activateListings` is a no-op (early return) while unsettled (749).
- **`activateListings(uint256 maxCount)` preconditions/permissions**: permissionless (748-751), but only does work when `unsettledAcquisitionCount == 0`; then calls `_drainStaging(maxCount)`.
- **Maximum activations per acquisition**: `maxActivationsPerAcquisition` (216, owner-config via factory at init only — no clone-level setter observed; hard ceiling `MAX_ACTIVATIONS_PER_ACQUISITION = 16`, line 217). Each `_openAcquisition` reserves up to this many FIFO staged listings (`_reserveStagedBatch`, 794-808) before requesting VRF; that exact batch activates at settlement/expiry time via `_activateReservedBatch` (812-827), regardless of outcome.
- **Per-tx / per-pool caps**: `maxAcquisitionsPerTx` (244, set at init from factory, hard-capped implicitly by factory's `uint16`) bounds `count` in `acquireBatch` (`InvalidAcquisitionCount()` if `count == 0 || count > maxAcquisitionsPerTx`, line 1083). `maxStagedListings` (318, optional, `0` = unlimited) caps the unreserved staging FIFO length — `StagingQueueFull()` if exceeded on `listNFT` (line 714). No cap on `activeListingCount` other than `CAPACITY = 2^32` slots.

## 10. Factory interface (`IFWACloneFactory`)

All functions the clone calls on the factory, file `.../interfaces/IFWACloneFactory.sol:8-41`:

| Factory function | Called from (FWAClone.sol line) | Purpose / what it controls |
|---|---|---|
| `vrfCoordinator()` | `initialize` (603) | Must equal `vrfService` address; validated once. |
| `vrfSubscriptionId()` | `initialize` (605) | Seeds `vrfSubId` (immutable post-init). |
| `vrfKeyHash()` | `initialize` (606) | Seeds `vrfKeyHash` (can later change via `configureVrfRequest`, service-only). |
| `callbackGasLimit()` | `initialize` (607) | Seeds `callbackGasLimit` (also changeable via `configureVrfRequest`). |
| `requestConfirmations()` | `initialize` (608) | Seeds `requestConfirmations` (fixed after init — no clone setter). |
| `selectionTimeoutBlocks()` | `initialize` (609) | Seeds `selectionTimeoutBlocks` (fixed after init — no clone setter observed). |
| `maxActivationsPerAcquisition()` | `initialize` (610) | Seeds `maxActivationsPerAcquisition` (fixed after init). |
| `maxAcquisitionsPerTx()` | `initialize` (611) | Seeds `maxAcquisitionsPerTx` (fixed after init). |
| `selectionSlippageBps()` | `initialize` (612) | Seeds `selectionSlippageBps` (fixed after init). |
| `maxStagedListings()` | `initialize` (639) | Seeds `maxStagedListings` (fixed after init). |
| `edgeBps()` | `acquisitionFee()` (972) | **Read live every quote/settlement** — factory can change the protocol edge and it applies immediately pool-wide. |
| `inventoryChangeCooldown()` | `purchasesResumeAt()` (730) | **Read live** — factory governs cooldown duration for all clones at once. |
| `globalWithdrawOnly()` | `listNFT` (671), `updatePrice` (929), `_validateAcquisition` (1157) | **Read live** — global kill-switch: when true, blocks new listings/repricing/purchases but not withdrawals. |
| `globalPurchasesEnabled()` | `_validateAcquisition` (1158) | **Read live** — global purchase on/off switch across all clones. |
| `consumerReady(address pool)` | `_validateAcquisition` (1159) | **Read live** — factory must have this clone registered/ready as a VRF consumer or purchases revert `ConsumerNotReady()`. |
| `vrfRequestsPaused()` | `_validateAcquisition` (1160), `configureVrfRequest` (1253) | **Read live** — pauses new VRF requests globally. |
| `protocolFeeRecipient()` | `initialize` (643), `protocolFeeRecipient()` view (654), `payoutProtocolFees` (1621) | **Read live** — destination for protocol fee sweeps; factory can rotate it. |
| `globalPurchasesEnabled()` / `vrfRequestsPaused()` also re-checked in `configureVrfRequest` (1253) | — | Gate for VRF gas-lane resync. |

Factory functions NOT called by the clone but relevant to integrators from the interface listing: `chainlinkCoordinator()`, `routerCallbackGasLimit()`, `buybackPurchaserBps/OwnerBps/ProtocolBps/PurchaserWindow/FinalizationWindow` (buyback-variant only, unused by standard clone), `poolCreationEnabled()`, `vrfSubscriptionActive()/vrfSubscriptionTerminated()/vrfRecoveryRecipient()` (VRF-service admin surface), `isPool(address)`, `maxOutstandingRequestsPerPool()/maxOutstandingRequestsGlobal()` (not read by this clone — likely enforced at the VRF service/router layer, not in `FWAClone.sol`).

**Summary of what an owning game contract must watch as externally-mutable and pool-behavior-affecting**: `edgeBps` (changes acquisition price instantly), `inventoryChangeCooldown` (changes purchase-resume timing instantly), `globalWithdrawOnly`, `globalPurchasesEnabled`, `vrfRequestsPaused`, `consumerReady(pool)`, `protocolFeeRecipient` — all read live, none snapshotted at clone init.

## 11. `IPurchaseOperator`

```solidity
interface IPurchaseOperator {
    function canPurchase(address wallet) external view returns (bool allowed);
}
```
(IPurchaseOperator.sol:7-9)

- Call site: `_validatePurchaseOperator(address purchaser)` (FWAClone.sol:1122-1144), invoked from both `_acquire` (1025) and `_acquireBatch` (1086) — **before** the fee/slippage validation (`_validateAcquisition`) and before any payment is taken or VRF requested. If `purchaseOperator == address(0)` the check is a no-op.
- `msg.sender` seen by the operator contract is the **FWAClone pool address** (`this`), not the original caller — confirmed by the doc comment in `IPurchaseOperator.sol:6` ("The calling pool is available as `msg.sender`").
- Argument passed: `purchaser` (the acquisition's designated recipient argument to `acquire`/`acquireBatch`), not `msg.sender` of the `acquire` call itself.
- Mechanics: raw `staticcall` via inline assembly (not a Solidity interface call) with a fixed gas stipend `PURCHASE_OPERATOR_GAS = 100_000` (line 156, 1129). Requires the call to succeed AND return exactly 32 bytes AND that word be canonically `0` or `1` (`gt(result,1)` invalidates any other value) — line 1130-1140.
- **False / malformed return handling**: any of — call fails, wrong return size, or return word `> 1` — sets `checked = false` → `revert PurchaseOperatorCheckFailed()` (1142). A well-formed but `false`/`0` result → `revert PurchaseNotAllowed()` (1143). Both fail closed (revert), never silently skip the purchase.

## 12. ERC721 delivery

- **Custody at `listNFT`**: `ERC721(collection).transferFrom(msg.sender, address(this), tokenId)` — plain `transferFrom`, not `safeTransferFrom` (line 689, with an explicit comment at 679-688 explaining why: destination is a known contract, no receiver callback needed, and arbitrary safe-transfers sent directly are meant to revert rather than create untracked listings — the clone does not implement `onERC721Received`). Requires the pool owner to have approved the clone beforehand (per-token `approve` or collection-wide `setApprovalForAll`). Post-transfer sanity check: `ownerOf(tokenId) == address(this)` else `NFTTransferFailed()` (line 691-693).
- **Delivery to purchaser** (`executeNFTDelivery`, 1547-1566, callable only via `msg.sender == address(this)` self-call): uses `ERC721(collection).transferFrom(address(this), recipient, tokenId)` — again plain `transferFrom`, not `safeTransferFrom`. Post-transfer sanity check: `ownerOf(tokenId) == recipient` else `NFTTransferFailed()` (1565).
- **Withdrawal to owner-depositor** (`withdrawListing`, 911): uses `ERC721(collection).safeTransferFrom(address(this), msg.sender, tokenId)` — this ONE path uses the safe variant (no ownership-verification revert follows it, unlike the other two transfer paths).
- **Try/catch behavior on delivery**: `_tryAtomicNFTDelivery` (1570-1576) uses a raw low-level `call` in assembly (not Solidity try/catch) with a bounded gas stipend `NFT_DELIVERY_GAS = 150_000`, targeting `this.executeNFTDelivery(listingId)`; a `false` return (revert inside, or OOG) is swallowed — no revert propagates to the caller of `_settleReadyAcquisition`. On failure it just emits `NFTDeliveryFailed` and leaves `listing.status = DeliveryPending` for permissionless retry (`retryNFTDelivery`, no gas cap — a plain external call `this.executeNFTDelivery(listingId)`, line 1509, so retries are NOT gas-bounded and can consume arbitrary gas from the retrying caller's tx).
- **Failure reasons possible**: collection requires a paused-transfer condition, a blacklist, a malicious `ownerOf` override, or insufficient gas within the 150k stipend on first attempt.
- The clone must be the current owner (post-`listNFT`) or hold a valid transfer path for each escrowed token; there is no "approved operator" delivery path — the clone always transfers as the token's direct owner (`address(this)`).

## 13. VRF

- Coordinator interface used: `IVRFCoordinatorV2Plus` (Chainlink v2.5), imported from `@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol`. The clone does **not** inherit Chainlink's official consumer base (`VRFConsumerBaseV2Plus`); it hand-implements the pattern (comment at FWAClone.sol:283-286).
- **The clone's `s_vrfCoordinator` is NOT the real Chainlink coordinator** — it is the immutable singleton `FWAVRFService`/router (`vrfService`, set at construction), which itself is "the real subscription's sole consumer" per the header comment (lines 10-12, 165-167). The clone calls `s_vrfCoordinator.requestRandomWords(...)` (1183) and only accepts callbacks from `msg.sender == address(s_vrfCoordinator)` (1288) — i.e. only from this service/router, never directly from Chainlink's coordinator.
- **Subscription model**: singleton **subscription**-based (`vrfSubId`, shared across all clones via the service), **native payment** — `extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))` (line 1190). Not LINK-funded from the clone's perspective.
- **Request fee charged to purchaser**: `vrfServiceFee() = vrfService.requestFee()` (961-963), explicitly noted as gas-price dependent (`tx.gasprice`) — doc comment recommends quoting via `eth_call` at the intended gas price (line 960). This fee is paid by the purchaser at `acquire`/`acquireBatch` time and forwarded to `vrfService.prepareRequests{value: vrf}(count)` (1035, 1098) BEFORE the VRF request is placed — funds pre-fund callback coverage; if the request itself reverts, the whole tx (including this forwarded payment) reverts.
- **Callback gas assumptions**: `callbackGasLimit` (189, `uint32 public`), bounded `[MIN_CALLBACK_GAS_LIMIT=150_000, MAX_CALLBACK_GAS_LIMIT=2_500_000]` (190-191). Fast-path settlement inside the callback additionally requires `callbackGasLimit >= MIN_FAST_PATH_CALLBACK_GAS_LIMIT = 900_000` (195) to attempt inline processing; that inline attempt reserves `CALLBACK_FAST_PATH_GAS = 700_000` for the subcall and `CALLBACK_RETURN_GAS_RESERVE = 50_000` to guarantee the parent callback itself returns successfully (1339-1347).
- `requestConfirmations` (`uint16`, 201) bounded `[MIN_REQUEST_CONFIRMATIONS=3, MAX_REQUEST_CONFIRMATIONS=200]` (205-206), with `selectionTimeoutBlocks` required to exceed `confirmations + MIN_CALLBACK_SLACK_BLOCKS(=2)` at init (line 618).
- `NUM_WORDS = 1` — exactly one random word per acquisition request (line 183).

## 14. Reentrancy guards and ETH handling

- `nonReentrant` (Solady `ReentrancyGuard`) modifier on: `listNFT` (666), `activateListings` (749 — note: no `nonReentrant`? checking — actually has `nonReentrant`, line 748), `withdrawListing` (894), `updatePrice` (925), `acquire` (1007), `acquireBatch` (1060), `processAcquisitions` (1358), `withdrawAcquisitionRefund` (1492), `retryNFTDelivery` (1506), `refundFailedDelivery` (1514), `recoverRefundedNFT` (1536), `withdrawOwnerProceeds` (1608), `payoutProtocolFees` (1617). NOT `nonReentrant`: `rawFulfillRandomWords`/`fulfillRandomWords` (coordinator-gated instead), `executeNFTDelivery` (self-call gated instead — `OnlySelf()`), `configureVrfRequest`, `reconcileUnfulfilledVrfCount`, `setBool`, `setPurchaseOperator`, `retirePool` (owner-gated, no ETH movement), all views.
- ETH is always sent via `SafeTransferLib.forceSafeTransferETH(recipient, amount)` (Solady) — used in `_refund` (1230), `withdrawAcquisitionRefund` (1497), `withdrawOwnerProceeds` (1612), `payoutProtocolFees` (1623). "Force" variant means it will use as much gas as needed / fall back to WETH-wrap-style handling per Solady's implementation if a plain call fails — check `lib/solady/src/utils/SafeTransferLib.sol` for the exact fallback if the recipient is a contract that rejects ETH (not reproduced here — see that file directly if needed).
- No `receive()` or `fallback()` function is defined in `FWAClone.sol` — the contract cannot passively accept stray ETH; the only payable entrypoints are `acquire` and `acquireBatch`.

## 15. Retirement

- `retirePool() external onlyOwner` (1774-1780): reverts `PoolAlreadyRetired()` if already `retired`. Sets `retired = true` (irreversible — no un-retire function exists), force-disables `acquisitionsEnabled = false` (emits `ConfigSet`), emits `PoolRetired(msg.sender)`.
- Effects: `listNFT` reverts `PoolAlreadyRetired()` (670); `updatePrice` reverts `PoolAlreadyRetired()` (926); `setBool`/`setPurchaseOperator` both revert `PoolAlreadyRetired()` (1755, 1764) — so purchase-operator policy is frozen too. `acquire`/`acquireBatch` revert `PoolAlreadyRetired()` (1022, 1082).
- What remains callable after retirement (per doc comment 1772-1773 and code review): `withdrawListing`, `activateListings`, `processAcquisitions`, `withdrawAcquisitionRefund`, `retryNFTDelivery`, `refundFailedDelivery`, `recoverRefundedNFT`, `withdrawOwnerProceeds`, `payoutProtocolFees`, `reconcileUnfulfilledVrfCount`, `configureVrfRequest`, all views — i.e. every settlement/exit/withdrawal path stays open; only new inventory input and new purchases are blocked.

## 16. Integration hazards

- **Owner proceeds accrue only at delivery completion**, not at selection/settlement time (`_completeNFTDelivery`, FWAClone.sol:1590-1591). A game contract tracking revenue must listen for `OwnerProceedsAccrued`/`PurchaseProceedsAccrued`, not `NFTAllocated`.
- **`purchaser` and the tx caller (`msg.sender`) can differ** — `acquire(address purchaser, ...)` lets any caller buy on behalf of another address. Refund of *overpayment* goes to `msg.sender` (`_refund`, uses `msg.sender` at line 1230), but the acquisition itself (NFT, later refund credit if it fails) belongs to `purchaser`. A ShapesPoolCore wrapper must decide who it passes as `purchaser` and reconcile overpayment refunds landing on itself vs. the end user.
- **`purchaseOperator.canPurchase` sees the pool as `msg.sender`**, not the original transaction sender — an operator implementation must be written against that, and PurchaseOperatorCheckFailed fails closed on ANY malformed/failed staticcall (§11), so a misbehaving operator contract can brick all purchases pool-wide.
- **Batch caps compound**: `acquireBatch` count is capped by `maxAcquisitionsPerTx` (owner cannot raise this from the clone — it's factory-seeded at init only, no clone setter observed for it), and each acquisition within the batch independently re-checks slippage at its own settlement turn (line 1048-1050) — a batch is NOT atomically all-or-nothing on price; individual entries can still be refunded via slippage even though the whole batch was priced once at submission.
- **Cooldown stacking**: every owner mutation (list/withdraw/reprice) resets `purchasesResumeAt` to `now + factory.inventoryChangeCooldown()` (§9) — repeated owner inventory operations in short succession can indefinitely delay purchase availability; a game contract driving inventory changes (e.g. programmatic relisting) must batch/throttle its own calls into the pool to avoid self-inflicted purchase lockout.
- **Staged listings are invisible to `acquisitionFee()`/`weightedBackingTotal`/`totalWeight`** until activated — deposits made while a request is in flight do not affect price or selection odds for outstanding requests, but also do not appear in any of the standard pool-value views until later `processAcquisitions`/`activateListings` calls run. An indexer/UI must separately track the internal staging FIFO length (no public getter for `stagingHead`/`stagedCount` — only `reservedStagedCount` and per-sequence lookups are exposed, §3).
- **Owner-only listing**: `listNFT` is hard-restricted to `msg.sender == owner()` (line 669) — the owning game contract itself must be the caller (not e.g. an approved operator address), and since ownership is permanently locked (§1), the game contract's own address becomes the sole listing authority forever.
- **Delivery is two-phase and can fail**: a successful VRF draw does not guarantee the buyer receives the NFT in the same transaction — `NFTDeliveryFailed` can fire, leaving `DeliveryPending` for up to `DELIVERY_WINDOW = 7 days` (159) before the purchaser can convert to a refund. UI/game logic must poll listing/acquisition status rather than assume delivery == purchase completion.
- **Rounding**: protocol/owner fee split rounds `protocolAmount` down (`(paid - basePrice) / 2`, floor division, line 1586) — owner always gets the remainder, i.e. any 1-wei rounding favors the owner over the protocol.
- **`consumerReady` gate**: purchases silently revert `ConsumerNotReady()` (1159) until the factory has registered/readied the specific clone address as a VRF consumer — this is an off-chain/factory-side prerequisite the game contract cannot itself satisfy from within the clone.
- **No `receive()`/`fallback()`** (§14) — sending plain ETH to the clone (e.g. accidental transfer) will revert; only `acquire`/`acquireBatch` accept value.
- **`executeNFTDelivery` retries are gas-unbounded**: `retryNFTDelivery`/`recoverRefundedNFT` call `this.executeNFTDelivery(listingId)` as a plain external call with no gas stipend cap (unlike the first atomic attempt's 150k stipend) — a malicious/broken collection could make retries expensive or force callers to supply large gas, but cannot block the eventual `refundFailedDelivery` purchaser exit after the window.

## 17. Buyback variant delta

`FWACloneBuyback.sol` (2084 lines, at `the buyback implementation (not vendored)`) is a structurally parallel but economically different implementation: instead of a purely notional owner-assigned price with no real backing, every listing is paired with actual ETH `backing` supplied at `listNFT(address collection, uint256 tokenId)` — note this variant's `listNFT` is `payable` (line 718) and takes no `price` argument (the ETH sent IS the backing/price). On a successful draw the purchaser does not receive the NFT automatically; instead they choose between `keepNFT(listingId)` (take the NFT) or `acceptBuyback(listingId)` (take the ETH backing) — functions entirely absent from the standard clone. It adds a settlement/finalization window (`ownerResolveNFTToPurchaser`, `ownerResolveBuyback`, `finalizeUnsettled`, `recoverStuckNFT`) for cases where the purchaser never chooses, plus an owner-fundable auto-reload mechanism (`fundAutoReload`, `setAutoReloadNFTs`, `withdrawAutoReloadETH`, `_tryAutoReload`/`_createAutoReloadListing`) that can automatically relist a new NFT+backing pair when a buyback is taken, and a `claimBuybackETHTo` pull-claim path. It also carries a factory wiring marker (comment near line 44) to prevent it from being mistaken for the standard implementation. The core VRF/sequencing/staging/segment-tree/slippage machinery (§6-§9, §13-§14 above) is otherwise identical between the two contracts.
