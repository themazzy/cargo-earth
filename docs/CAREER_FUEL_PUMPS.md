# Cheaper running costs and the game's own pumps

Released in 0.8.7.

## Lower fuel and service prices

A save from 2026-11-12 showed a Ferax using 21.6 L/100 km in town. BeamNG cars burn about two to three times what real
cars do, so at the real pump price (38 CZK/l) fuel took about 40 % of courier pay, and one 43 l fill cost 1,621 CZK
(about 3.5 hours of deliveries). Jan chose to cut fuel to a third and servicing in half:

| | Before | Now |
|---|---|---|
| Petrol / diesel / electricity | 38 / 36 CZK/l, 9 CZK/kWh | 13 / 12 CZK/l, 3 CZK/kWh |
| Roadside fuel call-out fee | 150 CZK | 30 CZK (75 until 2026-11-13) |
| Oil change / tyres / brakes (car) | 120 / 600 / 350 CZK | 60 / 300 / 175 CZK |
| Breakdown roadside fee | 150 CZK | 75 CZK |

Fuel is now about 13 % of courier pay and a full 50 l tank costs about 650 CZK. Service intervals, the 6 % station
spread, the firm tank's 15 % discount, the 1.6x roadside price and the bigger-vehicle service factors are unchanged.
Courier and freight pay are unchanged.

## Refuelling at the game's pumps

The game's own **Refuel** prompt at a gas station (the stock levels' stations, and BeamNG.Earth's stations, which go
through the same stock `freeroam/gasStations.lua`) now counts in the career:

- Cargo Earth wraps `freeroam_gasStations.refuelCar`. When you press Refuel in your career car, the next tank report
  that is fuller is booked as a purchase at that station (its name in the ledger, the same per-station price spread as
  the phone's stations, 0 for a company car). The phone's fuel gauge shows the new level.
- Without money the fill goes on your debt, like fuel delivery, so nobody is stranded.
- A fuller tank without a pump press (a reset or respawn) is still put back, as before. A pump press counts for
  20 seconds.
- The game shows its pumps outside its own career only with **Gas stations in freeroam** turned on in the game's
  options (BeamNG.Earth checks the same option). The phone's Refuel button at a known station still works as before.

Not tested in game yet: the wrapper on the real `freeroam_gasStations` and how soon the car reports the new level.
