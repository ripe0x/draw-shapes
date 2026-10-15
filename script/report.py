#!/usr/bin/env python3
"""Reads run directories written by test/scenario/PlayMonth.t.sol and prints the player and depositor tables.

usage: report.py RUN_DIR [RUN_DIR ...] [--fwa [REFERENCE_JSON]] [--no-html]
       report.py --visual [MAIN_RUN_DIR [COMPARE_RUN_DIR]]

Each RUN_DIR holds pulls.csv, hourly.csv, claims.csv and run.txt. The tables print one column per run. With
--fwa one reference column "FWA V2 main, expected" is added from REFERENCE_JSON (default
evidence/fwa/reference.json, a static copy of the V2 main pool board at one block: the return distribution is
computed from the full board, and the pull cadence comes from the event log). Neither side includes VRF or gas:
a run's ticket is the FWA acquisition fee with the VRF fee at zero at the fork block, and the V2 ticket is the
acquisition fee. Every row with a value on both sides marks the better side for the player with an asterisk.
After the table, an example pull block splits one ticket on each side. The Shapes split is computed from the
run's pulls.csv totals and the fee split in run.txt: the FWA protocol keeps (paid - base) / 2 with
base = paid / feeOverEv, each ordinary capture owes mintFee x rungs, and the remaining margin divides by
PREMIUM_BPS : MAINTENANCE_BPS : FEED_BPS. Unless --no-html is given, report.html is written into each RUN_DIR.
--visual writes evidence/play/visual-report.html from evidence/play/visual-report.template.html, the main run (default
evidence/play/test_play500PerDay), a second run for the NAV and board lines (default test_play100PerDay), the FWA
reference and evidence/play/visual-static.json (the FWA board and previous-design columns, fixed data).
Standard library only.
"""
import csv
import json
import math
import os
import random
import sys

ETH = 10**18
DEFAULT_REFERENCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "evidence", "fwa", "reference.json")
TRIGGERS = ["Claim", "GrailStep", "Held"]
SETTLE_TRIGGERS = ["Batch", "Age", "Thin", "Deep"]
# pulls.csv "track" values and hourly.csv group suffixes: 0 is the 1 ETH pieces, 1 is the merged items.
GROUPS = (("minor", 0, "1 ETH pieces"), ("major", 1, "merged items"))
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


