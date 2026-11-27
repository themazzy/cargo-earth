# Own trailers (part 1 of 3)

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
