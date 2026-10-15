# Draw Shapes v1 specification

Date: 2026-10-13. Status: owner decisions are in `docs/V1_PROMISES.md` (1 to 9). This document is the build input. It
states what the contracts do and what must stay true.

## 1. Purpose

Depositors fund a pool with ETH. The pool mints Shapes and Draw Packs and lists them on one FWA V2 custom pool. Players
pay FWA's ticket; FWA selects and delivers one listing per acquisition. The pool replaces each captured listing with a
row sampled from the mix (section 9). Each settled ticket pays depositors a premium, funds upkeep, and feeds the GRAIL
fund (section 11). Depositors exit at NAV in ETH.

## 2. Actors

| Actor | Can |
| --- | --- |
| Depositor | `deposit`, `withdraw`, read position. |
| Player | `acquire`, `acquireBatch`, `pullWithShapes`, `redeemAndDeposit`, claim FWA refunds at the FWA pool. |
| Anyone | `settle`, `rotate`, `payClaims`, `exportStep`, `migrateHolder` on a successor. |
| Admin | One address, transferable. `createFwaPool`, pause flags, parameter setters, `adminCall`, `startExit`, `transferGrailEstate`, `sweep`, `registerForeign`. |

Shares are nontransferable. There is one admin role.

## 3. Contracts and dependencies

| Contract | Role |
| --- | --- |
| `Pool.sol` | Shares, buckets, board, acquisitions, GRAIL fund, upkeep, rotation, claim payment. Immutable. Owns the FWA pool. Its `fallback` delegates `listBatch`, `openBoard`, `queueMissing`, `grailStep`, `grailReprice`, `grailReady`, `setGrail`, `setGrailStep`, `setGrailTarget`, `grail`, `grailItems`, `boardItems`, `chooseRow` and the read-only getters of parameters, rows, queues, held Shapes and migration state to `listingModule` and every other selector to `adminModule`. |
| `PoolAdmin.sol` | Admin and exit surface: `createFwaPool`, setters, `sweep`, `adminCall`, `startExit`, `exportStep`, `transferGrailEstate`, successor import (including `importGrail`) and `canImport`. Runs by delegatecall from `Pool` on the `PoolStorage` layout. A direct call reverts `NotDelegated`. |
| `PoolListing.sol` | Listing engine and GRAIL engine: fills queued replacements and held items (mint, held Shape, `createPack`) and lists them with `listNFTs`; mints GRAIL pieces, merges, forms the opening five, decays prices (section 11). Entrypoints `listBatch(max)`, `openBoard()`, `grailStep()` and `grailReprice()`, the foreign listing functions `registerForeign`, `repriceForeign` and `withdrawForeign` (section 11), the view `grailReady()`, the setters `setGrail`, `setGrailStep` and `setGrailTarget`, and the views `grail()`, `grailItems()`, `foreignListings()`, `boardItems()`, `chooseRow`, `rowCount`, `mixLength`, `listedRowCount`, `mixRow`, `heldCount`, `heldShapes`, `claimQueue`, `replacementQueue`, `oldestQueuedAt`, the parameter getters (`batchMin`, `batchMaxAge`, `surpriseBps`, `restoreK`, `bandBps`, `reserveBps`, `listWhilePaused`, `openingDeadline`, `openingDeadlineAt`, `maxBatch`, `concurrency`, `grailProbCapBps`), `lastRefundAt`, `maintenanceReceivable`, `margin`, `mintLineOwed` and the export and import records (`exportedShares`, `exportedNav`, `importedShares`, `importedFromShares`, `migrated`, `registered`). Runs by delegatecall from `Pool`. A direct call reverts `NotDelegated`. A call to `Pool` from any sender but `Pool` itself reverts `NotSelf`. |
| `PoolBooks.sol`, `PoolStorage.sol` | Shared bases: settlement, harvest, margin split, row choice; storage layout, item registry, parameter validation. `interfaces/IPool.sol` holds the combined ABI, types, errors and events. |
| `Lens.sol` | Read-only views and quotes. Replaceable by deploying a new one. |
| Draw Packs | Fork of `shape-packs` with `MIN_PACK_VALUE = 2 * unit()`, deployed as its own collection. Used through `IShapePacks`. |
| Shapes | Mainnet `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`. `mintBatchTo`, `redeem`, `mintFee`. |
| FWA V2 clone | Created by the pool through the factory. `listNFT`, `listNFTs`, `updatePrice`, `withdrawListingTo`, `processAcquisitions`, `withdrawOwnerProceeds`, `acquire`, `acquireBatch`, `setPurchaseOperator`, `retirePool`. |

`Pool`, `PoolAdmin` and `PoolListing` compile with via_ir and share one storage layout. The two modules are the only
delegatecall targets. `open`, `settle` and `rotate` reach `PoolListing` by calling `Pool` itself, inside their
`nonReentrant` frame, so the module entrypoints carry no guard. Pure math is in internal libraries (`PricingLib`).
Runtime sizes: `Pool` 23,484 B, `PoolAdmin` 22,960 B, `PoolListing` 23,861 B, `Lens` 17,537 B (limit 24,576 B).

## 4. Buckets and invariants

Every wei the pool holds is in exactly one bucket.

