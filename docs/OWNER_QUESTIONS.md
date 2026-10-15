# Owner questions and the guesses taken

Date: 2026-10-13. Director log for the unattended run through packets 3 to 7. Each entry states
the question, the guess the build follows, and where it is applied. Reverse any entry by editing
the named place; none of them is load bearing for the others unless the entry says so.

## Settled before the run (owner answered 2026-10-12)

- I1 drops `claims`. Applied in SPEC 4 and `Pool.sol` header.
- Settlement books `paid - (paid - base) / 2` per Fulfilled acquisition with `base` recorded at
  `acquire` and `acquireBatch`. Applied in `_acquire` and `_settle`.
- Draw Packs deploy from `lib/draw-packs` in fork setup. Applied in `ForkBase.deployDrawPacks`.
- `purchaseOperator` stays unset (pending owner confirmation). Superseded by owner decision 2 below.

## Owner decisions after the spec author's review (2026-10-13)

1. Entry 0 decided: via_ir and the PoolAdmin delegatecall module stay; SPEC 3 records the
   architecture with the measured sizes.
2. Purchase operator decided: `createFwaPool` sets the pool as FWA `purchaseOperator`. Pool exposes
   FWA's purchase ABI (`acquire`, `acquireBatch`, `quoteAcquisitionPrice`) so the FWA site can
   target the pool unchanged; `purchaser` must equal `msg.sender`; the caller's slippage, minimum
   weighted value, inventory version and deadline are forwarded; `canPurchase` is true only inside
   the pool's own forwarding call for the recorded purchaser. The operator toggle was removed
   (entry 40). Entry 9 superseded.
3. GRAIL probability cap decided: enforced by price only. The `GrailProbTooHigh` revert leaves the
   purchase path; `rotate` lifts a track's notional back toward `backing * listBps / 10_000` when
   its listed weight exceeds `grailProbCapBps`; growth and decay keep their cap checks.
   Superseded by entry 41 (2026-10-14): one fund and one ladder replace the tracks, and there is no lift. When the
   cap binds, the item keeps its price (SPEC 11).
4. Liquidation charge decided: stays, named the re-mint cost everywhere.
5. Launch values decided (entry 14 superseded for these keys): `MIN_ITEMS=100`,
   `NAV_CAP_WEI=100 ether`, `MIX_ROWS="0:3800;0,0:2800;0,0,0:1900;1:1000;2:400;3:100"` (0.01 Shape
   38 percent, 0.02 pack 28, 0.03 pack 19, 0.05 Shape 10, 0.1 Shape 4, 0.5 Shape 1),
   `ROTATE_INTERVAL_SECONDS=3600`; GRAIL tracks, fee split, entry curve, opening deadline and
   `grailProbCapBps` unchanged. Reasoning: a 100 item board gives headroom over FWA's 10 outstanding
   requests and the per-rotate captures, the 100 ETH cap bounds the opening, and the two large
   Shape rows restore the launch profile's 0.10 and 0.50 pieces at a small share.
   Superseded by entry 39 (2026-10-14) for the deposit cap (`NAV_CAP_FLOOR_WEI` and `TURNOVER_BPS` replace
   `NAV_CAP_WEI`) and the entry curve, by SPEC 5 for `ROTATE_INTERVAL_SECONDS` (900), and by
   entry 41 (2026-10-14) for the GRAIL tracks.
6. Every decided entry is folded into SPEC in one commit; this file stays the log, with each entry
   marked decided, open or superseded.
7. Remaining entries accepted as written: 4, 5, 10, 13, 18, 20, 22, 28, 29, 30, 31. Entry 6 is
   superseded: the FWA-shaped `acquire` takes the caller's `maxNegativeSlippageBps`.


## Owner decision 9, 2026-10-13: FWA cooldown goes to zero; settlement lists; replacement is sampled

Context: the FWA team is setting the factory `inventoryChangeCooldown` to 0, so inventory changes
no longer pause purchases. The owner reviewed the implications and decided:

a. `settle()` (anyone) books captures, harvests, and lists replacements in batches when due:
   queue at or above `batchMin` (5), oldest queued replacement older than `batchMaxAge` (3,600 s),
   or the board within 5 items of the concurrency guard. The caller is refunded gas plus the
   0.0005 ETH tip from maintenance only when the call was due and listed at least one item, so
   bots race for it and purchases carry no listing work. The purchase slice books and harvests
   only. Rotate keeps claims, GRAIL steps, decay and the held-items fallback.
