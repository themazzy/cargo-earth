# Cargo Earth 0.4.0

Content update: customer ratings and two reputations, fuel and running costs, your own firm with a headquarters, a delivery map and real speed cameras. Helper 0.4.0, save schema 4.

Exit BeamNG, replace the old ZIP with `cargo_earth_career_0.4.0.zip` in the mods folder and update the helper to `cargo_earth_helper_0.4.0.py` (the installer does both). Existing careers load and are upgraded on the first save; the 0.3 save is kept beside it as `career.json.legacy`. A career saved by 0.4 no longer opens in 0.3.

Nothing in this update depends on the in-game weather or time of day, because BeamNG.Earth lets a player set both by hand.

## Ratings and two reputations

Every finished, ruined or cancelled order leaves 1 to 5 stars. A delivery starts at 5 and loses one star per 20 % of the time limit it runs over (at most 3), one per 20 % of cargo damage (at most 3) and one for a speed camera fine on the way. A ruined order is 1 star; cancelling is 2 before the pickup and 1 with the cargo on board. The receipt shows the stars and a short customer line.

The stars feed one of two reputations (`rating.lua`):

| | Courier | Freight |
|---|---|---|
| Fed by | food orders | van, truck and company jobs |
| Averaged over | last 50 ratings | last 30 ratings |
| Reward | from 4.7 after 10 ratings: about one order in four is a **premium** order (pay × 1.4, time × 0.85) | from 4.7 after 5 ratings: **preferred carrier**, freight pays 8 % more |
| Penalty | below 4.0 orders ring 1.4 × less often, below 3.5 1.8 × | below 3.5 freight pays 10 % less |

A new career shows 4.5 until the first rating. Per-employer reputation for company contracts is unchanged.

## Fuel and running costs

The career car's real tanks and batteries are read from the vehicle and remembered per car, so a reset or respawn no longer refills it: the remembered level is put back (`fuel.lua`, vehicle extension `cargoEarth_fuel`).

- **Prices:** petrol 38 CZK/l, diesel 36 CZK/l, electricity 9 CZK/kWh. Each station is 6 % cheaper to 6 % dearer, always the same for that station.
- **Stations** are real ones: fuel stations and chargers from Overture Maps. Czechia is bundled (2,774 stations, 694 of them chargers); everywhere else the helper streams them with each area.
- **Garage → Fuel** shows the gauge, range, consumption per 100 km, cost per km, the nearest station with its price, **Fill up** when parked within 60 m of it, and **Route to this station**.
- **Fuel delivery** works anywhere: 10 units at 1.6 × the price plus a 150 CZK call-out. It can go on your debt, so an empty tank never ends a career.
- The starter car begins half full; a used car comes with whatever the last owner left. Loaners and company vans fill up free on the company fuel card.
- If the game does not take a refill within 6 seconds the money is returned, and a vehicle whose tank cannot be set is left alone.

To keep work worth doing with fuel to pay for, courier pay per km rises from 14 to 16 CZK, and freight offers add a fuel allowance when you drive your own vehicle: 3 CZK/km for a van, 8 for a rigid truck, 12 for an articulated one.

## Your own firm

**Career → Firm.** Founding a firm needs the Professional rank (30 deliveries), a reputation of 4.0 or better on either track after 5 ratings, no debt and a 6,000 CZK fee.

- **Headquarters:** drive to a yard or warehouse you like, or to your home garage, park and set it. The first choice is free; moving later costs 1,500 CZK.
- **Drivers are hired by the firm.** Hiring now needs a firm with a headquarters instead of only the rank. Drivers hired in 0.3 keep working.
- **Upgrades** (`firm.lua`):

| Upgrade | Levels and cost | Effect |
|---|---|---|
| Parking bays | 4,000 / 9,000 / 18,000 CZK | room for 2 / 4 / 6 more vehicles on top of the home garage's 3 |
| Workshop | 5,000 / 12,000 | repairs at the headquarters cost 15 % / 30 % less |
| Fuel tank | 7,000 | petrol and diesel at the headquarters for 15 % less |
| Dispatch office | 6,000 / 14,000 | hired drivers bring in 15 % / 30 % more |

