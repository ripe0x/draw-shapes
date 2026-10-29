#!/usr/bin/env python3
"""Purchase gate throughput: in-flight limit x board size (docs/IMPLEMENTOR_DECISIONS.md D45, D49).

Every input is an assumption; every output is a model result, not a forecast. Standard library only; fixed seeds.
Writes sim/results/throughput.md.

Model of the contracts (src/game/PoolOwner.sol `canPurchase`, src/game/FwaGame.sol `_maintenanceDue`, FWAClone):
- Board: the 30 / 45 / 25 mix of 0.01 / 0.05 / 0.5 ETH Shapes scaled to 50, 75 or 100 rows; price = (backing +
  0.001) x 1.05. FWA's fee is the harmonic mean of live prices x 1.05; odds are inverse to price.
- Arrivals: purchases at `eth_per_day` of ticket ETH, Poisson per 12-second block; each purchase is one draw or a
  batch of 5 (FWA's maxAcquisitionsPerTx) with probability `batch_share`.
- The gate (FWA's purchase operator): refuses unless unsettled < limit and live >= unsettled + 5 + floor, floor =
  ceil(80% x rows); it assumes a full batch whatever the purchase size. FWA's VRF layer refuses a purchase that
  would take more than 10 requests awaiting a word. Refused purchases count as rejections (no fee is paid).
- Settlement: a request receives its word 4-6 blocks after it is made and settles in order; FWA refunds it when the
  live fee has risen more than 10% above the fee it escrowed (positive-slippage guard). The VRF fee (about 1.95M
  gas at the gas price) is spent either way.
- Restock (keeper every block): when nothing is in flight, or the board is within limit + 5 rows of the floor; and
  then when 3 rows wait or 5 minutes have passed since the last change; up to 20 rows per call. A listing made while
  requests are unsettled is staged by FWA and joins the draw once they settle. FWA inventory cooldown 0.
"""
import math, os, random

HERE = os.path.dirname(os.path.abspath(__file__))
MINT = 0.001
MARKUP = 0.05
EDGE = 0.05
SLIP = 0.10
VRF_GAS = 1_950_000
BLOCK = 12


def board(rows):
    n1 = round(rows * 0.30)
    n3 = round(rows * 0.25)
    return [(n1, 0.01), (rows - n1 - n3, 0.05), (n3, 0.5)]