b. Deleted: the Weight trigger and snapshot, `restockTriggerBps`, demand sizing (trailing pulls,
   `rowDepth`; a row's target is `ceil(minItems * share)`), `repriceMinBps`, the quiet floor and
   `lastRotateCallAt`. Decisions 8, F1 and F2 are superseded by this block.
c. Replacement row is sampled at booking from the mix shares with deficit weighting
   `share * (1 + restoreK * deficit / target)` (`restoreK` 8), a surprise upgrade with
   `surpriseBps` (200) to a single Shape row of at least five times the drawn backing (60/30/10
   by size), and a band cap of target plus `bandBps` (3,000) above which the largest-deficit row
   is chosen. Randomness is `keccak256(FWA randomWord, requestId)`, public after fulfilment and
   unknowable at purchase. A captured 0.1 row returns within about eight captures at `restoreK` 8.
d. Shapes paid in through `pullWithShapes` and `redeemAndDeposit` are kept as inventory and fill
   replacements before any mint (singles and pack components through `createPack` with existing
   ids), which saves the mint fee; both fall back to redeeming when cash is short.
e. Replacement minting spends only cash above queued claims plus `reserveBps` (1,000) of NAV, so
   withdrawals are normally paid at once. Withdrawals never delay purchases.
f. Cooldown guard: settle lists only while the live factory cooldown is zero or the admin switch
   `listWhilePaused` is on; otherwise rotate lists held items in its batch, today's cadence. A
   nonzero cooldown throttles, nothing reverts.
g. Open for the owner: `maintenanceBps` may need 200 at launch if gas prices make keeper refunds
   exceed the 100 bps inflow; the lab shows the depositor cost. Pack rows carry the largest mint
   fee drag (0.003 ETH on a 0.03 pack) and remain part of the game by decision.

h. Size after decision 9: Pool 24,395 B and PoolAdmin 23,974 B. To fit, `createFwaPool`, the
   row and queue getters and the `chooseRow` rule moved into PoolAdmin (reachable through the
   fallback, ABI unchanged; Pool reads `chooseRow` by self-call). Entry 36 is spent. The next
   Pool change needs a byte budget first.
i. Keeper economics measured on the 500 a day week with cooldown 0: 505 settle calls listing
   3,409 items (0.25 ETH refunded) and 609 rotate calls, 568 of them for GRAIL decay, 0.56 ETH of
   refunds in all, against about 0.7 ETH of maintenance inflow. Spec author's finding
   (2026-10-13): the cause is `decayWeiPerPull` 0.001, which makes a reprice due every 20 minutes
   at 500 pulls a day and hits the floor in a day. Decided: launch decay 0.0001 for both tracks
   (odds ramp over a week) and a fixed 1 percent reprice threshold in the decay step; the tip and
   `maintenanceBps` stay. Rerun, 500 a day for 7 days: 88 rotates (45 GrailStep, 43 Decay),
   505 settles, refunds 0.30 ETH (settle 0.25, rotate 0.04) against 1.20 ETH of maintenance
   inflow measured as bucket end plus refunds. At 100 a day: 29 rotates, 141 settles, 0.08 ETH
   refunds against 0.20 ETH inflow. Decided and in SPEC.
j. Size plan (recorded, not built): Pool 24,395 B and PoolAdmin 23,974 B leave no room for an
   audit fix. The next Pool change first moves the listing engine (`_fill`, `_collectQueue`,
   `_listBatch`, `_listItems`, `_openBoard`) into a third module reached the same way as
   `chooseRow`, which frees roughly 3 KB in Pool.

## Owner decision 10, 2026-10-13: listing module, decay in settle, tip setter, bigger batches

a. The listing engine (`_fill`, `_collectQueue`, `_listBatch`, `_listItems`, `_openBoard`) lives in
   `PoolListing`, a third module with the same storage layout, reached by selector from Pool's
   fallback and only through Pool's own self-calls (`onlySelf`). Sizes after: Pool 22,387 B,
   PoolAdmin 24,021 B, PoolListing 7,738 B. PoolAdmin has 555 B of margin; the next admin change
   needs a byte budget.
b. The GRAIL decay reprice (1 percent step) and the probability lift run inside a due `settle`,
   under the same listing condition as the batch (factory cooldown 0 or `listWhilePaused`), so
   a reprice rides a refunded call and never touches FWA inventory while a cooldown is live.
   Rotate's reasons are Claim, GrailStep and Held.
c. Batches: `batchMin` 20, `batchMaxAge` 3,600 s, `MAX_LIST_PER_SETTLE` 25 so one due settle
   clears a batch (a 20-item settle costs about 10.9M gas). The tip is `tipWei`, `setTip`
   (at most 0.01 ETH), launch 0.0002 ETH, used by settle and rotate refunds.
d. Minor GRAIL `listBps` 10,000 at launch (lists at 1 ETH at target); `setGrail` lowers it later.
   Superseded by entry 41 (2026-10-14): no minor track; `listBps` 7,500 applies to merged items.
e. Measured, 500 a day for 7 days at cooldown 0: 40 rotates (all GrailStep), 174 settles,
   refunds 0.043 ETH against 1.04 ETH of maintenance inflow; NAV per share 1.0408; listed items
   average 91. At 100 a day: 21 rotates, 117 settles, 0.024 ETH refunds against 0.33 ETH.
f. Lab, 365 days at 500 a day and 1 gwei: keeper cost 34 ETH fully refunded from 62.5 ETH of
   maintenance; the bucket runs dry above about 3 gwei because the per-item mint and list gas
   (about 27 ETH per gwei per year) is structural. Decided (spec author, 2026-10-13):
   `maintenanceBps` stays 100; `fundMaintenance()` (payable, anyone) lets the operator top the
   bucket up from Shapes mint fee revenue, which at 1 gwei is about six times the gas per item
   and at 6 gwei about equal. Break-even without top-ups is about 2 gwei.

## Guesses taken during the run

Every entry carries its status in the title: decided (folded into SPEC), superseded by an owner decision, or deferred (entry 35).
No entry is open. A "Superseded by" line under an entry names the entry or SPEC section that replaced it; the entry text is the record of the earlier decision.

0. **The admin and exit surface lives in a delegatecall module. SPEC 3 forbids delegatecall
   libraries; this is the one guess that changes architecture, read it first.** (decided, in SPEC) The feature
   complete Pool measured 29,714 B runtime under via_ir, 5,138 B over EIP-170, with every
   SPEC function present and all suites green. Measured per group: admin setters 3,269 B
   (`setMix` alone 1,515), `sweep` plus `adminCall` 1,126, exit export side 2,706, successor
   import side 1,688, GRAIL compose 862. Merging setters saves 170 B, a generic `setParam` is
   larger, optimizer runs save 146 B, dropping events 88 B. Guess taken: `PoolAdmin.sol`, a
   module contract that inherits the same `PoolStorage` layout as `Pool`, reached through
   Pool's `fallback` by delegatecall; it holds the setters, `sweep`, `adminCall`, `startExit`,
   `exportStep`, `transferGrailEstate` and the successor import functions. Hot paths (deposit,
   withdraw, pull, settle, rotate, GRAIL, liquidate) stay in `Pool`. The alternative that keeps
   one contract: cut GRAIL compose (862), replace `setMix` with `setRowShare` plus `addRow`
   (about 1,000), reduce `adminCall`'s post-check to I1 plus unchanged `backing` (about 500),
   and move migration to ETH value instead of tokens (about 2,100); that lands near 24.5 KB with
   no room for any later fix. Place: `src/PoolAdmin.sol`, `src/PoolStorage.sol`, `Pool.fallback`.

1. **Harvest equality versus direct purchases.** (decided, in SPEC) SPEC 9 step 4 says the harvested amount must
   equal booked receivables. Direct FWA purchases (SPEC 12) have no recorded base, so equality is
   unreachable. Guess: `_harvest` writes ordinary receivable down by the gap and emits `HarvestShortfall` when `received < expected` (spec author review, 2026-10-13); the surplus is booked
   as margin for the direct captures that were booked with zero proceeds. After the packet 3
   review the surplus is also booked at the end of every `settle` from `ownerProceeds()`, so a
   direct capture never depresses NAV between settle and harvest. Place: `Pool._bookSurplus`.
   Proposed SPEC 9 step 4 wording: "received must be at least the booked receivables; the
   difference is the proceeds of direct purchases and enters the margin."
   Superseded by entry 40 (2026-10-14): the pool is the FWA `purchaseOperator`, so the surplus arises only from a
   purchase the pool did not record (the operator cleared through `adminCall`).

1b. **Share pricing follows the books.** (decided, in SPEC) FWA processes acquisitions permissionlessly and VRF words
   are public once Ready, so a depositor could exit at a pre-loss NAV. Guess: `deposit`,
   `withdraw` and `redeemAndDeposit` first process, settle, require the walk to be
   caught up, and harvest. SPEC 7 does not say this. Place: `Pool._sync`.

2. **Mint line inside the margin split.** (decided, in SPEC) SPEC 9 step 2 reserves the mint line in cash and step 3
   splits margin three ways (premium, maintenance, feed) with no mint line share. Three ways
   underfunds replacement mints by `mintFee` per capture. Guess: positive margin first covers
   `mintLineOwed` (sum of replacement mint fees of booked captures) and the rest splits three
   ways. Place: `Pool._splitMargin`. Proposed SPEC 9 step 3 wording: "margin first repays the
   mint line owed, then splits pro rata by premium, maintenance, feed."

3. **Pending deliveries never block settlement.** (decided, in SPEC) A direct `acquire(purchaser = Shapes)` makes
   delivery of a Shape impossible and only the purchaser can refund it, so one ticket could
   freeze a head-of-line walk. A bounded pending set was tried and rejected: 32 tickets would
   stall every pull for 14 days. Guess: `_settle` writes a DeliveryPending capture off at once
   (backing and margin fall by the value, no proceeds, no replacement) and advances. FWA delivers
   with plain `transferFrom`, so on mainnet the only failing recipient is the collection itself,
   and neither retry nor refund can ever run for it. If a delivery does complete later, FWA's
   owner proceeds reach the pool as harvest surplus into margin, which is the same end state as a
   normal capture. If the purchaser refunds later, the admin recovers the token through
   `adminCall(recoverRefundedNFT)` plus `sweep`. Place: `Pool._settle`. SPEC 9 should name the
   write-off rule.

4. **`minItems` and `grailProbCapBps` are constructor parameters.** (decided, in SPEC) SPEC 9 uses both, SPEC 5
   lists neither. Added to `Params` with a setter for each in the admin packet. Place:
   `Pool.Params`.

5. **`openingDeadline` is a duration.** (decided, in SPEC) SPEC 5 says 24 h after FWA pool creation. Stored as the
   duration; `createFwaPool` sets `openingDeadlineAt`. Place: `Pool.createFwaPool`.

6. **FWA slippage parameter. (superseded)** `pull` passes `fwaPool.selectionSlippageBps()` as the purchaser's
   `maxNegativeSlippageBps`. SPEC 8 gives `pull` no slippage argument. On a thin board a batch
   can have later requests refunded by FWA for slippage; those book nothing. Place: `Pool._pull`.
   Superseded by owner decision 2: `acquire` and `acquireBatch` take the caller's `maxNegativeSlippageBps` and forward it.

7. **Upkeep slice holds instead of listing.** (decided, in SPEC) FWA restarts the purchase cooldown on every
   `listNFT`, staged or not. Listing inside `pull` would lock purchases for 300 s after every
   ticket. Guess: the slice mints one replacement and holds it; `rotate` lists held items.
   Place: `Pool._pull`. SPEC 10 wording "mint and list" should become "mint; list at rotate".

10. **FWA slippage is a free option for buyers.** (decided, in SPEC) FWA re-prices each request at processing: a
   fee rise up to `selectionSlippageBps` (10 percent, fixed at clone init) is filled, a fee drop
   beyond the purchaser's tolerance is refunded. On a thin board one capture moves the harmonic
   mean by several percent, comparable to the edge. The pool cannot change the positive side.
   Guess: keep `pull` as is and treat a deep board (`minItems` well above `concurrency` and
   batch size) as the mitigation; log for a later SPEC decision on setting the operator.

11. **Residual NAV after a full exit goes to the next depositor.** (decided, in SPEC) `sharesFor` mints 1:1 when
   `totalShares == 0` whatever NAV is. Premium margin or a recovered token can leave NAV above
   zero with no shares. Guess: accepted for v1, amount is small and the pool is retired through
   `startExit` in practice. Place: `PricingLib.sharesFor`.

12. **Replacement mint fees leave NAV at mint time, not at capture.** (decided, in SPEC) A holder who exits between
   a capture and its replacement mint avoids `mintFee` (0.001 ETH on mainnet) per capture. Guess: accepted
   for v1 as rounding-scale. A `queuedMintFees` term subtracted in `nav()` would close it.

13. **Recovered tokens are not re-registered.** (decided, in SPEC) A token the admin recovers through `adminCall`
   after a purchaser refund is outside `backing`; `sweep` sends it out. Guess: no re-register
   admin path in v1, the admin redeems it and deposits the ETH if it should return to NAV.

9. **`purchaseOperator` left unset (SPEC 12, pending owner confirmation).** (superseded) FWA's own UI can
   acquire from the pool directly; the pool books those captures at the next `settle` with zero
   proceeds and the harvest surplus repays them (entry 1). Setting the operator to the pool would
   close direct buys and make harvest equality exact again. Superseded by owner decision 2: `createFwaPool` sets the pool as
   the operator (entries 34 and 40). Place: `Pool.createFwaPool`.

14. **Launch values in `script/env/*.env`.** (decided, in SPEC) The launch profile (old repo,
   `project/launch-profile.json`) gives premium 200, maintenance 100, feed 400, entry base 1,100, slope 2,000, cap 2,500,
   reference 55 ETH, GRAIL target 25 ETH, decay 0.001 ETH per pull, notional floor 1 ETH, list start 75 percent, merge
   policy (no minor share), opening window 24 h, restock interval 60 min. Decided values:
   - Owner decision 5 (2026-10-13): `MIN_ITEMS=100`, `NAV_CAP_WEI=100 ether`, mix `0.01 Shape 38 percent, 0.02 pack 28,
     0.03 pack 19, 0.05 Shape 10, 0.1 Shape 4, 0.5 Shape 1`, `ROTATE_INTERVAL_SECONDS=3600`, `REPRICE_MIN_BPS=100`.
   - Kept by the owner from the guesses: `minorShareBps` 2,000; minor track target 1 ETH, step 0.1 ETH, floor 0.25 ETH;
     major track target 25 ETH, step 0.5 ETH, floor 1 ETH; both `listBps` 7,500; `grailProbCapBps` 1,000.
   Place: `script/env/mainnet.env` (and anvil, sepolia). Edit the values, the deploy reads them.
   Superseded by entry 39 (2026-10-14) for the entry fee and the deposit cap (`NAV_CAP_WEI` is replaced by
   `NAV_CAP_FLOOR_WEI` and `TURNOVER_BPS`), by entry 41 (2026-10-14 and 2026-10-15) for GRAIL (one fund, no tracks,
   no `minorShareBps`, floors 1 ETH), and by SPEC 5 for `ROTATE_INTERVAL_SECONDS` (900). `REPRICE_MIN_BPS` is removed.

15. **Retirement folds `maintenance` into `cash`.** (decided, in SPEC) SPEC 13 moves maintenance to a successor and
   says nothing for retirement. Guess: at the final `exportStep` of a retirement, `cash +=
   maintenance`, so depositors receive it. Place: `Pool.exportStep`.

16. **Successor row matching on import.** (decided, in SPEC) SPEC 13 says imported tokens are registered by reading
   `valueOf` and denominations. Guess: `importItem` picks the first successor mix row with equal
   backing and matching pack-ness and reverts `NoMatchingRow` otherwise, so a migration plan must
   give the successor a mix that covers the old rows. Place: `Pool.importItem`.

17. **Imported shares are priced at the successor's NAV per share.** (decided, in SPEC) `finalizeImport` mints
   `importedNav * totalShares / navBefore` (1:1 when the successor has no shares) and
   `migrateHolder` divides them by `exportedShares`. Rounding dust stays unassigned. Place:
   `Pool.finalizeImport`.

18. **FWA locks starve liquidation and GRAIL work under steady pull flow.** (decided, in SPEC) `withdrawListing` and
   `updatePrice` revert while any acquisition is unsettled. With a pull every VRF latency the
   count never reaches zero, so liquidation, GRAIL growth and decay reprice wait for a gap. One
   ticket plus VRF fee per interval keeps the gap closed. This follows from FWA and SPEC 7.
   Guess: accepted for v1; the admin can pause pulls to open a gap. Record for a SPEC note.

19. **`growGrail` is public and each call relists, which restarts FWA's 300 s purchase cooldown.** (superseded by 37)
   Bounded by one bucket step per call. Guess: accepted; gate behind `rotateInterval` if abused.

20. **I5 holds in the books, not in expectation.** (decided, in SPEC) A GRAIL listed above the harmonic mean raises
   the ordinary ticket and so ordinary margin, funded by the track's expected loss. This is the
   product's design (the feed pays for a prize that makes tickets dearer). Recorded for the SPEC.

21. **`open()` runs restock only, not the full `rotate`.** (decided, in SPEC) GRAIL growth and decay start one
   interval after open. SPEC 6 says open runs the first rotate. Guess: restock is the part of
   rotate that builds the board; the GRAIL step waits for funding anyway. Place: `Pool.open`.

22. **Decay reprice runs after growth, and is skipped when the track grew.** (decided, in SPEC) SPEC 11 orders decay
   first. End state is identical because growth resets price and the pull counter.

23. **Pool.sol compiles with via_ir. SPEC 3 says under 24KB without via_ir and no delegatecall
   libraries; both cannot hold with the SPEC's feature set.** (decided, in SPEC) Measured at packet 6 (1,673 lines,
   before admin setters, sweep, adminCall): legacy codegen 26,166 B runtime (over EIP-170),
   via_ir 22,907 B. The SPEC's own remedies are exhausted: pure math already sits in PricingLib
   (internal libraries do not shrink bytecode) and every diagnostic view moved to the test harness
   with Lens reading public getters. Note: Pool has compiled under via_ir since packet 3a because
   the `lib/draw-packs/src/**` restriction in foundry.toml also covers the `IShapePacks` interface
   Pool imports; the director added that glob and did not notice until packet 6. Guess taken:
   keep via_ir for Pool (standard pipeline, no storage-layout coupling), make it explicit in
   foundry.toml, and record it in SPEC 3. Alternatives: a delegatecall library for exit and admin
   (about 4 KB, SPEC forbids), or dropping functions (none are optional under SPEC). Place:
   `foundry.toml`.

