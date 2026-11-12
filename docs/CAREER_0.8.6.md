# Cargo Earth 0.8.6

Changes since 0.8.0. None of them have been tested in game yet.

- **Simpler phone.** The phone keeps Work, Radio and Menu. Garage, Home, Companies, Progress, Finances, the delivery map,
  the firm and Settings open in a large Menu window. The bottom line shows fuel and range.
- **Radio through the game.** MP3 and OGG stations play in the game through the helper. AAC stations play in the
  helper's own Windows player, which now really starts and reports when sound plays. Saved stations keep playing after
  the country list goes stale.
- **Phone holder on the dash (VR).** The floating dash screen is gone. Settings → VR fits the Pigeon's phone holder part,
  which runs the full phone app and turns to face the driver. See [DASH_PHONE.md](DASH_PHONE.md).
- **Cheaper running costs.** Fuel costs a third of before and servicing half. Refuelling at the game's own pumps is
  booked in the career. See [CAREER_FUEL_PUMPS.md](CAREER_FUEL_PUMPS.md).
- **Repairs capped** at half of the car's parts value.
- **Tips** go only by speed and the order's condition. Customers no longer react to how the car was driven.
- **Update notice.** The phone says when a newer Cargo Earth release is out (the helper checks GitHub every 6 hours;
  `--no-update-check` turns it off).
- **Helper status page** at http://127.0.0.1:47820/, an "Open its page" button in BeamNG.Earth, and a clear message when
  the port is in use. Settings has **Copy support report**.
