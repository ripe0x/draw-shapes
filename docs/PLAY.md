# Play loop

`test/scenario/PlayMonth.t.sol` runs the real contracts on the pinned fork against simulated traffic and
writes CSVs. `script/report.py` turns them into tables and an HTML page. The contracts are the simulator.

## The loop

1. Edit env vars (below) or `script/env/anvil.env`.
2. `FORK_BLOCK=26170000 forge test --match-contract PlayMonth --match-test test_play500PerDay`
3. `python3 script/report.py evidence/play/test_play500PerDay`
4. `open evidence/play/test_play500PerDay/report.html`
5. Compare with FWA: `python3 script/report.py evidence/play/test_play500PerDay --fwa`. The flag reads
   `evidence/fwa/reference.json` unless a path follows it.

Tests: `test_play100PerDay`, `test_play500PerDay`, `test_play2000PerDay`, and `test_playCustom`, which runs
when `PLAY_PULLS_PER_DAY` is set. The first run at a fresh fork block fills the RPC cache and is slow.
Later runs read it from disk.

## Env overrides

The runner reads `script/env/anvil.env` (`PLAY_ENV_FILE` to change it) through the same `Deploy._params`
the deploy script uses. Every key `K` of that file is overridden by `PLAY_K`:

- Board: `PLAY_MIX_ROWS`, `PLAY_MIN_ITEMS`, `PLAY_NAV_CAP_FLOOR_WEI`, `PLAY_TURNOVER_BPS`, `PLAY_FOUNDER_WINDOW_SECONDS`, `PLAY_GRAIL_PROB_CAP_BPS`
- Rotation and listing: `PLAY_ROTATE_INTERVAL_SECONDS`, `PLAY_OPENING_DEADLINE_SECONDS`, `PLAY_BATCH_MIN`,
  `PLAY_BATCH_MAX_AGE_SECONDS`
- Replacement: `PLAY_SURPRISE_BPS`, `PLAY_RESTORE_K`, `PLAY_BAND_BPS`, `PLAY_RESERVE_BPS`
- Fee split: `PLAY_PREMIUM_BPS`, `PLAY_MAINTENANCE_BPS`, `PLAY_FEED_BPS`
- Entry fee: `PLAY_ENTRY_FLOOR_BPS`, `PLAY_ENTRY_CAP_BPS`, `PLAY_ENTRY_PAYBACK_DAYS`
- GRAIL: `PLAY_GRAIL_TARGET_WEI`, `PLAY_GRAIL_LIST_BPS`, `PLAY_GRAIL_DECAY_WEI_PER_PULL`,
  `PLAY_GRAIL_PIECE_FLOOR_WEI`, `PLAY_GRAIL_FLOOR_WEI`

Run settings (defaults in brackets):

