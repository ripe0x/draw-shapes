# Draw Shapes v1 specification

Date: 2026-10-13. Status: owner decisions recorded in `docs/V1_PROMISES.md` (decisions 1 to 9). This document is the
build input. It states what the contracts do and what must stay true.

## 1. Purpose

Depositors fund a pool with ETH. The pool mints Shapes and Draw Packs and lists them on one FWA V2 custom pool. Players
pay FWA's ticket; FWA selects and delivers one listing per acquisition. The pool replaces each captured listing with the
same composition. Each settled ticket pays depositors a premium, funds upkeep, and feeds two GRAIL prize tracks.
Depositors exit at NAV in ETH.

## 2. Actors

| Actor | Can |
| --- | --- |
| Depositor | `deposit`, `withdraw`, read position. |
| Player | `acquire`, `acquireBatch`, `pullWithShapes`, `redeemAndDeposit`, claim FWA refunds at the FWA pool. |
| Anyone | `rotate`, `payClaims`, `exportStep`, `migrateHolder` on a successor. |
| Admin | One address, transferable. Pause flags, parameter setters, `setPurchaseGate`, `adminCall`, `startExit`, `transferGrailEstate`, `sweep`. |

Shares are nontransferable. There is one admin role.

## 3. Contracts and dependencies

| Contract | Role |
| --- | --- |
| `Pool.sol` | Shares, buckets, board, acquisitions, GRAIL tracks, upkeep, rotation, claim payment. Immutable. Owns the FWA pool. Its `fallback` delegates to `PoolAdmin`. |
| `PoolAdmin.sol` | Admin and exit surface: setters, `sweep`, `adminCall`, `startExit`, `exportStep`, `transferGrailEstate`, successor import. Runs by delegatecall from `Pool` on the `PoolStorage` layout. A direct call reverts `NotDelegated`. |
| `PoolBooks.sol`, `PoolStorage.sol` | Shared bases of both: settlement, harvest and margin split; storage layout, item registry and parameter validation. |
| `interfaces/IPool.sol` | Combined ABI of `Pool` and `PoolAdmin`, with the types, errors and events. |
| `Lens.sol` | Read-only views and quotes. Replaceable by deploying a new one. |
| Draw Packs | Fork of `shape-packs` with `MIN_PACK_VALUE = 2 * unit()`, deployed as its own collection. Used through `IShapePacks`. |
| Shapes | Mainnet `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`. `mintBatchTo`, `redeem`, `mintFee`. |
| FWA V2 clone | Created by the pool through the factory. `listNFT`, `listNFTs`, `updatePrice`, `withdrawListingTo`, `processAcquisitions`, `withdrawOwnerProceeds`, `acquire`, `acquireBatch`, `setPurchaseOperator`, `retirePool`. |

`Pool` and `PoolAdmin` compile with via_ir. The `PoolAdmin` module is the only delegatecall target. Pure math is in
internal libraries (`PricingLib`). Measured runtime sizes: `Pool` 24,129 B, `PoolAdmin` 18,058 B, `Lens` 12,536 B,
against the EIP-170 limit of 24,576 B.

## 4. Buckets and invariants

Every wei the pool holds is in exactly one bucket.

| Bucket | Holds |
| --- | --- |
| `cash` | Spendable ordinary ETH. |
| `backing` | Sum of backing of ordinary Shapes and Draw Packs held or listed. |
| `receivable` | FWA `ownerProceeds` booked and awaiting harvest. |
| `maintenanceReceivable`, `grail[t].receivable` | Booked shares of `ownerProceeds`. Harvest credits them to `maintenance` and `grail[t].bucket`. |
| `claims` | Unpaid withdrawal claims, FIFO. |
| `maintenance` | Upkeep refunds. |
| `grail[t].bucket`, `grail[t].backing` | ETH for track `t`, and the backing of its pack. |

Ordinary NAV = `cash + backing + receivable - claims`, or zero when `claims` exceed the assets. GRAIL buckets and GRAIL
backing are outside ordinary NAV. A replacement mint fee leaves NAV at the replacement mint.

Invariants, enforced by the invariant suite:

- I1 `address(this).balance >= cash + maintenance + sum(grail[t].bucket)`. Claims are a NAV liability paid from `cash`;
  a queued claim is by definition the part cash did not cover.
