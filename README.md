# Cargo Earth

A career layer for **BeamNG.drive on BeamNG.Earth**. Deliver food, haul freight, work company contracts and build a garage at an address you choose.

**Early development · mod 0.12.2 · helper 0.12.2**

[Download the mod and helper (latest release)](https://github.com/themazzy/cargo-earth/releases/latest) · [Landing page](website/index.html) · [Payout statistics](docs/research/payout-statistics-0.3.5/README.md)

## What you can do

Cargo Earth turns BeamNG.Earth's real-world maps into a working life. Real restaurants, addresses, depots, repair shops,
fuel stations, bus lines and speed cameras come from Overture Maps and OpenStreetMap, so the same game works in your
own town and anywhere else on Earth. Every action is available on the in-game phone; buses also support the normal door key (O).

### Four ways to work

Pick **Food delivery**, **Freight**, **Taxi** or **Bus** on the phone's offline screen (or in Settings).

**Food delivery**
- Deliver meals, family orders and grocery baskets from real restaurants and shops to real addresses. Fit real cargo
  boxes and take compatible orders together.
- Orders favour nearby customers in your own town, and pay by the real road distance, not a straight line.
- At most two orders in a row come from one place before others get a turn. The phone shows separate *Pick up in* and
  *Deliver in* targets.

**Taxi** (owned cars, SUVs and passenger vans with verified passenger seats)
- Pick up a group at a real nearby address and drive to an airport, station, museum, sight or hotel. Groups can fill all usable passenger seats, with seated dummies adding 75 kg each.
- The fare starts at 45 CZK plus 13 CZK/km, plus up to 45 % in a more valuable car. Each passenger after the first adds 20%; Rush then adds 25%. Fuel and reputation supplements follow their existing rules. The phone shows the breakdown before acceptance.
- Comfort passengers reward a smooth ride; Rush passengers reward speed. Time allowances include the pickup drive and use road distances where mapped, with labelled pickup estimates elsewhere. Existing accepted rides keep their agreed fares.

**Freight** (the work depends on what you drive, see [vehicle types](docs/VEHICLE_TYPES.md))
- **Car:** tow jobs with a tow hitch, or company contracts.
- **SUV or pickup:** parts runs from parts shops and car plants to repair workshops.
- **Van:** parcel routes from a depot to 4-7 addresses, emptying the cargo containers stop by stop; van freight.
- **Box truck:** business shipping between real companies.
- **Tractor:** trailer freight, fuel tanker runs that resupply real fuel stations, heavy tow jobs.
- **Anything with a tow hitch:** tow jobs. A wrecked car (crashed front, rear or side, rolled over, stripped or with
  flat tyres) waits by the road; park your trailer next to it and press **Load** on the phone. It goes to a real auto
  repair shop or your own headquarters. No trailer of your own? Borrow one at the repair shop first, or take your
  firm's own car trailer out at HQ. Small cars go on a light box utility trailer any car can pull.
- **Company contracts:** the phone lists the three nearest. Take one and the company lends you its van, box truck or
  tractor for the job; your own car waits for you. Independent contracts unlock at 20 reputation per employer.
- Special cargo: fragile, chilled and oversize loads pay more and need care.
- Loads have realistic weights (a van up to a tonne, a semi trailer up to 22 t), all in BeamNG's own cargo containers,
  and the phone shows the kg on board and dropped at each stop.

**Bus** (new)
- Choose a real city bus or trolleybus line, then park your own car inside its depot marker for two seconds.
  Your car is stored and replaced by a city bus. Open its doors at each stop using **O** or the phone; both displays
  show the same passenger timer. Each stop has its own timetable time, and harsh braking or bumps cost passenger comfort
  and pay. At the last stop, hand over the bus and return to your car. See [bus lines](docs/BUS_LINES.md).
- **Intercity coaches:** the Bus page's Coaches list offers rides from a bus station near you to bus stations in far
  towns, one way or with a return trip, in a lent highway coach.

### Career

- Start with a beat-up car and a little money, or pick **Free play** to just drive without a save.
- Buy used cars with real wear (each with the game's own picture and a Details card: power, torque, weight, top speed,
  0-100, drive, gearbox and fuel; filter by kind, see cargo space and the jobs each can do), trade in, and buy real BeamNG parts. Repairs cost money; repairing for free through the
  game's menu puts the bill on your debt, and Finances shows where every charge came from.
- Used cars can come with worn parts (misfiring engine, worn clutch and gearbox, brakes or tyres, overdue oil change).
  The listing shows them and the price is lower; fix them after buying.
- Insure your own cars: a weekly premium from the car's value, claims pay the repair minus 10 %, reckless crashes are
  covered half or refused, and a write-off gets a free tow home. See [insurance](docs/INSURANCE.md).
- Stuck or wrecked by a map bug? The phone's **Unstuck** button repairs the car in place for free (once every 5 min).
- The phone's **Map** tab shows a live heading-up street map (OpenStreetMap, through the helper) with the GPS route,
  your stops, turn directions, lanes and your speed against the limit. See [live map](docs/LIVE_MAP.md).
- Set a home garage where you park, grow it from a small to an extra large garage and build rooms (workshop, fuel tank, rest room) for bonuses at home. A home is never required.
- If a car you own came from a vehicle mod you have since removed, the career still loads: another of your cars (or a
  stand-in Pigeon) takes its place until the mod is back.
- Earn 1 to 5 stars on every order. They build two reputations, courier and freight, that bring premium work and better
  pay. Tips come for fast deliveries that arrive in perfect condition.
- Pay for fuel at real stations: fill up or only to 25 / 50 / 75 % from the phone at the pumps, or call a roadside
  delivery. Cars need servicing (oil, tyres, brakes) or they break down.
- Found your own firm: set its headquarters at a real yard, build parking bays, a workshop, a fuel tank and a dispatch
  office, buy trucks and trailers and hire drivers. Drivers have licences (car, truck, articulated), speed, care, a
  wage and a vehicle they know best.
- Get paid in the money of the country you drive in; crossing a border exchanges it for free.
- Speed cameras are temporarily paused: no camera downloads, camera fines or lost stars. The normal road speed-limit
  display still works.
- A delivery map with your personal records, and a full progress and finance overview.
- Keep several named careers (up to 20): load or delete one on the phone's start screen, start a new one with its own
  name, and switch from Menu → Settings → **Save and switch career**. A save from before 0.10.3 becomes **Career 1**.
  **Delete this career** in Settings deletes only the current one (type DELETE to confirm).

### The phone

- A small phone in the corner with **Work**, **Radio** and **Menu**. It folds away and stays folded through camera
  changes and the pause menu, and has a dark mode.
- **Menu** opens a big window with Garage, Home, Companies, Progress, Finances, Delivery map, Firm and Settings. It
  reopens on the page you left. Settings and Radio work before a saved career is loaded.
- **Radio:** real internet radio stations of the region you drive in, played through the helper.
- **Dash phone:** a phone holder on the dashboard of any car with the same app, side buttons for the main actions and a
  per-car position (behind the wheel or on the center console). Made for VR, also fine on a monitor. See [dash phone](docs/DASH_PHONE.md).
- When a new version is out, the phone says so with a link to the release.

**Settings → Jobs** has separate saved distance profiles for food, taxi, parts runs, parcel rounds, each tow class,
fuel resupply, and each vehicle class of own-vehicle freight and company contracts. Choose a profile without
switching your current work, enter distances directly, then press **Apply distances**. **Reset this job type**
restores only that profile. Accepted jobs keep their agreed route and quote.

| Job profile | Default pickup radius | Default shortest–longest | Editable longest distance |
| --- | ---: | ---: | ---: |
| Food and groceries | 3 km | 0.5–5 km | 8 km |
| Taxi | 1.5 km (up to 15 km) | 1.95–15.6 km | 15.6 km |
| Parts runs | 15 km | 5.2–39 km | 800 km |
| Parcel rounds | 20 km | 0.5–100 km (whole round) | 100 km |
| Tow jobs, either trailer class | 8 km | 3.9–39 km (loaded leg) | 800 km |
| Fuel resupply | 40 km | 15–150 km | 800 km |
| Own van / box truck / semi | 30 km | 3–45 / 12–125 / 20–250 km | 800 km |
| Company van / box truck / semi | 25 km | 1–20 / 12–40 / 20–60 km (per loaded leg) | 800 km |

Pickups use straight-line distance; freight and company delivery lengths are estimated as straight-line distance
× 1.3. Food lengths use straight-line distance, and its countryside option can widen the search. Taxi, parts and tow
use road distance where available. Bus lines retain their mapped stops and lengths. Parcel settings filter normal
rounds rather than adding more stops. Defaults and older saved settings are retained; company and own-vehicle
settings are independent.

**Long hauls.** When an own-vehicle freight or company contract profile reaches past 120 km, the game picks up to
8 real towns in that ring, spread by compass direction (a bundled Natural Earth list of towns over 30,000 people),
and the helper loads only their workplaces (warehouses, yards and stores; `/v1/sites`, cached on disk). They become
delivery points; pickups stay near you. Workplaces are not checked for truck access (none are bundled any more): within 600 m of one,
the phone offers **Load here** or **Hand over here** for 85 % of the pay (once a job) and no fee. Taxi, tow, parts, parcel and fuel jobs keep their
local data. Long hauls need the helper running.

Cargo Earth is separate from BeamNG's stock career mode. It is not affiliated with BeamNG, BeamNG.Earth or the RLS
Career Overhaul project.

## Install

You need **BeamNG.drive** (Windows or Linux) and **[BeamNG.Earth](https://github.com/TecnaGamer/BeamNG.Earth) 1.9.0-beta or newer** installed and working first (1.10 adds posted speed limits). Cargo Earth has two parts:

- **the mod** (a ZIP in BeamNG's `mods` folder): the career and the phone, in the game;
- **the helper** (a small Python program): it downloads restaurants, shops, workplaces, addresses, fuel stations, speed cameras, bus lines, repair shops and radio stations around you, and plays the radio. The game cannot go online itself, so the helper does it. BeamNG.Earth starts it for you.

### Quick install (Windows)

1. Download **[CargoEarthSetup.exe](https://github.com/themazzy/cargo-earth/releases/latest/download/CargoEarthSetup.exe)** and double-click it. Windows SmartScreen may say "Windows protected your PC" (the installer is not code-signed): click **More info**, then **Run anyway**.
2. Choose **1** (install or update). It downloads the latest release, puts the mod ZIP in your BeamNG `mods` folder (older Cargo Earth ZIPs are moved to `cargo_earth_old_mods`), copies the helper to `%LOCALAPPDATA%\CargoEarth\helper`, installs its Python libraries (duckdb, fsspec) and registers it with BeamNG.Earth. Career saves are never touched.
3. Continue with **[First start](#first-start)** below.

The other choices: 2 installs the mod only, 3 removes Cargo Earth, 4 deletes your career save to start over. The source is in [`installer/`](installer/) and the release file is built from it by a GitHub workflow.

Options, from a command prompt in the download folder (for example `CargoEarthSetup.exe -uninstall`):

| Option | What it does |
| --- | --- |
| `-user-folder "D:\BeamNG\user"` | Use this BeamNG user folder when it is not found automatically |
| `-version 0.12.2` | Install a specific release instead of the latest |
| `-mod-only`, `-helper-only` | Install only one part |
| `-skip-python` | Don't install the helper's Python libraries |
| `-zip <file>`, `-helper <file>` | Use files you already downloaded |
| `-uninstall` | Remove the mod, the helper and its BeamNG.Earth entry (saves are kept) |
| `-delete-save` | Delete every career save and its backups (asks you to type DELETE; add `-yes` to skip). Close the game first |
| `-dry-run` | Only show what would happen |

In the game you can delete one career from the phone: Menu → Settings → **Delete this career** (type DELETE to confirm), or ✕ next to it on the careers list. `-delete-save` deletes all careers.

### Quick install (Linux x86_64 / Steam Deck Desktop Mode)

1. Download **[CargoEarthSetup-linux-x86_64](https://github.com/themazzy/cargo-earth/releases/latest/download/CargoEarthSetup-linux-x86_64)** from a release that includes the Linux installer.
2. Open a terminal in the download folder and run:

   ```sh
   chmod +x CargoEarthSetup-linux-x86_64
   ./CargoEarthSetup-linux-x86_64
   ```

3. Choose **1** (install or update), then follow **First start** below. Run as your normal user, without `sudo`. Python 3.9+ with `venv` support is required (some distributions package this as `python3-venv`). The installer creates a private Python environment for the manual helper launcher and installs `duckdb` and `fsspec` there.

The installer uses the active profile remembered by BeamNG.Earth, or detects native, Flatpak and Snap BeamNG user folders. If several profiles exist, or you use Proton or a custom location, specify the active profile explicitly:

```sh
./CargoEarthSetup-linux-x86_64 -user-folder "/path/to/BeamNG/BeamNG.drive/current"
```

The same command-line options listed for Windows work on Linux. The helper is installed in `${XDG_DATA_HOME:-$HOME/.local/share}/CargoEarth/helper`; run `start_helper.sh` there to start it manually. Registration goes in `~/.cache/beamng-earth/addons/local.json`, matching BeamNG.Earth's Linux app directory. For helper radio playback, install `ffplay`, `mpv`, or `cvlc`. `-skip-python` skips environment and dependency installation; the manual helper launcher then uses your system Python, whose dependencies you must provide yourself.

### Manual install

1. Download `cargo_earth_career_<version>.zip` and `cargo_earth_helper_<version>.py` from the [latest release](https://github.com/themazzy/cargo-earth/releases/latest).
2. Close the game. Put the ZIP as it is (do not unpack it) in your BeamNG user folder's `mods` directory (for example `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`). Keep only one Cargo Earth version there.
3. Install Python 3 and the helper's libraries: `python -m pip install duckdb fsspec`.
4. Register the helper with BeamNG.Earth: copy [`helper/local.json.example`](helper/local.json.example) to `%LOCALAPPDATA%\beamng-earth\addons\local.json` (or add its entry to the file there) and set `"file"` to where you saved the helper. Or run it yourself before playing: `python cargo_earth_helper_<version>.py` (it listens on `127.0.0.1:47821`; keep the window open).
5. Continue with **First start** below.

Cargo Earth uses **47821** to coexist with EarthRadio on **47820**. Update both Cargo Earth and its helper, then restart BeamNG.Earth to close the old helper process. CargoEarthSetup synchronizes the launchers, Cargo Earth's configuration and BeamNG.Earth's saved add-on options, preserving other custom ports. Old `--port 47820` arguments and `helperPort: 47820` configurations migrate to 47821. For a custom port, keep the helper's `--port`, the add-on's Port option and `settings/cargoEarth/config.json`'s `helperPort` equal. See [EarthRadio compatibility](docs/EARTHRADIO_COMPATIBILITY.md) for the remaining antenna-reload check.

### First start

1. **Start BeamNG.Earth.** The installer sets the helper up there with **Start with BeamNG.Earth** on, so it runs whenever you play (you can turn that off on Earth's **Add-ons** page). After a manual install, the phone shows **Install and start** or **Start helper** when the helper isn't running; one press starts it through BeamNG.Earth and turns that switch on. The helper needs internet access.
2. **Load a BeamNG.Earth map** with the mod enabled (BeamNG's Mods menu shows **cargo_earth_career**).
3. **The phone:** the first time, the mod adds the **Cargo Earth: Phone** app to BeamNG.Earth's ".Earth" UI layout, above the speedometer. Move or resize it with the UI Apps editor (Escape → **UI Apps**). If you play with another layout, or removed the phone, add **Cargo Earth: Phone** there yourself and save the layout. Everything is done by clicking on the phone; the mod has no key bindings.
4. **Choose Career or Free play** on the phone, then choose Food delivery, Freight, Taxi or Bus from the **Work** dropdown.
5. Optional: turn **traffic on in BeamNG.Earth** for the speed-limit sign on the phone (it reads Earth's road graph).

If the phone says the helper is not running: press **Start helper** on the phone, check the Add-ons page (step 1), or run `start_helper.cmd` from `%LOCALAPPDATA%\CargoEarth\helper` on Windows or `start_helper.sh` from `${XDG_DATA_HOME:-$HOME/.local/share}/CargoEarth/helper` on Linux and keep its window open. The mod bundles no places: restaurants, customers, workplaces, fuel stations and everything else come from the helper, the same way in every country.

The phone keeps what you need while driving: **Work** (deliveries), **Radio**, and a fuel line at the bottom. **Menu** opens a big window over the game with **Garage**, **Home**, **Companies**, **Progress**, **Finances**, **Delivery map**, **Firm** and **Settings**. The firm's headquarters opens from Firm as a full-screen plan of the building.

Parts selected in BeamNG Vehicle Config are previews. Apply them, leave Vehicle Config, then confirm or discard checkout in Menu → Garage. Driving with unconfirmed changes restores the paid configuration.

## Saves and cache

Career progress is local JSON in `settings/cargoEarth/` in the active BeamNG profile: `career.json` for the first career, `career-2.json` and so on for the others, each with two recovery backups, and `saves.json` listing their names. It includes your selected home address/coordinates. Cargo Earth implements no cloud-save upload.

The helper's default 1 GiB soft cache budget covers replaceable downloaded source blocks and processed geographic areas. It does not include career saves, installed mod assets or BeamNG.Earth's own terrain/imagery cache. Increase it with `--cache-mb 4096` for 4 GiB; use `--cache` to choose a directory.

## Update notice

The game itself can't go online, so the helper checks this repository's latest GitHub release when it starts (unless it already asked in the last 10 minutes), each time you load a save (unless it asked in the last 5 minutes) and every 2 hours (one small request each time). So a new release shows on the phone a few seconds after you load your save. When a newer mod or helper is out, the phone shows **Cargo Earth x.y.z is out** with a **Get it** button that opens the release page; **Later** hides it until the next release. Settings → Help shows your mod and helper versions. Start the helper with `--no-update-check` to turn the check off. Without the helper running, the game can't learn about updates.

## Development

Source lives under `mod/cargo_earth/`; the helper lives under `helper/`. Runtime code is Lua, AngularJS and Python. No build step is needed to edit the mod itself.

```text
npm install
npm test
python -m unittest discover -s tests -p helper_test.py
python -m unittest discover -s tests -p cz_terrain_test.py
powershell -ExecutionPolicy Bypass -File tools/build.ps1
node tools/payout-stats.cjs
```

`earth-addons/cz-terrain/` is a separate BeamNG.Earth add-on: Czech DMR 5G lidar terrain in place of Mapterhorn's 5 m grid (see its README).

Both installers share the Go program in `installer/`. From that folder, build with `GOOS=windows GOARCH=amd64 go build -o CargoEarthSetup.exe .` or `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o CargoEarthSetup-linux-x86_64 .`. Run installer checks with `go test ./...` and `go vet ./...`.

To publish a release, create a GitHub release with a tag such as `v0.12.2` and attach the mod ZIP and `cargo_earth_helper_*.py`. The Windows and Linux installer workflows build `CargoEarthSetup.exe` and `CargoEarthSetup-linux-x86_64` from the release tag and attach them to that release. Both also support manual runs with a release tag (the tag must contain the installer source). Pull requests touching the installer run checks and upload installer artifacts without publishing release assets.

`npm test` uses Fengari to check Lua and isolated game adapters; it is not a substitute for in-game driving tests. See [0.12.2 notes](docs/CAREER_0.12.2.md), [0.12.1 notes](docs/CAREER_0.12.1.md), [0.12.0 notes](docs/CAREER_0.12.0.md), [0.11.0 notes](docs/CAREER_0.11.0.md), [0.10.4 notes](docs/CAREER_0.10.4.md), [0.10.3 notes](docs/CAREER_0.10.3.md), [0.10.2 notes](docs/CAREER_0.10.2.md), [0.10.1 notes](docs/CAREER_0.10.1.md), [0.10.0 notes](docs/CAREER_0.10.0.md), [0.9.1 notes](docs/CAREER_0.9.1.md), [0.9.0 notes](docs/CAREER_0.9.0.md), [0.8.7 notes](docs/CAREER_0.8.7.md), [0.8.6 notes](docs/CAREER_0.8.6.md), [0.8.0 notes](docs/CAREER_0.8.0.md), [0.7.0 notes](docs/CAREER_0.7.0.md), [0.6.0 notes](docs/CAREER_0.6.0.md), [0.5.0 notes](docs/CAREER_0.5.0.md), [0.4.0 notes](docs/CAREER_0.4.0.md), [0.3.5 notes](docs/CAREER_0.3.5.md), [code/storage review](docs/reviews/2026-11-11-code-and-storage-review.md) and the [statistics methodology](docs/research/payout-statistics-0.3.5/README.md).

## Current limits

This is an early development build, made by one person with a lot of help and tested in game as time allows. Bus lines, tow jobs (wrecks, coupling and loading), parts runs, vehicle-type detection, heavier loads and the BeamNG.Earth 1.10 speed limits are new in 0.10 and still need more driving; check the [release notes](docs/CAREER_0.10.3.md) for what is untested. Public places are candidate stops rather than certified loading bays, and a truck may not fit every yard a van does. Bulk and fluid loads have no condition yet. The payout report describes 0.3.5, before fuel costs.

The helper fetches public Overture source data; busy areas and first visits may take time to load. Python queries and connections are bounded, but real-world latency and coverage vary.

## Data attribution

The mod bundles no map places. Places the helper loads come from **Overture Maps Foundation** (and OpenStreetMap through it) and keep their source metadata. The freight catalogue (`data/freight.json`: cargo, trailers, workplace types) is gameplay rules, not data about real businesses. Country borders (`data/borders.json`, for the local currency) are simplified from **Natural Earth** 1:10m admin 0 countries, which is in the public domain. Long-haul towns (`data/cities.json`) are Natural Earth 1:10m populated places, also public domain. No BeamNG game assets or proprietary runtime are included here.

Report bugs through [GitHub Issues](https://github.com/themazzy/cargo-earth/issues), with mod/helper version, reproduction steps and the relevant error excerpt. Remove home coordinates and other personal data before sharing a save or log.

## Licence

Code: [MIT](LICENSE). The phone's OSM map shows OpenFreeMap tiles (© OpenFreeMap, © OpenMapTiles, © OpenStreetMap contributors), passed on by the helper. Bundled data: Natural Earth (public domain). Data the helper loads: Overture Maps Foundation and OpenStreetMap contributors under their licences (see [LICENSE](LICENSE)).
