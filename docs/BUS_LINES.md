# City bus lines

A third work mode beside food delivery and freight: pick **Bus** on the phone's offline screen (or in Settings).

## Where the lines come from

The helper asks OpenStreetMap (Overpass API) for bus and trolleybus route relations (`type=route`,
`route=bus|trolleybus`) and for bus stations / depots (`amenity=bus_station`, `landuse=depot`, `depot=bus`), one
request per 0.1 degree cell around the player, kept for 14 days (`/v1/buslines`). Each relation is one direction of a
line. Its stops are the stop positions on the road where the relation has them (`stop`, `stop_entry_only`,
`stop_exit_only`), else its platforms; a stop position without a name takes the nearest platform's. A line with fewer
than 4 stops, a gap over 4 km between stops (a broken relation) or under 1.2 km in all is left out. Works anywhere
OpenStreetMap maps the lines; data (c) OpenStreetMap contributors, ODbL.

## A shift

1. The phone lists up to 6 lines whose bus is lent within 4 km of you: at the bus station or depot nearest to the
   line's first stop (within 3 km), else at that first stop ("Terminus ...").
2. Drive your own career car there and press **Start**: the city lends you a stock Wentward city bus (a city
   configuration when the game has one); your car is kept, as with company contracts.
3. Drive to each stop in turn. Stop within 30 m and press **Open doors**. People get off (none at the first stop,
   0-40 % at the others, everyone at the last) and get on (fewer towards the end, never more than 70 on board). The
   doors stay open 3 s plus 0.6 s a person (15 s at most). Driving off before they close serves nobody: stop and open
   them again.
4. After the last stop the line is paid: 120 + 12 per km + 6 per stop, plus 2 per passenger, late minutes cost as for
   freight. As with company work, 80 % is your wage.
5. Bring the bus back where you got it. Parking there pays the shift and gives your car back. **End shift** ends early
   (finished lines are paid).

Rules: `lua/ge/extensions/cargoEarth/bus.lua` (pure); the shift runs through `cargoEarth/employment` with one job of
kind `bus` (saves accept a one-job shift with `tier = 'bus'`).

The phone button opens the real doors (citybus controller `bus`, `bus_doorsRequestedOpen`; fallback: the `doors` pneumatics on frontDoors/rearDoors). Not done yet: coaches between towns, and
buying your own bus. Not tested in game.

## People in the seats

BeamNG 0.40 has a seat system (`gameplay_seatOccupants`): every stock car whose seats have an `occupant_generic` part
shows the player in the driver's seat, and the game can seat dummy people in the other seats.

- **Passengers.** The lent city bus gets an `occupant_generic` part in all 34 passenger seats (`occupants.BUS_SEATS`).
  The people on board sit in them as BeamNG dummy occupants, 75 kg each (real weight, Jan's pick), in a scattered
  order fixed per line, so people stay where they sat. At a stop, those getting off leave their seats when the doors
  open; those getting on sit down when the doors close. Over 34 on board, the rest stand and are not shown.
- **Driver.** After the mod spawns, swaps or respawns the player's car, it checks once (1 to 8 s later) that the
  player sits in a seat and asks the game to seat them if not. Mod cars without seat occupant slots show no driver;
  that is up to the car's author.
