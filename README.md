# geo-infra: shared PostGIS, Martin and Nginx

Shared infrastructure for two independent Django projects:

| Project | Repo folder | Public port | Database(s) |
|---|---|---|---|
| GeoTrak Maps | `../geotrak-maps` | **:8000** | `geotrak`, `riyadh_roads` |
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
  connect to its own databases. Martin uses `martin_reader` (SELECT / EXECUTE only).
* **One Martin.** Not published on the host. Nginx is the only way in; each port
  exposes only its own sources (`:8081` can never serve `riyadh_roads`).
* **Tile auth via Nginx `auth_request`.** Django answers yes/no; tile bodies go
  Nginx → Martin. GeoTrak uses session / API tokens; GeoLayers uses session / JWT
  or XYZ share-link tokens (`/x/<token>/…`).
* **GeoLayers Martin function** `layers_data.geolayers_tile` (migration `layers.0003`)
  serves any `layer_<uuid>` via `?layer=` — no Martin restart on upload.
* Martin tile cache is **off** so GeoTrak edits appear on the next tile reload.

## First-time setup

```bash
# 1. Shared infra (creates network geo_shared)
cd geo_infra
# Use .env for local, or copy .env.prod → .env on the VPS
docker compose up -d

# 2. Apps (secrets in each app's .env must match geo_infra/.env)
cd ../geotrak-maps && docker compose -f docker-compose.prod.yml up -d --build
cd ../layeruploading_martintileserver && docker compose -f docker-compose.prod.yml up -d --build

# 3. After GeoLayers' FIRST migrate (creates geolayers_tile):
cd ../geo_infra && docker compose restart martin
```

Local development (bind-mount source) uses `docker-compose.yml` in each app instead of
`docker-compose.prod.yml`.

### Secret alignment

| geo-infra `.env` | GeoTrak `.env` | GeoLayers `.env` |
|---|---|---|
| `GEOTRAK_DB_PASSWORD` | `DB_PASSWORD`, `RIYADH_ROADS_DB_PASSWORD` | – |
| `GEOLAYERS_DB_PASSWORD` | – | password inside `DATABASE_URL` |
| `TILE_AUTH_SHARED_SECRET` | `TILE_AUTH_SHARED_SECRET` | – |
| `GEOLAYERS_TILE_AUTH_SHARED_SECRET` | – | `TILE_AUTH_SHARED_SECRET` |

Environment files:
* **`.env`** — local development (gitignored)
* **`.env.prod`** — production values; copy to the VPS as `.env` (gitignored)

## GeoTrak tile tokens

```bash
docker compose -f ../geotrak-maps/docker-compose.prod.yml exec geotrak_maps \
  python manage.py tile_tokens create --name "QGIS – Ops" --layers riyadh_roads --days 90
```

Clients send the token as `?token=`, `Authorization: Bearer gtk_…`, or `X-Tile-Token`.

To require auth on roads tiles (disable anonymous):

```bash
python manage.py tile_tokens set-layer riyadh_roads --no-anonymous
```

## Tests

See [tests/README.md](tests/README.md). On the Docker host:

```bash
bash tests/run_all.sh [--load]
```

## Verify

```bash
curl -si http://localhost:8000/tiles/riyadh_roads/10/690/430 | head -1
curl -si http://localhost:8000/tiles/catalog | head -1                        # 404
curl -si http://localhost:8081/tiles/riyadh_roads/10/690/430 | head -1         # 404
curl -si "http://localhost:8081/tiles/geolayers_tile/0/0/0?layer=layer_<hex>" | head -1
```

## Operations

* **Firewall:** only **8000** and **8081** (later 443). Postgres is `127.0.0.1:5432`.
* **pgAdmin:** `docker compose --profile tools up -d pgadmin` → `127.0.0.1:5050` (SSH tunnel on VPS).
* **Backups:**  
  `docker compose exec postgis pg_dump -U postgres -Fc <db> > backups/<db>-$(date +%F).dump`  
  for `geotrak`, `riyadh_roads`, `geolayers`. After restore:  
  `docker compose exec postgis bash /scripts/grant-martin-read.sh`
* **TLS (later):** add SSL in Nginx templates, then set `SECURE_SSL_REDIRECT`,
  `SESSION_COOKIE_SECURE`, `CSRF_COOKIE_SECURE` to `True` in both apps.