| Bucket | Holds |
| --- | --- |
| `cash` | Spendable ordinary ETH. |
| `backing` | Sum of backing of ordinary Shapes and Draw Packs held or listed. |
| `receivable` | FWA `ownerProceeds` booked and awaiting harvest. |
| `maintenanceReceivable`, `grail.receivable` | Booked shares of `ownerProceeds`. Harvest credits them to `maintenance` and `grail.fund`. |
| `foreignReceivable` | Booked proceeds of captured foreign listings. Harvest pays them to the controllers (section 11). |
| `claims` | Unpaid withdrawal claims, FIFO. |
| `maintenance` | Upkeep refunds. |
| `grail.fund` | ETH for GRAIL piece mints. The GRAIL items (`grailItems`) hold the backing. |

Ordinary NAV = `cash + backing + receivable - claims`, or zero when `claims` exceed the assets. The GRAIL fund and the
GRAIL items are outside ordinary NAV. A replacement mint fee leaves NAV at the replacement mint.

Invariants, enforced by the invariant suite:

- I1 `address(this).balance >= cash + maintenance + grail.fund`. A queued claim is the part cash did not cover.
- I2 `backing` equals the sum of `valueOf` or denomination over every ordinary token the pool owns or has listed. Held
  Shapes are indexed once under the ladder index of their value.
- I3 Shares redeem at ordinary NAV per share; a withdrawal never pays more than that at request time.
- I4 Claims are paid in request order.
- I5 The GRAIL fund pays only for piece mints and their mint fees.
- I6 `maintenance` pays only `settle` and `rotate` refunds and is never negative.
- I7 `maintenance` is credited from netted positive margin (section 9). `grail.fund` is credited from netted
  positive margin, the entry contribution, `fundGrail`, GRAIL capture proceeds and `importGrail`. Ordinary NAV changes at a settled capture by `proceeds - value` less the replacement mint fee.

## 5. Parameters

Constructor: Shapes, Draw Packs, FWA factory, admin, `oldPool` (zero unless the pool succeeds another), mix table, fee
split, GRAIL parameters (`targetWei`, `listBps`, `decayWeiPerPull`, `pieceFloorWei`, `floorWei`, `stepUpSeconds`, `stepDownSeconds`), `navCapFloor`, `turnoverBps`, entry fee, `founderWindowSeconds`, `rotateInterval`, `openingDeadline` (seconds, started by
`createFwaPool`), `minItems`, `grailProbCapBps`, `batchMin`, `batchMaxAge`, `surpriseBps`, `restoreK`, `bandBps`,
`reserveBps`, `tipWei` and the `PoolAdmin` and `PoolListing` addresses.

Setters (admin, immediate effect, each emits `ParamSet(selector)`):

| Setter | Bound |
| --- | --- |
| `setFeeSplit(premiumBps, maintenanceBps, feedBps)` | Sum at most 1,000. |
| `setEntryFee(floorBps, capBps, paybackDays)` | `floorBps` at most `capBps`. `capBps` at most 10,000. `paybackDays` at least 1. |
| `setNavCapFloor(wei)`, `setPaused(pulls, deposits)`, `setMinItems(n)` | Any wei amount. Flags. Any. |
| `setTurnover(bps)` | 1 to 10,000. |
| `setFounderWindow(seconds)` | Any. Applies to the next `open()` only. |
| `setMix(rows)` | Each row: array of rungs, weight share. Rows of two or more rungs are packs. A row that holds items keeps its rungs. The table may grow. A row with items or queued replacements cannot be dropped (`RowInUse`). |
| `setGrail(decayWeiPerPull, pieceFloorWei, floorWei, listBps)` | `listBps` 1 to 10,000. `pieceFloorWei` above zero and at most one piece (1 ETH). `floorWei` above zero and at most `5 ETH * listBps / 10_000`. Amounts in ETH follow the mainnet ladder; a testnet ladder scales them with its unit. |
| `setGrailTarget(wei)` | One of 5, 10, 25, 50, 100 ETH. Writes `nextTargetWei`. |
| `setGrailStep(up, down)` | `up` below `down`. A completed cycle steps `nextTargetWei` one rung up when it took less than `up` seconds and one rung down when it took more than `down` seconds. |
| `setGrailProbCap(bps)`, `setReserve(bps)`, `setListWhilePaused(on)` | 1 to 10,000. At most 10,000. Flag. |
| `setBatch(batchMin, batchMaxAge)`, `setReplacement(surpriseBps, restoreK, bandBps)` | Both above zero. At most 10,000, 100 and 100,000. |
| `setTip(tipWei)` | At most 0.01 ether. |
| `setMaxBatch(n)`, `setConcurrency(n)`, `setRotateInterval(seconds)`, `setAdmin(address)` | At most FWA's live values (`n` above zero for `setMaxBatch`). At least FWA's `inventoryChangeCooldown`. Nonzero. |

Launch values: premium 200, maintenance 100, feed 400; entry fee floor 1,000,
cap 2,500, payback 20 days; `turnoverBps` 1,250; `navCapFloor` 69 ETH; `founderWindowSeconds` 2,592,000 (30 days);
opening deadline 24 h. The owner set these:
- `minItems` 100: the board stays above FWA's 10 outstanding requests. `navCapFloor` 69 ETH: bounds the opening and
  every day until booked volume lifts `navCap()` above it.
- Mix 0.01 Shape 38 percent, 0.02 pack 28, 0.03 pack 19, 0.05 Shape 10, 0.1 Shape 4, 0.5 Shape 1: the 0.1 and 0.5
  rows restore the large pieces of the launch profile at a small share.
