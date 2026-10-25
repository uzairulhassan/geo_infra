#!/usr/bin/env bash
# Build an app-ready riyadh_roads table (+ optional pg_dump) for GeoTrak / Martin.
#
# Preferred source (UTF-8, official governorate clip):
#   backups/geofabrik_roads/gis_osm_roads_free_1.shp
#   backups/riyadh_governorate.geojson
#
# Fallback:
#   backups/riyadh_roads.zip — already-clipped UTF-8 shapefile
#
# Why:
#   GeoTrak labels use name_en / name_ar (see mapping API + symbology/labeling.json).
#   QGIS clips written as Windows-1252 (.cpg=1252) destroy Arabic names → "????".
#   This script clips with GDAL (UTF-8) and splits Arabic vs Latin into name_ar / name_en.
#
# Usage (geo-infra stack running):
#   docker compose exec -T postgis bash /scripts/build-riyadh-roads-dump.sh
#
# Env:
#   ROADS_SHP     Geofabrik roads .shp (default: /backups/geofabrik_roads/gis_osm_roads_free_1.shp)
#   BOUNDARY      Governorate GeoJSON/shp (default: /backups/riyadh_governorate.geojson)
#   SHP_ZIP       Fallback zip if ROADS_SHP+BOUNDARY missing
#   MAKE_DUMP     1 (default) → /backups/riyadh_roads-YYYY-MM-DD.dump
#   REPLACE       1 (default) DROP public.riyadh_roads only (never geotrak/geolayers)
#
set -euo pipefail

ROADS_SHP="${ROADS_SHP:-/backups/geofabrik_roads/gis_osm_roads_free_1.shp}"
BOUNDARY="${BOUNDARY:-/backups/riyadh_governorate.geojson}"
MAKE_DUMP="${MAKE_DUMP:-1}"
REPLACE="${REPLACE:-1}"
WORK="/tmp/riyadh_roads_import"
STAGING="public._riyadh_roads_staging"
TARGET="public.riyadh_roads"
DUMP_OUT="/backups/riyadh_roads-$(date +%F).dump"

