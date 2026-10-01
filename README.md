# geo-infra: shared PostGIS, Martin and Nginx

This is the shared infrastructure for two independent Django projects:

| Project | Repo folder | Public port | Database(s) |
|---|---|---|---|
| GeoTrak Maps | `../naqel-mapserver` | **:8000** | `geotrak`, `riyadh_roads` |
| GeoLayers | `../layeruploading_martintileserver` | **:8081** | `geolayers` |

```
                    ┌──────────────────────────── geo-nginx ───────────────────────────┐
 browser / QGIS ──► │ :8000 /tiles/<src>/z/x/y ─ auth_request ─► geotrak_web /tiles-auth/ │
                    │         └─ 204 ─────────────────────────► martin                  │
                    │       /*  ──────────────────────────────► geotrak_web:8000        │
                    │ :8081 /tiles/geolayers_tile/... ┐                                 │
                    │       /x/<share-token>/...      ┴ auth_request ► geolayers_web     │
                    │         └─ 204 + X-Tile-Layer ──────────► martin                  │
                    │       /*  ──────────────────────────────► geolayers_web:8000      │
                    └──────────────────────────────────────────────────────────────────┘
                                         geo-martin ──(martin_reader, read-only)──┐
 geotrak_web ──(geotrak_user)──► geo-postgis: geotrak, riyadh_roads ◄─────────────┤
 geolayers_web ─(geolayers_user)► geo-postgis: geolayers ◄────────────────────────┘
```

* **One Postgres instance, three databases, three login roles.** Each app can only
  connect to its own databases. Martin uses `martin_reader`, which has `SELECT` only.
* **One Martin.** It is not published on the host. Nginx is the only way in, and each
  port exposes only its own sources: `:8081` can never serve `riyadh_roads`.
* **GeoTrak tiles use `auth_request`.** For every tile, Nginx asks Django
  (`tile_access.views.validate_tile_request`) whether the request may proceed.
  * API tokens: stored hashed, revocable (effective on the next tile), optionally
    expiring, limited to specific layers, with usage counted per day.
  * Session cookie: signed-in GeoTrak admins, managers and editors (the web map).
  * Anonymous: only for layers flagged `allow_anonymous_access`. `riyadh_roads` starts
    with this **on** so the public landing page keeps working. See *Lock down*.
* **GeoLayers tiles also use `auth_request`** (`apps.layers.tile_auth.validate_tile_request`):
  * `/tiles/geolayers_tile/...?layer=`: the map builder. Only the layer's owner,
    users it is shared with, and superusers (session cookie or `Bearer` JWT) get through.
  * `/x/<share-token>/{z}/{x}/{y}.pbf`: the **Share → XYZ link** URLs. Anyone with
    the link gets through until it expires, is blocked by an admin, or is revoked
    (effective on the next tile). Each link's tile requests are counted per day,
    and the count is shown in the Share dialog and the admin.
  * Django replies with the table to serve (`X-Tile-Layer`), and Nginx always uses
    that value. A client can't swap `?layer=` to read another layer, so knowing a
    table name grants nothing.
  * Tiles go Nginx → Martin directly. Django only answers the small yes/no
    subrequest, instead of proxying every tile body as it used to.
* **GeoLayers uses one Martin function source** (`layers_data.geolayers_tile`,
  created by migration `layers.0003`). New uploads are servable immediately, so the
  old Martin restart through `docker.sock` is gone. That restart would have
  interrupted GeoTrak's tiles too.
* The Martin tile cache is **off** (`cache_size_mb: 0`), because GeoTrak edits must
  show on the next tile reload.

## First-time setup

```bash
cd geo-infra
cp .env.example .env          # fill in every secret
docker compose up -d          # postgis + martin + nginx, creates network geo_shared
```

Make each app's `.env` match `geo-infra/.env`:

