-- cargoEarth/gamecar: the game side of cargoEarth/garage (the player's car, its parts, car configs, damage).
-- Uses the game's own parts system (the vehicle's parts tree, jbeam part data) as of BeamNG 0.36+. Every call is
-- wrapped, so a game version that differs gives nil instead of an error; M.probe() writes what it found to a file.
local M = {}

local jbeamIO
local function io()
  if jbeamIO == nil then
    local ok, m = pcall(require, 'jbeam/io')
    jbeamIO = ok and m or false
  end
  return jbeamIO or nil
end

-- a game extension, loaded if it isn't yet
local function ext(name)
  local e = extensions and extensions[name] or rawget(_G, name)
  if not e and extensions and extensions.load then
    pcall(extensions.load, name)
    e = extensions[name] or rawget(_G, name)
  end
  return e
end
M.ext = ext

local function playerVeh()
  return (be and be.getPlayerVehicle and be:getPlayerVehicle(0)) or (getPlayerVehicle and getPlayerVehicle(0)) or nil
end

function M.playerId()
  local v = playerVeh()
  return v and v:getID() or nil
end

function M.vehicleState(action, path, token)
  local car = playerVeh()
  if not car then return false end
  car:queueLuaCommand(string.format(
    'extensions.load("cargoEarth_vehicleState"); extensions.cargoEarth_vehicleState.run(%q, %q, %d)', action, path, token))
  return true
end

function M.watchForces(id, token, busRide)
  local v = getObjectByID and getObjectByID(id)
  if not v then return false end
  if token then
    v:queueLuaCommand(string.format(
      'extensions.load("cargoEarth_gforce"); if extensions.cargoEarth_gforce then extensions.cargoEarth_gforce.watch(%d, %s) end', token, tostring(busRide == true)))
  else
    v:queueLuaCommand('if extensions.cargoEarth_gforce then extensions.unload("cargoEarth_gforce") end')
  end
  return true
end

-- Fuel: the vehicle side (lua/vehicle/extensions/cargoEarth/fuel.lua) reports its tanks through the
-- onCargoEarthFuel hook and sets their level on request.
function M.watchFuel(id, token)
  local v = getObjectByID and getObjectByID(id)
  if not v then return false end
  v:queueLuaCommand(string.format(
    'extensions.load("cargoEarth_fuel"); if extensions.cargoEarth_fuel then extensions.cargoEarth_fuel.watch(%d) end', token))
  return true
end

function M.setFuel(id, levels)
  local v = getObjectByID and getObjectByID(id)
  if not v then return false end
  local parts = {}
  for name, ratio in pairs(levels) do
    if type(name) == 'string' and type(ratio) == 'number' and ratio == ratio then
      parts[#parts + 1] = string.format('[%q]=%.5f', name, math.max(0, math.min(1, ratio)))
    end
  end
  if #parts == 0 then return false end
  v:queueLuaCommand('if extensions.cargoEarth_fuel then extensions.cargoEarth_fuel.set({' .. table.concat(parts, ',') .. '}) end')
  return true
end

-- The game's own pumps (stock levels and BeamNG.Earth's stations both go through freeroam/gasStations.lua refuelCar):
-- wraps refuelCar so the career hears of a refuel before the game fills the tank. Called again every few seconds, it
-- wraps a reloaded extension again and never wraps twice.
local pumpWrapper
function M.hookPumps(onRefuel)
  local gs = extensions and extensions.freeroam_gasStations or rawget(_G, 'freeroam_gasStations')   -- never loaded by us
  if type(gs) ~= 'table' or type(gs.refuelCar) ~= 'function' then return false end
  if gs.refuelCar == pumpWrapper then return true end
  local original = gs.refuelCar
  pumpWrapper = function(station, fuelTypes, veh, ...)
    local ok, id = pcall(function() return veh and veh:getID() end)
    pcall(onRefuel, ok and id or nil, station, fuelTypes)
    return original(station, fuelTypes, veh, ...)
  end
  gs.refuelCar = pumpWrapper
  return true
end

