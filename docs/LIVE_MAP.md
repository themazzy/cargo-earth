# Live map (phone Map tab)

The phone's **Map** tab draws a flat, heading-up sat-nav sketch:

- **Roads** come from the game's road graph (`map.getMap()`), the graph BeamNG.Earth hands to the game for its
  traffic. Nothing is downloaded and no other add-on is needed. Roads within 1 km of the car are sent to the phone
  only when the car enters another 300 m tile (or the graph changes), so the 4-per-second updates stay small.
  Colours: tracks grey and thin, streets white, roads of 60 km/h and more yellow, 90 km/h and more orange.
- **Route**: BeamNG.Earth's planned GPS route (modding API 1.6, `gpsRoute()`), cached per route version and frame.
  With an older Earth, a dashed straight line to the next stop.
- **Stops**: the next stop (P pickup / D delivery, held at the map's edge with an arrow when off screen), the other
  orders' stops, a parcel route's stops ahead (numbered), Home (H) and the firm's workshop (W).
- Three zoom steps (250 / 500 / 1000 m top to bottom), remembered per phone. Click-only, works on the dash phone.
- Nothing is asked or drawn while another tab shows or the phone is folded or hidden.

Code: `lua/ge/extensions/cargoEarth/phonemap.lua` (pure rules), `core.phoneMap(roadsKey)`, the Map tab in
`ui/modules/apps/CargoEarthPhone/app.js`. Tests: `tests/phonemap.lua`, the live map test in `tests/career.lua`,
the Map tab in `tests/phone.cjs`.