24. **`withdraw` is closed during a migration.** (decided, in SPEC) After `startExit(successor)` moved items leave the
   old pool's NAV before the successor has minted shares, so a withdrawal between export steps
   is underpaid and the remainder lands on migrators. Guess: `withdraw` reverts during a
   migration; `migrateHolder` is the only exit, queued claims still pay through `payClaims`.
   Retirement keeps `withdraw`. SPEC 13 should say so. Place: `Pool.withdraw`.

25. **Deposits and withdrawals on a successor pause while an import is open.** (decided, in SPEC) Imported items
   enter NAV before `finalizeImport` mints their shares. Guess: `deposit`, `redeemAndDeposit`
   and `withdraw` revert `ImportInProgress` from the first import until finalize. Place:
   `Pool._deposit`, `Pool.withdraw`.

26. **Items the successor cannot register are redeemed, not moved.** (decided, in SPEC) `importItem` needs a
   matching row; the old pool asks `canImport` first and redeems locally into cash when false,
   so the export cannot brick on a mix mismatch. Place: `Pool.exportStep`.

27. **`startExit` disables FWA purchases.** (decided, in SPEC) Otherwise a direct buyer keeps the FWA pool busy and
   every `exportStep` reverts. SPEC 13 says pulls close; FWA's own buy path must close too.