| geo-infra `.env` | GeoTrak `.env` | GeoLayers `.env` |
|---|---|---|
| `GEOTRAK_DB_PASSWORD` | `DB_PASSWORD`, `RIYADH_ROADS_DB_PASSWORD` | – |
| `GEOLAYERS_DB_PASSWORD` | – | password inside `DATABASE_URL` |
| `TILE_AUTH_SHARED_SECRET` | `TILE_AUTH_SHARED_SECRET` | – |
| `GEOLAYERS_TILE_AUTH_SHARED_SECRET` | – | `TILE_AUTH_SHARED_SECRET` |

See each project's `.env.example`. The key changes are:
* GeoTrak: `DB_HOST=postgis`, `DB_NAME=geotrak`, `DB_USER=geotrak_user`,
  `RIYADH_ROADS_DB_*` → `postgis` / `riyadh_roads` / `geotrak_user`. Add
  `TILE_AUTH_SHARED_SECRET`, and remove the old `RIYADH_ROADS_TILE_URL`.
* GeoLayers: `DATABASE_URL=postgis://geolayers_user:<pw>@postgis:5432/geolayers`,
  `TILES_PUBLIC_URL=/tiles`. Remove `MARTIN_TILE_SERVER_URL` and `MARTIN_DOCKER_CONTAINER`.

Then start the apps. Both run their migrations on start:

```bash
cd ../naqel-mapserver && docker compose up -d --build
cd ../layeruploading_martintileserver && docker compose -f docker-compose.prod.yml up -d --build
# Martin loads the geolayers_tile function at startup. After GeoLayers' FIRST migrate:
cd ../geo-infra && docker compose restart martin
```

## Moving existing data in (one-off)

Take the dumps **before** stopping the old stacks. The old compose files no longer
define `db` services, so use the container names directly.

```bash
mkdir -p geo-infra/backups && cd geo-infra

# 1. GeoTrak app DB (old container: geotrak_maps_db)
docker exec geotrak_maps_db pg_dump -U <old DB_USER> -Fc <old DB_NAME> > backups/geotrak.dump

# 2. Riyadh roads (old external server; pg_dump must be >= the server's major version)
pg_dump -h <old riyadh host> -U <old riyadh user> -Fc <old riyadh db> > backups/riyadh_roads.dump

# 3. GeoLayers (old prod container: geolayers-db-1)
docker exec geolayers-db-1 pg_dump -U gis_user -Fc gis_app > backups/geolayers.dump

# Stop the old stacks (frees ports 8000/8001/3000/3002/5435. The old GeoTrak app used host port 8000, which Nginx now takes), then start geo-infra (above).

# Restore. "extension postgis already exists" messages are expected and harmless.
docker compose exec -T postgis pg_restore -U postgres -d geotrak      --no-owner --role=geotrak_user   < backups/geotrak.dump
docker compose exec -T postgis pg_restore -U postgres -d riyadh_roads --no-owner --role=geotrak_user   < backups/riyadh_roads.dump
docker compose exec -T postgis pg_restore -U postgres -d geolayers    --no-owner --role=geolayers_user < backups/geolayers.dump

# Restored tables don't inherit default privileges: re-grant Martin read access.
docker compose exec postgis bash /scripts/grant-martin-read.sh
docker compose restart martin
```

The GeoTrak dump comes from PostgreSQL 18, so the shared instance is also 18.
A dump can't be restored into an older server.

## GeoTrak tile tokens

Run these inside the GeoTrak container (`docker compose exec geotrak_maps ...`):

```bash
python manage.py tile_tokens layers
python manage.py tile_tokens create --name "QGIS – Ops" --layers riyadh_roads --days 90 --created-by admin@example.com
python manage.py tile_tokens list            # add --all for revoked/expired
python manage.py tile_tokens revoke gtk_AbCd1234
python manage.py tile_tokens usage --days 30
python manage.py tile_tokens add-layer my_new_table --name "My layer"   # any Martin source id
```

Clients send the token in one of three ways. Use the header form where possible,
because it keeps the token out of URLs:

```
http://<host>:8000/tiles/riyadh_roads/{z}/{x}/{y}?token=gtk_...
Authorization: Bearer gtk_...
X-Tile-Token: gtk_...
```

