"""Tests for earth-addons/cz-terrain/cz_terrain.py: python -m unittest discover -s tests -p cz_terrain_test.py"""
import io
import json
import os
import sys
import tempfile
import time
import unittest

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "earth-addons", "cz-terrain"))
import cz_terrain as cz  # noqa: E402


def tiff(a):
    buf = io.BytesIO()
    Image.fromarray(np.asarray(a, np.float32), "F").save(buf, "TIFF")
    return buf.getvalue()


class Fake(cz.Sources):
    def __init__(self, cuzk=None, mt=None, mt_list=None):
        self.c, self.m, self.l = cuzk or {}, mt or {}, mt_list
        self.calls = []

    def cuzk(self, z, x, y):
        self.calls.append(("cuzk", z, x, y))
        return self.c.get((z, x, y), np.full((cz.TILE, cz.TILE), np.nan, np.float32)).copy()

    def mapterhorn(self, z, x, y):
        self.calls.append(("mt", z, x, y))
        return self.m.get((z, x, y))

    def mapterhorn_list(self):
        if self.l is None:
            raise OSError("offline")
        return self.l


class TileMaths(unittest.TestCase):
    def test_prague(self):
        self.assertEqual(cz.tile_xy(50.0875, 14.4213, 15), (17696, 11100))
        lat, lon = cz.tile_latlon(15, 17696, 11100)
        self.assertAlmostEqual(lat, 50.0875, delta=0.01)
        self.assertAlmostEqual(lon, 14.4213, delta=0.01)

    def test_box_matches_tile(self):
        x0, y0, x1, y1 = cz.tile_box(15, 17696, 11100)
        self.assertAlmostEqual(x1 - x0, cz.WORLD / 2 ** 15, places=6)
        self.assertAlmostEqual(y1 - y0, x1 - x0, places=6)

    def test_around_nearest_first_and_in_czechia(self):
        keys = cz.tiles_around(50.0875, 14.4213, 2500, 15)
        self.assertEqual(keys[0], (15, 17696, 11100))
        self.assertGreater(len(keys), 20)
        self.assertEqual(cz.tiles_around(52.52, 13.40, 2500, 15), [])   # Berlin: outside the box

    def test_coverage_tiles(self):
        self.assertIn((34, 21), cz.coverage_tiles())                      # Prague's z6 tile
        self.assertIn(cz.tile_xy(49.2, 16.6, 6), cz.coverage_tiles())     # Brno


class Terrarium(unittest.TestCase):
    def test_round_trip(self):
        h = np.linspace(-50, 1603.4, cz.TILE * cz.TILE, dtype=np.float32).reshape(cz.TILE, cz.TILE)
        back = cz.image_heights(cz.tile_bytes(h))
        self.assertLess(float(np.abs(back - h).max()), 1 / 256 + 1e-4)

    def test_known_value(self):
        rgb = cz.encode_terrarium(np.array([[0.0, 235.5]]))
        self.assertEqual(rgb[0, 0].tolist(), [128, 0, 0])
        self.assertEqual(rgb[0, 1].tolist(), [128, 235, 128])

    def test_earth_decoder_reads_it(self):
        """BeamNG.Earth's own decode (dem.decode_terrarium, native) when its source is beside this repo."""
        server = os.environ.get("BNE_SERVER_DIR")
        if not server or not os.path.isdir(server):
            self.skipTest("BNE_SERVER_DIR not set")
        sys.path.insert(0, server)
        import dem
        h = (np.random.default_rng(1).random((cz.TILE, cz.TILE)) * 900 + 150).astype(np.float32)
        got = dem.decode_terrarium(cz.tile_bytes(h), 512)
        self.assertLess(float(np.abs(got - h).max()), 1 / 256 + 1e-4)


class Cuzk(unittest.TestCase):
    def test_decode(self):
        a = np.full((cz.TILE, cz.TILE), 250.0, np.float32)
        a[0, 0] = cz.NODATA
        a[1, 1] = 5000
        h = cz.decode_cuzk(tiff(a))
        self.assertTrue(np.isnan(h[0, 0]) and np.isnan(h[1, 1]))
        self.assertEqual(float(h[2, 2]), 250.0)

    def test_decode_deflate(self):
        buf = io.BytesIO()
        Image.fromarray(np.full((cz.TILE, cz.TILE), 412.5, np.float32), "F").save(buf, "TIFF",
                                                                              compression="tiff_adobe_deflate")
        self.assertEqual(float(cz.decode_cuzk(buf.getvalue())[7, 7]), 412.5)

    def test_error_page(self):
        with self.assertRaises(ValueError):
            cz.decode_cuzk(b'{"error":{"code":400}}')

    def test_wrong_size(self):
        with self.assertRaises(ValueError):
            cz.decode_cuzk(tiff(np.zeros((256, 256))))

    def test_url(self):
        u = cz.cuzk_url(15, 17696, 11100)
        self.assertIn("/dmr5g/ImageServer/exportImage?", u)
        self.assertIn("size=512,512", u)
        self.assertIn("bboxSR=3857", u)


class Upsample(unittest.TestCase):
    def test_constant_and_ramp(self):
        p = np.tile(np.arange(cz.TILE, dtype=np.float32), (cz.TILE, 1))
        q = cz.upsample_quadrant(p, 1, 1, 0)        # right half
        self.assertAlmostEqual(float(q[0, 0]), 255.75, places=3)
        self.assertAlmostEqual(float(q[0, -1]), 511.0, places=3)


