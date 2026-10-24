# ENGINE implementation plan

Revision 3, 2026-10-24. Input: [BRIEF](BRIEF.md). Findings: [REVIEW](REVIEW.md). Correction passes:
[NOTES_2026-10-24](NOTES_2026-10-24.md) (answered by revision 2, cited "notes N") and
[NOTES_2026-10-24b](NOTES_2026-10-24b.md) (answered by this revision, cited "notes2 N"). Status: the author
approved the product direction, the branch reuse and the market-first order on revision 2, and asked for the
notes2 corrections to be built into phase 2's acceptance tests before phase 3 is approved. Base: `main` at `4a13a09`. Reused branches:
`origin/feat/coin-funded-engine` (PR #7, `2c70c15`) and `origin/claude/next` (PR #5, `7afd772`), both fetched.
Nothing in this plan is built yet.

## 0. Decisions

| Decision | Source | Affects |
| --- | --- | --- |
| D1. Base is `main`. The depositor layer (shares, NAV as a share price, entry fee, volume cap, founder window, withdrawal claims, claim liquidation, successor migration) is removed. The creator's 5 ETH enters through typed funding calls. | review 1, notes 1, 6 | Phase 3 |
| D2. Reuse from the two PR branches, selectively: foreign listings (`registerForeign`, `repriceForeign`, `withdrawForeign`, `foreignListings`, SPEC 11 text, `test/fork/PoolForeign.t.sol`, identical on both branches); `PrizeSponsorship` and `test/fork/engine/EngineSponsor.t.sol` as the sponsor base; `SponsorOffer` (standing offer any holder can take) and `docs/PUNK_VALUE.md` plus `script/survey/` as the evidence for P; `test/fork/engine/EngineBase.sol` and `EngineGas.t.sol` as the harness; the EIP-7825 listing batch size of 12 and the VRF fee priced at the transaction gas price; `sim/engine.mjs` as the model base; `docs/SECURITY_REVIEW.md` and `AUTONOMOUS_DECISIONS.md` as reference. Not reused: `FoundingRound`, `IArtcoins`, the Artcoins market, founder splits, `FeeSplit` mint fee routing, `boardNavCap`. | notes 1 | Phase 1 |
| D3. The 48 hour ETH exit of an ENGINE mode pack pays `backing × (10,000 − haircutBps) / 10,000`, haircut launch value 500. The haircut and the exit delay are snapshotted on the accepted request and bound to the selected pack when the award is verified (one authoritative rule, notes2 6); a later parameter change applies to later requests only. Exit haircuts are reported as a separate line from market fees. The model and the published tables carry zero, half and full conversion; the baseline game must stand at zero. | review 1, notes 4 | Phase 2, 3 |
| D4. Original inventory is held by the hook and sold only to authenticated game buyers along a virtual curve (section 2). Accepted as a candidate only: it is built and tested first, and the brief's price and liquidity figures are not carried forward until the new market reproduces or improves them on the same scenarios. | review 1, notes 2 | Phase 2 |
| D5. Primary proceeds are a conserved account that becomes hook-owned ETH bid liquidity in the canonical pool, deployed in the same transaction as the primary sale. They are never fees, profit, GRAIL or Punk money. | notes 2 | Phase 2 |
| D6. The transfer gate authenticates each path. No allowlist of wallets, no blanket trust of `PoolManager`. Closed before `start()`. | notes 3 | Phase 2 |
| D7. Sponsor terms are the brief's: `2 P / 100,000` per eligible settled draw, cumulative cap `1.5 P`, 30 day reclaim, early win ends future accrual, cap reached transfers ownership. Compensation is reserved for every newly accepted draw of a batch before exposure. Odds are a fixed-point fraction (`1e18` scale), not basis points. The 1× rate with a `1.0 P` cap is kept in the model as a comparison row only. | notes 5, 8 | Phase 4 |
| D8. Public buys of resale open at hour zero; `publicBuyDelay` is a policy parameter at 0. | review 1, notes 9 | Phase 2 |
| D9. One prize wrapper, `PrizePack`, carries both modes and replaces Draw Packs. | review 1, notes 9 | Phase 3 |
| D10. Capital protection stays: an explicit distribution gate decides when retained surplus may leave the game, and a retirement lifecycle (no successor migration) stays. | notes 6 | Phase 3 |
| D11. Scheduled farming tokens and purchased reward tokens are accounted separately with their own conservation equations and one claim interface. Purchase budgets attribute to their source epoch. An epoch is final only when every request accepted in it has a terminal FWA status. | notes 7 | Phase 3 |
| D12. One multisig everywhere. A 72 hour timelock in front of every setter that can raise spending or weaken a guard, on the hook and the game. Direct multisig calls: pauses that stop new risk and tighten-only changes. Fork integration is the acceptance environment; Sepolia is a rehearsal. The shutdown notice is 30 days; the timelock is 72 hours. | review 1, notes 8, 10 | Phase 2, 3, 5 |

Open for the owner (not blocking phase 1 or 2): the mint fee stays the creator's income with disclosure
and no subsidy promise (notes 9); the 1.122 ETH ordinary buffer is the operating coverage floor of D10.

### Revision 3 changes (notes2), each verified before it was adopted

| notes2 | Verified | Change |
| --- | --- | --- |
| 1 | `retryNFTDelivery` reverts `DeliveryWindowElapsed` at the deadline; `refundFailedDelivery` is purchaser-only; no status changes on its own (vendored `FWAClone.sol`) | Epoch resolution cursor classifies a `DeliveryPending` past its deadline as ineligible for rewards without touching the purchaser's refund; late Fulfilled requests are credited by the same cursor (section 5) |
| 2 | A curve sale does not move the pool; a range containing the current price needs both assets; pool `sqrtPriceX96` is ENGINE per ETH with ETH as `currency0` | Executable sequence rewritten: the pool swap at the curve price limit moves the pool first, bids go strictly below the pool's price after the swap, orientation and Q96 conversion stated (section 2). I17 split into commitment and current-asset reconciliations. "Passes by construction" removed |
| 3 | Exponential curve clears for 175.89 ETH; the position for 142.30 ETH; `0.05 / p0` is 1,000,000 against an exact 998,723 | Curve is the concentrated-liquidity formula of the brief's position held virtually, so it is the same curve; the exponential is dropped. `minOut` is the exact curve quote for the whole budget, which is a true floor for the route |
| 4 | `afterSwap` runs before the router settles; ERC-6909 claims settle without an ERC20 transfer | Authorisation is a transient allowance set in `afterSwap` from the actual delta, consumed by gated transfers for the rest of the transaction, never cleared early. The promise is narrowed: original inventory custody is structural; circulated tokens can move through 6909 claims and other pools, tested and disclosed. Routers using the canonical pool work |
| 5 | v4 has no TWAP | `finaliseEpoch` finalises counts, weights and the scheduled allocation only. Purchased rewards are tranches executed separately against the finalised cohort; execution protection is the curve floor during genesis and bounded size and rate with a caller `minOut` after it |
| 6 | 1.122 = 4 − 2.730 − 0.148 already; FWA deletes the pending record on completion | Operating floor 1.122 ETH; pack terms snapshotted on the accepted request and bound at award verification; the wrapper records `deliveredAt` in its own transfer hook when FWA delivers; the deadline guard is on the primary buy itself |

## 1. Target architecture

| Contract | New or changed | Role | Enforced outside the replaceable module |
| --- | --- | --- | --- |
| `Pool` + `PoolAdmin` + `PoolListing` + `PoolBooks` + `PoolStorage` | changed | The FWA game: board, settlement, buckets, keeper refunds, GRAIL, foreign listings (reused). Records every accepted request for genesis. Distribution gate. Retirement. | Owner proceeds split by fixed bps; retained surplus leaves only through the gate, only to `Treasury` |
| `Treasury` | new (patterns from `EngineTreasury`) | Buckets: reserve, retained, Punk fund, liquidity fund, GRAIL routing. ENGINE purchases for rewards and burns, fee allocation, sponsor reservation and payment, Punk acquisition. | ETH leaves only to the hook (purchase), the GRAIL fund, a sponsor's accrued compensation, a Punk acquisition it executes, or the game's operating coverage |
| `PrizePack` | new | ERC721 wrapper around Shapes for every multi-Shape prize and every ENGINE prize. Mode fixed at mint; haircut and exit delay bound from the winning request at award verification. | A pack redeems exactly once; backing goes to the holder or to the holder's purchase |
| `Engine` | new | ERC20, 1e9 minted once to `Genesis`. Transfer gate (section 3) until the deadline. | No mint; gate ends at the deadline by code |
| `Genesis` | new | Epoch ledger, scheduled 100 million custody, purchased reward custody, claims, burns. Hands 900 million to the hook at `start()`. | 14 × 86,400 s from `startedAt`; schedule constants; credit only from `Pool` |
| `EngineHook` | new | v4 hook: original inventory curve, primary proceeds account and bid deployment, fee matrix, transfer authorisation, liquidity gating, finalizer. | Fee cap 500 bps; original inventory leaves only by authenticated buy or finalizer burn; primary proceeds only to bid liquidity; finalizer once, after the deadline, by anyone |
| `HookPolicy` | new, replaceable through the timelock | Fee level (≤ 500), `publicBuyDelay`, per-swap limits. | Replaced only by `Timelock` |
| `Sponsorship` | reused and adapted (`PrizeSponsorship`, `SponsorOffer`) | Posted offer, acceptance, per-draw accrual, reservation, reclaim, early win, cap. | Compensation reserved before exposure |
| `Timelock` | pinned OpenZeppelin `TimelockController` from `lib/shapes` | 72 hours. | |
| `Lens` | changed | Views for every contract above. | |

### Invariants

I1, I2, I5, I6, I7 stay with NAV terms replaced by the game's asset ledger (section 4). New:

- I8 `Engine.totalSupply()` ≤ 1e9, never increases.
- I9 Original released + original burned + hook original balance = 900 million.
- I10a Scheduled farming: claimed + claimable + reserved for open epochs + burned = 100 million.
- I10b Purchased rewards: claimed + claimable + held for open epochs = purchased; never mixed with I10a.
- I11 Every credited request maps to one FWA request with terminal status Fulfilled; refunded, expired and refunded-delivery requests carry no credit.
- I12 A `PrizePack` is in one state: listed, held, awarded-unredeemed, redeemed-to-ENGINE, redeemed-to-ETH, exited-to-ETH. Shapes leave only in the last three.
- I13 Treasury ETH out = ENGINE purchases + GRAIL funding + sponsor compensation + Punk acquisitions + coverage transfers to the game.
- I14 Sponsor compensation accrued ≤ `1.5 P` and ≤ reserved; every accepted draw while active had its compensation reserved before acceptance.
- I15 Fee receipts allocated = fee receipts collected.
- I16 After `finalise()`: hook original balance 0, gate open, every restriction lifted.
- I17a Primary proceeds received = primary proceeds committed to bid positions + pending deployment (historical commitment).
- I17b For every hook-owned position, current ETH + current ENGINE reconcile to its deposits plus the swaps that crossed its range (current assets); the ENGINE it holds is circulated, never original (notes2 2).
- I18 Game ledger: `cash ≥ openLiabilities + replacementOwed + operatingFloor` after every distribution; retained swept ≤ cumulative positive margin − cumulative realised losses.
- I19 Transfer gate: during genesis every ENGINE ERC20 transfer is one of the authenticated paths of section 3. (ERC-6909 claim movements are outside the gate and are disclosed, section 3.)
- I20 No original token leaves the hook at or after `Genesis.deadline()` except by the `finalise()` burn, whether or not `finalise()` has been called.

## 2. The market (answers notes 2 and 8, notes2 2, 3, 6)

### Assets and accounts in the hook

| Account | Holds | In | Out |
| --- | --- | --- | --- |
| `original` | ENGINE never released, 900 million at start | `start()` | authenticated buy before the deadline; `finalise()` burn |
| `primaryProceeds` | ETH paid for original tokens, until deployed | authenticated buy from the curve | bid liquidity, same transaction |
| bid positions | hook-owned, ETH-only ranges strictly below the pool's price at placement | primary proceeds; the 0.25 ETH seed; the liquidity fund share of fees | never withdrawn during the hook's life; after sellers trade through a range it holds circulated ENGINE, which stays in the position |
| `feeReceipts` | ETH fees from public swaps, as ERC-6909 claims | fee matrix | `Treasury.pullFees()` keeper call |

The canonical pool holds circulated ENGINE and ETH only. Nothing original is ever in a position.

### Orientation

Native ETH is `currency0`, ENGINE `currency1`. The pool's `sqrtPriceX96` is `sqrt(ENGINE per ETH) × 2^96`;
both tokens have 18 decimals, so no further normalisation. The brief and this plan quote prices as ETH per
ENGINE, `p`. Conversions: `sqrtPriceX96(p) = sqrt(1 / p) × 2^96`; a buy of ENGINE with ETH is `zeroForOne =
true` and moves `sqrtPriceX96` down; an ETH-only position (holds `currency0`) occupies ticks strictly above the
current tick, which is the range of prices below the current `p`. `CurveLib` carries these conversions and
the tick rounding, with unit tests at the boundaries.

### The curve

The curve is the brief's "initial primary position" held virtually: a single concentrated-liquidity range
`[p0, 10 p0)` with `p0 = 5e-8` ETH per ENGINE holding `X = 900 million` ENGINE, so `L = X / (1/√p0 − 1/√(10 p0))`,
`ETH to clear = L (√(10 p0) − √p0) ≈ 142.30`. For released quantity `q` the marginal price is
`p(q) = 1 / (1/√p0 − q / L)^2`; `CurveLib.tokensFor(ethIn, q)` and `ethFor(tokens, q)` are the standard
closed forms, rounding against the buyer. This is the same curve the brief and its model used (notes2 3),
so the model's primary-sale arithmetic carries over; the liquidity placement below does not, and is re-run.
The exponential curve of revision 2 is dropped.

### Authenticated buy: executable sequence

Input: a receipt `(source, beneficiary, budgetWei, minOut, nonce)` issued by `PrizePack` or `Treasury`,
consumed once. The hook runs the sequence inside its own `PoolManager.unlock`:

0. Deadline guard (notes2 6): if `block.timestamp >= Genesis.deadline()`, skip steps 2 and 3; the buy is
   pool-only and may fill partially. Original issuance stops at the deadline whether or not `finalise()`
   has run.
1. Pool leg. Let `pCurve = p(q)`. If the pool's price in ETH per ENGINE is at or below `pCurve`, swap exact
   input `budgetWei` of ETH for ENGINE with `sqrtPriceLimitX96 = sqrtPriceX96(pCurve)` and the fee 0 flag.
   The pool fills through whatever ask liquidity exists until its price reaches `pCurve` or the budget is
   spent; through empty ranges the price moves to the limit with no fill. After this step the pool's price
   is `pCurve` exactly (budget not exhausted) or below it (budget exhausted in the pool). If the pool's price
   was above `pCurve`, this step is skipped.
2. Curve leg. `remainder = budget − spent`; `Δq = CurveLib.tokensFor(remainder, q)`; `original −= Δq`;
   `q += Δq`; `primaryProceeds += remainder`. The curve price is now `p(q) > pCurve`; the pool's price is
   unchanged by this step.
3. Bid placement. Let `tickNow` be the pool's current tick after step 1. Add an ETH-only position of
   `primaryProceeds` over the ticks from `tickNow + spacing` (first initialisable tick strictly above
   the current tick, which is strictly below the current `p`) up to the tick for `p / 10`. The range never
   contains the current tick, so it takes ETH only and no ENGINE (notes2 2). `primaryProceeds` returns to
   zero. The position's upper price in ETH per ENGINE is therefore the pool's price after the swap, not the
   new curve price.
4. Delivery. `filled + Δq` ENGINE to `beneficiary`; the gate (section 3) authorises exactly this transfer.
   Revert the whole call if `filled + Δq < minOut`.

`minOut` for a `Treasury` receipt is `CurveLib.tokensFor(budget, q)` computed at execution, rounded down:
the route delivers at least that because the pool leg executes at or below the curve price everywhere
(notes2 3). A `PrizePack` receipt carries the holder's own `minOut`.

What this sequence does and does not establish: the pool's price trails the curve by one purchase; the new
bids sit immediately below the pool's price, so a seller after step 4 sells into them at close to
`pCurve`. Whether the depth the sequence creates supports the brief's scenarios is the subject of the phase 2
rerun, not an assumption (notes2 2). The first acceptance test (notes 2, verbatim) remains: a 0.05 ETH
ENGINE mode pack buys; the holder sells everything at once; the test prints the holder's, the pool's, the
hook accounts' and each bid position's ETH and ENGINE before and after and asserts I9, I17a and I17b and
that the sale was filled by the position step 3 created.

### Public swaps and the fee matrix

| Swap | Specified currency | Fee on the ETH side taken in | Permission |
| --- | --- | --- | --- |
| Buy, exact ETH in | ETH | `beforeSwap`, positive specified delta on ETH | `beforeSwapReturnDelta` |
| Buy, exact ENGINE out | ENGINE | `afterSwap`, delta on the unspecified currency (ETH) | `afterSwapReturnDelta` |
| Sell, exact ENGINE in | ENGINE | `afterSwap`, delta on the unspecified currency (ETH) | `afterSwapReturnDelta` |
| Sell, exact ETH out | ETH | `beforeSwap`, positive specified delta on ETH | `beforeSwapReturnDelta` |

Permissions: `beforeSwap`, `beforeSwapReturnDelta`, `afterSwap`, `afterSwapReturnDelta`,
`beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterInitialize`. The fee is `policy.feeBps()` (≤ 500) of the
ETH amount actually moved, so a partial fill at a price limit pays on the filled part. Fees accrue as
ERC-6909 claims on ETH in `feeReceipts`; `Treasury.pullFees()` collects. No treasury call and no liquidity
change inside a public swap (notes 8). Public buys revert while `block.timestamp < startedAt +
publicBuyDelay` (launch 0). Any router that swaps on the canonical pool works and pays the fee (notes2 4).

### Liquidity policy

The liquidity fund (10 percent of fees) is deployed by a bounded keeper call `deployLiquidity()` as ETH-only
ranges strictly below the pool's price at the time of the call, the same shape as step 3. No full range
positions: the hook owns no circulated ENGINE to pair, and it never takes original inventory for this
(notes2 2). `beforeAddLiquidity` and `beforeRemoveLiquidity` admit only the hook during genesis and anyone
after.

### Finalise

Anyone, once, after the deadline: `Engine.burn(original)`, `original = 0`, `Genesis.recordBurn`, liquidity
open. No position is moved. The deadline guard of step 0, not this call, is what stops issuance (notes2 6).

## 3. The transfer gate (answers notes 3, notes2 4)

`Engine._beforeTokenTransfer(from, to, amount)` during the restricted period:

| Path | Allowed when |
| --- | --- |
| Farming or reward claim | `from == Genesis` |
| Delivery of an authenticated buy | `from == EngineHook` and the hook's transient `deliveryTo == to`, `deliveryAmount == amount` |
| Burn | `to == address(0)` and `from` is `EngineHook` or `Treasury` |
| Canonical pool, user side | `from` or `to` is `PoolManager`, and `EngineHook.consumeAllowance(from, to, amount)` succeeds against the transient allowance below |
| Canonical pool, hook side | `from` or `to` is `PoolManager` and the counterparty is `EngineHook` inside the hook's own unlock |

Allowance (notes2 4): `afterSwap` on the canonical pool, where the swap's delta is known, adds the exact
ENGINE amount and direction to a transient allowance keyed by the pool id. Gated transfers between any
account and `PoolManager` consume it. It is never cleared by the hook; transient storage ends with the
transaction, so a router that settles after `afterSwap`, settles net across several swaps, or settles at
the end of a multi-call unlock finds the allowance in place. Test: whole unlock and settlement
transactions through a periphery router, with one swap, several swaps and net settlement.

What the gate enforces and what it does not (notes2 4): original inventory never leaves the hook except by
an authenticated buy, which is custody, not the gate. Circulated ENGINE that a user holds as ERC-6909 claims
inside `PoolManager` can be used in another pool without any ERC20 transfer, so during genesis circulated
tokens can trade outside the canonical pool and outside its fee. The brief already allows this ("later
markets may not pay the canonical fee"); the plan states it for genesis too, and the test suite shows it
rather than claiming otherwise. The restricted period runs from deployment until `Genesis.deadline()`;
`deadline()` returns `type(uint64).max` until `start()`, so unset means closed (notes 3). The gate is
demonstrated by `test/fork/EngineGate.t.sol` before anything is built on it.

## 4. The game ledger, distribution gate and retirement (answers notes 6)

Buckets stay as in SPEC 4 minus `claims`: `cash`, `backing`, `receivable`, `maintenance`, `grail.fund`,
plus `foreignReceivable` from the reused foreign listings. NAV as a share price goes; the game's asset
ledger stays as views:

- `openLiabilities`: FWA escrow the game may have to refund is FWA's, not the pool's, so this is the
  value of listed items selected by requests not yet booked (bounded by `unsettledAcquisitionCount` ×
  largest listed backing).
- `replacementOwed`: `mintLineOwed` plus the backing of queued replacements not yet funded.
- `operatingFloor`: parameter, launch 1.122 ETH, the brief's liquid remainder (already net of the opening
  mint fees; notes2 6).
- `realisedLoss`: cumulative negative margin, carried as today.

Margin split per settled capture is unchanged in shape: `mintLineOwed` first, then
`retainedBps : maintenanceBps : feedBps` = 200 : 200 : 100, with negative margin carried forward.
Retained accrues to a `retainedCredit` ledger inside `cash`; it does not leave the game at harvest.

Distribution gate, `Pool.distribute()` by anyone:
`amount = min(retainedCredit, cash − openLiabilities − replacementOwed − operatingFloor)`, zero if negative,
and only while `realisedLoss` is fully repaid. `amount` goes to `Treasury.receiveRetained(epochTag)` with the
epoch tag of the captures that produced it (section 5). Tests order outcomes adversely: fifty cheap
captures then the 0.5 ETH capture, the 0.5 ETH capture first, two 0.5 ETH captures in one batch.

Retirement (`startExit()` by the timelock, or by the multisig after a 30 day notice recorded on chain):
disables FWA purchases, settles every request, withdraws unawarded listings and redeems them into `cash`,
returns the sponsored asset under its agreement, redeems protocol owned prize assets after obligations,
folds `maintenance` into the game's `cash`, and sends the residual to `Treasury.receiveResidual()`, which can
spend it only on bounded `buyAndBurn`. No successor import, no `migrateHolder`.

## 5. Genesis accounting (answers notes 7, notes2 1, 5, 6)

Two ledgers in `Genesis`, one claim interface:

- Scheduled: `100_000_000e18 / 14` per epoch, remainder to epoch 13; 80 percent equal, 20 percent by
  bonus points, bonus portion joins equal when no points; empty epoch burns; division dust burns (I10a).
- Purchased: tranches. Retained surplus is tagged at capture with the capture's epoch. Whenever a tagged
  budget is distributable, `Treasury.executeRewardPurchase(e, maxBudget)` (anyone, bounded) spends up to
  `maxBudget` of epoch `e`'s tag on an authenticated buy and credits the tokens as tranche `t` of epoch `e`,
  divided by the finalised weights of `e`. Later distributable earnings attributable to `e` simply form
  later tranches; nothing is redirected to another epoch (notes2 5). Execution protection: before the
  deadline the curve floor (`minOut` of section 2); after it, bounded size (at most 0.05 ETH per call) and
  rate (one call per block) with a caller-supplied `minOut`, and a cap per epoch tag so a mispriced call
  cannot drain a tag. No oracle (notes2 5). Surplus from captures booked after the deadline is not reward
  budget; it goes to `buyAndBurn` as the brief says.

Attribution: `Pool.acquire` records `(requestId, purchaser, acceptedAt)` and snapshots the pack terms
(haircut, exit delay) on the request; `Genesis.accept` stores the epoch and appends the request id to the
epoch's list. Credit is granted when the request's FWA status is Fulfilled: by `Genesis.credit` from the
pool's walk, or by the resolution cursor below for a request the walk passed as `DeliveryPending`.

Resolution (notes2 1): `Genesis.resolve(e, max)` by anyone, bounded, advances a cursor over epoch `e`'s
request list from where it stopped, classifying each request from FWA's live state:

| FWA state | Classification |
| --- | --- |
| Fulfilled, not yet credited | credit now |
| Fulfilled, credited | skip |
| Refunded, Expired, DeliveryRefunded | ineligible |
| DeliveryPending with `pendingDeliveries[listingId].deadline <= block.timestamp` | ineligible for rewards; the purchaser's `refundFailedDelivery` right is untouched. After the deadline FWA allows no retry, so this request can never become Fulfilled |
| Pending, Ready, or DeliveryPending before its deadline | stop; not resolvable yet |

`finaliseEpoch(e)` requires the epoch to have ended and the cursor to have reached the end of the list.
It finalises success counts, bonus points and the scheduled allocation only; scheduled claims open at
once and do not wait for any purchase (notes2 5). The wait is bounded by FWA's 7 day delivery window plus
one keeper call, whatever any purchaser does. Acceptance test (notes2 1): one request fails delivery and
its purchaser never acts; every other successful purchaser claims the correct reward after the deadline.

Pack rights (notes2 6): `PrizePack` records `deliveredAt[packId] = block.timestamp` in its own transfer
hook when `from` is the FWA pool, which is the delivery path FWA actually takes. `registerAward(packId)` by
the holder reads the pool's `(listingId → requestId)` record made at booking (written for Fulfilled and
DeliveryPending alike), verifies at FWA that the listing is Settled to this holder's lineage, and binds the
request's snapshotted terms to the pack. The 48 hour clock runs from `deliveredAt`. Test matrix: delivery
before bookkeeping, delayed delivery after write-off, refunded delivery, transfer before redemption,
settlement after the deadline, authenticated buy after the deadline without `finalise()` (pool-only).

