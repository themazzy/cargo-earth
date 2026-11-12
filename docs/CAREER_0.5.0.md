# Cargo Earth 0.5

Four features Jan picked on 12 November 2026. Everything is clicked in the phone or the headquarters view; nothing
depends on the country, the weather or the time of day.

## Trucks and trailers for the firm

The headquarters view has a factory list: an H-Series cargo van, an MD-Series box truck and a T-Series tractor, BeamNG's
stock configs, priced by their game value like every car (no used discount; fallback prices 6,000 / 14,000 / 20,000 CZK
when the game has none). A bought vehicle goes straight into a free bay; nothing is spawned until you drive it.

Trailers: a box trailer (6,000 CZK: parcels, pallets, dry bulk) and a tanker (8,000 CZK: milk, fuel, chemicals), up to
six in the yard, sold back for half. A hired tractor driver needs a free trailer to work. Your own articulated jobs pay
12 % more when the load fits a trailer the firm owns (no trailer hire).

## Hired drivers with skills

Three people look for work at a time; a new list comes every 20 minutes of play. Each has a speed (80-125 %), a level of
care (75-125 %) and a wage per 10-minute shift (15-70 CZK, higher for better drivers). In the headquarters view you
choose someone in the office, then the vehicle in the yard; the hire button shows what that person would bring in per
shift in that vehicle. A shift brings in 70 (car), 110 (van), 170 (box truck) or 260 CZK (tractor) times the driver's
speed and the dispatch office, less the wage. Drivers from before 0.5 become average drivers (wage 25), so they bring
in the same 45 CZK a shift as before.

A shift drives 8-15 km and wears the vehicle; a careless driver wears it faster and has more accidents (3 % a shift
for an average driver). An accident, or a breakdown of an overdue vehicle, leaves the vehicle waiting for a repair at
the headquarters (Repair in its bay, with the workshop discount).

## Upkeep

Every owned car keeps km since its last oil change (every 800 km), tyres (2,500 km) and brakes (1,600 km). A starter
car comes worn, a used car as worn as its condition. The phone's Garage shows what is due; service at the
headquarters (workshop discount) or at any fuel station. Bigger vehicles cost more to service (van x1.3, box truck
x2.4, tractor x3.2).

Overdue service can end in a breakdown: 0.4 % per km for each whole interval overdue. The most overdue part fails, the
engine is switched off and kept off until you call roadside help from the phone (twice that service plus 150 CZK;
what you cannot pay is added to your debt). Company and loaner vehicles are looked after by their owners.

## Customer tips

Private customers (meals and parcel routes) tip for speed as before, and add 6 % of the pay for a smooth ride. A harsh
moment (hard braking, accelerating or cornering: 0.55 g or more held for 0.4 s, at most one every 3 s, measured by the
car's own accelerometer) loses the smooth tip and 30 % of the speed tip each. The phone says why: fast, smooth ride, or
how many harsh moments.

## Not tested in the game yet

- Switching the engine off for a breakdown (`electrics.setIgnitionLevel`) and on again after roadside help.
- The harsh-moment threshold: it may need tuning once it is felt in a real car.
- Spawning a firm vehicle bought into a bay the first time you drive it.
