# BeamNG.Earth 1.10 modding API in Cargo Earth

BeamNG.Earth 1.10.0-beta (2026-11-14) raised its modding API from 1.1 to 1.8. Nothing Cargo Earth used changed, so the
mod still runs on 1.9.0-beta. Every new feature is checked with `beamngEarth_api.has(...)` and the old behaviour stays
on an older Earth.

- **Posted speed limits** (`speedlimit.lua`): Earth 1.10 keeps the legal limit on each road graph edge (`posted`, m/s;
  positive the map's own limit, negative the road class's default). The phone's speed sign and the speed cameras use
  it directly. Without it, the old guess from the traffic speed (which Earth lowers in bends) is used.
- **Multi-stop GPS for parcel routes** (API 1.2 `gpsSetRoute`): after loading, the GPS goes through every address
  still ahead (at most 11), so the whole round is on the map. The phone's distance and time are to the next address
  (from the route's legs). If Earth drops an address the car only drove past (within 40 m), the stops are set again
  once the car is 80 m clear of it. After a stop is served, a route Earth is already following is left alone.
- **Earth's own coordinate conversion** (API 1.6 `toGame`): stop markers, poles and cameras are placed with it.
  The same east/north maths stays as the fallback.
- **World origin moved** (API 1.7 `onBeamNGEarthRebased`): markers are worked out again straight away.

Kept on the helper (Jan, 2026-11-15): restaurants, addresses, depots and other places. The helper reaches farther and
has more detail than Earth's `places()` (3 km, or 25 km over cached cells only).
