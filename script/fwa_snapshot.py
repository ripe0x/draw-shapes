#!/usr/bin/env python3
"""Snapshots an FWA V2 custom pool at the fork block and computes the player table under FWA's quote.

usage: fwa_snapshot.py [--pool ADDRESS] [--block N] [--rpc URL] [--out snapshot.json] [--list-pools]

Pool: docs/external/fwa-v2.md names the FWA factory (0xF5A3...300c) and no pool. The default pool is
the largest pool the factory had created at block 26170000, found from the factory's PoolCreated logs
and the pool's `activeListingCount()`: 0x39fde68bfa68a1dda887d34838ef0fc36972fcf8, owned by
0x1FEbbd255a99170DeC9714043A7a46cB5d3670B2, 9,923 active listings of the FWAIR Punks collection
(0x8d6A9c594745dCaa544Cd96B6a91C688eD2c0101), every one at 0.001 ETH. `--list-pools` prints all
pools of the factory with their active listing counts, to pick a pool with mixed prices.

Reads go through `cast call --rpc-url RPC --block BLOCK`. The listing walk batches 250 `listings(id)`
reads per call through Multicall3 (0xcA11bde05977b3631167028862bE2a173976CA11), sent as raw calldata
with `cast call --data`, so the walk takes tens of calls instead of one per listing.

RPC: `--rpc`, else MAINNET_RPC_URL, else the Tenderly public gateway. Block: `--block`, else FORK_BLOCK,
else 26170000.

Model: FWA selects an Active listing with probability weight / totalWeight (weight = 1e36 / price),
so the expected value is the harmonic mean of the prices. The ticket is `quoteAcquisitionPrice()`,
which is the harmonic mean times (1 + edgeBps / 10_000) plus the VRF fee. A player receives the
selected listing and its value is the listing price. Standard library plus `cast`.
"""
import argparse
import json
import math
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402  (shared table format)

FACTORY = "0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c"
DEFAULT_POOL = "0x39fde68bfa68a1dda887d34838ef0fc36972fcf8"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
POOL_CREATED = "0x451303f8c2b76d53ca965213a1f812340d6111dac5c47a4382a40ba861790f68"
FACTORY_FIRST_BLOCK = 26_000_000
CHUNK = 250
ETH = 10**18


