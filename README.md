# Cargo Earth

A career layer for **BeamNG.drive on BeamNG.Earth**. Deliver food, haul freight, work company contracts and build a garage at an address you choose.

**Early development · mod 0.3.5 · helper 0.3.1**

[Download the mod and helper (latest release)](https://github.com/themazzy/cargo-earth/releases/latest) · [Landing page](website/index.html) · [Payout statistics](docs/research/payout-statistics-0.3.5/README.md)

## What you can do

- Deliver standard meals, larger family orders and grocery baskets. Fit real cargo boxes and combine compatible orders.
- Start company contracts at nearby yards, use a supplied cargo van and return for your wages. Independent contracts unlock at 20 reputation per employer.
- Progress from vans to rigid trucks and articulated freight with native cargo containers and loads.
- Choose a nearby address as your home garage, then drive there and park to claim it. Store and switch owned cars, buy used vehicles, repair and confirm real parts purchases.
- Track money, debt, deliveries, cargo condition, employer reputation and active driving distance through the phone.
- Discover nearby restaurants, stores, workplaces and addresses through the local helper. Bundled Czech geography provides fallback coverage.

Cargo Earth is separate from BeamNG's stock career mode. It is not affiliated with BeamNG or the RLS Career Overhaul project.

## Install

### Quick install (Windows)

With BeamNG.drive and BeamNG.Earth already installed, open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/themazzy/cargo-earth/main/install.ps1 | iex
```

It downloads the latest release, puts the mod ZIP in your BeamNG `mods` folder (older Cargo Earth ZIPs are moved to `cargo_earth_old_mods`), copies the helper to `%LOCALAPPDATA%\CargoEarth\helper`, installs its Python libraries and registers it with BeamNG.Earth. Career saves are never touched. Options, with a downloaded copy of [`install.ps1`](install.ps1):

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -UserFolder "D:\BeamNG\user"   # BeamNG user folder not found automatically
powershell -ExecutionPolicy Bypass -File install.ps1 -Version 0.3.5                    # a specific release
powershell -ExecutionPolicy Bypass -File install.ps1 -ModOnly                          # or -HelperOnly, -SkipPython
powershell -ExecutionPolicy Bypass -File install.ps1 -ZipPath dist\cargo_earth_career_0.3.5.zip -HelperPath helper\cargo_earth_helper.py
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall                        # add -DryRun to any command to only show what it would do
```

### Manual install

1. Install and set up BeamNG.drive and BeamNG.Earth separately.
2. Download `cargo_earth_career_0.3.5.zip` from the [latest release](https://github.com/themazzy/cargo-earth/releases/latest). Close the game. Put the ZIP in your active BeamNG user-folder `mods` directory. Keep only one Cargo Earth version enabled; do not unpack the ZIP for normal installation.
3. For live geography, install Python 3 and the helper dependencies: `python -m pip install duckdb fsspec`.
4. Run `python cargo_earth_helper_0.3.1.py` (also attached to the release), or add it to BeamNG.Earth as a companion add-on with [`helper/local.json.example`](helper/local.json.example) in `%LOCALAPPDATA%\beamng-earth\addons\local.json`. It listens locally on `127.0.0.1:47820`. Keep it running while playing. The helper also needs internet access to fetch public geographic data.
5. Load BeamNG.Earth, add the **Cargo Earth: Phone** UI app, then start or resume your career in the phone.

Phone sections: **Work**, **Garage**, **Home**, **Career**, **Settings**. Work separates Deliveries and Companies; Career separates Progress and Finances.

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

`npm test` uses Fengari to check Lua and isolated game adapters; it is not a substitute for in-game driving tests. See [0.3.5 notes](docs/CAREER_0.3.5.md), [code/storage review](docs/reviews/2026-11-11-code-and-storage-review.md) and the [statistics methodology](docs/research/payout-statistics-0.3.5/README.md).

## Current limits

This is an early development build. Native crash/accelerometer behaviour, phone layout and full driving sessions need further verification. Public POIs are candidate stops rather than certified loading bays. Rigid/articulated site access is more restricted than van access. Parcel cargo has condition penalties; bulk/fluid condition is not yet modeled. Company contracts currently offer weak hourly pay because of return travel; the payout report documents that imbalance.

The helper fetches public Overture source data; busy areas and first visits may take time to load. Python queries and connections are bounded, but real-world latency and coverage vary.

## Data attribution

Bundled Czech geography credits **OpenStreetMap contributors** and **Overture Maps Foundation**; the pack declares **ODbL-1.0**. Preserve the pack's attribution and licence metadata when redistributing the data. Live helper data retains its source metadata. No BeamNG game assets or proprietary runtime are included here.

Report bugs through [GitHub Issues](https://github.com/themazzy/cargo-earth/issues), with mod/helper version, reproduction steps and the relevant error excerpt. Remove home coordinates and other personal data before sharing a save or log.

## Licence

Code: [MIT](LICENSE). Bundled geographic data: ODbL 1.0, © OpenStreetMap contributors and Overture Maps Foundation (see [LICENSE](LICENSE)).
