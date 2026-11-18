-- Stop rings sit on the ground under trees, pylons and roofs, and the stop zone is a short column (issue #118).
local saved = { castRayStatic = castRayStatic, vec3 = vec3, ColorF = ColorF, ColorI = ColorI, String = String,
  debugDrawer = debugDrawer, map = map, earth = package.loaded['cargoEarth/earth'], marker = package.loaded['cargoEarth/marker'] }
local function ground(x, y) return 100 + 0.08 * x + 0.03 * y end
-- every surface at x, y: the sloped ground, a building over the address (roof 12 m up), a tree crown at the
-- ring's east edge and a power pylon on its north edge
local function surfaces(x, y)
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

castRayStatic, vec3, ColorF, ColorI, String = saved.castRayStatic, saved.vec3, saved.ColorF, saved.ColorI, saved.String
debugDrawer, map = saved.debugDrawer, saved.map
package.loaded['cargoEarth/earth'], package.loaded['cargoEarth/marker'] = saved.earth, saved.marker
print('Stop rings: ground under roofs, trees and pylons; zone column 4.5 m up, 3.5 m down')
