# Implementor decisions

A running list of every decision the build brief left open, with what was chosen, why, and the alternative,
plus everything found to contradict the brief. The owner reviews this once at the end. Numbering is stable;
an entry the build later changed is marked **Revised** and keeps its number.

Sources: the task text the build was issued with, `docs/BUILD_PROMPT.md` at 4d3e811 (module seams), the
amendment ecdc9eb ("amend the build prompt after design review", committed to the branch while the build was
running), the sustainability follow-up to PR #9 (D31 onward), which wins over older instructions on revenue
routing, ordinary prizes, farming and post-genesis rewards, and the owner's review of the collection-games designs
(D44 onward: zero-ETH single-sided launch, Shape Packs, and the recommended gate, recovery, booking, keeper, cadence
and exposure changes). Entries it replaced are marked **Superseded** or
**Removed** and kept for the record.

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

**D3. Draw Packs. Revised; Pack rows now rejected by BoardPolicy (D35).** `0xf21514b0…` on mainnet is "Shape Packs" with `MIN_PACK_VALUE = 0.03 ETH`
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

**D7. Revenue is booked at expectation; variance stays with the house. Superseded by D32.** The owner proceeds of a pull are fixed
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

**D12. Taper fixed on 21 epochs; schedule immutable. Superseded by D34.** `EmissionSchedule.allocationOf(e)` is the
1.5× → 0.5× taper over the original 21 epochs regardless of shortening; `shorten` cuts the tail and burns the
cut epochs at once (re-tapering would change epochs already played). The schedule address is immutable in the
farm, so a final epoch's pot can no longer change: deposits land only in the current epoch, rollovers only
move empty epochs, and the pot is snapshotted at the first claim. The farm still caps committed genesis
allocations at the budget (tested with an over-allocating schedule).

**D13. Empty epochs. Superseded by D34.** Genesis epochs with no units are burned by `retireUnearned`. A final epoch with no units
can roll its non-genesis part (deposits, season allocation, rolled-in amounts) into the current epoch (anyone,
`rollover`), so buyback rewards are never stranded.

**D14. Seasons. Removed (D34).** `scheduleSeason(startEpoch, epochs, amount)`: after genesis, at least 7 epochs
(50,400 blocks) of notice, at most the genesis average per epoch, no overlap with another season, at most 8
seasons. Seasons cannot be cancelled (a partly played season would need a rule); the reserve's only other
outflow is `burnReserve`.

**D15. Treasury allocates; sinks draw. Removed (D31, D39).** One `Buyback` sink (90 %) and `GrailFund` (10 %).
`Treasury.distribute()` allocates the unallocated balance to sinks by the table (`owed[sink]`); a sink's
`process` draws what it spends in the same call and returns anything unspent. So the Buyback's allocation waits
in the Treasury between slices and no sink holds ETH between calls (the invariant suite checks it). The Buyback
slice is `min(sliceWei, max(owed/4, 0.005 ETH))`; one purchase per call, `burnShareBps` (launch 5,000) burned, the
rest deposited into the farm's current epoch. A new table returns every allocation to the unallocated balance.
When the impact cap stops a slice early, the unspent part returns to the unallocated balance and is re-split by
the table at the next `distribute` (a small leak from the buyback share to GRAIL; accepted).

**D16. KeeperFund. Revised (funding and overflow: D33).** A holder of the keeper allowance, seeded at deploy (`KEEPER_SEED`), funded by the
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

**D23. Protected working capital. Superseded by D32 and D36.** FwaGame tracks `cash` (balance less the GRAIL reserve), `replacementsOwed`
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

**D25. Maintenance windows. Revised by D49.** Every FWA inventory change bumps `inventoryVersion` (in-flight purchases revert) and
restarts the factory cooldown (0 on mainnet at the fork block; 5 minutes by default). FwaGame changes inventory
only when a full batch (`listBatch`, launch 20) is waiting or `maintenanceInterval` (launch 30 minutes, bound
≤ 1 day) has passed since its last change; GRAIL listing and repricing happen in the same windows.

**D26. FwaGame size.** Rule 3 forbids `via_ir` for holders. Built on the legacy pipeline the amended FwaGame first
measured 23.1 KB, then failed with stack-too-deep (it had been compiled through a via-ir profile that the
`lib/draw-packs` restriction pulled in; that restriction is gone since nothing deploys Draw Packs from source).
To get headroom: constructor arguments in a struct, wide FWA tuples read through small helpers, conversion moved
to the Converter module, Pack minting removed (D3), smaller event payloads. FwaGame is 21,495 bytes (3,081 bytes
under EIP-170). Lowering optimizer runs saved under 200 bytes and was not used.

