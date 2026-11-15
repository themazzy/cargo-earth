# Cargo Earth 0.10.1

Phone usability, bus pickup and door controls, readable stop names, and more useful bus-loading status.

**Update both the mod and helper.** Run CargoEarthSetup.exe and choose 1, or replace the mod with cargo_earth_career_0.10.1.zip and update the registered helper to cargo_earth_helper_0.10.1.py. Close BeamNG and stop the helper first, then restart both. Keep only one Cargo Earth ZIP installed. Existing career saves are retained.

Requires BeamNG.Earth 1.9.0-beta or newer. Earth 1.10 adds posted speed-limit support.

## Phone controls stay within reach

- Current-job controls are outside the scrolling details: bus doors, Navigate, Skip stop, End shift, tow loading/hitching, and trailer recovery.
- Accept/Decline, parts checkout, car-preview purchase/return, company settlement, home confirmation, and garage navigation/repair controls stay separate from their scrolling lists.
- Radio playback and volume remain visible while browsing stations.
- Nearby freight contracts have more room, with All contracts outside the list.
- Long names, prices, action rows, fuel/damage status and notifications wrap or use bounded scrolling. The headquarters has a narrow-screen layout.

## Bus pickup and stops

- Choose a line to show its depot marker and set GPS. Park your own career car inside the 12 m marker for two seconds; only then is it stored and replaced by the bus. Cancel selection cancels before pickup.
- A discovery refresh cannot move the depot after you select it, including when a new depot is discovered for the same line.
- Use the normal **O** door control or **Open doors** on the phone. Both start the same boarding flow. Closing early cancels boarding without serving the stop or duplicating passengers.
- The phone and upper overlay show the same passenger timer. Bus stops no longer show the generic one-second cargo countdown.
- GPS road distance and ETA keep updating during bus runs; stale values clear when navigation is planning or unavailable.

## Stop names and helper loading

- Helper responses preserve UTF-8 names, fixing Czech text displayed as literal u011b/u0161 fragments. A running shift can refresh corrupted saved names from matching OpenStreetMap stops without restarting it, when the route is available.
- Bus discovery shows checked, queued and failed areas, elapsed time, the server being tried, the actual error and a retry control.
- Distinguish no usable routes from routes whose starting depots are beyond the offer radius.
- OpenStreetMap runtime errors returned with HTTP 200 trigger the next server instead of being cached as empty routes for 14 days. Older bus caches refresh once.
- Recognise public-transport stops without an explicit bus=yes tag. Requests remain serialized, with faster server failover.

## Speed cameras paused

Speed-camera downloads, alerts, fines and star deductions are temporarily disabled, including for existing saves. Settings labels them Paused. Existing history is retained, and the normal road speed-limit display remains available.

## Validation and remaining checks

124 career checks, 38 helper checks, Lua syntax, bus-control/overlay tests and the phone checks passed. The phone source audit covers 11 Work states, every menu section and 40 critical action groups.

This remains an early development build. Visual checks at 290 x 560, 240 x 420 and 360 x 640, live bus discovery, depot placement and physical door behaviour still need in-game verification. One existing radio-relay test could not run because the execution environment blocked its local socket.
