-- A broken-down car for a tow job, damaged right after it spawns:
--   front / rear / side / rolled: the body at one end (or the roof) is pressed in. The rest lengths of the body beams
--     near that end are shortened bit by bit (the way the game's own hydros and saved-vehicle load set beam lengths),
--     so the soft-body pulls itself into a crumpled shape and keeps it. No outside force: the car does not move or
--     fly, and the loose parts are not just torn off (Jan's 0.10.1 test: an outside push only ripped the bumper and
--     lights off and left the body straight);
--   a few break groups (bumpers, mirrors, lights) are broken off, all of them for 'stripped', with the doors too;
--   one or two tyres go flat.
-- It is done again after a reset (a reset repairs the car), the same way for the same seed. Every game call is
-- guarded: a call the game does not have is skipped.
local M = {}

M.DELAY_S = 1.0          -- let the car settle on its wheels first
M.AIR_DELAY_S = 0.2      -- in the air there is nothing to settle on
M.PRESS_S = 0.8          -- how long the body takes to be pressed in (gradual: no snap)
M.BREAK_SHARE = 0.35     -- share of the break groups broken off (all of them when stripped)
-- per kind: how deep from the hit end the body is pressed (m), and how much the beams there shrink at the very end
M.PRESS = {
  front = { zone = 0.9, shrink = 0.35 },
  rear = { zone = 0.75, shrink = 0.3 },
  side = { zone = 0.5, shrink = 0.3 },
  rolled = { zone = 0.45, shrink = 0.3 },
}

local kind, seed, seed0, timer, press

local function call(f, ...)
  if type(f) ~= 'function' then return false end
  return pcall(f, ...)
end

local function rand(n)
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed % n + 1
end

local function nodePos(cid)
  local ok, p = pcall(function() return obj:getNodePosition(cid) end)
  if ok and p then return vec3(p) end
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

local function restLength(cid, a, b)
  local ok, len = pcall(function() return obj:getBeamRestLength(cid) end)
  len = ok and tonumber(len) or nil
  if len and len > 0 then return len end
  local d = b - a
  return math.sqrt(d:dot(d))
end

-- The beams to shorten and by how much: { cid, rest length, target length }.
local function startPress()
  local cfg = M.PRESS[kind]
  if not cfg or type(obj.setBeamLength) ~= 'function' then return end
  local axis = hitAxis()
  local data = v and v.data
  if not axis or not data or type(data.nodes) ~= 'table' or type(data.beams) ~= 'table' then return end
  local pos, wheel, cidOf, maxK = {}, {}, {}, nil
  for key, n in pairs(data.nodes) do
    local cid = type(n) == 'table' and n.cid
    local p = cid and nodePos(cid)
    if p then
      cidOf[key], pos[cid] = cid, p
      if n.wheelID ~= nil then wheel[cid] = true
      else
        local k = p:dot(axis)
        if not maxK or k > maxK then maxK = k end
      end
    end
  end
  if not maxK then return end
  local list = {}
  for _, b in pairs(data.beams) do
    -- a beam's id1 / id2 are keys of v.data.nodes (the game's beamstate reads v.data.nodes[beam.id1].cid)
    local cid = type(b) == 'table' and b.cid
    local a, c = cid and cidOf[b.id1], cid and cidOf[b.id2]
    -- body beams only: not tyres, shocks, hydros or support beams (they have a beamType), not the wheels' own nodes
    local pa, pc = a and pos[a], c and pos[c]
    if cid and pa and pc and (b.beamType == nil or b.beamType == 0) and not wheel[a] and not wheel[c] then
      local depth = maxK - (pa:dot(axis) + pc:dot(axis)) / 2
      if depth >= 0 and depth < cfg.zone then
        local d = pc - pa
        local len = math.sqrt(d:dot(d))
        if len > 1e-3 then
          local along = math.abs(d:dot(axis)) / len
          local s = cfg.shrink * (1 - depth / cfg.zone) * (0.4 + 0.6 * along) * (0.85 + 0.3 * rand(100) / 100)
          local rest = restLength(cid, pa, pc)
          list[#list + 1] = { cid, rest, rest * (1 - s) }
        end
      end
    end
  end
  if #list > 0 then press = { t = 0, beams = list } end
end

local function pressTick(dt)
  press.t = press.t + dt
  local f = math.min(1, press.t / M.PRESS_S)
  for _, b in ipairs(press.beams) do pcall(obj.setBeamLength, obj, b[1], b[2] + (b[3] - b[2]) * f) end
  if f >= 1 then press = nil end
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
-- onDeck: the car stands on a trailer deck (kept for the game side's calls; the press is safe there too).
-- inAir: spawned high up out of sight (cargoEarth/trailers stageTowed): no wait for it to settle.
function M.start(newKind, newSeed, onDeck, inAir)
  local _ = onDeck
  kind, seed0 = newKind, math.floor(tonumber(newSeed) or 1) % 2147483648
  seed, timer, press = seed0, inAir == true and M.AIR_DELAY_S or M.DELAY_S, nil
end

-- (older builds asked for no push on the deck; the press needs no such care)
function M.calm() end

function M.updateGFX(dt)
  if timer then
    timer = timer - dt
    if timer > 0 then return end
    timer = nil
    breakParts()
    flatTyres()
    startPress()
    return   -- the press starts from the next frame
  end
  if press then pressTick(dt) end
end

-- a reset repairs the car: damage it again
function M.onReset()
  if kind then seed, timer, press = seed0, M.DELAY_S, nil end
end

return M
