"""Offline helper checks: classification, row separation, payloads and capability discovery."""
import importlib.util
from pathlib import Path
import unittest
import os
import tempfile
import threading
import time
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cargo_helper", Path(__file__).parents[1] / "helper/cargo_earth_helper.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Connection:
    def __init__(self, rows):
        self.rows = rows
        self.query = ""
        self.closed = False

    def close(self):
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def execute(self, query):
        self.query = query
        return self

    def fetchall(self):
        return self.rows


class HelperTests(unittest.TestCase):
    def test_business_classification(self):
        self.assertEqual(helper.depot_kind("warehouse", None, None), "yard")
        self.assertEqual(helper.depot_kind(None, "industrial manufacturing", None), "yard")
        self.assertEqual(helper.depot_kind("supermarket", None, "food_and_beverage_store"), "shop")
        self.assertIsNone(helper.depot_kind("restaurant", "food", None))
        self.assertIsNone(helper.depot_kind(None, None, None))

    def test_place_query_keeps_workplaces_out_of_food_orders(self):
        rows = [
            ("full-warehouse-id-123456789", " Warehouse ", "industrial", "warehouse", "industrial warehouse", 42.65, 23.35, "Sofia", False),
            ("full-grocery-id", "Grocer", "food_and_beverage_store", "grocery_store", "retail grocery_store", 42.66, 23.35, "Sofia", True),
            ("full-food-id", "Cafe", "cafe", "cafe", "food cafe", 42.67, 23.35, "Sofia", False),
        ]
        con = Connection(rows)
        builder = object.__new__(helper.Builder)
        builder._con = lambda *args: (con, ["local.parquet"])
        food, depots = builder.places((23.3, 42.6, 23.4, 42.7))
        self.assertEqual(len(food), 2)
        self.assertEqual(len(depots), 2)
        self.assertEqual(depots[0]["id"], "overture:full-warehouse-id-123456789")
        self.assertEqual(depots[0]["access"], "candidate")
        self.assertIn("regexp_matches", con.query)
        self.assertIn("confidence >=", con.query)
        self.assertTrue(con.closed)

    def test_area_contains_depots_and_advertises_capability(self):
        builder = object.__new__(helper.Builder)
        builder.index = SimpleNamespace(release="fixture")
        builder.places = lambda box: ([], [
            {"id": "yard", "n": "Yard", "g": [42.65, 23.35], "t": "yard"},
            {"id": "out", "n": "Outside", "g": [0, 0], "t": "yard"},
        ])
        builder.addresses = lambda box: [[42.65, 23.35, "Street 12", "Sofia"]] * 31
        data = builder.build(426, 233)
        self.assertEqual([d["id"] for d in data["depots"]], ["yard"])
        with patch.object(helper, "WORKERS", 0), patch.object(helper.os, "makedirs"), patch.object(helper.os.path, "isfile", return_value=False):
            areas = helper.Areas(builder, "test-cache")
            near = areas.near(42.65, 23.35)
            self.assertTrue(near["depots"])
            self.assertEqual(near["loading"], 9)


@contextmanager
def cache_dir():
    parent = Path(__file__).resolve().parent
    context = tempfile.TemporaryDirectory(dir=parent)
    directory = Path(context.name).resolve()
    if directory.parent != parent:
        raise RuntimeError("test cache escaped the workspace")
    try:
        yield directory
    finally:
        context.cleanup()


class Response:
    def __init__(self, body, status=206, content_range="bytes 0-3/4"):
        self.body, self.status = body, status
        self.headers = {"Content-Range": content_range}
        self.reads = 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, size):
        self.reads += 1
        return self.body[:size]