- I2 `backing` equals the sum of `valueOf` or denomination over every ordinary token the pool owns or has listed.
- I3 Shares redeem at ordinary NAV per share; a withdrawal never pays more than that at request time.
- I4 Claims are paid in request order.
- I5 A GRAIL bucket pays only for its own track's mints, pack additions and list-price gap.
- I6 `maintenance` pays only `rotate` refunds and is never negative.
- I7 Buckets outside ordinary NAV (`maintenance`, `grail[t].bucket`) are credited only from netted positive margin
  (section 9). Ordinary NAV changes at a settled capture by `proceeds - value` less the replacement mint fee; per
  capture that can be negative, in expectation over the board it is positive.

## 5. Parameters

Constructor: Shapes, Draw Packs, FWA factory, admin, `oldPool` (zero unless the pool succeeds another), mix table, fee
split, GRAIL track parameters, `navCap`, entry curve, `rotateInterval`, `quietIntervalSeconds`, `restockTriggerBps`,
`openingDeadline`, `minItems`, `grailProbCapBps`, `repriceMinBps`, and the `PoolAdmin` address. `openingDeadline` is a
duration in seconds that `createFwaPool` starts.

Setters (admin, immediate effect, each emits `ParamSet(selector)`):

| Setter | Bound |
| --- | --- |
| `setFeeSplit(premiumBps, maintenanceBps, feedBps, minorShareBps)` | Sum of the first three at most 1,000. `minorShareBps` at most 10,000. |
| `setEntryCurve(baseBps, slopeBps, capBps, referenceWei)` | `capBps` at most 2,500. `referenceWei` above zero. |
| `setNavCap(wei)`, `setPaused(pulls, deposits)` | Any wei amount. Flags. |
| `setMix(rows)` | Each row: array of rungs, weight share. Rows of two or more rungs are packs. A row that holds items keeps its rungs. The table may grow. A row with items or queued replacements cannot be dropped (`RowInUse`). |
| `setGrail(track, targetWei, stepWei, listBps, decayWeiPerPull, floorWei)` | `listBps` 1 to 10,000. `floorWei` above zero and at most `targetWei * listBps / 10_000`. `stepWei` a multiple of the Shapes unit and at least two units. |
| `setMinItems(n)` | Any. |
| `setGrailProbCap(bps)` | 1 to 10,000. |
| `setRepriceMinBps(bps)` | At most 10,000. |
| `setMaxBatch(n)`, `setConcurrency(n)` | At most FWA's live values. `n` above zero for `setMaxBatch`. |
| `setRotateInterval(seconds)` | At least FWA's `inventoryChangeCooldown` and at most `quietIntervalSeconds`. |
| `setRestockTriggerBps(bps)`, `setQuietInterval(seconds)` | `bps` at most 10,000. `seconds` at least `rotateInterval`. |
| `setAdmin(address)` | Nonzero. |

Launch values: premium 200, maintenance 100, feed 400, minor share per `launch-profile.json`; entry curve base 1,100,
slope 2,000, cap 2,500, reference 55 ETH; opening deadline 24 h. The owner set these:
- `minItems` 100: the board stays above FWA's 10 outstanding requests and the captures per rotate.
- `navCap` 100 ETH: bounds the opening.
- Mix 0.01 Shape 38 percent, 0.02 pack 28, 0.03 pack 19, 0.05 Shape 10, 0.1 Shape 4, 0.5 Shape 1: the 0.1 and 0.5
  rows restore the large pieces of the launch profile at a small share.
- `rotateInterval` 900 s (spacing between inventory changes), `restockTriggerBps` 1,000, `quietIntervalSeconds` 43,200.
- `repriceMinBps` 100: GRAIL decay reprices in steps of at least 1 percent.

`grailProbCapBps` and the GRAIL tracks are set in `script/env/<env>.env`.

## 6. Lifecycle

`Opening -> Live -> (Paused) -> Exiting -> Exported`.

- Opening: deposits open from deployment at NAV, which is pure cash, so every opening depositor receives shares 1:1.
  Pulls closed. Admin calls `createFwaPool(expectedFee)`, which starts the opening deadline. After the deadline anyone
  calls `open()`. It enables FWA acquisitions and runs one restock. Each call mints at most 20 tokens, so `open()`
  repeats until the board is built. The first call that mints fewer than 20 sets Live.
