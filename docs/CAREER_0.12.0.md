# Cargo Earth 0.12.0

A real street map on the phone with turn directions, lanes, speed and limit, stop rings at the roadside instead of
inside houses, the dash phone behind the steering wheel, part changes on cars that damage themselves, and door and
radio fixes.

**Update both the mod and the helper** (the map tiles come through the new helper). Run `CargoEarthSetup.exe`
(Windows) or `CargoEarthSetup-linux-x86_64` (Linux) and choose 1, or replace the mod with
`cargo_earth_career_0.12.0.zip` and the helper with `cargo_earth_helper_0.12.0.py`. Close BeamNG and the helper first.
Keep only one Cargo Earth ZIP installed. Saves are kept. Requires BeamNG.Earth 1.9.0-beta or newer; turn directions
and lanes need Earth's modding API 1.7 (older versions show the map without them).

**Most of this release is not tested in game yet.** The street map, tile loading, the speed colours and the
slim tab bar were checked in game or in the browser preview; roadside stops, the dash phone's Behind wheel spot,
part changes on damaged cars and the door watch have only passed the automated tests. Please report what breaks.

## Live street map
- The phone's **Map** tab now draws OpenStreetMap streets (OpenFreeMap vector tiles): water, parks, roads, buildings,
  street and river names that follow the street, and named places (food, shops, fuel, health, lodging). The tiles come
  through the helper and are kept on disk. Without the helper the phone shows the simple road map and says why.
- **Directions**: the next turn with an arrow, the distance and the street; lane arrows within 1 km of the turn.
- **Speed**: a speedometer with the limit sign beside it. Amber just over the limit, red well over (more than 10 km/h
  or 10 %). A short chime when you go over; tap the speedometer to mute it.
- **Way left**: distance, time and arrival clock time to the next stop. The orange work bar shows the way left on every
  tab.
- **Close up**: house numbers in the 250 m view, one-way arrows, speed cameras as small limit signs, Home and HQ pins,
  and a name tag on the next stop.
- **Whole-route view** button, and a **Route to** panel (Home, Headquarters, Nearest fuel, Clear route) while no job
  steers the GPS.
- A ⚙ panel on the map switches the chime, street and river names, places by kind, house numbers, one-way arrows, speed
  cameras, buildings, North up, auto zoom, lane arrows, the speedometer and **Latin names** (read Cyrillic and other
  scripts in Latin letters).
- On the Map tab the job is one slim line under the turn banner, so the map reaches the top of the phone. Tap it to
  open the Work tab.
- Details: [live map](https://github.com/themazzy/cargo-earth/blob/main/docs/LIVE_MAP.md).

## Phone
- Slimmer bottom tab bar (icon beside the label) and footer: about 26 px more room for every tab.

## Roadside stops
- Drop-offs, parcel stops, taxi pickups and drop-offs and tow places now stand at the edge of the nearest road on the
  building's side, like food pickups already did. Before, some rings stood inside houses. Freight yards keep their own
  gate points.

## Dash phone
- Settings → Phone on the dashboard → **Default position**: **Behind wheel** (on top of the gauges, facing the driver)
  or **Center console** (as before). Each car is measured again for the new place; nudges are kept per place. A car
  with no dash ahead of the driver keeps the old place and says why.

## Parts on damaged cars
- A car whose config damages itself on spawn (for example a box truck with a cab kit that doesn't fit) no longer locks
  the parts picker. You can swap damaged parts for new ones; the repair of what you replace is paid in the checkout,
  and every other part keeps its damage. Discard puts the car back as it was.

## Fixes
- Doors, hood and tailgate that hang open and can't be shut after loading a save are reset properly. The career car
  also watches its latches while you drive and re-latches one that came loose unnoticed (for example after accepting a
  contract).
- Radio on Linux: media players no longer inherit BeamNG.Earth's library path (mpv and ffplay failed to start on some
  systems).
- Radio: Stop ends the whole player (also snap/flatpak launchers), and no station keeps playing after the helper or
  BeamNG closes.
