# Owner questions and the guesses taken

Date: 2026-10-13. Director log for the unattended run through packets 3 to 7. Each entry states
the question, the guess the build follows, and where it is applied. Reverse any entry by editing
the named place; none of them is load bearing for the others unless the entry says so.

## Settled before the run (owner answered 2026-10-12)

- I1 drops `claims`. Applied in SPEC 4 and `Pool.sol` header.
- Settlement books `paid - (paid - base) / 2` per Fulfilled acquisition with `base` recorded at
  `pull`. Applied in `_pull` and `_settle`.
- Draw Packs deploy from `lib/draw-packs` in fork setup. Applied in `ForkBase.deployDrawPacks`.
- `purchaseOperator` stays unset (pending owner confirmation). Applied: `createFwaPool` never
  calls `setPurchaseOperator`.

## Guesses taken during the run

0. **The admin and exit surface lives in a delegatecall module. SPEC 3 forbids delegatecall
   libraries; this is the one guess that changes architecture, read it first.** The feature
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

1. **Harvest equality versus direct purchases.** SPEC 9 step 4 says the harvested amount must
   equal booked receivables. Direct FWA purchases (SPEC 12) have no recorded base, so equality is
   unreachable. Guess: `_harvest` reverts only when `received < expected`; the surplus is booked
   as margin for the direct captures that were booked with zero proceeds. After the packet 3
   review the surplus is also booked at the end of every `settle` from `ownerProceeds()`, so a
   direct capture never depresses NAV between settle and harvest. Place: `Pool._bookSurplus`.
   Proposed SPEC 9 step 4 wording: "received must be at least the booked receivables; the
   difference is the proceeds of direct purchases and enters the margin."

1b. **Share pricing follows the books.** FWA processes acquisitions permissionlessly and VRF words
   are public once Ready, so a depositor could exit at a pre-loss NAV. Guess: `deposit`,
   `withdraw`, `redeemAndDeposit` and `liquidate` first process, settle, require the walk to be
   caught up, and harvest. SPEC 7 does not say this. Place: `Pool._sync`.

2. **Mint line inside the margin split.** SPEC 9 step 2 reserves the mint line in cash and step 3
   splits margin three ways (premium, maintenance, feed) with no mint line share. Three ways
   underfunds replacement mints by `mintFee` per capture. Guess: positive margin first covers
   `mintLineOwed` (sum of replacement mint fees of booked captures) and the rest splits three
   ways. Place: `Pool._splitMargin`. Proposed SPEC 9 step 3 wording: "margin first repays the
   mint line owed, then splits pro rata by premium, maintenance, feed."

3. **Pending deliveries never block settlement.** A direct `acquire(purchaser = Shapes)` makes
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

4. **`minItems` and `grailProbCapBps` are constructor parameters.** SPEC 9 uses both, SPEC 5
   lists neither. Added to `Params` with a setter for each in the admin packet. Place:
   `Pool.Params`.

5. **`openingDeadline` is a duration.** SPEC 5 says 24 h after FWA pool creation. Stored as the
   duration; `createFwaPool` sets `openingDeadlineAt`. Place: `Pool.createFwaPool`.

6. **FWA slippage parameter.** `pull` passes `fwaPool.selectionSlippageBps()` as the purchaser's
   `maxNegativeSlippageBps`. SPEC 8 gives `pull` no slippage argument. On a thin board a batch
   can have later requests refunded by FWA for slippage; those book nothing. Place: `Pool._pull`.
   Consider adding a `maxSlippageBps` argument in a later SPEC edit.

7. **Upkeep slice holds instead of listing.** FWA restarts the purchase cooldown on every
   `listNFT`, staged or not. Listing inside `pull` would lock purchases for 300 s after every
   ticket. Guess: the slice mints one replacement and holds it; `rotate` lists held items.
   Place: `Pool._pull`. SPEC 10 wording "mint and list" should become "mint; list at rotate".

