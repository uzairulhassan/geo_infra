// k6 load test: tiles through Nginx -> Django auth_request -> Martin, for GeoTrak and GeoLayers,
// plus direct-to-Martin baselines (no auth) so the cost of authentication is visible.
//
// Run inside the geo_shared network (run_all.sh --load does this):
//   docker run --rm -i --network geo_shared -v "$PWD/tests:/tests" grafana/k6 run \
//     -e FIXTURES=/tests/.fixtures.json -e HOST_HEADER=localhost \
//     -e GEOTRAK_URL=http://geo-nginx:8000 -e GEOLAYERS_URL=http://geo-nginx:8081 \
//     -e MARTIN_URL=http://martin:3000 -e RATE=30 -e DURATION=2m /tests/load/tiles.js
//
// Knobs (env): RATE (tiles/s per scenario, default 20), DURATION (default 1m),
//              SCENARIOS (comma list, default all), P95_MS (threshold, default 500).
//
// A browser map view loads ~20-60 tiles at once, so RATE=30 is roughly one user panning
// continuously per scenario. Raise RATE until p95 or errors breach the thresholds to find capacity.
import http from "k6/http";
import { check } from "k6";
import { Trend, Rate } from "k6/metrics";

const FX = JSON.parse(open(__ENV.FIXTURES || "/tests/.fixtures.json"));
const GEOTRAK = (__ENV.GEOTRAK_URL || "http://geo-nginx:8000").replace(/\/$/, "");
const GEOLAYERS = (__ENV.GEOLAYERS_URL || "http://geo-nginx:8081").replace(/\/$/, "");
const MARTIN = (__ENV.MARTIN_URL || "").replace(/\/$/, "");
const HOST = __ENV.HOST_HEADER || "";
const RATE = parseInt(__ENV.RATE || "20", 10);
const DURATION = __ENV.DURATION || "1m";
const P95 = parseInt(__ENV.P95_MS || "500", 10);
const RIYADH = [46.55, 24.55, 46.9, 24.85];

const authMs = new Trend("tile_auth_ms", true);
const martinMs = new Trend("tile_martin_ms", true);
const badStatus = new Rate("tile_bad_status");

const ALL = {
  geotrak_token: "geotrakToken",
  geotrak_session: "geotrakSession",
  geolayers_session: "geolayersSession",
  geolayers_share: "geolayersShare",
  martin_riyadh: "martinRiyadh",
  martin_geolayers: "martinGeolayers",
};
const wanted = (__ENV.SCENARIOS || Object.keys(ALL).join(",")).split(",").map((s) => s.trim());

const scenarios = {};
const thresholds = { http_req_failed: ["rate<0.01"], tile_bad_status: ["rate<0.01"] };
for (const name of wanted) {
  if (!ALL[name] || (name.startsWith("martin_") && !MARTIN)) continue;
  scenarios[name] = {
    executor: "constant-arrival-rate",
    exec: ALL[name],
    rate: RATE,
    timeUnit: "1s",
    duration: DURATION,
    preAllocatedVUs: Math.max(10, RATE),
    maxVUs: RATE * 10,
  };
  thresholds[`http_req_duration{scenario:${name}}`] = [`p(95)<${P95}`];
  thresholds[`tile_auth_ms{scenario:${name}}`] = ["p(95)>=0"]; // forces per-scenario rows in the summary
  thresholds[`tile_martin_ms{scenario:${name}}`] = ["p(95)>=0"];
}

export const options = { scenarios, thresholds, summaryTrendStats: ["avg", "med", "p(90)", "p(95)", "p(99)", "max"] };

// ------------------------------------------------------------------ helpers
function hostHeaders(url, extra) {
  const headers = Object.assign({}, extra || {});
  if (HOST && !url.startsWith(MARTIN || "\u0000")) {
    const port = (url.match(/^https?:\/\/[^/:]+(:\d+)/) || [])[1] || "";
    headers.Host = HOST + port;
  }
  return headers;
}