class Work(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = cz.Cache(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_tile_fills_border_and_forgets_decoded(self):
        key = (15, 17696, 11100)
        c = np.full((cz.TILE, cz.TILE), 300.0, np.float32)
        c[:, :100] = np.nan                         # "outside Czechia"
        parent = np.full((cz.TILE, cz.TILE), 280.0, np.float32)
        src = Fake(cuzk={key: c}, mt={(14, 8848, 5550): parent})
        dec = os.path.join(self.tmp.name, "dem", "decoded", "v4", "g1", "16", str(17696 * 2), f"{11100 * 2}.f32z")
        os.makedirs(os.path.dirname(dec))
        open(dec, "wb").close()
        s = cz.Seeder(self.cache, src)
        self.assertEqual(s.do(key), "written")
        with open(self.cache.tile_path(*key), "rb") as f:
            h = cz.image_heights(f.read())
        self.assertAlmostEqual(float(h[10, 10]), 280.0, places=2)
        self.assertAlmostEqual(float(h[10, 300]), 300.0, places=2)
        self.assertFalse(os.path.exists(dec))
        self.assertEqual(self.cache.state(key), "written")
        self.assertIn(("mt", 15, 17696, 11100), src.calls)      # its own zoom asked first

    def test_outside_is_remembered(self):
        s = cz.Seeder(self.cache, Fake())
        key = (15, 17000, 11000)
        self.assertEqual(s.do(key), "outside")
        self.assertEqual(s.add([key], 0), 0)

    def test_unfillable_hole_leaves_tile_alone(self):
        key = (15, 17696, 11100)
        c = np.full((cz.TILE, cz.TILE), 300.0, np.float32)
        c[5, 5] = np.nan
        s = cz.Seeder(self.cache, Fake(cuzk={key: c}))
        self.assertEqual(s.do(key), "outside")
        self.assertFalse(os.path.exists(self.cache.tile_path(*key)))

    def test_rewrites_when_earth_dropped_it(self):
        key = (15, 17696, 11100)
        s = cz.Seeder(self.cache, Fake(cuzk={key: np.full((cz.TILE, cz.TILE), 1.0, np.float32)}))
        s.do(key)
        os.remove(self.cache.tile_path(*key))
        self.assertIsNone(self.cache.state(key))

    def test_failed_tile_is_retried_then_dropped(self):
        class Down(Fake):
            def cuzk(self, z, x, y):
                raise OSError("down")
        s = cz.Seeder(self.cache, Down())
        key = (15, 17696, 11100)
        s.add([key], 0)
        orig = cz.time.sleep
        cz.time.sleep = lambda t: None
        try:
            import threading
            threading.Thread(target=s.work, daemon=True).start()
            for _ in range(200):
                if not s.queued:
                    break
                orig(0.02)
        finally:
            cz.time.sleep = orig
        self.assertEqual(s.stats["errors"], cz.RETRIES)
        self.assertEqual(s.queued, set())
        self.assertIn("down", s.last_error)

    def test_done_survives_restart(self):
        key = (14, 8848, 5550)
        self.cache.mark(key, "outside")
        self.cache.save_done()
        self.assertEqual(cz.Cache(self.tmp.name).state(key), "outside")

    def test_around_car_queues_ahead(self):
        s = cz.Seeder(self.cache, Fake())
        s.around_car({"lat": 50.0875, "lon": 14.4213, "ve": 30.0, "vn": 0.0})
        first = s.q.get()[2]
        self.assertEqual(first[0], 15)
        self.assertGreaterEqual(first[1], 17696)    # ahead (east) of the car


class List(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = cz.Cache(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def doc(self):
        return {"items": [{"name": "6-34-21.pmtiles", "max_zoom": 14}, {"name": "6-33-21.pmtiles", "max_zoom": 16},
                          {"name": "0-0-0.pmtiles", "max_zoom": 12}]}

    def test_patch(self):
        d, changed = cz.patch_list(self.doc())
        self.assertTrue(changed)
        z = {it["name"]: it["max_zoom"] for it in d["items"]}
        self.assertEqual(z["6-34-21.pmtiles"], 15)
        self.assertEqual(z["6-33-21.pmtiles"], 16)      # Germany's deeper lidar kept
        for x, y in cz.coverage_tiles():
            self.assertGreaterEqual(z[f"6-{x}-{y}.pmtiles"], 15)
        self.assertFalse(cz.patch_list(d)[1])

    def test_ensure_list_downloads_and_patches(self):
        st = self.cache.ensure_list(Fake(mt_list=json.dumps(self.doc()).encode()))
        self.assertEqual(st, "patched")
        self.assertEqual(self.cache.ensure_list(Fake()), "ok")      # fresh copy on disk: no download
        with open(self.cache.list_path) as f:
            doc = json.load(f)
        self.assertTrue(any(it["name"] == "6-34-21.pmtiles" and it["max_zoom"] == 15 for it in doc["items"]))

    def test_old_list_offline_still_patched(self):
        os.makedirs(os.path.dirname(self.cache.list_path))
        with open(self.cache.list_path, "w") as f:
            json.dump(self.doc(), f)
        old = time.time() - 10 * 86400
        os.utime(self.cache.list_path, (old, old))
        self.assertEqual(self.cache.ensure_list(Fake()), "patched")

    def test_missing_offline(self):
        self.assertEqual(self.cache.ensure_list(Fake()), "missing")


if __name__ == "__main__":
    unittest.main()