def read_text(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return f.read().splitlines()


def analyze(run_dir):
    pulls = read_csv(os.path.join(run_dir, "pulls.csv"))
    hourly = read_csv(os.path.join(run_dir, "hourly.csv"))
    claims = read_csv(os.path.join(run_dir, "claims.csv"))
    m = {"name": os.path.basename(os.path.normpath(run_dir)).replace("test_", "")}
    cfg = {}
    for line in read_text(os.path.join(run_dir, "run.txt")):
        k, _, v = line.partition("=")
        cfg[k] = v.strip()
    m["cfg"] = cfg
    m["pulls_rows"] = pulls
    if "pullsPerDay" in cfg:
        m["name"] = f"Shapes run ({cfg['pullsPerDay']}/day)"

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
        m["ge2"] = sum(1 for x in ratios if x >= 2) / len(ratios)
        hist = [0] * len(EDGES)
        for x in ratios:
            hist[bucket_index(x)] += 1
        m["hist"] = [h / len(ratios) for h in hist]
        for kind in RETURN_KINDS:
            m["share_" + kind] = sum(1 for r in counted if r["kind"] == kind) / len(counted)
    m["not_returned"] = len(pulls) - len(counted)

    for track, _, _ in GROUPS:
        hits = [int(r["hour"]) for r in pulls if r["kind"] == "Grail" and r["track"] == track]
        m["grail_" + track] = len(hits)
        m["grail_first_" + track] = min(hits) if hits else None
    m["grail_captures"] = m["grail_minor"] + m["grail_major"]

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
        m["settles"] = sum(int(r["settles"]) for r in body)
        for t in SETTLE_TRIGGERS:
            m["set_" + t] = sum(int(r.get("set" + t, 0)) for r in body)
        m["settle_listed"] = sum(int(r["settleListed"]) for r in body)
        m["settle_refund"] = sum(int(r["settleRefund"]) for r in body) / ETH
        m["inventory_changed"] = sum(int(r["inventoryChanged"]) for r in body)
        m["rejected"] = sum(int(r["rejected"]) for r in body)
        m["wait_per_pull"] = sum(int(r["pullWaitSeconds"]) for r in body) / max(1, sum(int(r["pulls"]) for r in body))
        m["listed_avg"] = sum(int(r["listedCount"]) for r in body) / len(body)
        m["listed_min"] = min(int(r["listedCount"]) for r in body)
        m["listed_start"], m["listed_end"] = int(first["listedCount"]), int(last["listedCount"])
        m["listed_max"] = max(int(r["listedCount"]) for r in hourly)
        if "grailFund" in last:
            m["grail_fund_end"] = int(last["grailFund"]) / ETH
            m["grail_target_end"] = int(last["grailTarget"]) / ETH
            m["grail_fund_max"] = max(int(r["grailFund"]) for r in hourly) / ETH
        m["grail_pieces_end"] = int(last["grailBacking0"]) / ETH
        m["grail_item_end"] = int(last["grailBacking1"]) / ETH
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
    ("pulls at 2x ticket or more", "ge2", _pct),
    ("share Shape", "share_Shape", _pct),
    ("share Pack", "share_Pack", _pct),
    ("share GRAIL", "share_Grail", _pct),
    ("GRAIL captures, 1 ETH pieces", "grail_minor", lambda v: _n(v)),
    ("first 1 ETH piece capture", "grail_first_minor", _first),
    ("GRAIL captures, merged items", "grail_major", lambda v: _n(v)),
    ("first merged item capture", "grail_first_major", _first),
    ("expected captures, 1 ETH pieces (odds x pulls)", "hits_expected_0", lambda v: _n(v, 2)),
    ("avg odds, 1 ETH pieces (bps of weight)", "odds_avg_0", lambda v: _n(v, 2)),
    ("expected captures, merged items (odds x pulls)", "hits_expected_1", lambda v: _n(v, 2)),
    ("avg odds, merged items (bps of weight)", "odds_avg_1", lambda v: _n(v, 2)),
    ("GRAIL fund, end (ETH)", "grail_fund_end", lambda v: _n(v, 3)),
    ("GRAIL fund, peak (ETH)", "grail_fund_max", lambda v: _n(v, 3)),
    ("GRAIL cycle target, end (ETH)", "grail_target_end", lambda v: _n(v, 1)),
    ("1 ETH pieces on the board, end (ETH)", "grail_pieces_end", lambda v: _n(v, 1)),
    ("largest merged item, end (ETH backing)", "grail_item_end", lambda v: _n(v, 1)),
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
    ("listed items, hour 0", "listed_start", lambda v: _n(v)),
    ("listed items, last hour", "listed_end", lambda v: _n(v)),
    ("listed items, peak", "listed_max", lambda v: _n(v)),
    ("listed items, average", "listed_avg", lambda v: _n(v, 1)),
    ("listed items, minimum", "listed_min", lambda v: _n(v)),
    ("purchase pause (min/day)", "pause_min_day", lambda v: _n(v, 1)),
    ("rotate calls", "rotates", lambda v: _n(v)),
    ("rotate calls that changed inventory", "inventory_changed", lambda v: _n(v)),
] + [(f"rotate trigger {t}", "rot_" + t, lambda v: _n(v)) for t in TRIGGERS] + [
    ("settle calls", "settles", lambda v: _n(v)),
    ("items listed by settle", "settle_listed", lambda v: _n(v)),
    ("settle refunds paid (ETH)", "settle_refund", lambda v: _n(v, 4)),
] + [(f"settle trigger {t}", "set_" + t, lambda v: _n(v)) for t in SETTLE_TRIGGERS]


# Rows compared across columns: key -> True when a higher value is better for the player.
BETTER_HIGH = {
    "ticket": False,
    "mean": True,
    "median": True,
    "p5": True,
    "p95": True,
    "ge1": True,
    "lt_half": False,
    "ge2": True,
}


