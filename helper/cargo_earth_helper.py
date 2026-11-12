"""Cargo Earth helper: nearby workplaces, restaurants, grocery stores and home addresses.

BeamNG's game Lua may only connect to programs on the same computer, so this small program does the downloading: it
reads Overture Maps places and addresses around the player straight from Overture's public bucket (only
the parts of the files it needs, with HTTP Range requests, cached on disk) and serves them to the mod on
http://127.0.0.1:<port>. Where a place has no addresses in Overture, houses (building outlines) are the customers.

Run it as a BeamNG.Earth add-on (its Add-ons page, kind "companion": BeamNG.Earth's own Python runs it, "Start with
BeamNG.Earth" starts it every time), or by hand:  python3 cargo_earth_helper.py [--port 47820] [--cache DIR]
Needs duckdb and fsspec (both come with BeamNG.Earth).  python3 cargo_earth_helper.py --test LAT,LON  builds one area
and prints what it found.

API (GET, JSON):
  /                           a small status page for people (is it running, libraries, areas, network)
  /v1/info                    {"app": "cargo-earth-helper", "version", "release", "update": {"latest", "url", "page",
                              "helper", "helperOutdated", "checkedAt", "error"}} (the newest Cargo Earth release on
                              GitHub, checked every 6 hours unless --no-update-check)
  /v1/update/open             opens that release page in the browser: {"opened", "url"}
  /v1/cameras?lat=..&lon=..   speed cameras around the point, from OpenStreetMap (Overpass API, one request per
                              0.5 degree cell, kept for 30 days): {"state": "ready" | "loading" | "failed",
                              "cells": [...], "cameras": [[id, lat, lon, limit km/h (0 = unknown), road class], ...]}
  /v1/radio?cc=CZ&lat=..&lon=..  internet radio stations of the country, from Radio Browser (one request per country a
                              day): {"state": "ready" | "loading" | "failed", "country", "top": [[id, name, stream url,
                              codec, kbps, tags, region], ...] (most listened first), "near": [[... the same, km], ...]}
  /v1/radioclick?id=uuid      tells Radio Browser a station started playing (its listening counts)
  /v1/player/play?id=uuid&vol=0.6, /v1/player/volume?vol=.., /v1/player/stop, /v1/player/alive
                              the helper plays a listed station itself (when the game's UI cannot); alive is the
                              heartbeat: {"playing", "url", "vol", "secs", "error", "player"}
  /v1/near?lat=..&lon=..      the 3 x 3 areas around the point: {"ready": ["r_c", ...], "loading": n, "failed": n,
                              "errors": [...], "grocers": true, "depots": true, "fuel": true}; builds missing areas
                              nearest first
  /v1/area?key=r_c            one ready area: {"key", "restaurants": [[id, lat, lon, curbLat, curbLon, name, cat, town],
                              ...], "grocers": [rows in the same format],
                              "fuel": [[id, lat, lon, name, "f" (fuel) | "e" (charger), town], ...], "tiles": {"row_col":
                              [[lat, lon, curbLat, curbLon, label, town], ...]}, "houses": bool,
                              "depots": [{id, n, g: [lat, lon], t: "yard" | "shop", town, source, access}, ...]}
Areas are AREA x AREA degrees (r = floor(lat / AREA), c = floor(lon / AREA)); address tiles inside are TILE degrees,
the same keys as the mod's own data pack (food_CZ/a/<row>_<col>.json).

Data: Overture Maps Foundation, places (CDLA-Permissive-2.0), addresses (sources' licences), buildings (ODbL and
others); https://docs.overturemaps.org/attribution/
Speed cameras: (c) OpenStreetMap contributors, ODbL; https://www.openstreetmap.org/copyright
Radio stations: Radio Browser (https://www.radio-browser.info), free community directory; the streams belong to the stations
"""
import argparse
import datetime
import hashlib
import html
import importlib.util
import json
import math
import os
import re
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.8.0"
AREA_CACHE_VERSION = "5"  # fuel depots for tanker runs; retain existing downloaded Parquet blocks
RELEASE = "2026-10-21.0"
BUCKET = "https://overturemaps-us-west-2.s3.us-west-2.amazonaws.com"
STAC_ROOT = "https://stac.overturemaps.org"
AREA = 0.1                 # area size, degrees (about 11 x 7 km in central Europe)
TILE = 0.05                # address tile size, degrees (as the mod's packs)
MIN_CONF = 0.7             # restaurants: Overture's confidence
CELL_M = 100               # one customer per this grid cell, metres
HOUSES_BELOW = 30          # fewer addresses than this in an area: houses (building outlines) are the customers too
HOUSE_M2 = (40, 600)       # a house's footprint, m2
BLOCK = 1 << 16            # range-read block, bytes (cached on disk)
WORKERS = 2                # areas built at once
MAX_AREA_BYTES = 8 * 1024 * 1024
NETWORK = {"requests": 0, "bytes": 0, "range_requests": 0}
NETWORK_LOCK = threading.Lock()
FUEL = {"gas_station": "f", "truck_gas_station": "f", "ev_charging_station": "e"}   # place category -> what it sells
FUEL_MIN_CONF = 0.5        # a filling station is a plain fact; fewer false ones than among restaurants
FOOD = {"restaurant", "fast_food_restaurant", "casual_eatery", "cafe", "coffee_shop", "food_truck_stand", "food_court"}
CATS = [  # (category id, regex on the place's taxonomy); the same as the mod's Czech pack (depot-builder/build_food.py)
    ("pizza", r"pizza"), ("burger", r"burger"),
    ("asian", r"asian|chinese|vietnam|thai|japan|sushi|korean|indian|pho|ramen|noodle"),
    ("kebab", r"kebab|turkish|middle_eastern|falafel|gyro|mediterranean|greek|lebanese"),
    ("italian", r"italian|pasta"), ("mexican", r"mexican|latin|taco|burrito"),
    ("cafe", r"cafe|coffee|bakery|pastry|dessert|cake|bagel|breakfast"),
    ("fastfood", r"fast_food|chicken|hot_dog|sandwich|fried|fish_and_chips"),
    ("czech", r"czech|european|traditional|pub|beer_garden|brasserie|gastropub|german|austrian"),
]
CATS_RX = [(c, re.compile(r)) for c, r in CATS]

# Geographic business categories identify candidates, not certified loading bays.
# Cargo relationships below are fictional gameplay rules, not claims about the real businesses.
DEPOT_RULES = [
    ("fuel", r"fuel_depot|fuel_terminal|oil_refiner|petroleum|oil_and_gas|fuel_supplier"),
    ("yard", r"warehous|distribution|logistics|wholesale|courier|freight|shipping|manufactur|industrial|factory|sawmill|lumber"),
    ("shop", r"hardware|home_improvement|building_material|furniture|electronics|appliance|auto_parts|grocery|supermarket|hypermarket|department_store"),
]
DEPOT_RX = [(kind, re.compile(pattern)) for kind, pattern in DEPOT_RULES]
DEPOT_SQL_RX = "|".join(pattern for _, pattern in DEPOT_RULES)


def depot_kind(primary, hierarchy, basic):
    taxonomy = " ".join(str(value or "") for value in (primary, hierarchy, basic)).lower()
    for kind, pattern in DEPOT_RX:
        if pattern.search(taxonomy):
            return kind
    return None

