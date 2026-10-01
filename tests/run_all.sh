#!/usr/bin/env bash
# Run every test against the deployed stack, on the Docker host.
#
#   cd geo-infra && bash tests/run_all.sh                 # config + unit + smoke + latency
#   bash tests/run_all.sh --load                          # ... plus the k6 load test
#   RATE=50 DURATION=3m bash tests/run_all.sh --load      # heavier load
#   bash tests/run_all.sh --only unit|smoke|latency|load  # one stage
#
# Needs: the geo-infra stack plus both apps running. Test fixtures (a loadtest user,
# token, layer and share link) are created first and removed at the end, even on failure.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INFRA="$(cd "$HERE/.." && pwd)"
GEOTRAK_DIR="${GEOTRAK_DIR:-$INFRA/../naqel-mapserver}"
GEOLAYERS_DIR="${GEOLAYERS_DIR:-$INFRA/../layeruploading_martintileserver}"
GEOLAYERS_COMPOSE="${GEOLAYERS_COMPOSE:-docker-compose.prod.yml}"
FIXTURES="$HERE/.fixtures.json"
REPORTS="$HERE/reports"
HOST_HEADER="${HOST_HEADER:-localhost}"   # must be in both apps' ALLOWED_HOSTS
RATE="${RATE:-20}"
DURATION="${DURATION:-1m}"

ONLY=""; LOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --load) LOAD=1 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

set -a; . "$INFRA/.env"; set +a
mkdir -p "$REPORTS"

dc_infra()     { docker compose -f "$INFRA/docker-compose.yml" "$@"; }
dc_geotrak()   { docker compose -f "$GEOTRAK_DIR/docker-compose.yml" "$@"; }
dc_geolayers() { docker compose -f "$GEOLAYERS_DIR/$GEOLAYERS_COMPOSE" "$@"; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. config sanity
if want unit || want config; then
  step "Nginx config test"
  dc_infra exec -T nginx nginx -t

  step "Migrations match models"
  dc_geotrak exec -T geotrak_maps python manage.py makemigrations --check --dry-run
  dc_geolayers exec -T web python manage.py makemigrations --check --dry-run
fi

# ---------------------------------------------------------------- 2. unit / integration tests (Django)
# Test databases are created by the postgres superuser, so the app roles don't need CREATEDB.
if want unit; then
  step "GeoTrak unit tests"
  dc_geotrak exec -T -e DB_USER=postgres -e DB_PASSWORD="$POSTGRES_PASSWORD" geotrak_maps \
    python manage.py test --noinput tile_access mapping layer_uploader

  step "GeoLayers unit tests"
  dc_geolayers exec -T -e DATABASE_URL="postgis://postgres:${POSTGRES_PASSWORD}@postgis:5432/geolayers" web \
    python manage.py test --noinput apps
fi

needs_fixtures() { want smoke || want latency || want load || [ "$LOAD" = 1 ]; }
if ! needs_fixtures; then exit 0; fi

# ---------------------------------------------------------------- 3. fixtures
cleanup() {
  step "Removing test fixtures"
  dc_geotrak exec -T geotrak_maps python manage.py tile_loadtest_fixture --cleanup || true
  dc_geolayers exec -T web python manage.py tile_loadtest_fixture --cleanup || true
  rm -f "$FIXTURES"
}
trap cleanup EXIT

step "Creating test fixtures"
GT_JSON="$(dc_geotrak exec -T geotrak_maps python manage.py tile_loadtest_fixture | tail -n 1)"
GL_JSON="$(dc_geolayers exec -T web python manage.py tile_loadtest_fixture | tail -n 1)"
umask 077
printf '{"geotrak": %s, "geolayers": %s}\n' "$GT_JSON" "$GL_JSON" > "$FIXTURES"

PY=(docker run --rm --network geo_shared -v "$HERE:/tests" -w /tests python:3.12-alpine python)
NGINX_ARGS=(--fixtures /tests/.fixtures.json --geotrak http://geo-nginx:8000 --geolayers http://geo-nginx:8081
            --host-header "$HOST_HEADER" --martin http://martin:3000)

# ---------------------------------------------------------------- 4. smoke (end-to-end behaviour)
if want smoke; then
  step "End-to-end smoke test"
  "${PY[@]}" smoke_test.py "${NGINX_ARGS[@]}"
fi

# ---------------------------------------------------------------- 5. latency (single-user timings)
if want latency; then
  step "Latency probe (server-local; run latency_probe.py from your PC for real browser numbers)"
  "${PY[@]}" latency_probe.py "${NGINX_ARGS[@]}" --keep-alive -n "${REQUESTS:-200}" --json /tests/reports/latency.json
fi

# ---------------------------------------------------------------- 6. load (concurrency)
if [ "$LOAD" = 1 ] || [ "$ONLY" = load ]; then
  step "k6 load test: RATE=${RATE}/s per scenario for ${DURATION}"
  docker run --rm -i --network geo_shared -v "$HERE:/tests" grafana/k6 run \
    -e FIXTURES=/tests/.fixtures.json -e HOST_HEADER="$HOST_HEADER" \
    -e GEOTRAK_URL=http://geo-nginx:8000 -e GEOLAYERS_URL=http://geo-nginx:8081 -e MARTIN_URL=http://martin:3000 \
    -e RATE="$RATE" -e DURATION="$DURATION" -e P95_MS="${P95_MS:-500}" \
    --summary-export /tests/reports/k6-summary.json /tests/load/tiles.js

  step "Tile log sample (auth / martin split per request, token prefixes only)"
  docker logs --since 10m geo-nginx 2>&1 | grep 'tile_token=' | tail -n 5 || true
  step "Checking that no full tokens or share tokens were logged"
  # Prefixes (gtk_ + 8 chars) are logged on purpose; a full token is gtk_ + 43 chars.
  SHARE_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["geolayers"]["share_token"])' "$FIXTURES" 2>/dev/null || true)"
  if docker logs --since 30m geo-nginx 2>&1 | grep -Eq 'gtk_[A-Za-z0-9_-]{20,}'      || { [ -n "$SHARE_TOKEN" ] && docker logs --since 30m geo-nginx 2>&1 | grep -qF "$SHARE_TOKEN"; }; then
    echo "FAIL: a full API token or share-link token appears in the Nginx logs"; exit 1
  else
    echo "ok"
  fi
fi

step "All requested stages passed. Reports: $REPORTS"