local function vehData(id)
  local vm = extensions and extensions.core_vehicle_manager or core_vehicle_manager
  if not vm then return nil end
  local read = id and vm.getVehicleData or vm.getPlayerVehicleData
  if not read then return nil end
  local ok, d = pcall(read, id)
  return ok and d or nil
end

local ownedId, replacedData

-- The config's "Body Style" from the game's vehicle list (Sedan, Hatchback, SUV, Pickup...), or the model's; nil
-- when the game gives none. Looked up once per model and config.
local styles = {}
local function styleOf(t)
  if type(t) ~= 'table' then return nil end
  if type(t['Body Style']) == 'string' then return t['Body Style'] end
  local agg = type(t.aggregates) == 'table' and t.aggregates['Body Style']
  if type(agg) == 'table' then
    local first = next(agg)
    if type(first) == 'string' then return first end
  end
end
local infos = {}
-- The game's vehicle list entries for this model and config (the config's own, the model's): looked up once.
local function infoOf(model, config)
  if type(model) ~= 'string' then return nil end
  local file = type(config) == 'table' and config.partConfigFilename
  local key = type(file) == 'string' and file:match('([^/\\]+)%.pc$') or ''
  local cacheKey = model .. '/' .. key
  if infos[cacheKey] == nil then
    infos[cacheKey] = false
    local cv = ext('core_vehicles')
    if cv and cv.getModel then
      local ok, md = pcall(cv.getModel, model)
      if ok and type(md) == 'table' then
        infos[cacheKey] = { config = type(md.configs) == 'table' and md.configs[key] or nil, model = md.model }
      end
    end
  end
  return infos[cacheKey] or nil
end

local function bodyStyle(model, config)
  if type(model) ~= 'string' then return nil end
  local file = type(config) == 'table' and config.partConfigFilename
  local key = type(file) == 'string' and file:match('([^/\\]+)%.pc$') or ''
  local cacheKey = model .. '/' .. key
  if styles[cacheKey] == nil then
    local i = infoOf(model, config)
    styles[cacheKey] = i and (styleOf(i.config) or styleOf(i.model)) or false
  end
  return styles[cacheKey] or nil
end

