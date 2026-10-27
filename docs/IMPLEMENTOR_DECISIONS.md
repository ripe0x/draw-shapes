# Implementor decisions

A running list of every decision the build brief left open, with what was chosen, why, and the alternative,
plus everything found to contradict the brief. The owner reviews this once at the end. Numbering is stable;
an entry the build later changed is marked **Revised** and keeps its number.

Sources: the task text the build was issued with, `docs/BUILD_PROMPT.md` at 4d3e811 (module seams), and the
amendment ecdc9eb ("amend the build prompt after design review", committed to the branch while the build was
running). The task text says it is authoritative where they differ; see D2 for how the amendment was handled.

## Process and sources

**D1. Branch.** The task text names `claude/relaxed-goodall-mmbzpd` as the only branch to push to; the
session's harness also proposed `claude/draw-shapes-ethereum-4405vp`. The work is built on and pushed to
`claude/relaxed-goodall-mmbzpd`, as the task text says. Nothing was pushed anywhere else. The amendment
ecdc9eb landed on that branch mid-build; the build was rebased onto it (only `docs/BUILD_PROMPT.md` changed).

**D2. Three versions of the brief. Revised.** The committed 4d3e811 added module seams; the amendment ecdc9eb
then fixed real weaknesses (a stuck delivery stalling the walk, revenue leaving while the bankroll is short,
inventory churn on every pull, custody overstated, unbounded seasons). None of the amendment reopens a
section 3 decision, so it was adopted, except where noted. Taken: two-cursor walk with a delivery grace
period (D24), protected working capital (D23), maintenance windows (D25), one Buyback sink with a burn share
(D15), tips per unit of progress with a seeded maintenance floor (D16), season limits and a fixed schedule
(D12, D14), the gate starting at `openBlock` with `EngineBuyer` as the only buy path, the bonus capped at the
sell fee (D10), custody described as a governance trust model (D21), `SwapPolicy`, `EngineBuyer`. Not taken as
separate contracts: `GameRevenueRouter`, `ConversionPolicy` and `TipPolicy`. FwaGame routes the markup line to
KeeperFund and the margin line to the Treasury directly (both immutable holders), the bonus rate lives in
`PricingPolicy`, and the tip formula lives in KeeperFund with bounded parameters. Reason: each would be one more
module address and wiring step for a decision that already has a bounded parameter, and FwaGame has no code
room for indirection it does not need (D26). Not taken: `scheduleSeason(ledger, startBlock, …)` binding seasons
to a ledger (D11 makes all ledgers share one clock, so there is nothing to collide). Not taken:
`convertPack` (D3).

**D3. Draw Packs. Revised.** `0xf21514b0…` on mainnet is "Shape Packs" with `MIN_PACK_VALUE = 0.03 ETH`
(3 units), not the two-unit Draw Packs variant (checked on the fork: `MIN_PACK_VALUE()` = 3e16). Per the brief,
the board is Shapes only until the owner decides. FwaGame lists Shapes only: a Pack row in the board policy is
skipped, never minted. An earlier version of FwaGame minted and listed Packs; it was removed to keep FwaGame
under 24 KB on the legacy pipeline with headroom (D26). Consequence for the owner: adding Packs later (the
real three-unit collection, or a two-unit Draw Packs deployment) means a new FwaGame, which costs another
50,000 FWA and a retire-and-activate cycle. The Converter is a module and converts only Shapes today.

## FWA integration

**D4. Paying the 50,000 FWA creation fee.** FWA is transfer-locked: wallet-to-wallet transfers revert
unless one side is the token owner, a registered distributor, or the v4 PoolManager under the hook's
transient allowance (verified in the verified FWAToken source, `_afterTokenTransfer`). The deploy
wallet therefore cannot send FWA to FwaGame. Flow: the deploy script calls the stateless helper
`FwaFeeBuyer.buyTo(game, minOut)` with ETH; it buys FWA exact-in on FWA's own v4 pool and takes the
output straight to FwaGame (PoolManager → recipient is allowed). Then `FwaGame.createPool(salt)` (anyone, once)
approves the factory for the exact live fee, calls `factory.createPool(salt, fee, expectedImplementation)`
(the factory pulls FwaGame → dead address, a distributor) and burns any FWA left over. The pool address is
write-once rather than `immutable` because the fee must reach FwaGame through a v4 callback after
construction. Alternative: the deploy wallet creates the pool and becomes its permanent owner, against
section 3. Fork tests run this exact path against the real FWA token, hook and factory.

