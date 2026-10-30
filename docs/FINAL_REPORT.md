# Final report: Draw Shapes + ENGINE

Date: 2026-10-30. Branch: `claude/relaxed-goodall-mmbzpd` (PR #9). This covers the original build (D1–D30), the
sustainability follow-up (D31–D43), the collection-games review (D44–D52) and the fixes for an independent audit of
5494c33 (D53). The audit's findings are fixed; the fixes have not been re-audited.
Nothing was broadcast to any live network. No private key was created or used. Time manipulation happened only in
local fork tests and on a local anvil fork.

## Audit fixes (D53)

A fresh-discovery audit of 5494c33 (`docs/AUDIT_PROMPT.md`) reported nine findings, each with a fork reproduction. All
were verified and fixed, the ninth documented:

| # | finding | fix |
|---|---|---|
| 1 | a purchase naming Shapes or Packs as purchaser locked the prize in FWA's quarantine for good | the gate refuses those purchasers |
| 2 | the gate counted a live promotion as a board prize (a batch could leave 79 of 80) | the promotion is added to the floor |
| 3 | the true-up put promotional proceeds into ordinary profit | the difference goes to the promotion budget when a promotional capture is in the window |
| 4 | a full-range addition let ENGINE trade below its launch valuation | every position ends at the start price |
| 5 | a late ledger could dilute finalized genesis epochs | ledgers count from the epoch they were added in |
| 6 | `createPool` could be front-run with another salt between deploy transactions | salt fixed in the constructor; the deploy skips an existing pool; postflight checks the address |
| 7 | a caller-chosen shutdown price limit could leave ETH idle | `shutdown()` has no limit; empty additions revert |
| 8 | `FwaFeeBuyer` paid ETH left in it to the next caller | refunds only the caller's ETH |
| 9 | the promotion odds cap is checked only at the start | documented |

Consequence of fix 4: near the start price a shutdown places little ETH; the rest stays in ProtocolLiquidity for later
additions. Tests: 110 pass (8 new regressions in `test/fork/AuditFixes.t.sol` and `test/unit/Farm.t.sol`; the gate
invariant now subtracts a live promotion). FwaGame is 24,286 bytes (290 spare).

## Designs adopted from collection-games (D44–D52)

The owner asked which `ripe0x/collection-games` designs to adopt and approved: a zero-ETH single-sided launch; Shape
Packs (mainnet `0xf21514B0…5cA7`) as a prize; the purchase gate, step recovery, fixed booking, keeper pay, restock
cadence and exposure changes; FwaGame split in two; farm selling quantified without changing the split; the Shapes
board kept with Pack boards presented; the opening valuation proposed from a model.

- **PoolOwner** (D44) creates and owns the FWA pool, holds and lists prizes, mints Shapes and Packs with exactly the
  game's ETH, turns withdrawn or recovered prizes back into ETH, and is FWA's purchase operator. FwaGame keeps the
  books (24,195 bytes then; 24,286 after the audit fixes).
- **Purchase gate** (D45) on live FWA state: refuses past 10 in flight, outside the edge/cooldown range, or when the
  board would fall below 80% + a batch of 5 + every unsettled request. It binds FWA's own site and holds while nobody
  syncs: in a day-long keeper outage direct purchases stopped with 84 prizes in the draw; one sync booked all 16 pulls
  and reopened.
- **Step recovery** (D46): each `sync` step in its own `try`, `StepFailed` events; booking reads no module.
- **Booking** (D47) at the highest edge ever accepted, trued up to what FWA paid; markup and operating allocation
  frozen per listing.
- **Keepers** (D48): gas at the price paid (≤ 5 gwei, ≤ 0.05 ETH) plus a 0.0003 ETH hourly flat fee; seed 0.05 ETH;
  the vault tops KeeperFund up from trading fees within a 1 ETH lifetime limit, returned to the vault before any
  overflow reaches the game.
- **Restock and exposure** (D49): 3-row trigger, 5-minute interval (≥ 6 FWA cooldowns), only with nothing in flight
  unless near the gate's line; exposure = min(unsettled × costliest prize, inventory cost).
- **Single-sided launch** (D50): no ETH; start price from `START_TICK` (replaces `LAUNCH_ETH_WEI`), which also sets the
  rate cap. Recommended 184,200 (≈ 10 ETH FDV).
- **Shape Packs** (D51) minted with the fewest Shapes, redeemed on withdraw, recovery, conversion and retirement;
  tested end to end on the real contract. Launch board unchanged.
- **Keeper and site**: the keeper acts at once when the gate is closed with rows waiting; the site shows the gate,
  Pack prizes and converts either collection.
- A regression found and fixed during the split: the operating allocation had lost its edge division (5% too high);
  `test_pullFulfilledBookedToTheWei` caught it.

**Findings for the owner:**

1. **Farm selling can take the opening market's ETH** (D52). Public buys are closed through genesis and the rate cap is
   valued at the start price, so with no conversions, 1 ETH of opening buys and 20 ETH of genesis tickets, full farm
   selling returns the price to the start and opening buyers exit with nothing (with 25% of prizes converted they exit
   at 1.3×). Options: a smaller farm, a time-weighted rate cap (contract change), a lower start. Split unchanged.
2. **Start valuation**: 10 ETH FDV recommended; 5 ETH FDV favours opening buyers at the price of concentration (a 5 ETH
   opening leaves the largest buyer 24% of supply against 14%).
3. **Throughput**: limit 10 on 100 rows is best (0.02% refused at 10 ETH a day; 3.3% refused and 2.2% drift-refunded at
   50 ETH a day). Ten in-flight cheap captures in a row can trigger FWA's drift refund (8 of 10 settled in the fork test).
4. **Small boards**: the gate needs at least floor + 5 rows; a board under 25 rows needs `minLiveBps` below 80%.
5. **Pack board A** offers seven prize levels on half the board capital (7.72 ETH) with a rarer headline.

## Sustainability follow-up (D31–D43)

**Funding routes** (D31). ENGINE trading fees go from the hook straight to the PrizeVault and reach the game as capital,
all of them, even above any target. Realised, distributable game profit goes to a burn-only `Buyback`. Promotions have
their own budget. The `Treasury` with its sink table, the recurring player reward (half of every buyback deposited into
farm epochs), `GrailFund` and `GrailPolicy` were removed. The fee stays at 3%. The founder's only income is still the
Shapes mint fee.

**Accounting in FwaGame** (D32, D33):

- Inventory is capital carried at cost; a won prize's cost is recognised once, as its only expense.
- Revenue is owner proceeds. The operating allocation is 3% of the quote's expected replacement cost, paid to KeeperFund;
  KeeperFund's overflow returns.
- Profit is signed and cumulative, so losses carry.
- A distribution is the lesser of undistributed profit and cash above replacements owed, operating allocation owed, the
  reserve target and the settlement exposure. Capital never counts as profit.

**Admission and readiness** (D36):

- FWA's own purchase switch is opened and closed from `sync`, so the rules bind direct FWA purchases too: board fill,
  unsettled requests, FWA edge and cooldown, pause.
- `openGame` needs the 48-hour market, the full board and the reserve in cash.

**Board** (D35). The ordinary mix is the 100-item form of 6/9/5: 30 × 0.01, 45 × 0.05, 25 × 0.5 ETH at 5% markup.

**Genesis** (D34):

- Weight is eligible ticket ETH.
- Each epoch pays the lesser of its allocation cap and its eligible ETH times its rate cap: 14 steady epochs at F/17.5,
  then 87.5% … 12.5% on both caps.
- The end is fixed. `finalize` burns what an epoch can no longer pay, and claims never expire.
- Seasons, the 79% reserve, deposits, rollover and `shorten` were removed. The supply for a fresh deployment is 80% LP,
  19% genesis and 1% bonus.

**Promotions** (D37). Pre-funded, capped at the prize's cost, ending at a win or an end block, accounted apart. There
is no per-pull decay.

**Conversion and router** (D38). `convert` spends exactly the redeemed backing. The swap exempt set is fixed at
wiring, so no shared router can ever be whitelisted.

**Buyback** (D39). The slice is a maximum, one purchase per hour, 3% impact cap, and it refuses a price moved more than
2% since the block opened (the hook records the opening price). It burns everything it buys.

**Lens, site and keeper:**

- New views: books, funding, current inventory and probabilities, the modelled board, genesis caps.
- The site shows ticket price and VRF fee, current vs modelled prizes, recent verified wins (FWA events), genesis
  eligibility, taper, end block and claims, gameplay and promotional turnover, trading fees, realised profit, ETH spent
  on buybacks, ENGINE burned, and conversion purchases separately.
- The keeper runs sync, buyback, finalize and retireBonus.

## Assumptions verified

Each was checked against the vendored source, the fork, or both.

- Reference economics reproduced exactly: inventory 3.03 / 15.15 ETH, ticket 0.03012685, probabilities 74.5253% /
  24.1111% / 1.36357%, headline 1 in 73.34, 2.20941 ETH per headline, return 87.38365%, per 100 ETH 87.38365 / 3.31930 /
  2.72109 / 2.38095 / 4.19501.
- FWA quotes vs owner proceeds: the game's booked proceeds are within 1 wei of FWA's split and never above it (fork).
- Which inventory decides a request: the live pool at its ordered turn. Cheap prizes won first raise the fee 1.52% each
  on 100 items, and the seventh request on one quote is refunded at +10.46% (fork test).
- Early headline wins, replacements at the next window, settlement against a changed distribution, refunds, cooldowns,
  the outstanding-request limit, direct FWA purchases, maximum batches of 5 with every request booked, admission at the
  pool: all fork-tested.
- `setBool` does not bump FWA's inventory version. A pool has at most 10 outstanding VRF requests. A failed delivery can
  stay pending forever; only the purchaser can refund it (docs/external/fwa-v2.md section 18).
- VRF fee: 1.5M gas × gas price × 1.3 per pull, paid by the player (0.00195 ETH at 1 gwei).
- Keeper cost: the operating allocation pays a sync per 10 pulls up to about 1.6 gwei (fork measurement with each call its own transaction, as on mainnet).
- FWA is practical, so no venue change was made. The mint-after-result alternative was not needed and is not built.

## Recommended launch configuration and capital

`script/LaunchConfig.sol`:

- Board 30 / 45 / 25 Shapes (15.15 ETH at cost), markup 500, operating allocation 300.
- Reserve target 12 ETH; admission fill 80%; purchase gate: 10 in flight, a batch of 5 assumed, max edge 5%, max
  cooldown 5 min; restock trigger 3 rows, 5-minute interval; market lead 48 h.
- Start tick 184,200 (≈ 10 ETH FDV, single-sided); rate cap 10% of ticket ETH at the start price; buyback slice
  0.05 ETH, hourly, impact 3%, deviation 2%.
- Keepers: tip cap 0.05 ETH, gas price cap 5 gwei, overhead 70,000, flat fee 0.0003 ETH hourly; target 0.5 ETH, floor
  0.05 ETH; vault top-up target 0.1 ETH, ≤ 1 ETH over its life.

Owner-funded:

- Opening capital about 28 ETH (board + reserve + about 1 ETH working cash).
- No launch ETH (single-sided); set `START_TICK` before deploying.
- `KEEPER_SEED` 0.05 ETH; the FWA creation fee (50,000 FWA at spot + 5%).

## Tests and sims run

Totals after this round: 102 tests in 12 suites (unit 26; fork 63 including the new resilience suite and the gas
receipt; the invariant suite, 10 invariants and a fixed walk; the genesis rehearsal), all passing locally on the pinned
fork. New this round:

- **Resilience** (6): keeper outage with direct FWA purchases then recovery; reverting board and pricing modules;
  booking unchanged by markup, operating-allocation and edge changes; Shape Packs minted, listed, won, converted,
  recovered after a failed delivery and redeemed at retirement; keeper top-ups within the lifetime limit; a sync
  topping KeeperFund up.
- **Accounting**: full batches with requests in flight (a third batch refused; drift refunds counted); gate refusal
  counting in-flight requests; restock waiting for requests in flight.
- **Market**: single-sided launch position and rate cap; no sale before any buy; price never above the start and
  sellers taking out at most buyers' ETH.
- **Invariants**: keeper top-ups bounded and returned; booking never ahead of FWA; gate headroom; PoolOwner holds
  nothing.
- **KeeperFund unit**: the gas-plus-flat-fee formula, splitting earns no more, overflow to the vault first, bounds.
- **Sims**: `sim/launch.py`, `sim/throughput.py`, `sim/boards.py`; `sim/sustainability.py` updated to the gate,
  cadence and keeper pay.
- **Anvil rehearsal** (`script/rehearse-anvil.sh`, rerun): full `deploy.sh anvil` broadcast with postflight (41.6M gas
  estimated); readback shows the FWA pool owned by PoolOwner with PoolOwner as purchase operator; `launch()` with no
  ETH; 28 ETH opening capital, 100 listings with 12.85 ETH cash; `openGame` through the timelock; one player pull
  through FWA admitted by the gate. The Sepolia simulation passed as well. Forge stalled on network lookups through the session's proxy until run with
  `FOUNDRY_OFFLINE=true`, now set by the script.

From the sustainability follow-up, all on the pinned fork (block 26,279,000) with the real Shapes, FWA factory and VRF service (callbacks driven through
the real service), FWA token and hook, and the v4 PoolManager. Runs used a local anvil node forking a public archive RPC,
because the public endpoints rate-limit.

- **Unit** (25): farm schedule, caps, rate cap, zero participation, finality, never-expiring claims, frozen pots, cleanup
  while rewards are outstanding, bonus retirement, ledgers; KeeperFund tips and overflow to the game; modules, vault
  sources, token.
- **Fork** (55):
  - game 21: walk, booking to the wei, refunds, delivery refunded and never refunded, conversion, retirement;
  - accounting 15:
    - cheap prizes first with requests on an earlier quote;
    - several headlines early;
    - losses then trading fees then an attempted distribution;
    - zero trading fees over 120 pulls;
    - replacement capital preserved after burns;
    - operating allocation against measured keeper gas;
    - admission closing and reopening with settlement continuing;
    - external settings out of range;
    - outstanding limit and maximum batches;
    - delayed replacements and cooldown;
    - keeper calls without progress and with an empty fund;
    - promotions;
    - late settlement across the genesis end;
    - retirement with pending requests and unpaid obligations;
    - `openGame` readiness;
  - market 17:
    - gate exactly before, at and after the end block, at the ordinary fee;
    - a shared router cannot open the gate;
    - buyback burn-only, profit-only, slice maximum, impact cap whatever `minOut`, same-block price check, through the
      genesis end;
    - conversion top-up attempts;
    - vault shutdown, second game;
  - smoke 1, gas 1.
- **Invariants** (7 + a fixed walk, 12 runs × 40 calls): custody, books identity, ledger vs FWA, farm bounds, buyback
  spends only profit received, modules hold nothing, escrow.
- **Scenario**: the full 21-epoch genesis with late and out-of-order words and a timeout, finalization and claims, the
  gate lifting by itself, then three post-genesis days with no rewards and no trading fees (prizes replenished), a
  second game, and shutdown.
- **Deploy dry run**: `script/rehearse-anvil.sh` on an anvil fork: full `deploy.sh anvil` broadcast with postflight,
  then market launch, 28 ETH opening capital, board fill and `openGame` through the real timelock, and one player pull
  through FWA. It passed: 37.5M gas estimated for the deploy script; supply, governance and FWA pool owner read back;
  100 listings with 12.85 ETH cash; purchases open; sequence 1 issued.
- **Keeper and site**: keeper unit checks (`npm run check`); site typecheck and production build.
- **Sims**: `python3 sim/sustainability.py` (seeded; `sim/results/sustainability.md`). It covers:
  - reference economics and board comparison;
  - settlement drift and burst refunds;
  - VRF and execution costs;
  - 60-day paths (low, base, busy, clumped, adverse; no trading fees);
  - reserve sizing (200 × 90 days);
  - genesis rate-cap scenarios and the supply-split comparison.

  Every scenario is an assumption; its outputs are model results.

## Report

From docs/ECONOMICS.md.

- **Per 100 ETH of gameplay, expected:** backing 87.38, mint 3.32, operating 2.72, FWA 2.38, margin 4.20.
- **After execution costs, realised (60-day models, rerun with the gate, cadence and keeper pay of this round):** 3.4
  to 4.3 ETH profit per 100 ETH. The 5th to 95th percentile in the base case is +0.2 to +7.4. At 1 ETH a day a run
  loses money about one time in ten. Keeper cost was 2.0 to 2.9 per 100 ETH at 1 gwei against an allocation of 2.72;
  vault top-ups cover the difference within their 1 ETH limit.
- **Headline frequency:** 0.45 per ETH for a full board; 0.46 to 0.51 in play.
- **Availability:** rows wait 4 to 17 hours per 60 days with the 3-row trigger (39 to 137 before). The gate closed
  purchases about 12 minutes in 60 days, only in the clumped case.
- **Capital:** inventory 15.15 ETH; working cash about 1 ETH; reserve 12 ETH. With that reserve, 200 runs saw no cash
  shortfall; at 3 ETH, 97% did. KeeperFund target 0.5 ETH.
- **Distributable profit in tested paths:** never more than realised profit; zero while a loss is carried (fork tests
  and the invariant).
- **What pauses distributions or purchases:** docs/RUNBOOK.md, "Conditions that pause distributions or new purchases".

## Blockers and limits

- **Audit.** One independent audit was run and its findings are fixed (D53); the fixes are not yet re-audited, and
  an audit is not a guarantee (docs/SECURITY.md).
- **FwaGame size.** FwaGame is 24,286 bytes, 290 under the limit; further features need another module split.
- **Keeper gas.** At base fees above about 1.6 gwei the operating allocation does not pay for every sync. Keepers wait;
  settlement does not.
- **Buyback price check.** It defeats a same-block sandwich, not a manipulation held across a block boundary; the slice
  and the impact cap bound that.
- **Admission timing.** Resolved by the purchase gate (D45): FWA asks it before every purchase, without a sync.
- **Edge changes.** Proceeds are booked at the highest edge governance accepted and trued up to what FWA paid (D47).
- **Farm selling and the start valuation** (D50, D52): see the findings above.
- **Release gates:** the Sepolia simulation (`DRY_RUN=1 script/deploy.sh sepolia`) was rerun for this round and passed
  (everything except FWA, which Sepolia's older factory cannot create, and Shape Packs, which Sepolia lacks). CI on
  PR #9 reads `MAINNET_RPC_URL`.

## Implications for existing commitments

- No deployment exists, so no earned entitlement, reward or asset changes.
- The owner's earlier decisions 49, 52, 54, 55 and 56 are superseded by the follow-up; the record is entry 61 in
  docs/OWNER_QUESTIONS.md.
- Player-facing text changed: the Terms now say profit buybacks may be zero; recurring player buybacks and GRAIL decay
  are gone; the genesis page describes ETH-weighted rewards and the fixed end.
- A fresh deployment needs 28 ETH of opening capital instead of 3 ETH. Most of it is the board (15.15 ETH) and the
  reserve (12 ETH); both come back to the vault on retirement.

## Next steps that need the owner

1. Review docs/IMPLEMENTOR_DECISIONS.md D44–D52, especially the start valuation (D50) and farm selling (D52), and
   D31–D43 (supply split D40, reserve D41).
2. Choose `START_TICK` (start price and rate cap), the opening capital and whether to adopt a Pack board.
3. Have the audit fixes (D53) reviewed, ideally by the same auditor, before outside money is material.
4. Run the Sepolia simulation and CI with a private archive RPC; then `DRY_RUN=1 script/deploy.sh mainnet` and the
   owner's broadcast.
5. Raise the timelock delay before outside money is material.
