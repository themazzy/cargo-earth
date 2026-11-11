# Cargo Earth code, network and storage review

Reviewed 11 November 2026, starting from build 0.3.0. Fixes are included in 0.3.1. The scope is Cargo Earth and its helper, including their Earth API integration points; this is not an audit of the whole BeamNG.Earth application or the game engine.

## Findings and fixes

| Priority | Finding | Change |
|---|---|---|
| High | A JSON file with a valid balance but broken nested vehicle/contract state was accepted as a save, potentially failing after vehicle restoration had begun. | Validate critical garage, home, account, job and contract structures before restoration. Recover a valid committed backup when available. |
| High | Checkpoint verification only compared a few top-level values, missing dropped nested data. | Compare the complete decoded snapshot, allowing small floating-point serialization differences. Writes still use BeamNG's atomic JSON function. |
| High | A saved, settled company contract could fail to return the personal vehicle while geographic indexes were unavailable. | Run company restoration independently of map-data readiness. Retried returns retain the existing payment identity. |
| High | HTTP Range replies and cached blocks were trusted without confirming byte counts. A server ignoring Range could make the helper read an entire large file. | Require matching partial-content headers before reading a range body, enforce expected length and cap ordinary responses. Reject incomplete blocks and repair short cached blocks. |
| Medium | Concurrent queries could fetch identical byte ranges. Remote reads also scheduled work recursively into the same shared executor. | Serialize cache misses per remote file; merge adjacent missing blocks into requests of at most 4 MiB. Independent remote files can still download concurrently. |
| Medium | Old area queues continued downloading after movement or teleport, while status records grew across a trip. | Keep queued work for the latest neighbourhood; remove obsolete queued/status entries. Up to two already-running area builds can finish. |
| Medium | Processed-cache corruption could be served repeatedly. | Validate area identity, release and nested row/coordinate types. Rebuild invalid cache entries rather than forwarding them to game Lua. |
| Medium | Geographic disk storage had no size policy. | Add a configurable 1 GiB soft cache budget, approximate least-recently-used retention, active-area protection and resolved-path checks before removal. |
| Medium | Delivered transaction IDs grew forever even though visible history was bounded. | Store replay protection as a monotonic watermark plus identities above the oldest unfinished payment. Preserve pending jobs and held wages. |
| Medium | Owner-operator saves duplicated the same garage, and the current order was saved twice. | Store one independent garage and a current-order ID; reconnect ownership on load. Keep separate personal/company garages when a company van is borrowed. |
| Medium | A helper release change could leave previously loaded addresses stale; evicting one area could remove a tile owned by a newer area. | Refresh on release/format changes and track streamed tile ownership. |
| Medium | Database connections were left open in some address/building and failure paths. | Close connections explicitly and cap each discovery query connection at 512 MB. |
| Low | Loaded neighbourhoods were polled every three seconds, including when stationary. | Use a 30-second idle local heartbeat; keep three-second polling while loading and refresh immediately after changing cells. |
| Low | Large socket reads and overlapping UI refreshes could create bursts of work. | Limit socket work to 512 KiB per helper tick and responses to roughly 8 MiB. Prevent overlapping page refreshes and poll a folded phone every two seconds. |
| Low | Contract generation repeatedly scanned the same candidates and searched beyond the five results displayed. | Add conservative geographic bounds, reuse destination sets and stop after five valid companies. |

The helper also rejects browser-origin/cross-host requests that could otherwise queue downloads despite being bound to loopback. It validates coordinate ranges before scheduling work. Its information endpoint includes process network counters and the last cache-budget result, without exposing the cache's filesystem path.

## Contract quality and measured work

The comparison uses the supplied Czech depot pack and isolated Lua code. It measures distance-function calls, not BeamNG frame rate or live network bandwidth.

| Check | Before | After |
|---|---:|---:|
| Distance calculations for the Prague company board | 49,552 | 1,037 |
| Companies returned there | 5 | 5 |
| Sparse fixture with two reachable recipients | 1 company | 1 company |
| Sparse fixture with only one reachable recipient | 0 companies | 0 companies |

The final Prague case performs about 97.9% fewer exact distance calculations. The improvement comes from avoiding repeated calculations and rejecting geometrically impossible candidates cheaply, rather than lowering the number of valid contracts sought. Exact distance and cargo checks still determine eligibility.

The existing search rules remain: yards within 25 km, deliveries of 1–20 estimated road km, up to sixteen nearby candidate yards, two compatible deliveries per company and five companies displayed. The first five valid nearby companies are still the output. Spherical bounds include special handling for polar routes and the date line; those cases are covered by checks.

This does not prove equal gameplay quality everywhere. A sparse area can fail to produce a two-delivery contract under the existing distance limits. The helper's currently loaded neighbourhood also constrains discoverable workplaces. Widening those rules would be a separate balance/discovery change, with longer drives and more data loading; it was not hidden inside this optimization.

## What the cache budget means

1 GiB is 1,073,741,824 bytes, or 1,024 MiB. Geographic source files are cached in 64 KiB blocks, so the budget could hold 16,384 full blocks if nothing else shared it. Processed area JSON shares the budget, reducing the space available for blocks.

Examples of arithmetic, not measured town coverage:

| Stored data mix | Approximate capacity in 1 GiB |
|---|---:|
| Only 64 KiB source blocks | 16,384 blocks |
| Only hypothetical 1 MiB processed areas | 1,024 areas |
| 256 MiB of processed areas, remainder source blocks | 12,288 full blocks |

