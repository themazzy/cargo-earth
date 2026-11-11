# Career systems for Cargo Earth / BeamNG.Earth

Research date: 11 November 2026. Status: design proposal, grounded in the local Cargo Earth source and the primary sources below. No gameplay code was changed and no in-game compatibility testing was performed.

Implementation update: this document records the starting point before build 0.3.0. The first home-garage, contract and live-workplace implementation is described in [the 0.3.0 guide](../CAREER_0.3.0.md). The current helper now includes nearby workplaces as well as courier locations and addresses.

## Recommendation

Expand Cargo Earth into an independent career add-on for BeamNG.Earth. Borrow BeamNG's relationship between vehicles, work and progression, and RLS's employment, contracts and business loops. Use Earth for the world and navigation, with Cargo Earth owning the economy, jobs and saves.

The most valuable first addition is a persistent network of usable workplaces and garages. That gives the existing delivery, vehicle and fleet systems a place in the world and creates reasons to return to a town or expand to another one.

Treat direct integration with stock Career or RLS as a separate compatibility project. Neither was verified to work with Earth's streamed world in this review.

## What the reference games actually provide

### Stock BeamNG career

The official v0.35 notes introduced Career Paths: APM vehicle evaluation, BMRA racing, Logistics and Freestyle. Content and progression were explicitly still evolving. Organizations and reputation, introduced earlier, connect successful deliveries to improved rewards and access to loaner vehicles. [S1, S2]

The v0.38 update added vehicle price negotiation, revised shopping, configurable insurance, delivery introductions and parking quality rewards. Insurance can be declined; its renewal distance and vehicle/provider rules belong to BeamNG's economy and should not be copied as Earth balance values. [S3]

The useful design principle is that a vehicle is both an investment and access to different activities. Progress should open worthwhile choices: more capacity, specialist cargo, a new employer or a new event. A larger bank balance alone does not create that variety.

### RLS Career Overhaul

The checked public release is v2.8.0, advertised for BeamNG.drive 0.40.3. It has its own career entry, saves and RLS West Coast map. Its additional maps need compatible career content. BeamNG's news index lists 0.40.5 on 6 November; this does not establish RLS compatibility with that patch or identify the user's installed game version. [S4, S5]

RLS distinguishes company employment, independent contracts and facility work. Employees apply at a yard, use company equipment and return to settle a shift. Compatible equipment is required for different load types. This is a good way to let players try commercial driving before buying expensive vehicles. [S6]

Its business systems connect workshops, vehicles, jobs and finances. Wallet and Logbook expose income and spending; company funds and personal funds can be separate. Freeroam events include several disciplines, but courses still depend on map content. [S7, S8, S9]

Source inspection also matters: RLS's facility service reads level information, facility JSON and sites references. Its career/session, employment and contract modules depend on multiple RLS services. Its save system has four rotating autosaves. These are reference implementations, not isolated modules we can simply drop into Cargo Earth. The code inspected was current `main`, not an audit of every file in the v2.8.0 release ZIP. [S10]

## What Cargo Earth already contains

These are source findings, not claims of successful in-game testing.

| System | Current implementation | Next useful extension |
|---|---|---|
| Courier work | Restaurant and grocery orders, customer addresses, batching, tips, deadlines, load condition and physical container mass | Repeat customers, company reputation, scheduled multi-stop rounds |
| Freight | Producer/receiver matching, compatible cargo and native container loading | Persistent contracts, return loads, route and access validation |
| Freight progression | Van, rigid and semi tiers; advancement after 5 van and 10 rigid deliveries | Equipment and competence requirements alongside current unlocks |
| Vehicle ownership | Starter car, used listings, previews, parts, spares, repairs, debt, saved configurations and parked cars | Physical garages, limited storage, service locations |
| Driver progression | Delivery-count ranks and courier milestones | Separate capabilities and organization relationships |
| Hired drivers | Assigned to owned parked cars; simulated shifts, earnings and mileage | Assignments with wages, operating costs and suitability checks |
| Persistence | One career JSON, save retry, unfinished orders, saved location and resume flow | Versioned profiles, recoverable checkpoints and transaction deduplication |
| Earth integration | Versioned API wrapper, geodetic coordinates, navigation, teleport and world/teleport hooks | Shared facility lifecycle and capability checks |
| User interface | Existing phone with orders, career, garage and settings flows | Places, contracts and income/cost explanations |

The bundled freight dataset contains 3,969 Czech depots. The loader can merge additional country packs, but only the Czech freight pack is present. The companion helper streams restaurants, grocers and customer locations from Overture worldwide; it does not currently supply a worldwide network of truck depots, garages or fuel stations.

Fuel purchasing, insurance policies, physical property ownership, company employment and a general transaction ledger are additions. Vehicle fuel-related part names in the garage do not constitute a refuelling system.

