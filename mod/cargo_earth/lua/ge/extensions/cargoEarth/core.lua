-- cargoEarth_core: real-world delivery jobs on BeamNG.Earth, in two modes:
--   courier  (default): food orders from real restaurants to real house addresses, in any car, a few km each
--   trucking: cargo between real depots (sawmills, breweries, car plants...) with a trailer, tens to hundreds of km
-- Phases: idle (jobs offered) -> toPickup -> toDelivery -> idle. Money is in CZK, shared by both modes.
-- Everything is clicked on the phone (the UI app): orders, the garage and the settings. The debug window opens from
-- the phone's settings (or the console: extensions.cargoEarth_core.toggleWindow()). No key bindings.
local M = {}
M.VERSION = '0.8.0'      -- the mod's version (package.json has the same; the support report shows it)
M.dependencies = { 'ui_imgui' }

local jobs = require('cargoEarth/jobs')
local food = require('cargoEarth/food')
local cargo = require('cargoEarth/cargo')
local earth = require('cargoEarth/earth')
local trailers = require('cargoEarth/trailers')
local ui = require('cargoEarth/ui')
local marker = require('cargoEarth/marker')
local helper = require('cargoEarth/helper')
local garage = require('cargoEarth/garage')
local gamecar = require('cargoEarth/gamecar')
local progress = require('cargoEarth/progress')
local fleet = require('cargoEarth/fleet')
local haul = require('cargoEarth/haul')
local careerClock = require('cargoEarth/clock')
local economy = require('cargoEarth/economy')
local home = require('cargoEarth/home')
local employment = require('cargoEarth/employment')
local persistence = require('cargoEarth/persistence')
local rating = require('cargoEarth/rating')
local fuel = require('cargoEarth/fuel')
local records = require('cargoEarth/stats')
local cameras = require('cargoEarth/cameras')
local speedlimit = require('cargoEarth/speedlimit')
local upkeep = require('cargoEarth/upkeep')
local special = require('cargoEarth/special')
local resupply = require('cargoEarth/resupply')
local tow = require('cargoEarth/tow')
local firm = require('cargoEarth/firm')
local parcel = require('cargoEarth/parcel')
local borders = require('cargoEarth/borders')
local uiLayout = require('cargoEarth/layout')
local currency = require('cargoEarth/currency')
local dash = require('cargoEarth/dash')

local DATA_DIR = '/lua/ge/extensions/cargoEarth/data/'
local SAVE = '/settings/cargoEarth/career.json'
local CONFIG = '/settings/cargoEarth/config.json'

-- per mode: arrival radius (m), seconds standing still there, cancel fee (CZK)
M.RULES = {
  courier = { arriveM = 30, stopS = 5, cancelFee = 50 },
  trucking = { arriveM = 35, stopS = 3, cancelFee = 2000 },
}
M.COUNTRY_S = 5   -- seconds between border checks
M.TOW_RULES = { arriveM = 30, stopS = 3, cancelFee = 200 }
M.TOW_RELOAD_FEE = 150  -- putting a car that slid off back on the trailer
M.STOP_SPEED = 1.5     -- m/s that counts as standing still
M.random = function(...) return math.random(...) end   -- (tests replace it)
M.INTACT_TIP = 0.06      -- a customer tips this share of the pay when the order arrives in perfect condition
M.PARCEL_TIP_SHARE = 0.5 -- a parcel route's tip for speed is figured on this share of its pay
M.ROAD_M = 20          -- the car is on the road edge this close (else: a car park, a field; no limit shown)
M.LIMIT_S = 0.5        -- the limit under the car is read this often
M.OVER_KMH = 3         -- the phone's sign turns red this far over the limit
M.CAMERA_ROAD_M = 600  -- a camera without a mapped limit takes its road's limit from this close
M.LATE_PER_MIN = { courier = 0.05, trucking = 0.02 }   -- share of pay lost per minute late (food goes cold faster)
M.LATE_FLOOR = 0.5     -- never less than this share of the pay
M.TICK_S = 0.5
M.SAVE_RETRY_S = 5      -- try again if the last career checkpoint could not be written
M.RESUME_TIMEOUT_S = 120  -- allow time for BeamNG.Earth to stream the saved area
M.RESUME_NEAR_M = 3       -- skip teleport if already at the saved spot
M.RESUME_ARRIVAL_M = 100  -- BeamNG.Earth may set the car down on nearby safe ground
-- several orders at once (courier), like the real apps' batched orders: a second one rings while you carry the first,
-- from the same restaurant or with a pickup close by, going to the same part of town
M.MAX_ORDERS = 2           -- default; the phone's settings allow 1 to 3
M.BATCH_PAY = 0.85         -- a batched order pays this share (the ride is shared)
M.BATCH_PICKUP_KM = 1.5    -- its restaurant within this of you (or the same restaurant as an order not picked up yet)
M.BATCH_DROP_KM = 3        -- its customer within this of a customer you already have
M.PHONE = {
  pingMinS = 8,        -- seconds before the next order rings, at least
  pingMaxS = 30,       -- and at most
  acceptS = 25,        -- seconds to accept an order before it goes to another courier
  retryS = 10,         -- no order found: ask again after this
  doneShowS = 8,       -- the delivery summary stays on the phone this long
  declinedKeep = 40,   -- declined orders not offered again (the last n)
}

local S = {
  idx = nil, fidx = nil, packInfo = '', loadError = nil, mode = 'courier',
  phase = 'idle', job = nil, orders = {}, offers = {}, offerStats = nil, offeredAt = nil,
  optsByMode = { courier = {}, trucking = {} }, opts = nil,
  career = { money = 0, delivered = 0, km = 0, history = {}, garage = nil },
  stopT = 0, tick = 0, dist = nil, log = {}, config = {}, window = false, phoneHidden = false,
  clock = 0,
  -- the phone: orders ring in one at a time while online
  phone = { online = false, incoming = nil, nextPingAt = 0, declined = {}, lastDone = nil },
}
S.opts = S.optsByMode.courier

