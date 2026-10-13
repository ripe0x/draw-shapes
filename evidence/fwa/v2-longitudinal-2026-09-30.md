# FWA V2 main pool, longitudinal timeline to 2026-09-30

Pool `0x958C41181182e76F221331b2755b77D9e1426A98`. Head block 26,088,128 (2026-09-30 05:13 UTC). Read-only JSON-RPC (archive: Tenderly gateway, recent: publicnode). Script: `script/fwa-v2-longitudinal.py`. Every number is in `evidence/external/fwa-v2-longitudinal-2026-09-30.json`.

## Window

The pool has no code before block 25,944,609 (2026-09-10 04:30 UTC), so the 90-day window (from block 25,444,628) holds 20.0 days of pool life. One listing is on the board by 09-13, and the first `AcquisitionRequested` is at block 25,991,095 (09-16 15:59 UTC), giving 13.6 days of pulls. Weeks before 09-16 are empty. Samples are daily (20 blocks from 09-10 to head) plus block 26,001,499 (the earlier benchmark anchor) and one block 300 after the first pull.

## Method

Board at each block: Multicall3 over `listings(id)` for every id below `nextListingId`, keeping `status == 1`. Each board is checked against `activeListingCount`, `totalWeight` and `weightedBackingTotal` at the same block; all checks pass. Metrics follow `script/fwa-v2-player-benchmark.py`: independent weighted draws (weight = 1e36 / value), 1,000,000 five-pull sessions, seed 1729, item paid out at 90% of value, gas excluded. Block 26,001,499 reproduces the earlier benchmark exactly (811 listings, fee 0.06745 ETH, median 79.9%, below half 2.06%, above spend 13.87%, 2x or more 1.81%). `vrfServiceFee()` reads 0 at head, so the fee is the whole ticket.

## Board and return per block

Five-pull columns use the 90% cash-out lens. Return at 90% and at face are expected values per pull over the fee. Odds are the largest item's draw probability.

