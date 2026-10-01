#!/usr/bin/env python3
"""
End-to-end smoke test against the RUNNING stack (Nginx -> Django auth -> Martin).

    python3 smoke_test.py --fixtures .fixtures.json \
        --geotrak http://localhost:8000 --geolayers http://localhost:8081

run_all.sh creates the fixtures and runs this inside a container on geo_shared.
Exit code 0 = all checks passed.
"""
import argparse
import json
import sys
import unittest

from geotest import (
    Config,
    Http,
    add_common_args,
    center_tile,
    login_geolayers,
    login_geotrak,
)

CFG: Config = None  # set in main()
OK_TILE = (200, 204)  # Martin answers 204 for an empty tile


def tile_path(z, x, y):
    return f"{z}/{x}/{y}"


class GeoTrakTiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = Http(host_header=CFG.host_header)
        cls.fx = CFG.fixtures["geotrak"]
        cls.session = login_geotrak(cls.http, CFG)
        cls.tile = f"{CFG.geotrak}/tiles/{cls.fx['layer']}/{tile_path(*center_tile(z=13))}"

    def test_app_is_served(self):
        self.assertEqual(self.http.get(f"{CFG.geotrak}/login/").status, 200)

    def test_token_in_query(self):
        res = self.http.get(f"{self.tile}?token={self.fx['token']}")
        self.assertIn(res.status, OK_TILE)
        self.assertIn("no-store", res.header("cache-control"))
        self.assertEqual(res.header("access-control-allow-origin"), "*")
        self.assertIsNotNone(res.timing("X-Timing-Auth"), "Nginx timing header missing")

    def test_token_in_bearer_and_custom_header(self):
        self.assertIn(self.http.get(self.tile, {"Authorization": f"Bearer {self.fx['token']}"}).status, OK_TILE)
        self.assertIn(self.http.get(self.tile, {"X-Tile-Token": self.fx["token"]}).status, OK_TILE)

    def test_bad_token_is_403_even_on_public_layer(self):
        self.assertEqual(self.http.get(f"{self.tile}?token=gtk_definitely_not_valid").status, 403)

    def test_session_cookie(self):
        res = self.http.get(self.tile, {"Cookie": f"geotrak_sessionid={self.session}"})
        self.assertIn(res.status, OK_TILE)

    def test_no_credentials(self):
        expected = OK_TILE if self.fx.get("layer_allows_anonymous") else (401,)
        self.assertIn(self.http.get(self.tile).status, expected)

    def test_unregistered_martin_source_is_refused(self):
        res = self.http.get(f"{CFG.geotrak}/tiles/geolayers_tile/0/0/0?token={self.fx['token']}")
        self.assertEqual(res.status, 403)

    def test_internal_paths_not_exposed(self):
        self.assertEqual(self.http.get(f"{CFG.geotrak}/tiles/catalog").status, 404)
        self.assertEqual(self.http.get(f"{CFG.geotrak}/tiles-auth/validate/").status, 404)

    def test_cors_preflight(self):
        res = self.http.request("OPTIONS", self.tile, {"Origin": "https://partner.example",
                                                      "Access-Control-Request-Headers": "authorization"})
        self.assertEqual(res.status, 204)
        self.assertIn("Authorization", res.header("access-control-allow-headers"))


class GeoLayersTiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = Http(host_header=CFG.host_header)
        cls.fx = CFG.fixtures["geolayers"]
        cls.session, cls.jwt = login_geolayers(cls.http, CFG)
        # Zoom 13 tile at the centre of the fixture's random points: always has features.
        z, x, y = center_tile(cls.fx["bounds"], z=13)
        cls.zxy = tile_path(z, x, y)
        cls.tile = f"{CFG.geolayers}/tiles/geolayers_tile/{cls.zxy}?layer={cls.fx['layer_table']}"
        cls.share = f"{CFG.geolayers}/x/{cls.fx['share_token']}/{cls.zxy}.pbf"

    def test_anonymous_needs_sign_in(self):
        self.assertEqual(self.http.get(self.tile).status, 401)

    def test_owner_session_gets_real_features(self):
        res = self.http.get(self.tile, {"Cookie": f"geolayers_sessionid={self.session}"})
        self.assertEqual(res.status, 200)
        self.assertIn(self.fx["layer_table"].encode(), res.body)  # MVT layer name
        self.assertIn("private", res.header("cache-control"))

    def test_owner_jwt(self):
        self.assertEqual(self.http.get(self.tile, {"Authorization": f"Bearer {self.jwt}"}).status, 200)

    def test_other_layer_param_is_refused(self):
        other = f"{CFG.geolayers}/tiles/geolayers_tile/{self.zxy}?layer=layer_{'0' * 32}"
        self.assertEqual(self.http.get(other, {"Authorization": f"Bearer {self.jwt}"}).status, 403)

    def test_share_link_public(self):
        res = self.http.get(self.share)
        self.assertEqual(res.status, 200)
        self.assertIn("max-age=60", res.header("cache-control"))
        self.assertEqual(res.header("access-control-allow-origin"), "*")

    def test_unknown_share_link_is_404(self):
        self.assertEqual(self.http.get(f"{CFG.geolayers}/x/not-a-real-token/{self.zxy}.pbf").status, 404)

    def test_geotrak_source_not_exposed_here(self):
        self.assertEqual(self.http.get(f"{CFG.geolayers}/tiles/riyadh_roads/0/0/0").status, 404)
        self.assertEqual(self.http.get(f"{CFG.geolayers}/tiles-auth/validate/").status, 404)

    def test_create_use_revoke_share_link_end_to_end(self):
        auth = {"Authorization": f"Bearer {self.jwt}"}
        api = f"{CFG.geolayers}/api/layers/{self.fx['layer_id']}/share-links/"
        created = self.http.post_json(api, {"expires_at": "2099-01-01T00:00:00Z"}, auth)
        self.assertEqual(created.status, 201, created.body[:300])
        link = json.loads(created.body)
        url = f"{CFG.geolayers}/x/{link['token']}/{self.zxy}.pbf"

        self.assertEqual(self.http.get(url).status, 200)
        listed = json.loads(self.http.get(api, auth).body)
        self.assertGreaterEqual(next(l for l in listed if l["id"] == link["id"])["total_requests"], 1)

        self.assertEqual(self.http.request("DELETE", f"{api}{link['id']}/", auth).status, 204)
        self.assertEqual(self.http.get(url).status, 404, "revoked link must stop on the next tile")


class MartinDirect(unittest.TestCase):
    """Optional: only when --martin is given (runs inside the geo_shared network)."""

    def setUp(self):
        if not CFG.martin:
            self.skipTest("no --martin URL")
        self.http = Http()

    def test_martin_serves_both_databases(self):
        z, x, y = center_tile(z=13)
        self.assertIn(self.http.get(f"{CFG.martin}/riyadh_roads/{z}/{x}/{y}").status, OK_TILE)
        fx = CFG.fixtures["geolayers"]
        z, x, y = center_tile(fx["bounds"], z=13)
        self.assertEqual(self.http.get(f"{CFG.martin}/geolayers_tile/{z}/{x}/{y}?layer={fx['layer_table']}").status, 200)


def main():
    global CFG
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    add_common_args(parser)
    args, rest = parser.parse_known_args()
    CFG = Config.from_args(args)
    result = unittest.main(argv=[sys.argv[0], "-v", *rest], exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