- `rotateInterval` 900 s, `batchMin` 20, `batchMaxAge` 3,600 s, `reserveBps` 1,000 (10 percent of NAV stays in `cash`,
the rest is listed on the board).
- `tipWei` 0.0002 ether: the fixed part of every `settle` and `rotate` refund.
- `surpriseBps` 200, `restoreK` 8, `bandBps` 3,000: a captured 0.1 row returns within about eight captures.

`grailProbCapBps` and the GRAIL parameters are set in `script/env/<env>.env`: target 25 ETH, `listBps` 7,500,
`decayWeiPerPull` 0.001 ETH, `pieceFloorWei` 1 ETH, `floorWei` 1 ETH, `stepUpSeconds` 14 days (1,209,600),
`stepDownSeconds` 60 days (5,184,000).

## 6. Lifecycle

`Opening -> Live -> (Paused) -> Exiting -> Exported`.

- Opening: deposits open from deployment at NAV, which is pure cash, so every opening depositor receives shares 1:1.
  Pulls closed. Admin calls `createFwaPool(expectedFee)`, which starts the opening deadline. After the deadline anyone
  calls `open()`, which enables FWA acquisitions and lists at most 20 items per call. The first call after which at
  least `minItems` are listed, or which lists fewer than 20, sets Live. Once Live, the `Deep` settle trigger (section 9)
  lists the rest of the board up to `boardItems()`.
- Live: all paths open subject to pause flags and reopen guards.
- Paused: admin flags. Settlement of issued pulls, deposits, `settle` and `rotate` continue unless a flag closes them.
- Exiting: `startExit(dest)` by admin. It disables FWA acquisitions and closes pulls, deposits, rotation and GRAIL
  growth. `exportStep()` by anyone until done.
- Exported: snapshot recorded. Holders `withdraw` against cash when `dest` is the pool itself; otherwise the successor
  mints their shares.

## 7. Depositor paths

Share pricing follows the books. `deposit`, `withdraw` and `redeemAndDeposit` first sync: process and book
up to 20 FWA acquisitions, require the booking walk to reach FWA's processing queue (`BooksBehind` otherwise), then
harvest. FWA processes acquisitions permissionlessly, and their outcomes are public before they are booked.

`deposit()` payable. Reverts when deposits are paused, when the pool is Live before `depositsOpenAt`
(`DepositsClosed`), when ordinary NAV is at or above `navCap()` (`NavCapReached`), when the pool is Exiting, when NAV is
zero while shares exist (`NavZero`), and on a successor while its import is open. Three rules decide admission and
price, and all three read one volume measure.

- Volume. Every acquisition that `_walk` books as a capture adds its FWA `paid` value to the fee total of the current
  UTC day, in one of eight day slots (`day % 8`). Refunded, expired, written-off and unbooked requests add nothing.
  `dailyVolume()` is the mean of those totals over the complete days after the Live day and before today, at most
  seven. The Live day and today are partial days, and zero complete days give zero.
- Cap. `navCap() = max(navCapFloor, dailyVolume() * 10_000 / turnoverBps)`. Deposits are admitted while `nav() <
  navCap()`. `turnoverBps` is the target daily volume over NAV. Design and sizing: `docs/VOLUME_CAP.md`.
- Entry fee. The contribution is `msg.value * contributionBps / 10_000`, where `contributionBps = clamp(paybackDays *
  dailyYieldBps, floorBps, capBps)` and `dailyYieldBps = premiumBps * dailyVolume() / nav()`, zero when NAV is zero.
  The product `paybackDays * premiumBps * dailyVolume()` is divided by `nav()` once. The contribution goes to
  `grail.fund` in full. Shares minted = `(msg.value - contribution) * totalShares / nav`, or 1:1 when
  `totalShares == 0`, whatever NAV is: residual NAV while the share supply is zero goes to the next depositor.
- Founder window. `open()` sets `depositsOpenAt = block.timestamp + founderWindowSeconds` at the transition to Live.
  Deposits made while Opening are admitted at once. Successor import is outside the cap and the window.

`Lens.admission()` returns `navCap`, `navCapFloor`, `dailyVolume`, `headroom`, `depositsOpenAt`, `contributionBps` and
whether a deposit would be admitted now.

`withdraw(shares)`. Burns shares. Claim = `shares * nav / totalShares`. Pays `min(claim, cash)` now and enqueues the
remainder. It reverts once an exit to a successor has started (holders use `migrateHolder`) and on a successor while its
import is open (`ImportInProgress`).

Claim payment. `payClaims()` (anyone, any lifecycle state) pays queued claims from `cash` in FIFO order, at most 20
entries per call. In `rotate()` (reason Claim) the claims step pays from `cash`, then, once the head claim is at least
`rotateInterval` old, redeems up to 25 items: held items first, then listed items of the row most over its share, while
FWA's `unsettledAcquisitionCount` is zero. The re-mint cost of each redeemed row, one mint fee per rung, is deducted from
the claim and stays in `cash`. A claim remainder at or below that cost leaves listings alone.

`redeemAndDeposit(tokenId)`. A Shape whose backing equals a single rung mix row stays in the pool as a held item at its
`backingOf` while spendable cash (section 9) covers its value. The entry contribution then comes from `cash`, and shares
are priced on NAV before the Shape arrives. Any other Shape is redeemed at Shapes and its proceeds are deposited.

