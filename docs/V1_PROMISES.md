# Draw Shapes v1: what to keep, what to cut

Date: 2026-10-12. Director draft for owner markup. Sources: `docs/PRODUCT_RULES.md`,
`docs/OWNER_DIRECTIVES.md`, `docs/PRODUCT_ARCHITECTURE.md`, `project/launch-profile.json`,
`docs/external/shapes.md`.

## The product in one paragraph

Depositors put ETH into a pool. The pool mints Shapes and lists them on one FWA V2 custom pool.
Players pay a ticket, FWA picks and delivers a Shape. The pool replaces what was taken. Each
ticket pays depositors a premium, the operator a fee, and feeds a big-prize bucket. Depositors can
leave at NAV. That loop is the whole product. Everything else in the current system is lifecycle,
edge case or optionality.

## Where the 24k LOC comes from: nine multipliers

These are properties of the design that make every feature cost more. Removing one removes cost
from every path at once. Ordered by payoff.

| # | Multiplier | What it costs today | v1 proposal |
| --- | --- | --- | --- |
| X1 | Permissionless bounded resumable work. Every operation is a multi-call state machine with snapshots, slices, phases, caller reimbursement and per-cohort gas maxima. | Stages, Ops, Tracks, window libraries, maintenance accounting. The largest single driver. | Three layers. (a) Each pull carries a small fixed slice of upkeep: process and settle prior acquisitions, harvest, pay queued claims from cash. `settle()` by anyone lists queued replacements and reprices GRAIL items. A busy pool maintains itself. (b) One `rotate()` callable by anyone once per interval: run the GRAIL step (mint pieces and merge), pay queued withdrawal claims, liquidating inventory only as far as those claims require, and list held items when `settle` may not list. (c) The caller of `rotate()` is refunded `gasUsed * block.basefee` plus a small fixed tip from the maintenance bucket when funded; it runs unrefunded otherwise. Refund is paid only when the call did work and the interval had elapsed, so the drain is bounded to one refund per interval. The admin runs a cron as backstop; liveness never depends on it. |
| X2 | Non-native denominations. Launch mix uses 0.02 and 0.03 ETH and the GRAIL target is 25 ETH. Shapes' native ladder is 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 50, 100. Packs fill the gaps so more pulls land at or above the ticket. | ShapePack with open, unseal, claim, claimant, makeup, stored recipes, merge, addToPack, replaceable renderer, presentation lock, ERC-2981, ERC-4906, collection succession, recipe validation in custody. About 3k LOC, 45 functions. | Draw Packs: a fork of `shape-packs` (mainnet Shape Packs `0xf21514b090da7df4390803497d6ae673801e5ca7`) with `MIN_PACK_VALUE` as a constructor parameter set to `2 * unit()`, deployed as its own collection. One-line source change, same renderer, same tests. `createPack(shapeIds, mintCounts)` mints from ETH and packs in one call; `addToPack` grows a pack; `valueOf` is the exact cached backing. Zero pack code in this repo beyond the interface. Owner decided 2026-10-12. |
| X3 | Two accounting domains. Ordinary NAV and a separate GRAIL estate with minor and major tracks, merge ladder, decay, notional floor, probability gates, step timers, late recovery, zero-share residual. | Every path reasons about both domains. GRAIL stages about 1,500 LOC, handoff about 700, recovery and beneficiary logic across settle and custody. | One `Grail` struct: a single fund, one ladder of targets (5, 10, 25, 50, 100 ETH) and a list of `grailItems`. The GRAIL step runs inside `rotate()`: while the fund covers a piece and its mint fee, mint a 1 ETH piece and list it at face; merge listed items up the ladder (five pieces to 5 ETH, then 10, 25, 50, 100) and list the output at `listBps` of its backing. Decay is a reprice rule inside `settle()`: a list price falls `decayWeiPerPull` per settled pull toward `pieceFloorWei` for a piece and `floorWei` for a merged item. On capture, proceeds return to the fund. A completed cycle sets the next target by the step rule: under `stepUpSeconds` one rung up, over `stepDownSeconds` one rung down, and the admin may set it with `setGrailTarget`. `open()` forms the opening five pieces into a 5 ETH item from the entry fund. Cut: demand gates, seed receivables, late recovery, beneficiary. After the exit, admin `transferGrailEstate(to)`. |
| X4 | Upgradeability. Replaceable controller with carried state, FWA pool migration, GRAIL-only successor handoff with preflight, staging, precommit, commit, repricing, unlock. | Controller/custody split, ControllerStore, PoolStore, PoolMigrationOps, GrailHandoff*, delay plumbing. About 2.5k LOC. | Immutable code with one terminal export path shared by retirement and migration. Admin `startExit(dest)` closes pulls and deposits. After FWA shows zero pending acquisitions, anyone runs `exportStep()` in bounded slices: FWA `withdrawListingTo(dest)` moves every NFT, then ETH buckets, the GRAIL pack and the unpaid claim array, then a snapshot of total shares and exported NAV. Retirement is the same loop with the pool itself as the destination: items are redeemed to cash and holders `withdraw`. A successor pool stores the old pool address and snapshot; `migrateHolder(addr)` by anyone mints the holder's pro-rata shares once. Depositors do nothing, nothing is redeemed, FWA refund credits stay at the old FWA pool. About 80 lines old side, 60 lines new side. |
| X5 | Deferred everything. Pending deposit escrow, opening cohort, finalizeLaunch, launch seed, activation at next rotation, withdrawal cohorts, 12-hour windows, navLow freeze, in-kind exit plans, claim ledgers. | LaunchAdmin, ShareOps, WithdrawalWindowLib (1,239 LOC), MergeDepositOps, parts of RotateOps and SettleOps. | Immediate at NAV. Deposit mints shares now. Pre-open NAV is pure cash so the opening round is 1:1 for everyone until `open()`. Withdraw burns shares at NAV into a FIFO ETH claim paid from cash. The rotate liquidation step raises cash when short. ETH exits only. |
| X6 | Admin surface. Staged versus immediate parameters, 20-plus setters, allowlists, raw calls with post-call proofs, typed board scans. | CustodyAdminOps, ControllerAdminOps, PrizeAdmin, RawBoardOps, ParamsLens. | Constructor parameters plus a handful of immediate setters (fee split, pause flags, GRAIL target, max batch). One `adminCall` escape hatch, disclosed. Scans cut. |
| X7 | Four-contract split with mirrored stores and two lenses. | Custody, Controller, PoolStore, ControllerStore, Lens, ParamsLens, LensQuote, 15 interfaces. 172 external functions. | One `Pool` contract plus one `Lens`. Target under 30 external functions. Falls out of X1 to X6 once the body is under 24KB. |
| X8 | Entry fee. Floor 10%, cap 25%, 20 payback days of depositor yield (owner decision 2026-10-14, OWNER_QUESTIONS 39). | `PricingLib.entryFeeBps`, evaluated inside `deposit()`, Lens `admission()`. | Once deposits are immediate (X5), the fee is a pure function of the trailing fee volume and current NAV. A volume-responsive `navCap()` with a `navCapFloor` and a founder window sit beside it. |
| X9 | Generated surface in web and tooling. ABI files scale with contract surface. | 20k of 34k web lib LOC, 17k of 18.5k runtime LOC. | Falls out of X7. A 30-function ABI is about 2k LOC. |