One processed area spans 0.1 degrees in each direction, roughly 11 km north/south and 7–8 km east/west in Czechia/Bulgaria. The helper requests the surrounding 3-by-3 neighbourhood. Dense cities, rural areas, source columns and Parquet row groups have different costs, so a fixed number of towns or driving kilometres cannot be promised. Source chunks can include records outside the requested geographic box.

The budget is a storage policy, not a maximum amount of internet traffic. A larger cache can save repeat downloads on revisits; a smaller cache evicts useful source blocks sooner. A first visit still requires data transfer. The 30-second heartbeat reduces local Lua-to-helper polling; it should not be presented as a 90% reduction in total internet downloads.

Pruning checks run at startup, after completed area builds and through background housekeeping, at most once every five minutes. Active neighbourhood JSON is pinned; newly written or recently touched files have a thirty-second grace period to protect working reads. In-flight work and the delay between checks can exceed the target temporarily. File-index metadata and transient atomic-write files are not counted. The cleanup considers only block and area cache files and verifies that each resolved deletion path remains inside the selected cache root.

## Where data lives

Game paths below are relative to the active BeamNG user profile or the mounted mod, not this source checkout.

| Data | Location | Contents and retention |
|---|---|---|
| Career state | `settings/cargoEarth/career.json` | Money, home address/geographic parking point, vehicle configurations, parked cars, debt, employer progress, active contracts/orders and play-time counters. Persistent. |
| Previous checkpoints | Same path with `.backup1` and `.backup2` | Two prior committed snapshots. Recoverable. |
| Original older-format save | Same path with `.legacy` | Preserved older-schema snapshot where one does not already exist. Not overwritten each save. |
| Staging and atomic files | `.pending`, plus temporary files produced by the atomic writer | Not considered committed saves during recovery. |
| Settings | `settings/cargoEarth/config.json`; per-career options also in the save | Helper port/enabled setting, vehicle options, job preferences and current career options. |
| Delivery history | Inside the career JSON | Most recent 50 delivery records; aggregate progression is separate. |
| Money history | Inside the career JSON | Most recent 100 entries; the phone receives at most twenty. Older duplicate-payment protection is compacted separately. |
| Employer progress | Inside the career JSON | Retained for visited employers; not deleted with geographic cache entries. |
| Bundled fallback geography | `lua/ge/extensions/cargoEarth/data/` in the installed mod | Czech depots, restaurants and address tiles. Read-only mod assets, outside the helper budget. |
| Processed nearby geography | `<helper-cache>/areas/<release>/3/<row>_<col>.json` | Restaurants, grocers, candidate workplaces and customer addresses. Replaceable cached public data. |
| Downloaded file chunks | `<helper-cache>/blocks/<URL-hash>/<block>.blk` | Reusable 64 KiB chunks of public Parquet files. Replaceable cached public data. |
| File coverage indexes | `<helper-cache>/index/<release>/*.json` | Dataset filenames, geographic bounds and sizes. Small metadata, outside the block/area budget. |

The helper-cache default is `cache` beside the helper script. `--cache` or `BNE_CARGO_CACHE` overrides it; `--cache-mb` changes the budget. The game's save directory is independent of that choice. This budget does not cap BeamNG.Earth's own terrain and satellite-image cache.

The existing fallback JSON totals **54,782,410 bytes (about 52.2 MiB)** across **4,032 files**: 621,808 bytes of depot data, 2,367,195 bytes of restaurant data and 51,793,407 bytes of address tiles. These figures describe the current bundled data, not the size of the world's source dataset or an estimate of live cache coverage.

In-memory geographic caches remain bounded by the existing 25 streamed food areas, 25 streamed workplace areas and 48 bundled address tiles. Accepted orders retain their endpoint snapshots outside those discovery caches. The selected home point is saved separately. Evicting public geographic data therefore does not delete the home garage or an accepted contract.

## Storage and network boundaries

Career JSON is ordinary local text, including the selected home address/coordinates; it is not encrypted. Cargo Earth implements no cloud-save upload. Player coordinates go from game Lua to the helper over loopback. The inspected external helper requests retrieve public Overture source files and indexes; they do not post the career save or an exact-position field to a custom service. BeamNG.Earth's own services and traffic are outside this audit.

Save schema 3 is necessary because compact replay protection has new semantics. Supported older saves migrate; older Cargo Earth versions refuse schema 3 instead of loading it incorrectly. The complete read-back verification adds work per checkpoint, deliberately preserving durability rather than weakening it for a smaller disk-write count.

## Checks and remaining limits

Passed: 25 career scenarios, five helper-client scenarios, sixteen Python helper scenarios, phone structure/Unicode/polling/backpressure/teardown checks and the real depot-pack smoke test. Checks include interrupted settlement, independent-car save/resume, malformed snapshots, dropped nested fields, cache corruption, duplicate range reads, stale queues, invalid coordinates, cache deletion boundaries, sparse destinations, polar/date-line bounds and helper release changes.

Lua checks use Fengari/Lua 5.3 and isolated game adapters. Python network checks use controlled HTTP fixtures. No native driving session, live Overture download or end-to-end bandwidth measurement was performed. Actual FPS, live query latency, native bridge behaviour and long-session disk use remain to be measured in BeamNG. Public POI coordinates remain candidate stops rather than certified loading bays.
