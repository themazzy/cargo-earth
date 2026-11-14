# CZ lidar terrain (BeamNG.Earth add-on)

Czech **DMR 5G** lidar terrain (ČÚZK, 2 m) for BeamNG.Earth, instead of the 5 m DMR 4G grid that Mapterhorn
serves for Czechia. Road cuttings, embankments, ditches and small streams come out much sharper.

Terrain © ČÚZK (DMR 5G), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Border tiles are completed with
[Mapterhorn](https://mapterhorn.com/attribution) tiles.

## How it works

BeamNG.Earth has no add-on hook for terrain, but it reads every Mapterhorn tile from its own download cache before it
asks the internet. This program runs beside BeamNG.Earth and:

1. reads the car's position from BeamNG.Earth's companion feed,
2. asks ČÚZK's DMR 5G image service for each Web-Mercator tile of zoom 13, 14 and 15 round the car (1.5 m a pixel at
   zoom 15) and a little ahead of it,
3. fills the pixels ČÚZK has no data for (outside Czechia) from Mapterhorn's own tile,
4. writes the result as a Mapterhorn tile (512 px Terrarium WebP) into `<cache>/dem/mapterhorn/z/x/y.webp`,
5. patches Mapterhorn's file list in the cache (`download_urls.json`) so it says Czechia goes to zoom 15, and
   removes BeamNG.Earth's decoded copies of tiles it replaced.

Nothing of BeamNG.Earth itself is changed. To go back: stop the add-on and clear BeamNG.Earth's cache (or delete
`<cache>/dem/mapterhorn` and `<cache>/dem/decoded`).

## Install

Save `cz_terrain.py` somewhere, then add it to BeamNG.Earth's local add-on list
`%LOCALAPPDATA%\beamng-earth\addons\local.json` (next to the Cargo Earth helper if you have it):

```json
{"format": 1, "addons": [
  {"id": "cz-terrain", "name": "CZ lidar terrain", "author": "themazzy", "repo": "themazzy/cargo-earth",
   "kind": "companion", "summary": "Czech DMR 5G lidar terrain (ČÚZK) instead of Mapterhorn's 5 m grid.",
   "licence": "MIT", "asset": "^cz_terrain.*\\.py$",
   "local": {"file": "C:\\Users\\YOU\\Documents\\cz_terrain.py", "tag": "v0.1.0"},
   "run": {"args": [], "port": 47830, "page": "http://127.0.0.1:47830/"}}]}
```

Open BeamNG.Earth's Add-ons page, start **CZ lidar terrain** and tick **Start with BeamNG.Earth**.

**After the very first start, restart BeamNG.Earth once.** It reads Mapterhorn's file list only when it starts,
and until it sees the patched list it does not ask for zoom-15 tiles in Czechia.

## Use

- Just drive: tiles are written round the car as you go.
- On a first visit the ground near you may load before its tiles are written; it uses the lidar the next time the
  place loads. To have it right on the first visit, open the page (http://127.0.0.1:47830/) and press
  **5 km / 10 km / 20 km round the car**, or type a place's lat/lon and **Prepare here**, before you drive there.
- Places you visited before the add-on keep their old road shapes until you clear BeamNG.Earth's cache there.
- By hand, without the game: `python cz_terrain.py --prepare 50.0875 14.4213 10` writes 10 km round Prague.
  `--cache-dir` points to the cache if it is not found (it is read from BeamNG.Earth's `app.json`).

Rough cost: a 10 km circle is ~800 tiles, roughly 0.5–1 GB of ČÚZK downloads and ~150 MB on disk.

## Known limits

- DMR 5G was flown in 2009–2013. Roads built since then sit on the old ground (the same is true of the current
  DMR 4G source).
- Heights are in the Czech Bpv datum, like Mapterhorn's Czech tiles; at the borders the neighbours' datums differ by
  decimetres, as they already do in Mapterhorn.
- It depends on ČÚZK's public image service (`ags.cuzk.gov.cz`). If it is down, BeamNG.Earth simply keeps
  Mapterhorn's terrain where no tile was written.
- Bridges are not changed: DMR 5G is bare ground, and bridge decks stay BeamNG.Earth's own estimate.

## Tests

`python -m unittest discover -s tests -p cz_terrain_test.py` (set `BNE_SERVER_DIR` to a BeamNG.Earth `server`
folder to also check that BeamNG.Earth's own decoder reads the tiles).