**D27. Exempt senders. Revised: fixed at wiring (D38).** The swap policy exempts `EngineBuyer` (callable only by the Converter and the Buyback)
and `ProtocolLiquidity` (whose only swap is the half-swap inside `addLiquidity`, callable by the vault and the
timelock). No public router is exempt. The amendment says EngineBuyer is the only exempt sender; ProtocolLiquidity
is added because otherwise the vault's shutdown into the liquidity position would revert during genesis and pay
the fee to the Treasury.

**D28. Not re-verified against FWA's website.** The amendment asks to re-verify the factory against FWA's current
deployment page. This build verified on-chain at the pinned block (`implementation()`, creation fee, `edgeBps`,
`betaAccess`, `poolCreationEnabled`, VRF service, `inventoryChangeCooldown` 0) and against the vendored verified
source; it did not consult FWA's site. The deploy script refuses if `implementation()` differs from the pinned
value.

**D29. FWA's VRF fee is not zero.** The brief's fact table says "VRF request fee 0 today". The fee is
`serviceGasEstimate × tx.gasprice × (1 + serviceMarginBps) + serviceFlatWei` (`FWACloneVRFService.requestFee`; on the
fork 1,500,000 gas, 3,000 bps, 0), so it reads 0 only in an `eth_call` with gas price 0. A real pull pays about
0.00195 ETH at 1 gwei (14 % on top of the 0.0142 ticket) and 0.0098 at 5 gwei. Consequences: the farming break-even
nearly doubles at 1 gwei; the site quotes at the current max fee per gas and shows the VRF fee separately (FWA refunds
any excess); the sims include it; `LAUNCH_ETH` is recommended at 5 ETH instead of 10 (docs/ECONOMICS.md section 6).
Nothing in our contracts can change it; it goes to FWA's VRF service, not to the game.

**D30. A delivery stuck forever cannot block retirement.** Found in review after the amendment: the first amended
`retireStep` waited for the open set to empty, so a delivery that keeps failing while its purchaser never claims the
refund would have held the vault's capital forever. Retirement now withdraws only listings FWA still holds as Active
or Staged, completes without a quarantined prize, and later `retireStep` calls sweep whatever that prize eventually
yields (owner proceeds, or the recovered Shape burned) to the vault.

## Sustainability follow-up (PR #9)

**D31. Three funding routes, kept apart.** Trading fees and every other inflow that is not earned by the game are
capital: the hook pays its fee to the PrizeVault (`feeRecipient`), which counts PoolManager inflows as `tradingFees` and
everything else as `contributions`, and `fund()` passes the whole balance to the game as `capitalIn`, even above any
capital target. Profit is the only thing that leaves for the token, and only to the burn-only `Buyback`. Promotions
have their own budget (D37). The `Treasury` and its sink table were removed: a governance-settable table could route
revenue anywhere, including a recurring player reward or a founder skim, and the follow-up allows neither. The
`BuybackReward` half (burn share 50%, the rest deposited into farm epochs) is gone with it; nothing had been earned
under it (no deployment exists), so no entitlement changed. Alternative considered: keep the Treasury with a fixed
one-sink table; rejected as dead weight. Reporting caveat: `tradingFees` counts every ETH the PoolManager sends the
vault, so someone who routes their own swap output to the vault is counted there too; it is capital either way.

**D32. Cumulative profit and loss in FwaGame.** Inventory is capital carried at cost. A captured board prize books owner
proceeds as revenue and its carried cost (backing + mint fee) as the one expense; replacing it is a purchase of
inventory, not a second expense, so a replacement cost is recognised exactly once, when that replacement is itself won.
The initial fill and inventory bought with trading fees are capital, never free: they become expense when won. Burning
a held prize writes off its mint fee. Profit is `revenue + opsReturned − prizeExpense − opsAccrued`, signed and
cumulative, so losses carry and capital contributions cannot reset or disguise them. A distribution needs both
undistributed profit and cash above `replacementsOwed + opsOwed + reserveTarget + exposure` (unsettled requests × the
largest prize cost), so deferred obligations come first and an adverse run stops distributions by itself. Player claims,
refunds and escrow stay in FWA and are never counted as the game's. Booked proceeds use `base = paid / (1 + edge)`,
which is never above FWA's own split (FWA rounds its fee down from the base), so revenue is never overstated; the wei
difference stays in cash unbooked. Limitation: if FWA changes its edge between a request and its booking, that
request's proceeds are computed with the new edge; admission closes on an edge above `maxEdgeBps` (D36).