28. **Admin trust in the exit.** (decided, in SPEC) `adminCall` on the old pool can reach the successor's import
   functions with arbitrary arguments. Double import is blocked by a registry check; cash
   imports cost the admin their own ETH; a forged `finalizeImport` could misprice migration. The
   admin is trusted in SPEC 2, so this is recorded, not blocked.

29. **Migration dust.** (decided, in SPEC) `migrateHolder` rounds down per holder, so a few wei of shares stay
   unassigned in the successor's `totalShares`, which keeps NAV per share conservative.

30. **Sepolia FWA values were read live.** (decided, in SPEC) The carried `sepolia.env` implementation and VRF service
   did not match the factory in `dependencies.json`; the deploy worker filled them from the
   factory's `implementation()` and `vrfService()` on 2026-10-13. `DRAW_PACKS` is empty on
   Sepolia (the recorded collections are three-unit), so the wrapper refuses until a two-unit
   Draw Packs is deployed there. Place: `script/env/sepolia.env`.

31. **Anvil pool creation impersonates the FWA factory owner.** (decided, in SPEC) On the mainnet fork the factory
   charges 50,000 FWA and allows one pool per wallet; with `CREATE_POOL=1` the wrapper sets the
   fee to `EXPECTED_CREATION_FEE`, lifts the beta gate and raises the wallet limit, anvil only.
   On mainnet the admin needs allowance and the FWA token fee before `createFwaPool`.

