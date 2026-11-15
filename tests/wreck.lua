-- The vehicle-side wreck (lua/vehicle/extensions/cargoEarth/wreck.lua) with the game stubbed: the body at the hit end
-- is pressed in (beam rest lengths shortened bit by bit, no outside force), parts break off, tyres go flat, and a
-- reset does it all again.
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
function V.__unm(a) return vec(-a.x, -a.y, -a.z) end
function V.__sub(a, b) return vec(a.x - b.x, a.y - b.y, a.z - b.z) end
function V:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:cross(b) return vec(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
local saved = { vec3 = rawget(_G, 'vec3'), obj = rawget(_G, 'obj'), v = rawget(_G, 'v'), beamstate = rawget(_G, 'beamstate'),
  wheels = rawget(_G, 'wheels') }
vec3 = function(x, y, z) if type(x) == 'table' then return vec(x.x, x.y, x.z) end return vec(x, y, z) end

-- a car of 100 nodes in a line along its forward axis (+y here, 5 m long), a beam between each two neighbours, one
-- tyre beam (pressured) at the front and two wheel nodes at the very front
local nodes, positions, beams = {}, {}, {}
for i = 0, 99 do
  nodes[i] = { cid = i, wheelID = (i >= 98) and 0 or nil }
  positions[i] = vec(0, (i - 50) / 20, 0.5)
end
for i = 0, 98 do beams[#beams + 1] = { cid = i, id1 = i, id2 = i + 1 } end
beams[#beams + 1] = { cid = 99, id1 = 96, id2 = 97, beamType = 3 }
beams[#beams + 1] = { cid = 100, breakGroup = 'bumper_F' }
beams[#beams + 1] = { cid = 101, breakGroup = { 'mirror_L', 'mirror_R' } }
beams[#beams + 1] = { cid = 102, breakGroup = 'light_F' }
local lengths, forces = {}, 0
obj = {
  getNodePosition = function(_, cid) return positions[cid] end,
  getDirectionVector = function() return vec(0, 1, 0) end,
  getDirectionVectorUp = function() return vec(0, 0, 1) end,
  getBeamRestLength = function() return 0.05 end,
  setBeamLength = function(_, cid, len) lengths[cid] = len end,
  applyForceVector = function() forces = forces + 1 end,
}
v = { data = { nodes = nodes, beams = beams } }
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

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local ok, err = pcall(function()
  wreck.start('front', 42)
  wreck.updateGFX(0.5)
  assert(count(lengths) == 0, 'waits for the car to settle')
  wreck.updateGFX(0.6)
  assert(#broken == 1 and #flat == 1, 'a part broken off and a flat tyre: ' .. #broken .. ' ' .. #flat)
  -- half way through the press: shorter, but not yet all the way
  wreck.updateGFX(0.4)
  local half = {}
  for cid, len in pairs(lengths) do half[cid] = len end
  for _ = 1, 20 do wreck.updateGFX(0.05) end
  local pressed = 0
  for cid, len in pairs(lengths) do
    pressed = pressed + 1
    -- only the front end (the first 0.9 m from the front, wheels left alone), never the tyre
    assert(positions[cid].y > 2.35 - 0.9 - 0.06, 'only the front is pressed: ' .. cid)
    assert(cid ~= 99 and cid < 97, 'tyres and wheel nodes are left alone: ' .. cid)
    assert(len < 0.05 and len >= 0.05 * (1 - 0.35 * 1.15), 'shorter, within the limit: ' .. len)
    assert(half[cid] and half[cid] > len, 'pressed in bit by bit')
  end
  assert(pressed > 10, 'a crumple zone, not a beam or two: ' .. pressed)
  assert(forces == 0, 'no outside force: the car does not move')
  -- deeper in, less shrink
  assert(lengths[95] < lengths[80], 'the very front is pressed most')
  local n = count(lengths)
  local before = lengths[95]
  wreck.updateGFX(0.05)
  assert(count(lengths) == n and lengths[95] == before, 'the press ends and stays')
  -- a reset (it repairs the car) damages it again, the same way
  local first, firstLen = broken[1], lengths[95]
  lengths = {}
  wreck.onReset()
  wreck.updateGFX(1.1)
  for _ = 1, 20 do wreck.updateGFX(0.05) end
  assert(#broken == 2 and broken[2] == first and math.abs(lengths[95] - firstLen) < 1e-9, 'the same damage again after a reset')
  -- the old deck call is harmless
  wreck.calm()
  -- stripped: everything breaks off, the doors too, two flat tyres, no press
  lengths, flat = {}, {}
  wreck.start('stripped', 7)
  wreck.updateGFX(1.1)
  assert(all == 1 and hinges == 1 and #flat == 2 and count(lengths) == 0)
  -- a rolled car: only the roof is pressed (two nodes up high here)
  lengths = {}
  positions[10], positions[11] = vec(0, -2, 1.5), vec(0, -1.95, 1.5)
  wreck.start('rolled', 5, false, true)
  wreck.updateGFX(0.25)   -- in the air: no wait to settle
  for _ = 1, 20 do wreck.updateGFX(0.05) end
  assert(lengths[10] and count(lengths) == 1, 'the roof beam only: ' .. count(lengths))
  positions[10], positions[11] = vec(0, -2, 0.5), vec(0, -1.95, 0.5)
  -- a game without these calls: nothing fails
  beamstate, obj.setBeamLength, obj.getBeamRestLength = {}, nil, nil
  wreck.start('side', 3)
  wreck.updateGFX(1.1)
  wreck.updateGFX(0.1)
end)
for k, f in pairs(saved) do _G[k] = f end
assert(ok, err)
print('Wreck: pressed-in end, broken parts, flat tyres and reset checked')