**D33. Operating allocation: 3% of the expected replacement cost.** `PricingPolicy.opsBps` (≤ the markup) of the quote's
expected replacement cost `C = base / (1 + markup)`, not of the prize won: price 1.1025C, owner proceeds 1.07625C, ops
0.03C, expected margin 0.04625C. It is accrued as an expense, paid to KeeperFund once replacements are covered, and
KeeperFund's overflow above its 0.5 ETH target returns to the game (`returnOps`), reducing the net expense, so an
operating reserve is treated the same way going in and coming out. Measured on the fork (`test_operatingAllocation
AgainstMeasuredKeeperGas`): it pays the keeper gas of a sync per 10 pulls up to about a 1.6 gwei base fee (1.60 to 1.66 gwei, measured with each call its own transaction; warm-storage runs read 2.1). Above that, tips
are capped by what KeeperFund holds and keepers wait for cheaper blocks; settlement never depends on tips.

**D34. Genesis farm rebuilt: ticket ETH, two caps, fixed end.** Weight is eligible ticket ETH: the FWA fee escrowed by
delivered pulls, after refunds. VRF fees, gas, donations, conversions, transfers and refunded or undelivered draws add
nothing, and the prize won does not affect weight. Per epoch `pot = min(allocationCap, eligibleETH × rateCap)`; 14
steady epochs at F/17.5, then 87.5% … 12.5% on both caps; the last epoch takes the rounding so the caps sum to F; rewards
round down. The rate cap is fixed at deploy so a steady epoch pays at most 10% of ticket ETH in ENGINE at the launch
price (16M ENGINE per ETH at LAUNCH_ETH 5); a single pull earns its rate, never a whole day's pot. `finalize` fixes a
final epoch's pot and burns the rest of its cap, which nobody can earn any more; earned pots and every unfinalized cap
stay reserved (`reserved()`); claims never expire; finality comes from the game's own walk, and a stuck delivery holds
only its own epoch. Requests accepted before the end keep their epoch; at or after `genesisEndBlock` the cap is zero.
Removed: seasons, the 79% reserve, deposits, rollover, `shorten`, `retireUnearned` and `EmissionSchedule`. Alternative:
weight by pulls (the PR #9 rule); rejected because the follow-up asks for ETH weight and a per-pull unit rewards cheap
boards over value.

**D35. Launch board: the 100-item form of 6 / 9 / 5.** 30 × 0.01, 45 × 0.05, 25 × 0.5 ETH Shapes at 5% markup has the
same probabilities, price (0.03012685 ETH), headline odds (1 in 73.34) and return (87.38%) as the 20-item mix, at five
times the inventory (15.15 vs 3.03 ETH). The deciding evidence is FWA's ordered settlement: each cheap prize won ahead
of a request raises the live fee 8.47% on 20 items but 1.52% on 100, and FWA refunds a request whose fee drifted more
than 10%, so on the 20-item board 3 requests on one quote already lose 17.55% to refunds and normal play refunds about
30%, against under 0.4% on the 100-item board (`sim/results/sustainability.md` sections 2 and 4). The bigger board
also depletes more slowly, keeps intermediate wins steady and needs fewer replacement windows per ETH; it costs 12 ETH
more inventory capital. The PR #9 board (80/15/5 at 0.01/0.05/0.1) was dropped: its headline is 0.1 ETH and its mint
fees take 7% of turnover. Pack rows are now rejected by `BoardPolicy` (the game never minted them).

**D36. Admission control at the pool. Revised by D45.** FwaGame opens and closes FWA's own purchase switch from `sync`, so the rules bind
direct FWA purchases, not only the site: closed below 80% board fill, above `maxOutstanding` (20) unsettled requests,
when FWA's edge exceeds `maxEdgeBps` (500, the launch edge) or its inventory cooldown exceeds `maxCooldown` (5 min), or
when paused. FWA itself caps a transaction at 5 requests and, at the pinned block, a pool at 10 outstanding VRF requests.
`setBool` does not bump FWA's inventory version, so toggling costs players nothing. `openGame` requires the 48-hour
market lead, a full board and the reserve in cash. Granularity: a request is admitted or not by FWA's switch at its
transaction; the game cannot refuse one request inside a batch, so the limits are set below the point where a batch
could hurt.

**D37. Promotions are budgeted.** A promotion is one prize paid in full from a pre-funded budget (its maximum obligation),
listed once below cost and never repriced, ending at a win or its end block, with its proceeds, cost and turnover
accounted apart from the ordinary game. GRAIL per-pull decay and the GRAIL reserve fed by revenue are gone.

**D38. Conversion and router semantics.** `convert` is not payable and spends exactly the burned backing; the bonus pool
running dry never stops it. The hook's `sender` is the caller of `PoolManager.swap`, which for any public router is the
router itself, shared by all its users; exempting one would open the gate to everyone. So the exempt set (EngineBuyer,
ProtocolLiquidity) is fixed at wiring and `setExempt` was removed; EngineBuyer serves only registered callers.

**D39. Buyback: burn-only, bounded, manipulation-checked.** One purchase per call of at most `sliceWei` (a maximum: a
smaller balance is spent whole), at most once per hour, capped at 3% impact, and refused when the price has moved more
than 2% against the buyer since the block opened. The hook records that opening price at the first swap of each block,
which costs one storage write per block. This defeats a same-block sandwich; a manipulation held across a block boundary
is not prevented, only bounded by the slice and the impact cap. The keeper's `minOut` can only tighten these limits.

**D40. Supply split 80 / 19 / 1 for a fresh deployment. Launch valuation revised by D50.** 800M ENGINE to the protocol position, 190M genesis, 10M bonus.
No deployment exists, so nothing is redistributed. Compared with 70/29/1, 50/49/1 and the PR #9 split (10/10/1 with a 79%
reserve) in `sim/results/sustainability.md` section 7: it removes the reserve dependence and keeps farm supply at 24%
of the pool's token depth; the cost is a low launch valuation (about 6.25 ETH FDV at LAUNCH_ETH 5), so genesis rewards
are worth about 1.2 ETH at the launch price. The owner may prefer a larger genesis share; the farm takes the budget as
a constructor argument, so only `DeploySystem` constants change.