class NetworkAndStorageTests(unittest.TestCase):
    def test_query_failure_still_closes_database_connection(self):
        con = Connection([])
        builder = object.__new__(helper.Builder)
        builder._con = lambda *args: (con, ["local.parquet"])
        with patch.object(con, "execute", side_effect=RuntimeError("query failed")), self.assertRaises(RuntimeError):
            builder.places((23.3, 42.6, 23.4, 42.7))
        self.assertTrue(con.closed)

    def test_metadata_index_build_is_single_flight(self):
        with cache_dir() as cache, patch.object(helper, "find_bne_index", return_value=None):
            index = helper.Index("fixture", str(cache))
            calls = []
            def build(key):
                calls.append(key)
                time.sleep(0.01)
                return [["file.parquet", [0, 0, 1, 1], 16]]
            with patch.object(index, "_build", side_effect=build), ThreadPoolExecutor(2) as pool:
                result = list(pool.map(lambda _: index.get("places/place"), range(2)))
            self.assertEqual(len(calls), 1)
            self.assertEqual(result[0], result[1])

    def test_ignored_range_is_rejected_before_reading_large_file(self):
        response = Response(b"huge response", status=200)
        with patch.object(helper.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(ValueError):
                helper.http_get("https://example.invalid/data", {"Range": "bytes=0-3"})
        self.assertEqual(response.reads, 0)

    def test_short_or_mismatched_range_is_rejected(self):
        for response in (Response(b"abc"), Response(b"abcd", content_range="bytes 1-4/5")):
            with patch.object(helper.urllib.request, "urlopen", return_value=response), self.assertRaises(ValueError):
                helper.http_get("https://example.invalid/data", {"Range": "bytes=0-3"})

    def test_concurrent_range_reads_download_once_and_repair_short_cache(self):
        with cache_dir() as cache:
            remote = helper.Remote("https://example.invalid/file", 16, cache)
            requests = []
            def download(url, headers):
                requests.append(headers["Range"])
                time.sleep(0.01)
                return b"abcdefghijklmnop"
            with patch.object(helper, "http_get", side_effect=download):
                with ThreadPoolExecutor(2) as pool:
                    result = list(pool.map(lambda _: remote.read(0, 16), range(2)))
                self.assertEqual(result, [b"abcdefghijklmnop"] * 2)
                self.assertEqual(len(requests), 1)
                Path(remote.dir, "0.blk").write_bytes(b"bad")
                self.assertEqual(remote.read(0, 4), b"abcd")
                self.assertEqual(len(requests), 2)

    def test_failed_range_never_publishes_partial_blocks(self):
        with cache_dir() as cache:
            remote = helper.Remote("https://example.invalid/file", 16, cache)
            with patch.object(helper, "http_get", return_value=b"short"), self.assertRaises(ValueError):
                remote.read(0, 16)
            self.assertFalse(remote._have(0))

    def test_moving_discards_old_queue_and_bounds_status_history(self):
        with cache_dir() as cache, patch.object(helper, "WORKERS", 0):
            areas = helper.Areas(SimpleNamespace(index=SimpleNamespace(release="test")), cache)
            areas.near(50, 14)
            old = set(areas.queue)
            areas.near(42.65, 23.35)
            self.assertEqual(len(areas.queue), 9)
            self.assertTrue(old.isdisjoint(areas.queue))
            self.assertLessEqual(len(areas.state), 9)
            self.assertEqual(areas.near(42.65, 23.35)["loading"], 9)

    def test_invalid_coordinates_do_not_queue_downloads(self):
        with cache_dir() as cache, patch.object(helper, "WORKERS", 0):
            areas = helper.Areas(SimpleNamespace(index=SimpleNamespace(release="test")), cache)
            for lat, lon in ((float("nan"), 14), (90.1, 14), (50, float("inf")), (50, 181)):
                with self.assertRaises(ValueError):
                    areas.near(lat, lon)
            self.assertEqual(areas.queue, [])
            result = areas.near(90, 180)
            self.assertLessEqual(result["loading"], 9)
            self.assertTrue(all(-1800 <= int(key.split("_")[1]) < 1800 for key in areas.queue))

    def test_corrupt_area_is_rebuilt_instead_of_served_forever(self):
        with cache_dir() as cache, patch.object(helper, "WORKERS", 0):
            areas = helper.Areas(SimpleNamespace(index=SimpleNamespace(release="test")), cache)
            key = "500_140"
            Path(areas.path(key)).write_text('{"wrong":true}', encoding="utf-8")
            result = areas.near(50, 14)
            self.assertNotIn(key, result["ready"])
            self.assertIn(key, areas.queue)

    def test_area_validation_rejects_bad_nested_coordinates_and_tile_rows(self):
        data = {"key": "1_1", "release": "test", "restaurants": [], "grocers": [], "depots": [], "tiles": {"1_1": [[50, 14, 50, 14, "Street 12"]]}}
        self.assertTrue(helper.valid_area(data, "1_1", "test"))
        data["tiles"]["1_1"][0][0] = float("nan")
        self.assertFalse(helper.valid_area(data, "1_1", "test"))
        data["tiles"]["1_1"] = "bad rows"
        self.assertFalse(helper.valid_area(data, "1_1", "test"))

    def test_cache_budget_prunes_old_owned_files_and_keeps_pinned_area(self):
        with cache_dir() as cache:
            block = cache / "blocks/file/0.blk"
            area = cache / "areas/release/3/1_1.json"
            index = cache / "index/file.json"
            for file in (block, area, index):
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(b"x" * 32)
            os.utime(block, (1, 1))
            budget = helper.CacheBudget(cache, megabytes=32 / 1024 / 1024)
            budget.prune([area], force=True)
            self.assertFalse(block.exists())
            self.assertTrue(area.exists() and index.exists())
            self.assertEqual(budget.stats["bytes"], 32)

    def test_cache_budget_never_unlinks_a_resolved_path_outside_its_root(self):
        with cache_dir() as cache:
            budget = helper.CacheBudget(cache)
            realpath = helper.os.path.realpath
            outside = str(cache.parent / "outside.blk")
            def resolve(path):
                return outside if str(path).endswith("escape.blk") else realpath(path)
            with patch.object(helper.os, "walk", return_value=[(str(cache / "blocks"), [], ["escape.blk"])]), \
                 patch.object(helper.os.path, "realpath", side_effect=resolve), patch.object(helper.os, "unlink") as remove:
                budget.prune(force=True)
                remove.assert_not_called()

    def test_browser_requests_cannot_trigger_data_downloads(self):
        captured = []
        def server(address, handler):
            captured.append(handler)
            return SimpleNamespace(serve_forever=lambda: None)
        areas = SimpleNamespace(near=lambda *args: self.fail("browser request queued work"))
        with patch.object(helper, "ThreadingHTTPServer", side_effect=server):
            helper.serve(areas, "test", 47820)
        for headers in ({"Host": "other.example"}, {"Host": "127.0.0.1", "Origin": "https://other.example"}):
            handler = object.__new__(captured[0])
            handler.headers, handler.path = headers, "/v1/near?lat=50&lon=14"
            result = []
            handler._send = lambda code, *args: result.append(code)
            handler.do_GET()
            self.assertEqual(result, [403])


if __name__ == "__main__":
    unittest.main()
