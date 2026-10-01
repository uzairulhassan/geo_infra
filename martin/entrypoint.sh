#!/bin/sh
# Shared Martin config (Martin v0.18.x keys). It connects to two databases on the same instance.
#
#   riyadh_roads DB : auto-publishes public.* geometry tables -> source id "riyadh_roads"
#   geolayers DB    : ONE function source "geolayers_tile", which serves any uploaded layer via
#                     ?layer=layer_<uuid>. New uploads are visible immediately, so Martin
#                     never needs a restart or catalog reload.
#
# Martin is only reachable inside the geo_shared network. Nginx decides what is exposed:
#   :8000 /tiles/<source>/...           (GeoTrak, guarded by auth_request)
#   :8081 /tiles/geolayers_tile/... and /x/<share-token>/...  (GeoLayers, guarded by auth_request)
set -eu

RIYADH_URL="${MARTIN_RIYADH_DATABASE_URL:?MARTIN_RIYADH_DATABASE_URL not set}"
GEOLAYERS_URL="${MARTIN_GEOLAYERS_DATABASE_URL:?MARTIN_GEOLAYERS_DATABASE_URL not set}"
CACHE_MB="${MARTIN_CACHE_MB:-0}"
POOL="${MARTIN_POOL_SIZE:-5}"
WORKERS="${MARTIN_WORKERS:-2}"
CONFIG="/tmp/martin-runtime.yaml"

cat > "$CONFIG" <<EOF
listen_addresses: "0.0.0.0:3000"
worker_processes: ${WORKERS}
# 0 = disabled. GeoTrak tiles must reflect approved edits immediately.
cache_size_mb: ${CACHE_MB}
preferred_encoding: gzip
web_ui: disable

postgres:
  - connection_string: "${RIYADH_URL}"
    pool_size: ${POOL}
    auto_publish:
      tables:
        from_schemas:
          - public
        source_id_format: "{table}"
      functions: false

  - connection_string: "${GEOLAYERS_URL}"
    pool_size: ${POOL}
    auto_bounds: skip
    auto_publish: false
    functions:
      geolayers_tile:
        schema: layers_data
        function: geolayers_tile
        minzoom: 0
        maxzoom: 22
EOF

exec martin --config "$CONFIG"