**D41. Reserve target 12 ETH; opening capital about 28 ETH.** Sized from 200 seeded 90-day runs at 5 ETH a day with no
trading fees: at 3 ETH 97% of runs saw cash fall below the replacements owed at some point (rows waiting for profit), at
8 ETH 6.5%, at 12 ETH none. The reserve is capital, so a larger one barely changes what is distributed; it only locks
more opening capital. A shortfall is not insolvency (every listed prize is owned, every accepted request settles).

**D42. Removed:** `sim/engine_genesis.py` and its results (they modelled the Treasury, recurring player buybacks and the
old farm); `test/unit/Treasury.t.sol` (its KeeperFund cases moved to `test/unit/KeeperFund.t.sol`).

**D43. FwaGame size. Superseded by D44.** The follow-up's accounting and admission brought FwaGame to about 23.5 KB on the legacy pipeline,
about 1.1 KB under the limit, after making ten bound constants internal and dropping `nav()` (Lens computes it). GRAIL
repricing and the relist queue were removed. Further growth needs another module split.

## Collection-games review (D44 onward)

The owner asked which designs from `ripe0x/collection-games` (a1d4646) should be adopted here, then approved a plan:
a zero-ETH single-sided launch, Shape Packs as a prize (mainnet `0xf21514B0…5cA7`), and the recommended gate,
recovery, booking, keeper, cadence and exposure changes; FwaGame split in two; farm selling quantified without
changing the split; the Shapes board kept with Pack boards presented; the opening valuation proposed from a model.

**D44. FwaGame split into PoolOwner and the ledger.** FwaGame had about 1.1 KB left (D43), not enough for Packs and
the gate. `PoolOwner` now creates and permanently owns the FWA pool (paying the FWA creation fee from FWA it holds),
holds and lists prizes, mints them with exactly the ETH the game sends, turns withdrawn or recovered prizes back into
ETH (a Shape burned, a Pack redeemed) and forwards every wei to the game, collects owner proceeds, and is FWA's
purchase operator. It has no module, no generic call and no withdraw; its only ETH destinations are Shapes, Shape Packs
and the game (invariant: it holds no ETH, Shape or Pack between calls). FwaGame keeps the books, the walk, admission,
promotions and retirement, and is 24,195 bytes on the legacy pipeline (381 under the limit; no via_ir). Alternative:
a library split (smaller saving, same trust surface).

