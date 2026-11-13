# Cargo Earth 0.9.0

Changes since 0.8.7. Parts of them were tried in game during development (the dash phone, the phone layout, the tab
fix); the new freight contracts, truck contracts and radio retries have not been tested in game yet.

- **Food orders stay close in small towns.** Customers within 1.5 km are the most likely, further ones become rarer,
  and other towns' addresses are much rarer. Where the game's road map is loaded, an order whose road trip is far
  longer than the straight line (across a river, railway or motorway) is skipped, and pay follows the real road
  distance. Tow pickups are weighted near too, and tow pay follows the road.
- **Freight without your own van: company contracts.** The freight page lists the nearest contracts (Route, Start,
  All contracts). The free loaner van is gone; the company hands over its vehicle at the yard when you start a
  contract. Once unlocked, **box truck and tractor contracts** appear too (12-40 km and 20-60 km deliveries).
  Company vehicles do only contract work: no food, tow, parcel or own freight jobs in them. Old loaners leave My
  cars.
- **Blue rings** show where your home garage (60 m) and headquarters (80 m) count.
- **Phone:** one compact status row, a shorter footer, shorter texts, a Food delivery | Freight switch on the offline
  screen. The Work/Radio choice now really reaches the game, so the phone no longer jumps back to Work during an
  active order, and an incoming offer leaves Radio on screen with an offer bar on top.
- **Dash phone (VR):** found on every car (BeamNG keeps only a node's first group after loading), no more vanishing
  car when switched on, labelled side buttons (Go online, Accept, Decline, Scroll, Route), click boxes lie flat on
  the turned screen, the radio plays from the holder phone too and keeps playing when the UI phone is hidden.
- **Radio:** a station that drops is tried again before it counts as an error, and the helper reconnects a dropped
  station inside the same stream.