-- The last warnings and errors, for the support report the phone copies (Settings > Help).
M.PROBLEMS_KEPT = 20
local problems = {}
local function problem(level, msg)
  log(level, 'cargoEarth', msg)
  problems[#problems + 1] = os.date('%H:%M:%S') .. ' ' .. level .. ' ' .. tostring(msg)
  if #problems > M.PROBLEMS_KEPT then table.remove(problems, 1) end
end
S.career.garage = garage.new()
local carSeenAt = 0
local conditionAt, usedAt, previewAt
local fuelWatch, fuelToken, fuelPending, fuelNearAt = nil, 0, nil, 0
local gamePump, pumpHookAt = nil, 0   -- a refuel started at one of the game's own pumps
local forceWatch, forceToken = nil, 0
local cams = cameras.index()
local roadLimit = { at = -math.huge }
local function camerasOn() return S.career.garage.started and not S.career.camerasOff end

function M.elapsed(job) return careerClock.elapsed(S.career, job) end

local PHONE_SOUNDS = {
  offer = 'event:>UI>Missions>Info_Open',
  accepted = 'event:>UI>Main>Click_Tonal_01',
  pickup = 'event:>UI>Career>Buy_02',
  delivered = 'event:>UI>Career>EndScreen_Receive_Money',
  failed = 'event:>UI>Career>Drift_Canceled',
  cancelled = 'event:>UI>Main>Cancel',
  expired = 'event:>UI>Main>Back',
}

-- Play from the game transition so the sound is heard once, even if the phone is folded.
local function phoneSound(name)
  if Engine and Engine.Audio and Engine.Audio.playOnce then
    pcall(Engine.Audio.playOnce, 'AudioGui', PHONE_SOUNDS[name])
  end
end

local function say(text, seconds)
  text = currency.localize(text, S.career and S.career.currency)
  table.insert(S.log, 1, os.date('%H:%M:%S') .. '  ' .. text)
  while #S.log > 30 do table.remove(S.log) end
  earth.notify(text, seconds or 6)
  log('I', 'cargoEarth', text)
end

local function releaseStorage()
  local storage = S.storage
  S.storage = nil
  if not storage or not next(storage.applied) then return end
  local empty = {}
  for id in pairs(storage.applied) do empty[id] = 0 end
  M.G.setCargoLoad(storage.id, empty)
end

local function refreshStorage()
  local G = M.G
  local id, data
  if G.cargoVehicle then id, data = G.cargoVehicle(S.career.garage.started) end
  local storage = S.storage
  if storage and (storage.id ~= id or storage.data ~= data) then
    releaseStorage()
    storage = nil
  end
  if not id then return end
  if not storage then
    storage = { id = id, data = data, applied = {}, deadline = S.clock + 2 }
    S.storage = storage
  end
  if not storage.rows and S.clock >= (storage.readAt or 0) then
    storage.readAt = S.clock + 2
    if not G.readCargoBoxes(id, function(rows)
      -- A delayed reply from a different vehicle or configuration is stale.
      if S.storage == storage then storage.rows, storage.boxes = rows, cargo.boxes(rows) end
    end) then
      storage.boxes = {}
    end
  end
  if not storage.boxes and S.clock >= storage.deadline then storage.boxes = {} end
  return storage
end

local function storagePlan()
  local storage = S.storage
  if storage and storage.boxes then return cargo.layout(storage.boxes, S.orders) end
end

local function syncStorage()
  local plan = storagePlan()
  if not plan then return end
  local storage = S.storage
  local g = S.career.garage
  if g.car and not S.parts and not g.pendingUsed and garage.inOwnCar(M.G, g) then
    g.car.storageSlots, g.car.boxCount = plan.capacity, #storage.boxes
  end
  local delta = {}
  for id, kg in pairs(plan.weights) do
    if storage.applied[id] ~= kg then delta[id] = kg end
  end
  for id in pairs(storage.applied) do
    if not plan.weights[id] then delta[id] = 0 end
  end
  if next(delta) and M.G.setCargoLoad(storage.id, delta) then storage.applied = plan.weights end
end

local function freightCarrier()
  local g = S.career.garage
  if not g.started or g.pendingUsed or not garage.inOwnCar(M.G, g) then return end
  local v = M.G.vehicle()
  return v, haul.carrier(v)
end

local function freightSettingsTier()
  local _, tier = freightCarrier()
  return tier or haul.state(S.career).unlocked
end

local function freightOptions(tier)
  local o = {}
  for k, v in pairs(S.opts) do o[k] = v end
  local range = o.freightRanges and o.freightRanges[tier] or {}
  o.minKm = range.minKm or (tier == 'semi' and o.minKm or nil)
  o.maxKm = range.maxKm or (tier == 'semi' and o.maxKm or nil)
  return o
end

local function clearFreight()
  local load = S.freightLoad
  S.freightLoad, S.freightStatus = nil, nil
  if load and load.command and load.plan and load.command ~= 'unloadDone'
    and (not M.G.vehicleData or M.G.vehicleData(load.id) == load.data) then
    M.G.setFreightLoad(load.id, haul.empty(load.plan))
  end
end

-- A requested bridge update is followed by a new read, so a pickup or drop-off only completes after
-- BeamNG has moved the physical load. Numeric container IDs are only kept for the current vehicle instance.
local function workFreight(job, unload)
  local v, tier = freightCarrier()
  if not v or tier ~= job.haul.tier or (job.haul.model and v.model ~= job.haul.model) then
    S.freightStatus = 'Use the truck you accepted this haul with.'
    return false
  end
  local G, id, data = M.G, v.id, v.data
  if tier == 'semi' then
    id = trailers.id()
    if not id or not trailers.coupled(v.id) then
      S.freightStatus = id and 'Couple the assigned trailer.' or 'Restore the assigned trailer.'
      return false
    end
    data = G.vehicleData and G.vehicleData(id)
    if G.vehicleData and not data then return false end
  end
  if not id or not G.readCargoBoxes or not G.setFreightLoad then return false end
  local state = S.freightLoad
  if not state or state.job ~= job or state.id ~= id or state.data ~= data then
    if state then clearFreight() end
    state = { job = job, id = id, data = data, readAt = 0 }
    S.freightLoad = state
  end
  -- A parcel route loads what is still to deliver, and each stop but the last takes out only its own parcels.
  local command = unload and 'unload' or 'load'
  local keepSlots
  if job.route then
    if unload and not parcel.last(job) then command, keepSlots = 'stop' .. job.route.at, parcel.left(job)
    elseif not unload and job.route.at > 1 then keepSlots = parcel.left(job, true) end
  end
  if state.command == 'unloadDone' or state.command == command .. 'Done'
    or (not unload and (state.command == 'loadDone' or (state.command or ''):match('^stop%d+Done$'))) then
    S.freightStatus = nil
    return true
  end
  if S.clock >= state.readAt then
    state.readAt = S.clock + 0.65
    G.readCargoBoxes(id, function(rows) if S.freightLoad == state then state.rows = rows end end)
  end
  S.freightStatus = unload and (job.route and 'Unloading parcels…' or 'Unloading freight…') or 'Loading freight…'
  if not state.rows then return false end
  if not state.plan then
    state.plan = haul.plan(state.rows, job.haul)
    if not state.plan then
      S.freightStatus = 'The fitted containers do not have enough free space for this load.'
      return false
    end
  end
  local target = unload and haul.empty(state.plan) or state.plan
  if keepSlots then target = parcel.keep(state.plan, keepSlots, job.haul.density) end
  if state.command ~= command or (S.clock >= state.sentAt + 2 and not haul.reached(state.rows, target, true)) then
    if G.setFreightLoad(id, target) then state.command, state.sentAt, state.rows, state.readAt = command, S.clock, nil, 0 end
    return false
  end
  if not haul.reached(state.rows, target) then return false end
  state.command, S.freightStatus = command .. 'Done', nil
  return true
end

local function rules(job)
  if job and job.kind == 'tow' then return M.TOW_RULES end
  return M.RULES[(job and job.kind == 'food') and 'courier' or (job and 'trucking') or S.mode]
end
local function arrivalRadius(job)
  if job and job.kind == 'food' and S.phase == 'toPickup' then return marker.PICKUP_RADIUS end
  return rules(job).arriveM
end

------------------------------------------------------------------------------------------ data and saves

local function loadPacks()
  local info = {}
  -- trucking depots: every depots_<CC>.json
  local files = FS:findFiles(DATA_DIR, 'depots_*.json', 0, false, false) or {}
  table.sort(files)
  local merged
  for _, f in ipairs(files) do
    local p = jsonReadFile(f)
    if type(p) == 'table' and p.format == 1 and type(p.depots) == 'table' then
      merged = merged or { format = 1, cargo = p.cargo, types = p.types, trailers = p.trailers, depots = {} }
      for _, d in ipairs(p.depots) do merged.depots[#merged.depots + 1] = d end
      info[#info + 1] = (p.country or '?') .. ': ' .. #p.depots .. ' depots'
    end
  end
  if merged then S.idx, S.packDepots = jobs.index(merged), merged.depots end
  -- food: data/food_<CC>/restaurants.json and its address tiles (the first country found, for now)
  local rf = FS:findFiles(DATA_DIR, 'restaurants.json', 1, false, false) or {}
  table.sort(rf)
  for _, f in ipairs(rf) do
    local p = jsonReadFile(f)
    if type(p) == 'table' and p.format == 1 and type(p.restaurants) == 'table' then
      local dir = f:match('^(.*/)restaurants%.json$')
      S.fidx = food.index(p, function(row, col) return jsonReadFile(dir .. 'a/' .. row .. '_' .. col .. '.json') end)
      S.fidx.packCount = #S.fidx.restaurants
      info[#info + 1] = (p.country or '?') .. ': ' .. #p.restaurants .. ' restaurants'
      break
    end
  end
  -- country borders, for the local money
  local b = jsonReadFile(DATA_DIR .. 'borders.json')
  if type(b) == 'table' then S.borders = borders.index(b) end
  -- fuel stations and chargers: every fuel_<CC>.json (more arrive from the helper)
  S.fuelIdx = fuel.index()
  local ff = FS:findFiles(DATA_DIR, 'fuel_*.json', 0, false, false) or {}
  table.sort(ff)
  for _, f in ipairs(ff) do
    local p = jsonReadFile(f)
    if type(p) == 'table' and p.format == 1 then
      info[#info + 1] = (p.country or '?') .. ': ' .. fuel.addPack(S.fuelIdx, p) .. ' fuel stations'
    end
  end
  if not S.idx and not S.fidx then S.loadError = 'No data packs found in ' .. DATA_DIR return end
  S.packInfo = table.concat(info, ', ') .. '. Data: OpenStreetMap contributors (ODbL), Overture Maps Foundation.'
end

local function validLocation(p)
  return type(p) == 'table' and type(p.lat) == 'number' and type(p.lon) == 'number'
    and math.abs(p.lat) <= 90 and math.abs(p.lon) <= 180
end

local function atLocation(p, location, metres)
  return validLocation(p) and jobs.km(p.lat, p.lon, location.lat, location.lon) * 1000 <= metres
end

local function rememberLocation(p)
  if not validLocation(p) or p.camera then return end
  if garage.inOwnCar(M.G, S.career.garage) then S.career.location = { lat = p.lat, lon = p.lon } end
end

local function saveCareer()
  if S.pendingCareer then return end
  local c = S.career
  if earth.status() == 'ok' then rememberLocation(earth.pose()) end
  -- S.skipCapture: the company van is not spawned yet, so the live car is still the personal one.
  if c.garage.car and not c.garage.pendingUsed and not S.parts and not S.skipCapture then
    local ok, err = pcall(garage.remember, M.G, c.garage)
    if not ok then problem('W', 'Could not capture the career car: ' .. tostring(err)) end
  end
  c.savedAt = os.time()
  c.mode = S.mode
  c.currentOrderId = S.job and S.job.id or nil
  c.job = nil -- legacy saves duplicated the full active order here as well as in orders
  c.preferredDelivery = S.preferredDelivery
  c.orders = {}
  for i, o in ipairs(S.orders) do c.orders[i] = { phase = o.phase, data = o.job } end
  c.options = S.optsByMode
  economy.reconcile(c)
  economy.compact(c)
  local ok, saved = pcall(persistence.save, jsonWriteFile, jsonReadFile, SAVE, c)
  if ok and saved then
    S.saveRetryAt, S.saveError = nil, nil
    S.nextAutosaveActive = (c.activeSeconds or 0) + 60
    return true
  else
    if not S.saveRetryAt then problem('E', 'Could not save career progress. Retrying in ' .. M.SAVE_RETRY_S .. ' seconds.') end
    S.saveRetryAt = S.clock + M.SAVE_RETRY_S
    S.saveError = 'Progress could not be saved. Retrying; keep the game open.'
  end
end

local function loadCareer(c)
  S.career = c
  c.history = c.history or {}
  c.activeSeconds = tonumber(c.activeSeconds) or 0
  if c.employment then
    c.employment.routed = nil
    if c.employment.ownerOperator then c.employment.personalGarage = c.garage end
  end
  economy.restore(c)
  S.odometerPose = nil
  progress.restore(c)
  rating.restore(c)
  records.restore(c)
  firm.restore(c)
  if type(c.garage) ~= 'table' then c.garage = garage.new() end
  c.garage.inventory = c.garage.inventory or {}
  if (c.garage.owed or 0) > 0 then c.garage.debt = (c.garage.debt or 0) + c.garage.owed end   -- older saves
  c.garage.owed, c.garage.fixUntil = nil, nil
  if (c.garage.priceV or 1) < garage.PRICE_V then   -- prices now follow delivery pay: a debt from the old prices shrinks too
    if c.garage.started then c.garage.debt = math.floor((c.garage.debt or 0) * garage.PRICE_PER_VALUE / 3 / 5 + 0.5) * 5 end
    c.garage.priceV = garage.PRICE_V
  end
  if c.mode == 'courier' or c.mode == 'trucking' then S.mode = c.mode end
  if c.employment then S.mode = 'trucking' end
  if type(c.options) == 'table' then
    -- saved choices over config.json's defaults, key by key
    for m, o in pairs(c.options) do
      if S.optsByMode[m] and type(o) == 'table' then
        for k, v in pairs(o) do S.optsByMode[m][k] = v end
      end
    end
  end
  S.opts = S.optsByMode[S.mode]
  -- an unfinished job comes back (a trucking trailer does not: it is spawned again at the pickup or from the window)
  local saved = type(c.orders) == 'table' and #c.orders > 0 and c.orders or (c.job and { c.job }) or {}
  local savedJob = type(c.job) == 'table' and c.job
  local current
  S.orders = {}
  for _, o in ipairs(saved) do
    local j = type(o) == 'table' and o.data
    if type(j) == 'table' and j.from and j.to and j.from.g and j.to.g then
      j.trailerSpawned = false
      careerClock.restoreJob(c, j)
      j.paymentId = j.paymentId or economy.nextId(c, 'delivery')
      local order = { job = j, phase = o.phase == 'toDelivery' and 'toDelivery' or 'toPickup' }
      S.orders[#S.orders + 1] = order
      if c.currentOrderId == j.id or (savedJob and type(savedJob.data) == 'table' and savedJob.data.id == j.id and savedJob.phase == order.phase) then
        current = order
      end
    end
  end
  current = current or S.orders[1]
  S.job, S.phase = current and current.job, current and current.phase or 'idle'
  S.preferredDelivery = S.job and S.phase == 'toDelivery' and S.job.id == c.preferredDelivery and c.preferredDelivery or nil
  c.savedAt = os.time()
end

local function loadConfig()
  local c = jsonReadFile(CONFIG)
  S.config = type(c) == 'table' and c or {}
  if S.config.spawnTrailer == nil then S.config.spawnTrailer = true end
  if S.config.requireTrailer == nil then S.config.requireTrailer = true end
  if S.config.mode == 'courier' or S.config.mode == 'trucking' then S.mode = S.config.mode end
  trailers.configure(S.config)
  helper.configure(S.config)
  for m, o in pairs(S.config.jobOptions or {}) do
    if S.optsByMode[m] and type(o) == 'table' then
      for k, v in pairs(o) do S.optsByMode[m][k] = v end
    end
  end
  S.opts = S.optsByMode[S.mode]
end

------------------------------------------------------------------------------------------ jobs

local function target()
  if not S.job then return nil end
  return S.phase == 'toPickup' and S.job.from or S.job.to
end

local function gpsToTarget()
  local d = target()
  if not d then return end
  local ok, why = earth.gps(d.g[1], d.g[2], d.n)
  if not ok then say('GPS not set: ' .. tostring(why)) end
end

local function spawnCareerCar(g, vehicleId, position)
  if not g.car then return true end
  local car = g.car
  local ok, err = pcall(M.G.spawn, car.model, car.key, garage.savedConfig(car), vehicleId, position)
  if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  garage.updateStarter(g)
  if g.pendingUsed then g.pendingUsed.attempts = nil end
  usedAt = g.pendingUsed and S.clock + 1 or nil
  conditionAt = not g.pendingUsed and S.clock + 3 or nil
  -- A spawn resets physical damage. Keep its outstanding repair cost with the car.
  g.carriedRepair, g.lastDamage, g.preview = g.repair or 0, 0, nil
  return true
end

local function finishResume(pose)
  local saved = S.pendingCareer
  S.resumeTrip = nil
  if type(saved.garage) == 'table' then
    local ok, why = spawnCareerCar(saved.garage, nil, pose)
    if not ok then S.resumeError = why return end
  end
  loadCareer(saved)
  S.pendingCareer, S.resumeError, S.inCareerWorld = nil, nil, true
  S.offers, S.offerStats, S.offeredAt = {}, nil, nil
  if S.job then gpsToTarget() end
end

local function requestResume()
  if S.loadBlocked then return end
  if S.resumeTrip or earth.status() ~= 'ok' then return end
  local location, pose = S.pendingCareer.location, earth.pose()
  if not validLocation(location) or atLocation(pose, location, M.RESUME_NEAR_M) then
    finishResume(pose)
    return
  end
  S.resumeError = nil
  S.resumeTrip = { location = location, leftS = M.RESUME_TIMEOUT_S }
  local ok, why = earth.teleport(location.lat, location.lon, 'Cargo Earth saved location')
  if not ok then
    S.resumeTrip, S.resumeError = nil, 'Could not load the saved location: ' .. tostring(why)
  end
end

local function updateResume(dt)
  local trip = S.resumeTrip
  if not trip then return end
  if earth.status() == 'ok' then
    local pose = earth.pose()
    local tolerance = trip.arrived and M.RESUME_ARRIVAL_M or M.RESUME_NEAR_M
    if atLocation(pose, trip.location, tolerance) then finishResume(pose) return end
  end
  trip.leftS = trip.leftS - (dt or 0)
  if trip.leftS <= 0 then
    S.resumeTrip, S.resumeError = nil, 'The saved location did not load. Try again when the world is ready.'
  end
end

local function pauseCareer()
  if S.pendingCareer or not S.career.savedAt then return false end
  if not saveCareer() then
    say('Career could not be saved. Try pausing again in a moment.')
    return false
  end
  S.pendingCareer = S.career
  clearFreight()
  releaseStorage()
  S.parts = nil   -- only the paid configuration was saved
  local ph = S.phone
  ph.online, ph.incoming, ph.lastDone, ph.lastFailure, ph.cancelAskUntil = false, nil, nil, nil, nil
  S.window, S.inCareerWorld, S.stopT, S.dist, S.roadM, S.etaS = false, false, 0, nil, nil, nil
  fuelWatch, fuelPending, gamePump = nil, nil, nil
  if earth.status() == 'ok' then earth.gpsClear() end
  trailers.remove()
  marker.reset()
  return true
end

local function modeReady()
  if S.mode == 'courier' then return S.fidx ~= nil end
  return S.idx ~= nil
end

-- Tow offers near the player. The workshop is your headquarters when it is close enough, else one at a fuel station.
local function towOffers(class, p)
  local c = S.career
  local kind = tow.CLASSES[class].trailer
  S.towCars = S.towCars or trailers.existing(tow.CARS)
  if S.towTrailer == nil then S.towTrailer = {} end
  if S.towTrailer[kind] == nil then S.towTrailer[kind] = trailers.towModel(kind) ~= nil end
  if not S.towTrailer[kind] then return {} end
  local hq = c.firm and c.firm.hq
  local function workshop(lat, lon)
    if hq and hq.g then
      local k = jobs.km(lat, lon, hq.g[1], hq.g[2])
      if k >= tow.WORKSHOP_KM[1] and k <= tow.WORKSHOP_KM[2] then
        return { id = 'hq', n = hq.n or 'Headquarters', town = hq.town or '', g = { hq.g[1], hq.g[2] }, label = 'Your workshop' }
      end
    end
    local list = S.fuelIdx and fuel.within(S.fuelIdx, lat, lon, 'fuel', tow.WORKSHOP_KM[1], tow.WORKSHOP_KM[2]) or {}
    local s = list[1] and list[1].station
    if s then return { id = 'workshop:' .. s.id, n = 'Workshop at ' .. s.n, town = s.town or '', g = { s.g[1], s.g[2] },
      label = 'Workshop' } end
  end
  local addresses = food.addressesNear(S.fidx, p.lat, p.lon, tow.NEAR_KM)
  local out = tow.offers(class, p.lat, p.lon, addresses, workshop, S.towCars, M.random)
  local factor = rating.freightPay(c)
  for _, offer in ipairs(out) do
    if factor ~= 1 then offer.pay, offer.reputationPay = math.floor(offer.pay * factor / 5 + 0.5) * 5, factor end
    if firm.ownsTrailer(c, kind) then
      offer.trailerBonus = math.floor(offer.pay * firm.TRAILER_BONUS / 5 + 0.5) * 5
      offer.pay = offer.pay + offer.trailerBonus
    end
  end
  return out
end

function M.generate()
  if not modeReady() then S.offers, S.offerStats = {}, nil return end
  local p = earth.pose()
  if not p then S.offers, S.offerStats = {}, nil return end
  if S.mode == 'courier' then
    local plan = storagePlan()
    S.offers, S.offerStats = food.generate(S.fidx, S.opts, p.lat, p.lon, nil, plan and plan.maxFree or 1)
  else
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    local rows = store and store.rows
    S.offers, S.offerStats = {}, nil
    if tier and haul.allowed(S.career, tier) and (tier == 'semi' or rows) then
      local offers, stats = jobs.generate(S.idx, haul.options(tier, freightOptions(tier), rows), p.lat, p.lon)
      -- Freight customers pay a carrier by its reputation.
      local factor = rating.freightPay(S.career)
      local ownTruck = S.career.garage.car and not S.career.garage.car.loaner
      -- tanker runs to real fuel stations
      if tier == 'semi' and S.fuelIdx and S.opts.adr ~= false then
        local within = function(lat, lon, a, b) return fuel.within(S.fuelIdx, lat, lon, 'fuel', a, b) end
        for _, offer in ipairs(resupply.offers(S.idx, p.lat, p.lon, within, M.random, nil, S.opts.nearKm)) do
          table.insert(offers, 1, offer)
        end
      end
      -- parcel routes from the nearest depots to real addresses, in vans and box trucks
      if (tier == 'van' or tier == 'rigid') and rows and S.fidx then
        local room = haul.capacity(rows, 'parcel')
        local near = {}
        for _, d in ipairs(S.idx.depots or {}) do
          if d.g and math.abs(d.g[1] - p.lat) < 0.2 then
            local k = jobs.km(p.lat, p.lon, d.g[1], d.g[2])
            if k <= math.min(20, S.opts.nearKm or 20) then near[#near + 1] = { d = d, k = k } end
          end
        end
        table.sort(near, function(a, b) return a.k < b.k end)
        for i = 1, math.min(2, #near) do
          local d = near[i].d
          local route = parcel.route(d, food.addressesNear(S.fidx, d.g[1], d.g[2], parcel.TIERS[tier].radiusKm), tier, room, nil, i)
          if route then
            route.pickupKm = near[i].k
            offers[#offers + 1] = route
          end
        end
      end
      for _, offer in ipairs(offers) do
        if offer.route or haul.prepare(offer, tier, rows, S.idx) then
          if offer.resupply then resupply.bonus(offer)
          elseif not offer.route then special.roll(offer, tier, M.random) end
          if ownTruck then
            offer.fuelAllowance = math.floor(offer.km * haul.FUEL_ALLOWANCE[tier] / 5 + 0.5) * 5
            offer.pay = offer.pay + offer.fuelAllowance
          end
          if factor ~= 1 then
            offer.pay, offer.reputationPay = math.floor(offer.pay * factor / 5 + 0.5) * 5, factor
          end
          -- your firm's own trailer: no trailer hire to pay
          if tier == 'semi' and offer.haul and firm.ownsTrailer(S.career, firm.trailerKind(offer.haul.kind)) then
            offer.trailerBonus = math.floor(offer.pay * firm.TRAILER_BONUS / 5 + 0.5) * 5
            offer.pay = offer.pay + offer.trailerBonus
          end
          S.offers[#S.offers + 1] = offer
        end
      end
      S.offerStats = stats
    end
    -- tow jobs: broken-down cars at real addresses, for a vehicle with a tow hitch or a tractor
    local class = v and tow.class(tier, tow.hasHitch(v))
    if class and S.fidx and garage.inOwnCar(M.G, S.career.garage) then
      for _, offer in ipairs(towOffers(class, p)) do S.offers[#S.offers + 1] = offer end
    end
  end
  S.offeredAt = { lat = p.lat, lon = p.lon }
end

function M.setMode(m)
  if S.job or S.career.employment or not M.RULES[m] or m == S.mode then return end
  S.mode = m
  S.opts = S.optsByMode[m]
  S.offers, S.offerStats, S.offeredAt = {}, nil, nil
  S.phone.incoming, S.phone.declined = nil, {}
  saveCareer()
  M.generate()
end

-- When the next order rings: sooner for a courier customers like.
local function nextPing(short)
  local wait = short and M.PHONE.pingMinS or (M.PHONE.pingMinS + math.random() * (M.PHONE.pingMaxS - M.PHONE.pingMinS))
  S.phone.nextPingAt = S.clock + wait * rating.pingFactor(S.career)
end

local function maxOrders()
  local n = S.optsByMode.courier.maxOrders or M.MAX_ORDERS
  return math.max(1, math.min(3, n))
end

local function isDropoff(order)
  return cargo.supports(order.job) and order.phase == 'toDelivery'
end

local function carriedOrders()
  local count = 0
  for _, order in ipairs(S.orders) do if isDropoff(order) then count = count + 1 end end
  return count
end

local function stopForceWatch()
  local watch = forceWatch
  forceWatch = nil
  if watch then M.G.watchForces(watch.id) end
end

local function updateForceWatch(p)
  local G, g = M.G, S.career.garage
  local id = p and not p.camera and G.playerId and carriedOrders() > 0 and G.playerId()
  if id and g.started and not G.ownsVehicleId(id) then id = nil end
  if forceWatch and id == forceWatch.id and p.anchorLat == forceWatch.lat and p.anchorLon == forceWatch.lon then return end
  stopForceWatch()
  if id then
    forceToken = forceToken + 1
    if G.watchForces(id, forceToken) then
      forceWatch = { id = id, token = forceToken, lat = p.anchorLat, lon = p.anchorLon }
    end
  end
end

local function setStop(order)
  if S.job == order.job and S.phase == order.phase then return end
  S.job, S.phase = order.job, order.phase
  S.stopT, S.dist, S.roadM, S.etaS = 0, nil, nil, nil
  S.phone.cancelAskUntil = nil
  gpsToTarget()
end

-- Keep a customer chosen on the phone until their order leaves the car. Otherwise use
-- the nearest pickup first, then the nearest drop-off.
local function nextStop()
  if S.preferredDelivery then
    for _, order in ipairs(S.orders) do
      if order.job.id == S.preferredDelivery and isDropoff(order) then
        setStop(order)
        return
      end
    end
    S.preferredDelivery = nil
  end
  local p = earth.pose()
  local best, bestK
  for _, wantPhase in ipairs({ 'toPickup', 'toDelivery' }) do
    for _, o in ipairs(S.orders) do
      if o.phase == wantPhase then
        local d = wantPhase == 'toPickup' and o.job.from or o.job.to
        local k = p and jobs.km(p.lat, p.lon, d.g[1], d.g[2]) or 0
        if not best or k < bestK then best, bestK = o, k end
      end
    end
    if best then break end
  end
  if best then
    setStop(best)
  else
    S.job, S.phase = nil, 'idle'
  end
end

local function selectDelivery(id)
  if type(id) ~= 'string' or not S.job or S.parts or S.phone.incoming or carriedOrders() < 2 then return end
  for _, order in ipairs(S.orders) do
    if order.job ~= S.job and order.job.id == id and isDropoff(order) then
      S.preferredDelivery = id
      setStop(order)
      saveCareer()
      return
    end
  end
end

local function orderOf(j)
  for i, o in ipairs(S.orders) do if o.job == j then return i, o end end
end

local function takeJob(j)
  if not j or S.pendingCareer or S.parts then return end
  if S.career.employment and j.companyShift ~= S.career.employment.id then return end
  if S.job then
    -- a batched order: only food, while there is room
    if j.kind ~= 'food' or S.job.kind ~= 'food' or #S.orders >= maxOrders() then return end
    for _, o in ipairs(S.orders) do if o.job.id == j.id then return end end
  end
  if j.kind == 'food' then
    if not garage.inOwnCar(M.G, S.career.garage) then say('Get in your delivery car to accept this order.', 4) return end
    local storage = earth.status() == 'ok' and refreshStorage()
    if not storage then say('Get in your delivery car to accept this order.', 4) return end
    local plan = storagePlan()
    if not plan then say('Checking the car’s cargo space. Try again in a moment.', 4) return end
    local box = cargo.fit(plan, j)
    if not box then say('This order needs more cargo space.', 4) return end
    j.cargoBox = box.key
  elseif j.tow then
    local v, tier = freightCarrier()
    if not v or tow.class(tier, tow.hasHitch(v)) ~= j.tow.class then
      say(j.tow.class == 'heavy' and 'Tow jobs with two cars need a tractor for the flatbed trailer.'
        or 'This tow job needs a vehicle with a tow hitch for the car trailer.', 5)
      return
    end
  elseif j.haul then
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    if tier ~= j.haul.tier or not haul.allowed(S.career, tier) then
      say('Use a truck with the equipment for this haul.', 4) return
    end
    if tier ~= 'semi' and not haul.plan(store and store.rows, j.haul) then
      say('This haul needs more free space in compatible containers.', 4) return
    end
    j.haul.model = v.model
  end
  S.phone.incoming = nil
  S.phone.lastDone = nil
  S.phone.lastFailure = nil
  j.startedAt, j.startedActive = os.time(), S.career.activeSeconds or 0
  j.paymentId = j.paymentId or economy.nextId(S.career, 'delivery')
  local first = S.job == nil
  S.orders[#S.orders + 1] = { job = j, phase = 'toPickup' }
  nextPing()
  if first then
    if j.kind == 'food' then
      say(string.format('Order accepted: %s. Pick it up at %s.', j.cargoName, j.from.n))
    else
      say(string.format('Job taken: %s, %s to %s. Drive to the pickup.', j.cargoName, j.from.n, j.to.n))
    end
    setStop(S.orders[#S.orders])
  else
    say(string.format('Order %d added: %s from %s.', #S.orders, j.cargoName, j.from.n))
    nextStop()
  end
  saveCareer()
  phoneSound('accepted')
end

function M.take(i) takeJob(S.offers[i]) end

local function finishPickup()
  local j = S.job
  if j.kind == 'food' then
    -- every order waiting at this restaurant comes along
    local n = 0
    for _, o in ipairs(S.orders) do
      if o.phase == 'toPickup' and (o.job == j or (o.job.from.id and o.job.from.id == j.from.id)) then
        o.phase = 'toDelivery'
        n = n + 1
      end
    end
    say(n > 1 and string.format('Collected %d orders from %s.', n, j.from.n)
      or string.format('Collected %s from %s.', j.cargoName, j.from.n))
  elseif j.tow then
    local ok, why = trailers.spawnTow(tow.CLASSES[j.tow.class].trailer, j.tow.cars)
    if not ok then
      S.stopT = -10
      say('The broken-down car could not be loaded: ' .. tostring(why), 6)
      return
    end
    j.trailerSpawned, j.tow.spawnedAt, j.tow.damage0, j.tow.onBoard = true, S.clock, nil, #j.tow.cars
    local _, o = orderOf(j)
    if o then o.phase = 'toDelivery' end
    say(string.format('%s on the trailer behind you. Couple it and drive gently to %s: %s not strapped down.',
      #j.tow.cars > 1 and 'The cars are' or 'The car is', j.to.n, #j.tow.cars > 1 and 'they are' or 'it is'), 8)
  elseif j.haul then
    if j.haul.tier == 'semi' and not trailers.id() then
      M.spawnTrailer(true)
      return
    end
    if not workFreight(j, false) then return end
    local _, o = orderOf(j)
    if o then o.phase = 'toDelivery' end
    say('Freight loaded. Drive to ' .. j.to.n .. '.')
  else
    local _, o = orderOf(j)
    if o then o.phase = 'toDelivery' end
    if S.config.spawnTrailer then
      local ok, why = trailers.spawn(j.trailer)
      j.trailerSpawned = ok
      if ok then say('Loaded. Couple the ' .. (S.idx.trailers[j.trailer] or j.trailer) .. ' trailer behind you.')
      else say('Trailer not spawned: ' .. tostring(why)) end
    else
      say('Loaded: ' .. j.cargoName .. '.')
    end
  end
  nextStop()
  saveCareer()
  syncStorage()
  phoneSound('pickup')
end

-- An order leaves the list; the next stop takes over, or the courier is free again.
local function dropOrder(j)
  if j.haul then clearFreight() end
  local i = orderOf(j)
  if i then table.remove(S.orders, i) end
  if #S.orders == 0 then
    trailers.remove()
    earth.gpsClear()
    S.job, S.phase, S.stopT, S.preferredDelivery = nil, 'idle', 0, nil
    return true
  end
  S.job = nil
  nextStop()
  return false
end

local function finishDelivery(force)
  local j = S.job
  if cargo.supports(j) and cargo.condition(j) == 0 then M.spoil(nil, {[j] = true}) return end
  if j.haul then
    local cmd = S.freightLoad and S.freightLoad.command or ''
    if cmd ~= 'unload' and cmd ~= 'unloadDone' and not cmd:match('^stop') then
      if not workFreight(j, false) then return end
    end
    if not workFreight(j, true) then return end
    -- a parcel route goes on to its next address; it is paid and rated at the last one
    if j.route and not parcel.last(j) then
      local served = parcel.advance(j)
      say(string.format('%d parcels left at %s. Next stop %d of %d: %s.', served.slots, served.n, j.route.at,
        #j.route.stops, j.to.n), 6)
      S.stopT, S.dist, S.roadM, S.etaS = 0, nil, nil, nil
      gpsToTarget()
      saveCareer()
      phoneSound('pickup')
      return
    end
  elseif j.tow then
    if not trailers.withPlayer() then
      say('Bring the trailer with the broken-down car.', 3)
      S.stopT = -10
      return
    end
    local onBoard = tow.onBoard(trailers.towedDistances())
    if onBoard < #j.tow.cars then
      say(string.format('Only %d of %d cars are on the trailer. Put them back on from the phone (Work).', onBoard, #j.tow.cars), 5)
      S.stopT = -10
      return
    end
    j.cargoCondition = tow.condition((j.tow.damageDone or 0)
      + math.max(0, trailers.towedDamage() - (j.tow.damage0 or trailers.towedDamage())))
  elseif not force and j.kind ~= 'food' and S.config.requireTrailer and S.config.spawnTrailer and not trailers.withPlayer() then
    say('Bring the trailer: it is not with your truck.', 3)
    S.stopT = -10   -- don't repeat the message every tick
    return
  end
  local minutes = M.elapsed(j) / 60
  local late = math.max(0, minutes - j.minutes)
  local perMin = M.LATE_PER_MIN[j.kind == 'food' and 'courier' or 'trucking']
  local pay = math.floor(j.pay * math.max(M.LATE_FLOOR, 1 - late * perMin) + 0.5)
  if j.special == 'chilled' then special.warm(j, late) end
  local condition = cargo.supports(j) and cargo.condition(j) or (j.tow and cargo.condition(j)) or 100
  -- Tips from private customers (meals and parcel routes) go only by what they can see: how soon the order came and
  -- the state it arrived in. How it was driven on the way is not theirs to know.
  local tip, tipWhy = 0, nil
  if j.kind == 'food' or j.route then
    local fast = food.tip(j.kind == 'food' and j.pay or math.floor(j.pay * M.PARCEL_TIP_SHARE), minutes, j.minutes)
    local intact = condition >= 100 and math.floor(j.pay * M.INTACT_TIP / 5 + 0.5) * 5 or 0
    tip = fast + intact
    tipWhy = { fast = fast > 0 or nil, intact = intact > 0 or nil, damaged = condition < 100 and condition or nil }
  end
  local conditionFactor = j.kind == 'food' and (0.6 + 0.004 * condition) or condition / 100
  pay = math.floor(pay * conditionFactor * (1 - special.penalty(j) / 100) + 0.5)
  tip = math.floor(tip * condition / 100 + 0.5)
  local c = S.career
  local toDebt = 0
  if j.companyShift then
    if not employment.delivered(c, j, pay + tip) then return end
  else
    if economy.isSettled(c, j.paymentId) then return end
    toDebt = garage.takeForDebt(c.garage, pay + tip)
    if not economy.post(c, pay + tip - toDebt, 'delivery', j.paymentId, j.cargoName) then return end
  end
  local rankUp = progress.complete(c, j)
  local truckUnlock = j.haul and haul.complete(c, j.haul.tier)
  local today = os.date('%Y-%m-%d')
  if type(c.today) ~= 'table' or c.today.date ~= today then c.today = { date = today, earned = 0, count = 0 } end
  if not j.companyShift then c.today.earned = c.today.earned + pay + tip end
  c.today.count = c.today.count + 1
  -- The customer's rating feeds the courier or the freight reputation.
  local track = rating.track(j)
  local stars = rating.add(c, track, rating.stars(minutes, j.minutes, condition, j.starPenalty))
  local note = rating.note(track, stars, late > 0, condition < 100, c.delivered)
  local newRecords = records.record(c, j, { pay = pay, tip = tip, minutes = minutes, stars = stars, date = today,
    earnedToday = c.today.earned })
  S.phone.lastDone = { pay = pay, tip = tip, late = math.floor(late + 0.5), to = j.to.n, untilT = S.clock + M.PHONE.doneShowS,
    toDebt = toDebt, net = pay + tip - toDebt, rankUp = rankUp, truckUnlock = truckUnlock,
    cargoCondition = condition < 100 and condition or nil, held = j.companyShift ~= nil,
    ownerOperator = c.employment and c.employment.ownerOperator,
    stars = stars, note = note, track = track, records = #newRecords > 0 and newRecords or nil, premium = j.premium,
    tipWhy = tip > 0 and tipWhy or (tipWhy and tipWhy.damaged and tipWhy) or nil, special = special.info(j) }
  nextPing()
  c.km = (c.km or 0) + j.km
  table.insert(c.history, 1, { date = os.date('%Y-%m-%d %H:%M'), kind = j.kind or 'cargo', from = j.from.n,
    to = j.to.n, cargo = j.cargoName, km = math.floor(j.km * 10 + 0.5) / 10, pay = pay, tip = tip,
    minutes = math.floor(minutes + 0.5), late = math.floor(late + 0.5), batched = j.batched or nil, orderType = j.orderType,
    cargoCondition = condition < 100 and condition or nil, stars = stars })
  while #c.history > 50 do table.remove(c.history) end
  say(string.format('Delivered to %s: %s%d CZK%s%s', j.to.n, j.companyShift and 'held ' or '+', pay, tip > 0 and string.format(' + %d CZK tip', tip) or '',
    late > 0 and string.format(' (%d min late)', late) or '') .. (toDebt > 0 and string.format(', %d CZK to your debt', toDebt) or ''), 8)
  local free = dropOrder(j)
  saveCareer()
  syncStorage()
  phoneSound('delivered')
  if free and not c.employment then M.generate() end
end

-- Cancels the current order (all of them with `all`); free: no fee (a crash, the debug window).
function M.cancel(free, all)
  if not S.job then return end
  if S.job.companyShift then
    say('End company work from Menu → Companies. Completed deliveries are paid without a cancellation fee.')
    return
  end
  repeat
    local fee = rules(S.job).cancelFee
    if not free then
      S.career.money = (S.career.money or 0) - fee
      economy.reconcile(S.career, 'cancel_fee', S.job.cargoName)
      -- A cancelled order is a poor rating: worse once the cargo was already on board.
      local _, order = orderOf(S.job)
      rating.add(S.career, rating.track(S.job), order and order.phase == 'toDelivery' and 1 or 2)
      records.broken(S.career)
    end
    say((S.job.kind == 'food' and 'Order cancelled' or 'Job cancelled') .. (free and '.' or (' (-' .. fee .. ' CZK).')))
    local done = dropOrder(S.job)
  until done or not all
  saveCareer()
  syncStorage()
  if not free then phoneSound('cancelled') end
  if not S.job then M.generate() end
end

-- Only cargo already on board can be ruined by an impact; pending pickups remain available.
function M.spoil(peak, ruined)
  local lost = 0
  for i = #S.orders, 1, -1 do
    local o = S.orders[i]
    -- A company load the manifest doesn't accept as failed stays on board (it was not the current one).
    if cargo.supports(o.job) and o.phase == 'toDelivery' and (not ruined or ruined[o.job])
      and (not o.job.companyShift or employment.failed(S.career, o.job)) then
      if o.job.haul then clearFreight() end
      rating.add(S.career, rating.track(o.job), 1)
      table.remove(S.orders, i)
      lost = lost + 1
    end
  end
  if lost == 0 then return 0 end
  records.broken(S.career)
  S.career.failed = (S.career.failed or 0) + lost
  local ph = S.phone
  ph.lastDone, ph.incoming = nil, nil
  ph.lastFailure = { count = lost, g = peak, untilT = S.clock + M.PHONE.doneShowS }
  ph.nextPingAt = math.max(ph.nextPingAt, ph.lastFailure.untilT)
  say(string.format('%d order%s ruined%s.', lost, lost > 1 and 's' or '',
    peak and string.format(' by a %.1f g impact', peak) or ''), M.PHONE.doneShowS)
  if #S.orders == 0 then
    earth.gpsClear()
    S.job, S.phase, S.stopT, S.preferredDelivery = nil, 'idle', 0, nil
  else
    S.job = nil
    nextStop()
  end
  saveCareer()
  syncStorage()
  phoneSound('failed')
  return lost
end

function M.onCargoEarthShock(id, token, peak)
  local watch = forceWatch
  if not watch or watch.id ~= id or watch.token ~= token or S.pendingCareer then return end
  if type(peak) ~= 'number' or peak ~= peak or peak <= 0 or peak == math.huge then return end
  if M.G.playerId() ~= id or earth.status() ~= 'ok' then return end
  local p = earth.pose()
  if not p or p.camera or p.anchorLat ~= watch.lat or p.anchorLon ~= watch.lon then return end
  stopForceWatch()
  local ruined, damaged = {}, 0
  for _, order in ipairs(S.orders) do
    local job = order.job
    if cargo.supports(job) and order.phase == 'toDelivery' and cargo.shock(job, peak) then
      if cargo.condition(job) == 0 then ruined[job] = true else damaged = damaged + 1 end
    end
  end
  if next(ruined) then M.spoil(peak, ruined)
  elseif damaged > 0 then
    say(string.format('%d order%s damaged by a %.1f g impact.', damaged, damaged == 1 and '' or 's', peak))
    saveCareer()
  end
end

-- A harsh moment (hard braking, accelerating or cornering): it cracks a fragile load. Other orders only suffer from real
-- impacts (onCargoEarthShock), and customers tip by the state their order arrives in, not by how it was driven.
function M.onCargoEarthHarsh(id, token, g)
  if S.pendingCareer or type(g) ~= 'number' or g ~= g then return end
  if M.G.playerId() ~= id then return end
  local cracked, ruined = 0, {}
  for _, order in ipairs(S.orders) do
    local job = order.job
    if order.phase == 'toDelivery' and special.harsh(job) > 0 then
      cracked = cracked + 1
      if special.condition(job) == 0 then ruined[job] = true end
    end
  end
  if next(ruined) then M.spoil(nil, ruined) return end
  if cracked > 0 then
    say(string.format('The fragile load felt that: %d %% intact.', special.condition(S.job or {})), 4)
  end
end

-- Would this order fit with the ones on board? (food only, room left, restaurant close or the same as one still to
-- pick up, customer near one we already have)
local function batchFits(j)
  if S.mode ~= 'courier' or j.kind ~= 'food' or #S.orders >= maxOrders() then return false end
  local p = earth.pose()
  local nearPickup = p and jobs.km(p.lat, p.lon, j.from.g[1], j.from.g[2]) <= M.BATCH_PICKUP_KM
  local nearDrop = false
  for _, o in ipairs(S.orders) do
    if o.job.kind ~= 'food' or o.job.id == j.id then return false end
    if o.phase == 'toPickup' and o.job.from.id == j.from.id then nearPickup = true end
    if jobs.km(o.job.to.g[1], o.job.to.g[2], j.to.g[1], j.to.g[2]) <= M.BATCH_DROP_KM then nearDrop = true end
  end
  return nearPickup and nearDrop
end

-- metres from the player to the current target: its stop point (curb or gate), door / dock or road point
local function distToTarget(p)
  local d = target()
  if not d or not p then return nil end
  local best = jobs.km(p.lat, p.lon, d.g[1], d.g[2]) * 1000
  if S.job.kind == 'food' and S.phase == 'toPickup' then
    return marker.pickupDistance(p, d, S.clock) or best
  end
  for _, k in ipairs({ 'd', 'r' }) do
    if d[k] then best = math.min(best, jobs.km(p.lat, p.lon, d[k][1], d[k][2]) * 1000) end
  end
  return best
end

-- The country the player drives in sets the currency; crossing a border exchanges the money for free.
-- The money's currency for the phone: { code, rate, symbol, prefix, decimals, country }.
-- Before a saved career is resumed, the phone shows the save's money in the save's currency.
local function moneyInfo()
  local c = type(S.pendingCareer) == 'table' and S.pendingCareer or S.career
  local info = currency.info(c.currency)
  info.country = c.country and currency.name(c.country)
  return info
end

local function countryTick(p)
  if not S.borders or not p or p.camera or S.clock < (S.countryAt or 0) then return end
  S.countryAt = S.clock + M.COUNTRY_S
  S.countryTrack = S.countryTrack or {}
  local c = S.career
  local change = currency.observe(c, S.countryTrack, borders.find(S.borders, p.lat, p.lon))
  if change then
    say(currency.welcome(change, c.money or 0), 8)
    saveCareer()
  end
end

local function tick(dt)
  if not S.job then return end
  local p = earth.pose()
  local r = rules(S.job)
  if S.job.haul and S.phase == 'toDelivery'
    and (not S.freightLoad or (S.freightLoad.command ~= 'unload' and S.freightLoad.command ~= 'unloadDone'
      and not (S.freightLoad.command or ''):match('^stop'))) then
    workFreight(S.job, false)
  end
  -- a tow job: the damage the cars came with is not yours; a car that slides off is noticed
  if S.job.tow and S.phase == 'toDelivery' and S.clock >= (S.towCheckAt or 0) then
    local t = S.job.tow
    S.towCheckAt = S.clock + 1
    if not t.damage0 and t.spawnedAt and S.clock >= t.spawnedAt + 3 then t.damage0 = trailers.towedDamage() end
    if trailers.towedCount() > 0 then
      local n = tow.onBoard(trailers.towedDistances())
      if n < (t.onBoard or #t.cars) then say('A car slid off the trailer! Put it back on from the phone (Work).', 6) end
      t.onBoard = n
    end
  end
  -- special cargo on board: a chilled load warms up after its time limit, an oversize one has an escort
  if S.job.special and S.phase == 'toDelivery' then
    local j = S.job
    if j.special == 'chilled' then
      local before = special.condition(j)
      if special.warm(j, M.elapsed(j) / 60 - j.minutes) < before then
        if special.condition(j) == 0 then M.spoil(nil, { [j] = true }) return end
        if before == 100 then say('The chilled load is warming up: it spoils by the minute now.', 6) end
      end
    elseif p and not p.camera and special.speed(j, (p.speed or 0) * 3.6, dt) then
      say(string.format('Escort: too fast for an oversize load (%d km/h max). Pay now %d %% lower.',
        special.KINDS.oversize.maxKmh, special.penalty(j)), 5)
    end
  end
  S.dist = distToTarget(p)
  -- the road distance of the GPS route, for the phone and window (arrival still uses the straight distance)
  local rt = earth.route()
  if rt and not rt.planning and type(rt.remaining) == 'number' and rt.remaining >= 0 then
    S.roadM, S.etaS = rt.remaining, type(rt.eta) == 'number' and rt.eta or nil
  else
    S.roadM, S.etaS = nil, nil
  end
  if not S.dist or S.dist > arrivalRadius(S.job) or (p.speed or 0) > M.STOP_SPEED or p.camera
    or (S.job.kind == 'food' and not garage.inOwnCar(M.G, S.career.garage)) then
    S.stopT = 0
    return
  end
  S.stopT = S.stopT + dt
  if S.stopT < r.stopS then return end
  if S.phase == 'toPickup' then finishPickup() else finishDelivery(false) end
end

-- The stop at the current target: { inZone, stopping, frac (0..1 of the wait), leftS, stopS, moving } or nil.
-- frac moves smoothly between ticks so the bar doesn't jump.
local function stopInfo()
  if not S.job or not S.dist then return nil end
  local r = rules(S.job)
  local inZone = S.dist <= arrivalRadius(S.job)
  local t = S.stopT > 0 and math.min(r.stopS, S.stopT + S.tick) or 0
  return { inZone = inZone, stopping = inZone and S.stopT > 0, frac = t / r.stopS, leftS = math.max(0, r.stopS - t),
    stopS = r.stopS, pickup = S.phase == 'toPickup' }
end
M.stopInfo = stopInfo

------------------------------------------------------------------------------------------ the phone

local function phoneTick()
  local ph = S.phone
  if not ph.online or S.parts or S.career.employment then return end
  if S.job and (S.mode ~= 'courier' or #S.orders >= maxOrders()) then return end
  if not garage.inOwnCar(M.G, S.career.garage) then ph.incoming = nil return end
  if ph.incoming then
    if S.clock >= ph.incoming.expiresAt then
      ph.declined[#ph.declined + 1] = ph.incoming.job.id
      ph.incoming = nil
      nextPing(true)
      phoneSound('expired')
    end
    return
  end
  if S.clock < ph.nextPingAt then return end
  local plan = storagePlan()
  if S.mode == 'courier' and (not plan or plan.free < 1 or plan.overflow > 0) then return end
  M.generate()
  -- one grocery basket, one parcel route and one tow job get a place beside the first three offers
  local fresh, groceryIncluded, routeIncluded, anyRoute = {}, false, false, false
  local towIncluded, anyTow = false, false
  for _, j in ipairs(S.offers) do
    if j.route then anyRoute = true end
    if j.tow then anyTow = true end
  end
  for _, j in ipairs(S.offers) do
    local seen = false
    for _, id in ipairs(ph.declined) do if id == j.id or (j.from.id and id:find(j.from.id .. '>', 1, true) == 1) then seen = true break end end
    if not seen and j.kind == 'food' and not cargo.fit(plan, j) then seen = true end
    if not seen and S.job and not batchFits(j) then seen = true end
    if not seen and (#fresh < 3 or (j.orderType == 'grocery' and not groceryIncluded) or (j.route and not routeIncluded)
      or (j.tow and not towIncluded)) then
      fresh[#fresh + 1] = j
      if j.orderType == 'grocery' then groceryIncluded = true end
      if j.route then routeIncluded = true end
      if j.tow then towIncluded = true end
    end
    if #fresh >= 3 and (groceryIncluded or not plan or plan.maxFree < food.GROCERY_SLOTS)
      and (routeIncluded or not anyRoute) and (towIncluded or not anyTow) then break end
  end
  if #fresh == 0 then ph.nextPingAt = S.clock + M.PHONE.retryS return end
  local j = fresh[math.random(#fresh)]
  if S.job then
    j.batched = true
    local bonus = j.sizeBonus or 0
    j.pay = math.floor((j.pay - bonus) * M.BATCH_PAY / 5 + 0.5) * 5 + bonus
  elseif j.kind == 'food' and rating.premium(S.career) and math.random(rating.PREMIUM_ONE_IN) == 1 then
    rating.makePremium(j)
  end
  ph.incoming = { job = j, expiresAt = S.clock + M.PHONE.acceptS }
  S.phoneHidden = false   -- a ringing phone shows itself
  phoneSound('offer')
  earth.notify('New order: ' .. j.cargoName .. ', ' .. j.from.n, 4)
end

local function r1(x) return x and math.floor(x * 10 + 0.5) / 10 or nil end

local function place(d)
  local label = d.label
  if not label and S.idx and d.t and S.idx.types[d.t] then label = S.idx.types[d.t].label end
  return { name = d.n, label = label or '', town = d.town or '' }
end

local function incomingInfo(inc)
  local j = inc.job
  return { kind = j.kind or 'cargo', cargo = j.cargoName, items = j.items, from = place(j.from), to = place(j.to),
    orderType = j.orderType, sizeBonus = j.sizeBonus, freight = j.haul, handling = j.kind == 'food' and cargo.handling(j) or nil,
    slots = j.kind == 'food' and cargo.size(j) or nil,
    pickupKm = r1(j.pickupKm), km = r1(j.km), pay = j.pay, minutes = j.minutes, adr = j.adr or false,
    special = special.info(j), resupplyBonus = j.resupplyBonus, litres = j.litres, tow = tow.info(j),
    trailerBonus = j.trailerBonus,
    farPickup = j.farPickup or 0, batch = false, premium = j.premium, reputationPay = j.reputationPay,
    route = j.route and parcel.state(j),
    fuelAllowance = j.fuelAllowance,
    trailer = j.trailer and ((j.tow and tow.CLASSES[j.tow.class].name) or (j.haul and j.haul.trailerName) or (S.idx and S.idx.trailers[j.trailer]) or j.trailer) or nil,
    leftS = math.max(0, math.floor(inc.expiresAt - S.clock + 0.5)), totalS = M.PHONE.acceptS }
end

local function truckingState()
  local out = haul.state(S.career)
  local g = S.career.garage
  local v, tier = freightCarrier()
  local rows = S.storage and S.storage.rows
  out.carrier = tier and haul.tiers[tier].name or nil
  out.canLoan = earth.status() == 'ok' and not S.job and not S.parts and not g.preview and not g.pendingUsed
    and not (g.freightLoaners and g.freightLoaners[out.unlocked])
  out.loanerLabel = haul.loaners[out.unlocked].label
  if not v or not tier then
    out.hint = 'Get in a ' .. haul.loaners[out.unlocked].label .. ' to take freight jobs.'
  elseif not haul.allowed(S.career, tier) then
    out.hint = 'This truck unlocks after completing the earlier stage.'
  elseif tier ~= 'semi' and not rows then
    out.hint = 'Checking fitted cargo containers…'
  elseif tier == 'van' and haul.capacity(rows, 'parcel') < 8 then
    out.hint = 'Fit parcel boxes with at least 8 free slots.'
  elseif tier == 'rigid' and haul.capacity(rows, 'parcel') < 8 and haul.capacity(rows, 'fluid') < 100
    and haul.capacity(rows, 'dryBulk') < 100 then
    out.hint = 'Fit parcel boxes, a fluid tank, or aggregate storage for freight.'
  elseif S.offerStats and S.offerStats.pairs == 0 then
    out.hint = 'No compatible routes nearby. Try a different depot area or widen the distance filters.'
  end
  out.error = S.freightSetupError
  return out
end

function M.careerState()
  local state = progress.state(S.career)
  state.driverRank, state.driverAt, state.driverUnlocked = progress.DRIVER_RANK, progress.DRIVER_AT, fleet.unlocked(S.career)
  state.firm = M.firmState()
  state.trucking = haul.state(S.career)
  state.drivenKm = math.floor((S.career.drivenKm or 0) * 10 + 0.5) / 10
  local shift = S.career.employment
  local personal = shift and shift.personalGarage or S.career.garage
  state.debt = personal and personal.debt or 0
  state.heldWages = shift and shift.phase ~= 'settled' and math.floor(shift.gross * (shift.share or employment.SHARE) + 0.5) or 0
  state.ledger = {}
  for i, row in ipairs(economy.restore(S.career).history) do
    if i > 20 then break end
    state.ledger[i] = row
  end
  state.reputation = rating.state(S.career)
  state.fines = S.career.fines
  return state
end

-- The delivery map and records for the phone (Career / Map).
function M.mapState()
  return records.state(S.career, S.career.home, S.career.firm and S.career.firm.hq)
end

------------------------------------------------------------------------------------------ places and company work

function M.placesState()
  S.placesRequestedAt = S.clock
  if S.companyBoardDirty and not S.career.employment and S.clock >= (S.nextBoardAt or 0) then
    S.companyBoard = employment.board(S.idx, earth.pose())
    S.companyBoardDirty, S.nextBoardAt = nil, S.clock + 2
  end
  local c, p = S.career, earth.pose()
  local out = { home = c.home, addresses = S.homeAddresses or {}, selected = S.selectedHome,
    companies = {}, msg = S.placesMsg, status = earth.status(), busy = S.job ~= nil or S.parts ~= nil,
    started = c.garage.started, blocked = S.pendingCareer ~= nil, last = c.lastContract,
    discovery = helper.status() }
  if c.home then
    out.atHome, out.used = home.near(c, p), home.count(c.employment and c.employment.personalGarage or c.garage)
    out.capacity = firm.capacity(c)
    out.homeKm = p and jobs.km(p.lat, p.lon, c.home.g[1], c.home.g[2]) or nil
  end
  for _, offer in ipairs(S.companyBoard or {}) do
    local company = c.companies and c.companies[offer.id]
    local km = p and jobs.km(p.lat, p.lon, offer.yard.g[1], offer.yard.g[2]) or nil
    out.companies[#out.companies + 1] = { id = offer.id, name = offer.name, yard = offer.yard.n,
      km = km, routeKm = offer.km, wages = offer.wages, minutes = offer.minutes,
      reputation = company and company.reputation or 0,
      independentPay = offer.gross, independentUnlocked = company ~= nil and company.reputation >= employment.INDEPENDENT_REP,
      atYard = km and km * 1000 <= employment.RADIUS and not p.camera and (p.speed or 0) <= M.STOP_SPEED }
  end
  local shift = c.employment
  if shift then
    out.shift = { company = shift.companyName, phase = shift.phase, completed = shift.completed, total = #shift.jobs,
      held = math.floor(shift.gross * (shift.share or employment.SHARE) + 0.5), atYard = employment.atYard(c, p),
        failed = shift.failed or 0, vehicleDamage = shift.vehicleDamage or 0, reputationScore = employment.reputation(shift, false),
      error = S.companyError, ownerOperator = shift.ownerOperator }
  end
  return out
end

local function companyReturn(aborted)
  local c, shift = S.career, S.career.employment
  if not shift then return false, 'No company contract is active.' end
  if S.parts then return false, 'Close the parts preview before ending the contract.' end
  if shift.phase ~= 'settled' then
    if not aborted and not employment.atYard(c, earth.pose()) then return false, 'Park at the company yard first.' end
    local g = c.garage
    local what, cost = garage.trackDamage(g, M.G.damage())
    if what == 'hit' then employment.damage(c, math.max(0, cost)) end
    if not shift.ownerOperator then g.debt = 0 end
    if not employment.settle(c, aborted) then return false, 'Complete the deliveries before settling this shift.' end
    local today = os.date('%Y-%m-%d')
    if type(c.today) ~= 'table' or c.today.date ~= today then c.today = { date = today, earned = 0, count = 0 } end
    c.today.earned = c.today.earned + c.lastContract.wages
    clearFreight()
    releaseStorage()
    S.orders, S.job, S.phase, S.stopT = {}, nil, 'idle', 0
    trailers.remove()
    earth.gpsClear()
  end
  -- Wages and the settled phase must be committed before returning the player's car.
  if not saveCareer() then return false, S.saveError end
  local personal = shift.personalGarage
  if personal.car and not shift.ownerOperator then
    local ok, why = spawnCareerCar(personal)
    if not ok then return false, why .. ' Your wages are saved; retry returning your car.' end
  end
  c.garage, c.employment = personal, nil
  S.mode = shift.previousMode == 'trucking' and 'trucking' or 'courier'
  S.opts, S.offeredAt, S.odometerPose = S.optsByMode[S.mode], nil, nil
  S.companyError, S.companyPreparedAt = nil, nil
  S.phone.lastDone = nil
  if not saveCareer() then return false, S.saveError end
  return true, string.format('Company work ended. Paid %d CZK; %d CZK went to debt.', c.lastContract.net, c.lastContract.toDebt)
end

local function companyStart(id, independent)
  local c, g, p = S.career, S.career.garage, earth.pose()
  if c.employment or S.job or S.parts or g.preview or g.pendingUsed then return false, 'Finish your current work or vehicle preview first.' end
  if not g.started or not g.car or not garage.inOwnCar(M.G, g) then return false, 'Start your career and drive your own car to the company yard.' end
  if earth.status() ~= 'ok' or not p or p.camera or (p.speed or 0) > M.STOP_SPEED then return false, 'Park at the company yard first.' end
  local offer
  for _, row in ipairs(S.companyBoard or {}) do if row.id == id then offer = row break end end
  if not offer then return false, 'Refresh the company board.' end
  if jobs.km(p.lat, p.lon, offer.yard.g[1], offer.yard.g[2]) * 1000 > employment.RADIUS then
    return false, 'Drive to the company yard, then park to start.'
  end
  if not garage.remember(M.G, g) then return false, 'Could not save your car configuration.' end
  local damage = M.G.damage and M.G.damage()
  if damage then garage.trackDamage(g, damage) end
  if independent then
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    if g.car.loaner or tier ~= 'van' or not store or not store.rows then
      return false, 'Independent contracts need your own van with compatible parcel boxes.'
    end
    for _, j in ipairs(offer.jobs) do
      if not haul.plan(store.rows, j.haul) then return false, 'Your van needs enough free parcel capacity for this contract.' end
    end
    local ok, why = employment.begin(c, offer, g, g, S.mode, true)
    if not ok then return false, why end
    if not saveCareer() then c.employment = nil return false, S.saveError end
    S.mode, S.opts = 'trucking', S.optsByMode.trucking
    S.phone.online, S.phone.incoming, S.phone.lastDone = false, nil, nil
    S.offeredAt = nil
    return true, 'Independent contract accepted. Use your own van; keep 100% of delivery revenue and cover your vehicle costs.'
  end
  local preset = haul.loaners.van
  local config = M.G.freightLoanerConfig and M.G.freightLoanerConfig(preset.model, preset.key)
  if not config then return false, 'The company van configuration is unavailable in this game version.' end
  local companyGarage = garage.new()
  companyGarage.started = true
  companyGarage.car = { model = preset.model, key = preset.key, name = 'Company H-Series van', config = config,
    km = 0, condition = 1, loaner = true, company = true }
  local ok, why = employment.begin(c, offer, g, companyGarage, S.mode)
  if not ok then return false, why end
  c.garage = companyGarage
  c.location = { lat = p.lat, lon = p.lon }
  -- Commit the personal-car snapshot before any spawn can replace it.
  S.skipCapture = true
  local saved = saveCareer()
  S.skipCapture = nil
  if not saved then c.garage, c.employment = g, nil return false, S.saveError end
  releaseStorage()
  local spawned, err = spawnCareerCar(companyGarage)
  if not spawned then
    S.companyError = err .. ' End company work to restore your car.'
    return false, S.companyError
  end
  S.mode, S.opts, S.companyPreparedAt = 'trucking', S.optsByMode.trucking, c.activeSeconds or 0
  S.phone.online, S.phone.incoming, S.phone.lastDone = false, nil, nil
  S.offeredAt, S.odometerPose = nil, nil
  saveCareer()
  return true, 'Company van loading. Two deliveries, then return here for wages. The company keeps 20% and covers vehicle costs.'
end

function M.companyTick()
  local c, shift = S.career, S.career.employment
  if not shift then return end
  if shift.phase == 'settled' then
    if S.clock >= (S.companyRetryAt or 0) then
      S.companyRetryAt = S.clock + 5
      local ok, why = companyReturn(false)
      if not ok then S.companyError = why end
    end
    return
  end
  if shift.phase == 'preparing' then
    S.companyPreparedAt = S.companyPreparedAt or c.activeSeconds or 0
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    local first = shift.jobs[shift.index]
    if tier == 'van' and store and store.rows and haul.plan(store.rows, first.haul) then
      shift.phase, S.companyError = 'working', nil
    elseif (c.activeSeconds or 0) - S.companyPreparedAt >= employment.PREPARE_TIMEOUT then
      S.companyError = 'The van cargo equipment is not ready. End company work to restore your car, then try again.'
      return
    end
  end
  if shift.phase == 'working' and not S.job then
    if S.phone.lastFailure and S.clock < S.phone.lastFailure.untilT then return end
    takeJob(employment.nextJob(c))
  elseif shift.phase == 'returning' and not S.job and not shift.routed then
    shift.routed = earth.gps(shift.yard.g[1], shift.yard.g[2], shift.yard.n) == true
    say('Company route finished. Return to the yard and settle in Menu → Companies.')
    saveCareer()
  end
end

function M.placesDo(name, value)
  if S.pendingCareer then return M.placesState() end
  local c, p, ok, why = S.career, earth.pose(), false, nil
  if earth.status() ~= 'ok' or not p then S.placesMsg = earth.status() return M.placesState() end
  if name == 'search' then
    S.homeAddresses = food.addresses(S.fidx, p.lat, p.lon, value)
    S.placesMsg = #S.homeAddresses > 0 and 'Select an address, route there, then park safely to confirm your garage.'
      or 'No matching addresses within 3 km. Try another search or wait for local address data.'
  elseif name == 'select' then
    for _, address in ipairs(S.homeAddresses or {}) do
      if address.id == value then S.selectedHome = address break end
    end
  elseif name == 'routeSelected' and S.selectedHome then
    if S.job or c.employment then why = 'Finish your current work before changing GPS.'
    else ok, why = earth.gps(S.selectedHome.g[1], S.selectedHome.g[2], S.selectedHome.n) end
  elseif name == 'claimHome' then
    if S.job or c.employment or S.parts then why = 'Finish your current work first.'
    elseif not garage.inOwnCar(M.G, c.garage) then why = 'Park your career car at this address.'
    else
      local old = c.home
      ok, why = home.claim(c, S.selectedHome, p)
      if ok and not saveCareer() then c.home, ok, why = old, false, S.saveError end
    end
  elseif name == 'homeGps' and c.home then
    if S.job or c.employment then why = 'Finish your current work before changing GPS.'
    else ok, why = earth.gps(c.home.g[1], c.home.g[2], c.home.name) end
  elseif name == 'refreshCompanies' then
    S.companyBoard = employment.board(S.idx, p)
    S.companyBoardDirty, S.nextBoardAt = nil, S.clock + 2
    S.placesMsg = #S.companyBoard > 0 and 'Fictional employers at mapped depot locations. Check access on arrival; you can end work without a cancellation fee.'
      or 'Looking for nearby workplaces through the helper. Contracts appear as local data loads; the Czech pack also works offline.'
  elseif name == 'companyGps' then
    if S.job then why = 'Follow the current delivery GPS.'
    elseif c.employment then
      ok, why = earth.gps(c.employment.yard.g[1], c.employment.yard.g[2], c.employment.yard.n)
    else
      for _, offer in ipairs(S.companyBoard or {}) do
        if offer.id == value then ok, why = earth.gps(offer.yard.g[1], offer.yard.g[2], offer.yard.n) break end
      end
    end
  elseif name == 'startCompany' then ok, why = companyStart(value)
  elseif name == 'startIndependent' then ok, why = companyStart(value, true)
  elseif name == 'settleCompany' then ok, why = companyReturn(false)
  elseif name == 'endCompany' then ok, why = companyReturn(true)
  end
  if why then S.placesMsg = why elseif ok then S.placesMsg = 'GPS updated.' end
  return M.placesState()
end

-- Everything the phone shows, small and JSON friendly. screen: offline, waiting, incoming, active, done, error.
-- The speed limit of the road under the car: { kmh, sign, unit }, or nil off the road or without a road graph.
local function limitHere(p)
  if not (p and p.x and p.y) or p.camera or not M.G.road then return nil end
  if S.clock < roadLimit.at + M.LIMIT_S then return roadLimit.value end
  roadLimit.at = S.clock
  local graph, a, b, d = M.G.road(p.x, p.y, p.z)
  local kmh, sign, unit
  if graph and d <= M.ROAD_M then kmh, sign, unit = speedlimit.at(graph, a, b, speedlimit.unitsFor(S.career.country)) end
  -- no sign where the road's speed is no posted limit in the country's unit (Earth's fallback where it knows none)
  roadLimit.value = kmh and sign and { kmh = kmh, sign = sign, unit = unit } or nil
  return roadLimit.value
end

function M.phoneState()
  local c, ph = S.career, S.phone
  local today = (type(c.today) == 'table' and c.today.date == os.date('%Y-%m-%d')) and c.today or { earned = 0, count = 0 }
  local out = { mode = S.mode, online = ph.online, money = c.money or 0, todayEarned = today.earned,
    todayCount = today.count, status = earth.status(), clock = os.date('%H:%M'), hidden = S.phoneHidden,
      helper = M.helperInfo(), saveError = S.saveError, company = c.employment and c.employment.companyName,
      companyDamage = c.employment and (c.employment.vehicleDamage or 0), companyOwnerOperator = c.employment and c.employment.ownerOperator,
      currency = moneyInfo(), update = M.updateInfo() }
  if S.pendingCareer then
    out.screen, out.money = 'resume', S.pendingCareer.money or 0
    local savedGarage = S.pendingCareer.garage
    out.savedCar = type(savedGarage) == 'table' and type(savedGarage.car) == 'table' and savedGarage.car.name or nil
    out.resumeLoading = S.resumeTrip ~= nil
    out.resumeHasLocation = validLocation(S.pendingCareer.location)
    out.resumeError = S.resumeError
    return out
  end
  if S.mode == 'trucking' then out.trucking = truckingState() end
  local gauge = c.garage.started and c.garage.car and fuel.state(c.garage.car)
  if gauge then
    out.fuel = { pct = math.floor(gauge.share * 100 + 0.5), low = gauge.low, empty = gauge.empty, rangeKm = gauge.rangeKm }
  end
  local here = earth.pose()
  local limit = limitHere(here)
  if limit then
    out.limit = { sign = limit.sign, unit = limit.unit, over = (here.speed or 0) * 3.6 > limit.kmh + M.OVER_KMH }
  end
  if camerasOn() then
    local p = here
    if p and not p.camera then out.camera = cameras.ahead(cams, p.lat, p.lon, (p.speed or 0) > M.STOP_SPEED and p.heading or nil) end
    if ph.flash and S.clock < ph.flash.untilT then out.flash = ph.flash else ph.flash = nil end
  end
  if S.mode == 'courier' and out.status == 'ok' then
    local plan = storagePlan()
    if plan then
      out.storage = { used = plan.used, reserved = plan.reserved, capacity = plan.capacity, free = plan.free,
        overflow = plan.overflow, boxes = #S.storage.boxes, kg = r1(plan.kg) }
    else
      out.storage = { checking = S.storage ~= nil, unavailable = S.storage == nil }
    end
  end
  if S.parts and not S.job then out.screen = 'parts' return out end
  if S.loadError then out.screen, out.error = 'error', S.loadError return out end
  if ph.lastDone and S.clock < ph.lastDone.untilT then
    local receipt = ph.lastDone
    out.done = { pay = receipt.pay, tip = receipt.tip, late = receipt.late, to = receipt.to,
      toDebt = receipt.toDebt, net = receipt.net, rankUp = receipt.rankUp, truckUnlock = receipt.truckUnlock,
      cargoCondition = receipt.cargoCondition, held = receipt.held, ownerOperator = receipt.ownerOperator,
      stars = receipt.stars, note = receipt.note, track = receipt.track, records = receipt.records, premium = receipt.premium,
      tipWhy = receipt.tipWhy, special = receipt.special }
  end
  if ph.lastFailure and S.clock < ph.lastFailure.untilT then
    out.failure = { count = ph.lastFailure.count, g = ph.lastFailure.g }
  end
  if S.job then
    local j = S.job
    local carrying = carriedOrders()
    local radius = arrivalRadius(j)
    local straightM = j.kind == 'food' and S.phase == 'toPickup' and marker.PICKUP_RANGE or radius
    local distRoad = S.roadM ~= nil and not (S.dist and S.dist <= straightM)
    local left = j.minutes * 60 - M.elapsed(j)
    out.screen = 'active'
    out.active = { phase = S.phase, kind = j.kind or 'cargo', cargo = j.cargoName, items = j.items, from = place(j.from), to = place(j.to),
        orderType = j.orderType, handling = cargo.supports(j) and cargo.handling(j) or nil,
      freight = j.haul, freightStatus = S.freightStatus, route = j.route and parcel.state(j),
      canRestoreTrailer = j.trailer and ((not trailers.id() and (S.phase == 'toDelivery' or j.trailerRequested))
        or (j.tow and S.phase == 'toDelivery' and (j.tow.onBoard or #j.tow.cars) < #j.tow.cars)) or nil,
        cargoCondition = cargo.supports(j) and S.phase == 'toDelivery' and cargo.condition(j) or nil,
      special = special.info(j), tow = tow.info(j), reloadFee = j.tow and M.TOW_RELOAD_FEE or nil,
      slots = j.kind == 'food' and cargo.size(j) or nil,
      distM = distRoad and math.floor(S.roadM + 0.5)
        or (S.dist and math.floor(S.dist + 0.5)) or nil,
      distRoad = distRoad,
      etaS = S.etaS and math.floor(S.etaS + 0.5) or nil, km = r1(j.km), pay = j.pay, minutes = j.minutes,
      leftS = math.floor(left + 0.5), arriveM = radius, stop = stopInfo(),
      cancelAsk = S.phone.cancelAskUntil ~= nil and S.clock <= S.phone.cancelAskUntil, trailer = j.trailer and ((j.tow and tow.CLASSES[j.tow.class].name) or S.idx and S.idx.trailers[j.trailer] or j.trailer) or nil,
      trailerM = j.trailerSpawned and trailers.distanceToPlayer() and math.floor(trailers.distanceToPlayer()) or nil,
      cancelFee = rules(j).cancelFee, count = #S.orders, carrying = carrying, orders = {} }
    -- List the current stop first, then the remaining orders.
    for _, o in ipairs(S.orders) do
      local oj = o.job
      local destination = o.phase == 'toPickup' and oj.from or oj.to
      local l = oj.minutes * 60 - M.elapsed(oj)
      local row = { id = oj.id, pickup = o.phase == 'toPickup', name = destination.n,
        cargo = oj.cargoName, leftS = math.floor(l + 0.5), current = oj == j,
        cargoCondition = isDropoff(o) and cargo.condition(oj) or nil,
        selectable = carrying >= 2 and oj ~= j and isDropoff(o) }
      if row.current then table.insert(out.active.orders, 1, row) else out.active.orders[#out.active.orders + 1] = row end
    end
    if ph.incoming then
      out.screen = 'incoming'
      out.incoming = incomingInfo(ph.incoming)
      out.incoming.batch = true
      out.incoming.openOrders = #S.orders
    end
    return out
  end
  if out.failure then out.screen = 'failed' return out end
  if out.done then out.screen = 'done' return out end
  if c.employment then out.screen = 'company' return out end
  if out.status ~= 'ok' then out.screen = 'error' out.error = out.status return out end
  local g = S.career.garage
  if g.started then out.repair, out.debt = g.repair or 0, g.debt or 0 end
  if not garage.inOwnCar(M.G, g) then
    out.screen, out.error = 'error', g.preview and 'You are looking at a used car. Menu → Garage: buy it or go back to your car.'
      or g.car and ('Drive your own car (' .. g.car.name .. '). Menu → Garage → Bring my car.')
      or 'You have no car. Buy one in Menu → Garage → Used cars.'
    return out
  end
  if not ph.online then out.screen = 'offline' return out end
  if ph.incoming then
    out.screen = 'incoming'
    out.incoming = incomingInfo(ph.incoming)
    return out
  end
  out.screen = 'waiting'
  return out
end

-- Buttons on the phone: resume, online, offline, accept, decline, gps, selectDelivery, cancel, dismiss.
function M.phoneAction(a, orderId)
  if S.pendingCareer then
    if a == 'resume' then requestResume() end
    return M.phoneState()
  end
  if S.parts and (a == 'online' or a == 'accept') then return M.phoneState() end
  local ph = S.phone
  if a == 'online' then
    ph.online = true
    ph.nextPingAt = S.clock + 2
  elseif a == 'offline' then
    ph.online, ph.incoming = false, nil
  elseif a == 'accept' and ph.incoming then
    takeJob(ph.incoming.job)
  elseif a == 'decline' and ph.incoming then
    ph.declined[#ph.declined + 1] = ph.incoming.job.id
    while #ph.declined > M.PHONE.declinedKeep do table.remove(ph.declined, 1) end
    ph.incoming = nil
    nextPing(true)
  elseif a == 'gps' then
    gpsToTarget()
  elseif a == 'selectDelivery' then
    selectDelivery(orderId)
  elseif a == 'restoreTrailer' then
    M.spawnTrailer()
  elseif a == 'loanerTruck' and S.mode == 'trucking' then
    M.garageFreightLoaner()
  elseif a == 'cancel' then
    M.cancel(false)
  elseif a == 'dismiss' then
    ph.lastDone, ph.lastFailure = nil, nil
  end
  return M.phoneState()
end

------------------------------------------------------------------------------------------ the helper (anywhere)

M.HELPER_NEAR_KM = 15     -- request restaurants if the shipped pack has fewer than HELPER_MIN this close
M.HELPER_MIN = 20
M.HELPER_CHECK_S = 5

local helperWanted, helperCheckAt, depotsHere, stationsWanted = false, 0, false, false

local function packRestaurantsNear(lat, lon)
  local idx = S.fidx
  if not idx then return 0 end
  local n, r = 0, M.HELPER_NEAR_KM
  local dLat = r / 111.32
  for i = 1, idx.packCount or 0 do
    local x = idx.restaurants[i]
    if x and math.abs(x.g[1] - lat) <= dLat and food.km(lat, lon, x.g[1], x.g[2]) <= r then
      n = n + 1
      if n >= M.HELPER_MIN then break end
    end
  end
  return n
end

-- Is this point covered by a bundled depot pack? There, trucking keeps to the pack's checked depots
-- (real name and type) and streamed candidate workplaces are not mixed in.
local function packDepotsNear(lat, lon)
  local dLat = M.HELPER_NEAR_KM / 111.32
  for _, d in ipairs(S.packDepots or {}) do
    if math.abs(d.g[1] - lat) <= dLat and jobs.km(lat, lon, d.g[1], d.g[2]) <= M.HELPER_NEAR_KM then return true end
  end
  return false
end
M.packDepotsNear = packDepotsNear

local function areaCentre(key)
  local r, c = tostring(key):match('^(%-?%d+)_(%-?%d+)$')
  if r then return (tonumber(r) + 0.5) * 0.1, (tonumber(c) + 0.5) * 0.1 end
end

local function onHelperArea(data)
  if not S.fidx then
    S.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, function() return nil end)
  end
  local n, stores = food.addArea(S.fidx, data, function(key)
    helper.forget(key)
    fuel.dropArea(S.fuelIdx, key)
  end)
  if type(data.fuel) == 'table' and S.fuelIdx then
    fuel.addArea(S.fuelIdx, data.key, data.fuel)
    fuelNearAt = 0
  end
  local lat, lon = areaCentre(data.key)
  local workplaces = 0
  if not (lat and packDepotsNear(lat, lon)) then
    S.idx = S.idx or jobs.streamIndex()
    workplaces = jobs.addArea(S.idx, data, helper.forget)
  end
  if S.idx or S.fidx then S.loadError = nil end
  if data.depots and S.companyBoard and not S.career.employment then
    S.companyBoardDirty = true
  end
  stores = stores or 0
  log('I', 'cargoEarth', string.format('helper area %s: %d restaurants, %d grocery stores', tostring(data.key), n - stores, stores))
  if n > 0 and not S.job then S.offeredAt = nil end
end
M.onHelperArea = onHelperArea

local function wantsGroceryData()
  for _, box in ipairs(S.storage and S.storage.boxes or {}) do
    if box.capacity >= food.GROCERY_SLOTS then return true end
  end
  return false
end

------------------------------------------------------------------------------------------ speed cameras

local function onHelperCameras(data)
  if type(data) ~= 'table' or type(data.cameras) ~= 'table' then return end
  cameras.set(cams, data.cameras, data.state)
end
M.onHelperCameras = onHelperCameras

-- Every frame: a camera measures the career car that passes it. The fine is paid at once (what the wallet cannot
-- cover is owed), and each order on board loses a star.
local function cameraTick(p)
  if not p or p.camera or S.parts or not camerasOn() then
    cameras.clear(cams)
    return
  end
  if #cams.near == 0 then return end
  local flash = cameras.pass(cams, p.lat, p.lon, (p.speed or 0) * 3.6, S.clock)
  -- (who is driving is only looked up when a camera fires: it is not a per-frame question)
  if not flash or not garage.inOwnCar(M.G, S.career.garage) then return end
  local c = S.career
  local shift = c.employment
  local g = shift and shift.personalGarage or c.garage
  local paid = math.max(0, math.min(flash.fine, math.floor(c.money or 0)))
  local detail = string.format('Speed camera: %d km/h, limit %d', flash.speed, flash.limit)
  if paid > 0 then economy.post(c, -paid, 'fine', economy.nextId(c, 'fine'), detail) end
  if paid < flash.fine then g.debt = (g.debt or 0) + flash.fine - paid end
  local rated = 0
  local function mark(job)
    if type(job) == 'table' and not job.starPenalty then job.starPenalty, rated = cameras.STAR_PENALTY, rated + 1 end
  end
  for _, order in ipairs(S.orders) do if order.phase == 'toDelivery' then mark(order.job) end end
  if S.job and S.phase == 'toDelivery' then mark(S.job) end
  c.fines = { count = ((c.fines or {}).count or 0) + 1, paid = ((c.fines or {}).paid or 0) + flash.fine }
  S.phone.flash = { speed = flash.speed, limit = flash.limit, fine = flash.fine, owed = flash.fine - paid, stars = rated,
    untilT = S.clock + 10 }
  phoneSound('cancelled')
  say(string.format('Speed camera: %d km/h where the limit is %d. Fine %d CZK%s%s', flash.speed, flash.limit, flash.fine,
    paid < flash.fine and ' (added to your debt)' or '',
    rated > 0 and '. The customer takes a star off.' or '.'), 8)
  saveCareer()
end

-- A camera that OpenStreetMap gives no limit takes the limit of its road from the game's road graph once the graph
-- reaches it, the limit BeamNG.Earth's own signs show there.
local cameraRoadAt = -math.huge
local function learnCameraLimits(p)
  if not (p and p.x and M.G.road) or S.clock < cameraRoadAt + 2 then return end
  cameraRoadAt = S.clock
  for _, cam in ipairs(cams.near) do
    if cam.assumed and not cam.road and jobs.km(p.lat, p.lon, cam.lat, cam.lon) * 1000 <= M.CAMERA_ROAD_M then
      local x, y = earth.worldXY(p, { cam.lat, cam.lon })
      local graph, a, b, d
      if x then graph, a, b, d = M.G.road(x, y, p.z) end
      -- Only a posted limit fines anyone: a road farther than ROAD_M (the graph does not reach the camera yet) or a
      -- bend speed not yet resolved by the road around it keeps the default and is asked again later.
      if graph and d <= M.ROAD_M then
        local kmh, _, _, sure = speedlimit.at(graph, a, b, speedlimit.unitsFor(S.career.country))
        if kmh == nil or sure then cameras.learn(cam, kmh) end
      end
    end
  end
end

local radioAlive   -- (the radio, below)
local askUpdate    -- (the update notice, with the support report below)
local function helperTick(p)
  if not p then return end
  if camerasOn() then
    cameras.refresh(cams, p.lat, p.lon)
    learnCameraLimits(p)
  end
  if S.clock >= helperCheckAt then
    helperCheckAt = S.clock + M.HELPER_CHECK_S
    helperWanted = packRestaurantsNear(p.lat, p.lon) < M.HELPER_MIN
    depotsHere = packDepotsNear(p.lat, p.lon)
    -- no fuel station known around here: the helper streams them
    stationsWanted = S.career.garage.started and S.fuelIdx ~= nil
      and fuel.nearest(S.fuelIdx, p.lat, p.lon, 'fuel', M.HELPER_NEAR_KM) == nil
  end
  local places = S.placesRequestedAt and S.clock - S.placesRequestedAt < 30
  local areas = (S.mode == 'trucking' and not depotsHere) or places or helperWanted or stationsWanted or wantsGroceryData()
  local wantCameras = camerasOn() and onHelperCameras or nil
  radioAlive()
  askUpdate()
  if areas or wantCameras or helper.asking() then
    helper.tick(p.lat, p.lon, S.clock, onHelperArea, wantCameras, not areas)
  end
end

------------------------------------------------------------------------------------------ radio
-- The phone's radio plays internet stations of the country the player drives in. The helper finds them (Radio Browser);
-- the phone plays the stream itself. The game only asks and passes the list on.

M.RADIO_ASK_S = 3          -- the helper is still fetching the list: ask again after this long
M.RADIO_NEAR_S = 120       -- the "near you" list follows the car this often
M.RADIO_ALIVE_S = 5       -- while the helper plays the radio, the game says so this often (it stops without)
local radio = { cc = nil, state = nil, data = nil, askedAt = -math.huge, asking = false, aliveAt = -math.huge }

-- The helper's own player: { playing, url, vol, secs, error, player } as it last said, or nil. Each play starts a
-- new session (radio.gen): an answer to a request of an older one, still in flight, is ignored.
local function onPlayer(gen)
  return function(data, err)
    if gen ~= radio.gen then return end
    if data then radio.player = data
    elseif radio.player then radio.player = { playing = false, error = err == 'HTTP 404' and 'old' or 'helper' } end
    if radio.player then radio.helperOn = radio.player.playing == true end
  end
end

-- From the helper tick: the heartbeat that keeps the helper's player going.
radioAlive = function()
  if radio.helperOn and S.clock >= radio.aliveAt + M.RADIO_ALIVE_S then
    radio.aliveAt = S.clock
    helper.command('/v1/player/alive', onPlayer(radio.gen), '/v1/player/alive')
  end
end

local function radioRows(rows, withKm)
  local out = {}
  for _, r in ipairs(type(rows) == 'table' and rows or {}) do
    if type(r) == 'table' and type(r[1]) == 'string' and type(r[2]) == 'string' and type(r[3]) == 'string'
      and r[3]:match('^https?://') then
      out[#out + 1] = { id = r[1], name = r[2], url = r[3], codec = tostring(r[4] or ''), kbps = tonumber(r[5]) or 0,
        tags = tostring(r[6] or ''), region = tostring(r[7] or ''), km = withKm and tonumber(r[8]) or nil }
    end
  end
  return out
end

local function radioAsk(p, cc)
  if radio.asking then return end
  radio.asking, radio.askedAt = true, S.clock
  local path = string.format('/v1/radio?cc=%s&lat=%.4f&lon=%.4f', cc, p.lat, p.lon)
  helper.ask(path, function(data, err)
    radio.asking = false
    if radio.cc ~= cc then return end
    if not data then
      radio.state = err == 'HTTP 404' and 'old' or 'off'
      return
    end
    radio.state = data.state
    if data.state == 'ready' then
      radio.data = { near = radioRows(data.near, true), top = radioRows(data.top) }
    end
  end)
end

-- What the phone's Radio tab shows: the country, its stations and how the list is coming along.
function M.radioState()
  if radio.asking and S.clock - radio.askedAt > 30 then radio.asking = false end
  local p = earth.pose()
  local cc = S.borders and p and borders.find(S.borders, p.lat, p.lon) or nil
  if cc and cc ~= radio.cc and radio.cc then
    -- a new country: keep the old list until the new one is in, so a station playing does not vanish from view
    radio.state = 'loading'
  end
  if cc then
    local changed = cc ~= radio.cc
    radio.cc = cc
    local wait = radio.state == 'ready' and M.RADIO_NEAR_S or M.RADIO_ASK_S
    if (changed or S.clock - radio.askedAt >= wait) and helper.enabled then radioAsk(p, cc) end
  end
  local out = { country = radio.cc, countryName = radio.cc and currency.name(radio.cc) or nil,
    state = not helper.enabled and 'disabled' or (not radio.cc and (p and 'nowhere' or 'noworld')) or radio.state or 'loading' }
  if radio.data then out.near, out.top = radio.data.near, radio.data.top end
  out.player = radio.player
  -- the phone's <audio> plays the station through the helper: the game's UI refuses web streams, not local ones
  if helper.enabled then out.stream = string.format('http://%s:%d/v1/stream?id=', helper.HOST, helper.PORT) end
  return out
end

-- name: refresh | played (a = station id: Radio Browser counts what is listened to) | helperPlay (a = station id,
-- b = volume 0..1) | helperVolume (a = volume) | helperStop
function M.radioDo(name, a, b)
  if name == 'refresh' then
    radio.askedAt = -math.huge
  elseif name == 'played' and type(a) == 'string' and a:match('^[%x%-]+$') and #a == 36 then
    helper.ask('/v1/radioclick?id=' .. a, nil)
  elseif name == 'helperPlay' and type(a) == 'string' and a:match('^[%x%-]+$') and #a == 36 then
    -- the game's UI cannot play the stream: the helper plays this station on the computer
    local vol = math.max(0, math.min(1, tonumber(b) or 0.6))
    radio.gen = (radio.gen or 0) + 1
    radio.helperOn, radio.aliveAt = true, S.clock
    radio.player = { playing = true, secs = 0 }
    helper.command(string.format('/v1/player/play?id=%s&vol=%.2f', a, vol), onPlayer(radio.gen), '/v1/player/')
  elseif name == 'helperVolume' and radio.helperOn then
    helper.command(string.format('/v1/player/volume?vol=%.2f', math.max(0, math.min(1, tonumber(a) or 0.6))), onPlayer(radio.gen),
      '/v1/player/volume')
  elseif name == 'helperStop' then
    radio.gen = (radio.gen or 0) + 1
    radio.helperOn, radio.player = false, nil
    helper.command('/v1/player/stop', nil, '/v1/player/')
  end
  return M.radioState()
end

-- What the phone and window say about the helper: nil when it isn't needed here.
function M.helperInfo()
  if S.mode ~= 'courier' or S.pendingCareer then return nil end
  local groceries = wantsGroceryData()
  if not helperWanted and not groceries then return nil end
  local h = helper.status()
  return { state = h.state, loading = h.loading, ready = h.ready, msg = h.msg,
    restaurants = helperWanted, groceries = groceries, outdated = groceries and h.supportsGrocers == false }
end

------------------------------------------------------------------------------------------ the garage (own car, parts)

M.G = gamecar               -- the game adapter (tests put a stub here)
garage.clock = function() return S.clock end

local fuelTick   -- (defined with the fuel rules below)

local function garageTick(dt)
  local g = S.career.garage
  if not g.started then return end
  garage.marketTick(M.G, g, (dt or 0) / 60)
  local own = garage.inOwnCar(M.G, g)
  if g.preview and not g.preview.ready and not g.preview.error and S.clock >= (previewAt or 0) then
    if garage.previewReady(M.G, g) then previewAt = nil saveCareer() else previewAt = S.clock + 1 end
  end
  if g.pendingUsed then
    if not S.parts and own and S.clock >= (usedAt or 0) then
      local setup = g.pendingUsed
      local ready, why = garage.prepareUsed(M.G, g, g.car, setup)
      usedAt = S.clock + 1
      if ready or why then
        g.pendingUsed, usedAt, conditionAt = nil, nil, S.clock
        if ready then g.car.wearVersion = setup.wearVersion end
        if why then
          say(why)
        elseif #setup.missing > 0 then
          say('Missing parts: ' .. #setup.missing .. '. Replacements are available in Vehicle Config.')
        end
        saveCareer()
      end
    end
    if g.pendingUsed then return end
  end
  if not S.parts and conditionAt and own and S.clock >= conditionAt then
    conditionAt = nil
    if M.G.applyCondition then pcall(M.G.applyCondition, g.car.km or 0, g.car.condition or 1) end
  end
  fuelTick(own)
  if not own then return end
  -- the odometer
  local p = earth.pose()
  local shift = S.career.employment
  if p and p.speed and dt then
    local km = p.speed * dt / 1000
    g.car.km = (g.car.km or 0) + km
    -- upkeep: your own car wears, also on an owner-operator contract; a long overdue service can end in a breakdown
    -- (company and loaner vehicles are looked after by their owners)
    if (not shift or shift.ownerOperator) and not g.car.loaner and km > 0 then
      upkeep.wear(g.car, km)
      S.wearKm = (S.wearKm or 0) + km
      if S.wearKm >= 1 and not g.car.breakdown then
        local chance = upkeep.chance(g.car, S.wearKm)
        S.wearKm = 0
        if chance > 0 and M.random() < chance then
          local failure = upkeep.breakdown(g.car)
          g.car.breakdown, S.stallAt = failure, 0   -- kept with the car: saved, and it stays broken when parked
          phoneSound('cancelled')
          say(failure.text .. string.format(' Roadside help: %d CZK (Garage on the phone).', failure.cost), 10)
          saveCareer()
        end
      end
    end
  end
  -- a breakdown keeps the engine off until the roadside help is paid
  if g.car.breakdown and S.clock >= (S.stallAt or 0) then
    S.stallAt = S.clock + 1
    if M.G.stall then pcall(M.G.stall, true) end
  end
  if not g.car.value and not S.parts and S.clock >= (S.valueAt or 0) then   -- caps the repair (older saves, new cars)
    S.valueAt = S.clock + 5
    garage.noteValue(M.G, g)
  end
  local what, amount = garage.trackDamage(g, M.G.damage())
  if shift and what == 'hit' then employment.damage(S.career, math.max(0, amount)) end
  if shift and not shift.ownerOperator then g.debt = 0 end
  if what == 'hit' then
    S.dirtyAt = S.dirtyAt or (S.clock + 5)
  elseif what == 'debt' then
    if shift and not shift.ownerOperator then
      say('Company van repaired. Recorded damage still affects employer reputation.', 8)
    else
      say(string.format('Your car was fixed without paying (menu repair, reset or respawn): %d CZK added to your debt.', amount), 8)
    end
    saveCareer()
  end
  if S.dirtyAt and S.clock >= S.dirtyAt then S.dirtyAt = nil saveCareer() end
  if not S.parts and S.clock >= carSeenAt then
    carSeenAt = S.clock + 10
    garage.remember(M.G, g)
  end
end
M.garageTick = garageTick

------------------------------------------------------------------------------------------ fuel

M.FUEL_SILENT_S = 8        -- no report from the car for this long: ask it again
M.FUEL_VERIFY_S = 6        -- a refill the game has not taken after this long is refunded
M.FUEL_GIVE_UP = 5         -- putting a level back failed this often: this car's tank cannot be set
M.PUMP_WAIT_S = 20         -- a game pump's refuel shows in the car's report within this long

local function stopFuelWatch()
  fuelWatch, fuelPending, gamePump = nil, nil, nil
end

-- The game's own "Refuel" prompt at a pump (stock gas stations and BeamNG.Earth's): remembered, so the fuller tank
-- in the next report is paid for at that station's price instead of being put back like a reset's free refill.
function M.onGameRefuel(id, station, fuelTypes)
  local g = S.career.garage
  if not g.started or not g.car or not fuelWatch or (id and fuelWatch.id ~= id) then return end
  local f = type(station) == 'table' and (type(station.facility) == 'table' and station.facility or station) or {}
  local types = type(fuelTypes) == 'table' and fuelTypes or {}
  gamePump = { id = fuelWatch.id, untilT = S.clock + M.PUMP_WAIT_S,
    station = { id = tostring(f.id or station and station.id or 'pump'), n = type(f.name) == 'string' and f.name ~= '' and f.name or 'Gas station',
      kind = types.electricEnergy and not types.gasoline and not types.diesel and 'electric' or 'fuel' } }
end

-- Keeps the vehicle-side reporter running on the career car the player sits in.
function fuelTick(own)
  local G, g = M.G, S.career.garage
  if G.hookPumps and S.clock >= pumpHookAt then
    pumpHookAt = S.clock + 5
    pcall(G.hookPumps, function(...) return M.onGameRefuel(...) end)
  end
  if not own or not g.car or S.parts or g.preview or g.pendingUsed or not G.watchFuel then
    if fuelWatch then stopFuelWatch() end
    return
  end
  local id = G.playerId and G.playerId()
  if not id then return end
  if fuelWatch and fuelWatch.id == id and S.clock - fuelWatch.seen <= M.FUEL_SILENT_S then return end
  fuelToken = fuelToken + 1
  if G.watchFuel(id, fuelToken) then
    fuelWatch = { id = id, token = fuelToken, seen = S.clock, km = g.car.km or 0, failed = fuelWatch and fuelWatch.id == id and fuelWatch.failed or 0,
      off = fuelWatch and fuelWatch.id == id and fuelWatch.off or nil }
  end
end

function M.onCargoEarthFuel(id, token, report)
  local watch, g = fuelWatch, S.career.garage
  if not watch or watch.id ~= id or watch.token ~= token or S.pendingCareer then return end
  if not g.started or not g.car or S.parts or g.preview or g.pendingUsed then return end
  if M.G.ownsVehicleId and not M.G.ownsVehicleId(id) then return end
  watch.seen = S.clock
  local car = g.car
  -- A paid refill is checked first: the game must show the new level.
  local pending = fuelPending
  if pending then
    if pending.id ~= id or pending.car ~= car then
      fuelPending = nil
    else
      local seen, taken = fuel.clean(report) or {}, true
      for name, level in pairs(pending.levels) do
        -- half of what was bought, at most 2 %: an unchanged tank can never confirm a small paid refill
        local added = level - (pending.before[name] or 0)
        local slack = math.min(0.02, math.max(0, added) / 2)
        if not seen[name] or seen[name].ratio < level - slack then taken = false end
      end
      if taken then
        fuelPending = nil
      elseif S.clock < pending.untilT then
        M.G.setFuel(id, pending.levels)
        return
      else
        -- This vehicle's tank cannot be filled from here: give the money back and keep the game's level.
        fuelPending = nil
        for name, level in pairs(pending.before) do
          if car.fuel.tanks[name] then car.fuel.tanks[name].ratio = level end
        end
        if pending.cost > 0 then
          if pending.debt then
            g.debt = math.max(0, (g.debt or 0) - pending.cost)
          else
            economy.post(S.career, pending.cost, 'fuel', economy.nextId(S.career, 'fuel'), 'Refund: refuelling failed')
          end
        end
        say('Refuelling did not work for this vehicle. Your money was returned.', 8)
        problem('W', 'fuel: the vehicle did not take the new tank level')
        saveCareer()
      end
    end
  end
  if gamePump then
    if gamePump.id ~= id or S.clock > gamePump.untilT then gamePump = nil
    elseif M.payPump(car, report) then gamePump = nil end
  end
  local km = math.max(0, (car.km or 0) - (watch.km or car.km or 0))
  watch.km = car.km or 0
  if watch.off then
    -- The tank cannot be set on this vehicle: follow what the game shows.
    for name, t in pairs(fuel.clean(report) or {}) do
      if car.fuel and car.fuel.tanks and car.fuel.tanks[name] then car.fuel.tanks[name].ratio = t.ratio end
    end
    return
  end
  local set = fuel.observe(car, report, km)
  if set then
    watch.failed = (watch.failed or 0) + 1
    if watch.failed > M.FUEL_GIVE_UP then
      watch.off = true
      problem('W', 'fuel: could not put the remembered tank level back; following the game level')
    else
      M.G.setFuel(id, set)
    end
  else
    watch.failed = 0
  end
end

-- The nearest place to refuel the career car: { station, km, at } (looked up about once a second).
local function fuelNear()
  local g, p = S.career.garage, earth.pose()
  local st = g.car and fuel.state(g.car)
  if not st or not p then return nil, st end
  if S.fuelNear and S.clock < fuelNearAt and S.fuelNear.kind == st.kind then return S.fuelNear, st end
  fuelNearAt = S.clock + 1
  local station, km = fuel.nearest(S.fuelIdx, p.lat, p.lon, fuel.stationKind(st.kind), 40)
  -- The firm's own tank is a station too, once it is built.
  local firmState = S.career.firm
  local hq = firmState and firmState.hq
  if hq and firmState.upgrades and firmState.upgrades.tank and st.kind ~= 'electric' then
    local d = fuel.km(p.lat, p.lon, hq.g[1], hq.g[2])
    if not km or d < km or d * 1000 <= fuel.STATION_RADIUS then
      station, km = { id = 'hq', g = hq.g, n = 'Your firm tank', kind = 'fuel', hq = true }, d
    end
  end
  S.fuelNear = station and { station = station, km = km, kind = st.kind,
    at = km * 1000 <= fuel.STATION_RADIUS and not p.camera and (p.speed or 0) <= M.STOP_SPEED } or { kind = st.kind }
  return S.fuelNear, st
end

local function fuelFactor(station)
  return station.hq and fuel.HQ_DISCOUNT or fuel.stationFactor(station.id)
end

local function fuelCar()
  local g = S.career.garage
  if not g.started or not g.car or not garage.inOwnCar(M.G, g) then return nil, 'Sit in your career car first.' end
  if S.parts or g.preview or g.pendingUsed then return nil, 'Finish the parts or car preview first.' end
  if not fuelWatch or not M.G.setFuel then return nil, 'Reading the fuel gauge. Try again in a moment.' end
  if fuelWatch.off then return nil, 'This vehicle’s tank cannot be filled from the phone.' end
  if fuelPending then return nil, 'Refuelling…' end
  local p = earth.pose()
  if not p or p.camera or (p.speed or 0) > M.STOP_SPEED then return nil, 'Stop the car first.' end
  return g.car, nil, p
end

-- Takes the money (or adds a debt when there is none left: nobody is stranded) and fills the tank.
local function fuelBuy(car, quote, extra, detail, onCredit)
  local c, g = S.career, S.career.garage
  local cost = quote.cost + (extra or 0)
  local before = {}
  for name in pairs(quote.levels) do before[name] = car.fuel.tanks[name].ratio end
  if not M.G.setFuel(fuelWatch.id, quote.levels) then return false, 'Could not reach the car’s tank.' end
  local debt = false
  if cost > 0 then
    if onCredit and (c.money or 0) < cost then
      g.debt, debt = (g.debt or 0) + cost, true
    else
      economy.post(c, -cost, 'fuel', economy.nextId(c, 'fuel'), detail)
    end
  end
  fuel.apply(car, quote)
  car.fuel.bought = (car.fuel.bought or 0) + (extra or 0)
  fuelPending = { id = fuelWatch.id, car = car, levels = quote.levels, before = before, cost = cost, debt = debt,
    untilT = S.clock + M.FUEL_VERIFY_S }
  saveCareer()
  return true, cost, debt
end

local function unitsText(units)
  local parts = {}
  for _, kind in ipairs({ 'gasoline', 'diesel', 'electric' }) do
    if units[kind] then parts[#parts + 1] = string.format('%.1f %s', units[kind], fuel.UNIT[kind]) end
  end
  return table.concat(parts, ' + ')
end

-- A game pump filled the tank: books it and takes the money (a debt when the wallet is short, like fuel delivery).
function M.payPump(car, report)
  local c, g, st = S.career, S.career.garage, gamePump.station
  local free = car.loaner == true
  local quote = fuel.pumpQuote(car, report, fuel.stationFactor(st.id), free)
  if not quote then return false end
  local debt = false
  if quote.cost > 0 then
    if (c.money or 0) < quote.cost then
      g.debt, debt = (g.debt or 0) + quote.cost, true
    else
      economy.post(c, -quote.cost, 'fuel', economy.nextId(c, 'fuel'), st.n)
    end
  end
  fuel.apply(car, quote)
  say(free and string.format('Filled %s at %s on the company fuel card.', unitsText(quote.units), st.n)
    or string.format('Filled %s at %s for %d CZK%s.', unitsText(quote.units), st.n, quote.cost, debt and ' (added to your debt)' or ''), 8)
  saveCareer()
  return true
end

-- amount: units to buy, or nil for a full tank
local function fuelRefuel(amount)
  local car, why = fuelCar()
  if not car then return false, why end
  local near = fuelNear()
  if not near or not near.station or not near.at then return false, 'Park at a station first. Garage shows the nearest one.' end
  local free = car.loaner == true
  local money = math.max(0, S.career.money or 0)
  local quote = fuel.quote(car, fuel.sells(near.station.kind), fuelFactor(near.station), tonumber(amount), not free and money or nil, free)
  if not quote then
    local full = fuel.quote(car, fuel.sells(near.station.kind), fuelFactor(near.station), nil, nil, true)
    return false, full and 'Not enough money for fuel. Fuel delivery can go on your debt.' or 'The tank is full.'
  end
  local ok, cost = fuelBuy(car, quote, 0, near.station.n)
  if not ok then return false, cost end
  return true, free and string.format('Filled %s on the company fuel card.', unitsText(quote.units))
    or string.format('Filled %s for %d CZK.', unitsText(quote.units), cost)
end

-- Roadside delivery: a few litres anywhere, at a price. It can go on the debt, so an empty tank never ends a career.
local function fuelDelivery()
  local car, why = fuelCar()
  if not car then return false, why end
  local free = car.loaner == true
  local quote = fuel.quote(car, { gasoline = true, diesel = true, electric = true }, fuel.DELIVERY_FACTOR, fuel.DELIVERY_UNITS, nil, free)
  if not quote then return false, 'The tank is full.' end
  local ok, cost, debt = fuelBuy(car, quote, free and 0 or fuel.DELIVERY_FEE, 'Roadside fuel delivery', true)
  if not ok then return false, cost end
  return true, free and string.format('The company sent %s.', unitsText(quote.units))
    or string.format('Delivered %s for %d CZK%s.', unitsText(quote.units), cost, debt and ' (added to your debt)' or '')
end

local function fuelGps()
  if S.job then return false, 'Follow the current delivery GPS first.' end
  local near = fuelNear()
  if not near or not near.station then return false, 'No station is known nearby. Use fuel delivery, or start the helper for local stations.' end
  local ok, err = earth.gps(near.station.g[1], near.station.g[2], near.station.n)
  if not ok then return false, 'GPS not set: ' .. tostring(err) end
  return true, 'GPS set to ' .. near.station.n .. '.'
end

-- The fuel card on the phone's Garage page.
local function fuelState()
  local g = S.career.garage
  if not g.car or not garage.inOwnCar(M.G, g) then return nil end
  local near, st = fuelNear()
  if not st then return { reading = true } end
  st.free = g.car.loaner == true
  st.locked = fuelWatch and fuelWatch.off or nil
  st.busy = fuelPending ~= nil
  if near and near.station then
    local s = near.station
    st.station = { name = s.n, town = s.town, km = math.floor(near.km * 10 + 0.5) / 10, at = near.at, hq = s.hq,
      price = fuel.price(st.kind, fuelFactor(s)) }
    if near.at then
      local money = math.max(0, S.career.money or 0)
      local full = fuel.quote(g.car, fuel.sells(s.kind), fuelFactor(s), nil, nil, st.free)
      local can = fuel.quote(g.car, fuel.sells(s.kind), fuelFactor(s), nil, not st.free and money or nil, st.free)
      st.fill = full and { cost = full.cost, afford = can and can.full or false, canCost = can and can.cost or 0,
        units = can and unitsText(can.units) or nil }
    end
  end
  local delivery = fuel.quote(g.car, { gasoline = true, diesel = true, electric = true }, fuel.DELIVERY_FACTOR, fuel.DELIVERY_UNITS, nil, st.free)
  st.delivery = delivery and { cost = delivery.cost + (st.free and 0 or fuel.DELIVERY_FEE), units = unitsText(delivery.units) } or nil
  return st
end

local function garageSay(ok, msg)
  say(msg)
  -- Garage actions change money directly; give each change its own line in the money history.
  economy.reconcile(S.career, 'garage', msg)
  if ok then saveCareer() end
  return ok, msg
end

function M.garageStart(model)
  if S.career.employment then return false, 'End company work first.' end
  if S.career.garage.started then return false, 'Your career has already started.' end
  if S.job then M.cancel(true, true) end   -- a new career: orders from before go
  local ok, msg = garage.start(M.G, S.career.garage, S.career, model or S.config.starterModel)
  if ok then
    usedAt, conditionAt = S.clock + 1, nil
    S.career.garage.car.fuel = { start = 0.5 }   -- the old starter car comes with half a tank
  end
  return garageSay(ok, msg)
end
function M.garageSell(part) return garageSay(garage.sell(M.G, S.career.garage, S.career, part)) end
function M.garageRepair()
  -- the firm's workshop does the work for less at the headquarters: the discount counts before the money check
  local g = S.career.garage
  local full, factor = g.repair or 0, firm.repairFactor(S.career, earth.pose())
  local ok, msg, cost = garage.repairCar(M.G, g, S.career, factor)
  if ok and factor < 1 then
    msg = string.format('Repaired in your workshop (-%d CZK, %d CZK saved)', cost, full - cost)
  end
  return garageSay(ok, msg)
end
function M.garagePayDebt() return garageSay(garage.payDebt(S.career.garage, S.career)) end
function M.garageBuy(offer)
  if S.job then return false, 'Finish the order first' end
  local ok, msg = garage.buyCar(M.G, S.career.garage, S.career, offer)
  return garageSay(ok, msg)
end
-- Spawns the career car again with its parts (after driving something else).
function M.garageBringCar()
  local g = S.career.garage
  if not g.started or not g.car then return false, 'No career car yet' end
  local ok, why = spawnCareerCar(g)
  if not ok then return garageSay(false, why) end
  return garageSay(true, 'Here is your ' .. g.car.name .. '.')
end
function M.garageFreightLoaner()
  if S.job or S.parts then return false, 'Finish your current order or parts preview first.' end
  if earth.status() ~= 'ok' then return false, 'Wait for the world to finish loading.' end
  local tier = haul.state(S.career).unlocked
  local ok, why = garage.issueFreightLoaner(M.G, S.career.garage, S.career, tier, haul.loaners[tier])
  S.freightSetupError = not ok and why or nil
  if ok then
    releaseStorage()
    conditionAt, usedAt = S.clock + 3, nil
    S.phone.incoming, S.offeredAt = nil, nil
  end
  return garageSay(ok, why)
end
local function garageSwitchCar(id)
  if S.job then return false, 'Finish your current orders before switching cars.' end
  local here = earth.pose()
  if S.career.home and not home.near(S.career, here) and not firm.atHq(S.career, here) then
    return false, S.career.firm and S.career.firm.hq and 'Return to your home garage or headquarters to switch cars.'
      or 'Return to your home garage to switch cars.'
  end
  local ok, why = garage.switchCar(M.G, S.career.garage, tonumber(id))
  if ok then
    releaseStorage()
    local g = S.career.garage
    garage.updateStarter(g)
    usedAt = g.pendingUsed and S.clock + 1 or nil
    conditionAt, S.dirtyAt = not g.pendingUsed and S.clock + 3 or nil, nil
    S.phone.incoming, S.offeredAt = nil, nil
  end
  return garageSay(ok, why)
end
local function garageRefuel(amount) local ok, msg = fuelRefuel(amount) say(msg) return ok, msg end
local function garageFuelDelivery() local ok, msg = fuelDelivery() say(msg) return ok, msg end
local function garageFuelGps() return fuelGps() end
local function garageHireDriver(id, applicant)
  if S.career.firm then fleet.applicants(S.career.firm, (S.career.activeSeconds or 0) / 60, M.random) end
  return garageSay(fleet.hire(S.career.garage, S.career, tonumber(id), applicant))
end
-- Roadside help after a breakdown: the failed item is serviced, the engine can be started again.
local function garageRoadside()
  local g = S.career.garage
  local failure = g.car and g.car.breakdown
  if type(failure) ~= 'table' or not upkeep.byId[failure.id] then
    if g.car then g.car.breakdown = nil end
    return false, 'Your car is running.'
  end
  failure.cost = tonumber(failure.cost) or 0
  local paid, owed = upkeep.roadside(S.career, g, g.car, failure)
  g.car.breakdown = nil
  if M.G.stall then pcall(M.G.stall, false) end
  saveCareer()
  local msg = string.format('Roadside help fixed the %s for %d CZK%s. Start the engine and drive on.',
    upkeep.byId[failure.id].name:lower(), failure.cost, owed > 0 and string.format(' (%d CZK added to your debt)', owed) or '')
  say(msg)
  return true, msg
end
-- Where a service is possible now: at the headquarters (the workshop's share off) or at a fuel station.
local function serviceSpot()
  local p = earth.status() == 'ok' and earth.pose() or nil
  if firm.atHq(S.career, p) then return 'the headquarters', firm.value(S.career, 'workshop') or 1 end
  if not p or p.camera or (p.speed or 0) > M.STOP_SPEED then return nil end
  for _, kind in ipairs({ fuel.stationKind('gasoline'), fuel.stationKind('electric') }) do
    local station, km = fuel.nearest(S.fuelIdx, p.lat, p.lon, kind, 1)
    if station and km * 1000 <= fuel.STATION_RADIUS then return station.n or 'the fuel station', 1 end
  end
end
-- id: a parked vehicle's fleet id (it is at the headquarters), or nil for the car you drive; item: one, or nil for
-- all that are due.
local function garageService(id, item)
  local g, c = S.career.garage, S.career
  local car, where, factor
  if id ~= nil and id ~= '' and id ~= 'current' then
    car = garage.parkedCar(g, tonumber(id))
    if not car then return false, 'That vehicle is not parked here.' end
    if not (c.firm and c.firm.hq) then return false, 'Parked vehicles are serviced at the headquarters.' end
    where, factor = 'the headquarters', firm.value(c, 'workshop') or 1
  else
    car = g.car
    if not car or car.loaner then return false, 'The loaner is serviced by its company.' end
    if not garage.inOwnCar(M.G, g) then return false, 'Sit in your car first.' end
    where, factor = serviceSpot()
    if not where then return false, 'Drive to your headquarters or a fuel station for a service.' end
  end
  return garageSay(upkeep.service(c, car, item and item ~= '' and { item } or nil, factor, where))
end
local function garageRepairParked(id)
  local c = S.career
  if not (c.firm and c.firm.hq) then return false, 'Parked vehicles are repaired at the headquarters.' end
  return garageSay(garage.repairParked(S.career.garage, c, tonumber(id), firm.value(c, 'workshop') or 1))
end
local function garageReleaseDriver(id)
  return garageSay(fleet.release(S.career.garage, tonumber(id)))
end
function M.garageProbe() return M.G.probe(garage) end

-- The paid configuration stays on g.car while BeamNG previews changes on the live vehicle.
local function startParts(vehicle, fromGame)
  local g, G = S.career.garage, M.G
  if not g.started or (not fromGame and not garage.inOwnCar(G, g)) then return false, 'Sit in your career car first.' end
  if not vehicle or not vehicle.id or not vehicle.slotPartMap then return false, 'Wait for the career car to load.' end
  local damage = G.damage(vehicle.id) or 0
  local blocked = S.job and 'Finish the current order before changing parts.'
    or g.pendingUsed and 'Wait for the car to finish loading its parts.'
    or (g.car and g.car.loaner) and 'The loaner comes with fixed equipment.'
    or ((g.repair or 0) > 0 or damage * garage.REPAIR_PER_DAMAGE >= 2.5) and 'Repair the car before changing parts.'
  if blocked and not fromGame then return false, blocked end
  -- Native Apply may have already changed the live config when its hook arrives.
  -- Keep the last paid snapshot as the baseline, rather than accepting that preview for free.
  if not fromGame or not g.car or type(g.car.parts) ~= 'table' then
    if not garage.remember(G, g, vehicle) then return false, 'The career car configuration is unavailable.' end
  end
  if damage > (g.lastDamage or 0) then garage.trackDamage(g, damage) end
  S.partsRevision = (S.partsRevision or 0) + 1
  S.parts = { before = g.car.parts, id = vehicle.id, blocked = blocked }
  S.phone.incoming, S.phone.lastDone, S.window = nil, nil, false
  S.garageMsg = nil
  return true
end

local function previewVehicle()
  local G = M.G
  local v = G.ownedVehicle and G.ownedVehicle() or G.vehicle()
  if not v or v.id ~= S.parts.id or not v.slotPartMap or (G.isOwned and not G.isOwned(v)) then return nil end
  if S.parts.waiting == (v.data or v.slotPartMap) then return nil end
  S.parts.waiting = nil
  return v
end

local function quoteParts()
  if not S.parts then return nil, 'No parts preview is open.' end
  if S.parts.blocked then return nil, S.parts.blocked end
  local ok, quote, why = pcall(function()
    local v = previewVehicle()
    if not v then return nil, 'Waiting for BeamNG to apply the preview.' end
    return garage.partsQuote(M.G, S.career.garage.inventory, S.parts.before, v)
  end)
  if not ok then
    if S.parts.quoteError ~= tostring(quote) then
      S.parts.quoteError = tostring(quote)
      problem('E', 'parts checkout: ' .. S.parts.quoteError)
    end
    return nil, 'Could not price the preview. Retry checkout or discard it to restore your paid parts.'
  end
  S.parts.quoteError = nil
  return quote, why
end

local function partsProblem(quote)
  local g = S.career.garage
  if (g.repair or 0) > 0 then return 'Repair the car before changing parts.' end
  if quote.cost > 0 and (g.debt or 0) > 0 then return 'Pay off your debt before buying parts.' end
  if quote.cost > (S.career.money or 0) then return 'Not enough money for these parts.' end
end

local function openParts()
  if not garage.inOwnCar(M.G, S.career.garage) then return false, 'Sit in your career car first.' end
  local opening = not S.parts
  if opening then
    local ok, why = startParts(M.G.vehicle())
    if not ok then return false, why end
  end
  local ok, opened, why = pcall(M.G.openParts)
  if ok and opened then return true end
  if opening then S.parts = nil end
  if not ok then
    problem('W', 'Could not open BeamNG’s parts editor: ' .. tostring(opened))
    return false, 'Could not open the parts editor.'
  end
  return false, why
end

local function finishParts()
  S.parts = nil
  S.phone.nextPingAt = S.clock + 2
end

local function cancelParts()
  if not S.parts then return false, 'No parts preview is open.' end
  local blocked, g = S.parts.blocked, S.career.garage
  local ok, why = spawnCareerCar(g, S.parts.id)
  if not ok then return false, why end
  finishParts()
  saveCareer()
  return true, blocked or 'Original configuration restored.'
end

local function buyParts(revision)
  if not S.parts then return false, 'No parts preview is open.' end
  if tonumber(revision) ~= S.partsRevision then return false, 'The preview changed. Review the new total.' end
  local quote, why = quoteParts()
  if not quote then return false, why end
  why = partsProblem(quote)
  if why then return false, why end
  local c, g = S.career, S.career.garage
  local money, spent, inventory, config, parts = c.money, g.spent, g.inventory, g.car.config, g.car.parts
  if not garage.remember(M.G, g, previewVehicle()) then return false, 'Could not capture the new configuration.' end
  c.money, g.spent, g.inventory = (money or 0) - quote.cost, (spent or 0) + quote.cost, quote.inventory
  economy.reconcile(c, 'parts', 'Parts fitted')
  if not saveCareer() then
    c.money, g.spent, g.inventory, g.car.config, g.car.parts = money, spent, inventory, config, parts
    economy.reconcile(c, 'parts', 'Purchase not saved, refunded')
    return false, 'The purchase could not be saved. Try again.'
  end
  finishParts()
  conditionAt = S.clock + 1
  return true, quote.cost > 0 and string.format('Parts fitted. Paid %d CZK.', quote.cost) or 'Parts changes kept.'
end

-- For the phone app (small, JSON friendly): the garage page.
function M.garageState()
  local g, G = S.career.garage, M.G
  local out = { started = g.started, money = S.career.money or 0, startMoney = garage.START_MONEY,
    starter = S.config.starterModel or garage.STARTER_MODEL, busy = S.job ~= nil, msg = S.garageMsg,
    currency = moneyInfo() }
  if S.parts then
    local quote, why = quoteParts()
    if quote then why = partsProblem(quote) end
    out.parts = { revision = S.partsRevision, items = quote and quote.items, cost = quote and quote.cost,
      error = why, canBuy = quote ~= nil and not why, blocked = not not S.parts.blocked }
    return out
  end
  if not g.started then return out end
  out.fleet = fleet.state(g, S.career, firm.driverFactor(S.career))
  for _, v in ipairs(out.fleet.cars) do
    local car = garage.parkedCar(g, v.id)
    if car and not car.loaner then v.upkeep = upkeep.state(car, firm.value(S.career, 'workshop')) end
  end
  local shift = S.career.employment
  if g.car and not g.car.loaner and (not shift or shift.ownerOperator) then
    local where, factor = serviceSpot()
    out.upkeep = upkeep.state(g.car, factor)
    out.upkeep.where = where
  end
  local broken = g.car and g.car.breakdown
  if type(broken) == 'table' then out.breakdown = { text = broken.text, cost = broken.cost } end
  out.capacity = firm.capacity(S.career)
  out.car = g.car and g.car.name or nil
  out.loaner = g.car and g.car.loaner or nil
  out.km = g.car and math.floor(g.car.km or 0) or nil
  out.own = garage.inOwnCar(G, g)
  out.repair = g.repair or 0
  out.debt = g.debt or 0
  out.debtShare = garage.DEBT_SHARE
  out.income = math.floor(garage.INCOME_PER_HOUR / 10 + 0.5) * 10   -- what an hour of deliveries pays
  out.repairHours = garage.hours(out.repair)
  local cap = garage.repairCap(g)
  out.repairCapped = cap ~= nil and out.repair > 0 and out.repair >= cap or nil
  if g.preview then
    local l = garage.findListing(g, g.preview.id)
    if l then
      local names = {}
      for i, m in ipairs(g.preview.ready and l.missing or {}) do names[i] = m.name end
      out.preview = { id = l.id, name = l.name, km = l.km, condition = l.condition, price = l.price,
        tradeIn = g.preview.tradeIn, keepCar = g.preview.keepCar, ready = g.preview.ready, error = g.preview.error,
        paint = g.preview.ready and l.finish and l.finish.name or nil, missing = names }
    end
  end
  out.damage = g.lastDamage or 0
  if out.own then
    out.value = garage.carWorth(G, g)
    out.tradeIn = math.floor(out.value * garage.TRADE_IN / 5 + 0.5) * 5
    out.sellPrice = math.max(0, out.tradeIn - (g.repair or 0))
    out.condition = g.car and g.car.condition or 1
  end
  out.spares = garage.spares(G, g)
  out.fuel = fuelState()
  return out
end

-- the used-car market for the phone
function M.garageDealer(filter)
  local g = S.career.garage
  garage.marketTick(M.G, g, 0)
  local cars = garage.market(g, filter)
  local inCar = g.car and not g.car.loaner and garage.inOwnCar(M.G, g)
  return { cars = cars, tradeIn = inCar and math.floor(garage.carWorth(M.G, g) * garage.TRADE_IN / 5 + 0.5) * 5 or 0,
    money = S.career.money or 0, debt = g.debt or 0 }
end
function M.garageBuyListing(id, keepCar)
  if S.job then return false, 'Finish the order first' end
  local g = S.career.garage
  local keeping = keepCar == true
  if g.preview then keeping = g.preview.keepCar == true end
  if keeping and home.count(g) >= firm.capacity(S.career) then
    return garageSay(false, S.career.firm and 'Every parking bay is taken. Build more bays, trade in a car or sell one first.'
      or 'Your garage is full. Trade in a car or sell one first.')
  end
  local ok, msg = garage.buyListing(M.G, S.career.garage, S.career, tonumber(id), keepCar == true)
  if ok then
    local bought = S.career.garage.car
    if bought and not bought.fuel then bought.fuel = { start = fuel.usedStart() } end   -- what the last owner left in it
    previewAt = nil
    usedAt = S.career.garage.pendingUsed and S.clock + 1 or nil
    conditionAt = nil
    S.phone.incoming, S.offeredAt = nil, nil
  end
  return garageSay(ok, msg)
end
function M.garagePreview(id, keepCar)
  if S.job then return false, 'Finish the order first' end
  local ok, msg = garage.previewStart(M.G, S.career.garage, tonumber(id), keepCar == true)
  if ok then previewAt = S.clock + 2 end
  return garageSay(ok, msg)
end
function M.garagePreviewEnd()
  local ok, msg = garage.previewEnd(M.G, S.career.garage)
  if ok and S.career.garage.car then conditionAt = S.clock + 3 end
  return garageSay(ok, msg)
end
function M.garageSellCar()
  if S.job then return false, 'Finish the order first' end
  return garageSay(garage.sellCar(M.G, S.career.garage, S.career))
end

-- Runs a garage action for the phone and returns the new garage page with its message.
function M.garageDo(name, a, b)
  if S.pendingCareer then return M.garageState() end
  local fuelAction = name == 'refuel' or name == 'fuelDelivery' or name == 'fuelGps'
  if S.career.employment and name ~= 'bring' and not fuelAction then
    S.garageMsg = 'Company equipment is fixed. End company work in Places to use your garage.'
    return M.garageState()
  end
  local partsAction = name == 'openParts' or name == 'buyParts' or name == 'cancelParts'
  if S.parts and not partsAction then return M.garageState() end
  local fns = { start = M.garageStart, repair = M.garageRepair, paydebt = M.garagePayDebt, sellCar = M.garageSellCar,
    buyListing = M.garageBuyListing, preview = M.garagePreview, back = M.garagePreviewEnd, bring = M.garageBringCar,
    switchCar = garageSwitchCar, hireDriver = garageHireDriver, releaseDriver = garageReleaseDriver,
    roadside = garageRoadside, service = garageService, repairParked = garageRepairParked,
    refuel = garageRefuel, fuelDelivery = garageFuelDelivery, fuelGps = garageFuelGps,
    sell = M.garageSell, openParts = openParts, buyParts = buyParts, cancelParts = cancelParts }
  local f = fns[name]
  local ok, msg = false, 'Unknown action'
  if name == 'probe' then
    local r = M.garageProbe()
    ok, msg = true, string.format('Saved settings/cargoEarth/garage_probe.json: %s, %d parts slots, %d cars.',
      tostring(r.model), r.shopSlots or 0, r.configs or 0)
  elseif f then
    local okCall, r1, r2 = pcall(f, a, b)
    if okCall then ok, msg = r1, r2
    else ok, msg = false, 'Error: ' .. tostring(r1) problem('E', 'garage ' .. name .. ': ' .. tostring(r1)) end
  end
  S.garageMsg = msg
  return M.garageState()
end

------------------------------------------------------------------------------------------ the firm and its headquarters

local function personalGarage()
  local shift = S.career.employment
  return shift and shift.personalGarage or S.career.garage
end

-- The real place the car is parked at that can become the headquarters: the nearest known yard or warehouse,
-- else the home garage.
local function hqPlace(p)
  if not p or not p.lat then return nil end
  local best, bestM
  for _, d in ipairs(S.idx and S.idx.depots or {}) do
    if d.g and math.abs(d.g[1] - p.lat) < 0.002 then
      local m = jobs.km(p.lat, p.lon, d.g[1], d.g[2]) * 1000
      if m <= firm.PLACE_RADIUS and (not bestM or m < bestM) then best, bestM = d, m end
    end
  end
  if best then return { id = best.id, n = best.n, town = best.town, g = best.g } end
  local h = S.career.home
  if h and home.near(S.career, p) then return { id = 'home', n = 'Home office', town = h.town, g = h.g } end
end

function M.firmState()
  local c, p = S.career, earth.status() == 'ok' and earth.pose() or nil
  local out = firm.state(c, p, personalGarage().debt or 0)
  out.msg = S.firmMsg
  if out.founded then
    local spot = p and not p.camera and hqPlace(p)
    out.place = spot and { name = spot.n, town = spot.town } or nil
    out.parked = p ~= nil and not p.camera and (p.speed or 0) <= M.STOP_SPEED
  end
  return out
end

-- The full-screen headquarters: the firm, every parking bay with its car and driver, the workshop, tank and stores.
function M.hqState()
  local c, g = S.career, personalGarage()
  local out = M.firmState()
  out.currency = moneyInfo()
  if not out.founded then return out end
  out.bays = {}
  local workshop = firm.value(c, 'workshop') or 1
  local factor = firm.driverFactor(c)
  local function bay(car, current)
    local owed = not current and garage.parkedRepairCost(car) or 0
    out.bays[#out.bays + 1] = { id = car.fleetId, name = car.name, current = current or nil, loaner = car.loaner or nil,
      km = math.floor(car.km or 0), condition = car.condition, repair = owed > 0 and owed or nil,
      repairCost = owed > 0 and math.floor(owed * workshop / 5 + 0.5) * 5 or nil,
      broken = type(car.breakdown) == 'table' and car.breakdown.text or nil,
      tier = upkeep.tier(car), upkeep = upkeep.state(car, workshop),
      driver = fleet.driverState(car.driver, car, factor) }
  end
  if g.car and not g.car.loaner then bay(g.car, true) end
  for _, car in ipairs(g.parked or {}) do if not car.loaner then bay(car, false) end end
  out.free = math.max(0, out.capacity - #out.bays)
  local drivers = 0
  for _, b in ipairs(out.bays) do if b.driver then drivers = drivers + 1 end end
  local f = fleet.state(g, c, firm.driverFactor(c))
  out.drivers = { count = drivers, pay = f.pay, shiftMinutes = f.shiftMinutes, hireFee = f.hireFee, earned = f.earned,
    can = fleet.unlocked(c), applicants = fleet.applicants(c.firm, (c.activeSeconds or 0) / 60, M.random),
    nextMin = math.max(1, math.ceil((c.firm.applicantsAt or 0) + fleet.APPLICANT_MIN - (c.activeSeconds or 0) / 60)) }
  for _, a in ipairs(out.drivers.applicants) do
    a.nets = {}
    for tier, gross in pairs(fleet.GROSS) do a.nets[tier] = math.floor(gross * a.speed * factor + 0.5) - a.wage end
  end
  -- the factory and the trailer yard
  out.shop = {}
  for _, v in ipairs(firm.VEHICLES) do
    local offer = firm.vehicleOffer(v.id)
    offer.price = garage.newPrice(M.G, v.model, v.key) or offer.price
    out.shop[#out.shop + 1] = { id = offer.id, name = offer.name, text = offer.text, price = offer.price,
      can = out.free > 0 and (c.money or 0) >= offer.price and (g.debt or 0) <= 0 }
  end
  out.trailerShop = {}
  for _, t in ipairs(firm.TRAILERS) do
    out.trailerShop[#out.trailerShop + 1] = { id = t.id, name = t.name, text = t.text, price = t.price,
      can = (c.money or 0) >= t.price and (g.debt or 0) <= 0 and #firm.trailers(c) < firm.TRAILER_MAX }
  end
  out.trailers = {}
  local semiDrivers = 0
  for _, b in ipairs(out.bays) do if b.driver and b.tier == 'semi' then semiDrivers = semiDrivers + 1 end end
  for i, t in ipairs(firm.trailers(c)) do
    out.trailers[#out.trailers + 1] = { id = t.id, name = t.name, kind = t.kind, busy = i <= semiDrivers or nil }
  end
  out.trailerBonus = math.floor(firm.TRAILER_BONUS * 100 + 0.5)
  out.workshopFactor = workshop
  local parts, kinds = 0, 0
  out.parts = { items = {} }
  local okSpares, spares = pcall(garage.spares, M.G, g)   -- (names the parts as the shop does)
  for _, row in ipairs(okSpares and spares or {}) do
    parts, kinds = parts + (tonumber(row.count) or 0), kinds + 1
    if #out.parts.items < 12 then out.parts.items[#out.parts.items + 1] = { name = row.name, count = row.count } end
  end
  out.parts.count, out.parts.kinds = parts, kinds
  if not c.employment then out.fuel = fuelState() end
  out.repair = { cost = g.repair or 0, factor = firm.repairFactor(c, earth.pose()) }
  out.debt, out.busy, out.company = g.debt or 0, S.job ~= nil, c.employment ~= nil
  return out
end

-- name: found (a = name), rename (a = name), setHq, gpsHq, upgrade (a = id). Returns the firm for the phone.
function M.firmDo(name, a)
  if S.pendingCareer then return M.firmState() end
  local c, p = S.career, earth.status() == 'ok' and earth.pose() or nil
  local debt = personalGarage().debt or 0
  local ok, msg = false, 'Unknown action'
  if name == 'found' then ok, msg = firm.found(c, a, debt)
  elseif name == 'rename' then ok, msg = firm.rename(c, a)
  elseif name == 'setHq' then
    if S.job or c.employment then ok, msg = false, 'Finish your current work first.'
    else ok, msg = firm.setHq(c, p and hqPlace(p), p) end
  elseif name == 'gpsHq' then
    if c.firm and c.firm.hq then ok, msg = earth.gps(c.firm.hq.g[1], c.firm.hq.g[2], c.firm.name), 'Route set to your headquarters.'
    else msg = 'Choose the headquarters first.' end
  elseif name == 'upgrade' then ok, msg = firm.upgrade(c, a, debt)
  end
  S.firmMsg = msg
  if ok and name ~= 'gpsHq' then
    S.fuelNear, fuelNearAt = nil, 0
    say(msg)
    saveCareer()
  end
  return M.firmState()
end

-- The same actions from the headquarters screen, plus the garage's (repair, switchCar, hireDriver, releaseDriver,
-- refuel): returns the headquarters.
function M.hqDo(name, a, b)
  if name == 'found' or name == 'rename' or name == 'setHq' or name == 'gpsHq' or name == 'upgrade' then
    M.firmDo(name, a)
  else
    local allowed = { repair = true, switchCar = true, hireDriver = true, releaseDriver = true, refuel = true, paydebt = true,
      service = true, repairParked = true }
    if allowed[name] then S.firmMsg = M.garageDo(name, a, b).msg
    elseif name == 'buyVehicle' or name == 'buyTrailer' or name == 'sellTrailer' then
      local c, g = S.career, personalGarage()
      local ok, msg = false, 'Unknown action'
      if c.employment then ok, msg = false, 'End company work first.'
      elseif not (c.firm and c.firm.hq) then ok, msg = false, 'Choose the headquarters first.'
      elseif name == 'buyTrailer' then ok, msg = firm.buyTrailer(c, a, g.debt)
      elseif name == 'sellTrailer' then ok, msg = firm.sellTrailer(c, tonumber(a))
      else
        local v = firm.vehicleOffer(a)
        if v then
          v.price = garage.newPrice(M.G, v.model, v.key) or v.price
          ok, msg = garage.buyForFirm(g, c, v, firm.capacity(c))
          if ok then economy.reconcile(c, 'firm', msg) end
        end
      end
      S.firmMsg = msg
      if ok then say(msg) saveCareer() end
    end
  end
  return M.hqState()
end

------------------------------------------------------------------------------------------ settings for the phone

-- numeric options the phone can change: key, label, step, min, max, unit
local aboutHelper   -- (the support report, below)
M.SETTINGS = {
  courier = { { 'nearKm', 'Pickups within', 0.5, 0.5, 25, 'km' }, { 'minKm', 'Shortest order', 0.5, 0.5, 8, 'km' },
    { 'maxKm', 'Longest order', 0.5, 1, 8, 'km' }, { 'maxOrders', 'Orders at once', 1, 1, 3, '' } },
  trucking = { { 'nearKm', 'Pickups within', 5, 5, 200, 'km' }, { 'minKm', 'Shortest job', 10, 10, 600, 'km' },
    { 'maxKm', 'Longest job', 10, 20, 1000, 'km' } },
}

function M.settingsState()
  local defs = S.mode == 'courier' and food.defaults or jobs.defaults
  local freightTier, opts = nil, S.opts
  if S.mode == 'trucking' then
    local tier = freightSettingsTier()
    freightTier, opts = haul.tiers[tier], freightOptions(tier)
  end
  local out = { mode = S.mode, canSwitch = S.job == nil and not S.career.employment, canPause = S.career.savedAt ~= nil, window = S.window,
    reviewingParts = S.parts ~= nil, items = {} }
  for _, d in ipairs(M.SETTINGS[S.mode]) do
    local key, step, min, max, default = d[1], d[3], d[4], d[5], defs[d[1]]
    if freightTier and (key == 'minKm' or key == 'maxKm') then
      min, max, default = freightTier.minKm, freightTier.maxKm, freightTier[key]
      step = key == 'minKm' and 1 or 5
    end
    local v = math.max(min, math.min(max, opts[key] or default))
    out.items[#out.items + 1] = { key = key, label = d[2], step = step, min = min, max = max, unit = d[6], value = v }
  end
  out.dash = dash.state(M.G.vehicle and M.G.vehicle() or nil)
  out.dash.error = S.dashError
  aboutHelper()
  out.update = M.updateInfo() or { mod = M.VERSION, unknown = true }
  out.cameras = { on = not S.career.camerasOff, known = #cams.list,
    helper = cams.state or (helper.status().cameras == 'off' and 'off' or nil) }
  if S.mode == 'courier' then
    out.autoReach = S.opts.autoReach
    if out.autoReach == nil then out.autoReach = food.defaults.autoReach end
  end
  return out
end

-- name: mode (a = courier | trucking), step (a = key, b = +1 | -1), autoReach (a = true | false), reset, window,
-- dash (a = on | off | x+ | x- | y+ | y- | z+ | z- | reset | measure: the phone on the dashboard, see dashDo)
function M.settingsDo(name, a, b)
  -- the dash phone is the player's own choice, outside the career: it works on the resume screen too
  if name == 'dash' then
    local ok, why = M.dashDo(a)
    S.dashError = not ok and why or nil
    return M.settingsState()
  end
  if S.pendingCareer then return M.settingsState() end
  if S.parts then return M.settingsState() end
  if name == 'pause' then
    pauseCareer()
    return M.settingsState()
  end
  if name == 'mode' then M.setMode(a)
  elseif name == 'step' then
    for _, item in ipairs(M.settingsState().items) do
      if item.key == a then
        local v = item.value + item.step * (tonumber(b) or 0)
        M.setOption(a, math.max(item.min, math.min(item.max, math.floor(v / item.step + 0.5) * item.step)))
      end
    end
  elseif name == 'autoReach' then S.opts.autoReach = a and true or false
  elseif name == 'cameras' then
    S.career.camerasOff = (not a) or nil
    cameras.clear(cams)
  elseif name == 'reset' then M.resetOptions()
  elseif name == 'window' then M.toggleWindow() end
  if name ~= 'window' then
    saveCareer()
    if not S.job then S.offeredAt = nil end
  end
  return M.settingsState()
end
M.garage = garage

------------------------------------------------------------------------------------------ actions for the window

------------------------------------------------------------------------------------------ support report

-- What the helper says about itself (/v1/info), asked for while the settings are open, for the support report.
-- The same answer carries the newest Cargo Earth release on GitHub (the helper looks it up; the game cannot go
-- online), so it is also asked for now and then while playing: the phone then says an update is out.
local helperAbout, helperAboutAt = nil, -math.huge
local updateAskAt, updateSaid = nil, nil
M.HELPER_ABOUT_S = 30
M.UPDATE_FIRST_S = 20      -- the first update question, this long after the mod starts
M.UPDATE_ASK_S = 1800      -- then this often (the helper itself asks GitHub every 6 hours)
M.UPDATE_RETRY_S = 300     -- the helper did not answer: ask again after this long
M.RELEASES = 'https://github.com/themazzy/cargo-earth/releases'

-- '0.10.2' newer than '0.9.3'? Plain release numbers only; anything else is never newer.
function M.versionNewer(latest, current)
  local function parts(v)
    local a, b, c = tostring(v or ''):match('^v?(%d+)%.(%d+)%.?(%d*)$')
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) or 0 }
  end
  local x, y = parts(latest), parts(current)
  if not x or not y then return false end
  for i = 1, 3 do
    if x[i] ~= y[i] then return x[i] > y[i] end
  end
  return false
end

local function onAbout(data, err)
  helperAbout = data or { error = tostring(err or 'no answer') }
  if not data then return end
  local u = M.updateInfo()
  if u and u.available and updateSaid ~= u.latest then
    updateSaid = u.latest
    say('Cargo Earth ' .. u.latest .. ' is out. Open the phone to get it.', 10)
  end
end

aboutHelper = function()
  if not helper.enabled or S.clock - helperAboutAt < M.HELPER_ABOUT_S then return end
  helperAboutAt = S.clock
  helper.ask('/v1/info', onAbout)
end

-- From the helper tick: ask for the newest release now and then.
askUpdate = function()
  if not helper.enabled then return end
  updateAskAt = updateAskAt or S.clock + M.UPDATE_FIRST_S
  if S.clock < updateAskAt then return end
  updateAskAt = S.clock + M.UPDATE_ASK_S
  helperAboutAt = S.clock
  helper.ask('/v1/info', function(data, err)
    if not data then updateAskAt = S.clock + M.UPDATE_RETRY_S end
    onAbout(data, err)
  end)
end

-- What the phone shows about updates: nil until the helper has said which release is the newest.
-- { latest, mod, helper, modOld, helperOld, available, hidden (the player closed the notice for this release), checkError }
function M.updateInfo()
  local a = helperAbout
  local u = a and type(a.update) == 'table' and a.update or nil
  if not u or type(u.latest) ~= 'string' then return nil end
  local helperVersion = tostring(a.version or '?')
  local modOld, helperOld = M.versionNewer(u.latest, M.VERSION), M.versionNewer(u.latest, helperVersion)
  return { latest = u.latest, mod = M.VERSION, helper = helperVersion, modOld = modOld, helperOld = helperOld,
    available = modOld or helperOld, hidden = S.career and S.career.updateHidden == u.latest or false,
    checkError = type(u.error) == 'string' and u.error or nil }
end

-- name: open (the release page in the player's browser) | hide (close the notice until a newer release)
function M.updateDo(name)
  local u = M.updateInfo()
  if name == 'hide' and u and S.career then
    S.career.updateHidden = u.latest
    saveCareer()
  elseif name == 'open' then
    -- the helper opens it (Python's webbrowser); a helper too old for that: the game's own browser call
    helper.ask('/v1/update/open', function(data)
      if data and data.opened then return end
      local open = rawget(_G, 'openWebBrowser')
      if not (open and pcall(open, M.RELEASES .. '/latest')) then
        say('Open ' .. M.RELEASES .. ' in your browser to download the update.', 10)
      end
    end)
  end
  return M.updateInfo()
end

local function gameValue(fn)
  local ok, v = pcall(fn)
  if ok and v ~= nil and v ~= '' then return tostring(v) end
  return '?'
end

-- Plain text a player can paste into Discord or a GitHub issue: versions, BeamNG.Earth and helper state, the
-- last problems. Where they are only to 0.1 degree (about 10 km), never the home or the exact spot. Copied to the
-- clipboard by the game; the phone shows it too. phoneNotes: the phone's own errors.
function M.supportReport(phoneNotes)
  local lines = {}
  local function add(...) lines[#lines + 1] = table.concat({ ... }) end
  local c = S.career or {}
  add('Cargo Earth support report (', os.date('!%Y-%m-%d %H:%M UTC'), ')')
  add('Mod: ', M.VERSION, ', save schema ', tostring(persistence.VERSION))
  add('BeamNG: ', gameValue(function() return rawget(_G, 'beamng_versiond') or rawget(_G, 'beamng_versionb') or rawget(_G, 'beamng_version') end),
    ', level ', gameValue(function() return getMissionFilename() end))
  add('BeamNG.Earth: ', gameValue(earth.status))
  add('Mode: ', tostring(S.mode), ', phase ', tostring(S.phase), ', online ', S.phone.online and 'yes' or 'no',
    ', career ', S.pendingCareer and 'paused/resume screen' or 'running', S.parts and ', parts preview open' or '')
  add('Car: ', gameValue(function() local v = M.G.vehicle and M.G.vehicle() return v and v.model end))
  local p = earth.pose()
  local cc = S.borders and p and borders.find(S.borders, p.lat, p.lon) or nil
  add('Where: ', p and string.format('about %.1f, %.1f', p.lat, p.lon) or 'no position', cc and (' (' .. cc .. ')') or '')
  local h = helper.status()
  add('Helper: ', helper.enabled and tostring(h.state) or 'turned off in config.json', ' on port ', tostring(helper.PORT),
    ', areas ', tostring(h.ready or 0), ' ready, ', tostring(h.loading or 0), ' loading',
    h.cameras and (', cameras ' .. tostring(h.cameras)) or '', h.supportsGrocers == false and ', old helper (no groceries)' or '')
  if h.msg then add('Helper says: ', tostring(h.msg)) end
  local a = helperAbout
  if a and a.error then add('Helper info: no answer (', a.error, ')')
  elseif a then
    local missing = type(a.missing) == 'table' and #a.missing > 0 and table.concat(a.missing, ', ') or nil
    local net = type(a.network) == 'table' and a.network or {}
    add('Helper info: version ', tostring(a.version), ', Overture ', tostring(a.release),
      missing and (', MISSING libraries: ' .. missing) or '', ', ', tostring(net.requests or 0), ' downloads')
  else add('Helper info: not asked yet (open Settings with the game running, then copy again)') end
  local up = M.updateInfo()
  if up then add('Newest release: ', up.latest, up.available and ' (update available)' or ' (up to date)') end
  add('Data: ', S.loadError and ('ERROR ' .. S.loadError) or (S.packInfo ~= '' and S.packInfo or 'bundled packs loaded'))
  if S.saveError then add('Save: ', tostring(S.saveError)) end
  add('Money: ', tostring(math.floor(c.money or 0)), ' CZK, ', tostring(c.delivered or 0), ' deliveries')
  add('Recent problems:')
  if #problems == 0 then add('  none') end
  for _, line in ipairs(problems) do add('  ', line) end
  if type(phoneNotes) == 'table' and #phoneNotes > 0 then
    add('Phone errors:')
    for i = math.max(1, #phoneNotes - 9), #phoneNotes do add('  ', tostring(phoneNotes[i]):sub(1, 300)) end
  end
  local text = table.concat(lines, '\n')
  local copied = false
  local set = rawget(_G, 'setClipboard')
  if set then copied = pcall(set, text) end
  return { text = text, copied = copied }
end

function M.forceArrive()
  if S.phase == 'toPickup' then finishPickup() elseif S.phase == 'toDelivery' then finishDelivery(true) end
end

-- Teleport to the job's pickup / delivery (its road or curb point, so the car lands on a road), or an offer's pickup.
function M.teleport(which, i)
  local d
  if which == 'offer' then d = S.offers[i] and S.offers[i].from
  elseif S.job then d = (which == 'pickup') and S.job.from or S.job.to end
  if not d then return end
  local pt = d.r or d.g
  local ok, why = earth.teleport(pt[1], pt[2], d.n)
  if not ok then say('Teleport refused: ' .. tostring(why)) end
end

function M.spawnTrailer(atPickup)
  local j, p = S.job, earth.pose()
  if not j or not j.trailer or not p or p.camera or earth.status() ~= 'ok' then return end
  if j.tow then
    -- the trailer is gone (a reload) or a car slid off: load the cars on again, for a fee
    if S.phase ~= 'toDelivery' then return end
    if (p.speed or 0) > M.STOP_SPEED then say('Stop before loading the cars again.') return end
    if (S.career.money or 0) < M.TOW_RELOAD_FEE then say('Not enough money to load the cars again.') return end
    -- the damage done so far stays counted: the cars spawned again come without it
    local before = j.tow.damage0 and math.max(0, trailers.towedDamage() - j.tow.damage0) or 0
    local ok, why = trailers.spawnTow(tow.CLASSES[j.tow.class].trailer, j.tow.cars)
    if not ok then say('The cars could not be loaded: ' .. tostring(why)) return end
    economy.post(S.career, -M.TOW_RELOAD_FEE, 'cancel_fee', economy.nextId(S.career, 'cancel_fee'), 'Tow: loading the cars again')
    j.tow.damageDone = (j.tow.damageDone or 0) + before
    j.trailerSpawned, j.tow.spawnedAt, j.tow.damage0, j.tow.onBoard = true, S.clock, nil, #j.tow.cars
    say(string.format('The cars are back on the trailer (%d CZK). Couple it again.', M.TOW_RELOAD_FEE))
    saveCareer()
    return
  end
  if j.haul then
    if trailers.id() then return end
    if not atPickup and S.phase ~= 'toDelivery' and not j.trailerRequested then return end
    local v, tier = freightCarrier()
    if not v or tier ~= 'semi' or (p.speed or 0) > M.STOP_SPEED then
      say('Stop the tractor before restoring the trailer.')
      return
    end
  end
  local ok, why = trailers.spawn(j.trailer, j.haul and j.haul.kind)
  j.trailerSpawned = ok
  if ok and j.haul then
    j.trailerRequested = true
    S.freightStatus = 'Couple the assigned trailer.'
    saveCareer()
  elseif not ok then
    S.stopT = -6
    say('Trailer not spawned: ' .. tostring(why))
  end
end

function M.setOption(k, v)
  if S.mode ~= 'trucking' or (k ~= 'minKm' and k ~= 'maxKm') then S.opts[k] = v return end
  local tier = freightSettingsTier()
  S.opts.freightRanges = S.opts.freightRanges or {}
  S.opts.freightRanges[tier] = S.opts.freightRanges[tier] or {}
  S.opts.freightRanges[tier][k] = v
end

function M.resetOptions()
  for k in pairs(S.opts) do S.opts[k] = nil end
end

function M.saveOptions() saveCareer() end

function M.gpsAgain() gpsToTarget() end

function M.toggleWindow() S.window = not S.window end
function M.togglePhone() S.phoneHidden = not S.phoneHidden end

function M.state() return S end

M.rules = rules
M.arrivalRadius = arrivalRadius

------------------------------------------------------------------------------------------ hooks

function M.onExtensionLoaded()
  dash.load()
  local okIo, jbeamIO = pcall(require, 'jbeam/io')
  if okIo and not dash.install(jbeamIO) then log('W', 'cargoEarth', 'dash phone: the game\'s jbeam part lookup was not found') end
  loadPacks()
  loadConfig()
  local saved, recovery = persistence.load(jsonReadFile, SAVE)
  if not saved and not recovery and FS.fileExists and FS:fileExists(SAVE) then
    recovery = 'The career save and its backups could not be read. Your files have been left untouched.'
  end
  if type(saved) == 'table' then S.pendingCareer = saved end
  if recovery then S.saveError = recovery end
  if not saved and recovery then S.pendingCareer, S.resumeError, S.loadBlocked = {}, recovery, recovery end
  if S.loadError then problem('E', S.loadError) end
end

-- The phone page on a car's dash screen (vehicles/common/cargo_earth_phone) asks the same questions as the floating phone
-- app, but a car screen page can only send Lua one way. dashCall runs the question (only the phone app's own calls into
-- cargoEarth_core) and sends the answer back through the car's cargoEarthPhone controller.
function M.dashAllowed(cmd)
  if type(cmd) ~= 'string' or #cmd > 4000 then return false end
  return cmd:find('^cargoEarth_core and cargoEarth_core%.[%w_]+%(') ~= nil
    or cmd:find('^%(function%(%) if not cargoEarth_core then return nil end; local ok, value = pcall%(cargoEarth_core%.[%w_]+') ~= nil
end

-- The Menu window. Either phone (floating or on the dash) asks openMenu; the window opens in the "Cargo Earth: Menu" UI
-- app when it is in the UI, else in the floating phone. Both say they are there every few seconds (menuHost). With
-- neither, openMenu answers false and the asking phone opens the section on its own screen.
-- 'toggle': the Menu button, closing an open window or opening its last section
local MENU_PANELS = { garage = true, home = true, companies = true, career = true, settings = true, toggle = true }
local menuHosts = {}
M.now = function() return os.time() end
function M.menuHost(kind)
  menuHosts[kind == 'menu' and 'menu' or 'phone'] = M.now()
  return true
end
function M.openMenu(panel, view)
  if not MENU_PANELS[panel] or not (guihooks and guihooks.trigger) then return false end
  local now = M.now()
  local function alive(kind) return menuHosts[kind] ~= nil and now - menuHosts[kind] <= 6 end
  local to = alive('menu') and 'menu' or (alive('phone') and 'phone' or nil)
  if not to then return false end
  guihooks.trigger('CargoEarthOpenMenu', { panel = panel, view = type(view) == 'string' and view or nil, to = to })
  return true
end

-- a car's phone holder has started its screen
function M.dashPhonePart(vehId)
  log('I', 'cargoEarth', 'dash phone holder running in car ' .. tostring(vehId))
  dash.partCar(tonumber(vehId))
end

function M.dashCall(vehId, id, cmd)
  local veh = getObjectByID and getObjectByID(tonumber(vehId) or -1)
  if not veh or not M.dashAllowed(cmd) then return end
  local fn = (loadstring or load)('return ' .. cmd)
  local ok, value = false, nil
  if fn then ok, value = pcall(fn) end
  local json = jsonEncode(ok and value or nil) or 'null'
  veh:queueLuaCommand(string.format(
    'local c = controller.getControllerSafe("cargoEarthPhone") if c and c.reply then c.reply(%d, %q) end',
    tonumber(id) or 0, json))
end

-- Phone on the dashboard, in any car (cargoEarth/dash.lua). While the switch is on, the player's car gets the phone:
-- the car is measured once per model (driver camera, dash nodes), and respawned with the phone in its parts tree.
-- A new car (spawned or switched to) gets it a moment later, the same way. Traffic never does.
local dashClock, dashCheckAt, dashTried = 0, nil, {}
local dashPending -- a change from Settings the car was too busy for: { rebuild } (done once the car is free)
M.DASH_CHECK_S, M.DASH_RETRY_S = 1.5, 20

local function dashMeasure(v)
  local vdata = type(v.data) == 'table' and v.data.vdata or nil
  local eye, camNode = dash.eyeOf(vdata)
  local spot, why = dash.findSpot(dash.nodesOf(vdata, camNode), eye)
  if spot then
    dash.setSpot(v.model, spot)
    log('I', 'cargoEarth', string.format('dash phone: %s measured, phone at %.3f %.3f %.3f on group %s', v.model,
      spot.centre.x, spot.centre.y, spot.centre.z, spot.group))
  else
    log('W', 'cargoEarth', 'dash phone: ' .. tostring(why) .. ' (' .. tostring(v.model) .. ')')
  end
  return spot, why
end

local function dashBusy()
  local G = M.G
  return G.spawning or G.applyingParts or S.parts ~= nil or (G.partsEditorOpen and G.partsEditorOpen()) or false
end

-- Puts the phone into the player's car (on) or takes it out, by respawning the car. opts.measure measures the car
-- again; opts.rebuild respawns even when the phone is already in (it moved). Returns ok, why.
function M.dashFit(on, opts)
  opts = opts or {}
  local G = M.G
  local v = G.vehicle and G.vehicle()
  if not v or not v.model or not v.id then return false, 'Sit in a car first.' end
  if v.model == 'unicycle' then return false, 'On foot there is no dashboard.' end
  local tree = type(v.config) == 'table' and v.config.partsTree or v.tree
  if type(tree) ~= 'table' or type(tree.children) ~= 'table' then return false, 'This car’s parts could not be read.' end
  if on and (opts.measure or not dash.spot(v.model)) then
    local spot, why = dashMeasure(v)
    if not spot then return false, why end
  end
  if not opts.rebuild and not opts.measure and dash.treeHasPhone(tree) == (on and true or false) then return true end
  if dashBusy() then return false, 'The car is busy: the phone follows as soon as it is free.', 'busy' end
  dashTried[v.id] = dashClock
  local ok, err = pcall(G.respawnPlayer, function(config) dash.setTreePhone(config.partsTree, on) end)
  if not ok then
    log('W', 'cargoEarth', 'dash phone: ' .. tostring(err))
    return false, 'BeamNG could not respawn this car.'
  end
  return true
end

-- Settings > Phone on the dashboard. a: on | off | reset | measure, or a nudge: x+ / x- (left / right as the driver
-- sees it), y+ / y- (closer / further), z+ / z- (up / down). Nudges are kept per car model.
local dashDoInner
function M.dashDo(a)
  local ok, why, busy = dashDoInner(a)
  if busy then
    -- kept until the car is free (being changed, or in the parts editor)
    dashPending = { rebuild = dash.isOn() }
    M.dashCheckSoon()
  end
  return ok, why
end

dashDoInner = function(a)
  local G = M.G
  if a == 'on' or a == 'fit' or a == 'off' or a == 'remove' then
    local on = a == 'on' or a == 'fit'
    dash.setOn(on)
    return M.dashFit(on)
  end
  if not dash.isOn() then return false, 'Switch the phone on first.' end
  local v = G.vehicle and G.vehicle()
  if not v or not v.model then return false, 'Sit in a car first.' end
  if a == 'measure' then
    dash.nudge(v.model, 'reset')
    return M.dashFit(true, { measure = true })
  end
  local axis, sign
  if type(a) == 'string' then axis, sign = a:match('^([xyz])([+-])$') end
  if axis then
    if not dash.nudge(v.model, axis, sign == '+' and 1 or -1) then return false, 'The phone can’t go further that way.' end
    return M.dashFit(true, { rebuild = true })
  elseif a == 'reset' then
    if not dash.nudge(v.model, 'reset') then return true end
    return M.dashFit(true, { rebuild = true })
  end
  return false, 'Unknown choice.'
end

-- every frame, even before a career is loaded: a new car gets the phone a moment after it appears
local function dashTick(dt)
  dashClock = dashClock + (dt or 0)
  if not dashCheckAt or dashClock < dashCheckAt then return end
  dashCheckAt = nil
  local v = M.G.vehicle and M.G.vehicle()
  if not v or not v.id or not v.model or v.model == 'unicycle' then return end
  local tree = type(v.config) == 'table' and v.config.partsTree or v.tree
  local on = dash.isOn()
  if dashPending then
    -- a change from Settings: carried out as soon as the car is free, whatever the cooldown
    if dashBusy() then dashCheckAt = dashClock + 2 return end
    local pending = dashPending
    dashPending = nil
    local ok, why = M.dashFit(on, { rebuild = on and pending.rebuild })
    S.dashError = not ok and why or nil
    return
  end
  -- switched off: a car that still has the phone loses it
  if not on and not dash.treeHasPhone(tree) then return end
  if dashBusy() then dashCheckAt = dashClock + 2 return end
  if on and dash.treeHasPhone(tree) and dash.spot(v.model) then return end
  local last = dashTried[v.id]
  if on and last and dashClock - last < M.DASH_RETRY_S then return end
  local ok, why = M.dashFit(on)
  if not ok then dashTried[v.id] = dashClock end
  S.dashError = not ok and why or nil
end
M.dashTick = dashTick
function M.dashCheckSoon() dashCheckAt = dashClock + M.DASH_CHECK_S end

function M.onUpdate(dtReal, dtSim)
  dashTick(dtReal)
  if S.pendingCareer then
    stopForceWatch()
    updateResume(dtReal)
    return
  end
  S.clock = S.clock + (dtReal or 0)
  S.tick = S.tick + (dtReal or 0)
  if helper.commanding() then helper.pump(S.clock) end     -- radio presses: answered within frames, not ticks
  local worldReady = earth.status() == 'ok'
  local activeDt = careerClock.advance(S.career, dtReal, dtSim, worldReady and not S.parts)
  S.workTick = (S.workTick or 0) + activeDt
  local pose = activeDt > 0 and earth.pose() or nil
  -- Hired drivers work while you do: on an order or contract, or driving. Standing idle earns nothing.
  if S.job or S.career.employment or (pose and not pose.camera and (pose.speed or 0) > M.STOP_SPEED) then
    S.driverTick = (S.driverTick or 0) + activeDt
  end
  if worldReady then
    if pose and camerasOn() and marker.drawCameras then marker.drawCameras(pose, cams.near, S.clock) end
    local okC, errC = pcall(cameraTick, pose)
    if not okC and not S.cameraErr then S.cameraErr = tostring(errC) problem('W', 'cameras: ' .. S.cameraErr) end
  end
  local measured
  S.odometerPose, measured = careerClock.distance(S.odometerPose, pose, activeDt)
  S.career.drivenKm = (S.career.drivenKm or 0) + measured
  local g = S.career.garage
  local inPartsEditor = g.started and M.G.partsEditorOpen and M.G.partsEditorOpen()
  if inPartsEditor and not S.parts then
    local target = M.G.partsTarget()
    inPartsEditor = target and M.G.isOwned(target)
  end
  if S.tick >= M.TICK_S then
    local dt = S.workTick or 0
    S.workTick = 0
    S.tick = 0
    local driverDt = S.driverTick or 0
    S.driverTick = 0
    if S.parts and S.parts.blocked and S.clock >= (S.parts.rollbackAt or 0)
      and (previewVehicle() or S.clock >= (S.parts.retryAt or 0)) then
      local ok, why = cancelParts()
      S.garageMsg = why
      if ok then say(why) else S.parts.rollbackAt = S.clock + 2 end
    end
    -- Applied native-editor changes are a preview. Driving away cannot keep unpaid equipment.
    if S.parts and not inPartsEditor and S.clock >= (S.parts.rollbackAt or 0) then
      local p = earth.pose()
      if p and not p.camera and (p.speed or 0) > M.STOP_SPEED then
        local ok, why = cancelParts()
        S.garageMsg = ok and 'Unconfirmed parts discarded. Confirm checkout before driving.' or why
        if ok then say(S.garageMsg) else S.parts.rollbackAt = S.clock + 2 end
      end
    end
    if inPartsEditor and S.parts then
      local quote, why = quoteParts()
      S.parts.editorSummary = quote and (#quote.items > 0 and string.format('Preview total: %d CZK', quote.cost)
        or 'No parts previewed yet.') or why
    end
    local okG, errG = pcall(garageTick, dt)
    if not okG and not S.garageErr then S.garageErr = tostring(errG) problem('W', 'garage: ' .. S.garageErr) end
    local ready = worldReady
    if ready then refreshStorage() else releaseStorage() end
    if ready then
      -- Hired drivers belong to the personal garage, also while the player drives a company van.
      local shift = S.career.employment
      local fg = shift and shift.personalGarage or g
      local income, events = fleet.advance(fg, driverDt, firm.driverFactor(S.career), S.career, M.random)
      for _, e in ipairs(events) do say(e.text, 8) end
      if #events > 0 then saveCareer() end
      if income < 0 then
        local c = S.career
        economy.post(c, income, 'drivers', economy.nextId(c, 'drivers'), 'Driver wages')
        saveCareer()
      elseif income > 0 then
        local c = S.career
        local debtPaid = garage.takeForDebt(fg, income)
        economy.post(c, income - debtPaid, 'drivers', economy.nextId(c, 'drivers'), 'Fleet shift')
        say(string.format('Drivers earned %d CZK%s.', income,
          debtPaid > 0 and string.format(' (%d CZK toward debt)', debtPaid) or ''))
        saveCareer()
      end
    end
    if ready then helperTick(earth.pose()) end
    if ready then countryTick(earth.pose()) end
    -- Returning a saved company vehicle must not depend on the geographic data cache.
    if ready and activeDt > 0 and S.career.employment then M.companyTick(dt) end
    if modeReady() and ready then
      S.inCareerWorld = true
      local pose = earth.pose()
      rememberLocation(pose)
      if S.job and not S.parts and dt > 0 then tick(dt) end
      if S.phone.online and dt > 0 then phoneTick()
      elseif not S.job and not S.offeredAt and not S.career.employment then M.generate() end
    end
    syncStorage()
    if S.saveRetryAt and S.clock >= S.saveRetryAt then saveCareer() end
    if dt > 0 and g.started and not S.parts and not g.preview and not g.pendingUsed
      and (S.career.activeSeconds or 0) >= (S.nextAutosaveActive or 60) then
      local p = earth.pose()
      if p and ((p.speed or 0) <= M.STOP_SPEED or S.career.activeSeconds >= (S.nextAutosaveActive or 60) + 60) then
        saveCareer()
      end
    end
  end
  if S.job and worldReady then
    local d, p = target(), earth.pose()
    updateForceWatch(p)
    local st = stopInfo()
    if d and p then
      marker.draw(p, d, S.phase == 'toPickup' and 'pickup' or 'delivery', S.job.kind == 'food',
        arrivalRadius(S.job), st and st.inZone, S.clock)
    end
    ui.drawStop(st)
  else
    stopForceWatch()
  end
  if S.window then
    local open = ui.draw(M, S, { jobs = jobs, food = food }, earth, trailers)
    if open == false then S.window = false end
  end
  ui.drawPartsExit(inPartsEditor and M.G.leavePartsEditor, S.parts and S.parts.editorSummary, S.parts ~= nil)
end

function M.onBeamNGEarthWorldReady()
  stopForceWatch()
  marker.reset()
  -- the first time: the phone goes into BeamNG.Earth's UI layout, above the speedometer
  local okL, placed = pcall(uiLayout.ensure, uiLayout.gameApi(), uiLayout.gameFlag())
  if okL and placed == 'added' then say('Cargo Earth: the phone was added to the .Earth UI layout (move it with the UI Apps editor).', 8)
  elseif not okL then log('W', 'cargoEarth', 'layout: ' .. tostring(placed)) end
  if S.pendingCareer then return end
  S.inCareerWorld = true
  if not S.job then M.generate() end
  if S.job then gpsToTarget() end
end

function M.onBeamNGEarthTeleported(info)
  S.odometerPose = nil
  stopForceWatch()
  marker.reset()
  local trip = S.resumeTrip
  if trip and validLocation(info) then
    if atLocation(info, trip.location, M.RESUME_ARRIVAL_M) then
      trip.arrived = true
    else
      S.resumeTrip, S.resumeError = nil, 'BeamNG.Earth reached a different location. Try loading the save again.'
    end
  end
  if not S.job then S.offeredAt = nil end
end

function M.onBeforeVehicleReplaced(id)
  dash.dropCar(id)
  if S.storage and S.storage.id == id then releaseStorage() end
  if forceWatch and forceWatch.id == id then stopForceWatch() end
  if not M.G.spawning and M.G.ownsVehicleId and M.G.ownsVehicleId(id) then
    pauseCareer()
    M.G.clearOwnership()
  end
end

function M.onVehicleDestroyed(id) dash.dropCar(id) dashTried[id] = nil end
function M.onVehicleSwitched() M.dashCheckSoon() end

function M.onVehicleSpawned(id)
  M.dashCheckSoon()
  if fuelWatch and fuelWatch.id == id then stopFuelWatch() end
  -- A respawn recreates the vehicle-side storage, even when BeamNG reuses its object ID.
  if S.storage and S.storage.id == id then S.storage = nil end
  if forceWatch and forceWatch.id == id then forceWatch = nil end
  if S.freightLoad and S.freightLoad.id == id then S.freightLoad = nil end
end

function M.onPartsTreeConfigChanged(_, respawn)
  local G = M.G
  if S.pendingCareer or G.applyingParts or G.spawning or not G.partsTarget then return end
  local v = G.partsTarget()
  if not v or not G.isOwned(v) or not S.career.garage.started then return end
  if not S.parts and not startParts(v, true) then return end
  if v.id ~= S.parts.id then return end
  S.partsRevision = S.partsRevision + 1
  S.parts.waiting = respawn ~= false and (v.data or v.slotPartMap) or nil
  S.parts.retryAt = S.clock + 2
end

function M.onClientEndMission()
  dash.forget()
  S.resumeTrip = nil
  releaseStorage()
  clearFreight()
  stopForceWatch()
  if S.inCareerWorld then pauseCareer() end
end

function M.onExtensionUnloaded()
  dash.remove()
  dash.uninstall()
  releaseStorage()
  clearFreight()
  stopForceWatch()
  if not S.pendingCareer and S.career.savedAt then saveCareer() end
  trailers.remove()
end

return M
