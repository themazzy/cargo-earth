-- The vehicle-side wreck (lua/vehicle/extensions/cargoEarth/wreck.lua) with the game stubbed: the push bends one end
-- without moving the car, parts break off, tyres go flat, and a reset does it all again.
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
function V.__unm(a) return vec(-a.x, -a.y, -a.z) end
function V:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:cross(b) return vec(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
local saved = { vec3 = rawget(_G, 'vec3'), obj = rawget(_G, 'obj'), v = rawget(_G, 'v'), beamstate = rawget(_G, 'beamstate'),
  wheels = rawget(_G, 'wheels'), float3 = rawget(_G, 'float3') }
vec3 = function(x, y, z) if type(x) == 'table' then return vec(x.x, x.y, x.z) end return vec(x, y, z) end
float3 = nil

-- a car of 100 nodes in a line along its forward axis (+y here)
local nodes, positions = {}, {}
for i = 0, 99 do
  nodes[i + 1] = { cid = i }
  positions[i] = vec(0, (i - 50) / 20, 0.5)
end
local forces = {}
obj = {
  getNodePosition = function(_, cid) return positions[cid] end,
  getDirectionVector = function() return vec(0, 1, 0) end,
  getDirectionVectorUp = function() return vec(0, 0, 1) end,
  applyForceVector = function(_, cid, f) forces[#forces + 1] = { cid = cid, f = f } end,
}
v = { data = { nodes = nodes, beams = { { breakGroup = 'bumper_F' }, { breakGroup = { 'mirror_L', 'mirror_R' } }, { breakGroup = 'light_F' }, {} } } }
local broken, flat, all, hinges = {}, {}, 0, 0
beamstate = {
  breakBreakGroup = function(g) broken[#broken + 1] = g end,
  deflateTire = function(i) flat[#flat + 1] = i end,
  breakAllBreakgroups = function() all = all + 1 end,
  breakHinges = function() hinges = hinges + 1 end,
}
wheels = { wheels = { [0] = {}, {}, {}, {} } }

package.path = 'mod/cargo_earth/lua/vehicle/extensions/?.lua;' .. package.path
local wreck = require('cargoEarth/wreck')

local ok, err = pcall(function()
  wreck.start('front', 42)
  wreck.updateGFX(0.5)
  assert(#forces == 0, 'waits for the car to settle')
  wreck.updateGFX(0.6)
  assert(#broken == 1 and #flat == 1, 'a part broken off and a flat tyre: ' .. #broken .. ' ' .. #flat)
  local sum, front = 0, 0
  for _, f in ipairs(forces) do
    sum = sum + f.f.y
    if f.f.y < 0 then
      front = front + 1
      assert(positions[f.cid].y > 1.8, 'only the front end is pushed in')
    end
  end
  assert(front == 12 and math.abs(sum) < 1e-6, 'the front is pushed back, the car as a whole does not move: ' .. sum)
  for _ = 1, 20 do wreck.updateGFX(0.05) end
  local n = #forces
  wreck.updateGFX(0.05)
  assert(#forces == n, 'the push ends')
  -- a reset (the teleport onto the trailer can do one) damages it again, the same way
  local first = broken[1]
  wreck.onReset()
  wreck.updateGFX(1.1)
  assert(#broken == 2 and broken[2] == first, 'the same damage again after a reset')
  -- put on a trailer deck: the reset of the move breaks parts again but never pushes (it threw the car off the deck)
  local pushes = #forces
  wreck.calm()
  wreck.onReset()
  wreck.updateGFX(1.1)
  for _ = 1, 10 do wreck.updateGFX(0.05) end
  assert(#broken == 3 and #forces == pushes, 'no push on the deck')
  wreck.start('front', 42, true)
  wreck.updateGFX(1.1)
  assert(#forces == pushes, 'spawned on the deck: no push either')
  -- stripped: everything breaks off, the doors too, two flat tyres, no push
  forces, flat = {}, {}
  wreck.start('stripped', 7)
  wreck.updateGFX(1.1)
  assert(all == 1 and hinges == 1 and #flat == 2 and #forces == 0)
  -- a rolled car: the roof is pushed down and nothing pushes the rest up (that lifted the car off the ground)
  forces = {}
  wreck.start('rolled', 5)
  wreck.updateGFX(1.1)
  for _, f in ipairs(forces) do assert(f.f.z <= 0, 'nothing is pushed up') end
  -- spawned out of sight in the air: no ground to hold the roof's push, so the rest is pushed back; no wait to settle
  forces = {}
  wreck.start('rolled', 5, false, true)
  wreck.updateGFX(0.25)
  local up = 0
  for _, f in ipairs(forces) do if f.f.z > 0 then up = up + 1 end end
  assert(up > 0, 'in the air the rest of a rolled car is pushed back')
  -- heavier nodes get more force (light panels are not flung), and the car is held in place while it bends
  forces = {}
  obj.getNodeMass = function(_, cid) return cid < 50 and 1 or 3 end
  wreck.start('front', 42)
  wreck.updateGFX(1.1)
  local light, heavy
  for _, f in ipairs(forces) do
    if f.f.y > 0 and f.cid < 50 then light = f.f.y end
    if f.f.y > 0 and f.cid >= 50 and positions[f.cid].y < 1.8 then heavy = f.f.y end
  end
  assert(light and heavy and math.abs(heavy - 3 * light) < 1e-6, 'counter-force by mass')
  forces = {}
  obj.getVelocity = function() return vec(2, 0, 0) end
  wreck.updateGFX(0.05)
  local braked = 0
  for _, f in ipairs(forces) do if f.f.x < 0 then braked = braked + 1 end end
  assert(braked == 100, 'every node is braked against the drift: ' .. braked)
  for _ = 1, 40 do wreck.updateGFX(0.05) end
  forces = {}
  wreck.updateGFX(0.05)
  assert(#forces == 0, 'the hold ends')
  obj.getNodeMass, obj.getVelocity = nil, nil
  -- a game without these calls: nothing fails
  beamstate, obj.applyForceVector = {}, nil
  wreck.start('side', 3)
  wreck.updateGFX(1.1)
  wreck.updateGFX(0.1)
end)
for k, f in pairs(saved) do _G[k] = f end
assert(ok, err)
print('Wreck: bent end, broken parts, flat tyres and reset checked')
