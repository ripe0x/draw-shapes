#!/usr/bin/env python3
"""Draw Shapes after genesis: board choice, FWA settlement drift, accounting and capital (docs/ECONOMICS.md).

Every input below is an assumption; every output is a model result, not a forecast. Standard library only; fixed
seeds, so a rerun reproduces the report. Writes sim/results/sustainability.md.

Model of the contracts (src/game/FwaGame.sol, FWAClone):
- Board: rows of Shapes; cost = backing + 0.001 ETH mint fee; listing price = cost x (1 + markup). FWA's odds are
  inverse to price; its fee is EV x 1.05 (EV = harmonic mean of live prices) and the owner receives
  fee - (fee - EV) / 2. A request escrows the fee quoted when it is made and settles later, in order, against the
  live pool: if the live fee has risen more than 10% above the escrow FWA refunds it (positive-slippage guard).
- Accounting: revenue = owner proceeds; expense = the captured prize's cost, once; operating allocation = 3% of the
  quote's expected replacement cost (EV / (1 + markup)). Profit is cumulative; losses carry. A distribution is
  min(undistributed profit, cash - replacements owed - ops owed - reserve - unsettled x largest prize cost).
- Keeper: syncs once 10 requests wait to be booked, 20 rows wait to be listed, or `idle_hours` have passed with any
  work; replacements list at most 20 per sync, at most once per 30-minute maintenance window (or at once when the
  board falls below the admission fill), while cash covers them. Tip = gas x base fee x 1.2 + bounty
  (0.002 ETH x age ramp over 6 h x items / 20), paid by KeeperFund while it has funds; anything unpaid is reported
  as a keeper shortfall (settlement never depends on it).
- Admission: new purchases close below 80% board fill or above `max_outstanding` unsettled requests.
- Keeper cost: gas from docs/receipts/gas.json (sync of 1 pull vs 20 pulls gives the per-pull increment) at an
  assumed base fee; KeeperFund keeps 0.5 ETH and returns the rest of the operating allocation to the game.
- No trading-fee inflow anywhere in this file: the game must stand on its own capital and results.
"""
import json, math, os, random

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GAS = json.load(open(os.path.join(ROOT, "docs", "receipts", "gas.json")))

MINT = 0.001
EDGE = 0.05
POS_SLIP = 0.10
VRF_GAS = 1_500_000 * 1.3  # FWACloneVRFService.requestFee: estimate x gas price x (1 + 30% margin)
SYNC_BASE = GAS["sync_1"]
SYNC_PER_PULL = (GAS["sync_20"] - GAS["sync_1"]) / 19

BOARD_20 = [(6, 0.01), (9, 0.05), (5, 0.5)]
BOARD_100 = [(30, 0.01), (45, 0.05), (25, 0.5)]
BOARD_OLD = [(80, 0.01), (15, 0.05), (5, 0.1)]
RESERVE = 12.0
BASEFEE = 1.0


def tiers(board, markup):
    return [dict(n=n, backing=b, cost=b + MINT, price=(b + MINT) * (1 + markup)) for n, b in board]


def economics(board, markup=0.05, ops=0.03):
    t = tiers(board, markup)
    w = sum(x["n"] / x["price"] for x in t)
    ev = sum(x["n"] for x in t) / w
    fee = ev * (1 + EDGE)
    probs = [x["n"] / x["price"] / w for x in t]
    backing = sum(p * x["backing"] for p, x in zip(probs, t))
    mint = sum(p * MINT for p in probs)
    c = ev / (1 + markup)
    proceeds = fee - (fee - ev) / 2
    return dict(inventory=sum(x["n"] * x["cost"] for x in t), fee=fee, probs=probs, headline=1 / probs[-1],
                turnover_per_headline=fee / probs[-1], ret=backing / fee, backing=backing, mint=mint,
                ops=ops * c, fwa=fee - proceeds, margin=proceeds - c - ops * c, c=c, proceeds=proceeds)


def per100(e):
    k = 100 / e["fee"]
    return {key: e[key] * k for key in ("backing", "mint", "ops", "fwa", "margin")}


