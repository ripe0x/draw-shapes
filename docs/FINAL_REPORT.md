# Final report: Draw Shapes + ENGINE, sustainability follow-up

Date: 2026-10-27. Branch: `claude/relaxed-goodall-mmbzpd` (PR #9). This follows the original build (D1–D30) with the
owner's follow-up: make the game sustainable after genesis. No independent audit has been done. Nothing was broadcast to
any live network. No private key was created or used. Time manipulation happened only in local fork tests and on a local
anvil fork.

## What changed

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
- Keeper cost: the operating allocation pays a sync per 10 pulls up to 2.12 gwei (fork measurement).
- FWA is practical, so no venue change was made. The mint-after-result alternative was not needed and is not built.

## Recommended launch configuration and capital

`script/LaunchConfig.sol`:

- Board 30 / 45 / 25 (15.15 ETH at cost), markup 500, operating allocation 300.
- Reserve target 12 ETH; admission fill 80%, max 20 unsettled, max edge 5%, max cooldown 5 min; market lead 48 h.
- Rate cap 10% of ticket ETH at the launch price; buyback slice 0.05 ETH, hourly, impact 3%, deviation 2%.

Owner-funded:

- Opening capital about 28 ETH (board + reserve + about 1 ETH working cash).
- `LAUNCH_ETH` 5 ETH; it also fixes the rate cap at deploy, so set `LAUNCH_ETH_WEI` before deploying.
- `KEEPER_SEED` 0.5 ETH; the FWA creation fee (50,000 FWA at spot + 5%).

## Tests and sims run

All on the pinned fork (block 26,279,000) with the real Shapes, FWA factory and VRF service (callbacks driven through
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
  then market launch, 28 ETH opening capital, board fill and `openGame` through the real timelock (results below).
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
- **After execution costs, realised (60-day models):** 3.4 to 4.3 ETH profit per 100 ETH. The 5th to 95th percentile
  in the base case is +0.9 to +7.0. At 1 ETH a day a run loses money about one time in ten. Keeper cost was 1.9 to
  2.7 per 100 ETH at 1 gwei, within the allocation.
- **Headline frequency:** 0.45 per ETH for a full board; 0.46 to 0.51 in play.
- **Availability:** rows wait 39 to 137 hours per 60 days for windows and keeper batching. Purchases close only under
  clumped or very busy play: 4 to 25 hours in 60 days.
- **Capital:** inventory 15.15 ETH; working cash about 1 ETH; reserve 12 ETH. With that reserve, 200 runs saw no cash
  shortfall; at 3 ETH, 97% did. KeeperFund target 0.5 ETH.
- **Distributable profit in tested paths:** never more than realised profit; zero while a loss is carried (fork tests
  and the invariant).
- **What pauses distributions or purchases:** docs/RUNBOOK.md, "Conditions that pause distributions or new purchases".

## Blockers and limits

- **No audit.** The accounting and admission code is new and should be reviewed independently.
- **FwaGame size.** FwaGame is 23,489 bytes, about 1.1 KB under the limit; further features need another module split.
- **Keeper gas.** At base fees above about 2 gwei the operating allocation does not pay for every sync. Keepers wait;
  settlement does not.
- **Buyback price check.** It defeats a same-block sandwich, not a manipulation held across a block boundary; the slice
  and the impact cap bound that.
- **Admission timing.** Admission is enforced at the next `sync`, so a burst inside one block can exceed the limits
  until then. FWA's own caps (5 per transaction, 10 outstanding VRF requests per pool) bound it.
- **Edge changes.** If FWA changes its edge between a request and its booking, that request's proceeds are computed at
  the new edge (D32). Admission closes above a 5% edge.
- **Low launch valuation.** With 80% of supply in the pool, genesis rewards are worth about 1.2 ETH at the launch
  price (D40).
- **Release gates not repeated here:** the Sepolia simulation (`DRY_RUN=1 script/deploy.sh sepolia`) was not rerun for
  this follow-up, and CI on PR #9 needs a private archive `MAINNET_RPC_URL`.

## Implications for existing commitments

- No deployment exists, so no earned entitlement, reward or asset changes.
- The owner's earlier decisions 49, 52, 54, 55 and 56 are superseded by the follow-up; the record is entry 61 in
  docs/OWNER_QUESTIONS.md.
- Player-facing text changed: the Terms now say profit buybacks may be zero; recurring player buybacks and GRAIL decay
  are gone; the genesis page describes ETH-weighted rewards and the fixed end.
- A fresh deployment needs 28 ETH of opening capital instead of 3 ETH. Most of it is the board (15.15 ETH) and the
  reserve (12 ETH); both come back to the vault on retirement.

## Next steps that need the owner

1. Review docs/IMPLEMENTOR_DECISIONS.md D31–D43, especially the supply split (D40) and the reserve (D41).
2. Choose `LAUNCH_ETH` (sets the rate cap at deploy), the opening capital and `KEEPER_SEED`.
3. Commission an independent audit before outside money is material.
4. Run the Sepolia simulation and CI with a private archive RPC; then `DRY_RUN=1 script/deploy.sh mainnet` and the
   owner's broadcast.
5. Raise the timelock delay before outside money is material.