- Live: all paths open subject to pause flags and reopen guards.
- Paused: admin flags. Settlement of issued pulls, deposits and `rotate` continue unless the specific flag closes them.
- Exiting: `startExit(dest)` by admin. It disables FWA acquisitions and closes pulls, deposits, rotation and GRAIL
  growth. `exportStep()` by anyone until done.
- Exported: snapshot recorded. Holders `withdraw` against cash when `dest` is the pool itself; otherwise the successor
  mints their shares.

## 7. Depositor paths

Share pricing follows the books. `deposit`, `withdraw` and `redeemAndDeposit` first sync: process and book
up to 20 FWA acquisitions, require the booking walk to reach FWA's processing queue (`BooksBehind` otherwise), then
harvest. FWA processes acquisitions permissionlessly, and their outcomes are public before they are booked.

`deposit()` payable. Reverts when deposits are paused, when ordinary NAV is at or above `navCap`, when the pool is
Exiting, when NAV is zero while shares exist (`NavZero`), and on a successor while its import is open. Contribution =
`msg.value * curve(nav)`, where `curve(nav) = min(capBps, baseBps + slopeBps * nav / referenceWei)`. Contribution splits
into the GRAIL buckets by `minorShareBps`. Shares minted = `(msg.value - contribution) * totalShares / nav`, or 1:1 when
`totalShares == 0`, whatever NAV is: residual NAV while the share supply is zero goes to the next depositor. Imported
NAV from a migration is exempt from `navCap`.

`withdraw(shares)`. Burns shares. Claim = `shares * nav / totalShares`. Pays `min(claim, cash)` now and enqueues the
remainder. `withdraw` reverts once an exit to a successor has started (holders use `migrateHolder`) and on a successor
while its import is open (`ImportInProgress`).

Claim payment. `payClaims()` (anyone, any lifecycle state) pays queued claims from `cash` in FIFO order, at most 20
entries per call. In `rotate()` (trigger Claim) the claims step pays from `cash`, then, once the head claim is at least
`rotateInterval` old, redeems up to 25 items: held items first, then listed items of the row most over its share, and
only while FWA's `unsettledAcquisitionCount` is zero. The re-mint cost of each redeemed row, one mint fee per rung, is
deducted from the claim and stays in `cash`. A claim remainder at or below that cost leaves listings alone.

`redeemAndDeposit(tokenId)`. Redeems the caller's Shape at Shapes and runs `deposit()` with the proceeds.

## 8. Player paths

`acquire(purchaser, maxAcquisitionFee, minWeightedValue, maxNegativeSlippageBps, expectedInventoryVersion, deadline)`
payable returns one request id. `acquireBatch(purchaser, count, maxAcquisitionFee, minWeightedValue,
maxNegativeSlippageBps, expectedInventoryVersion, deadline)` payable returns the request ids. Both take FWA's purchase
ABI. `purchaser` must equal the caller (`PurchaserMismatch`). `count` is at most `maxBatch` and FWA's live limit. The
pool checks the reopen guards (section 9), forwards the caller's slippage, minimum weighted value, inventory version and
deadline to FWA `acquireBatch`, refunds overpayment to the caller, records each request's base price (section 9) and
runs the upkeep slice (section 10). `quoteAcquisitionPrice(count)` returns FWA's fee and VRF fee per acquisition and the
total.

`pullWithShapes(tokenIds, count, maxFee, deadline)` payable. Redeems the caller's Shapes at Shapes, adds `msg.value`,
and calls the batch path with the pool defaults: minimum weighted value 0 and FWA's `selectionSlippageBps` and
`inventoryVersion`. Excess returns to the caller.

Purchase gate. `createFwaPool` sets the pool as the FWA `purchaseOperator`, so FWA accepts a purchase only while the
pool's `canPurchase(wallet)` is true, which holds only inside the pool's forwarding call for that purchaser. Every
purchase passes the reopen guards and the upkeep slice. `setPurchaseGate(bool)` sets the operator to the pool or to
zero. The gate depends on the FWA site update that routes buys through the pool. Until it ships, the launch runs with
the gate off: direct FWA buys skip the reopen guards (board depth, solvency), and the next `settle` books them and
counts them for demand sizing and decay.

Refunds for slippage, timeout and failed delivery are FWA credits that the purchaser claims at the FWA pool.

