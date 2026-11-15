-- cargoEarth/trailers: the job's trailer as a real BeamNG vehicle. It is spawned behind the player's truck at the
-- pickup (no lat/lon to game coordinate conversion needed: the player is standing at the gate), the player backs up
-- and couples it, and at the delivery the trailer has to be near the truck.
--
-- Model names are BeamNG's stock trailers; override them in /settings/cargoEarth/config.json:
--   { "trailerModels": { "tanker": { "model": "tanker", "config": "" } } }
local M = {}

-- cargo trailer kind -> stock BeamNG model (not verified for every kind yet: check in game, see README "To check")
M.models = {
  curtain   = { model = 'dryvan' },
  -- cartrailer and a tow job's flatbed: see M.TOW_MODELS
  box       = { model = 'dryvan' },
  reefer    = { model = 'dryvan' },
  flatbed   = { model = 'flatbed' },
  lowloader = { model = 'flatbed' },
  log       = { model = 'flatbed' },
  container = { model = 'flatbed' },
  tipper    = { model = 'frameless_dump' },
  silo      = { model = 'tanker' },
  tanker    = { model = 'tanker' },
  livestock = { model = 'dryvan' },
}
M.BEHIND_M = 16      -- spawn distance behind the truck's centre
M.NEAR_M = 30        -- a trailer this close to the truck counts as with it

local id = nil       -- the job trailer's vehicle id
local towed = {}     -- vehicle ids of the cars on a tow job's trailer
local loaded = {}    -- [vehicle id] = true for the towed cars that were put on the deck (Load, or spawned there)
-- Jan: the broken-down cars are spawned (and crumpled) out of sight when the job starts, then put by the road before
-- the player gets there: no spawn lag and no crumple at the pickup.
local staged = {}    -- [vehicle id] = seconds until it is hidden (setActive 0), or 0 once hidden
local placedOut = false   -- the staged cars stand by the road at the pickup

-- Tow trailers: the first stock model found is used (override with trailerModels.cartrailer / .flatbed).
-- Each is a model, or { model, configuration }. BeamNG 0.40 has no 'cartrailer': the 22 ft tilt deck is its car
-- trailer, the small TSFB flatbed the fallback (its configuration given: spawned without one it failed to load).
-- The small car trailer (Jan: the 22 ft one is too big and heavy for a small car) is the Large Box Utility Trailer
-- (Jan's pick: 490 kg, floor 4.2 m x 1.9 m inside its low sides) with its tailgate left off, so a car a little longer
-- than the floor can stand on it; the smaller TSFB (3.5 m deck, ramp door off) when the game lacks it.
M.SMALL_CONFIG = { format = 2, model = 'boxutility_large', parts = { boxutility_large_load = '', boxutility_tailgate = '' } }
M.SMALL_FALLBACK = { format = 2, model = 'tsfb', parts = { tsfb_load = '', tsfb_ramp = '' } }
M.TOW_MODELS = { cartrailer = { { 'tiltdeck', '22ft_standard' }, { 'tsfb', 'unloaded' }, 'cartrailer' },
  smalltrailer = { { 'boxutility_large', M.SMALL_CONFIG }, { 'tsfb', M.SMALL_FALLBACK } }, flatbed = { 'flatbed' } }
M.DECK_LIFT = 0.15   -- metres above the deck a towed car's lowest point is let down from
-- the deck of each tow trailer model: its height above the ground under the trailer, and how far its middle is behind
-- the middle of the trailer's box (the drawbar makes the box longer at the front). From the models' jbeam nodes.
M.DECK = { tiltdeck = { h = 0.9, back = 0.9 }, tsfb = { h = 0.75, back = 0.6 }, boxutility_large = { h = 0.63, back = 0.35 },
  flatbed = { h = 1.45, back = 0 } }
M.DECK_DEFAULT = { h = 0.9, back = 0.4 }
M.HITCH_TRIES = 120  -- frames to wait for the game to know a new trailer's couplers
local kindOut = nil  -- the tow trailer kind that is out (for its deck)
local adopted = false  -- the model of the player's own trailer when that is the one out (coupled before the job): never deleted
local hitchWanted = nil  -- { vehicle id, trailer id, frames left }: couple the trailer that was just spawned
local ownId = nil   -- the firm's own tow trailer the player took out at the headquarters (a job never deletes it)

function M.configure(cfg)
  for k, v in pairs((cfg and cfg.trailerModels) or {}) do
    if type(v) == 'table' and type(v.model) == 'string' then M.models[k] = v end
  end
end

local function obj()
  if not id then return nil end
  local o = scenetree.findObjectById(id)
  if not o then id, adopted = nil, false end
  return o
end

function M.exists() return obj() ~= nil end

function M.id() return obj() and id or nil end

M.AGGREGATE_SLOTS = { 'FA', 'FB', 'FC', 'FD', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'RA', 'RB', 'RC', 'RD' }
M.AGGREGATE_L = 800 * #M.AGGREGATE_SLOTS

local function freightConfig(kind)
  if kind == 'fluid' then
    return 'tanker', 'vehicles/tanker/career_shuffleboard_empty_long.pc'
  end
  local config = jsonReadFile('vehicles/dryvan/48ft.pc')
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return end
  local parts = config.parts
  parts.dryvan_load_F = 'dryvan_load_F_cargo_load_box_4XL'
  parts.dryvan_load_M = 'dryvan_load_M_cargo_load_box_8xl'
  parts.dryvan_load_R = 'dryvan_load_R_cargo_load_box_4XL'
  if kind == 'dryBulk' then
    -- every box slot of the trailer takes the game's 800 L aggregate box in place of the parcel box (same slot type,
    -- checked in common.zip vehicles/common/cargo/loads_XL): 16 boxes, 12,800 L
    for _, suffix in ipairs(M.AGGREGATE_SLOTS) do
      parts['cargo_load_box_XL_' .. suffix .. '_90deg'] = 'cargo_load_aggregate_box_XL_' .. suffix .. '_90deg'
    end
  end
  return 'dryvan', config
