#!/bin/bash
# Re-apply DB grants after a dump restore (restores with --no-acl drop grants).
# Safe to run any number of times:
#   docker compose exec postgis bash /scripts/grant-martin-read.sh
#
#   riyadh_roads: geotrak_user (read/write) + martin_reader (read)
#   geolayers:    martin_reader (read) on layers_data
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres --dbname riyadh_roads <<'SQL'
GRANT USAGE ON SCHEMA public TO geotrak_user, martin_reader;

ALTER TABLE IF EXISTS public.riyadh_roads OWNER TO geotrak_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO geotrak_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO martin_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO geotrak_user;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'riyadh_roads_gid_seq'
  ) THEN
    ALTER SEQUENCE public.riyadh_roads_gid_seq OWNER TO geotrak_user;
  END IF;
END $$;
SQL

psql -v ON_ERROR_STOP=1 --username postgres --dbname geolayers <<'SQL'
CREATE SCHEMA IF NOT EXISTS layers_data AUTHORIZATION geolayers_user;
GRANT USAGE ON SCHEMA layers_data TO martin_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA layers_data TO martin_reader;
DO $$
BEGIN
  IF to_regprocedure('layers_data.geolayers_tile(integer, integer, integer, json)') IS NOT NULL THEN
    GRANT EXECUTE ON FUNCTION layers_data.geolayers_tile(integer, integer, integer, json) TO martin_reader;
  END IF;
END $$;
SQL

echo "riyadh_roads (geotrak_user + martin_reader) and geolayers (martin_reader) grants refreshed."
