#!/usr/bin/env python3
"""ENGINE genesis on an FWA V2 custom pool, Ethereum mainnet: 21 daily epochs.

Model (inputs are assumptions; outputs are model results, not forecasts):
- Board and pricing: listing price = cost (backing + 0.001 ETH mint fee per Shape) x (1 + markup). FWA charges
  EV_list x 1.05 and pays the pool owner EV_list x 1.025 (FWAClone `_completeNFTDelivery`). Win odds are
  inverse to listing price. Per pull: markup line -> KeeperFund, margin line (2.5 % of EV_list) -> Treasury,
  expected cost stays as the replacement budget.
- Gas from docs/receipts/gas.json (fork, isolated transactions): a player's `acquire`, the keeper's `sync`
  (first pull of a batch, then each further pull), `distribute`, buyback `process`, `claim`, `convert`.
- Market: one full-range v4 position, LP fee 0 (constant product), hook fee on the ETH side (3 %) to the
  Treasury. LAUNCH_ETH against the 100M ENGINE float. 48 h pre-market with outside buying `pre_buy` ETH/day.
- Gate: from game open to genesis end the only buyers are prize conversion (a share `convert_share` of the
  backing players win, fee exempt, + 2 % bonus from the 10M pool) and the buyback sinks. Sells always work.
- Treasury: hook fees + margin lines. distribute daily: 90 % Buyback (one purchase per slice, half burned,
  half deposited into that day's epoch), 10 % GRAIL. The Buyback spends at most 0.05 ETH per hour.
- Players: `organic` pulls/day play for prizes regardless of rewards. Farmers add pulls while the ENGINE an
  epoch pays, sold over the next day, returns more ETH per pull than a pull loses (competitive equilibrium).
- Emission: 100M ENGINE over 21 epochs, linear taper 1.5x -> 0.5x of the average epoch.
Writes sim/results/engine-genesis.md. Usage: python3 sim/engine_genesis.py
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GAS = json.load(open(os.path.join(ROOT, "docs", "receipts", "gas.json")))

MINT_FEE = 0.001
EDGE = 0.05
# FWA's VRF service charges serviceGasEstimate × tx.gasprice × (1 + serviceMarginBps) per pull
# (FWACloneVRFService.requestFee; read on the fork: 1,500,000 gas, 3,000 bps, flat 0).
VRF_GAS = 1_500_000 * 1.3
BOARDS = {
    "shapes-only launch (80x0.01, 15x0.05, 5x0.1)": [(80, 0.01, 1), (15, 0.05, 1), (5, 0.1, 1)],
    "reference with packs (62x0.01, 26x0.02P, 7x0.03P, 4x0.05, 1x0.1)": [(62, 0.01, 1), (26, 0.02, 2), (7, 0.03, 3), (4, 0.05, 1), (1, 0.1, 1)],
}
EPOCHS = 21
GENESIS = 100e6
FLOAT = 100e6


def taper(e, total=GENESIS, n=EPOCHS):
    return total * (3 * (n - 1) - 2 * e) / (2 * n * (n - 1))


def board_economics(rows, markup):
    """Per pull: price, expected backing, expected mint fees, markup and margin lines."""
    items = []
    for count, backing, shapes in rows:
        cost = backing + MINT_FEE * shapes
        items.append((count, backing, cost, cost * (1 + markup)))
    w = sum(c / p for c, _, _, p in items)
    ev_list = sum(c for c, _, _, _ in items) / w
    exp_backing = sum(c / p * b for c, b, _, p in items) / w
    exp_cost = sum(c / p * k for c, _, k, p in items) / w
    price = ev_list * (1 + EDGE)
    proceeds = ev_list * (1 + EDGE / 2)
    markup_line = ev_list * markup / (1 + markup)
    margin_line = proceeds - ev_list
    return dict(price=price, backing=exp_backing, mint=exp_cost - exp_backing, markup=markup_line,
                margin=margin_line, fwa=price - proceeds, ev_list=ev_list)


class Pool:
    """Constant-product pool with the hook's fee on the ETH side (to the Treasury)."""

    def __init__(self, eth, tokens, fee=0.03):
        self.x, self.y, self.fee, self.fees = float(eth), float(tokens), fee, 0.0

    def price(self):
        return self.x / self.y

    def buy(self, eth, exempt=False):
        fee = 0.0 if exempt else eth * self.fee
        dx = eth - fee
        out = self.y * dx / (self.x + dx)
        self.x += dx
        self.y -= out
        self.fees += fee
        return out

    def sell(self, tokens):
        gross = self.x * tokens / (self.y + tokens)
        self.y += tokens
        self.x -= gross
        fee = gross * self.fee
        self.fees += fee
        return gross - fee


