# Draw Shapes Lab

`sim/lab.html` is one self-contained page: inline CSS, inline script, no external resources. Open it in a
browser. It simulates the v1 pool over 365 days of tickets, with every launch value editable, and compares the
result with the FWA V2 main pool for players and for depositors. The page runs offline.

## Layout

| Block | Content |
| --- | --- |
| Run bar | Horizon (7, 30, 90, 180, 365 days), tickets per day (500 launch, FWA V2 observed 2,848 and 3,646), seed, reset, compute time. |
| Parameters | Contract settings (minimum board depth is the floor of `boardItems`), Deposits (entry fee floor, cap and payback days; NAV cap floor and turnover; founder window days), Board (mix rows), Replacement and cash, Settle, rotate and refunds, Demand and depositors, GRAIL (target, list price, decay, piece floor, floor), Value received basis. Changed fields are marked. |
| Players | Ticket, expected, median, p5, p95 return, shares at or above ticket, below half, 2x or more, 10x or more, house take, for FWA V2 and for Shapes at 90, 180 and 365 days. Shaded cells are better for the player. |
| Depositors | NAV per share chart with cohort break-even and entry price, and a pool NAV chart with the deposit cap, the cap floor, the founder window and the days deposits are closed shaded. Start and end NAV per share, annualised rate, break-even day, entry fee, days deposits are closed, cap, premium, operator mint fees, FWA protocol fees, maintenance. FWA V2 owner margin as a reference. |
| GRAIL | Fund, cycle and target, listed items by size, pieces minted and merges run, hits and largest hit, largest item reached. Chart of the fund, the largest listed item and listed GRAIL backing over 365 days. Hits and largest hit per 30 day month. |
| Board and keeper | Settle and rotate counts (Batch, Age, Thin, Deep), surprises, mint fees saved by held Shapes, average time a captured 0.1 row stays missing, listed items, keeper cost, refunds and the share of cost the maintenance bucket could not cover. Board items (the target depth), listed ordinary items and Deep settle count. Stacked area of listed items by row (daily mean) with a dashed line for the board items target, and a table of mean target depth against mean listed per row. Maintenance balance, cumulative keeper cost, refunds and unpaid cost over time. A side by side of decay reprice in rotate against inside settle. |
| Where 1 ETH goes | Stacked split of a ticket, both sides. |
| One pull | A single ticket traced into buckets, both sides. |
| What moves what | Each parameter at a low and a high value, two seeds, relative change in player figures and in end NAV per share. |
| Check against the fork runs | 7 days, 500 tickets a day, 20 seeds. Columns: fork run, pre-sampling design; fork run, decision 9 (`evidence/play/test_play500PerDay`); the model with the fork run's inputs, with a gate on five measures; the model at lab defaults. |

## Mapping to the contracts

| Model | Contract rule |
| --- | --- |
| Row list price `backing x (1 + premium + maintenance + feed) + mintFee x rungs` | SPEC 8, listing price with `mintLineBps` |
| Ticket = harmonic mean of listing prices x (1 + edge); draw weight 1 / price | SPEC 9, FWA `base`, weight 1e36 / value |
| Proceeds `paid - (paid - base) / 2` | SPEC 9 settlement |
| Mint line owed repaid first, rest split by premium : maintenance : feed, negative margin carries | SPEC 9 step 3 |
| Feed share of the margin and the whole entry fee go to the GRAIL fund | SPEC 7, 9, 11 |
| Daily volume = mean of booked ticket fees over the last 7 complete days, zero before the first complete day | SPEC 7 `dailyVolume()` |
| Entry fee `clamp(paybackDays x premiumBps x dailyVolume / nav, floorBps, capBps)`, zero NAV gives the floor; shares minted at NAV, 1:1 on the first deposit | SPEC 7 `deposit` |
| Deposit cap `max(navCapFloor, dailyVolume x 10,000 / turnoverBps)`, deposits admitted while NAV is below it | SPEC 7 `navCap()`, `docs/VOLUME_CAP.md` |
| Founder window: no deposit for `founderWindowDays` after the board opens; opening deposits are admitted at once | SPEC 7 `depositsOpenAt` |
| Withdrawals paid from cash, remainder queued | SPEC 7 `withdraw`, `payClaims` |
| Board depth `boardItems = max(minItems, floor((NAV - NAV x reserveBps / 10,000) / meanRowCost))`, `meanRowCost` = share-weighted `backing + mintFee x rungs` of the mix rows (0.0308 ETH at the launch mix). Row target = `ceil(boardItems x share)`, recomputed at every capture and keeper tick. NAV is the model's ordinary NAV, already net of claims, so claims are subtracted once | SPEC 9 |
| A capture in a row whose count (listed + held + queued) is above its target queues no replacement; nothing is delisted when NAV falls | SPEC 9 |
| Replacement row sampled at each capture: weight `share x (1 + restoreK x deficit / target)`, deficit `max(target - count, 0)`, target `ceil(boardItems x share)`, count = listed + held + queued | SPEC 9 replacement row, step 2 |
| Surprise with probability `surpriseBps`: single Shape row of at least 5 times the drawn backing, three lowest candidates weighted 60, 30, 10 and cut to the candidate count | SPEC 9 step 3 |
| Band cap `max(target + 1, ceil(target x (1 + bandBps)))`, a capped row falls to the largest deficit, all rows at or above target keep the draw | SPEC 9 step 4 |
| Queue listed by settle when `batchMin` entries wait, the oldest is `batchMaxAge` old, listed ordinary items are below the concurrency guard plus 5, or (Deep) listed, held and queued ordinary items are below `boardItems` by `batchMin` or more; a Deep settle first queues each row's `target - count` missing items in row order; at most 25 items per call; held Shapes fill first; a mint needs cash above claims plus `reserveBps` of NAV; the opening queues every row's target and lists in row order while spendable cash covers the mints | SPEC 9 filling, `settleDue`, SPEC 10 |
| Share `payInShapesBps` of tickets paid with a Shape no larger than the ticket, drawn from the capture value distribution, kept as a held item while spendable cash covers it, NAV unchanged | SPEC 8 `pullWithShapes` |
| Keeper tick every 300 s: settle when due, then rotate when due. Rotate spacing `rotateInterval`; with the toggle on the only reason is GrailStep | SPEC 9 `rotate` |
| Refund `(100k + 150k per listed item + 30k) gas x gasPriceGwei + tipWei` (0.0002 ETH at launch) from the maintenance bucket, capped at its balance; paid by a settle that lists and by a rotate that changes inventory | SPEC 10 refunds |
| `cooldownSeconds` pauses ticket arrival after a listing batch | factory `inventoryChangeCooldown` |
| One GRAIL fund fed by the whole entry fee, the feed share and captured GRAIL proceeds | SPEC 11 Funding |
| Mint: while the fund covers 1 ETH plus the mint fee, pieces are below 6 and items below 16, rotate mints a 1 ETH piece listed at face, up to 3 per pass | SPEC 11 Mint |
| Merge: largest recipe first, at most 2 per pass: 5 from five pieces, 10 from two 5s, 25 from two 10s and a 5, 50 from two 25s, 100 from two 50s; the output lists at `backing x listBps / 10,000`; an output equal to the target completes the cycle, stays listed and is never a recipe input | SPEC 11 Merge |
| Opening five: when the fund covers five pieces and their mint fees at open, one 5 ETH item lists at face | SPEC 11 Opening |
| Every listed GRAIL item loses `decay` per pull down to the piece floor (pieces) or the floor; a reprice needs a drop of 1 percent or more and the listed GRAIL weight at the new price within `grailProbCapBps`; when the cap binds the item keeps its price | SPEC 11 Decay |
| Capture of a GRAIL item pays the ticket proceeds into the fund and the item leaves | SPEC 9 step 2, SPEC 11 Capture |
| Toggle "decay reprice inside settle" (on at launch): a settle call reprices listed GRAIL items after its listing step and is refunded when it listed or repriced, and rotate keeps GRAIL mints and merges. Off gives rotate the Decay reason | SPEC 9, 10 |
| Concurrency guard: fewer than 10 listed ordinary items rejects a ticket | SPEC 9 reopen guards |

