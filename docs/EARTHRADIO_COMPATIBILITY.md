# EarthRadio compatibility

Reviewed against the supplied EarthRadio R0.40 source and Cargo Earth's current development branch.

## Helper connection

EarthRadio uses a newline-delimited JSON protocol on `127.0.0.1:47820`. Cargo Earth's HTTP helper now uses `127.0.0.1:47821`. Disabling Cargo Earth's radio playback does not stop its data helper, so separate ports are required.

Update the mod and helper together with CargoEarthSetup and restart BeamNG.Earth. The installer updates manual launchers, the Cargo helper's add-on entry and its saved Port option. Explicit legacy Cargo port settings migrate to 47821. Other custom ports remain supported and are synchronized with Cargo Earth's `helperPort` configuration. The installer keeps other add-ons' entries and backs up changed configuration files.

An already-running old helper must be stopped by restarting BeamNG.Earth or closing its own manual launcher. The installer does not terminate unrelated processes. Updating only the mod can leave an old helper listening on the retired port; the phone's connection message identifies the port and the update/restart steps.

## Vehicle part hooks

Cargo Earth restores a JBeam lookup function only when its own wrapper is still installed there. If EarthRadio or another add-on installed a wrapper later, that wrapper stays in place. Cargo's retained wrapper becomes a passive delegate when Cargo unloads. Reinstalling Cargo adds its phone slot once.

Automated checks cover both wrapper installation orders and Cargo unload/reload with another wrapper retained.

## Antenna fitting on damaged cars

This remains an interaction requiring in-game verification. EarthRadio R0.40's `antennaToggle(true)` and automatic fitting path can call `core_vehicle_manager.reloadVehicle(0)`. Its fallback can also change the parts configuration or replace the vehicle. These calls can rebuild a damaged car. Cargo Earth's damage tracker charges a damage reduction from an external reset/respawn as an unpaid repair.

Code tracing confirms the reload path and the charge mechanism. It does not establish that every antenna fitting clears damage in the running game. This change keeps genuine repair/reset charges in place and does not exempt all reloads while EarthRadio is loaded.

To verify, damage an owned career car, note its repair bill and debt, then let EarthRadio fit its antenna or press its ANT button. Check the physical damage, repair bill and debt afterward. Repeat with an ordinary game reset to distinguish the two paths. A damage-preserving antenna integration requires coordination with EarthRadio's reload path if this reproduces.