# ------------------------------------------------------------------ FWA drift: requests accepted on one quote


def drift_table(board, markup=0.05):
    """Fee after removing k of the cheapest prizes: the drift a request accepted before them sees."""
    t = tiers(board, markup)
    prices = []
    for x in t:
        prices += [x["price"]] * x["n"]
    prices.sort()
    fee0 = len(prices) / sum(1 / p for p in prices)
    out = []
    for k in range(1, 9):
        rest = prices[k:]
        out.append((k, len(rest) / sum(1 / p for p in rest) / fee0 - 1))
    return out


def burst_refunds(board, burst, runs=20000, markup=0.05, seed=1):
    """Share of requests refunded when `burst` requests accepted on one quote settle in order (no restock between)."""
    rnd = random.Random(seed)
    t = tiers(board, markup)
    refunded = total = 0
    for _ in range(runs):
        counts = [x["n"] for x in t]
        quote = None
        for _ in range(burst):
            w = sum(c / x["price"] for c, x in zip(counts, t))
            fee = sum(counts) / w * (1 + EDGE)
            if quote is None:
                quote = fee
            total += 1
            if fee > quote * (1 + POS_SLIP):
                refunded += 1
                continue
            r = rnd.random() * w
            for i, (c, x) in enumerate(zip(counts, t)):
                r -= c / x["price"]
                if r <= 0 or i == len(t) - 1:
                    counts[i] -= 1
                    break
    return refunded / total


# ------------------------------------------------------------------ the game over time


