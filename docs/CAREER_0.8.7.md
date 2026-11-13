# Cargo Earth 0.8.7

Changes since 0.8.6. None of them have been tested in game yet.

- **Phone on the dash of any car.** Settings → VR → "Phone on the dashboard" fits a phone holder to whatever car you
  drive, not only the Pigeon. The spot is measured from the driver's seat and the dashboard, and each car model keeps
  its own spot. Up/down, closer/further and left/right buttons move it 1 cm at a time, and "Measure this car again"
  starts over. The click boxes now sit on the screen. See [DASH_PHONE.md](DASH_PHONE.md).
- **Menu window.** The Menu has its own game UI app, "Cargo Earth: Menu", so it opens as a large window even when you
  use the dash phone.
- **Radio responds faster.** Play, stop and volume reach the helper straight away instead of waiting in the queue.
- **Smoother game.** The phone asks the game for updates less often and skips unchanged ones, animations stop after a
  few cycles, and saves are smaller.
