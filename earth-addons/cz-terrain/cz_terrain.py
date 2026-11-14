"""CZ lidar terrain: Czech DMR 5G heights for BeamNG.Earth, in place of Mapterhorn's 5 m DMR 4G.

A companion add-on for BeamNG.Earth (run beside it, like the Cargo Earth helper). BeamNG.Earth reads its terrain from
Mapterhorn, whose Czech source is CUZK's DMR 4G, a 5 m grid. CUZK's DMR 5G (airborne lidar, 2 m, CC BY 4.0) is far
sharper. BeamNG.Earth has no add-on hook for terrain, but it reads every Mapterhorn tile from its own download cache
before it asks the network. So this program writes Mapterhorn-format tiles (512 px, Terrarium encoding) made from
DMR 5G into that cache, ahead of the car, and BeamNG.Earth builds the ground from them. Nothing of BeamNG.Earth is
changed; delete <cache>/dem/mapterhorn (or Clear cache in BeamNG.Earth) to go back.

What it does:
- Tiles of zoom 13, 14 and 15 (~6, 3 and 1.5 m a pixel in Czechia) around the car, nearest first, plus a look-ahead
  in the direction of travel. A whole area can be prepared before driving from the local page.
- Each tile is CUZK's exportImage of the dmr5g ImageServer for exactly that Web-Mercator tile. Pixels CUZK has no
  data for (outside Czechia, a few holes) are filled from Mapterhorn's own tile, so border tiles have no seam.
- Mapterhorn's file list in the cache (download_urls.json) says Czechia goes to zoom 15 (it says 14 for DMR 4G), so
  BeamNG.Earth reads the zoom-15 tiles at all. It is patched when found, and refreshed from Mapterhorn every few days.
  BeamNG.Earth reads that list once when it starts: after the very first run, restart BeamNG.Earth once.
- BeamNG.Earth's decoded copies of a written tile (<cache>/dem/decoded) are removed, so the new heights are used the
  next time the place is loaded. Places loaded before keep their old roads until the cache is cleared there.

Run: BeamNG.Earth's Add-ons page (a local add-on, see README.md), or by hand: python cz_terrain.py [--cache-dir DIR]
Page: http://127.0.0.1:47830/  Data: (c) CUZK, DMR 5G, CC BY 4.0. Mapterhorn tiles: see mapterhorn.com/attribution.
"""
import argparse
import io
import json
import math
import os
import queue
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image

VERSION = "0.1.0"
PORT = 47830
TILE = 512
ZOOMS = (13, 14, 15)                # written zooms; BeamNG.Earth upsamples 15 for its 16
LISTED_ZOOM = 15                    # what Mapterhorn's list is made to say for Czechia
COVERAGE_ZOOM = 6
BOUNDS = (48.55, 12.09, 51.06, 18.86)   # Czechia's box (lat0, lon0, lat1, lon1); CUZK answers nodata outside
CUZK_URL = "https://ags.cuzk.gov.cz/arcgis2/rest/services/dmr5g/ImageServer/exportImage"
MT_URL = "https://tiles.mapterhorn.com/{z}/{x}/{y}.webp"
MT_LIST_URL = "https://download.mapterhorn.com/download_urls.json"
LIST_REFRESH_S = 5 * 86400          # BeamNG.Earth itself reads the list again after 7 days
NODATA = -9999.0
TOP = 2000.0                        # higher is not Czech ground (Snezka 1603 m)
RADIUS_M = {15: 2500.0, 14: 5000.0, 13: 10000.0}
AHEAD_S = 45.0                      # look-ahead along the car's velocity
RETRIES = 3                         # tries per tile before it is left to BeamNG.Earth (asked again when passed)
WORKERS = 4                         # parallel CUZK requests (be kind to a government server)
TIMEOUT_S = 30
UA = "cz-terrain-addon/" + VERSION
R = 6378137.0
WORLD = 2.0 * math.pi * R


# --- tile maths ------------------------------------------------------------------------------------