## 6. Admin powers (answers notes 8)

| Call | Authority |
| --- | --- |
| Raise `tipWei`, `maxGasPrice`, `batchMin`, `batchMaxAge`, `maxBatch`, `concurrency`; lower `minActiveOutcomes`, `maintenanceFloor`, `operatingFloor`; change fee split, mix, GRAIL parameters, sponsorship offer, `HookPolicy`, haircut, `publicBuyDelay`; `adminCall`; `startExit` | Timelock, 72 hours |
| Lower `tipWei` and the other spending tunables; raise the guard floors; `setPaused(true)`; `pauseNewRisk()` on the hook | Multisig, direct |
| `setPaused(false)` | Timelock |

`tipWei` keeps its hard cap of 0.01 ETH; the refund formula is unchanged, so a tip raise through the
timelock is visible three days before it can spend maintenance.

## 7. Phases

Order follows notes 10: recover, prove the market, re-model, then refactor the game.

### Phase 1. Recover and specify

- Check `docs/engine/model/` in from the companion archive. Record in `OWNER_QUESTIONS.md` entries 44
  onward the decisions D1 to D12 and the superseded first pass.
- Cherry-pick onto this branch, from `claude/next` and `feat/coin-funded-engine`: foreign listings (the
  `src/Pool*.sol`, `IPool.sol`, `IForeignController.sol` and `PoolForeign.t.sol` changes, SPEC 11 text), the
  EIP-7825 batch sizes, the gas-priced VRF fee note, `test/fork/engine/EngineBase.sol`, `EngineGas.t.sol`,
  `PrizeSponsorship.sol`, `EngineSponsor.t.sol`, `SponsorOffer.sol`, `SponsorOffer.t.sol`, `PUNK_VALUE.md`,
  `script/survey/`, `sim/engine.mjs`. Record what was taken and what was left in `docs/engine/REUSE.md`.