def better_columns(cols, key):
    """Indices of the best column for the player on a row, among columns holding a number. Ties give none."""
    vals = [(i, c[key]) for i, c in enumerate(cols) if isinstance(c.get(key), (int, float))]
    if len(vals) < 2:
        return set()
    best = (max if BETTER_HIGH[key] else min)(v for _, v in vals)
    winners = {i for i, v in vals if v == best}
    return winners if len(winners) == 1 else set()


def render_table(cols):
    names = [c["name"] for c in cols]
    label_w = max(len(r[0]) for r in ROWS)
    col_w = [max(len(n), 12) for n in names]
    marked = False
    lines = ["".ljust(label_w) + "  " + "  ".join(n.rjust(w + 1) for n, w in zip(names, col_w))]
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
        best = better_columns(cols, key) if key in BETTER_HIGH else set()
        marked = marked or bool(best)
        for i, (c, w) in enumerate(zip(cols, col_w)):
            v = c.get(key)
            text = v if isinstance(v, str) else fmt(v) if key in c else "-"
            cells.append((text + ("*" if i in best else " ")).rjust(w + 1))
        lines.append(label.ljust(label_w) + "  " + "  ".join(cells))
    if marked:
        lines += ["", "* better for the player: lower ticket, higher return, higher share at or above ticket and at 2x or more, lower share below half"]
    lines.append("")
    lines.append("Return buckets, share of pulls by value / ticket")
    for i, lab in enumerate(bucket_labels()):
        cells = []
        for c, w in zip(cols, col_w):
            h = c.get("hist")
            cells.append((_pct(h[i]) if h else "-").rjust(w + 1))
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


def write_html(m, fwa, ref=None):
    rows = m["series"]
    xs = [int(r["hour"]) for r in rows]
    charts = [
        line_chart("NAV per share (ETH)", [("NAV per share", [(x, int(r["navPerShare"]) / ETH) for x, r in zip(xs, rows)])]),
        line_chart("Board depth, listed items", [("listed", [(x, int(r["listedCount"])) for x, r in zip(xs, rows)])]),
        line_chart(
            "GRAIL odds (bps of FWA selection weight)",
            [(label, [(x, float(r[f"grailOddsBps{t}"])) for x, r in zip(xs, rows)]) for _, t, label in GROUPS],
        ),
        line_chart("GRAIL fund (ETH)", [("fund", [(x, int(r["grailFund"]) / ETH) for x, r in zip(xs, rows)])]),
        line_chart(
            "GRAIL backing (ETH)",
            [(label, [(x, int(r[f"grailBacking{t}"]) / ETH) for x, r in zip(xs, rows)]) for _, t, label in GROUPS],
        ),
    ]
    hist_series = [(m["name"], m["hist"])] if "hist" in m else []
    hist_series += [(f["name"], f["hist"]) for f in fwa if "hist" in f]
    charts.append(histogram("Player return, share of pulls by value / ticket", hist_series))
    table = render_table([m] + fwa)
    if ref:
        table += "\n\n" + "\n".join(example_pull(m, ref))
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


# ---------------------------------------------------------------------------------------------- visual report

PLAY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "evidence", "play")
SESSIONS = 20_000


def _series(rows, key, scale=1):
    return [int(r[key]) / scale for r in rows]


def session_stats(counted, ticket, spend, rng):
    """Value over spend for SESSIONS sessions of round(spend / ticket) tickets drawn with replacement from the run."""
    k = max(1, round(spend / ticket))
    vals = [(int(r["backingReceived"]), int(r["paid"])) for r in counted]
    out = []
    for _ in range(SESSIONS):
        pick = rng.choices(vals, k=k)
        out.append(sum(v for v, _ in pick) / sum(p for _, p in pick))
    out.sort()
    return {
        "tickets": k,
        "p10": percentile(out, 0.10),
        "median": percentile(out, 0.5),
        "p90": percentile(out, 0.90),
        "mean": sum(out) / len(out),
        "atOrAbove": sum(1 for x in out if x >= 1) / len(out),
        "belowHalf": sum(1 for x in out if x < 0.5) / len(out),
    }


def _changes(hourly, key):
    """Hours at which an hourly column changes, as (hour, ETH) pairs."""
    out, prev = [], None
    for r in hourly:
        v = int(r[key])
        if v != prev:
            out.append((int(r["hour"]), v / ETH))
            prev = v
    return out