# Which files of the release cover which box: [name, [xmin, ymin, xmax, ymax], size]. Places from Overture's STAC
# index, addresses from the files' own row-group statistics (read 2026-11-09). Another release: built again on the fly.
EMBEDDED = json.loads('{"places/place":[["part-00000-a0a9949b-7e8e-59fe-803b-6cc55b17f790-c000.zstd.parquet",[-179.9981,-84.9901,-74.9132,28.3447],729511821],["part-00001-95b3bb67-399f-571e-9503-61421d57661c-c000.zstd.parquet",[-120.6488,28.3447,-76.4124,34.7701],810722286],["part-00002-6f03d044-7fc3-539e-842b-7b15c796e629-c000.zstd.parquet",[-179.8171,34.7701,-87.9379,81.752],814700009],["part-00003-755a53ba-2d37-54c8-b30e-8c14897bc3f3-c000.zstd.parquet",[-87.9379,34.7701,-74.9132,82.7833],826418126],["part-00004-14b83d8c-d850-51f9-85b2-8f8a0b4634af-c000.zstd.parquet",[-74.9105,-84.9283,3.8745,-20.0129],712441815],["part-00005-c3667754-428e-500c-bf3b-a0b5921b7cc0-c000.zstd.parquet",[-74.9132,-20.0129,4.383,40.6943],720677975],["part-00006-55d446f6-129a-556e-b79e-e1cfd5735068-c000.zstd.parquet",[-74.9132,40.6943,-1.5036,83.5715],755632071],["part-00007-a2c7689b-daa2-5233-9780-d37ccfc3ea74-c000.zstd.parquet",[-1.5036,40.6944,4.3831,60.8553],725017426],["part-00008-8b09f6c1-f726-581a-9b39-f891088cc2ad-c000.zstd.parquet",[4.3833,-84.543,35.85,42.225],721833497],["part-00009-fe90ff49-733f-5fa3-9755-c6cd4438305c-c000.zstd.parquet",[4.3831,42.225,35.8445,47.6986],713205738],["part-00010-c680fdf1-f03b-5be1-93f1-56c835a00765-c000.zstd.parquet",[4.3831,47.6986,35.8499,51.4741],723633922],["part-00011-472205f3-e3ff-5474-98a4-b9b3361f7306-c000.zstd.parquet",[4.3831,51.4741,35.8498,80.5055],714390669],["part-00012-8cf9bdfe-d946-56f8-84c0-19493d0fbb9c-c000.zstd.parquet",[35.85,-84.9799,106.4591,18.79],730097847],["part-00013-6c366648-1364-543e-894b-d6e65d03c056-c000.zstd.parquet",[106.4591,-84.8864,179.9976,18.7881],719333214],["part-00014-dcceff87-235e-5a0e-a4b4-5f25ccb873e7-c000.zstd.parquet",[35.85,18.79,104.2679,81.8431],744601106],["part-00015-eb1c1331-f519-5db6-8fef-74a77e5776ff-c000.zstd.parquet",[104.2679,18.7901,179.9556,77.1],733499664]],"addresses/address":[["part-00000-c44357eb-9a65-5104-b485-af7f0be62da4-c000.zstd.parquet",[-176.8745,-44.2591,-99.7396,21.8634],396310089],["part-00001-e6512f5d-8e51-5d4e-8ec6-e662624e3788-c000.zstd.parquet",[-99.7396,16.0897,-97.5896,21.8547],400909175],["part-00002-afd2a599-4cd8-55a2-9746-5d533c93e617-c000.zstd.parquet",[-117.2573,21.8634,-102.1315,32.7418],425797673],["part-00003-b938da94-7ac4-58f4-aaeb-56a6c3b2b564-c000.zstd.parquet",[-102.1316,21.8634,-97.5896,32.7418],463773363],["part-00004-840e4c45-87f6-5cd9-afcc-2a36efc5379e-c000.zstd.parquet",[-97.5896,-0.2004,-74.4655,19.1217],353119632],["part-00005-ce12b8e6-6f9a-592f-9e4c-1a161bbdb588-c000.zstd.parquet",[-97.5896,19.1217,-80.0314,27.6431],398882815],["part-00006-3e54d273-9691-55f0-a6d0-69a424c9f65f-c000.zstd.parquet",[-97.5896,27.7505,-86.571,32.7418],532113940],["part-00007-35c895dc-c928-5020-8e73-8f1354d4ac2e-c000.zstd.parquet",[-86.571,27.6431,-80.3525,32.7418],451786048],["part-00008-b60c2743-2fe9-5dc1-8977-57d4589c56e7-c000.zstd.parquet",[-73.8478,-54.938,-52.3744,-25.391],409203006],["part-00009-ce3cdfaa-c2cd-5ff3-8d2f-43d8e143209a-c000.zstd.parquet",[-52.3744,-32.474,-48.1926,-25.391],406745905],["part-00010-f0ba84f5-937d-52f2-b838-d9643b395c1f-c000.zstd.parquet",[-70.458,-25.391,-46.7819,-22.7914],397556902],["part-00011-6c2a0d83-2856-5246-96a0-928e1ba0ad30-c000.zstd.parquet",[-46.7819,-24.1832,-44.47,-22.7914],375346604],["part-00012-77045553-2ca1-543b-b3f3-ce9c8dab80dc-c000.zstd.parquet",[-70.3285,-22.7914,-48.2891,-15.7156],408293753],["part-00013-e4589c5b-f3d5-564f-85ad-b5a8efe8d906-c000.zstd.parquet",[-48.2891,-22.7914,-44.4699,-15.7156],406372509],["part-00014-b303ac44-075c-5fff-a091-df8778cc0a9b-c000.zstd.parquet",[-73.665,-15.7156,-44.4699,-3.0541],426030819],["part-00015-267d55a0-3068-5a6d-bce8-c1c64737ce14-c000.zstd.parquet",[-74.4655,-3.0541,-44.4699,18.3655],370050261],["part-00016-bee8259d-b394-5226-b61e-b8223dbfda73-c000.zstd.parquet",[-166.5914,37.0096,-122.1694,69.4542],446728446],["part-00017-4ae842e7-9273-5948-89f7-af031518a4e8-c000.zstd.parquet",[-122.1694,33.3754,-118.3788,61.8706],449138168],["part-00018-d1b0d746-294d-516e-af97-9f82110ded44-c000.zstd.parquet",[-118.3788,32.7418,-105.9812,34.1079],451567357],["part-00019-eaaaf030-b755-5fe9-b72c-2c04f7d833ed-c000.zstd.parquet",[-118.3788,34.1079,-105.9812,67.8285],483425936],["part-00020-5452a30a-8a9f-56c5-9435-9d9af4d0fe81-c000.zstd.parquet",[-105.9812,32.7418,-94.1448,39.6402],519667557],["part-00021-a06a2fa3-5561-5122-a74a-1bfa66544ad9-c000.zstd.parquet",[-94.1448,32.7418,-86.7107,39.6402],533657904],["part-00022-53d85508-2af1-5a35-b399-32995ad85627-c000.zstd.parquet",[-105.9812,39.6402,-86.7107,42.1018],502353033],["part-00023-ac7821d9-f0a1-50d6-9f8b-cbad4142723d-c000.zstd.parquet",[-105.9807,42.1018,-86.8391,69.1223],498551536],["part-00024-cc2f7e7b-0f5d-5238-8a64-c85be70c933b-c000.zstd.parquet",[-86.7107,32.7418,-80.0343,37.2087],525727353],["part-00025-acfa519a-e5c8-51e5-b896-4f12a4619f4b-c000.zstd.parquet",[-86.7107,37.2087,-80.0342,40.7098],541019519],["part-00026-f573c251-3367-58c7-8a0e-0ec5b0dddabb-c000.zstd.parquet",[-80.0343,33.844,-76.9867,40.7097],530000479],["part-00027-f6c3761e-52a8-540b-9b57-1b95a71b5c3d-c000.zstd.parquet",[-76.9867,34.6708,-72.9968,40.7098],509785512],["part-00028-5a71bcfb-241e-5122-80b5-a44e643fd8f3-c000.zstd.parquet",[-86.7107,40.7097,-73.997,42.9615],507804698],["part-00029-dcffa920-532b-5b56-b485-3defbdf642fe-c000.zstd.parquet",[-86.4607,42.9615,-73.997,62.4201],413816227],["part-00030-da1ff535-9232-568d-9216-a4e758608459-c000.zstd.parquet",[-73.997,40.7097,-69.9305,42.736],442277459],["part-00031-71140f43-3232-5c76-94af-996f899d671b-c000.zstd.parquet",[-73.997,42.736,-44.6561,77.7865],427663477],["part-00032-f1bd2776-8dd3-54db-881f-cd1f38d75a81-c000.zstd.parquet",[-44.4699,-23.2186,-40.7825,-20.8493],387058354],["part-00033-ad38b3a3-2229-5e59-8359-ae1ff6e86183-c000.zstd.parquet",[-44.4699,-20.8493,-40.7825,-7.2056],415261782],["part-00034-8684e828-acad-5fcd-9adf-d8fbcec49c90-c000.zstd.parquet",[-40.7825,-20.9076,-38.3313,-7.2055],408789354],["part-00035-d4096140-2468-5072-ae2d-36c348a4f32a-c000.zstd.parquet",[-38.3313,-12.9406,-34.7952,-7.2055],406988339],["part-00036-b64540e2-fa46-574b-b72c-d8f411af3e0e-c000.zstd.parquet",[-44.4699,-7.2055,-32.3982,-3.7382],412380423],["part-00037-685b6988-31f0-54fc-ac2a-b70965649583-c000.zstd.parquet",[-44.4699,-3.7382,-8.0944,42.6525],384549505],["part-00038-8fd7182d-8556-5b0b-bcb0-ad2851859657-c000.zstd.parquet",[-8.0944,35.2667,8.8318,39.983],467878293],["part-00039-ca8d1765-1721-55a4-9b5c-7fd0e9747501-c000.zstd.parquet",[-8.0944,39.983,8.8318,42.6525],468566899],["part-00040-75cc20ee-ed31-551e-87de-43a8b3efaf41-c000.zstd.parquet",[-44.2882,42.6525,-0.0774,70.7446],453770460],["part-00041-3551e56c-a859-5f98-b803-9219805091ef-c000.zstd.parquet",[-0.0774,42.6525,2.4836,51.0664],441806658],["part-00042-6a84135d-6ece-5560-8eda-a7b5cf9e9e65-c000.zstd.parquet",[2.4836,42.6525,4.813,50.7693],424404912],["part-00043-bf5f8313-1e1b-5798-870b-e1ca9fdb3897-c000.zstd.parquet",[2.4836,50.7693,4.813,61.6389],351612733],["part-00044-5bd8836b-244c-5b6c-b90b-0f4c877c9933-c000.zstd.parquet",[4.813,42.9831,8.8318,47.3119],441191627],["part-00045-9603784b-4676-503b-b261-ea0be415bd9e-c000.zstd.parquet",[4.813,47.3119,8.8318,50.6255],432766114],["part-00046-4088d28f-c429-55c8-a213-b5289ec2fa1e-c000.zstd.parquet",[4.813,50.6255,8.8318,51.9582],439041527],["part-00047-4ff97c76-bfed-58d6-9cc5-af87955b1415-c000.zstd.parquet",[4.813,51.9582,8.8318,63.8741],430384476],["part-00048-6fabe1b4-f0bf-5ded-baab-b79a42240bd2-c000.zstd.parquet",[8.8318,35.5017,18.5076,40.7999],411049800],["part-00049-30b7ddcc-8bf9-5e5e-a5dd-aace7d28fd23-c000.zstd.parquet",[8.8318,40.7999,21.2793,43.5322],421906722],["part-00050-a7cbd1e2-6bdf-5f2e-b5c3-431a91eb1257-c000.zstd.parquet",[8.8318,43.5322,11.7227,47.2092],435638549],["part-00051-cade5724-e2c4-56e0-8827-55bd035a565f-c000.zstd.parquet",[11.7227,43.5322,21.2793,47.2092],434698334],["part-00052-141d2213-2820-5b2c-a6aa-6edbddba5fbb-c000.zstd.parquet",[8.8318,47.2092,15.0551,51.5903],433268383],["part-00053-e3166b68-761b-5abb-9b5c-491db8dddcb4-c000.zstd.parquet",[15.0551,47.2092,21.2793,51.5903],493373592],["part-00054-6ef66ac1-9df1-540f-9df0-f856819cc902-c000.zstd.parquet",[8.8318,51.5903,21.2793,53.9441],495179614],["part-00055-5bbbf98d-0f68-521e-8ab3-47640b5d6cc9-c000.zstd.parquet",[8.8318,53.9441,21.2793,78.3384],412780874],["part-00056-5ac3af38-6d76-5966-a765-dea871fdf9d0-c000.zstd.parquet",[45.0475,-35.0975,120.9656,25.0636],384237714],["part-00057-04cc2a04-912b-5810-b4af-fe1c2ffd288c-c000.zstd.parquet",[120.9656,-35.0094,136.1993,33.546],324494004],["part-00058-1f188281-69df-52f8-90ca-5e824e7411b4-c000.zstd.parquet",[21.2793,42.2393,25.3652,71.1096],511827241],["part-00059-63968199-20d8-57e7-a819-8dc4adb46917-c000.zstd.parquet",[25.3652,33.546,136.1993,71.1698],398356845],["part-00060-c466f1bb-bcaf-5ce5-81ef-598a75c47851-c000.zstd.parquet",[136.1993,-43.583,150.9096,-27.4159],374830956],["part-00061-55c59714-619e-5fe1-b52f-bb493ada6f27-c000.zstd.parquet",[150.9096,-46.909,178.5453,-27.4159],357751254],["part-00062-7eecbdb8-7b10-5a4c-974a-9757b4c9bb9e-c000.zstd.parquet",[136.1993,-27.4159,166.9089,35.6475],316593129],["part-00063-13ab5e0c-a2c8-50b6-a751-da6887045332-c000.zstd.parquet",[136.1993,35.6475,145.6201,45.4487],314720552]]}')


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


