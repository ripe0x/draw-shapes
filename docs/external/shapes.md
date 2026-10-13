# Shapes — External Integrator Dossier

Repo: `/Users/dd/CascadeProjects/shapes` (read-only inspection). HEAD at time of inspection:
`53969b6894c64c8daa1ef5a55cee208c63eda938` (2026-09-09, branch `main`).

## 1. Deployment facts

Source: `lib/shapes/deployments/1.json` (mainnet, chainId 1), verbatim:

```json
{
  "rpc": "https://ethereum-rpc.publicnode.com",
  "indexerUrl": "https://shapes-indexer-mainnet.fly.dev",
  "chainId": 1,
  "shapes": "0x6fe9193276bf7abcbee44ab7afd717d637d6faf0",
  "renderer": "0xe9ac8d910767d8efc71bf4f2cb5d7ef4c4f69295",
  "collection": "0x9d1bd0c348900d5c6bce28148f2adc68f73c8af3",
  "auctionHouse": "0xe123d75956cb2c487251593e1be50985b23f427d",
  "mintFeeWei": "1000000000000000",
  "mintStart": "1788462000",
  "libraries": {
    "AdminOps": "0xde64667e15ff3999f6fa0bcf9930c1653e361597",
    "ComposeCompute": "0xfbf7f6e9552f93d2dbd86e30b3b0637be5d520ea",
    "CopyValidation": "0xede9393cf5bd8037b9d4a15c2d864f97f98a9da7",
    "EIP712Signature": "0x48208746f35222a751e5fe286a8942bfceaf0906",
    "GeometrySampling": "0x991e1352b0f6131748f36d8d45f756d55ee930d3",
    "InkGenes": "0x34a7a97b92288b3f804f416b3b15214fb85e4200",
    "RecompositionOps": "0x94f63d2bcbcd6a3980bebbbe71de498e57f200f2"
  },
  "fromBlock": 25898721,
  "auctionId": "0",
  "artistReleaseHash": "0xca51273fc507fd7c2ff85d5813660b59de876c714a866a5a229079a5e7ca24dc",
  "commit": "1b84c102a6603ca9751d863ff259b08870d22a6b",
  "branch": "main",
  "auctionHouseFromBlock": 25941422
}
```

- Mainnet Shapes address (deployment record, lowercased): `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`.
  Byte-for-byte identical (case-insensitive) to the address the caller asked to confirm,
  `0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0` — CONFIRMED as the same 20-byte address. Checksum
  casing was not independently re-derived in this pass (no on-chain/`cast` call made); both are
  40 hex chars, same digits.
- Chain id: 1 (mainnet).
- Renderer: `0xe9ac8d910767d8efc71bf4f2cb5d7ef4c4f69295`.
- Collection (metadata contract, `ShapeCollection`): `0x9d1bd0c348900d5c6bce28148f2adc68f73c8af3`.
- Auction house (periphery, `ShapeAuctionHouse`): `0xe123d75956cb2c487251593e1be50985b23f427d`.
- Libraries (linked, `DELEGATECALL`, no setter — trusted implementation): `AdminOps`,
  `ComposeCompute`, `CopyValidation`, `EIP712Signature`, `GeometrySampling`, `InkGenes`,
  `RecompositionOps` — addresses above.
- Deployed git commit: `1b84c102a6603ca9751d863ff259b08870d22a6b`, branch `main`
  (`deployments/1.json:24-25`). This commit was not checked out/diffed against current HEAD in
  this pass.
- Sepolia deployment record: `lib/shapes/deployments/11155111.json`
  (chainId 11155111), pasted verbatim above the mainnet block is not duplicated here — see file;
  key fields: `shapes = 0x6c2f9c00f44fbbf141dd166979903004b80d5f99`,
  `renderer = 0x7025fc7e13ca24505d471e193e2e2a54e960a1b2`,
  `mintFeeWei = "10000000000000"` (0.00001 ETH — testnet ladder is 100x smaller, see §3),
  commit `b3370281e56a61dc7c5e05b59d2aa709b804525c`, branch `claude/contracts-page` (not `main`).

## 2. Exact external interface

Primary interface file to copy into an external repo:
`lib/shapes/src/interfaces/IShapes.sol` (672 lines). It extends
`IERC721` (OpenZeppelin), `IERC721Value` (`src/interfaces/IERC721Value.sol`, draft ERC-8060),
and `IAdminControl` (`src/interfaces/IAdminControl.sol`). Also copy those two plus
`src/ShapeTypes.sol` (return-type structs: `ComposeRecordView`, `ShapeChildPreview`,
`ShapeFormation`, `ShapeState`, etc., defined at `src/ShapeTypes.sol:11,27,39,52,66,79,91,115,130,142,158`).
Implementation: `src/Shapes.sol` (1225 lines), contract `Shapes is ERC721, ReentrancyGuard,
IShapes, IERC2981, IERC4906` (`src/Shapes.sol:69`).

### Mint entrypoints

All four are `external payable nonReentrant`, callable by anyone (no allowlist), and all funnel
into the same private `_mintBatch` (`src/Shapes.sol:406`):

