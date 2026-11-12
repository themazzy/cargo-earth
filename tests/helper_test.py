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
        self.assertEqual(helper.depot_kind("oil_refiners", None, None), "fuel")
        self.assertIsNone(helper.depot_kind("gas_station", None, None))
        self.assertIsNone(helper.depot_kind("restaurant", "food", None))
        self.assertIsNone(helper.depot_kind(None, None, None))

    def test_place_query_keeps_workplaces_out_of_food_orders(self):
        rows = [
            ("full-warehouse-id-123456789", " Warehouse ", "industrial", "warehouse", "industrial warehouse", 42.65, 23.35, "Sofia", False),
            ("full-grocery-id", "Grocer", "food_and_beverage_store", "grocery_store", "retail grocery_store", 42.66, 23.35, "Sofia", True),
            ("full-food-id", "Cafe", "cafe", "cafe", "food cafe", 42.67, 23.35, "Sofia", False),
            ("full-station-id-0123456789", "Petrol", "gas_station", "gas_station", "automotive gas_station", 42.68, 23.35, None, False),
            ("full-charger-id-0123456789", None, "ev_charging_station", "ev_charging_station", "automotive", 42.69, 23.35, "Sofia", False),
        ]
        con = Connection(rows)
        builder = object.__new__(helper.Builder)
        builder._con = lambda *args: (con, ["local.parquet"])
        food, depots, stations = builder.places((23.3, 42.6, 23.4, 42.7))
        self.assertEqual(len(food), 2)
        self.assertEqual(len(depots), 2)
        self.assertEqual([s[3:5] for s in stations], [["Petrol", "f"], ["Charging station", "e"]])
        self.assertEqual(stations[0][0], "ofull-station-id-")
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
        ], [["oa", 42.66, 23.36, "Petrol", "f", ""], ["ob", 1, 1, "Far", "f", ""]])
        builder.addresses = lambda box: [[42.65, 23.35, "Street 12", "Sofia"]] * 31
        data = builder.build(426, 233)
        self.assertEqual([d["id"] for d in data["depots"]], ["yard"])
        self.assertEqual(data["fuel"], [["oa", 42.66, 23.36, "Petrol", "f", "Sofia"]])
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
        player.play("http://s/2", 0.5)               # its clock never moves: reported as stuck
        now[0] += helper.PLAYER_OPEN_S + 1
        self.assertTrue(player.status()["stuck"])
        with tempfile.TemporaryDirectory() as cache:
            radio = helper.Radio(cache, lambda cc: [], servers=lambda: ["x"])
            radio.state["CZ"] = [["00000000-0000-0000-0000-000000000001", "A", "http://a", "MP3", 0, "", ""]]
            self.assertEqual(radio.url_of("00000000-0000-0000-0000-000000000001"), "http://a")
            self.assertIsNone(radio.url_of("00000000-0000-0000-0000-000000000002"))
            self.assertIsNone(radio.url_of("http://evil"))

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
            now[0] += helper.UPDATE_EVERY_S
            self.assertTrue(u.due())

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