def keeper_gas_per_pull():
    first = GAS["sync_1"]
    extra = (GAS["sync_20"] - GAS["sync_5"]) / 15
    return first, extra


def run(launch_eth=10.0, gwei=1.0, organic=100, markup=0.03, board="shapes-only launch (80x0.01, 15x0.05, 5x0.1)",
        convert_share=0.10, sell_share=1.0, pre_buy=1.0, batch=20, days=EPOCHS):
    eco = board_economics(BOARDS[board], markup)
    g = gwei * 1e-9
    acquire_gas = GAS["acquire"] * g
    vrf = VRF_GAS * g
    loss = eco["price"] - eco["backing"] + acquire_gas + vrf  # a pull's all-in loss to a player (prize at backing)
    pool = Pool(launch_eth, FLOAT)
    treasury = 0.0
    # 48 h pre-market: outside buying, buys allowed (anti-snipe ignored after the first hour)
    for _ in range(48):
        pool.buy(pre_buy / 24)
    treasury += pool.fees
    fees_seen = pool.fees
    burned = 0.0
    bonus_pool = 10e6
    farm_carry = 0.0  # ENGINE farmers hold from the previous epoch, sold over the next day
    out = dict(days=[], pulls=0, mint_fees=0.0, keeper_income=0.0, keeper_cost=0.0, treasury_in=0.0,
               burned=0.0, rewards=0.0, player_eth_in=0.0, farmer_eth=0.0, loss=loss, eco=eco)
    first, extra = keeper_gas_per_pull()
    expected_realised = None
    for d in range(days):
        pot = taper(d)
        # farmers anticipate the ETH this epoch's ENGINE will realise at today's price, net of slippage
        p_now = pool.price()
        trial = Pool(pool.x, pool.y, pool.fee)
        realised = trial.sell(pot * sell_share)
        farm_pulls = max(0.0, realised / loss - organic)
        pulls = organic + farm_pulls
        # pulls pay the pool; owner (operator) earns the replacement mint fees
        out["pulls"] += pulls
        out["mint_fees"] += pulls * eco["mint"]
        out["player_eth_in"] += pulls * (eco["price"] + vrf)
        out["keeper_income"] += pulls * eco["markup"]
        batches = max(1.0, pulls / batch)
        out["keeper_cost"] += (batches * first + (pulls - batches) * extra) * g
        out["keeper_cost"] += (GAS["distribute"] + 24 * GAS["process_buyback"] + GAS["process_grail"]) * g
        margin = pulls * eco["margin"]
        # prize conversion: a share of won backing buys ENGINE, fee exempt, + 2 % bonus
        conv_eth = pulls * eco["backing"] * convert_share
        conv_out = pool.buy(conv_eth, exempt=True)
        bonus = min(bonus_pool, conv_out * 0.02)
        bonus_pool -= bonus
        # farmers sell yesterday's rewards hourly; buybacks run hourly in slices
        hook_fees_before = pool.fees
        reward_deposit = 0.0
        day_budget = treasury + margin
        burn_budget = day_budget * 0.45  # one Buyback slice of up to 0.05 ETH/h, split 50/50 below
        reward_budget = day_budget * 0.45
        grail = day_budget * 0.10
        treasury = 0.0
        for _ in range(24):
            if farm_carry:
                out["farmer_eth"] += pool.sell(farm_carry / 24)
            b = min(0.025, burn_budget)
            r = min(0.025, reward_budget)
            burn_budget -= b
            reward_budget -= r
            if b + r:
                got = pool.buy(b + r, exempt=True)
                burned += got * b / (b + r)
                reward_deposit += got * r / (b + r)
        treasury += burn_budget + reward_budget  # unspent slices roll over
        farm_carry = (pot + reward_deposit) * sell_share
        new_fees = pool.fees - hook_fees_before
        treasury += new_fees
        out["treasury_in"] += margin + new_fees
        out["rewards"] += pot + reward_deposit
        out["days"].append(dict(day=d, pulls=pulls, farm=farm_pulls, price=pool.price(), pot=pot,
                                deposit=reward_deposit, burned=burned, pool_eth=pool.x,
                                reward_per_pull=(pot + reward_deposit) / pulls * p_now))
    # the last epoch's rewards are sold after genesis (buys reopen; not modelled)
    out["burned"] = burned
    out["end_price"] = pool.price()
    out["end_pool_eth"] = pool.x
    out["bonus_used"] = 10e6 - bonus_pool
    return out


