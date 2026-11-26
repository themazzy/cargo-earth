# Cargo Earth 0.12.2

Hotfix: stop rings show again on BeamNG.drive 0.40.6, and freight drop-offs can be found and reached.

**Update the mod.** The helper only changes its version number, so 0.12.x helpers keep working; the installer updates
both anyway. Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux) and choose 1, or replace
the mod with `cargo_earth_career_0.12.2.zip`. Close BeamNG first. Keep only one Cargo Earth ZIP installed. Saves are
kept. Requires BeamNG.Earth 1.9.0-beta or newer.

**Not tested in game yet.** These fixes passed the automated tests; please report what still misbehaves.

## Fixes
- **Stop rings on BeamNG 0.40.6.** The game changed how it takes the ring's fill colour, so the fill failed on every
  frame and rings showed at most a thin outline. The ring now works with both the old and the new game.
- **Freight yards at the road.** Yards, fuel depots and parts suppliers are often a point in the middle of a site, far
  from any road. A yard with no road within 20 m now puts its ring at the edge of the nearest road on its side.
- **A beacon on every stop.** Every pickup and drop-off has a tall named beacon (`Pick up: …` / `Deliver: …`),
  visible from 6 km. Before, only freight pickups had one.
- **Bus and coach stops** count at their roadside ring, also where the station's point lies inside the station.
- **Roadside spots found more reliably.** The spot is checked again every second until you are 100 m away (roads may
  still be streaming in), the road is searched at the stop's ground instead of your car's height (a car on a bridge
  found the bridge), and rings on a bank above or below the road are found.