## The v1 loop, promise by promise

Owner marks the last column KEEP, CUT or SIMPLIFY. Director column is the recommendation.

| # | Promise | v1 mechanism | Director | Owner |
| --- | --- | --- | --- | --- |
| 1 | Deposit ETH, get pro-rata nontransferable shares at NAV, while NAV is under the cap. | `deposit()` computes the contribution from the entry fee on current NAV and the trailing fee volume, sends it to the GRAIL bucket, mints the remainder at NAV, reverts at or above `navCap()`. | KEEP | |
| 2 | Opening round prices everyone the same. | Pulls closed until `open()`, which anyone calls after the opening deadline. Pre-open NAV is cash, so 1:1. `open()` lists the opening board and forms the opening five GRAIL pieces from the entry fund. | SIMPLIFY | |
| 3 | Depositor NAV excludes GRAIL and counts pulls in flight. | Buckets: ordinary cash, backing, in-flight, maintenance, operator, GRAIL. Invariant: every wei in one bucket. | KEEP | |
| 4 | Depositor earns a flat premium per ticket. | 200 bps to ordinary cash at settle. | KEEP | |
| 5 | Withdraw any time at NAV. | `withdraw(shares)` burns at current NAV, pays what spendable cash covers in the same transaction, and queues the rest as a FIFO claim. Claims are paid inside `rotate()`: first from cash that would otherwise mint replacements, then by withdrawing listings proportional to the mix table and redeeming them, bounded to the unpaid claim total and to a per-call item limit. `payClaims()` pays queued claims from cash in any lifecycle state. The claim bears the mint fees of the Shapes redeemed on its behalf. | SIMPLIFY | |
| 6 | Redeposit a won Shape. | `redeemAndDeposit(tokenId)`: Shapes redeem to ETH, then `deposit()`, one transaction. | SIMPLIFY | |
| 7 | Pay a count-aware ticket, FWA selects and delivers, refunds stay claimable. | `acquire` and `acquireBatch` on the pool forward to FWA, and `settle()` books the results. Quote from live FWA weights. | KEEP | |
| 8 | Pay with owned Shapes. | `pullWithShapes` redeems or keeps the Shapes inside the pull. Bonus cut. | SIMPLIFY | |
| 9 | Captured items are replaced by the same composition; the mint line funds it. | Replacement queue keyed by mix-table row. A pack row mints its rungs and wraps them. | KEEP | |
| 10 | Board restocks without the pool depending on a keeper. | `settle()` by anyone lists queued replacements. `rotate()` by anyone runs claims and the GRAIL step. Both refund the caller's basefee cost from the maintenance bucket. Admin runs it on a cron as backstop. | SIMPLIFY | |
| 11 | Pulls reopen only when safe. | FWA cooldown, ledger solvency, unreserved inventory at least max concurrency. GRAIL probability cap kept as one check. | SIMPLIFY | |
| 12 | A big prize forms from the feed, grows step by step, and sits on the board. | X3: one fund and one ladder. The GRAIL step inside `rotate()` mints 1 ETH pieces from the fund and merges them up to the cycle target; target, step and list price setters. Anyone may add to the fund through `fundGrail()`. | SIMPLIFY | |
| 13 | Fee split 100 maintenance, 200 premium, 400 GRAIL, FWA fees and replacement mint fees pass through. | Constants with setters. Operator line removed: Shapes mint fees on every replacement are the operator's revenue. | SIMPLIFY | |
| 14 | Operator revenue. | Shapes mint fees, paid by the ticket's mint line, received at the Shapes contract. No pool-side bucket. | CUT | |
| 15 | Admin can pause, edit economics, recover a broken board. | Pause flags, setters, `adminCall`. | KEEP | |
| 16 | Retirement returns value. | `startExit(address(pool))` then `exportStep()`: listings withdrawn, Shapes redeemed, holders `withdraw()` at NAV. `sweep(asset, to)` for strays after a solvency check. | SIMPLIFY | |
| 17 | The whole pool, depositors and GRAIL included, moves to a successor without anyone withdrawing. | `startExit(newPool)` then `exportStep()`; successor `migrateHolder(addr)` by anyone. See X4. | SIMPLIFY | |
| 18 | FWA pool created by the pool after deploy with the live factory fee. | `createFwaPool()`. | KEEP | |

