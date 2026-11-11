# Payout statistics for Cargo Earth 0.3.5

Calculated from the real Lua modules and bundled Czech cargo/depot pack. Reproduce with `node tools/payout-stats.cjs` (Fengari dependency or FENGARI_PATH). No game save was read or modified. These are formula-based scenarios, not measured driving results.

## Findings

- Biggest supported native-freight payout: a 250 road km fuel haul pays **10,340 CZK** before damage/late/repair/debt effects. Fuel requires articulated-truck progression, tanker/ADR-compatible jobs and suitable endpoints. This is an eligible formula example, not a guarantee a matching route appears at your location.
- Best modeled short-session courier work: nearby groceries, then family meals, then standard meals. The fixed 80/40 CZK size bonuses favour short routes. Groceries need four free slots in one box and helper-discovered stores; family meals need two.
- Since 0.3.5 the company also pays the empty drive back to the yard after each delivery, and the driver keeps 80%. Twenty-five actual generated company offers at five Czech locations model at **285–506 CZK/h**, median **377 CZK/h**. Company work now pays close to courier work, with repairs covered.
- Independent company contracts pay **25% more** than the same company-van manifest before personal repair expenses, but retain the same backtracking. Regular freight generally uses time better if a useful next job exists near its destination.
- The largest catalog multipliers are not all usable: heavy machinery is 1.8× and LPG 1.65× plus ADR, but the current native allocator does not support those cargo IDs. Do not rank them as presently playable native jobs.

## Modeling assumptions

Courier average: 24 km/h; van 40, rigid 50 and articulated 55 km/h; company routes 35 km/h. Initial pickup is 0.5 straight km, expanded to road distance using the relevant Lua factor (food 1.35, freight 1.3). Extra handling: 1 minute per courier order, 3 minutes per ordinary freight job and 8 minutes per two-job company shift. Ordinary jobs also include 19 seconds average offer wait, excluding it from tip timing. These handling/wait values are modeling assumptions, not fixed in-game loading timers. Setup, vehicle acquisition, searching/declining offers, detours, coupling delays beyond the allowance, repairs and debt repayment are excluded. Company examples include every required return and wages are unavailable until the shift ends.

Use the hourly figures as clean-run comparisons. Ordinary freight one-way rates assume another useful nearby pickup; the return-loop column shows the result if you must drive empty all the way back. Company return travel is already included. Displayed deadlines include slack and are not predicted completion times. No fixed fuel-per-km expense is implemented in the inspected payment code; do not confuse these rates with a complete simulated operating-profit model.

## Short courier work

| Order | Delivery road km | Payout incl. modeled tip, CZK | Modeled minutes | CZK/h |
| --- | --- | --- | --- | --- |
| Meal | 2 | 75 | 8 | 562 |
| Family meal | 2 | 115 | 8 | 862 |
| Groceries | 2 | 155 | 8 | 1,162 |
| Meal | 6.8 | 145 | 19.9 | 438 |
| Family meal | 6.8 | 185 | 19.9 | 558 |
| Groceries | 6.8 | 225 | 19.9 | 679 |

Near-identical pickup, destination and driving time make groceries about twice the standard-meal pay at 2 road km. Moving from 2 to 6.75 road km increases the payout but lowers the modeled hourly return. Pickup kilometres below 3 straight km receive no extra pay. Beyond 3 km, only 8 CZK per additional straight kilometre is added, rounded to 5 CZK; avoid long pickup drives unless you also want to relocate.

## Ordinary freight

| Vehicle / cargo | Delivery road km | Payout, CZK | One-way minutes | One-way CZK/h | With empty return CZK/h |
| --- | --- | --- | --- | --- | --- |
| van / pallets_general | 10 | 190 | 19.3 | 591 | 332 |
| rigid / pallets_general | 30 | 570 | 40.1 | 853 | 449 |
| semi / pallets_general | 50 | 1,400 | 58.6 | 1,434 | 743 |
| semi / fuel | 20 | 1,320 | 25.8 | 3,065 | 1,662 |
| semi / fuel | 50 | 2,495 | 58.6 | 2,556 | 1,323 |
| semi / fuel | 100 | 4,455 | 113.1 | 2,363 | 1,203 |
| semi / fuel | 250 | 10,340 | 276.8 | 2,242 | 1,129 |

Since 0.3.5 articulated trucks have a 300 CZK base and 22 CZK/km, rigid trucks 120 CZK and 15 CZK/km, vans 80 CZK and 11 CZK/km. Short fuel runs remain the best paid work because of fuel's pay factor and the ADR bonus. Rigid unlocks after 5 van hauls; articulated unlocks after a further 10 rigid hauls. The existing loaner system can provide the appropriate vehicle. Reliable endpoints and compatible trailers still constrain availability.

## Company shifts

Each example has two equally long deliveries from the same yard, with both returns included. Initial approach is 0.5 straight km.

