# FWA V1 historical player outcomes

In this recent sample, 30.20% of FWA V1 draws offered an ETH cashout above the ticket price, compared with roughly 14.3% wins in the original Shapes ordinary-prize model. This comparison uses a historical whole-pool sample for FWA and a static ordinary-prize model for Shapes; it is not a comparison of two deployed games or lifetime rates.

## Cohort and results

Ethereum pool: `0xB276F62DB0ce8CA2Ca5bc522695bE604521eAc1c`, identified in [FWA's deployment documentation](https://www.fwa.fun/docs/deployments). Allocation blocks 25,964,020–25,984,020, September 12, 2026 21:27:35 UTC through September 15, 2026 16:20:35 UTC. Settlement observation extends through block 25,991,001.

| Metric | All 2,401 allocations |
| --- | ---: |
| Cashout value above ticket | 725 (30.20%) |
| Cashout value below ticket | 1,676 (69.80%) |
| Exact break-even | 0 |
| Cashout value at least 2× ticket | 112 (4.66%) |
| Median cashout value / ticket | 71.48% |
| Total cashout value / total ticket fees | 90.04% |
| Largest cashout value / ticket | 19.32× |

The aggregate 90.04% is an observed sample result, not a guaranteed or theoretical long-run return. Win frequency depends on inventory and prices and can change over time.

## Method and limits

Join `AcquisitionRequested.acquisitionFee` to every `NFTAllocated` by request ID. Compare the ticket with 90% of the allocated ETH backing, using integer wei for win/loss classification. Gas and pass-through VRF are excluded. Token rewards, later token-price changes and NFT resale premiums are excluded.

The `settlementDiscountBps()` historical getter returned 9000 at block 25,964,020, independently checked with Blockscout. Verified source identifies settlement-discount config key 17; no corresponding `ConfigSet` occurred through the observation end. All 2,346 observed ETH or token settlements also use exactly 90%. See `discount-verification.json`, `FWA.sol`, `FWAConfigKeys.sol`, and the cached config logs.

The primary measure is available ETH cashout value for every allocation, not ETH actually received by every player. Matched outcomes: 2,145 ETH settlements, 201 token settlements, 34 NFTs kept, and 21 unresolved during observation. Token settlement payout records ETH spent purchasing FWA tokens, not liquid ETH received. Actual ETH settlements alone show 32.59% wins, but that subset is selected by player choices and therefore is not the primary all-draw comparator.

The older approximation based on same-window allocated minus kept counts was not a matched cohort and must not be used as a cashout or win rate. This analysis joins individual requests and allocations and retains unresolved settlements explicitly.

## Shapes comparison

The earlier “six out of seven lose” figure describes the original ordinary 0.05/0.10 ETH prize mix, approximately 14.3% wins and 85.7% losses at the discussed ticket prices. It excludes rare grails. FWA's 30.20% includes its whole pool, including larger prizes. Within that scope, FWA's recent win frequency is about 2.1 times the original Shapes ordinary model. Simplifying pricing alone does not establish a more frequent-win experience; inventory composition and ticket price must be assessed together.

## Reproduction

Run `python3 evidence/fee-odds-review/fwa-v1-history/analyze_v1_history.py --from-raw` from the repository root. `raw-rpc.json` retains decoded public logs with original topics/data and joined cohort rows; `results.json` contains derived statistics. Omitting `--from-raw` fetches fresh public RPC logs and extends settlement observation, which can change settlement counts.