end

-- A trailer of this model (and configuration: a .pc path or a table) spawned on the ground behind the player's vehicle.
-- The vehicle, or nil and why.
local function spawnBehind(veh, model, config)
  local pos, dir = veh:getPosition(), veh:getDirectionVector()
  dir.z = 0
  if dir:length() < 1e-3 then return nil, 'vehicle has no direction' end
  dir = dir:normalized()
  local p = pos - dir * M.BEHIND_M
  -- set it on the ground: a ray down from above
  local d = castRayStatic(vec3(p.x, p.y, p.z + 20), vec3(0, 0, -1), 60)
  if d and d < 60 then p.z = p.z + 20 - d + 0.3 else p.z = pos.z + 0.5 end
  local opt = { pos = p, rot = quatFromDir(dir, vec3(0, 0, 1)), autoEnterVehicle = false }
  if config and config ~= '' then opt.config = config end
  local ok, v = pcall(core_vehicles.spawnNewVehicle, model, opt)
  if not ok or not v then return nil, 'could not spawn ' .. tostring(model) .. ': ' .. tostring(v) end
  -- spawning can switch the camera to the new vehicle: give it back
  if be and be.enterVehicle then pcall(be.enterVehicle, be, 0, veh) end
  return v
end

-- Spawn the trailer for this kind behind the player's vehicle. True, or false and why.
function M.spawn(kind, freightKind)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  local m = M.models[kind] or M.models.curtain
  if freightKind then
    local model, config = freightConfig(freightKind)
    if not model then return false, 'The stock freight trailer configuration is unavailable.' end
    m = { model = model, config = config }
  end
  M.remove()
  local v, why = spawnBehind(veh, m.model, m.config)
  if not v then return false, why end
  id = v:getID()
  return true
end

function M.coupledIds(vehicleId, trailerId)
  local couplings = core_vehicles and core_vehicles.vehsCouplings
  local attached = couplings and couplings[vehicleId]
  return trailerId ~= nil and attached ~= nil and attached[trailerId] == true
end

function M.coupled(vehicleId) return M.coupledIds(vehicleId, id) end

M.TELEPORT_M = 60   -- a trailer that moves this far in one frame was teleported
M.DECK_NEAR_M = 8    -- a loaded car this close to the trailer still counts as on its deck
M.TRAILER_LEN = { cartrailer = 9.5, smalltrailer = 6, flatbed = 15 }   -- metres behind the vehicle a trailer of this kind takes

-- Other vehicles (parked cars, traffic) standing in a box: centre c, unit direction dir, half length and half width
-- (each vehicle by its own bounding box when the game gives one). The first one found, or nil.
local function vehicleIn(c, dir, halfLen, halfWid, skip)
  local right = vec3(dir.y, -dir.x, 0)
  local list = getAllVehicles and getAllVehicles() or {}
  for _, o in ipairs(list) do
    local vid = o:getID()
    if not skip[vid] then
      local p = o:getPosition()
      local r = 1.2
      pcall(function() local e = o:getSpawnWorldOOBB():getHalfExtents() r = math.min(3, math.max(e.x, e.y)) end)
      local d = p - c
      local along, side = math.abs(d:dot(dir)), math.abs(d:dot(right))
      if along <= halfLen + r * 0.8 and side <= halfWid + r * 0.6 and math.abs(d.z) < 4 then return o end
    end
  end
end

-- Is there room behind the player's vehicle for this kind of trailer (no other vehicle, wall or building there)?
-- True, or false and why.
function M.roomBehind(kind)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  local dir = veh:getDirectionVector()
  dir.z = 0
  if dir:length() < 1e-3 then return true end
  dir = dir:normalized()
  local half = 2.4
  pcall(function() half = veh:getSpawnWorldOOBB():getHalfExtents().y end)
  local len = M.TRAILER_LEN[kind] or 14
  local pos = veh:getPosition()
  local c = pos - dir * (half + len / 2 + 0.3)
  local skip = { [veh:getID()] = true }
  if id then skip[id] = true end
  if ownId then skip[ownId] = true end
  for _, tid in ipairs(towed) do skip[tid] = true end
  if vehicleIn(c, dir, len / 2, 1.3, skip) then return false, 'another car stands behind you' end
  local eye = vec3(pos.x, pos.y, pos.z + 1)
  local tail = pos - dir * (half + len)
  local d = castRayStatic(eye - dir * half, -dir, len + 0.5)
  if d and d < len then return false, 'a wall or a building is behind you' end
  return true
