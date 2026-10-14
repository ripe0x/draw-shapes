# Volume-responsive deposit cap

Status: design for owner review, 2026-10-14. Nothing built. Supersedes the fixed `navCap` as the
admission rule if adopted; `navCap` becomes the floor.

## 1. Purpose

Depositors earn the premium share of every settled ticket. The premium per ticket is fixed, so
depositor yield is `premium x ticket volume / NAV`. A fixed cap either starves the pool when play
grows (deposits close while yield is high) or dilutes it when play slows (yield falls toward zero).
The cap should follow volume: open when play can carry more capital, close when it cannot.

## 2. Rule

```
dailyVolume = mean over the trailing W days of booked ticket fees (ETH per day)
capDynamic  = max(navCapFloor, dailyVolume * 10_000 / turnoverBps)
deposit allowed while nav() < capDynamic
```

`turnoverBps` is the target daily turnover, `dailyVolume / NAV`, in basis points. It is the one
economic knob. With premium at 200 bps the implied depositor yield at the cap is
`200 bps x turnoverBps / 10_000` per day:

| turnoverBps | NAV at cap | yield per day at cap | simple per year |
| --- | --- | --- | --- |
| 2,500 | 4 x daily volume | 0.50% | 182% |
| 1,250 | 8 x daily volume | 0.25% | 91% |
| 625 | 16 x daily volume | 0.125% | 46% |
| 250 | 40 x daily volume | 0.05% | 18% |

The old system's "0.25 turnover line" is the first row. Recommended launch: `turnoverBps` 1,250,
`navCapFloor` 100 ETH (today's `navCap`), `W` 7 days.

Worked example at launch volume, 500 tickets a day at 0.021 ETH: daily volume 10.5 ETH, dynamic
cap 84 ETH, so the 100 ETH floor binds. At 1,500 a day: 31.5 ETH a day, cap 252 ETH. At 3,000 a
day (FWA's observed cadence): 63 ETH a day, cap 504 ETH. Back to 500 a day: the cap falls to the
floor over the 7 day window and deposits close until NAV is below it again.

## 3. What counts as volume

Booked ticket fees: the FWA acquisition fee of every acquisition the pool books as a capture in
`_walk` (the `paid` value already read there). Excluded: VRF, gas, refunded and expired requests,
and requests the pool has not booked yet. Direct FWA purchases count once settle books them, which
keeps the rule the same with the purchase gate on or off.

Using booked fees rather than requested fees makes the measure resistant to a buyer who opens
requests and lets them expire, and ties volume to tickets that actually paid the pool.

## 4. Gaming

A depositor could buy tickets to raise the cap. Raising the cap by `X` ETH needs
`X x turnoverBps / 10_000 x W` ETH of volume per window, and every ticket costs the buyer the
house edge (about 16 percent of the ticket at launch, including the mint fees paid to the
operator). At `turnoverBps` 1,250 and W 7, opening 100 ETH of room costs about 87 ETH of tickets
and roughly 14 ETH of edge paid to the pool and the operator. The attacker funds the very premium
the other depositors earn. No depositor can be harmed by it; the pool only gains. No countermeasure
is needed beyond the window, which spreads the cost over a week.

A withdrawal is never blocked by the cap. The cap only closes new deposits.

## 5. Behaviour over the lifecycle

- Opening: no bookings yet, so `dailyVolume` is zero and the cap is the floor. The opening cohort
  is bounded by the floor as today.
- Live, growing: the cap rises with the trailing mean, one day of volume at a time. A spike of play
  raises the cap by one seventh of its size per day and the rise fades over the next week.
- Live, slowing: the cap falls the same way. NAV above the cap simply closes deposits; nothing is
  forced out, and the entry curve still prices every deposit that gets in.
- Migration import: imported NAV bypasses the cap (SPEC 13), unchanged.
- Exiting and Exported: deposits are closed by lifecycle, unchanged.
- Pause: `depositsPaused` still overrides.

## 6. Interaction with other rules

- Entry curve: unchanged. It prices the GRAIL contribution per deposit against NAV; the cap only
  decides whether the deposit is accepted. Both are read at deposit time.
- Cash reserve: unchanged. More NAV means more cash above the reserve, so replacements are always
  funded when the cap is open.
- GRAIL feed: more volume means more feed; the cap does not touch the GRAIL buckets.
- Board depth: independent. `minItems` sizes the board; the cap sizes capital. The board tide
  idea (parked) would use the same volume measure, so one ring buffer serves both.

## 7. Two implementations

### 7a. Off-chain, first

The keeper computes `dailyVolume` from the pool's `Captured` events (or from the FWA clone's
processed acquisitions) over the trailing 7 days and calls `setNavCap(max(floor, volume x 10_000
/ turnoverBps))` once per UTC day when the value moves by more than 5 percent. No contract
change. `navCap` keeps its meaning as the live cap, and Lens shows it. Reversible by stopping the
rule. Downside: the cap is only as live as the keeper, and the rule lives in a script rather than
in the protocol.

### 7b. On-chain, after the rule has been watched

- Storage: `uint128[8] _dailyFees` (slot `day % 8`, written in `_walk` per booked capture with the
  day stamped in a parallel `uint32[8]` so a stale slot reads as zero), `uint16 turnoverBps`,
  `navCapFloor` reusing today's `navCap`.
- `navCapDynamic() view`: mean of the 7 complete days before today (today's partial day is
  excluded so the cap does not jump within a day), times `10_000 / turnoverBps`, floored at
  `navCap`. `_deposit` checks `nav() < navCapDynamic()`.
- Setters: `setTurnover(turnoverBps)` with bound 1 to 10,000; `setNavCap` stays as the floor.
- Lens: `parameters` gains `turnoverBps`; `reopenStatus` or a new `admission()` view returns the
  cap, the trailing daily volume, headroom, and the day boundary at which the cap next changes.
- Size: about 350 bytes in Pool (room exists), one setter in PoolAdmin (555 B margin there, so
  it may go through the existing `setBounds` style or the setter moves with the views).
- Tests: cap equals floor with no volume; cap follows a ramp up and down over 7 days; today's
  partial day excluded; deposit accepted at cap minus one wei and rejected at cap; migration
  import ignores the cap; invariant: `navCapDynamic() >= navCap` always.

## 8. Lab

Add `turnoverBps`, `navCapFloor` and the window to the lab, with the cap as a line on the NAV
chart and "deposits closed" shading, plus gate-open days per year, so the multiple can be chosen
from the depositor outcome before anything ships. The 365 day default run today closes deposits at
day 30 at the fixed 100 ETH cap; the same run with `turnoverBps` 1,250 should keep them open
whenever volume supports it.

## 9. Open decisions for the owner

1. `turnoverBps` at launch (recommended 1,250, which targets a quarter percent a day for
   depositors at the cap).
2. Floor at 100 ETH or lower.
3. 7a now and 7b later, or 7b directly.