def table(rows, cols):
    head = "| " + " | ".join(c for c, _ in cols) + " |\n|" + "---|" * len(cols) + "\n"
    return head + "\n".join("| " + " | ".join(f(r) for _, f in cols) + " |" for r in rows) + "\n"


def main():
    L = ["# ENGINE genesis on mainnet (generated by sim/engine_genesis.py)\n",
         "Model results under the stated assumptions (module docstring); not forecasts. Gas from "
         "docs/receipts/gas.json measured on the fork.\n"]
    L.append("## Per-pull economics (markup 3 %)\n")
    rows = []
    for name, rws in BOARDS.items():
        e = board_economics(rws, 0.03)
        e0 = board_economics(rws, 0.0)
        rows.append(dict(name=name, **e, price0=e0["price"]))
    L.append(table(rows, [
        ("board", lambda r: r["name"]), ("price, markup 0", lambda r: f"{r['price0']:.5f}"),
        ("price, markup 3 %", lambda r: f"{r['price']:.5f}"), ("E[backing]", lambda r: f"{r['backing']:.5f}"),
        ("E[mint fees] (owner)", lambda r: f"{r['mint']:.5f}"), ("markup line (keeper)", lambda r: f"{r['markup']:.6f}"),
        ("margin line (treasury)", lambda r: f"{r['margin']:.6f}"), ("FWA", lambda r: f"{r['fwa']:.6f}")]))

    L.append("## Farming break-even: a pull's all-in loss (price + VRF fee − E[backing] + acquire gas)\n")
    be = []
    for gw in (0.5, 1, 5, 20):
        e = board_economics(BOARDS["shapes-only launch (80x0.01, 15x0.05, 5x0.1)"], 0.03)
        vrf = VRF_GAS * gw * 1e-9
        gas = GAS["acquire"] * gw * 1e-9
        be.append(dict(g=gw, vrf=vrf, gas=gas, loss=e["price"] - e["backing"] + gas + vrf, ticket=e["price"] + vrf))
    L.append("Rewards worth more than this per pull (in ETH at the price farmers sell) attract farming. The VRF fee "
             "is FWA's, charged per pull in proportion to the transaction's gas price.\n")
    L.append(table(be, [("basefee", lambda r: f"{r['g']} gwei"), ("VRF fee / pull", lambda r: f"{r['vrf']:.5f}"),
                        ("acquire gas / pull", lambda r: f"{r['gas']:.5f}"), ("all-in ticket", lambda r: f"{r['ticket']:.5f}"),
                        ("loss / pull (ETH)", lambda r: f"{r['loss']:.5f}"),
                        ("ENGINE / pull to break even at 1e-7 ETH", lambda r: f"{r['loss'] / 1e-7:,.0f}")]))

    first, extra = keeper_gas_per_pull()
    L.append("## Keeper gas against the 3 % markup\n")
    e = board_economics(BOARDS["shapes-only launch (80x0.01, 15x0.05, 5x0.1)"], 0.03)
    kg = []
    for gw in (0.5, 1, 5, 20):
        g = gw * 1e-9
        kg.append(dict(g=gw, one=first * g, warm=extra * g, b20=(first + 19 * extra) / 20 * g, markup=e["markup"]))
    L.append(f"`sync` gas: {first:,.0f} for the first pull of a call (booking + replacement mint + listing + "
             f"routing + tip), {extra:,.0f} for each further pull in the same call.\n")
    L.append(table(kg, [("basefee", lambda r: f"{r['g']} gwei"), ("1-pull sync", lambda r: f"{r['one']:.5f}"),
                        ("per extra pull", lambda r: f"{r['warm']:.5f}"), ("per pull, batches of 20", lambda r: f"{r['b20']:.5f}"),
                        ("markup line / pull", lambda r: f"{r['markup']:.5f}"),
                        ("covered?", lambda r: "yes" if r["markup"] >= r["b20"] else f"{100 * r['markup'] / r['b20']:.0f} %")]))

    L.append("## 21-day runs\n")
    L.append("Organic pulls/day are players who play for prizes regardless of rewards; farm pulls are the "
             "equilibrium addition. Pre-market buying 1 ETH/day for 48 h; 10 % of won backing converted.\n")
    grid = []
    for launch in (5.0, 10.0, 20.0, 40.0):
        for organic in (50, 150, 300):
            for gw in (1.0, 5.0):
                r = run(launch_eth=launch, organic=organic, gwei=gw)
                grid.append(dict(launch=launch, organic=organic, g=gw, **r))
    L.append(table(grid, [
        ("LAUNCH_ETH", lambda r: f"{r['launch']:g}"), ("organic/day", lambda r: f"{r['organic']}"),
        ("gwei", lambda r: f"{r['g']:g}"), ("pulls (21 d)", lambda r: f"{r['pulls']:,.0f}"),
        ("pulls/day avg", lambda r: f"{r['pulls'] / 21:,.0f}"),
        ("owner mint fees", lambda r: f"{r['mint_fees']:.2f}"),
        ("treasury in", lambda r: f"{r['treasury_in']:.2f}"),
        ("keeper: markup in / gas out", lambda r: f"{r['keeper_income']:.2f} / {r['keeper_cost']:.2f}"),
        ("ENGINE burned", lambda r: f"{r['burned'] / 1e6:.1f}M"),
        ("end price (1e-7 ETH)", lambda r: f"{r['end_price'] * 1e7:.2f}"),
        ("start price", lambda r: f"{r['launch'] / 1e8 * 1e7:.2f}"),
        ("end pool ETH", lambda r: f"{r['end_pool_eth']:.1f}")]))

    base = run(launch_eth=10.0, organic=150, gwei=1.0)
    L.append("## Daily path: LAUNCH_ETH 10, 150 organic pulls/day, 1 gwei\n")
    L.append(table(base["days"], [
        ("epoch", lambda r: str(r["day"])), ("pot (M)", lambda r: f"{r['pot'] / 1e6:.2f}"),
        ("pulls", lambda r: f"{r['pulls']:.0f}"), ("of which farm", lambda r: f"{r['farm']:.0f}"),
        ("deposit (M)", lambda r: f"{r['deposit'] / 1e6:.3f}"),
        ("reward/pull ETH", lambda r: f"{r['reward_per_pull']:.5f}"),
        ("price (1e-7)", lambda r: f"{r['price'] * 1e7:.3f}"), ("pool ETH", lambda r: f"{r['pool_eth']:.2f}"),
        ("burned (M, cum.)", lambda r: f"{r['burned'] / 1e6:.2f}")]))
    L += amended_sections()
    path = os.path.join(HERE, "results", "engine-genesis.md")
    open(path, "w").write("\n".join(L))
    print("\n".join(L))


