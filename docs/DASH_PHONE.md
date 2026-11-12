# Dash phone part (VR, work in progress)

A real phone on the dash that shows the full Cargo Earth phone app, for cockpit and VR play.
The floating flat phone stays for normal play.

## How it works

* **Part:** `cargo_earth_phone_pigeon` ("Cargo Earth phone holder") fits the Pigeon's *Additional Modification*
  slot (`pigeon_mod`). It is a small mesh (`cargo_earth_phone.dae`) fixed to the dash nodes, so it never turns
  toward your head. Other cars come later (likely through the common Navigation Unit slot).
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
* While the part is fitted, the old floating VR billboard is not shown in that car.

Regenerate the part with `python3 tools/make-phone-mesh.py` and `python3 tools/make-dash-phone.py`.

## Not tested in game yet

Flexbody placement on the dash, the trigger frame axes, the emissive screen material, `beamng.sendEngineLua`
inside a vehicle web view, and loading the app script from `local://local/ui/...`.