32. **Purchase pause cadence.** (superseded by 37) FWA restarts its purchase pause on every inventory change
   (`listNFT`, `updatePrice`, `withdrawListing`). The pool restarts it at most once per
   interval: `rotate`, `growGrail` and the listing-withdrawing part of `liquidate` share the
   `rotateInterval` gate (`lastRotateAt`), so the pause restarts at most once per interval. The GRAIL
   decay reprice runs only when the price falls by at least `repriceMinBps` of the current price,
   launch value 100 (1 percent), so decay does not restart the pause for small steps. Place:
   `Pool.rotate`, `Pool.growGrail`, `Pool._liquidateForClaims`, `Pool._rotateGrail`,
   `script/env/*.env` (`REPRICE_MIN_BPS`).

8. **Launch `minItems` must exceed `concurrency`.** (decided, in SPEC) FWA `maxOutstandingRequestsPerPool` is 10 on
   mainnet. With `minItems` 10 the board is `BoardTooThin` after the first capture until the
   replacement is listed. Resolved by `MIN_ITEMS=100` (entry 14).

33. **GRAIL probability cap is enforced by price in `rotate`.** (decided, in SPEC) Owner decision 3. The purchase path has
   no `GrailProbTooHigh` revert. `rotate` lifts a track's notional toward `backing * listBps / 10_000` when the listed
   GRAIL weight exceeds `grailProbCapBps`, the mirror of decay. Decay keeps its cap check. Place: `Pool._rotateGrail`,
   `Pool._liftedNotional`. SPEC 9 and 11.
   Superseded by entry 41 (2026-10-14): the lift is removed; the item keeps its price when the cap binds (SPEC 11).

