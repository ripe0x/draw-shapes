# Draw Shapes v1 specification

Date: 2026-10-12. Status: owner decisions recorded in `docs/V1_PROMISES.md` (decisions 1 to 9).
This document is the build input for the rebuild. It states what the contracts do and what must
stay true. Code, tests, web and runbook derive from it.

## 1. Purpose

Depositors fund a pool with ETH. The pool mints Shapes and Draw Packs and lists them on one FWA V2
custom pool. Players pay FWA's ticket; FWA selects and delivers one listing per acquisition. The
pool replaces each captured listing with the same composition. Each settled ticket pays depositors
a premium, funds upkeep, and feeds two GRAIL prize tracks. Depositors exit at NAV in ETH.

## 2. Actors

| Actor | Can |
| --- | --- |
| Depositor | `deposit`, `withdraw`, read position. |
| Player | `pull`, `pullWithShapes`, `redeemAndDeposit`, claim FWA refunds at the FWA pool. |
| Anyone | `rotate`, `liquidate`, `growGrail`, `exportStep`, `migrateHolder` on a successor. |
| Admin | One address, transferable. Pause flags, parameter setters, `adminCall`, `startExit`, `transferGrailEstate`, `sweep`. |

Shares are nontransferable. There is one admin role.

## 3. Contracts and dependencies

| Contract | Role |
| --- | --- |
| `Pool.sol` | Shares, buckets, board, pulls, GRAIL tracks, upkeep, exit. Immutable. Owns the FWA pool. |
| `Lens.sol` | Read-only views and quotes. Replaceable by deploying a new one. |
| Draw Packs | Fork of `shape-packs` with `MIN_PACK_VALUE = 2 * unit()`, deployed as its own collection. Used through `IShapePacks`. |
| Shapes | Mainnet `0x6fe9193276bf7abcbee44ab7afd717d637d6faf0`. `mintBatchTo`, `redeem`, `mintFee`. |
| FWA V2 clone | Created by the pool through the factory. `listNFT`, `listNFTs`, `updatePrice`, `withdrawListingTo`, `processAcquisitions`, `withdrawOwnerProceeds`, `acquire`, `acquireBatch`, `retirePool`. |

Target size: `Pool.sol` under 2,000 lines, under 40 external functions, no delegatecall
libraries. If the body exceeds 24KB, move pure math to internal libraries first and views to
`Lens` second.

## 4. Buckets and invariants

Every wei the pool holds is in exactly one bucket.

| Bucket | Holds |
| --- | --- |
| `cash` | Spendable ordinary ETH. |
| `backing` | Sum of backing of ordinary Shapes and Draw Packs held or listed. |
| `receivable` | FWA `ownerProceeds` booked but not yet harvested. |
| `claims` | Unpaid withdrawal claims, FIFO. |
| `maintenance` | Upkeep refunds. |
| `grail[t].bucket` | ETH for track `t`. |
| `grail[t].backing` | Backing of track `t`'s pack. |

Ordinary NAV = `cash + backing + receivable - claims`. GRAIL buckets and GRAIL backing are
outside ordinary NAV.

Invariants, enforced by the invariant suite:

- I1 `address(this).balance >= cash + claims + maintenance + sum(grail[t].bucket)`.
- I2 `backing` equals the sum of `valueOf` or denomination over every ordinary token the pool owns
  or has listed.
- I3 Shares redeem at ordinary NAV per share; a withdrawal never pays more than that at request
  time.
- I4 Claims are paid in request order.
- I5 A GRAIL bucket pays only for its own track's mints, pack additions and list-price gap.
- I6 `maintenance` pays only `rotate` refunds and is never negative.
- I7 Ordinary NAV does not decrease across a settled pull except by the replacement mint fee,
  which the ticket's mint line funds.

## 5. Parameters

Constructor: Shapes, Draw Packs, FWA factory, admin, mix table, fee split, GRAIL track
parameters, `navCap`, entry curve, `rotateInterval`, `openingDeadline`.

Setters (admin, immediate effect):

| Setter | Bound |
| --- | --- |
| `setFeeSplit(premiumBps, maintenanceBps, feedBps, minorShareBps)` | Sum of the first three at most 1,000. |
| `setEntryCurve(baseBps, slopeBps, capBps, referenceWei)` | `capBps` at most 2,500. |
| `setNavCap(wei)` | Any. |
| `setMix(rows)` | Each row: array of rungs, weight share. Rows of two or more rungs are packs. |
| `setGrail(track, targetWei, stepWei, listBps, decayWeiPerPull, floorWei)` | `listBps` 1 to 10,000. |
| `setMaxBatch(n)`, `setConcurrency(n)` | At most FWA's live values. |
| `setRotateInterval(seconds)` | At least FWA's `inventoryChangeCooldown`. |
| `setPaused(pulls, deposits)` | Flags. |
| `setAdmin(address)` | Nonzero. |