10. **FWA slippage is a free option for buyers.** FWA re-prices each request at processing: a
   fee rise up to `selectionSlippageBps` (10 percent, fixed at clone init) is filled, a fee drop
   beyond the purchaser's tolerance is refunded. On a thin board one capture moves the harmonic
   mean by several percent, comparable to the edge. The pool cannot change the positive side.
   Guess: keep `pull` as is and treat a deep board (`minItems` well above `concurrency` and
   batch size) as the mitigation; log for a later SPEC decision on setting the operator.

11. **Residual NAV after a full exit goes to the next depositor.** `sharesFor` mints 1:1 when
   `totalShares == 0` whatever NAV is. Premium margin or a recovered token can leave NAV above
   zero with no shares. Guess: accepted for v1, amount is small and the pool is retired through
   `startExit` in practice. Place: `PricingLib.sharesFor`.

12. **Replacement mint fees leave NAV at mint time, not at capture.** A holder who exits between
   a capture and its replacement mint avoids `mintFee` (0.0005 ETH) per capture. Guess: accepted
   for v1 as rounding-scale. A `queuedMintFees` term subtracted in `nav()` would close it.

13. **Recovered tokens are not re-registered.** A token the admin recovers through `adminCall`
   after a purchaser refund is outside `backing`; `sweep` sends it out. Guess: no re-register
   admin path in v1, the admin redeems it and deposits the ETH if it should return to NAV.

9. **`purchaseOperator` left unset (SPEC 12, pending owner confirmation).** FWA's own UI can
   acquire from the pool directly; the pool books those captures at the next `settle` with zero
   proceeds and the harvest surplus repays them (entry 1). Setting the operator to the pool would
   close direct buys and make harvest equality exact again. Place: `Pool.createFwaPool`.

14. **Launch values in `script/env/*.env` are guesses where SPEC 5 points at
   `launch-profile.json`.** The profile (old repo, `project/launch-profile.json`) gives: premium
   200, maintenance 100, feed 400, entry base 1,100, slope 2,000, cap 2,500, reference 55 ETH,
   GRAIL target 25 ETH, decay 0.001 ETH per pull, notional floor 1 ETH, list start 75 percent,
   merge policy (no minor share), opening window 24 h, restock interval 60 min. Guesses filling
   the gaps: mix rows `0.01 Shape 40%, 0.02 pack 30%, 0.03 pack 20%, 0.05 Shape 10%`;
   `minorShareBps` 2,000 with a minor track of target 1 ETH, step 0.1 ETH, floor 0.25 ETH, and a
   major track of target 25 ETH, step 0.5 ETH, floor 1 ETH, both `listBps` 7,500; `navCap`
   unlimited (`type(uint256).max`); `minItems` 30; `grailProbCapBps` 1,000. Place:
   `script/env/mainnet.env` (and anvil, sepolia). Edit the values, the deploy reads them.

15. **Retirement folds `maintenance` into `cash`.** SPEC 13 moves maintenance to a successor and
   says nothing for retirement. Guess: at the final `exportStep` of a retirement, `cash +=
   maintenance`, so depositors receive it. Place: `Pool.exportStep`.

16. **Successor row matching on import.** SPEC 13 says imported tokens are registered by reading
   `valueOf` and denominations. Guess: `importItem` picks the first successor mix row with equal
   backing and matching pack-ness and reverts `NoMatchingRow` otherwise, so a migration plan must
   give the successor a mix that covers the old rows. Place: `Pool.importItem`.

17. **Imported shares are priced at the successor's NAV per share.** `finalizeImport` mints
   `importedNav * totalShares / navBefore` (1:1 when the successor has no shares) and
   `migrateHolder` divides them by `exportedShares`. Rounding dust stays unassigned. Place:
   `Pool.finalizeImport`.

18. **FWA locks starve liquidation and GRAIL work under steady pull flow.** `withdrawListing` and
   `updatePrice` revert while any acquisition is unsettled. With a pull every VRF latency the
   count never reaches zero, so liquidation, GRAIL growth and decay reprice wait for a gap. One
   ticket plus VRF fee per interval keeps the gap closed. This follows from FWA and SPEC 7.
   Guess: accepted for v1; the admin can pause pulls to open a gap. Record for a SPEC note.

