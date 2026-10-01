# Tests: unit, end-to-end, latency, and load

| Layer | What | Where | Runs on |
|---|---|---|---|
| Unit / integration | Django logic: tokens, sessions, share links, permissions, usage counting, management commands, the PostGIS tile function | `naqel-mapserver/tile_access/tests.py`, `layeruploading_martintileserver/apps/layers/tests.py` | Django test runner (PostGIS test DB) |
| Config | `nginx -t`, migrations match models | `run_all.sh` | containers |
| End-to-end smoke | Real HTTP through Nginx → Django auth → Martin: status codes, headers, CORS, revocation, isolation between ports | `smoke_test.py` | any machine with Python 3 (stdlib only) |
| Latency | Per-request time split into **auth** (Django), **martin** (render) and **network/Nginx** | `latency_probe.py` | your PC (real browser numbers) or the server |
| Load | Throughput and percentiles under concurrency, with direct-Martin baselines | `load/tiles.js` (k6) | `grafana/k6` container |

## One command (on the Docker host)

```bash
cd geo-infra
bash tests/run_all.sh            # config + unit + smoke + latency
bash tests/run_all.sh --load     # ... + k6 load test (RATE=20/s per scenario for 1m)
RATE=60 DURATION=3m bash tests/run_all.sh --only load
```

`run_all.sh` creates throwaway fixtures (a `loadtest` GeoTrak editor and token, plus
a GeoLayers user with a 5,000-point layer and a share link) and **always removes
them at the end**. The fixtures' secrets live only in `tests/.fixtures.json`
(mode 600, gitignored, deleted on exit). Reports go to `tests/reports/`.

Unit tests create their test databases with the `postgres` superuser (from
`geo-infra/.env`), so the app roles don't need `CREATEDB`.

## Measuring "browser → auth → Martin → browser"

Every tile response from Nginx carries the server-side split:

```
X-Timing-Auth:   0.004   # Django auth_request subrequest (seconds)
X-Timing-Martin: 0.012   # Martin + PostGIS rendering the tile (seconds)
```

**In the browser:** open DevTools → Network, filter on `tiles` (GeoTrak) or
`geolayers_tile` / `/x/` (GeoLayers), and click a tile:
* **Timing** tab → *Waiting for server response* (TTFB) = auth + martin + Nginx + one network round trip.
* **Headers** tab → `X-Timing-Auth` / `X-Timing-Martin` show the server-side part.
* Network round trip ≈ TTFB − auth − martin.

**From your PC (scripted, same numbers a browser sees):**

```bash
# on the server: create fixtures and copy them to your PC (delete afterwards!)
docker compose -f ../naqel-mapserver/docker-compose.yml exec -T geotrak_maps python manage.py tile_loadtest_fixture
docker compose -f ../layeruploading_martintileserver/docker-compose.prod.yml exec -T web python manage.py tile_loadtest_fixture
#   -> put both JSON outputs into tests/.fixtures.json as {"geotrak": ..., "geolayers": ...}

python3 tests/latency_probe.py --fixtures tests/.fixtures.json \
    --geotrak http://<server>:8000 --geolayers http://<server>:8081 --keep-alive -n 200
```

Sample output layout (your numbers will differ):

```
scenario                           ok/err             total            ttfb         connect            auth          martin        network+
GeoTrak  | API token                200/0     p50 /  p95      ...
GeoTrak  | session (web map)        200/0     ...
GeoLayers| session (builder)        200/0     ...
GeoLayers| share link               200/0     ...
Martin   | riyadh (no auth)         200/0     (server-side run only, via --martin)
```

The cost of authentication = **auth** column, or (Nginx row − Martin-direct row)
from the server-side run. Expect auth to be a few milliseconds: one indexed token
or session lookup plus one usage upsert, on the same host. Martin time depends on
zoom and data density. From a remote PC, **network round-trip time usually
dominates**. Measure, don't assume.

## Load test details (k6)

Scenarios (each at `RATE` tiles/s, constant-arrival-rate):

| scenario | path |
|---|---|
| `geotrak_token` | `:8000/tiles/riyadh_roads/...` + `Authorization: Bearer gtk_…` |
| `geotrak_session` | same, with the GeoTrak session cookie (web map) |
| `geolayers_session` | `:8081/tiles/geolayers_tile/...?layer=` + GeoLayers session cookie |
| `geolayers_share` | `:8081/x/<share-token>/...pbf` |
| `martin_riyadh`, `martin_geolayers` | Martin directly, **no auth**: the baseline |

The pass/fail thresholds are p95 < `P95_MS` (default 500 ms) per scenario and < 1 % errors.
The summary also shows `tile_auth_ms` and `tile_martin_ms` per scenario.

To find capacity, raise `RATE` until a threshold fails. The usual first bottleneck
is the Django auth workers (`GUNICORN_WORKERS`, 3 by default for GeoTrak and 2 for GeoLayers),
because every tile makes one auth call. Then it's Martin/PostGIS at high zoom on dense data.
