-- Stop rings sit on the ground under trees, pylons and roofs, and the stop zone is a short column (issue #118).
local saved = { castRayStatic = castRayStatic, vec3 = vec3, ColorF = ColorF, ColorI = ColorI, String = String,
  debugDrawer = debugDrawer, map = map, earth = package.loaded['cargoEarth/earth'], marker = package.loaded['cargoEarth/marker'] }
local ground, surfaces
ground = function(x, y) return 100 + 0.08 * x + 0.03 * y end
-- every surface at x, y: the sloped ground, a building over the address (roof 12 m up), a tree crown at the
-- ring's east edge and a power pylon on its north edge
surfaces = function(x, y)
  local g = ground(x, y)
  local list = { g }
  if math.abs(x) < 6 and math.abs(y) < 6 then list[#list + 1] = g + 12 end
  if (x - 30)^2 + y^2 < 25 then list[#list + 1] = g + 7; list[#list + 1] = g + 10 end
  if x^2 + (y - 30)^2 < 9 then list[#list + 1] = g + 2.5; list[#list + 1] = g + 6; list[#list + 1] = g + 20 end
  return list
end
vec3 = function(x, y, z) return { x = x, y = y, z = z } end
castRayStatic = function(o, _, len)
  local best
  for _, z in ipairs(surfaces(o.x, o.y)) do
    if z <= o.z and o.z - z <= len and (not best or z > best) then best = z end
  end
  return best and (o.z - best) or len
end
ColorF = function(...) return { ... } end
ColorI, String = ColorF, function(s) return s end
local lines, tris = 0, 0
debugDrawer = { drawLineInstance = function() lines = lines + 1 end, drawTriSolid = function() tris = tris + 1 end,
  drawTextAdvanced = function() end, drawCylinder = function() end }
map = nil
package.loaded['cargoEarth/earth'] = { worldXY = function(_, g) return g.x, g.y end }
package.loaded['cargoEarth/marker'] = nil
local marker = require('cargoEarth/marker')

local stop = { g = { 50, 14, x = 0, y = 0 } }
local p = { lat = 50, lon = 14, x = 10, y = 0, z = ground(10, 0) + 0.8, anchorLat = 50, anchorLon = 14 }
marker.draw(p, stop, 'delivery', true, 30, false, 0)
assert(lines == 20 and tris == 40, 'the ring is drawn')

-- the ring follows the ground, not the roof over the address, the tree crown or the pylon
marker.reset()
local outer
local real = debugDrawer.drawLineInstance
debugDrawer.drawLineInstance = function(_, a) outer = outer or {}; outer[#outer + 1] = a end
marker.draw(p, stop, 'delivery', true, 30, false, 0)
debugDrawer.drawLineInstance = real
for _, pt in ipairs(outer) do
  assert(math.abs(pt.z - ground(pt.x, pt.y) - 0.18) < 0.05,
    string.format('ring point at %.1f, %.1f floats %.2f m above the ground', pt.x, pt.y, pt.z - ground(pt.x, pt.y)))
end

-- the zone is a column a few metres tall around the ground of the ring (it follows the slope)
local gap = marker.heightGap(p, stop)
assert(gap and math.abs(gap - 0.8) < 0.05, 'a car on the ground is level with the stop: ' .. tostring(gap))
assert(not marker.offLevel(p, stop), 'a car at the stop counts')
local far = { lat = 50, lon = 14, x = -25, y = 10, z = ground(-25, 10) + 1, anchorLat = 50, anchorLon = 14 }
assert(not marker.offLevel(far, stop), 'the slope across the ring is allowed for')
local bridge = { lat = 50, lon = 14, x = 5, y = 0, z = ground(5, 0) + 7, anchorLat = 50, anchorLon = 14 }
assert(marker.offLevel(bridge, stop), 'a bridge over the stop does not count')
local under = { lat = 50, lon = 14, x = 5, y = 0, z = ground(5, 0) - 6, anchorLat = 50, anchorLon = 14 }
assert(marker.offLevel(under, stop), 'a road under the stop does not count')
assert(marker.heightGap(p, { g = { 50, 14, x = 1, y = 1 } }) == nil, 'another stop has no height yet')

-- a steep street (15 %): the first ring point is a whole radius from the centre, and a sloping depot yard
ground = function(x, y) return 100 + 0.15 * x end
surfaces = function(x, y) return { ground(x, y), ground(x, y) + 9 } end
marker.reset()
outer = nil
debugDrawer.drawLineInstance = function(_, a) outer = outer or {}; outer[#outer + 1] = a end
local steep = { lat = 50, lon = 14, x = 0, y = 5, z = ground(0, 5) + 0.8, anchorLat = 50, anchorLon = 14 }
marker.draw(steep, stop, 'delivery', true, 30, false, 0)
debugDrawer.drawLineInstance = real
for _, pt in ipairs(outer) do
  assert(math.abs(pt.z - ground(pt.x, pt.y) - 0.18) < 0.05,
    string.format('steep ring point at %.1f, %.1f is %.2f m off the ground', pt.x, pt.y, pt.z - ground(pt.x, pt.y)))
end
local uphill = { lat = 50, lon = 14, x = 28, y = 0, z = ground(28, 0) + 0.8, anchorLat = 50, anchorLon = 14 }
assert(not marker.offLevel(uphill, stop), 'uphill inside a steep ring counts')
map = { findClosestRoad = function() return 'a', 'b' end,
  getMap = function() return { nodes = { a = { pos = vec3(-50, 0, ground(-50, 0)) }, b = { pos = vec3(50, 0, ground(50, 0)) } } } end }
local yard = { g = { 50, 14, x = 0, y = 0 }, n = 'Yard', t = 'warehouse' }
marker.reset()
marker.draw(steep, yard, 'pickup', false, 35, false, 0)
local truck = { lat = 50, lon = 14, x = 30, y = 0, z = ground(30, 0) + 0.8, anchorLat = 50, anchorLon = 14 }
assert(not marker.offLevel(truck, yard), 'uphill in a sloping depot yard counts: ' .. tostring(marker.heightGap(truck, yard)))
truck.z = truck.z + 6
assert(marker.offLevel(truck, yard), 'a bridge over the yard does not count')


-- A customer's address point inside a house 20 m from the street (y = 0): the ring stands at the street's edge on
-- the house's side, and the stop counts there. A freight yard (it has a type) stays where it is.
ground = function() return 100 end
surfaces = function(x, y)
  if math.abs(x) < 8 and y > 14 and y < 26 then return { 100, 109 } end   -- the house with its roof
  return { 100 }
end
local house = { g = { 50, 14, x = 0, y = 20 }, d = { 50, 14, x = 0, y = 20 }, n = 'Customer' }
local centre
debugDrawer.drawLineInstance = function(_, a) outer = outer or {}; outer[#outer + 1] = a end
local car = { lat = 50, lon = 14, x = 40, y = -2, z = 100.8, anchorLat = 50, anchorLon = 14 }
for _, phase in ipairs({ 'delivery', 'pickup' }) do
  marker.reset()
  outer = nil
  marker.draw(car, house, phase, phase == 'pickup', phase == 'pickup' and 5 or 30, false, 0)
  local sx, sy = 0, 0
  if phase == 'delivery' then
    for _, pt in ipairs(outer) do sx, sy = sx + pt.x, sy + pt.y end
    centre = { x = sx / #outer, y = sy / #outer }
    assert(math.abs(centre.x) < 0.1 and math.abs(centre.y - 3.5) < 0.1,
      string.format('the delivery ring stands at the roadside, not in the house: %.1f, %.1f', centre.x, centre.y))
  end
  local at = { lat = 50, lon = 14, x = 0, y = 3, z = 100.8, anchorLat = 50, anchorLon = 14 }
  local d = marker.roadsideDistance(at, house)
  assert(d and d < 1, phase .. ': the roadside point is known for the distance: ' .. tostring(d))
end
local taxi = { g = { 50, 14, x = 0, y = 20 }, n = 'Passenger' }
marker.reset()
marker.draw(car, taxi, 'pickup', false, 25, false, 0)
assert(marker.roadsideDistance({ x = 0, y = 3.5, anchorLat = 50, anchorLon = 14 }, taxi) < 0.1,
  'a taxi passenger waits at the roadside')
local depotStop = { g = { 50, 14, x = 0, y = 20 }, n = 'Warehouse', t = 'warehouse' }
marker.reset()
marker.draw(car, depotStop, 'pickup', false, 35, false, 0)
assert(marker.roadsideDistance(car, depotStop) == nil, 'a freight yard is not moved to the road')
assert(marker.roadside(house) and not marker.roadside(depotStop), 'only yards keep their own point')
debugDrawer.drawLineInstance = real

-- A freight yard whose point lies deep in its site, 150 m from the street (y = 0): the zone and its ring move to the
-- street's edge on the yard's side once the car is near, the stop counts there, and a beacon shows it from afar.
local deep = { g = { 50, 14, x = 0, y = 150 }, n = 'Big warehouse', t = 'warehouse' }
local beacons, labels = 0, {}
debugDrawer.drawCylinder = function(_, a, b) if b.z - a.z > 30 then beacons = beacons + 1 end end
debugDrawer.drawTextAdvanced = function(_, _, text) labels[#labels + 1] = text end
local farCar = { lat = 50, lon = 14.02, x = 1400, y = -2, z = 100.8, anchorLat = 50, anchorLon = 14 }
for _, phase in ipairs({ 'delivery', 'pickup' }) do
  marker.reset()
  beacons, labels, outer = 0, {}, nil
  debugDrawer.drawLineInstance = function(_, a) outer = outer or {}; outer[#outer + 1] = a end
  marker.draw(farCar, deep, phase, false, 35, false, 0)
  assert(beacons == 1, phase .. ': a beacon shows the yard from 1.4 km')
  assert(labels[1] == (phase == 'delivery' and 'Deliver: ' or 'Pick up: ') .. 'Big warehouse', tostring(labels[1]))
  local near = { lat = 50, lon = 14, x = 60, y = -2, z = 100.8, anchorLat = 50, anchorLon = 14 }
  marker.draw(near, deep, phase, false, 35, false, 2)
  local at = { lat = 50, lon = 14, x = 0, y = 3, z = 100.8, anchorLat = 50, anchorLon = 14 }
  local d = marker.roadsideDistance(at, deep)
  assert(d and d < 1, phase .. ': the yard zone stands at the street, where the road ends: ' .. tostring(d))
  assert(not marker.offLevel(at, deep), phase .. ': a truck at the street is level with the moved zone')
  if phase == 'delivery' then
    local sx, sy = 0, 0
    outer = nil
    marker.draw(near, deep, phase, false, 35, false, 4)
    for _, pt in ipairs(outer) do sx, sy = sx + pt.x, sy + pt.y end
    assert(math.abs(sx / #outer) < 0.1 and math.abs(sy / #outer - 3.5) < 0.1,
      string.format('the delivery ring stands at the street: %.1f, %.1f', sx / #outer, sy / #outer))
  end
end
debugDrawer.drawLineInstance, debugDrawer.drawCylinder, debugDrawer.drawTextAdvanced = real, function() end, function() end

-- BeamNG 0.40.6: drawTriSolid takes a packed colour number and throws on a ColorF (beamng.log, 2026-11-26)
local packedTris, threw = 0, 0
color = function(r, g, b, a) return r * 16777216 + g * 65536 + b * 256 + a end
debugDrawer.drawTriSolid = function(_, _, _, _, col)
  if type(col) ~= 'number' then threw = threw + 1 error("bad argument #4 to 'drawTriSolid' (number expected, got userdata)") end
  packedTris = packedTris + 1
end
marker.reset()
marker.draw(car, house, 'delivery', true, 30, false, 0)
assert(packedTris == 40 and threw == 0, 'the ring is filled with a packed colour: ' .. packedTris .. ', ' .. threw)
color = nil

castRayStatic, vec3, ColorF, ColorI, String = saved.castRayStatic, saved.vec3, saved.ColorF, saved.ColorI, saved.String
debugDrawer, map = saved.debugDrawer, saved.map
package.loaded['cargoEarth/earth'], package.loaded['cargoEarth/marker'] = saved.earth, saved.marker
print('Stop rings: ground under roofs, trees and pylons; zone column 4.5 m up, 3.5 m down; houses moved to the roadside; deep yards moved to their road, beacons from afar')