-- Power (the game's info value, hp) and weight (kg) of this config, from the game's vehicle list; nil when unknown
-- (a mod car without the numbers, or a config the player changed and saved under no listed name).
local function specsOf(model, config)
  local i = infoOf(model, config)
  local c = i and i.config
  if type(c) ~= 'table' then return nil end
  local power, weight = tonumber(c.Power), tonumber(c.Weight)
  if not power or not weight or power <= 0 or weight <= 0 then return nil end
  return { power = power, weight = weight }
end

local function describe(v, d)
  if not d then return nil end
  local vdata, config = d.vdata or {}, d.config or {}
  local model = vdata.model or config.model or (d.model)
  if not model then model = v and v.getJBeamFilename and v:getJBeamFilename() or nil end
  return { model = model, slotPartMap = vdata.slotPartMap, tree = config.partsTree, ioCtx = d.ioCtx,
    id = v and v:getID(), data = d, config = config, bodyStyle = bodyStyle(model, config),
    specs = specsOf(model, config) }
end

function M.vehicle() return describe(playerVeh(), vehData()) end
-- Is this vehicle model installed? false when the game lists it nowhere (a removed vehicle mod), nil when the game
-- can't answer (the career then just tries to spawn it). core_vehicles.getModel gives {} for a missing model.
function M.modelExists(model)
  if type(model) ~= 'string' or model == '' then return false end
  local cv = ext('core_vehicles')
  if not (cv and cv.getModel) then return nil end
  local ok, md = pcall(cv.getModel, model)
  if not ok or type(md) ~= 'table' then return nil end
  return md.model ~= nil
end
-- What the used-car list shows about a config without spawning it, like the game's own dealership: the config's
-- picture (core_vehicles gives a path inside the game files, e.g. /vehicles/pigeon/base.jpg; a mod car without one
-- falls back to its model picture, else nil) and the info numbers. Cached per model/key; never errors.
local infoCache = {}
local function num(v) v = tonumber(v) return v and v > 0 and v or nil end
local function word(v) if type(v) == 'table' then v = next(v) end return type(v) == 'string' and v ~= '' and v or nil end
function M.carInfo(model, key)
  if type(model) ~= 'string' or type(key) ~= 'string' then return nil end
  local id = model .. '/' .. key
  if infoCache[id] ~= nil then return infoCache[id] or nil end
  local cv = ext('core_vehicles')
  local out = false
  if cv and cv.getModel then
    local ok, md = pcall(cv.getModel, model)
    if ok and type(md) == 'table' and md.model then
      local c = type(md.configs) == 'table' and md.configs[key] or nil
      if not c then for _, x in pairs(md.configs or {}) do if type(x) == 'table' and x.key == key then c = x break end end end
      c = type(c) == 'table' and c or {}
      local m = type(md.model) == 'table' and md.model or {}
      local agg = type(c.aggregates) == 'table' and c.aggregates or {}
      local years = type(c.Years) == 'table' and c.Years or type(agg.Years) == 'table' and agg.Years or type(m.Years) == 'table' and m.Years or nil
      local pic   -- the game answers '/ui/images/appDefault.png' when a config has no picture: try the model's
      for _, p in ipairs({ c.preview or false, m.preview or false, md.preview or false }) do
        if type(p) == 'string' and p ~= '' and not p:find('appDefault', 1, true) then pic = p break end
      end
      out = {
        preview = pic,
        power = num(c.Power), torque = num(c.Torque), weight = num(c.Weight),
        topSpeed = num(c['Top Speed']) and math.floor(num(c['Top Speed']) * 3.6 + 0.5) or nil,   -- m/s -> km/h
        sprint = num(c['0-100 km/h']) and math.floor(num(c['0-100 km/h']) * 10 + 0.5) / 10 or nil,
        drivetrain = word(c.Drivetrain), gearbox = word(c.Transmission), fuel = word(c['Fuel Type']),
        body = word(c['Body Style']) or word(agg['Body Style']), brand = word(c.Brand) or word(m.Brand),
        country = word(c.Country) or word(m.Country),
        years = years and num(years.min) and { min = num(years.min), max = num(years.max) or num(years.min) } or nil,
      }
    end
  end
  infoCache[id] = out
  return out or nil
end

function M.ownedVehicle()
  local v = ownedId and getObjectByID and getObjectByID(ownedId)
  if v then return describe(v, vehData(ownedId)) end
end

function M.cargoVehicle(owned)
  local stockCareer = rawget(_G, 'career_career')
  if stockCareer and stockCareer.isActive and stockCareer.isActive() then return nil end
  local v
  if owned then v = M.ownedVehicle() else v = M.vehicle() end
  if v and v.model ~= 'unicycle' and (not owned or M.isOwned(v)) then return v.id, v.data end
end

function M.readCargoBoxes(id, callback)
  local v = getObjectByID and getObjectByID(id)
  local bridge = ext('core_vehicleBridge')
  if not (v and bridge and bridge.requestValue) then return false end
  return pcall(bridge.requestValue, v, function(result)
    if type(result) == 'table' and type(result[1]) == 'table' then callback(result[1]) end
  end, 'getCargoContainers')
end

function M.setCargoLoad(id, weights)
  local payload = {}
  for boxId, kg in pairs(weights) do payload[boxId] = { volume = kg, density = 1 } end
  return M.setFreightLoad(id, payload)
end

function M.setFreightLoad(id, loads)
  local v = getObjectByID and getObjectByID(id)
  local bridge = ext('core_vehicleBridge')
  if not (v and bridge and bridge.executeAction) then return false end
  local payload = {}
  for boxId, load in pairs(loads) do
    payload[boxId] = { containerId = boxId, volume = load.volume, density = load.density }
  end
  -- Explicit mode leaves other systems' containers alone.
  return pcall(bridge.executeAction, v, 'setCargoContainers', payload, 'updateExplicit')
end

function M.freightLoanerConfig(model, key)
  local config = jsonReadFile('vehicles/' .. model .. '/' .. key .. '.pc')
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return end
  if model == 'van' then config.parts.van_load = 'van_cargo_load_box_2XL' end
  return config
end

-- The city bus the city lends for a bus line: a stock Wentward citybus configuration, a city one when the game has one
-- (not a coach or highway one). Returns the config and its key, or nil.
M.BUS_MODEL = 'citybus'
function M.busLoanerConfig()
  local ok, info = pcall(function() return core_vehicles.getModel(M.BUS_MODEL) end)
  local configs = ok and type(info) == 'table' and type(info.configs) == 'table' and info.configs or {}
  local keys = {}
  for key in pairs(configs) do keys[#keys + 1] = key end
  table.sort(keys)
  local pick
  for _, key in ipairs(keys) do
    local k = key:lower()
    if k:find('city', 1, true) and not k:find('coach', 1, true) and not k:find('highway', 1, true) then pick = key break end
  end
  for _, key in ipairs(pick and {} or keys) do
    local k = key:lower()
    if not k:find('coach', 1, true) and not k:find('highway', 1, true) then pick = key break end
  end
  pick = pick or keys[1]
  if not pick then return nil end
  local entry = configs[pick]
  local file = type(entry) == 'table' and type(entry.pcFilename) == 'string' and entry.pcFilename
    or ('vehicles/' .. M.BUS_MODEL .. '/' .. pick .. '.pc')
  local config = jsonReadFile(file)
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return nil end
  require('cargoEarth/occupants').fillBusSeats(config)   -- a seat for every passenger
  return config, pick
end

-- The city bus's real doors (content/vehicles/citybus: controller 'bus' keeps the lever state, the pneumatic 'doors'
-- controller moves the frontDoors and rearDoors beam groups). open: true opens, false closes.
function M.busDoors(open)
  local v = playerVeh()
  if not v or not v.queueLuaCommand then return false end
  local want = open and 'true' or 'false'
  v:queueLuaCommand('local b = controller and controller.getControllerSafe and controller.getControllerSafe("bus") '
    .. 'if b and b.setState then pcall(b.setState, { bus_doorsRequestedOpen = ' .. want .. ' }) else '
    .. 'local d = controller and controller.getControllerSafe and controller.getControllerSafe("doors") '
    .. 'if d and d.setBeamGroupsValveState then pcall(d.setBeamGroupsValveState, { "frontDoors", "rearDoors" }, '
    .. (open and '-1' or '1') .. ') end end')
  return true
end

function M.watchBusDoors(id, token)
  local v = getObjectByID and getObjectByID(id)
  if not v or not v.queueLuaCommand then return false end
  if token then
    v:queueLuaCommand(string.format('extensions.load("cargoEarth_busdoors"); if extensions.cargoEarth_busdoors then extensions.cargoEarth_busdoors.watch(%d) end', token))
  else
    v:queueLuaCommand('if extensions.cargoEarth_busdoors then extensions.unload("cargoEarth_busdoors") end')
  end
  return true
end

-- The lent bus's line number, destination and next stops on its own signs (citybus controller 'bus': the event
-- bus_onRouteChange draws the destination sign and the next-stop screen without its stop triggers). data: bus.sign().
function M.busSign(data)
  local v = playerVeh()
  if not (v and v.queueLuaCommand and type(data) == 'table') then return false end
  if v:getID() ~= ownedId or (v.getJBeamFilename and v:getJBeamFilename() ~= M.BUS_MODEL) then return false end
  local text = rawget(_G, 'serialize') and serialize(data)
  if not text then return false end
  v:queueLuaCommand('if controller and controller.onGameplayEvent then pcall(controller.onGameplayEvent, '
    .. '"bus_onRouteChange", ' .. text .. ') end')
  return true
