# Cargo Earth 0.8: a phone screen on the dashboard for VR

Jan's ask on 12 November 2026: a phone on the centre of the dash. On a monitor the normal phone app stays as it is.
In VR, BeamNG shows the whole UI on a floating panel anchored to the room or your head, not to the car, so the panel
phone can never sit on the dash. The mod therefore puts a small phone screen in the 3D world for VR.

(A first try drew the UI phone in perspective over the dash on a monitor. Jan found it not usable, and it could not
work in VR, so it was dropped.)

## How it works

- In VR, in any camera inside the car, a phone screen sits at the centre of the dash: ahead of the driver's seat,
  below the eyes, most of the way to the middle of the car. It always faces your head and moves with the car.
  Right-hand drive cars get it on their own side.
- It shows what you need while driving: pick up or drop off, the place, the distance, time left and pay; an incoming
  order with its countdown and pay; online/offline and today's earnings; the speed limit sign, the clock and money.
- It has buttons at the bottom, pressed like the car's own cockpit buttons (doors, lights, parking brake): point a
  VR controller at one and pull the trigger. On a monitor (show "Always") they can be clicked with the mouse. The
  buttons follow the phone: Decline / Accept for a new order, Route while driving to a stop, OK after a delivery,
  Go online / Go offline when idle, Resume for a saved career. Cancelling an order stays on the normal phone, so it
  cannot be hit by accident.
- Settings, VR: "Screen on the dashboard" switches between VR (default), Always (also on a monitor, handy to check
  the place without the headset) and Off. In the cockpit you can move it (up, down, left, right, closer, further),
  make it bigger or smaller, or put it back. Every car model keeps its own place (`settings/cargoEarth/dash.json`).

## Inside

`cargoEarth/dash.lua` uses the engine's Skia billboards (`WorldBillboardRenderer`), the same path the game uses for
multiplayer name tags and world icons: no browser view, no mesh, no per-frame drawing in Lua. Each frame only the
billboard's position is set (driver camera node, vehicle axes, vehicle box centre). The picture is a Skia template
(boxes and text with flex layout) built from `phoneState()`, and it is re-rasterized only when its text changes, at
most once a second. Text uses the game's own label font (from its icon marker config).

The buttons (`cargoEarth/dashtap.lua`) use the game's vehicle interaction system. While the screen is shown, the
player's car gets two extra trigger boxes (`veh:addTrigger()`, set up with the same calls the jbeam loader uses for
cockpit triggers) over the left and right halves of the button row, framed on the car's reference nodes. They are
linked to two small input actions in the car's data (`cargoEarthDash1`, `cargoEarthDash2`, run in game Lua), so the
game's own pointer, highlight, hover label and VR controller trigger all work on them. Pressing one calls
`cargoEarth_core.dashTap(slot)`, which reads the phone again and does what that button shows at that moment. The boxes
are placed again only when the screen moves or the car is reloaded; when the screen is hidden they shrink to nothing.

## Not tested in game yet

- The buttons: that the added trigger boxes land on the drawn buttons, that the VR controller laser and trigger press
  them, and that the game's hover label shows the button's name.

- That the billboard shows in VR inside the cabin and is not hidden by the dashboard (move it up if it is).
- The template details (font, rounded boxes, text shrinking) as BeamNG's Skia renderer draws them.
- Default place and size in vans and trucks.