- Rewrite `docs/SPEC.md` as the v2 build input with sections 2 to 6 of this plan as the new material and
  the depositor sections removed. Write `docs/external/uniswap-v4.md` and `docs/external/wrapped-punks.md`.
- Pin `lib/v4-core` and `lib/v4-periphery`; add the mainnet `PoolManager` to `deployments/dependencies.json`;
  move `FORK_BLOCK` once to a block after the v4 mainnet deployment and the FWA factory state the brief
  asks to verify, then pin it.

Exit: owner sign-off on SPEC.

### Phase 2. Market proof on the mainnet fork

Files: `src/Engine.sol`, `src/EngineHook.sol`, `src/HookPolicy.sol`, `src/lib/CurveLib.sol`, a minimal
`Genesis` stub exposing `deadline()` and `start()`, `script/MineHookAddress.s.sol`,
`test/fork/EngineGate.t.sol`, `test/fork/EngineHook.t.sol`, `test/unit/CurveLib.t.sol`.

Demonstrations, each a fork test against the deployed `PoolManager`, and the mandatory proofs before phase 3
(notes2, "What I would approve now"):

| Proof | Test |
| --- | --- |
| Primary purchase and immediate sale | The section 2 sequence for a 0.05 ETH pack from a fresh pool and from a pool whose price is above the curve; exact original release, bid placement ticks, sale proceeds and remaining assets reconcile (I9, I17a, I17b) |
| Public trading | A periphery router and a direct `unlock` both swap on the canonical pool and pay the fee; forged, replayed and over-budget receipts revert; no path releases original tokens but an authenticated buy |
| Fee and transfer handling | All four swap forms, a partial fill at a price limit, exact `pullFees` receipts; settlement after `afterSwap` with one swap, several swaps and net settlement; ERC-6909 claims used in a second pool, shown to work and documented as outside the fee |
| Gate | Every row of section 3 passes, everything else reverts, before `start()`, during genesis and after the deadline |
| Genesis closure | After the deadline and before `finalise()`, an authenticated buy is pool-only and releases nothing (I20); `finalise()` burns exactly `900e6 − released` (I16) |
| Reward availability | Stubbed `Genesis`: a failed delivery whose purchaser never acts does not block other claims after the deadline; a failed reward purchase does not block scheduled claims (full tests in phase 3) |