######################################################################################## remote files, cached in blocks

class Remote:
    """Byte ranges of one remote file, in BLOCK-sized blocks kept on disk (a release's files never change)."""

    def __init__(self, url, size, cache_dir):
        self.url, self.size = url, size
        self.dir = os.path.join(cache_dir, "blocks", hashlib.sha1(url.encode()).hexdigest()[:20])
        self.lock = threading.RLock()

    def _block(self, i):
        path = os.path.join(self.dir, f"{i}.blk")
        with self.lock:
            try:
                with open(path, "rb") as f:
                    data = f.read()
                if len(data) == min(BLOCK, self.size - i * BLOCK):
                    touch_cache(path)
                    return data
            except OSError:
                pass
            self._fetch_run(i, i)
            with open(path, "rb") as f:
                return f.read()

    def _have(self, i):
        try:
            return os.path.getsize(os.path.join(self.dir, f"{i}.blk")) == min(BLOCK, self.size - i * BLOCK)
        except OSError:
            return False

    def _fetch_run(self, i, j):
        """Blocks i..j in one Range request, each kept as its own file."""
        a, b = i * BLOCK, min(self.size, (j + 1) * BLOCK) - 1
        data = http_get(self.url, {"Range": f"bytes={a}-{b}"})
        if len(data) != b - a + 1:
            raise ValueError("incomplete byte range; cache left unchanged")
        os.makedirs(self.dir, exist_ok=True)
        for k in range(i, j + 1):
            path = os.path.join(self.dir, f"{k}.blk")
            tmp = f"{path}.{threading.get_ident()}.tmp"
            with open(tmp, "wb") as f:
                f.write(data[(k - i) * BLOCK:(k - i + 1) * BLOCK])
            os.replace(tmp, path)

    def read(self, start, end):
        if start < 0 or end < start:
            raise ValueError("invalid byte range")
        end = min(end, self.size)
        if start >= end:
            return b""
        # Single flight per remote file. No tasks recursively wait on the shared worker pool.
        with self.lock:
            first, last = start // BLOCK, (end - 1) // BLOCK
            missing = [i for i in range(first, last + 1) if not self._have(i)]
            runs = []
            for i in missing:
                if runs and runs[-1][1] == i - 1 and i - runs[-1][0] < 64:
                    runs[-1][1] = i
                else:
                    runs.append([i, i])
            for run in runs:
                self._fetch_run(*run)
            buf = b"".join(self._block(i) for i in range(first, last + 1))
            off = start - first * BLOCK
            return buf[off:off + (end - start)]


from concurrent.futures import ThreadPoolExecutor
POOL = ThreadPoolExecutor(8)


def http_get(url, headers=None, tries=4):
    err = None
    headers = dict(headers or {}, **{"User-Agent": f"cargo-earth-helper/{VERSION}"})
    requested = re.fullmatch(r"bytes=(\d+)-(\d+)", headers.get("Range", ""))
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with NETWORK_LOCK:
                NETWORK["requests"] += 1
                NETWORK["range_requests"] += int(requested is not None)
            with urllib.request.urlopen(req, timeout=20) as r:
                limit = MAX_AREA_BYTES
                if requested:
                    start, end = map(int, requested.groups())
                    received = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", r.headers.get("Content-Range", ""))
                    if r.status != 206 or not received or tuple(map(int, received.groups()[:2])) != (start, end):
                        raise ValueError("server did not honour requested byte range")
                    limit = end - start + 1
                data = r.read(limit + 1)
                with NETWORK_LOCK:
                    NETWORK["bytes"] += len(data)
                if len(data) > limit or (requested and len(data) != limit):
                    raise ValueError("unexpected HTTP response length")
                return data
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                raise
            err = e
        except OSError as e:
            err = e
        if k + 1 < tries:
            time.sleep(1.5 * (k + 1))
    raise err


def touch_cache(path):
    """Approximate LRU without writing filesystem metadata for every small block read."""
    try:
        if time.time() - os.path.getmtime(path) > 300:
            os.utime(path, None)
    except OSError:
        pass


class CacheBudget:
    """Prune only this helper's blocks/area files, with an absolute-path boundary check."""
    def __init__(self, root, megabytes=1024):
        self.root = os.path.realpath(root)
        self.limit = megabytes * 1024 * 1024
        self.last = 0
        self.lock = threading.Lock()
        self.stats = {"bytes": 0, "removed": 0, "limit": self.limit}

    def prune(self, pinned=(), force=False):
        with self.lock:
            if not force and time.monotonic() - self.last < 300:
                return
            self.last = time.monotonic()
            pinned = {os.path.normcase(os.path.realpath(p)) for p in pinned}
            files = []
            for sub, extension in (("blocks", ".blk"), ("areas", ".json")):
                for directory, _, names in os.walk(os.path.join(self.root, sub), followlinks=False):
                    for name in names:
                        if not name.endswith(extension):
                            continue
                        path = os.path.realpath(os.path.join(directory, name))
                        try:
                            inside = os.path.normcase(os.path.commonpath((self.root, path))) == os.path.normcase(self.root)
                        except ValueError:
                            inside = False
                        if not inside:
                            continue
                        try:
                            st = os.stat(path)
                            files.append((st.st_mtime, st.st_size, path))
                        except OSError:
                            pass
            total = sum(item[1] for item in files)
            removed = 0
            for _, size, path in sorted(files):
                if total <= self.limit:
                    break
                if os.path.normcase(path) in pinned:
                    continue
                try:
                    # Readers may have refreshed/replaced a candidate since the scan.
                    if time.time() - os.path.getmtime(path) < 30:
                        continue
                    os.unlink(path)
                    total -= size
                    removed += 1
                except OSError:
                    pass
            self.stats = {"bytes": total, "removed": removed, "limit": self.limit}


def make_fs(remotes):
    """An fsspec filesystem over Remote files for DuckDB (no DuckDB extension needed)."""
    from fsspec.spec import AbstractFileSystem, AbstractBufferedFile

    class RFile(AbstractBufferedFile):
        def _fetch_range(self, start, end):
            return self.fs.remotes[self.path].read(start, end)

    class RangeFS(AbstractFileSystem):
        protocol = "cargoearth"

        def __init__(self, **kw):
            super().__init__(**kw)
            self.remotes = remotes

        def _strip(self, path):
            return path.split("://", 1)[-1]

        def info(self, path, **kw):
            p = self._strip(path)
            return {"name": p, "size": self.remotes[p].size, "type": "file"}

        def modified(self, path):
            return datetime.datetime(2026, 1, 1)

        def ls(self, path, detail=True, **kw):
            return [self.info(path)] if detail else [self._strip(path)]

        def _open(self, path, mode="rb", block_size=None, **kw):
            p = self._strip(path)
            return RFile(self, p, mode, block_size=BLOCK, cache_type="none", size=self.remotes[p].size)

    RangeFS.cachable = False
    return RangeFS()


######################################################################################## which files cover a box

class Index:
    """Per theme/type: the release's files with their boxes."""

    def __init__(self, release, cache_dir):
        self.release, self.cache_dir = release, cache_dir
        self.files = {}
        self.lock = threading.Lock()
        self.key_locks = {}
        if release == RELEASE:
            self.files.update({k: v for k, v in EMBEDDED.items()})
        bundled = find_bne_index(release)
        if bundled:
            for k, rows in bundled.items():
                self.files.setdefault(k, [[r[0], r[1], int(r[3])] for r in rows["files"]])

    def url(self, key, name):
        theme, typ = key.split("/")
        return f"{BUCKET}/release/{self.release}/theme={theme}/type={typ}/{name}"

    def get(self, key):
        with self.lock:
            if key in self.files:
                return self.files[key]
            key_lock = self.key_locks.setdefault(key, threading.Lock())
        with key_lock:
            with self.lock:
                if key in self.files:
                    return self.files[key]
            path = os.path.join(self.cache_dir, "index", self.release, key.replace("/", "_") + ".json")
            try:
                with open(path, encoding="utf-8") as f:
                    rows = json.load(f)
                if not isinstance(rows, list):
                    raise ValueError("invalid file index")
            except (OSError, ValueError):
                rows = self._build(key)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                tmp = path + f".{threading.get_ident()}.tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(rows, f)
                os.replace(tmp, path)
            with self.lock:
                self.files[key] = rows
            return rows

    def _build(self, key):
        """The files' boxes from Overture's STAC index, else from each file's own row-group statistics."""
        theme, typ = key.split("/")
        try:
            coll = json.loads(http_get(f"{STAC_ROOT}/{self.release}/{theme}/{typ}/collection.json"))
            items = [ln["href"] for ln in coll["links"] if ln.get("rel") == "item"]
            boxes = coll["extent"]["spatial"]["bbox"][1:]
            if len(items) != len(boxes):
                raise ValueError("STAC items and partition bounds do not match")
            rows = []
            for href, bb in zip(items, boxes):
                item = json.loads(http_get(href))
                a = item["assets"]["aws"]
                rows.append([a["href"].rsplit("/", 1)[-1], bb, int(a["file:size"])])
            if rows:
                return rows
        except Exception as e:  # noqa: BLE001 - STAC down or blocked: the statistics instead
            log("STAC index not available:", e)
        if key == "buildings/building":
            raise RuntimeError("no index of the buildings files (needs Overture's STAC index or BeamNG.Earth's)")
        log("building the file index of", key, "from the files' statistics (once)")
        rows = []
        for name, size in list_files(self.release, theme, typ):
            rows.append([name, file_box(self.url(key, name), size, self.cache_dir), size])
        return rows


def list_files(release, theme, typ):
    s = http_get(f"{BUCKET}/?list-type=2&prefix=release/{release}/theme={theme}/type={typ}/").decode()
    return [(k.rsplit("/", 1)[-1], int(n)) for k, n in
            re.findall(r"<Key>([^<]+\.parquet)</Key>.*?<Size>(\d+)</Size>", s)]


