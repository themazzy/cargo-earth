-- A broken-down car for a tow job, damaged by the game's own soft-body physics right after it spawns:
--   front / rear / side / rolled: the nodes at one end (or the roof) are pushed into the car for a moment, so the body
--     really bends; the rest of the car is pushed back just as hard, so it does not move off;
--   a few break groups (bumpers, mirrors, lights) are broken off, all of them for 'stripped', with the doors too;
--   one or two tyres go flat.
-- It is done again after a reset (moving the car onto the trailer with setPositionRotation resets it: the game's
-- vePartTree.lua). Every game call is guarded: a call the game does not have is skipped.
local M = {}

M.DELAY_S = 1.0          -- let the car settle on its wheels first
M.PUSH_S = 0.3           -- how long the push lasts
M.NODE_N = 4000          -- newtons on each pushed node
M.SHARE = 0.12           -- share of the nodes at the hit end that are pushed
M.BREAK_SHARE = 0.35     -- share of the break groups broken off (all of them when stripped)

local kind, seed, seed0, timer, push

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

local function startPush()
  local axis = hitAxis()
  if not axis or not v or not v.data or type(v.data.nodes) ~= 'table' then return end
  local list = {}
  for _, n in pairs(v.data.nodes) do
    local cid = type(n) == 'table' and n.cid
    local p = cid and nodePos(cid)
    if p then list[#list + 1] = { cid = cid, k = vec3(p):dot(axis) } end
  end
  if #list < 10 then return end
  table.sort(list, function(a, b) return a.k > b.k end)
  local cut = math.max(1, math.floor(#list * M.SHARE))
  local hit, rest = {}, {}
  for i, n in ipairs(list) do if i <= cut then hit[#hit + 1] = n.cid else rest[#rest + 1] = n.cid end end
  local back = M.NODE_N * #hit / math.max(1, #rest)
  push = { t = M.PUSH_S, hit = hit, rest = rest,
    force = vecOf(-axis.x * M.NODE_N, -axis.y * M.NODE_N, -axis.z * M.NODE_N),
    counter = vecOf(axis.x * back, axis.y * back, axis.z * back) }
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
function M.start(newKind, newSeed)
  kind, seed0 = newKind, math.floor(tonumber(newSeed) or 1) % 2147483648
  seed, timer, push = seed0, M.DELAY_S, nil
end

function M.updateGFX(dt)
  if timer then
    timer = timer - dt
    if timer > 0 then return end
    timer = nil
    breakParts()
    flatTyres()
    startPush()
  end
  if push then
    -- applyForceVectorTime holds the force for the whole push (the game's container locks use it); without it the
    -- force is given again every frame
    if not push.timed and type(obj.applyForceVectorTime) == 'function' then
      for _, cid in ipairs(push.hit) do pcall(obj.applyForceVectorTime, obj, cid, push.force, M.PUSH_S) end
      for _, cid in ipairs(push.rest) do pcall(obj.applyForceVectorTime, obj, cid, push.counter, M.PUSH_S) end
      push = nil
      return
    end
    for _, cid in ipairs(push.hit) do pcall(obj.applyForceVector, obj, cid, push.force) end
    for _, cid in ipairs(push.rest) do pcall(obj.applyForceVector, obj, cid, push.counter) end
    push.t = push.t - dt
    if push.t <= 0 then push = nil end
  end
end

-- a reset repairs the car: damage it again
function M.onReset()
  if kind then seed, timer, push = seed0, M.DELAY_S, nil end
end

return M