Fallback rule (notes2): if any proof fails or the rerun does not reproduce or explain the brief's figures,
build the brief's original design (original inventory in a position with a ledger) in the same harness,
run the same proofs and rerun, and document a recommendation. Phase 3 does not start on an unproven market.

Economic rerun: `sim/engine.mjs` adapted to this exact market (curve, bid deployment, fee matrix), run on
the brief's six scenarios plus zero, half and full ENGINE conversion, plus the sponsor comparison rows
(brief terms against the 1× / 1.0 P variant). Results in `docs/engine/MODEL_V2.md`. Phase 3 starts only
if the baseline game stands at zero conversion and the market figures are reproduced or explained.

### Phase 3. Game refactor and integration

Files: `src/Pool*.sol`, `src/interfaces/IPool.sol`, `src/lib/PricingLib.sol`, `src/Lens.sol`,
`src/Treasury.sol`, `src/PrizePack.sol`, `src/Genesis.sol` (full), `src/interfaces/*`.

- Remove: `deposit`, `withdraw`, `redeemAndDeposit`, `payClaims`, shares, `nav` as a price, `navCap`,
  `dailyVolume`, `EntryFee`, `turnoverBps`, `founderWindowSeconds`, `depositsOpenAt`, `Claim`,
  `_liquidateForClaims`, successor import, `migrateHolder`, `Lifecycle.Exported` as a migration state,
  `PricingLib.sharesFor`, `claimFor`, `entryFeeBps`, `entryContribution`, `chooseRow`, `_surprise`,
  `rowDepth`, `surpriseBps`, `restoreK`, `bandBps`, `reserveBps`, `boardItems()` as a NAV function,
  `createPack` and the Draw Packs handle (D9).
