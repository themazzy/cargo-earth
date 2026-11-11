# Cargo Earth 0.3.2

Phone navigation update, including all career and storage fixes from 0.3.1.

Replace the previous Cargo Earth mod ZIP with `dist/cargo_earth_career_0.3.2.zip` in your BeamNG user-folder mods directory. Keep only one Cargo Earth version enabled. The helper is unchanged: continue using `cargo_earth_helper_0.3.1.py`. Save schema remains 3.

| Phone tab | Contents |
|---|---|
| Work | Deliveries and Companies views; offers, current delivery, company contracts and wage collection |
| Garage | Current vehicle, repairs, parts, used cars, fleet and debt payments |
| Home | Home address search, parking claim, capacity and route home |
| Career | Progress and Finances views; milestones, balance, debt, held wages and recent transactions |
| Settings | Delivery mode, search preferences, save/pause and debug window |

The bottom navigation stays outside the content scroll. Section labels, icons, selection states and keyboard focus indicators make each destination identifiable. The Work and Career subviews retain their selection across tabs. Reselecting Garage preserves the current garage subpage.

A shortcut on other pages returns to the active delivery or company contract. Incoming offers open Work / Deliveries, including when Companies was previously selected. Resume screens hide the other pages. Discovery refreshes run only while Home or Companies is visible; no additional geographic downloads were added by the navigation change.

Finances reads debt from the personal garage during company work. Held wages exclude already-settled contracts. These values supplement the existing bounded transaction history.

Validation: 26 career scenarios, five helper-client scenarios, phone navigation/shortcut/polling/backpressure/teardown checks, Lua syntax and the Czech depot smoke test passed. Browser preview verification was blocked by a connection timeout and browser URL verification failure. The 290 x 560 default layout still needs a native BeamNG visual check.
