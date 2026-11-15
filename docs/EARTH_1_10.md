# BeamNG.Earth 1.10 modding API in Cargo Earth

BeamNG.Earth 1.10.0-beta (2026-11-14) raised its modding API from 1.1 to 1.8. Nothing Cargo Earth used changed, so the
mod still runs on 1.9.0-beta. Every new feature is checked with `beamngEarth_api.has(...)` and the old behaviour stays
on an older Earth.

- **Posted speed limits** (`speedlimit.lua`): Earth 1.10 keeps the legal limit on each road graph edge (`posted`, m/s;
  positive the map's own limit, negative the road class's default). The phone's speed sign and the speed cameras use
  it directly. Without it, the old guess from the traffic speed (which Earth lowers in bends) is used.
- **Multi-stop GPS for parcel routes**: tried and taken out again (Jan, 2026-11-15). Earth puts its destination, and
  the map's teleport to it, at the last point of a route through several stops, so the teleport went to the round's
  final address and Navigate on the phone kept that spot. The GPS goes to the next undelivered address alone, set
  again after every stop, after a teleport (once the world is ready) and by Navigate. `earth.gpsStops` stays for
  later use.
- **Earth's own coordinate conversion** (API 1.6 `toGame`): stop markers, poles and cameras are placed with it.
  The same east/north maths stays as the fallback.
- **World origin moved** (API 1.7 `onBeamNGEarthRebased`): markers are worked out again straight away.

Kept on the helper (Jan, 2026-11-15): restaurants, addresses, depots and other places. The helper reaches farther and
has more detail than Earth's `places()` (3 km, or 25 km over cached cells only).