```solidity
function mint(uint256 amountWei) external payable returns (uint256 tokenId);                              // IShapes.sol:331, Shapes.sol:361
function mintTo(uint256 amountWei, address to) external payable returns (uint256 tokenId);                 // IShapes.sol:336, Shapes.sol:366
function mintBatch(uint256 amountWei, uint256 quantity) external payable returns (uint256 firstTokenId);   // IShapes.sol:341, Shapes.sol:371
function mintBatchTo(uint256 amountWei, uint256 quantity, address to) external payable returns (uint256 firstTokenId); // IShapes.sol:344, Shapes.sol:381
```

- `amountWei` must be one of the 9 ladder denominations (`Shapes.sol:427-430`,
  `Denominations.indexOf`); else `UnsupportedDenomination(amountWei)`.
- `msg.value` formula (`Shapes.sol:431-433`): `msg.value == amountWei * quantity + mintFee() * quantity`
  (i.e. `quantity * (amountWei + mintFee())`); mismatch reverts `IncorrectPayment(expected, provided)`.
- Gate: `block.timestamp >= mintStart` (immutable, mainnet `mintStart = 1788462000`), else
  `MintNotOpen()` (`Shapes.sol:415`). `quantity == 0` reverts `ZeroQuantity()`.
- No per-call quantity cap in the contract itself (bounded only by block gas — batch loops mint
  `quantity` NFTs via `_safeMint`, `Shapes.sol:464`).
- Any address may call; `mintTo`/`mintBatchTo` mint to an arbitrary `to`, which does not need to
  be `msg.sender`. `to` (or `msg.sender` for `mint`/`mintBatch`) must be able to receive an
  ERC-721: `_safeMint` is used, so **a contract recipient must implement
  `IERC721Receiver.onERC721Received`**, or the mint reverts (`Shapes.sol:464`, comment
  `Shapes.sol:337-338` in IShapes.sol). A contract CAN mint (call these functions) and CAN
  receive, provided it implements the receiver hook.
- Fee: flat `mintFee()` per token, credited to `feeRecipient()`'s pending balance
  (`_feesOwed[recipient] += fees`, `Shapes.sol:456-459`), withdrawn separately via
  `withdrawFees(recipient)` (anyone may call, pays `recipient`, `Shapes.sol:471-478`). Fee never
  enters `redeemableBacking`.
- Seed: `keccak256(batchRoot, tokenId)`, `batchRoot` mixes `block.prevrandao`, previous
  blockhash, `block.number`, `block.timestamp`, `block.chainid`, contract address, and
  `firstTokenId` (`Shapes.sol:392-402`). Explicitly documented as grindable, not secure
  randomness (`Shapes.sol:434-438`); does not affect redemption value.

### valueOf / burn (ERC-8060 draft)

```solidity
function valueOf(uint256 tokenId) external view returns (uint256); // IERC721Value.sol:9, Shapes.sol:845 (== backingOf(tokenId))
function burn(uint256 tokenId) external;                            // IERC721Value.sol:14, Shapes.sol:495 (nonReentrant)
```

- `valueOf` = `backingOf(tokenId)`, reverts for nonexistent id (`_requireOwned`). Returns 0 for a
  Black Shape.
- `burn(tokenId)`: only the **current owner** may call (`_burnForRedemption`,
  `Shapes.sol:562-583`, checks `tokenOwner == msg.sender`, else `NotShapeOwner`); an approved
  operator must first take ownership via transfer. Destroys the token and pays `valueOf` to
  `msg.sender` (via `_redeemTo(tokenId, msg.sender, allowBlack=true)`). Unlike `redeem`, `burn`
  is allowed on a Black Shape (pays 0, no ETH call). `guarded by nonReentrant`.
- Native `redeem` family (`IShapes`, not ERC-8060) behaves the same for non-Black tokens but
  reverts `TokenIsBlack` on a Black Shape:
  ```solidity
  function redeem(uint256 tokenId) external;                                                  // Shapes.sol:487
  function redeemBatch(uint256[] calldata tokenIds) external returns (uint256 totalWei);        // Shapes.sol:500
  function redeemTo(uint256 tokenId, address payable recipient) external;                       // Shapes.sol:505
  function redeemBatchTo(uint256[] calldata tokenIds, address payable recipient) external returns (uint256 totalWei); // Shapes.sol:510
  ```
  Owner-only (`_burnForRedemption`, `Shapes.sol:566-567`), `recipient` must be nonzero
  (`InvalidRecipient`), pays exact backing, no fee. `redeem`/`burn`/`redeemBatch` pay
  `msg.sender`; `redeemTo`/`redeemBatchTo`/`burn`-via-transfer-then-burn let the owner name an
  arbitrary payout recipient. **Redeeming/burning the owner token (`ownerToken()`) permanently
  ends collection ownership** (`owner()` → zero, no successor) — `Shapes.sol:568-571`.

### compose

```solidity
function compose(uint256 survivorId, uint256[] calldata burnIds) external returns (uint256 outId); // IShapes.sol:381, Shapes.sol:600 (nonReentrant)
function composeMany(ComposeCall[] calldata calls) external returns (uint256[] memory outIds);       // IShapes.sol:392, Shapes.sol:609
```

