# Implementor decisions

A running list of every decision the build brief (`docs/BUILD_PROMPT.md` and the task text it was
issued with) left open, with what was chosen, why, and the alternative. It also records what was
found to contradict the brief. The owner reviews this once at the end. Numbering is stable;
entries are appended, never renumbered.

## Process and sources

**D1. Branch.** The task text names `claude/relaxed-goodall-mmbzpd`; the session that ran the build
was assigned `claude/draw-shapes-ethereum-4405vp` by its harness and may push only there. The work
starts from `origin/claude/relaxed-goodall-mmbzpd` (which carries `docs/BUILD_PROMPT.md`) and is
pushed to `claude/draw-shapes-ethereum-4405vp`. Alternative: push to the brief's branch, which the
session is not permitted to do.

**D2. Two versions of the brief.** The committed `docs/BUILD_PROMPT.md` (commit 4d3e811) adds module
seams the task text does not have (`GameRevenueRouter`, `ConversionPolicy`, `TipPolicy`, `SwapPolicy`,
`EngineBuyer`) and drops `allowNoBonus`. The task text is authoritative where they differ. Taken
from the committed version, because they serve section 2 without adding a holder: `SwapPolicy`
(the task text already calls the hook's fee policy a decider) and `EngineBuyer` (one buy path for
conversion, both buybacks and nothing else). Not taken: `GameRevenueRouter`, `ConversionPolicy` and
`TipPolicy` as separate contracts. FwaGame sends the markup line to `KeeperFund` and the margin line
to `Treasury` (both addresses timelock-settable); the conversion bonus rate lives in `PricingPolicy`;
the tip formula lives in `KeeperFund` with bounded parameters, as the task text's section 4.6 has it.
Alternative: build all five modules; more contracts and more wiring for no new decision surface.

**D3. Draw Packs.** `0xf21514b0…` on mainnet is "Shape Packs" with `MIN_PACK_VALUE = 0.03 ETH`
(3 units), not the two-unit Draw Packs variant (checked on the fork). Per the brief the launch board
is Shapes only until the owner decides. FwaGame still supports a pack collection (row kind `Pack`,
minted with `createPackTo` and `defaultMakeup`), constructed with the real `0xf215…` address, so a
0.03+ pack row works today and a two-unit Draw Packs deployment would need a new game (the collection
address is immutable in FwaGame). Fork tests exercise the pack path against the real `0xf215…` with a
0.03 pack row. The Shapes-only launch board is in `docs/ECONOMICS.md`.

## FWA integration

**D4. Paying the 50,000 FWA creation fee.** FWA is transfer-locked: wallet-to-wallet transfers revert
unless one side is the token owner, a registered distributor, or the v4 PoolManager under the hook's
transient allowance (verified in the verified FWAToken source, `_afterTokenTransfer`). The deploy
wallet therefore cannot send FWA to FwaGame. Flow: the deploy script calls the stateless helper
`FwaFeeBuyer.buyTo(game, minOut)` with ETH; it buys FWA exact-in on FWA's own v4 pool and takes the
output straight to FwaGame (PoolManager → recipient is allowed). Then anyone calls
`FwaGame.createPool(salt)` once: it approves the factory for the exact live fee, calls
`factory.createPool(salt, fee, expectedImplementation)` (the factory pulls FwaGame → dead address,
which is a distributor) and burns any FWA left over. The pool address is write-once rather than
`immutable` because a contract cannot be the factory's `msg.sender` from its own constructor and
also hold FWA bought through a v4 callback. Alternative: the deploy wallet creates the pool, which
would make the wallet its permanent owner, against section 3.

**D5. `DeliveryPending` halts the walk.** As the brief says. FWA delivers with `transferFrom`
(no receiver hook) of Shapes or Packs, which cannot fail for a non-zero purchaser short of the
collection reverting, so a stuck walk is not expected. The recovery path for `DeliveryRefunded`
is implemented and tested by forcing a delivery failure.

