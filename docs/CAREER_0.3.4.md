# Cargo Earth 0.3.4

Company parcel damage, failure and reputation update. Includes the 0.3.3 parts-checkout fixes and 0.3.2 phone navigation. Helper remains 0.3.1; save schema remains 3.

## Installation

Exit BeamNG, replace the previous Cargo Earth ZIP with `cargo_earth_career_0.3.4.zip`, and leave only one Cargo Earth version enabled. Resume the existing career. New optional condition/incident fields also support in-progress contracts; damage from before this update cannot be reconstructed.

## Corrected behaviour

The impact watcher and condition-based payment previously covered food orders only. Native parcel freight, including company and independent van contracts, now uses the same vehicle-side impact feed and loaded-only guards. Pickup cargo still at the depot is not affected. Glassware/electronics are fragile, bricks/car parts are sturdy, and other parcels use standard handling.

- Loaded parcels display handling and 0–100% condition on Work / Deliveries.
- Parcel payment is proportional to remaining condition, after lateness adjustments. Existing food payment rules are unchanged.
- A ruined parcel load pays zero, increments failure history and advances the company manifest once. It does not award a delivery, rank or haul completion. Its native container load is cleared.
- After a failure, the next company pickup waits until the failure notice expires or is dismissed. Even two failed loads allow returning to the yard and ending the contract.
- Employer reputation reflects delivered cargo quality, failed loads and vehicle damage. It no longer automatically awards +10 for every finished route.
- Company-covered repairs remain free to the driver. Vehicle damage accumulates as estimated repair value for the reputation result and survives vehicle resets and save/resume. It is also sampled at settlement to catch damage since the last periodic tick. Independent drivers keep their ordinary repair/debt costs.
- Work / Companies shows failed loads, recorded vehicle damage and reputation score. The settlement shows the actual reputation change, clamped to the existing 0–100 range. No new damage-related wage deductible is applied; cargo damage itself reduces wages through revenue.

## Reputation calculation

For a normal yard finish, quality reward is `round(10 * sum(delivered condition) / 200)` for the two-job route. Ending early grants no quality reward. Each ruined load subtracts 10 points. Vehicle damage subtracts `min(30, ceil(recorded repair value / max(1000, quoted route revenue) * 20))`. Existing reputation remains bounded to 0–100, and damaged routes do not manufacture negative balances. A route containing a failed delivery does not count as a successful shift.

## Checks and limits

Passed 39 career scenarios, five helper-client scenarios, phone checks, Lua syntax and the real Czech depot smoke test. Seven new scenarios exercise actual company impact callbacks, partial payment, failure/physical unloading, manifest advancement, reset-resistant vehicle damage, stale/pickup guards, save/resume, all-failed settlement and independent repair ownership.

Checks use isolated BeamNG adapters. This build still needs native crash/accelerometer and UI verification in-game. Cargo condition currently covers food and native **parcel** freight; bulk/fluid cargo condition and trailer-specific impact telemetry are outside this change. New vehicle damage records require game damage samples; repair estimates are a reputation measure, not a structural roadworthiness assessment.