class Sim:
    def __init__(self, rows, limit, eth_per_day, batch_share, seed):
        self.tiers = [(b, (b + MINT) * (1 + MARKUP)) for _, b in board(rows)]
        self.target = [n for n, _ in board(rows)]
        self.live = list(self.target)
        self.staged = [0, 0, 0]
        self.rows = rows
        self.floor = math.ceil(0.8 * rows)
        self.limit = limit
        self.rnd = random.Random(seed)
        self.queue = []  # [ready_block, escrowed_fee]
        self.last_change = -10 ** 9
        self.done = self.refunded = self.rejected = self.purchases = 0
        self.turnover = 0.0
        fee0 = self.fee()
        draws_per_purchase = 1 + 4 * batch_share
        self.lam = eth_per_day / fee0 / draws_per_purchase / (86400 / BLOCK)
        self.batch_share = batch_share

    def fee(self):
        w = sum(c / p for c, (_, p) in zip(self.live, self.tiers))
        n = sum(self.live)
        return n / w * (1 + EDGE) if w else float("inf")

    def gate(self):
        u = len(self.queue)
        return u < self.limit and sum(self.live) >= u + 5 + self.floor

    def purchase(self, block, size):
        self.purchases += 1
        if not self.gate() or len(self.queue) + size > 10:
            self.rejected += size
            return
        quote = self.fee()
        for _ in range(size):
            self.queue.append([block + 3 + self.rnd.randint(1, 3), quote])

    def settle(self, block):
        while self.queue and self.queue[0][0] <= block:
            _, quote = self.queue.pop(0)
            fee = self.fee()
            if fee > quote * (1 + SLIP) or sum(self.live) == 0:
                self.refunded += 1
                continue
            w = sum(c / p for c, (_, p) in zip(self.live, self.tiers))
            r = self.rnd.random() * w
            k = 2
            for j, (c, (_, p)) in enumerate(zip(self.live, self.tiers)):
                r -= c / p
                if r <= 0:
                    k = j
                    break
            self.live[k] -= 1
            self.done += 1
            self.turnover += quote
        if not self.queue and any(self.staged):
            self.live = [a + b for a, b in zip(self.live, self.staged)]
            self.staged = [0, 0, 0]

    def keeper(self, block):
        u = len(self.queue)
        held = [a + b for a, b in zip(self.live, self.staged)]
        missing = self.rows - sum(held)
        if missing == 0:
            return
        near = sum(self.live) < self.floor + self.limit + 5
        if u and not near:
            return
        if missing < 3 and block - self.last_change < 300 // BLOCK:
            return
        listed = 0
        for k in range(3):
            while held[k] < self.target[k] and listed < 20:
                held[k] += 1
                listed += 1
                if u:
                    self.staged[k] += 1
                else:
                    self.live[k] += 1
        self.last_change = block

    def run(self, days):
        for block in range(days * 86400 // BLOCK):
            self.settle(block)
            self.keeper(block)
            n = self._poisson(self.lam)
            for _ in range(n):
                self.purchase(block, 5 if self.rnd.random() < self.batch_share else 1)
        return self

    def _poisson(self, lam):
        l, k, p = math.exp(-lam), 0, 1.0
        while True:
            p *= self.rnd.random()
            if p <= l:
                return k
            k += 1


def main():
    lines = []
    w = lines.append
    w("# Purchase gate throughput\n")
    w("Generated by `sim/throughput.py` (fixed seeds). Assumptions in the file header; model results, not forecasts.")
    w("Each cell: 3 runs of 4 days. `completed` is draws that settled with a prize per day; `rejected` is the share of")
    w("draws refused before any fee (gate or FWA's VRF cap); `refunded` is the share of accepted draws FWA refunded on")
    w("drift (the VRF fee is spent); VRF cost is per completed draw at 1 gwei, refunds included.\n")
    days, seeds = 4, 3
    for eth, label in ((10, "10 ETH a day"), (50, "50 ETH a day")):
        w(f"## {label}, 30% of purchases are batches of 5\n")
        w("| board | limit | completed per day | rejected | refunded | VRF per completed draw (1 gwei) |")
        w("|---|---|---|---|---|---|")
        for rows in (50, 75, 100):
            for limit in (3, 4, 5, 10):
                done = ref = rej = 0
                for s in range(seeds):
                    x = Sim(rows, limit, eth, 0.3, seed=1000 * rows + 10 * limit + s).run(days)
                    done += x.done
                    ref += x.refunded
                    rej += x.rejected
                accepted = done + ref
                vrf = (accepted * VRF_GAS * 1e-9) / max(done, 1)
                w(f"| {rows} | {limit} | {done / seeds / days:.0f} | {rej / max(rej + accepted, 1):.2%} | "
                  f"{ref / max(accepted, 1):.2%} | {vrf:.5f} ETH |")
        w("")
    w("## Reading\n")
    w("- Rejections are refusals before payment, not losses. At limits 3-5 most come from the in-flight limit itself:")
    w("  one batch of 5 fills it, so the next purchase within the minute or so a word takes is refused. At limit 10")
    w("  two batches fit, and at 10 ETH a day almost nothing is refused; at 50 ETH a day the rest come from the board")
    w("  falling toward the floor between restocks.")
    w("- Refunds come from FWA's drift guard: each cheap prize captured raises the live fee, and a request settling")
    w("  after several captures can find the fee more than 10% above its escrow. More in flight means more captures")
    w("  between a request's quote and its settlement, so refunds rise with the limit, and fall with board size.")
    w("- Launch value: **limit 10 on the 100-row board**: the most completed draws; refunds stay small. On a board cut")
    w("  to about 50 rows, lower the limit (governance `setCapital`).")
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    open(os.path.join(HERE, "results", "throughput.md"), "w").write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
