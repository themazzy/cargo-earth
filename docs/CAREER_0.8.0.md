# Cargo Earth 0.8

Regional radio on the phone, and a phone screen on the dashboard for VR. Also two phone fixes: the online/offline switch
is now on the delivery screen too (a courier on a delivery kept getting new orders), and the speed limit sign uses the
country's unit (BeamNG.Earth's 35 mph fallback showed as a 35 mph sign in Czechia; a speed that is no posted limit in the
country now shows no sign).

## Regional radio

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
- **When the game cannot play it** (Jan's first test: every station failed inside BeamNG's UI browser), the phone hands
  the station to the helper, which plays it on the computer: on Windows with the system's own media player (Media
  Foundation through PowerShell; MP3 and AAC), elsewhere with ffplay, mpv or VLC if installed. The phone remembers
  this ("Play through the Cargo Earth helper", a switch under the volume). The helper plays only stations it listed
  itself, and stops when the game has not checked in for 20 s, so the music never outlives the game.
- **Presses answer at once.** Jan found the controls slow: the helper player's commands waited in the one-at-a-time
  helper queue (worked every half-second tick, behind area downloads), and the helper waited up to 2 s for the old
  player to quit before answering. Play/stop/volume and the heartbeat now use their own connection worked every frame
  (`helper.command` / `helper.pump`), the helper answers before the old player has ended, and the phone checks the
  tuning-in state every 0.4 s instead of 1.5 s.
- Crossing a border keeps the current station playing and lists the new country's stations.

Helper API: `/v1/radio?cc=CZ&lat=..&lon=..` and `/v1/radioclick?id=<uuid>`. The helper's `/v1/info` says `"radio": true`.

### Not tested in game

- Whether BeamNG's UI browser plays sound at all, and at what volume relative to the game. If it is silent, the fallback
  is to let the helper play the stream.
- Which codecs it supports: MP3 and Ogg should play; AAC may not (the phone says so when a stream fails).
- Live requests to Radio Browser (the build sandbox blocks the site); tested with fixtures only.

## A phone screen on the dashboard for VR

> Replaced after 0.8: the floating screen below is gone; see [DASH_PHONE.md](DASH_PHONE.md) for the phone holder part.

Jan's ask on 12 November 2026: a phone on the centre of the dash. On a monitor the normal phone app stays as it is.
In VR, BeamNG shows the whole UI on a floating panel anchored to the room or your head, not to the car, so the panel
phone can never sit on the dash. The mod therefore puts a small phone screen in the 3D world for VR.

(A first try drew the UI phone in perspective over the dash on a monitor. Jan found it not usable, and it could not
work in VR, so it was dropped.)

### How it works

- In VR, in any camera inside the car, a phone screen sits at the centre of the dash: ahead of the driver's seat,
  below the eyes, most of the way to the middle of the car. It always faces your head and moves with the car.
  Right-hand drive cars get it on their own side.
- It shows what you need while driving: pick up or drop off, the place, the distance, time left and pay; an incoming
  order with its countdown and pay; online/offline and today's earnings; the speed limit sign, the clock and money.
- It has buttons at the bottom, pressed like the car's own cockpit buttons (doors, lights, parking brake): point a
  VR controller at one and pull the trigger. On a monitor (show "Always") they can be clicked with the mouse. The
  buttons follow the phone: Decline / Accept for a new order, Route while driving to a stop, OK after a delivery,
  Go online / Go offline when idle, Resume for a saved career. Cancelling an order stays on the normal phone, so it
  cannot be hit by accident.
- Settings, VR: "Screen on the dashboard" switches between VR (default), Always (also on a monitor, handy to check
  the place without the headset) and Off. In the cockpit you can move it (up, down, left, right, closer, further),
  make it bigger or smaller, or put it back. Every car model keeps its own place (`settings/cargoEarth/dash.json`).

### Inside

`cargoEarth/dash.lua` uses the engine's Skia billboards (`WorldBillboardRenderer`), the same path the game uses for
multiplayer name tags and world icons: no browser view, no mesh, no per-frame drawing in Lua. Each frame only the
billboard's position is set (driver camera node, vehicle axes, vehicle box centre). The picture is a Skia template
(boxes and text with flex layout) built from `phoneState()`, and it is re-rasterized only when its text changes, at
most once a second. Text uses the game's own label font (from its icon marker config).

The buttons (`cargoEarth/dashtap.lua`) use the game's vehicle interaction system. While the screen is shown, the
player's car gets two extra trigger boxes (`veh:addTrigger()`, set up with the same calls the jbeam loader uses for
cockpit triggers) over the left and right halves of the button row, framed on the car's reference nodes. They are
linked to two small input actions in the car's data (`cargoEarthDash1`, `cargoEarthDash2`, run in game Lua), so the
game's own pointer, highlight, hover label and VR controller trigger all work on them. Pressing one calls
`cargoEarth_core.dashTap(slot)`, which reads the phone again and does what that button shows at that moment. The boxes
are placed again only when the screen moves or the car is reloaded; when the screen is hidden they shrink to nothing.

### Not tested in game yet

- The buttons: that the added trigger boxes land on the drawn buttons, that the VR controller laser and trigger press
  them, and that the game's hover label shows the button's name.

- That the billboard shows in VR inside the cabin and is not hidden by the dashboard (move it up if it is).
- The template details (font, rounded boxes, text shrinking) as BeamNG's Skia renderer draws them.
- Default place and size in vans and trucks.
