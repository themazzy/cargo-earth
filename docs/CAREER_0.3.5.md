# Cargo Earth 0.3.5

Fix and pay-balance update after a code review of 0.3.4. Helper stays 0.3.1 and save schema stays 3, so existing careers load as before.

Exit BeamNG, replace the old ZIP with `cargo_earth_career_0.3.5.zip` in the mods folder and keep only one Cargo Earth version enabled.

## Fixes

- **Lighter saves.** A save used to write four files (staging, two backups and the save), each read back and checked. Saves happen on every accept, pickup and delivery, so this could stutter. Backups now rotate at most every 5 minutes of play (`persistence.BACKUP_EVERY_S`); an ordinary save writes the staging file and the save. Recovery still uses the two backups, which can now be up to a few minutes older.
- **Owned-car limit without a home.** The 3-car limit only applied once a home garage was chosen, so you could keep any number of parked cars and hired drivers. Keeping a car now always respects the limit (the home's capacity, or `garage.CAR_LIMIT` = 3 without a home). Cars you already own are kept.
- **Drivers work while you do.** Hired drivers now earn only while you have an order or contract, or are driving. Standing idle with the game open no longer earns money.
- **Money history.** Cancel fees, repairs, debt payments, parts, car purchases and driver hiring now get their own lines in Career / Finances (Garage, Parts, Cancel fee) instead of one unnamed "adjustment". Categories show readable names.
- **Czech trucking keeps to the checked depots.** Where the bundled depot pack covers the area, streamed Overture yards and shops are no longer mixed into trucking and company jobs, and trucking mode no longer asks the helper for workplaces there. Outside the pack (other countries) streamed workplaces work as before.
- **Cleanup.** Removed the unused `phoneButton` (old hardware-button code), a garage action pointing to a missing function, and an early return in the crash handler that could skip saving and the phone notice.

## Pay rebalance

Courier work pays about 450 CZK per hour, and car, part and repair prices follow it. Trucking paid 3,500 to 9,000 CZK/h, which made cars nearly free, and company contracts only about 190 CZK/h. Agreed with Jan:

| Work | Before | Now | Change |
|---|---|---|---|
| Van freight | ~590 CZK/h | ~590 CZK/h | unchanged (base 80, 11 CZK/km) |
| Rigid truck | ~1,200 | ~850 | base 240 → 120, per km 19 → 15 |
| Articulated truck, general goods | ~3,500 | ~1,250–1,700 | base 1,500 → 300, per km 38 → 22 |
| Company contract (board sample median) | ~188 | ~377 | the empty drive back to the yard is paid, driver share 65% → 80% |
| Own-van contract (board sample median) | ~290 | ~470 | the drive back is paid |

Short fuel runs with an articulated truck still pay most (about 3,000 CZK/h) because of fuel's pay factor and the ADR bonus. Details: [payout statistics 0.3.5](research/payout-statistics-0.3.5/README.md).

## Checks

`npm test`: 41 career checks (two new: car limit without a home, streamed workplaces vs. the depot pack), 5 helper-client checks, phone checks and the Czech depot smoke test pass. All Lua files also compile in LuaJIT. Not yet checked in game.
