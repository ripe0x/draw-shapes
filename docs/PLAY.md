# Play loop

`test/scenario/PlayMonth.t.sol` runs the real contracts on the pinned fork against simulated traffic and
writes CSVs. `script/report.py` turns them into tables and an HTML page. The contracts are the simulator.

## The loop

1. Edit env vars (below) or `script/env/anvil.env`.
2. `FORK_BLOCK=26170000 forge test --match-contract PlayMonth --match-test test_play500PerDay`
3. `python3 script/report.py evidence/play/test_play500PerDay`
4. `open evidence/play/test_play500PerDay/report.html`
5. Compare with FWA: `python3 script/fwa_snapshot.py --out evidence/play/fwa_snapshot.json`, then
   `python3 script/report.py evidence/play/test_play500PerDay --fwa evidence/play/fwa_snapshot.json`.
   The snapshot holds two pools; `--fwa` compares against its default, the mixed-price pool
   `0xfac9af47...`, and `--pool <address>` selects the other (`0x39fde68b...`, all listings at 0.001 ETH).

Tests: `test_play100PerDay`, `test_play500PerDay`, `test_play2000PerDay`, and `test_playCustom`, which runs
when `PLAY_PULLS_PER_DAY` is set. The first run at a fresh fork block fills the RPC cache and is slow.
Later runs read it from disk.

## Env overrides

The runner reads `script/env/anvil.env` (`PLAY_ENV_FILE` to change it) through the same `Deploy._params`
the deploy script uses. Every key `K` of that file is overridden by `PLAY_K`:

- Board: `PLAY_MIX_ROWS`, `PLAY_MIN_ITEMS`, `PLAY_NAV_CAP_WEI`, `PLAY_GRAIL_PROB_CAP_BPS`
- Rotation: `PLAY_ROTATE_INTERVAL_SECONDS`, `PLAY_RESTOCK_TRIGGER_BPS`, `PLAY_QUIET_INTERVAL_SECONDS`,
  `PLAY_REPRICE_MIN_BPS`, `PLAY_OPENING_DEADLINE_SECONDS`
- Fee split: `PLAY_PREMIUM_BPS`, `PLAY_MAINTENANCE_BPS`, `PLAY_FEED_BPS`, `PLAY_MINOR_SHARE_BPS`
- Entry curve: `PLAY_ENTRY_BASE_BPS`, `PLAY_ENTRY_SLOPE_BPS`, `PLAY_ENTRY_CAP_BPS`, `PLAY_ENTRY_REFERENCE_WEI`
- GRAIL, for `MINOR` and `MAJOR`: `PLAY_GRAIL_<T>_TARGET_WEI`, `_STEP_WEI`, `_LIST_BPS`,
  `_DECAY_WEI_PER_PULL`, `_FLOOR_WEI`

Run settings (defaults in brackets):

- `PLAY_PULLS_PER_DAY` (required by `test_playCustom`), `PLAY_DAYS` (7), `PLAY_SEED` (1)
- `PLAY_OPENING_ETH` (50, split over 5 depositors), `PLAY_DEPOSIT_ETH_PER_DAY` (2, one new depositor per day)
- `PLAY_WITHDRAW_SHARE_BPS_PER_DAY` (200 of one random depositor's shares, every other day)
- `PLAY_VRF_LATENCY_SECONDS` (24, applied when FWA's 10 outstanding requests are full)

Amounts take decimals (`PLAY_DEPOSIT_ETH_PER_DAY=0.5`). The same seed and fork block give the same files.

## Reading the report

- Player: return is backing received over the ticket paid (FWA fee plus VRF fee). The share at or above 1x is
  the share of pulls that return at least their ticket. GRAIL rows give hits per track and the hour of the first hit.
- Depositor: NAV per share at hour 0 (board built) and at the last hour, with the annualised rate. Exit wait runs
  from `withdraw` until the claim queue head passes its entry. Payouts from cash count as 0 h.
- Board: purchase pause is the time FWA blocks purchases after an inventory change, from `purchasesResumeAt`.
  Rotate calls are counted by the trigger `rotateDue()` returned. A keeper tick runs every 5 minutes.
- Return buckets list the share of pulls by value over ticket. With `--fwa`, the FWA column holds the same
  metrics from the listing weights, where value is the listing price.

Files per run: `pulls.csv` (one row per request), `hourly.csv` (hour 0 is the baseline, hour h covers the h-th
hour), `claims.csv`, `run.txt` (resolved inputs), `report.html`.

## Live anvil (not built yet)

The runner forks the pinned block inside `forge test`, so it does not write to a running node. The next step is a
`forge script` runner that reuses its loop against `script/deploy.sh anvil` with `CREATE_POOL=1`: warp past the
opening deadline, call `open()` until Live, send purchases from impersonated players with `PLAY_RPC` set, and
deliver VRF words with `anvil_impersonateAccount` on the VRF coordinator. The web port then has a live board to read.
