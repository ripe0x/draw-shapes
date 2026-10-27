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
| Admission | close below 80% fill, above 20 unsettled, FWA edge above 5%, cooldown above 5 min | D36 |
| Maintenance interval / list batch | 30 min / 20 | D25 |
| Buyback | profit only; slice ≤ 0.05 ETH, 1 h spacing, 3% impact cap, 2% same-block deviation, 100% burned | D39 |
| Genesis | 190M ENGINE; 14 steady epochs at F/17.5, then 87.5% … 12.5%; rate cap 10% of ticket ETH at the launch price | section 7; D34 |
| Supply | 800M protocol liquidity / 190M genesis / 10M conversion bonus | section 8; D40 |
| `LAUNCH_ETH` | 5 ETH recommended (fixes the rate cap at 16M ENGINE per ETH) | section 8 |
| VRF fee (FWA's) | 1,500,000 gas × gas price × 1.3 per pull, paid by the player | section 3 |
| Keeper | premium 20%, basefee cap 30 gwei, tip cap 0.01, bounty 0.002 over 6 h, overhead 40k gas, target 0.5 ETH, floor 0.05 ETH | BUILD_PROMPT 4.6 |
| `KEEPER_SEED` | 0.5 ETH recommended | covers keeper gas before the operating allocation builds up |

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
| a player's `acquire` (FWA) | 584,985 | 0.00058 | 0.00292 |
| `sync`: 1 pull booked + its replacement minted and listed | 1,233,895 | 0.00123 | 0.00617 |
| `sync`: 5 pulls + 5 replacements | 2,902,099 | 0.00290 | 0.01451 |
| `sync`: 20 pulls + 20 replacements | 9,819,782 | 0.00982 | 0.04910 |
| `Buyback.process` (one slice, bought and burned) | 343,615 | 0.00034 | 0.00172 |
| `Converter.convert` | 457,803 | 0.00046 | 0.00229 |
| `GenesisFarm.finalize`, one epoch | 160,830 | 0.00016 | 0.00080 |
| `GenesisFarm.claim`, one epoch | 126,933 | 0.00013 | 0.00063 |

Per pull, `sync` costs about 452k gas beyond the first pull of a call: almost all of it is the replacement (a Shapes mint
and an FWA listing). The player also pays FWA's VRF fee (1.95M gas-equivalents × gas price): 0.00195 ETH at 1 gwei,
0.0039 at 2 gwei, 0.0098 at 5 gwei. Net of the VRF fee the expected return is 84.6% at 0.5 gwei, 82.1% at 1 gwei,
77.4% at 2 gwei and 66.0% at 5 gwei.

## 4. Operating allocation against measured cost

The allocation is 3% of C (C = the quote's expected replacement cost), 0.000820 ETH per pull. Measured on the fork
(`test_operatingAllocationAgainstMeasuredKeeperGas`: 120 pulls, a sync per 10 pulls with replacements, 12 syncs,
48.7M gas): it covers the keeper gas plus overhead up to a **2.12 gwei** base fee. In the 60-day models at 1 gwei,
keeper cost (gas × 1.2 premium + bounty) was 1.9 to 2.7 ETH per 100 ETH of turnover against an allocation of 2.72, and
KeeperFund never ran short. Above about 2 gwei the allocation does not pay for every sync. Tips are capped by what
KeeperFund holds, keepers wait for cheaper blocks (the bounty ramps over 6 h), and settlement never waits on tips.
Unspent allocation above KeeperFund's 0.5 ETH target returns to the game and raises realised profit.

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
20 empty rows or 4 idle hours. Profit is realised profit after the operating allocation. Percentiles are across 40
seeded runs (12 for busy).

| scenario | turnover | realised profit, mean (p05 … p95) | per 100 ETH, mean (p05 … p95) | distributed | deepest P&L | hours closed |
|---|---|---|---|---|---|---|
| low: 1 ETH/day | 62 ETH | +2.64 (−2.41 … +7.06) | +4.29 (−3.74 … +11.80) | 3.74 | −6.33 | 0 |
| base: 5 ETH/day, bursts | 306 ETH | +11.51 (+2.76 … +21.34) | +3.77 (+0.90 … +6.97) | 13.35 | −4.67 | 0.3 |
| busy: 30 ETH/day | 1,688 ETH | +59.74 (+17.26 … +81.24) | +3.54 (+1.02 … +4.79) | 61.74 | −5.12 | 24.9 |
| clumped: 5 ETH/day in 4 sessions | 299 ETH | +10.30 (+1.83 … +21.43) | +3.44 (+0.61 … +7.10) | 11.91 | −7.90 | 4.0 |
| adverse: 5 headline wins first | 315 ETH | +12.91 (+2.07 … +20.70) | +4.10 (+0.66 … +6.69) | 14.43 | −10.91 | 0 |

- **Actual distributable profit.** Realised profit averaged 3.4 to 4.3 ETH per 100 ETH of gameplay, below the 4.195
  expectation. Rows emptied between windows shift the board towards dearer prizes, and the cheapest prizes carry the
  margin. At low volume a 60-day run loses money one time in ten. Over the long run distributions approach realised
  profit; they are never more than it.
- **Headline frequency.** 0.46 to 0.51 headline wins per ETH of gameplay, against 0.453 for a full board: one per 2.0
  to 2.2 ETH.
- **Availability.** Each row is empty 39 to 137 hours per 60 days, waiting for the 30-minute window and the keeper's
  batching. Purchases close (below 80% fill) only under clumped or very busy play.
- **Busy.** At 30 ETH a day one run in twelve briefly ran short of cash after a deep headline run, and purchases closed
  about 25 hours in 60 days while the board refilled. More capital or a faster keeper cadence absorbs it.

## 7. Genesis rewards

`pot(e) = min(allocationCap(e), eligibleTicketETH(e) × rateCap(e))`, with F = 190M ENGINE, steady cap F/17.5 =
10,857,143 ENGINE, and both caps multiplied by 87.5% … 12.5% over the last seven epochs. The rate cap is fixed at deploy
to 10% of ticket ETH valued at the launch price: at LAUNCH_ETH 5 against the 800M float, 16,000,000 ENGINE per ETH.

| eligible ticket ETH per day | pot | rewards as % of ticket ETH at the launch price | burned at finalization |
|---|---|---|---|
| 0.2 | 3.2M | 10.00% | 7.66M |
| 0.68 | 10.86M | 9.98% | 0 |
| 2 | 10.86M | 3.39% | 0 |
| 5 | 10.86M | 1.36% | 0 |
| 20 | 10.86M | 0.34% | 0 |

A single 0.03 ETH pull earns 482k ENGINE, 4.4% of a steady pot, never the pot. Below about 0.68 ETH a day the rate cap
binds and the unearned rest of each cap is burned when the epoch becomes final. Above it the allocation cap binds and
rewards per ETH fall as activity grows. The reward value is at the launch price only; the market sets the rest.

## 8. Supply split and LAUNCH_ETH

| split (LP / genesis / bonus) | launch FDV at 5 ETH | genesis value at the launch price | genesis / LP tokens |
|---|---|---|---|
| 80 / 19 / 1 (adopted) | 6.25 ETH | 1.19 ETH | 0.24 |
| 70 / 29 / 1 | 7.14 ETH | 2.07 ETH | 0.41 |
| 50 / 49 / 1 | 10.00 ETH | 4.90 ETH | 0.98 |
| 10 / 10 / 1 + 79% reserve (PR #9) | 50.00 ETH | 5.00 ETH | 1.00 |

80 / 19 / 1 removes the dependence on a seasons reserve and keeps everything the farm can ever pay at 24% of the pool's
token depth. Its cost is a low launch valuation, so genesis rewards are a modest incentive at the launch price. A
larger LAUNCH_ETH raises the price, lowers the rate cap in ENGINE terms (same 10% value), and deepens the pool for
conversions and buybacks. 5 ETH remains the recommendation for a first launch; the owner may raise it. The farm's
budget is a constructor argument if the owner prefers 70 / 29 / 1.

## 9. Sizes

Runtime bytes (legacy codegen, optimizer 200), from `forge build --sizes`: FwaGame about 23,500 (about 1.1 KB under
24,576), Lens about 18,200, ProtocolLiquidity 8,578, GenesisFarm about 7,000, EngineHook about 6,100, KeeperFund
about 4,500, EngineBuyer 4,190, Buyback about 4,000, Converter about 3,750, PrizeVault about 3,450, EngineToken 2,940.
Exact figures in `docs/FINAL_REPORT.md`.

## 10. Model limits

- Arrivals are Poisson with geometric bursts, or clumped sessions. Real demand is unknown, and every scenario is an
  assumption.
- Each FWA request settles against the live pool in order, with the 10% positive-slippage refund and no negative-
  slippage refunds (the site sends 100% tolerance). VRF latency within a burst is not modelled.
- The keeper syncs at 10 pulls, 20 empty rows or 4 idle hours. Real keepers and bots will differ, and a slower keeper
  leaves rows empty longer.
- No trading fees, no promotions, no conversions and no market model: the token's price does not enter the game's
  accounts, and none of these figures implies anything about it.
