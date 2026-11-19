# Cargo Earth 0.10.4

Taxi as its own job, freight to towns up to 800 km away, a fairer career with a Progress page, car damage kept in your
save, and one way to find workplaces everywhere on Earth (the bundled Czech data is gone, so the mod is much smaller).

**Update both the mod and the helper.** Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux)
and choose 1, or replace the mod with `cargo_earth_career_0.10.4.zip` and the helper with `cargo_earth_helper_0.10.4.py`.
Close BeamNG and the helper first. Keep only one Cargo Earth ZIP installed. Saves are kept. Requires BeamNG.Earth
1.9.0-beta or newer.

**The helper moved to port 47821** so it no longer clashes with EarthRadio (which uses 47820). The installer updates
BeamNG.Earth's add-on entry and your settings. If you start the helper by hand, restart BeamNG.Earth after updating so
the old helper closes.

## Taxi is its own job
- Pick **Taxi** next to Food delivery, Freight and Bus. It has its own distance settings and its own search.
- Owned cars, SUVs and passenger vans qualify when the game finds at least one usable passenger seat. Groups fill up to
  the seats you have; each passenger after the first adds 20 % to the fare.
- A more valuable car earns more: +15 % of the fare per doubling of its value above 10,000 CZK, up to +45 %.
- Time allowances include the drive to the pickup. Passengers only count as boarded once they are really seated.

## Long-distance freight
- Freight and company contracts can go up to 800 km. The helper loads workplaces around far towns (picked from a
  bundled list of towns, spread in every direction) and they become delivery points.
- When a far or newly found site has no proper loading spot, **Load here** / **Hand over here** appears within 600 m
  for 85 % of the pay, with no fee.

## One data source for the whole Earth
- The bundled Czech depots, restaurants and fuel stations are removed. Czechia now uses the helper like every other
  country, and the mod ZIP is about 2 MB instead of 16 MB.
- Workplaces from the helper get real cargo types (steel, timber, chemicals and more) instead of only general pallets.
  The helper rebuilds its area cache once.

## Fairer career and a Progress page
- Bus and taxi no longer out-earn everything else. Parts runs, parcel routes, tow jobs and van and box truck freight pay
  more; company contracts in a lent box truck or tractor pay 65 % of the fare.
- Vans cost half their usual price, box trucks and tractors about a third. Box trucks unlock after 3 van hauls,
  tractors after 5 box truck hauls. Your first own tractor takes about 12 hours instead of 50.
- Each kind of work pays a little more the more you do it.
- **Progress** lists every kind of work: what it needs, whether you can do it now (and what is missing) and about how
  much it earns an hour. Ranks show what they unlock.
- Parts taken off a cheap work vehicle sell at that vehicle's discount.

## Jobs settings
- Menu → Settings → **Jobs**: pick a job type and set its pickup radius and shortest/longest distance with − and +.
  Each job type keeps its own values, and Reset resets only that one.

## Used cars
- Eight listings per category, refilled straight away. Each listing lasts 15 to 30 minutes of play and shows a live
  timer.
- Trade-ins and direct sales always give at least 25 % of the car's parts value.

## Car damage stays
- Dents, broken parts and mechanical damage are saved with the career and come back when you load it. Each car's
  damage sits in its own file next to the save, and is only written when the car got new damage, so saves are lighter.

## Phone
- The Work page has one row of Food / Freight / Taxi / Bus buttons instead of a drop-down, so it works on the dash
  phone in VR. The Jobs settings list also scrolls with the holder's buttons.
- Details (stops, distance, time, cargo and more) show as small pills instead of long lines joined with dots.
- Distance labels match the job (ride, tow, round...).

## Fixes
- Stop rings stay on the ground instead of climbing trees, pylons or roofs. A car on a bridge above the stop or on a
  road under it no longer counts as arrived.
- Bus: boarding stops if you leave the stop and freezes on pause. Lines are found by nearby stops, with each direction
  selectable. Comfort ignores normal braking (0.8 g) but notices low-speed crashes from damage.
- Tow: cars on the trailer stay put when BeamNG.Earth teleports you. A dropped car can be reloaded onto the hitched
  trailer for 150 CZK.
- Road distances for offers share one search budget, so long offer lists don't freeze the game for a moment.

## Not tested in game yet
Taxi seat checks and seating, far-town freight and the hand-over, helper workplace types, saved car damage and its
files, the new port with EarthRadio, the Progress page, Jobs settings on the dash phone, stop rings on real ground.