Relevant local files:

- `mod/cargo_earth/lua/ge/extensions/cargoEarth/core.lua`: session, payment, job lifecycle, saves and resume.
- `food.lua`, `cargo.lua`, `jobs.lua`, `haul.lua`: offers, condition, capacity and freight progression.
- `garage.lua`, `gamecar.lua`: ownership and economic logic, separated from game operations.
- `progress.lua`, `fleet.lua`: ranks, milestones and simulated drivers.
- `earth.lua`, `marker.lua`: Earth API access, coordinate conversion and nearby markers.
- `helper/cargo_earth_helper.py`: streamed geographic data and local cache.
- `mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js`: phone UI.

## Choose the integration boundary

| Approach | Benefit | Main cost | Assessment |
|---|---|---|---|
| Activate stock Career on Earth | Potential access to stock shopping, UI and progression | Must adapt facility/site discovery, world changes, saves, restrictions and vehicle lifecycle | A separate technical experiment |
| Make Earth an RLS career map | Potential access to a broad existing feature set | Earth geography must satisfy RLS map, organization, facility, course and lifecycle assumptions | Highest dependency and compatibility burden |
| Extend Cargo Earth's career | Fits the existing API wrapper, coordinates, helper, vehicles and saves | We implement the selected gameplay systems | Recommended first product |

This recommendation follows the inspected architecture. It is not evidence that either integration alternative is impossible.

## The player experience to build

Start in a chosen town with an affordable car and a home parking spot. Offer courier work and, where a validated employer exists, a company-driver introduction. Food deliveries should remain a viable specialization rather than a mandatory grind before trucking.

Company shifts provide a vehicle and a small sequence of jobs. The player returns the equipment and sees wages, company share and any agreed deductions. Owning a suitable van opens independent contracts with higher potential margins and more responsibility. Saving for a larger garage and a second vehicle then supports a small delivery business.

Geography supplies the long-term goals: establish a base in another town, build a relationship with a regional employer, take a return load, or maintain a route between two depots. Expansion should add opportunities and useful infrastructure. Travelling somewhere should not require an arbitrary geographic unlock.

Keep short and long sessions available. Display estimated duration, pickup travel, equipment requirements and pay before acceptance. Real-world scale makes distance a significant commitment.

## Feature priorities

| Feature | Inspiration | Earth implementation | Priority / dependency |
|---|---|---|---|
| Places and home garage | Stock facilities and RLS property | Geographic service records with validated parking; store parked vehicles without spawning them | First playable addition |
| Company jobs | RLS employment | Yard-based shift, provided vehicle, bounded assignments and one settlement | First playable addition |
| Company reputation | Stock organizations | Service-specific completion, condition and reliability record; explain unlocks | Alongside employment |
| Contract board | RLS broker and independent work | Stable offers with equipment, capacity, geography and frozen quotes | After reliable places |
| Multi-stop parcel rounds | Stock logistics | Manifest in one compatible vehicle; several reachable stops and one job record | After contract lifecycle |
| Fuel and roadside service | Stock ownership costs | Read/write real vehicle energy through an adapter; transact at a usable service point | Requires vehicle energy proof |
| Insurance | Stock and RLS | Optional coverage and deductible, explicit incident/claim handling | Requires reliable damage lifecycle |
| Garage business and drivers | RLS business loop | Existing parked-car drivers gain assignments, costs, garage capacity and clear net earnings | After contracts and ledger |
| Regional demand | RLS economy | Small, bounded changes by cargo, area and active career time | After measured baseline balance |
| Taxi and vehicle transfer | RLS alternative work | Reachable stops, seat or vehicle requirements, saved job state | Later diversification |
| Timed routes and rally | Stock/RLS events | Validated geographic checkpoints; begin with solo runs | Later, after route validation |
| Police pursuits and heavy worksite jobs | RLS variety | Need proof of traffic/navigation, spawn safety, equipment and suitable ground | Separate feasibility work |

Avoid launching a large macroeconomy, complex lending or worldwide AI simulation before the driving loop is reliable.

## The key technical system: geographic facilities

Stock facility definitions commonly reference zones, parking spots, scene objects and sites files. Earth changes the world origin as the player travels, so stored local coordinates cannot be the permanent identity of a business. [S11, S12]

Introduce `cargoEarth/facilities.lua` as our own registry. Each record needs:

- A stable, namespaced ID and provenance: source dataset, full source ID and data revision.
- WGS84 location, display name, region and service types.
- A separate approach/interaction location, heading, clearance and supported vehicle class where validated.
- Access state: candidate, validated, blocked or curated; local override version.
- Available services, capacity and gameplay organization ID.