def tile_xy(lat, lon, z):
    """Web-Mercator tile (x, y) of zoom z holding (lat, lon)."""
    n = 1 << z
    lat = max(-85.05, min(85.05, lat))
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def tile_box(z, x, y):
    """(x0, y0, x1, y1) of tile (z, x, y) in EPSG:3857 metres."""
    s = WORLD / (1 << z)
    x0 = -WORLD / 2 + x * s
    y1 = WORLD / 2 - y * s
    return x0, y1 - s, x0 + s, y1


def tile_latlon(z, x, y):
    """(lat, lon) of tile (z, x, y)'s centre."""
    n = 1 << z
    lon = (x + 0.5) / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (y + 0.5) / n))))
    return lat, lon


def in_bounds(z, x, y):
    """Does tile (z, x, y) meet Czechia's box?"""
    n = 1 << z
    lon0, lon1 = x / n * 360.0 - 180.0, (x + 1) / n * 360.0 - 180.0
    lat1 = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n))))
    lat0 = math.degrees(math.atan(math.sinh(math.pi * (1.0 - 2.0 * (y + 1) / n))))
    return lat1 >= BOUNDS[0] and lat0 <= BOUNDS[2] and lon1 >= BOUNDS[1] and lon0 <= BOUNDS[3]


def tiles_around(lat, lon, radius_m, z):
    """[(z, x, y)] within radius_m of (lat, lon) inside Czechia's box, nearest first."""
    dlat = radius_m / 111320.0
    dlon = radius_m / (111320.0 * max(0.05, math.cos(math.radians(lat))))
    x0, y0 = tile_xy(lat + dlat, lon - dlon, z)
    x1, y1 = tile_xy(lat - dlat, lon + dlon, z)
    cx, cy = tile_xy(lat, lon, z)
    keys = [(z, x, y) for y in range(y0, y1 + 1) for x in range(x0, x1 + 1) if in_bounds(z, x, y)]
    keys.sort(key=lambda k: (k[1] - cx) ** 2 + (k[2] - cy) ** 2)
    return keys