Launch values: premium 200, maintenance 100, feed 400, minor share per `launch-profile.json`;
entry curve base 1,100, slope 2,000, cap 2,500, reference 55 ETH; `rotateInterval` 3,600 s;
opening deadline 24 h after FWA pool creation.

## 6. Lifecycle

`Opening -> Live -> (Paused) -> Exiting -> Exported`.

- Opening: deposits open from deployment at NAV, which is pure cash, so every opening depositor
  receives shares 1:1. Pulls closed. Admin calls `createFwaPool(expectedFee)`; the opening
  deadline starts there. After the deadline anyone calls `open()`, which runs the first
  `rotate()` to build the board and enables pulls once the reopen guards pass.
- Live: all paths open subject to pause flags and reopen guards.
- Paused: admin flags. Settlement of issued pulls, deposits and `rotate` continue unless the
  specific flag closes them.
- Exiting: `startExit(dest)` by admin. Pulls and deposits closed. `exportStep()` by anyone until
  done.
- Exported: snapshot recorded. Holders `withdraw` against cash when `dest` is the pool itself;
  otherwise the successor mints their shares.

## 7. Depositor paths

`deposit()` payable. Reverts when deposits are paused, when ordinary NAV is at or above `navCap`,
or when the pool is Exiting. Contribution = `msg.value * curve(nav)`, where
`curve(nav) = min(capBps, baseBps + slopeBps * nav / referenceWei)`. Contribution splits into the
GRAIL buckets by `minorShareBps`. Shares minted = `(msg.value - contribution) * totalShares /
nav`, or 1:1 when `totalShares == 0`. Imported NAV from a migration is exempt from `navCap`.

`withdraw(shares)`. Burns shares. Claim = `shares * nav / totalShares`. Pays `min(claim, cash)`
now and enqueues the remainder. A queued claim is paid by `rotate()` or `liquidate()` in FIFO
order and bears the mint fees of Shapes redeemed on its behalf.

`liquidate()`. Same step as the claim-paying part of `rotate()`. No-op when the queue is empty.
Callable when the head claim is older than `rotateInterval`. Bounded by the unpaid claim total
and by a per-call item limit. Requires FWA `unsettledAcquisitionCount == 0`; otherwise it first
calls `processAcquisitions`.

`redeemAndDeposit(tokenId)`. Pulls the Shape from the caller, redeems it at Shapes, and runs
`deposit()` with the proceeds in the same transaction.

## 8. Player paths

`pull(count, maxFee, deadline)` payable. `count` at most `maxBatch` and at most FWA's live limit.
Quotes FWA `quoteAcquisitionPrice(count)`, forwards it with `acquireBatch(msg.sender, ...)`,
refunds overpayment to the caller, and runs the per-pull upkeep slice (section 10). The purchaser
is always `msg.sender`.

`pullWithShapes(tokenIds, count, maxFee, deadline)` payable. Redeems the caller's Shapes at Shapes,
adds `msg.value`, and runs `pull`. Excess returns to the caller.

Refunds for slippage, timeout and failed delivery are FWA's credits, claimed by the purchaser at
the FWA pool. The pool records nothing about them.

Listing price for an ordinary token = `backing * (10_000 + premiumBps + maintenanceBps + feedBps
+ mintLineBps) / 10_000`, where `mintLineBps` is the replacement mint fee for that row expressed
in bps of its backing. FWA adds its own edge on top.

## 9. Board, replacement, rotation

The mix table is an array of rows: rungs (one for a Shape, two or more for a Draw Pack) and a
weight share. Target board depth = `max(minItems, pulls in the trailing 4 hours)`, scaled by row
share.

Settlement: `settle(maxCount)` calls FWA `processAcquisitions(maxCount)`, then reads each newly
settled acquisition. For a captured ordinary listing: `backing -= value`, `receivable += price`,
replacement row enqueued, fee split of `price - backing` credited to `cash` (premium),
`maintenance`, and the GRAIL buckets (feed, split by `minorShareBps`), mint line reserved in
`cash` for the replacement. For a captured GRAIL listing: `receivable += price`, that track's
bucket is credited when harvested, the track resets to step one.

`rotate()`. Anyone. Requires `rotateInterval` elapsed since the last rotation that changed
inventory. In order, each bounded:

1. `settle`.
2. `withdrawOwnerProceeds` into `cash`; `receivable` to zero.
3. Pay queued claims: from `cash` first; then withdraw and redeem ordinary listings proportional
   to row shares until the head claim is payable or the item limit is hit.
4. Mint replacements from the queue while `cash` covers backing plus mint fee; list them with
   `listNFTs`.
5. Mint new inventory toward target depth from spare `cash` above a one-step reserve.
6. GRAIL: decay reprice, then `growGrail` for each track if funded.
7. Refund the caller (section 10).

Reopen guards, checked before any pull: FWA `purchasesResumeAt` passed, I1 holds, unreserved
ordinary items at least `concurrency`, aggregate GRAIL selection probability at most
`grailProbCapBps`.

## 10. Upkeep and refund

