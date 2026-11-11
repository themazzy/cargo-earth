# Cargo Earth career build 0.3.0

This build adds a player-selected home address, company contracts, company reputation, a money ledger, measured driving distance, pause-safe deadlines and recoverable saves. It builds on the existing courier and trucking career.

## Install

Build with `powershell -File tools/build.ps1`, or use `dist/cargo_earth_career_0.3.0.zip`.

Use BeamNG's launcher to open the user folder for the profile you play. Keep a copy of your existing `settings/cargoEarth` folder. Disable older Cargo Earth ZIPs and unpacked copies, then place the new ZIP in the profile's `mods` folder. Leave it zipped and restart BeamNG. Load BeamNG.Earth with its companion app running. Use the existing Cargo Earth phone HUD app.

This package does not include BeamNG.Earth or RLS. The updated helper is supplied separately as `dist/cargo_earth_helper_0.3.0.py`. Replace/run the helper version used by your companion setup when testing this build. Its new workplace discovery requires version 0.3.0; the phone identifies older helpers. Run it through BeamNG.Earth's companion setup, or with Python plus `duckdb` and `fsspec`, as for the existing helper. Existing bundled Czech locations continue to work without it.

The helper now pulls real nearby workplace candidates, restaurants, grocery stores and home addresses for the player's current location. Cached regions are rebuilt in format 3 while existing downloaded data blocks are retained. General parcel yards and recipients can generate van contracts outside Czechia, subject to available place data. Candidate locations are not certified loading bays; larger truck jobs continue to use the bundled/authored depot data. Accepted contracts snapshot their endpoints and survive discovery-cache eviction.

## Choose your home

1. Open **Places > Home garage** on the Cargo Earth phone.
2. Search nearby addresses, optionally filtering by street or town. The picker searches within 3 km of your vehicle.
3. Select an address and choose **Route to address**.
4. Drive there and stop in a safe parking spot within 100 metres of the selected stop point. Choose **Make this parking spot my home**.

The garage saves your chosen address and the actual spot where you parked. It has room for three owned vehicles; existing cars are preserved even if you already exceed that number. Once a home is set, return there to switch parked cars. Loaners do not use owned-vehicle capacity. Choosing a different address changes your home location without deleting vehicles.

This is a saved gameplay garage and parking point. It does not create a building interior or certify legal access to private real-world property.

## Take company work

1. Start your existing career from **Garage**, if you have not already.
2. Open **Places > Company work > Find company contracts**. The helper discovers workplaces around your current location; the Czech depot pack remains available offline. Leave the page open while nearby areas load: the board refreshes as data arrives.
3. Review estimated wages and duration. Route to the chosen yard and park within 60 metres to start.
4. Your personal car is saved and replaced by a company H-Series van with parcel boxes. Follow the two freight deliveries in **Orders**. Each includes real container loading and unloading.
5. Return to the company yard, park and choose **Collect wages and return my car** in Places.

You receive 65% of completed delivery revenue. The company retains 35% and covers company vehicle costs. Revenue is held during the shift; late-delivery reductions can lower the final amount. Existing personal debt receives its usual deduction at settlement. Completing a full contract raises that employer's reputation by ten points, up to 100.

At **20 reputation with an employer**, its board unlocks **Use my own van**. Bring an owned van with enough free parcel boxes to the yard. These independent contracts keep your vehicle in use and pay 100% of completed delivery revenue; you cover your own vehicle costs. Return to the yard to settle the contract. Loaner vehicles do not qualify.

**End company work early** asks for a second click. It pays the completed deliveries and returns your car with no cancellation fee; unfinished deliveries receive no pay. Use this when a procedural depot is inaccessible or equipment fails to load. Employers are fictional gameplay organizations placed at mapped depot locations, not real employment relationships.

## Saving and recovery

An unfinished contract, held revenue, personal-car snapshot and home location are saved with the career. Reload through the normal Cargo Earth resume screen. Company cargo is restored through the existing container bridge. Original crash deformation is not guaranteed to survive a vehicle respawn; the existing repair-cost tracking remains in place.

The save remains `settings/cargoEarth/career.json`. Writes use BeamNG's atomic JSON writer, a verified staging file and two previous checkpoints (`.backup1` and `.backup2`). The first successful migration preserves an old-format save as `.legacy`. Only committed files and backups are recovery candidates; `.pending` is not a committed save. Failed writes show a warning on the phone and retry. A save from a newer schema is blocked rather than reset.

Deadlines now count active, unpaused career time while Earth is ready. Display dates still use the computer's clock. Measured driving distance starts at zero for existing careers; completed route kilometres remain a separate statistic. Origin rebases do not add distance, and teleport jumps are excluded.

## Development checks

With Node.js installed: run `npm install`, then `npm test`. Alternatively point the environment variable `FENGARI_PATH` at an existing Fengari installation. The runner compiles the Lua modules and exercises career rules and the real core against isolated game/filesystem adapters, including streamed workplace discovery without a country pack. It also checks the phone template structure. Run `python -m unittest discover -s tests -p '*_test.py' -v` for the helper's offline classification and area-payload tests.

The test VM implements Lua 5.3; BeamNG uses LuaJIT. Adapter tests do not replace an in-game playtest or a live Overture download. Check workplace/address discovery in your area, actual van spawning and cargo loading, both deliveries, return settlement, an interrupted save/resume and a floating-origin crossing before treating this as a stable release. No files are installed into the game's user folder by the build script.
