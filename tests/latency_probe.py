#!/usr/bin/env python3
"""
How long does one tile take, browser -> Nginx -> Django auth -> Martin -> back?

Sends N sequential tile requests per scenario and prints percentiles of:

  total     whole request as the client sees it (what DevTools calls "Time")
  ttfb      request sent -> first response byte (server work + one network round trip)
  connect   new TCP connection (0 with --keep-alive, which is what browsers do)
  auth      Django auth subrequest, measured by Nginx      (X-Timing-Auth)
  martin    Martin tile render + PostGIS query, by Nginx    (X-Timing-Martin)
  network+  ttfb - auth - martin  = Nginx overhead + network round trip

Run it from YOUR machine to get real browser numbers (includes your network):
    python3 latency_probe.py --fixtures .fixtures.json --geotrak http://<server>:8000 --geolayers http://<server>:8081 --keep-alive

Run it inside geo_shared (run_all.sh does) to add a no-auth Martin baseline:
    ... --geotrak http://geo-nginx:8000 --geolayers http://geo-nginx:8081 --host-header localhost --martin http://martin:3000
"""
import argparse
import json
import random
import statistics
import sys

from geotest import (
    Config,
    Http,
    add_common_args,
    login_geolayers,
    login_geotrak,
    random_tile,
)


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, round(pct / 100 * (len(ordered) - 1))))
    return ordered[k]


def build_scenarios(cfg, http):
    gt, gl = cfg.fixtures["geotrak"], cfg.fixtures["geolayers"]
    gt_session = login_geotrak(http, cfg)
    gl_session, gl_jwt = login_geolayers(http, cfg)
    gl_bbox = gl["bounds"]

    def gt_url(z, x, y):
        return f"{cfg.geotrak}/tiles/{gt['layer']}/{z}/{x}/{y}"

    def gl_url(z, x, y):
        return f"{cfg.geolayers}/tiles/geolayers_tile/{z}/{x}/{y}?layer={gl['layer_table']}"

    scenarios = [
        ("GeoTrak  | API token       ", lambda t: (gt_url(*t), {"Authorization": f"Bearer {gt['token']}"}), None),
        ("GeoTrak  | session (web map)", lambda t: (gt_url(*t), {"Cookie": f"geotrak_sessionid={gt_session}"}), None),
        ("GeoLayers| session (builder)", lambda t: (gl_url(*t), {"Cookie": f"geolayers_sessionid={gl_session}"}), gl_bbox),
        ("GeoLayers| share link       ",
         lambda t: (f"{cfg.geolayers}/x/{gl['share_token']}/{t[0]}/{t[1]}/{t[2]}.pbf", {}), gl_bbox),
    ]
    if cfg.martin:
        scenarios += [
            ("Martin   | riyadh (no auth)",
             lambda t: (f"{cfg.martin}/riyadh_roads/{t[0]}/{t[1]}/{t[2]}", {}), None),
            ("Martin   | geolayers (no auth)",
             lambda t: (f"{cfg.martin}/geolayers_tile/{t[0]}/{t[1]}/{t[2]}?layer={gl['layer_table']}", {}), gl_bbox),
        ]
    return scenarios


def run(cfg, requests, keep_alive, seed):
    rng = random.Random(seed)
    login_http = Http(host_header=cfg.host_header)
    scenarios = build_scenarios(cfg, login_http)
    report = {}

    for name, make, bbox in scenarios:
        is_martin = name.startswith("Martin")
        http = Http(keep_alive=keep_alive, host_header="" if is_martin else cfg.host_header)
        tiles = [random_tile(bbox or (46.55, 24.55, 46.90, 24.85), rng=rng) for _ in range(requests)]
        rows = {"total": [], "ttfb": [], "connect": [], "auth": [], "martin": [], "network+": []}
        errors = 0
        http.get(make(tiles[0])[0], make(tiles[0])[1])  # warm-up (DNS, first connection, Django import)
        for tile in tiles:
            url, headers = make(tile)
            try:
                res = http.get(url, headers)
            except OSError:
                errors += 1
                continue
            if res.status not in (200, 204):
                errors += 1
                continue
            rows["total"].append(res.total_ms)
            rows["ttfb"].append(res.ttfb_ms)
            rows["connect"].append(res.connect_ms)
            auth, martin = res.timing("X-Timing-Auth"), res.timing("X-Timing-Martin")
            if auth is not None:
                rows["auth"].append(auth)
            if martin is not None:
                rows["martin"].append(martin)
            if auth is not None and martin is not None:
                rows["network+"].append(max(0.0, res.ttfb_ms - auth - martin))
        http.close()
        report[name.strip()] = {"errors": errors, "ok": len(rows["total"]), **{
            k: {"p50": percentile(v, 50), "p95": percentile(v, 95), "max": max(v) if v else None,
                "mean": statistics.fmean(v) if v else None}
            for k, v in rows.items()
        }}
    return report


def print_report(report, keep_alive):
    cols = ["total", "ttfb", "connect", "auth", "martin", "network+"]
    print(f"\nTile latency in ms (p50 / p95), {'keep-alive (browser-like)' if keep_alive else 'new connection per request'}\n")
    print(f"{'scenario':<32}{'ok/err':>9}  " + "".join(f"{c:>16}" for c in cols))
    for name, row in report.items():
        cells = []
        for c in cols:
            p50, p95 = row[c]["p50"], row[c]["p95"]
            cells.append(f"{'-':>16}" if p50 is None else f"{p50:7.1f} /{p95:7.1f}")
        print(f"{name:<32}{row['ok']:>5}/{row['errors']:<3}  " + "".join(f"{c:>16}" for c in cells))
    print("\nauth   = time Django spent validating (Nginx auth_request subrequest)")
    print("martin = time Martin + PostGIS spent rendering the tile")
    print("Compare 'GeoTrak/GeoLayers' rows with 'Martin (no auth)' rows to see the full cost of authentication.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    add_common_args(parser)
    parser.add_argument("-n", "--requests", type=int, default=100, help="requests per scenario")
    parser.add_argument("--keep-alive", action="store_true", help="reuse connections like a browser")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--json", help="also write the report to this file")
    args = parser.parse_args()

    cfg = Config.from_args(args)
    report = run(cfg, args.requests, args.keep_alive, args.seed)
    print_report(report, args.keep_alive)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2)
    sys.exit(1 if any(r["ok"] == 0 for r in report.values()) else 0)


if __name__ == "__main__":
    main()