- Caller must **own and hold live** (not Black) both `survivorId` and every id in `burnIds`
  (`_requireCallerOwnsLive` → `RecompositionOps.requireLiveOwner`, `Shapes.sol:630-636`,
  `RecompositionOps.sol:49-54`; per-input check `RecompositionOps.requireComposeInput`,
  `RecompositionOps.sol:60-76`). No "approved operator" path — literal ERC-721 `ownerOf ==
  msg.sender` on each token (approval alone is insufficient; an approved operator must transfer
  to itself first).
- `burnIds` must be non-empty (`NoComposeInputs`), contain no duplicates (`DuplicateComposeInput`,
  checked by `RecompositionOps.requireDistinctComposeInputs`, `RecompositionOps.sol:77-110`), and
  the survivor cannot appear in its own `burnIds` (`CannotComposeWithSelf`).
- **Survivor keeps its token id and seed**; every id in `burnIds` is burned
  (`ERC721._burn`, no receiver callback) into it. `Composed` event's `denomIndex` is the
  survivor's new (summed) denomination.
- Denomination rule: `Denominations.requireIndexOf(acc.total)` (`RecompositionOps.sol:181`) —
  the **sum of survivor's backing + every burned input's backing must land exactly on one of the
  9 ladder amounts** (§3). There is no restriction on which specific inputs combine (no "must be
  2x0.05" pattern enforced structurally) beyond the sum landing on a valid rung; see §3.
- Origins (`originCountOf`) are summed onto the survivor. If the owner token is among `burnIds`,
  ownership moves to `survivorId` (`Shapes.sol:653-658`, `OwnerTokenMoved` event).
- **No ETH moves, no fee charged** (`Shapes.sol` comment at 600-603; `redeemableBacking`
  untouched since sum is conserved).
  `composeMany` runs several composes in one tx/one reentrancy guard, atomically, gas-bounded by
  caller-chosen batch size (`Shapes.sol:609-620`).
- Reversible: each compose pushes a record consumed by `decompose` (see §7).

### decompose

```solidity
function decompose(uint256 survivorId) external returns (uint256[] memory restoredIds);                          // IShapes.sol:401, Shapes.sol:717 (nonReentrant)
function decomposeTo(uint256 survivorId, address recipient) external returns (uint256[] memory restoredIds);      // IShapes.sol:406, Shapes.sol:722
function decomposeMany(uint256[] calldata survivorIds) external returns (uint256[][] memory restoredIds);          // IShapes.sol:413, Shapes.sol:735
function decomposeManyTo(uint256[] calldata survivorIds, address recipient) external returns (uint256[][] memory); // IShapes.sol:416, Shapes.sol:746
```

- Caller must own and hold live (not Black) `survivorId` (`_requireCallerOwnsLive`,
  `Shapes.sol:770`).
- **LIFO rule**: reverses the survivor's **most recent** (topmost) compose record; stacked
  composes unwind newest-first (`Shapes.sol:717-720` doc, `RecompositionOps.decompose`,
  `RecompositionOps.sol:221-227`). Reverts `NoComposeRecord(survivorId)` if the stack is empty
  (`composeDepth(survivorId) == 0`).
- Result: survivor reverts to its pre-compose denomination/origin-count/gene; every input burned
  by that compose is **re-minted under its original id and seed** via `_safeMint` to `recipient`
  (default: caller) — `Shapes.sol:775-782`. Re-minted ids do NOT advance `totalMinted` and do NOT
  emit `ShapeMinted` (only `Decomposed` + per-input `ShapeRevived`). Since re-minting uses
  `_safeMint`, **`recipient` (or caller) must implement `onERC721Received` if it is a contract**.
- If the reversed compose had moved ownership from one of its inputs, ownership restores to that
  input only after every restored id has been minted (`Shapes.sol:786-792`, ordering note in
  comment: moving `_ownerToken` before the mint loop could let a receiver callback observe an
  `ownerToken()` pointing at an id not yet minted).
- **No ETH moves, no fee charged.**
- `decomposeMany`/`decomposeManyTo`: repeat an id to pop several stacked records; list
  parent-before-child for nested trees so a re-minted input exists before its own id is reached;
  atomic, gas-bounded (`Shapes.sol:735,746`).

### transfer / approve, ERC-165, self-custody block

- Standard OpenZeppelin ERC-721 transfer/approve/`safeTransferFrom`/`getApproved`/
  `isApprovedForAll` — `Shapes` inherits `ERC721` with no added modifier on those functions
  (not `nonReentrant`; comment `Shapes.sol:53-56` explicitly flags that a receiver can re-enter
  and e.g. `redeem` during its own `onERC721Received` mid-`safeTransferFrom` — "an integrator
  must not assume the token still exists after that callback returns").
- **Self-custody transfer block**: `_update` override (`Shapes.sol:1198-1201`) reverts
  `SelfCustodyRejected(tokenId)` whenever `to == address(this)` (the Shapes contract's own
  address) — covers `transferFrom`, `safeTransferFrom`, and the mint path. This does **not**
  restrict transfers to any other address, including a game/pool contract, provided that
  contract is not the Shapes contract itself.
- `supportsInterface` (`Shapes.sol:1203-1210`) answers true for: `IShapes`, `IAdminControl`,
  `IShapeValue`, `IShapeRecomposition`, `IShapeProvenance`, `IERC721Value` (draft ERC-8060),
  `IERC2981`, `bytes4(0x49064906)` (ERC-4906 `MetadataUpdate`/`BatchMetadataUpdate`), plus
  everything OZ `ERC721.supportsInterface` answers (`IERC721`, `IERC721Metadata`, `IERC165`).
- `royaltyInfo(uint256, uint256) external pure returns (address, uint256)` (`Shapes.sol:1129`) —
  IERC2981 is implemented but not inspected further in this pass (need its body to know the
  actual bps/recipient it returns — flagged as a gap in §11 if not zero/placeholder).

### owner/admin functions affecting fees or renderer

All `onlyAdmin` (`modifier onlyAdmin`, `Shapes.sol:274-277`, reverts
`AdminUnauthorizedAccount(msg.sender)`); `admin()` is a separate role from Shape/collection
`owner()` and from any protocol governance/timelock — **plain single EOA/multisig key, not
time-locked, no on-chain limiter beyond the fee cap below**:

```solidity
function admin() external view returns (address);                       // reads _admin, Shapes.sol:273
function transferAdmin(address newAdmin) external;                       // Shapes.sol:283, onlyAdmin, reverts on zero
function renounceAdmin() external;                                       // Shapes.sol:291, onlyAdmin, sets admin to 0
function setFeeRecipient(address newRecipient) external;                 // Shapes.sol:298, onlyAdmin
function setMintFee(uint256 newFee) external;                            // Shapes.sol:309, onlyAdmin
function setRenderer(address newRenderer) external;                      // Shapes.sol:314, onlyAdmin
function setCollection(address newCollection) external;                  // Shapes.sol:319, onlyAdmin
function lockPresentation() external;                                    // Shapes.sol:324, onlyAdmin, one-way
function refreshMetadata() external;                                     // Shapes.sol:331, onlyAdmin, emits only
function setPointer(uint8 pointer, address target) external;             // Shapes.sol:337, onlyAdmin
function lockPointer(uint8 pointer) external;                            // Shapes.sol:342, onlyAdmin, one-way
```

- `setMintFee`/construction fee are capped at `AdminOps.MAX_MINT_FEE = Denominations.UNIT` = 0.01
  ETH mainnet (`AdminOps.sol:69`), enforced both at construction (`Shapes.sol:225`,
  `_requireFeeWithinCap`) and in `AdminOps.setMintFee`. No lower bound (fee may be 0).
  `setMintFee` changes take effect for every subsequent mint call immediately — **a game contract
  minting/reselling Shapes should read `mintFee()` live before computing `msg.value`, not cache
  it.**
- Admin actions never touch Shape ownership, `redeemableBacking`, or accrued fees
  (`IAdminControl.sol:9-10` doc). Renderer/collection changes affect `tokenURI`/`svg` output only.
  `admin` address on mainnet was not read on-chain in this pass (not recorded in
  `deployments/1.json`) — gap, see §11.

## 3. Denomination ladder

Source: `lib/shapes/ladders/mainnet/Ladder.sol` (selected by the
`ladder/` remapping for the default Foundry profile; `ladders/testnet/Ladder.sol` is the
100x-smaller variant selected by `FOUNDRY_PROFILE=testnet`, used for the Sepolia deployment).
Consumed by `src/lib/Denominations.sol`.

Exact mainnet ladder, index → wei (`ladders/mainnet/Ladder.sol:23-32`):

| index | amount |
|---|---|
| 0 | 0.01 ETH |
| 1 | 0.05 ETH |
| 2 | 0.1 ETH |
| 3 | 0.5 ETH |
| 4 | 1 ETH |
| 5 | 5 ETH |
| 6 | 10 ETH |
| 7 | 50 ETH |
| 8 | 100 ETH (apex/max) |

- `UNIT = 0.01 ether` (`ladders/mainnet/Ladder.sol:19`); every denomination is a whole multiple
  of `UNIT`.
- Max denomination: index 8, 100 ETH ("apex"; `APEX_INDEX = 8`, `Shapes.sol:93`), required for
  `burnBacking` (Black Shape creation) together with `originCount == 10000`
  (`Denominations.unitsAt(8) = 100/0.01 = 10000`) — i.e. an apex Shape must be "Complete" (one
  origin per 0.01 unit, no compose/decompose shortcuts) to be burned to Black.
- **Composition/split rule is purely "sum lands on a rung," not a fixed step pattern.** Enforced
  in `RecompositionOps.compose` at `RecompositionOps.sol:181`:
  `uint256 newIndex = Denominations.requireIndexOf(acc.total);` — `acc.total` is the arithmetic
  sum of the survivor's pre-compose backing plus every burned input's backing
  (`Denominations.amountAt` per input). If that sum is not exactly one of the 9 table values
  above, `compose`/`previewCompose` revert `UnsupportedDenomination`. There is no requirement
  that inputs be same-denomination or count-matched (e.g. "5x0.1=0.5" is not a hard-coded rule —
  any combination whose sum equals an existing rung, such as 0.01+0.5+0.49-worth in mixed
  denominations landing on 1 ETH, is equally valid) as long as every input individually already
  exists at a valid denomination (they must, since only valid denominations can ever be minted or
  produced) and the total lands on the ladder. The commonly cited "2x0.05=0.1, 5x0.1=0.5,
  2x0.5=1, 5x1=5, ..." sequences are simply the *adjacent* combinations that also satisfy this
  general sum rule, not a separately coded special case.
- `split(tokenId, outDenoms)`: `outDenoms` (each an index 0-8) must sum in wei to exactly the
  input's backing (`SplitSumMismatch(inputBacking, outputSum)`), checked in
  `RecompositionOps.split` (`RecompositionOps.sol:280` on; exact revert line not individually
  extracted in this pass — function starts at `RecompositionOps.sol:280`), with at least 2
  outputs (`SplitTooFewOutputs`, `IShapes.sol:182-183`).
- Grid mapping per index (module count), not backing-relevant but affects rendering:
  `Denominations.gridAt`, `src/lib/Denominations.sol:57-69` (25 modules at index 0 down to 1
  module at index 8).

## 4. Fees

- **Mint fee**: flat, per Shape, `mintFee()` — mainnet deployment value in
  `deployments/1.json:9`: `"mintFeeWei": "1000000000000000"` = **0.001 ETH**. CONFIRMED matches
  the value the caller expected. (Sepolia: `"10000000000000"` = 0.00001 ETH, consistent with the
  testnet ladder being 100x smaller.) Charged on top of backing, never enters
  `redeemableBacking` (`IShapes.sol:213-216`).
- **Compose fee**: none — "No ETH moves and no fee is charged" (`IShapes.sol:378-380`,
  `Shapes.sol:600-603`).
- **Decompose fee**: none — same statement (`IShapes.sol:397-398`).
- **Split fee**: none (implied by "No ETH moves and no fee is charged" doc at
  `IShapes.sol:420-424`; split is structurally analogous to decompose).
- **Redeem/burn fee**: none — pays exact backing (`valueOf`/`backingOf`), no deduction anywhere
  in `_burnForRedemption`/`_redeemTo` (`Shapes.sol:523-533,562-586`).
- **Fee recipient**: `feeRecipient()` (`Shapes.sol:119-121`, reads `_feeConfig.feeRecipient`),
  admin-settable via `setFeeRecipient` (only affects *future* accruals; already-accrued balances
  to the old recipient remain owed and withdrawable, `IAdminControl.sol:29-32`). The actual
  mainnet `feeRecipient` address is **not recorded in `deployments/1.json`** (it's set at deploy
  time from the `SHAPES_FEE_RECIPIENT` env var, `script/Deploy.s.sol:128`, not persisted to the
  deployment record) — gap, would need `cast call <shapes> feeRecipient()`.
- **Mutability**: `mintFee` mutable by `admin()` only, via `setMintFee`, capped at
  `AdminOps.MAX_MINT_FEE = unit() = 0.01 ETH` mainnet (`AdminOps.sol:69`, enforced
  `AdminOps.sol` setter + `Shapes.sol:225` at construction). No floor, no timelock, no
  governance — single `admin` key, effective immediately for every subsequent mint call
  (`IAdminControl.sol:35-37` notes it also affects the auction house's ETH-bid card minting,
  which reads the fee live).
- Withdrawal: `withdrawFees(address recipient) external` (`Shapes.sol:471`) — **callable by
  anyone**, always pays the named `recipient`'s own accrued balance to that same `recipient`
  (never the caller), reverts `NoFeesPending` if zero owed. A reverting recipient blocks only its
  own withdrawal, not minting or other recipients' withdrawals.

## 5. Events (exact signatures)

All defined in `src/interfaces/IShapes.sol` (`Shapes` emits them; also `IAdminControl` and
inherited `IERC4906`):

```solidity
event ShapeMinted(uint256 indexed tokenId, address indexed to, uint256 amountWei, bytes32 seed, uint256 originCount);            // IShapes.sol:37
event ShapeRedeemed(uint256 indexed tokenId, address indexed to, uint256 amountWei, uint256 originCount);                         // IShapes.sol:43
event MintFeeAccrued(uint256 amountWei);                                                                                          // IShapes.sol:48
event FeesWithdrawn(address indexed recipient, uint256 amountWei);                                                                // IShapes.sol:51
event ArtistAttested(address indexed artist, bytes32 indexed releaseHash, bytes signature);                                       // IShapes.sol:54
event RendererUpdated(address indexed renderer);                                                                                   // IShapes.sol:57
event CollectionUpdated(address indexed collection);                                                                               // IShapes.sol:60
event PresentationLocked(address indexed renderer, address indexed collection);                                                    // IShapes.sol:64
event ContractURIUpdated();                                                                                                        // IShapes.sol:67
event PositionsSet(address indexed positions);                                                                                     // IShapes.sol:70
event PositionsLocked(address indexed positions);                                                                                  // IShapes.sol:73
event MarketSet(address indexed market);                                                                                           // IShapes.sol:76
event MarketLocked(address indexed market);                                                                                        // IShapes.sol:79
event Composed(uint256 indexed survivorId, uint256[] burnedIds, uint8 denomIndex, uint32 originCount);                             // IShapes.sol:83
event Decomposed(uint256 indexed survivorId, uint256[] restoredIds, uint8 survivorDenomIndex, uint32 survivorOriginCount);          // IShapes.sol:89-94
event Split(uint256 indexed tokenId, bytes32 indexed parentSeed, uint256[] newIds, uint8[] outDenoms, uint32[] originCounts);       // IShapes.sol:99-105
event BlackShapeCreated(uint256 indexed tokenId, uint256 burnedWei);                                                                // IShapes.sol:109
event InkGene(uint256 indexed tokenId, uint8 gene);                                                                                 // IShapes.sol:115
event ShapeAbsorbed(uint256 indexed survivorId, uint256 indexed burnedId);                                                          // IShapes.sol:119
event ShapeFragmentCreated(uint256 indexed parentId, uint256 indexed childId, bytes32 indexed parentSeed, uint256 childIndex);       // IShapes.sol:122-124
event ShapeRevived(uint256 indexed survivorId, uint256 indexed revivedId);                                                          // IShapes.sol:128
event ModulesSampled(uint256 indexed tokenId, bytes modules);                                                                       // IShapes.sol:134
event OwnerTokenMoved(uint256 indexed fromTokenId, uint256 indexed toTokenId);                                                      // IShapes.sol:140

// IAdminControl.sol
event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);      // IAdminControl.sol:12
event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient); // IAdminControl.sol:13
event MintFeeUpdated(uint256 previousFee, uint256 newFee);                            // IAdminControl.sol:15

// Standard ERC-721 (OZ): Transfer(address indexed from, address indexed to, uint256 indexed tokenId),
// Approval(address indexed owner, address indexed approved, uint256 indexed tokenId),
// ApprovalForAll(address indexed owner, address indexed operator, bool approved)
// Plus IERC4906: MetadataUpdate(uint256 tokenId), BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId)
```

Compose burns emit both the aggregate `Composed` and one `ShapeAbsorbed` per burned input
(`Shapes.sol:658`). Split emits `Split` plus one `ShapeFragmentCreated` per child (child-emission
call sites not individually line-cited; see `RecompositionOps.split`, `RecompositionOps.sol:280+`).
Decompose emits `Decomposed` plus one `ShapeRevived` per restored input. Re-minted/re-split
tokens do NOT emit `ShapeMinted` (only original mints do; `IShapes.sol:33-35`).

## 6. Custom errors (full list)

From `src/interfaces/IShapes.sol:142-210` and `src/interfaces/IAdminControl.sol:17-19`:

```solidity
error UnsupportedDenomination(uint256 amountWei);
error IncorrectPayment(uint256 expected, uint256 provided);
error ZeroQuantity();
error ArtistAlreadyAttested();
error InvalidArtistReleaseHash();
error InvalidArtistSignature();
error NotShapeOwner(uint256 tokenId, address caller);
error EthTransferFailed(address to, uint256 amountWei);
error InvalidRecipient(address recipient);
error NoFeesPending();
error MintFeeAboveCap(uint256 fee);
error DirectDepositRejected();
error MintNotOpen();
error SelfCustodyRejected(uint256 tokenId);
error PresentationIsLocked();
error UnsupportedRenderer(address renderer);
error UnsupportedCollection(address collection);
error TokenIsBlack(uint256 tokenId);
error NoComposeInputs();
error CannotComposeWithSelf(uint256 tokenId);
error SplitSumMismatch(uint256 inputBacking, uint256 outputSum);
error SplitTooFewOutputs();
error NoComposeRecord(uint256 survivorId);
error NotApexComplete(uint256 tokenId);
error DuplicateComposeInput(uint256 tokenId);
error CollectionNotSet();
error InvalidPointerTarget();
error PointerIsLocked();
error InvalidPointer();
error ComposeRecordOutOfRange(uint256 survivorId, uint256 depth, uint256 depthAvailable);
error NotASplitChild(uint256 tokenId);
error NoOwnerToken();

// IAdminControl.sol
error AdminUnauthorizedAccount(address account);
error AdminInvalidAdmin(address admin);
error AdminInvalidFeeRecipient(address recipient);

// Denominations.sol / Ladder.sol (library-local, can surface via delegatecall context)
error DenominationIndexOutOfRange(uint256 index); // src/lib/Denominations.sol:21, ladders/mainnet/Ladder.sol
```

## 7. Seeds, rendering, and onchain compose history (holder-relevant facts only)

- **Compose changes the survivor's geometry/gene, not its id or seed.** `seed` is immutable per
  token (`seedOf`, `Shapes.sol:856-859`); `Composed` doc: "The survivor keeps its id and seed and
  becomes the summed denomination" (`IShapes.sol:81-83`). Module geometry (`modulesOf`) and ink
  gene (`inkGeneOf`) DO change on compose — new geometry is sampled from the survivor + all
  burned donors via `ComposeCompute.composeSampleAndGene` (`src/lib/ComposeCompute.sol:19-38`),
  gene evolves per `InkGenes.geneAtCompose`. `ModulesSampled` and `InkGene` events fire on the
  survivor id each compose.
- **Token id persists through compose** (survivor keeps it) but NOT through split/decompose of
  a burned input's original id — decompose re-mints under the *original* id (so it does persist
  across a compose→decompose round trip), while split always burns the input id and mints fresh
  child ids (`IShapes.sol:420-424`).
- **Onchain compose history is fully readable**, function names:
  - `composeDepth(uint256 survivorId) external view returns (uint256)` — stack depth
    (`Shapes.sol:879`).
  - `composeRecordAt(uint256 survivorId, uint256 depth) external view returns
    (ComposeRecordView memory)` — full pre-compose survivor snapshot + every burned input's
    snapshot (id, seed, denomIndex, originCount, materialized module bytes, and
    `ownerTokenFrom`) at a given stack depth (`Shapes.sol:884-891`; struct at
    `src/ShapeTypes.sol:158`).
  - `splitOriginOf(uint256 childId) external view returns (...)` — the split that minted a
    child: parent id/seed/denomIndex/gene/modules, root split ancestor's denomination index, and
    the child's index among siblings (`Shapes.sol:893-919`; reverts `NotASplitChild` for
    non-split tokens).
  - `shapeState(uint256 tokenId) external view returns (ShapeState memory)` — single-call
    snapshot of every protocol fact about a live token (`Shapes.sol:921-925`; struct at
    `src/ShapeTypes.sol:115`).
  - `previewCompose`/`previewSplit` — pure simulators, write nothing, same checks/errors as the
    mutating calls, useful for a game/pool contract to validate a compose/split before submitting
    it (`Shapes.sol:934-964`).