**D6. Epoch finality without an "accepted" counter.** FwaGame cannot observe an acquisition when it
is accepted: purchases go straight to the FWA pool (ours or FWA's own site). Sequences are issued in
block order, so an epoch is final when its last block has passed and the walk has booked every
sequence whose `requestBlock` lies in it (the next unbooked sequence, if any, was requested after the
epoch ended). `epochTotals(e)` returns `(booked, units)`; "accepted" and "resolved" both equal
`booked` once final. Alternative: a purchase operator that counts requests, which the brief rules
out (`purchaseOperator` stays unset).

**D7. Revenue is routed at expectation; variance stays with the house.** The owner proceeds of a pull
are fixed by FWA from the pool's expected value at request time, but the item drawn is random, so
`proceeds − captured backing − mint line` is negative for every large prize. Negative amounts cannot
be routed. For each booked capture FwaGame computes, from the escrowed `paid` and the live `edgeBps`:
`base = paid × 10,000 / (10,000 + edgeBps)` (the listing-price EV), `proceeds = paid − (paid − base)/2`
(FWA's owner split), `markupLine = base × markupBps / (10,000 + markupBps)`, `marginLine = proceeds −
base`, `expectedCost = base − markupLine`. Markup goes to KeeperFund, margin to Treasury, and
`expectedCost` stays in the game as the replacement budget. The realised `expectedCost − (backing +
mint line)` is tracked as signed P&L (`bookedGain`, `bookedLoss`) and is the bankroll's variance.
`markupBps` is the captured listing's own snapshot; while a markup change is rolling through the
board the pool holds mixed markups and the line is approximate. Up to 1 wei per capture of rounding
between this formula and FWA's internal `requestBasePrice` stays in the game.

**D8. FwaGame cranks FWA.** `sync` calls the pool's permissionless `processAcquisitions` before
walking, so keepers drive FWA settlement too.

**D9. Replacement is a board bitmap, not a queue.** Each board row has one bit (live or not). A
capture clears the row's bit; `sync` lists unset rows (up to `BoardPolicy.listBatch()`, ≤ 20) while
the bankroll can pay for them. A board change takes effect as rows are replaced; nothing is
withdrawn to rebalance. Every listing call bumps FWA's `inventoryVersion`, which makes in-flight
purchases with the old version revert, so listing in batches matters more than listing fast.

**D10. Conversion.** Shapes only (the brief's wording); a delivered Pack can be opened and its Shapes
are not convertible. Any holder of a delivered Shape may convert it once (Shapes are transferable;
binding to the original purchaser would add a mapping and stop nothing). With `allowNoBonus` the call
pays whatever the bonus pool holds, possibly zero. The bonus pool is held by GenesisFarm (it already
holds and burns farm ENGINE), so FwaGame never holds ENGINE.

## Token side

**D11. The farm owns the epoch clock.** "A second game registered after retiring the first" means the
ledger cannot be one FwaGame. GenesisFarm holds `openBlock` (set once by the first registered game's
`openGame`) and sums units over up to four registered ledgers. Every game derives epochs from the
farm's `openBlock`, so all ledgers share one clock in blocks. Ledgers can be added, never removed
(removal would change past rewards).

**D12. Taper is fixed on 21 epochs.** `EmissionSchedule.allocationOf(e)` is the 1.5× → 0.5× taper over
the original 21 epochs regardless of shortening; `shorten` cuts the tail and burns the cut epochs at
once. Re-tapering over the shorter length would change epochs already played. The farm snapshots an
epoch's pot when it is first claimed, so a later schedule module cannot change a settled epoch, and
it caps snapshotted genesis allocations at the genesis budget.

**D13. Empty epochs.** Genesis epochs with no units are burned by `retireUnearned`, as the brief says.
A final post-genesis epoch with no units (only deposits or season allocation in it) can be rolled
into the current epoch by anyone (`rollover`), so buyback rewards are never stranded.

**D14. Seasons cannot be cancelled.** `scheduleSeason(startEpoch, epochs, amount)` moves `amount` out
of the reserve into a fixed per-epoch allocation starting at least two epochs out. Cancelling would
need a rule for partly-played seasons; the reserve's only other outflow is `burnReserve`.

**D15. Sinks hold nothing between calls: the Treasury allocates, sinks draw.** Buyback slices
(`sliceWei`, `minSpacing`) mean ETH waits between purchases. To keep "a sink never holds a balance
between calls" true, `Treasury.distribute()` allocates its unallocated balance to sinks by the table
(`owed[sink]`), and each sink's `process` draws at most its owed amount and spends it in the same
call (any unspent ETH goes back to the Treasury). Setting a new table returns every allocation to
the unallocated balance. Outflows from the Treasury still go only to registered sinks.

**D16. KeeperFund is a holder.** It holds the keeper allowance by design (section 4.4). Tips are pushed
with a 50,000 gas stipend; a failed push is credited and withdrawn with `withdrawTips()` (rule 5).
`age` for the bounty is seconds since the job last ran; a call that does no work reverts `NoWork` and
pays nothing. A per-call `gasOverhead` (launch 40,000) covers the intrinsic and calldata gas the
in-call measurement cannot see.

**D17. Anti-snipe applies to buys only and is bounded in the hook.** The hook caps the fee at 500 bps,
except within three hours of pool initialisation, where it allows up to 9,500 bps so the policy's
50% → 0 decay fits. Sells cannot be blocked by any policy: if the policy reverts or disallows a sell,
the hook proceeds with the fee clamped to 500 bps (or 0 if the policy reverted).

**D18. Wiring.** Contracts take immutable references where deploy order allows and a single
`wire(...)` call by the deploying address for the cycle (FwaGame ↔ Treasury, KeeperFund, EngineBuyer,
farm ↔ games). `wire` can run once, after which the deployer has no power; postflight reads every
reference back. Alternative: predict CREATE addresses for every cross-reference, which is fragile with
a CREATE2-mined hook in the middle.

**D19. Vault shutdown price protection.** `shutdown` (anyone, after the delay) sends the whole balance to
`ProtocolLiquidity.addLiquidity`, whose half-swap is capped at `maxImpactBps` from the current price;
any ETH the cap leaves unswapped stays in ProtocolLiquidity and joins the next addition. The 3% hook
fee each way makes sandwiching a bounded slice unprofitable.

## Repository

**D20. Removed beyond the listed docs.** `docs/PLAY.md`, `docs/VOLUME_CAP.md`, `evidence/`, `sim/` (old
HTML labs) and the old helper scripts described the depositor pool and were removed with it; git
history keeps them.