end

------------------------------------------------------------------------------------------ people in the seats
local function seatSystem() return rawget(_G, 'gameplay_seatOccupants') or ext('gameplay_seatOccupants') end

-- Seated passengers in the player's vehicle: n people (BeamNG's dummy occupants, real weight) in the order the seed
-- gives. Returns how many sit, or nil when the vehicle has no seat system.
function M.busPassengers(n, seed)
  local so, v = seatSystem(), playerVeh()
  if not (so and so.getSeats and so.setDummyOccupant and v) then return nil end
  local id = v:getID()
  -- only the lent bus itself: not a car the player switched to during the line
  if id ~= ownedId or (v.getJBeamFilename and v:getJBeamFilename() ~= M.BUS_MODEL) then return nil end
  if so.usesSeatSystem and not so.usesSeatSystem(id) then return nil end
  local okSeats, seats = pcall(so.getSeats, id)
  if not okSeats or type(seats) ~= 'table' then return nil end
  local occupants = require('cargoEarth/occupants')
  local plan = occupants.plan(seats, n, seed)
  for _, seatId in ipairs(plan.remove) do pcall(so.clearDummyOccupant, id, seatId) end
  for _, seatId in ipairs(plan.add) do pcall(so.setDummyOccupant, id, seatId, occupants.PASSENGER_KG) end
  return plan.shown