- Add: `fundOrdinary()`, the asset ledger views and `distribute()` (section 4), retirement (section 4),
  `MixRow.mode`, `boardDepth` 100 with like for like replacement, guards `maxGasPrice`, `minActiveOutcomes`,
  `maintenanceFloor`, genesis attribution calls, the admin split of section 6, `PrizePack` listing.
- `PrizePack`: `mint(shapeIds, mode)` by `Pool`; a transfer hook recording `deliveredAt` when FWA delivers;
  `registerAward` binding the request's snapshotted terms; `redeemToEth` for ETH mode at once;
  `redeemToEngine(minOut, deadline)` through a receipt; `exitToEth` after the bound delay at the bound
  haircut, haircut to `Treasury.allocateFees()` under its own line (D3).
- `Treasury`: buckets and flows of section 1; `allocateFees()` with the first GRAIL milestone rule;
  `buyForRewards(epochTag)`, `buyAndBurn`, `reserveSponsorCompensation`, `paySponsor`, `acquirePunk`,
  `receiveRetained`, `receiveResidual`, `pullFees`, `deployLiquidity` call-through.
- `Genesis`: section 5 in full.

Tests: rewrite `PoolAdmission`, `PoolDepth`, `PoolReplace`, delete `PoolExit` (replace with
`PoolRetire.t.sol`), add `PoolGuards.t.sol`, `PoolDistribute.t.sol` (adverse orderings), `Treasury.t.sol`,
`PrizePack.t.sol` (the delivery matrix of section 5), `Genesis.t.sol` unit and fork (all 14 boundaries, the resolution cursor and its five classifications, late
delivery credit, a stuck failed delivery, tranches and a failed tranche purchase, epoch 13 after the
deadline, pause does not move the calendar), invariant handlers for
I8 to I20. Sizes recorded in SPEC 3; gas receipts refreshed.

