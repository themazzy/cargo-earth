# Phone and bus discovery test build

Based on GitHub v0.10.0 (aeccb2400b0b774c73564621379f82b49acdbbe0). This is an unpublished test build.

- Freight's offline summary is compact, its nearby contracts take the remaining scrolling area, and the daily statistics card no longer crowds that list. Long company names wrap beside the wage.
- Bus searches show checked, queued and failed areas, elapsed loading time, the active server, retry cooldown and the actual error. A helper timeout no longer means an outdated helper; only HTTP 404 does.
- Searches distinguish no usable mapped routes from routes whose starting depots are outside the 4 km offer radius, including the nearest starting distance.
- Retry bus search rechecks failed or empty areas, coalesces in-flight work, and limits repeated manual requests.
- OpenStreetMap runtime errors returned as HTTP 200 trigger the next server instead of being cached as empty routes for 14 days. Earlier bus caches are refreshed once.
- Public transport stop positions/platforms without an explicit bus=yes tag can discover their bus route relations.
- Overpass requests remain serialized. Bus searches take priority over queued camera work; each mirror has a 40-second client timeout and a 30-second bus query timeout.
- Speed cameras are temporarily paused in both the game and helper. There are no camera downloads, alerts, fines or lost stars, including for saves that previously enabled cameras. Settings labels the feature Paused. Existing fines/history and the normal road speed-limit display are retained.
- Choosing a bus line marks its depot and sets GPS without spawning a vehicle. Park your own car inside the 12 m marker for two seconds: only then is it stored and replaced with the lent bus. Selection can be cancelled before pickup.
- The upper stop overlay and phone share the passenger boarding/alighting timer. Bus stops no longer run the generic one-second cargo timer. Both displays say to open the doors while waiting.
- BeamNG's normal O / toggle_doors control is observed through the stock bus controller. It starts the same boarding flow as the phone button. Closing the doors early cancels boarding, without serving the stop or duplicating passengers. Other vehicle IDs and stale callbacks are ignored.
- Helper API JSON is sent as actual UTF-8, preventing Czech stop names becoming literal u011b/u0161 fragments. Corrupted active-shift names are refreshed from fresh OSM stops at matching coordinates when that route is available; progress and payment IDs are preserved.
- Phone-wide source audit: current-job controls, checkout and preview confirmation controls, company settlement and radio playback are outside scrolling details. Names, prices and action rows wrap; long alerts cannot push navigation off screen. See PHONE_UI_AUDIT.md for screen coverage and the remaining visual checks.

## Install for testing

Close BeamNG and stop the helper. Replace the installed Cargo Earth mod ZIP with `cargo_earth_career_0.10.0_ui_bus_fix.zip` (keep just one Cargo Earth ZIP). Replace the contents of the helper file that BeamNG.Earth actually launches with the supplied helper, keeping its registered path, or update the add-on registration to the new file. Restart the helper and BeamNG. The installed helper may be in BeamNG.Earth's add-ons folder rather than the standalone installer's helper folder. Career saves do not need to be reset.

## Verification

- Lua syntax, 9 helper-client checks, 122 career checks, 9 dashboard checks, wreck checks, bundled depot data and the phone interaction/template checks passed. Native bus-door observation, the actual overlay rendering calls, depot parking and active-shift name recovery also passed isolated checks.
- 38 Python helper checks passed, including UTF-8 API output, retry/error-cache handling, queued/active progress and camera pause. One existing radio-relay check that opens a local socket was excluded after the execution sandbox blocked the socket.
- Visual preview could not be opened because browser policy blocks local file URLs. Freight at the normal 290 x 560 size, depot marker placement, physical door controls and live bus discovery still need in-game verification.
- The installed helper's log showed both successful bus downloads and repeated Overpass timeouts. The patch addresses local queueing, handling and visibility; it does not guarantee availability of the public Overpass servers.
