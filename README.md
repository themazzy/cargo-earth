# Cargo Earth

A career layer for **BeamNG.drive on BeamNG.Earth**. Deliver food, haul freight, work company contracts and build a garage at an address you choose.

**Early development · mod 0.8.0 · helper 0.8.0**

[Download the mod and helper (latest release)](https://github.com/themazzy/cargo-earth/releases/latest) · [Landing page](website/index.html) · [Payout statistics](docs/research/payout-statistics-0.3.5/README.md)

## What you can do

- Deliver standard meals, larger family orders and grocery baskets. Fit real cargo boxes and combine compatible orders.
- Start company contracts at nearby yards, use a supplied cargo van and return for your wages. Independent contracts unlock at 20 reputation per employer.
- Progress from vans to rigid trucks and articulated freight with native cargo containers and loads.
- Drive parcel routes: load a van or box truck at a depot and drop parcels at several real addresses, emptying its cargo containers stop by stop.
- Choose a nearby address as your home garage, then drive there and park to claim it. Store and switch owned cars, buy used vehicles, repair and confirm real parts purchases.
- In VR, a phone screen sits on the centre of the dashboard with your order, distance, time left and speed limit; move or resize it per car in Settings.
- Track money, debt, deliveries, cargo condition, employer reputation and active driving distance through the phone.
- Earn 1 to 5 stars on every order. They build two reputations, courier and freight, that bring premium orders and better freight pay.
- Pay for fuel at real stations and chargers. The car keeps its fuel level through resets, and a roadside delivery is always available.
- Found your own firm, set its headquarters at a real yard, and build parking bays, a workshop, a fuel tank and a dispatch office. The firm hires your drivers.
- See where you have delivered on a map with your personal records.
- Mind real speed cameras from OpenStreetMap: a fine and a lost star for passing one too fast.
- See the speed limit of the road you drive on, the same one BeamNG.Earth's signs and traffic use.
- Buy new trucks and trailers for your firm, hire drivers with their own speed, care and wage, and keep every vehicle serviced or risk a breakdown.
- Earn tips for fast deliveries that arrive in perfect condition.
- Special cargo: fragile, chilled and oversize loads that pay more and need care.
- Tow broken-down cars to a workshop on a car trailer or a flatbed.
- Tanker runs that resupply real fuel stations.
- Get paid in the money of the country you drive in. Crossing a border exchanges it for free.
- Discover nearby restaurants, stores, workplaces and addresses through the local helper. Bundled Czech geography provides fallback coverage.

Cargo Earth is separate from BeamNG's stock career mode. It is not affiliated with BeamNG or the RLS Career Overhaul project.

## Install

You need **BeamNG.drive** (Windows) and **[BeamNG.Earth](https://github.com/TecnaGamer/BeamNG.Earth)** installed and working first. Cargo Earth has two parts:

- **the mod** (a ZIP in BeamNG's `mods` folder): the career and the phone, in the game;
- **the helper** (a small Python program): it downloads restaurants, shops, workplaces, addresses, fuel stations, speed cameras and radio stations around you, and plays the radio. The game cannot go online itself, so the helper does it. BeamNG.Earth starts it for you.

### Quick install (Windows)

1. Download **[CargoEarthSetup.exe](https://github.com/themazzy/cargo-earth/releases/latest/download/CargoEarthSetup.exe)** and double-click it. Windows SmartScreen may say "Windows protected your PC" (the installer is not code-signed): click **More info**, then **Run anyway**.
2. Choose **1** (install or update). It downloads the latest release, puts the mod ZIP in your BeamNG `mods` folder (older Cargo Earth ZIPs are moved to `cargo_earth_old_mods`), copies the helper to `%LOCALAPPDATA%\CargoEarth\helper`, installs its Python libraries (duckdb, fsspec) and registers it with BeamNG.Earth. Career saves are never touched.
3. Continue with **[First start](#first-start)** below.

The other choices: 2 installs the mod only, 3 removes Cargo Earth, 4 deletes your career save to start over. The source is in [`installer/`](installer/) and the release file is built from it by a GitHub workflow.

Options, from a command prompt in the download folder (for example `CargoEarthSetup.exe -uninstall`):

| Option | What it does |
| --- | --- |
| `-user-folder "D:\BeamNG\user"` | Use this BeamNG user folder when it is not found automatically |
| `-version 0.8.0` | Install a specific release instead of the latest |
| `-mod-only`, `-helper-only` | Install only one part |
| `-skip-python` | Don't install the helper's Python libraries |
| `-zip <file>`, `-helper <file>` | Use files you already downloaded |
| `-uninstall` | Remove the mod, the helper and its BeamNG.Earth entry (saves are kept) |
| `-delete-save` | Delete the career save and its backups (asks you to type DELETE; add `-yes` to skip). Close the game first |
| `-dry-run` | Only show what would happen |

### Manual install

1. Download `cargo_earth_career_<version>.zip` and `cargo_earth_helper_<version>.py` from the [latest release](https://github.com/themazzy/cargo-earth/releases/latest).
2. Close the game. Put the ZIP as it is (do not unpack it) in your BeamNG user folder's `mods` directory (for example `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`). Keep only one Cargo Earth version there.
3. Install Python 3 and the helper's libraries: `python -m pip install duckdb fsspec`.
4. Register the helper with BeamNG.Earth: copy [`helper/local.json.example`](helper/local.json.example) to `%LOCALAPPDATA%\beamng-earth\addons\local.json` (or add its entry to the file there) and set `"file"` to where you saved the helper. Or run it yourself before playing: `python cargo_earth_helper_<version>.py` (it listens on `127.0.0.1:47820`; keep the window open).
5. Continue with **First start** below.

### First start

1. **Start BeamNG.Earth** and open its **Add-ons** page. Allow **Cargo Earth helper** the first time it asks, and turn on **Start with BeamNG.Earth** so it runs whenever you play. The helper needs internet access.
2. **Load a BeamNG.Earth map** with the mod enabled (BeamNG's Mods menu shows **cargo_earth_career**).
3. **The phone:** the first time, the mod adds the **Cargo Earth: Phone** app to BeamNG.Earth's ".Earth" UI layout, above the speedometer. Move or resize it with the UI Apps editor (Escape → **UI Apps**). If you play with another layout, or removed the phone, add **Cargo Earth: Phone** there yourself and save the layout. Everything is done by clicking on the phone; the mod has no key bindings.
4. **Start your career** on the phone (**Menu → Garage**) and go online for orders on **Work**.
5. Optional: turn **traffic on in BeamNG.Earth** for the speed-limit sign on the phone (it reads Earth's road graph).

If the phone says the helper is not running: check the Add-ons page (step 1), or run `start_helper.cmd` from `%LOCALAPPDATA%\CargoEarth\helper` and keep its window open. In Czechia the bundled data works without the helper, but the radio, speed cameras and grocery runs still need it.

The phone keeps what you need while driving: **Work** (deliveries), **Radio**, and a fuel line at the bottom. **Menu** opens a big window over the game with **Garage**, **Home**, **Companies**, **Progress**, **Finances**, **Delivery map**, **Firm** and **Settings**. The firm's headquarters opens from Firm as a full-screen plan of the building.

Parts selected in BeamNG Vehicle Config are previews. Apply them, leave Vehicle Config, then confirm or discard checkout in Menu → Garage. Driving with unconfirmed changes restores the paid configuration.

## Saves and cache

Career progress is local JSON at `settings/cargoEarth/career.json` in the active BeamNG profile, with two recovery backups. It includes your selected home address/coordinates. Cargo Earth implements no cloud-save upload.

The helper's default 1 GiB soft cache budget covers replaceable downloaded source blocks and processed geographic areas. It does not include career saves, installed mod assets or BeamNG.Earth's own terrain/imagery cache. Increase it with `--cache-mb 4096` for 4 GiB; use `--cache` to choose a directory.

## Update notice

The game itself can't go online, so the helper checks this repository's latest GitHub release when it starts and then every 6 hours (one small request; the answer is kept in its cache folder). When a newer mod or helper is out, the phone shows **Cargo Earth x.y.z is out** with a **Get it** button that opens the release page; **Later** hides it until the next release. Settings → Help shows your mod and helper versions. Start the helper with `--no-update-check` to turn the check off. Without the helper running, the game can't learn about updates.

## Development

Source lives under `mod/cargo_earth/`; the helper lives under `helper/`. Runtime code is Lua, AngularJS and Python. No build step is needed to edit the mod itself.

```text
npm install
npm test
python -m unittest discover -s tests -p helper_test.py
powershell -ExecutionPolicy Bypass -File tools/build.ps1
node tools/payout-stats.cjs
```

The Windows installer is a small Go program in `installer/` (`cd installer && GOOS=windows go build -o CargoEarthSetup.exe .`).

To publish a release, create a GitHub release with a tag such as `v0.8.0` and attach the mod ZIP and `cargo_earth_helper_*.py`. A workflow then builds `CargoEarthSetup.exe` and adds it to the same release.

`npm test` uses Fengari to check Lua and isolated game adapters; it is not a substitute for in-game driving tests. See [0.8.0 notes](docs/CAREER_0.8.0.md), [0.7.0 notes](docs/CAREER_0.7.0.md), [0.6.0 notes](docs/CAREER_0.6.0.md), [0.5.0 notes](docs/CAREER_0.5.0.md), [0.4.0 notes](docs/CAREER_0.4.0.md), [0.3.5 notes](docs/CAREER_0.3.5.md), [code/storage review](docs/reviews/2026-11-11-code-and-storage-review.md) and the [statistics methodology](docs/research/payout-statistics-0.3.5/README.md).

## Current limits

This is an early development build. Fuel, the headquarters screen and speed cameras (0.4), the firm's trucks, drivers and upkeep (0.5), special cargo, tow jobs and fuel resupply (0.6), local money (0.7), and the regional radio and VR dashboard screen (0.8) still need in-game verification; the payout report describes 0.3.5, before fuel costs. Native crash/accelerometer behaviour, phone layout and full driving sessions need further verification. Public POIs are candidate stops rather than certified loading bays. Rigid/articulated site access is more restricted than van access. Parcel cargo has condition penalties; bulk/fluid condition is not yet modeled. Company contracts pay for the return trip from 0.3.5; the payout report shows the hourly pay of each kind of work.

The helper fetches public Overture source data; busy areas and first visits may take time to load. Python queries and connections are bounded, but real-world latency and coverage vary.

## Data attribution

Bundled Czech geography credits **OpenStreetMap contributors** and **Overture Maps Foundation**; the pack declares **ODbL-1.0**. Preserve the pack's attribution and licence metadata when redistributing the data. Live helper data retains its source metadata. Country borders (`data/borders.json`, for the local currency) are simplified from **Natural Earth** 1:10m admin 0 countries, which is in the public domain. No BeamNG game assets or proprietary runtime are included here.

Report bugs through [GitHub Issues](https://github.com/themazzy/cargo-earth/issues), with mod/helper version, reproduction steps and the relevant error excerpt. Remove home coordinates and other personal data before sharing a save or log.

## Licence

Code: [MIT](LICENSE). Bundled geographic data: ODbL 1.0, © OpenStreetMap contributors and Overture Maps Foundation (see [LICENSE](LICENSE)).