### Phase 4. Sponsorship, scenarios, operations

- `Sponsorship` from `PrizeSponsorship` and `SponsorOffer`: per-draw accrual at `2 P / 100,000` from the
  Punk fund, reservation for every accepted draw of a batch, cap `1.5 P`, reclaim, early win, cap
  transfer, exposure guard on live weight and pending requests, `oddsPerDraw` as a `1e18` fraction. Tests
  from `EngineSponsor.t.sol` and `SponsorOffer.t.sol` adapted, plus funding exhaustion mid-batch.
- `test/scenario/Genesis14Days.t.sol`: the brief's section 16 checks as one lifecycle at 100 and 300 draws
  a day, recorded in `evidence/play/`.
- Deploy: `script/Deploy.s.sol` order `Timelock`, `Engine` and `Genesis` (CREATE2 predicted pair),
  `PrizePack`, `Treasury`, `HookPolicy`, `EngineHook` at the mined salt, `Sponsorship`, `PoolAdmin`,
  `PoolListing`, `Pool`, `Lens`; env keys per value; postflight readback including setter authorities and
  hook permission bits; the Draw Packs guards removed. `DEPLOY.md` and `RUNBOOK.md` with the launch
  sequence (`fund*`, `createFwaPool`, `open`, initialise the pool, `Genesis.start()` when Live and the
  market is ready) and the keeper set (`settle`, `rotate`, `resolve`, `finaliseEpoch`, `executeRewardPurchase`, `distribute`,
  `pullFees`, `allocateFees`, `deployLiquidity`, `buyAndBurn`).
