# Draw Shapes Lab

`sim/lab.html` is one self-contained page: inline CSS, inline script, no external resources. Open it in a
browser. It simulates the v1 pool over 365 days of tickets, with every launch value editable, and compares the
result with the FWA V2 main pool for players and for depositors. The page runs offline.

## Layout

| Block | Content |
| --- | --- |
| Run bar | Horizon (7, 30, 90, 180, 365 days), tickets per day (500 launch, FWA V2 observed 2,848 and 3,646), seed, reset, compute time. |
| Parameters | Contract settings, Board (mix rows), Demand and depositors, GRAIL tracks, Value received basis. Changed fields are marked. |
| Players | Ticket, expected, median, p5, p95 return, shares at or above ticket, below half, 2x or more, 10x or more, house take, for FWA V2 and for Shapes at 90, 180 and 365 days. Shaded cells are better for the player. |
| Depositors | NAV per share chart with cohort break-even and entry price, start and end NAV per share, annualised rate, break-even day, premium, GRAIL hits and days to first hit, operator mint fees, FWA protocol fees, maintenance. FWA V2 owner margin as a reference. |
| Where 1 ETH goes | Stacked split of a ticket, both sides. |
| One pull | A single ticket traced into buckets, both sides. |
| What moves what | Each parameter at a low and a high value, two seeds, relative change in player figures and in end NAV per share. |
| Check against the fork run | Launch values, 7 days, 500 tickets a day, 20 seeds, beside `evidence/play/test_play500PerDay`. |

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
| One replacement minted per ticket when cash covers it, listed at the next rotate | SPEC 10 upkeep slice, `rotate` |
| Rotate spacing (`rotateInterval`, keeper tick 300 s) and triggers Weight, GrailCap, GrailStep, Restock, Quiet | SPEC 9 `rotate` |
| GRAIL growth by step when the bucket covers step plus mint fees, decay by pull with the reprice threshold, probability cap lift, capture and reset | SPEC 11 |
| NAV cap closes deposits | SPEC 5 `navCap` |
| Concurrency guard: fewer than 10 listed ordinary items rejects a ticket | SPEC 9 reopen guards |

Ordinary NAV = cash + ordinary backing (held and listed) - queued claims. GRAIL buckets, GRAIL backing and the
maintenance bucket are outside it. The model conserves ETH exactly: deposits plus proceeds equal cash, backing,
buckets, withdrawals, delivered backing and mint fees at every horizon.

## Statistics

Shapes distribution figures (median, p5, p95, shares) accumulate the probability mass of every outcome at every
ticket, using the listed board at that moment, GRAIL listings included. They are exact expectations over the draw
and the sampled path supplies the board. NAV, hits and prizes come from seeded draws (mulberry32, separate streams
for demand, timing, draws and schedules). FWA V2 figures come from the embedded board histogram at block 26,088,128
with value received at the cash-out setting (90 percent). The board is a snapshot, so tickets per day does not change
the FWA V2 column.

## Not modelled

VRF latency and fees, FWA purchase pauses after inventory changes, FWA outstanding request limits, DeliveryPending
write-offs and refunds, claim liquidation of listed items, pool staging and the opening deadline, batch pricing,
migration and exit, rotate refund payments (the maintenance collected is reported instead), the compose step when a
GRAIL pack reaches a native rung, FWA token and epoch rewards, gas, resale value.

## Validation

The block on the page compares the model with the fork run. Figures from the last build are in the change report.
The gates are ticket, expected return, end NAV per share, mint fees and backing delivered, each within 5 percent.
Launch values are used as given. The modelled structure that matters is the relist lag (a replacement is listed at the next
rotate, which lifts the ticket about 1 percent over an instant relist), the depth rule over the last five hours,
and the entry contribution sequence of the five opening deposits.

## Checks

`node --check` on the extracted script, and a conservation test that compares deposits plus proceeds with the sum
of every holding and outflow after 120 days across four parameter sets.
