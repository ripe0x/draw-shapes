#!/usr/bin/env python3
"""Reads run directories written by test/scenario/PlayMonth.t.sol and prints the player and depositor tables.

usage: report.py RUN_DIR [RUN_DIR ...] [--fwa [SNAPSHOT_JSON]] [--pool ADDRESS] [--no-html]

Each RUN_DIR holds pulls.csv, hourly.csv and claims.csv. The tables print one column per run, plus an
FWA column when --fwa is given. SNAPSHOT_JSON is written by script/fwa_snapshot.py and defaults to
evidence/play/fwa_snapshot.json. The file holds several pools; the FWA column shows its `default` pool
(the mixed-price pool) unless --pool names another. The header line lists every pool's ticket and
listing count. Unless --no-html is given, report.html is written into each RUN_DIR. Standard library only.
"""
import csv
import json
import math
import os
import sys

ETH = 10**18
DEFAULT_SNAPSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "evidence", "play", "fwa_snapshot.json")
TRIGGERS = ["Weight", "GrailCap", "Claim", "GrailStep", "Restock", "Quiet"]
# Edges of the return buckets, as multiples of the ticket. The last bucket is open ended.
EDGES = [0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2, 3, 5, 10]
RETURN_KINDS = ("Shape", "Pack", "Grail")


def bucket_labels(edges=EDGES):
    out = []
    for i, lo in enumerate(edges):
        out.append(f"{lo:g}x to {edges[i + 1]:g}x" if i + 1 < len(edges) else f"{lo:g}x and above")
    return out


def bucket_index(ratio, edges=EDGES):
    for i in range(len(edges) - 1, -1, -1):
        if ratio >= edges[i]:
            return i
    return 0


def percentile(sorted_vals, p):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_vals:
        return None
    return sorted_vals[max(0, math.ceil(p * len(sorted_vals)) - 1)]


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def analyze(run_dir):
    pulls = read_csv(os.path.join(run_dir, "pulls.csv"))
    hourly = read_csv(os.path.join(run_dir, "hourly.csv"))
    claims = read_csv(os.path.join(run_dir, "claims.csv"))
    m = {"name": os.path.basename(os.path.normpath(run_dir)).replace("test_", "")}

    counted = [r for r in pulls if r["kind"] in RETURN_KINDS]
    ratios = sorted(int(r["backingReceived"]) / int(r["paid"]) for r in counted)
    m["pulls"] = len(pulls)
    m["counted"] = len(counted)
    if counted:
        m["ticket"] = sum(int(r["paid"]) for r in counted) / len(counted) / ETH
        m["mean"] = sum(ratios) / len(ratios)
        m["median"] = percentile(ratios, 0.5)
        m["p5"] = percentile(ratios, 0.05)
        m["p95"] = percentile(ratios, 0.95)
        m["ge1"] = sum(1 for x in ratios if x >= 1) / len(ratios)
        m["lt_half"] = sum(1 for x in ratios if x < 0.5) / len(ratios)
        hist = [0] * len(EDGES)
        for x in ratios:
            hist[bucket_index(x)] += 1
        m["hist"] = [h / len(ratios) for h in hist]
        for kind in RETURN_KINDS:
            m["share_" + kind] = sum(1 for r in counted if r["kind"] == kind) / len(counted)
    m["not_returned"] = len(pulls) - len(counted)

    for track in ("minor", "major"):
        hits = [int(r["hour"]) for r in pulls if r["kind"] == "Grail" and r["track"] == track]
        m["grail_" + track] = len(hits)
        m["grail_first_" + track] = min(hits) if hits else None

    if hourly:
        first, last = hourly[0], hourly[-1]
        hours = int(last["hour"]) - int(first["hour"])
        a, b = int(first["navPerShare"]) / ETH, int(last["navPerShare"]) / ETH
        m["nav_start"], m["nav_end"], m["hours"] = a, b, hours
        m["nav_rate"] = (b / a) ** (8760 / hours) - 1 if hours and a > 0 and b > 0 else None
        body = hourly[1:] or hourly
        days = max(hours, 1) / 24
        m["pause_min_day"] = sum(int(r["pauseSecondsAccrued"]) for r in body) / 60 / days
        m["rotates"] = sum(int(r["rotates"]) for r in body)
        for t in TRIGGERS:
            m["rot_" + t] = sum(int(r["rot" + t]) for r in body)
        m["inventory_changed"] = sum(int(r["inventoryChanged"]) for r in body)
        m["rejected"] = sum(int(r["rejected"]) for r in body)
        m["wait_per_pull"] = sum(int(r["pullWaitSeconds"]) for r in body) / max(1, sum(int(r["pulls"]) for r in body))
        m["listed_avg"] = sum(int(r["listedCount"]) for r in body) / len(body)
        m["listed_min"] = min(int(r["listedCount"]) for r in body)
        for t in (0, 1):
            m[f"odds_avg_{t}"] = sum(float(r[f"grailOddsBps{t}"]) for r in body) / len(body)
            # Hourly end-of-hour odds times that hour's pulls: a check of hits against odds.
            m[f"hits_expected_{t}"] = sum(int(r["pulls"]) * float(r[f"grailOddsBps{t}"]) / 10_000 for r in body)

    waits = [int(r["waitSeconds"]) / 3600 for r in claims]
    m["exits"] = len(claims)
    m["exits_open"] = sum(1 for r in claims if r["open"] == "1")
    m["exit_avg_h"] = sum(waits) / len(waits) if waits else None
    m["exit_max_h"] = max(waits) if waits else None
    m["series"] = hourly
    return m