- Web: remove `/deposit`; add `/genesis`, `/pack`, the market view, `/sponsor` (reuse the engine branch's
  pages where the data model matches); first chart is the per draw split including the mint fee and FWA's
  protocol share; the cost table at 0.25, 1 and 5 gwei.

### Phase 5. Review and launch

Independent review of `EngineHook`, `Engine`, `Genesis`, `PrizePack`, `Treasury` and the `Pool` changes;
legal review (started in phase 1) closed; Sepolia rehearsal as a dry run of the scripts only; 72 hour
timelock and multisig set up; mainnet.

## 8. Brief and notes to work item

| Source | Where |
| --- | --- |
| Brief 1 to 4 | Phase 3 (funding, board, pricing, guards) |
| Brief 5 | Phase 3 (`PrizePack`), D3 |
| Brief 6, 7 | Phase 3 (`Genesis`), section 5 |
| Brief 8, 9 | Phase 2, section 2 |
| Brief 10 | Phase 3 (`Treasury.allocateFees`), section 2 liquidity policy |
| Brief 11 | Phase 4, D7 |
| Brief 12, 13 | Phase 2 model rerun, phase 4 evidence |
| Brief 15 | Section 6, phase 5 |
| Brief 16 | Phases 2 and 4 tests |
| Notes 1 | D2, phase 1 |
| Notes 2 | Section 2, D4, D5 |
| Notes 3 | Section 3, D6 |
| Notes 4 | D3 |
| Notes 5 | D7 |
| Notes 6 | Section 4, D10 |
| Notes 7 | Section 5, D11 |
| Notes 8 | Section 2 fee matrix, section 6, D7, D12 |
| Notes 9 | D8, D9, mint fee left as income |
| Notes 10 | Phase order, D12 |
| Notes2 1 | Section 5 resolution cursor |
| Notes2 2 | Section 2 sequence, orientation, I17a and I17b |
| Notes2 3 | Section 2 curve, `minOut` |
| Notes2 4 | Section 3 allowance and narrowed promise, phase 2 proofs |
| Notes2 5 | Section 5 tranches |
| Notes2 6 | Section 4 floor, D3, section 5 pack rights, I20, phase 2 fallback rule |