Listing price for an ordinary token = `backing * (10_000 + premiumBps + maintenanceBps + feedBps + mintLineBps) /
10_000`, where `mintLineBps` is the replacement mint fee for that row expressed in bps of its backing. FWA adds its own
edge on top.

## 9. Board, replacement, rotation

The mix table is an array of rows: rungs (one for a Shape, two or more for a Draw Pack) and a weight share. Target depth
of a row = `max(minItems, pulls in the current clock hour and the four before it) * share`, rounded up.

Settlement. FWA pays the pool owner per acquisition `paid - (paid - base) / 2`, where `paid` is the escrowed fee and
`base = min(fee, weightedBackingTotal / totalWeight)` at request time (the harmonic mean of list prices). Proceeds are
the same for every capture in a batch.

1. At `acquire` and `acquireBatch`, the pool records `base` per request id. A request opened by a direct FWA buy books
   zero proceeds at capture.
2. `settle(maxCount)` (at most 20 per call) calls `processAcquisitions(maxCount)`, then walks FWA's sequence numbers
   from `nextSequenceToBook` up to FWA's processing queue. Every sequence passed counts as one pull in the current clock
   hour and adds one to `pullsSinceList` of each listed GRAIL track. Per status:
   - Fulfilled ordinary item: `backing -= value`, `receivable += proceeds`, `margin += proceeds - value`, `mintLineOwed
     += mintFee * rungs`, replacement row enqueued, margin split.
   - Fulfilled GRAIL pack: `grail[t].receivable += proceeds`, track resets.
   - DeliveryPending: written off at once. The item leaves `backing`, its value is charged to `margin`, and no proceeds
     or replacement are booked. If the delivery completes later, FWA's owner proceeds reach the pool as surplus (step
     4). If the purchaser refunds later, the admin recovers the token with `adminCall(recoverRefundedNFT)` and `sweep`.
   - DeliveryRefunded: the token returns to held items and the next `rotate` lists it.
   - Any other status: books nothing, and the walk advances past it.
3. Margin split. Positive `margin` first repays `mintLineOwed`. The rest divides pro rata by `premiumBps :
   maintenanceBps : feedBps`. The premium share stays in ordinary NAV. The maintenance share and the feed share (split
   by `minorShareBps`) leave it as receivables of their buckets. Negative `margin` carries forward until later captures
   repay it. After Exported the split is skipped, so later proceeds stay in ordinary NAV.
4. Surplus. At the end of each settle that reaches FWA's processing queue, `ownerProceeds()` above the booked
   receivables is booked as `receivable` and `margin` and split. It is the proceeds of direct purchases.
5. Harvest (`withdrawOwnerProceeds`) runs when the walk is level with FWA's queue. When the amount received is below the
   booked receivables, the pool emits `HarvestShortfall(received, expected)`, writes `receivable` down by the gap, and
   credits the buckets from the receivables.

`rotate()`. Anyone. Reverts `RotateTooSoon` until `rotateInterval` has passed since `lastRotateAt`, and `RotateNotDue`
unless a trigger holds. `lastRotateAt` and `ordinaryWeightSnapshot` move when the call changed inventory, so FWA's
purchase pause restarts at most once per interval. Triggers, in evaluation order at the start of the call:

1. Weight: ordinary selection weight (FWA `totalWeight` minus the listed GRAIL weight) is `restockTriggerBps` or more
   below `ordinaryWeightSnapshot`, its value after `open()` and after each call that changed inventory.
2. GrailCap: the listed GRAIL weight exceeds `grailProbCapBps` at current prices.
3. Claim: the head queued claim is at least `rotateInterval` old.
4. GrailStep: a track below `targetWei` holds a bucket that covers a step and its mint fees.
5. Restock: a held item exists, or cash after queued claims covers the next replacement or a row below target depth.
6. Quiet: `quietIntervalSeconds` have passed since `lastRotateAt`.

`rotateDue()` returns the first trigger that holds as a `RotateTrigger`, and `None` before the spacing ends, outside the
Live state and while every trigger is false. A trigger can hold while its work is blocked, such as Claim while FWA holds
unsettled acquisitions. That call keeps `lastRotateAt`, the FWA pause and `maintenance` as they were. Steps, each
bounded: (1) settle and harvest; (2) pay queued claims, then liquidate for the head claim when due; (3) restock
(`open()` runs this step only): pay claims again, mint queued replacements while `cash` covers the row cost, mint toward
target depth from `cash` above one step of the cheapest row once the queue is empty, then list every held item with
`listNFTs`, at most 20 mints; (4) `activateListings` when FWA's `unsettledAcquisitionCount` is zero and the walk is
level; (5) GRAIL, per track: grow when funded, otherwise decay or lift the list price; (6) refund the caller.