# ---------------------------------------------------------------------------------------------- amended brief

import random  # noqa: E402

SHAPES_BOARD = BOARDS["shapes-only launch (80x0.01, 15x0.05, 5x0.1)"]


def _draw_cost(rows, markup, rng):
    """One capture's cost (backing + mint fees), drawn with FWA's inverse-price odds."""
    items = [(c, b + MINT_FEE * k) for c, b, k in rows]
    w = [c / (k * (1 + markup)) for c, k in items]
    tot = sum(w)
    u = rng.random() * tot
    for (c, k), wi in zip(items, w):
        u -= wi
        if u <= 0:
            return k
    return items[-1][1]


def shortfall_probability(reserve, pulls_per_day=300, days=21, markup=0.03, seeds=2000, batch=20, rows=SHAPES_BOARD):
    """P(the game cannot fund a replacement at a maintenance window) over `days`, starting with `reserve` of free
    cash. Free cash F = cash - replacements owed. Each pull adds its retained expected cost and, while F is below
    the reserve, its markup and margin lines too (they are not distributed); each capture adds its cost to what is
    owed. Replacements are paid in batches of `batch` (a maintenance window); a shortfall is a window where cash
    cannot pay the batch. Outstanding requests and the cooldown only delay listing, which this models as the batch."""
    eco = board_economics(rows, markup)
    keep = eco["price"] / (1 + EDGE) * (1 + EDGE / 2)  # owner proceeds per pull
    lines = eco["markup"] + eco["margin"]
    rng = random.Random(7)
    fails = 0
    n = pulls_per_day * days
    for _ in range(seeds):
        free = reserve
        owed = 0.0
        failed = False
        for i in range(n):
            cost = _draw_cost(rows, markup, rng)
            proceeds = keep
            # revenue lines leave only above the reserve
            free += proceeds - (lines if free - owed >= reserve else 0.0)
            owed += cost
            if (i + 1) % batch == 0:
                if free < owed:
                    failed = True
                    break
                free -= owed
                owed = 0.0
        fails += failed
    return fails / seeds


