"""Offline helper checks: classification, row separation, payloads and capability discovery."""
import importlib.util
from pathlib import Path
import unittest
import json
import io
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


CATALOGUE_TYPES = json.loads((Path(__file__).parents[1] / "mod/cargo_earth/lua/ge/extensions/cargoEarth/data/freight.json")
                             .read_text(encoding="utf-8"))["types"]


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


class HelperPortTests(unittest.TestCase):
    def test_default_environment_and_legacy_launch_arguments(self):
        for arguments, environment, expected in (
            ([], {}, 47821),
            (['--port', '47820'], {}, 47821),
            ([], {'BNE_CARGO_PORT': '47820'}, 47821),
            ([], {'BNE_CARGO_PORT': '53100'}, 53100),
            (['--port', '53101'], {'BNE_CARGO_PORT': '53100'}, 53101),
        ):
            with self.subTest(arguments=arguments, environment=environment):
                with patch.dict(os.environ, environment, clear=True), patch.object(helper.sys, 'argv', ['helper.py'] + arguments), \
                     patch.object(helper, 'bind', side_effect=RuntimeError('stop before network')) as bind:
                    with self.assertRaisesRegex(RuntimeError, 'stop before network'):
                        helper.main()
                    bind.assert_called_once_with('127.0.0.1', expected)

    def test_invalid_ports_are_rejected(self):
        for value in ('not-a-port', '99999', '0', '1234.5'):
            with self.subTest(value=value), self.assertRaises(helper.argparse.ArgumentTypeError):
                helper.helper_port(value)