def visual_data(main, other, ref, static):
    """Builds the D object and the template tokens from two analyzed runs."""
    rows, rows2 = main["series"], other["series"]
    sp = split_pulls(main, ref)
    n = main["pulls"]
    counted = [r for r in main["pulls_rows"] if r["kind"] in RETURN_KINDS]
    ratios = [int(r["backingReceived"]) / int(r["paid"]) for r in counted]
    per_day = main["cfg"].get("pullsPerDay", "?")
    per_day2 = other["cfg"].get("pullsPerDay", "?")
    ticket = main["ticket"]
    t = sp["ticket"]
    ours = {k: sp[k] / t for k in ("backing", "mint", "protocol", "premium", "maintenance", "feed")}
    ours["prem"], ours["maint"] = ours.pop("premium"), ours.pop("maintenance")
    paid_total = sum(int(r["paid"]) for r in counted) / ETH
    split_eth = {k: sp[k] * len(counted) / ETH for k in sp}
    nav0, nav1 = rows[0], rows[-1]
    fund0 = int(rows[0]["grailFund"]) / ETH
    opening = 50.0  # runner default PLAY_OPENING_ETH
    cohort_shares = opening - fund0
    break_even = opening / cohort_shares
    claims = [{"hour": int(c["hour"]), "wait": int(c["waitSeconds"]), "paid": int(c["paidNow"]) / ETH} for c in read_csv(os.path.join(main["dir"], "claims.csv"))]
    trig = [[f"rotate {t}", main["rot_" + t]] for t in TRIGGERS] + [[f"settle {t}", main["set_" + t]] for t in SETTLE_TRIGGERS]
    rng = random.Random(1)
    res, spends = {}, static["equalSpends"]
    for sp_eth in spends:
        key = f"{sp_eth:g}"  # same text as JavaScript's String(number)
        res[key] = {"ours": session_stats(counted, ticket, sp_eth, rng), "fwa": static["equalFwa"][key]}
    r100 = {"nav": _series(rows2, "navPerShare", ETH), "listed": _series(rows2, "listedCount")}
    nav_a, nav_b = main["nav_start"], main["nav_end"]
    nav2_a, nav2_b = other["nav_start"], other["nav_end"]

    item = _changes(rows, "grailBacking1")
    item = [c for c in item if c[1] > 0]
    list_pct = None
    first_item = next((r for r in rows if int(r["grailBacking1"]) > 0), None)
    if first_item:
        list_pct = round(100 * int(first_item["grailNotional1"]) / int(first_item["grailBacking1"]))
    steps = "; ".join(f"hour {h}: {b:g} ETH" for h, b in item)
    cap = main["grail_captures"]
    grail_text = (
        f"One fund and one ladder. The fund started the week at {fund0:g} ETH from the opening cohort's entry fee, mints 1 ETH pieces, "
        f"and the pieces merge into one item that lists at {list_pct}% of its backing. Backing of the merged item by hour: {steps}. "
        f"Cycle target {main['grail_target_end']:g} ETH. Captures in the week: {cap}. Fund at the end {main['grail_fund_end']:.3f} ETH. "
        "Odds are the listing's share of FWA selection weight at that hour."
        if item
        else f"One fund and one ladder. No merged item was listed. Fund at the end {main['grail_fund_end']:.3f} ETH."
    )
    rot_text = ", ".join(str(main["rot_" + t]) + " " + t for t in TRIGGERS)
    board_text = (
        f"The board is sized from NAV and starts at {main['listed_start']} listed items. It reached {main['listed_end']:,} at the end of the "
        f"week at {per_day} a day and {other['listed_end']:,} at {per_day2} a day. {main['settles']} settle calls listed "
        f"{main['settle_listed']:,} items: {main['set_Batch']} on Batch, {main['set_Age']} on Age, {main['set_Thin']} on Thin and "
        f"{main['set_Deep']} on Deep. {main['rotates']} rotate calls ran ({rot_text}). Settle refunds paid {main['settle_refund']:.4f} ETH. "
        f"The purchase pause averaged {main['pause_min_day']:.1f} minutes a day (the factory cooldown is {main['cfg'].get('cooldown', '0')} at the fork block)."
    )
    flag = (
        f"NAV per share moved from {nav_a:.4f} to {nav_b:.4f} at {per_day} a day ({100 * (nav_b / nav_a - 1):+.1f} percent) and from "
        f"{nav2_a:.4f} to {nav2_b:.4f} at {per_day2} a day ({100 * (nav2_b / nav2_a - 1):+.1f} percent). "
        f"The board grows from {main['listed_start']} to {main['listed_end']:,} listed items, and {main['set_Deep']} of {main['settles']} settle calls ran on Deep."
    )
    exits_note = (
        "All paid from cash with no wait." if claims and all(c["wait"] == 0 for c in claims)
        else f"{sum(1 for c in claims if c['wait'] > 0)} of {len(claims)} waited in the queue."
    )
    depositors = (
        f"Depositors are the house. The opening cohort paid {opening:g} ETH and the entry fee put {fund0:g} ETH of it into the GRAIL fund, "
        f"which leaves {cohort_shares:g} shares. After the first board's mint fees NAV per share started at {nav_a:.4f} and a share breaks even "
        f"for the cohort at {break_even:.3f}. The week ended at {nav_b:.4f} ({100 * (nav_b / nav_a - 1):+.1f} percent). "
        "FWA's V2 main pool has no depositor side: FWA supplies the inventory and keeps the 5 percent surcharge plus the 10 percent settlement discount."
    )
    d = {
        "ours": ours,
        "fwa": {"owner": ref["v2"]["evWei"] / ref["v2"]["ticketWei"], "protocol": 1 - ref["v2"]["evWei"] / ref["v2"]["ticketWei"]},
        "r": {
            "n": n, "P": paid_total, "B": split_eth["backing"], "ticket": ticket, "ev": main["mean"], "median": main["median"],
            "p5": main["p5"], "p95": main["p95"], "atOrAbove": main["ge1"], "belowHalf": main["lt_half"], "two": main["ge2"],
            "ten": sum(1 for x in ratios if x >= 10) / len(ratios), "hist": main["hist"],
            "nav": _series(rows, "navPerShare", ETH), "listed": _series(rows, "listedCount"), "pph": _series(rows, "pulls"),
            "odds0": [float(r["grailOddsBps0"]) for r in rows], "odds1": [float(r["grailOddsBps1"]) for r in rows],
            "gb0": _series(rows, "grailBacking0", ETH), "gb1": _series(rows, "grailBacking1", ETH),
            "fund": _series(rows, "grailFund", ETH), "claims": claims, "trig": trig,
            "protocol": split_eth["protocol"], "mintline": split_eth["mint"], "prem": split_eth["premium"],
            "maint": split_eth["maintenance"], "feed": split_eth["feed"],
        },
        "r100": r100,
        "rText": {"paid": f"{paid_total:.2f} ETH over the week"},
        "v2": static["v2"],
        "prev": static["prev"],
        "breakEven": break_even,
        "equal": {"spends": spends, "res": res, "prev": static["equalPrev"], "ourTicket": ticket, "fwaTicket": static["v2"]["ticket"]},
    }
    mint_total = split_eth["mint"]
    d["tiles"] = [
        ["tickets", f"{n:,}", f"{main['hours'] // 24} days, {per_day} a day"],
        ["ticket", f"{ticket:.4f} ETH", "FWA acquisition fee, VRF excluded"],
        ["median return", f"{main['median']:.2f}×", f"FWA V2 {static['v2']['median']:.2f}×"],
        ["expected return", f"{main['mean']:.2f}×", f"FWA V2 {static['v2']['ev']:.2f}×"],
        ["NAV per share", f"{nav_a:.4f} → {nav_b:.4f}", f"{100 * (nav_b / nav_a - 1):+.1f}% in a week, break-even {break_even:.2f}"],
        ["board listed", f"{main['listed_start']:,} → {main['listed_end']:,}", f"peak {main['listed_max']:,}"],
        ["GRAIL fund", f"{main['grail_fund_end']:.2f} ETH", f"target {main['grail_target_end']:g} ETH, peak {main['grail_fund_max']:.1f}"],
        ["GRAIL item", f"{main['grail_item_end']:g} ETH", f"{cap} captures in the week"],
        ["settles", f"{main['settles']}", f"Batch {main['set_Batch']}, Age {main['set_Age']}, Thin {main['set_Thin']}, Deep {main['set_Deep']}"],
        ["mint fees", f"{mint_total:.2f} ETH", "estimated from captures"],
    ]
    tokens = {
        "forkBlock": f"{int(main['cfg'].get('forkBlock', 0)):,}", "perDay": per_day, "perDay100": per_day2, "n": f"{n:,}",
        "flag": flag, "depositors": depositors, "breakEven": f"{break_even:.2f}", "entryFee": f"{fund0:g}",
        "cohortShares": f"{cohort_shares:g}", "exitsNote": exits_note, "boardText": board_text, "grailText": grail_text,
        "target": f"{main['grail_target_end']:g}",
    }
    return d, tokens