def keeper_budget(pulls_per_day, gwei=1.0, markup=0.03, batch=20, rows=SHAPES_BOARD):
    """Daily keeper cost of syncing `pulls_per_day` in batches, distribute, 24 buyback slices and one GRAIL forward,
    against the markup lines those pulls book."""
    eco = board_economics(rows, markup)
    g = gwei * 1e-9
    first, extra = keeper_gas_per_pull()
    batches = max(1.0, pulls_per_day / batch)
    sync = (batches * first + max(0.0, pulls_per_day - batches) * extra) * g
    slices = min(24, max(1, int(pulls_per_day * eco["margin"] * 0.9 / 0.005)))  # small treasuries buy fewer slices
    other = (GAS["distribute"] + slices * GAS["process_buyback"] + GAS["process_grail"]) * g
    income = pulls_per_day * eco["markup"]
    return dict(pulls=pulls_per_day, g=gwei, sync=sync, other=other, cost=sync + other, income=income,
                net=income - sync - other)


def launch_drawdown(launch_eth, sell_share=1.0, organic=100, gwei=1.0):
    r = run(launch_eth=launch_eth, organic=organic, gwei=gwei, sell_share=sell_share)
    start = launch_eth / FLOAT
    low = min(d["price"] for d in r["days"])
    return dict(launch=launch_eth, sell=sell_share, pulls=r["pulls"], drawdown=1 - low / start,
                end=r["end_price"] / start - 1, pool_eth=r["end_pool_eth"], mint=r["mint_fees"])


