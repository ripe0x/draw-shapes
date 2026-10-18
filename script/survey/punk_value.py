#!/usr/bin/env python3
"""Punk value from native CryptoPunksMarket asks and bids.

Usage: python3 script/survey/punk_value.py [market.csv] [wrapped.csv]
Rules evaluated against every asked punk:
  A: value = floor(type)
  B: value = floor(type) * product(min(multiplier(accessory), CAP)) over accessories with >= MIN_ASKS asks
  C: value = floor(type) * k, k = median over all asks of ask / type floor
  D: value = floor(type) * k * product(min(multiplier(accessory) / k, CAP)); multipliers divided by k so the markup is counted once
Each rule is evaluated on all asks and on asks <= TRIM x type floor (the fit uses the same subset).
Reported twice: fitted on all asks (in-sample) and with the punk's own ask left out of the fit (leave-one-out).
"""
import csv
import statistics as st
import sys
from collections import defaultdict

MIN_ASKS = 5
CAP = 5.0
TRIM = 20.0
W = 1e18
market_path = sys.argv[1] if len(sys.argv) > 1 else "evidence/punks/market-26170000.csv"
wrapped_path = sys.argv[2] if len(sys.argv) > 2 else "evidence/punks/wrapped-26170000.csv"


def load(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))]


def fit(asks):
    """asks: list of (type, accessories, ask_eth). Returns (floor per type, multiplier per accessory)."""
    floors = {}
    for t, _, a in asks:
        floors[t] = min(a, floors.get(t, a))
    ratios = defaultdict(list)
    for t, accs, a in asks:
        for x in accs:
            ratios[x].append(a / floors[t])
    k = st.median(a / floors[t] for t, _, a in asks)
    return floors, {x: st.median(r) for x, r in ratios.items() if len(r) >= MIN_ASKS}, k


def rule_b(floors, mults, t, accs, k=1.0):
    v = floors[t] * k
    for x in accs:
        v *= min(mults.get(x, k) / k, CAP) if k != 1.0 else min(mults.get(x, 1.0), CAP)
    return v


def errors(asks, loo):
    out = [[], [], [], []]
    base = fit(asks)
    for i, (t, accs, a) in enumerate(asks):
        floors, mults, k = fit(asks[:i] + asks[i + 1:]) if loo else base
        if t not in floors:
            continue
        for e, v in zip(out, (floors[t], rule_b(floors, mults, t, accs), floors[t] * k, rule_b(floors, mults, t, accs, k))):
            e.append(abs(v / a - 1))
    return out


rows = load(market_path)
asks = []
for r in rows:
    if int(r["askWei"]) > 0:
        asks.append((r["type"], [x for x in r["accessories"].split("|") if x], int(r["askWei"]) / W))
floors, mults, k_all = fit(asks)

print(f"asks: {len(asks)}  bids: {sum(1 for r in rows if int(r['bidWei']) > 0)}  wrapped-held rows: {sum(1 for r in rows if r['ownerIsWrapper'] == '1')}")

print("\n## Asks by type (ETH)\ntype | count | floor ask | median ask")
by = defaultdict(list)
for t, _, a in asks:
    by[t].append(a)
for t in sorted(by):
    print(f"{t} | {len(by[t])} | {min(by[t]):.3f} | {st.median(by[t]):.3f}")

print("\n## Bids by type (ETH)\ntype | count | max bid | median bid")
bb = defaultdict(list)
for r in rows:
    if int(r["bidWei"]) > 0:
        bb[r["type"]].append(int(r["bidWei"]) / W)
for t in sorted(bb):
    print(f"{t} | {len(bb[t])} | {max(bb[t]):.3f} | {st.median(bb[t]):.3f}")

print(f"\n## Accessory multipliers (median of ask / type floor, >= {MIN_ASKS} asks)\naccessory | asks | multiplier")
cnt = defaultdict(int)
for _, accs, _ in asks:
    for x in accs:
        cnt[x] += 1
for x, m in sorted(mults.items(), key=lambda kv: -kv[1]):
    print(f"{x} | {cnt[x]} | {m:.2f}")

print(f"\nmarkup k (median ask / type floor): {k_all:.2f}")
print("\n## Rule error |rule / ask - 1|\nrule | asks | fit | n | median | p90")
names = ["A floor(type)", f"B floor x multipliers (cap {CAP:g})", "C floor x k", "D floor x k x (multiplier / k)"]
for label, subset in (("all", asks), (f"<= {TRIM:g}x floor", [x for x in asks if x[2] <= TRIM * floors[x[0]]])):
    for loo in (False, True):
        for name, e in zip(names, errors(subset, loo)):
            print(f"{name} | {label} | {'leave-one-out' if loo else 'in-sample'} | {len(e)} | {st.median(e):.1%} | {pct(e, .9):.1%}")

print("\n## Wrapped punks")
try:
    wrapped = load(wrapped_path)
    print(f"wrapped punks: {len(wrapped)}")
    wb = [r for r in rows if r["ownerIsWrapper"] == "1" and int(r["bidWei"]) > 0]
    print(f"wrapped with a standing native bid: {len(wb)}")
    over = [int(r["bidWei"]) / W / floors[r["type"]] for r in wb if r["type"] in floors]
    if over:
        print(f"median bid / type floor ask: {st.median(over):.2f}  (n={len(over)})")
    for r in sorted(wb, key=lambda r: -int(r["bidWei"]))[:10]:
        print(f"  #{r['index']} {r['type']} bid {int(r['bidWei']) / W:.3f} ETH")
except FileNotFoundError:
    print("wrapped csv missing")

print("\n## Largest asks (check for placeholders)")
for t, accs, a in sorted(asks, key=lambda x: -x[2])[:8]:
    print(f"  {t} {a:.2f} ETH ({floors[t]:.2f} floor)")