34. **FWA-shaped purchase ABI.** (decided, in SPEC) Owner decision 2. The pool exposes `acquire`,
   `acquireBatch` and `quoteAcquisitionPrice`; `purchaser` must equal the caller; the caller's slippage, minimum weighted
   value, inventory version and deadline are forwarded; `pullWithShapes` uses the pool defaults. `createFwaPool` sets the
   pool as `purchaseOperator`; `canPurchase` is true only inside the pool's forwarding call. Entry 40 fixes the operator.
   Place: `Pool.acquire`, `Pool.acquireBatch`, `Pool.canPurchase`. SPEC 8.

35. **Relisting an unlisted GRAIL pack whose decayed price breaks the cap.** (deferred) In `_rotateGrail`
   an unlisted pack whose decayed price would exceed `grailProbCapBps` stays unlisted until the board
   deepens. Trying the face price `backing * listBps / 10_000` before giving up would relist sooner.
   Spec author's second pass, 2026-10-13: low, not worth Pool's remaining margin in v1.
   Superseded by entry 41 (2026-10-14): `_rotateGrail` and GRAIL packs per track are removed; `PoolListing.grailStep`
   and `grailReprice` own the GRAIL step.

36. **Size plan for a future Pool change.** (decided) Pool is 23,711 B of 24,576. The first lever when
   a Pool change is required: move the views `rowCount`, `mixLength`, `listedRowCount` and `mixRow`
   into `PoolAdmin`, reachable through the fallback, which frees several hundred bytes with no ABI
   change. Any Pool change is a redeploy, so the margin is accepted for v1. After entry 37 Pool is 24,330 B, 246 B under
   the limit, and the views stay in `Pool`.
   Superseded by SPEC 3: the row, queue and parameter getters live in `PoolListing`, and the current sizes are in SPEC 3.

