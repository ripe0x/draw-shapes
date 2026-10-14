# Draw Shapes Lab

`sim/lab.html` is one self-contained page: inline CSS, inline script, no external resources. Open it in a
browser. It simulates the v1 pool over 365 days of tickets, with every launch value editable, and compares the
result with the FWA V2 main pool for players and for depositors. The page runs offline.

## Layout

| Block | Content |
| --- | --- |
| Run bar | Horizon (7, 30, 90, 180, 365 days), tickets per day (500 launch, FWA V2 observed 2,848 and 3,646), seed, reset, compute time. |
| Parameters | Contract settings, Board (mix rows), Replacement and cash, Settle, rotate and refunds, Demand and depositors, GRAIL tracks, Value received basis. Changed fields are marked. |
| Players | Ticket, expected, median, p5, p95 return, shares at or above ticket, below half, 2x or more, 10x or more, house take, for FWA V2 and for Shapes at 90, 180 and 365 days. Shaded cells are better for the player. |
| Depositors | NAV per share chart with cohort break-even and entry price, start and end NAV per share, annualised rate, break-even day, premium, GRAIL hits and days to first hit, operator mint fees, FWA protocol fees, maintenance. FWA V2 owner margin as a reference. |
| Board and keeper | Settle and rotate counts, surprises, mint fees saved by held Shapes, average time a captured 0.1 row stays missing, listed items, keeper cost, refunds and the share of cost the maintenance bucket could not cover. Stacked area of listed items by row (daily mean) with a table of mean against target depth. Maintenance balance, cumulative keeper cost, refunds and unpaid cost over time. A side by side of decay reprice in rotate against inside settle. |
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
| Feed and entry contribution split by `minorShareBps` | SPEC 7, 9 |
| Entry contribution `min(cap, base + slope x nav / reference)`, shares minted at NAV, 1:1 on the first deposit | SPEC 7 `deposit` |
| Withdrawals paid from cash, remainder queued | SPEC 7 `withdraw`, `payClaims` |
| Depth of a row = `max(minItems, pulls in the current and four previous clock hours) x share`, rounded up | SPEC 9 |
| Replacement row sampled at each capture: weight `share x (1 + restoreK x deficit / target)`, deficit `max(target - count, 0)`, target `ceil(minItems x share)`, count = listed + held + queued | SPEC 9 replacement row, step 2 |
| Surprise with probability `surpriseBps`: single Shape row of at least 5 times the drawn backing, three lowest candidates weighted 60, 30, 10 and cut to the candidate count | SPEC 9 step 3 |
| Band cap `max(target + 1, ceil(target x (1 + bandBps)))`, a capped row falls to the largest deficit, all rows at or above target keep the draw | SPEC 9 step 4 |
| Queue listed by settle when `batchMin` entries wait, the oldest is `batchMaxAge` old, or listed ordinary items are below the concurrency guard plus 5; at most 10 items per call; held Shapes fill first; a mint needs cash above claims plus `reserveBps` of NAV | SPEC 9 filling, `settleDue`, SPEC 10 |
| Share `payInShapesBps` of tickets paid with a Shape no larger than the ticket, drawn from the capture value distribution, kept as a held item while spendable cash covers it, NAV unchanged | SPEC 8 `pullWithShapes` |
| Keeper tick every 300 s: settle when due, then rotate when due. Rotate spacing `rotateInterval`; with the toggle on the only reason is GrailStep | SPEC 9 `rotate` |
| Refund `(100k + 150k per listed item + 30k) gas x gasPriceGwei + tipWei` (0.0002 ETH at launch) from the maintenance bucket, capped at its balance; paid by a settle that lists and by a rotate that changes inventory | SPEC 10 refunds |
| `cooldownSeconds` pauses ticket arrival after a listing batch | factory `inventoryChangeCooldown` |
| GRAIL growth by step when the bucket covers step plus mint fees, decay by pull when the decayed price is at least 1 percent below the list price, probability cap lift, capture and reset | SPEC 11 |
| Toggle "decay reprice inside settle" (on at launch): a settle call that lists items reprices the GRAIL tracks and lifts them to the probability cap, and rotate keeps GRAIL growth. Off gives rotate the Decay reason | owner decision 9 open item |
| NAV cap closes deposits | SPEC 7 `navCap()` |
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
exit, gas for GRAIL reprices and growth inside a refund, the compose step when a GRAIL pack reaches a native rung, FWA
token and epoch rewards, resale value. Captures are booked at the moment of the ticket.

## Validation

The block on the page compares the model with the decision 9 fork run. The gates are ticket, expected return, end NAV
per share, mint fees and settle count, each within 5 percent. The model column uses the lab defaults with the inputs the
fork run used: decay 0.001 ETH per pull, a reprice on any decayed price, no tickets paid with Shapes and a gas price of
0, a tip of 0.0005 ETH, settle batch size 5, the decay reprice in rotate and a minor list price of 7500 bps. The structure that matters is the keeper tick of 300 s with arrival groups of 1 to 5 tickets (batches reach 5 at a
tick, which gives about 6.8 items per settle), the sampled replacement with surprises and the band cap (rows above
target lift the ticket and the expected return), and the entry contribution sequence of the five opening deposits. The
fork run records no mint events, so its mint fee figure is derived from the hourly NAV balance.

## Checks

`node --check` on the extracted script, and a conservation test that compares deposits plus proceeds with the sum
of every holding and outflow after 120 days across four parameter sets.