function lonlatToTile(lon, lat, z) {
  const n = 2 ** z;
  const x = Math.floor(((lon + 180) / 360) * n);
  const r = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.asinh(Math.tan(r)) / Math.PI) / 2) * n);
  return [z, Math.min(Math.max(x, 0), n - 1), Math.min(Math.max(y, 0), n - 1)];
}

function randomTile(bbox) {
  const b = bbox || RIYADH;
  const z = 12 + Math.floor(Math.random() * 4); // 12..15, typical city-scale map views
  return lonlatToTile(b[0] + Math.random() * (b[2] - b[0]), b[1] + Math.random() * (b[3] - b[1]), z);
}

function seconds(header) {
  if (!header || header === "-") return null;
  const parts = String(header).split(/[,:]/).map((s) => s.trim()).filter((s) => s && s !== "-");
  const v = parseFloat(parts[parts.length - 1]);
  return isNaN(v) ? null : v * 1000;
}

function hit(url, headers) {
  const res = http.get(url, { headers: hostHeaders(url, headers), tags: { name: url.split("/").slice(0, 5).join("/") } });
  const ok = res.status === 200 || res.status === 204;
  badStatus.add(!ok);
  check(res, { "tile 200/204": () => ok });
  const a = seconds(res.headers["X-Timing-Auth"]);
  const m = seconds(res.headers["X-Timing-Martin"]);
  if (a !== null) authMs.add(a);
  if (m !== null) martinMs.add(m);
  return res;
}

function cookieValue(res, name) {
  const c = res.cookies[name];
  return c && c.length ? c[0].value : "";
}

// ------------------------------------------------------------------ setup: log in once
export function setup() {
  const gt = http.post(`${GEOTRAK}/api/login/`, JSON.stringify({ email: FX.geotrak.email, password: FX.geotrak.password }), {
    headers: hostHeaders(GEOTRAK + "/", { "Content-Type": "application/json" }),
  });
  const gl = http.post(
    `${GEOLAYERS}/api/auth/login/`,
    JSON.stringify({ username: FX.geolayers.username, password: FX.geolayers.password }),
    { headers: hostHeaders(GEOLAYERS + "/", { "Content-Type": "application/json" }) }
  );
  if (gt.status !== 200 || gl.status !== 200) {
    throw new Error(`login failed: geotrak=${gt.status} geolayers=${gl.status}`);
  }
  return {
    gtSession: cookieValue(gt, "geotrak_sessionid"),
    glSession: cookieValue(gl, "geolayers_sessionid"),
  };
}

// ------------------------------------------------------------------ scenarios
export function geotrakToken() {
  const [z, x, y] = randomTile();
  hit(`${GEOTRAK}/tiles/${FX.geotrak.layer}/${z}/${x}/${y}`, { Authorization: `Bearer ${FX.geotrak.token}` });
}

export function geotrakSession(data) {
  const [z, x, y] = randomTile();
  hit(`${GEOTRAK}/tiles/${FX.geotrak.layer}/${z}/${x}/${y}`, { Cookie: `geotrak_sessionid=${data.gtSession}` });
}

export function geolayersSession(data) {
  const [z, x, y] = randomTile(FX.geolayers.bounds);
  hit(`${GEOLAYERS}/tiles/geolayers_tile/${z}/${x}/${y}?layer=${FX.geolayers.layer_table}`, {
    Cookie: `geolayers_sessionid=${data.glSession}`,
  });
}

export function geolayersShare() {
  const [z, x, y] = randomTile(FX.geolayers.bounds);
  hit(`${GEOLAYERS}/x/${FX.geolayers.share_token}/${z}/${x}/${y}.pbf`);
}

export function martinRiyadh() {
  const [z, x, y] = randomTile();
  hit(`${MARTIN}/riyadh_roads/${z}/${x}/${y}`);
}

export function martinGeolayers() {
  const [z, x, y] = randomTile(FX.geolayers.bounds);
  hit(`${MARTIN}/geolayers_tile/${z}/${x}/${y}?layer=${FX.geolayers.layer_table}`);
}