def build_visual(args):
    main_dir = args[0] if args else os.path.join(PLAY_DIR, "test_play500PerDay")
    other_dir = args[1] if len(args) > 1 else os.path.join(PLAY_DIR, "test_play100PerDay")
    main, other = analyze(main_dir), analyze(other_dir)
    main["dir"], other["dir"] = main_dir, other_dir
    with open(DEFAULT_REFERENCE) as f:
        ref = json.load(f)
    with open(os.path.join(PLAY_DIR, "visual-static.json")) as f:
        static = json.load(f)
    with open(os.path.join(PLAY_DIR, "visual-report.template.html")) as f:
        page = f.read()
    d, tokens = visual_data(main, other, ref, static)
    for k, v in tokens.items():
        page = page.replace("{{" + k + "}}", str(v))
    page = page.replace("__DATA__", json.dumps(d, separators=(",", ":"), allow_nan=False))
    path = os.path.join(PLAY_DIR, "visual-report.html")
    with open(path, "w") as f:
        f.write(page)
    print("wrote", os.path.normpath(path))
    return 0


# ---------------------------------------------------------------------------------------------- main


def main(argv):
    dirs, fwa_path, html = [], None, True
    args = list(argv)
    if args and args[0] == "--visual":
        return build_visual(args[1:])
    while args:
        a = args.pop(0)
        if a == "--fwa":
            fwa_path = args.pop(0) if args and args[0].endswith(".json") else DEFAULT_REFERENCE
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
    fwa, ref = [], None
    if fwa_path:
        with open(fwa_path) as f:
            ref = json.load(f)
        fwa = reference_columns(ref)
        print(reference_header(ref))
    print(render_table(runs + fwa))
    if ref:
        for m in runs:
            print()
            print("\n".join(example_pull(m, ref)))
    if html:
        for m in runs:
            print("wrote", write_html(m, fwa, ref))
    return 0