def file_box(url, size, cache_dir):
    import duckdb
    r = Remote(url, size, cache_dir)
    con = duckdb.connect()
    con.register_filesystem(make_fs({url.split("://", 1)[1]: r}))
    q = f"""SELECT path_in_schema, min(stats_min), max(stats_max) FROM parquet_metadata('cargoearth://{url.split("://", 1)[1]}')
            WHERE path_in_schema LIKE 'bbox%' GROUP BY 1"""
    try:
        st = {p.split(", ")[-1]: (float(a), float(b)) for p, a, b in con.execute(q).fetchall()}
    finally:
        con.close()
    return [st["xmin"][0], st["ymin"][0], st["xmax"][1], st["ymax"][1]]


def find_bne_index(release):
    """BeamNG.Earth ships its release's file index (server/overture_stac_<release>.json.gz): use it when found."""
    import gzip
    name = f"overture_stac_{release}.json.gz"
    roots = [os.environ.get("BNE_SERVER_DIR", ""), os.path.dirname(sys.executable), os.getcwd()]
    for root in roots:
        d = root
        for _ in range(6):
            if not d:
                break
            for sub in ("server", os.path.join("_internal", "server"), ""):
                p = os.path.join(d, sub, name)
                if os.path.isfile(p):
                    try:
                        with gzip.open(p, "rt", encoding="utf-8") as f:
                            data = json.load(f)
                        if data.get("release") == release:
                            log("using BeamNG.Earth's file index", p)
                            return data.get("collections", {})
                    except (OSError, ValueError):
                        pass
            d = os.path.dirname(d) if os.path.dirname(d) != d else ""
    return None


def latest_release():
    s = http_get(f"{BUCKET}/?list-type=2&delimiter=/&prefix=release/").decode()
    rel = sorted(re.findall(r"<Prefix>release/([0-9][^<]*)/</Prefix>", s))
    return rel[-1] if rel else None


######################################################################################## one area

def cat_of(prim, tax, basic):
    for text in (prim or "", (tax or "") + " " + (basic or "")):
        for c, rx in CATS_RX:
            if rx.search(text):
                return c
    return "other"