# ---------------------------------------------------------------------------------------------- tables


def _pct(x):
    return "-" if x is None else f"{100 * x:.1f}%"


def _x(x):
    return "-" if x is None else f"{x:.3f}x"


def _n(x, d=0):
    return "-" if x is None else f"{x:,.{d}f}"


def _first(x):
    return "none" if x is None else f"hour {x}"


ROWS = [
    ("Player", None, None),
    ("pulls booked", "pulls", lambda v: _n(v)),
    ("pulls without a returned item", "not_returned", lambda v: _n(v)),
    ("ticket paid (ETH)", "ticket", lambda v: _n(v, 5)),
    ("expected return / ticket", "mean", _x),
    ("median return / ticket", "median", _x),
    ("p5 return / ticket", "p5", _x),
    ("p95 return / ticket", "p95", _x),
    ("pulls at or above ticket", "ge1", _pct),
    ("pulls below half ticket", "lt_half", _pct),
    ("share Shape", "share_Shape", _pct),
    ("share Pack", "share_Pack", _pct),
    ("share GRAIL", "share_Grail", _pct),
    ("GRAIL hits minor", "grail_minor", lambda v: _n(v)),
    ("first minor hit", "grail_first_minor", _first),
    ("GRAIL hits major", "grail_major", lambda v: _n(v)),
    ("first major hit", "grail_first_major", _first),
    ("expected hits minor (odds x pulls)", "hits_expected_0", lambda v: _n(v, 2)),
    ("avg odds minor (bps of weight)", "odds_avg_0", lambda v: _n(v, 2)),
    ("expected hits major (odds x pulls)", "hits_expected_1", lambda v: _n(v, 2)),
    ("avg odds major (bps of weight)", "odds_avg_1", lambda v: _n(v, 2)),
    ("rejected pulls", "rejected", lambda v: _n(v)),
    ("avg wait for the pause (s/pull)", "wait_per_pull", lambda v: _n(v, 1)),
    ("Depositor", None, None),
    ("hours simulated", "hours", lambda v: _n(v)),
    ("NAV per share, start", "nav_start", lambda v: _n(v, 4)),
    ("NAV per share, end", "nav_end", lambda v: _n(v, 4)),
    ("annualised NAV rate", "nav_rate", _pct),
    ("withdrawals", "exits", lambda v: _n(v)),
    ("withdrawals still queued at end", "exits_open", lambda v: _n(v)),
    ("exit wait, average (h)", "exit_avg_h", lambda v: _n(v, 2)),
    ("exit wait, max (h)", "exit_max_h", lambda v: _n(v, 2)),
    ("Board", None, None),
    ("listed items, average", "listed_avg", lambda v: _n(v, 1)),
    ("listed items, minimum", "listed_min", lambda v: _n(v)),
    ("purchase pause (min/day)", "pause_min_day", lambda v: _n(v, 1)),
    ("rotate calls", "rotates", lambda v: _n(v)),
    ("rotate calls that changed inventory", "inventory_changed", lambda v: _n(v)),
] + [(f"rotate trigger {t}", "rot_" + t, lambda v: _n(v)) for t in TRIGGERS]