A POI marks a candidate business, not a guaranteed driveway, parking space, truck entrance or represented interior. A road snap does not establish access. Start with a small curated set of usable locations in one Czech town or corridor. Let the helper discover additional candidates in the background, then validate the nearby ground and road access when streamed. Provide a fee-free way to report and cancel work at an inaccessible procedural stop.

Persist purchased properties and active job endpoints independently of the temporary discovery cache. A dataset update or cell eviction must not delete a purchased garage or strand an accepted delivery. Simulated employers can use real geographic context without implying an actual business participates in the game.

Only nearby markers and active physical equipment should exist in the game world. Project geographic points into current world coordinates when needed. The existing marker code already checks anchor changes; reuse that pattern. Rebase, teleport, load and genuine player recovery must be distinct transitions.

## Earth API capabilities and limits

The published API exposes pose, readiness, place names, GPS, teleport, notifications and events. The inspected implementation reports API 1.1 and also supports add-on options; the documentation's core API table still describes 1.0. Use major-version compatibility and `has()` for optional features. [S12, S13]

The API does not expose a general career facility registry, global traffic service, arbitrary point-to-point route quotation, truck clearance certification or a global road graph. Its GPS information describes the current destination. Setting GPS repeatedly to price every offer would disrupt the player's route.

Keep current distance estimates clearly labelled initially. A future helper routing adapter can supply cached route estimates without changing the active GPS destination, but its provider, coverage, cost, truck restrictions and failure behaviour need a separate choice. A routed car path still does not certify a semi can travel it. Freeze the accepted quote; avoid paying extra for detours or repeated GPS recalculations.

## Economy, time and saves before greater complexity

Introduce a small `economy.lua` with a single transaction function. Record integer CZK amounts, transaction ID, category, vehicle/job reference and active career time. Route delivery pay, purchases, parts, repair, debt collection and driver income through it incrementally. Every job/shift settlement needs a unique persisted ID so replayed callbacks cannot pay twice.

Keep the current currency and courier-based price calibration initially. Measure net earnings per active hour, including pickup travel, waiting and operating costs. Employment should offer lower capital requirements and predictable returns; independent work should reward investment and risk. Avoid stacking large pay multipliers for reputation, cargo, region and urgency.

Current concerns to address before adding bills or timed contracts:

1. Job deadlines currently use `os.time()`. Offline time is compensated on load, but an in-session pause can still age a deadline. Introduce an explicit active-career clock for deadlines, shifts, demand changes and recurring costs; freeze it while paused, loading, restoring or disconnected. Keep wall time for display dates.
2. Career distance currently increases by the job's estimated kilometres on completion. Track a separate measured odometer for insurance, maintenance and running costs. Sample geodetic movement and reject teleport/discontinuity samples; an origin rebase should not add distance.
3. Repair-debt detection observes drops in damage. New service and recovery actions need explicit expected-reset reasons so respawns and legitimate transitions cannot trigger duplicate charges. Reload restores a configuration and outstanding repair cost, not necessarily exact crash deformation.
4. Hired drivers currently earn 45 CZK per ten-minute shift regardless of route, equipment or operating costs. Extend this through assignments; do not add another independent passive-income timer.
5. Current persistence writes one career file. Add a schema version, migration, validated temporary write and recoverable rotating checkpoints using filesystem behaviour verified in BeamNG. Commit job state, settlement IDs and balances together. Save failure must remain visible and retryable.

Separate transaction history from the existing fifty-entry delivery history. Retain durable aggregates and settlement identities even when old display rows are pruned.

## Concrete first implementation

Build one complete company-driving loop in a Czech test area. Use three validated service/parking locations, one fictional employer, the existing van and cargo adapters, and a two-delivery shift that ends back at the employer. Include one home garage with a small number of parking slots. Keep wages in CZK and show a single understandable settlement.

Implement in this order:

1. **State foundation:** add `clock.lua`, `economy.lua` and a persistence boundary around the current save functions. Migrate the existing save and balances without resetting progression.
2. **World services:** add `facilities.lua` and a small curated data pack. Add Places and route-to-place actions to the phone; gate physical service actions on proximity and readiness in Lua.
3. **Company shift:** add `employment.lua`; snapshot the provided vehicle, generate bounded assignments using existing freight logic, restore unfinished work and settle exactly once on return. Support safe early termination.
4. **Ownership expansion:** tie parked vehicles to garage capacity, then add independent contracts, repeat-customer reputation and return loads.
5. **Broader simulation:** add verified fuel/energy handling, optional insurance and assignment-based drivers. Broaden geographic data and activities after the initial area works.

Keep `core.lua` coordinating these services. The existing `garage.lua` / `gamecar.lua` separation is a useful model: pure rules in one place, version-sensitive game operations in an adapter. Do not rewrite the full phone UI or refactor every module before the first shift is playable.

