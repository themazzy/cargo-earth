# Cargo Earth 0.8: the phone on the dashboard

Jan's ask on 12 November 2026: in cockpit view the phone should sit on the centre of the dash instead of taking a
corner of the screen.

## How it works

- In any camera inside the car (driver or passenger seats), the phone app leaves its corner and is drawn where the
  centre of the dashboard is: ahead of the driver's seat, below the eyes, most of the way to the middle of the car,
  turned toward the driver. It moves with the car, with your head and when you look around. Right-hand drive cars get
  it on their own side.
- It is the same phone: every screen and button works and is clicked with the mouse as before. Outside the car, in
  menus, photo mode or when the app is hidden, it goes back to its corner.
- Settings, Cockpit view: turn it on or off, move it (up, down, left, right, closer, further), make it bigger or
  smaller, reset. Every car model keeps its own place (`settings/cargoEarth/dash.json`). "Follows the car" sets how
  often it is moved: 15, 30 (default) or 60 times a second; fewer is lighter on the computer.
- VR: BeamNG shows the UI on a floating panel anchored to the room or your head, not to the car, so in VR the phone
  stays the floating phone.

## Inside

Nothing new is drawn in the 3D world: no mesh, texture, extra browser view or debug drawing. `cargoEarth/dash.lua`
places a phone-sized rectangle in the car each frame (driver camera node, vehicle axes, vehicle box centre), projects
its four corners with the game camera (position, axes, vertical field of view) and, at the chosen rate, sends the
corners to the UI with the hook `CargoEarthDash` (only when they moved). `app.js` moves the phone and its folded bar
to the page and bends it onto those corners with one CSS `matrix3d`, which also maps the mouse clicks.

The game is asked only for: `core_camera.isCameraInside`, `getDriverData`, `getPosition`, `getForward`, `getRight`,
`getUp`, `getFovRad`, `veh:getNodeAbsPositionXYZ`, `be:getObjectOOBBCenterXYZ`, `veh:getDirectionVector(Up)`
(BeamNG 0.40.5 Lua).

## Not tested in game yet

- How well the phone stays glued to the dash while driving fast or looking around (the UI is drawn a frame after the
  world, so it can trail slightly when you turn your head quickly).
- The default place in vans and trucks; use the Settings buttons and tell me what fits better.
- The phone is drawn over the steering wheel and your hands if they pass in front of it.