Cut outright: operator fee line, named purchaser distinct from payer, controller reserve subsidy, builder revenue
path, zero-share beneficiary, late GRAIL recovery claims, OD-235 later-cohort rule, OD-231 surplus
relay, in-kind exits, last-holder NFT exit, pending deposit escrow and cancel, finalizeLaunch,
launch seed, controller replacement, FWA pool migration, GRAIL handoff, pack reveal and claim states, pack owner merge, pack
collection succession, pack renderer replacement, pack royalty and metadata refresh, typed board scan, restock weight trigger,
variable premium curve, pullWithShapes bonus.

## What v1 looks like

| Layer | Today | v1 target |
| --- | --- | --- |
| Contracts | 45 files, 24.3k LOC, 172 external functions | `Pool.sol` with the `PoolAdmin.sol` and `PoolListing.sol` delegatecall modules, `Lens.sol`, interfaces for Shapes, Shape Packs and FWA. About 2.5k to 3k LOC, under 40 external functions, no delegatecall libraries. Packs come from the deployed Shape Packs collection |
| Tests | 103 suites, 1,419 functions, 45k LOC | Ported fork suite against real Shapes and FWA V2 as the acceptance gate. One invariant suite: every wei in one bucket, shares redeem at NAV, claims FIFO. Unit tests per function. About 4k to 6k LOC |
| Web | 14 routes, 50k LOC | Landing with pull, deposit with withdraw, protocol. Activity, profile, admin, grail, dev and preview routes cut for v1. Indexer cut. About 8k to 12k LOC |
| Runtime keeper | 18.5k LOC package | A cron calling `rotate()`. Under 100 lines |
| Sim | 80 Python files | Archive |
| Docs | 779 files, 98k lines | `SPEC.md` (this promise list plus invariants, under 300 lines), `RUNBOOK.md`, `DEPLOY.md`. Everything else moves to `docs/archive/` in one commit |
| Evidence | 1,242 files | Archive |