def cast(*args, retries=6):
    for attempt in range(retries):
        p = subprocess.run(["cast", *args], capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout.strip()
        if "429" in p.stderr or "rate" in p.stderr.lower():
            time.sleep(2 * (attempt + 1))
            continue
        raise RuntimeError(f"cast {' '.join(args[:3])} failed: {p.stderr.strip()}")
    raise RuntimeError("cast: rate limited after retries")


def call(rpc, block, to, sig, *params):
    out = cast("call", "--rpc-url", rpc, "--block", str(block), to, sig, *params)
    return [line.split(" ")[0] for line in out.splitlines()]


def word(n):
    return f"{n:064x}"


def multicall_listings(rpc, block, pool, first, last):
    """Returns [(id, weight, price, status)] for ids first..last through Multicall3.aggregate3."""
    ids = list(range(first, last + 1))
    n = len(ids)
    element = 6 * 32
    body = [word(32), word(n)]
    body += [word(n * 32 + i * element) for i in range(n)]
    for i in ids:
        body += [word(int(pool, 16)), word(1), word(96), word(36)]
        body += [("de74e57b" + word(i)).ljust(128, "0")]
    data = "0x82ad56cb" + "".join(body)
    out = cast("call", "--rpc-url", rpc, "--block", str(block), MULTICALL3, "--data", data)
    raw = bytes.fromhex(out[2:])
    w = lambda off: int.from_bytes(raw[off:off + 32], "big")
    arr = w(0)  # offset of the array
    count = w(arr)
    assert count == n, (count, n)
    base = arr + 32
    rows = []
    for i in range(count):
        t = base + w(base + 32 * i)
        success = w(t)
        ret = t + w(t + 32)
        length = w(ret)
        if not success or length not in (256, 288):
            raise RuntimeError(f"listings({ids[i]}) failed in multicall")
        d = ret + 32
        # collection, depositor, purchaser, tokenId, weight, price, slot, [one more word on the other
        # implementation 0x6066...], status. Status is always the last word.
        rows.append((ids[i], w(d + 4 * 32), w(d + 5 * 32), w(d + length - 32)))
    return rows


def list_pools(rpc, block):
    out = cast("logs", "--json", "--rpc-url", rpc, "--from-block", str(FACTORY_FIRST_BLOCK), "--to-block",
               str(block), "--address", FACTORY, POOL_CREATED)
    pools = []
    for log in json.loads(out):
        pools.append("0x" + log["topics"][2][-40:])
    return pools


def weighted_percentile(pairs, p):
    """pairs: ascending [(value, probability)]. Smallest value whose cumulative probability reaches p."""
    acc = 0.0
    for v, pr in pairs:
        acc += pr
        if acc >= p - 1e-12:
            return v
    return pairs[-1][0]


def main():
    ap = argparse.ArgumentParser(description="FWA pool snapshot and player table")
    ap.add_argument("--pool", default=DEFAULT_POOL)
    ap.add_argument("--block", type=int, default=int(os.environ.get("FORK_BLOCK", 26_170_000)))
    ap.add_argument("--rpc", default=os.environ.get("MAINNET_RPC_URL", "https://gateway.tenderly.co/public/mainnet"))
    ap.add_argument("--out", default="snapshot.json")
    ap.add_argument("--list-pools", action="store_true")
    a = ap.parse_args()

    if a.list_pools:
        for p in list_pools(a.rpc, a.block):
            active = call(a.rpc, a.block, p, "activeListingCount()(uint256)")[0]
            retired = call(a.rpc, a.block, p, "retired()(bool)")[0]
            print(p, "active", active, "retired", retired)
        return 0

    pool = a.pool
    fee, vrf, total = (int(x) for x in call(a.rpc, a.block, pool, "quoteAcquisitionPrice()(uint256,uint256,uint256)"))
    next_id = int(call(a.rpc, a.block, pool, "nextListingId()(uint256)")[0])
    weighted = int(call(a.rpc, a.block, pool, "weightedBackingTotal()(uint256)")[0])
    total_weight = int(call(a.rpc, a.block, pool, "totalWeight()(uint256)")[0])
    edge = int(call(a.rpc, a.block, FACTORY, "edgeBps()(uint16)")[0])

    listings = []
    for first in range(1, next_id, CHUNK):
        listings += multicall_listings(a.rpc, a.block, pool, first, min(first + CHUNK - 1, next_id - 1))
    active = [(price, weight) for _, weight, price, status in listings if status == 1]
    if sum(w for _, w in active) != total_weight:
        raise RuntimeError("active weights do not sum to totalWeight; the walk is incomplete")

    sum_w = total_weight
    ticket = total
    pairs = sorted((price / ticket, weight / sum_w) for price, weight in active)
    mean = sum(r * pr for r, pr in pairs)
    hist = [0.0] * len(report.EDGES)
    for r, pr in pairs:
        hist[report.bucket_index(r)] += pr
    harmonic = weighted // total_weight if total_weight else 0

    # Odds table by listing price bucket, in multiples of the ticket.
    buckets = []
    labels = report.bucket_labels()
    for i, lab in enumerate(labels):
        members = [(price, weight) for price, weight in active if report.bucket_index(price / ticket) == i]
        buckets.append({
            "bucket": lab,
            "listings": len(members),
            "probability": sum(w for _, w in members) / sum_w,
            "minPriceWei": min((p for p, _ in members), default=0),
            "maxPriceWei": max((p for p, _ in members), default=0),
        })

    snap = {
        "source": "factory PoolCreated logs and activeListingCount at the fork block (docs/external/fwa-v2.md names no pool)",
        "factory": FACTORY,
        "pool": pool,
        "block": a.block,
        "activeListings": len(active),
        "feeWei": fee,
        "vrfWei": vrf,
        "ticketWei": ticket,
        "edgeBps": edge,
        "harmonicMeanWei": harmonic,
        "stats": {
            "mean": mean,
            "median": weighted_percentile(pairs, 0.5),
            "p5": weighted_percentile(pairs, 0.05),
            "p95": weighted_percentile(pairs, 0.95),
            "shareAtOrAbove": sum(pr for r, pr in pairs if r >= 1),
            "shareBelowHalf": sum(pr for r, pr in pairs if r < 0.5),
        },
        "histogram": {"edges": report.EDGES, "share": hist},
        "oddsByPriceBucket": buckets,
    }
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(snap, f, indent=1)

    print(f"FWA pool {pool} at block {a.block}: {len(active)} active listings, ticket {ticket / ETH:.6f} ETH "
          f"(fee {fee / ETH:.6f} + VRF {vrf / ETH:.6f}), harmonic mean {harmonic / ETH:.6f} ETH, edge {edge} bps")
    print()
    print(report.render_table([report.flatten_snapshot(snap)]))
    print()
    print("Odds by listing price bucket (price / ticket)")
    for b in buckets:
        print(f"  {b['bucket']:>16}  listings {b['listings']:>6}  probability {100 * b['probability']:6.2f}%")
    print("wrote", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
