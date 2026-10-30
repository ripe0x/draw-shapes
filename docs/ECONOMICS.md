# Economics

Inputs, measurements and model outputs behind the launch parameters. Everything here is reproducible: gas from
`forge test --match-path test/fork/Gas.t.sol --isolate` (writes `docs/receipts/gas.json`); model tables from
`python3 sim/sustainability.py` (writes `sim/results/sustainability.md`, seeded); fork measurements from
`test/fork/Accounting.t.sol`. Model outputs are results under stated assumptions, not forecasts of demand. No
trading-fee inflow is assumed anywhere: the game is sized to stand on its own capital and results.

## 1. Launch parameters and where each comes from

| parameter | launch | source |
|---|---|---|
| Board | 30 × 0.01, 45 × 0.05, 25 × 0.5 ETH Shapes (100 rows, 15.15 ETH at cost) | section 2; IMPLEMENTOR_DECISIONS D35 |
| Markup | 500 bps: listing price = (backing + 0.001 mint fee) × 1.05 | follow-up section 3 |
| Operating allocation | 300 bps of the quote's expected replacement cost | section 4; D33 |
| Reserve target | 12 ETH | section 5; D41 |
| Opening capital | about 28 ETH: board 15.15 + reserve 12 + about 1 working cash | section 5 |
| Purchase gate | refuse unless the board keeps 80% + a batch of 5 + every unsettled request; at most 10 in flight; FWA edge ≤ 5%, cooldown ≤ 5 min | section 11; D45 |
| Admission | close below 80% fill, FWA edge above 5%, cooldown above 5 min | D36 |
| Restock | when nothing is in flight (or near the gate's line); 3 rows waiting or 5 min (≥ 6 FWA cooldowns) | section 11; D49 |
| Buyback | profit only; slice ≤ 0.05 ETH, 1 h spacing, 3% impact cap, 2% same-block deviation, 100% burned | D39 |
| Genesis | 190M ENGINE; 14 steady epochs at F/17.5, then 87.5% … 12.5%; rate cap 10% of ticket ETH at the start price | section 7; D34 |
| Supply | 800M protocol liquidity / 190M genesis / 10M conversion bonus | section 8; D40 |
| `START_TICK` | 184,200 recommended (≈ 10 ETH FDV, ≈ 99.8M ENGINE per ETH); single-sided, no ETH paired; fixes the rate cap at ≈ 9.98M ENGINE per ETH | section 8; D50 |
| VRF fee (FWA's) | 1,500,000 gas × gas price × 1.3 per pull, paid by the player | section 3 |
| Keeper | (gas + 70k) × min(gas price, 5 gwei), capped at 0.05 ETH, + 0.0003 ETH flat fee at most hourly per job; target 0.5 ETH, floor 0.05 ETH | section 4; D48 |
| `KEEPER_SEED` | 0.05 ETH | the vault tops KeeperFund up from trading fees (floor + 0.1 ETH, ≤ 1 ETH over its life) |

## 2. Ordinary prize mix

FWA charges `EV × 1.05` (EV = harmonic mean of live listing prices; odds are inverse to price) and pays the owner
`fee − (fee − EV)/2`. Reproduced exactly (`sim/results/sustainability.md` section 1):

| | 6 / 9 / 5 (20 items) | 30 / 45 / 25 (100 items, launch) |
|---|---|---|
| inventory at cost | 3.03 ETH | 15.15 ETH |
| ticket (FWA fee) | 0.03012685 ETH | 0.03012685 ETH |
| win 0.01 / 0.05 / 0.5 | 74.5253% / 24.1111% / 1.36357% | same |
| headline odds | 1 in 73.34 | same |
| turnover per headline | 2.20941 ETH | same |
| expected return (backing / ticket) | 87.38365% | same |

Per 100 ETH of gameplay, in expectation: backing paid out 87.38365, mint fees 3.31930 (the founder's only income),
operating allocation 2.72109, FWA's half-edge 2.38095, game margin 4.19501. The margin is an expectation. What is
booked is realised profit: owner proceeds less the actual cost of the prizes won and the operating allocation. That
varies with the draw (section 6), and the contracts never hardcode it.

Board size, from the evidence (D35):

- **Settlement drift.** FWA settles each request in order against the live pool and refunds it if the fee has risen more
  than 10% above its escrow. Each cheap prize won ahead of a request raises the fee by 8.47% on 20 items but 1.52% on
  100. A burst of 3 requests on one quote loses 17.55% to refunds on 20 items and none on 100; in modelled play the
  20-item board refunds about 30% of requests, the 100-item board under 0.4%.
- **Depletion and availability.** The 100-item board keeps every probability within a few percent between replacement
  windows. The 20-item board closes to purchases (below 80% fill) 15 to 33 hours per 60 days in the models, against
  0 to 4 hours for 100 items at the same volume.
- **Entry price, return, intermediate wins, headline frequency.** These are identical by construction.
- **Capital.** 12.12 ETH more inventory. That is the cost of the larger board, and it is what makes FWA's ordered
  settlement work for players.
- **Execution cost.** The same per pull. The larger board needs no more replacements per ETH.

The PR #9 board (80/15/5 at 0.01/0.05/0.1, 3% markup) had a 0.1 ETH headline, 85.42% return and mint fees taking 7.04%
of turnover. It was not kept.

## 3. Gas receipts and execution costs (fork, isolated transactions, block 26,279,000)

Each figure is the call's execution gas plus the 21,000 base cost.

| call | gas | ETH at 1 gwei | 5 gwei |
|---|---|---|---|
| a player's `acquire` (FWA; now includes the purchase gate) | 617,639 | 0.00062 | 0.00309 |
| `sync`: 1 pull booked + its replacement minted and listed | 1,379,242 | 0.00138 | 0.00690 |
| `sync`: 5 pulls + 5 replacements | 3,002,776 | 0.00300 | 0.01501 |
| `sync`: 20 pulls + 20 replacements | 9,971,776 | 0.00997 | 0.04986 |
| `Buyback.process` (one slice, bought and burned) | 409,894 | 0.00041 | 0.00205 |
| `Converter.convert` | 463,682 | 0.00046 | 0.00232 |
| `GenesisFarm.finalize`, one epoch | 234,785 | 0.00023 | 0.00117 |
| `GenesisFarm.claim`, one epoch | 129,935 | 0.00013 | 0.00065 |

Per pull, `sync` costs about 452k gas beyond the first pull of a call: almost all of it is the replacement (a
Shapes mint through PoolOwner and an FWA listing). The 20-pull figure was measured with the gate's floor lowered to 50%
so 20 captures fit before a restock (at 80% at most 16 do). The player also pays FWA's VRF fee (1.95M gas-equivalents × gas price): 0.00195 ETH at 1 gwei,
0.0039 at 2 gwei, 0.0098 at 5 gwei. Net of the VRF fee the expected return is 84.6% at 0.5 gwei, 82.1% at 1 gwei,
77.4% at 2 gwei and 66.0% at 5 gwei.

## 4. Operating allocation against measured cost

The allocation is 3% of C (C = the quote's expected replacement cost), 0.000820 ETH per pull. Measured on the fork
(`test_operatingAllocationAgainstMeasuredKeeperGas`: 120 pulls, a sync per 10 pulls with replacements, 12 syncs,
63.5M gas, each call its own transaction with cold storage as on mainnet): it covers the keeper gas plus overhead up
to about a **1.6 gwei** base fee (1.62 with `--isolate` after the PoolOwner split). Keepers are paid the gas they used
at the gas price they paid (up to 5 gwei; at most 0.05 ETH a call) plus a 0.0003 ETH flat fee at most once an hour per
job, so splitting work earns nothing extra and idle time earns nothing (D48). Above about 1.6 gwei the allocation does
not pay for every sync; the vault then tops KeeperFund up from trading fees, at most 1 ETH over its life (about 70M
gas of listing at 10 gwei), and those top-ups go back to the vault before any overflow reaches the game. Settlement
never waits on tips, and the purchase gate keeps the board safe whether or not anyone syncs.

## 5. Capital and replenishment

Deterministic obligations are the board at cost (15.15 ETH) and the replacements owed between windows. The risk buffer
is the reserve target. A distribution leaves only `replacementsOwed + opsOwed + reserveTarget + unsettled × largest
prize` in cash, so a run of headline wins after a distribution is absorbed by the reserve; if the reserve is not
enough, rows wait for cash. Modelled with 200 seeded 90-day runs at 5 ETH a day and no trading fees:

| reserve target | runs where cash fell below replacements owed | worst headroom | distributed over 90 days (mean) |
|---|---|---|---|
| 3 ETH | 97.0% | −6.00 ETH | 19.30 ETH |
| 5 ETH | 40.0% | −4.56 ETH | 18.97 ETH |
| 8 ETH | 6.5% | −3.31 ETH | 18.92 ETH |
| 10 ETH | 1.5% | −1.70 ETH | 18.91 ETH |
| 12 ETH | 0.0% | +0.09 ETH | 18.91 ETH |

The reserve is capital, not profit: a larger one barely changes distributions; it locks more opening capital.
Recommended: **12 ETH reserve, about 28 ETH opening capital.** A shortfall is not insolvency. Every listed prize is
owned and every accepted request settles; some rows stay empty until proceeds refill cash, and below 80% fill new
purchases close.

Conditions under which the game pauses distributions or new purchases: docs/RUNBOOK.md ("Conditions that pause…").

## 6. Results after execution costs, variation and availability (60 days, no trading fees)

From `sim/results/sustainability.md` section 4: 100-item board, 12 ETH reserve, keeper at 1 gwei syncing at 10 pulls,
3 empty rows, near the gate's line or 4 idle hours, paid gas at cost plus the hourly flat fee; purchases through the
gate. Profit is realised profit after the operating allocation. Percentiles are across 40 seeded runs (12 for busy).

| scenario | turnover | realised profit, mean (p05 … p95) | per 100 ETH, mean (p05 … p95) | distributed | deepest P&L | keeper cost per 100 ETH | hours closed |
|---|---|---|---|---|---|---|---|
| low: 1 ETH/day | 61 ETH | +2.58 (−2.70 … +6.27) | +4.26 (−4.28 … +10.67) | 3.66 | −6.00 | 2.91 | 0 |
| base: 5 ETH/day, bursts | 293 ETH | +10.14 (+0.65 … +21.40) | +3.47 (+0.22 … +7.38) | 12.03 | −6.32 | 2.42 | 0 |
| busy: 30 ETH/day | 1,577 ETH | +52.97 (+19.64 … +75.80) | +3.36 (+1.24 … +4.73) | 54.78 | −3.69 | 2.22 | 0 |
| clumped: 5 ETH/day in 4 sessions | 294 ETH | +11.70 (+4.31 … +24.66) | +3.98 (+1.49 … +8.30) | 13.01 | −5.97 | 2.04 | 0.2 |
| adverse: 5 headline wins first | 303 ETH | +10.40 (+0.96 … +18.05) | +3.43 (+0.32 … +5.99) | 12.07 | −10.19 | 2.67 | 0 |

- **Actual distributable profit.** Realised profit averaged 3.4 to 4.3 ETH per 100 ETH of gameplay, below the 4.195
  expectation: rows emptied between restocks shift the board towards dearer prizes, and the cheapest prizes carry the
  margin. At low volume a 60-day run loses money about one time in ten. Distributions are never more than realised
  profit.
- **Availability.** With the 3-row trigger each row is empty 4 to 17 hours per 60 days (39 to 137 with the old
  30-minute window and 20-row batches). The gate closed purchases only in the clumped case, about 12 minutes in 60 days.
- **Keeper cost** is 2.0 to 2.9 ETH per 100 ETH at 1 gwei against an allocation of 2.72: the hourly flat fee weighs
  most at low volume; vault top-ups cover the difference within their 1 ETH limit.
- **Busy.** At 30 ETH a day the lowest headroom went 1.65 ETH below replacements owed for a while after a headline run
  (rows waited for cash); more capital absorbs it.
- **Small boards.** The 20-row board needs a 50% floor under the gate (an 80% floor plus a batch of 5 exceeds 20 rows);
  with it, drift refunds rise to 16-26% at 5 ETH a day (section 11).

## 7. Genesis rewards

`pot(e) = min(allocationCap(e), eligibleTicketETH(e) × rateCap(e))`, with F = 190M ENGINE, steady cap F/17.5 =
10,857,143 ENGINE, and both caps multiplied by 87.5% … 12.5% over the last seven epochs. The rate cap is fixed at deploy
to 10% of ticket ETH valued at the start price: at `START_TICK` 184,200, 9,983,996 ENGINE per ETH.

| eligible ticket ETH per day | pot | rewards as % of ticket ETH at the start price | burned at finalization |
|---|---|---|---|
| 0.2 | 2.0M | 10.00% | 8.86M |
| 1.09 | 10.86M | 9.98% | 0 |
| 2 | 10.86M | 5.44% | 0 |
| 5 | 10.86M | 2.17% | 0 |
| 20 | 10.86M | 0.54% | 0 |

A single 0.03 ETH pull earns about 300k ENGINE, under 3% of a steady pot, never the pot. Below about 1.09 ETH a day the
rate cap binds and the unearned rest of each cap is burned when the epoch becomes final. Above it the allocation cap
binds and rewards per ETH fall as activity grows. ENGINE can trade only at or above the start price, so the value is a
floor; what selling rewards takes from the pool is in section 8.

## 8. Single-sided launch and the supply split

`ProtocolLiquidity.launch` pairs no ETH: the 800M float is one position over `[TICK_LOWER, START_TICK)`, so the start
price is the lowest valuation ENGINE can ever trade at, and sellers can take out only the ETH buyers put in
(`sim/results/launch.md`, D50).

| start FDV | `START_TICK` | 1 ETH opening buy moves the price | largest buyer after a 5 ETH opening | genesis budget at the start price |
|---|---|---|---|---|
| 5 ETH | 191,200 | +55% | 24% of supply | 0.95 ETH |
| **10 ETH (recommended)** | **184,200** | **+26%** | **14%** | **1.90 ETH** |
| 20 ETH | 177,200 | +12% | 7% | 3.83 ETH |

Farm selling (D52): public buys are closed through genesis, so farm rewards sold then meet only the opening market's
ETH, conversions and buybacks. With no conversions, 1 ETH of opening buys and 20 ETH of genesis tickets at 10 ETH FDV,
full farm selling takes the price back to the start and opening buyers exit with nothing; with 25% of delivered prize
backing converted the same opening exits at 1.3×, and at 100-300 ETH of tickets conversions dominate. A seeded
two-sided position would not protect buyers: it gives farm sellers the owner's ETH too and removes the floor. The
80 / 19 / 1 split is unchanged (D40); a smaller farm, a time-weighted rate cap or a lower start are the owner's options.

| split (LP / genesis / bonus) | start FDV | genesis value at the start price | genesis / LP tokens |
|---|---|---|---|
| 80 / 19 / 1 (adopted) | 10.02 ETH | 1.90 ETH | 0.24 |
| 70 / 29 / 1 | 10.02 ETH | 2.90 ETH | 0.41 |
| 50 / 49 / 1 | 10.02 ETH | 4.91 ETH | 0.98 |

Single-sided, the start FDV is set by `START_TICK`, not by the split.

## 9. Sizes

Runtime bytes (legacy codegen, optimizer 200), from `forge build --sizes`: FwaGame 24,286 (290 under 24,576), Lens
18,992, PoolOwner 9,297, ProtocolLiquidity 8,723, GenesisFarm 7,228, EngineHook 6,123, KeeperFund 4,747, PrizeVault
4,661, Converter 4,319, EngineBuyer 4,190, Buyback 3,936, EngineToken 2,940.
Exact figures in `docs/FINAL_REPORT.md`.

## 10. Model limits

- Arrivals are Poisson with geometric bursts, or clumped sessions. Real demand is unknown, and every scenario is an
  assumption.
- Each FWA request settles against the live pool in order, with the 10% positive-slippage refund and no negative-
  slippage refunds (the site sends 100% tolerance). VRF latency within a burst is not modelled.
- The keeper syncs at 10 pulls, 3 empty rows, near the gate's line or 4 idle hours. Real keepers and bots will differ,
  and a slower keeper leaves rows empty (and the gate closed) longer.
- `sim/launch.py` models the pool exactly (concentrated liquidity) but buyers and farmers as fixed patterns; real
  traders will differ. `sim/throughput.py` models VRF latency and FWA's ordering, not gas competition.
- No trading fees, no promotions, no conversions and no market model: the token's price does not enter the game's
  accounts, and none of these figures implies anything about it.

## 11. Gate throughput and Pack boards

`sim/results/throughput.md` (in-flight limit × board size; 30% of purchases batches of 5): on the 100-row board at
10 ETH a day, limit 10 completes the most draws with 0.02% refused and 0.45% refunded on FWA's drift guard; at 50 ETH a
day, 3.3% refused and 2.2% refunded, against 12-16% refused at limits 3-5 (one batch fills those). A 50-row board refunds
11-18% at any limit (each cheap capture moves FWA's fee more), so the limit and the board are set together. Launch:
limit 10, 100 rows (D45).

`sim/results/boards.md` (Pack costs read from the fork): the Shapes board returns 87.4% before VRF (82.1% at 1 gwei)
with a 0.5 ETH headline 1 in 73; Pack board A (seven levels, 30 Packs) returns 86.0% on half the board capital (7.72
ETH) with a rarer 0.5 ETH headline (1 in 393); Pack board B (40 Packs, 1 ETH headline 1 in 715) returns 86.2% on 12.02
ETH. Packs carry one mint fee per Shape inside, so the mint-fee share of the ticket rises from 3.3% to about 4.5-4.7%.
The launch board stays Shapes-only (D51).