For employment, the saved states should distinguish offered, accepted, equipment preparation, pickup, delivery, returning and settled. Resume must reconcile the saved vehicle and load before timers advance. Cancellation and failed spawning must have explicit outcomes instead of falling through to normal settlement.

### Acceptance criteria

- Existing courier and freight progress survives migration, with a recoverable original checkpoint.
- A paused game, world loading or lost Earth connection does not run a job deadline or generate bills.
- Crossing a floating-origin boundary keeps the same workplace, destination and reasonable odometer reading.
- Reloading during pickup, loaded driving or return-to-yard resumes safely without duplicating cargo, charges or wages.
- An unsuitable vehicle or unvalidated truck stop cannot be accepted as if compatible.
- A candidate location with bad access can be reported and escaped without an unfair fee.
- A failed or delayed spawn restores the previous usable state; a delayed callback cannot settle a different job.
- The player can complete the two-delivery shift, understand gross versus net pay and spend the wages at the home garage.
- Discovery is cached and nonblocking; distant vehicles and businesses do not require spawned simulation.

Use focused pure-Lua checks for transactions, clock rules, migration, contract transitions and deduplication. Then test the vehicle/streaming transitions in BeamNG itself. This research task did not run those future tests.

## Sources and reproducibility

Primary sources accessed 11 November 2026. Public release claims and current-main code observations are distinguished above.

- **S1:** [BeamNG v0.35 release notes](https://beamng.com/game/news/patch/beamng-drive-v0-35/), Career Progression Overhaul.
- **S2:** [BeamNG v0.33 release notes](https://www.beamng.com/game/news/patch/beamng-drive-v0-33/), organizations, reputation, materials and loaners.
- **S3:** [BeamNG v0.38 release notes](https://www.beamng.com/game/news/patch/beamng-drive-v0-38/), insurance, negotiation and delivery changes.
- **S4:** [BeamNG news index](https://www.beamng.com/game/news/), current patch dates.
- **S5:** [RLS releases](https://github.com/RLS-Modding/rls_career_overhaul/releases), v2.8.0, and [current project README](https://github.com/RLS-Modding/rls_career_overhaul).
- **S6:** [RLS Jobs and Deliveries](https://github.com/RLS-Modding/rls_career_overhaul/wiki/Deliveries).
- **S7:** [RLS Businesses](https://github.com/RLS-Modding/rls_career_overhaul/wiki/Businesses).
- **S8:** [RLS Money and Progression](https://github.com/RLS-Modding/rls_career_overhaul/wiki/Reward-System).
- **S9:** [RLS Freeroam Events](https://github.com/RLS-Modding/rls_career_overhaul/wiki/Freeroam-Events) and [Insurance](https://github.com/RLS-Modding/rls_career_overhaul/wiki/Insurance).
- **S10:** RLS main snapshot `e701d9e2218ca12ff70ba4a09c0c91514e96e380`: [facilities](https://github.com/RLS-Modding/rls_career_overhaul/blob/e701d9e2218ca12ff70ba4a09c0c91514e96e380/lua/ge/extensions/overhaul/world/facilities.lua), [career session](https://github.com/RLS-Modding/rls_career_overhaul/blob/e701d9e2218ca12ff70ba4a09c0c91514e96e380/lua/ge/extensions/overhaul/career/career.lua), [employment](https://github.com/RLS-Modding/rls_career_overhaul/blob/e701d9e2218ca12ff70ba4a09c0c91514e96e380/lua/ge/extensions/overhaul/career/work/employment.lua), [independent contracts](https://github.com/RLS-Modding/rls_career_overhaul/blob/e701d9e2218ca12ff70ba4a09c0c91514e96e380/lua/ge/extensions/overhaul/career/logistics/ownerOpContracts.lua), [saves](https://github.com/RLS-Modding/rls_career_overhaul/blob/e701d9e2218ca12ff70ba4a09c0c91514e96e380/lua/ge/extensions/overhaul/career/saveSystem.lua).
- **S11:** [BeamNG facility format](https://documentation.beamng.com/modding/levels/level_formats/facilities/).
- **S12:** [Earth add-ons and modding API](https://github.com/TecnaGamer/BeamNG.Earth/blob/main/docs/ADDONS.md).
- **S13:** Earth main snapshot `e1c72abf66a42f6e877c3e1de8839352360913fc`: [API implementation](https://github.com/TecnaGamer/BeamNG.Earth/blob/e1c72abf66a42f6e877c3e1de8839352360913fc/mod/beamng_earth/lua/ge/extensions/beamngEarth/api.lua).

Use the reference projects for design and architectural learning. Any future source or asset reuse needs its own per-file check: RLS's [licensing document](https://github.com/RLS-Modding/rls_career_overhaul/blob/main/LICENSING.md) distinguishes scoped original AGPL code, BeamNG-derived bCDDL code and third-party components. This proposal requires no copied RLS code or assets.