Reopen guards, checked by `acquire` and `acquireBatch`: FWA `purchasesResumeAt` passed, I1 holds with the incoming
value, and listed ordinary items at least `concurrency` above the unsettled acquisitions.

## 10. Upkeep and refund

Per-pull slice, inside `acquire` and `acquireBatch`: process and settle up to 3 acquisitions, harvest, pay queued claims
from `cash`, then mint at most one queued replacement when `cash` covers it. The slice mints and holds; `rotate` lists.
FWA restarts its purchase pause on every listing, so a listing inside the purchase would pause the next ticket.

FWA rejects `withdrawListing` and `updatePrice` while any acquisition is unsettled. Under continuous pull flow,
listed-item liquidation, GRAIL growth and repricing wait for a gap. The admin can pause pulls to open one.

`rotate` refund: `refund = min(maintenance, (gasUsed + 30,000) * block.basefee + tip)`, with `gasUsed` covering the
trigger evaluation. It is paid only when the call changed inventory (listed, withdrew or repriced) and
`rotateInterval` has passed since `lastRefundAt`: one refund per interval. A rotate that changes no inventory
pays nothing. `tip` is a constant 0.0005 ETH.

## 11. GRAIL tracks

Two tracks, `minor` and `major`, one struct each: `bucket`, `packId`, `backing`, `notional`, `targetWei`, `stepWei`,
`listBps`, `decayWeiPerPull`, `floorWei`, `pullsSinceList`, `receivable`, `listingId`.

Growth (trigger GrailStep), per track: requires `bucket >= stepWei + mint fees`, `backing < targetWei` and a zero FWA
`unsettledAcquisitionCount`. Withdraws the listing if listed; mints the largest native rungs that fit; `createPack` if
`packId == 0`, else `addToPack`; `backing += step`; if the pack's contents sum to a native rung, opens, composes at
Shapes, and repacks it as one Shape; `notional = backing * listBps / 10_000`; lists. It resets `pullsSinceList`.

Decay, inside `rotate`, after the growth step, for a track the growth step left unchanged: `next = max(floorWei,
notional - decayWeiPerPull * pullsSinceList)`. The reprice runs when the listing is Active, `notional - next >=
notional * repriceMinBps / 10_000`, and the listed GRAIL weight at `next` stays within `grailProbCapBps`. It calls
`updatePrice` and resets `pullsSinceList`. An unlisted pack is listed at `next`. On capture: proceeds go to the track's
receivable and then its bucket, `packId = 0`, `backing = 0`.

Probability cap (trigger GrailCap). When the listed GRAIL weight exceeds `grailProbCapBps`, `rotate` lifts a track's
`notional` to the smallest price that restores the cap, at most `backing * listBps / 10_000`. The lift mirrors decay: it
needs an Active listing and no unsettled acquisitions, and it resets `pullsSinceList`. Purchases and growth carry no cap
check. The purchase path keeps at least `concurrency` ordinary items listed through the board depth guard, and growth
only raises a track's price. With ten 0.01 ETH items listed, a first minor listing at 0.075 ETH holds about 1.3 percent
of selection weight and a first major step at 0.375 ETH about 0.3 percent, both under a 10 percent cap; a breach needs
fewer than two ordinary items listed.

## 12. Admin

`PoolAdmin` implements the setters (section 5, with `setRestockTriggerBps` and `setQuietInterval`), `setPaused`,
`setPurchaseGate`, `setAdmin`, `startExit`, `exportStep`, `transferGrailEstate(t, to)` (Exiting or Exported), `sweep`,
`adminCall` and the import functions. `Pool` implements `createFwaPool`.

`sweep(token, id, to)` sends out an ERC-721 token held outside the books. It reverts (`Accounted`) for a held or listed
ordinary token and for a GRAIL pack.

`adminCall(target, data, value)` is payable and requires `msg.value == value`, so the admin funds the call. After the
call it checks I1 and I2 and reverts `InvariantBroken` when either fails. The admin is trusted: on the old pool,
`adminCall` can reach the successor's import functions, and a forged `finalizeImport` argument misprices a migration.

