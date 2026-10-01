"""Shared helpers for smoke_test.py and latency_probe.py (standard library only).

Fixture JSON (written by run_all.sh from the two `tile_loadtest_fixture` commands):
    {"geotrak":   {"email", "password", "token", "layer", "layer_allows_anonymous"},
     "geolayers": {"username", "password", "layer_id", "layer_table", "share_token", "bounds"}}
"""
from __future__ import annotations

import http.client
import json
import math
import os
import random
import ssl
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

GEOTRAK_SESSION_COOKIE = os.environ.get("GEOTRAK_SESSION_COOKIE", "geotrak_sessionid")
GEOLAYERS_SESSION_COOKIE = os.environ.get("GEOLAYERS_SESSION_COOKIE", "geolayers_sessionid")
RIYADH_BBOX = (46.55, 24.55, 46.90, 24.85)


# ----------------------------------------------------------------------------- config
@dataclass
class Config:
    geotrak: str = "http://localhost:8000"
    geolayers: str = "http://localhost:8081"
    martin: str = ""  # e.g. http://martin:3000 (only reachable inside the geo_shared network)
    host_header: str = ""  # set when calling Nginx by container name (Django checks ALLOWED_HOSTS)
    fixtures: dict = field(default_factory=dict)

    @classmethod
    def from_args(cls, args):
        with open(args.fixtures, encoding="utf-8") as fh:
            fixtures = json.load(fh)
        return cls(
            geotrak=args.geotrak.rstrip("/"),
            geolayers=args.geolayers.rstrip("/"),
            martin=(args.martin or "").rstrip("/"),
            host_header=args.host_header or "",
            fixtures=fixtures,
        )


def add_common_args(parser):
    parser.add_argument("--fixtures", default=os.path.join(os.path.dirname(__file__), ".fixtures.json"))
    parser.add_argument("--geotrak", default=os.environ.get("GEOTRAK_URL", "http://localhost:8000"))
    parser.add_argument("--geolayers", default=os.environ.get("GEOLAYERS_URL", "http://localhost:8081"))
    parser.add_argument("--martin", default=os.environ.get("MARTIN_URL", ""),
                        help="Direct Martin base for a no-auth baseline (inside geo_shared only)")
    parser.add_argument("--host-header", default=os.environ.get("HOST_HEADER", ""),
                        help="Override Host (e.g. localhost) when targeting http://geo-nginx:8000")


# ----------------------------------------------------------------------------- HTTP with timings
@dataclass
class Result:
    status: int
    headers: dict
    body: bytes
    connect_ms: float  # TCP (+TLS) connect; 0 when the connection was reused
    ttfb_ms: float  # request sent -> response headers received (server time + 1 RTT)
    total_ms: float  # whole exchange, including connect and body download
    set_cookies: list = field(default_factory=list)  # every Set-Cookie header (a dict would drop repeats)

    def header(self, name: str, default: str = "") -> str:
        return self.headers.get(name.lower(), default)

    def timing(self, name: str) -> float | None:
        """Parse X-Timing-* (Nginx seconds, possibly 'a, b' lists) into milliseconds."""
        raw = self.header(name)
        values = [v.strip() for v in raw.replace(":", ",").split(",") if v.strip() not in ("", "-")]
        try:
            return float(values[-1]) * 1000 if values else None
        except ValueError:
            return None


