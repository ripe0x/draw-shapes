# Economic validation

Date: 2026-10-23. Model: `sim/engine.mjs` (treasury rules of `EngineTreasury`) on the unchanged game
model of `sim/lab.html` (FWA pricing, settlement, margin split, replacement, keeper refunds, GRAIL mint,
merge and decay), with the board capped at the pool target as in the contracts. 12 independent seeds
per row, 365 days, p10 / p50 / p90 across seeds. Reproduce with `node sim/engine.mjs --out
sim/engine-results.md` (about 40 seconds). Fork measurements: `test/fork/engine/*.t.sol` at block
26,240,000.

## Conclusions

1. **The baseline game does not need coin trading.** In every row without trading income the
   ordinary bankroll was never refilled from the reserve (0 ETH at p90), the reserve paid no keeper
   subsidy at the base gas price (0.1 gwei), and game earnings stayed positive, down to 3.0 ETH a year
   at 10 draws a day. The
   treasury's 4 ETH reserve covers two thirds of the 6 ETH pool, against no observed drawdown to the
   refill line. This is a modeled statement over 12 simulated years per row, not a guarantee.
2. **Founders are repaid by demand, not by design.** With 5 ETH or more of daily trading, the 24 ETH
   cap (20 ETH round, 1.2x) is reached inside the year at every draw volume (day 160 at 10 draws, day 50
   at 750). Without trading it takes 300 draws a day (cap at day 182) or 750 a day (day 72). At 100
   draws and no trading founders receive 15.6 ETH in year one (about 1.5 years to the cap at that
   pace); at 30 draws 4.4 ETH; at 10 draws 1.5 ETH. Nothing in the contracts makes up a shortfall: a wind-down returns what is left of the
   bankroll, the reserve and an unwon GRAIL fund, founders first.
3. **The game earns about 4.3 percent of ticket spend for its owner.** Of a 0.0203 ETH ticket at 100
   draws a day: about 85.3 percent returns to players as backing at redemption value (14.7 percent house
   take), FWA keeps half its 5 percent edge, the creator receives the Shapes mint fee of every
   replacement (46 ETH a year at 100 draws, about 6.2 percent of spend), the maintenance share pays keeper
   gas, the feed share funds the GRAIL, and the premium share is the game's earnings (32 ETH a year).
   **The creator's mint fee revenue is about 1.4 times the game's earnings at every volume.** It is a real
   operating expense already recovered in the listing price, not profit.
4. **Trading receipts are the faster lever.** 4.5 percent of ETH-side volume reaches the treasury
   (measured). 5 ETH a day of trading is 82 ETH a year of receipts, about 2.5 times the game's
   earnings at 100 draws a day.
5. **Board depth must be capped.** Without `boardNavCap` the pool reinvested all profit into more listed
   items (NAV 6 to 20 ETH in a year at 100 draws, 6 to 151 ETH at 750), harvests found no free cash and
   GRAIL odds diluted. With the cap NAV holds near 6.5 ETH and earnings are harvestable.
6. **Sustainable is the right word only for the baseline game.** The coin flywheel (trading to prizes to
   play to earnings to burns) is real in the contracts' flows, but nothing here shows that more prizes
   cause more play or that burns cause more trading. Those links are assumptions; the model takes
   draws and trading as inputs.

## Players

