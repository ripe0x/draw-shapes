# Economics

Inputs, measurements and model outputs behind the launch parameters. Everything here is reproducible:
gas from `forge test --match-path test/fork/Gas.t.sol --isolate` (writes `docs/receipts/gas.json`), model
tables from `python3 sim/engine_genesis.py` (writes `sim/results/engine-genesis.md`). Model outputs are
results under stated assumptions, not forecasts of demand.

## 1. Launch parameters and where each comes from

| parameter | launch | source |
|---|---|---|
| Board | 80 × 0.01, 15 × 0.05, 5 × 0.1 ETH Shapes (100 rows) | Shapes only (IMPLEMENTOR_DECISIONS D3); EV close to the reference board (section 2) |
| Markup | 300 bps | section 3 decision; covers keeper gas at ≈ 0.75 gwei (section 4) |
| Reserve target | 0.75 ETH | adverse-sequence sim, P(shortfall) 0.05 % over 21 days at 300 pulls/day (section 5) |
| Opening capital | 3.0 ETH (board 2.15 incl. mint fees + reserve 0.75 + 0.1) | sections 2 and 5 |
| VRF fee (FWA's) | 1,500,000 gas × gas price × 1.3 per pull, paid by the player | FWACloneVRFService on the fork (section 8) |
| Maintenance interval / list batch | 30 min / 20 | D25; batching is what makes the markup cover replacement gas |
| Keeper | premium 20 %, basefee cap 30 gwei, tip cap 0.01, bounty 0.002 over 6 h, overhead 40k gas, target 0.5 ETH, floor 0.05 ETH | BUILD_PROMPT 4.6; floor from the amendment |
| `KEEPER_SEED` | 0.5 ETH recommended | covers ~30 days of keeper shortfall at 100 pulls/day and 1 gwei (section 4) |
| `LAUNCH_ETH` | 5 ETH recommended | section 6 |
| Buyback | 90 % of treasury; slice 0.05 ETH, 1 h spacing, 3 % impact cap, burn share 50 % | section 3 decision as amended |

## 2. Per-pull economics

FWA charges `EV_list × 1.05` and pays the pool owner `EV_list × 1.025`, where `EV_list` is the harmonic mean of
listing prices (win odds are inverse to price). Listing price = cost × 1.03; cost = backing + 0.001 ETH mint fee
per Shape.


| board | price, markup 0 | price, markup 3 % | E[backing] | E[mint fees] (owner) | markup line (keeper) | margin line (treasury) | FWA |
|---|---|---|---|---|---|---|---|
| shapes-only launch (80x0.01, 15x0.05, 5x0.1) | 0.01379 | 0.01420 | 0.01213 | 0.00100 | 0.000394 | 0.000338 | 0.000338 |
| reference with packs (62x0.01, 26x0.02P, 7x0.03P, 4x0.05, 1x0.1) | 0.01475 | 0.01519 | 0.01282 | 0.00123 | 0.000421 | 0.000362 | 0.000362 |

## 3. Gas receipts (fork, isolated transactions, block 26,279,000)

Each figure is the call's execution gas plus the 21,000 base cost.

| call | gas | ETH at 1 gwei | 5 gwei | 20 gwei |
|---|---|---|---|---|
| a player's `acquire` (FWA) | 584,985 | 0.00058 | 0.00292 | 0.0117 |
| `sync`: 1 pull booked + its replacement minted and listed | 1,117,003 | 0.00112 | 0.00559 | 0.0223 |
| `sync`: 5 pulls + 5 replacements | 2,833,151 | 0.00283 | 0.01417 | 0.0567 |
| `sync`: 20 pulls + 20 replacements | 9,814,243 | 0.00981 | 0.04907 | 0.1963 |
| `Treasury.distribute` | 197,180 | 0.00020 | 0.00099 | 0.0039 |
| `Buyback.process` (one slice, burn + deposit) | 434,141 | 0.00043 | 0.00217 | 0.0087 |
| `GrailFund.process` | 161,136 | 0.00016 | 0.00081 | 0.0032 |
| `Converter.convert` | 347,744 | 0.00035 | 0.00174 | 0.0070 |
| `GenesisFarm.claim`, one epoch | 209,681 | 0.00021 | 0.00105 | 0.0042 |

Per pull, `sync` costs about 1.12M gas for the first pull of a call and about 465k for each further pull
(`(sync_20 − sync_5) / 15`). Almost all of it is the replacement: a Shapes mint and an FWA listing (FWA's segment
tree writes 32 levels per insert). Booking alone is a small part.

## 4. Keeper budget and the 3 % markup


`sync` gas: 1,117,003 for the first pull of a call (booking + replacement mint + listing + routing + tip), 465,406 for each further pull in the same call.

| basefee | 1-pull sync | per extra pull | per pull, batches of 20 | markup line / pull | covered? |
|---|---|---|---|---|---|
| 0.5 gwei | 0.00056 | 0.00023 | 0.00025 | 0.00039 | yes |
| 1 gwei | 0.00112 | 0.00047 | 0.00050 | 0.00039 | 79 % |
| 5 gwei | 0.00559 | 0.00233 | 0.00249 | 0.00039 | 16 % |
| 20 gwei | 0.02234 | 0.00931 | 0.00996 | 0.00039 | 4 % |


| pulls/day | gwei | sync gas cost/day | distribute + buyback + GRAIL/day | markup income/day | net/day | 30 days of shortfall (seed to cover) |
|---|---|---|---|---|---|---|
| 10 | 1 | 0.0053 | 0.0008 | 0.0039 | -0.0022 | 0.065 |
| 30 | 1 | 0.0149 | 0.0008 | 0.0118 | -0.0039 | 0.117 |
| 100 | 1 | 0.0498 | 0.0030 | 0.0394 | -0.0134 | 0.401 |
| 300 | 1 | 0.1494 | 0.0082 | 0.1182 | -0.0394 | 1.182 |
| 10 | 0.5 | 0.0027 | 0.0004 | 0.0039 | +0.0009 | 0.000 |
| 30 | 0.5 | 0.0075 | 0.0004 | 0.0118 | +0.0040 | 0.000 |
| 100 | 0.5 | 0.0249 | 0.0015 | 0.0394 | +0.0130 | 0.000 |
| 300 | 0.5 | 0.0747 | 0.0041 | 0.1182 | +0.0394 | 0.000 |

Answer to rule 9: the 3 % markup covers replacement gas when syncs are batched (20 per call) and the basefee is at
or below about 0.75 gwei; at 1 gwei it covers about 79 %, at 5 gwei about 16 %. The hosted keeper calls only when
the basefee is under 1 gwei or work has waited 6 hours, which batches work and keeps it in the covered range most
of the time. `KEEPER_SEED` of 0.5 ETH covers a month of the 1 gwei shortfall at 100 pulls/day; above that, or at
higher gas, the owner either tops up KeeperFund, raises the markup toward its 5 % cap, or accepts slower
replacement (the board refills when gas is cheap).

## 5. Reserve target and post-genesis operability


Probability that the game cannot pay a batch of 20 replacements at some maintenance window in 21 days at 300 pulls/day, by starting free cash (the reserve), Shapes-only board, markup 3 %, 2,000 seeds. Revenue lines stay in the game while free cash is below the reserve (the protected-capital rule).

| reserve (ETH) | P(shortfall, 21 d) |
|---|---|
| 0.10 | 77.05 % |
| 0.20 | 42.95 % |
| 0.30 | 18.45 % |
| 0.50 | 2.35 % |
| 0.75 | 0.05 % |
| 1.00 | 0.00 % |



### Post-genesis at 10 / 30 / 100 / 300 pulls/day

No prize conversion, minimal trading (hook fees 0), farming gone. Operable means: the keeper can be paid (markup income plus the seed covers sync and the daily jobs) and replacements stay affordable (the reserve absorbs adverse sequences: P(shortfall) for the 0.75 ETH launch reserve over 30 days).

| pulls/day | keeper net/day (1 gwei) | treasury margin/day | P(shortfall) 30 d, reserve 0.75 |
|---|---|---|---|
| 10 | -0.0022 | 0.0034 | 0.00 % |
| 30 | -0.0039 | 0.0101 | 0.00 % |
| 100 | -0.0134 | 0.0338 | 0.00 % |
| 300 | -0.0394 | 0.1014 | 0.00 % |

Post-genesis the system stays operable at every rate: replacements are affordable with the 0.75 ETH reserve, and
the keeper shortfall at 1 gwei is small in absolute terms (0.002 to 0.04 ETH/day), covered by the seed or a top-up,
and positive below about 0.75 gwei. Nothing in the game depends on trading volume or conversions to stay running.

## 6. LAUNCH_ETH


The farm can sell up to 100M ENGINE into a pool that starts with 100M. Price drawdown (lowest price in genesis vs the launch price) and end-of-genesis change, 100 organic pulls/day, 1 gwei.

| LAUNCH_ETH | farm sells | pulls (21 d) | max drawdown | end vs launch | pool ETH at end | owner mint fees |
|---|---|---|---|---|---|---|
| 5 | 100 % | 2,183 | 21 % | -19 % | 4.5 | 2.18 |
| 5 | 50 % | 2,100 | -43 % | +51 % | 6.1 | 2.10 |
| 10 | 100 % | 2,471 | 47 % | -47 % | 7.3 | 2.47 |
| 10 | 50 % | 2,106 | 7 % | -6 % | 9.7 | 2.11 |
| 20 | 100 % | 3,386 | 58 % | -58 % | 12.9 | 3.39 |
| 20 | 50 % | 2,427 | 30 % | -30 % | 16.8 | 2.43 |
| 40 | 100 % | 5,732 | 63 % | -63 % | 24.4 | 5.73 |
| 40 | 50 % | 3,660 | 39 % | -39 % | 31.3 | 3.66 |

The farm can sell up to 100M ENGINE (genesis) into a pool that starts with 100M against `LAUNCH_ETH`. More launch
ETH buys more farming (the same ENGINE realises more ETH, so more pulls are worth farming) and more owner mint fees,
but it is protocol-owned and locked, and the price falls further in proportion when farmers sell everything.
Recommendation: **5 ETH** (start price 5e-8 ETH per ENGINE). With FWA's VRF fee in every pull's cost, farming pays
only at low gas, so extra launch ETH mostly becomes ETH that farmers sell into: going from 5 to 10 ETH adds about 13 %
pulls but more than doubles the model drawdown (21 % → 47 % when farmers sell everything). 10 ETH is reasonable if
the owner's budget is larger and a ~50 % drawdown is acceptable; 20 ETH or more only if the owner wants farming to
carry play and accepts ~60 %.

## 7. 21-day runs


Organic pulls/day are players who play for prizes regardless of rewards; farm pulls are the equilibrium addition. Pre-market buying 1 ETH/day for 48 h; 10 % of won backing converted.

| LAUNCH_ETH | organic/day | gwei | pulls (21 d) | pulls/day avg | owner mint fees | treasury in | keeper: markup in / gas out | ENGINE burned | end price (1e-7 ETH) | start price | end pool ETH |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 5 | 50 | 1 | 1,408 | 67 | 1.41 | 0.64 | 0.55 / 0.93 | 5.8M | 0.30 | 0.50 | 3.9 |
| 5 | 50 | 5 | 1,050 | 50 | 1.05 | 0.50 | 0.41 / 3.75 | 5.5M | 0.28 | 0.50 | 3.8 |
| 5 | 150 | 1 | 3,150 | 150 | 3.15 | 1.27 | 1.24 / 1.79 | 9.3M | 0.54 | 0.50 | 5.2 |
| 5 | 150 | 5 | 3,150 | 150 | 3.15 | 1.27 | 1.24 / 8.97 | 9.3M | 0.54 | 0.50 | 5.2 |
| 5 | 300 | 1 | 6,300 | 300 | 6.30 | 2.42 | 2.48 / 3.36 | 11.8M | 0.99 | 0.50 | 7.0 |
| 5 | 300 | 5 | 6,300 | 300 | 6.30 | 2.42 | 2.48 / 16.82 | 11.8M | 0.99 | 0.50 | 7.0 |
| 10 | 50 | 1 | 1,889 | 90 | 1.89 | 0.89 | 0.74 / 1.17 | 4.9M | 0.45 | 1.00 | 6.7 |
| 10 | 50 | 5 | 1,074 | 51 | 1.07 | 0.59 | 0.42 / 3.81 | 4.2M | 0.41 | 1.00 | 6.4 |
| 10 | 150 | 1 | 3,273 | 156 | 3.27 | 1.38 | 1.29 / 1.86 | 7.5M | 0.64 | 1.00 | 8.0 |
| 10 | 150 | 5 | 3,150 | 150 | 3.15 | 1.34 | 1.24 / 8.97 | 7.5M | 0.63 | 1.00 | 8.0 |
| 10 | 300 | 1 | 6,300 | 300 | 6.30 | 2.48 | 2.48 / 3.36 | 10.2M | 1.02 | 1.00 | 10.1 |
| 10 | 300 | 5 | 6,300 | 300 | 6.30 | 2.48 | 2.48 / 16.82 | 10.2M | 1.02 | 1.00 | 10.1 |
| 20 | 50 | 1 | 3,077 | 147 | 3.08 | 1.48 | 1.21 / 1.76 | 4.5M | 0.78 | 2.00 | 12.5 |
| 20 | 50 | 5 | 1,242 | 59 | 1.24 | 0.80 | 0.49 / 4.22 | 3.1M | 0.67 | 2.00 | 11.6 |
| 20 | 150 | 1 | 3,946 | 188 | 3.95 | 1.78 | 1.55 / 2.19 | 5.7M | 0.91 | 2.00 | 13.5 |
| 20 | 150 | 5 | 3,150 | 150 | 3.15 | 1.48 | 1.24 / 8.97 | 5.4M | 0.87 | 2.00 | 13.2 |
| 20 | 300 | 1 | 6,378 | 304 | 6.38 | 2.65 | 2.51 / 3.40 | 7.9M | 1.22 | 2.00 | 15.6 |
| 20 | 300 | 5 | 6,300 | 300 | 6.30 | 2.62 | 2.48 / 16.82 | 7.9M | 1.21 | 2.00 | 15.6 |
| 40 | 50 | 1 | 5,687 | 271 | 5.69 | 2.73 | 2.24 / 3.06 | 4.5M | 1.48 | 4.00 | 24.4 |
| 40 | 50 | 5 | 1,776 | 85 | 1.78 | 1.30 | 0.70 / 5.55 | 2.6M | 1.22 | 4.00 | 22.1 |
| 40 | 150 | 1 | 5,985 | 285 | 5.98 | 2.84 | 2.36 / 3.21 | 4.7M | 1.53 | 4.00 | 24.7 |
| 40 | 150 | 5 | 3,242 | 154 | 3.24 | 1.82 | 1.28 / 9.20 | 3.8M | 1.38 | 4.00 | 23.5 |
| 40 | 300 | 1 | 7,582 | 361 | 7.58 | 3.40 | 2.99 / 4.00 | 5.9M | 1.75 | 4.00 | 26.4 |
| 40 | 300 | 5 | 6,300 | 300 | 6.30 | 2.92 | 2.48 / 16.82 | 5.6M | 1.69 | 4.00 | 26.0 |


## 8. Farming break-even

Rewards worth more than this per pull (in ETH at the price farmers sell) attract farming. The VRF fee is FWA's, charged per pull in proportion to the transaction's gas price.

| basefee | VRF fee / pull | acquire gas / pull | all-in ticket | loss / pull (ETH) | ENGINE / pull to break even at 1e-7 ETH |
|---|---|---|---|---|---|
| 0.5 gwei | 0.00098 | 0.00029 | 0.01517 | 0.00334 | 33,376 |
| 1 gwei | 0.00195 | 0.00058 | 0.01615 | 0.00461 | 46,051 |
| 5 gwei | 0.00975 | 0.00292 | 0.02395 | 0.01474 | 147,450 |
| 20 gwei | 0.03900 | 0.01170 | 0.05320 | 0.05277 | 527,698 |

The brief's reference figures (0.0021 / 0.0029 / 0.0059 ETH at 1 / 5 / 20 gwei) leave out FWA's VRF fee, which is
`1,500,000 × gas price × 1.3` per pull (`FWACloneVRFService.requestFee`; "VRF request fee 0 today" holds only for a
zero gas price). With it, and the measured gas of a single `acquire`, a pull loses 0.0046 ETH at 1 gwei and 0.0147 at
5 gwei, so farming genesis rewards needs cheap gas: above a few gwei almost no pull is worth farming and play comes
from people who want the prizes. A farmer using `acquireBatch` saves part of the acquire gas, not the VRF fee.


## Honest baseline (as the amended brief asks)

- A pull costs 0.01420 ETH plus FWA's VRF fee (0.00195 ETH at 1 gwei, 0.0097 at 5 gwei). The common outcome (95.5 % of pulls) is a 0.01 ETH Shape: at 1 gwei the player loses 38 % of what they paid (30 % of the ticket alone).
- Treasury revenue from the game is the margin line, 0.000338 ETH per pull; 90 % of it buys ENGINE back: about 0.00030 ETH per pull before hook fees.
- The owner's mint fees, 0.00100 ETH per pull, are 3.0x the treasury's game revenue.
- At 300 pulls/day that is about 0.091 ETH/day of buyback from the game, plus whatever the 3 % hook fee brings.


## 9. Model limits

- The market model is a constant-product pool with the hook fee; it ignores other venues, OTC and arbitrage.
- Farmers are modelled as competitive (they farm until the marginal pull breaks even at the next day's selling
  price); real farmers are lumpier.
- The reserve sim draws captures independently with the board's odds and pays replacements in batches of 20; it
  ignores the GRAIL (funded separately) and board changes.
- Keeper costs assume every sync is paid at the formula; at higher basefees keepers wait (the bounty ramp), which
  this does not model.