class HelperTests(unittest.TestCase):
    def test_business_classification(self):
        self.assertEqual(helper.depot_kind("warehouse", None, None), "yard")
        self.assertEqual(helper.depot_kind(None, "industrial manufacturing", None), "yard")
        self.assertEqual(helper.depot_kind("supermarket", None, "food_and_beverage_store"), "shop")
        self.assertEqual(helper.depot_kind("oil_refiners", None, None), "fuel")
        self.assertIsNone(helper.depot_kind("gas_station", None, None))
        self.assertIsNone(helper.depot_kind("restaurant", "food", None))
        self.assertIsNone(helper.depot_kind(None, None, None))
        # the workplace's type in the mod's freight catalogue
        self.assertEqual(helper.workplace_kind("warehouse", None, None, "yard"), "logistics")
        self.assertEqual(helper.depot_kind("brewery", "food_and_beverage brewery", None), "yard")
        self.assertEqual(helper.workplace_kind("brewery", "food_and_beverage brewery", None, "yard"), "brewery")
        self.assertEqual(helper.workplace_kind("sawmill", None, None, "yard"), "sawmill")
        self.assertEqual(helper.workplace_kind("steel_fabricators", None, None, "yard"), "steelworks")
        self.assertEqual(helper.workplace_kind("oil_refiners", None, None, "fuel"), "fuel_depot")
        self.assertEqual(helper.workplace_kind(None, "industrial manufacturing", None, "yard"), "factory")
        self.assertEqual(helper.workplace_kind("industrial_company", None, None, "yard"), "factory")
        self.assertEqual(helper.workplace_kind("lumber_yard_unknown", None, None, "yard"), "sawmill")
        self.assertEqual(helper.workplace_kind("odd_yard", None, None, "yard"), "industrial")
        self.assertIsNone(helper.workplace_kind("supermarket", None, None, "shop"))
        self.assertIsNone(helper.depot_kind("plastic_surgeon", "health plastic_surgeon", None))
        self.assertIsNone(helper.depot_kind("farmers_market", None, None))
        self.assertEqual(helper.workplace_kind("dairy_farm", "farm dairy_farm", None, "yard"), "farm")
        for k, _ in helper.WORKPLACE_RULES:
            self.assertIn(k, CATALOGUE_TYPES, k)
        self.assertEqual(helper.auto_kind("auto_parts_and_supply_store", None, None), "p")
        self.assertEqual(helper.auto_kind("automotive_repair", None, None), "g")
        self.assertEqual(helper.auto_kind(None, "automotive car_dealer", None), "g")
        self.assertIsNone(helper.auto_kind("gas_station", "automotive", None))
        # taxi destinations
        self.assertEqual(helper.auto_kind("airport", "travel airport", None), "t")
        self.assertEqual(helper.auto_kind("train_station", None, None), "t")
        self.assertEqual(helper.auto_kind("art_museum", "arts_and_entertainment museum art_museum", None), "t")
        self.assertEqual(helper.auto_kind("hotel", None, None), "t")
        self.assertIsNone(helper.auto_kind("tour_operator", None, None))
        self.assertIsNone(helper.auto_kind("airport_shuttles", None, None))

    def test_place_query_keeps_workplaces_out_of_food_orders(self):
        rows = [
            ("full-warehouse-id-123456789", " Warehouse ", "industrial", "warehouse", "industrial warehouse", 42.65, 23.35, "Sofia", False),
            ("full-grocery-id", "Grocer", "food_and_beverage_store", "grocery_store", "retail grocery_store", 42.66, 23.35, "Sofia", True),
            ("full-food-id", "Cafe", "cafe", "cafe", "food cafe", 42.67, 23.35, "Sofia", False),
            ("full-station-id-0123456789", "Petrol", "gas_station", "gas_station", "automotive gas_station", 42.68, 23.35, None, False),
            ("full-charger-id-0123456789", None, "ev_charging_station", "ev_charging_station", "automotive", 42.69, 23.35, "Sofia", False),
            ("full-parts-id-0123456789ab", "Parts", "automotive", "auto_parts_and_supply_store", "retail automotive", 42.70, 23.35, "Sofia", False),
            ("full-garage-id-0123456789a", "Garage", "automotive", "automotive_repair", "automotive automotive_repair", 42.71, 23.35, "Sofia", False),
        ]
        con = Connection(rows)
        builder = object.__new__(helper.Builder)
        builder._con = lambda *args: (con, ["local.parquet"])
        food, depots, stations, autos = builder.places((23.3, 42.6, 23.4, 42.7))
        self.assertEqual(len(food), 2)
        self.assertEqual(len(depots), 3)   # the warehouse, the grocer, the parts shop
        self.assertEqual([a[3:5] for a in autos], [["Parts", "p"], ["Garage", "g"]])
        self.assertEqual([s[3:5] for s in stations], [["Petrol", "f"], ["Charging station", "e"]])
        self.assertEqual(stations[0][0], "ofull-station-id-")
        self.assertEqual(depots[0]["id"], "overture:full-warehouse-id-123456789")
        self.assertEqual(depots[0]["access"], "candidate")
        self.assertEqual(depots[0]["k"], "logistics")
        self.assertIn("regexp_matches", con.query)
        self.assertIn("confidence >=", con.query)
        self.assertTrue(con.closed)

    def test_area_contains_depots_and_advertises_capability(self):
        builder = object.__new__(helper.Builder)
        builder.index = SimpleNamespace(release="fixture")
        builder.places = lambda box: ([], [
            {"id": "yard", "n": "Yard", "g": [42.65, 23.35], "t": "yard"},
            {"id": "out", "n": "Outside", "g": [0, 0], "t": "yard"},
        ], [["oa", 42.66, 23.36, "Petrol", "f", ""], ["ob", 1, 1, "Far", "f", ""]],
            [["op", 42.67, 23.36, "Parts", "p", ""], ["og", 1, 1, "Far garage", "g", ""]])
        builder.addresses = lambda box: [[42.65, 23.35, "Street 12", "Sofia"]] * 31
        data = builder.build(426, 233)
        self.assertEqual([d["id"] for d in data["depots"]], ["yard"])
        self.assertEqual(data["fuel"], [["oa", 42.66, 23.36, "Petrol", "f", "Sofia"]])
        self.assertEqual(data["autos"], [["op", 42.67, 23.36, "Parts", "p", "Sofia"]])
        self.assertFalse(helper.valid_area(dict(data, autos=[["op", 42.67, 23.36, "Parts", "x"]]), "426_233", "fixture"))
        self.assertTrue(helper.valid_area(data, "426_233", "fixture"))
        self.assertFalse(helper.valid_area(dict(data, fuel=[["oa", 420, 23, "Petrol", "f"]]), "426_233", "fixture"))
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

    def test_far_sites_queue_build_and_serve_from_disk(self):
        rows = [("abc", "Big Warehouse", "warehouse", "warehouse", "warehouse", 48.2, 16.37, "Wien"),
                ("def", "Cafe", "cafe", "cafe", "cafe", 48.21, 16.38, "Wien"),
                ("ghi", "Far Away Depot", "warehouse", "warehouse", "warehouse", 49.5, 16.37, "Elsewhere")]
        conn = Connection(rows)
        builder = helper.Builder(SimpleNamespace(release="test"), "")
        builder._con = lambda key, box: (conn, ["x"])
        with cache_dir() as cache:
            sites = helper.Sites(builder, cache, start=False)
            first = sites.get(48.2, 16.37)
            self.assertEqual(first["state"], "loading")
            self.assertEqual(sites.queue, [first["key"]])
            data = sites.build(sites.queue.pop())
            self.assertTrue(helper.valid_sites(data, first["key"], "test"))
            self.assertEqual([d["n"] for d in data["depots"]], ["Big Warehouse"], "only workplaces inside the box")
            self.assertIn("regexp_matches", conn.query)
            self.assertNotIn("addresses/address", conn.query)
            Path(sites.path(first["key"])).write_text(json.dumps(data), encoding="utf-8")
            ready = sites.get(48.2001, 16.3701)
            self.assertEqual(ready["state"], "ready")
            self.assertEqual(ready["depots"][0]["t"], "yard")
            for lat, lon in ((float("nan"), 14), (91, 14)):
                with self.assertRaises(ValueError):
                    sites.get(lat, lon)
            for i in range(helper.SITE_QUEUE + 5):
                sites.get(40 + i * 0.1, 10)
            self.assertLessEqual(len(sites.queue), helper.SITE_QUEUE)

    def test_coach_stations_queue_build_rank_and_serve(self):
        hier = "travel_and_transportation public_transit_facility_or_service bus_station"
        rows = [("a1", "Autobusové nádraží Písek", "public_transit_facility_or_service", "bus_station", hier, 49.30, 14.15, "Písek"),
                ("a2", "Steel Fish", "public_transit_facility_or_service", "bus_station", hier, 49.31, 14.15, "Písek"),
                ("a3", "Železniční stanice Písek", "train_station", "train_station", "travel train_station", 49.29, 14.16, "Písek"),
                ("a4", "Cafe", "cafe", "cafe", "cafe", 49.30, 14.15, "Písek"),
                ("a5", "Far Station", "bus_station", "bus_station", hier, 51.0, 14.15, "")]
        conn = Connection(rows)
        builder = helper.Builder(SimpleNamespace(release="test"), "")
        builder._con = lambda key, box: (conn, ["x"])
        with cache_dir() as cache:
            stations = helper.Stations(builder, cache, start=False)
            first = stations.get(49.30, 14.15)
            self.assertEqual(first, {"state": "loading", "key": first["key"], "stations": []})
            data = stations.build(stations.queue.pop())
            self.assertTrue(helper.valid_stations(data, first["key"], "test"))
            self.assertFalse(helper.valid_sites(data, first["key"], "test"))
            got = {r["n"]: (r["k"], r["s"]) for r in data["stations"]}
            self.assertEqual(got, {"Autobusové nádraží Písek": ("bus", 2), "Steel Fish": ("bus", 0),
                                   "Železniční stanice Písek": ("rail", 1)})
            self.assertIn("bus_station", conn.query)
            Path(stations.path(first["key"])).write_text(json.dumps(data), encoding="utf-8")
            ready = stations.get(49.3001, 14.1501)
            self.assertEqual(ready["state"], "ready")
            self.assertEqual(len(ready["stations"]), 3)
            self.assertIn(os.path.join("stations", "test", helper.STATIONS_CACHE_VERSION), stations.dir)
            bad = dict(data, stations=[{"id": "x", "n": "X", "g": [99, 14], "k": "bus"}])
            self.assertFalse(helper.valid_stations(bad, first["key"], "test"))

    def test_station_names_say_how_sure_a_row_is(self):
        for name, score in (("Prague Bus Station", 2), ("ÚAN Florenc", 2), ("AN Holešovice", 2), ("ZOB Hamburg", 2),
                            ("Gare routière de Perrache", 2), ("Автовокзал Казань", 2), ("Flixbus Stop", 2),
                            ("Na Knížecí (tram, bus)", 1), ("Gare de Lyon Part-Dieu", 1), ("An der Kirche", 0),
                            ("Bigben Travel", 0), ("JYSK", 0)):
            self.assertEqual(helper.station_score(name), score, name)

    def test_area_validation_rejects_bad_nested_coordinates_and_tile_rows(self):
        data = {"key": "1_1", "release": "test", "restaurants": [], "grocers": [], "depots": [], "fuel": [], "tiles": {"1_1": [[50, 14, 50, 14, "Street 12"]]}}
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

    def test_speed_values_and_camera_limits(self):
        self.assertEqual(helper.parse_speed("50"), 50)
        self.assertEqual(helper.parse_speed("30 mph"), 48)
        self.assertEqual(helper.parse_speed("80;60"), 60)
        self.assertIsNone(helper.parse_speed("signals"))
        self.assertIsNone(helper.parse_speed(None))
        road = {"type": "way", "tags": {"highway": "primary_link", "maxspeed": "70"},
                "geometry": [{"lat": 50.0, "lon": 14.0}, {"lat": 50.0, "lon": 14.01}]}
        rows = helper.camera_rows({"elements": [
            {"type": "node", "id": 1, "lat": 50.0001, "lon": 14.005, "tags": {"highway": "speed_camera", "maxspeed": "50"}},
            {"type": "node", "id": 2, "lat": 50.0001, "lon": 14.006, "tags": {"highway": "speed_camera"}},
            {"type": "node", "id": 3, "lat": 50.0001, "lon": 14.007, "tags": {"highway": "speed_camera"}},
            {"type": "node", "id": 4, "lat": 50.2, "lon": 14.007, "tags": {"highway": "speed_camera"}},
            {"type": "node", "id": 5, "lat": 500, "lon": 14.007, "tags": {"highway": "speed_camera"}},
            {"type": "node", "id": 6, "lat": 50.0, "lon": 14.0, "tags": {"highway": "traffic_signals"}},
            {"type": "relation", "id": 9, "tags": {"type": "enforcement", "enforcement": "maxspeed", "maxspeed": "60"},
             "members": [{"type": "node", "ref": 3, "role": "device"}, {"type": "node", "ref": 2, "role": "from"}]},
            road]})
        self.assertEqual(rows, [["n1", 50.0001, 14.005, 50, "primary"], ["n2", 50.0001, 14.006, 70, "primary"],
                                ["n3", 50.0001, 14.007, 60, "primary"], ["n4", 50.2, 14.007, 0, ""]])

    def test_cameras_are_fetched_once_per_cell_and_cached(self):
        calls = []
        def fetch(box):
            calls.append(box)
            return {"elements": [{"type": "node", "id": 7, "lat": box[0] + 0.1, "lon": box[1] + 0.1,
                                  "tags": {"highway": "speed_camera", "maxspeed": "50"}}]}
        with cache_dir() as cache:
            cameras = helper.Cameras(str(cache), fetch)
            first = cameras.near(50.25, 14.25)
            self.assertEqual(first["state"], "loading")
            for _ in range(100):
                if cameras.near(50.25, 14.25)["state"] == "ready":
                    break
                time.sleep(0.01)
            ready = cameras.near(50.25, 14.25)
            self.assertEqual((ready["state"], ready["cells"], len(ready["cameras"]), len(calls)), ("ready", ["100_28"], 1, 1))
            later = []
            again = helper.Cameras(str(cache), lambda box: later.append(box) or {"elements": []})
            self.assertEqual(again.near(50.25, 14.25)["cameras"], ready["cameras"])
            self.assertEqual(later, [])
            self.assertEqual(len(again.near(50.49, 14.49)["cells"]), 4)
            for _ in range(200):
                if again.near(50.49, 14.49)["state"] == "ready":
                    break
                time.sleep(0.01)
            with self.assertRaises(ValueError):
                cameras.near(float("nan"), 14)

    def test_failed_camera_request_is_reported_and_not_hammered(self):
        calls = []
        def fetch(box):
            calls.append(box)
            raise OSError("offline")
        with cache_dir() as cache:
            cameras = helper.Cameras(str(cache), fetch)
            cameras.near(50.25, 14.25)
            for _ in range(100):
                if cameras.near(50.25, 14.25)["state"] == "failed":
                    break
                time.sleep(0.01)
            self.assertEqual(cameras.near(50.25, 14.25)["state"], "failed")
            self.assertEqual(len(calls), 1)

    def test_paused_cameras_do_not_download_or_return_cached_fines(self):
        with cache_dir() as cache:
            calls = []
            cameras = helper.Cameras(str(cache), lambda box: calls.append(box), enabled=False)
            cameras.state["100_28"] = [["n1", 50.25, 14.25, 50, "primary"]]
            self.assertEqual(cameras.near(50.25, 14.25)["state"], "paused")
            self.assertEqual(cameras.near(50.25, 14.25)["cameras"], [])
            self.assertEqual(calls, [])

    def test_bus_lines_from_route_relations(self):
        def node(i, lat, lon, name=None):
            return {"type": "node", "id": i, "lat": lat, "lon": lon, "tags": {"name": name} if name else {}}
        els = [node(1, 50.000, 14.000, "A"), node(2, 50.005, 14.000), node(3, 50.010, 14.000, "C"),
               node(4, 50.015, 14.000, "D"), node(5, 50.020, 14.000, "E"),
               node(11, 50.0051, 14.0002, "B platform"), node(12, 50.30, 14.0, "Far")]
        good = {"type": "relation", "id": 100, "tags": {"type": "route", "route": "bus", "ref": "136", "name": "Bus 136",
                                                         "operator": "DPP", "to": "Terminal E"},
                "members": [{"type": "node", "ref": r, "role": "stop"} for r in (1, 2, 3, 3, 4, 5)]
                + [{"type": "node", "ref": 11, "role": "platform"}, {"type": "way", "ref": 99, "role": ""}]}
        gappy = {"type": "relation", "id": 101, "tags": {"type": "route", "route": "bus"},
                 "members": [{"type": "node", "ref": r, "role": "stop"} for r in (1, 2, 3, 12)]}
        tram = dict(good, id=102, tags={"type": "route", "route": "tram"})
        short = {"type": "relation", "id": 103, "tags": {"type": "route", "route": "bus"},
                 "members": [{"type": "node", "ref": r, "role": "stop"} for r in (1, 2)]}
        station = {"type": "way", "id": 7, "center": {"lat": 50.001, "lon": 14.001}, "tags": {"amenity": "bus_station", "name": "Hub"}}
        depot = {"type": "node", "id": 8, "lat": 50.002, "lon": 14.002, "tags": {"landuse": "depot", "depot": "tram"}}
        yard = {"type": "way", "id": 9, "center": {"lat": 50.003, "lon": 14.003}, "tags": {"landuse": "depot"}}
        rows = helper.bus_rows({"elements": els + [good, gappy, tram, short, station, depot, yard]})
        lines = [r for r in rows if not r.get("depot")]
        self.assertEqual([r["id"] for r in lines], ["r100"])
        line = lines[0]
        self.assertEqual([st[0] for st in line["stops"]], ["A", "B platform", "C", "D", "E"])
        self.assertEqual((line["ref"], line["from"], line["to"], line["operator"]), ("136", "A", "Terminal E", "DPP"))
        self.assertAlmostEqual(line["km"], 2.23, places=1)
        self.assertEqual([r for r in rows if r.get("depot")],
                         [{"depot": True, "id": "w7", "name": "Hub", "kind": "station", "lat": 50.001, "lon": 14.001}])

    def test_bus_lines_query_starts_from_the_stops(self):
        with cache_dir() as cache:
            q = helper.BusLines(str(cache), lambda box: {"elements": []}).query((50, 14, 50.04, 14.04))
        self.assertIn('node["highway"="bus_stop"](50,14,50.04,14.04)', q)
        self.assertIn("rel(bn.s)", q)
        self.assertIn('node(r.r:"stop")', q)
        self.assertNotIn("way(r.r);", q)        # not the lines' roads
        self.assertNotIn("node(r.r);", q)

    def test_bus_lines_crossing_cells_come_once(self):
        line = {"id": "r1", "ref": "5", "name": "", "from": "A", "to": "B", "operator": "", "colour": "", "km": 3,
                "stops": [["A", 50, 14], ["B", 50.01, 14], ["C", 50.02, 14], ["D", 50.03, 14]]}
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache), lambda box: {"elements": []})
            lines.rows = lambda data: [line, {"depot": True, "id": "n1", "name": "Hub", "kind": "station", "lat": 50, "lon": 14}]
            for _ in range(200):
                got = lines.near(50.039, 14.039)
                if got["state"] == "ready":
                    break
                time.sleep(0.01)
            self.assertEqual(got["state"], "ready")
            self.assertEqual(len(got["lines"]), 1)
            self.assertGreaterEqual(len(got["depots"]), 1)
            self.assertGreater(len(got["cells"]), 1)

    def test_overpass_runtime_error_tries_mirror_instead_of_caching_empty_lines(self):
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache))
            with patch.object(helper, "http_get", side_effect=[
                    json.dumps({"elements": [], "remark": "runtime error: Query timed out"}).encode(),
                    json.dumps({"elements": []}).encode()]) as fetch:
                lines._work("1250_350")
            self.assertEqual(fetch.call_count, 2)
            self.assertEqual(lines.near(50.02, 14.02)["state"], "ready")

    def test_bus_failure_reports_reason_and_cooldown_and_manual_retry_recovers(self):
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache), lambda box: {"elements": [], "remark": "Query timed out"})
            lines._work("1250_350")
            failed = lines.near(50.02, 14.02)
            self.assertEqual((failed["state"], failed["failed"], failed["total"]), ("failed", 1, 1))
            self.assertIn("timed out", failed["errors"][0])
            self.assertGreater(failed["retryAfter"], 0)
            self.assertFalse(Path(lines.path("1250_350")).exists(), "a server error must not become a 14-day empty cache")
            lines.fetch = lambda box: {"elements": []}
            lines.near(50.02, 14.02, retry=True)
            for _ in range(100):
                ready = lines.near(50.02, 14.02)
                if ready["state"] == "ready":
                    break
                time.sleep(0.01)
            self.assertEqual((ready["state"], ready["ready"], ready["errors"]), ("ready", 1, []))

    def test_bus_refresh_failure_keeps_only_local_cached_lines(self):
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache), lambda box: {"elements": [], "remark": "Query timed out"})
            key = "1250_350"
            cached = {"at": 0, "format": lines.CACHE_VERSION, "lines": [{"id": "r123"}]}
            Path(lines.path(key)).write_text(json.dumps(cached), encoding="utf-8")
            lines._work(key)
            result = lines.near(50.02, 14.02)
            self.assertEqual((result["state"], result["lines"]), ("failed", [{"id": "r123"}]))
            lines.fetch = lambda box: {"elements": []}
            lines._work(key)
            self.assertEqual(lines.near(50.02, 14.02)["lines"], [])

    def test_bus_cache_from_before_error_validation_is_refetched(self):
        with cache_dir() as cache:
            calls = []
            lines = helper.BusLines(str(cache), lambda box: calls.append(box) or {"elements": []})
            Path(lines.path("1250_350")).write_text(json.dumps({"at": time.time(), "lines": []}), encoding="utf-8")
            self.assertIsNone(lines._load("1250_350"))
            lines._work("1250_350")
            self.assertEqual(len(calls), 1)
            self.assertEqual(lines._load("1250_350"), [])

    def test_bus_loading_reports_queued_and_active_progress(self):
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache))
            entered, release = threading.Event(), threading.Event()
            def fetch(*a, **kw):
                entered.set()
                release.wait(2)
                return json.dumps({"elements": []}).encode()
            with patch.object(helper, "http_get", side_effect=fetch):
                try:
                    with helper.overpass_slot(), helper.overpass_slot():   # every slot taken
                        queued = lines.near(50.02, 14.02)
                        self.assertEqual((queued["loading"], queued["queued"]), (1, 1))
                        again = lines.near(50.02, 14.02, retry=True)
                        self.assertEqual(again["loading"], 1)
                    self.assertTrue(entered.wait(1))
                    active = lines.near(50.02, 14.02)
                    self.assertEqual((active["queued"], active["attempt"]), (0, 1))
                    self.assertIn("overpass", active["server"])
                finally:
                    release.set()
                for _ in range(100):
                    if lines.near(50.02, 14.02)["state"] == "ready":
                        break
                    time.sleep(0.01)

    def test_overpass_fails_over_through_every_server_with_readable_reasons(self):
        import urllib.error
        helper.OVERPASS_HEALTH.clear()
        asked = []
        def fetch(url, **kw):
            asked.append(url.split("?")[0])
            if len(asked) == 1:
                raise urllib.error.HTTPError(url, 502, "Bad Gateway", {}, None)
            if len(asked) == 2:
                raise TimeoutError("The read operation timed out")
            if len(asked) == 3:
                raise urllib.error.HTTPError(url, 429, "Too Many Requests", {}, None)
            return json.dumps({"elements": []}).encode()
        with cache_dir() as cache, patch.object(helper, "http_get", side_effect=fetch):
            data = helper.BusLines(str(cache))._overpass((50, 14, 50.04, 14.04))
        self.assertEqual(data, {"elements": []})
        self.assertEqual(asked, helper.OVERPASS)
        # the server that answered is asked first next time, the ones that just failed last
        self.assertEqual(helper.overpass_order()[0], helper.OVERPASS[3])
        with cache_dir() as cache, patch.object(helper, "http_get", side_effect=[
                urllib.error.HTTPError("u", 502, "Bad Gateway", {}, None), TimeoutError("timed out")] * 2):
            with self.assertRaises(RuntimeError) as err:
                helper.BusLines(str(cache))._overpass((50, 14, 50.04, 14.04))
        self.assertIn("busy (HTTP 502)", str(err.exception))
        self.assertIn(f"no answer in {helper.OVERPASS_TIMEOUT_S} s", str(err.exception))
        helper.OVERPASS_HEALTH.clear()

    def test_failed_bus_area_is_retried_sooner_first_then_backs_off(self):
        with cache_dir() as cache:
            lines = helper.BusLines(str(cache), lambda box: {"elements": [], "remark": "Query timed out"})
            lines._work("1250_350")
            first = lines.near(50.02, 14.02)["retryAfter"]
            self.assertTrue(0 < first <= helper.OVERPASS_RETRY_S[0])
            lines._work("1250_350")
            lines._work("1250_350")
            lines._work("1250_350")
            self.assertGreater(lines.near(50.02, 14.02)["retryAfter"], helper.OVERPASS_RETRY_S[1])

    def test_two_requests_run_at_once_on_different_servers(self):
        helper.OVERPASS_HEALTH.clear()
        with helper.overpass_slot() as a, helper.overpass_slot() as b:
            self.assertNotEqual(a, b)
            got = []
            t = threading.Thread(target=lambda: got.append(helper.overpass_slot(0).__enter__()))
            t.start()
            t.join(0.2)
            self.assertEqual(got, [], "a third request waits")
        t.join(2)
        self.assertEqual(len(got), 1)
        with helper.OVERPASS_ONE:
            helper.OVERPASS_BUSY.clear()
            helper.OVERPASS_ONE.notify_all()

    def test_bus_query_includes_public_transport_stops_without_bus_yes(self):
        with cache_dir() as cache:
            q = helper.BusLines(str(cache)).query((50, 14, 50.04, 14.04))
            self.assertIn('node["public_transport"~"^(stop_position|platform)$"](50,14,50.04,14.04)', q)
            self.assertNotIn('["bus"="yes"]', q)

    def test_bus_requests_take_priority_over_queued_camera_requests(self):
        order = []
        def request(name, priority):
            with helper.overpass_slot(priority):
                order.append(name)
        threads = []
        with helper.overpass_slot(), helper.overpass_slot():
            for name, priority in (("camera", 1), ("bus", 0)):
                t = threading.Thread(target=request, args=(name, priority))
                threads.append(t)
                t.start()
            for _ in range(100):
                with helper.OVERPASS_ONE:
                    if len(helper.OVERPASS_WAITING) == 2:
                        break
                time.sleep(0.01)
        for t in threads:
            t.join(2)
            self.assertFalse(t.is_alive())
        self.assertEqual(order, ["bus", "camera"])

    def test_radio_rows_keep_working_streams_of_the_country(self):
        good = {"stationuuid": "960e57c5-0601-11e8-ae97-52543be04c81", "name": " Radio  Jih ", "url": "http://a/x.pls",
                "url_resolved": "http://a/stream", "codec": "MP3", "bitrate": 128, "countrycode": "CZ", "state": "South Bohemia",
                "geo_lat": 48.97, "geo_long": 14.47, "lastcheckok": 1, "hls": 0, "tags": "pop,  news ,", "votes": 9}
        rows = helper.radio_rows([
            good, dict(good),                                                  # duplicate
            dict(good, stationuuid="960e57c5-0601-11e8-ae97-52543be04c82", lastcheckok=0),
            dict(good, stationuuid="960e57c5-0601-11e8-ae97-52543be04c83", hls=1, name="HLS"),
            dict(good, stationuuid="960e57c5-0601-11e8-ae97-52543be04c84", countrycode="SK", name="Other"),
            dict(good, stationuuid="960e57c5-0601-11e8-ae97-52543be04c85", url_resolved="ftp://x", url="", name="Ftp"),
            dict(good, stationuuid="bad", name="Bad id"),
            dict(good, stationuuid="960e57c5-0601-11e8-ae97-52543be04c86", name="Nowhere", geo_lat=None, codec="AAC"),
        ], "CZ")
        self.assertEqual([r[1] for r in rows], ["Radio Jih", "Nowhere"])
        self.assertEqual(rows[0][2:7], ["http://a/stream", "MP3", 128, "pop, news", "South Bohemia"])
        self.assertIsNone(rows[1][7])

    def test_radio_is_fetched_once_per_country_and_lists_near_stations(self):
        base = {"url_resolved": "http://s", "codec": "MP3", "countrycode": "CZ", "lastcheckok": 1, "hls": 0}
        stations = [dict(base, stationuuid="00000000-0000-0000-0000-00000000000%d" % i, name="S%d" % i,
                         url_resolved="http://s/%d" % i, geo_lat=lat, geo_long=14.4) for i, lat in enumerate([50.1, 48.5, 50.0, None])]
        calls = []
        with tempfile.TemporaryDirectory() as cache:
            radio = helper.Radio(cache, lambda cc: calls.append(cc) or stations, servers=lambda: ["x"])
            self.assertEqual(radio.near("cz", 50.0, 14.4)["state"], "loading")
            for _ in range(100):
                if isinstance(radio.state.get("CZ"), list):
                    break
                time.sleep(0.01)
            out = radio.near("CZ", 50.0, 14.4)
            self.assertEqual(out["state"], "ready")
            self.assertEqual(len(out["top"]), 4)
            self.assertEqual([r[1] for r in out["near"]], ["S2", "S0"])     # S1 is 167 km away
            again = helper.Radio(cache, lambda cc: calls.append(cc) or [], servers=lambda: ["x"])
            self.assertEqual(len(again.near("CZ")["top"]), 4)
            self.assertEqual(calls, ["CZ"])
            radio.fresh_until["CZ"] = 0                                 # a day later, still running
            stations.pop()
            self.assertEqual(len(radio.near("CZ")["top"]), 4)            # the old list meanwhile
            for _ in range(100):
                if "CZ" not in radio.refreshing:
                    break
                time.sleep(0.01)
            self.assertEqual(len(radio.near("CZ")["top"]), 3)
            self.assertEqual(calls, ["CZ", "CZ"])
            with self.assertRaises(ValueError):
                radio.near("CZE")
            with self.assertRaises(ValueError):
                radio.click("../../etc")

    def test_helper_player_plays_only_listed_stations_and_stops_without_the_game(self):
        class Proc:
            kind = "powershell"
            def __init__(self):
                self.lines, self.code, self.stdin, self.stdout = [], None, self, None
            def write(self, line):
                self.lines.append(line)
            def flush(self):
                pass
            def poll(self):
                return self.code
            def wait(self, timeout=None):
                self.code = 0
        procs, now = [], [1000.0]
        player = helper.Player(spawn=lambda url, vol: procs.append((url, vol, Proc())) or procs[-1][2], clock=lambda: now[0])
        with self.assertRaises(ValueError):
            player.play("file:///etc/passwd", 0.5)
        out = player.play("http://s/1", 0.5)
        self.assertTrue(out["playing"])
        player.pos = 4
        player.volume(0.3)
        self.assertEqual(procs[0][2].lines, ["vol 0.30\n"])
        now[0] += 10
        self.assertTrue(player.alive()["playing"])
        self.assertFalse(player.stop()["playing"])
        self.assertIn("stop\n", procs[0][2].lines)
        out = player.play("http://s/2", 0.5)
        self.assertFalse(out["sound"], "Windows' player has said nothing yet")
        player.sound = True
        self.assertTrue(player.status()["sound"])
        player.play("http://s/3", 0.5)               # never makes a sound: stopped, and the phone hears why
        now[0] += helper.PLAYER_OPEN_S + 1
        player.check()
        out = player.status()
        self.assertFalse(out["playing"])
        self.assertIn("no sound", out["error"])
        self.assertIn("stop\n", procs[-1][2].lines)
        player.play("http://s/4", 0.5)               # the player reports a failure
        player.error = "Windows could not play it: bad codec"
        player.check()
        self.assertEqual(player.status()["error"], "Windows could not play it: bad codec")
        with tempfile.TemporaryDirectory() as cache:
            radio = helper.Radio(cache, lambda cc: [], servers=lambda: ["x"])
            radio.state["CZ"] = [["00000000-0000-0000-0000-000000000001", "A", "http://a", "MP3", 0, "", ""]]
            self.assertEqual(radio.url_of("00000000-0000-0000-0000-000000000001"), "http://a")
            asked = []
            def api(path):
                asked.append(path)
                if path.endswith("0003"):
                    return [{"stationuuid": "00000000-0000-0000-0000-000000000003", "name": "Saved", "url_resolved": "http://saved/s", "countrycode": "CZ",
                             "codec": "MP3", "lastcheckok": 1}]
                raise OSError("unknown")
            radio._api = api
            self.assertIsNone(radio.url_of("00000000-0000-0000-0000-000000000002"))
            self.assertEqual(radio.url_of("00000000-0000-0000-0000-000000000003"), "http://saved/s",
                             "A saved station no list has is looked up")
            radio.url_of("00000000-0000-0000-0000-000000000003")
            self.assertEqual(asked.count("/json/stations/byuuid/00000000-0000-0000-0000-000000000003"), 1)
            radio.state.clear()
            with open(radio.path("SK"), "w") as f:      # a list older than a day still knows its stations
                json.dump({"at": 0, "stations": [["00000000-0000-0000-0000-000000000004", "Old", "http://old", "MP3", 0, "", ""]]}, f)
            self.assertEqual(radio.url_of("00000000-0000-0000-0000-000000000004"), "http://old")
            self.assertIsNone(radio.url_of("http://evil"))

    def test_stream_relay_passes_only_listed_stations_to_the_game(self):
        import http.server
        import threading
        import urllib.request

        class Up(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html" if self.path == "/page" else "audio/mpeg")
                self.end_headers()
                self.wfile.write(b"ID3" + bytes(3000))
            def log_message(self, *a):
                pass
        up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Up)
        threading.Thread(target=up.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory() as cache:
            radio = helper.Radio(cache, lambda cc: [], servers=lambda: ["x"])
            a, b = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b"
            radio.state["CZ"] = [[a, "A", f"http://127.0.0.1:{up.server_port}/s", "MP3", 0, "", ""],
                                 [b, "B", f"http://127.0.0.1:{up.server_port}/page", "MP3", 0, "", ""]]
            radio._api = lambda path: []  # Unknown UUIDs must not make a live Radio Browser request in this fixture.
            srv = helper.bind("127.0.0.1", 0)
            areas = type("Areas", (), {"budget": type("Budget", (), {"stats": {}})()})()
            threading.Thread(target=helper.serve, args=(areas, "r", 0), kwargs={"radio": radio, "srv": srv},
                             daemon=True).start()
            base = f"http://127.0.0.1:{srv.server_port}/v1/stream?id="
            try:
                with urllib.request.urlopen(base + a, timeout=5) as r:
                    self.assertEqual(r.headers["Content-Type"], "audio/mpeg")
                    self.assertEqual(len(r.read()), 3003)
                # a station that drops after running a while is reconnected inside the same stream to the game
                with patch.object(helper, "STREAM_LIVE_S", 0):
                    with urllib.request.urlopen(base + a, timeout=5) as r:
                        self.assertEqual(len(r.read()), 3003 * (1 + helper.STREAM_RECONNECTS))
                for sid, code in ((b, 415), ("00000000-0000-0000-0000-00000000000c", 404)):
                    with self.assertRaises(urllib.error.HTTPError) as e:
                        urllib.request.urlopen(base + sid, timeout=5)
                    self.assertEqual(e.exception.code, code)
            finally:
                srv.shutdown()
                up.shutdown()

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

    def test_linux_player_says_why_it_stopped_and_the_status_page_shows_radio(self):
        class Proc:
            kind = "mpv"
            def __init__(self):
                self.code, self.stdin = None, io.StringIO()
                self.stdout = ["", "[ao] Could not open/initialize audio device -> no sound.\n",
                               "Failed to open http://station.example/live?key=secret.\n"]
            def poll(self):
                return self.code
            def wait(self, timeout=None):
                self.code = 0
        proc = Proc()
        player = helper.Player(spawn=lambda url, vol: proc)
        helper.RADIO_LOG.clear()
        self.assertTrue(player.play("http://station.example/live?key=secret", 0.5)["playing"])
        for _ in range(100):
            if player.why and "Failed" in player.why:
                break
            time.sleep(0.01)
        proc.code = 2
        out = player.status()
        self.assertFalse(out["playing"])
        self.assertIn("station.example", out["error"])
        self.assertTrue(out["error"].startswith("mpv: "))
        self.assertNotIn("secret", out["error"])
        # a player that ended before its reason was read: the generic error gives way to the reason
        player.generic, player.error, player.why = False, None, None
        late = Proc()
        late.stdout, late.code = iter(()), 1
        player.proc = late
        self.assertIn("could not be opened", player.status()["error"])
        late.stdout = ["no audio device\n"]
        player._read_err(late)
        self.assertEqual(player.status()["error"], "mpv: no audio device")
        player.proc = proc
        self.assertTrue(any("playing with mpv: station.example" in e for e in helper.RADIO_LOG))
        self.assertFalse(any("secret" in e for e in helper.RADIO_LOG), "station keys stay out of the log")
        areas = SimpleNamespace(cv=threading.Condition(), state={}, budget=SimpleNamespace(stats={}))
        with patch.object(helper.Player, "available", staticmethod(lambda: None)):
            page = helper.status_page(areas, "test", 47821, player=player).decode()
        self.assertIn("Radio player", page)
        self.assertIn("install mpv", page)
        self.assertIn("audio device", page)
        with patch.object(helper.Player, "available", staticmethod(lambda: "ffplay")):
            page = helper.status_page(areas, "test", 47821, player=player).decode()
        self.assertNotIn("install mpv", page)

    def test_linux_players_do_not_inherit_bundled_library_paths(self):
        base = {"PATH": "/usr/bin", "LD_LIBRARY_PATH": "/opt/earth/lib"}
        env = helper.player_env(base, "mpv")
        self.assertNotIn("LD_LIBRARY_PATH", env)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertEqual(base["LD_LIBRARY_PATH"], "/opt/earth/lib", "the helper's own environment is untouched")
        env = helper.player_env(dict(base, LD_LIBRARY_PATH_ORIG="/home/me/lib"), "ffplay")
        self.assertEqual(env["LD_LIBRARY_PATH"], "/home/me/lib", "the path from before Earth started comes back")
        self.assertNotIn("LD_LIBRARY_PATH_ORIG", env)
        self.assertEqual(helper.player_env(base, "powershell")["LD_LIBRARY_PATH"], "/opt/earth/lib")

    @unittest.skipIf(os.name == "nt", "process groups and /proc are Linux")
    def test_stop_ends_the_player_and_what_it_started_and_nothing_outlives_the_helper(self):
        import subprocess
        def spawn(url, vol):
            # a launcher (like a snap or a wrapper script) that starts the real player and waits for it
            proc = subprocess.Popen(["sh", "-c", "sleep 60 & echo $!; wait"], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, text=True, start_new_session=True,
                                    env=dict(os.environ, CARGO_EARTH_STREAM=url))
            proc.kind, proc.group = "mpv", True
            proc.child = int(proc.stdout.readline())
            return proc
        def alive(pid):
            try:
                with open(f"/proc/{pid}/stat") as f:
                    return f.read().split(")")[-1].split()[0] != "Z"
            except OSError:
                return False
        def gone(pid):
            for _ in range(200):
                if not alive(pid):
                    return True
                time.sleep(0.01)
            return False
        player = helper.Player(spawn=spawn)
        player._read_err = lambda proc: None
        player.play("http://s/1", 0.5)
        first = player.proc
        player.stop()
        self.assertTrue(gone(first.child), "Stop ends what the launcher started, too")
        self.assertTrue(gone(first.pid))
        player.play("http://s/2", 0.5)
        second = player.proc
        player.shutdown()
        self.assertTrue(gone(second.child), "a closing helper takes its player with it")
        # a player left by a helper that was killed outright: found by its stream variable and ended at start
        # (its owner, a pid no process has, is gone)
        orphan = subprocess.Popen(["sleep", "60"], env=dict(os.environ, CARGO_EARTH_STREAM="http://s/3",
                                                             CARGO_EARTH_HELPER_PID=str(2 ** 22 + 7)))
        other = subprocess.Popen(["sleep", "60"])
        # another helper's player while that helper (this Python process) runs: left alone
        owned = subprocess.Popen(["sleep", "60"], env=dict(os.environ, CARGO_EARTH_STREAM="http://s/4",
                                                            CARGO_EARTH_HELPER_PID=str(os.getpid())))
        try:
            ended = helper.Player.end_leftovers(me=-1)
            self.assertIn(orphan.pid, ended)
            self.assertNotIn(other.pid, ended)
            self.assertNotIn(owned.pid, ended, "a running helper's player is not touched")
            orphan.wait(timeout=5)
        finally:
            for p in (other, owned, orphan):
                p.kill()
                p.wait()

    def test_root_is_a_status_page(self):
        captured = []
        def server(address, handler):
            captured.append(handler)
            return SimpleNamespace(serve_forever=lambda: None)
        areas = SimpleNamespace(cv=threading.Condition(), state={"1_2": "ready", "1_3": "failed: no <network>"},
                                budget=SimpleNamespace(stats={"bytes": 0, "limit": 1 << 30}))
        with patch.object(helper, "ThreadingHTTPServer", side_effect=server):
            helper.serve(areas, "test", 47820)
        handler = object.__new__(captured[0])
        handler.headers, handler.path = {"Host": "127.0.0.1:47820"}, "/"
        result = []
        handler._send = lambda code, body, ctype="application/json": result.append((code, body, ctype))
        handler.do_GET()
        code, body, ctype = result[0]
        self.assertEqual(code, 200)
        self.assertTrue(ctype.startswith("text/html"))
        page = body.decode()
        self.assertIn("Cargo Earth helper", page)
        self.assertIn("1 ready", page)
        self.assertIn("no &lt;network&gt;", page)

    def test_stop_names_are_sent_as_utf8_instead_of_unicode_escape_sequences(self):
        captured = []
        def server(address, handler):
            captured.append(handler)
            return SimpleNamespace(serve_forever=lambda: None)
        areas = SimpleNamespace(budget=SimpleNamespace(stats={}))
        with patch.object(helper, 'ThreadingHTTPServer', side_effect=server):
            helper.serve(areas, 'test', 47820)
        handler = object.__new__(captured[0])
        handler.send_response = lambda code: None
        handler.send_header = lambda *args: None
        handler.end_headers = lambda: None
        handler.wfile = io.BytesIO()
        names = ['Kralupy n. Vlt., Kovošrot', 'Chvatěruby', 'Zlončice', 'Kozomín', '😀']
        handler._send(200, {'names': names})
        wire = handler.wfile.getvalue()
        self.assertNotIn(b'\\u', wire)
        self.assertIn('Kovošrot'.encode('utf-8'), wire)
        self.assertEqual(json.loads(wire)['names'], names)

    def test_port_in_use_exits_with_a_message(self):
        def busy(address, handler):
            raise OSError(10048, "address already in use")
        with patch.object(helper, "ThreadingHTTPServer", side_effect=busy), patch.object(helper, "log") as log:
            with self.assertRaises(SystemExit):
                helper.bind("127.0.0.1", 47820)
        self.assertIn("another --port", " ".join(str(c) for c in log.call_args_list))


if __name__ == "__main__":
    unittest.main()


class UpdateCheckTests(unittest.TestCase):
    def test_versions_compare_numerically(self):
        self.assertTrue(helper.newer("0.10.0", "0.9.3"))
        self.assertTrue(helper.newer("v1.0", "0.8.0"))
        self.assertFalse(helper.newer("0.8.0", "0.8.0"))
        self.assertFalse(helper.newer("0.8.0-beta", "0.7.0"))
        self.assertFalse(helper.newer(None, "0.8.0"))

    def test_check_saves_latest_and_restart_reuses_it(self):
        with tempfile.TemporaryDirectory() as d:
            now = [1000.0]
            u = helper.Updates(d, fetch=lambda: {"tag_name": "v99.1.0",
                                                 "html_url": "https://github.com/themazzy/cargo-earth/releases/tag/v99.1.0"},
                               clock=lambda: now[0])
            self.assertTrue(u.due())
            with patch.object(helper, "log"):
                u.check()
            info = u.info()
            self.assertEqual(info["latest"], "99.1.0")
            self.assertTrue(info["helperOutdated"])
            self.assertFalse(u.due())
            again = helper.Updates(d, fetch=lambda: self.fail("asked again"), clock=lambda: now[0] + 60)
            self.assertEqual(again.info()["latest"], "99.1.0")
            self.assertFalse(again.due())
            # a release published since: a helper restarted 10 minutes later asks GitHub again
            later = helper.Updates(d, fetch=lambda: {}, clock=lambda: now[0] + helper.UPDATE_RESTART_S)
            self.assertTrue(later.due())
            self.assertFalse(u.due())
            now[0] += helper.UPDATE_EVERY_S
            self.assertTrue(u.due())

    def test_save_load_recheck_is_rate_limited(self):
        with tempfile.TemporaryDirectory() as d:
            now = [1000.0]
            calls = []
            u = helper.Updates(d, fetch=lambda: calls.append(1) or {"tag_name": "v1.0.0"}, clock=lambda: now[0])
            with patch.object(helper, "log"):
                u.check()
                self.assertEqual(len(calls), 1)
                self.assertFalse(u.recheck()["checking"])  # asked a moment ago
                now[0] += helper.UPDATE_ON_LOAD_S
                with patch.object(helper.threading, "Thread") as T:
                    T.return_value.start.side_effect = lambda: T.call_args.kwargs["target"]()
                    self.assertTrue(u.recheck()["checking"])
            self.assertEqual(len(calls), 2)
            self.assertFalse(u.busy)
            self.assertFalse(helper.Updates(d, enabled=False).recheck()["checking"])

    def test_foreign_url_is_never_opened_and_failure_retries_sooner(self):
        with tempfile.TemporaryDirectory() as d:
            now = [0.0]
            u = helper.Updates(d, fetch=lambda: {"tag_name": "v0.0.1", "html_url": "https://evil.example/x"}, clock=lambda: now[0])
            u.check()
            self.assertTrue(u.info()["url"].startswith(helper.UPDATE_PAGE))
            self.assertFalse(u.info()["helperOutdated"])

            def boom():
                raise OSError("offline")
            bad = helper.Updates(os.path.join(d, "x"), fetch=boom, clock=lambda: now[0])
            with patch.object(helper, "log"):
                bad.check()
            self.assertEqual(bad.info()["error"], "offline")
            now[0] += helper.UPDATE_RETRY_S
            self.assertTrue(bad.due())
            self.assertFalse(helper.Updates(d, enabled=False).due())



class OsmTileTests(unittest.TestCase):
    def test_tiles_come_from_openfreemap_and_stay_on_disk(self):
        import gzip
        asked = []

        def get(url):
            asked.append(url)
            if url == helper.OsmTiles.TILEJSON:
                return json.dumps({"tiles": ["https://tiles.openfreemap.org/planet/20251119_001001_pt/{z}/{x}/{y}.pbf"]}).encode()
            return gzip.compress(b"tile-bytes")

        with tempfile.TemporaryDirectory() as cache:
            osm = helper.OsmTiles(cache, get=get)
            self.assertEqual(osm.tile(14, 8848, 5550), b"tile-bytes")
            self.assertEqual(asked[-1], "https://tiles.openfreemap.org/planet/20251119_001001_pt/14/8848/5550.pbf")
            self.assertEqual(osm.tile(14, 8848, 5550), b"tile-bytes")
            self.assertEqual(len(asked), 2, "the second time from disk")
            osm.tile(14, 8848, 5551)
            self.assertEqual(len(asked), 3, "the tile address is asked once")
            with self.assertRaises(ValueError):
                osm.tile(15, 0, 0)
            with self.assertRaises(ValueError):
                osm.tile(14, 2 ** 14, 0)

    def test_only_openfreemap_addresses(self):
        with tempfile.TemporaryDirectory() as cache:
            osm = helper.OsmTiles(cache, get=lambda url: json.dumps({"tiles": ["https://evil.example/{z}/{x}/{y}"]}).encode())
            with self.assertRaises(ValueError):
                osm.tile(14, 1, 1)
            self.assertEqual(osm.stats["failed"], 1)

    def test_same_tile_fetched_at_once_by_two_phones(self):
        import threading as th
        gate = th.Barrier(2)

        def get(url):
            if url == helper.OsmTiles.TILEJSON:
                return json.dumps({"tiles": ["https://tiles.openfreemap.org/planet/v/{z}/{x}/{y}.pbf"]}).encode()
            if url.endswith("/1/1.pbf"):
                gate.wait(5)
            return b"tile"

        with tempfile.TemporaryDirectory() as cache:
            osm = helper.OsmTiles(cache, get=get)
            osm.tile(14, 1, 0)  # TileJSON read first
            got, errors = [], []

            def ask():
                try:
                    got.append(osm.tile(14, 1, 1))
                except Exception as e:
                    errors.append(e)

            threads = [th.Thread(target=ask) for _ in range(2)]
            for t in threads:
                t.start()
            for t in threads:
                t.join(10)
            self.assertEqual(errors, [])
            self.assertEqual(got, [b"tile", b"tile"])
            self.assertEqual(sorted(os.listdir(os.path.join(cache, "osm", "14", "1"))), ["0.pbf", "1.pbf"])
            self.assertFalse([n for n in os.listdir(os.path.join(cache, "osm", "14", "1")) if n.endswith(".tmp")])

    def test_old_tiles_are_dropped(self):
        with tempfile.TemporaryDirectory() as cache:
            osm = helper.OsmTiles(cache, get=lambda url: b"x")
            osm.MAX_FILES = 2
            for i in range(4):
                path = os.path.join(cache, "osm", "14", "1", f"{i}.pbf")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as f:
                    f.write(b"x")
                os.utime(path, (i, i))
            osm._prune()
            self.assertEqual(sorted(os.listdir(os.path.join(cache, "osm", "14", "1"))), ["2.pbf", "3.pbf"])