def render_table(cols):
    names = [c["name"] for c in cols]
    label_w = max(len(r[0]) for r in ROWS)
    col_w = [max(len(n), 12) for n in names]
    lines = ["".ljust(label_w) + "  " + "  ".join(n.rjust(w) for n, w in zip(names, col_w))]
    header = None
    for label, key, fmt in ROWS:
        if key is None:
            header = label
            continue
        if not any(key in c for c in cols):
            continue
        if header:
            lines += ["", header]
            header = None
        cells = []
        for c, w in zip(cols, col_w):
            v = c.get(key)
            cells.append((fmt(v) if key in c else "-").rjust(w))
        lines.append(label.ljust(label_w) + "  " + "  ".join(cells))
    lines.append("")
    lines.append("Return buckets, share of pulls by value / ticket")
    for i, lab in enumerate(bucket_labels()):
        cells = []
        for c, w in zip(cols, col_w):
            h = c.get("hist")
            cells.append((_pct(h[i]) if h else "-").rjust(w))
        lines.append(lab.ljust(label_w) + "  " + "  ".join(cells))
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------- html

COLORS = ["#2563eb", "#dc2626", "#059669", "#d97706", "#7c3aed"]


def line_chart(title, series, w=640, h=240, unit=""):
    """series: list of (name, [(x, y), ...]). Returns an inline SVG string."""
    pts = [p for _, s in series for p in s]
    if not pts:
        return f"<p>{title}: no data</p>"
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
    if y1 == y0:
        y0, y1 = y0 - 1, y1 + 1
    if x1 == x0:
        x1 = x0 + 1
    L, R, T, B = 60, 12, 24, 28
    sx = lambda x: L + (x - x0) / (x1 - x0) * (w - L - R)
    sy = lambda y: T + (1 - (y - y0) / (y1 - y0)) * (h - T - B)
    out = [f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-label="{title}">']
    out.append(f'<text x="{L}" y="14" font-size="12" font-weight="bold">{title}</text>')
    for i in range(5):
        y = y0 + (y1 - y0) * i / 4
        out.append(f'<line x1="{L}" x2="{w - R}" y1="{sy(y):.1f}" y2="{sy(y):.1f}" stroke="#ddd"/>')
        out.append(f'<text x="{L - 4}" y="{sy(y) + 4:.1f}" font-size="10" text-anchor="end">{y:.4g}{unit}</text>')
    for i in range(5):
        x = x0 + (x1 - x0) * i / 4
        out.append(f'<text x="{sx(x):.1f}" y="{h - 10}" font-size="10" text-anchor="middle">{x:.0f}h</text>')
    for i, (name, s) in enumerate(series):
        d = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in s)
        color = COLORS[i % len(COLORS)]
        out.append(f'<polyline fill="none" stroke="{color}" stroke-width="1.5" points="{d}"/>')
        out.append(f'<text x="{w - R - 4}" y="{T + 12 * (i + 1)}" font-size="10" fill="{color}" text-anchor="end">{name}</text>')
    out.append("</svg>")
    return "".join(out)


def histogram(title, series, w=640, h=240):
    """series: list of (name, [share per bucket])."""
    labels = bucket_labels()
    n = len(labels)
    L, R, T, B = 60, 12, 24, 52
    top = max([max(s) for _, s in series if s] + [0.01])
    bw = (w - L - R) / n
    k = len(series)
    out = [f'<svg viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-label="{title}">']
    out.append(f'<text x="{L}" y="14" font-size="12" font-weight="bold">{title}</text>')
    for i in range(5):
        y = top * i / 4
        py = T + (1 - y / top) * (h - T - B)
        out.append(f'<line x1="{L}" x2="{w - R}" y1="{py:.1f}" y2="{py:.1f}" stroke="#ddd"/>')
        out.append(f'<text x="{L - 4}" y="{py + 4:.1f}" font-size="10" text-anchor="end">{100 * y:.0f}%</text>')
    for j, (name, s) in enumerate(series):
        color = COLORS[j % len(COLORS)]
        for i, v in enumerate(s):
            bh = v / top * (h - T - B)
            x = L + i * bw + j * bw / k
            out.append(f'<rect x="{x:.1f}" y="{h - B - bh:.1f}" width="{bw / k - 1:.1f}" height="{bh:.1f}" fill="{color}"/>')
        out.append(f'<text x="{w - R - 4}" y="{T + 12 * (j + 1)}" font-size="10" fill="{color}" text-anchor="end">{name}</text>')
    for i, lab in enumerate(labels):
        out.append(
            f'<text x="{L + (i + 0.5) * bw:.1f}" y="{h - B + 12}" font-size="9" text-anchor="end" '
            f'transform="rotate(-35 {L + (i + 0.5) * bw:.1f} {h - B + 12})">{lab}</text>'
        )
    out.append("</svg>")
    return "".join(out)