## 8. Player paths

`acquire(purchaser, maxAcquisitionFee, minWeightedValue, maxNegativeSlippageBps, expectedInventoryVersion, deadline)`
payable returns one request id. `acquireBatch(purchaser, count, maxAcquisitionFee, minWeightedValue,
maxNegativeSlippageBps, expectedInventoryVersion, deadline)` payable returns the request ids. `purchaser` must equal the
caller (`PurchaserMismatch`). `count` is at most `maxBatch` and FWA's live limit. The reopen guards require FWA's
`purchasesResumeAt` passed, I1 holding with the incoming value, and listed ordinary items at least `concurrency` above
the unsettled acquisitions. The pool forwards the caller's slippage, minimum weighted value, inventory version and
deadline to FWA `acquireBatch`, refunds overpayment to the caller, records each request's base price (section 9) and
runs the upkeep slice (section 10). `quoteAcquisitionPrice(count)` returns FWA's fee, VRF fee and total.

`pullWithShapes(tokenIds, count, maxFee, deadline)` payable. Calls the batch path with the pool defaults: minimum
weighted value 0 and FWA's `selectionSlippageBps` and `inventoryVersion`. A Shape whose backing equals a single rung mix
row stays in the pool as a held item at its `backingOf` while the running total of kept value fits the spendable cash
(section 9). `cash` pays FWA for the value those Shapes cover, `msg.value` pays the rest, and NAV is unchanged. Any
other Shape is redeemed at Shapes and its proceeds join `msg.value`. Excess returns to the caller.

Purchase operator. `createFwaPool` sets the pool as the FWA `purchaseOperator`, so FWA accepts a purchase while the pool's
`canPurchase(wallet)` is true, which holds inside the pool's forwarding call for that purchaser. Every purchase passes
the reopen guards and the upkeep slice. The operator is fixed from creation.

Refunds for slippage, timeout and failed delivery are FWA credits that the purchaser claims at the FWA pool. Listing
price for an ordinary token = `backing * (10_000 + premiumBps + maintenanceBps + feedBps + mintLineBps) / 10_000`, where
`mintLineBps` is the replacement mint fee for that row expressed in bps of its backing. FWA adds its own edge on top.

## 9. Board, replacement, rotation

The mix table is an array of rows: rungs (one for a Shape, two or more for a Draw Pack) and a weight share. The board
depth is `boardItems() = max(minItems, (nav - nav * reserveBps / 10_000) / meanRowCost)`, where `meanRowCost` is the
share-weighted backing plus replacement mint fee of the mix rows. Capital above the reserve goes on the board. The target
depth of a row is `ceil(boardItems() * shareBps / 10_000)`. A row's count is its listed, held and queued items. A row
above its target is not replaced after a capture until it is below it again; nothing is delisted when NAV falls.

Settlement. FWA pays the pool owner per acquisition `paid - (paid - base) / 2`, where `paid` is the escrowed fee and
`base = min(fee, weightedBackingTotal / totalWeight)` at request time (the harmonic mean of list prices). Proceeds are
the same for every capture in a batch.

1. `acquire` and `acquireBatch` record `base` per request id. A purchase the pool did not record (the operator cleared through `adminCall`) books zero proceeds at capture.
2. `settle(maxCount)` (at most 20 per call) calls `processAcquisitions(maxCount)`, then walks FWA's sequence numbers
   from `nextSequenceToBook` to FWA's processing queue. Each sequence adds one to `grail.pulls`, the pull counter the GRAIL
   decay reads. Per status:
   - Fulfilled ordinary item: `backing -= value`, `receivable += proceeds`, `margin += proceeds - value`, `mintLineOwed
     += mintFee * rungs`, the replacement row (below) is queued, margin split.
   - Fulfilled GRAIL item (any entry of `grailItems`, a Shape or a Draw Pack): `grail.receivable += proceeds` and the
     item leaves `grailItems`. DeliveryRefunded: an ordinary token returns to held items and a GRAIL item stays in
     `grailItems` unlisted until the GrailStep lists it again. Any other status books nothing, and the walk advances past it.
   - Fulfilled foreign listing: the entry leaves `foreignListings` and `foreignReceivable += proceeds` (section 11).
   - DeliveryPending: written off at once. The item leaves `backing`, its value is charged to `margin`, and no proceeds
     or replacement are booked. Owner proceeds of a delivery that completes later arrive as surplus (step 4). After a
     purchaser refund the admin recovers the token with `adminCall(recoverRefundedNFT)` and `sweep`.
3. Margin split. Positive `margin` first repays `mintLineOwed`. The rest divides pro rata by `premiumBps :
   maintenanceBps : feedBps`. The premium share stays in ordinary NAV. The maintenance and feed shares leave it as receivables of
   `maintenance` and `grail.fund`. Negative `margin` carries forward until later captures
   repay it. After Exported the split is skipped, so later proceeds stay in ordinary NAV.
4. Surplus. When a settle reaches FWA's processing queue, `ownerProceeds()` above the booked receivables (the proceeds
   of purchases the pool did not record, which the operator cleared through `adminCall`) is booked as `receivable` and `margin` and split.
5. Harvest (`withdrawOwnerProceeds`) runs when the walk is level with FWA's queue. An amount received below the booked
   receivables emits `HarvestShortfall(received, expected)` and writes `receivable` down by the gap.

