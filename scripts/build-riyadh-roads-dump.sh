#!/usr/bin/env bash
# Build an app-ready riyadh_roads table (+ optional pg_dump) from sau_road.zip.
#
# Why this exists:
#   GeoTrak expects public.riyadh_roads with a fixed column set (see mapping.models.RiyadhRoad
#   + layer_uploader inserts for name_en/name_ar). The OSM-style shapefile sau_road.zip is
#   close (EPSG:3857 lines) but not schema-compatible — this script normalizes it.
#
# Usage (from host, with geo-infra stack running):
#   1. Put sau_road.zip in geo_infra/backups/  (or pass SHP_ZIP=...)
#   2. docker compose exec -T postgis bash /scripts/build-riyadh-roads-dump.sh
#
# Env:
#   SHP_ZIP     path inside container (default: /backups/sau_road.zip)
#   MAKE_DUMP   1 (default) write /backups/riyadh_roads-YYYY-MM-DD.dump
#   REPLACE     1 (default) DROP existing public.riyadh_roads before load
#
set -euo pipefail

SHP_ZIP="${SHP_ZIP:-/backups/sau_road.zip}"
MAKE_DUMP="${MAKE_DUMP:-1}"
REPLACE="${REPLACE:-1}"
WORK="/tmp/sau_road_import"
STAGING="public._sau_road_staging"
TARGET="public.riyadh_roads"
DUMP_OUT="/backups/riyadh_roads-$(date +%F).dump"

if [[ ! -f "$SHP_ZIP" ]]; then
  echo "ERROR: shapefile zip not found at $SHP_ZIP" >&2
  echo "Copy sau_road.zip into geo_infra/backups/ first." >&2
  exit 1
fi