## 8. Concurrency and callback hazards

- **Reentrancy guard (`nonReentrant`) is present on**: `mint`, `mintTo`, `mintBatch`,
  `mintBatchTo`, `withdrawFees`, `redeem`, `burn`, `redeemBatch`, `redeemTo`, `redeemBatchTo`,
  `compose`, `composeMany`, `split`, `splitTo`, `decompose`, `decomposeTo`, `decomposeMany`,
  `decomposeManyTo`, `burnBacking` (grep of `nonReentrant` across `Shapes.sol`, lines 361-794).
- **NOT guarded**: `admin()`-only setters, `attestArtist`, and the inherited ERC-721
  transfer/approval functions (`transferFrom`, `safeTransferFrom`, `approve`,
  `setApprovalForAll`) — explicitly called out in the contract header doc
  (`Shapes.sol:53-56`): "During a `safeTransferFrom` the receiver may redeem the Shape from
  inside its own `onERC721Received`. Accounting stays exact. An integrator must not assume the
  token still exists after that callback returns."
- **Callback surfaces (receiver hook required on the recipient if it's a contract)**:
  - `mint`/`mintTo`/`mintBatch`/`mintBatchTo` → `_safeMint` per token, called only **after** all
    storage effects for the whole batch are written (`Shapes.sol:462-465`, comment: "Minting
    happens after every storage write, behind the reentrancy guard... a supply read from inside
    `onERC721Received` sees the batch's end state").
  - `split`/`splitTo` → `_safeMint` per child, after all accounting (`Shapes.sol:702-708`,
    comment at 667-669: "All accounting precedes the `_safeMint` loop, so a receiver callback
    sees consistent state").
  - `decompose`/`decomposeTo`/`decomposeMany`/`decomposeManyTo` → `_safeMint` per restored input,
    after `RecompositionOps.decompose` effects; owner-token pointer move deferred until after the
    full mint loop (`Shapes.sol:764-792`, explicit ordering comment).
  - `compose`/`composeMany` do **not** mint — only burns (plain `_burn`, no receiver callback).
  - `redeem`/`burn`/`redeemBatch`/`redeemTo`/`redeemBatchTo` do not mint; they call
    `_sendEth` (low-level `.call{value:}`) to the recipient **after** all state is
    written/burned (checks-effects-interactions; `Shapes.sol:523-533,562-586,589-593`). **A
    game/pool contract that will call `redeem`/`burn` on Shapes it holds must accept plain ETH**
    (implement `receive()`/payable `fallback()`), or the call reverts `EthTransferFailed`.
  - `burnBacking` sends ETH to a fixed dead address (`UNSPENDABLE =
    0x000...dEaD`, `Shapes.sol:93-95`), not to the caller — no callback hazard for the caller.
- **Ordering pattern**: consistently checks → effects (storage) → interactions (external calls),
  per the contract header's explicit reserve invariant note (`Shapes.sol:57-58`):
  `address(this).balance >= redeemableBacking() + pendingFees()`.

## 9. Holder restrictions relevant to a game/pool contract

- **Self-custody block**: transferring (or minting) a Shape *to the Shapes contract's own
  address* reverts `SelfCustodyRejected` (`Shapes.sol:1198-1201`). Does not apply to any other
  contract address, including a game/pool contract — those can hold Shapes normally.
- **No blocklist, no pause, no upgrade path** found on the token contract:
  `Shapes` is not `Pausable`, not proxy/upgradeable (concrete, immutable bytecode; libraries are
  linked at deploy with no setter). Contract header explicitly states: "No pause, upgrade path,
  recovery function or admin path reaches the reserve" (`Shapes.sol` / `IShapes.sol:11-15`).
- **Admin powers that indirectly affect a holding game contract**: `setMintFee` (changes cost of
  future mints, capped at 0.01 ETH), `setFeeRecipient`, `setRenderer`/`setCollection` (changes
  `tokenURI`/`svg` output, can be locked permanently via `lockPresentation`), `setPointer`/
  `lockPointer` (discovery-only pointers to a positions/market contract, read by no token or
  reserve logic). None of these can move a held Shape, change its backing, or block
  redeem/compose/decompose/transfer.
- **Black Shapes**: a Shape whose backing was burned via `burnBacking` (owner-only, one-way,
  requires an apex 100 ETH "Complete" Shape) becomes non-redeemable and non-recomposable
  (`compose`/`decompose`/`redeem`/`burnBacking` again all revert `TokenIsBlack`), but **stays
  transferable** and can still be destroyed for zero via `burn` (ERC-8060 path). A game contract
  should check `isBlackShape(tokenId)` before assuming a held Shape is redeemable/composable.
- **Owner token semantics**: exactly one Shape (starting as #0) is the "owner token"
  (`ownerToken()`/`owner()`), conferring **no administrative or economic permission** — it is a
  provenance/attribution pointer only (`IShapes.sol:17-22,254-262`). A game contract does not
  need to special-case holding it, but should be aware `owner()` may resolve to the game
  contract's own address if it ends up holding that particular token id.

## 10. Tests/helpers reusable for an integrator

- **Mainnet-fork test fixture**: `lib/shapes/test/Fork.t.sol` (353 lines).
  `setUp()` at `test/Fork.t.sol:68` uses `vm.createSelectFork`/env RPC (forks mainnet — see
  `onlyFork` modifier gating `test_ForkIsMainnet`, `test_DeployScriptSucceedsOnFork`,
  `test_FullLifecycleUnderRealBlockEnv`, `test_WithdrawFeesToSplitsWallet`,
  `test_GasProfileUnderRealConditions` at lines 98,107,180,266,286). `test_FullLifecycleUnderRealBlockEnv`
  (`test/Fork.t.sol:180`) mints via `shapes.mintTo{value: amount + feeOf(amount)}(amount, alice)`
  (line 188) — a working, mainnet-fork-verified mint call pattern an integrator can copy for
  their own fork tests.
- **Deploy script**: `lib/shapes/script/Deploy.s.sol` (single script for
  every environment per this repo's stated one-deploy-path convention) — useful as a reference
  for constructor args and post-deploy invariant assertions (`_requireFreshCoreInvariants`,
  `script/Deploy.s.sol:176` on) but not something an external game repo would run.
- **Interface file to copy**: `src/interfaces/IShapes.sol` (+ `IERC721Value.sol`,
  `IAdminControl.sol`, `ShapeTypes.sol` for the struct return types). **Not published as an npm
  or soldeer package** — `package.json` (repo root) declares only a private `workspaces` monorepo
  (`web`, `preview`) with no publishable package; `remappings.txt` has only `@openzeppelin` and
  `forge-std` — no `soldeer.lock`/`dependencies.toml` found. An external repo must vendor/copy the
  interface files directly (or add this repo as a git submodule/forge dependency pointed at
  `src/interfaces/`).

## 11. Explicit gaps (not determined from the repo in this pass)

- **Current mainnet `admin()` and `feeRecipient()` addresses** are not recorded in
  `deployments/1.json` or any file found in this pass (set via `SHAPES_FEE_RECIPIENT` env var at
  deploy time, not persisted to the deployment record; admin defaults to `msg.sender` of the
  deploy transaction per `script/Deploy.s.sol`, but the actual deployer/admin address was not
  independently confirmed). Requires `cast call <shapes> admin()` / `feeRecipient()`.
- **Checksum-correctness of the mainnet address** was confirmed only as "same digits,
  case-insensitive" against the caller's supplied checksummed string — not re-derived via
  EIP-55 checksum computation or an on-chain call in this pass.
- **`royaltyInfo` (IERC2981) return values** (royalty bps / recipient) were not inspected beyond
  confirming the function exists at `Shapes.sol:1129` and is `external pure` (meaning its return
  is a compile-time constant, not read from storage) — the actual constant values were not
  extracted in this pass.
- **`RecompositionOps.split`'s exact `SplitSumMismatch`/child-id-assignment code** was located
  (`RecompositionOps.sol:280` onward) but not line-by-line traced in this pass; the described
  behavior (sum must equal input backing, children filled to capacity in listed order, first
  child inherits owner-token status if the input was the owner token) is drawn from
  `IShapes.sol:420-424` doc comments and `Shapes.sol:686-712`, not independently re-derived from
  `RecompositionOps.sol`'s internals line-by-line.
- **Whether the deployed bytecode at commit `1b84c102a6603ca9751d863ff259b08870d22a6b` matches
  current HEAD** (`53969b6894c64c8daa1ef5a55cee208c63eda938`) was not diffed in this pass — recent
  commits after the recorded deploy commit could include changes not reflected on the deployed
  contract (this is expected and normal — deployment record commit is necessarily older than
  HEAD — but exact diff was not produced).
- **No `cast`/RPC calls were made** in this investigation (read-only repo inspection only per
  task scope); every fact above is a static read of the source tree, not a live on-chain read.