Replacement row, chosen when a captured ordinary item is booked and appended to the replacement queue with
`ReplacementChosen(requestId, capturedRow, chosenRow, surprise)`. `oldestQueuedAt` is set when the queue becomes
nonempty and cleared when it empties. `randomWord` is FWA's word for the request, public once FWA fulfils it.
1. `h = keccak256(abi.encode(randomWord, requestId))`.
2. Deficit draw: row weight `shareBps * (10_000 + restoreK * deficit * 10_000 / target) / 10_000`, `deficit =
   max(target - count, 0)`. The row is `uint256(h) % sum(weights)`, counted through the weights in row order.
3. Surprise: when `(uint256(h) >> 64) % 10_000 < surpriseBps`, the draw moves to a single rung row of at least five
   times the drawn row's backing that is below its target depth. The three of lowest backing take the weights 60, 30 and 10, cut to the candidate
   count, and `(uint256(h) >> 128) % 100` scaled to the weight sum picks one. Without a candidate the draw stands.
4. Band: a chosen row with `count >= max(target + 1, ceil(target * (10_000 + bandBps) / 10_000))` becomes the row of
   largest deficit (lowest index on a tie). When no row is below target the step 2 row stands.

Filling. `settle`, `rotate` and `open` fill queue entries in order and list them with `listNFTs` (`PoolListing`). A Shape row takes a
held Shape of its rung, else mints one. A pack row lists a held pack of equal backing, else calls `createPack(shapeIds,
mintCounts)` with one held Shape per rung that has one and a mint count for the others. A mint needs spendable cash,
`cash - claims - nav * reserveBps / 10_000`, of at least its cost. An entry that cash cannot fund stays queued.

`settle(maxCount)` (anyone) books, harvests and calls `activateListings` when FWA holds no unsettled acquisition. When
`settleDue()` is nonzero and the factory's `inventoryChangeCooldown` is 0 or `listWhilePaused` is on, it lists at most
`MAX_LIST_PER_SETTLE` (25) items, then applies the GRAIL decay (section 11) while FWA holds no unsettled acquisition
and the walk is level. `settleDue()` returns the first of these, and `None` outside Live or when no
held item exists and cash cannot fund the queue head: Batch, `batchMin` replacements queued; Age, the oldest queued
replacement is `batchMaxAge` old; Thin, listed items minus unsettled acquisitions are fewer than `concurrency + 5`; Deep,
the board count (listed, held and queued ordinary items) is below `boardItems()` by at least `batchMin`. On Deep, `settle` queues each row's missing items against
its target depth before listing, up to 25 entries in total per call, existing queue entries included. A reprice rides on a due settle and never makes one due.

`rotate()`. Anyone. Reverts `RotateTooSoon` until `rotateInterval` has passed since `lastRotateAt`, and `RotateNotDue`
unless a reason holds. `lastRotateAt` moves when the call changed inventory. Reasons, in evaluation order:
1. Claim: the head queued claim is at least `rotateInterval` old.
2. GrailStep: FWA holds no unsettled acquisition, and the fund covers a piece and its mint fee with the caps allowing it, or a merge recipe's inputs are listed, or a GRAIL item is unlisted (section 11).
3. Held: `settle` may not list (cooldown above zero and `listWhilePaused` off), and a held item exists or spendable cash
   covers the queue head.

`rotateDue()` returns the first reason that holds, and `None` before the spacing ends, outside Live and when no reason
holds. A reason can hold while its work is blocked, such as Claim while FWA holds unsettled acquisitions; that call
leaves `lastRotateAt`, the FWA pause and `maintenance` as they were. Steps, each bounded: (1) settle and harvest; (2) pay
claims, then liquidate for the head claim when due; (3) when `settle` may not list, list up to 20 queued replacements
and held items; (4) `activateListings` when FWA holds no unsettled acquisition and the walk is level; (5) GRAIL step: mint and merge
(section 11); (6) refund the caller. `open()` queues each row's
missing items against its target depth and runs step 3.

## 10. Upkeep and refund

Per-pull slice, inside `acquire` and `acquireBatch`: process and settle up to 3 acquisitions, harvest, pay queued claims
from `cash`. Listing runs in `settle` and `rotate`, because every FWA listing restarts the purchase pause of the
factory's `inventoryChangeCooldown`. FWA rejects `withdrawListing` and `updatePrice` while any acquisition is
unsettled, so under continuous pull flow liquidation, GRAIL mints, merges and repricing wait for a gap that a pause opens.

Refunds come from `maintenance`: `refund = min(maintenance, (gasUsed + 30,000) * block.basefee + tipWei)`, with `tipWei`
a parameter (section 5, `setTip`). `settle` pays when `settleDue()` was nonzero and the call listed an item or repriced a
GRAIL item, and emits `Settled(reason, listed, refund)`. `rotate` pays when the call changed inventory (listed, withdrew, minted or merged a
GRAIL item) and `rotateInterval` has passed since `lastRefundAt`: one refund per interval.

`fundMaintenance()` payable adds the sent ETH to `maintenance`. Anyone may call it. The launch plan is `maintenanceBps`
100 plus operator top-ups from Shapes mint fee revenue: at 1 gwei the mint fee per Shape is about six times the mint
and list gas per item, at 6 gwei about equal, so the bucket is refilled from that revenue when the basefee is high.
`fundGrail()` payable adds the sent ETH to `grail.fund`. Anyone may call it.