need_pkgs=()
command -v ogr2ogr >/dev/null 2>&1 || need_pkgs+=(gdal-bin)
command -v unzip >/dev/null 2>&1 || need_pkgs+=(unzip)
if ((${#need_pkgs[@]})); then
  echo "Installing: ${need_pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}" >/dev/null
fi

rm -rf "$WORK"
mkdir -p "$WORK"
unzip -qo "$SHP_ZIP" -d "$WORK"

SHP="$(find "$WORK" -maxdepth 1 -iname '*.shp' | head -n 1)"
if [[ -z "$SHP" ]]; then
  echo "ERROR: no .shp inside $SHP_ZIP" >&2
  exit 1
fi

echo "==> Source: $SHP"
ogrinfo -so -al "$SHP" | head -n 40

echo "==> Loading staging table $STAGING via ogr2ogr (EPSG:3857, MultiLineString)"
psql -v ON_ERROR_STOP=1 -U postgres -d riyadh_roads -c "DROP TABLE IF EXISTS $STAGING CASCADE;"

ogr2ogr \
  -f PostgreSQL \
  "PG:dbname=riyadh_roads user=postgres host=localhost" \
  "$SHP" \
  -nln "${STAGING#public.}" \
  -nlt MULTILINESTRING \
  -lco GEOMETRY_NAME=geom \
  -lco FID=ogc_fid \
  -lco PRECISION=NO \
  -s_srs EPSG:3857 \
  -t_srs EPSG:3857 \
  -overwrite \
  --config PG_USE_COPY YES

echo "==> Creating app schema $TARGET and mapping rows"

DROP_SQL=""
if [[ "$REPLACE" == "1" ]]; then
  DROP_SQL="DROP TABLE IF EXISTS $TARGET CASCADE;"
fi

psql -v ON_ERROR_STOP=1 -U postgres -d riyadh_roads <<SQL
BEGIN;

$DROP_SQL

-- Target schema aligned with GeoTrak (Django unmanaged model + insert SQL).
CREATE TABLE $TARGET (
  gid          serial PRIMARY KEY,
  id           double precision,
  objectid     numeric(20, 0),
  osm_id       varchar(12),
  code         double precision,
  fclass       varchar(28),
  name         varchar(100),
  name_en      text,
  name_ar      text,
  ref          varchar(20),
  oneway       varchar(1),
  maxspeed     double precision,
  layer        numeric(10, 2),
  bridge       varchar(1),
  tunnel       varchar(1),
  shape_leng   numeric(20, 6),
  geom         geometry(MultiLineString, 3857) NOT NULL,
  road_closure integer NOT NULL DEFAULT 0
);

-- Field mapping from OSM-style sau_road → GeoTrak riyadh_roads
INSERT INTO $TARGET (
  id, objectid, osm_id, code, fclass, name, name_en, name_ar,
  ref, oneway, maxspeed, layer, bridge, tunnel, shape_leng, geom, road_closure
)
SELECT
  ROW_NUMBER() OVER (ORDER BY s.ogc_fid)::double precision AS id,
  NULL::numeric AS objectid,
  LEFT(NULLIF(TRIM(s.osm_id), ''), 12) AS osm_id,
  NULL::double precision AS code,
  LEFT(
    LOWER(
      COALESCE(
        NULLIF(TRIM(s.highway), ''),
        'unclassified'
      )
    ),
    28
  ) AS fclass,
  LEFT(NULLIF(TRIM(s.name), ''), 100) AS name,
  NULLIF(TRIM(s.name), '') AS name_en,
  NULL::text AS name_ar,
  LEFT(NULLIF(TRIM(s.ref), ''), 20) AS ref,
  NULL::varchar AS oneway,
  CASE
    WHEN NULLIF(regexp_replace(COALESCE(s.maxspeed, ''), '[^0-9.]', '', 'g'), '') IS NULL
      THEN NULL
    ELSE NULLIF(regexp_replace(s.maxspeed, '[^0-9.]', '', 'g'), '')::double precision
  END AS maxspeed,
  NULL::numeric AS layer,
  NULL::varchar AS bridge,
  NULL::varchar AS tunnel,
  ROUND(ST_Length(s.geom)::numeric, 6) AS shape_leng,
  ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 2))::geometry(MultiLineString, 3857) AS geom,
  0 AS road_closure
FROM $STAGING s
WHERE s.geom IS NOT NULL
  AND NOT ST_IsEmpty(s.geom);

DROP TABLE $STAGING;

CREATE INDEX riyadh_roads_geom_gist ON $TARGET USING GIST (geom);
CREATE INDEX riyadh_roads_fclass_idx ON $TARGET (fclass);
CREATE INDEX riyadh_roads_id_idx ON $TARGET (id);
CREATE INDEX riyadh_roads_name_en_idx ON $TARGET (name_en);
CREATE INDEX riyadh_roads_name_ar_idx ON $TARGET (name_ar);

ANALYZE $TARGET;

ALTER TABLE $TARGET OWNER TO geotrak_user;
GRANT SELECT ON $TARGET TO martin_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON $TARGET TO geotrak_user;
GRANT USAGE, SELECT ON SEQUENCE riyadh_roads_gid_seq TO geotrak_user;
ALTER SEQUENCE riyadh_roads_gid_seq OWNER TO geotrak_user;

COMMIT;

SELECT COUNT(*) AS road_count,
       COUNT(*) FILTER (WHERE name_en IS NOT NULL AND name_en <> '') AS named,
       COUNT(DISTINCT fclass) AS fclass_count
FROM $TARGET;

SELECT fclass, COUNT(*) AS n
FROM $TARGET
GROUP BY fclass
ORDER BY n DESC
LIMIT 20;
SQL

if [[ "$MAKE_DUMP" == "1" ]]; then
  echo "==> Writing custom-format dump → $DUMP_OUT"
  pg_dump -U postgres -d riyadh_roads -Fc \
    --table=public.riyadh_roads \
    --no-owner --no-acl \
    -f "$DUMP_OUT"
  ls -lh "$DUMP_OUT"
  echo "Restore later with:"
  echo "  docker compose exec -T postgis pg_restore -U postgres -d riyadh_roads --clean --if-exists /backups/$(basename "$DUMP_OUT")"
  echo "  docker compose exec postgis bash /scripts/grant-martin-read.sh"
  echo "  docker compose restart martin"
fi

echo "==> Done. Restart Martin so it auto-publishes public.riyadh_roads:"
echo "  docker compose restart martin"
