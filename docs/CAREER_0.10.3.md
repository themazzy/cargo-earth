# Cargo Earth 0.10.3

Several named careers, used cars with pictures and specs, a helper that starts by itself, and update notices that show
up as soon as you load a save.

**Update both the mod and the helper.** Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux)
and choose 1, or replace the mod with `cargo_earth_career_0.10.3.zip` and the helper with `cargo_earth_helper_0.10.3.py`.
Close BeamNG and the helper first. Keep only one Cargo Earth ZIP installed. Saves are kept. Requires BeamNG.Earth
1.9.0-beta or newer.

## Several careers
- Keep up to 20 named careers. The phone's start screen lists them (money, car, hours played, when you last played)
  with **Load** and ✕ to delete one (it asks first).
- **Start new career** with a name of your own, or leave the field empty for the suggested one.
- Menu → Settings → **Save and switch career** goes back to the list; **Delete this career** deletes only the current
  one (type DELETE). Your settings and other careers stay.
- Your save from before 0.10.3 becomes **Career 1**, in the same file, nothing is copied or lost.
- The installer's `-delete-save` deletes every career.

## Helper starts by itself
- Players had to find **Start with BeamNG.Earth** on BeamNG.Earth's Add-ons page, or start the helper by hand. The
  installer now sets the helper up in BeamNG.Earth with that switch on. If you turned it off yourself, it stays off.
- When the helper is not running, the phone shows **Start helper** (or **Install and start** when BeamNG.Earth has not
  installed it yet). One press starts it through BeamNG.Earth and turns the switch on. **Not now** hides it. The
  button also shows when speed cameras, radio or the update check cannot reach the helper.

## Update notice
- The helper used to remember GitHub's answer for 6 hours, even across restarts, so a new release could stay unnoticed.
  It now asks when it starts (unless it asked in the last 10 minutes), every time you load a save (at most once per
  5 minutes) and every 2 hours. A new release shows on the phone a few seconds after you load your save.

## Used cars
- Every listing shows the car's picture from the game (like the career dealership) and a **Details** card with power,
  torque, weight, top speed, 0-100 km/h, drive, gearbox and fuel. No car is spawned for this. Mod cars without a
  picture get a plain car outline; numbers the game does not know are left out. Pictures work on the dash phone too.

## Fixes
- Bus: your history and records keep the real driving time; only the rating uses the timetable plus late minutes.
- Rush taxi rides are never ended by a rough ride.
- A firm trailer taken out at HQ brings no offers until it is latched on the hitch, then offers count it.
- Saves: a failed write of the careers list is retried before the save counts; a failed resume can be retried.

## Not tested in game yet
Career list (load, new, delete, switch, the old save becoming Career 1), the installer's autostart in BeamNG.Earth and
the phone's Start helper button (it uses BeamNG.Earth's own Add-ons functions), used-car pictures and Details, and the
update check on save load.
