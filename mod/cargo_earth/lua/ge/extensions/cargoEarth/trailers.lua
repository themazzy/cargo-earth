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

-- Tow trailers: the first stock model found is used (override with trailerModels.cartrailer / .flatbed).
M.TOW_MODELS = { cartrailer = { 'cartrailer', 'tsfb', 'boxutility_large' }, flatbed = { 'flatbed' } }
M.DECK_LIFT = 0.4    -- metres above the trailer's top a towed car is let down from

function M.configure(cfg)
  for k, v in pairs((cfg and cfg.trailerModels) or {}) do
    if type(v) == 'table' and type(v.model) == 'string' then M.models[k] = v end
  end
end

local function obj()
  if not id then return nil end
  local o = scenetree.findObjectById(id)
  if not o then id = nil end
  return o
end

function M.exists() return obj() ~= nil end

function M.id() return obj() and id or nil end

local function freightConfig(kind)
  if kind == 'fluid' then
    return 'tanker', 'vehicles/tanker/career_shuffleboard_empty_long.pc'
  end
  local config = jsonReadFile('vehicles/dryvan/48ft.pc')
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return end
  local parts = config.parts
  parts.dryvan_load_F = 'dryvan_load_F_cargo_load_box_4XL'
  if kind == 'dryBulk' then
    for _, suffix in ipairs({ 'FA', 'FB', 'FC', 'FD' }) do
      parts['cargo_load_box_XL_' .. suffix .. '_90deg'] = 'cargo_load_aggregate_box_XL_' .. suffix .. '_90deg'
    end
  else
    parts.dryvan_load_M = 'dryvan_load_M_cargo_load_box_8xl'
    parts.dryvan_load_R = 'dryvan_load_R_cargo_load_box_4XL'
  end
  return 'dryvan', config
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
  local pos, dir = veh:getPosition(), veh:getDirectionVector()
  dir.z = 0
  if dir:length() < 1e-3 then return false, 'vehicle has no direction' end
  dir = dir:normalized()
  local p = pos - dir * M.BEHIND_M
  -- set it on the ground: a ray down from above
  local d = castRayStatic(vec3(p.x, p.y, p.z + 20), vec3(0, 0, -1), 60)
  if d and d < 60 then p.z = p.z + 20 - d + 0.3 else p.z = pos.z + 0.5 end
  M.remove()
  local opt = { pos = p, rot = quatFromDir(dir, vec3(0, 0, 1)), autoEnterVehicle = false }
  if m.config and m.config ~= '' then opt.config = m.config end
  local ok, v = pcall(core_vehicles.spawnNewVehicle, m.model, opt)
  if not ok or not v then return false, 'could not spawn ' .. tostring(m.model) .. ': ' .. tostring(v) end
  id = v:getID()
  -- spawning can switch the camera to the new vehicle: give it back
  if be and be.enterVehicle then pcall(be.enterVehicle, be, 0, veh) end
  return true
end

function M.coupled(vehicleId)
  local couplings = core_vehicles and core_vehicles.vehsCouplings
  local attached = couplings and couplings[vehicleId]
  return id ~= nil and attached ~= nil and attached[id] == true
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
  towed = {}
end

function M.remove()
  removeTowed()
  local o = obj()
  if o then o:delete() end
  id = nil
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
    if M.modelExists(m) then return m end
  end
end

-- Parked, engine off, hazard lights on (vehicle-side Lua, each call guarded).
local PARK_CMD = 'if input and input.event then input.event("parkingbrake", 1, 2) end '
  .. 'if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(0) end '
  .. 'if electrics and electrics.set_warn_signal then pcall(electrics.set_warn_signal, true) end'

local function spawnCar(model, p, dir)
  local ok, v = pcall(core_vehicles.spawnNewVehicle, model, { pos = p, rot = quatFromDir(dir, vec3(0, 0, 1)),
    autoEnterVehicle = false })
  if not ok or not v then return false end
  towed[#towed + 1] = v:getID()
  v:queueLuaCommand(PARK_CMD)
  return true
end

local function backToPlayer(veh)
  if be and be.enterVehicle and veh then pcall(be.enterVehicle, be, 0, veh) end
end

-- The cars on the deck of the trailer that is out (let down from DECK_LIFT above its top). How many were placed.
local function onDeck(trailer, cars)
  local pos, dir = trailer:getPosition(), trailer:getDirectionVector()
  dir.z = 0
  dir = dir:length() > 1e-3 and dir:normalized() or vec3(0, 1, 0)
  local top = pos.z + 1.2
  local okBox, box = pcall(function() return trailer:getSpawnWorldOOBB() end)
  if okBox and box then
    local okTop, z = pcall(function() return box:getCenter().z + box:getHalfExtents().z end)
    if okTop and type(z) == 'number' then top = z end
  end
  local n, placed = #cars, 0
  for i, carModel in ipairs(cars) do
    local along = n > 1 and (i == 1 and 3.2 or -3.2) or 0
    if spawnCar(carModel, vec3(pos.x, pos.y, top + M.DECK_LIFT) + dir * along, dir) then placed = placed + 1 end
  end
  return placed
end

-- Make sure the tow trailer for this kind is out (spawned behind the player when it is not). True, or false and why.
local function towTrailer(kind, fresh)
  if obj() and not fresh then return true end
  local model, config = M.towModel(kind)
  if not model then return false, 'this game has no ' .. tostring(kind) .. ' trailer' end
  M.models[kind] = { model = model, config = config }
  return M.spawn(kind)
end

-- Spawn a tow trailer behind the player's vehicle with the broken-down cars on its deck (brakes on, engine off).
-- True, or false and why.
function M.spawnTow(kind, cars)
  local ok, why = towTrailer(kind, true)
  if not ok then return false, why end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  local placed = onDeck(obj(), cars)
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
local function ground(p)
  local d = castRayStatic(vec3(p.x, p.y, p.z + 20), vec3(0, 0, -1), 60)
  if d and d < 60 then return vec3(p.x, p.y, p.z + 20 - d + 0.5) end
end

-- The broken-down cars waiting by the road near the player (the trailer is spawned behind the player when it is not
-- out yet). Each spot is tried until one is clear of the static world: ahead of the player on the road they came by,
-- then to either side. True, or false and why.
function M.spawnRoadside(kind, cars)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  local ok, why = towTrailer(kind)
  if not ok then return false, why end
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
      local g = clear(eye, vec3(p.x, p.y, pos.z + 1)) and ground(p)
      if not g then spots = nil break end
      spots[i] = g
    end
    if spots then
      for i, carModel in ipairs(cars) do spawnCar(carModel, spots[i], dir) end
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

-- Put the waiting cars on the trailer's deck. True, or false and why.
function M.loadTowed(cars)
  local trailer = obj()
  if not trailer then return false, 'the trailer is gone' end
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  removeTowed()
  local placed = onDeck(trailer, cars)
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
