-- A broken-down car for a tow job, damaged by the game's own soft-body physics right after it spawns:
--   front / rear / side / rolled: the nodes at one end (or the roof) are pushed into the car for a moment, so the body
--     really bends; the rest of the car is pushed back just as hard (a rolled roof: the ground holds it), every node
--     by its own mass so light panels are not flung; while it bends and a moment after, the car is held in place
--     (a brake on its whole-body speed: the game's own freeze only locks the gearbox, Jan saw the car fly);
--   a few break groups (bumpers, mirrors, lights) are broken off, all of them for 'stripped', with the doors too;
--   one or two tyres go flat.
-- It is done again after a reset (moving the car onto the trailer with setPositionRotation resets it: the game's
-- vePartTree.lua). Every game call is guarded: a call the game does not have is skipped.
local M = {}

M.DELAY_S = 1.0          -- let the car settle on its wheels first
M.AIR_DELAY_S = 0.2      -- in the air there is nothing to settle on
M.PUSH_S = 0.3           -- how long the push lasts
M.HIT_ACCEL = 1200       -- m/s² on each pushed node (newtons = this x the node's mass)
M.HOLD_S = 1.5           -- the car is held in place this long from the start of the push
M.HOLD_K = 6             -- 1/s: how hard the hold brakes the car's speed (force = mass x speed x this)
M.SHARE = 0.12           -- share of the nodes at the hit end that are pushed
M.BREAK_SHARE = 0.35     -- share of the break groups broken off (all of them when stripped)

local kind, seed, seed0, timer, push, hold
local air = false    -- spawned in the air out of sight: no ground to wait for or to hold a rolled roof's push
local calm = false   -- on a trailer deck: no push (Jan's test: the push crushed the car and threw it off the deck)

local function call(f, ...)
  if type(f) ~= 'function' then return false end
  return pcall(f, ...)
end

local function rand(n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed % n + 1
end

-- the game passes forces as vec3 in newtons, world frame (lua/vehicle/playerController.lua)
local function vecOf(x, y, z) return vec3(x, y, z) end

local function nodePos(cid)
  local ok, p = pcall(function() return obj:getNodePosition(cid) end)
  if ok and p then return p end
end

-- The hit end: the axis (world space) pointing out of it, from the car's own direction vectors.
local function hitAxis()
  local okF, fwd = pcall(function() return obj:getDirectionVector() end)
  local okU, up = pcall(function() return obj:getDirectionVectorUp() end)
  if not okF or not fwd or not okU or not up then return nil end
  fwd, up = vec3(fwd), vec3(up)
  local right = fwd:cross(up)
  if kind == 'front' then return fwd end
  if kind == 'rear' then return -fwd end
  if kind == 'side' then return rand(2) == 1 and right or -right end
  if kind == 'rolled' then return up end
end

local function massOf(cid)
  local ok, m = pcall(function() return obj:getNodeMass(cid) end)
  m = ok and tonumber(m) or nil
  return (m and m > 0) and m or 1
end

local function startPush()
  local axis = hitAxis()
  if not axis or not v or not v.data or type(v.data.nodes) ~= 'table' then return end
  local list = {}
  for _, n in pairs(v.data.nodes) do
    local cid = type(n) == 'table' and n.cid
    local p = cid and nodePos(cid)
    if p then list[#list + 1] = { cid = cid, k = vec3(p):dot(axis), m = massOf(cid) } end
  end
  if #list < 10 then return end
  table.sort(list, function(a, b) return a.k > b.k end)
  local cut = math.max(1, math.floor(#list * M.SHARE))
  local hitMass, restMass = 0, 0
  for i, n in ipairs(list) do
    if i <= cut then hitMass = hitMass + n.m else restMass = restMass + n.m end
  end
  -- the rest of the car gets the same total force back (a rolled car: none, the ground takes the roof's push)
  local back = (kind == 'rolled' and not air) and 0 or M.HIT_ACCEL * hitMass / math.max(1e-6, restMass)
  local forces = {}
  for i, n in ipairs(list) do
    local a = i <= cut and -M.HIT_ACCEL or back
    if a ~= 0 then forces[#forces + 1] = { n.cid, vecOf(axis.x * a * n.m, axis.y * a * n.m, axis.z * a * n.m) } end
  end
  push = { t = M.PUSH_S, forces = forces }
  hold = { t = M.HOLD_S, nodes = list }
end

-- Hold the car in place: every node braked by the car's whole-body speed. Skipped when the game gives no speed.
local function holdTick(dt)
  hold.t = hold.t - dt
  local ok, vel = pcall(function() return obj:getVelocity() end)
  if ok and vel and type(obj.applyForceVector) == 'function' then
    local vx, vy, vz = vel.x or 0, vel.y or 0, vel.z or 0
    if vx * vx + vy * vy + vz * vz > 0.0025 then
      for _, n in ipairs(hold.nodes) do
        local k = -n.m * M.HOLD_K
        pcall(obj.applyForceVector, obj, n.cid, vecOf(vx * k, vy * k, vz * k))
      end
    end
  end
  if hold.t <= 0 then hold = nil end
end

local function breakParts()
  if not beamstate then return end
  local groups, seen = {}, {}
  for _, b in pairs(v and v.data and v.data.beams or {}) do
    local g = type(b) == 'table' and b.breakGroup
    local names = type(g) == 'table' and g or { g }
    for _, name in ipairs(names) do
      if type(name) == 'string' and name ~= '' and not seen[name] then
        seen[name] = true
        groups[#groups + 1] = name
      end
    end
  end
  table.sort(groups)
  if kind == 'stripped' then
    if not call(beamstate.breakAllBreakgroups) then
      for _, name in ipairs(groups) do call(beamstate.breakBreakGroup, name) end
    end
    call(beamstate.breakHinges)
  elseif kind ~= 'flat' then
    for _ = 1, math.floor(#groups * M.BREAK_SHARE) do call(beamstate.breakBreakGroup, groups[rand(#groups)]) end
  end
end

-- beamstate.deflateTire takes the wheel's key in wheels.wheels (its index, not its name)
local function flatTyres()
  if not beamstate or type(beamstate.deflateTire) ~= 'function' then return end
  local keys = {}
  for k in pairs(wheels and wheels.wheels or {}) do keys[#keys + 1] = k end
  if #keys == 0 then return end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _ = 1, (kind == 'flat' or kind == 'stripped') and 2 or 1 do call(beamstate.deflateTire, keys[rand(#keys)]) end
end

-- Damage this car as `newKind` (see tow.WRECKS), the same way every time for the same seed.
-- onDeck: the car stands on a trailer: only parts broken off and flat tyres, no push.
-- inAir: spawned high up out of sight (cargoEarth/trailers stageTowed): crumpled at once, a rolled roof pushed back too.
function M.start(newKind, newSeed, onDeck, inAir)
  kind, seed0 = newKind, math.floor(tonumber(newSeed) or 1) % 2147483648
  air = inAir == true
  seed, timer, push, hold, calm = seed0, air and M.AIR_DELAY_S or M.DELAY_S, nil, nil, onDeck == true
end

-- The car is being put on a trailer deck: from now on no push (also after the reset the move causes).
function M.calm()
  calm, push, hold, air = true, nil, nil, false
end

function M.updateGFX(dt)
  if timer then
    timer = timer - dt
    if timer > 0 then return end
    timer = nil
    breakParts()
    flatTyres()
    if not calm then startPush() end
  end
  if hold then holdTick(dt) end
  if push then
    -- applyForceVectorTime holds the force for the whole push (the game's container locks use it); without it the
    -- force is given again every frame
    if not push.timed and type(obj.applyForceVectorTime) == 'function' then
      for _, f in ipairs(push.forces) do pcall(obj.applyForceVectorTime, obj, f[1], f[2], M.PUSH_S) end
      push = nil
      return
    end
    for _, f in ipairs(push.forces) do pcall(obj.applyForceVector, obj, f[1], f[2]) end
    push.t = push.t - dt
    if push.t <= 0 then push = nil end
  end
end

-- a reset repairs the car: damage it again
function M.onReset()
  if kind then seed, timer, push, hold, air = seed0, M.DELAY_S, nil, nil, false end
end

return M