37. **Demand-triggered rotate.** (decided, in SPEC) Owner decision 8. `rotate()` runs once `rotateInterval` (launch
   900 s, the minimum spacing between inventory changes) has passed since `lastRotateAt` and a trigger holds: Weight,
   GrailCap, Claim, GrailStep, Restock or Quiet, in that order. `rotateDue()` returns the first trigger that holds.
   `liquidate()` and `growGrail()` are removed; claim liquidation and GRAIL growth run inside `rotate`. Reason: an
   hourly relist let the GRAIL's selection share climb all hour, because captured listings left FWA's weight while
   their replacements waited for the next relist, so late-hour play had better odds. The Weight trigger bounds the
   drift to `restockTriggerBps` (launch 1,000) of the ordinary weight and follows demand; `quietIntervalSeconds`
   (launch 43,200) bounds the idle gap. Griefing analysis: the Claim trigger needs a fully deployed pool, so a caller
   must queue a claim by depositing and every setup deposit loses the entry contribution. The GrailStep trigger costs
   about 0.11 ETH per FWA pause, a deposit large enough to fund one step through the contribution. A rotate whose
   work is blocked or already done leaves `lastRotateAt`, the FWA pause and `maintenance` as they were. Restock fires
   when the listed count is `restockTriggerBps` below the target depth and a held item or spendable cash exists. Quiet
   measures from `lastRotateCallAt`, which every successful `rotate` call sets. The worst case is a large
   legitimate exit, bounded by the spacing and the 25 item slice. Place: `Pool.rotate`, `Pool.rotateDue`,
   `Pool._rotateTrigger`, `PoolAdmin.setRestockTriggerBps`, `PoolAdmin.setQuietInterval`, `script/env/*.env`
   (`ROTATE_INTERVAL_SECONDS`, `RESTOCK_TRIGGER_BPS`, `QUIET_INTERVAL_SECONDS`). SPEC 5, 7, 9, 10, 11, 14.
   Superseded by owner decision 10b (2026-10-13) and SPEC 9: the reasons are Claim, GrailStep and Held. Weight,
   GrailCap, Restock and Quiet, `setRestockTriggerBps` and `setQuietInterval` no longer exist.

38. **`payClaims()` pays queued claims in every lifecycle state.** (decided, in SPEC) Removing
   `liquidate()` was the only function that paid queued claims to an Exiting or Exported pool, because `rotate` requires
   Live. `payClaims()` pays from `cash` in FIFO order, at most 20 entries per call, and leaves items alone. Place:
   `Pool.payClaims`. Built; SPEC 7 and 13.

39. **Admission rules.** (decided, in SPEC) Owner decisions of 2026-10-14 for `deposit()`. Cap: `navCap()` is
   `max(navCapFloor, dailyVolume() * 10_000 / turnoverBps)`, with `navCapFloor` 69 ETH and `turnoverBps` 1,250
   (`docs/VOLUME_CAP.md`). Entry fee: floor 10 percent, cap 25 percent, payback 20 days of depositor yield; entries 5 and
   14 record the values of 2026-10-12 and 2026-10-13. Founder window: 30 days (2,592,000 s) from the transition to
   Live, during which `deposit()` reverts `DepositsClosed`. Place: `Pool._deposit`, `Pool.navCap`, `Pool.dailyVolume`, `PoolBooks._walk`,
   `PoolAdmin.setEntryFee`, `setNavCapFloor`, `setTurnover`, `setFounderWindow`, `Lens.admission`,
   `script/env/*.env` (`NAV_CAP_FLOOR_WEI`, `TURNOVER_BPS`, `ENTRY_FLOOR_BPS`, `ENTRY_CAP_BPS`, `ENTRY_PAYBACK_DAYS`,
   `FOUNDER_WINDOW_SECONDS`). SPEC 5 and 7.