| block | UTC | fee ETH | listings | backing ETH | return 90% | return face | 5-pull median | below half | above spend | 2x+ | largest item | its odds |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 25,945,128 | 09-10 06:14 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| 25,952,278 | 09-11 06:10 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| 25,959,428 | 09-12 06:06 | 0 | 0 | 0 | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| 25,966,578 | 09-13 06:00 | 0.75705 | 1 | 0.7 | 85.71% | 95.24% | 85.7% | 0.00% | 0.00% | 0.00% | 0.721 ETH | 1 in 1 |
| 25,973,728 | 09-14 05:54 | 0.05685 | 33 | 53.3 | 85.71% | 95.24% | 73.5% | 3.17% | 12.05% | 2.25% | 33 ETH | 1 in 20,112 |
| 25,980,878 | 09-15 05:49 | 0.05566 | 42 | 53.9 | 85.71% | 95.24% | 75.0% | 3.57% | 14.92% | 1.73% | 33 ETH | 1 in 26,146 |
| 25,988,028 | 09-16 05:44 | 0.05658 | 521 | 138.7 | 85.71% | 95.24% | 79.7% | 11.20% | 21.21% | 1.35% | 33 ETH | 1 in 319,083 |
| 25,991,395 | 09-16 17:00 | 0.07710 | 258 | 515.0 | 85.71% | 95.24% | 65.6% | 17.46% | 13.57% | 5.03% | 85 ETH | 1 in 298,656 |
| 25,995,178 | 09-17 05:40 | 0.06353 | 675 | 468.5 | 85.71% | 95.24% | 79.3% | 1.27% | 15.29% | 1.40% | 85 ETH | 1 in 948,269 |
| 26,001,499 | 09-18 02:49 | 0.06745 | 811 | 496.7 | 85.71% | 95.24% | 79.9% | 2.06% | 13.87% | 1.81% | 85 ETH | 1 in 1,073,077 |
| 26,002,328 | 09-18 05:35 | 0.06792 | 881 | 500.6 | 85.71% | 95.24% | 80.6% | 1.31% | 14.37% | 1.73% | 85 ETH | 1 in 1,157,692 |
| 26,009,478 | 09-19 05:29 | 0.07106 | 942 | 512.3 | 85.71% | 95.24% | 77.5% | 3.44% | 16.00% | 1.94% | 85 ETH | 1 in 1,183,058 |
| 26,016,628 | 09-20 05:27 | 0.07753 | 1,376 | 560.4 | 85.71% | 95.24% | 80.1% | 3.44% | 19.78% | 1.30% | 85 ETH | 1 in 1,583,925 |
| 26,023,778 | 09-21 05:23 | 0.07762 | 1,824 | 623.4 | 85.71% | 95.24% | 81.2% | 1.84% | 19.23% | 1.05% | 85 ETH | 1 in 2,097,298 |
| 26,030,928 | 09-22 05:25 | 0.07889 | 2,150 | 665.6 | 85.71% | 95.24% | 80.8% | 2.67% | 19.67% | 1.28% | 85 ETH | 1 in 2,432,322 |
| 26,038,078 | 09-23 05:24 | 0.07411 | 2,747 | 712.3 | 85.71% | 95.24% | 80.0% | 0.38% | 19.87% | 1.28% | 85 ETH | 1 in 3,308,218 |
| 26,045,228 | 09-24 05:25 | 0.07807 | 2,588 | 793.3 | 85.71% | 95.24% | 79.9% | 1.47% | 19.42% | 1.21% | 156 ETH | 1 in 5,429,592 |
| 26,052,378 | 09-25 05:28 | 0.08189 | 2,405 | 686.7 | 85.71% | 95.24% | 80.6% | 1.12% | 18.97% | 1.22% | 156 ETH | 1 in 4,810,319 |
| 26,059,528 | 09-26 05:26 | 0.08237 | 2,464 | 609.6 | 85.71% | 95.24% | 80.5% | 1.37% | 19.11% | 1.17% | 156 ETH | 1 in 4,900,045 |
| 26,066,678 | 09-27 05:23 | 0.08506 | 2,643 | 611.9 | 85.71% | 95.24% | 81.2% | 0.44% | 17.97% | 0.83% | 156 ETH | 1 in 5,089,625 |
| 26,073,828 | 09-28 05:22 | 0.08587 | 2,778 | 523.1 | 85.71% | 95.24% | 81.3% | 0.25% | 17.17% | 0.74% | 156 ETH | 1 in 5,299,022 |
| 26,080,978 | 09-29 05:17 | 0.07032 | 3,153 | 535.8 | 85.71% | 95.24% | 81.5% | 5.49% | 22.55% | 0.98% | 156 ETH | 1 in 7,344,860 |
| 26,088,128 | 09-30 05:13 | 0.05107 | 4,090 | 471.0 | 85.71% | 95.24% | 79.3% | 3.08% | 22.96% | 0.98% | 85 ETH | 1 in 7,147,366 |

Face-value five-pull metrics (no cash-out haircut) are in the JSON under `five_pull_face`. At head they read median 88.1%, below half 0.00%, above spend 34.66%, 2x or more 1.49%.

## Pull cadence per week

Weeks end at the head timestamp and step back 7 days. Block timestamps are anchored per 2,000-block bucket and interpolated at 12 seconds a block. Ticket volume is the sum of `acquisitionFee` over `AcquisitionRequested`.

| week (UTC) | pulls | pulls per day | ticket volume ETH |
|---|---|---|---|
| 09-23 05:13 to 09-30 05:13 | 19,939 | 2,848 | 1,617.9 |
| 09-16 05:13 to 09-23 05:13 | 25,519 | 3,646 | 2,012.4 |
| 09-09 05:13 to 09-16 05:13 | 0 | 0 | 0.0 |

Daily pulls (UTC day, pulls, ticket ETH):

| day | pulls | ticket ETH |
|---|---|---|
| 09-16 | 2,679 | 193.7 |
| 09-17 | 3,398 | 233.2 |
| 09-18 | 5,641 | 407.1 |
| 09-19 | 11,801 | 1,023.3 |
| 09-20 | 813 | 63.3 |
| 09-21 | 438 | 34.7 |
| 09-22 | 526 | 40.6 |
| 09-23 | 1,112 | 83.4 |
| 09-24 | 7,797 | 641.8 |
| 09-25 | 3,866 | 319.5 |
| 09-26 | 2,957 | 246.4 |
| 09-27 | 1,758 | 150.0 |
| 09-28 | 1,318 | 113.8 |
| 09-29 | 1,052 | 63.8 |
| 09-30 | 302 | 15.5 |

