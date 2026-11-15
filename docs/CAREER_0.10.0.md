# Cargo Earth 0.10.0

Changes since 0.9.1. **Needs the new helper** (bus lines, parts shops and repair shops come from it; its area cache
moves to format 6 and downloads those areas again). Still runs on BeamNG.Earth 1.9.0-beta; 1.10 adds posted speed
limits. Little of this has been driven in game yet.

## New: Bus mode
- A third work mode beside Food delivery and Freight. The helper reads real city bus and trolleybus lines from
  OpenStreetMap; the phone lists up to 6 lines near you.
- Drive to the depot or terminus and press **Start**: the city lends you a bus and keeps your car. Stop at each stop,
  press **Open doors** (the bus's real doors open), wait while passengers get off and on, and drive on. The line pays
  at the last stop, where the bus is handed over and BeamNG.Earth takes you back to the depot and your own car.
- **Skip stop** passes a stop the bus can't reach (nobody boards, that stop isn't paid). **End shift** before the last
  stop pays nothing for the line; away from the depot the company collects the bus for 150 CZK.
- Passengers sit in the bus's seats as BeamNG's own seated people (75 kg each), getting up and sitting down at the
  stops. See `docs/BUS_LINES.md`.

## Each vehicle has its own work
- Cars are sorted by BeamNG's "Body Style": cars get short parcel rounds, SUVs and pickups get parts runs from parts
  shops and car plants to repair workshops, vans get parcel routes, box trucks get business shipping (no more parcel
  routes), tractors get trailer freight, tanker runs and heavy tows. Food delivery works in anything.
- Hired drivers hold licences (car, truck, articulated), know one vehicle kind best (+15 %) and wait when their vehicle
  has no cargo boxes. See `docs/VEHICLE_TYPES.md`.

## Tow jobs, redone
- Broken-down cars are real wrecks (crashed front, rear or side, rolled over, stripped, flat tyres) and wait by the
  road. Park the trailer next to one and press **Load** on the phone to put it on the deck.
- The tow trailer spawns coupled to your hitch; the car trailer is the game's tilt-deck. No more looping "stand still"
  bar at the pickup. Cancelling a tow job removes its trailer and cars.
- No car trailer of your own? The job starts at the repair shop: borrow its trailer, hitch it from the phone, fetch
  the car and bring both back to the same shop. The empty-trailer legs pay half the tow rate. A trailer of your own
  that is coupled is used instead and never deleted.
- Wrecks go to a real auto repair shop (or your headquarters), not a fuel station, when one is known.

## Heavier, visible loads
- Parcels, parts and freight weigh what they would in real life: a van carries up to a tonne, a box truck up to 8 t,
  a semi trailer up to 22 t. The dry-bulk trailer now fills all 16 aggregate boxes.
- The phone shows the kg on board and the kg dropped at every stop.

## Phone and settings
- **Dark mode** (Menu → Settings → Look).
- The phone stays folded through camera changes and the pause menu, without a flash of the open or light phone.
- Settings, Radio and the dash phone switch work on the "Load latest save" screen, before a career is loaded.
- **Restart career** in Menu → Settings, confirmed by typing DELETE (also from the resume screen).

## BeamNG.Earth 1.10
- The speed sign and speed cameras use Earth 1.10's posted speed limits when available (before: a guess from traffic
  speed). Markers and cameras use Earth's own coordinate conversion and follow when the world origin moves.
- Parcel route GPS goes to the next undelivered address, set again after each stop and after a teleport.

## Driver in the seat
- After the mod spawns, swaps or respawns your car, you are seated in the driver's seat (stock cars with seat
  occupants; mod cars depend on their author).

## Fixes
- Car and SUV jobs could not be saved ("Progress could not be saved").
- Cargo weight no longer stays in the car after cancelling an order. After a reset the load is put back, and any
  leftover load is emptied once nothing is on board.
- The debug window no longer breaks on tow and parcel offers.

## Not tested in game yet
Bus lines (live Overpass answers, door API, citybus configs, handover trip to the depot, seated passengers), driver
seating, tow coupling, trailer borrowing and deck placement, cargo clean-up on cancel, wreck forces, Body
Style detection, parts runs, handling at the new weights.