**D5. `DeliveryPending`. Revised (see D24).** The first version halted the walk at a pending delivery. The
amended walk does not: the request stays open and resolves when it settles, or counts as resolved without a
unit after the grace period.

**D6. Epoch finality. Revised.** `accepted` comes from FWA's issuance: the first cursor sees every issued
sequence once and counts it in the epoch of its `requestBlock`. An epoch is final when its last block has
passed, every request issued in it has been seen, and `accepted == resolved`. `epochTotals(e)` returns
`(accepted, resolved, units)`.

**D7. Revenue is booked at expectation; variance stays with the house.** The owner proceeds of a pull are fixed
by FWA from the pool's expected value at request time, but the prize is random, so `proceeds − backing − mint
line` is negative for every large prize and cannot be routed. Per booked capture FwaGame computes, from the
escrowed `paid` and the live `edgeBps`: `base = paid × 10,000 / (10,000 + edgeBps)`, `proceeds = paid − (paid −
base)/2` (FWA's owner split), `markupLine = base × markupBps / (10,000 + markupBps)`, `marginLine = proceeds −
base`, `expectedCost = base − markupLine`. The two lines are owed to KeeperFund and the Treasury; `expectedCost`
stays as the replacement budget; `expectedCost − (backing + mint line)` is tracked as `bookedGain`/`bookedLoss`.
`markupBps` is the captured listing's own snapshot; while a markup change rolls through the board the pool holds
mixed markups and the line is approximate. FWA's own split uses its internal request-time base price, so the
formula can differ from the withdrawn proceeds by 1 wei per capture; the difference stays in the game (tested).

**D8. FwaGame cranks FWA.** `sync` calls the pool's permissionless `processAcquisitions` first, so keepers drive
FWA settlement as well.

**D9. Replacement is a board bitmap. Revised (see D25).** Each board row has one bit (live or not). A capture
clears the bit and adds the prize's cost to `replacementsOwed`; replacements are minted and listed at
maintenance windows while cash pays for them. A board change takes effect as rows are replaced; nothing is
withdrawn to rebalance.

**D10. Conversion. Revised.** Conversion moved out of FwaGame into the `Converter` module (D26). It reads
delivery from FWA's own record: listing `listingId` of the game's pool must be `Settled` (delivered) with the
Shapes collection, and not converted before. Eligibility follows the token (any holder). With `allowNoBonus`
the call pays whatever the bonus pool holds. The bonus rate is the pricing policy's, capped at 500 bps and at
the swap policy's live sell fee, so convert-then-sell never returns more than the backing. The farm pays bonuses
only to registered bonus payers (the Converter). Alternative: keep conversion in FwaGame with a delivered-token
map, which did not fit (D26).

## Token side

**D11. The farm owns the epoch clock.** "A second game registered after retiring the first" means the ledger
cannot be one FwaGame. GenesisFarm holds `openBlock` (set once by the first registered game's `openGame`) and
sums units over up to four registered ledgers; every game derives epochs from the farm's `openBlock`. Ledgers
are added, never removed (removal would change past rewards). Tested with a second game in the rehearsal.

**D12. Taper fixed on 21 epochs; schedule immutable. Revised.** `EmissionSchedule.allocationOf(e)` is the
1.5× → 0.5× taper over the original 21 epochs regardless of shortening; `shorten` cuts the tail and burns the
cut epochs at once (re-tapering would change epochs already played). The schedule address is immutable in the
farm, so a final epoch's pot can no longer change: deposits land only in the current epoch, rollovers only
move empty epochs, and the pot is snapshotted at the first claim. The farm still caps committed genesis
allocations at the budget (tested with an over-allocating schedule).

**D13. Empty epochs.** Genesis epochs with no units are burned by `retireUnearned`. A final epoch with no units
can roll its non-genesis part (deposits, season allocation, rolled-in amounts) into the current epoch (anyone,
`rollover`), so buyback rewards are never stranded.

**D14. Seasons. Revised.** `scheduleSeason(startEpoch, epochs, amount)`: after genesis, at least 7 epochs
(50,400 blocks) of notice, at most the genesis average per epoch, no overlap with another season, at most 8
seasons. Seasons cannot be cancelled (a partly played season would need a rule); the reserve's only other
outflow is `burnReserve`.

**D15. Treasury allocates; sinks draw. Revised.** One `Buyback` sink (90 %) and `GrailFund` (10 %).
`Treasury.distribute()` allocates the unallocated balance to sinks by the table (`owed[sink]`); a sink's
`process` draws what it spends in the same call and returns anything unspent. So the Buyback's allocation waits
in the Treasury between slices and no sink holds ETH between calls (the invariant suite checks it). The Buyback
slice is `min(sliceWei, max(owed/4, 0.005 ETH))`; one purchase per call, `burnShareBps` (launch 5,000) burned, the
rest deposited into the farm's current epoch. A new table returns every allocation to the unallocated balance.
When the impact cap stops a slice early, the unspent part returns to the unallocated balance and is re-split by
the table at the next `distribute` (a small leak from the buyback share to GRAIL; accepted).

**D16. KeeperFund. Revised.** A holder of the keeper allowance, seeded at deploy (`KEEPER_SEED`), funded by the
markup line up to `keeperTargetWei` (overflow to the Treasury). Tip = gas part + bounty, where the bounty is
`maxBounty × min(age, ramp)/ramp × min(items, 20)/20`, `items` being units of progress (requests seen or
resolved, listings made, slices bought); a call with no progress reverts `NoWork` and pays nothing, and splitting
work earns no more than one call (tested). Ordinary jobs cannot spend below `maintenanceFloor` (launch
0.05 ETH); retirement steps can. Tips are pushed with a 50,000 gas stipend; a failed push is credited and pulled
with `withdrawTips()`. `age` is seconds since the job last ran; a per-call `gasOverhead` (40,000) covers intrinsic
gas the in-call measurement cannot see.

**D17. Anti-snipe buys only; bounded in the hook.** The hook caps the fee at 500 bps, except within three hours
of pool initialisation, where it allows up to 9,500 bps so the 50 % → 0 decay fits. Sells cannot be blocked: if
the policy reverts or disallows a sell, the hook proceeds with the fee clamped (or 0 if the policy reverted).

**D18. Wiring.** Contracts take immutable references where deploy order allows and a single `wire(...)` call by
the deploying address for the cycles. `wire` runs once and then the deployer has no power; postflight reads every
reference back and checks `deployer() == 0` everywhere. The token address is predicted (CREATE nonce) so the farm
and ProtocolLiquidity can be its mint recipients; the hook is CREATE2-mined for its permission bits.

**D19. Vault shutdown price protection.** `shutdown` (anyone, 30 days after the last game returned) sends the whole
balance to `ProtocolLiquidity.addLiquidity`, whose half-swap is capped at `maxImpactBps` (launch 5 %) from the
current price; ETH the cap leaves unswapped stays in ProtocolLiquidity and joins the next addition. The 3 % hook
fee each way makes sandwiching it unprofitable at that size.

## Repository

**D20. Removed beyond the listed docs.** `docs/PLAY.md`, `docs/VOLUME_CAP.md`, `evidence/`, `sim/` (old HTML labs)
and the old helper scripts described the depositor pool and were removed with it; git history keeps them.

## Added after the amendment

**D21. Custody, stated accurately.** Code enforces: no holder has a withdraw function; the vault sends only to the
active game and the liquidity position; FwaGame sends only to the vault, Shapes (mint cost), the Treasury and
KeeperFund; the Treasury sends only to registered sinks; KeeperFund sends only to keepers (tips) and the Treasury.
Governance chooses the game, the sinks and the modules, so governance can direct all capital, and the timelock
delay (0 at launch) is the only notice. This contradicts the original wording "nobody, the owner included, can
withdraw it"; the docs and the site's Terms say what governance can move, where, and with what notice, and the
final report reminds the owner to raise the delay before outside money is material.

**D22. Sepolia rehearsal covers everything except FWA.** The Sepolia FWA factory (`0xdF0b…`) is an older stack:
`createPool(bytes32,uint256,address)` reverts there (simulated 2026-10-26). `script/deploy.sh sepolia` with
`DRY_RUN=1` simulates every other contract, the wiring and the postflight against Sepolia Shapes and the Sepolia
v4 PoolManager with `CREATE_FWA_POOL=false`. Nothing was broadcast to Sepolia (no keys in this build).

**D23. Protected working capital.** FwaGame tracks `cash` (balance less the GRAIL reserve), `replacementsOwed`
(cost of captured board prizes not yet replaced) and `reserveTarget` (timelock, bounded: at least twice the
board's most expensive prize, at most 1,000 ETH). Only `distributable = cash − replacementsOwed − reserveTarget`
may leave, markup line first; owed lines wait otherwise. Expensive wins are paid from cash and the reserve, and
gains refill the reserve before anything is distributed (tested; the invariant handler flags any outflow while
cash is below `replacementsOwed + reserveTarget`). Launch `reserveTarget` 0.75 ETH from the adverse-sequence sim
(P(shortfall) 0.05 % over 21 days at 300 pulls/day). `replacementsOwed` counts captures only, not rows that were
never listed: a board enlarged by governance needs capital before its new rows fill.

**D24. Two-cursor walk.** `seenSeq` advances over every issued sequence regardless of status (accepted in the
epoch of its `requestBlock`); terminal requests resolve on sight, the rest join an open set that each `sync`
re-checks in any order. A delivery still pending `DELIVERY_GRACE_BLOCKS` (50,400 + 7,200) after its request is
counted resolved without a unit and stays open until FWA settles it (its economics then book). Tested with a
delivery that fails and is never refunded: the walk and later epochs keep progressing, and epoch 0 becomes final
after the grace period.

**D25. Maintenance windows.** Every FWA inventory change bumps `inventoryVersion` (in-flight purchases revert) and
restarts the factory cooldown (0 on mainnet at the fork block; 5 minutes by default). FwaGame changes inventory
only when a full batch (`listBatch`, launch 20) is waiting or `maintenanceInterval` (launch 30 minutes, bound
≤ 1 day) has passed since its last change; GRAIL listing and repricing happen in the same windows.

**D26. FwaGame size.** Rule 3 forbids `via_ir` for holders. Built on the legacy pipeline the amended FwaGame first
measured 23.1 KB, then failed with stack-too-deep (it had been compiled through a via-ir profile that the
`lib/draw-packs` restriction pulled in; that restriction is gone since nothing deploys Draw Packs from source).
To get headroom: constructor arguments in a struct, wide FWA tuples read through small helpers, conversion moved
to the Converter module, Pack minting removed (D3), smaller event payloads. FwaGame is 21,223 bytes (3,353 bytes
under EIP-170). Lowering optimizer runs saved under 200 bytes and was not used.

**D27. Exempt senders.** The swap policy exempts `EngineBuyer` (callable only by the Converter and the Buyback)
and `ProtocolLiquidity` (whose only swap is the half-swap inside `addLiquidity`, callable by the vault and the
timelock). No public router is exempt. The amendment says EngineBuyer is the only exempt sender; ProtocolLiquidity
is added because otherwise the vault's shutdown into the liquidity position would revert during genesis and pay
the fee to the Treasury.

**D28. Not re-verified against FWA's website.** The amendment asks to re-verify the factory against FWA's current
deployment page. This build verified on-chain at the pinned block (`implementation()`, creation fee, `edgeBps`,
`betaAccess`, `poolCreationEnabled`, VRF service, `inventoryChangeCooldown` 0) and against the vendored verified
source; it did not consult FWA's site. The deploy script refuses if `implementation()` differs from the pinned
value.
