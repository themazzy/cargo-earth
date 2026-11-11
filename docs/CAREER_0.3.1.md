# Cargo Earth 0.3.1

This update reviews and fixes the first career build's persistence, geographic discovery, network usage and contract-generation performance. The [review and storage report](reviews/2026-11-11-code-and-storage-review.md) explains the findings and measurements.

## Install and use

Disable older Cargo Earth ZIPs or unpacked copies. Install `dist/cargo_earth_career_0.3.1.zip` in the active BeamNG profile's mods folder and restart the game. Update the companion helper to `dist/cargo_earth_helper_0.3.1.py`; keep its existing cache location to reuse valid downloaded data.

Open **Places > Home garage** to select an address and confirm a safe parked location. Use **Places > Company work** for company contracts and reputation-based independent work. The [0.3.0 gameplay guide](CAREER_0.3.0.md) describes those unchanged flows.

The update migrates supported career saves to schema 3, with the existing backup and original-save preservation mechanism. Schema 3 prevents older versions from loading the compact payment records incorrectly. Keep the previous save if you need to return to 0.3.0.

## Cache settings

The helper defaults to a **1 GiB soft budget** for geographic byte blocks and processed areas. Its default directory is `cache` beside the helper script; `--cache` or `BNE_CARGO_CACHE` selects another location. This is separate from the game profile's career save and from BeamNG.Earth's own terrain/imagery cache.

Example for a 4 GiB geographic cache:

```powershell
python cargo_earth_helper_0.3.1.py --cache-mb 4096
```

Use `--cache-mb 1024` for the default. Minimum supported setting: 64 MiB. The limit is checked at startup, after area builds and by background housekeeping, with scans at most every five minutes; active neighbourhood files and recently accessed working files are retained. Downloads in progress and the interval between checks can temporarily exceed it. Index metadata and temporary write files are outside the budget. Evicted public data can be downloaded again; home, vehicle, money, reputation and active contracts live in the separate career save.

## Verification

The update passes 25 career checks, 5 socket-client checks, 16 Python helper checks, the phone checks and the actual Czech depot-pack smoke test. The Lua checks run in a Lua 5.3 VM with game adapters isolated; BeamNG uses LuaJIT. Live Overture queries and a native BeamNG session remain unverified in this environment.

With Node dependencies installed, run `npm test`. Run `python -m unittest discover -s tests -p '*_test.py' -v` for helper checks and `node tests/benchmark.cjs` for geographic work counts. Build with `powershell -File tools/build.ps1`.