## 11. GRAIL

One fund, one ladder, many listed pieces. The GRAIL is built on the board from 1 ETH Shapes that players
can draw while it forms.

Storage. `grail`: `fund` (ETH), `receivable`, `targetWei`, `nextTargetWei`, `cycleId`, `listBps`,
`decayWeiPerPull`, `pieceFloorWei`, `floorWei`, `pulls`, `cycleStartedAt`, `stepUpSeconds`, `stepDownSeconds`. `grailItems`: entries of `collection` (Shapes or Draw Packs),
`tokenId`, `backing`, `notional`, `listingId`, `listedAtPull`, `done` (true for a completed GRAIL; a done item is
never a recipe input). At most `MAX_BUILDING_ITEMS` (16) items that are not done and at most `MAX_DONE_ITEMS` (32)
done items exist at once. A piece is an item with backing of 1 ETH. At most `MAX_PIECES` (6) pieces exist at once.
`grail.pulls` counts booked sequences; an item's pulls since listing are `grail.pulls - listedAtPull`.

Ladder. `targetWei` is one of 5, 10, 25, 50, 100 ETH. `setGrailTarget(wei)` writes `nextTargetWei`;
a cycle reads it at start. Launch target 25 ETH. Step rule: when a cycle completes, `elapsed` is the time since
that cycle started. `elapsed < stepUpSeconds` sets `nextTargetWei` one rung up (at most 100 ETH);
`elapsed > stepDownSeconds` sets it one rung down (at least 5 ETH); otherwise it is unchanged. A later
`setGrailTarget` overrides it. `setGrailStep(stepUpSeconds, stepDownSeconds)` with `stepUpSeconds <
stepDownSeconds`; launch 14 days and 60 days. `grail.cycleStartedAt` records the cycle start.

Funding. The whole entry contribution (section 7), the feed share of every settled ticket (section 9),
`fundGrail()` from any sender, and the proceeds of a captured GRAIL item (through `receivable`). The fund
is outside ordinary NAV (section 4).

A GRAIL step that reverts is skipped by `rotate` (`GrailStepSkipped`) and the rest of `rotate` runs.

Mint (trigger GrailStep, inside `rotate`). While `fund >= 1 ETH + mintFee`, pieces < 6, building items < 16, FWA
holds no unsettled acquisition, and at most `MAX_GRAIL_MINTS_PER_ROTATE` (3) per call: mint one 1 ETH
Shape, list it at `notional = backing`, `fund -= 1 ETH + mintFee`.

Merge (same trigger, after mint). Recipes by target, inputs taken from `grailItems`:
- 5 ETH from five pieces.
- 10 ETH from two 5 ETH items.
- 25 ETH from two 10 ETH items and one 5 ETH item.
- 50 ETH from two 25 ETH items.
- 100 ETH from two 50 ETH items.
A recipe runs when its inputs are listed and FWA holds no unsettled acquisition, at most
`MAX_GRAIL_MERGES_PER_ROTATE` (2) per call, largest recipe first. It withdraws the inputs'
listings, composes at Shapes when the output backing is a native rung (5, 10, 50, 100), else creates a
Draw Pack of the inputs (25), and lists the output at `backing * listBps / 10_000`. The output joins
`grailItems`. When the output backing equals `targetWei` the cycle is complete:
`cycleId += 1`, the step rule runs, `targetWei = nextTargetWei`, `cycleStartedAt = block.timestamp`, and minting
continues from the fund. The completed GRAIL stays
listed until captured.

Opening. Inside `open()` before the board lists: if `fund >= 5 * (1 ETH + mintFee)`, mint five pieces,
compose one 5 ETH Shape, list it at `notional = backing`. It is the first item of cycle 1.

Decay, inside `settle` after the listing step and under the same listing condition, per listed item:
`next = max(floor, notional - decayWeiPerPull * (grail.pulls - listedAtPull))`, with `floor = pieceFloorWei` for a piece
and `floorWei` otherwise. The reprice runs when the listing is Active and `next` is at least 1 percent
below `notional`, and the listed GRAIL and foreign weight at `next` stays within `grailProbCapBps`. It calls
`updatePrice` and sets `listedAtPull = grail.pulls`. There is no lift: when the cap binds, the item keeps its price.

Capture. A fulfilled GRAIL item leaves `grailItems`; `receivable += proceeds`; harvest credits the fund.
A captured intermediate does not stop the cycle; the recipe waits for new inputs.

Foreign listings. A prize the pool did not mint, owned by a controller contract that holds every rule about it.
Storage `foreignListings`: at most `MAX_FOREIGN` (8) entries of `collection`, `tokenId`, `controller`, `listingId`,
`notional`, `lastRepriceAt`, keyed by the FWA `listingId`. A foreign item is outside `backing`, ordinary NAV and the GRAIL fund.
- `registerForeign(collection, tokenId, controller, priceWei)`: admin, Live only. Transfers the ERC-721 from the
  admin to the pool (the admin approves the pool first), approves and lists it on the FWA pool at `priceWei`, records
  the entry and marks the token registered, so `sweep` and `importItem` refuse it. Reverts `NotLive`, `ForeignFull`,
  `AlreadyRegistered`, `ZeroAddress` for a zero `collection` or `controller`, `PriceOutOfRange` and
  `ProbCapExceeded`. The price needs a selection weight: `priceWei` is nonzero and at most `1e36`, so `PricingLib.weightOf`
  is defined for it. The Active GRAIL and foreign weight plus the weight of the new listing at `priceWei` stays within
  `grailProbCapBps` of the FWA selection weight including that listing.