19. **`growGrail` is public and each call relists, which restarts FWA's 300 s purchase cooldown.**
   Bounded by one bucket step per call. Guess: accepted; gate behind `rotateInterval` if abused.

20. **I5 holds in the books, not in expectation.** A GRAIL listed above the harmonic mean raises
   the ordinary ticket and so ordinary margin, funded by the track's expected loss. This is the
   product's design (the feed pays for a prize that makes tickets dearer). Recorded for the SPEC.

21. **`open()` runs restock only, not the full `rotate`.** GRAIL growth and decay start one
   interval after open. SPEC 6 says open runs the first rotate. Guess: restock is the part of
   rotate that builds the board; the GRAIL step waits for funding anyway. Place: `Pool.open`.

22. **Decay reprice runs after growth, and is skipped when the track grew.** SPEC 11 orders decay
   first. End state is identical because growth resets price and the pull counter.

23. **Pool.sol compiles with via_ir. SPEC 3 says under 24KB without via_ir and no delegatecall
   libraries; both cannot hold with the SPEC's feature set.** Measured at packet 6 (1,673 lines,
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

24. **`withdraw` is closed during a migration.** After `startExit(successor)` moved items leave the
   old pool's NAV before the successor has minted shares, so a withdrawal between export steps
   is underpaid and the remainder lands on migrators. Guess: `withdraw` reverts during a
   migration; `migrateHolder` is the only exit, queued claims still pay through `liquidate`.
   Retirement keeps `withdraw`. SPEC 13 should say so. Place: `Pool.withdraw`.

25. **Deposits and withdrawals on a successor pause while an import is open.** Imported items
   enter NAV before `finalizeImport` mints their shares. Guess: `deposit`, `redeemAndDeposit`
   and `withdraw` revert `ImportInProgress` from the first import until finalize. Place:
   `Pool._deposit`, `Pool.withdraw`.

26. **Items the successor cannot register are redeemed, not moved.** `importItem` needs a
   matching row; the old pool asks `canImport` first and redeems locally into cash when false,
   so the export cannot brick on a mix mismatch. Place: `Pool.exportStep`.

27. **`startExit` disables FWA purchases.** Otherwise a direct buyer keeps the FWA pool busy and
   every `exportStep` reverts. SPEC 13 says pulls close; FWA's own buy path must close too.

28. **Admin trust in the exit.** `adminCall` on the old pool can reach the successor's import
   functions with arbitrary arguments. Double import is blocked by a registry check; cash
   imports cost the admin their own ETH; a forged `finalizeImport` could misprice migration. The
   admin is trusted in SPEC 2, so this is recorded, not blocked.

29. **Migration dust.** `migrateHolder` rounds down per holder, so a few wei of shares stay
   unassigned in the successor's `totalShares`, which keeps NAV per share conservative.

30. **Sepolia FWA values were read live.** The carried `sepolia.env` implementation and VRF service
   did not match the factory in `dependencies.json`; the deploy worker filled them from the
   factory's `implementation()` and `vrfService()` on 2026-10-13. `DRAW_PACKS` is empty on
   Sepolia (the recorded collections are three-unit), so the wrapper refuses until a two-unit
   Draw Packs is deployed there. Place: `script/env/sepolia.env`.

31. **Anvil pool creation impersonates the FWA factory owner.** On the mainnet fork the factory
   charges 50,000 FWA and allows one pool per wallet; with `CREATE_POOL=1` the wrapper sets the
   fee to `EXPECTED_CREATION_FEE`, lifts the beta gate and raises the wallet limit, anvil only.
   On mainnet the admin needs allowance and the FWA token fee before `createFwaPool`.

8. **Launch `minItems` must exceed `concurrency`.** FWA `maxOutstandingRequestsPerPool` is 10 on
   mainnet. With `minItems` 10 the board is `BoardTooThin` after the first capture until the
   replacement is listed. Not a code change; a launch-profile note.