class Http:
    """Tiny client. keep_alive=True reuses one connection per origin, like a browser."""

    def __init__(self, keep_alive: bool = False, host_header: str = "", timeout: float = 30):
        self.keep_alive = keep_alive
        self.host_header = host_header
        self.timeout = timeout
        self._conns: dict[str, http.client.HTTPConnection] = {}

    def _connection(self, url):
        parts = urlsplit(url)
        key = f"{parts.scheme}://{parts.netloc}"
        conn = self._conns.get(key) if self.keep_alive else None
        fresh = conn is None
        if fresh:
            if parts.scheme == "https":
                conn = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=self.timeout,
                                                   context=ssl.create_default_context())
            else:
                conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=self.timeout)
            if self.keep_alive:
                self._conns[key] = conn
        return conn, fresh, parts

    def request(self, method, url, headers=None, body=None) -> Result:
        headers = dict(headers or {})
        conn, fresh, parts = self._connection(url)
        if self.host_header:
            port = f":{parts.port}" if parts.port else ""
            headers.setdefault("Host", f"{self.host_header}{port}")
        path = parts.path + (f"?{parts.query}" if parts.query else "")

        t0 = time.perf_counter()
        if fresh:
            conn.connect()
        t_connected = time.perf_counter()
        try:
            conn.request(method, path or "/", body=body, headers=headers)
            resp = conn.getresponse()
            t_headers = time.perf_counter()
            data = resp.read()
        except (http.client.HTTPException, OSError):
            conn.close()
            self._conns.pop(f"{parts.scheme}://{parts.netloc}", None)
            raise
        t_done = time.perf_counter()
        if not self.keep_alive:
            conn.close()
        return Result(
            status=resp.status,
            headers={k.lower(): v for k, v in resp.getheaders()},
            body=data,
            connect_ms=(t_connected - t0) * 1000 if fresh else 0.0,
            ttfb_ms=(t_headers - t_connected) * 1000,
            total_ms=(t_done - t0) * 1000,
            set_cookies=[v for k, v in resp.getheaders() if k.lower() == "set-cookie"],
        )

    def get(self, url, headers=None) -> Result:
        return self.request("GET", url, headers=headers)

    def post_json(self, url, payload, headers=None) -> Result:
        headers = {"Content-Type": "application/json", **(headers or {})}
        return self.request("POST", url, headers=headers, body=json.dumps(payload).encode())

    def close(self):
        for conn in self._conns.values():
            conn.close()
        self._conns.clear()


def cookie_from(result: Result, name: str) -> str:
    for raw in result.set_cookies:
        key, _, value = raw.split(";", 1)[0].strip().partition("=")
        if key == name:
            return value
    return ""


# ----------------------------------------------------------------------------- logins
def login_geotrak(http: Http, cfg: Config) -> str:
    """GeoTrak JSON login -> session cookie value."""
    fx = cfg.fixtures["geotrak"]
    res = http.post_json(f"{cfg.geotrak}/api/login/", {"email": fx["email"], "password": fx["password"]})
    if res.status != 200:
        raise RuntimeError(f"GeoTrak login failed: {res.status} {res.body[:200]!r}")
    session = cookie_from(res, GEOTRAK_SESSION_COOKIE)
    if not session:
        raise RuntimeError(f"GeoTrak login set no '{GEOTRAK_SESSION_COOKIE}' cookie")
    return session


def login_geolayers(http: Http, cfg: Config) -> tuple[str, str]:
    """GeoLayers login -> (session cookie value, JWT access token)."""
    fx = cfg.fixtures["geolayers"]
    res = http.post_json(f"{cfg.geolayers}/api/auth/login/",
                         {"username": fx["username"], "password": fx["password"]})
    if res.status != 200:
        raise RuntimeError(f"GeoLayers login failed: {res.status} {res.body[:200]!r}")
    return cookie_from(res, GEOLAYERS_SESSION_COOKIE), json.loads(res.body)["access"]


# ----------------------------------------------------------------------------- tiles
def lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int, int]:
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    lat_r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n)
    return z, min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def center_tile(bbox=RIYADH_BBOX, z: int = 12):
    minx, miny, maxx, maxy = bbox
    return lonlat_to_tile((minx + maxx) / 2, (miny + maxy) / 2, z)


def random_tile(bbox=RIYADH_BBOX, zooms=(12, 13, 14, 15), rng=random):
    minx, miny, maxx, maxy = bbox
    return lonlat_to_tile(rng.uniform(minx, maxx), rng.uniform(miny, maxy), rng.choice(zooms))
