# Live map (phone Map tab)

The Map tab has two maps. Tap **Use the simple map / Use the OSM map** in the timing readout (tap the north dial)
to switch; the choice is remembered per phone.

## OSM map (default)

OpenStreetMap vector tiles from [OpenFreeMap](https://openfreemap.org) (OpenMapTiles schema), decoded and drawn by the
phone itself on its 2D canvas (`cargoEarthOsm` at the top of `app.js`). Two things in BeamNG's UI browser shape it:

- **No WebGL**: the game runs its browser with GPU drawing off ("GL_RENDERER = Disabled"), so a WebGL map library
  (MapLibre) cannot start. The phone has its own small Mapbox Vector Tile decoder and draws water, parks and woods,
  residential areas, buildings (close up), rail and roads by class (casing, then fill, small under big) with 2D canvas
  calls, and street names upright along the streets, kept clear of each other.
- **No web**: the browser does not load from the internet (the radio streams go through the helper for the same
  reason). The tiles come through the helper: `GET /v1/osm/tile?z=14&x=..&y=..` asks OpenFreeMap (the tile address
  from its TileJSON, asked once a day) and keeps the tile on disk (`cache/osm`, the oldest past 3000 dropped).
- **Not even the helper**: BeamNG's UI browser cancels the page's own requests to 127.0.0.1 (beamng.log:
  `BNGCefClient::OnBeforeResourceLoad| Resource cancel`). So the phone asks the game: `cargoEarth_core.osmTile(z, x, y)`
  (cargoEarth/osmtiles.lua) queues `/v1/osm/tile?...&as=b64` on the helper client's own map lane (worked every frame
  next to the radio's lane, never in its way) and answers `loading` until the helper sent the tile as base64 text;
  the phone asks again every 200 ms. A finished tile is handed out for 20 s, so every phone on screen gets it.
  `core.phoneMap` says `tiles = 'game'` when the helper is on. (The helper still answers a page directly, with CORS,
  for a browser that allows it.)

Each z14 tile (about 1.5 km) is cut into 512 px pieces, as many as the zoom needs, each drawn north-up once and kept
(48 at most); a frame only turns and places those pictures under the car, so a frame costs a few image draws. At most
two new pieces are drawn per frame. Decoded tiles are kept (30 at most), 4 load at once, a failed one is asked again
after 30 s. In this mode the game sends no roads at all, only the car, the route and the stops by lat / lon
(`core.phoneMap(nil, perf, true)`). The credit (© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors) is in the
map's corner.

Without the helper, or when three tiles failed and none came (the reason is named: the helper did not answer, is too
old, or could not reach OpenFreeMap), the phone shows the simple map and says why in a note you can close (✕).

## Directions

Over both maps: the next turn (BeamNG.Earth's route steps, OSRM maneuvers, modding API 1.7 `routeSteps`; arrow,
distance, "Turn left onto …", roundabout exits), the car's speed, and the way and time left to the next stop (Earth's
GPS `remaining` / `eta`). Lengths and speed follow the game's units (Options > Display, `uiUnitLength`): m / km and
km/h, or ft / mi and mph. Earth's step offsets count metres along its full route, ours along the simplified line, so
the car's distance along our line is scaled by Earth's route length.

**Lanes**: when the next turn is within 1 km and Earth's step has lane data (OSRM `lanes`), a row of lane arrows
shows under the banner, bright for the lanes that lead your way (a lane with several arrows shows the one the route
takes).

**Speeding**: the speedometer turns red and the phone plays a short two-tone chime (Web Audio) when the car goes over
the limit (the same moment the phone's speed-limit sign turns red, `OVER_KMH` over). Once per time over, again after
3 s back under. Only one phone chimes: the floating one, or the dash phone while the floating one is hidden. Tap the
speedometer to turn the chime off or on (`core.setQuiet`, kept in `settings/cargoEarth/ui.json` for both phones).

## Timing readout

Tap the north dial. It shows the game's time per answer (and per second, 4 answers a second), the answer's size and
round trip, the phone's drawing time and frames a second, and for the simple map the road index (time, slices,
edges) and the roads last sent; for the full map the tiles loaded and failed.

## Simple map

A flat, heading-up sat-nav sketch drawn on a canvas:

- **Roads** come from the game's road graph (`map.getMap()`), the graph BeamNG.Earth hands to the game for its
  traffic. Nothing is downloaded and no other add-on is needed. Roads within 1 km of the car are sent to the phone
  only when the car enters another 300 m tile (or the graph changes), so the 4-per-second updates stay small.
  Colours: tracks grey and thin, streets white, roads of 60 km/h and more yellow, 90 km/h and more orange.
- **Route**: BeamNG.Earth's planned GPS route (modding API 1.6, `gpsRoute()`), cached per route version and frame.
  With an older Earth, a dashed straight line to the next stop.
- **Stops**: the next stop (P pickup / D delivery, held at the map's edge with an arrow when off screen), the other
  orders' stops, a parcel route's stops ahead (numbered), Home (H) and the firm's workshop (W).
- Three zoom steps (250 / 500 / 1000 m top to bottom), remembered per phone. Click-only, works on the dash phone.
- Nothing is asked or drawn while another tab shows or the phone is folded or hidden. A frame that would look the
  same as the last one (the car stands) is not drawn again.
- The road index (the graph's edges sorted into 250 m cells) is built 3 ms at a time over several answers
  (`phonemap.SLICE_MS`), never in one frame: a city-size graph takes 15 to 100 ms to sort. The last finished index
  is used meanwhile; it is built again every 30 s so roads Earth streams in show up.

Code: `lua/ge/extensions/cargoEarth/phonemap.lua` (pure rules), `core.phoneMap(roadsKey)`, the Map tab in
`ui/modules/apps/CargoEarthPhone/app.js`. Tests: `tests/phonemap.lua`, the live map test in `tests/career.lua`,
the Map tab in `tests/phone.cjs`.

## Places, river names and the map's ⚙ panel

- **Places** come from the tiles' `poi` layer (OpenMapTiles): named businesses and landmarks, a dot coloured by kind
  (food, shops, fuel, health, other) and the name beside it, the most important of each tile first (`rank`). Street
  furniture (parking, bins, gates, benches...) is left out. They show only in the 250 and 500 m views, at most 12 at
  once, never over a street name, each other or the car.
- **River names**: named `waterway` lines, blue and slanted, placed like street names.
- **⚙ panel** (under the north dial): Speed chime, Street names, River names, Buildings, North up, Auto zoom (one step
  out from 70 km/h, back under 50), Lane arrows, Speedometer, and Places by kind. Kept in the player's
  `settings/cargoEarth/ui.json` (`map`), set by `cargoEarth_core.setMapPref(key, on)`; `phoneState().mapPrefs` brings
  them to every phone. The panel fits the map without scrolling (VR controllers can't scroll inside it).