### Means

- Total 45,458 pulls since block 25,991,095.
- Mean per live day (first pull to head, 13.6 days): 3,355 per day.
- 30-day calendar mean: 1,515 per day (45,458 pulls / 30). 90-day calendar mean: 505 per day (same pulls / 90).
- Cross-check against `sim/data/fwa-v2-cadence.json`: the same event over its block range 25,816,119 to 26,032,119 returns 24,875 acquisitions (24,875 in the file), and 24,875 over its 30.1-day span is 826 per day. The 826 figure therefore spreads 5.7 live days of pulls across a span that includes 24 days before the first pull. Over the live days inside that span the rate is 4,344 per day.

## Realized outcome

`NFTAllocated` carries the delivered item value and `AcquisitionRequested` carries the fee paid, joined on `requestId`. Slippage refunds (`AcquisitionRefundedSlippage`) return the fee for those requests.

- Requests 45,458: allocated 44,917, refunded 541 (all slippage, 52.73 ETH returned), unresolved 0. Gross requested 3,630.24 ETH.
- Allocated pulls paid 3,577.52 ETH and received 3,358.93 ETH of backing: 93.89% at face, 84.50% at 90% cash-out (expected value was 85.71%).
- Per pull, cash-out lens: at or above the fee 30.71%, below half the fee 26.42%, 2x or more 1.74% (face lens 2x or more 2.48%). Expected 2x or more per pull at head is 0.98% (single-item, cash-out).

| week (UTC) | pulls | paid ETH | delivered ETH | ratio face | ratio 90% | 2x+ (90%) | at or above fee (90%) |
|---|---|---|---|---|---|---|---|
| 09-23 05:13 to 09-30 05:13 | 19,939 | 1,617.9 | 1,527.2 | 94.40% | 84.96% | 1.67% | 29.02% |
| 09-16 05:13 to 09-23 05:13 | 24,978 | 1,959.7 | 1,831.7 | 93.47% | 84.12% | 1.80% | 32.06% |
| 09-09 05:13 to 09-16 05:13 | 0 | 0 | 0 | n/a | n/a | n/a | n/a |

The five-pull session shares cannot be observed from events, because sessions are not recorded; only per-pull outcomes are realized figures.

## Summary

Over the 20 days the pool has existed, the board grew from one 0.721 ETH listing (09-13) to 4,090 listings and 471 ETH of backing (09-30), with backing peaking at 793 ETH on 09-24 and falling since. The fee follows the board: it stayed between 0.055 and 0.086 ETH until 09-28, then dropped to 0.0511 ETH by 09-30 while the board grew to 4,090 listings and backing fell to 471 ETH. The expected return per pull is 85.71% at 90% cash-out (95.24% at face) in every sampled block, which equals the fee being 1.05 times the expected backing per pull, so the return has not moved. The shape of outcomes has moved: the five-pull median stayed between 77% and 82% once the board passed 500 listings, the above-spend share rose from about 14% to about 23%, and the 2x or more share fell from 1.8% to 0.98% while the largest item (85 ETH, then 156 ETH from 09-24 to 09-29) carried odds of 1 in 1.1 million to 1 in 7.3 million per pull. The below-half share is volatile (0.25% to 5.5%) and depends on how many cheap listings are present; it read 3.08% at head. Cadence ran 2,679 to 11,801 pulls a day, averaging about 3,350 per live day, with a 30-day calendar mean of 1,515 per day; the sim file's 826 per day is a 30-day mean that includes 24 days before the first pull. Realized outcomes across 44,917 pulls were 84.50% at cash-out and 93.89% at face, 1.74% of pulls at 2x or more.

## Data gaps

- The window is 20 days of pool life inside a requested 90 days; 13 weekly samples were impossible. Daily sampling replaces them.
- Blocks before 09-16 have few listings and no pulls, so their five-pull figures describe a board of 1 to 521 listings.
- Timestamps inside a 2,000-block bucket are interpolated at 12 seconds a block; daily counts can shift by a few pulls at UTC midnight.
- Session-level five-pull outcomes are unobservable from events; the JSON holds per-pull realized figures and expected five-pull figures.