class Game:
    def __init__(self, board, capital, reserve=3.0, markup=0.05, ops=0.03, min_live=0.8, max_outstanding=20,
                 basefee_gwei=2.0, idle_hours=4, seed=0):
        self.t = tiers(board, markup)
        self.rows = sum(x["n"] for x in self.t)
        self.counts = [x["n"] for x in self.t]
        self.cash = capital - sum(x["n"] * x["cost"] for x in self.t)
        assert self.cash >= 0, "capital below the board"
        self.reserve, self.markup, self.ops_bps = reserve, markup, ops
        self.min_live, self.max_outstanding = min_live, max_outstanding
        self.basefee = basefee_gwei * 1e-9
        self.idle = idle_hours * 60
        self.last_sync = 0
        self.keeper_short = 0.0
        self.min_headroom = self.cash
        self.rnd = random.Random(seed)
        self.revenue = self.expense = self.ops_accrued = self.ops_returned = self.distributed = 0.0
        self.owed = 0.0  # replacements owed
        self.keeper_fund = 0.5
        self.keeper_spent = 0.0
        self.turnover = 0.0
        self.pulls = self.refunds = self.turned_away = self.headlines = self.mid = 0
        self.closed_minutes = 0
        self.min_cash = self.cash
        self.max_loss = 0.0
        self.unavailable_row_minutes = 0
        self.last_maint = -10 ** 9
        self.pending_pulls = 0

    def live(self):
        return sum(self.counts)

    def fee(self):
        w = sum(c / x["price"] for c, x in zip(self.counts, self.t))
        return sum(self.counts) / w * (1 + EDGE) if w else 0.0

    def profit(self):
        return self.revenue + self.ops_returned - self.expense - self.ops_accrued

    def admissible(self, unsettled=0):
        return self.live() >= self.min_live * self.rows and unsettled <= self.max_outstanding

    def burst(self, n, forced=None):
        """`n` requests accepted on one quote, settled in order against the live pool."""
        if not self.admissible(n - 1) or self.live() == 0:
            self.turned_away += n
            return
        quote = self.fee()
        for i in range(n):
            fee = self.fee()
            if self.live() == 0 or fee > quote * (1 + POS_SLIP):
                self.refunds += 1
                continue
            w = sum(c / x["price"] for c, x in zip(self.counts, self.t))
            if forced is not None and self.counts[forced] > 0:
                k = forced
            else:
                r = self.rnd.random() * w
                k = len(self.t) - 1
                for j, (c, x) in enumerate(zip(self.counts, self.t)):
                    r -= c / x["price"]
                    if r <= 0:
                        k = j
                        break
            x = self.t[k]
            self.counts[k] -= 1
            base = quote / (1 + EDGE)
            proceeds = quote - (quote - base) / 2
            c = base / (1 + self.markup)
            self.revenue += proceeds
            self.cash += proceeds
            self.expense += x["cost"]
            self.ops_accrued += self.ops_bps * c
            self.owed += x["cost"]
            self.min_headroom = min(self.min_headroom, self.cash - self.owed)
            self.turnover += quote
            self.pulls += 1
            self.pending_pulls += 1
            if k == len(self.t) - 1:
                self.headlines += 1
            elif k > 0:
                self.mid += 1
        self.max_loss = min(self.max_loss, self.profit())

    def sync(self, minute):
        # keeper gas for the pulls booked since the last sync, paid by KeeperFund from the operating allocation
        gas = SYNC_BASE + SYNC_PER_PULL * max(self.pending_pulls - 1, 0) if self.pending_pulls else 0
        listed = 0
        due = minute - self.last_maint >= 30 or self.live() < self.min_live * self.rows \
            or self.rows - self.live() >= 20
        if due:
            for k, x in enumerate(self.t):
                while self.counts[k] < x["n"] and listed < 20 and self.cash >= x["cost"]:
                    self.cash -= x["cost"]
                    self.owed = max(self.owed - x["cost"], 0.0)
                    self.counts[k] += 1
                    listed += 1
            if listed:
                self.last_maint = minute
        if gas == 0 and listed:
            gas = SYNC_BASE
        items = self.pending_pulls + listed
        self.pending_pulls = 0
        age = min(minute - self.last_sync, 360) / 360
        self.last_sync = minute
        cost = gas * self.basefee * 1.2 + (0.002 * age * min(items, 20) / 20 if items else 0.0)
        self.keeper_spent += cost
        paid = min(cost, max(self.keeper_fund, 0.0))
        self.keeper_short += cost - paid
        self.keeper_fund -= paid
        # pay the operating allocation once replacements are covered; overflow above 0.5 ETH returns to the game
        self._paid = getattr(self, "_paid", 0.0)
        owe = self.ops_accrued - self._paid
        if owe > 0 and self.cash >= owe + self.owed:
            self.cash -= owe
            self._paid += owe
            self.keeper_fund += owe
            if self.keeper_fund > 0.5:
                back = self.keeper_fund - 0.5
                self.keeper_fund = 0.5
                self.cash += back
                self.ops_returned += back
        # distribute realised profit above protected cash
        undistributed = self.profit() - self.distributed
        keep = self.owed + (self.ops_accrued - self._paid) + self.reserve
        if undistributed > 0 and self.cash > keep:
            d = min(undistributed, self.cash - keep)
            self.cash -= d
            self.distributed += d
        self.min_cash = min(self.min_cash, self.cash)

    def ops_paid(self):
        return getattr(self, "_paid", 0.0)

    def run(self, days, eth_per_day, burst_mean=1.0, clumps=None, forced_headlines=0):
        """Arrivals: Poisson pulls per minute grouped into bursts (geometric size, mean `burst_mean`); with
        `clumps`, the day's volume arrives in that many short sessions instead of evenly."""
        minutes = days * 1440
        fee0 = self.fee()
        pulls_per_min = eth_per_day / fee0 / 1440
        forced_left = forced_headlines
        session = set()
        if clumps:
            for d in range(days):
                for _ in range(clumps):
                    s = d * 1440 + self.rnd.randrange(1440)
                    for m in range(s, min(s + 10, minutes)):
                        session.add(m)
            rate_in = pulls_per_min * 1440 / (clumps * 10)
        for m in range(minutes):
            lam = (rate_in if m in session else 0.0) if clumps else pulls_per_min
            n = self._poisson(lam / burst_mean)
            for _ in range(n):
                size = self._geometric(burst_mean)
                forced = len(self.t) - 1 if forced_left > 0 else None
                if forced is not None:
                    forced_left -= size
                self.burst(size, forced)
            if not self.admissible():
                self.closed_minutes += 1
            self.unavailable_row_minutes += self.rows - self.live()
            missing = self.rows - self.live()
            if self.pending_pulls >= 10 or missing >= 20 or self.live() < self.min_live * self.rows \
                    or ((self.pending_pulls or missing) and m - self.last_sync >= self.idle):
                if m - self.last_sync >= 1:
                    self.sync(m)
        return self

    def _poisson(self, lam):
        if lam <= 0:
            return 0
        l, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rnd.random()
            if p <= l:
                return k
            k += 1

    def _geometric(self, mean):
        if mean <= 1:
            return 1
        p = 1 / mean
        k = 1
        while self.rnd.random() > p and k < 5:
            k += 1
        return k