## 9. Sequencing and effort

```
Phase 1 (recover, spec) ─► Phase 2 (market proof, model) ─► Phase 3 (game, wrapper, genesis, treasury) ─► Phase 4 (sponsor, scenarios, ops, web) ─► Phase 5
```

Focused engineer weeks: phase 1, 1.5; phase 2, 3; phase 3, 4; phase 4, 2.5; phase 5, 2 plus the external
review's calendar. About 13 weeks serial. Phase 2 is the gate: if the market proof or the rerun fails, the
fallback is the brief's original design (original inventory as a position with a ledger), which the
phase 2 harness can also test, and nothing in phase 3 depends on which one won.

## 10. Repository rules this plan keeps

- Solidity 0.8.28, the compiler profiles, via_ir restrictions and remappings. New contracts default to
  the legacy pipeline and join the via_ir list only when measured over the limit, recorded in SPEC 3.
- One Solidity writer per repo; phases are serial, so one branch at a time.
- Real Shapes, FWA, Wrapped CryptoPunks and `PoolManager` on the pinned fork as the acceptance environment
  (D12). Sepolia is a rehearsal of scripts.
- `script/deploy.sh <env>` with values-only env files and every existing guard.
- Every brief value lands in `script/env/*.env` except the constants enforced outside the replaceable
  module (supply, schedule, fee cap, first offer cap, timelock delay).

## 11. Risks

- **Phase 2 may not reproduce the brief's market figures.** The curve is the brief's position held
  virtually, but the bid placement is new. Mitigation: the harness tests both designs; the decision is made
  on the rerun.
- **Gate correctness.** A missed path blocks users or opens a bypass. Mitigation: it is the first thing
  built and demonstrated.
- **Epoch finality waits on FWA's delivery window.** One failed delivery delays an epoch's scheduled claims
  up to 7 days, never longer: the resolution cursor classifies it at the deadline without the purchaser.
- **Bid depth may not match the brief's model.** Bids trail the curve by one purchase and are one-sided.
  Mitigation: the phase 2 rerun decides, with the fallback rule.
- **Bytecode.** `Pool` family within 3 KB of the limit on `main`, and the foreign listings add to it.
  Mitigation: depositor removal frees more than the additions; measured at phase 3.
- **Sponsor uptake and uptime.** Published, tested, optional.
- **No Forge in the planning container.** Nothing here has compiled.