def coverage_tiles():
    """The zoom-6 tiles meeting Czechia's box (Mapterhorn's list is per zoom-6 tile)."""
    x0, y0 = tile_xy(BOUNDS[2], BOUNDS[1], COVERAGE_ZOOM)
    x1, y1 = tile_xy(BOUNDS[0], BOUNDS[3], COVERAGE_ZOOM)
    return [(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


# --- Terrarium -------------------------------------------------------------------------------------

def encode_terrarium(h):
    """RGB uint8 (TILE, TILE, 3) of heights h (metres, finite): v = (h + 32768) * 256 split into R, G, B."""
    v = np.rint((np.asarray(h, np.float64) + 32768.0) * 256.0)
    v = np.clip(v, 0, 2 ** 24 - 1).astype(np.uint32)
    return np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=-1).astype(np.uint8)


def decode_terrarium(rgb):
    a = np.asarray(rgb, np.float64)
    return (a[..., 0] * 256.0 + a[..., 1] + a[..., 2] / 256.0 - 32768.0).astype(np.float32)


def tile_bytes(h):
    """Lossless WebP of heights h (PNG when this Python's Pillow has no WebP: BeamNG.Earth decodes either)."""
    im = Image.fromarray(encode_terrarium(h), "RGB")
    buf = io.BytesIO()
    try:
        im.save(buf, "WEBP", lossless=True, quality=100, method=2)
    except (OSError, KeyError, ValueError):
        buf = io.BytesIO()
        im.save(buf, "PNG", compress_level=6)
    return buf.getvalue()


def image_heights(data):
    """float32 heights of a Mapterhorn tile's bytes, resized to TILE if needed."""
    im = Image.open(io.BytesIO(data)).convert("RGB")
    if im.size != (TILE, TILE):
        im = im.resize((TILE, TILE), Image.BILINEAR)
    return decode_terrarium(np.asarray(im))


def upsample_quadrant(parent, dz, qx, qy):
    """The part (qx, qy) of a 2^dz x 2^dz split of parent, bilinearly resized to TILE (pixel-area aligned)."""
    k = 1 << dz
    s = TILE / k
    c = (np.arange(TILE) + 0.5) / k - 0.5         # child pixel centres in the parent part's pixel units
    px = np.clip(qx * s + c, 0, TILE - 1)
    py = np.clip(qy * s + c, 0, TILE - 1)
    x0 = np.floor(px).astype(int)
    y0 = np.floor(py).astype(int)
    x1 = np.minimum(x0 + 1, TILE - 1)
    y1 = np.minimum(y0 + 1, TILE - 1)
    fx = (px - x0)[None, :]
    fy = (py - y0)[:, None]
    p = parent.astype(np.float64)
    top = p[np.ix_(y0, x0)] * (1 - fx) + p[np.ix_(y0, x1)] * fx
    bot = p[np.ix_(y1, x0)] * (1 - fx) + p[np.ix_(y1, x1)] * fx
    return (top * (1 - fy) + bot * fy).astype(np.float32)


# --- network ---------------------------------------------------------------------------------------

class NotFound(Exception):
    pass


def http_get(url, timeout=TIMEOUT_S):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise NotFound(url) from None
        raise


def cuzk_url(z, x, y):
    x0, y0, x1, y1 = tile_box(z, x, y)
    q = {"bbox": f"{x0:.4f},{y0:.4f},{x1:.4f},{y1:.4f}", "bboxSR": 3857, "imageSR": 3857,
         "size": f"{TILE},{TILE}", "format": "tiff", "compression": "LZ77", "pixelType": "F32", "noData": f"{NODATA:g}",
         "interpolation": "RSP_BilinearInterpolation", "f": "image"}
    return CUZK_URL + "?" + urllib.parse.urlencode(q, safe=",")


def decode_cuzk(body):
    """float32 (TILE, TILE) heights of a CUZK exportImage TIFF, NaN where none. ValueError for anything else (an
    ArcGIS error page answered with a 200, a wrong size)."""
    if body[:2] not in (b"II", b"MM"):
        raise ValueError("CUZK: not a TIFF: " + bytes(body[:120]).decode("latin-1", "replace"))
    im = Image.open(io.BytesIO(body))
    if im.size != (TILE, TILE):
        raise ValueError(f"CUZK: {im.size}, not {TILE} x {TILE}")
    a = np.asarray(im, dtype=np.float32).astype(np.float32)
    if a.ndim == 3:
        a = a[..., 0]
    a = a.copy()
    a[~np.isfinite(a) | (a <= -1000.0) | (a > TOP)] = np.nan
    return a


class Sources:
    """Where the heights come from (replaced by fakes in the tests)."""

    def cuzk(self, z, x, y):
        return decode_cuzk(http_get(cuzk_url(z, x, y)))

    def mapterhorn(self, z, x, y):
        """Mapterhorn's tile, or None (404)."""
        try:
            return image_heights(http_get(MT_URL.format(z=z, x=x, y=y)))
        except NotFound:
            return None

    def mapterhorn_list(self):
        return http_get(MT_LIST_URL, timeout=60)


# --- BeamNG.Earth's cache --------------------------------------------------------------------------

def find_cache_dir():
    """BeamNG.Earth's download cache: the launcher's app.json cacheDir, else its default (~/.cache/beamng-earth)."""
    base = os.environ.get("LOCALAPPDATA") if os.name == "nt" else None
    data = (os.path.join(base or os.path.join(os.path.expanduser("~"), "AppData", "Local"), "beamng-earth")
            if os.name == "nt" else os.path.join(os.path.expanduser("~"), ".cache", "beamng-earth"))
    try:
        with open(os.path.join(data, "app.json"), encoding="utf-8") as f:
            p = json.load(f).get("cacheDir")
            if isinstance(p, str) and p:
                return p
    except (OSError, ValueError, AttributeError):
        pass
    return os.path.join(os.path.expanduser("~"), ".cache", "beamng-earth")


def atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.cz.tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def patch_list(doc):
    """Mapterhorn's download_urls.json made to say Czechia's zoom-6 tiles go to LISTED_ZOOM. Returns (doc, changed)."""
    items = doc.setdefault("items", [])
    have = {}
    for it in items:
        parts = str(it.get("name", "")).split(".")[0].split("-")
        if len(parts) == 3 and parts[0] == str(COVERAGE_ZOOM):
            have[(int(parts[1]), int(parts[2]))] = it
    changed = False
    for x, y in coverage_tiles():
        it = have.get((x, y))
        if it is None:
            items.append({"name": f"{COVERAGE_ZOOM}-{x}-{y}.pmtiles", "max_zoom": LISTED_ZOOM, "cz_terrain": True})
            changed = True
        else:
            try:
                mz = int(it.get("max_zoom", 0))
            except (TypeError, ValueError):
                mz = 0
            if mz < LISTED_ZOOM:
                it["max_zoom"] = LISTED_ZOOM
                it["cz_terrain"] = True
                changed = True
    return doc, changed


class Cache:
    """BeamNG.Earth's terrain cache (<cache>/dem) and this add-on's own record of what it wrote."""

    def __init__(self, cache_dir):
        self.root = cache_dir
        self.dem = os.path.join(cache_dir, "dem")
        self.mt = os.path.join(self.dem, "mapterhorn")
        self.own = os.path.join(cache_dir, "cz-terrain")
        self.list_path = os.path.join(self.mt, "download_urls.json")
        self._lock = threading.Lock()
        self.done = self._load_done()

    def tile_path(self, z, x, y):
        return os.path.join(self.mt, str(z), str(x), f"{y}.webp")

    def _done_path(self):
        return os.path.join(self.own, "done.json")

    def _load_done(self):
        try:
            with open(self._done_path(), encoding="utf-8") as f:
                d = json.load(f)
            return {tuple(int(v) for v in k.split("/")): s for k, s in d.items()}
        except (OSError, ValueError):
            return {}

    def save_done(self):
        with self._lock:
            d = {f"{z}/{x}/{y}": s for (z, x, y), s in self.done.items()}
        atomic_write(self._done_path(), json.dumps(d).encode())

    def state(self, key):
        """'written' (and still there), 'outside' (no Czech data), or None (to do)."""
        with self._lock:
            s = self.done.get(key)
        if s == "written" and not os.path.exists(self.tile_path(*key)):
            return None             # BeamNG.Earth's cache dropped it: write it again
        return s

    def mark(self, key, s):
        with self._lock:
            self.done[key] = s

    def write_tile(self, key, h):
        atomic_write(self.tile_path(*key), tile_bytes(h))
        return self.forget_decoded(key)

    def forget_decoded(self, key):
        """Remove BeamNG.Earth's decoded copies (<dem>/decoded/v*/g*/z/x/y.*) of the tile and of its children down to
        zoom 17 (BeamNG.Earth's deeper tiles there were upsampled from it)."""
        base = os.path.join(self.dem, "decoded")
        try:
            dirs = [os.path.join(base, v, g) for v in os.listdir(base) for g in os.listdir(os.path.join(base, v))]
        except OSError:
            return 0
        z, x, y = key
        n = 0
        for dz in range(0, 18 - z):
            k = 1 << dz
            for cx in range(x * k, (x + 1) * k):
                for cy in range(y * k, (y + 1) * k):
                    for d in dirs:
                        for ext in (".f32z", ".npy"):
                            p = os.path.join(d, str(z + dz), str(cx), f"{cy}{ext}")
                            try:
                                os.remove(p)
                                n += 1
                            except OSError:
                                pass
        return n

    def ensure_list(self, sources, now=None):
        """Mapterhorn's file list patched for Czechia. Returns 'patched' (written now: BeamNG.Earth reads it when it
        starts), 'ok' (already patched), 'missing' (no list yet and Mapterhorn not reachable) or an error text."""
        now = time.time() if now is None else now
        body = None
        try:
            age = now - os.path.getmtime(self.list_path)
            if age < LIST_REFRESH_S:
                with open(self.list_path, "rb") as f:
                    body = f.read()
        except OSError:
            pass
        fresh = body is None
        if fresh:
            try:
                body = sources.mapterhorn_list()
            except Exception as e:      # offline: keep what is there
                try:
                    with open(self.list_path, "rb") as f:
                        body = f.read()
                    fresh = False
                except OSError:
                    return "missing"
                if body is None:
                    return f"list: {e}"
        try:
            doc = json.loads(body)
        except ValueError as e:
            return f"list unreadable: {e}"
        doc, changed = patch_list(doc)
        if changed or fresh:
            atomic_write(self.list_path, json.dumps(doc).encode())
            return "patched" if changed else "ok"
        return "ok"


# --- the work ---------------------------------------------------------------------------------------

class Seeder:
    def __init__(self, cache, sources, workers=WORKERS):
        self.cache, self.src = cache, sources
        self.q = queue.PriorityQueue()
        self.queued = set()
        self.lock = threading.Lock()
        self.stats = {"written": 0, "outside": 0, "errors": 0, "decodedRemoved": 0}
        self.last_error = ""
        self.paused = False
        self.pose = None
        self.list_state = "not checked"
        self.seq = 0
        self.workers = workers
        self.dirty = 0
        self.tries = {}

    def add(self, keys, prio):
        n = 0
        with self.lock:
            for k in keys:
                if k in self.queued or self.cache.state(k) is not None:
                    continue
                self.queued.add(k)
                self.seq += 1
                self.q.put((prio, self.seq, k))
                n += 1
        return n

    def add_area(self, lat, lon, radius_m, prio=5):
        n = 0
        for z in ZOOMS:
            r = radius_m * {15: 1.0, 14: 1.3, 13: 1.6}[z]
            n += self.add(tiles_around(lat, lon, r, z), prio + (15 - z))
        return n

    def around_car(self, pose):
        """Queue the tiles round the car and ahead of it (nearest first)."""
        lat, lon = pose["lat"], pose["lon"]
        ve, vn = float(pose.get("ve") or 0.0), float(pose.get("vn") or 0.0)
        alat = lat + vn * AHEAD_S / 111320.0
        alon = lon + ve * AHEAD_S / (111320.0 * max(0.05, math.cos(math.radians(lat))))
        for z in (15, 14, 13):
            self.add(tiles_around(alat, alon, RADIUS_M[z] * 0.5, z), 0 + (15 - z))
            self.add(tiles_around(lat, lon, RADIUS_M[z], z), 1 + (15 - z))

    def fill(self, key, h):
        """h's NaN pixels from Mapterhorn's tile, or its nearest ancestor upsampled. Returns h, or None when some stay
        empty (no Mapterhorn either: leave the tile to BeamNG.Earth)."""
        holes = ~np.isfinite(h)
        if not holes.any():
            return h
        z, x, y = key
        for dz in range(0, z - 9):
            mt = self.src.mapterhorn(z - dz, x >> dz, y >> dz)
            if mt is None:
                continue
            if dz:
                k = 1 << dz
                mt = upsample_quadrant(mt, dz, x - (x >> dz) * k, y - (y >> dz) * k)
            h = h.copy()
            h[holes] = mt[holes]
            return h
        return None

    def do(self, key):
        h = self.src.cuzk(*key)
        if not np.isfinite(h).any():
            self.cache.mark(key, "outside")
            self.stats["outside"] += 1
            return "outside"
        h = self.fill(key, h)
        if h is None:
            self.cache.mark(key, "outside")
            self.stats["outside"] += 1
            return "outside"
        self.stats["decodedRemoved"] += self.cache.write_tile(key, h)
        self.cache.mark(key, "written")
        self.stats["written"] += 1
        return "written"

    def work(self):
        while True:
            if self.paused:
                time.sleep(0.5)
                continue
            try:
                prio, _, key = self.q.get(timeout=1.0)
            except queue.Empty:
                continue
            again = False
            try:
                self.do(key)
                self.dirty += 1
            except Exception as e:
                self.stats["errors"] += 1
                self.last_error = f"{key[0]}/{key[1]}/{key[2]}: {type(e).__name__}: {e}"[:300]
                with self.lock:
                    n = self.tries[key] = self.tries.get(key, 0) + 1
                    if n < RETRIES:     # (asked again later, behind the rest)
                        self.seq += 1
                        self.q.put((prio + 10 * n, self.seq, key))
                        again = True
                time.sleep(2.0)
            finally:
                if not again:
                    with self.lock:
                        self.queued.discard(key)

    def status(self):
        with self.lock:
            q = len(self.queued)
        return {"version": VERSION, "cache": self.cache.root, "list": self.list_state, "queued": q,
                "paused": self.paused, "pose": self.pose, "lastError": self.last_error, **self.stats}


def follow_feed(seeder, feed, stop):
    """Read the car's position from BeamNG.Earth's companion feed (/v1/pose) and queue the tiles round it."""
    last = None
    while not stop.is_set():
        try:
            p = json.loads(http_get(feed.rstrip("/") + "/v1/pose", timeout=5))
            if p.get("ok") and p.get("lat") is not None:
                seeder.pose = {"lat": p["lat"], "lon": p["lon"]}
                here = (round(p["lat"], 3), round(p["lon"], 3))
                if here != last:
                    last = here
                    seeder.around_car(p)
        except Exception:
            pass
        stop.wait(2.0)


def housekeeping(seeder, stop):
    while not stop.is_set():
        try:
            seeder.list_state = seeder.cache.ensure_list(seeder.src)
        except Exception as e:
            seeder.list_state = f"error: {e}"
        for _ in range(60):
            if stop.wait(5.0):
                break
            if seeder.dirty:
                seeder.dirty = 0
                try:
                    seeder.cache.save_done()
                except OSError:
                    pass


PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>CZ lidar terrain</title><style>
body{font:15px system-ui,sans-serif;margin:0;background:#f4f5f7;color:#1c1f24}main{max-width:640px;margin:0 auto;padding:16px}
.card{background:#fff;border-radius:10px;padding:14px 16px;margin:12px 0;box-shadow:0 1px 3px #0002}
button{font:inherit;padding:8px 14px;border:0;border-radius:8px;background:#2c6bed;color:#fff;margin:4px 6px 4px 0;cursor:pointer}
button.alt{background:#e3e7ee;color:#1c1f24}input{font:inherit;padding:7px;width:7em}td{padding:3px 12px 3px 0}
small{color:#5d6470}@media(prefers-color-scheme:dark){body{background:#15171b;color:#e6e8eb}.card{background:#1f2227}
button.alt{background:#30343b;color:#e6e8eb}small{color:#9aa1ad}}</style></head><body><main>
<h2>CZ lidar terrain</h2><small>Czech DMR 5G heights for BeamNG.Earth. Terrain &copy; ČÚZK (DMR 5G, CC BY 4.0).</small>
<div class="card"><table id="s"></table></div>
<div class="card"><b>Prepare an area</b><br><small>Writes the tiles before you drive there, so the first visit already
has the lidar ground.</small><br>
<button onclick="prep(5)">5 km round the car</button><button onclick="prep(10)">10 km</button><button onclick="prep(20)">20 km</button><br>
<input id="lat" placeholder="lat"> <input id="lon" placeholder="lon"> <input id="r" placeholder="km" value="5">
<button class="alt" onclick="prepAt()">Prepare here</button></div>
<div class="card"><button class="alt" id="p" onclick="pause()">Pause</button></div>
<script>
async function j(u,o){const r=await fetch(u,o);return r.json()}
async function tick(){try{const s=await j('/v1/status');const rows=[['Tiles written',s.written],['Waiting',s.queued],
['No Czech data',s.outside],['Errors',s.errors],['Last error',s.lastError||'none'],['Mapterhorn list',s.list],
['Car',s.pose?s.pose.lat.toFixed(4)+', '+s.pose.lon.toFixed(4):'no position yet'],['Cache',s.cache]];
document.getElementById('s').innerHTML=rows.map(r=>'<tr><td>'+r[0]+'</td><td>'+String(r[1]).replace(/</g,'&lt;')+'</td></tr>').join('');
document.getElementById('p').textContent=s.paused?'Resume':'Pause'}catch(e){}}
async function prep(km){await j('/v1/prepare',{method:'POST',body:JSON.stringify({km})});tick()}
async function prepAt(){await j('/v1/prepare',{method:'POST',body:JSON.stringify({km:+r.value,lat:+lat.value,lon:+lon.value})});tick()}
async function pause(){await j('/v1/pause',{method:'POST'});tick()}
tick();setInterval(tick,2000)</script></main></body></html>"""


def make_handler(seeder):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype="application/json"):
            b = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def _local(self):
            host = (self.headers.get("Host") or "").split(":")[0]
            return host in ("127.0.0.1", "localhost")

        def do_GET(self):
            if not self._local():
                return self._send(403, {"error": "local only"})
            if self.path in ("/", "/index.html"):
                return self._send(200, PAGE.encode(), "text/html; charset=utf-8")
            if self.path == "/v1/status":
                return self._send(200, seeder.status())
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            if not self._local():
                return self._send(403, {"error": "local only"})
            n = int(self.headers.get("Content-Length") or 0)
            try:
                d = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                d = {}
            if self.path == "/v1/prepare":
                km = max(0.5, min(50.0, float(d.get("km") or 5)))
                lat, lon = d.get("lat"), d.get("lon")
                if not lat or not lon:
                    if not seeder.pose:
                        return self._send(409, {"error": "no car position yet"})
                    lat, lon = seeder.pose["lat"], seeder.pose["lon"]
                return self._send(200, {"queued": seeder.add_area(float(lat), float(lon), km * 1000.0)})
            if self.path == "/v1/pause":
                seeder.paused = not seeder.paused
                return self._send(200, {"paused": seeder.paused})
            return self._send(404, {"error": "not found"})
    return H


def main(argv=None):
    ap = argparse.ArgumentParser(description="Czech DMR 5G terrain for BeamNG.Earth")
    ap.add_argument("--cache-dir", default=os.environ.get("BNE_CZ_CACHE") or None,
                    help="BeamNG.Earth's cache folder (default: found from its settings)")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--feed", default=os.environ.get("BNE_FEED") or "http://127.0.0.1:47615",
                    help="BeamNG.Earth's companion feed")
    ap.add_argument("--prepare", nargs=3, type=float, metavar=("LAT", "LON", "KM"),
                    help="write an area's tiles, then stop (no page, no car)")
    a = ap.parse_args(argv)
    cache = Cache(a.cache_dir or find_cache_dir())
    seeder = Seeder(cache, Sources())
    stop = threading.Event()
    print(f"CZ lidar terrain {VERSION}: cache {cache.root}", flush=True)
    seeder.list_state = cache.ensure_list(seeder.src)
    print(f"Mapterhorn list: {seeder.list_state}" + (" (restart BeamNG.Earth once so it reads it)"
                                                     if seeder.list_state == "patched" else ""), flush=True)
    for _ in range(seeder.workers):
        threading.Thread(target=seeder.work, daemon=True).start()
    if a.prepare:
        n = seeder.add_area(a.prepare[0], a.prepare[1], a.prepare[2] * 1000.0)
        print(f"{n} tiles to write", flush=True)
        while seeder.status()["queued"]:
            time.sleep(2.0)
            s = seeder.status()
            print(f"  {s['written']} written, {s['queued']} waiting, {s['errors']} errors {s['lastError']}", flush=True)
        cache.save_done()
        return 0
    threading.Thread(target=follow_feed, args=(seeder, a.feed, stop), daemon=True).start()
    threading.Thread(target=housekeeping, args=(seeder, stop), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(seeder))
    print(f"Page: http://127.0.0.1:{a.port}/", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        cache.save_done()
    return 0


if __name__ == "__main__":
    sys.exit(main())