def write_html(m, fwa):
    rows = m["series"]
    xs = [int(r["hour"]) for r in rows]
    charts = [
        line_chart("NAV per share (ETH)", [("NAV per share", [(x, int(r["navPerShare"]) / ETH) for x, r in zip(xs, rows)])]),
        line_chart("Listed items", [("listed", [(x, int(r["listedCount"])) for x, r in zip(xs, rows)])]),
        line_chart(
            "GRAIL odds (bps of FWA selection weight)",
            [(f"track {t}", [(x, float(r[f"grailOddsBps{t}"])) for x, r in zip(xs, rows)]) for t in (0, 1)],
        ),
    ]
    hist_series = [(m["name"], m["hist"])] if "hist" in m else []
    if fwa and "hist" in fwa:
        hist_series.append(("FWA " + fwa["name"], fwa["hist"]))
    charts.append(histogram("Player return, share of pulls by value / ticket", hist_series))
    table = render_table([m] + ([fwa] if fwa else []))
    html = (
        "<!doctype html><meta charset=utf-8><title>Play report</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:16px auto;max-width:700px;padding:0 16px}"
        "pre{font-size:12px;overflow-x:auto}svg{max-width:100%;height:auto;display:block;margin:12px 0}</style>"
        f"<h1>{m['name']}</h1>" + "".join(charts) + f"<pre>{table}</pre>"
    )
    path = os.path.join(m["dir"], "report.html")
    with open(path, "w") as f:
        f.write(html)
    return path


# ---------------------------------------------------------------------------------------------- main


def main(argv):
    dirs, fwa_path, pool, html = [], None, None, True
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--fwa":
            fwa_path = args.pop(0) if args and args[0].endswith(".json") else DEFAULT_SNAPSHOT
        elif a == "--pool":
            pool = args.pop(0)
        elif a == "--no-html":
            html = False
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            dirs.append(a)
    if not dirs:
        print(__doc__)
        return 2
    runs = []
    for d in dirs:
        m = analyze(d)
        m["dir"] = d
        runs.append(m)
    fwa = None
    if fwa_path:
        with open(fwa_path) as f:
            snap, header = select_snapshot(json.load(f), pool)
        fwa = flatten_snapshot(snap)
        print(header)
    print(render_table(runs + ([fwa] if fwa else [])))
    if html:
        for m in runs:
            print("wrote", write_html(m, fwa))
    return 0


def snapshot_pools(doc):
    """Returns (default address, {address: pool snapshot}) for the multi-pool shape or the old single-pool shape."""
    if "pools" in doc:
        return doc["default"], doc["pools"]
    return doc["pool"], {doc["pool"]: doc}


def select_snapshot(doc, pool=None):
    """Returns (snapshot of `pool` or the default pool, header line listing every pool's ticket and listings)."""
    default, pools = snapshot_pools(doc)
    want = (pool or default).lower()
    byaddr = {a.lower(): v for a, v in pools.items()}
    if want not in byaddr:
        raise SystemExit(f"pool {want} is not in the snapshot; pools: {', '.join(pools)}")
    parts = []
    for a, v in sorted(pools.items(), key=lambda kv: kv[0].lower() != want):
        tag = " (shown)" if a.lower() == want else ""
        parts.append(f"{a[:10]}{tag} ticket {v['ticketWei'] / ETH:.6f} ETH, {v['activeListings']} listings")
    block = next(iter(pools.values()))["block"]
    return byaddr[want], f"FWA pools at block {block}: " + "; ".join(parts)


def flatten_snapshot(snap):
    """Maps snapshot.json onto the metric keys of analyze()."""
    s = snap["stats"]
    return {
        "name": "FWA " + snap["pool"][:8],
        "pulls": None,
        "ticket": snap["ticketWei"] / ETH,
        "mean": s["mean"],
        "median": s["median"],
        "p5": s["p5"],
        "p95": s["p95"],
        "ge1": s["shareAtOrAbove"],
        "lt_half": s["shareBelowHalf"],
        "hist": snap["histogram"]["share"],
    }


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
