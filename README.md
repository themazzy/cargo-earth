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
- Earn tips for fast deliveries and a smooth ride.
- Special cargo: fragile, chilled and oversize loads that pay more and need care.
- Tow broken-down cars to a workshop on a car trailer or a flatbed.
- Tanker runs that resupply real fuel stations.
- Get paid in the money of the country you drive in. Crossing a border exchanges it for free.
- Discover nearby restaurants, stores, workplaces and addresses through the local helper. Bundled Czech geography provides fallback coverage.

Cargo Earth is separate from BeamNG's stock career mode. It is not affiliated with BeamNG or the RLS Career Overhaul project.

## Install

### Quick install (Windows)

With BeamNG.drive and BeamNG.Earth already installed, download **[CargoEarthSetup.exe](https://github.com/themazzy/cargo-earth/releases/latest/download/CargoEarthSetup.exe)** and double-click it. Choose 1 to install or update, 2 for the mod only, 3 to remove Cargo Earth, or 4 to delete your career save and start over.

It downloads the latest release, puts the mod ZIP in your BeamNG `mods` folder (older Cargo Earth ZIPs are moved to `cargo_earth_old_mods`), copies the helper to `%LOCALAPPDATA%\CargoEarth\helper`, installs its Python libraries and registers it with BeamNG.Earth. Career saves are never touched.

**The phone in the game:** the first time you load a BeamNG.Earth map with Cargo Earth, the mod adds the **Cargo Earth: Phone** app to BeamNG.Earth's ".Earth" UI layout, above the speedometer. Move or resize it with the UI Apps editor (Escape → **UI Apps**). If you use another layout, or removed the phone, add **Cargo Earth: Phone** there yourself and save the layout.

The installer is not code-signed, so Windows SmartScreen may say "Windows protected your PC". Click **More info**, then **Run anyway**. The source is in [`installer/`](installer/) and the release file is built from it by a GitHub workflow.

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

1. Install and set up BeamNG.drive and BeamNG.Earth separately.
2. Download `cargo_earth_career_0.8.0.zip` from the [latest release](https://github.com/themazzy/cargo-earth/releases/latest). Close the game. Put the ZIP in your active BeamNG user-folder `mods` directory. Keep only one Cargo Earth version enabled; do not unpack the ZIP for normal installation.
3. For live geography, install Python 3 and the helper dependencies: `python -m pip install duckdb fsspec`.
4. Run `python cargo_earth_helper_0.8.0.py` (also attached to the release), or add it to BeamNG.Earth as a companion add-on with [`helper/local.json.example`](helper/local.json.example) in `%LOCALAPPDATA%\beamng-earth\addons\local.json`. It listens locally on `127.0.0.1:47820`. Keep it running while playing. The helper also needs internet access to fetch public geographic data.
5. Load a BeamNG.Earth map. The first time, the mod adds the **Cargo Earth: Phone** app to the ".Earth" UI layout above the speedometer; in any other layout add it yourself (Escape → **UI Apps**) and save the layout. Then start or resume your career in the phone.

Phone sections: **Work**, **Garage**, **Home**, **Career**, **Settings**. Work separates Deliveries and Companies; Career separates Progress, Finances, Map and Firm. The firm's headquarters opens as a full-screen plan of the building.

Parts selected in BeamNG Vehicle Config are previews. Apply them, leave Vehicle Config, then confirm or discard checkout in the phone Garage. Driving with unconfirmed changes restores the paid configuration.

## Saves and cache

Career progress is local JSON at `settings/cargoEarth/career.json` in the active BeamNG profile, with two recovery backups. It includes your selected home address/coordinates. Cargo Earth implements no cloud-save upload.

The helper's default 1 GiB soft cache budget covers replaceable downloaded source blocks and processed geographic areas. It does not include career saves, installed mod assets or BeamNG.Earth's own terrain/imagery cache. Increase it with `--cache-mb 4096` for 4 GiB; use `--cache` to choose a directory.

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