**D45. Purchase gate on live FWA state.** `PoolOwner.canPurchase`, which FWA calls for every purchase (its own site
included) with a 100,000-gas stipend and fails closed, refuses when `maxInFlight` requests are unsettled, when FWA's
edge or inventory cooldown is outside the accepted range, or when the active listings would fall below
`unsettled + 5 + floor`, floor = ceil(`minLiveBps` × rows). FWA does not tell the operator the batch size, so it
assumes a full batch (`maxAcquisitionsPerTx`, 5, read at pool creation). It reads only FWA state and settings the game
pushes, so it holds while nobody syncs (test: a day without keepers, direct FWA purchases stop after 16 captures with
84 prizes in the draw; one sync books everything and reopens). Launch `maxInFlight` 10 (two batches; FWA's VRF layer
separately refuses an 11th request awaiting a word). Consequences: a board needs at least floor + 5 rows (an 80% floor
admits nothing below 25 rows; a small board needs a lower `minLiveBps`); and FWA's drift guard refunds about 2% of
accepted draws at 50 ETH a day on the 100-row board (`sim/results/throughput.md`; `test_fullBatchesWithRequestsInFlight`
sees 8 of 10 settle when ten cheap prizes are taken in a row). Admission (FWA's switch) still closes below the floor and
outside the range, as D36.

**D46. Step-by-step recovery.** `sync` runs FWA processing, booking, proceeds collection, the true-up and payment, then
maintenance, admission, the keeper top-up and the tip, each in its own `try`; a failing step emits `StepFailed` and the
others run. Booking and retirement read no module, so a reverting board or pricing module stops listing only (test:
`test_revertingModulesStopOnlyTheirSteps`). A delivery refund whose recovery fails stays open and is retried.

**D47. Booking that configuration cannot move.** Proceeds are booked at `bookingEdgeBps`, the highest FWA edge
governance has ever accepted (so lowering `maxEdgeBps` later never inflates booked revenue), then trued up to what FWA
actually paid once no request is outstanding and FWA holds no proceeds for the game. Each listing's markup and operating
allocation are fixed when it lists. The operating allocation is computed on the base price at the booking edge, as
before (a regression from the split, caught by `test_pullFulfilledBookedToTheWei`, was fixed). Invariant: booked
proceeds never exceed what FWA paid plus what it holds.

**D48. Keeper pay and vault top-ups.** KeeperFund pays `min(tipCap, (gas + 70,000) × min(tx.gasprice, 5 gwei))` plus a
0.0003 ETH flat fee at most once an hour per job; a call with no work earns nothing (the game reverts it). Launch:
`tipCap` 0.05 ETH (lists 20 prizes in one call at up to about 5 gwei), seed 0.05 ETH (the maintenance floor). The vault
refills KeeperFund from trading fees to its floor plus 0.1 ETH in every sync, at most 1 ETH over the vault's life
(`KEEPER_TOP_UP_LIMIT`, permanent); KeeperFund returns top-ups to the vault before any overflow reaches the game, so
fees never become game profit (invariant: KeeperFund's `capitalHeld` equals top-ups less returns). Replaces the 20%
premium and age bounty, which paid splitting and idle time.

**D49. Restock cadence and exposure.** Replacements list when nothing is in flight (FWA would otherwise stage them),
unless the board is within `maxInFlight` + 5 rows of the gate's floor (so steady play never closes the gate for want of
a restock); then once 3 rows wait (`listBatch`, now the trigger) or 5 minutes, and at least six FWA cooldowns, after the
last inventory change. Settlement exposure is `min(unsettled × costliest prize, inventory cost)`.

**D50. Zero-ETH single-sided launch.** `ProtocolLiquidity.launch` takes no ETH: it initialises the pool at `START_TICK`
and places the whole 80% float in one position over `[TICK_LOWER, START_TICK)`. The price can never return above the
start (ENGINE never trades below its launch valuation) and sellers can take out only the ETH buyers put in. The genesis
rate cap is derived from the start price (10% of ticket ETH valued there). `LAUNCH_ETH_WEI` is replaced by `START_TICK`.
Recommended start: **10 ETH FDV, `START_TICK` 184,200** (≈ 99.8M ENGINE per ETH; `sim/results/launch.md`): 1 ETH of
opening buys moves the price about a quarter (5 ETH FDV: more than half) and leaves less concentration. 5 ETH FDV is
the alternative that favours opening buyers. No seeded ETH: it would be exit liquidity from the owner and remove the
floor. Needs owner review.

**D51. Shape Packs as a second prize kind.** A board row has a kind (0 Shape, 1 Pack); Pack rows must be at least Shape
Packs' 0.03 ETH minimum (read from the contract at deployment; on a chain without Shape Packs no Pack row is allowed).
A Pack is minted with the fewest Shapes (`defaultMakeup`) and costs its backing plus 0.001 ETH per Shape inside
(read from the fork: 0.03 → 0.033, 0.08 → 0.084, 0.25 → 0.253). Withdrawn, recovered and retired Packs are redeemed;
converted Packs are redeemed by the Converter. The launch board stays Shapes-only (owner's decision); two Pack boards
are presented in `sim/results/boards.md` (board A: seven prize levels on half the board capital, 7.72 ETH, with a rarer
headline; board B: a 1 ETH headline). Board changes apply as rows are next vacated. Tested end to end against the real
Shape Packs contract (`test_packsMintListWinConvertRecoverRetire`).

**D52. Farm selling under the single-sided launch (finding, not changed).** Public buys stay closed through genesis
(D34), so farm rewards sold during genesis meet only the opening market's ETH, conversions and buybacks. The rate cap is
valued at the start price, and ENGINE trades above it once anyone buys, so the rewards are worth more than 10% of ticket
ETH. In the worst case modelled (no conversions, 1 ETH of opening buys, 20 ETH of genesis tickets at 10 ETH FDV), full
farm selling takes the price back to the start and opening buyers exit with nothing; with 25% of prizes converted the
same opening exits at 1.3×. The split is unchanged (the owner did not approve a change). Options for the owner: a
smaller farm (for example 10% with the rest to the float); valuing the rate cap at a time-weighted pool price (a
contract change); a lower start FDV. Needs owner review.

## Independent audit of 5494c33 (D53 onward)

**D53. Audit findings and fixes.** A fresh-discovery audit of commit 5494c33 (prompt in `docs/AUDIT_PROMPT.md`)
reported nine findings with fork reproductions. All were verified against the code and fixed or documented; each has a
regression test in `test/fork/AuditFixes.t.sol` or `test/unit/Farm.t.sol`:

1. *Undeliverable purchaser.* A purchase naming Shapes or Shape Packs as purchaser left the prize in FWA's delivery
   quarantine for good: each collection refuses its own tokens, and only the purchaser may take FWA's refund that
   lets the owner recover the prize. `PoolOwner.canPurchase` now refuses those purchasers (and zero), before any fee.
2. *Promotion counted as a board prize by the gate.* The gate compared FWA's active listings, which include a live
   promotion, with the board floor, so a batch could leave 79 board prizes. It now adds the promotion to the floor.
3. *Promotional proceeds in ordinary profit through the true-up.* The true-up credited every difference to ordinary
   revenue. When a promotional capture was booked since the last true-up, the whole difference now goes to the
   promotion budget (ordinary revenue can only be understated, by at most that window's booking-edge margin).
4. *Price ceiling after an addition.* `addLiquidity` added full range, so sellers could trade ENGINE below its launch
   valuation against the added position. Every position now ends at `startTick`. Consequence: near the start the
   range absorbs little ETH, so most of a shutdown's ETH stays in ProtocolLiquidity (protocol-owned, for later
   additions) instead of entering the pool; the ceiling was preferred. Past the start there is no liquidity: v4 may
   report a price beyond it after a sell, but nothing trades there.
5. *Finalized epochs diluted by a late ledger.* `GenesisFarm` now records the epoch each ledger is added in and counts
   it only from then, so governance cannot change an ended or finalized epoch.
6. *Pool creation front-run between deploy transactions.* The salt is fixed in PoolOwner's constructor and
   `createPool()` takes none, so anyone calling it first creates the intended pool; the deploy routine skips a pool that
   exists, and postflight checks the salt and FWA's predicted address.
7. *Shutdown with a caller-chosen price limit.* `PrizeVault.shutdown()` takes no limit (only the impact cap bounds the
   half-swap), and an addition that would add nothing reverts `NothingAdded`.
8. *FwaFeeBuyer paid prior ETH to the next caller.* It refunds only the caller's unspent ETH.
9. *Promotion odds cap checked only at the start.* Documented as such: as ordinary prizes are won the promotion's live
   chance can rise above 10% until replacements list. The prize is fully funded, so no capital is exposed; enforcing
   the cap continuously would need room FwaGame does not have (24,286 bytes, 290 under the limit).

The audit also found the gate invariant copied finding 2; it now subtracts a live promotion and checks the refused
purchasers. Governance's breadth with a zero-delay timelock remains a documented trust assumption (docs/SECURITY.md).