- `repriceForeign(listingId, priceWei)`: the entry's controller only (`NotController`), while the listing is Active
  (`ListingNotActive`) and FWA holds no unsettled acquisition and the booking walk is level (`FwaBusy`). Calls
  `updatePrice` and stores `notional` and `lastRepriceAt`. `priceWei` has a selection weight (`PriceOutOfRange`, as in
  `registerForeign`) and differs from `notional` by at least 1 percent of `notional` (`RepriceTooSmall`). The entry
  takes one reprice per `rotateInterval` (`RepriceTooSoon`); the first reprice of an entry is accepted at once, and a
  withdrawal removes the entry with its `lastRepriceAt`. A price that raises the entry's selection weight is refused
  (`ProbCapExceeded`) when the Active GRAIL and foreign weight at `priceWei` would pass `grailProbCapBps` of the FWA
  selection weight. The GRAIL decay in `grailReprice` counts the Active foreign weight under the same cap. Every
  stored foreign `notional` has a selection weight, so `grailReprice` and `settle` compute the weight of every foreign entry.
- `withdrawForeign(listingId, to)`: the entry's controller only. Withdraws the listing, transfers the token to `to`,
  removes the entry. A listed entry needs FWA to hold no unsettled acquisition and the walk to be level (`FwaBusy`).
- Capture: in the booking walk a Fulfilled foreign listing removes the entry and books `proceeds` as a foreign
  receivable, which is part of the booked receivables and stays at FWA as owner proceeds. The next harvest withdraws the
  proceeds from FWA and sends them to `controller.onForeignCapture(listingId, tokenId, proceeds)` by a plain call with
  the ETH value, forwarding at most `FOREIGN_CALL_GAS` (200,000). The harvest is the only place the pool calls a
  controller. A capture with zero proceeds queues a due of zero value, which the harvest reports like any other due,
  and a harvest runs while a due waits even when FWA holds no owner proceeds. A harvest that finds FWA holding less than
  the booked receivables writes the gap down in the order `receivable`, `maintenanceReceivable`, GRAIL receivable,
  foreign receivable, and pays each due in queue order from the withdrawn proceeds, up to the foreign receivable that
  remains. The call needs `gasleft() >= FOREIGN_CALL_GAS * 64 / 63 + 20,000`, and the pool reverts `InsufficientGas`
  (`settle`, `deposit`, `withdraw`, `acquire`, `exportStep`) otherwise. When the call fails the proceeds are booked as
  `receivable` and `margin`, and the margin of all failed dues of one harvest is split once after the last due.
  `ForeignCaptured(listingId, tokenId, proceeds, delivered)` reports the result. A request opened directly at the FWA
  pool books zero proceeds (section 9, step 1), so its owner proceeds arrive as surplus.
- Refunded delivery: the token returns to the pool unlisted and the entry stays under its `listingId` with `notional`
  zero. The controller may `withdrawForeign` it, and the admin may then `registerForeign` it again. A DeliveryPending
  listing removes the entry and reports `ForeignCaptured` with zero proceeds.
- Exit: `exportStep` releases every foreign listing to its controller before the GRAIL estate moves: it withdraws the
  FWA listing when the entry is listed and transfers the token, forwarding at most `FOREIGN_CALL_GAS` to the
  collection. A step that fails removes the entry, clears the token's registration so `sweep` can send it once the pool
  holds it, emits `ForeignReleaseFailed(listingId, tokenId)` and the export continues. `withdrawForeign` reverts on a
  failed withdrawal or transfer.
- Lens: `foreign()` returns every entry with its selection weight in bps, which is zero unless the FWA listing is
  Active.
The pool holds no term of any deal. A controller decides prices, phases, reclaim rights and where capture proceeds go.

Launch values: target 25 ETH, `listBps` 7,500, decay 0.001 ETH per pull, piece floor 1 ETH, floor 1 ETH. A piece
lists at face and never decays; a merged item decays to 1 ETH and stays.

## 12. Admin