## 13. Exit: retirement and migration

`startExit(dest)`: admin, from Opening (once the FWA pool exists) or Live. Disables FWA acquisitions and closes pulls,
deposits, rotation and GRAIL growth. `dest` is the pool itself for retirement or a successor for migration. A successor
has code, names this pool as `oldPool`, is Opening or Live, and uses the same Shapes and Draw Packs collections.

`exportStep(maxItems)`: anyone, repeatable. Settles, requires FWA `unsettledAcquisitionCount == 0` and a caught-up walk
(`FwaBusy`), then harvests. Moves, in order and bounded: ordinary listings via `withdrawListingTo`, held ordinary
tokens, then GRAIL tracks (migration only). On retirement every ordinary item is withdrawn to the pool and redeemed into
`cash`. On migration an item moves to `dest` while `cash >= claims` and `dest.canImport(token)` is true, and is redeemed
into `cash` otherwise. The final call folds `maintenance` into `cash`, records `exportedShares = totalShares` and
`exportedNav` (items already moved included), sets Exported, calls FWA `retirePool`, and on migration sends `cash -
claims` through `importCash` and calls `finalizeImport(exportedShares)`.

Retirement: holders `withdraw` against `cash`; `payClaims()` pays queued claims FIFO. `transferGrailEstate` withdraws
the track's listing and sends the pack and bucket where the admin directs.

Successor import, by `oldPool` only. `deposit`, `redeemAndDeposit` and `withdraw` revert `ImportInProgress` from the
first import until `finalizeImport`:

- `importItem(collection, tokenId)` registers the token as a held item of the first mix row with equal backing and the
  same kind (Shape or pack), and reverts `NoMatchingRow` otherwise. `canImport` is the view of that rule. The
  successor's mix must cover the old rows.
- `importGrail(t, packId)` credits the ETH value to the track's bucket. The pack becomes the track's pack, listed by the
  next `rotate`. When the track already holds a pack, the arriving pack is redeemed and its proceeds join the bucket.
- `importCash()` credits `cash`.
- `finalizeImport(fromShares)` mints `importedShares = importedNav * totalShares / preImportNav`, or `importedNav` when
  the share supply or `preImportNav` is zero, and stores `importedFromShares = fromShares`. Imported NAV bypasses
  `navCap`.

`migrateHolder(addr)` by anyone mints `oldPool.sharesOf(addr) * importedShares / importedFromShares` once per address.
Rounding leaves a few wei of `importedShares` unassigned, so NAV per share stays conservative. The next `rotate` lists
imported tokens.

FWA refund credits stay at the old FWA pool and remain claimable there.

## 14. Lens

Views only: `quote(count)`, `nav()`, `sharePrice()`, `position(addr)`, `board()`, `grail(t)`, `claims()`,
`reopenStatus()`, `rotateDue()`, `parameters()`. `reopenStatus()` lists the reopen guards: the purchase cooldown,
solvency and board depth. `quote(count)` returns the FWA quote and `purchasable` with a reason.

## 15. Out of scope for v1

Controller replacement, FWA pool migration machinery, GRAIL successor handoff, zero-share beneficiary, late GRAIL
recovery claims, in-kind exits, withdrawal cohorts and windows, pending deposit escrow and cancellation, launch seed,
named purchaser, controller reserve subsidy, builder revenue, operator fee line, pullWithShapes bonus, typed board scan,
step-up and step-down GRAIL timers, demand gates, pack code in this repo, indexer, activity and profile pages, runtime
keeper package.

## 16. Acceptance

All suites run against the real Shapes, Draw Packs and FWA contracts on a mainnet fork at a pinned block.

- Unit tests per external function.
- Invariant suite over I1 to I7 with deposit, withdraw, acquire, settle, `rotateIfDue` (`rotate` once `rotateDue`
  returns a trigger), `payClaims`, startExit, exportStep as actions.
- Scenario suite: open a pool, deposit, build, pull single and batch, settle, capture a pack, capture a GRAIL, withdraw
  with liquidation, retire, migrate to a second pool and `migrateHolder`.
- Gas: `acquireBatch(5)` and `rotate` receipts in `evidence/`. Sepolia rehearsal of the scenario path, then mainnet.