def quantile(xs, q):
    xs = sorted(xs)
    return xs[min(int(q * len(xs)), len(xs) - 1)]


def scenario(board, label, runs, days, **kw):
    capital = kw.pop("capital", None)
    reserve = kw.pop("reserve", 3.0)
    basefee = kw.pop("basefee_gwei", 2.0)
    res = []
    for s in range(runs):
        inv = sum(n * (b + MINT) for n, b in board)
        g = Game(board, capital if capital else inv + reserve, reserve=reserve, basefee_gwei=basefee, seed=s)
        g.run(days, **kw)
        res.append(g)
    return label, res


def summarize(label, res):
    t = [g.turnover for g in res]
    prof = [g.profit() for g in res]
    dist = [g.distributed for g in res]
    loss = [g.max_loss for g in res]
    minc = [g.min_cash for g in res]
    pulls = sum(g.pulls for g in res)
    ref = sum(g.refunds for g in res) / max(pulls + sum(g.refunds for g in res), 1)
    away = sum(g.turned_away for g in res) / max(pulls + sum(g.turned_away for g in res), 1)
    heads = sum(g.headlines for g in res) / max(sum(t), 1e-9)
    mean_t = sum(t) / len(t)
    p100 = [p / tt * 100 for p, tt in zip(prof, t) if tt > 0]
    keeper = sum(g.keeper_spent for g in res) / max(sum(t), 1e-9) * 100
    closed = sum(g.closed_minutes for g in res) / len(res) / 60
    unavail = sum(g.unavailable_row_minutes for g in res) / len(res) / max(res[0].rows, 1) / 60
    short = sum(g.keeper_short for g in res) / max(sum(t), 1e-9) * 100
    head = [g.min_headroom for g in res]
    return dict(label=label, turnover=mean_t, profit_mean=sum(prof) / len(prof), profit_p05=quantile(prof, 0.05),
                keeper_short=short, headroom_p05=quantile(head, 0.05), headroom_min=min(head),
                profit_p95=quantile(prof, 0.95), per100_mean=sum(p100) / len(p100) if p100 else 0,
                per100_p05=quantile(p100, 0.05) if p100 else 0, per100_p95=quantile(p100, 0.95) if p100 else 0,
                dist_mean=sum(dist) / len(dist), worst_loss=min(loss), loss_p05=quantile(loss, 0.05),
                min_cash=min(minc), refund=ref, away=away, heads_per_eth=heads, keeper_per100=keeper,
                closed_hours=closed, row_hours=unavail)


# ------------------------------------------------------------------ genesis farm


def farm_table(launch_eth=5.0, lp_tokens=800e6, genesis=190e6, reward_value=0.10):
    price = launch_eth / lp_tokens  # ETH per ENGINE at launch
    rate = reward_value * lp_tokens / launch_eth  # ENGINE per ETH of ticket ETH
    cap = genesis / 17.5
    rows = []
    for daily in (0.2, 0.68, 2, 5, 20, 50):
        pot = min(cap, daily * rate)
        rows.append((daily, pot, pot * price / daily, cap - pot))
    return rate, cap, rows


