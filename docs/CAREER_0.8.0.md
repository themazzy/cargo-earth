# Cargo Earth 0.8 (in progress): regional radio

The phone has a **Radio** tab that plays real internet radio stations of the country you drive in, anywhere in the world.

- **Stations** come from [Radio Browser](https://www.radio-browser.info), a free community directory (no key, public-domain
  data). The game cannot reach the internet, so the Cargo Earth helper asks for them: one request per country a day,
  kept in the helper's cache (`cache/radio/<CC>.json`). It finds Radio Browser's servers through DNS as its docs ask,
  sends a `cargo-earth-helper/<version>` User-Agent and reports each station you start (`/json/url/<id>`), which is how
  Radio Browser counts listeners.
- **Country**: the mod's bundled borders (the same as for the local money). **Near you**: stations whose listed place is
  within 120 km of the car, nearest first. Radio Browser has no place-based search, so the helper filters the country's
  400 most listened stations itself; countries where stations list no place show only the popular list.
- Only working streams (last check OK), no HLS playlists, no duplicates.
- **Playback** happens in the phone page itself (an HTML audio element), so it keeps playing with the phone folded or on
  another tab; the folded phone shows the station. Play/stop, previous/next, volume and saved stations (star), all by
  clicking. Volume, the last station and saved stations stay in the UI's local storage.
- Crossing a border keeps the current station playing and lists the new country's stations.

Helper API: `/v1/radio?cc=CZ&lat=..&lon=..` and `/v1/radioclick?id=<uuid>`. The helper's `/v1/info` says `"radio": true`.

## Not tested in game

- Whether BeamNG's UI browser plays sound at all, and at what volume relative to the game. If it is silent, the fallback
  is to let the helper play the stream.
- Which codecs it supports: MP3 and Ogg should play; AAC may not (the phone says so when a stream fails).
- Live requests to Radio Browser (the build sandbox blocks the site); tested with fixtures only.