class Builder:
    def __init__(self, index, cache_dir):
        self.index, self.cache_dir = index, cache_dir
        self.remotes = {}
        self.lock = threading.Lock()

    def _con(self, key, box):
        import duckdb
        rows = [r for r in self.index.get(key)
                if r[1][0] <= box[2] and r[1][2] >= box[0] and r[1][1] <= box[3] and r[1][3] >= box[1]]
        paths = []
        with self.lock:
            for name, _, size in rows:
                url = self.index.url(key, name)
                p = url.split("://", 1)[1]
                if p not in self.remotes:
                    self.remotes[p] = Remote(url, size, self.cache_dir)
                paths.append("cargoearth://" + p)
            remotes = {p.split("://", 1)[1]: self.remotes[p.split("://", 1)[1]] for p in paths}
        con = duckdb.connect(config={"threads": 2, "memory_limit": "512MB"})
        con.register_filesystem(make_fs(remotes))
        return con, paths

    @staticmethod
    def _where(box):
        return (f"bbox.xmin <= {box[2]} AND bbox.xmax >= {box[0]} AND bbox.ymin <= {box[3]} AND bbox.ymax >= {box[1]}")

    def places(self, box):
        con, paths = self._con("places/place", box)
        if not paths:
            con.close()
            return [], [], []
        food = ", ".join(f"'{c}'" for c in sorted(FOOD))
        # Overture groups grocery subtypes under food_and_beverage_store at the basic level.
        grocer = """(list_contains(taxonomy.hierarchy, 'grocery_store')
                     OR taxonomy.primary IN ('grocery_store', 'supermarket', 'hypermarket'))"""
        depot = ("regexp_matches(lower(concat_ws(' ', basic_category, taxonomy.primary, "
                 f"array_to_string(taxonomy.hierarchy, ' '))), '{DEPOT_SQL_RX}')")
        kinds = ", ".join(f"'{c}'" for c in sorted(FUEL))
        fuel = f"(coalesce(basic_category IN ({kinds}), false) OR coalesce(taxonomy.primary IN ({kinds}), false))"
        q = f"""SELECT id, names.primary, basic_category, taxonomy.primary, array_to_string(taxonomy.hierarchy, ' '),
                       (bbox.ymin + bbox.ymax) / 2, (bbox.xmin + bbox.xmax) / 2, addresses[1].locality,
                       coalesce({grocer}, false) AS is_grocer
                FROM read_parquet({paths!r}, union_by_name = true)
                WHERE {self._where(box)} AND coalesce(operating_status, 'open') = 'open'
                  AND (({fuel} AND confidence >= {FUEL_MIN_CONF})
                       OR ((basic_category IN ({food}) OR {grocer} OR {depot}) AND confidence >= {MIN_CONF}
                           AND names.primary IS NOT NULL))"""
        try:
            rows = con.execute(q).fetchall()
        finally:
            con.close()
        out, depots = [], []
        stations = []
        for pid, name, basic, prim, hier, lat, lon, town, is_grocer in rows:
            name = (name or "").strip()
            sells = FUEL.get(prim) or FUEL.get(basic)
            if sells:
                stations.append([f"o{pid[:16]}", round(lat, 6), round(lon, 6),
                                 name or ("Charging station" if sells == "e" else "Filling station"), sells,
                                 (town or "").strip()])
                continue
            if name:
                town = (town or "").strip()
                if is_grocer or basic in FOOD:
                    category = "grocery" if is_grocer else cat_of(prim, hier, basic)
                    out.append([f"o{pid[:16]}", round(lat, 6), round(lon, 6), round(lat, 6), round(lon, 6), name,
                                category, town])
                kind = depot_kind(prim, hier, basic)
                if kind:
                    depots.append({"id": "overture:" + str(pid), "n": name, "g": [round(lat, 6), round(lon, 6)],
                                   "t": kind, "town": town, "source": "Overture", "access": "candidate"})
        return out, depots, stations
    def addresses(self, box):
        con, paths = self._con("addresses/address", box)
        if not paths:
            con.close()
            return []
        q = f"""SELECT street, number, postal_city, address_levels, bbox.ymin, bbox.xmin
                FROM read_parquet({paths!r}, union_by_name = true) WHERE {self._where(box)}"""
        out = []
        try:
            rows = con.execute(q).fetchall()
        finally:
            con.close()
        for street, number, city, levels, lat, lon in rows:
            lv = [x.get("value") for x in (levels or []) if x and x.get("value")]
            town = (city or (lv[0] if lv else "") or "").strip()
            place = (street or (lv[-1] if lv else "") or town).strip()
            out.append([lat, lon, f"{place} {number or ''}".strip(), town])
        return out

    def houses(self, box):
        con, paths = self._con("buildings/building", box)
        if not paths:
            con.close()
            return []
        q = f"""SELECT (bbox.ymin + bbox.ymax) / 2, (bbox.xmin + bbox.xmax) / 2,
                       (bbox.xmax - bbox.xmin) * (bbox.ymax - bbox.ymin), class
                FROM read_parquet({paths!r}, union_by_name = true)
                WHERE {self._where(box)} AND (class IS NULL OR class IN ('house', 'detached', 'residential',
                      'semidetached_house', 'apartments', 'terrace', 'bungalow', 'farm'))"""
        out = []
        try:
            rows = con.execute(q).fetchall()
        finally:
            con.close()
        for lat, lon, deg2, _ in rows:
            m2 = deg2 * 111320 * 111320 * math.cos(math.radians(lat))
            if HOUSE_M2[0] <= m2 <= HOUSE_M2[1] * 2:      # (a bbox is larger than the footprint)
                out.append([lat, lon, "House", ""])
        return out

    def build(self, r, c):
        box = (c * AREA, r * AREA, (c + 1) * AREA, (r + 1) * AREA)
        t0 = time.time()
        fut = POOL.submit(self.places, box)
        addr = self.addresses(box)
        found = fut.result()
        places, depots, stations = found[0], found[1], (found[2] if len(found) > 2 else [])
        houses = False
        if len(addr) < HOUSES_BELOW:
            try:
                addr += self.houses(box)
                houses = True
            except Exception as e:  # noqa: BLE001 - no buildings index: addresses only
                log("houses not available:", e)
        # one customer per CELL_M grid cell
        seen, kept = set(), []
        k_lat = CELL_M / 111320.0
        k_lon = CELL_M / (111320.0 * max(0.2, math.cos(math.radians(box[1] + AREA / 2))))
        for la, lo, label, town in addr:
            cell = (int(la // k_lat), int(lo // k_lon))
            if cell in seen or not label:
                continue
            seen.add(cell)
            kept.append((la, lo, label, town))
        tiles = {}
        for la, lo, label, town in kept:
            if not (box[1] <= la < box[3] and box[0] <= lo < box[2]):
                continue
            key = f"{int(math.floor(la / TILE))}_{int(math.floor(lo / TILE))}"
            tiles.setdefault(key, []).append([round(la, 6), round(lo, 6), round(la, 6), round(lo, 6), label, town])
        # A pickup without a town uses the nearest customer's.
        if kept:
            for row in places:
                if not row[7]:
                    best = min(kept[:: max(1, len(kept) // 2000)],
                               key=lambda a: (a[0] - row[1]) ** 2 + (a[1] - row[2]) ** 2)
                    row[7] = best[3]
        restaurants, grocers = [], []
        for row in places:
            if box[1] <= row[1] < box[3] and box[0] <= row[2] < box[2]:
                (grocers if row[6] == "grocery" else restaurants).append(row)
        depots = [d for d in depots if box[1] <= d["g"][0] < box[3] and box[0] <= d["g"][1] < box[2]]
        if kept:
            for row in stations:
                if not row[5]:
                    row[5] = min(kept[:: max(1, len(kept) // 2000)],
                                 key=lambda a: (a[0] - row[1]) ** 2 + (a[1] - row[2]) ** 2)[3]
        stations = [s for s in stations if box[1] <= s[1] < box[3] and box[0] <= s[2] < box[2]]
        log(f"area {r}_{c}: {len(restaurants)} restaurants, {len(grocers)} grocery stores, "
            f"{len(depots)} workplaces, {len(stations)} fuel stations, {sum(len(v) for v in tiles.values())} customers"
            f"{' (with houses)' if houses else ''} in {time.time() - t0:.1f} s")
        return {"key": f"{r}_{c}", "restaurants": restaurants, "grocers": grocers, "depots": depots, "fuel": stations,
                "tiles": tiles, "houses": houses,
                "release": self.index.release}


######################################################################################## areas, jobs, the web server

def valid_area(data, key, release):
    def coordinates(row, offset):
        values = row[offset:offset + 4]
        return len(values) == 4 and all(type(n) in (int, float) and math.isfinite(n) for n in values) \
            and abs(values[0]) <= 90 and abs(values[1]) <= 180 and abs(values[2]) <= 90 and abs(values[3]) <= 180
    if not isinstance(data, dict) or data.get("key") != key or data.get("release") != release or not isinstance(data.get("tiles"), dict):
        return False
    for field in ("restaurants", "grocers"):
        if not isinstance(data.get(field), list):
            return False
        for row in data[field]:
            if not isinstance(row, list) or len(row) < 7 or not coordinates(row, 1) or not isinstance(row[0], str) or not isinstance(row[5], str) or not isinstance(row[6], str):
                return False
    for tile, rows in data["tiles"].items():
        if not re.fullmatch(r"-?\d+_-?\d+", tile) or not isinstance(rows, list):
            return False
        if any(not isinstance(row, list) or len(row) < 5 or not coordinates(row, 0) or not isinstance(row[4], str) for row in rows):
            return False
    if not isinstance(data.get("fuel"), list) or not isinstance(data.get("depots"), list):
        return False
    for row in data["fuel"]:
        if not isinstance(row, list) or len(row) < 5 or not isinstance(row[0], str) or not coordinates(row[1:3] * 2, 0) \
                or not isinstance(row[3], str) or row[4] not in ("f", "e"):
            return False
    for depot in data["depots"]:
        if not isinstance(depot, dict) or not isinstance(depot.get("id"), str) or not isinstance(depot.get("n"), str) or depot.get("t") not in ("yard", "shop", "fuel"):
            return False
        point = depot.get("g")
        if not isinstance(point, list) or not coordinates(point + point, 0):
            return False
    return True


class Areas:
    def __init__(self, builder, cache_dir, budget=None):
        self.builder = builder
        self.dir = os.path.join(cache_dir, "areas", builder.index.release, AREA_CACHE_VERSION)
        os.makedirs(self.dir, exist_ok=True)
        self.state = {}             # key -> "ready" | "loading" | "queued" | "failed: ..."
        self.queue = []             # keys waiting, nearest to the last request first
        self.last = (0.0, 0.0)
        self.wanted = set()
        self._fail_at = {}
        self.budget = budget or CacheBudget(cache_dir)
        self.cv = threading.Condition()
        for _ in range(WORKERS):
            threading.Thread(target=self._work, daemon=True).start()
        if WORKERS:
            threading.Thread(target=self._maintain, daemon=True, name="cargo-earth-cache").start()

    def _maintain(self):
        while True:
            time.sleep(30)
            with self.cv:
                pinned = [self.path(key) for key in self.wanted]
            self.budget.prune(pinned)

    def path(self, key):
        return os.path.join(self.dir, key + ".json")

    def status(self, key):
        with self.cv:
            s = self.state.get(key)
        if s is None:
            try:
                self._cached(key)
                s = "ready"
                with self.cv:
                    self.state[key] = s
            except (OSError, ValueError, TypeError):
                pass
        return s

    def near(self, lat, lon):
        if not math.isfinite(lat) or not math.isfinite(lon) or not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("coordinates must be finite WGS84 latitude/longitude")
        lon = (lon + 180) % 360 - 180
        lat = max(-89.999999, min(89.999999, lat))
        r0, c0 = int(math.floor(lat / AREA)), int(math.floor(lon / AREA))
        keys = [f"{r0 + dr}_{(c0 + dc + 1800) % 3600 - 1800}" for dr in (0, -1, 1) for dc in (0, -1, 1)
                if -900 <= r0 + dr < 900]
        out = {"ready": [], "loading": 0, "failed": 0, "errors": [], "grocers": True, "depots": True, "fuel": True,
               "release": self.builder.index.release, "areaFormat": AREA_CACHE_VERSION, "cellSize": AREA}
        with self.cv:
            self.last = (lat, lon)
            self.wanted = set(keys)
            self.queue[:] = [key for key in self.queue if key in self.wanted]
            # A long trip must not leave an ever-growing queue or in-memory status history.
            for key in list(self.state):
                if key not in self.wanted and self.state[key] != "loading":
                    self.state.pop(key, None)
                    self._fail_at.pop(key, None)
            for k in keys:
                s = self.status(k)
                if s is None or (s.startswith("failed") and time.time() > self._retry_at(k)):
                    self.state[k] = "queued"
                    if k not in self.queue:
                        self.queue.append(k)
                    self.cv.notify()
                    s = "queued"
                if s == "ready":
                    out["ready"].append(k)
                elif s.startswith("failed"):
                    out["failed"] += 1
                    out["errors"].append(s[8:])
                else:
                    out["loading"] += 1
        return out

    def _retry_at(self, k):
        return self._fail_at.get(k, 0) + 60

    def _next(self):
        lat, lon = self.last

        def d(k):
            r, c = map(int, k.split("_"))
            east = (((c + 0.5) * AREA - lon + 180) % 360 - 180) * math.cos(math.radians(lat))
            return ((r + 0.5) * AREA - lat) ** 2 + east ** 2
        self.queue.sort(key=d)
        return self.queue.pop(0)

    def _work(self):
        while True:
            with self.cv:
                while not self.queue:
                    self.cv.wait()
                k = self._next()
                self.state[k] = "loading"
            try:
                r, c = map(int, k.split("_"))
                data = self.builder.build(r, c)
                if not valid_area(data, k, self.builder.index.release):
                    raise ValueError("invalid geographic area; not published")
                body = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                if len(body) > MAX_AREA_BYTES:
                    raise ValueError("processed area exceeds 8 MiB; not published")
                tmp = self.path(k) + f".{threading.get_ident()}.tmp"
                with open(tmp, "wb") as f:
                    f.write(body)
                os.replace(tmp, self.path(k))
                with self.cv:
                    self.state[k] = "ready"
                    pinned = [self.path(key) for key in self.wanted]
                self.budget.prune(pinned)
            except Exception as e:  # noqa: BLE001 - reported to the mod, retried later
                log(f"area {k} failed:", repr(e))
                self._fail_at[k] = time.time()
                with self.cv:
                    self.state[k] = "failed: " + str(e)[:200]

    def read(self, key):
        if self.status(key) != "ready":
            return None
        try:
            return self._cached(key)
        except (OSError, ValueError, TypeError):
            with self.cv:
                self.state.pop(key, None)
            return None

    def _cached(self, key):
        with open(self.path(key), "rb") as f:
            body = f.read(MAX_AREA_BYTES + 1)
        if len(body) > MAX_AREA_BYTES:
            raise ValueError("area exceeds response size limit")
        data = json.loads(body)
        if not valid_area(data, key, self.builder.index.release):
            raise ValueError("invalid cached area")
        touch_cache(self.path(key))
        return body


######################################################################################## speed cameras (OpenStreetMap)

OVERPASS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]
CAMERA_CELL = 0.5          # one Overpass request covers this many degrees
CAMERA_REACH = 0.15        # cells this close to the player are fetched too, degrees
CAMERA_DAYS = 30           # a cached cell is asked for again after this long
CAMERA_ROAD_M = 30         # a camera beside the road belongs to a road this close
CAMERA_ROADS = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street"
MAX_CAMERA_BYTES = 4 * 1024 * 1024


def parse_speed(text):
    """An OpenStreetMap maxspeed value in km/h, or None ('50', '30 mph', '50;30' -> the lowest; 'signals' -> None)."""
    best = None
    for part in re.split(r"[;,|]", str(text or "")):
        m = re.fullmatch(r"\s*(\d{1,3})(?:\.\d+)?\s*(km/h|kmh|kph|mph|knots)?\s*", part.lower())
        if not m:
            continue
        value = float(m.group(1)) * {"mph": 1.609344, "knots": 1.852}.get(m.group(2), 1)
        if 5 <= value <= 200 and (best is None or value < best):
            best = value
    return best and int(round(best))


def _metres(lat, lon, a, b):
    """Distance from a point to the segment a-b ((lat, lon) pairs)."""
    k = math.cos(math.radians(lat))
    ax, ay, bx, by = (a[1] - lon) * k, a[0] - lat, (b[1] - lon) * k, b[0] - lat
    dx, dy = bx - ax, by - ay
    t = 0 if dx == dy == 0 else max(0, min(1, -(ax * dx + ay * dy) / (dx * dx + dy * dy)))
    return math.hypot(ax + t * dx, ay + t * dy) * 111320


def camera_rows(data):
    """Overpass JSON -> [[id, lat, lon, limit km/h (0 = not known), road class]]. The limit comes from the camera,
    its enforcement relation, or the nearest road, in that order."""
    nodes, relations, ways = [], {}, []
    for e in data.get("elements", []) if isinstance(data, dict) else []:
        tags = e.get("tags") or {}
        if e.get("type") == "node" and tags.get("highway") == "speed_camera":
            nodes.append(e)
        elif e.get("type") == "relation" and tags.get("enforcement", "maxspeed") == "maxspeed":
            limit = parse_speed(tags.get("maxspeed"))
            for m in e.get("members", []):
                if limit and m.get("type") == "node" and m.get("role") == "device":
                    relations[m.get("ref")] = limit
        elif e.get("type") == "way" and isinstance(e.get("geometry"), list):
            ways.append(e)
    rows = []
    for n in nodes:
        lat, lon = n.get("lat"), n.get("lon")
        if not all(type(x) in (int, float) and math.isfinite(x) for x in (lat, lon)) or abs(lat) > 90 or abs(lon) > 180:
            continue
        limit = parse_speed(n["tags"].get("maxspeed")) or relations.get(n.get("id"))
        best, cls, road_limit = CAMERA_ROAD_M, "", None
        for w in ways:
            pts = [(p["lat"], p["lon"]) for p in w["geometry"] if p]
            d = min((_metres(lat, lon, a, b) for a, b in zip(pts, pts[1:])), default=best)
            if d < best:
                best, cls = d, str(w["tags"].get("highway", "")).replace("_link", "")
                road_limit = parse_speed(w["tags"].get("maxspeed"))
        if cls and not limit:
            limit = road_limit
        rows.append([f"n{n.get('id')}", round(lat, 6), round(lon, 6), limit or 0, cls])
    return rows


class Cameras:
    """Speed cameras around the player, from OpenStreetMap through the Overpass API; one small request per cell,
    kept on disk."""

    def __init__(self, cache_dir, fetch=None):
        self.dir = os.path.join(cache_dir, "cameras")
        os.makedirs(self.dir, exist_ok=True)
        self.fetch = fetch or self._overpass
        self.state, self.fail_at = {}, {}
        self.lock = threading.Lock()

    def path(self, key):
        return os.path.join(self.dir, key + ".json")

    def _overpass(self, box):
        s, w, n, e = box
        q = (f'[out:json][timeout:25];node["highway"="speed_camera"]({s},{w},{n},{e})->.c;.c out body;'
             f'rel(bn.c)["type"="enforcement"];out body;'
             f'way(around.c:{CAMERA_ROAD_M})["highway"~"^({CAMERA_ROADS})(_link)?$"];out tags geom;')
        err = None
        for base in OVERPASS:
            try:
                return json.loads(http_get(base + "?data=" + urllib.parse.quote(q), tries=1))
            except Exception as e2:  # noqa: BLE001 - the next mirror
                err = e2
        raise err

    def _load(self, key):
        try:
            with open(self.path(key), "rb") as f:
                data = json.loads(f.read(MAX_CAMERA_BYTES))
            if time.time() - data["at"] < CAMERA_DAYS * 86400 and isinstance(data["cameras"], list):
                return data["cameras"]
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return None

    def _work(self, key):
        r, c = map(int, key.split("_"))
        try:
            rows = camera_rows(self.fetch((r * CAMERA_CELL, c * CAMERA_CELL, (r + 1) * CAMERA_CELL, (c + 1) * CAMERA_CELL)))
            tmp = self.path(key) + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"at": time.time(), "cameras": rows}, f, separators=(",", ":"))
            os.replace(tmp, self.path(key))
            log(f"cameras {key}: {len(rows)}")
            with self.lock:
                self.state[key] = rows
        except Exception as e:  # noqa: BLE001 - reported to the mod, retried later
            log(f"cameras {key} failed:", repr(e))
            with self.lock:
                self.state.pop(key, None)
                self.fail_at[key] = time.time()

    def near(self, lat, lon):
        if not math.isfinite(lat) or not math.isfinite(lon) or not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("coordinates must be finite WGS84 latitude/longitude")
        keys = sorted({f"{int(math.floor((lat + a) / CAMERA_CELL))}_{int(math.floor((lon + b) / CAMERA_CELL))}"
                       for a in (-CAMERA_REACH, 0, CAMERA_REACH) for b in (-CAMERA_REACH, 0, CAMERA_REACH)
                       if abs(lat + a) < 90 and abs(lon + b) < 180})
        out = {"state": "ready", "cells": keys, "cameras": []}
        for key in keys:
            with self.lock:
                rows = self.state.get(key)
                if rows is None:
                    rows = self._load(key)
                    if rows is not None:
                        self.state[key] = rows
                    elif time.time() - self.fail_at.get(key, 0) < 300:
                        rows = "failed"
                    else:
                        rows = self.state[key] = "loading"
                        threading.Thread(target=self._work, args=(key,), daemon=True).start()
                for old in [k for k in self.state if k not in keys and self.state[k] != "loading"]:
                    del self.state[old]
            if isinstance(rows, list):
                out["cameras"] += rows
            elif out["state"] != "loading":
                out["state"] = rows
        return out


######################################################################################## radio (Radio Browser)

RADIO_FALLBACK = ["de1.api.radio-browser.info", "nl1.api.radio-browser.info", "de2.api.radio-browser.info"]
RADIO_HOURS = 24           # a country's station list is asked for again after this long
RADIO_LIMIT = 400          # stations asked for per country (most listened first)
RADIO_NEAR_KM = 120        # a station with a known place this close is "near you"
RADIO_NEAR_MAX = 30
MAX_RADIO_BYTES = 6 * 1024 * 1024
RADIO_CODECS = {"MP3", "AAC", "AAC+", "OGG", "OPUS", "FLAC", ""}   # HLS playlists and video streams are left out


def radio_servers():
    """Radio Browser's API servers as its docs ask: every address behind all.api.radio-browser.info, named by
    reverse DNS (HTTPS needs the name), shuffled; the known names when DNS gives nothing."""
    import random
    import socket
    names = []
    try:
        for info in socket.getaddrinfo("all.api.radio-browser.info", 443, proto=socket.IPPROTO_TCP):
            try:
                name = socket.gethostbyaddr(info[4][0])[0]
            except OSError:
                continue
            if name.endswith(".api.radio-browser.info") and name not in names:
                names.append(name)
    except OSError:
        pass
    random.shuffle(names)
    return names or list(RADIO_FALLBACK)


def _text(v, n):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


def radio_rows(data, cc):
    """Radio Browser stations -> [[id, name, stream url, codec, kbps, tags, region, lat, lon, votes]], working ones
    only, no duplicates by name and stream."""
    rows, seen = [], set()
    for s in data if isinstance(data, list) else []:
        if not isinstance(s, dict) or str(s.get("countrycode", "")).upper() != cc:
            continue
        url = str(s.get("url_resolved") or s.get("url") or "").strip()
        codec = str(s.get("codec") or "").upper().strip()
        sid = str(s.get("stationuuid") or "")
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", sid) or not re.match(r"https?://", url) or len(url) > 500:
            continue
        if s.get("lastcheckok") in (0, "0", False) or s.get("hls") in (1, "1", True) or codec not in RADIO_CODECS:
            continue
        name = _text(s.get("name"), 60)
        if not name or (name.lower(), url) in seen:
            continue
        seen.add((name.lower(), url))
        lat, lon = s.get("geo_lat"), s.get("geo_long")
        ok = all(type(x) in (int, float) and math.isfinite(x) for x in (lat, lon)) and abs(lat) <= 90 and abs(lon) <= 180 \
            and (lat, lon) != (0, 0)
        tags = ", ".join(t.strip() for t in str(s.get("tags") or "").split(",") if t.strip())[:60]
        try:
            kbps = max(0, min(10000, int(s.get("bitrate") or 0)))
            votes = max(0, int(s.get("votes") or 0))
        except (TypeError, ValueError):
            kbps, votes = 0, 0
        rows.append([sid, name, url, codec, kbps, tags, _text(s.get("state"), 40),
                     round(lat, 4) if ok else None, round(lon, 4) if ok else None, votes])
    return rows


def _km(lat1, lon1, lat2, lon2):
    k = math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot((lon2 - lon1) * k, lat2 - lat1) * 111.32


class Radio:
    """Internet radio stations of the country the player drives in, from Radio Browser (radio-browser.info, a free
    community directory). One request per country a day, kept on disk; the phone plays the streams itself."""

    def __init__(self, cache_dir, fetch=None, servers=None):
        self.dir = os.path.join(cache_dir, "radio")
        os.makedirs(self.dir, exist_ok=True)
        self.fetch = fetch or self._get
        self.servers = servers or radio_servers
        self._hosts = None
        self.state, self.fail_at, self.fresh_until, self.refreshing = {}, {}, {}, set()
        self.lock = threading.Lock()

    def path(self, cc):
        return os.path.join(self.dir, cc + ".json")

    def _api(self, path):
        hosts = self._hosts = self._hosts or self.servers()
        err = None
        for host in list(hosts):
            try:
                return json.loads(http_get(f"https://{host}{path}", tries=1))
            except Exception as e:  # noqa: BLE001 - the next server
                err = e
                hosts.remove(host)
                hosts.append(host)
        raise err or OSError("no Radio Browser server")

    def _get(self, cc):
        q = urllib.parse.urlencode({"countrycode": cc, "hidebroken": "true", "order": "clickcount", "reverse": "true",
                                    "limit": RADIO_LIMIT})
        return self._api("/json/stations/search?" + q)

    def url_of(self, sid):
        """The stream of a station this helper listed (in memory or in the cache), or None: the helper plays only
        those, never an address it is handed."""
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", sid or ""):
            return None
        with self.lock:
            lists = [v for v in self.state.values() if isinstance(v, list)]
        for rows in lists:
            for r in rows:
                if r[0] == sid:
                    return r[2]
        try:
            names = [n for n in os.listdir(self.dir) if re.fullmatch(r"[A-Z]{2}\.json", n)]
        except OSError:
            names = []
        for n in names:
            for r in self._load(n[:2]) or []:
                if r[0] == sid:
                    return r[2]
        return None

    def click(self, sid):
        """Radio Browser counts what people listen to: one call each time a station starts playing."""
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", sid or ""):
            raise ValueError("bad station id")
        POOL.submit(lambda: self._api("/json/url/" + sid))
        return {"ok": True}

    def _load(self, cc):
        try:
            with open(self.path(cc), "rb") as f:
                data = json.loads(f.read(MAX_RADIO_BYTES))
            if time.time() - data["at"] < RADIO_HOURS * 3600 and isinstance(data["stations"], list):
                self.fresh_until[cc] = data["at"] + RADIO_HOURS * 3600
                return data["stations"]
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return None

    def _refresh(self, cc):
        try:
            self._work(cc, keep=True)
        finally:
            with self.lock:
                self.refreshing.discard(cc)

    def _work(self, cc, keep=False):
        try:
            rows = radio_rows(self.fetch(cc), cc)
            tmp = self.path(cc) + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"at": time.time(), "stations": rows}, f, separators=(",", ":"), ensure_ascii=False)
            os.replace(tmp, self.path(cc))
            log(f"radio {cc}: {len(rows)} stations")
            with self.lock:
                self.state[cc] = rows
                self.fresh_until[cc] = time.time() + RADIO_HOURS * 3600
        except Exception as e:  # noqa: BLE001 - reported to the mod, retried later
            log(f"radio {cc} failed:", repr(e))
            with self.lock:
                if not keep:
                    self.state.pop(cc, None)
                self.fail_at[cc] = time.time()

    def near(self, cc, lat=None, lon=None):
        cc = str(cc or "").upper()
        if not re.fullmatch(r"[A-Z]{2}", cc):
            raise ValueError("country must be an ISO 3166 alpha-2 code")
        here = lat is not None and lon is not None and math.isfinite(lat) and math.isfinite(lon) \
            and abs(lat) <= 90 and abs(lon) <= 180
        with self.lock:
            rows = self.state.get(cc)
            if isinstance(rows, list) and time.time() >= self.fresh_until.get(cc, 0) \
                    and time.time() - self.fail_at.get(cc, 0) >= 120 and cc not in self.refreshing:
                # a day old: fetched again in the background, the old list is served meanwhile
                self.refreshing.add(cc)
                threading.Thread(target=self._refresh, args=(cc,), daemon=True).start()
            if rows is None:
                rows = self._load(cc)
                if rows is not None:
                    self.state[cc] = rows
                elif time.time() - self.fail_at.get(cc, 0) < 120:
                    rows = "failed"
                else:
                    rows = self.state[cc] = "loading"
                    threading.Thread(target=self._work, args=(cc,), daemon=True).start()
        if not isinstance(rows, list):
            return {"state": rows, "country": cc, "near": [], "top": []}
        near = []
        if here:
            for r in rows:
                if r[7] is not None:
                    d = _km(lat, lon, r[7], r[8])
                    if d <= RADIO_NEAR_KM:
                        near.append(r[:7] + [round(d)])
            near.sort(key=lambda r: r[7])
            near = near[:RADIO_NEAR_MAX]
        return {"state": "ready", "country": cc, "near": near, "top": [r[:7] for r in rows]}


# The game's UI browser may not play web streams; then the helper plays the station on this computer. Windows: the
# system's own media player (Media Foundation, through PowerShell; MP3 and AAC). Elsewhere: ffplay, mpv or VLC if
# installed. The mod sends a heartbeat while the radio is on; without one for PLAYER_ALIVE_S the helper stops, so
# music never outlives the game.
PLAYER_ALIVE_S = 20
PLAYER_OPEN_S = 15        # a stream that has not started after this long is given up
PS_PLAYER = r"""
Add-Type -AssemblyName PresentationCore
$p = New-Object System.Windows.Media.MediaPlayer
$p.Volume = [double]::Parse($env:CARGO_EARTH_VOL, [Globalization.CultureInfo]::InvariantCulture)
$p.Open([Uri]$env:CARGO_EARTH_STREAM)
$p.Play()
$in = [Console]::OpenStandardInput()
$buf = New-Object byte[] 256
$t = $in.ReadAsync($buf, 0, 256)
$run = $true
while ($run) {
  Start-Sleep -Milliseconds 250
  if ($t.IsCompleted) {
    $n = $t.Result
    if ($n -le 0) { break }
    foreach ($line in [Text.Encoding]::ASCII.GetString($buf, 0, $n).Split("`n")) {
      $line = $line.Trim()
      if ($line -eq 'stop') { $run = $false }
      if ($line -like 'vol *') { $p.Volume = [double]::Parse($line.Substring(4), [Globalization.CultureInfo]::InvariantCulture) }
    }
    $t = $in.ReadAsync($buf, 0, 256)
  }
  [Console]::Out.WriteLine('pos ' + [int]$p.Position.TotalSeconds + ' ' + [int]$p.HasAudio)
  [Console]::Out.Flush()
}
$p.Stop(); $p.Close()
"""


class Player:
    def __init__(self, spawn=None, clock=time.time):
        self.spawn = spawn or self._spawn
        self.clock = clock
        self.proc, self.url, self.vol, self.alive_at = None, None, 0.6, 0
        self.started_at, self.pos, self.error, self.kind = 0, 0, None, None
        self.lock = threading.Lock()
        threading.Thread(target=self._watch, daemon=True).start()

    @staticmethod
    def available():
        import shutil
        if os.name == "nt":
            return "powershell"
        for name in ("ffplay", "mpv", "cvlc"):
            if shutil.which(name):
                return name
        return None

    def _spawn(self, url, vol):
        import subprocess
        kind = self.available()
        if not kind:
            raise OSError("no media player found on this computer")
        import base64
        flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        env = dict(os.environ, CARGO_EARTH_STREAM=url, CARGO_EARTH_VOL=f"{vol:.2f}")   # data, never code
        if kind == "powershell":
            cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
                   base64.b64encode(PS_PLAYER.encode("utf-16-le")).decode()]
        elif kind == "ffplay":
            cmd = ["ffplay", "-nodisp", "-loglevel", "quiet", "-volume", str(int(vol * 100)), url]
        elif kind == "mpv":
            cmd = ["mpv", "--no-video", "--really-quiet", f"--volume={int(vol * 100)}", url]
        else:
            cmd = ["cvlc", "--quiet", "--play-and-exit", f"--gain={vol:.2f}", url]
        proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, bufsize=1, creationflags=flags, env=env)
        proc.kind = kind
        return proc

    def _read(self, proc):
        for line in proc.stdout:
            parts = line.split()
            if len(parts) == 3 and parts[0] == "pos":
                with self.lock:
                    if proc is self.proc:
                        self.pos = int(parts[1]) if parts[1].isdigit() else 0

    def _kill(self):
        proc, self.proc = self.proc, None
        if proc:
            try:
                proc.stdin.write("stop\n")
                proc.stdin.flush()
            except (OSError, ValueError, AttributeError):
                pass
            try:
                proc.wait(timeout=2)
            except Exception:  # noqa: BLE001 - still running: ended the hard way
                try:
                    proc.kill()
                except OSError:
                    pass

    def play(self, url, vol):
        if not re.match(r"https?://", url or "") or len(url) > 500:
            raise ValueError("not a web stream")
        with self.lock:
            self._kill()
            self.url, self.vol, self.alive_at = url, max(0.0, min(1.0, vol)), self.clock()
            self.started_at, self.pos, self.error = self.clock(), 0, None
            try:
                self.proc = self.spawn(url, self.vol)
                self.kind = getattr(self.proc, "kind", None)
            except Exception as e:  # noqa: BLE001 - reported to the phone
                self.error = str(e)
                return self.status()
            if getattr(self.proc, "stdout", None):
                threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()
            return self.status()

    def volume(self, vol):
        with self.lock:
            self.vol = max(0.0, min(1.0, vol))
            self.alive_at = self.clock()
            proc = self.proc
            if proc and getattr(proc, "kind", None) == "powershell":
                try:
                    proc.stdin.write(f"vol {self.vol:.2f}\n")
                    proc.stdin.flush()
                except (OSError, ValueError):
                    pass
                return self.status()
        if proc and self.url:      # players without a volume command start again at the new volume
            return self.play(self.url, self.vol)
        return self.status()

    def stop(self):
        with self.lock:
            self._kill()
            self.url = None
            return self.status()

    def alive(self):
        with self.lock:
            self.alive_at = self.clock()
            return self.status()

    def status(self):
        proc = self.proc
        running = bool(proc) and proc.poll() is None
        if proc and not running and not self.error:
            self.error = "the stream stopped or could not be opened"
        # Windows' player fails silently: a stream whose clock has not moved after a while is probably not playing
        stuck = running and self.pos == 0 and self.clock() - self.started_at > PLAYER_OPEN_S
        return {"playing": running, "stuck": stuck, "url": self.url if running else None, "vol": self.vol, "secs": self.pos,
                "error": self.error, "player": self.kind or self.available()}

    def _watch(self):
        while True:
            time.sleep(2)
            with self.lock:
                if self.proc and self.clock() - self.alive_at > PLAYER_ALIVE_S:
                    log("radio: no word from the game, stopping")
                    self._kill()
                    self.url = None