## Rebuild or prune

Prune in place cannot reach the v1 target. The ops-library split, the controller/custody
boundary and the bucket model are shaped by X1 to X4, and every kept function is written against
those shapes. Pruning leaves a 10k LOC system with the same structure. Rebuild from the promise
list, porting PricingLib math, the FWA callback handling and the fork suite. Estimated contract
and test work is weeks, not months, because the kept promises are the ones already understood.

## Even smaller: on the table for completeness

Owner-funded v1 with no public depositors removes shares, NAV, withdrawals, entry contribution
and premium. Roughly half of what remains. OD-02 makes public deposits foundational, so this is
listed for the comparison and is the director's second choice.

## Decisions needed from the owner

1. Packs come from a forked Draw Packs instance with a 0.02 minimum, deployed as its own collection.
   Owner decided 2026-10-12.
2. GRAIL: one fund and one ladder, decay as a reprice rule, floor and targets as setters, the step rule
   for the next target, no demand gates. Owner asked to keep ladder, decay and floor, 2026-10-12; merge mode
   replaced the two tracks, 2026-10-14.
3. Trusted-admin operations with flat basefee refund, as in X1. Owner decided 2026-10-12.
4. ETH-only exits, as in X5. Owner decided 2026-10-12.
5. Immutable contracts with the shared export path baked in; successor by redeploy plus `startExit`/`exportStep`
   and `migrateHolder`, as in X4. Owner asked for full migration without redeposit, 2026-10-12.
6. Rebuild from the promise list rather than prune. Owner decided 2026-10-12.
9. Day-one capital: public depositors. Owner decided 2026-10-12.
7. Entry fee kept as a pure function inside `deposit()`, plus a volume-responsive NAV cap; no operator line,
   mint fees are the operator's revenue. Owner confirmed contribution is required, 2026-10-12.
8. The exiting depositor bears the mint fees burned by liquidating for their claim.
