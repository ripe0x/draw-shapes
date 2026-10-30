#!/usr/bin/env python3
"""The zero-ETH single-sided ENGINE launch (docs/IMPLEMENTOR_DECISIONS.md D50, docs/ECONOMICS.md section 8).

Every input is an assumption; every output is a model result, not a forecast. Standard library only; deterministic.
Writes sim/results/launch.md.

Model of the contracts (src/token/ProtocolLiquidity.sol, src/token/EngineHook.sol, src/token/GenesisFarm.sol):
- Pool: Uniswap v4 concentrated liquidity, ETH = currency0, ENGINE = currency1, price = ENGINE per ETH = 1.0001^tick.
  `launch` puts the whole 80% float (800M ENGINE) in one position over [TICK_LOWER, startTick) and pairs no ETH. A
  buy pays ETH in and moves the tick down into the range; a sell walks it back. The price can never return above
  the start (in ENGINE terms the ENGINE price never falls below its launch price), and the ETH sellers can take out
  is exactly the ETH buyers (conversions, buybacks) put in.
- Fees: the hook keeps 3% of the ETH side of every swap for the vault (on the input of a buy, the output of a sell);
  the first hour adds an anti-snipe fee on buys from 50% falling linearly to 0.
- Timeline: launch, 48 hours of open market (buys and sells), then the game opens and genesis runs 21 days with
  public buys closed (sells open; the Converter and the burn-only Buyback still buy). After genesis buys reopen.
- Genesis farm: 190M ENGINE over 14 steady epochs and a 7-step taper; per epoch at most the pot and at most the rate
  cap (10% of eligible ticket ETH valued at the start price, tapering with the pot). With ticket ETH spread evenly
  this emits min(190M, 0.0833 x P0 x T) over genesis, P0 the start price in ENGINE per ETH and T the genesis ticket
  ETH. Unemitted ENGINE is burned. The 1% bonus pool pays 2% on top of conversions.
- Genesis inflows: conversions buy ENGINE with `convert_share` of delivered prize backing (return about 76% of
  ticket ETH); buybacks spend `buyback_share` of ticket ETH (realised profit, about 3.5-4.5% in
  sim/results/sustainability.md; 3% assumed as genesis carries early losses).
- The comparison: the same start price with a small two-sided full-range position seeded with ETH (the owner's ETH
  is then exit liquidity too, and the price can fall below the start).
"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))

SUPPLY = 1e9
FLOAT = 8e8
GENESIS = 1.9e8
BONUS = 1e7
FEE = 0.03
TICK_LOWER = -887_200
SPACING = 200


def tick_for_fdv(fdv_eth):
    """The start tick (a multiple of 200) for a fully diluted valuation of `fdv_eth`: price = SUPPLY / FDV."""
    t = math.log(SUPPLY / fdv_eth) / math.log(1.0001)
    return int(round(t / SPACING)) * SPACING


def sqrt_at(tick):
    return 1.0001 ** (tick / 2)


class Pool:
    """Concentrated liquidity positions [(sqrt_lower, sqrt_upper, L)]; S = sqrt(ENGINE per ETH)."""

    def __init__(self, s, positions):
        self.s = s
        self.pos = positions
        self.eth = sum(self._amounts(p)[0] for p in positions)
        self.engine = sum(self._amounts(p)[1] for p in positions)

    def _amounts(self, p):
        a, b, l = p
        s = min(max(self.s, a), b)
        return l * (1 / s - 1 / b), l * (s - a)

    def _liq(self, s, down):
        # liquidity active just below (down) or just above s
        return sum(l for a, b, l in self.pos if (a < s <= b if down else a <= s < b))

    def _breaks(self):
        return sorted({x for a, b, _ in self.pos for x in (a, b)})

    def buy(self, eth_in):
        """ETH in (after fees), ENGINE out: S falls."""
        out, x = 0.0, eth_in
        while x > 1e-18:
            l = self._liq(self.s, True)
            nxt = max([b for b in self._breaks() if b < self.s], default=None)
            if l == 0 or nxt is None:
                break
            need = l * (1 / nxt - 1 / self.s)
            if x >= need:
                out += l * (self.s - nxt)
                x -= need
                self.s = nxt
            else:
                s2 = 1 / (1 / self.s + x / l)
                out += l * (self.s - s2)
                self.s, x = s2, 0.0
        used = eth_in - x
        self.eth += used
        self.engine -= out
        return out, x

    def sell(self, engine_in):
        """ENGINE in, ETH out (before fees): S rises; stops where liquidity ends."""
        out, y = 0.0, engine_in
        while y > 1e-9:
            l = self._liq(self.s, False)
            nxt = min([b for b in self._breaks() if b > self.s], default=None)
            if l == 0 or nxt is None:
                break
            need = l * (nxt - self.s)
            if y >= need:
                out += l * (1 / self.s - 1 / nxt)
                y -= need
                self.s = nxt
            else:
                s2 = self.s + y / l
                out += l * (1 / self.s - 1 / s2)
                self.s, y = s2, 0.0
        self.eth -= out
        self.engine += engine_in - y
        return out, y

    def price(self):
        return self.s * self.s  # ENGINE per ETH

    def fdv(self):
        return SUPPLY / self.price()


def single_sided(tick):
    s0, sa = sqrt_at(tick), sqrt_at(TICK_LOWER)
    return Pool(s0, [(sa, s0, FLOAT / (s0 - sa))])


def seeded(tick, seed_eth):
    """The same start with a full-range two-sided position seeded with `seed_eth` and matching ENGINE taken from the
    float; the rest of the float single-sided above it."""
    s0, sa, sb = sqrt_at(tick), sqrt_at(TICK_LOWER), sqrt_at(-TICK_LOWER)
    l_full = seed_eth / (1 / s0 - 1 / sb)
    engine_full = l_full * (s0 - sa)
    rest = FLOAT - engine_full
    return Pool(s0, [(sa, sb, l_full), (sa, s0, rest / (s0 - sa))])


def snipe_fee(minute):
    return 0.5 * max(0.0, 1 - minute / 60)


def opening(pool, total_eth, n=10, sniper=False):
    """`total_eth` of buys spread over the 48-hour market: `n` buys of falling size (the first is the largest); with
    `sniper`, the first buy lands at minute 0 and pays the 50% anti-snipe fee. Returns buyers, vault fees."""
    weights = [1 / (i + 1) for i in range(n)]
    sizes = [total_eth * w / sum(weights) for w in weights]
    buyers, fees = [], 0.0
    for i, eth in enumerate(sizes):
        minute = 0 if (sniper and i == 0) else 60 + i * (2880 - 60) / n
        fee = eth * (FEE + snipe_fee(minute))
        got, _ = pool.buy(eth - fee)
        fees += fee
        buyers.append(dict(eth=eth, engine=got))
    return buyers, fees


def genesis(pool, p0, ticket_eth, sell_share, convert_share=0.25, buyback_share=0.03, steps=21):
    """Genesis epochs: conversions and buybacks buy, farmers claim and sell `sell_share` of their rewards. Returns
    rewards emitted, ETH taken out by farm sales (after fees), vault fees, ETH bought in."""
    emitted = min(GENESIS, 0.0833 * p0 * ticket_eth)
    bonus = 0.0
    farm_eth = fees = bought = 0.0
    for _ in range(steps):
        t = ticket_eth / steps
        for eth in (t * 0.76 * convert_share, t * buyback_share):
            if eth <= 0:
                continue
            fee = eth * FEE
            got, _ = pool.buy(eth - fee)
            fees += fee
            bought += eth
            if eth == t * 0.76 * convert_share:
                b = min(got * 0.02, BONUS - bonus)
                bonus += b
        sold = emitted / steps * sell_share
        if sold > 0:
            out, _ = pool.sell(sold)
            fee = out * FEE
            fees += fee
            farm_eth += out - fee
    return dict(emitted=emitted, farm_eth=farm_eth, fees=fees, bought=bought, bonus=bonus)


def exit_value(pool, engine):
    p = Pool.__new__(Pool)
    p.s, p.pos, p.eth, p.engine = pool.s, pool.pos, pool.eth, pool.engine
    out, left = p.sell(engine)
    return out * (1 - FEE), left


def main():
    lines = []
    w = lines.append
    w("# Single-sided launch model\n")
    w("Generated by `sim/launch.py` (deterministic). Assumptions in the file header; these are model results, not")
    w("forecasts. FDV is in ETH at the pool price (1B supply). \"Exit\" is what selling the position into the pool at")
    w("that moment would return after the 3% fee.\n")

    fdvs = [5, 10, 20, 40]
    w("## 1. Start price and the first buys\n")
    w("| start FDV | START_TICK | ENGINE per ETH | rate cap (ENGINE per ticket ETH) | 0.1 ETH buy moves the price | 1 ETH | 5 ETH |"
      " farm budget at the start price |")
    w("|---|---|---|---|---|---|---|---|")
    for f in fdvs:
        t = tick_for_fdv(f)
        p0 = 1.0001 ** t
        moves = []
        for eth in (0.1, 1, 5):
            pool = single_sided(t)
            pool.buy(eth * (1 - FEE))
            moves.append(p0 / pool.price() - 1)
        w(f"| {f} ETH | {t:,} | {p0 / 1e6:,.2f}M | {0.1 * p0 / 1e6:,.2f}M | +{moves[0]:.1%} | +{moves[1]:.1%} | "
          f"+{moves[2]:.1%} | {GENESIS / p0:.2f} ETH |")
    w("")
    w("Reading: the start FDV is the lowest valuation ENGINE can ever trade at. A low start makes the first buys move")
    w("the price a lot (early buyers capture most of the move); a high start makes the farm budget worth more ETH at")
    w("the start price, and that is what farmers can try to sell into buyers' ETH during genesis.\n")

    w("## 2. Opening market (48 hours, buys and sells open)\n")
    w("Ten buys of falling size spread over the 48 hours after the first hour (no anti-snipe fee), the largest first.")
    w("`top buyer` is the largest buyer's share of the ENGINE bought and of supply.\n")
    w("| start FDV | opening buys | FDV after | ETH in the pool (exit liquidity) | vault fees | top buyer share of bought |"
      " of supply | top buyer exit now |")
    w("|---|---|---|---|---|---|---|---|")
    for f in fdvs:
        t = tick_for_fdv(f)
        for total in (0.1, 0.5, 1, 5):
            pool = single_sided(t)
            buyers, fees = opening(pool, total)
            bought = sum(b["engine"] for b in buyers)
            top = buyers[0]
            ex, _ = exit_value(pool, top["engine"])
            w(f"| {f} | {total} ETH | {pool.fdv():.2f} ETH | {max(pool.eth, 0):.3f} ETH | {fees:.4f} ETH | "
              f"{top['engine'] / bought:.0%} | {top['engine'] / SUPPLY:.2%} | {ex:.3f} of {top['eth']:.3f} ETH |")
    w("")
    w("A sniper at minute 0 pays the 50% anti-snipe fee: at 10 ETH FDV a 1 ETH first buy then gets")
    pool = single_sided(tick_for_fdv(10))
    buyers, fees = opening(pool, 1, n=1, sniper=True)
    pool2 = single_sided(tick_for_fdv(10))
    buyers2, _ = opening(pool2, 1, n=1)
    w(f"{buyers[0]['engine'] / 1e6:.1f}M ENGINE against {buyers2[0]['engine'] / 1e6:.1f}M an hour later, and the vault"
      f" keeps {fees:.3f} ETH.\n")

    w("## 3. Genesis: farm rewards selling into the single-sided pool\n")
    w("After the opening buys, 21 epochs with public buys closed. Buybacks spend 3% of ticket ETH; conversions buy with")
    w("0% (worst case: nobody converts) or 25% of delivered backing; farmers sell everything they are emitted, as they")
    w("are emitted. `farm ETH out` is what farm sales took out of the pool; `opening buyers exit` is what all opening")
    w("buyers together would get by selling at the end of genesis.\n")
    w("| start FDV | opening | genesis tickets | conversions | farm emitted | farm ETH out | ETH bought in genesis | "
      "pool ETH at end | FDV at end | opening buyers exit (of paid) |")
    w("|---|---|---|---|---|---|---|---|---|---|")
    for f in (5, 10, 20):
        t = tick_for_fdv(f)
        p0 = 1.0001 ** t
        for opening_eth in (1, 5):
            for tickets in (20, 100, 300):
                for conv in (0.0, 0.25):
                    pool = single_sided(t)
                    buyers, _ = opening(pool, opening_eth)
                    g = genesis(pool, p0, tickets, 1.0, convert_share=conv)
                    held = sum(b["engine"] for b in buyers)
                    ex, _ = exit_value(pool, held)
                    w(f"| {f} | {opening_eth} ETH | {tickets} ETH | {conv:.0%} | {g['emitted'] / 1e6:.0f}M | "
                      f"{g['farm_eth']:.2f} ETH | {g['bought']:.2f} ETH | {max(pool.eth, 0):.2f} ETH | {pool.fdv():.2f} ETH | "
                      f"{ex:.2f} of {opening_eth} ETH |")
    w("")
    w("Reading: farmers can only take out ETH that buyers put in, and every ENGINE they sell returns to the curve, so")
    w("the price can at worst return to the start. Without conversions the only genesis buying is the 3% buyback, and")
    w("full farm selling takes the price back to (or near) the start: opening buyers then exit with less than they")
    w("paid, the farm having taken their ETH. That is the cost of the 19% farm under a single-sided launch with buys")
    w("closed during genesis. Conversions are what keep buying in the pool; the 2% bonus is there to encourage them.\n")

    w("## 4. Single-sided against a small seeded two-sided position\n")
    w("Same start price (10 ETH FDV), 1 ETH of opening buys, 20 ETH of genesis tickets, no conversions, farmers sell")
    w("everything: the case in which sells outrun buys and the floor binds. The seeded variant adds a full-range")
    w("position with the owner's ETH at the start price.\n")
    w("| launch | owner ETH paired | lowest possible FDV | FDV at end | pool ETH at end | farm ETH out | of which the owner's |")
    w("|---|---|---|---|---|---|---|")
    t = tick_for_fdv(10)
    p0 = 1.0001 ** t
    base_out = None
    for label, seed in (("single-sided (adopted)", 0), ("seeded 1 ETH", 1), ("seeded 5 ETH", 5)):
        pool = single_sided(t) if seed == 0 else seeded(t, seed)
        opening(pool, 1)
        g = genesis(pool, p0, 20, 1.0, convert_share=0.0)
        if base_out is None:
            base_out = g["farm_eth"]
        lowest = "the start (10 ETH)" if seed == 0 else "none: below the start"
        w(f"| {label} | {seed} ETH | {lowest} | {pool.fdv():.2f} ETH | {max(pool.eth, 0):.2f} ETH | {g['farm_eth']:.2f} ETH | "
          f"{g['farm_eth'] - base_out:.2f} ETH |")
    w("")
    w("Reading: seeding ETH gives farm sellers the owner's ETH as well and removes the price floor; it does not protect")
    w("opening buyers. The single-sided launch needs no ETH and its floor is the start price.\n")

    w("## 5. Recommendation\n")
    w("- **Start at 10 ETH FDV (`START_TICK` 184,200, ≈ 99.8M ENGINE per ETH).** 1 ETH of opening buys moves the price")
    w("  by about a quarter (5 ETH FDV: more than half), and a 5 ETH opening leaves the largest buyer about 14% of")
    w("  supply (5 ETH FDV: 24%). 5 ETH FDV is the alternative if the owner prefers to give opening buyers more upside")
    w("  and the farm less ETH value (0.95 ETH at the start price); it is better for opening buyers in the worst case")
    w("  (section 3) at the price of more concentration. 20 ETH and above are worse for opening buyers in most cases.")
    w("- **The farm can take the opening market's ETH.** The rate cap pays 10% of ticket ETH valued at the start price;")
    w("  ENGINE trades above the start once anyone buys, so the rewards are worth more, and with public buys closed")
    w("  during genesis farm sales meet only the opening market's ETH, conversions and buybacks. In the worst case")
    w("  (no conversions, a thin opening market) opening buyers lose most of what they paid. Options, none applied")
    w("  without the owner's approval: a smaller farm (for example 10% with 9% more to the float); valuing the rate")
    w("  cap at a time-weighted pool price instead of the start price (a contract change); or a lower start FDV.")
    w("- **No seeded ETH.** It does not protect buyers and puts the owner's ETH up as exit liquidity.\n")

    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    out = os.path.join(HERE, "results", "launch.md")
    open(out, "w").write("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
