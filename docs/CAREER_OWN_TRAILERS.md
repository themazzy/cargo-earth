# Own trailers (parts 1 to 3)

Jan, 2026-11-27: owning trailers is the core of freight. Decisions:

1. Stock BeamNG loads may be used as cargo too (part 2).
2. No hiring a trailer for your own jobs. A company contract still hands you the company's tractor and trailer.
3. Trailers need a home. The basic home has one trailer spot.
4. You choose the amount on the offer and can change it at the pickup.
5. Pay follows the load: a fixed part for the trip, plus a distance part scaled by how full you load.

## What part 1 adds

- **Trailer pool** (`trailerpool.lua`, rules only). It is one pool, shared with your hired drivers.
  - Catalogue: box trailer 28/48/53 ft, flatbed 48 ft (cargo boxes, or two cars for tow jobs), fuel tanker and short fuel tanker, car trailer, small car trailer. Every entry is a stock model and config from BeamNG 0.40.
  - The 48 and 53 ft box trailers can be taken out with 16 aggregate boxes instead of cargo boxes, for dry bulk.
- **Spots.**
  - Home steps give 1 / 2 / 3 / 5 trailer spots.
  - The new **Trailer yard** room (1,500) adds 2 more.
  - The headquarters yard holds 6.
  - You can only buy a trailer when there is a free spot for it.
- **Garage → Trailers** on the phone.
  - **Take out**: at home or at the headquarters. The trailer is spawned behind you and put on your hitch.
  - **Park it here** returns it to its spot.
  - **Hitch** couples it again.
  - **Bring it home**: a trailer you leave anywhere is stored there. You can fetch it yourself (drive within 150 m and press Take out), or pay to have it brought home.
- **Buying.**
  - New trailers come from the factory.
  - Used trailers are listed at real yards near you, with km, condition, worn tyres or brakes and body damage, for 40–95 % of the new price. A used trailer you buy waits at the seller.