def reference_header(ref):
    v2 = ref["v2"]
    wk = v2["cadence"]["weeks"]
    cad = ", ".join(f"{w['pullsPerDay']:,} pulls/day ({w['ticketEthPerDay']:,.0f} ETH/day) in the week to {w['endsOn']}" for w in wk)
    return (
        f"FWA V2 main, expected: pool {v2['pool'][:10]}, block {v2['block']:,} ({v2['timestamp'][:10]}), "
        f"{v2['listings']:,} listings, ticket {v2['ticketWei'] / ETH:.6f} ETH (acquisition fee, VRF excluded), "
        f"{v2['ethSettlementDiscountBps'] / 100:g}% settlement discount, return distribution exact from the board. "
        f"Cadence: {cad}. "
        "Shapes run ticket: FWA acquisition fee, VRF fee zero at the fork block. "
        f"Excluded: {ref['exclusions']}."
    )


def reference_columns(ref):
    """Maps reference.json onto the metric keys of analyze(): the V2 board column."""
    v2 = ref["v2"]
    s = v2["stats"]
    return [
        {
            "name": "FWA V2 main, expected",
            "ticket": v2["ticketWei"] / ETH,
            "mean": s["mean"],
            "median": s["median"],
            "p5": s["p5"],
            "p95": s["p95"],
            "ge1": s["shareAtOrAbove"],
            "lt_half": s["shareBelowHalf"],
            "ge2": s["share2xPlus"],
            "hist": v2["histogram"]["share"],
            "listed_avg": f"{v2['listings']:,}",
        },
    ]