UPDATE_REPO = "themazzy/cargo-earth"
UPDATE_PAGE = f"https://github.com/{UPDATE_REPO}/releases"
UPDATE_EVERY_S = 6 * 3600          # GitHub allows 60 unauthenticated requests an hour; one in 6 hours is plenty
UPDATE_RETRY_S = 1800              # no answer (offline, rate limit): try again after this long


def version_tuple(v):
    """'v0.10.2' -> (0, 10, 2); None for anything that is not a plain release version."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?", str(v or "").strip())
    return tuple(int(x or 0) for x in m.groups()) if m else None


def newer(latest, current):
    a, b = version_tuple(latest), version_tuple(current)
    return bool(a and b and a > b)


class Updates:
    """The newest published Cargo Earth release (GitHub), checked at start and every few hours, kept on disk so a
    restart does not ask again. The game cannot go online; it reads this from /v1/info and shows it on the phone."""

    def __init__(self, cache_dir, enabled=True, fetch=None, clock=time.time):
        self.path = os.path.join(cache_dir, "update.json")
        self.enabled, self.clock = enabled, clock
        self.fetch = fetch or (lambda: json.loads(http_get(f"https://api.github.com/repos/{UPDATE_REPO}/releases/latest",
                                                           {"Accept": "application/vnd.github+json"}, tries=1)))
        self.lock = threading.Lock()
        self.state = {"latest": None, "url": None, "checkedAt": None, "error": None}
        try:
            with open(self.path, encoding="utf-8") as f:
                saved = json.load(f)
            if version_tuple(saved.get("latest")) and str(saved.get("url", "")).startswith(UPDATE_PAGE):
                self.state.update(latest=saved["latest"], url=saved["url"], checkedAt=float(saved.get("checkedAt") or 0))
        except (OSError, ValueError, TypeError, AttributeError):
            pass

    def due(self):
        with self.lock:
            at = self.state["checkedAt"]
            wait = UPDATE_RETRY_S if self.state["error"] else UPDATE_EVERY_S
        return self.enabled and (not at or self.clock() - at >= wait)

    def check(self):
        try:
            rel = self.fetch()
            tag, url = rel.get("tag_name"), str(rel.get("html_url") or "")
            if not version_tuple(tag):
                raise ValueError(f"unexpected release tag {tag!r}")
            if not url.startswith(UPDATE_PAGE):
                url = f"{UPDATE_PAGE}/latest"
            latest = ".".join(map(str, version_tuple(tag)))
            with self.lock:
                self.state.update(latest=latest, url=url, checkedAt=self.clock(), error=None)
                saved = dict(self.state)
            try:
                os.makedirs(os.path.dirname(self.path), exist_ok=True)
                with open(self.path + ".tmp", "w", encoding="utf-8") as f:
                    json.dump(saved, f)
                os.replace(self.path + ".tmp", self.path)
            except OSError:
                pass
            if newer(latest, VERSION):
                log(f"Cargo Earth {latest} is out (this helper is {VERSION}): {url}")
        except Exception as e:  # noqa: BLE001
            with self.lock:
                self.state.update(checkedAt=self.clock(), error=str(e)[:200])
            log("could not check for Cargo Earth updates:", e)

    def info(self):
        with self.lock:
            out = dict(self.state)
        if not self.enabled:
            out["error"] = "update check turned off"
        out["helper"] = VERSION
        out["helperOutdated"] = newer(out["latest"], VERSION)
        out["page"] = out["url"] or f"{UPDATE_PAGE}/latest"
        return out

    def open(self):
        """Opens the release page in the player's browser (only ever this repository's releases)."""
        url = self.info()["page"]
        if not url.startswith(UPDATE_PAGE):
            return {"opened": False, "url": None}
        import webbrowser
        try:
            return {"opened": bool(webbrowser.open(url)), "url": url}
        except Exception:  # noqa: BLE001
            return {"opened": False, "url": url}

    def run(self):
        while True:
            if self.due():
                self.check()
            time.sleep(60)

    def start(self):
        if self.enabled:
            threading.Thread(target=self.run, daemon=True, name="updates").start()
        return self


def missing_libraries():
    """The Python libraries the helper needs that this Python does not have."""
    return [m for m in ("duckdb", "fsspec") if importlib.util.find_spec(m) is None]


def status_page(areas, release, port, updates=None):
    """The page a player sees at http://127.0.0.1:<port>/: whether the helper works, in plain words."""
    with areas.cv:
        states = dict(areas.state)
    ready = sum(1 for s in states.values() if s == "ready")
    busy = sum(1 for s in states.values() if s in ("loading", "queued"))
    errors = [s[8:] for s in states.values() if s.startswith("failed")]
    with NETWORK_LOCK:
        network = dict(NETWORK)
    missing = missing_libraries()
    cache = getattr(areas.budget, "stats", {}) or {}
    rows = [("Version", VERSION), ("Port", str(port)), ("Overture release", release),
            ("Python", sys.version.split()[0]),
            ("Python libraries", "missing: " + ", ".join(missing) if missing else "duckdb and fsspec found"),
            ("Areas", f"{ready} ready, {busy} loading, {len(errors)} failed" if states else
             "none asked for yet (drive in BeamNG with Cargo Earth)"),
            ("Downloads", f"{network.get('requests', 0)} requests, {network.get('bytes', 0) / 1048576:.1f} MiB"),
            ("Cache", f"{cache.get('bytes', 0) / 1048576:.0f} of {cache.get('limit', 0) / 1048576:.0f} MiB")]
    up = updates.info() if updates else None
    if up and up["latest"]:
        rows.append(("Newest release", up["latest"] + (" (update available)" if up["helperOutdated"] else " (up to date)")))
    bad = missing or errors
    head = ("Running, but with problems" if bad else "Running")
    body = "".join(f"<tr><th>{html.escape(k)}</th><td>{html.escape(v)}</td></tr>" for k, v in rows)
    notes = ""
    if missing:
        notes += ("<p class=bad>Areas outside the bundled data can't be built without these libraries. Start the helper "
                  "from BeamNG.Earth's Add-ons page (its Python has them), or run <code>python -m pip install duckdb "
                  "fsspec</code>.</p>")
    if up and up["helperOutdated"]:
        notes += (f"<p class=bad>Cargo Earth {html.escape(up['latest'])} is out: "
                  f"<a href=\"{html.escape(up['page'])}\">download it from the release page</a>.</p>")
    if errors:
        notes += "<p class=bad>Last errors:</p><ul>" + "".join(f"<li>{html.escape(e)}</li>" for e in errors[-5:]) + "</ul>"
    return f"""<!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=5>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Cargo Earth helper</title>
<style>body{{font:15px system-ui,sans-serif;margin:24px auto;max-width:640px;padding:0 16px;background:#fff;color:#222}}
h1{{font-size:20px}}.ok{{color:#17803d}}.bad{{color:#b42318}}th{{text-align:left;padding:4px 16px 4px 0;font-weight:600}}
td,th{{vertical-align:top}}code{{background:#eee;padding:1px 4px}}
@media (prefers-color-scheme:dark){{body{{background:#1b1b1b;color:#ddd}}code{{background:#333}}.ok{{color:#5fd38a}}.bad{{color:#ff8a80}}}}</style>
</head><body><h1>Cargo Earth helper: <span class={"bad" if bad else "ok"}>{head}</span></h1>
<p>This page is only for checking the helper. The Cargo Earth mod talks to it by itself; keep it running while you play.</p>
<table>{body}</table>{notes}</body></html>""".encode()