40. **Purchase operator is fixed.** (decided, in SPEC) Owner decision of 2026-10-14. The pool is the FWA
   `purchaseOperator` from `createFwaPool` and every ticket is bought through `acquire`, `acquireBatch` or
   `pullWithShapes` on the pool. `setPurchaseGate(bool)` is removed. The FWA site calls the pool's purchase ABI.
   Place: `PoolAdmin.createFwaPool`, `Pool.canPurchase`. SPEC 8.

41. **GRAIL merge mode.** (decided, in SPEC) Owner decision of 2026-10-14. One fund and one ladder replace the minor and
   major tracks. The fund mints 1 ETH pieces, at most 6 pieces and 16 items at once and 3 mints per rotate. Merges
   build 5 ETH (five pieces), 10 ETH (two 5 ETH), 25 ETH (two 10 ETH and one 5 ETH, a Draw Pack), 50 ETH (two 25 ETH)
   and 100 ETH (two 50 ETH) up to the cycle target; the output backing equal to the target completes the cycle. Launch
   values: target 25 ETH, `listBps` 7,500, decay 0.001 ETH per pull, piece floor 1 ETH, floor 1 ETH
   (`GRAIL_TARGET_WEI`, `GRAIL_LIST_BPS`, `GRAIL_DECAY_WEI_PER_PULL`, `GRAIL_PIECE_FLOOR_WEI`, `GRAIL_FLOOR_WEI`).
   `minorShareBps` is removed: the whole entry contribution and the feed share go to the fund. Two chosen behaviours:
   a sixth piece may stay listed after the 5 ETH merge (the recipe takes any five pieces), and a completed GRAIL stays
   listed while the next cycle builds. The completed item carries a `done` flag so it is not a merge input. Place:
   `PoolListing.grailStep`, `grailReprice`, `PoolBooks._capture`, `PoolListing.setGrail`-family. SPEC 5, 11 and 13.
   2026-10-15 floor decision: `pieceFloorWei` and `floorWei` are both 1 ETH, so a piece lists at face and a merged item decays to 1 ETH.
   Earlier steps on the same day: piece floor 0.25 ETH with floor 0.1 ETH (floor lowered from 1 ETH because, on a
   NAV-deep board, a finished GRAIL at 1 ETH was one draw in 80,000 and sat unclaimed; at 0.1 ETH the lab year showed
   a 25 ETH win about every 61 days at 500 tickets a day), then the 1 ETH values above.
   Done items are capped apart from building items (`MAX_DONE_ITEMS` 32, `MAX_BUILDING_ITEMS` 16) so finished GRAILs do not stall the fund.
   Ladder step: a cycle under `stepUpSeconds` (14 days) moves `nextTargetWei` one rung up, one over `stepDownSeconds` (60 days) one rung down (`setGrailStep`).

42. **Board depth follows NAV.** (decided, in SPEC) Owner decision of 2026-10-14. `boardItems() = max(minItems, (nav -
   nav * reserveBps / 10_000) / meanRowCost)`, with `nav` the ordinary NAV (already net of `claims`) and `meanRowCost`
   the share-weighted cost of a mix row at the current Shapes mint fee: its backing plus the mint fee of each rung. The
   target depth of a row is `ceil(boardItems() * shareBps / 10_000)` in `open`, the replacement draw and `Lens.board`.
   A row at or past its band cap is redirected to the row of largest deficit, so a row above target gets no replacement
   until it is below it; nothing is delisted when NAV falls. A surprise upgrade only lands on a single rung row below
   its target. New settle trigger `Deep`: the listed, held and queued ordinary items are fewer than `boardItems()` by at
   least `batchMin`. `settle` on `Deep` queues each row's missing items (up to 25 entries in total per call,
   existing queue entries included) and lists at most 25. `open()` goes Live as before, on the first call that lists fewer than 20 items or once `listedCount` is at least `minItems`.
   No new parameter. Place: `PoolBooks._boardItems`, `PoolStorage._setMix`, `PoolListing._queueMissing`,
   `Pool.settleDue`, `Pool.settle`, `PricingLib.chooseRow`, `PoolListing.boardItems`, `Lens.parameters`. SPEC 9.
