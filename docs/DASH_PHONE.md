# Dash phone part (VR, work in progress)

A real phone on the dash that shows the full Cargo Earth phone app, for cockpit and VR play.
The floating flat phone stays for normal play.

## Fitting it

Phone app → Settings → VR → **Fit phone holder** (or BeamNG's Vehicle Config → *Additional Modification*). In a
career the parts checkout asks to pay for it like any other part. Pigeon only for now.

The older floating VR screen (a Skia billboard in front of the driver) is removed: a billboard always turns toward the
camera and was placed from the seat node, so it turned with your head, shook with g-forces and flickered, and its
runtime trigger boxes never ended up in the right place (beamng.log showed their centres as infinite).

## How it works

* **Part:** `cargo_earth_phone_pigeon` ("Cargo Earth phone holder") fits the Pigeon's *Additional Modification*
  slot (`pigeon_mod`). It is a small mesh (`cargo_earth_phone.dae`, made per car) fixed to the dash nodes and turned
  once (about 31° in the Pigeon) to face the driver's eyes; it never moves with your head. Other cars come later (likely through the common Navigation Unit slot).
* **Screen:** the vehicle controller `cargoEarthPhone` opens a vehicle web view (`@cargo_earth_phone`) with
  `vehicles/common/cargo_earth_phone/phone.html`. That page loads the same `CargoEarthPhone` app as the flat
  phone, so every screen and button is the same. The screen material shows the web view as its texture.
* **Calls:** the page has no `bngApi`; `dash.js` stands in for it and sends each call through
  `beamng.sendEngineLua` to `cargoEarth_core.dashCall`, which only runs the phone app's own call shapes
  (`dashAllowed`) and sends the answer back to the page through the car.
* **Pressing:** 72 cockpit trigger boxes (6 × 12 grid) lie 4 mm in front of the screen, in the same jbeam
  `triggers2` / `triggerEventLinks2` format as the stock hazard and sun visor buttons. Point the VR controller
  (or the mouse) at a spot and pull the trigger: the cell's input action asks the page to click whatever is
  under the middle of that cell.

Regenerate the part with `python3 tools/make-dash-phone.py` (it uses `tools/make-phone-mesh.py` for the mesh).
beamng.log shows `phone holder screen started` and `dash phone holder running in car N` when the part's screen starts.

## Not tested in game yet

Flexbody placement on the dash, the trigger frame axes, the emissive screen material, `beamng.sendEngineLua`
inside a vehicle web view, and loading the app script from `local://local/ui/...`.

## The Menu window

The Menu (Garage, Home, Companies, Progress, Finances, Delivery map, Firm, Settings) is its own UI app,
**Cargo Earth: Menu** (`ui/modules/apps/CargoEarthMenu`, the phone app's code in menu mode). Either phone asks the game
(`cargoEarth_core.openMenu`) and the window opens in the Menu app; without it, in the floating phone; without either,
on the asking phone itself. The Menu app is added to the .Earth layout once, top left, like the phone.
