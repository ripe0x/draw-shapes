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
- Treasury: hook fees + margin lines. distribute daily: 45 % burn, 45 % reward (deposited into that day's
  epoch), 10 % GRAIL. Buybacks spend at most 0.05 ETH per sink per hour (1.2 ETH/day/sink).
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
    loss = eco["price"] - eco["backing"] + acquire_gas  # a pull's all-in loss to a player (prize at backing)
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
        out["player_eth_in"] += pulls * eco["price"]
        out["keeper_income"] += pulls * eco["markup"]
        batches = max(1.0, pulls / batch)
        out["keeper_cost"] += (batches * first + (pulls - batches) * extra) * g
        out["keeper_cost"] += (GAS["distribute"] + 2 * 24 * GAS["process_burn"] / 24 + GAS["process_grail"]) * g
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
        burn_budget = day_budget * 0.45
        reward_budget = day_budget * 0.45
        grail = day_budget * 0.10
        treasury = 0.0
        for _ in range(24):
            if farm_carry:
                out["farmer_eth"] += pool.sell(farm_carry / 24)
            b = min(0.05, burn_budget)
            burn_budget -= b
            if b:
                burned += pool.buy(b, exempt=True)
            r = min(0.05, reward_budget)
            reward_budget -= r
            if r:
                reward_deposit += pool.buy(r, exempt=True)
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

    L.append("## Farming break-even: a pull's all-in loss (price − E[backing] + acquire gas)\n")
    be = []
    for gw in (1, 5, 20):
        e = board_economics(BOARDS["shapes-only launch (80x0.01, 15x0.05, 5x0.1)"], 0.03)
        be.append(dict(g=gw, loss=e["price"] - e["backing"] + GAS["acquire"] * gw * 1e-9))
    L.append("Rewards worth more than this per pull (in ETH at the price farmers sell) attract farming.\n")
    L.append(table(be, [("basefee", lambda r: f"{r['g']} gwei"), ("loss / pull (ETH)", lambda r: f"{r['loss']:.5f}"),
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
    path = os.path.join(HERE, "results", "engine-genesis.md")
    open(path, "w").write("\n".join(L))
    print("\n".join(L))


if __name__ == "__main__":
    main()