The token is shown **once**. Only its SHA-256 hash is stored. Nginx logs tile
requests (to `docker logs geo-nginx`) with only the token's public prefix. Its
access logs never include query strings, and share-link tokens in `/x/<token>/` paths are masked.

### Lock down `riyadh_roads`

While `allow_anonymous_access` is on, anyone can fetch the roads tiles without a
token. This matches the old public Django proxy. Revoking a token then only
stops *that token* from being used; the client can still drop it and load
tiles anonymously. To require a token or a signed-in session:

```bash
python manage.py tile_tokens set-layer riyadh_roads --no-anonymous
```

The public landing page (`/`) will then show the basemap without the roads layer.
Companion clients that poll `/mapping/api/riyadh-roads-map-sync/` will need a token.

## Tests, latency and load

See [tests/README.md](tests/README.md). In short: `bash tests/run_all.sh [--load]` on the
Docker host runs config checks, both apps' unit tests, an end-to-end smoke test, a latency
probe (auth vs Martin vs network split) and an optional k6 load test.

## Verify

```bash
curl -si http://localhost:8000/tiles/riyadh_roads/10/690/430 | head -1        # 200/204 (anonymous on) or 401
curl -si "http://localhost:8000/tiles/riyadh_roads/10/690/430?token=gtk_bad" | head -1   # 403
curl -si http://localhost:8000/tiles/catalog | head -1                        # 404 (catalog never exposed)
curl -si http://localhost:8000/tiles-auth/validate/ | head -1                 # 404 (internal only)
curl -si http://localhost:8081/tiles/riyadh_roads/10/690/430 | head -1   # 404 (not exposed on GeoLayers port)
curl -si "http://localhost:8081/tiles/geolayers_tile/0/0/0?layer=layer_<hex>" | head -1  # 401 (sign-in required)
curl -si http://localhost:8081/x/<share-token>/0/0/0.pbf | head -1        # 200 (valid share link)
curl -si http://localhost:8081/x/not-a-token/0/0/0.pbf | head -1          # 404; expired -> 410, blocked -> 403

docker compose -f ../naqel-mapserver/docker-compose.yml exec geotrak_maps python manage.py makemigrations --check --dry-run
docker compose -f ../naqel-mapserver/docker-compose.yml exec geotrak_maps python manage.py test tile_access mapping
docker compose -f ../layeruploading_martintileserver/docker-compose.prod.yml exec web python manage.py test apps.layers
```

## Operations notes

* **Firewall:** only 8000 and 8081 (later 443) should be open. Postgres is bound to
  `127.0.0.1:5432`. Use an SSH tunnel, or `docker compose --profile tools up -d pgadmin`
  for pgAdmin on `127.0.0.1:5050`.
* **Connections:** with the defaults, GeoTrak opens at most 3 workers × 4 threads × 2 DBs = 24
  persistent connections, GeoLayers 2 × 8 = 16, and Martin 2 pools × 5 = 10. That is ~50 of
  Postgres' default `max_connections=100`. If you raise workers or threads, raise that too.
* **Auth cost:** every GeoTrak tile is one small Django request: one token lookup or
  session lookup, plus one usage upsert. If tile traffic grows, raise
  `GUNICORN_WORKERS`, or set `TILE_ACCESS_LOG_SESSION_USAGE=False` to stop counting
  web-map tiles.
* **TLS:** add `listen 443 ssl` server blocks (e.g. certbot) in the Nginx templates,
  then set `SECURE_SSL_REDIRECT`, `SESSION_COOKIE_SECURE` and `CSRF_COOKIE_SECURE`
  to `True` in GeoTrak. Both apps already trust `X-Forwarded-Proto` from Nginx.
* **Backups:** `docker compose exec postgis pg_dump -U postgres -Fc <db> > backups/<db>-$(date +%F).dump`
  for each of `geotrak`, `riyadh_roads` and `geolayers`.
