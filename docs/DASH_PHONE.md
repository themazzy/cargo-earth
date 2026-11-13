# Phone on the dashboard (VR, work in progress)

A real phone on the dash that shows the full Cargo Earth phone app, for cockpit and VR play.
The floating flat phone stays for normal play.

## Turning it on

Phone app → Menu → Settings → VR → **Phone on the dashboard: On**. It works in every car, mod cars included: the car
you drive gets the phone, and so does each car you spawn or switch to afterwards (a moment after it appears, the car is
reloaded once with the phone). Traffic never gets one. It costs nothing and is not a career part.

Below the switch, **Up / down**, **Closer / further** and **Left / right** move it 1 cm per press, kept per car model.
The car reloads once, 1.5 s after the last press. **Move it with a small pad** closes the big window and shows the same
buttons in a small pad in the corner, so the phone stays in sight; **Done** brings the window back. **Back to where it
started** drops the nudges; **Measure this car again** measures the car again.

Beside the phone are six labelled buttons: on the left **Go online / offline**, **Accept the order** and **Decline
the order**; on the right **Scroll up**, **Scroll down** and **Route to the next stop**.

The older floating VR screen (a Skia billboard in front of the driver) is removed: a billboard always turns toward the
camera and was placed from the seat node, so it turned with your head, shook with g-forces and flickered, and its
runtime trigger boxes never ended up in the right place (beamng.log showed their centres as infinite).

## How it works

* **No file, no slot:** while the switch is on, `cargoEarth/dash.lua` wraps the game's jbeam part lookup
  (`lua/common/jbeam/io.lua`: `getPart`, `getCompatiblePartNamesForSlot`, `getAvailableParts`,
  `getAvailableSlotNameMap`). Every car's main part gets one more slot, `cargo_earth_phone`, empty by default, and the
  part `cargo_earth_phone_auto` is built for the car's model on request. From there the game loads it like a part from
  a file. The player's car is respawned with the part chosen in its parts tree (`gamecar.respawnPlayer`, which also
  clears the game's jbeam cache), so it stays in the car's config through BeamNG's own respawns.
* **Placement (findSpot):** the driver's head is the driver seat's camera (`vdata.cameras.occupant`, or the older
  `driver` camera). The phone stands on the dash between the driver and the middle of the car (15 % of the way from the
  middle), on top of the highest dash node and 2.7 cm behind its back edge, at most 12 cm below the eyes, turned in 5°
  steps to face the head (`cargo_earth_phone.dae` holds the phone turned every 5° from −70° to 70°). Dash nodes are the
  ones in a group named `*dash*` when the car has one; otherwise glass, hood, gear lever, steering, seats and doors are
  left out. On the Pigeon's real nodes this gives (−0.047, −0.43, 1.07), the spot tuned by hand in the VR test.
  The measured spot is saved per model in `settings/cargoEarth/dash.json` with the switch and the nudges.
* **Screen:** the vehicle controller `cargoEarthPhone` opens a vehicle web view (`@cargo_earth_phone`) with
  `vehicles/common/cargo_earth_phone/phone.html`. That page loads the same `CargoEarthPhone` app as the flat
  phone, so every screen and button is the same. The screen material shows the web view as its texture.
* **Calls:** the page has no `bngApi`; `dash.js` stands in for it and sends each call through
  `beamng.sendEngineLua` to `cargoEarth_core.dashCall`, which only runs the phone app's own call shapes
  (`dashAllowed`) and sends the answer back to the page through the car.
* **Pressing:** 72 nearly clear cockpit trigger boxes (6 × 12 grid) lie 4 mm in front of the screen, in the same
  jbeam `triggers2` / `triggerEventLinks2` format as the stock hazard and sun visor buttons. Point the VR controller
  (or the mouse) at a spot and pull the trigger: the cell's input action asks the page to click whatever is
  under the middle of that cell. The rows use the stock `triggers2` header (`dash.TRIGGER_HEADER`): the game keeps
  only the first part's header when it merges parts.
* **Box turn:** the game does not lay a box trigger along its three nodes. It points the box's y along the frame's
  normal, turns it about that to the frame's "up", then applies `baseRotation` (the game's Lua mirror of this is
  `lua/ge/extensions/core/vehicle/triggerLabelPlacement.lua`). `dash.boxAxes` repeats that math and `dash.boxTurn`
  searches the `baseRotation` that lays every box flat on the turned phone, so the boxes are exactly cell-sized.
  (Before 0.8.8 the boxes were sized for the node frame and came out skewed and too big.)
* **Buttons beside the phone:** six more triggers (`dash.BUTTONS`), each with a label and its own input action
  (`cargoEarthButton_<id>`); the controller scrolls the page itself and sends the rest to
  `cargoEarth_core.dashButton`.

Regenerate the meshes, materials and the click grid's input actions with `python3 tools/make-dash-phone.py` (it uses
`tools/make-phone-mesh.py`). beamng.log shows `dash phone: <model> measured, phone at ...` when a car is measured, and
`phone holder screen started` and `dash phone holder running in car N` when the screen starts.

## Not tested in game yet

The generated part (slot added at load time), the placement in other cars than the Pigeon, the mesh turn direction, the emissive screen material, `beamng.sendEngineLua`
inside a vehicle web view, and loading the app script from `local://local/ui/...`.

## One phone state for both phones

The floating phone and the phone in the holder show the same page and the same radio:

* **Work / Radio:** the game keeps which page the phone shows (`cargoEarth_core.phoneTab`, `phoneState().tab`); a
  choice made on one phone shows on the other within a moment. A ringing order sets it to Work.
* **Radio:** the game keeps the radio (`cargoEarth_core.radioDo`: play, stop, vol, via, fav), with the volume, the
  player setting, the last station and the saved stations in `settings/cargoEarth/radio.json` (taken once from the
  UI page's storage where an older version kept them). The sound comes from one player on the game's UI page
  (`pagePlayer` in the phone's `app.js`, started by the floating phone or the Menu app and kept for the page's life,
  so hiding the phone app in the cockpit does not stop it). It checks in twice a second (`radioDo('page', ...)`) and
  plays when the game says the page should. The helper plays instead when the setting says so, for AAC or a stream
  the page refused, and when no page has checked in for 5 s (only the holder phone in use: a car screen page plays
  no sound).

## The Menu window

The Menu (Garage, Home, Companies, Progress, Finances, Delivery map, Firm, Settings) is its own UI app,
**Cargo Earth: Menu** (`ui/modules/apps/CargoEarthMenu`, the phone app's code in menu mode). Either phone asks the game
(`cargoEarth_core.openMenu`) and the window opens in the Menu app; without it, in the floating phone; without either,
on the asking phone itself. The Menu app is added to the .Earth layout once, top left, like the phone.