def split_table(launch_eth=5.0):
    rows = []
    for name, lp, gen, bonus in (("80 / 19 / 1 (adopted)", 0.80, 0.19, 0.01), ("70 / 29 / 1", 0.70, 0.29, 0.01),
                                  ("50 / 49 / 1", 0.50, 0.49, 0.01), ("10 / 10 / 1 + 79 reserve (PR #9 before)", 0.10, 0.10, 0.01)):
        supply = 1e9
        price = launch_eth / (lp * supply)
        rows.append((name, lp * supply, supply * price, gen * supply * price, gen / lp))
    return rows


# ------------------------------------------------------------------ report


def main():
    out = []
    w = out.append
    w("# Draw Shapes: sustainability model\n")
    w("Generated by `python3 sim/sustainability.py`. Inputs are assumptions; outputs are model results from a seeded "
      "simulation, not forecasts. No trading-fee inflow is assumed anywhere. Gas from `docs/receipts/gas.json` "
      "(fork, isolated transactions).\n")

    w("## 1. Reference economics (5% markup, 3% operating allocation, FWA edge 5%)\n")
    w("| | 20-item board (6/9/5) | 100-item board (30/45/25) | PR #9 launch board (80/15/5) |")
    w("|---|---|---|---|")
    e20, e100, eold = economics(BOARD_20), economics(BOARD_100), economics(BOARD_OLD, markup=0.03)
    for key, fmt in (("inventory", "{:.2f} ETH"), ("fee", "{:.8f} ETH"), ("headline", "1 in {:.2f}"),
                     ("turnover_per_headline", "{:.5f} ETH"), ("ret", "{:.5%}")):
        w(f"| {key} | {fmt.format(e20[key])} | {fmt.format(e100[key])} | {fmt.format(eold[key])} |")
    w("| probabilities | " + " / ".join(f"{p:.4%}" for p in e20["probs"]) + " | "
      + " / ".join(f"{p:.4%}" for p in e100["probs"]) + " | " + " / ".join(f"{p:.4%}" for p in eold["probs"]) + " |")
    w("\nPer 100 ETH of gameplay (expected):\n")
    w("| line | 20 / 100-item board | PR #9 board |")
    w("|---|---|---|")
    p100, pold = per100(e100), per100(eold)
    for key in ("backing", "mint", "ops", "fwa", "margin"):
        w(f"| {key} | {p100[key]:.5f} | {pold[key]:.5f} |")
    w(f"\nThe margin is an expectation, not a booked figure: realised profit is revenue less the actual cost of the "
      f"prizes won and the operating allocation, and it varies with the draw (section 4).\n")

    w("## 2. FWA settlement drift: requests accepted on one quote\n")
    w("Removing the cheapest prizes raises the live fee; a request accepted before them is refunded once the drift "
      "passes FWA's 10% positive-slippage guard.\n")
    w("| cheap prizes removed ahead | 20-item board | 100-item board |")
    w("|---|---|---|")
    for (k, d20), (_, d100) in zip(drift_table(BOARD_20), drift_table(BOARD_100)):
        w(f"| {k} | {d20:+.2%} | {d100:+.2%} |")
    w("\nShare of requests refunded when a burst settles in order with no restock in between:\n")
    w("| burst size | 20-item board | 100-item board |")
    w("|---|---|---|")
    for b in (2, 3, 5, 10):
        w(f"| {b} | {burst_refunds(BOARD_20, b):.2%} | {burst_refunds(BOARD_100, b):.2%} |")
    w("\nFWA allows at most 5 requests per transaction and, at the pinned block, 10 outstanding VRF requests per pool, "
      "so bursts of 10 need several transactions within a few blocks.\n")

    w("## 3. VRF and execution costs per pull\n")
    w("| gas price | VRF fee | player cost (fee + VRF) | return net of VRF |")
    w("|---|---|---|---|")
    for gp in (0.5, 1, 2, 5, 20):
        vrf = VRF_GAS * gp * 1e-9
        w(f"| {gp} gwei | {vrf:.5f} ETH | {e100['fee'] + vrf:.5f} ETH | {e100['backing'] / (e100['fee'] + vrf):.2%} |")
    w(f"\nKeeper gas: a sync costs {SYNC_BASE:,.0f} gas for its first pull and about {SYNC_PER_PULL:,.0f} gas per "
      f"further pull (booking plus the replacement's mint and listing). The operating allocation, "
      f"{e100['ops']:.6f} ETH per pull, pays that up to a base fee of about "
      f"{e100['ops'] / SYNC_PER_PULL / 1.2 * 1e9:.2f} gwei with the 20% tip premium "
      f"(fork measurement: break-even 2.12 gwei, test/fork/Accounting.t.sol).\n")

    w("## 4. The game over 60 days, no trading fees\n")
    w(f"Capital = board cost + reserve target ({RESERVE:g} ETH). Keeper at a {BASEFEE:g} gwei base fee. 40 seeded "
      "runs per row (12 for the busy row). `per 100 ETH` is realised profit (after the operating allocation, before "
      "distribution) per 100 ETH of ticket ETH; p05/p95 are the 5th and 95th percentiles across runs. `lowest "
      "headroom` is the least cash above replacements owed seen in any run: below zero, rows wait for cash.\n")
    w("| scenario | board | turnover (ETH) | profit mean (p05, p95) | per 100 ETH mean (p05, p95) | distributed | "
      "deepest P&L (p05 of runs) | lowest headroom (p05) | refunded | turned away | headlines per ETH | keeper cost "
      "per 100 ETH | keeper unpaid per 100 ETH | hours closed | row-hours missing per row |")
    w("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    rows = []
    for board_name, board in (("100", BOARD_100), ("20", BOARD_20)):
        for label, kw in (
            ("low: 1 ETH/day, single pulls", dict(eth_per_day=1, burst_mean=1)),
            ("base: 5 ETH/day, bursts mean 2", dict(eth_per_day=5, burst_mean=2)),
            ("busy: 30 ETH/day, bursts mean 3", dict(eth_per_day=30, burst_mean=3)),
            ("clumped: 5 ETH/day in 4 sessions", dict(eth_per_day=5, burst_mean=2, clumps=4)),
            ("adverse: 5 headlines first, then 5 ETH/day", dict(eth_per_day=5, burst_mean=1, forced_headlines=5)),
        ):
            if board_name == "20" and "busy" in label:
                continue
            runs = 12 if "busy" in label else 40
            name, res = scenario(board, label, runs, 60, reserve=RESERVE, basefee_gwei=BASEFEE, **kw)
            s = summarize(name, res)
            rows.append((board_name, s))
            w(f"| {s['label']} | {board_name} | {s['turnover']:.1f} | {s['profit_mean']:+.3f} ({s['profit_p05']:+.3f}, "
              f"{s['profit_p95']:+.3f}) | {s['per100_mean']:+.2f} ({s['per100_p05']:+.2f}, {s['per100_p95']:+.2f}) | "
              f"{s['dist_mean']:.3f} | {s['worst_loss']:+.3f} ({s['loss_p05']:+.3f}) | {s['headroom_min']:+.3f} "
              f"({s['headroom_p05']:+.3f}) | {s['refund']:.2%} | {s['away']:.2%} | {s['heads_per_eth']:.4f} | "
              f"{s['keeper_per100']:.3f} | {s['keeper_short']:.3f} | {s['closed_hours']:.1f} | {s['row_hours']:.2f} |")
    w("\nReading: profit can only be distributed once it is realised and cash stays above every protected amount; "
      "the worst P&L low is the loss the reserve and capital had to absorb before the game recovered. A board that "
      "never runs short of cash keeps every row listed except during the 30-minute maintenance wait.\n")

    w("## 5. Capital requirement\n")
    w("Deterministic obligations: the board at cost (15.15 ETH for the 100-item board) and the replacements owed "
      "between maintenance windows, which the game pays from cash. Risk buffer: a distribution leaves only the reserve "
      "target above replacements owed, so a run of headline wins after a distribution must be absorbed by the reserve; "
      "if it is not, rows wait for cash (the game keeps settling, purchases close below 80% fill). The table sizes "
      "the reserve from 200 runs of 90 days of the base scenario per reserve level: the share of runs in which cash "
      "ever fell below replacements owed, and the row-hours lost.\n")
    w("| reserve target | runs with a cash shortfall | worst headroom | mean row-hours missing per row | "
      "mean hours closed | distributed (mean) |")
    w("|---|---|---|---|---|---|")
    for reserve in (3.0, 5.0, 8.0, 10.0, 12.0):
        res = []
        for sd in range(200):
            inv = sum(n * (b + MINT) for n, b in BOARD_100)
            g = Game(BOARD_100, inv + reserve, reserve=reserve, basefee_gwei=BASEFEE, seed=10_000 + sd)
            g.run(90, eth_per_day=5, burst_mean=2)
            res.append(g)
        short = sum(1 for g in res if g.min_headroom < 0) / len(res)
        w(f"| {reserve:g} ETH | {short:.1%} | {min(g.min_headroom for g in res):+.3f} | "
          f"{sum(g.unavailable_row_minutes for g in res) / len(res) / 100 / 60:.2f} | "
          f"{sum(g.closed_minutes for g in res) / len(res) / 60:.1f} | {sum(g.distributed for g in res) / len(res):.3f} |")
    w("\nA shortfall here is not insolvency: every prize on the board is already owned and every accepted request "
      "settles; it means some rows stay empty until profit refills cash. The reserve is capital, not profit: a larger "
      "reserve barely changes what is distributed over time (last column), it only locks more opening capital. The "
      "launch value is a 12 ETH reserve target (no shortfall in the 200 base runs); recommended opening capital is "
      "the 15.15 ETH board plus the 12 ETH reserve plus about 1 ETH of working cash, **about 28 ETH**. With zero "
      "trading fees the low, base, clumped and adverse scenarios then need no further capital; at 30 ETH a day one run "
      "in twelve briefly ran short (section 4), which more capital or a faster keeper cadence absorbs. A smaller "
      "reserve is a choice to accept occasional empty rows after a run of headline wins.\n")

    w("## 6. Genesis farm: rate cap scenarios\n")
    rate, cap, frows = farm_table()
    w(f"Launch: 5 ETH against the 800M float (price {5 / 800e6:.3e} ETH per ENGINE). Rate cap = 10% of ticket ETH in "
      f"ENGINE at that price = {rate:,.0f} ENGINE per ETH; steady allocation cap = {cap:,.0f} ENGINE per epoch.\n")
    w("| eligible ticket ETH per day | pot (ENGINE) | rewards as % of ticket ETH at launch price | burned at finalization |")
    w("|---|---|---|---|")
    for daily, pot, pct, burned in frows:
        w(f"| {daily} | {pot:,.0f} | {pct:.2%} | {burned:,.0f} |")
    w("\nBelow about 0.68 ETH a day the rate cap binds (a pull earns 10% of its ticket in ENGINE at the launch price, "
      "never a whole pot); above it the allocation cap binds and rewards per ETH fall as activity grows. The "
      "taper multiplies both caps by 87.5% down to 12.5% over the last seven epochs.\n")

    w("## 7. Supply split\n")
    w("| split (LP / genesis / bonus) | LP tokens | launch FDV at 5 ETH | genesis value at launch price | genesis / LP |")
    w("|---|---|---|---|---|")
    for name, lp, fdv, gv, ratio in split_table():
        w(f"| {name} | {lp:,.0f} | {fdv:.2f} ETH | {gv:.2f} ETH | {ratio:.2f} |")
    w("\nWith 80% in the protocol position the farm can at most add 19/80 of the pool's token depth, and the 79% "
      "seasons reserve disappears. The cost is a low launch FDV: the whole genesis allocation is worth about "
      "1.2 ETH at the launch price, so rewards are a modest incentive unless the market values ENGINE higher.\n")

    path = os.path.join(HERE, "results", "sustainability.md")
    open(path, "w").write("\n".join(out) + "\n")
    print(path)


if __name__ == "__main__":
    main()
