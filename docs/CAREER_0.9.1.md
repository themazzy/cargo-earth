# Cargo Earth 0.9.1

Changes since 0.9.0. None of them has been driven in game yet beyond quick checks; the helper is unchanged apart from
its version number.

- **First run: Career or Free play.** Without a started career the phone used to take orders in any car and keep
  money, ratings and stats. Now the first run asks: start the career, or free play ("Just drive"). Free play keeps
  nothing; starting a career later begins from a clean save that keeps only settings. A home garage or a firm needs
  the career.
- **Menu:** one request opens one window (no more two Menus stacked), the Menu reopens on the page you left, and
  looking at a car for sale stays on the car list with a "Looking at" card (Buy it, Details, Back to my car).
- **Debt shows where it comes from.** Every charge that goes on the debt (free repairs, camera fines, fuel on credit,
  roadside help) is listed; payments clear the oldest charges first. Finances shows the debt by source, each open
  charge and a short history. Older saves show their debt as "Before charges were listed".
- **Fuel bills:** the wallet pays what it can and only the rest goes on the debt (before, the whole bill did, and
  nothing showed in Finances). A failed refuel takes back its own charge. Roadside fuel call-out fee 30 CZK (was 75).
- **Part fills:** BeamNG's pump always fills the tank, so the Garage fuel card and a new fuel bar on the phone's Work
  screen (shown while you stand at a station's pumps) offer 25 / 50 / 75 % / Full at the station's price. *Not now*
  hides the bar until you leave that station; it doesn't show when the tank is 90 % full or more.
- **Food orders:** at most two accepted orders in a row from one place, then two from elsewhere before it rings again
  (a village with one restaurant still rings). The phone splits the order time into *Pick up in* and *Deliver in*;
  pay, tips and stars still go by the delivery time.
- **Experimental, separate download: CZ lidar terrain** (`earth-addons/cz-terrain`, add-on 0.1.0). A BeamNG.Earth
  add-on that writes ČÚZK DMR 5G lidar terrain (2 m) for Czechia into BeamNG.Earth's Mapterhorn cache. Not installed by
  `CargoEarthSetup.exe` and not needed by the mod; untested in game.
