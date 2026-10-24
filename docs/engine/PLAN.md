# ENGINE implementation plan

Revision 2, 2026-10-24. Input: [BRIEF](BRIEF.md). Findings: [REVIEW](REVIEW.md). Correction pass:
[NOTES_2026-10-24](NOTES_2026-10-24.md), the brief author's reply to revision 1; each numbered section of
that reply is answered here and cited as "notes N". Base: `main` at `4a13a09`. Reused branches:
`origin/feat/coin-funded-engine` (PR #7, `2c70c15`) and `origin/claude/next` (PR #5, `7afd772`), both fetched.
Nothing in this plan is built yet.

## 0. Decisions

| Decision | Source | Affects |
| --- | --- | --- |
| D1. Base is `main`. The depositor layer (shares, NAV as a share price, entry fee, volume cap, founder window, withdrawal claims, claim liquidation, successor migration) is removed. The creator's 5 ETH enters through typed funding calls. | review 1, notes 1, 6 | Phase 3 |
| D2. Reuse from the two PR branches, selectively: foreign listings (`registerForeign`, `repriceForeign`, `withdrawForeign`, `foreignListings`, SPEC 11 text, `test/fork/PoolForeign.t.sol`, identical on both branches); `PrizeSponsorship` and `test/fork/engine/EngineSponsor.t.sol` as the sponsor base; `SponsorOffer` (standing offer any holder can take) and `docs/PUNK_VALUE.md` plus `script/survey/` as the evidence for P; `test/fork/engine/EngineBase.sol` and `EngineGas.t.sol` as the harness; the EIP-7825 listing batch size of 12 and the VRF fee priced at the transaction gas price; `sim/engine.mjs` as the model base; `docs/SECURITY_REVIEW.md` and `AUTONOMOUS_DECISIONS.md` as reference. Not reused: `FoundingRound`, `IArtcoins`, the Artcoins market, founder splits, `FeeSplit` mint fee routing, `boardNavCap`. | notes 1 | Phase 1 |
| D3. The 48 hour ETH exit of an ENGINE mode pack pays `backing × (10,000 − haircutBps) / 10,000`, haircut launch value 500. The haircut and the exit delay are snapshotted into the pack at the request's acceptance; a later parameter change applies to later prizes only. Exit haircuts are reported as a separate line from market fees. The model and the published tables carry zero, half and full conversion; the baseline game must stand at zero. | review 1, notes 4 | Phase 2, 3 |
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

## 1. Target architecture

| Contract | New or changed | Role | Enforced outside the replaceable module |
| --- | --- | --- | --- |
| `Pool` + `PoolAdmin` + `PoolListing` + `PoolBooks` + `PoolStorage` | changed | The FWA game: board, settlement, buckets, keeper refunds, GRAIL, foreign listings (reused). Records every accepted request for genesis. Distribution gate. Retirement. | Owner proceeds split by fixed bps; retained surplus leaves only through the gate, only to `Treasury` |
| `Treasury` | new (patterns from `EngineTreasury`) | Buckets: reserve, retained, Punk fund, liquidity fund, GRAIL routing. ENGINE purchases for rewards and burns, fee allocation, sponsor reservation and payment, Punk acquisition. | ETH leaves only to the hook (purchase), the GRAIL fund, a sponsor's accrued compensation, a Punk acquisition it executes, or the game's operating coverage |
| `PrizePack` | new | ERC721 wrapper around Shapes for every multi-Shape prize and every ENGINE prize. Mode, haircut and exit delay fixed at mint. | A pack redeems exactly once; backing goes to the holder or to the holder's purchase |
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
- I17 Primary proceeds received = ETH in hook-owned bid positions (principal) + pending deployment; never anywhere else.
- I18 Game ledger: `cash ≥ openLiabilities + replacementOwed + operatingFloor` after every distribution; retained swept ≤ cumulative positive margin − cumulative realised losses.
- I19 Transfer gate: during genesis every ENGINE transfer is one of the authenticated paths of section 3.

## 2. The market (answers notes 2 and 8)

### Assets and accounts in the hook

| Account | Holds | In | Out |
| --- | --- | --- | --- |
| `original` | ENGINE never released, 900 million at start | `start()` | authenticated buy; `finalise()` burn |
| `primaryProceeds` | ETH paid for original tokens, until deployed | authenticated buy from the curve | bid liquidity positions, same transaction |
| bid positions | hook-owned, ETH-only ranges below spot in the canonical pool | primary proceeds; the 0.25 ETH seed; the liquidity fund share of fees | never withdrawn during the hook's life (D5); after a sale moves spot through a range they hold ENGINE, which stays in the position |
| `feeReceipts` | ETH fees from public swaps | fee matrix | `Treasury.pullFees()` keeper call |

The canonical pool holds circulated ENGINE and ETH only. Nothing original is ever in a position.

### The curve

Price `p(q) = p0 × 10^(q / Q)` with `p0 = 5e-8` ETH, `Q = 900 million`, `q` = original released so far. The
tenfold range of the brief, as a geometric curve so each token sold moves the price by the same ratio; an
exact closed form lives in `CurveLib` with the integral for "ETH for Δq" and its inverse. Unit tests check
it against the brief's position arithmetic (a constant-product position over the same range clears for
about 142 ETH; the curve is calibrated to the same total).

