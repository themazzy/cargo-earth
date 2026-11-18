# Career economy

The career is balanced so that each step up earns more an hour than the one before it. Figures are net CZK an hour
of one typical, clean job after fuel and upkeep, from `tools/career-economy.py --proposal` (the formulas there copy the
Lua pay rules; distances, speeds and fuel burn are estimates). Car prices follow food pay (`garage.scale`).

| Work | Needs | About CZK/h |
| --- | --- | --- |
| Food delivery | any own car | 500 |
| Taxi | own car with a passenger seat; a nicer car adds up to 45 % (`taxi.carRate`) | 550 |
| City bus line | nothing (lent bus) | 550 |
| Tow jobs | tow hitch (borrowed trailer 540, own car trailer 690) | 540-690 |
| Parts runs | own SUV or pickup | 580 |
| Company van contract | nothing (lent van) | 630 |
| Van freight / parcel routes | own van | 720 / 800 |
| Company box truck contract | 3 van hauls | 860 |
| Company tractor contract | 5 box truck hauls | 910 |
| Box truck freight | own box truck, 3 van hauls | 1,150 |
| Tractor freight | own tractor, 5 box truck hauls (firm trailer +12 %) | 1,370-1,580 |
| Fuel tanker runs | own tractor | 1,720 |

Hired drivers bring in, after wage, incidents and wear: about 100 CZK an hour in a car, 300 in a van, 500 in a box
truck and 900 in a tractor (x1.3 with the top dispatch office).

## The 2026-11-18 rebalance (issue #123)

Before it, a lent bus (about 800 CZK/h after the company's share) and taxi (about 700) out-earned the SUV, the van, the
box truck and every company contract, and a company truck earned 80-90 % of your own. Changes:

- Bus: base 60 -> 40, 7 -> 4.5 CZK a timetable minute, 2 -> 1.5 a rider.
- Taxi: 50 + 18/km -> 45 + 13/km; new nicer-car bonus (+15 % per doubling of the car's value above 10,000 CZK, at most +45 %).
- Parts runs: 70 + 10/km + 2/slot -> 110 + 16/km + 4/slot.
- Tow: empty legs with a borrowed trailer paid at the full rate (`BORROW_RATE` 0.5 -> 1).
- Parcel routes: 80 + 45 a stop -> 120 + 60 a stop.
- Van tier: 80 + 11/km -> 150 + 18/km. Box truck tier: 120 + 15/km -> 250 + 22/km. Tractor unchanged.
- Company contracts: you keep 65 % in a lent box truck or tractor (80 % in a van or bus).
- Fuel cargo pay factor 1.55 -> 1.15 (tanker runs).
- Unlocks: box trucks after 3 van hauls (was 5), tractors after 5 box truck hauls (was 10).

- Work vehicles cost a share of their value-based price (`garage.WORK_PRICE`): vans 0.5, box trucks and tractors 0.35,
  on the market, for the firm's new vehicles and in what a vehicle is worth (trade-in, sale, repair cap). Older
  market listings are repriced once (market v5). Cheapest used van about 1,800 CZK, tractor about 10,000.

With shorter unlocks and these prices the first own tractor comes after about 12 hours of play (about 7-8 h of
unlock hauls, then the rest of the money), and a used van pays for itself in about 8-10 hours.

## Experience pay

Every kind of work pays more the more of it you do (`experience.lua`). The bonus grows evenly with each finished job up to a
ceiling, and later-unlocked driving work has the higher ceilings, so the ladder keeps its order:

| Work | Ceiling | Jobs to reach it |
| --- | --- | --- |
| Food, taxi, parts runs | +10 % | 100 / 60 / 40 |
| Bus lines, parcel routes | +10 % | 30 |
| Tow jobs | +15 % | 30 |
| Vans (own or company) | +15 % | 40 |
| Box trucks | +20 % | 40 |
| Tractors | +25 % | 40 |

Your own jobs get it on the offer ("+X for your experience"). Company contracts and bus lines raise the driver's share of
the contract instead (never past the whole contract). The Progress page's Work types cards show the jobs done and the
current bonus. Taxi rides also keep the nicer-car bonus.