Ordinary NAV = cash + ordinary backing (held and listed) - queued claims. GRAIL buckets, GRAIL backing and the
maintenance bucket are outside it. The model conserves ETH exactly: deposits plus proceeds equal cash, backing,
buckets, withdrawals, delivered backing, mint fees, keeper refunds and the maintenance balance at every horizon.

## Statistics

Shapes distribution figures (median, p5, p95, shares) accumulate the probability mass of every outcome at every
ticket, using the listed board at that moment, GRAIL listings included. They are exact expectations over the draw
and the sampled path supplies the board. NAV, hits and prizes come from seeded draws (mulberry32, separate streams
for demand, timing, draws and schedules). FWA V2 figures come from the embedded board histogram at block 26,088,128
with value received at the cash-out setting (90 percent). The board is a snapshot, so tickets per day does not change
the FWA V2 column.

## Not modelled

VRF latency and fees, FWA outstanding request limits, DeliveryPending write-offs and refunds, claim liquidation of
listed items and the Claim and Held rotate reasons, pool staging and the opening deadline, batch pricing, migration and
exit, gas for GRAIL reprices, mints and merges inside a refund, the compose and pack steps of a GRAIL merge (the output lists at
once), the unlisted state of a GRAIL item after a refund, the unsettled-acquisition gate on GRAIL mints and merges, FWA
token and epoch rewards, resale value. Captures are booked at the moment of the ticket. Board depth counts ordinary NAV only, without receivables (the model books proceeds at the capture). The Deep board count is listed + held + queued ordinary items.

## Validation

The block on the page compares the model with the decision 9 fork run. The gates are ticket, expected return, end NAV
per share, mint fees and settle count, each within 5 percent. The model column uses the lab defaults with the inputs the
fork run used: a board fixed at `minItems` (no NAV depth, no Deep, no skip above target), a reprice on any decayed price, no tickets paid with Shapes and a gas price of 0, a tip of 0.0005 ETH,
settle batch size 5 and the decay reprice in rotate. The recording predates the single GRAIL fund and the indexed entry
fee (it ran a minor and a major track), so the GRAIL hit rows compare different mechanisms; the gated measures do not
depend on GRAIL. The structure that matters is the keeper tick of 300 s with arrival groups of 1 to 5 tickets (batches reach 5 at a
tick, which gives about 6.8 items per settle), the sampled replacement with surprises and the band cap (rows above
target lift the ticket and the expected return), and the entry fee on the five opening deposits. The
fork run records no mint events, so its mint fee figure is derived from the hourly NAV balance.

## Checks

`node --check` on the extracted script, and a conservation test that compares deposits plus proceeds with the sum
of every holding and outflow (`check.gap` of a run, below 1e-6 ETH) after 120 days across four parameter sets. The
block between `// MODEL BEGIN` and `// MODEL END` runs in node without a DOM.
