# Live map (phone Map tab)

The Map tab has two maps. Tap **Use the simple map / Use the full map** in the timing readout (tap the north dial) to
switch; the choice is remembered per phone.

## Full map (default)

[MapLibre GL JS](https://maplibre.org) 4.7.1 (BSD-3-Clause, bundled in `ui/modules/apps/CargoEarthPhone/lib/` with
its licence) draws [OpenFreeMap](https://openfreemap.org) vector tiles (OpenStreetMap data, OpenMapTiles schema;
`liberty` style, `dark` in dark mode). The phone page downloads the tiles itself, so it needs an internet connection
and WebGL in the game's browser. The style's attribution (OpenFreeMap, OpenMapTiles, OpenStreetMap) shows in the map's
corner. In this mode the game sends no roads at all: only the car, the route and the stops by lat / lon
(`core.phoneMap(nil, perf, true)`), so the road graph costs nothing. The car arrow is fixed (68 % down, heading up)
and the map turns under it; the next stop and the other stops are markers.

If the library cannot load, the screen cannot draw WebGL, or the style has not arrived in 20 s, the phone shows the
simple map and says why (also in the timing readout).

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
