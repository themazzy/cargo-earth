# Cargo Earth 0.3.3

Parts checkout recovery update. Includes the 0.3.2 phone navigation and earlier career fixes. Helper remains 0.3.1 and save schema remains 3.

## Installation and recovery

Exit BeamNG, replace the previous Cargo Earth ZIP with `cargo_earth_career_0.3.3.zip`, and leave only one Cargo Earth version enabled. Restart and resume the career. Resume uses the saved vehicle configuration; it does not require resetting the career. Unconfirmed parts must be selected again if they were not committed to that save. This update does not attempt to retroactively price equipment already recorded by an older version.

## Parts flow

Choose parts in BeamNG Vehicle Config. Apply/live updates preview them on the vehicle. Leave the editor and open phone Garage. Review the item list and total, then buy/keep the changes or discard the preview to restore the paid configuration. Closing Vehicle Config alone does not complete a purchase. Driving away with an open checkout restores the paid configuration without charging for the preview.

## Fixes

- Garage shows loading, error, retry and a fallback discard action instead of staying empty after a failed response.
- Page requests recover after a five-second missing-callback timeout; stale replies cannot replace newer results. Lua page/action errors are returned to the phone as error data.
- Pricing exceptions preserve the checkout and discard action. Unpriceable newly installed parts remain unpurchasable rather than being accepted free.
- Empty/false slot entries and non-text metadata names no longer crash the quote. Unresolved non-string slot entries return an explicit waiting/error result.
- A native Apply notification arriving after a live configuration change retains the recorded paid snapshot as the pricing/rollback baseline.
- Failed purchase checkpoints restore balance, inventory and saved configuration and keep checkout retryable.
- Unconfirmed equipment is restored when driving outside the parts editor. Blocked-preview rollback also handles a missing retry timestamp.

## Verification

Passed 32 career scenarios, five helper-client scenarios, the supplied Czech depot smoke check and phone navigation/request/error/timeout/teardown checks. Six new career scenarios cover native editing and payment, pricing failure and discard, unknown parts and retry, driving away, late Apply hooks and failed purchase saves. Tests use isolated game adapters; native visual verification was not performed. The original exception was not identifiable in the retained game log, so these checks verify the corrected failure/recovery paths rather than claim an exact replay of that session.