- **Upkeep like cars.** Tyres and brakes wear with the km you drive, and a trailer can break down if its service is overdue. Crash damage becomes a repair bill (capped at half the trailer's value). You can repair it parked at home or at the headquarters.
- **Freight board.** Your own tractor only gets jobs that fit the trailer on your hitch. A tanker gets fuel, chemicals, LPG and fuel-station resupply; a box trailer gets parcels, or dry bulk when it was taken out with bulk boxes. Without a trailer on the hitch there are no tractor jobs, and the phone says why.
- **Load picker.** − / + / Full on the offer and at the pickup, in steps of one box, one bulk box or 1,000 L.
- **Pay** = (base + rate × km × (0.4 + 0.6 × fill)) × cargo factor (× 1.15 for dangerous goods).
  - fill is the share of the class's weight limit or of its space, whichever is higher.
  - Above a full load for the class, fill counts at half the rate, up to 1.3.
  - A full 48 ft box pays the old distance pay. A half load pays about 70 % of the distance part. A 53 ft box or a big tanker earns more, and a 28 ft box earns less.
  - Van and box truck pay use the same formula, so a light load pays a little less than before.
- **Hired tractor drivers** take one of your trailers parked at home or at the headquarters, and it wears with their km. The firm no longer sells trailers; old firm trailers move into the pool at the headquarters.
- The +12 % firm-trailer bonus is gone (owning the trailer is now the requirement).

Not yet tested in game: spawning the configs (box layouts, aggregate boxes), the hitch, damage readings, and loading a pool trailer at the pickup.

## What part 2 adds

- **Stock loads as cargo** (decision 1). Coils, pipes, planks, marble, logs, hay bales and shipping containers are BeamNG's own load parts, not cargo containers. A job for one swaps your trailer, at the pickup, to the stock config that has the load on it (for example `flatbed/48ft_coil.pc`), spawned again behind you and put back on the hitch. At the drop it is swapped back to the empty config. The load picker steps through the stock loads, lightest first (3 coils or 2 big coils; 8, 12 or 16 logs). A container's stock Load Weight tuning value is the amount, in 2 t steps.
  - Flatbed 48 ft: steel coils, steel pipes, planks (and its boxes).
  - New: Flatbed 53 ft (coils, pipes, planks) and Flatbed 32 ft (a coil, a marble block, pipes, planks).
  - New: Log trailer 40 ft (logs, about 820 kg each), Container chassis 40 ft and 20 ft (containers).
  - Pay for a stock load goes by its weight: fill = kg / the class's weight limit.
- **Insulated box (reefer)**, the EU 3-axle box with 18 Cargo Box XL. Chilled food is only offered to it (no other trailer, van or box truck gets it). On your own trailers, the chilled special only rolls on the reefer or the food tanker, and oversize only on a flatbed.
- **Food tanker**, the EU milk tanker (22,500 L): milk. The fuel tanker takes no milk and the food tanker no fuel.
- **Trailers behind a car, SUV, van or box truck.** With one of your hitch trailers coupled, the board is the trailer's (class "Car and trailer": 8 t reference load, base 150, 14 CZK per km, fuel allowance 4 CZK per km, available from the start):
  - Tilt decks: the car trailer (22 ft) takes hay, the new 30 ft tilt deck hay, the new 40 ft tilt deck planks.
  - **Home deliveries** with the new utility trailer, large utility trailer and enclosed cargo trailer: a store near you sends a sofa, two armchairs or planks to a real address 1.5 to 8 km away. Pay 180 + 16 CZK per road km, at least 300. Stores whose names sound like furniture or building supplies are asked first.
- **Fill up the rest.** At the pickup, before loading, a box load of your own (box trailer, reefer, or flatbed with boxes) with room left shows up to three extra consignments of the same cargo to other workplaces on the way (at most 15 % detour). Each is a stop before the main drop, at most two per job. A fill-up pays its own load part (rate × km × 0.6 × its fill) plus a 100 CZK stop fee, so a light main load plus fill-ups pays about like a full load. Once one is booked, the amount stays.
- Catalogue: farms now also ship logs and hay; factories and industrial estates take lumber; concrete works and industrial estates take stone blocks.
- Garage → Trailers shows what each trailer carries and what is loaded on it.

Not yet tested in game (part 2): spawning the loaded stock configs and the swap back to empty, the 16-log config, the container Load Weight, the EU box and tanker configs (their cargo box and tank parts), the tilt deck and utility trailer configs, and the hitch after a swap.

## What part 3 adds

- **Drawbar trailers for box trucks.** New: Drawbar box trailer (EU 2-axle, 10 Cargo Box XL, 9 t) and Drawbar flatbed (10 boxes, or steel pipes 10 t or planks 8.4 t as stock loads). They need a box truck with a pintle hook: a part named "pintle" on the truck, and the game's couplers decide in the end. With one coupled, the box truck's board is the trailer's (class "Box truck and trailer": 9 t reference load, base 250, 22 CZK per km, fuel allowance 11 CZK per km, open with the box truck). The load goes in the trailer.
- **Hired drivers' pay by trailer family.** A tractor driver takes the best-paying free trailer parked at home or at the headquarters: box 1.0, log 1.05, flatbed and container 1.1, reefer and food tanker 1.15, fuel tanker 1.2 times the shift's pay. A box truck driver takes a free drawbar trailer when there is one and earns 1.45 times as much with it. That trailer wears with the driver's km.
- **The tipper stays out.** The frameless dump has no native cargo container and its Additional Modification slot is empty in every stock config, so dry bulk keeps using the 16 aggregate boxes in a box trailer.
- **Doubles (two trailers on a dolly)** are left for later: they chain four vehicles and load two trailers at once, on top of the hitch and swap code that has not been run in game yet.

Not yet tested in game (part 3): whether the stock box trucks have a pintle hook, the drawbar trailers' configs and their hitch.