| Measure | Value | Source |
| --- | --- | --- |
| FWA fee at opening, one draw | 0.016934 ETH (includes FWA's 5 percent edge) | fork `test_launch_deploysEscrowIntoGame` |
| VRF fee | 1,500,000 gas x 1.3 x the transaction's gas price: 0.000096 ETH at 0.049 gwei, 0.000195 ETH at 0.1 gwei, 0.00195 ETH at 1 gwei | live `FWACloneVRFService` reads, block 26,253,574 |
| Average ticket over a year | 0.0203 ETH (p50, 100 draws a day) | model |
| What lifts it | each listed GRAIL item raises the harmonic mean of list prices | model, D26 |
| Expected return at redemption | 86.8 percent of the ticket | model |
| Wallet gas | not included anywhere; the player pays it on top | |
| GRAIL wins a year | 11 (p50; 7 to 13) at 100 draws, largest 25 ETH | model |
| Opening headline | 5 ETH GRAIL, about one draw in 53,000 at face | fork weights |
| Sponsored punk at 8 ETH | one draw in 85,574 on the opening board | fork `test_stake_listsAtPublishedOdds` |

## Fork reconciliation

| Measure | Fork | Model | Note |
| --- | --- | --- | --- |
| Treasury share of a buy | 4.500 percent of ETH in | 4.5 percent (input) | exact |
| Treasury share of a sell | 4.500 percent of ETH volume | 4.5 percent (input) | exact |
| Board after opening (6 ETH pool) | 168 items | 175 target | the fork test stops after `open()`; Deep settles fill the rest |
| Opening mint fees | 0.257 ETH | about 0.26 ETH | first earnings only after these are recovered |
| Earnings per draw (premium 200 draft) | 0.00032 ETH over 1,050 draws | 0.00064 ETH | one standard deviation of payouts over 1,050 draws is about 0.36 ETH, so the fork sample (0.33 ETH of NAV growth) sits about one standard deviation below the model's 0.67 ETH expectation |
| Gas per listed item | about 1,000,000 (settle of 12: 12.4M) | 1,000,000 (input) | the lab default of 150,000 was replaced |

## What the model leaves out

The coin price and its response to buybacks (buyback ETH is reported, not coins burned); demand
feedback from prizes or burns; VRF fees (they scale with gas price and are paid by players on top of the FWA fee); FWA request
timeouts and delivery failures; a wind-down; sponsor behaviour beyond a fixed reclaim day.

## Tables

### Founder recovery: draws per day x trading ETH per day (20 ETH round, 1.2x cap = 24 ETH)

| Scenario | Founders paid, ETH (p10 / p50 / p90) | Days to 1.0x (share reaching; p50 day) | Days to cap (share; p50 day) | From trading (p50) | From earnings (p50) | Game earnings (p10 / p50 / p90) | Buyback ETH (p10 / p50 / p90) | Maintenance subsidy (p50 / p90) | Reserve spent on pool refill (p50 / p90) | Lowest reserve (p10) |
|---|---|---|---|---|---|---|---|---|---|---|
| 10 draws, 0 ETH trading | 1.16 / 1.50 / 1.83 | 0% ; - | 0% ; - | 0.00 | 1.50 | 2.33 / 3.01 / 3.66 | 1.16 / 1.50 / 1.82 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 10 draws, 5 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 133 | 100% ; 160 | 23.41 | 0.58 | 2.68 / 3.12 / 3.75 | 2.28 / 2.45 / 3.08 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 10 draws, 25 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 27 | 100% ; 32 | 23.97 | 0.03 | 3.56 / 3.97 / 4.34 | 3.51 / 3.92 / 4.31 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 10 draws, 100 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 6 | 100% ; 8 | 24.00 | 0.00 | 6.86 / 7.05 / 7.80 | 6.82 / 7.02 / 7.76 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 30 draws, 0 ETH trading | 3.68 / 4.39 / 4.66 | 0% ; - | 0% ; - | 0.00 | 4.39 | 7.35 / 8.78 / 9.32 | 3.66 / 4.37 / 4.64 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 30 draws, 5 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 128 | 100% ; 151 | 22.23 | 1.71 | 8.83 / 9.35 / 9.96 | 7.19 / 7.59 / 8.15 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 30 draws, 25 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 27 | 100% ; 32 | 23.83 | 0.16 | 10.85 / 11.97 / 12.71 | 10.78 / 11.75 / 12.52 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 30 draws, 100 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 6 | 100% ; 8 | 24.00 | 0.00 | 21.43 / 22.31 / 23.38 | 21.32 / 22.20 / 23.26 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 100 draws, 0 ETH trading | 14.95 / 15.59 / 16.59 | 0% ; - | 0% ; - | 0.00 | 15.59 | 29.90 / 31.19 / 33.19 | 14.87 / 15.51 / 16.51 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 100 draws, 5 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 107 | 100% ; 128 | 18.81 | 5.08 | 31.09 / 32.23 / 34.69 | 26.09 / 27.09 / 28.97 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 100 draws, 25 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 26 | 100% ; 31 | 22.99 | 0.93 | 39.99 / 40.55 / 42.15 | 38.65 / 39.33 / 40.70 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 100 draws, 100 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 6 | 100% ; 8 | 23.95 | 0.04 | 67.76 / 69.43 / 72.19 | 67.36 / 69.03 / 71.80 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 300 draws, 0 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 149 | 100% ; 182 | 0.00 | 24.00 | 92.14 / 97.67 / 101.51 | 67.80 / 73.30 / 77.12 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 300 draws, 5 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 73 | 100% ; 87 | 12.87 | 11.13 | 95.03 / 99.21 / 102.77 | 83.48 / 87.59 / 90.95 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 300 draws, 25 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 23 | 100% ; 28 | 20.69 | 3.31 | 106.46 / 110.53 / 114.36 | 102.63 / 106.69 / 110.98 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 300 draws, 100 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 6 | 100% ; 7 | 23.40 | 0.60 | 147.41 / 150.62 / 159.49 | 145.97 / 149.27 / 158.09 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 750 draws, 0 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 60 | 100% ; 72 | 0.00 | 24.00 | 241.03 / 247.38 / 251.96 | 215.95 / 222.27 / 226.82 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 750 draws, 5 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 42 | 100% ; 50 | 7.46 | 16.54 | 242.58 / 249.61 / 255.95 | 224.91 / 232.05 / 238.06 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 750 draws, 25 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 19 | 100% ; 22 | 16.82 | 7.18 | 258.32 / 264.26 / 267.33 | 250.62 / 255.67 / 258.69 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |
| 750 draws, 100 ETH trading | 24.00 / 24.00 / 24.00 | 100% ; 6 | 100% ; 7 | 22.16 | 1.81 | 307.03 / 311.00 / 319.21 | 303.88 / 307.51 / 315.59 | 0.00 / 0.00 | 0.00 / 0.00 | 4.00 |

### Opening capital (100 draws, 5 ETH trading)

| Scenario | Founders paid, ETH (p10 / p50 / p90) | Multiple of capital (p50) | Days to 1.0x (share reaching; p50 day) | Game earnings (p10 / p50 / p90) | Lowest reserve (p10) | GRAIL wins (p10 / p50 / p90) |
|---|---|---|---|---|---|---|
| 15 ETH (GRAIL 5.0, reserve 3.5) | 18.00 / 18.00 / 18.00 | 1.20 | 100% ; 81 | 31.36 / 32.35 / 34.41 | 3.50 | 7 / 9 / 12 |
| 20 ETH (GRAIL 9.5, reserve 4.0) | 24.00 / 24.00 / 24.00 | 1.20 | 100% ; 107 | 31.09 / 32.23 / 34.69 | 4.00 | 9 / 11 / 11 |
| 25 ETH (GRAIL 14.5, reserve 4.0) | 30.00 / 30.00 / 30.00 | 1.20 | 100% ; 133 | 31.71 / 32.55 / 35.30 | 4.00 | 8 / 10 / 14 |
| 30 ETH (GRAIL 19.5, reserve 4.0) | 36.00 / 36.00 / 36.00 | 1.20 | 100% ; 158 | 31.17 / 32.68 / 34.46 | 4.00 | 8 / 10 / 13 |
| 40 ETH (GRAIL 29.5, reserve 4.0) | 48.00 / 48.00 / 48.00 | 1.20 | 100% ; 210 | 30.81 / 33.02 / 35.35 | 4.00 | 10 / 12 / 14 |

### Board depth: ordinary pool target (100 draws, 5 ETH trading)

| Scenario | Ticket (p50) | Expected return (p50) | Game earnings (p10 / p50 / p90) | GRAIL wins (p10 / p50 / p90) | Largest win, ETH (p50) | Founders paid, ETH (p10 / p50 / p90) |
|---|---|---|---|---|---|---|
| 3.5 ETH pool | 0.0214 | 0.872 | 37.61 / 38.96 / 40.75 | 13 / 17 / 22 | 25.0 | 24.00 / 24.00 / 24.00 |
| 6 ETH pool | 0.0203 | 0.853 | 31.09 / 32.23 / 34.69 | 9 / 11 / 11 | 25.0 | 24.00 / 24.00 / 24.00 |
| 9 ETH pool | 0.0200 | 0.847 | 29.20 / 30.36 / 31.65 | 5 / 6 / 10 | 10.0 | 24.00 / 24.00 / 24.00 |
| 14 ETH pool | 0.0199 | 0.834 | 26.14 / 26.65 / 28.92 | 2 / 3 / 5 | 10.0 | 24.00 / 24.00 / 24.00 |

### GRAIL opening funding (100 draws, 5 ETH trading)

| Scenario | GRAIL wins (p10 / p50 / p90) | Largest win, ETH (p50) | Ticket (p50) | Expected return (p50) | Founders paid, ETH (p10 / p50 / p90) |
|---|---|---|---|---|---|
| opening five only (reserve 8.5) | 8 / 9 / 13 | 25.0 | 0.0203 | 0.846 | 24.00 / 24.00 / 24.00 |
| 9.5 ETH (reserve 4, launch) | 9 / 11 / 11 | 25.0 | 0.0203 | 0.853 | 24.00 / 24.00 / 24.00 |

### Price and mint configuration (100 draws, 5 ETH trading)

| Scenario | Ticket (p50) | Expected return (p50) | Game earnings (p10 / p50 / p90) | Creator mint fees (p50) | Founders paid, ETH (p10 / p50 / p90) | Days to 1.0x (share reaching; p50 day) |
|---|---|---|---|---|---|---|
| premium 200 bps, mint fee 0.001 | 0.0202 | 0.852 | 22.87 / 23.45 / 24.93 | 46.20 | 24.00 / 24.00 / 24.00 | 100% ; 113 |
| premium 300 bps, mint fee 0.001 | 0.0203 | 0.853 | 31.09 / 32.23 / 34.69 | 46.00 | 24.00 / 24.00 / 24.00 | 100% ; 107 |
| premium 400 bps, mint fee 0.001 | 0.0205 | 0.856 | 39.95 / 41.00 / 43.61 | 45.92 | 24.00 / 24.00 / 24.00 | 100% ; 101 |
| premium 200 bps, mint fee 0.002 | 0.0219 | 0.813 | 26.97 / 27.67 / 29.83 | 92.08 | 24.00 / 24.00 / 24.00 | 100% ; 111 |

### Ordinary mix (100 draws, 5 ETH trading)

| Scenario | Ticket (p50) | Expected return (p50) | Game earnings (p10 / p50 / p90) | Creator mint fees (p50) | GRAIL wins (p10 / p50 / p90) | Founders paid, ETH (p10 / p50 / p90) |
|---|---|---|---|---|---|---|
| current 38/28/19/10/4/1 | 0.0226 | 0.854 | 35.70 / 36.81 / 38.92 | 51.55 | 8 / 11 / 16 | 24.00 / 24.00 / 24.00 |
| more singles 50/22/13/10/4/1 | 0.0203 | 0.853 | 31.09 / 32.23 / 34.69 | 46.00 | 9 / 11 / 11 | 24.00 / 24.00 / 24.00 |
| no 3-packs 50/30/0/14/5/1 | 0.0202 | 0.863 | 30.68 / 32.77 / 34.36 | 42.55 | 8 / 11 / 13 | 24.00 / 24.00 / 24.00 |
| heavier top 30/25/20/16/7/2 | 0.0269 | 0.879 | 44.42 / 46.03 / 49.29 | 53.22 | 14 / 17 / 24 | 24.00 / 24.00 / 24.00 |

### Founder terms (100 draws, 5 ETH trading)

| Scenario | Founders paid, ETH (p10 / p50 / p90) | Days to 1.0x (share reaching; p50 day) | Days to cap (share; p50 day) | To GRAIL from trading (p50) | Buyback ETH (p10 / p50 / p90) |
|---|---|---|---|---|---|
| cap 1.1x, trading 65%, earnings 50% | 22.00 / 22.00 / 22.00 | 100% ; 107 | 100% ; 117 | 64.87 | 26.97 / 28.16 / 29.92 |
| cap 1.2x, trading 65%, earnings 50% | 24.00 / 24.00 / 24.00 | 100% ; 107 | 100% ; 128 | 63.21 | 26.09 / 27.09 / 28.97 |
| cap 1.3x, trading 65%, earnings 50% | 26.00 / 26.00 / 26.00 | 100% ; 107 | 100% ; 138 | 61.80 | 25.48 / 27.12 / 28.28 |
| cap 1.2x, trading 50%, earnings 50% | 24.00 / 24.00 / 24.00 | 100% ; 129 | 100% ; 154 | 64.38 | 25.36 / 26.19 / 27.44 |
| cap 1.2x, trading 80%, earnings 50% | 24.00 / 24.00 / 24.00 | 100% ; 90 | 100% ; 108 | 62.55 | 26.71 / 28.00 / 29.92 |
| cap 1.2x, trading 65%, earnings 25% | 24.00 / 24.00 / 24.00 | 100% ; 120 | 100% ; 143 | 61.04 | 27.88 / 29.57 / 31.58 |
| cap 1.2x, trading 65%, earnings 75% | 24.00 / 24.00 / 24.00 | 100% ; 97 | 100% ; 116 | 65.13 | 24.75 / 25.93 / 26.96 |
| cap 1.2x, trading 100%, earnings 100% | 24.00 / 24.00 / 24.00 | 100% ; 66 | 100% ; 80 | 64.08 | 25.70 / 26.48 / 28.43 |

### Stress (base 100 draws, 5 ETH trading unless stated)

| Scenario | Founders paid, ETH (p10 / p50 / p90) | Days to 1.0x (share reaching; p50 day) | Game earnings (p10 / p50 / p90) | Reserve spent on pool refill (p50 / p90) | Lowest reserve (p10) | GRAIL wins (p10 / p50 / p90) |
|---|---|---|---|---|---|---|
| launch 300/day, then 10/day from day 30 | 24.00 / 24.00 / 24.00 | 100% ; 107 | 9.97 / 10.91 / 11.78 | 0.00 / 0.00 | 4.00 | 2 / 3 / 6 |
| heavy draws, little trading: 750 draws, 0.5 ETH | 24.00 / 24.00 / 24.00 | 100% ; 58 | 239.23 / 247.54 / 250.30 | 0.00 / 0.00 | 4.00 | 75 / 81 / 90 |
| heavy trading, little play: 10 draws, 100 ETH | 24.00 / 24.00 / 24.00 | 100% ; 6 | 6.86 / 7.05 / 7.80 | 0.00 / 0.00 | 4.00 | 0 / 1 / 4 |
| trading stops after day 30 | 24.00 / 24.00 / 24.00 | 100% ; 26 | 30.13 / 31.66 / 32.88 | 0.00 / 0.00 | 4.00 | 7 / 10 / 13 |
| no paid draws at all | 24.00 / 24.00 / 24.00 | 100% ; 136 | 0.00 / 0.00 / 0.00 | 0.00 / 0.00 | 4.00 | 0 / 0 / 0 |
| 5 ETH GRAIL won on day 1 | 24.00 / 24.00 / 24.00 | 100% ; 107 | 31.08 / 32.25 / 33.86 | 0.00 / 0.00 | 4.00 | 9 / 12 / 13 |
| gas 1 gwei | 24.00 / 24.00 / 24.00 | 100% ; 139 | 30.70 / 32.34 / 34.43 | 0.00 / 0.00 | 3.56 | 8 / 9 / 12 |
| gas 5 gwei | 24.00 / 24.00 / 24.00 | 100% ; 145 | 31.46 / 32.25 / 34.34 | 0.00 / 0.00 | 2.77 | 9 / 10 / 12 |
| gas 5 gwei, owner raises maintenance to 400 bps | 24.00 / 24.00 / 24.00 | 100% ; 145 | 28.06 / 29.05 / 30.52 | 0.00 / 0.00 | 2.82 | 7 / 10 / 13 |
| gas 30 gwei | 24.00 / 24.00 / 24.00 | 100% ; 145 | 30.61 / 32.25 / 34.34 | 0.00 / 0.00 | 2.68 | 8 / 10 / 12 |
| keeper down 3 days in 10 | 24.00 / 24.00 / 24.00 | 100% ; 106 | 34.41 / 35.37 / 37.97 | 0.00 / 0.00 | 4.00 | 11 / 15 / 20 |
| keeper down days 30 to 60 | 24.00 / 24.00 / 24.00 | 100% ; 113 | 28.51 / 30.13 / 31.85 | 0.00 / 0.00 | 4.00 | 7 / 8 / 12 |
| reduced refill: 4 hour batches, 5 gwei | 24.00 / 24.00 / 24.00 | 100% ; 145 | 32.16 / 32.56 / 34.27 | 0.00 / 0.00 | 2.75 | 8 / 10 / 12 |

### Sponsored Wrapped Cryptopunk (value 30 ETH, cap 36 ETH, half the post-founder trading share)

| Scenario | Sponsor paid (p50); outcomes | Founders paid, ETH (p10 / p50 / p90) | Ticket (p50) | Expected return (p50) | GRAIL wins (p10 / p50 / p90) |
|---|---|---|---|---|---|
| no sponsor | 0.00; - 12 | 24.00 / 24.00 / 24.00 | 0.0203 | 0.853 | 9 / 11 / 11 |
| listed at 30 ETH (parked style) | 31.55; listed 9, won 3 | 24.00 / 24.00 / 24.00 | 0.0204 | 0.844 | 7 / 9 / 14 |
| listed at 8 ETH | 31.55; listed 10, won 2 | 24.00 / 24.00 / 24.00 | 0.0204 | 0.857 | 7 / 10 / 13 |
| listed at 8 ETH, 300 draws, 25 ETH trading | 36.00; won 8, completed 4 | 24.00 / 24.00 / 24.00 | 0.0206 | 0.967 | 36 / 41 / 47 |
| listed at 8 ETH, reclaimed day 60 | 2.32; reclaimed 12 | 24.00 / 24.00 / 24.00 | 0.0203 | 0.852 | 8 / 11 / 13 |

### Comparison with the depositor model and a coin-only launch (100 draws a day)

| Model | Capital at open | Days until the game opens | Ticket (p50) | Expected return (p50) | GRAIL wins (p50) | Who is paid from game earnings | Year-one figure (p50) |
|---|---|---|---|---|---|---|---|
| Depositor pool (lab defaults) | 55 ETH from depositors | 0 | 0.0221 | 0.831 | 1 | depositors, indefinitely | depositor NAV per share annualised 34.8%, end NAV 76.6 ETH |
| Engine, 20 ETH round | 20 ETH from founders | 0 | 0.0203 | 0.853 | 11 | founders to 1.2x, then buybacks | founders paid 24.00 ETH, buybacks 27.09 ETH |
| Coin-only launch, 5 ETH trading a day | none | 52 | 0.0203 | 0.851 | 8 | buybacks only | buybacks 27.19 ETH in the 313 days left |
| Coin-only launch, 25 ETH trading a day | none | 11 | 0.0209 | 1.000 | 15 | buybacks only | buybacks 39.13 ETH in the 354 days left |
| Coin-only launch, no trading | none | never | - | - | - | - | the game never opens |

Run time 42 s.
