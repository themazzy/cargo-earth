# Vehicle insurance

Issue #125. Jan's decisions (2026-11-23): one kind of cover with full protection, for the player's own cars only.
Hired drivers' cars and company vehicles are insured by someone else and are never covered or managed here.

Code: `lua/ge/extensions/cargoEarth/insurance.lua` (pure rules), hooks in `garage.lua` (repairs) and `core.lua`
(`M.insurance*`: samples, billing, the write-off window and the tow).

## Rules

| What | Value |
| --- | --- |
| Premium | 3 % of the car's value per insurance week (starts at 3 %, stays between 2 and 4 %) |
| Insurance week | 21 hours of play (Jan, 2026-11-23: was 7), billed an hour ahead, also while the car is parked |
| Buying | Garage → Insurance → Insure: only in your own car, standing still, with no job or orders. Covers at once |
| Claim | the real repair bill (from the game's damage) minus a 10 % deductible |
| Claim history | each claim adds 0.5 % to the rate for 3 hours of play (Jan, 2026-11-23); each claim-free week takes 0.25 % off the base rate |
| Reckless crash | top speed in the 2 s before the hit over the road limit by more than 15 km/h: covered half; more than 40 km/h over: refused |
| Limit that just dropped | the old limit still counts for 1.5 s plus the time to brake down to the new one at 4 m/s² (70 → 30: about 4.3 s) |
| Speed camera | a crash within 60 s after a camera flashed you: covered half |
| Unknown limit | no limit known on the road: no judgement, covered in full |
| Not covered | wear, servicing, faults the car came with, breakdowns, fuel |

- Hits within 3 s are one crash with one verdict. The phone says when a claim is cut or refused.
- Repair in the Garage, HQ workshop, or the game menu: the insurer pays its share. The Garage also offers
  "Pay it all yourself" to skip a claim and keep the rate.
- A game-menu repair still makes debt, but only the part the insurer doesn't pay.
- Unstuck waives the repair and makes no claim.
- **Write-off.** The repair reaches its cap (half the car's value) on an insured car. The phone then shows a window with
  a free tow home or to the HQ, or "Stay here". The tow teleports the car through BeamNG.Earth, and the bill stays
  owed even if the trip resets the car.
- A car that a hired driver takes over loses its insurance.
- Ending the insurance stops billing. Crashes it already covered can still be claimed.

Untested in game.
