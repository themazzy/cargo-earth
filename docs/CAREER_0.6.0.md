# Cargo Earth 0.6 (in progress)

Jan's picks on 12 November 2026: special cargo, tow jobs, fuel station resupply, and more trailer work. Everything is
clicked in the phone or the headquarters view, and nothing depends on the country, the weather or the time of day.

## Special cargo

About 3 in 10 freight offers carry a special load when the cargo allows it. The phone shows a coloured tag and the rule.
The load still travels in BeamNG's own containers.

| Load | Which cargo | Extra pay | Rule |
| --- | --- | --- | --- |
| Fragile | any box load | +40 % | every harsh moment (hard braking, accelerating or cornering) costs 8 % of the load |
| Chilled | milk, beer, packaged and chilled food | +30 % | time limit 20 % shorter; after it, 3 % of the load spoils per minute late |
| Oversize | furniture, pallets, car parts, machinery, consumer goods in a box truck or tractor | +50 % | an escort reports every 10 s above 60 km/h, and each report takes 3 % of the pay (at most 60 %) |

A load at 0 % is lost like a crashed one. Parcel routes and meals never become special.

## Fuel station resupply

A tractor gets up to two tanker runs among its offers. Each one takes fuel from the nearest fuel depot to a fuel station
15 to 150 km away. The stations are the ones the phone refuels at (bundled, or streamed by the helper), so the runs work
in any country. Besides the usual haul pay, the station adds 0.02 CZK a litre. The helper now also streams fuel depots
(oil terminals and refineries in Overture's places), so pickups exist outside the bundled packs too. Its area cache
moved to version 5. These runs are dangerous goods (ADR) and are hidden when ADR is turned off.

## Tow jobs

A broken-down car waits at a real address near you (up to 8 km away). Tow it to a workshop: your headquarters when it is
3 to 30 km away, otherwise the workshop at a fuel station.

- A vehicle with a tow hitch takes light jobs: one car on a car trailer, 220 CZK + 14 CZK/km.
- A tractor takes heavy jobs: two cars on a flatbed, (380 CZK + 20 CZK/km) × 1.5.

At the pickup, the trailer is spawned behind you with the car(s) on the deck, brakes on and engine off. Couple the
trailer and drive. The cars are not strapped down, so the phone tells you if one slides off. **Load the cars again**
(150 CZK) puts them back on, and also brings the trailer back after a reload. The job pays only when every car arrives
on the trailer. New damage to the cars costs 1 % of the pay per 60 points of BeamNG damage (at most 80 %). Damage they
already had when they broke down doesn't count.

## More trailers for the firm

The headquarters sells two more trailers:

- a flatbed trailer (7,000 CZK), for heavy tow jobs;
- a car trailer (2,500 CZK), for light tow jobs.

A tow job with a trailer your firm owns pays 12 % more. A hired tractor driver can also work with the flatbed.

## Not tested in the game yet

- The tow trailer models. The first stock model found is used: `cartrailer`, then `tsfb`, then `boxutility_large` for
  the car trailer, and `flatbed` for the flatbed. They can be overridden with `trailerModels` in the config.
- The broken-down car models and how they sit on the deck.
- The parking brake command sent to the towed cars.
- Tow hitch detection, which looks for part names containing `hitch` or `towball`.
- Overture's categories for fuel depots.