`PoolAdmin` implements `createFwaPool`, the setters (section 5, including `setTip`; `setGrail` and `setGrailTarget`
live in `PoolListing` with `grail()` and `grailItems()`), `startExit`, `exportStep`,
`transferGrailEstate(to)` (Exiting or Exported), `sweep`, `adminCall`, the import functions and `canImport`.
`PoolListing` implements `listBatch(max)`, `openBoard()`, `grailStep()` and `grailReprice()`, which only `Pool` calls on itself,
`registerForeign` (admin) and `repriceForeign` and `withdrawForeign` (the entry's controller),
and the read-only getters of the replacement, batch and reserve parameters, row counts, mix rows, held Shapes by
denomination, queue and claim entries and the GRAIL fund and items. `chooseRow(requestId, capturedRow)` returns the
replacement row for a fulfilled request.

`sweep(token, id, to)` sends out an ERC-721 token held outside the books (`Accounted` for an ordinary item, a GRAIL
item or a foreign listing). `adminCall(target, data, value)` is payable and requires `msg.value == value`, so the admin funds the call. After
the call it checks I1 and I2 and reverts `InvariantBroken` when either fails. A call to the FWA pool with the selector
of `withdrawOwnerProceeds` reverts `AdminCallDenied`: FWA owner proceeds leave FWA through the harvest. The admin is trusted: on the old pool,
`adminCall` can reach the successor's import functions, and a forged `finalizeImport` argument misprices a migration.

## 13. Exit: retirement and migration

`startExit(dest)`: admin, from Opening (once the FWA pool exists) or Live. Disables FWA acquisitions and closes pulls,
deposits, rotation and GRAIL mints and merges. `dest` is the pool itself for retirement or a successor for migration. A successor
has code, names this pool as `oldPool`, is Opening or Live, and uses the same Shapes and Draw Packs collections.

`exportStep(maxItems)`: anyone, repeatable. Settles, requires FWA `unsettledAcquisitionCount == 0` and a caught-up walk
(`FwaBusy`), then harvests. Moves, in order and bounded: every foreign listing to its controller, ordinary listings via `withdrawListingTo`, held ordinary
tokens, then the GRAIL estate (migration only, counted as one item). On retirement every ordinary item is redeemed into `cash`. On migration an
item moves to `dest` while `cash >= claims` and `dest.canImport(token)` is true, and is redeemed into `cash` otherwise.
The final call folds `maintenance` into `cash`, records `exportedShares = totalShares` and `exportedNav` (items already
moved included), sets Exported, calls FWA `retirePool`, and on migration sends `cash - claims` through `importCash` and
calls `finalizeImport(exportedShares)`.

Retirement: holders `withdraw` against `cash`; `payClaims()` pays queued claims FIFO. `transferGrailEstate(to)` withdraws
every GRAIL listing and sends the items and the fund to `to`. FWA refund credits stay at the old FWA pool.

Successor import, by `oldPool` only. `deposit`, `redeemAndDeposit` and `withdraw` revert `ImportInProgress` from the
first import until `finalizeImport`:

- `importItem(collection, tokenId)` registers the token as a held item of the first mix row with equal backing and the
  same kind (Shape or pack), and reverts `NoMatchingRow` otherwise (`canImport` is the view).
- `importGrail(collection, tokenId, done)` payable credits `msg.value` to `grail.fund` and, when `collection` is nonzero,
  registers the token as a GRAIL item with the `done` flag kept. The item is unlisted on arrival, priced at its backing
  for a piece and at `listBps` of its backing otherwise, and listed by the next `rotate`. When the cap of the item's kind is full (16 building, 32 done), the arriving token is
  redeemed into the fund. `exportStep` makes one call per item, the first
  one carrying the fund; with no items it makes one call with a zero `collection`. The successor keeps its own cycle.
- `importCash()` credits `cash`. `finalizeImport(fromShares)` mints `importedShares = importedNav * totalShares /
  preImportNav`, or `importedNav` when the share supply or `preImportNav` is zero, and stores `importedFromShares =
  fromShares`. Imported NAV bypasses `navCap()` and the founder window.

`migrateHolder(addr)` by anyone mints `oldPool.sharesOf(addr) * importedShares / importedFromShares` once per address.
Rounding leaves a few wei of `importedShares` unassigned, so NAV per share stays conservative. The next `rotate` lists
imported tokens.

## 14. Lens

Views only: `quote(count)`, `nav()`, `sharePrice()`, `position(addr)`, `board()`, `grail()`, `foreign()`, `claims()`,
`reopenStatus()`, `rotateDue()`, `settleDue()`, `parameters()`. `grail()` returns the fund, receivable, `targetWei`, `nextTargetWei`, `cycleId`, `listBps`, `decayWeiPerPull`, `pieceFloorWei`, `floorWei`, `pulls`, `cycleStartedAt`, `stepUpSeconds`, `stepDownSeconds` and every GRAIL item (collection, `done`, tokenId, backing, notional, listingId, `listedAtPull`, selection weight in bps). `parameters()` lists the constructor values and
the setter values, including the batch, replacement, reserve, `tipWei` and `listWhilePaused` fields. `reopenStatus()` lists the reopen guards: the purchase cooldown,
solvency and board depth. `quote(count)` returns the FWA quote and `purchasable` with a reason.

## 15. Out of scope for v1

Controller replacement, FWA pool migration machinery, GRAIL successor handoff, zero-share beneficiary, late GRAIL
recovery claims, in-kind exits, withdrawal cohorts and windows, pending deposit escrow and cancellation, launch seed,
named purchaser, controller reserve subsidy, builder revenue, operator fee line, pullWithShapes bonus, typed board scan,
RTP ceiling, maintenance sweep into the GRAIL, demand gates, pack code in this repo, indexer, activity and profile pages, runtime
keeper package.

## 16. Acceptance

All suites run against the real Shapes, Draw Packs and FWA contracts on a mainnet fork at a pinned block.

- Unit tests per external function.
- Invariant suite over I1 to I7 with deposit, withdraw, acquire, `pullWithShapes`, `redeemAndDeposit`, settle,
  `rotateIfDue` (`rotate` once `rotateDue` returns a reason), `payClaims`, startExit, exportStep as actions.
- Scenario suite: open a pool, deposit, build, pull single and batch, settle, capture a pack, capture a GRAIL, withdraw
  with liquidation, retire, migrate to a second pool and `migrateHolder`.
- Gas receipts of `acquireBatch(5)`, `settle` and `rotate` in `evidence/`. Sepolia rehearsal, then mainnet.
