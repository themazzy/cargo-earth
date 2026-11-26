# Cargo Earth 0.12.1

Fixes for the dash phone screen, bus boarding and the map's street names.

**Update the mod.** The helper only changes its version number, so 0.12.0's helper keeps working; the installer
updates both anyway. Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux) and choose 1, or
replace the mod with `cargo_earth_career_0.12.1.zip`. Close BeamNG first. Keep only one Cargo Earth ZIP installed.
Saves are kept. Requires BeamNG.Earth 1.9.0-beta or newer.

**Not tested in game yet.** These fixes passed the automated tests; please report what still misbehaves.

## Fixes
- **Dash phone glows** like the game's own car screens. Before, the cabin light shaded it grey and it looked dim next to
  the UI phone.
- **Bus: opening the doors with the game's O key boards passengers.** Before, nobody boarded if the doors opened
  while the bus was still rolling or short of the stop, or after the bus was respawned (dash phone fit, repairs),
  until you pressed Doors on the phone.
- **Live map: names stay on their street.** Street, river and lake names no longer slide along the road with the car;
  each name keeps a fixed spot on its line and moves with the map.
