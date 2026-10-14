# Volume-responsive deposit cap

Status: Built, 2026-10-14. Section 7b is the implementation. `navCapFloor` is the former fixed
`navCap`, and `navCap()` is the volume-responsive cap.

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
`navCapFloor` 69 ETH, `W` 7 days.

Worked example at launch volume, 500 tickets a day at 0.021 ETH: daily volume 10.5 ETH, dynamic
cap 84 ETH, above the 69 ETH floor. At 1,500 a day: 31.5 ETH a day, cap 252 ETH. At 3,000 a
day (FWA's observed cadence): 63 ETH a day, cap 504 ETH. Back to 500 a day: the cap falls to
84 ETH over the 7 day window and deposits close until NAV is below it again.

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
  forced out, and the entry fee still prices every deposit that gets in.
- Migration import: imported NAV bypasses the cap (SPEC 13), unchanged.
- Exiting and Exported: deposits are closed by lifecycle, unchanged.
- Pause: `depositsPaused` still overrides.

## 6. Interaction with other rules

- Entry fee: `paybackDays` days of depositor yield, clamped to `[floorBps, capBps]`, from the same
  `dailyVolume()`. It prices the GRAIL contribution per deposit; the cap decides whether the
  deposit is accepted. Both are read at deposit time.
- Cash reserve: unchanged. More NAV means more cash above the reserve, so replacements are always
  funded when the cap is open.
- GRAIL feed: more volume means more feed; the cap does not touch the GRAIL buckets.
- Board depth: independent. `minItems` sizes the board; the cap sizes capital. The board tide
  idea (parked) would use the same volume measure, so one ring buffer serves both.

## 7. Implementation

### 7b. On-chain

- Storage, appended to `PoolStorage`: `uint128[8] _dailyFees` (slot `day % 8`, written in `_walk` per
  booked capture), `uint32[8] _dailyFeesDay` (the day stamped on each slot, so a stale slot reads as
  zero), `uint16 _turnoverBps`, `uint32 _liveDay`, and the founder window fields. `navCapFloor`
  is the former `navCap` slot.
- `dailyVolume() view`: mean of the complete days before today since `_liveDay`, at most 7.
  Today's partial day is excluded so the cap does not jump within a day.
- `navCap() view`: `max(navCapFloor, dailyVolume() * 10_000 / turnoverBps)`. `_deposit` admits
  while `nav() < navCap()`.
- Setters: `setTurnover(bps)` with bound 1 to 10,000; `setNavCapFloor(wei)`.
- Lens: `parameters` carries `turnoverBps` and `navCapFloor`. `admission()` returns the cap, the
  floor, the trailing daily volume, headroom, `depositsOpenAt`, the entry fee a deposit pays now
  and whether a deposit is admitted.
- Tests: `test/fork/PoolAdmission.t.sol`.

## 8. Lab

Add `turnoverBps`, `navCapFloor` and the window to the lab, with the cap as a line on the NAV
chart and "deposits closed" shading, plus gate-open days per year, so the multiple can be chosen
from the depositor outcome before anything ships. The 365 day default run today closes deposits at
day 30 at the fixed 100 ETH cap; the same run with `turnoverBps` 1,250 should keep them open
whenever volume supports it.

## 9. Owner decisions, 2026-10-14

1. `turnoverBps` 1,250.
2. `navCapFloor` 69 ETH.
3. On-chain implementation (7b) built directly.