def amended_sections():
    L = []
    L.append("## Reserve target from adverse sequences\n")
    L.append("Probability that the game cannot pay a batch of 20 replacements at some maintenance window in 21 days "
             "at 300 pulls/day, by starting free cash (the reserve), Shapes-only board, markup 3 %, 2,000 seeds. "
             "Revenue lines stay in the game while free cash is below the reserve (the protected-capital rule).\n")
    rows = []
    for reserve in (0.1, 0.2, 0.3, 0.5, 0.75, 1.0):
        rows.append(dict(r=reserve, p=shortfall_probability(reserve)))
    L.append(table(rows, [("reserve (ETH)", lambda r: f"{r['r']:.2f}"), ("P(shortfall, 21 d)", lambda r: f"{100 * r['p']:.2f} %")]))
    L.append("## Keeper budget by daily pulls (1 gwei, batches of 20)\n")
    kb = [keeper_budget(n) for n in (10, 30, 100, 300)] + [keeper_budget(n, gwei=0.5) for n in (10, 30, 100, 300)]
    L.append(table(kb, [("pulls/day", lambda r: str(r["pulls"])), ("gwei", lambda r: f"{r['g']:g}"),
                        ("sync gas cost/day", lambda r: f"{r['sync']:.4f}"),
                        ("distribute + buyback + GRAIL/day", lambda r: f"{r['other']:.4f}"),
                        ("markup income/day", lambda r: f"{r['income']:.4f}"),
                        ("net/day", lambda r: f"{r['net']:+.4f}"),
                        ("30 days of shortfall (seed to cover)", lambda r: f"{max(0.0, -r['net']) * 30:.3f}")]))
    L.append("## Post-genesis: is the system operable at 10 / 30 / 100 / 300 pulls/day?\n")
    L.append("No prize conversion, minimal trading (hook fees 0), farming gone. Operable means: the keeper can be paid "
             "(markup income plus the seed covers sync and the daily jobs) and replacements stay affordable (the "
             "reserve absorbs adverse sequences: P(shortfall) for the 0.75 ETH launch reserve over 30 days).\n")
    pg = []
    for n in (10, 30, 100, 300):
        k = keeper_budget(n)
        pg.append(dict(n=n, net=k["net"], p=shortfall_probability(0.75, pulls_per_day=n, days=30, seeds=800),
                       treasury=n * board_economics(SHAPES_BOARD, 0.03)["margin"]))
    L.append(table(pg, [("pulls/day", lambda r: str(r["n"])), ("keeper net/day (1 gwei)", lambda r: f"{r['net']:+.4f}"),
                        ("treasury margin/day", lambda r: f"{r['treasury']:.4f}"),
                        ("P(shortfall) 30 d, reserve 0.75", lambda r: f"{100 * r['p']:.2f} %")]))
    L.append("## LAUNCH_ETH against the farm's selling\n")
    L.append("The farm can sell up to 100M ENGINE into a pool that starts with 100M. Price drawdown (lowest price in "
             "genesis vs the launch price) and end-of-genesis change, 100 organic pulls/day, 1 gwei.\n")
    ld = [launch_drawdown(x, s) for x in (5.0, 10.0, 20.0, 40.0) for s in (1.0, 0.5)]
    L.append(table(ld, [("LAUNCH_ETH", lambda r: f"{r['launch']:g}"), ("farm sells", lambda r: f"{100 * r['sell']:.0f} %"),
                        ("pulls (21 d)", lambda r: f"{r['pulls']:,.0f}"), ("max drawdown", lambda r: f"{100 * r['drawdown']:.0f} %"),
                        ("end vs launch", lambda r: f"{100 * r['end']:+.0f} %"), ("pool ETH at end", lambda r: f"{r['pool_eth']:.1f}"),
                        ("owner mint fees", lambda r: f"{r['mint']:.2f}")]))
    e = board_economics(SHAPES_BOARD, 0.03)
    win_small = 0.0
    items = [(c, b + MINT_FEE * k, b) for c, b, k in SHAPES_BOARD]
    w = [c / (k * 1.03) for c, k, _ in items]
    p_small = w[0] / sum(w)
    vrf1 = VRF_GAS * 1e-9
    L.append("## Honest baseline\n")
    L.append(f"- A pull costs {e['price']:.5f} ETH plus FWA's VRF fee ({vrf1:.5f} ETH at 1 gwei, {5 * vrf1:.4f} at 5 gwei). "
             f"The common outcome ({100 * p_small:.1f} % of pulls) is a 0.01 ETH Shape: at 1 gwei the player loses "
             f"{100 * (1 - 0.01 / (e['price'] + vrf1)):.0f} % of what they paid ({100 * (1 - 0.01 / e['price']):.0f} % of the ticket "
             "alone).")
    L.append(f"- Treasury revenue from the game is the margin line, {e['margin']:.6f} ETH per pull; 90 % of it buys "
             f"ENGINE back: about {0.9 * e['margin']:.5f} ETH per pull before hook fees.")
    L.append(f"- The owner's mint fees, {e['mint']:.5f} ETH per pull, are {e['mint'] / e['margin']:.1f}x the treasury's game "
             "revenue.")
    L.append("- At 300 pulls/day that is about "
             f"{300 * 0.9 * e['margin']:.3f} ETH/day of buyback from the game, plus whatever the 3 % hook fee brings.\n")
    return L


if __name__ == "__main__":
    main()