| Contract | Each loaded leg, road km | Full-shift payout, CZK | Full-shift minutes | CZK/h |
| --- | --- | --- | --- | --- |
| Company van | 1 | 160 | 16 | 601 |
| Own van contract | 1 | 200 | 16 | 751 |
| Company van | 3 | 240 | 29.7 | 485 |
| Own van contract | 3 | 300 | 29.7 | 606 |
| Company van | 5 | 304 | 43.4 | 420 |
| Own van contract | 5 | 380 | 43.4 | 525 |
| Company van | 10 | 480 | 77.7 | 371 |
| Own van contract | 10 | 600 | 77.7 | 463 |
| Company van | 20 | 832 | 146.3 | 341 |
| Own van contract | 20 | 1,040 | 146.3 | 427 |

The shortest company model (two 1 km deliveries) returns 160 CZK in 16 minutes. A ten-minute session is therefore better suited to short courier work than a company shift. The generated board sample below has substantially longer routes; do not mistake the synthetic minimum for the typical available contract.

### Actual generated board sample

Fixed city-centre positions: Prague, Brno, Ostrava, Mikulov and Jicin; deterministic board generation; first five displayed offers per position. Payouts and endpoints come from the supplied pack, while times remain modeled.

| Location | Offers | Min–max full-shift payout, CZK | Min–max modeled minutes | Min–max CZK/h |
| --- | --- | --- | --- | --- |
| Prague | 5 | 424–888 | 70.6–133.3 | 360–420 |
| Brno | 5 | 364–704 | 51.9–110.2 | 383–426 |
| Ostrava | 5 | 564–644 | 86.5–101.9 | 365–432 |
| Mikulov | 5 | 596–816 | 120.9–148.3 | 285–342 |
| Jicin | 5 | 264–884 | 31.3–157.8 | 314–506 |

## Cargo ranking at equal distance

Multipliers are comparisons within a vehicle tier, not across different vehicles. All supported parcel cargo is available to the van allocator: glassware 1.45×, electronics 1.40×, car parts 1.20×, furniture/beer 1.10×, consumer goods/dry food 1.05×, general pallets 1.00×, bricks 0.95×. Glassware/electronics have fragile handling. Car parts pay more than general goods and use sturdy handling. Supported bulk gravel/sand are lowest at 0.75×. Supported fuel is 1.55× plus 15% ADR = **1.7825×**; chemicals are **1.725×**. Ordinary helper-only geography currently supplies general goods, so these richer cargo choices depend on the depot pack and available endpoints.

Current limitation: fluid/bulk cargo condition is not tracked by the parcel-damage rules. Fuel's current high income is therefore not balanced by a corresponding fluid-cargo crash penalty, though vehicle damage/repair costs still exist. That is a balance gap, not evidence of safer cargo.

## Batching, tips and risk

Second courier orders receive 85% of their base/far-pickup payment, rounded to 5 CZK; the full family/grocery size bonus is preserved. A close extra stop can improve income, but both order timers keep running. The discount does not guarantee better hourly pay if the second route adds a long detour.

Tips can reach 25% only at an instantaneous theoretical delivery. They decrease to zero at 70% of the allowed time. The baseline city-speed examples above have zero modeled tips; do not add a flat 25% to every quote.

| Cargo condition | Food base pay on 1,000 CZK order | Parcel pay on 1,000 CZK order |
| --- | --- | --- |
| 100% | 1000 | 1000 |
| 75% | 900 | 750 |
| 50% | 800 | 500 |
| 25% | 700 | 250 |
| 0% | 0 | 0 |

At zero condition, the load fails and earns nothing, despite food's nonzero formula floor before failure. Food tips also scale with remaining condition. Lateness takes 5% of food pay or 2% of freight pay per minute, with a 50% lateness floor. It combines multiplicatively with condition penalties. Company wages are then 65% of the adjusted delivery revenue. Existing debt can divert up to 50% of earnings to repayment; that is debt reduction, not lost value.

## Drivers and session length

Each driver earns **45 CZK per 10 active minutes**, or **270 CZK per active hour**, alongside your driving. Hiring costs 350 CZK; cash payments recover that fee after eight shifts (**80 active minutes**), excluding the cost of the extra owned car. Hiring unlocks at 30 completed deliveries. A home with capacity three leaves room for at most two parked driver cars while you use another. In company work, fleet advancement currently runs on the temporary company garage, so personal parked drivers do not earn during that borrowed-van shift. Paused, closed-game and parts-preview time does not count.

- **About 10 minutes:** short grocery/family deliveries near your car; standard meals if using the starter bag.
- **15–45 minutes:** clustered courier jobs; a nearby regular van/rigid haul or short articulated run once unlocked. Accept a company shift only after checking its full return distance.
- **An hour or more:** short/mid-distance articulated freight gives strong modeled earnings; long routes favour one large payout and travelling elsewhere, rather than maximum income per minute.
- **Several active hours:** combine eligible fleet drivers with your own paid work. Company shifts pay close to courier work and build employer reputation.

0.3.5 rebalanced trucking (about 1,250-1,700 CZK/h for general semi freight instead of 3,500+) and company contracts (return km paid, 80% share). CSV files and statistics.json retain all 215 calculated rows for inspection.
