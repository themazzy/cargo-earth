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

function M.watchForces(id, token)
  local v = getObjectByID and getObjectByID(id)
  if not v then return false end
  if token then
    v:queueLuaCommand(string.format(
      'extensions.load("cargoEarth_gforce"); if extensions.cargoEarth_gforce then extensions.cargoEarth_gforce.watch(%d) end', token))
  else
    v:queueLuaCommand('if extensions.cargoEarth_gforce then extensions.unload("cargoEarth_gforce") end')
  end
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

local function describe(v, d)
  if not d then return nil end
  local vdata, config = d.vdata or {}, d.config or {}
  local model = vdata.model or config.model or (d.model)
  if not model then model = v and v.getJBeamFilename and v:getJBeamFilename() or nil end
  return { model = model, slotPartMap = vdata.slotPartMap, tree = config.partsTree, ioCtx = d.ioCtx,
    id = v and v:getID(), data = d, config = config }
end

function M.vehicle() return describe(playerVeh(), vehData()) end
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
  out[#out + 1] = { model = model, key = key, name = name, brand = c.Brand, value = value, type = typ }
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

function M._reset() configsCache, jbeamIO = nil, nil end

return M