end

-- A taxi's passengers in the player's own car: n people (0 empties the seats). They board only while the player drives
-- the career car; emptying always works on the career car, even after the player switched to another one. Returns how
-- many sit, or nil when the car has no seat system (most mod cars) or is not the career car.
function M.carPassengers(n, seed)
  local so, v = seatSystem(), playerVeh()
  if not (so and so.getSeats and so.setDummyOccupant and ownedId) then return nil end
  if n > 0 and not (v and v:getID() == ownedId) then return nil end
  local id = ownedId
  if so.usesSeatSystem and not so.usesSeatSystem(id) then return nil end
  local okSeats, seats = pcall(so.getSeats, id)
  if not okSeats or type(seats) ~= 'table' then return nil end
  local occupants = require('cargoEarth/occupants')
  local plan = occupants.plan(seats, n, seed)
  for _, seatId in ipairs(plan.remove) do
    local ok, result = pcall(so.clearDummyOccupant, id, seatId)
    if not ok or result == false then return nil end
  end
  for _, seatId in ipairs(plan.add) do
    local ok, result = pcall(so.setDummyOccupant, id, seatId, occupants.PASSENGER_KG)
    if not ok or result == false then return nil end
  end
  return plan.shown
end

-- Passenger seats in the car the player drives (taxi rides): the seats besides the driver's, or nil when the car has no
-- seat system (most mod cars), so its seats are unknown.
function M.freeSeats()
  local so, v = seatSystem(), playerVeh()
  if not (so and so.getSeats and v) then return nil end
  local id = v:getID()
  if so.usesSeatSystem then
    local okUses, uses = pcall(so.usesSeatSystem, id)
    if not okUses or not uses then return nil end
  end
  local okSeats, seats = pcall(so.getSeats, id)
  if not okSeats or type(seats) ~= 'table' or #seats == 0 then return nil end
  return require('cargoEarth/occupants').freeSeats(seats)
end

-- After the mod spawned, swapped or respawned the player's car: once the game knows its seats, the player sits in the
-- driver's seat (so the driver figure shows, as in any stock car). Tried for a few seconds, then left alone (the
-- player may choose to stand up from the game's own seat menu).
local seatWatch
function M.watchSeat() local now = os.clock() seatWatch = { fromT = now + 1, untilT = now + 8 } end

function M.seatTick()
  if not seatWatch then return end
  local now = os.clock()
  if now > seatWatch.untilT then seatWatch = nil return end
  if now < seatWatch.fromT then return end   -- the game's own seating runs first, on the spawn
  local so, v = seatSystem(), playerVeh()
  if not (so and so.requestEnterBestSeat and v) then return end
  local id = v:getID()
  local okUses, uses = pcall(function() return so.usesSeatSystem and so.usesSeatSystem(id) end)
  if not okUses then seatWatch = nil return end
  local d = vehData(id)
  if not (d and d.vdata) then return end   -- still loading
  if not uses then seatWatch = nil return end   -- a car without seat occupants (most mod cars): nothing to show
  local okP, presence = pcall(function() return so.getPlayerPresence and so.getPlayerPresence(0) end)
  if okP and require('cargoEarth/occupants').needsSeat(true, presence, id) then
    seatWatch = nil   -- one go: a car that refuses is left alone
    pcall(so.requestEnterBestSeat, id, 0)
  end
end

function M.vehicleData(id) return vehData(id) end