def split_pulls(m, ref):
    """Per-ticket ETH split of a run, from pulls.csv and the fee split in run.txt. None when run.txt lacks it."""
    cfg, sh = m["cfg"], ref["shapes"]
    try:
        bps = [int(cfg[k]) for k in ("PREMIUM_BPS", "MAINTENANCE_BPS", "FEED_BPS")]
    except KeyError:
        return None
    rungs = {}
    for row in cfg.get("MIX_ROWS", "").split(";"):
        idx = row.split(":")[0].split(",")
        if idx != [""]:
            rungs[sum(sh["denominationsWei"][int(i)] for i in idx)] = len(idx)
    counted = [r for r in m["pulls_rows"] if r["kind"] in RETURN_KINDS]
    paid = sum(int(r["paid"]) for r in counted)
    ordinary = [r for r in counted if r["kind"] != "Grail"]
    grail = [r for r in counted if r["kind"] == "Grail"]
    k = 1 - 1 / ref["v2"]["feeOverEv"]
    protocol = paid * k / 2
    mint = sum(sh["mintFeeWei"] * rungs.get(int(r["backingReceived"]), 1) for r in ordinary)
    backing = sum(int(r["backingReceived"]) for r in ordinary)
    margin = sum(int(r["paid"]) for r in ordinary) * (1 - k / 2) - backing - mint
    grail_proceeds = sum(int(r["paid"]) for r in grail) * (1 - k / 2)
    n = len(counted)
    out = {
        "ticket": paid / n,
        "backing": backing / n,
        "mint": mint / n,
        "protocol": protocol / n,
        "premium": margin * bps[0] / sum(bps) / n,
        "maintenance": margin * bps[1] / sum(bps) / n,
        "feed": (margin * bps[2] / sum(bps) + grail_proceeds) / n,
        "grail_prizes": sum(int(r["backingReceived"]) for r in grail) / n,
    }
    return out


def example_pull(m, ref):
    """Text block: one ticket on each side, ETH and share of the ticket."""
    v2 = ref["v2"]
    lines = ["Example pull, one ticket (ETH, share of ticket)"]
    sp = split_pulls(m, ref)
    if sp:
        t = sp["ticket"]
        lines += [f"{m['name']}: ticket {t / ETH:.6f}"]
        for label, key in (
            ("backing to players (ordinary items, redeemable at face)", "backing"),
            ("Shapes mint fees (replacement mints)", "mint"),
            ("FWA protocol", "protocol"),
            ("depositor premium", "premium"),
            ("maintenance", "maintenance"),
            ("GRAIL feed", "feed"),
        ):
            lines.append(f"  {label:<56}{sp[key] / ETH:>10.6f}{100 * sp[key] / t:>8.1f}%")
        lines.append(f"  {'total':<56}{sum(sp[k] for k in ('backing', 'mint', 'protocol', 'premium', 'maintenance', 'feed')) / ETH:>10.6f}{100.0:>8.1f}%")
        lines.append(
            f"  GRAIL prizes paid out of the feed buckets, per pull: {sp['grail_prizes'] / ETH:.6f} ETH "
            f"({100 * sp['grail_prizes'] / t:.1f}% of ticket, in expected return {m['mean']:.3f}x)"
        )
    ticket, ev = v2["ticketWei"], v2["evWei"]
    cash = ev * v2["ethSettlementDiscountBps"] / 10_000
    lines += [
        f"FWA V2 main, block {v2['block']:,}: ticket {ticket / ETH:.6f}",
        f"  {'expected cashout (' + format(v2['ethSettlementDiscountBps'] / 100, 'g') + '% of expected backing ' + format(ev / ETH, '.6f') + ')':<56}"
        f"{cash / ETH:>10.6f}{100 * cash / ticket:>8.1f}%",
        f"  {'surcharge (ticket over expected backing)':<56}{(ticket - ev) / ETH:>10.6f}{100 * (ticket - ev) / ticket:>8.1f}%",
        f"  {'settlement discount (backing not cashed out)':<56}{(ev - cash) / ETH:>10.6f}{100 * (ev - cash) / ticket:>8.1f}%",
        f"  {'total':<56}{ticket / ETH:>10.6f}{100.0:>8.1f}%",
    ]
    return lines


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
