#!/bin/bash
# Runs ONCE, on the first start of an empty postgres_data volume.
#
# Databases (one instance):
#   geotrak       GeoTrak Maps app data          owner: geotrak_user
#   riyadh_roads  Riyadh road network (MVT src)  owner: geotrak_user   (GeoTrak edits it)
#   geolayers     GeoLayers app data + layers    owner: geolayers_user
#
# martin_reader is a read-only login used by Martin. It can only SELECT.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
  -v geotrak_pw="$GEOTRAK_DB_PASSWORD" \
  -v geolayers_pw="$GEOLAYERS_DB_PASSWORD" \
  -v martin_pw="$MARTIN_DB_PASSWORD" <<'SQL'
CREATE ROLE geotrak_user   LOGIN PASSWORD :'geotrak_pw';
CREATE ROLE geolayers_user LOGIN PASSWORD :'geolayers_pw';
CREATE ROLE martin_reader  LOGIN PASSWORD :'martin_pw';

CREATE DATABASE geotrak      OWNER geotrak_user;
CREATE DATABASE riyadh_roads OWNER geotrak_user;
CREATE DATABASE geolayers    OWNER geolayers_user;

-- Apps must not be able to reach each other's databases.
REVOKE CONNECT ON DATABASE geotrak, riyadh_roads, geolayers FROM PUBLIC;
GRANT  CONNECT ON DATABASE geotrak      TO geotrak_user;
GRANT  CONNECT ON DATABASE riyadh_roads TO geotrak_user, martin_reader;
GRANT  CONNECT ON DATABASE geolayers    TO geolayers_user, martin_reader;
SQL

for db in geotrak riyadh_roads geolayers; do
  psql -v ON_ERROR_STOP=1 --username postgres --dbname "$db" \
    -c "CREATE EXTENSION IF NOT EXISTS postgis;"
done

# riyadh_roads: Martin reads every table GeoTrak owns, now and in the future.
psql -v ON_ERROR_STOP=1 --username postgres --dbname riyadh_roads <<'SQL'
GRANT USAGE ON SCHEMA public TO martin_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO martin_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE geotrak_user IN SCHEMA public
  GRANT SELECT ON TABLES TO martin_reader;
SQL

# geolayers: uploaded shapefiles become layers_data.layer_<uuid> tables
# (created by geolayers_user via ogr2ogr). Martin needs SELECT on them so the
# layers_data.geolayers_tile() function (a GeoLayers migration) can read them.
psql -v ON_ERROR_STOP=1 --username postgres --dbname geolayers <<'SQL'
CREATE SCHEMA IF NOT EXISTS layers_data AUTHORIZATION geolayers_user;
GRANT USAGE ON SCHEMA layers_data TO martin_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA layers_data TO martin_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE geolayers_user IN SCHEMA layers_data
  GRANT SELECT ON TABLES TO martin_reader;
SQL

echo "geo-infra: databases geotrak, riyadh_roads, geolayers initialised."