def serve(areas, release, port, host="127.0.0.1", cameras=None, radio=None, player=None, srv=None, updates=None):
    class H(BaseHTTPRequestHandler):
        def _send(self, code, body, ctype="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.headers.get("Origin") or self.headers.get("Host", "").split(":", 1)[0].lower() not in ("127.0.0.1", "localhost"):
                return self._send(403, {"error": "local client requests only"})
            u = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            try:
                if u.path in ("/", "/index.html"):
                    return self._send(200, status_page(areas, release, port, updates), "text/html; charset=utf-8")
                if u.path == "/v1/info":
                    with NETWORK_LOCK:
                        network = dict(NETWORK)
                    return self._send(200, {"app": "cargo-earth-helper", "version": VERSION, "release": release,
                                            "cameras": cameras is not None, "radio": radio is not None,
                                            "player": player is not None, "missing": missing_libraries(),
                                            "network": network, "cache": areas.budget.stats,
                                            "update": updates.info() if updates else None})
                if u.path == "/v1/update/open" and updates:
                    return self._send(200, updates.open())
                if u.path == "/v1/cameras" and cameras:
                    return self._send(200, cameras.near(float(q["lat"]), float(q["lon"])))
                if u.path == "/v1/radio" and radio:
                    lat, lon = q.get("lat"), q.get("lon")
                    return self._send(200, radio.near(q.get("cc", ""), float(lat) if lat else None, float(lon) if lon else None))
                if u.path.startswith("/v1/player/") and player and radio:
                    what = u.path[len("/v1/player/"):]
                    if what == "play":
                        url = radio.url_of(q.get("id", ""))
                        if not url:
                            return self._send(404, {"error": "unknown station"})
                        return self._send(200, player.play(url, float(q.get("vol", "0.6"))))
                    if what == "volume":
                        return self._send(200, player.volume(float(q.get("vol", "0.6"))))
                    if what == "stop":
                        return self._send(200, player.stop())
                    if what == "alive":
                        return self._send(200, player.alive())
                    return self._send(404, {"error": "unknown path"})
                if u.path == "/v1/radioclick" and radio:
                    return self._send(200, radio.click(q.get("id", "")))
                if u.path == "/v1/near":
                    return self._send(200, areas.near(float(q["lat"]), float(q["lon"])))
                if u.path == "/v1/area":
                    key = q.get("key", "")
                    if not re.fullmatch(r"-?\d+_-?\d+", key):
                        return self._send(400, {"error": "bad key"})
                    body = areas.read(key)
                    return self._send(200, body) if body else self._send(404, {"error": "not ready"})
                return self._send(404, {"error": "unknown path"})
            except (KeyError, ValueError, OverflowError) as e:
                return self._send(400, {"error": str(e)})

        def log_message(self, *a):
            pass

    srv = srv or bind(host, port, H)
    srv.RequestHandlerClass = H
    log(f"Cargo Earth helper {VERSION} on http://{host}:{port}/ (Overture {release}); open it in a browser to check it")
    missing = missing_libraries()
    if missing:
        log("missing Python libraries:", ", ".join(missing), "- areas can't be built (python -m pip install duckdb fsspec)")
    srv.serve_forever()


def bind(host, port, handler=BaseHTTPRequestHandler):
    """Take the port, or exit with a message a player can act on."""
    try:
        return ThreadingHTTPServer((host, port), handler)
    except OSError as e:
        log(f"can't listen on {host}:{port}: {e}")
        log("Another program (often a second copy of this helper) is using that port. Close it, or start the helper "
            "with another --port and set the same helperPort in the mod's config.json.")
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--port", type=int, default=int(os.environ.get("BNE_CARGO_PORT", "47820")))
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--cache", default=os.environ.get("BNE_CARGO_CACHE") or os.path.join(here, "cache"))
    ap.add_argument("--release", default=RELEASE, help="Overture release (default: the pinned one, else the latest)")
    ap.add_argument("--cache-mb", type=int, default=1024, help="soft disk-cache budget in MiB (default: 1024)")
    ap.add_argument("--no-update-check", action="store_true", help="never ask GitHub for a newer Cargo Earth release")
    ap.add_argument("--test", help="LAT,LON: build that area, print a summary and exit")
    a = ap.parse_args()
    if a.cache_mb < 64:
        ap.error("--cache-mb must be at least 64")
    release = a.release
    # take the port before anything slow: a second copy fails at once, and a browser that opens the page while the
    # release is checked waits in the queue instead of being refused
    srv = None if a.test else bind("127.0.0.1", a.port)
    try:            # the pinned release gone from the bucket: the latest one
        probe = http_get(f"{BUCKET}/?list-type=2&max-keys=1&prefix=release/{release}/")
        if b"<KeyCount>0</KeyCount>" in probe:
            release = latest_release() or release
            log("pinned release gone, using", release)
    except Exception as e:  # noqa: BLE001
        log("could not check the release:", e)
    budget = CacheBudget(a.cache, a.cache_mb)
    budget.prune(force=True)
    builder = Builder(Index(release, a.cache), a.cache)
    if a.test:
        lat, lon = map(float, a.test.split(","))
        d = builder.build(int(math.floor(lat / AREA)), int(math.floor(lon / AREA)))
        cats = {}
        for x in d["restaurants"]:
            cats[x[6]] = cats.get(x[6], 0) + 1
        print(json.dumps({"area": d["key"], "restaurants": len(d["restaurants"]), "grocers": len(d["grocers"]), "depots": len(d["depots"]), "cats": cats,
                          "fuel": len(d["fuel"]), "fuelExamples": d["fuel"][:3],
                          "customers": sum(len(v) for v in d["tiles"].values()), "houses": d["houses"],
                          "grocerExamples": d["grocers"][:3], "depotExamples": d["depots"][:3],
                          "examples": d["restaurants"][:3] + [next(iter(d["tiles"].values()), [None])[0]]},
                         ensure_ascii=False, indent=1))
        budget.prune(force=True)
        return
    updates = Updates(a.cache, enabled=not a.no_update_check).start()
    serve(Areas(builder, a.cache, budget), release, a.port, cameras=Cameras(a.cache), radio=Radio(a.cache), player=Player(), srv=srv,
          updates=updates)


if __name__ == "__main__":
    main()