- `PLAY_PULLS_PER_DAY` (required by `test_playCustom`), `PLAY_DAYS` (7), `PLAY_SEED` (1)
- `PLAY_OPENING_ETH` (50, split over 5 depositors), `PLAY_DEPOSIT_ETH_PER_DAY` (2, one new depositor per day)
- `PLAY_WITHDRAW_SHARE_BPS_PER_DAY` (200 of one random depositor's shares, every other day)
- `PLAY_VRF_LATENCY_SECONDS` (24, applied when FWA's 10 outstanding requests are full)
- `PLAY_COOLDOWN` (0, the factory's `inventoryChangeCooldown` in seconds; a nonzero value moves listing from `settle`
  to `rotate`)

Amounts take decimals (`PLAY_DEPOSIT_ETH_PER_DAY=0.5`). The same seed and fork block give the same files.

## Reading the report

- Player: return is backing received over the ticket paid (the FWA acquisition fee; the VRF fee is zero at the fork block). The share at or above 1x is
  the share of pulls that return at least their ticket. GRAIL rows give hits per group (pieces as minor, larger items as major) and the hour of the first hit.
- Depositor: NAV per share at hour 0 (board built) and at the last hour, with the annualised rate. Exit wait runs
  from `withdraw` until the claim queue head passes its entry. Payouts from cash count as 0 h.
- Board: purchase pause is the time FWA blocks purchases after an inventory change, from `purchasesResumeAt`.
  Rotate and settle calls are counted by the reason `rotateDue()` and `settleDue()` returned. A keeper tick runs every
  5 minutes: it calls `settle` when `settleDue()` is nonzero and `rotate` when `rotateDue()` is nonzero.
- Return buckets list the share of pulls by value over ticket. With `--fwa`, one reference column follows the
  run columns: "FWA V2 main, expected" (see FWA reference data). Every row with a value on both sides (ticket,
  expected, median, p5 and p95 return, shares at or above ticket, below half and at 2x or more) marks the better
  side for the player with an asterisk. The histogram shows both series.
- Example pull: after the table, one ticket is split in ETH and percent on each side. The Shapes split is computed
  from `pulls.csv` and the fee split in `run.txt`: the FWA protocol keeps `(paid - base) / 2` with
  `base = paid / feeOverEv` (1.05), each ordinary capture owes the Shapes mint fee (0.001 ETH) per rung, and the
  remaining margin divides by `PREMIUM_BPS : MAINTENANCE_BPS : FEED_BPS`. GRAIL pull proceeds go to the feed.
  The runner records no MarginSplit events, so the split follows the SPEC section 9 formulas applied to the
  recorded per-pull totals. The V2 split is the ticket, 90 percent of the expected backing as cashout, the
  surcharge (ticket over expected backing) and the settlement discount.

Files per run: `pulls.csv` (one row per request), `hourly.csv` (hour 0 is the baseline, hour h covers the h-th
hour), `claims.csv`, `run.txt` (resolved inputs), `report.html`.

## FWA reference data

`evidence/fwa/` holds a static copy of FWA V2 main pool evidence. Nothing fetches from a chain or an API.

- `reference.json`: read by `report.py --fwa`. `v2` holds the V2 main pool `0x958C4118...` at block 26,088,128
  (2026-09-30 05:13 UTC): 4,090 active listings, the ticket (the acquisition fee, 0.051072 ETH), the expected
  value, the 90 percent ETH settlement discount, and `stats` and `histogram` of the single-pull return over
  ticket. `v2.cadence` holds pulls and ticket ETH per day for the last two weeks, and per week
  (2,848 pulls/day in the week to 2026-09-30, 3,646 in the week before). `shapes` holds the Shapes mint fee and
  the denomination ladder used by the example pull. `v2Launch` keeps the earlier launch snapshot (block
  25,991,175, 571 listings, win frequency unknown).
- Distribution source: the full active board, replayed by Multicall3 over `listings(id)` at the block and checked
  against `activeListingCount`, `totalWeight` and `weightedBackingTotal`. FWA selects a listing with weight
  `1e36 / backing`, so the single-pull distribution over the board is exact. Value received is 90 percent of
  backing, over the ticket. `v2-board-26088128-histogram.json` holds the board as `[backing wei, count]` pairs and
  `v2-board-26088128-stats.json` the computed distribution.
- Cadence source: `v2-longitudinal-2026-09-30.json` and `.md` (daily boards and pull cadence from the
  `AcquisitionRequested` log).
- Ticket basis: both sides exclude VRF and gas. A run's `paid` is the FWA acquisition fee with the VRF fee at zero
  at the fork block. The V2 ticket is the acquisition fee, and `vrfServiceFee()` reads 0 at the head block.
- Exclusions: wallet gas, VRF (zero in the simulation, excluded from the V2 ticket), FWA token rewards, epoch
  rewards, NFT resale value.
- `v2-launch-README.md`: method and limits of the launch snapshot, copied from the source repo.

Provenance: board replay copied from the `shapes-on-fwa-v2` repo evidence on 2026-10-13.

## Live anvil (not built yet)

The runner forks the pinned block inside `forge test`, so it does not write to a running node. The next step is a
`forge script` runner that reuses its loop against `script/deploy.sh anvil` with `CREATE_POOL=1`: warp past the
opening deadline, call `open()` until Live, send purchases from impersonated players with `PLAY_RPC` set, and
deliver VRF words with `anvil_impersonateAccount` on the VRF coordinator. The web port then has a live board to read.