- **Open headquarters** shows a full-screen plan of the building, separate from the phone: the office with your drivers, the workshop, the parts storage, the fuel tank and the yard with every parking bay, its car and its driver. Everything there is clicked: build and extend, repair, fill up, drive another car, hire and release drivers, rename the firm, move the headquarters.
- Cars can be switched at the headquarters as well as at home.

## Delivery map and records

**Career → Map** draws your last 200 drop-off points (courier and freight in different colours) with your home and headquarters, and lists personal records: longest delivery, best pay, best tip, best day, quickest delivery and longest streak of 5-star orders. A new record is named on the receipt.

## Parcel routes

Van and box-truck drivers are also offered parcel routes from the nearest depots: 4-7 stops (van) or 5-8 stops
(box truck) at real addresses within 5 or 8 km, at least 150 m apart, visited nearest-first. The whole load goes into
the vehicle's own BeamNG cargo containers at the depot, and each stop takes its share out of those containers. Pay is
a base plus a sum per stop and per road kilometre, paid once at the last address; the phone lists the stops with what
is still on board. Parcels that do not fit the vehicle stay at the depot.

All cargo now rides in BeamNG's native containers. The courier starter car is fitted with the cheapest parcel box its
slots accept; the invisible starter bag is only a fallback for a car that cannot take a box.

## Speed cameras

Real speed cameras from OpenStreetMap, anywhere in the world. The helper asks the Overpass API for the cameras around you (one small request per 0.5° cell, kept for 30 days) and the limit that applies: the camera's own, its enforcement relation's, or the nearest road's. Limits in mph are converted.

- The phone names a camera ahead from 400 m with its limit, and a pole with the limit stands at the camera.
- Passing within 30 m more than 6 km/h over the limit is measured (the highest speed inside the circle counts). Fines: 200 CZK up to 10 km/h over, 500 up to 20, 1,500 up to 40, 3,000 beyond. What the wallet cannot cover is added to your debt. Every order on board loses one star.
- Where OpenStreetMap has no limit, the mod assumes one no country's default exceeds for that road class (130 motorway, 110 trunk, 100 other main roads, 60 residential), so nobody is fined for a limit the game cannot know. A camera on a road of unknown class is ignored.
- Cameras need the helper 0.4.0 running, also in Czechia. **Settings → Speed cameras** switches them off.

## Speed limit on the phone

The phone shows the speed limit of the road under the car as a round sign, red when you drive more than 3 km/h over
it. The limit comes from the road graph BeamNG.Earth gives the game for its traffic: Overture's mapped limits, else
Earth's default for the country and road type, the same limits Earth's own road signs show. Earth slows its traffic
in sharp bends, so the mod reads 250 m of road each way and keeps the limit found on both sides. Where the limit is a
whole number of mph (the US, the UK) the sign shows mph. No sign off the road, or with Earth's traffic switched off
(the graph exists only then). A speed camera with no limit in OpenStreetMap takes its road's limit from the same graph
once it is within reach, instead of the generous road-class default.

## Helper 0.4.0

- Areas now carry fuel stations and chargers (`"fuel"` rows; area cache format 4, so areas are rebuilt once).
- New `/v1/cameras?lat=..&lon=..`.
- Speed camera data © OpenStreetMap contributors, ODbL.

## Verification

`npm test` (64 career tests, 6 helper-client tests, the phone test) and the helper's 19 Python tests pass. The phone and the headquarters screen were rendered in a browser with fixture data.

**Not yet verified in the game**, and the first things to check:

1. Fuel: that the gauge reads, a fill-up reaches the real tank, and a reset puts the remembered level back. The vehicle-side tank calls are written against BeamNG's `energyStorage` and guarded, but have not run in BeamNG.
2. The headquarters screen covering the whole screen and taking clicks inside the game UI, and typing the firm's name.
3. Speed cameras against the live Overpass API, and the camera pole's position beside the road.
4. Premium orders, the fuel allowance and the upgrade prices as a matter of balance.