Per-pull slice, inside `pull`: `processAcquisitions(settleBudget)` and at most one replacement
mint and list when `cash` covers it and the cooldown allows.

`rotate` refund: `refund = min(maintenance, gasUsed * block.basefee + tip)`, paid only when the
call changed state and the interval had elapsed. `tip` is a constant 0.0005 ETH.

## 11. GRAIL tracks

Two tracks, `minor` and `major`, one struct each: `bucket`, `packId`, `backing`, `notional`,
`targetWei`, `stepWei`, `listBps`, `decayWeiPerPull`, `floorWei`, `pullsSinceList`.

`growGrail(t)`: when `bucket >= stepWei + fees` and `backing < targetWei`: withdraw the listing if
listed; mint the largest native rungs that fit the step; `createPack` if `packId == 0`, else
`addToPack`; `backing += step`; if the pack's contents sum to a native rung, open, compose at
Shapes, and recreate the pack as one Shape; `notional = backing * listBps / 10_000`; list.

Decay, inside `rotate`: `notional = max(floorWei, notional - decayWeiPerPull * pullsSinceList)`;
`updatePrice` when changed. On capture: proceeds to `bucket`, `packId = 0`, `backing = 0`.

The gap between `backing` and the capture `price` is the track's cost and is paid by its bucket
(I5).

## 12. Admin

`setPaused`, setters in section 5, `setAdmin`, `createFwaPool`, `startExit`,
`transferGrailEstate(t, to)` (Exporting or Exported only), `sweep(token, id, to)` for tokens the
pool does not account for, `adminCall(target, data, value)` with a post-call check that I1 and I2
hold. `setPurchaseOperator` on the FWA pool is set to the pool at creation and never changed.

## 13. Exit: retirement and migration

`startExit(dest)`: admin. Closes pulls and deposits. `dest` is the pool itself for retirement or
a successor address for migration.

`exportStep(maxItems)`: anyone, repeatable. Requires FWA `unsettledAcquisitionCount == 0` after
`processAcquisitions`. Moves, in order and bounded: ordinary listings via `withdrawListingTo(dest)`
(retirement: withdraw to self and redeem to `cash`), held ordinary tokens, GRAIL packs, GRAIL
buckets, `maintenance`, then `cash` less `claims` to `dest` when `dest` is a successor. Records
`exportedShares = totalShares` and `exportedNav` and sets Exported. Calls FWA `retirePool`.

Retirement: holders `withdraw` against `cash`; claims pay FIFO. `transferGrailEstate` sends GRAIL
packs and buckets where the admin directs.

Successor import: the successor stores `oldPool`, `exportedShares`, `exportedNav`.
`migrateHolder(addr)` by anyone mints `oldPool.sharesOf(addr) * importedShares / exportedShares`
once per address. Imported tokens are registered by reading `valueOf` and denominations, listed
by the next `rotate`. Imported NAV bypasses `navCap`.

FWA refund credits stay at the old FWA pool and remain claimable there.

## 14. Lens

`quote(count)`, `nav()`, `sharePrice()`, `position(addr)`, `board()` (rows, counts, listed),
`grail(t)`, `claims()`, `reopenStatus()`, `parameters()`. Views only.

## 15. Out of scope for v1

Controller replacement, FWA pool migration machinery, GRAIL successor handoff, zero-share
beneficiary, late GRAIL recovery claims, in-kind exits, withdrawal cohorts and windows, pending
deposit escrow and cancellation, launch seed, named purchaser, controller reserve subsidy,
builder revenue, operator fee line, pullWithShapes bonus, restock weight trigger, typed board
scan, step-up and step-down GRAIL timers, demand gates, pack code in this repo, indexer, activity
and profile pages, runtime keeper package.

## 16. Acceptance

- Unit tests per external function against mocks.
- Invariant suite over I1 to I7 with deposit, withdraw, pull, settle, rotate, liquidate,
  growGrail, startExit, exportStep as actions.
- Fork suite at a pinned mainnet block against real Shapes, real Draw Packs and a real FWA clone:
  open a pool, deposit, build, pull single and batch, settle, capture a pack, capture a GRAIL,
  withdraw with liquidation, retire, migrate to a second pool and `migrateHolder`.
- Gas: `pull(5)` and `rotate` receipts recorded in `evidence/`.
- Sepolia rehearsal of the fork suite path by hand, then mainnet.

## 17. Repository plan

New branch from `main`. `src/` replaced by `Pool.sol`, `Lens.sol`, `interfaces/`. `test/`
replaced by unit, invariant and fork suites above; `PricingLib` math and the FWA callback
handling are ported from the current tree with their tests. `docs/` keeps `SPEC.md`,
`RUNBOOK.md`, `DEPLOY.md`, `V1_PROMISES.md`, `external/`; everything else moves to
`docs/archive/` in one commit. `evidence/`, `sim/`, `tools/runtime/`, `indexer/` move to archive.
`web/` keeps landing, deposit and protocol routes against the new ABI.