function M.partsTarget()
  local target = extensions and extensions.core_vehicle_configTarget
  local id = target and target.getTargetVehicleId and target.getTargetVehicleId()
  if id then
    if M.ownsVehicleId(id) then return M.ownedVehicle() end
    return nil
  end
  return M.vehicle()
end

local PARTS_ROUTE = 'pause.vehicle.configurationcombined'
local LEGACY_PARTS_ROUTE = 'menu.vehicleconfig'

function M.partsEditorOpen()
  local router = extensions and extensions.ui_router
  local current = router and router.getCurrent and router.getCurrent()
  local name = current and ((current.resolved and current.resolved.name) or (current.request and current.request.name))
  return type(name) == 'string' and (name == PARTS_ROUTE or name:sub(1, #PARTS_ROUTE + 1) == PARTS_ROUTE .. '.'
    or name == LEGACY_PARTS_ROUTE or name:sub(1, #LEGACY_PARTS_ROUTE + 1) == LEGACY_PARTS_ROUTE .. '.')
end

function M.openParts()
  local router = ext('ui_router')
  local failure = 'Could not open the parts editor. You can also open Vehicle Config > Parts from BeamNG’s menu.'
  if not router or not router.navigate then return false, failure end
  local id = M.playerId()
  if not M.ownsVehicleId(id) then return false, 'Sit in your career car first.' end

  local target = extensions and extensions.core_vehicle_configTarget
  if target and target.begin and not target.begin(id, { playerId = 0, returnRoute = 'pause' }) then return false, failure end
  local ok, result = pcall(router.navigate, PARTS_ROUTE, { vehicleId = id, playerId = 0 },
    { preferredScope = 'pause-tab-combined-parts' })
  if ok and result and result.success then return true end
  if target and target.clear then target.clear('cargoEarth') end
  if ok and result and result.reason == 'route_not_found' then
    ok, result = pcall(router.navigate, LEGACY_PARTS_ROUTE .. '.parts')
    if ok and result and result.success then return true end
  end
  return false, failure
end

function M.leavePartsEditor()
  if not M.partsEditorOpen() then return true end
  local ok, result = pcall(extensions.ui_router.navigate, 'play')
  -- The native editor can prompt to apply or discard un-applied selections before leaving.
  if ok and result and (result.success or result.reason == 'guard_blocked_exit') then return true end
  return false, 'Use BeamNG’s Back control to leave Vehicle Config, then resume driving.'
end

function M.ownsVehicleId(id) return ownedId ~= nil and id == ownedId end
function M.isOwned(v) return M.ownsVehicleId(v.id) and v.data ~= replacedData end
function M.clearOwnership() ownedId, replacedData = nil, nil end

function M.captureConfig(v)
  local c = v.config
  if type(c.partsTree) ~= 'table' then return nil end
  return deepcopy({ format = 2, model = v.model, partsTree = c.partsTree, vars = c.vars, paints = c.paints,
    licenseName = c.licenseName, mainPartName = c.mainPartName })
end

function M.part(ioCtx, name)
  local j = io()
  if not j or not ioCtx then return nil end
  local ok, p = pcall(j.getPart, ioCtx, name)
  return ok and p or nil
end

local slotMapCache = { ctx = nil, map = nil, t = 0 }
function M.compatible(ioCtx, def)
  local j = io()
  if not j or not ioCtx then return {} end
  local now = os.clock()
  if slotMapCache.ctx ~= ioCtx or now - slotMapCache.t > 5 then
    local ok, m = pcall(j.getAvailableSlotNameMap, ioCtx)
    slotMapCache = { ctx = ioCtx, map = ok and m or nil, t = now }
  end
  if j.getCompatiblePartNamesForSlot then
    local ok, list = pcall(j.getCompatiblePartNamesForSlot, ioCtx, def, slotMapCache.map)
    if ok and type(list) == 'table' then return list end
  end
  local t = def.type or def.name
  return (slotMapCache.map and t and slotMapCache.map[t]) or {}
end

function M.applyTree(tree)
  local pm = extensions and extensions.core_vehicle_partmgmt or core_vehicle_partmgmt
  if not pm or not pm.setPartsTreeConfig then error('core_vehicle_partmgmt.setPartsTreeConfig missing') end
  M.applyingParts = true
  local ok, err = pcall(pm.setPartsTreeConfig, tree)
  M.applyingParts = false
  if not ok then error(err) end
end

function M.applyConfig(vehicle, config)
  local v = playerVeh()
  if not v or v:getID() ~= vehicle.id or vehData(vehicle.id) ~= vehicle.data or not M.isOwned(vehicle) then
    error('The vehicle is no longer active')
  end
  local serialized = serialize(config)
  local previousData = replacedData
  replacedData, M.spawning = vehicle.data, true
  local ok, err = pcall(v.respawn, v, serialized)
  M.spawning = false
  if not ok then
    replacedData = previousData
    error(err)
  end
end

-- Respawns the player's car with its own config after edit(config) changed it (the dash phone fits itself this way).
-- The career keeps owning the car, and the game's jbeam cache is cleared so a changed generated part is built again.
function M.respawnPlayer(edit)
  local v = playerVeh()
  if not v then error('no player vehicle') end
  local id = v:getID()
  local d = vehData(id)
  if not d or type(d.config) ~= 'table' then error('no vehicle data') end
  local config = deepcopy(d.config)
  edit(config)
  local loader = package and package.loaded and package.loaded['jbeam/loader']
  if type(loader) == 'table' and loader.onFileChanged then pcall(loader.onFileChanged) end
  local previousData = replacedData
  if ownedId == id then replacedData = d end
  M.spawning = true
  local ok, err = pcall(v.respawn, v, serialize(config))
  M.spawning = false
  if not ok then
    replacedData = previousData
    error(err)
  end
  M.watchSeat()
end

local configsCache
M.lastError = nil

local function addConfig(out, c, model, key)
  if type(c) ~= 'table' then return end
  model = c.model_key or model or c.model
  key = c.key or key
  if type(model) ~= 'string' or type(key) ~= 'string' then return end
  local agg = type(c.aggregates) == 'table' and c.aggregates or {}
  local value = tonumber(c.Value) or tonumber(c.value)
  if not value and type(agg.Value) == 'table' then value = tonumber(agg.Value.min) end
  local name = (c.Name or model) .. (c.Configuration and (' ' .. c.Configuration) or '')
  local typ = c.Type
  if not typ and type(agg.Type) == 'table' then typ = next(agg.Type) end
  local style = c['Body Style']
  if type(style) ~= 'string' and type(agg['Body Style']) == 'table' then style = next(agg['Body Style']) end
  out[#out + 1] = { model = model, key = key, name = name, brand = c.Brand, value = value, type = typ,
    bodyStyle = type(style) == 'string' and style or nil }
end

function M.configs()
  if configsCache and #configsCache > 0 then return configsCache end
  local cv = ext('core_vehicles')
  if not cv then M.lastError = 'core_vehicles not available' return {} end
  local out = {}
  if cv.getConfigList then
    local ok, list = pcall(cv.getConfigList)
    if ok and type(list) == 'table' then
      local src = type(list.configs) == 'table' and list.configs or list
      for k, c in pairs(src) do addConfig(out, c, nil, type(k) == 'string' and k or nil) end
    else
      M.lastError = 'getConfigList: ' .. tostring(list)
    end
  end
  -- older / other versions: every model's own config list
  if #out == 0 and cv.getModelList and cv.getModel then
    local ok, ml = pcall(cv.getModelList)
    local models = ok and type(ml) == 'table' and (ml.models or ml) or {}
    for k, mdl in pairs(models) do
      local mkey = type(mdl) == 'table' and (mdl.key or mdl.model_key) or (type(k) == 'string' and k) or nil
      if mkey then
        local ok2, md = pcall(cv.getModel, mkey)
        if ok2 and type(md) == 'table' and type(md.configs) == 'table' then
          for ck, c in pairs(md.configs) do addConfig(out, c, mkey, type(ck) == 'string' and ck or nil) end
        end
      end
    end
  end
  if #out == 0 then M.lastError = M.lastError or 'no car configs found'
  else configsCache = out end
  if log then log('I', 'cargoEarth', 'car configs found: ' .. #out .. (M.lastError and (' (' .. M.lastError .. ')') or '')) end
  return out
end

function M.spawn(model, key, config, vehicleId, position)
  local cv = ext('core_vehicles')
  if not cv then error('core_vehicles not available') end
  local cfg = config or (key and (key:find('%.pc$') and key or ('vehicles/' .. model .. '/' .. key .. '.pc')))
  local veh = vehicleId and getObjectByID(vehicleId) or nil
  if vehicleId and not veh then error('The career car is no longer in this level') end
  veh = veh or playerVeh()
  local spawn = veh and cv.replaceVehicle or cv.spawnNewVehicle
  if not spawn then error('Vehicle spawn function missing') end
  local options = { config = cfg, autoEnterVehicle = not vehicleId }
  if not veh and position and position.x and position.y and position.z then
    options.pos = vec3(position.x, position.y, position.z)
    options.safeSpawn = true
  end
  local previousData = veh and vehData(veh:getID())
  M.spawning = true
  local ok, spawned = pcall(spawn, model, options, veh)
  M.spawning = false
  if not ok then error(spawned) end
  if not spawned then error('BeamNG refused to spawn ' .. tostring(model)) end
  ownedId, replacedData = spawned:getID(), previousData
  M.watchSeat()
end

function M.repair()
  local v = playerVeh()
  if not v then error('no player vehicle') end
  if v.resetBroken then v:resetBroken() else v:queueLuaCommand('recovery.startRecovering() recovery.stopRecovering()') end
end

-- A used car's mileage and paint wear through BeamNG's part condition system.
function M.applyCondition(km, condition)
  local v = playerVeh()
  if not v or not v.queueLuaCommand then return end
  v:queueLuaCommand(string.format(
    'if partCondition and partCondition.initConditions then partCondition.initConditions(nil, %d, 1, %.2f) end',
    math.floor((km or 0) * 1000), math.max(0, math.min(1, condition or 1))))
end

-- The game's damage number for the player's car (it drops to 0 on reset / repair), or nil.
function M.damage(id)
  if not (map and map.objects) then return nil end
  local v = not id and playerVeh()
  local o = map.objects[id or (v and v:getID())]
  return o and tonumber(o.damage) or nil
end

-- Writes what the parts system gives for the player's car to /settings/cargoEarth/garage_probe.json.
function M.probe(garage)
  local out = { time = os.date('%Y-%m-%d %H:%M:%S'), version = beamng_versiond or (getVersion and getVersion()) }
  local v = M.vehicle()
  out.model = v and v.model
  out.hasTree, out.hasIoCtx = v and v.tree ~= nil, v and v.ioCtx ~= nil
  local n = 0
  for _ in pairs(v and v.slotPartMap or {}) do n = n + 1 end
  out.slotPaths = n
  local slots = garage and v and garage.slots(M, garage.new()) or nil
  out.shopSlots = slots and #slots or 0
  out.sample = {}
  for i = 1, math.min(12, slots and #slots or 0) do
    local s = slots[i]
    out.sample[i] = { path = s.path, title = s.title, installed = s.installed and s.installed.name,
      value = s.installed and s.installed.value, options = #s.options }
  end
  out.configs = #M.configs()
  out.damage = M.damage()
  if jsonWriteFile then jsonWriteFile('/settings/cargoEarth/garage_probe.json', out, true) end
  return out
end

-- A breakdown: the player's engine is switched off (on = true) and kept off until the roadside help is paid; false
-- turns the ignition back on so the engine can be started again.
function M.stall(on)
  local v = playerVeh()
  if not v then return false end
  v:queueLuaCommand(on and 'if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(0) end'
    or 'if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(2) end')
  return true
end

-- The game's road graph (BeamNG.Earth's traffic graph) and the road edge nearest a world point: graph, a, b, metres.
function M.road(x, y, z)
  if not (map and map.findClosestRoad and map.getMap and vec3) then return nil end
  local ok, a, b, d = pcall(map.findClosestRoad, vec3(x, y, z or 0))
  if not ok or a == nil or b == nil then return nil end
  return map.getMap(), a, b, tonumber(d) or math.huge
end

function M._reset() configsCache, jbeamIO, infoCache = nil, nil, {} end

return M

