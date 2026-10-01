#!/bin/bash
# Re-apply Martin's read-only grants. Safe to run any number of times.
# Run it after restoring a dump, because restored tables don't inherit default privileges:
#   docker compose exec postgis bash /scripts/grant-martin-read.sh
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres --dbname riyadh_roads <<'SQL'
GRANT USAGE ON SCHEMA public TO martin_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO martin_reader;
SQL

psql -v ON_ERROR_STOP=1 --username postgres --dbname geolayers <<'SQL'
CREATE SCHEMA IF NOT EXISTS layers_data AUTHORIZATION geolayers_user;
GRANT USAGE ON SCHEMA layers_data TO martin_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA layers_data TO martin_reader;
SQL

echo "martin_reader grants refreshed."
