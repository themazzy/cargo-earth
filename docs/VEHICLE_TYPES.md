# Vehicle types and their work

Cargo Earth sorts the vehicle you drive into one of five kinds (`cargoEarth/haul` `carrier`). Ordinary cars are
sorted by the "Body Style" BeamNG lists for every config; models known to be SUVs or pickups (D-Series, Roamer,
Hopper) count as such even without a style.

| Kind | Detected by | Food delivery mode | Freight mode |
| --- | --- | --- | --- |
| Car | any other road vehicle (Sedan, Hatchback, Wagon, Coupe...) | meals, groceries | short parcel rounds (2-4 stops, a few parcels), company contracts |
| SUV or pickup | Body Style SUV / Pickup / Crossover / Off-Road | meals, groceries | parts runs, company contracts |
| Van | the H-Series van | meals, groceries | parcel routes (4-7 stops), van freight, company contracts |
| Box truck | MD-Series, the mid truck, a T-Series without a fifth wheel | meals, groceries | business shipping between companies |
| Tractor | any truck with a fifth wheel | meals, groceries | trailer freight, fuel tanker runs, heavy tow jobs |

Any vehicle with a tow hitch also gets light tow jobs. Every load travels in BeamNG's own cargo containers.

## Tow jobs

A broken-down car at a real address goes on your trailer to a workshop 3-30 km away: your firm's headquarters, else a
real auto repair shop near the car (the helper's repair garages, one of the nearest three), else the workshop at a
fuel station where no shop is known. At the pickup the car stands by the road (ahead of you, else beside you, on
a spot clear of buildings and trees) with the trailer behind you; park the trailer next to it, stop and press Load
on the phone to put it on the deck.

The broken-down cars are wrecked by the game's own soft-body physics as they spawn (vehicle extension
`cargoEarth_wreck`): front-end crash, rear-ended, side impact, rolled over (one end or the roof pushed in for 0.3 s,
the rest of the car pushed back as hard so it stays put), stripped (every break group and the doors off) or flat tyres.
Some break groups come off and a tyre goes flat on every wreck. The look follows the address, so a breakdown always
looks the same, and it is done again if loading resets the car. The damage they come with does not cost pay.

## Parts runs

An SUV or a pickup loads car parts at a supplier within 15 km and brings them to a repair workshop 4-30 km away.
Suppliers are parts shops streamed by the helper (Overture places, worldwide) and the bundled depots that make car
parts (car plants, factories). Workshops are the helper's repair garages and dealers, your firm's headquarters, or,
when neither is near, the workshop at a fuel station. The parts go into the vehicle's parcel boxes:
4-20 slots, 5 kg each.

The helper's area cache is format 6: areas carry `autos` rows `[id, lat, lon, name, "p" | "g", town]`.

## Hired drivers

Every driver holds a car licence (cars, SUVs, vans); some also hold a truck licence (box trucks), and some of those an
articulated one (tractors). Each truck licence adds to the wage. A driver also knows one kind of vehicle best and
brings in 15 % more in it. A driver can only be hired for a vehicle their licence covers, and waits when the vehicle
is not fit for its work: a car, an SUV or a van without cargo boxes, a tractor without one of the firm's trailers.
Drivers hired before licences keep the licence for the vehicle they already drive.