end

-- Metres between the trailer and the player's vehicle, or nil.
function M.distanceToPlayer()
  local o = obj()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not o or not veh then return nil end
  return (o:getPosition() - veh:getPosition()):length()
end

function M.withPlayer()
  local d = M.distanceToPlayer()
  return d ~= nil and d <= M.NEAR_M
end

local function removeTowed()
  for _, tid in ipairs(towed) do
    local o = scenetree.findObjectById(tid)
    if o then o:delete() end
  end
  towed, loaded, staged, placedOut = {}, {}, {}, false
end

function M.adopted() return obj() ~= nil and adopted ~= false end

function M.remove()
  removeTowed()
  hitchWanted, kindOut = nil, nil
  local o = obj()
  if o and not adopted then o:delete() end
  id, adopted = nil, false
end

-- A tow job ends: its cars go, and its trailer when it is a tow trailer (a freight trailer that is out stays).
function M.removeTow()
  removeTowed()
  if kindOut then M.remove() end
end

-- Is this stock model in the game?
function M.modelExists(model)
  if type(model) ~= 'string' or not core_vehicles or not core_vehicles.getModel then return false end
  local ok, info = pcall(core_vehicles.getModel, model)
  return ok and type(info) == 'table' and info.model ~= nil
end

-- The models from `list` that exist in the game.
function M.existing(list)
  local out = {}
  for _, m in ipairs(list or {}) do if M.modelExists(m) then out[#out + 1] = m end end
  return out
end

-- The stock model for a tow trailer kind, or nil when the game has none.
function M.towModel(kind)
  local custom = M.models[kind]
  if custom and custom.model and M.modelExists(custom.model) then return custom.model, custom.config end
  for _, m in ipairs(M.TOW_MODELS[kind] or {}) do
    local model, config = m, nil
    if type(m) == 'table' then model, config = m[1], m[2] end
    if M.modelExists(model) then return model, config end
  end
end

-- Parked, engine off, hazard lights on (vehicle-side Lua, each call guarded).
local PARK_CMD = 'if input and input.event then input.event("parkingbrake", 1, 2) end '
  .. 'if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(0) end '
  .. 'if electrics and electrics.set_warn_signal then pcall(electrics.set_warn_signal, true) end'

-- wreck: { kind, seed } for the vehicle-side cargoEarth_wreck, or nil for an undamaged car
-- air: spawned in the air out of sight (no ground under it: the wreck pushes back on a rolled roof too)
local function wreckCmd(wreck, onDeck, air)
  if type(wreck) ~= 'table' or type(wreck[1]) ~= 'string' then return '' end
  return string.format(' extensions.load("cargoEarth_wreck") if extensions.cargoEarth_wreck then '
    .. 'extensions.cargoEarth_wreck.start(%q, %d, %s, %s) end', wreck[1], math.floor(tonumber(wreck[2]) or 1),
    onDeck and 'true' or 'false', air and 'true' or 'false')
end

-- How far a car's position is above its lowest point (its box bottom), so its wheels, not its middle, go on the deck.
local function lowestBelow(o)
  local ok, lift = pcall(function()
    local box = o:getSpawnWorldOOBB()
    return o:getPosition().z - (box:getCenter().z - box:getHalfExtents().z)
  end)
  return ok and type(lift) == 'number' and math.max(0, math.min(lift, 2)) or 0.5
end

-- Where the middle of a car's body is from its position (its ref node), in its own frame: metres forward and to the
-- right. The game moves a car by its ref node, which is not the middle of the body (Jan: 3 of 3 cars sat left of the
-- deck's middle). From the nodes of its main body only (the cluster of its ref node, as the game's spawn.lua does),
-- so parts broken off and lying about do not count. 0, 0 when the game cannot tell.
local function bodyOffset(o)
  local ok, f, r = pcall(function()
    local fwd = vec3(o:getDirectionVector())
    fwd.z = 0
    fwd = fwd:normalized()
    local right = vec3(fwd.y, -fwd.x, 0)
    local clusters = o:getNodeClusters()
    local main = clusters and clusters[o:getRefNodeId() + 1]
    local f0, f1, r0, r1
    for i = 0, o:getNodeCount() - 1 do
      if not main or clusters[i + 1] == main then
        local q = vec3(o:getNodePosition(i))
        local a, b = q:dot(fwd), q:dot(right)
        if not f0 then f0, f1, r0, r1 = a, a, b, b
        else f0, f1, r0, r1 = math.min(f0, a), math.max(f1, a), math.min(r0, b), math.max(r1, b) end
      end
    end
    if not f0 then return 0, 0 end
    return (f0 + f1) / 2, (r0 + r1) / 2
  end)
  if not ok or type(f) ~= 'number' or type(r) ~= 'number' or math.abs(f) > 4 or math.abs(r) > 2 then return 0, 0 end
  return f, r
end
M.bodyOffset = bodyOffset

-- The position for a car so the middle of its body is over p.x, p.y once it faces dir (flat, unit).
local function centred(o, p, dir)
  local f, r = bodyOffset(o)
  local right = vec3(dir.y, -dir.x, 0)
  return vec3(p.x - dir.x * f - right.x * r, p.y - dir.y * f - right.y * r, p.z)
end

local function spawnCar(model, p, dir, wreck, onDeckSpot, air)
  local ok, v = pcall(core_vehicles.spawnNewVehicle, model, { pos = p, rot = quatFromDir(dir, vec3(0, 0, 1)),
    autoEnterVehicle = false })
  if not ok or not v then return false end
  -- spawned on a deck: its body's middle over the spot, lifted so its lowest point, not its middle, is at the spot
  if onDeckSpot then
    local lift = lowestBelow(v)
    local c = centred(v, p, dir)
    pcall(function() v:setPosition(vec3(c.x, c.y, p.z + lift)) end)
  end
  towed[#towed + 1] = v:getID()
  if onDeckSpot then loaded[v:getID()] = true end
  v:queueLuaCommand(PARK_CMD .. wreckCmd(wreck, onDeckSpot, air))
  return true
end

-- Move a car without a reset, so it keeps its damage: the game's own way (spawn.lua setSafePositionRec: the car's
-- cluster moved and turned about its ref node, its speed zeroed). p: where its ref node goes; dir: it faces this way.
local function moveKeep(o, p, dir)
  return pcall(function()
    local ref = o:getRefNodeId()
    local cur = quatFromDir(vec3(o:getDirectionVector()), vec3(o:getDirectionVectorUp()))
    local diff = cur:inversed() * quatFromDir(dir, vec3(0, 0, 1))
    o:setClusterPosRelRot(ref, p.x, p.y, p.z, diff.x, diff.y, diff.z, diff.w)
    o:applyClusterVelocityScaleAdd(ref, 0, 0, 0, 0)
  end)
end

-- Move a car that is out, its body's middle over the spot, keeping its damage (moveKeep); when the game cannot, with
-- setPositionRotation, which resets the car (the wreck extension then damages it again); vehicles face backwards there,
-- so the rotation is turned around as the game's own callers do.
local function moveCar(o, p, dir)
  local c = centred(o, p, dir)
  local z = p.z + lowestBelow(o)
  if moveKeep(o, vec3(c.x, c.y, z), dir) then return true end
  local rot = quatFromDir(-dir, vec3(0, 0, 1))
  return pcall(function() o:setPositionRotation(c.x, c.y, z, rot.x, rot.y, rot.z, rot.w) end)
end

-- The first coupler node of a vehicle with this tag (as the game lists them in core_vehicles), checking `first`
-- (couplerTag or tag) before the other name.
local function couplerNode(vid, tag, first)
  local cache = core_vehicles and core_vehicles.vehsCouplerCache and core_vehicles.vehsCouplerCache[vid]
  if type(cache) ~= 'table' then return nil end
  local second = first == 'couplerTag' and 'tag' or 'couplerTag'
  for _, key in ipairs({ first, second }) do
    for cid, n in pairs(cache) do
      if type(n) == 'table' and n[key] == tag then return cid end
    end
  end
end

-- Put the trailer on the vehicle's hitch the way the game itself does after a reset (spawn.placeTrailer: moved to
-- the hitch, then the game's auto coupling latches it). True when done, false while the couplers are not known yet,
-- nil when the two have no hitch in common.
local latch = nil   -- { vehicle id, trailer id, tag, car node, trailer node, seconds left, next try }: after placing
local hitchFailed = false

local function hitchNow(vid, tid)
  if not (spawn and spawn.placeTrailer and core_vehicles and core_vehicles.couplerTagsOptions) then return nil end
  local offsets = core_vehicles.vehsCouplerOffset or {}
  if not offsets[vid] or not offsets[tid] then return false end
  for _, tag in ipairs({ 'tow_hitch', 'fifthwheel', 'gooseneck_hitch', 'pintle', 'fifthwheel_v2' }) do
    local vc, tc = couplerNode(vid, tag, 'couplerTag'), couplerNode(tid, tag, 'tag')
    if vc and tc and vc ~= nil and offsets[vid][vc] and offsets[tid][tc] then
      local ok, err = pcall(spawn.placeTrailer, vid, offsets[vid][vc], tid, offsets[tid][tc], tag)
      log('I', 'cargoEarth', string.format('trailer %s placed on the %s hitch of %s: %s', tostring(tid), tag, tostring(vid),
        ok and 'ok' or tostring(err)))
      -- the game's auto coupling should latch it; it is checked and helped along for a few seconds (M.update)
      if ok then latch = { vid, tid, tag, vc, tc, 6, 0.5 } end
      return ok
    end
  end
  log('W', 'cargoEarth', 'no hitch in common between vehicle ' .. tostring(vid) .. ' and trailer ' .. tostring(tid))
  return nil
end

-- World metres between two coupler nodes, or nil.
local function couplerGap(vid, vc, tid, tc)
  local ok, d = pcall(function()
    local a, b = scenetree.findObjectById(vid), scenetree.findObjectById(tid)
    local pa = a:getPosition() + a:getNodePosition(vc)
    local pb = b:getPosition() + b:getNodePosition(tc)
    return (pa - pb):length()
  end)
  return ok and type(d) == 'number' and d or nil
end

-- After placing: is it coupled? If not, ask the car to latch its coupler again (as the game's auto coupling does every
-- half second); give up after a few seconds and say so (M.hitchFailed), with the gap in the log.
local function latchTick(dt)
  local l = latch
  if not l then return end
  if not scenetree.findObjectById(l[1]) or not scenetree.findObjectById(l[2]) then latch = nil return end
  if M.coupledIds(l[1], l[2]) then
    log('I', 'cargoEarth', 'trailer coupled')
    latch = nil
    return
  end
  l[6], l[7] = l[6] - dt, l[7] - dt
  if l[7] <= 0 then
    l[7] = 0.5
    local car = scenetree.findObjectById(l[1])
    pcall(function() car:queueLuaCommand(string.format('beamstate.activateAutoCoupling(%q) beamstate.attachCouplers(%q)', l[3], l[3])) end)
  end
  if l[6] <= 0 then
    local gap = couplerGap(l[1], l[4], l[2], l[5])
    log('W', 'cargoEarth', string.format('trailer did not couple (%s, coupler gap %s m)', l[3], gap and string.format('%.2f', gap) or '?'))
    hitchFailed, latch = true, nil
  end
end

-- Did the last hitch fail to latch? (read once: true clears it)
function M.hitchFailed()
  local f = hitchFailed
  hitchFailed = false
  return f
end
function M.latching() return latch ~= nil end

-- Every frame (core onUpdate): couples the trailer that was just spawned once the game knows its couplers.
local follow = nil   -- { trailer position, { car on the deck = true } } of the last frame

-- A teleport (BeamNG.Earth's map, the game's own) takes the player and the coupled trailer but not the cars on the
-- deck: when the trailer jumps, the cars that were on it are put back on its deck.
local function followTick()
  local trailer = obj()
  if not trailer or #towed == 0 then follow = nil return end
  local pos = trailer:getPosition()
  if follow and (pos - follow[1]):length() > M.TELEPORT_M then
    local spots, dir = M.deckSpotsFor(trailer, #towed)
    local moved = 0
    for i, tid in ipairs(towed) do
      local o = scenetree.findObjectById(tid)
      -- left behind only: an origin rebase moves the cars with the world, they are still by the deck (no reset)
      if o and follow[2][tid] and (o:getPosition() - pos):length() > M.DECK_NEAR_M then
        M.moveCarTo(o, spots[i], dir)
        moved = moved + 1
      end
    end
    if moved > 0 then log('I', 'cargoEarth', 'trailer teleported: the cars on its deck went along') end
  end
  local on = {}
  for _, tid in ipairs(towed) do
    local o = scenetree.findObjectById(tid)
    -- only cars that were loaded and still sit by the deck (a waiting car parked next to it, or one that slid
    -- off, is not cargo)
    if o and loaded[tid] and (o:getPosition() - pos):length() <= M.DECK_NEAR_M then on[tid] = true end
  end
  follow = { pos, on }
end

-- BeamNG.Earth moved the world origin: positions jumped without a teleport
function M.onRebased() follow = nil end

local function stagedTick(dt)
  for tid, left in pairs(staged) do
    if left > 0 then
      left = left - dt
      staged[tid] = math.max(0, left)
      if left <= 0 then
        local o = scenetree.findObjectById(tid)
        if o then pcall(function() o:setActive(0) end) end
      end
    end
  end
end

-- dtSim: simulation time (the staged crumple runs in physics time: paused or slow motion holds the countdown)
function M.update(dt, dtSim)
  latchTick(dt or 0)
  stagedTick(dtSim or dt or 0)
  followTick()
  local h = hitchWanted
  if not h then return end
  if not scenetree.findObjectById(h[1]) or not scenetree.findObjectById(h[2]) then hitchWanted = nil return end
  local trailer = scenetree.findObjectById(h[2])
  local before = trailer:getPosition()
  local done = hitchNow(h[1], h[2])
  h[3] = h[3] - 1
  if done ~= false or h[3] <= 0 then hitchWanted = nil end
  -- cars already on the deck (a restored load) move along with the trailer to the hitch
  if done and h[4] and #towed > 0 then
    local shift = trailer:getPosition() - before
    for _, tid in ipairs(towed) do
      local o = scenetree.findObjectById(tid)
      if o then
        local p = o:getPosition() + shift
        pcall(function() o:setPosition(p) end)
      end
    end
  end
end

-- Couple the trailer that is out to the player's vehicle (in the next frames). False when there is no trailer or car.
function M.hitch()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local o = obj()
  if not veh or not o then return false end
  hitchWanted, hitchFailed = { veh:getID(), o:getID(), M.HITCH_TRIES }, false
  return true
end
function M.hitching() return hitchWanted ~= nil end

local function backToPlayer(veh)
  if be and be.enterVehicle and veh then pcall(be.enterVehicle, be, 0, veh) end
end

-- The deck spots of the trailer that is out, one per car, and its direction. A spot is the middle of the deck at its
-- height: the trailer's box middle (not its position, which is at the drawbar end), moved back by the deck's offset,
-- and the deck height above the ground found under it. (The box top would be the raised ramps: cars fell from there.)
local function deckSpots(trailer, n)
  local pos, dir = trailer:getPosition(), trailer:getDirectionVector()
  dir.z = 0
  dir = dir:length() > 1e-3 and dir:normalized() or vec3(0, 1, 0)
  local m = kindOut and M.models[kindOut]
  local deck = M.DECK[type(adopted) == 'string' and adopted or (m and m.model) or ''] or M.DECK_DEFAULT
  local mid = vec3(pos.x, pos.y, pos.z)
  local okBox, box = pcall(function() return trailer:getSpawnWorldOOBB() end)
  if okBox and box then
    local okC, c = pcall(function() return box:getCenter() end)
    if okC and c then mid = vec3(c.x, c.y, c.z) end
  end
  mid = mid - dir * deck.back
  local floor = pos.z
  local d = castRayStatic(vec3(mid.x, mid.y, mid.z + 3), vec3(0, 0, -1), 20)
  if d and d < 20 then floor = mid.z + 3 - d end
  local spots = {}
  for i = 1, n do
    local along = n > 1 and (i == 1 and 3.2 or -3.2) or 0
    spots[i] = vec3(mid.x, mid.y, floor + deck.h + M.DECK_LIFT) + dir * along
  end
  return spots, dir
end

M.deckSpotsFor = function(trailer, n) return deckSpots(trailer, n) end
M.moveCarTo = function(o, p, dir) return moveCar(o, p, dir) end

-- New cars on the deck of the trailer that is out. How many were placed.
local function onDeck(trailer, cars, wrecks)
  local spots, dir = deckSpots(trailer, #cars)
  local placed = 0
  for i, carModel in ipairs(cars) do
    if spawnCar(carModel, spots[i], dir, wrecks and wrecks[i], true) then placed = placed + 1 end
  end
  return placed
end

-- Make sure the tow trailer for this kind is out (spawned behind the player when it is not). True, or false and why.
-- parked: left standing behind the player for the phone's Hitch (a borrowed trailer at the workshop).
local function towTrailer(kind, fresh, parked)
  if obj() and not fresh then return true end
  local model, config = M.towModel(kind)
  if not model then return false, 'this game has no ' .. tostring(kind) .. ' trailer' end
  M.models[kind] = { model = model, config = config }
  local ok, why = M.spawn(kind)
  if ok then
    kindOut = kind
    if not parked then M.hitch() end
  end
  return ok, why
end

-- The borrowed trailer at the workshop: spawned on the player's hitch (Jan: no separate step) once there is room
-- behind. True, or false and why.
function M.spawnBorrowed(kind)
  local room, why = M.roomBehind(kind)
  if not room then return false, why end
  return towTrailer(kind, true)
end

-- Is this vehicle id one of the models a tow trailer of this kind can be?
local function isTowModel(vid, kind)
  local o = scenetree.findObjectById(vid)
  local ok, model = pcall(function() return o and o:getJBeamFilename() end)
  if not ok or type(model) ~= 'string' then return false end
  -- the model this game uses for the kind (not every fallback: the small TSFB is its own kind, not a car trailer)
  local want = M.towModel(kind)
  if want == model then return true, model end
  return false
end

-- A car trailer (or flatbed) of the player's own, coupled to the player's vehicle now: its vehicle id and model.
function M.ownTowTrailer(kind)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local couplings = veh and core_vehicles and core_vehicles.vehsCouplings and core_vehicles.vehsCouplings[veh:getID()]
  for vid, on in pairs(couplings or {}) do
    if on and vid ~= id then
      local yes, model = isTowModel(vid, kind)
      if yes then return vid, model end
    end
  end
end

-- The firm's own tow trailer of this kind, taken out at the headquarters: spawned behind the player's vehicle and put
-- on its hitch. A job uses it as the player's own (M.adopt) and never deletes it. True, or false and why.
function M.takeOwn(kind)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  M.putAwayOwn()
  local model, config = M.towModel(kind)
  if not model then return false, 'this game has no ' .. tostring(kind) .. ' trailer' end
  local room, why = M.roomBehind(kind)
  if not room then return false, why end
  local v, err = spawnBehind(veh, model, config)
  if not v then return false, err end
  ownId = v:getID()
  hitchWanted, hitchFailed = { veh:getID(), ownId, M.HITCH_TRIES }, false
  return true
end

-- The firm's trailer that is out (its vehicle id), or nil.
function M.ownOut()
  if ownId and not scenetree.findObjectById(ownId) then ownId = nil end
  return ownId
end

-- Leave the firm's trailer at the headquarters (it goes back to the yard).
function M.putAwayOwn()
  local o = ownId and scenetree.findObjectById(ownId)
  if o then
    if id == ownId then id, adopted, kindOut = nil, false, nil end
    o:delete()
  end
  ownId = nil
end

-- Use the player's own coupled trailer for this tow job (it is never deleted). True when there is one.
function M.adopt(kind)
  local vid, model = M.ownTowTrailer(kind)
  if not vid then return false end
  M.remove()
  id, kindOut, adopted = vid, kind, model
  return true
end

-- Spawn a tow trailer behind the player's vehicle with the broken-down cars on its deck (brakes on, engine off).
-- True, or false and why.
function M.spawnTow(kind, cars, wrecks)
  local ok, why = towTrailer(kind, true)
  if not ok then return false, why end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local placed = onDeck(obj(), cars, wrecks)
  if hitchWanted then hitchWanted[4] = true end   -- these cars go along when the trailer is put on the hitch
  backToPlayer(veh)
  if placed < #cars then M.remove() return false, 'a broken-down car could not be spawned' end
  return true
end

M.ROADSIDE_SPOTS = { { 10, 0 }, { 5, 4 }, { 5, -4 }, { -6, 4 }, { -6, -4 } }   -- metres ahead, right of the player
M.CAR_GAP_M = 6.5     -- between two broken-down cars, one behind the other
M.LOAD_M = 30         -- the trailer must be this close to each car to load it

-- Is the line from a to b free of buildings, walls and trees (the static world)?
local function clear(a, b)
  local d = b - a
  local len = d:length()
  if len < 0.1 then return true end
  local hit = castRayStatic(a, d / len, len + 2.5)
  return not hit or hit >= len + 2.5
end

-- Where a car can stand on the ground at p, or nil when nothing solid is below.
-- refZ: the player's height. The ground must be near it (not a roof: Jan's test had a car land on a house) and have
-- room above for a car (no roof, balcony or overhang).
local function ground(p, refZ)
  refZ = refZ or p.z
  local top = refZ + 2.5
  local d = castRayStatic(vec3(p.x, p.y, top), vec3(0, 0, -1), 10)
  if not d or d >= 10 then return nil end
  local z = top - d
  if math.abs(z - refZ) > 1.5 then return nil end
  local up = castRayStatic(vec3(p.x, p.y, z + 0.2), vec3(0, 0, 1), 3)
  if up and up < 3 then return nil end
  return vec3(p.x, p.y, z + 0.5)
end

M.HIDE_UP_M = 500      -- staged cars are spawned this high above the player, out of sight
M.HIDE_AFTER_S = 2.5   -- and hidden (physics off) this long after, once their crumple is done
M.PLACE_M = 300        -- they are put by the road when the player is this close to the pickup

-- Spawn the broken-down cars for a job out of sight (high above the player) and crumple them there. True when they
-- are out (or already were).
function M.stageTowed(cars, wrecks)
  if #towed >= #cars and M.towedAlive() >= #cars then return true end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false end
  removeTowed()
  local pos = veh:getPosition()
  for i, carModel in ipairs(cars) do
    local p = vec3(pos.x + (i - 1) * 12, pos.y, pos.z + M.HIDE_UP_M)
    if not spawnCar(carModel, p, vec3(0, 1, 0), wrecks and wrecks[i], false, true) then removeTowed() return false end
    staged[towed[#towed]] = M.HIDE_AFTER_S
  end
  backToPlayer(veh)
  return true
end

function M.towedStaged() return next(staged) ~= nil and not placedOut end
function M.towedPlaced() return placedOut end

-- Put the staged cars by the road at world x, y (the pickup), one behind the other along the road, kept damaged.
-- refZ: a height near there (the player's). True when they stand there.
function M.placeTowed(x, y, refZ)
  if placedOut or not next(staged) then return placedOut end
  for _, tid in ipairs(towed) do if (staged[tid] or 0) > 0 then return false end end   -- still crumpling
  local marker = require('cargoEarth/marker')
  local ok, ex, ey, ez = pcall(marker.roadEdge, x, y, refZ, x, y, 80)
  local cx, cy = x, y
  if ok and ex then cx, cy = ex, ey end
  -- along the road: from the nearest road's direction, else north
  local dir = vec3(0, 1, 0)
  local okR, a, b = pcall(map.findClosestRoad, vec3(cx, cy, ez or refZ), 80)
  local nodes = okR and map.getMap() and map.getMap().nodes
  if nodes and nodes[a] and nodes[b] then
    local d = nodes[b].pos - nodes[a].pos
    d.z = 0
    if d:length() > 0.1 then dir = d:normalized() end
  end
  -- only on a known road: its height tells the road from a roof; else they are spawned at the stop (spawnRoadside)
  if not (ok and ex and ez) then return false end
  local skip = {}
  for _, tid in ipairs(towed) do skip[tid] = true end
  local spots = {}
  for i = 1, #towed do
    local p = vec3(cx, cy, ez) - dir * ((i - 1) * M.CAR_GAP_M)
    -- ground near the road's height with free headroom (not loaded yet, a roof or an overhang: not here), no vehicle
    local g = ground(p, ez)
    if not g or vehicleIn(g, dir, 2.6, 1.2, skip) then return false end
    spots[i] = vec3(g.x, g.y, g.z - 0.5)
  end
  for i, tid in ipairs(towed) do
    local o = scenetree.findObjectById(tid)
    if not o then return false end
    pcall(function() o:setActive(1) end)
    if not moveKeep(o, vec3(spots[i].x, spots[i].y, spots[i].z + lowestBelow(o)), dir) then return false end
  end
  placedOut, staged = true, {}
  log('I', 'cargoEarth', string.format('broken-down cars put by the road (%d)', #towed))
  return true
end

-- The broken-down cars waiting by the road near the player (the trailer is spawned behind the player when it is not
-- out yet). Each spot is tried until one is clear of the static world: ahead of the player on the road they came by,
-- then to either side. True, or false and why.
function M.spawnRoadside(kind, cars, wrecks)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  if not obj() then
    local room, whyNot = M.roomBehind(kind)
    if not room then return false, 'no room for the trailer: ' .. whyNot end
  end
  local ok, why = towTrailer(kind)
  if not ok then return false, why end
  if placedOut and M.towedAlive() >= #cars then return true end   -- already waiting by the road (M.placeTowed)
  removeTowed()
  local pos, dir = veh:getPosition(), veh:getDirectionVector()
  dir.z = 0
  dir = dir:length() > 1e-3 and dir:normalized() or vec3(0, 1, 0)
  local right = vec3(dir.y, -dir.x, 0)
  local eye = vec3(pos.x, pos.y, pos.z + 1)
  for _, spot in ipairs(M.ROADSIDE_SPOTS) do
    local spots = {}
    for i = 1, #cars do
      local p = pos + dir * (spot[1] + (i - 1) * M.CAR_GAP_M) + right * spot[2]
      local skip = { [veh:getID()] = true }
      if id then skip[id] = true end
      local g = clear(eye, vec3(p.x, p.y, pos.z + 1)) and not vehicleIn(p, dir, 2.6, 1.2, skip) and ground(p, pos.z)
      if not g then spots = nil break end
      spots[i] = g
    end
    if spots then
      for i, carModel in ipairs(cars) do spawnCar(carModel, spots[i], dir, wrecks and wrecks[i]) end
      backToPlayer(veh)
      if #towed < #cars then removeTowed() return false, 'a broken-down car could not be spawned' end
      return true
    end
  end
  return false, 'no free spot by the road here: move on a little and stop again'
end

-- Are the waiting cars near the trailer (within maxM)? True, or false and why.
function M.towedNear(maxM)
  local trailer = obj()
  if not trailer then return false, 'The trailer is gone. Stop again here to bring it back.' end
  if #towed == 0 then return false, 'The broken-down car is gone. Stop again here to bring it back.' end
  for _, tid in ipairs(towed) do
    local o = scenetree.findObjectById(tid)
    if not o then return false, 'The broken-down car is gone. Stop again here to bring it back.' end
    if (o:getPosition() - trailer:getPosition()):length() > maxM then
      return false, 'Park the trailer next to the broken-down car first.'
    end
  end
  return true
end

-- Put the waiting cars on the trailer's deck: moved there, or (when the game cannot move them) spawned there again.
-- True, or false and why.
function M.loadTowed(cars, wrecks)
  local trailer = obj()
  if not trailer then return false, 'the trailer is gone' end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local spots, dir = deckSpots(trailer, #cars)
  local moved = #towed == #cars
  for i, tid in ipairs(moved and towed or {}) do
    local o = scenetree.findObjectById(tid)
    if not (o and moveCar(o, spots[i], dir)) then moved = false break end
    loaded[tid] = true
  end
  if moved then return true end
  removeTowed()
  local placed = onDeck(trailer, cars, wrecks)
  backToPlayer(veh)
  if placed < #cars then removeTowed() return false, 'a broken-down car could not be put on the trailer' end
  return true
end

-- Metres from the trailer to each towed car (nil for a car that is gone).
function M.towedDistances()
  local out, trailer = {}, obj()
  for i, tid in ipairs(towed) do
    local o = scenetree.findObjectById(tid)
    out[i] = (o and trailer) and (o:getPosition() - trailer:getPosition()):length() or nil
  end
  return out
end

-- The damage on the towed cars together (BeamNG's own damage value per vehicle).
function M.towedDamage()
  local sum = 0
  for _, tid in ipairs(towed) do
    local info = map and map.objects and map.objects[tid]
    sum = sum + (info and tonumber(info.damage) or 0)
  end
  return sum
end

function M.towedCount() return #towed end

-- How many of the towed cars still exist in the world (a deleted one keeps its id in the list).
function M.towedAlive()
  local n = 0
  for _, tid in ipairs(towed) do if scenetree.findObjectById(tid) then n = n + 1 end end
  return n
end

return M
