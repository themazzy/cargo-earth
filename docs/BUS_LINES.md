# City bus lines

A third work mode beside food delivery and freight: pick **Bus** on the phone's offline screen (or in Settings).

## Where the lines come from

The helper asks OpenStreetMap (Overpass API), one request per 0.04 degree cell (about 4 x 3 km) around the player,
one request at a time (waits up to 40 s per server), kept for 14 days (`/v1/buslines`). It finds the bus stops and platforms of
the cell first, then only the bus and trolleybus route relations (`type=route`, `route=bus|trolleybus`) that stop
there, then only those lines' stops and platforms (not their roads), and the bus stations / depots of the cell
(`amenity=bus_station`, `depot=bus`; a bare `landuse=depot` is left out, it is as often a tram or train depot). Each relation is one direction of a
line. Its stops are the stop positions on the road where the relation has them (`stop`, `stop_entry_only`,
`stop_exit_only`), else its platforms; a stop position without a name takes the nearest platform's. A line with fewer
than 4 stops, a gap over 4 km between stops (a broken relation) or under 1.2 km in all is left out. Works anywhere
OpenStreetMap maps the lines; data (c) OpenStreetMap contributors, ODbL.

## A shift

1. The phone lists up to 6 lines whose bus is lent within 4 km of you: at the bus station or depot nearest to the
   line's first stop (within 3 km), else at that first stop ("Terminus ...").
2. Press **Choose line** to set GPS and show a depot marker. Drive your own career car there and park inside the
   12 m marker for two seconds. Only then is your car stored and replaced by a stock Wentward city bus. A helper
   refresh cannot move the pickup after you have selected it. **Cancel selection** cancels before bus pickup.
3. Drive to each stop in turn. Stop within 30 m and press **Open doors** or **O**. People get off (none at the first stop,
   0-40 % at the others, everyone at the last) and get on (fewer towards the end, never more than 70 on board). The
   doors stay open 3 s plus 0.6 s a person (15 s at most), with the same timer on the phone and upper overlay.
   Closing the doors early cancels boarding. Driving off before they close serves nobody: stop and open
   them again. A stop the bus cannot reach (a road missing in BeamNG.Earth, say) can be passed with **Skip stop**:
   nobody gets on there and the stop is not paid.
4. **Timetable.** Every stop has its own time, counted from the moment the doors closed at the stop before (from the
   start at the depot for the first stop, plus a minute to get the bus out). A hop's time is its road km at a bus
   speed that grows with the hop: 18 km/h plus 8 km/h per km, at most 45 km/h (short city hops are slow, long ones
   between villages faster), times 1.15, plus 0.6 min for pulling in, the doors and pulling out, at least 1.5 min.
   Until the GPS has the route the road km is the straight line times 1.25; once it knows the road, that stop's time
   follows the real road (once per stop). The phone shows **Stop due in** for the current stop, and **Behind by**
   once it is late. The minutes late at each stop add up.
5. After the last stop the line is paid: 60 + 7 per timetable minute + 3 per stop (less each skipped stop's share),
   plus 2 per passenger; each minute behind the timetable (added up over the stops) takes 1 % (never below half).
   As with company work, 80 % is your wage. That is about 500-620 CZK an hour at the timetable's pace with the
   fares, near van freight; the board shows the wage and the fares a line usually brings.
   **Comfort** (as in a taxi): with people on board, every harsh moment (hard braking, accelerating or cornering,
   0.55 g for 0.4 s) costs 4 points and a bump or crash from 3.5 g costs 10-40. The phone shows it once it drops.
   The line's pay is multiplied by 0.6 + 0.004 x comfort (60 % at worst) and comfort counts in the stars and the
   company reputation like a load's condition. An empty bus feels nothing.
6. The line runs one way. At the last stop the bus is handed over; 3 s later BeamNG.Earth takes you back to the depot,
   where the shift is paid and your own car comes back. When Earth cannot take you there (2 minutes), the shift is
   settled where you are.
7. **End shift** before the last stop pays nothing for the line. At the depot it is free; anywhere else the company
   collects the bus for 150 CZK (`bus.COLLECT_FEE`, from your money, the rest as debt) and you are taken back to the
   depot as above.

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