### Authenticated buy: exact definition

Input: receipt `(packId or rewardEpoch, beneficiary, budgetWei, nonce)` signed by `PrizePack` or
`Treasury`, consumed once. The hook runs inside its own `PoolManager.unlock`:

1. Let `pCurve` be the curve price at the current `q`. Swap ETH for ENGINE in the canonical pool with
   `sqrtPriceLimitX96 = sqrt(pCurve)`, exact input `budgetWei`, fee 0 (authenticated). The pool fills up to
   the point where its price reaches the curve price, or exhausts the budget.
2. The unfilled remainder of the budget buys from the curve: `Δq = CurveLib.tokensFor(remainder, q)`,
   `original -= Δq`, `q += Δq`, `primaryProceeds += remainder`.
3. Deploy `primaryProceeds` as a bid position in the range `[pCurveAfter / 10, pCurveAfter)` (ETH only,
   ticks rounded down to the pool's spacing), owned by the hook. `primaryProceeds` returns to zero.
4. Deliver the pool fill plus `Δq` to `beneficiary`. The gate (section 3) authorises exactly this transfer.
5. Revert the whole call if the delivered amount is below the receipt holder's `minOut`.

Properties: the pool is always used first while it is cheaper (notes 2 routing rule, with the swap's own
price limit instead of a spot comparison); execution price is bounded above by the curve at every point;
the primary ETH is in the pool as bid depth before the transaction ends, so the first acceptance test
below passes by construction; no spot-price oracle is read.

The first acceptance test (notes 2, verbatim): an ENGINE mode pack of 0.05 ETH buys original tokens; the
holder immediately sells them all; the test prints ETH and ENGINE balances of the holder, the pool, the
hook accounts and the bid positions before and after, and asserts I9 and I17 and that the sale was
filled by the position step 3 created.

### Public swaps and the fee matrix

| Swap | Specified currency | Fee on the ETH side taken in | Permission |
| --- | --- | --- | --- |
| Buy, exact ETH in | ETH | `beforeSwap`, as a positive specified delta on ETH | `beforeSwapReturnDelta` |
| Buy, exact ENGINE out | ENGINE | `afterSwap`, as a delta on the unspecified currency (ETH) | `afterSwapReturnDelta` |
| Sell, exact ENGINE in | ENGINE | `afterSwap`, as a delta on the unspecified currency (ETH) | `afterSwapReturnDelta` |
| Sell, exact ETH out | ETH | `beforeSwap`, as a positive specified delta on ETH | `beforeSwapReturnDelta` |

Permissions therefore: `beforeSwap`, `beforeSwapReturnDelta`, `afterSwap`, `afterSwapReturnDelta`,
`beforeAddLiquidity`, `beforeRemoveLiquidity`, `afterInitialize`. The fee is `policy.feeBps()` (≤ 500) of
the ETH amount actually moved, so a partial fill at a price limit pays a fee on the filled part only.
Fees accrue in `feeReceipts` as ERC-6909 claims on ETH and are pulled by `Treasury.pullFees()`; no
treasury call and no liquidity change happens inside a public swap (notes 8). Public buys revert while
`block.timestamp < startedAt + publicBuyDelay` (launch 0).

### Liquidity policy

The liquidity fund (10 percent of fees) is deployed by a bounded keeper call `deployLiquidity()` as
ETH-only bid ranges below spot, the same shape as primary proceeds. No full range positions: the hook
owns no circulated ENGINE to pair with (notes 8). The tradeoff is one-sided support: the fund deepens the
bid, not the ask. `beforeAddLiquidity` and `beforeRemoveLiquidity` admit only the hook during genesis and
anyone after.

### Finalise

Anyone, once, after the deadline: `Engine.burn(original)`, `original = 0`, `Genesis.recordBurn`, gate open,
liquidity open. No position is moved. Protocol bid positions stay for the hook's life.

## 3. The transfer gate (answers notes 3)

`Engine._beforeTokenTransfer(from, to, amount)` during the restricted period:

| Path | Allowed when |
| --- | --- |
| Farming or reward claim | `from == Genesis` |
| Delivery of an authenticated buy | `from == EngineHook` and the hook's transient `deliveryTo == to`, `deliveryAmount == amount` |
| Burn | `to == address(0)` and `from` is `EngineHook` or `Treasury` |
| Canonical pool, user side | `from` or `to` is `PoolManager`, and `EngineHook.authorised(from, to, amount)` reads a transient record set in `beforeSwap` for this pool id, direction and maximum amount, and cleared in `afterSwap` |
| Canonical pool, hook side | `from` or `to` is `PoolManager` and the counterparty is `EngineHook` inside the hook's own unlock |

Everything else reverts `GenesisTransfer()`. The restricted period is from deployment until
`Genesis.deadline()`; `deadline()` returns `type(uint64).max` until `start()` is called, so an unset
deadline means closed, not open (notes 3). ERC-6909 minting of ENGINE inside `PoolManager`, a second pool,
or a router that does not go through the canonical pool all require an ENGINE transfer that no row
above authorises, so they cannot move tokens during genesis. The gate is demonstrated by
`test/fork/EngineGate.t.sol` in phase 2 before anything is built on it.

## 4. The game ledger, distribution gate and retirement (answers notes 6)

Buckets stay as in SPEC 4 minus `claims`: `cash`, `backing`, `receivable`, `maintenance`, `grail.fund`,
plus `foreignReceivable` from the reused foreign listings. NAV as a share price goes; the game's asset
ledger stays as views:

- `openLiabilities`: FWA escrow the game may have to refund is FWA's, not the pool's, so this is the
  value of listed items selected by requests not yet booked (bounded by `unsettledAcquisitionCount` ×
  largest listed backing).
- `replacementOwed`: `mintLineOwed` plus the backing of queued replacements not yet funded.
- `operatingFloor`: parameter, launch 1.122 ETH less the opening mint fees already spent, the brief's
  liquid remainder.
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

## 5. Genesis accounting (answers notes 7)

Two ledgers in `Genesis`, one claim interface:

- Scheduled: `100_000_000e18 / 14` per epoch, remainder to epoch 13; 80 percent equal, 20 percent by
  bonus points, bonus portion joins equal when no points; empty epoch burns; division dust burns (I10a).
- Purchased: `Treasury.buyForRewards(epochTag)` spends the retained surplus tagged to epoch `e` (the
  epoch of the captures that produced it, section 4) on an authenticated buy and credits the tokens to
  epoch `e`'s purchased pot, divided by the same equal and bonus shares (I10b). The buy for epoch `e`
  runs inside `finaliseEpoch(e)`, so the beneficiary cohort is fixed by economic source, not by keeper
  timing. During genesis the curve gives the buy a floor output, so `minOut = budget / pCurve` needs no
  oracle. After the deadline (epoch 13's late surplus) the buy is circulated only, with `minOut` from the
  pool's 30 minute TWAP less 5 percent; if unfillable it stays tagged and retries, never redirected.

Attribution: `Pool.acquire` records `(requestId, purchaser, acceptedAt)`; `Genesis.accept` stores the
epoch. Credit is granted by `Genesis.credit(requestId, randomWord)` when the request's FWA status is
Fulfilled, called from the pool's walk, or by anyone later through `Genesis.creditLate(requestId)`, which
reads FWA directly for a request the walk wrote off as DeliveryPending and FWA later completed.

Finality: `finaliseEpoch(e)` requires (1) the epoch has ended, (2) `nextSequenceToBook` passed the last
sequence accepted in `e`, (3) no request accepted in `e` is in status Pending, Ready or DeliveryPending at
FWA. FWA's `DELIVERY_WINDOW` (7 days) bounds the wait. A request that ends Refunded, Expired or
DeliveryRefunded earns nothing; one that ends Fulfilled earns, however late (notes 7).

Pack rights do not depend on the pool's walk: `PrizePack.registerAward(packId)` by the holder reads FWA's
listing and acquisition state and sets `awardedAt` from the delivery block's timestamp, so a pack delivered
after the write-off has its 48 hour clock and both redemption paths. Test matrix: delivery before
bookkeeping, delayed delivery after write-off, refunded delivery, transfer before redemption, settlement
after the deadline.

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

Demonstrations, each a fork test against the deployed `PoolManager`:

1. Gate: every row of section 3 passes and every other transfer reverts, before and after `start()`,
   and after the deadline everything passes.
2. Primary purchase then immediate sale (the first acceptance test, section 2).
3. Holder sale, public resale buy, fee capture on all four swap forms including a partial fill at a price
   limit, `pullFees()` exact receipts.
4. A second router, a direct `unlock`, ERC-6909 minting and a second pool all fail during genesis and
   pass after.
5. Forged, replayed and over-budget receipts revert.
6. `finalise()` burns exactly `900e6 − released`; I9, I16, I17 hold under a fuzzed sequence.

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
- `PrizePack`: `mint(shapeIds, mode, haircutBps, exitDelay)` by `Pool`; `registerAward`; `redeemToEth` for
  ETH mode at once; `redeemToEngine(minOut, deadline)` through a receipt; `exitToEth` after the snapshotted
  delay at the snapshotted haircut, haircut to `Treasury.allocateFees()` under its own line.
- `Treasury`: buckets and flows of section 1; `allocateFees()` with the first GRAIL milestone rule;
  `buyForRewards(epochTag)`, `buyAndBurn`, `reserveSponsorCompensation`, `paySponsor`, `acquirePunk`,
  `receiveRetained`, `receiveResidual`, `pullFees`, `deployLiquidity` call-through.
- `Genesis`: section 5 in full.

Tests: rewrite `PoolAdmission`, `PoolDepth`, `PoolReplace`, delete `PoolExit` (replace with
`PoolRetire.t.sol`), add `PoolGuards.t.sol`, `PoolDistribute.t.sol` (adverse orderings), `Treasury.t.sol`,
`PrizePack.t.sol` (the delivery matrix of section 5), `Genesis.t.sol` unit and fork (all 14 boundaries, late
delivery credit, epoch 13 after the deadline, pause does not move the calendar), invariant handlers for
I8 to I19. Sizes recorded in SPEC 3; gas receipts refreshed.

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
  market is ready) and the keeper set (`settle`, `rotate`, `finaliseEpoch`, `distribute`, `pullFees`,
  `allocateFees`, `deployLiquidity`, `buyAndBurn`).
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

- **Phase 2 may not reproduce the brief's market figures.** The curve and one-sided bids are not the
  original position. Mitigation: the harness tests both designs; the decision is made on the rerun.
- **Gate correctness.** A missed path blocks users or opens a bypass. Mitigation: it is the first thing
  built and demonstrated.
- **Epoch finality waits on FWA's delivery window.** One stuck delivery delays an epoch's claims up to
  7 days. Mitigation: disclosed; the pool's write-off keeps the game moving; `creditLate` keeps the credit.
- **Bytecode.** `Pool` family within 3 KB of the limit on `main`, and the foreign listings add to it.
  Mitigation: depositor removal frees more than the additions; measured at phase 3.
- **Sponsor uptake and uptime.** Published, tested, optional.
- **No Forge in the planning container.** Nothing here has compiled.
