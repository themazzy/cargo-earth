# Cargo Earth 0.11.0

Intercity coach rides, vehicle insurance, a live map on the phone, home garages that grow with rooms and bonuses, used
cars with worn parts, a free Unstuck button, cheaper unlocks and repairs, and the phone now says why no work comes.

**Update both the mod and the helper.** Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux)
and choose 1, or replace the mod with `cargo_earth_career_0.11.0.zip` and the helper with `cargo_earth_helper_0.11.0.py`.
Close BeamNG and the helper first. Keep only one Cargo Earth ZIP installed. Saves are kept. Requires BeamNG.Earth
1.9.0-beta or newer (the live map's GPS route needs Earth's modding API 1.6; older versions show a straight line).

## Intercity coaches
- The Bus page has a **Coaches** list: rides from the bus station near you to bus stations in far towns (towns of
  30,000 people or more, anywhere on Earth; the helper finds the stations).
- The company lends you a Wentward bus in its Highway configuration. Seated passengers board at the start.
- Each ride is **One way**, or a **Return trip** that picks up new passengers at the far station and ends where it
  started. The card shows both with their own figures.
- Pay follows the timetable minutes plus fares per km: about 620-650 CZK an hour.
- New job type in Settings → Jobs: **Intercity coaches**.

## Vehicle insurance
- Garage → Insurance → **Insure** covers your own car at once (standing still, with no job or orders). Hired drivers'
  cars and company vehicles are insured by someone else.
- The premium starts at 3 % of the car's value per insurance week (21 hours of play), billed by the hour, also while
  the car is parked.
- A claim pays the real repair bill minus a 10 % deductible. Each claim adds 0.5 % to the rate for 3 hours; claim-free
  weeks bring the base rate down.
- Crashes well over the speed limit are covered half (more than 15 km/h over) or refused (more than 40 km/h over). A
  crash right after a speed camera flashed you is covered half. Wear, servicing and faults the car came with are not
  covered.
- A write-off (repair reaches half the car's value) opens a window: free tow home or to your HQ, repair on the spot, or
  stay here.
- The phone footer shows when the car you drive is insured. Details: [insurance](INSURANCE.md).

## Live map on the phone
- The new **Map** tab is a heading-up sat-nav sketch drawn from the game's road graph: Earth's GPS route, the next
  stop, the other orders' stops, a parcel route's stops ahead, Home and your firm's workshop.
- It draws the GPS route without a job too (home, workshop, company yard), hides the part behind you and says when you
  are off the line.
- Three zoom steps, remembered per phone. Click-only, so it works on the dash phone. Details: [live map](LIVE_MAP.md).

## Home garage
- **Set home here**: park the career car on Menu → Home garage and press one button. The home is named from the nearest
  address. Moving an existing home asks for a second press.
- Four steps: Small garage (3 cars, 1 room), Medium (4 cars, 2 rooms, 2,500 CZK), Large (6 cars, 3 rooms, 6,000) and
  Extra large (8 cars, 4 rooms, 12,000).
- Rooms: **Workshop** (1,500; repairs and servicing at home 30 % cheaper), **Fuel tank** (1,000; fill up or charge at
  home 20 % cheaper), **Rest room** (500; park at home for 3 minutes to be Rested: +10 % pay for an hour of play).
- A full-screen home view opens from Menu → Home garage → Open home. A home is never required, and switching cars no
  longer needs the home or the headquarters.

## Used cars
- Listings can come with a misfiring engine, a worn clutch and gearbox, worn brakes, worn tyres or an overdue oil
  change. They show on the listing and on the test drive, lower the price by most of their repair, and need fixing
  after buying.
- Cars never sell for more than they cost: a trade-in is capped at 85 % of what you paid plus the parts you bought.
  Parts taken off and spares fitted from your inventory count at their real value.

## Unstuck
- Earth's roads have bugs (bridge ends held at ground, steps between tiles). The phone header's **Unstuck** button
  repairs the car you drive in place for free and drops the repairs owed. Standing still, once every 5 minutes; a
  damaged load stays damaged.
- In a company vehicle the waived damage no longer costs the contract's reputation, and bus passengers get back the
  comfort the crash cost them.

## Cheaper unlocks and repairs
- Work vehicles, firm vehicles, truck trailers, founding the firm and firm upgrades cost about a quarter less (the firm
  is now 4,500). Pay is unchanged. Existing used-car listings are repriced once.
- Repairs are about 40 % cheaper, and so are hired drivers' incidents. Repairs already owed keep their price.

## Why no work comes
- The waiting screen says in one line why no orders or freight come: helper not running, crashed, timed out or
  answering with an error, still loading, nothing in reach, your distance settings, or a vehicle that can't take the
  work. The game log gets a matching line with the vehicle's details.
- After loading a save, a load the restored car brought back with no order on board is emptied, so freight fits again.
  The offline screen names the vehicle you drive instead of the unlocked freight stage.

## Bus lines
- Lines can have up to 80 stops (was 40).
- Line number badges are readable: the line's text colour, or black or white by contrast.
- The bus search asks four Overpass servers, two at once, and retries sooner while loading.

## Other fixes
- Doors, hood and tailgate are latched again after a saved car state is restored.
- Radio on Linux: the helper says which player it uses and why it went silent.
