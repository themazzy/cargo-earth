# Cargo Earth 0.10.2

Taxi modes, bus timetables and passenger comfort, better tow jobs, and an installer that really updates the helper
BeamNG.Earth runs.

**Update both the mod and the helper.** Run `CargoEarthSetup.exe` (Windows) or `CargoEarthSetup-linux-x86_64` (Linux)
and choose 1, or replace the mod with `cargo_earth_career_0.10.2.zip` and the helper with `cargo_earth_helper_0.10.2.py`.
Close BeamNG and the helper first. Keep only one Cargo Earth ZIP installed. Saves are kept. Requires BeamNG.Earth
1.9.0-beta or newer.

## Installer updates BeamNG.Earth's own helper copy
- BeamNG.Earth runs the helper from its own copy in `addons/cargo-earth-helper/` and only replaced it when Update was
  pressed on its Add-ons page, so after installing 0.10.1 Earth could still run the 0.10.0 helper. The installer now
  copies the new helper there too and updates Earth's `installed.json`. If that fails it tells you to press Update.
- When the helper is older than the mod, the game says so once and the phone shows a bar asking you to press Update on
  Cargo Earth helper in BeamNG.Earth's Add-ons page.

## Taxi rides
- Each passenger is **Comfort** or **Rush**. Comfort gives more time and a tip for a smooth ride (15 % at full comfort);
  a rough ride costs pay. Rush pays 25 % more and doubles the speed tip, but every minute late costs more.
- Rides fit the car's seats: never more passengers than free seats (stock cars with BeamNG's seat system). Accepting
  checks the car you are in.

## Bus lines
- **Timetable per stop:** each stop has its own due time from the road distance. The phone shows *Stop due in* or
  *Behind by*, plus how far behind the timetable you are. Each late minute costs 1 % of the line's pay.
- **Pay** now follows the timetable: 60 + 7 per timetable minute + 3 per stop, plus fares (about 500-620 CZK/h).
  The board shows the fares a line usually brings.
- **Passenger comfort:** with people on board, harsh braking or cornering and bumps cost comfort; the line's pay is
  multiplied by 0.6 + 0.004 x comfort, and comfort counts in the stars. The phone shows it once it drops below 100 %.
- Stop names from an older helper (`u0161`-style leftovers) are shown as proper letters.

## Tow jobs
- Wrecks are pressed in for real (the body crumples) instead of only losing bumpers and lights; nothing flies.
- Cars sit in the middle of the deck.
- Small cars (Covet, Autobello, Pigeon) go on the stock Large Box Utility Trailer (490 kg, 4.2 m floor), which any car
  with a tow hitch can pull. Your firm can buy one at HQ (1,200).
- Firm trailers: **Take it out** at HQ puts your own car trailer on your hitch (**Leave it here** parks it), so tow
  offers skip borrowing.

## Texts
- Freight texts name the real vehicle (van, box truck, tractor, city bus) instead of always saying "van".

## Not tested in game yet
Taxi modes and seat check, bus timetable, comfort and pay, wreck press depth, small trailer and HQ trailers, and the
installer's update of BeamNG.Earth's helper copy.
