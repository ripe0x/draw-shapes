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

8. **Launch `minItems` must exceed `concurrency`.** FWA `maxOutstandingRequestsPerPool` is 10 on
   mainnet. With `minItems` 10 the board is `BoardTooThin` after the first capture until the
   replacement is listed. Not a code change; a launch-profile note.