need_pkgs=()
command -v ogr2ogr >/dev/null 2>&1 || need_pkgs+=(gdal-bin)
command -v unzip >/dev/null 2>&1 || need_pkgs+=(unzip)
command -v zip >/dev/null 2>&1 || need_pkgs+=(zip)
if ((${#need_pkgs[@]})); then
  echo "Installing: ${need_pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}" >/dev/null
fi

rm -rf "$WORK"
mkdir -p "$WORK"

SOURCE_MODE=""
SHP=""

if [[ -f "$ROADS_SHP" && -f "$BOUNDARY" ]]; then
  SOURCE_MODE="clip"
  echo "==> Mode: UTF-8 Geofabrik clip by governorate boundary"
  echo "    roads:    $ROADS_SHP"
  echo "    boundary: $BOUNDARY"
  if [[ -f "${ROADS_SHP%.shp}.cpg" ]]; then
    echo "    .cpg:     $(tr -d '\r\n' < "${ROADS_SHP%.shp}.cpg")"
  fi
  ogrinfo -so -al "$BOUNDARY" | head -n 25

  # Clip in QGIS-equivalent way, but keep UTF-8 names (SHAPE_ENCODING from .cpg / UTF-8).
  export SHAPE_ENCODING="${SHAPE_ENCODING:-UTF-8}"
  ogr2ogr \
    -f "ESRI Shapefile" \
    "$WORK/riyadh_roads_utf8.shp" \
    "$ROADS_SHP" \
    -clipsrc "$BOUNDARY" \
    -nlt MULTILINESTRING \
    -t_srs EPSG:4326 \
    -lco ENCODING=UTF-8 \
    --config SHAPE_ENCODING UTF-8
  SHP="$WORK/riyadh_roads_utf8.shp"
elif [[ -n "${SHP_ZIP:-}" || -f /backups/riyadh_roads.zip ]]; then
  SOURCE_MODE="zip"
  SHP_ZIP="${SHP_ZIP:-/backups/riyadh_roads.zip}"
  echo "==> Mode: fallback zip import ($SHP_ZIP)"
  echo "    WARNING: if this zip was exported as Windows-1252, Arabic labels will be corrupted."
  unzip -qo "$SHP_ZIP" -d "$WORK"
  SHP="$(find "$WORK" -iname '*.shp' | head -n 1)"
  [[ -n "$SHP" ]] || { echo "ERROR: no .shp inside $SHP_ZIP" >&2; exit 1; }
  if [[ -f "${SHP%.shp}.cpg" ]]; then
    cpg="$(tr -d '\r\n' < "${SHP%.shp}.cpg")"
    echo "    .cpg: $cpg"
    if [[ "$cpg" == "1252" || "$cpg" == "CP1252" ]]; then
      echo "ERROR: source shapefile encoding is Windows-1252 — Arabic names are already lost." >&2
      echo "       Provide Geofabrik UTF-8 roads + riyadh_governorate.geojson under /backups/." >&2
      exit 1
    fi
    export SHAPE_ENCODING="$cpg"
  else
    export SHAPE_ENCODING=UTF-8
  fi
else
  echo "ERROR: need either:" >&2
  echo "  1) $ROADS_SHP + $BOUNDARY" >&2
  echo "  2) /backups/riyadh_roads.zip (UTF-8)" >&2
  exit 1
fi

echo "==> Source shp: $SHP"
ogrinfo -so -al "$SHP" | head -n 50

echo "==> Loading staging $STAGING via ogr2ogr → EPSG:3857"
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
  -t_srs EPSG:3857 \
  -overwrite \
  --config PG_USE_COPY YES \
  --config SHAPE_ENCODING "${SHAPE_ENCODING:-UTF-8}"

echo "==> Normalising optional columns"
psql -v ON_ERROR_STOP=1 -U postgres -d riyadh_roads <<SQL
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS osm_id text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS code double precision;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS fclass text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS highway text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS name text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS ref text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS oneway text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS maxspeed text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS layer text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS bridge text;
ALTER TABLE $STAGING ADD COLUMN IF NOT EXISTS tunnel text;
SQL

echo "==> Creating $TARGET (riyadh_roads DB only) with bilingual name split"

DROP_SQL=""
if [[ "$REPLACE" == "1" ]]; then
  DROP_SQL="DROP TABLE IF EXISTS $TARGET CASCADE;"
fi

psql -v ON_ERROR_STOP=1 -U postgres -d riyadh_roads <<SQL
BEGIN;

$DROP_SQL

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

INSERT INTO $TARGET (
  id, objectid, osm_id, code, fclass, name, name_en, name_ar,
  ref, oneway, maxspeed, layer, bridge, tunnel, shape_leng, geom, road_closure
)
SELECT
  ROW_NUMBER() OVER (ORDER BY s.ogc_fid)::double precision AS id,
  NULL::numeric AS objectid,
  LEFT(NULLIF(TRIM(s.osm_id::text), ''), 12) AS osm_id,
  CASE
    WHEN NULLIF(regexp_replace(COALESCE(s.code::text, ''), '[^0-9.]', '', 'g'), '') IS NULL
      THEN NULL
    ELSE NULLIF(regexp_replace(s.code::text, '[^0-9.]', '', 'g'), '')::double precision
  END AS code,
  LEFT(
    LOWER(
      COALESCE(
        NULLIF(TRIM(s.fclass::text), ''),
        NULLIF(TRIM(s.highway::text), ''),
        'unclassified'
      )
    ),
    28
  ) AS fclass,
  LEFT(NULLIF(TRIM(s.name::text), ''), 100) AS name,
  -- Latin / non-Arabic primary name → English label field
  -- Arabic detection: main Arabic block + supplements (PostGIS POSIX, UTF-8 literals).
  CASE
    WHEN NULLIF(TRIM(s.name::text), '') IS NULL THEN NULL
    WHEN NULLIF(TRIM(s.name::text), '') ~ '[؀-ۿݐ-ݿࢠ-ࣿ]'
         AND NULLIF(TRIM(s.name::text), '') !~ '[A-Za-z]' THEN NULL
    ELSE NULLIF(TRIM(s.name::text), '')
  END AS name_en,
  -- Arabic script → Arabic label field (GeoTrak bilingual labels)
  CASE
    WHEN NULLIF(TRIM(s.name::text), '') IS NULL THEN NULL
    WHEN NULLIF(TRIM(s.name::text), '') ~ '[؀-ۿݐ-ݿࢠ-ࣿ]'
      THEN NULLIF(TRIM(s.name::text), '')
    ELSE NULL
  END AS name_ar,
  LEFT(NULLIF(TRIM(s.ref::text), ''), 20) AS ref,
  LEFT(NULLIF(TRIM(s.oneway::text), ''), 1) AS oneway,
  CASE
    WHEN NULLIF(regexp_replace(COALESCE(s.maxspeed::text, ''), '[^0-9.]', '', 'g'), '') IS NULL
      THEN NULL
    ELSE NULLIF(regexp_replace(s.maxspeed::text, '[^0-9.]', '', 'g'), '')::double precision
  END AS maxspeed,
  CASE
    WHEN NULLIF(regexp_replace(COALESCE(s.layer::text, ''), '[^0-9.-]', '', 'g'), '') IS NULL
      THEN NULL
    ELSE NULLIF(regexp_replace(s.layer::text, '[^0-9.-]', '', 'g'), '')::numeric
  END AS layer,
  LEFT(NULLIF(TRIM(s.bridge::text), ''), 1) AS bridge,
  LEFT(NULLIF(TRIM(s.tunnel::text), ''), 1) AS tunnel,
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

COMMIT;

SELECT COUNT(*) AS road_count,
       COUNT(*) FILTER (WHERE name_en IS NOT NULL AND name_en <> '') AS named_en,
       COUNT(*) FILTER (WHERE name_ar IS NOT NULL AND name_ar <> '') AS named_ar,
       COUNT(*) FILTER (WHERE name IS NOT NULL AND name ~ '\?') AS looks_corrupted,
       COUNT(DISTINCT fclass) AS fclass_count,
       ROUND(ST_XMin(ST_Extent(ST_Transform(geom, 4326)))::numeric, 4) AS lon_min,
       ROUND(ST_YMin(ST_Extent(ST_Transform(geom, 4326)))::numeric, 4) AS lat_min,
       ROUND(ST_XMax(ST_Extent(ST_Transform(geom, 4326)))::numeric, 4) AS lon_max,
       ROUND(ST_YMax(ST_Extent(ST_Transform(geom, 4326)))::numeric, 4) AS lat_max
FROM $TARGET;

SELECT fclass, COUNT(*) AS n
FROM $TARGET
GROUP BY fclass
ORDER BY n DESC
LIMIT 15;

SELECT gid, name, name_en, name_ar, fclass
FROM $TARGET
WHERE name_ar IS NOT NULL
LIMIT 5;
SQL

echo "==> Applying geotrak_user + martin_reader grants"
bash /scripts/grant-martin-read.sh

# Also write a fresh UTF-8 zip for optional re-use / GeoLayers (not committed).
if [[ "$SOURCE_MODE" == "clip" && -f "$WORK/riyadh_roads_utf8.shp" ]]; then
  echo "==> Writing UTF-8 shapefile zip → /backups/riyadh_roads.zip"
  rm -rf /tmp/riyadh_roads_zip_out
  mkdir -p /tmp/riyadh_roads_zip_out/riyadh_roads
  cp "$WORK"/riyadh_roads_utf8.* /tmp/riyadh_roads_zip_out/riyadh_roads/
  # Normalise basenames inside zip
  (
    cd /tmp/riyadh_roads_zip_out/riyadh_roads
    for f in riyadh_roads_utf8.*; do
      mv "$f" "riyadh_roads.${f#riyadh_roads_utf8.}"
    done
    printf 'UTF-8' > riyadh_roads.cpg
  )
  (
    cd /tmp/riyadh_roads_zip_out
    rm -f /backups/riyadh_roads.zip
    zip -qr /backups/riyadh_roads.zip riyadh_roads
  )
  ls -lh /backups/riyadh_roads.zip
fi

if [[ "$MAKE_DUMP" == "1" ]]; then
  echo "==> Writing custom-format dump → $DUMP_OUT"
  pg_dump -U postgres -d riyadh_roads -Fc \
    --table=public.riyadh_roads \
    --no-owner --no-acl \
    -f "$DUMP_OUT"
  ls -lh "$DUMP_OUT"
  echo "Restore later with:"
  echo "  docker compose exec -T postgis pg_restore -U postgres -d riyadh_roads --clean --if-exists --no-owner --no-acl /backups/$(basename "$DUMP_OUT")"
  echo "  docker compose exec postgis bash /scripts/grant-martin-read.sh"
  echo "  docker compose restart martin"
fi

echo "==> Done (mode=$SOURCE_MODE). Restart Martin:"
echo "  docker compose restart martin"
