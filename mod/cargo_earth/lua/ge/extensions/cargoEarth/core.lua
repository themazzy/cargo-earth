-- cargoEarth_core: real-world delivery jobs on BeamNG.Earth, in two modes:
--   courier  (default): food orders from real restaurants to real house addresses, in any car, a few km each
--   trucking: cargo between real depots (sawmills, breweries, car plants...) with a trailer, tens to hundreds of km
-- Phases: idle (jobs offered) -> toPickup -> toDelivery -> idle. Money is in CZK, shared by both modes.
-- Everything is clicked on the phone (the UI app): orders, the garage and the settings. The debug window opens from
-- the phone's settings (or the console: extensions.cargoEarth_core.toggleWindow()). No key bindings.
local M = {}
M.VERSION = '0.12.2'      -- the mod's version (package.json has the same; the support report shows it)
M.CAMERAS_PAUSED = true  -- temporarily suspended: no downloads, alerts, fines or lost stars
M.dependencies = { 'ui_imgui' }

local jobs = require('cargoEarth/jobs')
local food = require('cargoEarth/food')
local roads = require('cargoEarth/roads')
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
local CONFIG = '/settings/cargoEarth/config.json'

-- per mode: arrival radius (m), seconds standing still there, cancel fee (CZK)
M.RULES = {
  courier = { arriveM = 30, stopS = 5, cancelFee = 50 },
  trucking = { arriveM = 35, stopS = 3, cancelFee = 2000 },
  bus = { arriveM = 30, stopS = 1, cancelFee = 0 },   -- city bus lines (cargoEarth/bus): doors open from the phone
  -- intercity coaches (cargoEarth/coach): a station's point is the middle of its building or yard, not a bus bay
  coach = { arriveM = 60, stopS = 1, cancelFee = 0 },
}
M.COUNTRY_S = 5   -- seconds between border checks
M.TOW_RULES = { arriveM = 30, stopS = 3, cancelFee = 200 }
M.TAXI_RULES = { arriveM = 25, stopS = 3, cancelFee = 100 }   -- taxi rides (cargoEarth/taxi)
M.RULES.taxi = M.TAXI_RULES
M.jobSettings = require('cargoEarth/jobSettings')
M.TOW_RELOAD_FEE = 150  -- putting a car that slid off back on the trailer
M.STOP_SPEED = 1.5     -- m/s that counts as standing still
M.random = function(...) return math.random(...) end   -- (tests replace it)
M.INTACT_TIP = 0.06      -- a customer tips this share of the pay when the order arrives in perfect condition
M.PARCEL_TIP_SHARE = 0.5 -- a parcel route's tip for speed is figured on this share of its pay
M.ROAD_M = 20          -- the car is on the road edge this close (else: a car park, a field; no limit shown)
M.LIMIT_S = 0.5        -- the limit under the car is read this often
M.OVER_KMH = 3         -- the phone's sign turns red this far over the limit
-- well over (the map's speedometer turns red, amber before): 10 km/h or 10 % of the limit, whichever is more
M.WELL_OVER_KMH, M.WELL_OVER_SHARE = 10, 0.1
M.CAMERA_ROAD_M = 600  -- a camera without a mapped limit takes its road's limit from this close
M.LATE_PER_MIN = { courier = 0.05, trucking = 0.02, bus = 0.01 }   -- share of pay lost per minute late (food goes cold
-- faster; a bus line adds up the minutes it was late at each stop)
M.LATE_FLOOR = 0.5     -- never less than this share of the pay
M.TICK_S = 0.5
M.SAVE_RETRY_S = 5      -- try again if the last career checkpoint could not be written
M.RESUME_TIMEOUT_S = 120  -- allow time for BeamNG.Earth to stream the saved area
M.RESUME_NEAR_M = 3       -- skip teleport if already at the saved spot
M.BUS_HANDOVER_S = 3      -- after a bus handover, before the trip back to the depot
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

-- Settings that a new career keeps from free play. Money, ratings, stats, home and firm start again.
M.KEEP_ON_START = { 'mode', 'options', 'camerasOff', 'updateHidden', 'country', 'currency', 'location' }

local S = {
  idx = nil, fidx = nil, packInfo = '', loadError = nil, mode = 'courier',
  phase = 'idle', job = nil, orders = {}, offers = {}, offerStats = nil, offeredAt = nil,
  optsByMode = { courier = {}, trucking = {}, taxi = {}, bus = {} }, opts = nil,
  career = { money = 0, delivered = 0, km = 0, history = {}, garage = nil },
  stopT = 0, tick = 0, dist = nil, log = {}, config = {}, window = false, phoneHidden = false,
  clock = 0,
  slot = nil, saves = nil, saveInfo = {},   -- the running career's save slot (cargoEarth/saves), the list, what it shows
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
local function camerasOn() return not M.CAMERAS_PAUSED and S.career.garage.started and not S.career.camerasOff end

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
      if S.storage ~= storage then return end
      storage.rows, storage.boxes = rows, cargo.boxes(rows)
      -- nothing on board but a container still holds a load (a restored car state brings back the load it was saved
      -- with): it would leave no room for freight, so it is emptied (M.sweepCargo, passenger seats aside)
      if not S.job and #S.orders == 0 and type(rows) == 'table' then
        for _, row in ipairs(rows) do
          if type(row) == 'table' and ((tonumber(row.targetVolume) or 0) > 0.01 or (tonumber(row.currentVolume) or 0) > 0.01) then
            local seats = type(row.cargoTypes) == 'table' and #row.cargoTypes > 0
            for _, t in ipairs(type(row.cargoTypes) == 'table' and row.cargoTypes or {}) do if t ~= 'passenger' then seats = false end end
            if not seats then S.sweepWanted = true break end
          end
        end
      end
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
    -- the kind of vehicle is kept with the car: hired drivers and the headquarters need it while it is parked
    local v = M.G.vehicle and M.G.vehicle()
    local kind = v and haul.carrier(v)
    if kind then g.car.vclass, g.car.bodyStyle = kind, v.bodyStyle end
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

-- With no order on board, any load still in the car's containers is left over (the mod lost track of it: a Lua
-- reload, a reply that never came). It would weigh the car down and keep the box "taken". Read the containers once and
-- empty every one that holds something (passenger seats aside). The stock career is never touched (cargoVehicle).
-- (a module field, not a local: the main chunk of this file is at Lua's 200-local limit)
function M.sweepCargo()
  local function passengerOnly(types)
    if type(types) ~= 'table' or #types == 0 then return false end
    for _, t in ipairs(types) do if t ~= 'passenger' then return false end end
    return true
  end
  if S.job or S.parts or S.pendingCareer or S.clock < (S.sweepAt or 0) then return end
  local G = M.G
  local id
  if G.cargoVehicle then id = G.cargoVehicle(S.career.garage.started) end
  if not id or not G.readCargoBoxes or not G.setFreightLoad then S.sweepWanted = nil return end
  S.sweepAt = S.clock + 5   -- one read at a time; asked again when no answer comes
  local asked = G.readCargoBoxes(id, function(rows)
    if S.job or not S.sweepWanted then return end
    S.sweepWanted = nil
    local empty, n = {}, 0
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
      if type(row.id) == 'number' and (tonumber(row.targetVolume) or 0) > 0.01 and not passengerOnly(row.cargoTypes) then
        empty[row.id], n = { volume = 0, density = 1 }, n + 1
      end
    end
    if n > 0 and G.setFreightLoad(id, empty) then
      problem('I', string.format('emptied %d container%s left loaded with no order on board', n, n > 1 and 's' or ''))
      -- the boxes are read again, now empty and free for the next order
      if S.storage and S.storage.id == id then S.storage = nil end
    end
  end)
  if not asked then S.sweepWanted = nil end
end

-- Free play ("Just drive"): no career was started, so work comes in whatever vehicle the player sits in. During a
-- company shift the free play garage waits in the shift (personalGarage), so it is asked there.
function M.freePlay() return haul.freePlay(S.career) end

local function freightCarrier()
  local g = S.career.garage
  if not (g.started or M.freePlay()) or g.pendingUsed or not garage.inOwnCar(M.G, g) then return end
  local v = M.G.vehicle()
  local tier = haul.carrier(v)
  if tier and g.car then g.car.vclass, g.car.bodyStyle = tier, v.bodyStyle end
  return v, tier
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
  if tier == 'van' or tier == 'rigid' or tier == 'semi' then
    for k, v in pairs(M.jobOptions('freight_' .. tier)) do o[k] = v end
  end
  return o
end

function M.jobOptions(id) return M.jobSettings.resolve(S.optsByMode, id) end
function M.companyRanges()
  return {van = M.jobOptions('company_van'), rigid = M.jobOptions('company_rigid'), semi = M.jobOptions('company_semi')}
end

function M.settingsJobType()
  if M.jobSettings.type(S.settingsJobType) then return S.settingsJobType end
  if S.mode ~= 'trucking' then return S.mode end
  return M.windowJobType()
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
  if job and job.kind == 'taxi' then return M.TAXI_RULES end
  if job and job.kind == 'bus' then return job.bus and job.bus.coach and M.RULES.coach or M.RULES.bus end
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
  if merged then S.idx, S.packDepots = jobs.index(merged), merged.depots
  else
    -- no bundled workplaces (the Czech pack is gone, Jan 2026-11-18): the freight catalogue, and the helper brings the
    -- workplaces anywhere on Earth (jobs.addArea maps them to the catalogue's types)
    local cat = jsonReadFile(DATA_DIR .. 'freight.json')
    if type(cat) == 'table' and type(cat.cargo) == 'table' and type(cat.types) == 'table' then
      S.idx = jobs.index({ depots = {}, cargo = cat.cargo, types = cat.types, trailers = cat.trailers or {} })
      info[#info + 1] = 'workplaces from the helper'
    end
  end
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
  S.autoIdx = fuel.index()   -- parts shops and repair workshops from the helper (parts runs)
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

-- What the first-run screen offers. The career list stays general: it works in every country.
function M.careerChoice()
  if S.starterName == nil then   -- the config list is long: look the starter up once
    local ok, s = pcall(garage.starter, M.G, S.config.starterModel)
    S.starterName = ok and s and ((s.brand and (s.brand .. ' ') or '') .. (s.name or s.key)) or false
  end
  return { starter = S.starterName or nil, startMoney = garage.START_MONEY, busy = S.job ~= nil }
end

local function saveCareer(skipDamage)
  if S.pendingCareer then return end
  local c = S.career
  if earth.status() == 'ok' then rememberLocation(earth.pose()) end
  -- S.skipCapture: the company van is not spawned yet, so the live car is still the personal one.
  if c.garage.car and not c.garage.pendingUsed and not S.parts and not S.skipCapture then
    local ok, err = pcall(garage.remember, M.G, c.garage)
    if not ok then problem('W', 'Could not capture the career car: ' .. tostring(err)) end
  end
  local g = c.garage
  if not skipDamage and g.car and not g.pendingUsed and not g.preview and not S.parts and not S.skipCapture
      and not conditionAt and not g.restoringDamage and garage.inOwnCar(M.G, g)
      and require('cargoEarth/damage').due(M.G, g) then
    require('cargoEarth/damage').capture(M.G, g, function(ok)
      if ok and S.career == c and not S.pendingCareer and not S.pauseSaving then saveCareer(true) end
    end)
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
  local path = M.savePath(c)
  local restoring = g.restoringDamage
  g.restoringDamage = nil
  local ok, saved = pcall(persistence.save, jsonWriteFile, jsonReadFile, path, c,
    FS and FS.removeFile and function(file) FS:removeFile(file) end or nil)
  g.restoringDamage = restoring
  if ok and saved and S.indexDirty then saved = M.writeIndex() end
  if ok and saved then
    if S.slot then S.saveInfo[S.slot] = require('cargoEarth/saves').summary(c) end
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
  persistence.attach(jsonReadFile, c)   -- each car's snapshot from its own file
  S.careerEpoch = (S.careerEpoch or 0) + 1 -- the phone drops distance drafts typed for another career
  M.updateOnLoad = true   -- ask the helper to look for a newer release (Jan: every time a save is loaded)
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
  garage.retireLoaners(c.garage)
  if c.employment and type(c.employment.personalGarage) == 'table' then garage.retireLoaners(c.employment.personalGarage) end
  c.garage.inventory = c.garage.inventory or {}
  if (c.garage.owed or 0) > 0 then c.garage.debt = (c.garage.debt or 0) + c.garage.owed end   -- older saves
  c.garage.owed, c.garage.fixUntil = nil, nil
  if (c.garage.priceV or 1) < garage.PRICE_V then   -- prices now follow delivery pay: a debt from the old prices shrinks too
    if c.garage.started then c.garage.debt = math.floor((c.garage.debt or 0) * garage.PRICE_PER_VALUE / 3 / 5 + 0.5) * 5 end
    c.garage.priceV = garage.PRICE_V
  end
  if M.RULES[c.mode] then S.mode = c.mode end
  if c.employment then S.mode = c.employment.tier == 'bus' and 'bus' or 'trucking' end
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
      if type(j.tow) == 'table' and j.tow.stage == 'hitch' then j.tow.stage = 'shop' end
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
  -- Older saves kept taxi rides in Freight. Resume the same ride in its new category.
  if S.job and S.job.taxi and not c.employment then S.mode, S.opts = 'taxi', S.optsByMode.taxi end
  S.preferredDelivery = S.job and S.phase == 'toDelivery' and S.job.id == c.preferredDelivery and c.preferredDelivery or nil
  -- nothing is on board: a load the game still holds from before (a Lua reload, a lost reply) goes
  if not S.job then S.sweepWanted = true end
  c.savedAt = os.time()
end

local function loadConfig()
  local c = jsonReadFile(CONFIG)
  S.config = type(c) == 'table' and c or {}
  if S.config.spawnTrailer == nil then S.config.spawnTrailer = true end
  if S.config.requireTrailer == nil then S.config.requireTrailer = true end
  if M.RULES[S.config.mode] then S.mode = S.config.mode end
  trailers.configure(S.config)
  if helper.configure(S.config) then
    local ok, saved = pcall(jsonWriteFile, CONFIG, S.config, true)
    if not ok or saved == false then problem('W', 'Could not save the migrated helper port. Using port ' .. helper.PORT .. ' for this session.') end
  end
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
  -- a tow job with a borrowed trailer goes to the workshop for it first
  if S.phase == 'toPickup' and S.job.tow and S.job.tow.stage then return S.job.to end
  return S.phase == 'toPickup' and S.job.from or S.job.to
end

-- The GPS to the current target: the depot, then a parcel route's next undelivered address. Only that one address
-- (Jan, 2026-11-15): BeamNG.Earth puts its destination, and the map's teleport to it, at the last point of a route
-- through several stops, so a whole round on the GPS sent a teleport to the final address and Navigate to the same
-- place. The phone lists the stops still ahead.
local function gpsToTarget()
  local d = target()
  if not d then return end
  local ok, why = earth.gps(d.g[1], d.g[2], d.n)
  if not ok then say('GPS not set: ' .. tostring(why)) end
end

local function spawnCareerCar(g, vehicleId, position)
  if not g.car then return true end
  local note = garage.fallbackCar(M.G, g)   -- the saved car's vehicle mod is gone: another owned car or a Pigeon
  if note then say(note, 12) end
  local car = g.car
  local ok, err = pcall(M.G.spawn, car.model, car.key, garage.savedConfig(car), vehicleId, position)
  if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  garage.updateStarter(g)
  if g.pendingUsed then g.pendingUsed.attempts = nil end
  usedAt = g.pendingUsed and S.clock + 1 or nil
  conditionAt = not g.pendingUsed and S.clock + 3 or nil
  -- A spawn resets physical damage. Keep its outstanding repair cost with the car.
  g.damageBaseline, g.restoringDamage = nil, nil
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

local function pauseCareer(captured)
  if S.pendingCareer or not S.career.savedAt then return false end
  local c, g = S.career, S.career.garage
  if S.pauseSaving or S.replacementSaving then return false end
  if not captured and g.car and M.G.vehicleState and not conditionAt and not g.pendingUsed
      and not g.restoringDamage and not g.preview and not S.parts and garage.inOwnCar(M.G, g) then
    local car = g.car
    S.pauseSaving = c
    local sent = require('cargoEarth/damage').capture(M.G, g, function(ok)
      if S.pauseSaving ~= c then return end
      S.pauseSaving = nil
      if S.career ~= c or S.pendingCareer then return end
      if g.car ~= car then say('The active car changed. Try saving and switching career again.', 8) return end
      if ok then pauseCareer(true)
      else say('Vehicle damage could not be saved. Keep the game open and try pausing again.', 8) end
    end)
    if sent then return false end
    S.pauseSaving = nil
    say('Vehicle damage could not be saved. Keep the game open and try pausing again.', 8)
    return false
  end
  if not saveCareer(true) then
    say('Career could not be saved. Try pausing again in a moment.')
    return false
  end
  S.pendingCareer = S.career
  if S.taxiSeated then M.taxiSeats(0) end
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

-- Settings > Restart career (the installer's "Delete the career save" from inside the game). The player types DELETE to
-- confirm. Everything of the career goes: money, cars, home, firm, reputation, progress and the backups of the save, so
-- nothing can bring it back on the next start. Only the player's settings stay (M.KEEP_ON_START). The phone then shows
-- the first-run choice again (Career or Free play). On the resume screen it drops the saved career instead of loading it.
M.RESTART_WORD = 'DELETE'
function M.restartCareer(word)
  if word ~= M.RESTART_WORD then return false, 'Type ' .. M.RESTART_WORD .. ' to confirm. Nothing was deleted.' end
  local pending = S.pendingCareer
  local from = type(pending) == 'table' and next(pending) ~= nil and pending or S.career
  if not pending then
    -- the live world: what the old career put there goes (as when pausing), but nothing is saved
    clearFreight()
    releaseStorage()
    trailers.remove()
    if earth.status() == 'ok' then earth.gpsClear() end
    marker.reset()
  end
  -- this career's save and every copy of it; one that cannot be removed is overwritten with an empty career below
  local left, stored = M.deleteSlotFiles(S.slot), true
  if S.slot then
    local saves = require('cargoEarth/saves')
    saves.remove(M.saveIndex(), S.slot)
    S.saveInfo[S.slot] = nil
    stored = M.writeIndex()
  end
  local fresh = M.freshFree(from)
  -- backupAt 0 with no play time: this first save copies nothing into the backups (it goes to freeplay.json)
  stored = saveCareer() == true and stored
  for _, path in ipairs(left) do
    local ok, written = pcall(jsonWriteFile, path, fresh, false, nil, true)
    if not ok or not written then stored = false end
  end
  if not stored then
    -- the game runs the new career, but the old one may still be on disk and come back on the next start
    problem('E', 'Restart career: the old save could not be removed or replaced in settings/cargoEarth.')
    say('Career restarted, but the old save could not be deleted. Close the game and use the installer\'s Delete the career save.', 12)
    return true, 'The old save could not be deleted. Close the game and use the installer\'s Delete the career save.'
  end
  say('Career deleted. Choose how to play on the phone.')
  return true
end

------------------------------------------------------------------------------------------ career save slots
-- Several careers, each with a name and its own save (cargoEarth/saves). The phone's start screen lists them: load one,
-- start a new one with a name, or just drive (free play).

-- the list in saves.json, read once (an old single save becomes "Career 1" here)
function M.saveIndex()
  if not S.saves then
    local saves = require('cargoEarth/saves')
    local idx, migrated, free = saves.open(jsonReadFile, function(p) return persistence.load(jsonReadFile, p) end,
      function(p) return FS and FS.fileExists and FS:fileExists(p) or false end, os.time())
    S.saves, S.freeSave = idx, free
    if migrated and not M.writeIndex() then problem('W', 'Could not write the list of careers (saves.json).') end
  end
  return S.saves
end

-- Writes saves.json. A failed write is tried again with the next save (S.indexDirty), which counts as failed until then:
-- a career missing from the list would be lost on the next start.
function M.writeIndex()
  local ok = require('cargoEarth/saves').write(jsonWriteFile, M.saveIndex())
  S.indexDirty = not ok or nil
  return ok
end

-- Where the running career is written: its slot, or freeplay.json when no career runs. A career running without a
-- slot (it never had a name) gets one.
function M.savePath(c)
  local saves = require('cargoEarth/saves')
  local idx = M.saveIndex()
  local slot = S.slot and saves.find(idx, S.slot)
  if not slot and saves.isCareer(c) then
    slot = saves.create(idx, nil, os.time(), M.fileThere)
    S.slot = slot.id
    M.writeIndex()
  end
  return slot and slot.path or saves.FREE
end

function M.fileThere(p) return FS and FS.fileExists and FS:fileExists(p) or false end

-- Removes a slot's files; returns the ones that may still be there.
function M.deleteSlotFiles(id)
  local saves = require('cargoEarth/saves')
  local slot = id and saves.find(M.saveIndex(), id)
  local left = {}
  if not slot then return left end
  -- the cars' snapshot files: named in the save and its backups, and any other <save>.carN left beside it
  local files = {}
  for _, suffix in ipairs(saves.SUFFIXES) do
    local okR, c = pcall(jsonReadFile, slot.path .. suffix)
    for _, file in ipairs(okR and persistence.sidecarFiles(c) or {}) do files[#files + 1] = file end
  end
  local dir, name = slot.path:match('^(.*/)([^/]+)$')
  if dir and FS and FS.findFiles then
    local okF, found = pcall(FS.findFiles, FS, dir, name .. '.car*', 0, false, false)
    for _, file in ipairs(okF and type(found) == 'table' and found or {}) do
      local at = type(file) == 'string' and file:find('/' .. name .. '.car', 1, true)
      if at and file:sub(at + #name + 5):match('^%d+$') then files[#files + 1] = file end
    end
  end
  for _, file in ipairs(files) do
    if FS and FS.removeFile then pcall(FS.removeFile, FS, file) end
  end
  for _, suffix in ipairs(saves.SUFFIXES) do
    local path = slot.path .. suffix
    if FS and FS.removeFile and (not FS.fileExists or FS:fileExists(path)) then pcall(FS.removeFile, FS, path) end
    if suffix ~= '.pending' and (not FS or not FS.fileExists or FS:fileExists(path)) then left[#left + 1] = path end
  end
  return left
end

-- No career running: the start screen with the player's settings (from: a career or save to take them from).
function M.freshFree(from)
  -- a free play shift left open (the game or the mod reloaded): its company vehicle goes, the player's own comes back
  local shift = type(from) == 'table' and from.employment
  local held = type(shift) == 'table' and type(shift.personalGarage) == 'table' and shift.personalGarage.car
  if type(held) == 'table' and held.freePlay and type(held.model) == 'string' then
    local lent = type(from.garage) == 'table' and type(from.garage.car) == 'table' and from.garage.car.model
    S.freeRestore = { car = held, lent = lent }
  end
  local fresh = { money = 0, delivered = 0, km = 0, history = {}, garage = garage.new(), backupAt = 0 }
  for _, k in ipairs(M.KEEP_ON_START) do fresh[k] = type(from) == 'table' and from[k] or nil end
  S.slot = nil
  S.pendingCareer, S.resumeError, S.resumeTrip, S.loadBlocked, S.saveError = nil, nil, nil, nil, nil
  S.parts, S.job, S.phase, S.orders, S.preferredDelivery = nil, nil, 'idle', {}, nil
  S.offers, S.offerStats, S.offeredAt = {}, nil, nil
  local ph = S.phone
  ph.online, ph.incoming, ph.lastDone, ph.lastFailure, ph.cancelAskUntil = false, nil, nil, nil, nil
  S.stopT, S.dist, S.roadM, S.etaS, S.inCareerWorld = 0, nil, nil, nil, true
  fuelWatch, fuelPending, gamePump = nil, nil, nil
  loadCareer(fresh)
  return fresh
end

-- A career from the list waits to be loaded (the resume screen): read, but not in the world yet.
function M.pendSave(id)
  local saves = require('cargoEarth/saves')
  local idx = M.saveIndex()
  local slot = saves.find(idx, id)
  if not slot then return false end
  local saved, recovery = persistence.load(jsonReadFile, slot.path)
  if not saved and not recovery then
    recovery = FS and FS.fileExists and FS:fileExists(slot.path)
      and 'This career save and its backups could not be read. Your files have been left untouched.'
      or 'The save of this career was not found in settings/cargoEarth.'
  end
  S.slot, S.resumeTrip, S.resumeError, S.loadBlocked, S.saveError = slot.id, nil, nil, nil, nil
  if type(saved) == 'table' then S.pendingCareer = saved else S.pendingCareer, S.resumeError, S.loadBlocked = {}, recovery, recovery end
  if recovery then S.saveError = recovery end
  S.saveInfo[slot.id] = saved and saves.summary(saved) or { unreadable = true }
  if idx.last ~= slot.id then
    idx.last = slot.id
    M.writeIndex()
  end
  return true
end

-- The careers for the phone's start screens, last played first.
function M.savesList()
  local saves = require('cargoEarth/saves')
  local out = {}
  for _, slot in ipairs(M.saveIndex().slots) do
    local info = S.saveInfo[slot.id]
    if not info then
      local c = persistence.load(jsonReadFile, slot.path)
      info = saves.summary(c)
      S.saveInfo[slot.id] = info
    end
    out[#out + 1] = { id = slot.id, name = slot.name, money = info.money, car = info.car, hours = info.hours,
      delivered = info.delivered, unreadable = info.unreadable, savedAt = info.savedAt or slot.created or 0,
      when = info.savedAt and os.date('%d.%m. %H:%M', info.savedAt) or nil, current = slot.id == S.slot or nil }
  end
  table.sort(out, function(a, b) return a.savedAt > b.savedAt end)
  return out
end

-- The start screens' buttons. loadSave (id), newCareer (name), deleteSave (id), saveName (the running career's name).
function M.savesDo(a, arg)
  local saves = require('cargoEarth/saves')
  local idx = M.saveIndex()
  local pending = S.pendingCareer
  S.saveMsg = nil
  if a == 'loadSave' then
    if not pending and S.career.garage.started then return end   -- Settings: pause first
    if not saves.find(idx, arg) then return end
    if not pending then
      if S.job then S.saveMsg = 'Finish or cancel your order first.' return end
      if S.career.savedAt then saveCareer() end   -- the free play settings
      clearFreight()
      releaseStorage()
      trailers.remove()
      marker.reset()
      if earth.status() == 'ok' then earth.gpsClear() end
    end
    if M.pendSave(arg) and not S.loadBlocked then requestResume() end
  elseif a == 'newCareer' then
    if saves.full(idx) then S.saveMsg = 'You have ' .. saves.MAX .. ' careers. Delete one first.' return end
    if pending then M.freshFree(next(pending) ~= nil and pending or S.career) end
    local ok, msg = M.garageStart(nil, arg)
    if not ok then S.saveMsg = msg end
  elseif a == 'deleteSave' then
    local slot = saves.find(idx, arg)
    if not slot or (slot.id == S.slot and not pending) then return end
    local left = M.deleteSlotFiles(slot.id)
    saves.remove(idx, slot.id)
    S.saveInfo[slot.id] = nil
    if not M.writeIndex() then S.saveMsg = 'The list of careers could not be saved.' end
    for _, path in ipairs(left) do pcall(jsonWriteFile, path, { deleted = true }, false, nil, true) end
    if pending and slot.id == S.slot then M.freshFree(next(pending) ~= nil and pending or S.career) end
    S.saveMsg = S.saveMsg or (slot.name .. ' deleted.')
  end
end

local function modeReady()
  if S.mode == 'courier' or S.mode == 'taxi' then return S.fidx ~= nil end
  if S.mode == 'bus' then return true end    -- lines come from the helper, on the bus board
  return S.idx ~= nil
end

-- Tow offers near the player. The workshop is your headquarters when it is close enough, else one at a fuel station.
-- The road distance between two points (lat, lon) on the game's road graph, for food orders and tow jobs: km, false when longer
-- than maxKm, nil when the graph does not reach both points (a road further than ROAD_SNAP_M from them).
M.ROAD_SNAP_M = 80
-- Road nodes all the searches of one offer list may look at together: the searches run in one frame, so an offer list
-- in a big town (up to 4 searches for each of 8 restaurants) must not stall it. Past it, distances are estimated.
M.ROAD_BUDGET = 60000
local function roadKmFn(p)
  if not (M.G.road and p and p.x) then return nil end
  local function ends(pt)
    local x, y = earth.worldXY(p, pt)
    if not x then return nil end
    local graph, a, b, d = M.G.road(x, y, p.z)
    if not graph or not graph.nodes or d > M.ROAD_SNAP_M then return nil end
    local out = {}
    for _, n in ipairs({ a, b }) do
      local node = graph.nodes[n]
      if node and node.pos then
        out[#out + 1] = { n, math.sqrt((node.pos.x - x) ^ 2 + (node.pos.y - y) ^ 2) }
      end
    end
    return graph, out
  end
  local budget = { left = M.ROAD_BUDGET }
  return function(from, to, maxKm)
    if budget.left <= 0 then return nil end
    local ok, km = pcall(function()
      local graph, a = ends(from)
      if not graph then return nil end
      local graph2, b = ends(to)
      if graph2 ~= graph then return nil end
      return roads.km(graph, a, b, maxKm, budget)
    end)
    if ok then return km end
    return nil
  end
end

-- Parts runs (cargoEarth/parts): suppliers are the helper's parts shops and the depots that make car parts; the
-- workshops are the helper's repair garages, your firm's headquarters, or the workshop at a fuel station.
function M.partsOffers(p, room, range)
  local parts = require('cargoEarth/parts')
  local nearKm = range and range.nearKm or parts.NEAR_KM
  local suppliers = {}
  for _, d in ipairs(S.idx and S.idx.depots or {}) do
    if d.g and jobs.inBox(p.lat, p.lon, d.g, nearKm) then
      for _, id in ipairs((S.idx.types[d.t] or {}).produces or {}) do
        if id == 'car_parts' then suppliers[#suppliers + 1] = d break end
      end
    end
  end
  for _, row in ipairs(S.autoIdx and fuel.within(S.autoIdx, p.lat, p.lon, 'parts', 0, nearKm) or {}) do
    local s = row.station
    suppliers[#suppliers + 1] = { id = 'parts:' .. s.id, n = s.n, town = s.town, g = s.g }
  end
  local hq = S.career.firm and S.career.firm.hq
  local function workshops(lat, lon, minKm, maxKm)
    local out = {}
    for _, row in ipairs(S.autoIdx and fuel.within(S.autoIdx, lat, lon, 'garage', minKm, maxKm) or {}) do
      local s = row.station
      out[#out + 1] = { id = 'garage:' .. s.id, n = s.n, town = s.town, g = s.g, label = 'Workshop' }
    end
    if hq and hq.g then
      local k = jobs.km(lat, lon, hq.g[1], hq.g[2])
      if k >= minKm and k <= maxKm then
        table.insert(out, 1, { id = 'hq', n = hq.n or 'Headquarters', town = hq.town or '', g = { hq.g[1], hq.g[2] }, label = 'Your workshop' })
      end
    end
    if #out == 0 then
      for _, row in ipairs(S.fuelIdx and fuel.within(S.fuelIdx, lat, lon, 'fuel', minKm, maxKm) or {}) do
        local s = row.station
        out[#out + 1] = { id = 'workshop:' .. s.id, n = 'Workshop at ' .. s.n, town = s.town or '', g = { s.g[1], s.g[2] }, label = 'Workshop' }
        if #out >= 8 then break end
      end
    end
    return out
  end
  return parts.offers(suppliers, workshops, p.lat, p.lon, room, M.random, roadKmFn(p), range)
end

-- specs: the vehicle's power and weight (tow.weak warns per job)
local function towOffers(class, p, specs)
  local c = S.career
  local range = M.jobOptions(class == 'heavy' and 'tow_heavy' or 'tow_light')
  -- is this tow trailer kind in the game? (asked once; core's main chunk is at Lua's local limit, so it lives here)
  local function towTrailerExists(k)
    if S.towTrailer == nil then S.towTrailer = {} end
    if S.towTrailer[k] == nil then S.towTrailer[k] = trailers.towModel(k) ~= nil end
    return S.towTrailer[k]
  end
  local kind = tow.CLASSES[class].trailer
  S.towCars = S.towCars or trailers.existing(tow.CARS)
  -- a rig with a tow hitch: small cars go on the small car trailer, unless your own big car trailer is coupled (it
  -- takes them too); with your own small one coupled only small cars are offered
  local opts = nil
  local own = nil
  if class == 'light' then
    own = (trailers.ownTowTrailer('cartrailer') and 'cartrailer') or (trailers.ownTowTrailer('smalltrailer') and 'smalltrailer') or nil
    local small = towTrailerExists('smalltrailer') and own ~= 'cartrailer'
    opts = { small = small, onlySmall = own == 'smalltrailer' and small }
    if not towTrailerExists(kind) and not small then return {} end
  elseif not towTrailerExists(kind) then return {} end
  local hq = c.firm and c.firm.hq
  local function workshop(lat, lon)
    local minKm, maxKm = range.minKm / jobs.ROAD_FACTOR, range.maxKm / jobs.ROAD_FACTOR
    if hq and hq.g then
      local k = jobs.km(lat, lon, hq.g[1], hq.g[2])
      if k >= minKm and k <= maxKm then
        return { id = 'hq', n = hq.n or 'Headquarters', town = hq.town or '', g = { hq.g[1], hq.g[2] }, label = 'Your workshop' }
      end
    end
    -- a real auto repair shop (from the helper), one of the nearest few; else the workshop at a fuel station
    local shops = S.autoIdx and fuel.within(S.autoIdx, lat, lon, 'garage', minKm, maxKm) or {}
    if #shops > 0 then
      local g = shops[M.random(math.min(#shops, 3))].station
      return { id = 'garage:' .. g.id, n = g.n, town = g.town or '', g = { g.g[1], g.g[2] }, label = 'Repair shop' }
    end
    local list = S.fuelIdx and fuel.within(S.fuelIdx, lat, lon, 'fuel', minKm, maxKm) or {}
    local s = list[1] and list[1].station
    if s then return { id = 'workshop:' .. s.id, n = 'Workshop at ' .. s.n, town = s.town or '', g = { s.g[1], s.g[2] },
      label = 'Workshop' } end
  end
  local addresses = food.addressesNear(S.fidx, p.lat, p.lon, range.nearKm)
  opts = opts or {}
  for k, v in pairs(range) do opts[k] = v end
  -- no car trailer of your own coupled: the job starts by borrowing one at the workshop
  local borrow
  if class == 'light' then borrow = own == nil else borrow = not trailers.ownTowTrailer(kind) end
  if class == 'light' and not towTrailerExists(kind) then   -- only the small trailer in this game: small cars only
    opts.onlySmall = true
  end
  local out = tow.offers(class, p.lat, p.lon, addresses, workshop, S.towCars, M.random, nil, roadKmFn(p), borrow, opts)
  local factor = rating.freightPay(c)
  for _, offer in ipairs(out) do
    if factor ~= 1 then offer.pay, offer.reputationPay = math.floor(offer.pay * factor / 5 + 0.5) * 5, factor end
    if offer.tow and tow.weak(offer.tow.class, specs) then offer.tow.weak = true end
    if offer.tow then kind = tow.CLASSES[offer.tow.class].trailer end
    if firm.ownsTrailer(c, kind) then
      offer.trailerBonus = math.floor(offer.pay * firm.TRAILER_BONUS / 5 + 0.5) * 5
      offer.pay = offer.pay + offer.trailerBonus
    end
  end
  return out
end

function M.generate()
  -- the firm's trailer is still being hitched: no offers until it is on (M.trailerOffersTick)
  if S.trailerOffersWait then S.offers, S.offerStats = {}, nil S.offeredAt = S.offeredAt or { lat = 0, lon = 0 } return end
  if not modeReady() or S.mode == 'bus' then S.offers, S.offerStats = {}, nil return end   -- bus lines: no ringing
  local p = earth.pose()
  if not p then S.offers, S.offerStats = {}, nil return end
  if S.mode == 'courier' then
    local plan = storagePlan()
    local options = {}
    for k, v in pairs(S.opts) do options[k] = v end
    for k, v in pairs(M.jobOptions('courier')) do options[k] = v end
    S.offers, S.offerStats = food.generate(S.fidx, options, p.lat, p.lon, nil, plan and plan.maxFree or 1, roadKmFn(p))
    S.offerSearch = { nearKm = options.nearKm, minKm = options.minKm, maxKm = options.maxKm }
  elseif S.mode == 'taxi' then
    S.offers, S.offerStats = {}, nil
    local state = M.taxiState()
    if state.eligible then
      local function near(lat, lon, k) return food.addressesNear(S.fidx, lat, lon, k) end
      local function sights(lat, lon, a, b)
        local out = {}
        for _, row in ipairs(S.autoIdx and fuel.within(S.autoIdx, lat, lon, 'sight', a, b) or {}) do
          local d = row.station
          out[#out + 1] = { id = 'sight:' .. d.id, n = d.n, town = d.town, g = d.g }
        end
        return out
      end
      S.offers = require('cargoEarth/taxi').offers(near, sights, p.lat, p.lon, M.random, roadKmFn(p), M.jobOptions('taxi'), state.seats)
      -- Keep the existing taxi fare supplements when moving rides out of Freight.
      local factor = rating.freightPay(S.career)
      for _, offer in ipairs(S.offers) do
        offer.fuelAllowance = math.floor(offer.km * haul.FUEL_ALLOWANCE.car / 5 + 0.5) * 5
        offer.pay = offer.pay + offer.fuelAllowance
        local carRate = require('cargoEarth/taxi').carRate(S.career.garage.car and S.career.garage.car.value)
        if carRate > 0 then
          offer.carRate, offer.carBonus = carRate, math.floor(offer.pay * carRate / 5 + 0.5) * 5
          offer.pay = offer.pay + offer.carBonus
        end
        if factor ~= 1 then offer.pay, offer.reputationPay = math.floor(offer.pay * factor / 5 + 0.5) * 5, factor end
      end
    end
  else
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    local rows = store and store.rows
    S.offers, S.offerStats = {}, nil
    if tier and haul.allowed(S.career, tier) and (tier == 'semi' or tier == 'car' or rows) then
      -- an ordinary car or an SUV takes no company freight board: its own small work comes below
      local offers, stats = {}, nil
      if not haul.SMALL[tier] then
        local o = haul.options(tier, freightOptions(tier), rows)
        offers, stats = jobs.generate(S.idx, o, p.lat, p.lon)
        S.offerSearch = { nearKm = o.nearKm, minKm = o.minKm, maxKm = o.maxKm }
      end
      -- Freight customers pay a carrier by its reputation.
      local factor = rating.freightPay(S.career)
      local ownTruck = S.career.garage.car and not S.career.garage.car.loaner
      -- tanker runs to real fuel stations
      if tier == 'semi' and S.fuelIdx and S.opts.adr ~= false then
        local within = function(lat, lon, a, b) return fuel.within(S.fuelIdx, lat, lon, 'fuel', a, b) end
        local range = M.jobOptions('fuel')
        for _, offer in ipairs(resupply.offers(S.idx, p.lat, p.lon, within, M.random, nil, range.nearKm, range)) do
          table.insert(offers, 1, offer)
        end
      end
      -- parts runs in an SUV or a pickup: from a parts supplier to a repair workshop
      if tier == 'suv' and rows then
        local parts = M.partsOffers(p, haul.capacity(rows, 'parcel'), M.jobOptions('parts'))
        for _, offer in ipairs(parts) do offers[#offers + 1] = offer end
        stats = { parts = true, pairs = #parts }   -- an SUV's search is the parts runs (cargoEarth/offerwhy)
      end
      -- parcel routes from the nearest depots to real addresses: vans only (box trucks do business shipping)
      if parcel.TIERS[tier] and rows and S.fidx then
        local range = M.jobOptions('parcels')
        local room = haul.capacity(rows, 'parcel')
        local near = {}
        for _, d in ipairs(S.idx.depots or {}) do
          if d.g and jobs.inBox(p.lat, p.lon, d.g, range.nearKm) then
            local k = jobs.km(p.lat, p.lon, d.g[1], d.g[2])
            if k <= range.nearKm then near[#near + 1] = { d = d, k = k } end
          end
        end
        table.sort(near, function(a, b) return a.k < b.k end)
        for i = 1, math.min(2, #near) do
          local d = near[i].d
          local route = parcel.route(d, food.addressesNear(S.fidx, d.g[1], d.g[2], parcel.TIERS[tier].radiusKm), tier, room, nil, i)
          -- the shortest / longest job settings of this vehicle hold for the whole round
          if route and ((range.minKm and route.km < range.minKm) or (range.maxKm and route.km > range.maxKm)) then route = nil end
          if route then
            route.pickupKm = near[i].k
            offers[#offers + 1] = route
          end
        end
      end
      for _, offer in ipairs(offers) do
        if offer.route or offer.partsRun or offer.taxi or haul.prepare(offer, tier, rows, S.idx) then
          if offer.resupply then resupply.bonus(offer)
          elseif not offer.route and not offer.taxi then special.roll(offer, tier, M.random) end
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
      for _, offer in ipairs(towOffers(class, p, v.specs)) do S.offers[#S.offers + 1] = offer end
    end
  end
  S.offeredAt = { lat = p.lat, lon = p.lon }
  if #S.offers == 0 then S.offerWhyAt = nil M.offerWhy() end   -- a fresh search: say why at once (and log it)
end

function M.setMode(m)
  if S.job or S.career.employment or not M.RULES[m] or m == S.mode then return end
  S.mode = m
  S.settingsJobType = nil
  S.busDepot = nil
  S.opts = S.optsByMode[m]
  if m == 'bus' then S.phone.online = false end   -- bus lines are started from the board, nothing rings
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
  local busRide = S.job ~= nil and S.job.bus ~= nil
  local riders = busRide and (S.job.bus.onBoard or 0) > 0   -- bus passengers feel the ride too
  local id = p and not p.camera and G.playerId and (carriedOrders() > 0 or riders) and G.playerId()
  if id and g.started and not G.ownsVehicleId(id) then id = nil end
  if forceWatch and forceWatch.bus == busRide and id == forceWatch.id and p.anchorLat == forceWatch.lat and p.anchorLon == forceWatch.lon then return end
  stopForceWatch()
  if id then
    forceToken = forceToken + 1
    if G.watchForces(id, forceToken, busRide) then
      forceWatch = { id = id, token = forceToken, lat = p.anchorLat, lon = p.anchorLon, bus = busRide }
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
  if not j.companyShift and S.career.garage.car and S.career.garage.car.loaner then
    say('Company vehicles are for contract work only. Use your own car for your own jobs.', 5) return
  end
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
  elseif j.taxi then
    if S.mode ~= 'taxi' then return end
    local state = M.taxiState(true)
    if not state.eligible then say(state.hint, 5) return end
    if state.seats < j.taxi.people then say(string.format('This ride needs %d passenger seats; your vehicle has %d.', j.taxi.people, state.seats), 5) return end
  elseif j.tow then
    local v, tier = freightCarrier()
    if not v or not tow.fits(tow.class(tier, tow.hasHitch(v)), j.tow.class) then
      say(j.tow.class == 'heavy' and 'Tow jobs with two cars need a tractor for the flatbed trailer.'
        or 'This tow job needs a vehicle with a tow hitch for the car trailer.', 5)
      return
    end
    -- your own trailer goes along; without it (uncoupled since the offer) the trailer is borrowed at the workshop
    local kind = tow.CLASSES[j.tow.class].trailer
    if not j.tow.borrow and not trailers.adopt(kind) then
      -- the offer was made with your trailer coupled: now the empty-trailer legs are paid and timed too
      local p = earth.pose()
      local before = j.pay
      tow.borrow(j, p and p.lat or j.from.g[1], p and p.lon or j.from.g[2])
      j.pay = before + math.floor((j.pay - before) * (j.reputationPay or 1) / 5 + 0.5) * 5
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
  if not j.companyShift then S.career.pickups = require('cargoEarth/variety').note(S.career.pickups, j) end
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
  if j.bus then
    -- the first stop: the doors open from the phone (M.busDoors); the bus leaves once they close
    if not j.bus.ready then
      S.stopT = -10
      if j.bus.told ~= j.bus.at then j.bus.told = j.bus.at say('Open the doors on the phone.', 4) end
      return
    end
    j.bus.ready = nil
    local _, o = orderOf(j)
    if o then o.phase = 'toDelivery' end
    nextStop()
    saveCareer()
    phoneSound('pickup')
    return
  end
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
  elseif j.taxi then
    local state = M.taxiState(true)
    if not state.eligible or state.seats < j.taxi.people then
      S.stopT = 0
      say(state.eligible and 'There are not enough passenger seats for this group.' or state.hint, 5)
      return
    end
    -- Boarding must succeed before the ride starts. A failed seat API call can be retried at this stop.
    if M.taxiSeats(j.taxi.people, j.id) ~= j.taxi.people then
      M.taxiSeats(0)
      j.taxi.boardingError, S.stopT = true, 0
      say('Passengers could not be seated. Stay at the pickup to retry.', 5)
      return
    end
    j.taxi.boardingError = nil
    -- the passengers get in: they sit in the car and feel how it is driven from here
    local _, o = orderOf(j)
    if o then o.phase = 'toDelivery' end
    local rush = require('cargoEarth/taxi').info(j).mode == 'rush'
    say(string.format(rush and '%s in, in a hurry. Get to %s fast: arriving early pays a big tip.'
      or '%s in. Drive to %s smoothly: a rough ride costs a lot of pay.',
      j.taxi.people == 1 and 'Your passenger is' or (j.taxi.people .. ' passengers are'), j.to.n), 6)
  elseif j.tow and j.tow.stage then
    -- at the workshop: the borrowed trailer stands behind you until Hitch on the phone (M.towHitch)
    S.stopT = -10
    if j.tow.stage == 'hitch' and trailers.id() then return end
    local ok, why = trailers.spawnBorrowed(tow.CLASSES[j.tow.class].trailer)
    if not ok then say('No room for the trailer here (' .. tostring(why) .. '). Stop where it is free behind you.', 6) return end
    j.tow.stage, j.trailerSpawned = 'hitch', true
    say(string.format('Putting the %s on your hitch…', tow.CLASSES[j.tow.class].name:lower()), 5)
    saveCareer()
    return
  elseif j.tow then
    -- the car waits by the road with the trailer behind you; Load it on the phone puts it on (M.towLoad)
    S.stopT = -10
    if j.tow.waiting and trailers.id() and trailers.towedAlive() >= #j.tow.cars then return end
    local ok, why = trailers.spawnRoadside(tow.CLASSES[j.tow.class].trailer, j.tow.cars, tow.wreckPlan(j))
    if not ok then
      say('The broken-down car could not be placed: ' .. tostring(why), 6)
      return
    end
    j.trailerSpawned, j.tow.waiting, j.tow.onBoard = true, true, 0
    say(string.format('%s by the road, the trailer behind you. Park the trailer next to %s and press Load on the phone.',
      #j.tow.cars > 1 and 'The cars wait' or 'The car waits', #j.tow.cars > 1 and 'them' or 'it'), 8)
    saveCareer()
    return
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

-- Tow job, at the pickup: the car(s) and the trailer are out and wait for Load on the phone (no stop countdown then;
-- if they are gone, stopping there again brings them back).
function M.towWaiting()
  local j = S.job
  if j and j.tow and j.tow.stage == 'hitch' and S.phase == 'toPickup' and trailers.id() then return true end
  return j ~= nil and j.tow ~= nil and j.tow.waiting == true and S.phase == 'toPickup'
    and trailers.id() ~= nil and trailers.towedAlive() >= #j.tow.cars
end

-- Tow job on its way to the car (Jan): the broken-down cars are spawned and crumpled out of sight as the job starts,
-- then put by the road once the player is within trailers.PLACE_M of the pickup and the ground there has loaded.
-- When that cannot be done they are spawned by the road at the stop, as before (finishPickup).
M.towStageTick = function()
  local j = S.job
  if j.tow.waiting or earth.status() ~= 'ok' then return end
  if trailers.towedPlaced() then return end
  if not trailers.towedStaged() then trailers.stageTowed(j.tow.cars, tow.wreckPlan(j)) return end
  local p = earth.pose()
  local g = j.from and j.from.g
  if not (p and p.z and g) or jobs.km(p.lat, p.lon, g[1], g[2]) * 1000 > trailers.PLACE_M then return end
  local x, y = earth.worldXY(p, g)
  if x then trailers.placeTowed(x, y, p.z) end
end

-- Tow job, at the workshop: put the borrowed trailer on the hitch and head for the broken-down car.
function M.towHitch()
  local j = S.job
  if not (j and j.tow and j.tow.stage == 'hitch' and S.phase == 'toPickup') then return end
  local p = earth.pose()
  if p and (p.speed or 0) > M.STOP_SPEED then say('Stop before hitching.') return end
  local coupled = trailers.coupled(M.G.playerId and M.G.playerId() or -1)
  if not coupled and trailers.id() and not trailers.withPlayer() then
    say('Back up to the trailer first: it stands at the workshop.', 5)
    return
  end
  if not coupled then
    -- put on the hitch again; it counts once the game reports it coupled (tick)
    if not trailers.hitch() then
      j.tow.stage = 'shop'
      say('The trailer is gone. Stop at the workshop again to get it.', 5)
    else
      say('Hitching the trailer…', 3)
    end
    return
  end
  j.tow.stage = nil
  S.stopT, S.dist, S.roadM, S.etaS = 0, nil, nil, nil
  gpsToTarget()
  say(string.format('Trailer hitched. Drive to the broken-down car at %s.', j.from.n), 6)
  saveCareer()
  phoneSound('pickup')
end

-- Tow job, at the pickup: put the waiting car(s) on the trailer parked next to them.
function M.towLoad()
  local j = S.job
  if not (j and j.tow and j.tow.waiting and S.phase == 'toPickup') then return end
  local p = earth.pose()
  if p and (p.speed or 0) > M.STOP_SPEED then say('Stop before loading.') return end
  local near, why = trailers.towedNear(trailers.LOAD_M or 30)
  if not near then say(why, 5) return end
  local ok, err = trailers.loadTowed(j.tow.cars, tow.wreckPlan(j))
  if not ok then say('Could not load: ' .. tostring(err), 5) return end
  j.tow.waiting, j.tow.spawnedAt, j.tow.damage0, j.tow.onBoard = nil, S.clock, nil, #j.tow.cars
  local _, o = orderOf(j)
  if o then o.phase = 'toDelivery' end
  say(string.format('Loaded. Drive gently to %s: %s not strapped down.', j.to.n,
    #j.tow.cars > 1 and 'they are' or 'it is'), 8)
  nextStop()
  saveCareer()
  syncStorage()
  phoneSound('pickup')
end

-- An order leaves the list; the next stop takes over, or the courier is free again.
local function dropOrder(j)
  if j.haul then clearFreight() end
  if j.taxi then M.taxiSeats(0) end
  -- a tow job's trailer and the car(s) on it or waiting by the road go with it
  if j.tow then trailers.removeTow() end
  local i = orderOf(j)
  if i then table.remove(S.orders, i) end
  if #S.orders == 0 then
    trailers.remove()
    earth.gpsClear()
    S.job, S.phase, S.stopT, S.preferredDelivery = nil, 'idle', 0, nil
    S.sweepWanted, S.sweepAt = true, S.clock + 1   -- after the emptying above has reached the car
    return true
  end
  S.job = nil
  nextStop()
  return false
end

local function finishDelivery(force)
  local j = S.job
  if cargo.supports(j) and cargo.condition(j) == 0 and not M.speedOnly(j) then M.spoil(nil, {[j] = true}) return end
  if j.bus then
    if not j.bus.ready then
      S.stopT = -10
      if j.bus.told ~= j.bus.at then j.bus.told = j.bus.at say('Open the doors on the phone.', 4) end
      return
    end
    j.bus.ready = nil
    if not j.bus.finished then
      S.stopT, S.dist, S.roadM, S.etaS = 0, nil, nil, nil
      gpsToTarget(true)
      saveCareer()
      phoneSound('pickup')
      return
    end
    -- the end of the line: the quote and the fares
    j.pay = require('cargoEarth/bus').linePay(j)
  elseif j.haul then
    local cmd = S.freightLoad and S.freightLoad.command or ''
    if cmd ~= 'unload' and cmd ~= 'unloadDone' and not cmd:match('^stop') then
      if not workFreight(j, false) then return end
    end
    if not workFreight(j, true) then return end
    -- a parcel route goes on to its next address; it is paid and rated at the last one
    if j.route and not parcel.last(j) then
      local served = parcel.advance(j)
      local droppedKg = math.floor(served.slots * j.haul.density + 0.5)
      S.phone.dropped = { kg = droppedKg, left = math.floor(cargo.onBoard(S.orders) + 0.5),
        untilT = S.clock + M.PHONE.doneShowS }
      say(string.format('%d parcels (%d kg) left at %s. Next stop %d of %d: %s.', served.slots, droppedKg, served.n,
        j.route.at, #j.route.stops, j.to.n), 6)
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
  elseif not force and j.kind ~= 'food' and not j.taxi and S.config.requireTrailer and S.config.spawnTrailer and not trailers.withPlayer() then
    say('Bring the trailer: it is not with your truck.', 3)
    S.stopT = -10   -- don't repeat the message every tick
    return
  end
  local minutes = M.elapsed(j) / 60          -- the time it really took (history and records)
  local late = math.max(0, minutes - j.minutes)
  local judged = minutes                     -- the time the rating goes by
  if j.bus then
    -- a bus keeps to its timetable stop by stop: the minutes late at each stop count, not the whole run's
    late = require('cargoEarth/bus').lateMinutes(j)
    judged = j.minutes + late
  end
  local perMin = M.LATE_PER_MIN[j.kind == 'food' and 'courier' or j.bus and 'bus' or 'trucking']
  local pay = math.floor(j.pay * math.max(M.LATE_FLOOR, 1 - late * perMin) + 0.5)
  if j.special == 'chilled' then special.warm(j, late) end
  local condition = cargo.supports(j) and cargo.condition(j) or (j.tow and cargo.condition(j)) or 100
  -- Tips from private customers (meals and parcel routes) go only by what they can see: how soon the order came and
  -- the state it arrived in. How it was driven on the way is not theirs to know.
  local tip, tipWhy = 0, nil
  if j.kind == 'food' or j.route or j.taxi then
    local fast = food.tip(j.kind == 'food' and j.pay or math.floor(j.pay * M.PARCEL_TIP_SHARE), minutes, j.minutes)
    local intact = condition >= 100 and math.floor(j.pay * M.INTACT_TIP / 5 + 0.5) * 5 or 0
    tip = fast + intact
    tipWhy = { fast = fast > 0 or nil, intact = intact > 0 or nil, damaged = condition < 100 and condition or nil }
  end
  -- a meal or a taxi ride still arrives after a rough trip: the pay drops, but not to nothing
  if j.bus then
    condition = require('cargoEarth/bus').comfort(j)   -- the passengers' comfort, as a taxi's
    j.cargoCondition = condition
  end
  local conditionFactor = (j.kind == 'food' or j.taxi or j.bus) and (0.6 + 0.004 * condition) or condition / 100
  pay = math.floor(pay * conditionFactor * (1 - special.penalty(j) / 100) + 0.5)
  tip = math.floor(tip * condition / 100 + 0.5)
  if j.taxi then
    -- the passenger's mode decides: comfort pays for a smooth ride, rush for a fast one (cargoEarth/taxi)
    pay, tip, tipWhy = require('cargoEarth/taxi').settle(j, j.pay, minutes, j.minutes, perMin, M.LATE_FLOOR, condition, food.tip)
  end
  local c = S.career
  local restedExtra
  pay, restedExtra = home.restedPay(c, pay)
  j.restedExtra = restedExtra > 0 and restedExtra or nil
  local toDebt = 0
  if j.companyShift then
    if not employment.delivered(c, j, pay + tip) then return end
  else
    if economy.isSettled(c, j.paymentId) then return end
    toDebt = garage.takeForDebt(c.garage, pay + tip, 'Delivery to ' .. tostring(j.to.n))
    if not economy.post(c, pay + tip - toDebt, 'delivery', j.paymentId, j.cargoName) then return end
  end
  local rankUp = progress.complete(c, j)
  if not j.companyShift then   -- company shifts count when they settle (employment.settle)
    local experience = require('cargoEarth/experience')
    experience.add(c, experience.kind(j))
  end
  local truckUnlock = j.haul and haul.complete(c, j.haul.tier)
  local today = os.date('%Y-%m-%d')
  if type(c.today) ~= 'table' or c.today.date ~= today then c.today = { date = today, earned = 0, count = 0 } end
  if not j.companyShift then c.today.earned = c.today.earned + pay + tip end
  c.today.count = c.today.count + 1
  -- The customer's rating feeds the courier or the freight reputation.
  local track = rating.track(j)
  -- a passenger in a rush rates only the speed
  local felt = j.taxi and require('cargoEarth/taxi').mode(j).speedOnly and 100 or condition
  local stars = rating.add(c, track, rating.stars(judged, j.minutes, felt, j.starPenalty))
  local note = rating.note(track, stars, late > 0, felt < 100, c.delivered)
  local newRecords = records.record(c, j, { pay = pay, tip = tip, minutes = minutes, stars = stars, date = today,
    earnedToday = c.today.earned })
  local droppedKg = cargo.weight(j)
  S.phone.dropped = droppedKg > 0 and { kg = math.floor(droppedKg * 10 + 0.5) / 10,
    left = math.floor((cargo.onBoard(S.orders) - droppedKg) * 10 + 0.5) / 10, untilT = S.clock + M.PHONE.doneShowS } or nil
  S.phone.lastDone = { pay = pay, tip = tip, late = math.floor(late + 0.5), to = j.to.n, untilT = S.clock + M.PHONE.doneShowS,
    toDebt = toDebt, net = pay + tip - toDebt, rankUp = rankUp, truckUnlock = truckUnlock,
    cargoCondition = felt < 100 and condition or nil, held = j.companyShift ~= nil,
    ownerOperator = c.employment and c.employment.ownerOperator, vehicle = employment.vehicleLabel(c.employment),
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

------------------------------------------------------------------------------------------ city bus lines
-- Lines come from the helper (OpenStreetMap); a line is a company shift with one job of kind 'bus' (cargoEarth/bus).
M.BUS_ASK_S, M.BUS_LOADING_S = 30, 4

function M.busNamesNeedRefresh()
  local j = S.job
  if not (j and j.bus) then return false end
  for _, stop in ipairs(j.bus.stops) do
    if stop.n:find('u0[%da-fA-F][%da-fA-F][%da-fA-F]') then return true end
  end
  return false
end

-- Repair names already stored in an active shift using the actual OSM stop at the same coordinates.
-- Do not guess replacements from text that happens to resemble an escape sequence.
function M.busRefreshNames(idx)
  local j = S.job
  if not (j and j.bus) then return end
  for _, line in ipairs(idx.lines or {}) do
    if line.id == j.bus.line then
      local changed = false
      local targets = {}
      for _, stop in ipairs(j.bus.stops) do targets[#targets + 1] = stop end
      targets[#targets + 1], targets[#targets + 2] = j.from, j.to
      for _, target in ipairs(targets) do
        for _, fresh in ipairs(line.stops) do
          if jobs.km(target.g[1], target.g[2], fresh.g[1], fresh.g[2]) < 0.03 then
            if target.n ~= fresh.n then target.n, changed = fresh.n, true end
            break
          end
        end
      end
      if changed then
        j.cargoName = (j.bus.name or 'Bus line') .. ' to ' .. j.bus.stops[#j.bus.stops].n
        saveCareer()
      end
      return
    end
  end
end

function M.busFetch(p)
  if S.mode ~= 'bus' or (S.job and not M.busNamesNeedRefresh()) or not p or S.clock < (S.busAskAt or 0) then return end
  if S.busKind == 'coach' and not S.job then return end   -- the Coaches list asks for stations instead
  S.busAskAt = S.clock + M.BUS_ASK_S
  S.busIdx = S.busIdx or require('cargoEarth/bus').index()
  local retry = S.busRetry and '&retry=1' or ''
  S.busRetry = nil
  helper.ask(string.format('/v1/buslines?lat=%.5f&lon=%.5f', p.lat, p.lon) .. retry, function(data, err)
    local bus = require('cargoEarth/bus')
    if type(data) ~= 'table' then
      -- Only a missing endpoint means an old helper. A timeout is a connection failure.
      S.busIdx.state = err == 'HTTP 404' and 'old' or (helper.status().state == 'off' and 'off' or 'failed')
      S.busIdx.error = 'Could not load bus lines from the helper: ' .. tostring(err or 'invalid response')
      S.busIdx.progress = nil
      return
    end
    bus.set(S.busIdx, data)
    M.busRefreshNames(S.busIdx)
    if data.state == 'loading' then S.busAskAt = S.clock + M.BUS_LOADING_S end
    local here = earth.pose()
    if here then S.busBoard = bus.board(S.busIdx, here.lat, here.lon) end
  end, '/v1/buslines')
end

-- Intercity coaches (cargoEarth/coach): stations near you and in far towns from the helper (/v1/stations), while the
-- Bus page shows Coaches.
function M.coachTick(p)
  if S.mode ~= 'bus' or S.busKind ~= 'coach' or S.job or S.career.employment or not p then return end
  local coach, longhaul = require('cargoEarth/coach'), require('cargoEarth/longhaul')
  if not S.cities then
    local ok, data = pcall(jsonReadFile, DATA_DIR .. 'cities.json')
    S.cities = longhaul.cities(ok and data or nil)
  end
  S.coach = S.coach or {}
  local range = M.jobOptions('coach')
  coach.tick(S.coach, S.clock, p, range, S.cities, helper.ask)
  S.coachBoard, S.coachFrom = coach.board(S.coach, p, range)
end

-- The coach rides for the phone (the Bus page's Coaches list).
function M.coachState(p)
  local coach, bus = require('cargoEarth/coach'), require('cargoEarth/bus')
  local st = coach.status(S.coach)
  local out = { status = st, rides = {}, helper = helper.status().state, range = M.jobOptions('coach'),
    from = S.coachFrom and { n = S.coachFrom.n, rail = S.coachFrom.k == 'rail' or nil } or nil }
  local share = employment.shareFor('bus', S.career)
  local function money(x) return math.floor((x or 0) * share / 5 + 0.5) * 5 end
  local byRide = {}
  for _, o in ipairs(S.coachBoard or {}) do
    local km = p and jobs.km(p.lat, p.lon, o.yard.g[1], o.yard.g[2])
    local row = byRide[o.bus.ride]
    if not row then
      row = { name = o.bus.name, from = o.bus.from, to = o.bus.to, town = o.bus.town, rail = o.bus.station == 'rail' or nil,
        depot = o.yard.n, depotM = km and math.floor(km * 1000 + 0.5), seats = bus.COACH.SEATS }
      byRide[o.bus.ride] = row
      out.rides[#out.rides + 1] = row
    end
    -- one way and the return trip, each with its own button
    local leg = { id = o.id, km = math.floor(o.km + 0.5), minutes = o.minutes, pay = money(o.gross), fares = money(o.fares) }
    if o.bus.back then row.back = leg else
      row.id, row.km, row.minutes, row.pay, row.fares = leg.id, leg.km, leg.minutes, leg.pay, leg.fares
    end
  end
  return out
end

-- An offer of the bus board or the coach board, by id.
function M.busOffer(id)
  for _, list in ipairs({ S.busBoard or {}, S.coachBoard or {} }) do
    for _, offer in ipairs(list) do if offer.id == id then return offer end end
  end
end

-- Metres from the car to a bus or coach stop: its own point, or its ring where that was moved to the road (a coach
-- station's point is the middle of the station, up to the roadside search away from the ring).
function M.busStopMeters(p, stop)
  local meters = jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) * 1000
  local side = marker.roadsideDistance and marker.roadsideDistance(p, S.job and S.job.to)
  if side and S.job.to and S.job.to.g and S.job.to.g[1] == stop.g[1] and S.job.to.g[2] == stop.g[2] then
    meters = math.min(meters, side)
  end
  return meters
end

-- The phone and upper overlay share this stop state and the boarding clock.
function M.busStopInfo()
  local j, p = S.job, earth.pose()
  if not (j and j.bus and validLocation(p)) then return nil end
  local stop = j.bus.stops[j.bus.at]
  local meters = M.busStopMeters(p, stop)
  local inside = meters <= rules(j).arriveM
  local parked = not p.camera and (p.speed or 0) <= M.STOP_SPEED and garage.inOwnCar(M.G, S.career.garage)
  local d = S.busDwell
  local duration = d and d.duration or 0
  local left = d and d.remaining or 0
  return {bus = true, inZone = inside, canDoors = inside and parked and not d or false, stopping = d ~= nil,
    distM = math.floor(meters + 0.5), stopS = duration, leftS = math.ceil(left),
    frac = duration > 0 and math.max(0, math.min(1, 1 - left / duration)) or 0,
    title = d and 'Passengers getting off and on' or (parked and 'Open doors: O or phone' or 'Stop the bus at the marker'),
    detail = d and string.format('%d off, %d on', d.off, d.on) or stop.n }
end

-- The bus page: the lines near you, or the line you drive.
function M.busState()
  local bus, c, p = require('cargoEarth/bus'), S.career, earth.pose()
  local shift = c.employment
  local out = { state = S.busIdx and S.busIdx.state or 'loading', helper = helper.status().state, collectFee = bus.COLLECT_FEE,
    kind = S.busKind == 'coach' and 'coach' or 'lines' }
  out.progress, out.error = S.busIdx and S.busIdx.progress, S.busIdx and S.busIdx.error
  out.found = S.busIdx and #(S.busIdx.lines or {}) or 0
  out.nearestKm = S.busIdx and S.busIdx.nearestKm
  out.radiusKm = bus.NEAR_KM
  if S.busDepot and not shift then
    local d = S.busDepot
    out.selected = {id = d.offer.id, name = d.offer.jobs[1].cargoName, depot = d.offer.yard.n, coach = d.offer.coach,
      leftS = math.max(0, math.ceil(bus.PARK_S - (d.parked or 0))), error = d.error}
  end
  if shift and shift.tier == 'bus' then
    out.shift = { name = shift.companyName, depot = shift.yard.n, phase = shift.phase, error = S.companyError, coach = shift.coach,
      atDepot = employment.atYard(c, p), handover = shift.handover }
  end
  if S.job and S.job.bus then
    out.line = bus.state(S.job, S.busDwell, M.elapsed(S.job))
    local stop = M.busStopInfo()
    out.canDoors, out.stop = stop and stop.canDoors, stop
    return out
  end
  if out.kind == 'coach' and not shift then out.coach = M.coachState(p) end
  out.lines = {}
  for _, o in ipairs(not shift and out.kind == 'lines' and S.busBoard or {}) do
    local km = p and jobs.km(p.lat, p.lon, o.yard.g[1], o.yard.g[2])
    out.lines[#out.lines + 1] = { id = o.id, ref = o.bus.ref, name = o.bus.name, from = o.bus.from, to = o.bus.to,
      singleDirection = o.bus.singleDirection, limited = o.bus.limited, stops = o.bus.stops, km = math.floor(o.km * 10 + 0.5) / 10, pay = math.floor(o.gross * employment.shareFor('bus', S.career) / 5 + 0.5) * 5,
      fares = math.floor((o.fares or 0) * employment.shareFor('bus', S.career) / 5 + 0.5) * 5, minutes = o.minutes, depot = o.yard.n,
      depotM = km and math.floor(km * 1000 + 0.5), atDepot = km and km * 1000 <= bus.depotRadius(o) and not p.camera
        and (p.speed or 0) <= M.STOP_SPEED or nil, operator = o.name, colour = o.bus.colour, textColour = o.bus.textColour }
  end
  out.message = S.contractMsg and S.clock - S.contractMsg.at < 8 and S.contractMsg.text or nil
  return out
end

-- At a stop: the doors open, people get off and on, and the doors close again after a few seconds (stay stopped).
function M.busDoors(fromVehicle)
  local j = S.job
  if not (j and j.bus) or S.busDwell or earth.status() ~= 'ok' then return end
  local vehicle = M.G.playerId()
  local stop = M.busStopInfo()
  if not vehicle or not stop or not stop.canDoors then
    -- the game's own door key: boarding starts by itself once the bus stands at the stop (M.busDoorWatch)
    if not (fromVehicle and stop and stop.inZone) then say('Park your bus at the current stop first.') end
    return
  end
  local bus = require('cargoEarth/bus')
  local late = bus.arrived(j, M.elapsed(j))
  local off, on, dwell = bus.passengers(j, M.random)
  S.busDwell = { off = off, on = on, remaining = dwell, duration = dwell, at = j.bus.at, job = j, vehicle = vehicle }
  if not fromVehicle and M.G.busDoors then M.G.busDoors(true) end
  M.busSeats(j, j.bus.onBoard - off)   -- those getting off leave their seats first
  say(string.format('Doors open at %s: %d off, %d on.%s', j.bus.stops[j.bus.at].n, off, on,
    late >= 1 and string.format(' %d min behind the timetable.', math.floor(late + 0.5)) or ''), math.ceil(dwell))
end

-- Free passenger seats in the car the player drives, or nil when the game can't tell (a car without its seat system).
-- Asked again at most every 2 s (the phone polls often); fresh asks now (accepting a ride).
function M.taxiFreeSeats(fresh)
  if not M.G.freeSeats then return nil end
  local memo = S.freeSeats
  local id = M.G.playerId and M.G.playerId()
  if not fresh and memo and memo.id == id and (S.clock or 0) < memo.untilT then return memo.n end
  local ok, n = pcall(M.G.freeSeats)
  n = ok and type(n) == 'number' and n == n and n >= 0 and n < math.huge and math.floor(n) or nil
  S.freeSeats = { id = id, n = n, untilT = (S.clock or 0) + 2 }
  return n
end

function M.taxiState(fresh)
  local v, tier = freightCarrier()
  local out = { eligible = false }
  local passenger = tier == 'car' or tier == 'suv' or tier == 'van'
  local own = S.career.garage.car
  if not v or own and own.loaner then
    out.hint = M.freePlay() and 'Taxi work needs a car, SUV or passenger van.' or 'Use your own passenger vehicle for taxi work.'
  elseif not passenger or not haul.configClass(v.model, v.bodyStyle) then
    out.hint = 'Taxi work needs a car, SUV or passenger van with passenger seats.'
  else
    out.seats = M.taxiFreeSeats(fresh)
    if out.seats == nil then
      out.hint = 'Passenger seats could not be verified. Taxi work needs a vehicle with seats recognized by the game.'
    elseif out.seats < 1 then
      out.hint = 'This vehicle has no usable passenger seats. Fit a passenger seat or choose another vehicle.'
    else
      out.eligible = true
      out.hint = string.format('%d passenger %s available. Groups will fit your vehicle.', out.seats, out.seats == 1 and 'seat' or 'seats')
    end
  end
  local h = helper.status()
  if h.state == 'off' then out.search = 'Start the Cargo Earth helper to find passenger pickup addresses and destinations.'
  elseif h.state == 'error' then out.search = 'The helper could not load taxi locations. ' .. (h.msg or 'It will retry automatically.')
  elseif h.supportsAutos == false then out.search = 'Update the Cargo Earth helper to load taxi destinations.'
  elseif h.state == 'loading' or h.state == 'searching' then out.search = 'Loading passenger pickup addresses and destinations nearby.'
  elseif #S.offers == 0 then out.search = 'No rides match the nearby addresses, destinations and distance filters. Try another area or change the Taxi settings.'
  else out.search = 'Passengers nearby can request rides to airports, stations, hotels and sights.' end
  return out
end

M.BUS_WATCH_RENEW_S = 3   -- the bus's own Lua restarts when the car is respawned (dash phone, repairs): watch it again
M.BUS_DOOR_RETRY_S = 0.5  -- doors opened with the game's key before the bus stood at the stop: board once it does

function M.busDoorWatch()
  local j, watch = S.job, S.busWatch
  local id = j and j.bus and M.G.playerId and M.G.playerId()
  if watch and (not id or watch.id ~= id or watch.job ~= j) then
    if M.G.watchBusDoors then M.G.watchBusDoors(watch.id) end
    S.busWatch, watch, S.busDoorsOpen = nil, nil, nil
  end
  if id and not watch and M.G.watchBusDoors and garage.inOwnCar(M.G, S.career.garage) then
    S.busDoorToken = (S.busDoorToken or 0) + 1
    if M.G.watchBusDoors(id, S.busDoorToken) then
      S.busWatch = {id = id, token = S.busDoorToken, job = j, renewAt = (S.clock or 0) + M.BUS_WATCH_RENEW_S}
    end
  elseif watch and (S.clock or 0) >= (watch.renewAt or 0) then
    watch.renewAt = (S.clock or 0) + M.BUS_WATCH_RENEW_S
    M.G.watchBusDoors(watch.id, watch.token)   -- same token: a running watcher keeps going, a fresh one starts
  end
  -- The doors are open (the game's O key or the bus's own lever) but boarding did not start yet: the bus was still
  -- rolling or short of the stop when they opened. Start it as soon as the bus stands at the stop.
  if watch and S.busDoorsOpen and not S.busDwell and (S.clock or 0) >= (S.busDoorRetryAt or 0) then
    S.busDoorRetryAt = (S.clock or 0) + M.BUS_DOOR_RETRY_S
    local stop = earth.status() == 'ok' and M.busStopInfo()
    if stop and stop.canDoors then M.busDoors(true) end
  end
end

-- A respawned or reset bus: forget what its doors did and watch it again with a new token, so boarding waits for
-- the fresh look at the doors (and late reports from before are ignored).
function M.busDoorsForget(id)
  if S.busWatch and S.busWatch.id == id then S.busWatch, S.busDoorsOpen = nil, nil end
end

function M.onCargoEarthBusDoors(id, token, open, initial)
  local w = S.busWatch
  if not w or w.id ~= id or w.token ~= token or w.job ~= S.job or type(open) ~= 'boolean' then return end
  S.busDoorsOpen = open   -- kept even while the world loads: the watcher reports each change only once
  if M.G.playerId() ~= id or not garage.inOwnCar(M.G, S.career.garage) or earth.status() ~= 'ok' then return end
  if initial == true and not open then return end   -- first look at closed doors: a phone press may be on its way
  if open then M.busDoors(true)
  elseif S.busDwell then
    S.busDwell = nil
    M.busSeats(S.job, S.job.bus.onBoard)
    say('Boarding interrupted. Open the doors again to serve this stop.', 5)
  end
end

-- A taxi's passengers, seated in the car (BeamNG's seat occupants, real weight); 0 empties the seats again.
function M.taxiSeats(n, seed)
  local ok, shown = false, nil
  if M.G.carPassengers then ok, shown = pcall(M.G.carPassengers, n, seed or 'taxi', M.freePlay()) end
  S.taxiSeated = (n > 0 or not ok or shown ~= 0) and { n = n, seed = seed, at = S.clock + 5 } or nil
  return ok and shown or nil
end

-- Once a second: the passengers sit while they ride (again after a reset or a loaded save), and leave the seats when
-- the ride is over.
function M.taxiTick()
  local t, j = S.taxiSeated, S.job
  if j and j.taxi and S.phase == 'toDelivery' then
    if not t or t.n ~= j.taxi.people or t.seed ~= j.id or S.clock >= t.at then M.taxiSeats(j.taxi.people, j.id) end
  elseif t and (t.n > 0 or S.clock >= t.at) then
    M.taxiSeats(0)
  end
end

-- The people on board, seated in the bus (BeamNG's seat occupants, real weight; standing ones are not shown).
function M.busSeats(j, n)
  S.busSeatsAt = S.clock + 5
  if M.G.busPassengers then pcall(M.G.busPassengers, math.max(0, n or 0), j and j.bus and j.bus.line or 'bus') end
  -- the bus's own signs: line number, destination and the stops ahead (again now and then: a reset bus forgets them)
  local key = j and j.bus and (j.bus.line .. ':' .. j.bus.at)
  if key and M.G.busSign and (key ~= S.busSignKey or S.clock >= (S.busSignAt or 0)) then
    local ok, sent = pcall(M.G.busSign, require('cargoEarth/bus').sign(j))
    if ok and sent then S.busSignKey, S.busSignAt = key, S.clock + 30 end
  end
end

function M.interruptBoarding()
  local d, j = S.busDwell, S.job
  S.busDwell = nil
  if not d or d.job ~= j then return end
  if d.vehicle == M.G.playerId() then
    if M.G.busDoors then M.G.busDoors(false) S.busDoorsOpen = false end
    M.busSeats(j, j.bus.onBoard)
  end
  say('Boarding interrupted. Park at the stop and open the doors again.', 5)
end

function M.busTick(p, dt)
  local d, j = S.busDwell, S.job
  if not d then return end
  if not (j and j.bus) or d.job ~= j or j.bus.at ~= d.at then S.busDwell = nil return end
  -- The assigned vehicle was verified when the doors opened. Read its id each frame
  -- without fetching a full garage vehicle description or building the phone state.
  if not validLocation(p) or p.camera or (p.speed or 0) > M.STOP_SPEED or d.vehicle ~= M.G.playerId()
    or M.busStopMeters(p, j.bus.stops[d.at]) > rules(j).arriveM then
    M.interruptBoarding()
    return
  end
  d.remaining = math.max(0, d.remaining - dt)
  if d.remaining > 0 then return end
  S.busDwell = nil
  if M.G.busDoors then M.G.busDoors(false) S.busDoorsOpen = false end
  local bus = require('cargoEarth/bus')
  local last = bus.last(j)
  bus.served(j, d.off, d.on, M.elapsed(j))
  M.busSeats(j, j.bus.onBoard)
  j.bus.ready, j.bus.finished = true, last or nil
  if S.phase == 'toPickup' then finishPickup() else finishDelivery(false) end
  if S.job == j and not last then
    say(string.format('Next stop %d of %d: %s. %d on board.', j.bus.at, #j.bus.stops, j.bus.stops[j.bus.at].n, j.bus.onBoard), 5)
  end
end

-- A stop the bus cannot reach: skipped, unpaid, and the line goes on (or ends, at the last stop).
function M.busSkip()
  local j = S.job
  if not (j and j.bus) or j.bus.coach or S.busDwell then return end   -- a coach has only its two stations
  local bus = require('cargoEarth/bus')
  local name, last = j.bus.stops[j.bus.at].n, bus.last(j)
  bus.skip(j, M.elapsed(j))
  M.busSeats(j, j.bus.onBoard)
  j.bus.ready, j.bus.finished = true, last or nil
  if S.phase == 'toPickup' then finishPickup() else finishDelivery(false) end
  if S.job == j and not last then
    say(string.format('Skipped %s. Next stop %d of %d: %s.', name, j.bus.at, #j.bus.stops, j.bus.stops[j.bus.at].n), 5)
  end
end

-- Workplaces from the helper are not checked for truck access (jobs.UNCHECKED_SITES, Jan 2026-11-18: "allow, no fee if
-- blocked"). Close to such a site, the load can be picked up or handed over where the truck stands, for HANDOVER_PAY of
-- the pay (once a job). Fuel stations, parcel addresses, tow, taxi and food stops are reachable places and don't offer it.
M.HANDOVER_M = 600
M.HANDOVER_PAY = 0.85
function M.handoverSite()
  local j = S.job
  if not j or j.kind == 'food' or j.taxi or j.tow or j.bus or j.route then return nil end
  local site = S.phase == 'toPickup' and j.from or S.phase == 'toDelivery' and j.to or nil
  if not site or site.handedOver or not (site.access == 'candidate' or site.far == true) then return nil end
  return site
end
function M.canHandover()
  return M.handoverSite() ~= nil and S.dist ~= nil and S.dist <= M.HANDOVER_M and S.dist > arrivalRadius(S.job)
end

function M.handover()
  if not M.canHandover() then return false end
  local j, p = S.job, earth.pose()
  if not p then return false end
  local key = S.phase == 'toPickup' and 'from' or 'to'
  -- the site moves to the truck; arriving, stopping and (un)loading then go as at any gate
  local site = {}
  for k, v in pairs(j[key]) do site[k] = v end
  site.g, site.r, site.d, site.handedOver = { p.lat, p.lon }, nil, nil, true
  j[key] = site
  if not j.handover then j.pay = math.floor(j.pay * M.HANDOVER_PAY + 0.5) end
  j.handover = true
  S.dist, S.roadM, S.etaS, S.stopT = 0, nil, nil, 0
  saveCareer()
  say(key == 'from' and 'The site staff bring the load out to you. Stop here.' or 'The site staff come out to you. Stop and unload here.', 5)
  return true
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
    S.sweepWanted, S.sweepAt = true, S.clock + 1
  else
    S.job = nil
    nextStop()
  end
  saveCareer()
  syncStorage()
  phoneSound('failed')
  return lost
end

-- A taxi passenger in a rush rates only the speed: a rough ride never ends it (cargoEarth/taxi MODES).
function M.speedOnly(job)
  return job and job.taxi and require('cargoEarth/taxi').mode(job).speedOnly == true or false
end

function M.onCargoEarthShock(id, token, peak)
  local watch = forceWatch
  if not watch or watch.id ~= id or watch.token ~= token or S.pendingCareer then return end
  if type(peak) ~= 'number' or peak ~= peak or peak <= 0 or peak == math.huge then return end
  if M.G.playerId() ~= id or earth.status() ~= 'ok' then return end
  local p = earth.pose()
  if not p or p.camera or p.anchorLat ~= watch.lat or p.anchorLon ~= watch.lon then return end
  stopForceWatch()
  if S.job and S.job.bus then
    local bus = require('cargoEarth/bus')
    if bus.impact(S.job, peak, nil, S.clock) > 0 then
      say(string.format('Your passengers were thrown about (%.1f g). Comfort %d %%.', peak, bus.comfort(S.job)), 5)
      saveCareer()
    end
    return
  end
  local ruined, damaged = {}, 0
  for _, order in ipairs(S.orders) do
    local job = order.job
    if cargo.supports(job) and order.phase == 'toDelivery' and cargo.shock(job, peak) then
      if cargo.condition(job) == 0 and not M.speedOnly(job) then ruined[job] = true else damaged = damaged + 1 end
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
  if S.job and S.job.bus then
    local bus = require('cargoEarth/bus')
    local p, watch = earth.pose(), forceWatch
    if not watch or watch.id ~= id or watch.token ~= token or earth.status() ~= 'ok' or not p or p.camera
        or p.anchorLat ~= watch.lat or p.anchorLon ~= watch.lon or g < bus.HARSH_G or g == math.huge then return end
    local ride = S.job.bus
    if ride.impactAt and S.clock >= ride.impactAt and S.clock - ride.impactAt < bus.IMPACT_GAP_S then return end
    if ride.harshAt and S.clock >= ride.harshAt and S.clock - ride.harshAt < bus.HARSH_GAP_S then return end
    if bus.harsh(S.job) > 0 then
      ride.harshAt = S.clock
      say(string.format('Your passengers felt that. Comfort %d %%.', bus.comfort(S.job)), 4)
    end
    return
  end
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

-- New vehicle damage catches collisions that never cross the accelerometer threshold.
function M.busDamageTick(damage)
  local j, p = S.job, earth.pose()
  local id = M.G.playerId and M.G.playerId()
  if not (j and j.bus and p and not p.camera and id) or earth.status() ~= 'ok'
      or type(damage) ~= 'number' or damage ~= damage or damage == math.huge then
    S.busDamageWatch = nil
    return
  end
  local w = S.busDamageWatch
  if not w or w.job ~= j or w.id ~= id or w.lat ~= p.anchorLat or w.lon ~= p.anchorLon then
    S.busDamageWatch = {job=j, id=id, lat=p.anchorLat, lon=p.anchorLon, damage=damage, at=S.clock}
    return
  end
  local bus = require('cargoEarth/bus')
  if S.clock - w.at < 2 or damage < w.damage or not bus.riding(j) then w.damage = damage return end
  local added = damage - w.damage
  if added < bus.DAMAGE_MIN then return end
  w.damage = damage
  if bus.impact(j, nil, added, S.clock) > 0 then
    say(string.format('Your passengers felt the collision. Comfort %d %%.', bus.comfort(j)), 5)
    saveCareer()
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
  -- the ring moved from the house to the road: it counts too
  local side = marker.roadsideDistance and marker.roadsideDistance(p, d)
  return side and math.min(best, side) or best
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
  -- a borrowed trailer the player coupled with the game's own coupling counts as hitched
  if S.job.tow and S.job.tow.stage == 'hitch' and M.G.playerId and trailers.coupled(M.G.playerId()) then M.towHitch() end
  -- a tow job: the damage the cars came with is not yours; a car that slides off is noticed
  if S.job.tow and S.phase == 'toDelivery' and S.clock >= (S.towCheckAt or 0) then
    local t = S.job.tow
    S.towCheckAt = S.clock + 1
    if not t.damage0 and t.spawnedAt and S.clock >= t.spawnedAt + 3 then t.damage0 = trailers.towedDamage() end
    if trailers.towedCount() > 0 and not trailers.restoringTow() then
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
  -- the stop zone is only a few metres tall: on a bridge over the stop (or a road under it) it doesn't count
  local d = target()
  S.offLevel = (d and marker.offLevel and not S.job.bus and marker.offLevel(p, d)) or nil
  -- one line per stop in beamng.log when the car is at a stop but on another level (for player reports)
  if S.offLevel and S.dist and S.dist <= arrivalRadius(S.job) and S.offLevelLogged ~= d then
    S.offLevelLogged = d
    log('I', 'cargoEarth', string.format('at %s but %.1f m off its level: it does not count here', tostring(d.n),
      marker.heightGap(p, d) or 0))
  end
  -- the road distance of the GPS route, for the phone and window (arrival still uses the straight distance)
  local rt = earth.route()
  if rt and not rt.planning and type(rt.remaining) == 'number' and rt.remaining >= 0 then
    S.roadM, S.etaS = rt.remaining, type(rt.eta) == 'number' and rt.eta or nil
    -- a bus stop's time follows the real road once the GPS knows it (never shorter than the straight line: a road
    -- still left from the stop before is not taken)
    if S.job.bus and S.dist and rt.remaining >= S.dist * 0.9 then
      require('cargoEarth/bus').roadKnown(S.job, rt.remaining / 1000, M.elapsed(S.job))
    end
  else
    S.roadM, S.etaS = nil, nil
  end
  if S.job.bus then
    if not S.busDwell and S.clock >= (S.busSeatsAt or 0) and garage.inOwnCar(M.G, S.career.garage) then
      M.busSeats(S.job, S.job.bus.onBoard)
    end
    S.dist = S.job and distToTarget(p) or nil
    return -- refresh GPS metrics above, but bus stops advance through doors instead of the cargo timer
  end
  if not S.dist or S.dist > arrivalRadius(S.job) or S.offLevel or (p.speed or 0) > M.STOP_SPEED or p.camera
    or ((S.job.kind == 'food' or S.job.taxi) and not garage.inOwnCar(M.G, S.career.garage)) or M.towWaiting() then
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
  if S.job and S.job.bus then return M.busStopInfo() end
  if not S.job or not S.dist or M.towWaiting() then return nil end
  local r = rules(S.job)
  local inZone = S.dist <= arrivalRadius(S.job) and not S.offLevel
  local t = S.stopT > 0 and math.min(r.stopS, S.stopT + S.tick) or 0
  return { inZone = inZone, stopping = inZone and S.stopT > 0, frac = t / r.stopS, leftS = math.max(0, r.stopS - t),
    stopS = r.stopS, pickup = S.phase == 'toPickup' }
end
M.stopInfo = stopInfo

------------------------------------------------------------------------------------------ the phone

local function phoneTick()
  local ph = S.phone
  if not ph.online or S.parts or S.career.employment or S.trailerOffersWait then return end
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
  local anyRoute, anyTow = false, false
  for _, j in ipairs(S.offers) do
    if j.route then anyRoute = true end
    if j.tow then anyTow = true end
  end
  -- spread the pickups (variety): a place that just gave two orders in a row rests for two orders from elsewhere,
  -- unless nothing else is in reach (a village with one restaurant)
  local variety = require('cargoEarth/variety')   -- (core's main chunk is at Lua's 200 locals)
  local function shortlist(spread)
    local fresh, groceryIncluded, routeIncluded, towIncluded = {}, false, false, false
    for _, j in ipairs(S.offers) do
      local seen = spread and variety.resting(S.career.pickups, variety.key(j))
      if not seen then
        for _, id in ipairs(ph.declined) do if id == j.id or (j.from.id and id:find(j.from.id .. '>', 1, true) == 1) then seen = true break end end
      end
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
    return fresh
  end
  local fresh = shortlist(true)
  if #fresh == 0 then fresh = shortlist(false) end
  if #fresh == 0 then ph.nextPingAt = S.clock + M.PHONE.retryS return end
  local j = fresh[math.random(#fresh)]
  if S.job then
    j.batched = true
    local bonus = j.sizeBonus or 0
    j.pay = math.floor((j.pay - bonus) * M.BATCH_PAY / 5 + 0.5) * 5 + bonus
  elseif j.kind == 'food' and rating.premium(S.career) and math.random(rating.PREMIUM_ONE_IN) == 1 then
    rating.makePremium(j)
  end
  require('cargoEarth/experience').apply(S.career, j)   -- experience pay, once per offer
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
    taxi = require('cargoEarth/taxi').info(j),
    trailerBonus = j.trailerBonus,
    farPickup = j.farPickup or 0, batch = false, premium = j.premium, reputationPay = j.reputationPay,
    route = j.route and parcel.state(j),
    fuelAllowance = j.fuelAllowance, carBonus = j.carBonus, carRate = j.carRate, expBonus = j.expBonus, expRate = j.expRate, loadFill = j.loadFill, loadBonus = j.loadBonus,
    trailer = j.trailer and ((j.tow and tow.CLASSES[j.tow.class].name) or (j.haul and j.haul.trailerName) or (S.idx and S.idx.trailers[j.trailer]) or j.trailer) or nil,
    leftS = math.max(0, math.floor(inc.expiresAt - S.clock + 0.5)), totalS = M.PHONE.acceptS }
end

-- Company contracts near the player for the freight page when you have no van or truck of your own: the company
-- hands you its van or truck at the yard when you take one. The board is rebuilt when stale or after 5 km of driving.
M.CONTRACTS_SHOWN = 3
M.CONTRACT_MSG_S = 12   -- seconds a failed contract Route/Start message stays on the freight page
function M.nearContracts(p)
  if not (S.idx and p) or S.career.employment then return {} end
  local at = S.companyBoardPos
  if S.companyBoard == nil or (S.companyBoardDirty and S.clock >= (S.nextBoardAt or 0))
    or (at and jobs.km(at.lat, at.lon, p.lat, p.lon) > 5) then
    S.companyBoard = employment.board(S.idx, p, haul.state(S.career).unlocked, M.companyRanges())
    S.companyBoardDirty, S.nextBoardAt, S.companyBoardPos = nil, S.clock + 2, { lat = p.lat, lon = p.lon }
  end
  -- the nearest contract of every vehicle you may drive, then the nearest of the rest
  local rows, picked, out = {}, {}, {}
  for _, offer in ipairs(S.companyBoard or {}) do
    rows[#rows + 1] = { offer = offer, km = jobs.km(p.lat, p.lon, offer.yard.g[1], offer.yard.g[2]) }
  end
  table.sort(rows, function(a, b) if a.km == b.km then return a.offer.id < b.offer.id end return a.km < b.km end)
  local seen = {}
  for _, r in ipairs(rows) do
    local tier = r.offer.tier or 'van'
    if not seen[tier] and #picked < M.CONTRACTS_SHOWN then seen[tier], r.on = true, true picked[#picked + 1] = r end
  end
  for _, r in ipairs(rows) do
    if not r.on and #picked < M.CONTRACTS_SHOWN then r.on = true picked[#picked + 1] = r end
  end
  table.sort(picked, function(a, b) if a.km == b.km then return a.offer.id < b.offer.id end return a.km < b.km end)
  for _, r in ipairs(picked) do
    local offer, km = r.offer, r.km
    out[#out + 1] = { id = offer.id, name = offer.name, km = math.floor(km * 10 + 0.5) / 10, minutes = offer.minutes,
      wages = math.floor(offer.gross * employment.shareFor(offer.tier or 'van', S.career) + 0.5),
      vehicle = offer.vehicle or haul.loaners.van.name,
      atYard = km * 1000 <= employment.RADIUS and not p.camera and (p.speed or 0) <= M.STOP_SPEED }
  end
  return out
end

-- Why this vehicle gets no freight of its own (shown under "Looking for orders" and logged), nil when it can.
function M.freightHint(v, tier, rows)
  if not v or not tier then
    return 'Take a contract: park at its yard and the company gives you its vehicle.'
  elseif tier == 'car' then
    local style = type(v.bodyStyle) == 'string' and v.bodyStyle ~= '' and (' (body style ' .. v.bodyStyle .. ')') or ''
    return 'This vehicle counts as a car' .. style .. ': no freight board. Tow jobs with a tow hitch, or a company '
      .. 'contract below. Choose Taxi for passenger rides.'
  elseif tier == 'suv' and rows and haul.capacity(rows, 'parcel') < 4 then
    return 'Fit cargo boxes in the bed or boot for parts runs, or take a contract.'
  elseif not haul.allowed(S.career, tier) then
    return 'This truck unlocks after completing the earlier stage.'
  elseif tier ~= 'semi' and not rows then
    return 'Checking fitted cargo containers…'
  elseif tier == 'van' and haul.capacity(rows, 'parcel') < 8 then
    return string.format('Fit parcel boxes with at least 8 free slots (%d free now).', haul.capacity(rows, 'parcel'))
  elseif tier == 'rigid' and haul.capacity(rows, 'parcel') < 8 and haul.capacity(rows, 'fluid') < 100
    and haul.capacity(rows, 'dryBulk') < 100 then
    return 'Fit parcel boxes, a fluid tank, or aggregate storage for freight.'
  end
end

local function truckingState()
  local out = haul.state(S.career)
  local g = S.career.garage
  local v, tier = freightCarrier()
  local rows = S.storage and S.storage.rows
  -- a company vehicle outside contract work (an old loaner) counts as no vehicle of your own
  if g.car and g.car.loaner and not S.career.employment then v, tier = nil, nil end
  out.carrier = tier and haul.tiers[tier].name or nil
  if not v or not tier or haul.SMALL[tier] then
    -- no van or truck of your own: company contracts, the company's van is handed over at its yard
    out.contracts = not S.job and not g.preview and M.nearContracts(earth.pose()) or {}
  end
  out.hint = M.freightHint(v, tier, rows)
  local cm = S.contractMsg
  if cm and (S.clock or 0) - cm.at > M.CONTRACT_MSG_S then S.contractMsg, cm = nil, nil end
  out.error = S.freightSetupError or (cm and not S.career.employment and cm.text) or nil
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
  if personal and personal.started then state.debtInfo = garage.debtInfo(personal) end
  state.heldWages = shift and shift.phase ~= 'settled' and math.floor(shift.gross * (shift.share or employment.SHARE) + 0.5) or 0
  state.ledger = {}
  for i, row in ipairs(economy.restore(S.career).history) do
    if i > 20 then break end
    state.ledger[i] = row
  end
  state.reputation = rating.state(S.career)
  state.fines = S.career.fines
  -- every kind of work, what it needs and whether you have it (issue #123)
  local owned, g = {}, personal or {}   -- during a company shift the garage you own waits in the shift
  if g.car and not g.car.loaner and not g.car.standIn then owned[upkeep.tier(g.car)] = true end
  for _, car in ipairs(g.parked or {}) do if not car.loaner then owned[upkeep.tier(car)] = true end end
  local trusted = false
  for _, co in pairs(S.career.companies or {}) do
    if type(co) == 'table' and (co.reputation or 0) >= employment.INDEPENDENT_REP then trusted = true end
  end
  -- taxi and tow depend on the vehicle you are in: its passenger seats and its tow hitch (or fifth wheel)
  local okTaxi, taxiNow = pcall(M.taxiState)
  local v, tier = freightCarrier()
  local towOk = v ~= nil and tow.class(tier, tow.hasHitch(v)) ~= nil
  -- the car you drive is your only one of its kind and has no cargo boxes: its work can't come yet (parked cars
  -- can't be checked until driven)
  local boxless = {}
  local here = not shift and g.car and not g.car.loaner and not g.car.standIn and upkeep.tier(g.car)
  if (here == 'suv' or here == 'van' or here == 'rigid') and S.storage and S.storage.rows then
    local need = here == 'suv' and require('cargoEarth/parts').MIN_SLOTS or 1
    local another = false
    for _, car in ipairs(g.parked or {}) do if not car.loaner and upkeep.tier(car) == here then another = true end end
    local rows = S.storage.rows
    -- a box truck may carry fluid or dry bulk instead (haul.freight takes 100 L or more)
    local bulk = here == 'rigid' and (haul.capacity(rows, 'fluid') >= 100 or haul.capacity(rows, 'dryBulk') >= 100)
    if not another and not bulk and haul.capacity(rows, 'parcel') < need then boxless[here] = true end
  end
  state.work = progress.workTypes(S.career, { owned = owned, firm = fleet.unlocked(S.career), independent = trusted, boxless = boxless,
    taxi = okTaxi and type(taxiNow) == 'table' and { ready = taxiNow.eligible == true, why = taxiNow.hint } or nil,
    tow = { ready = towOk, why = 'The vehicle you drive has no tow hitch.' },
    firmReq = (firm.requirements(S.career, state.debt)), vanGoal = haul.VAN_GOAL, rigidGoal = haul.RIGID_GOAL })
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
    S.companyBoard = employment.board(S.idx, earth.pose(), haul.state(S.career).unlocked, M.companyRanges())
    S.companyBoardDirty, S.nextBoardAt = nil, S.clock + 2
  end
  local c, p = S.career, earth.pose()
  local out = { home = c.home,
    companies = {}, msg = S.placesMsg, status = earth.status(), busy = S.job ~= nil or S.parts ~= nil,
    started = c.garage.started, canContract = c.garage.started or M.freePlay() or nil, blocked = S.pendingCareer ~= nil, last = c.lastContract,
    discovery = helper.status() }
  if c.home then
    local pg = c.employment and c.employment.personalGarage or c.garage
    out.homeInfo = home.state(c, p, pg.debt or 0)
    out.money = math.floor(c.money or 0)
    out.atHome, out.used = home.near(c, p), home.count(pg)
    out.capacity = firm.capacity(c)
    out.homeKm = p and jobs.km(p.lat, p.lon, c.home.g[1], c.home.g[2]) or nil
  end
  for _, offer in ipairs(S.companyBoard or {}) do
    local company = c.companies and c.companies[offer.companyId or offer.id]
    local km = p and jobs.km(p.lat, p.lon, offer.yard.g[1], offer.yard.g[2]) or nil
    out.companies[#out.companies + 1] = { id = offer.id, name = offer.name, yard = offer.yard.n,
      vehicle = offer.vehicle or haul.loaners.van.name, van = (offer.tier or 'van') == 'van',
      km = km, routeKm = offer.km, wages = math.floor(offer.gross * employment.shareFor(offer.tier or 'van', c) + 0.5), minutes = offer.minutes,
      reputation = company and company.reputation or 0,
      independentPay = offer.gross, independentUnlocked = company ~= nil and company.reputation >= employment.INDEPENDENT_REP,
      atYard = km and km * 1000 <= employment.RADIUS and not p.camera and (p.speed or 0) <= M.STOP_SPEED }
  end
  local shift = c.employment
  if shift then
    out.shift = { company = shift.companyName, phase = shift.phase, completed = shift.completed, total = #shift.jobs,
      held = math.floor(shift.gross * (shift.share or employment.SHARE) + 0.5), atYard = employment.atYard(c, p),
        failed = shift.failed or 0, vehicleDamage = shift.vehicleDamage or 0, reputationScore = employment.reputation(shift, false),
      error = S.companyError, ownerOperator = shift.ownerOperator, vehicle = employment.vehicleLabel(shift) }
  end
  return out
end

-- here: settle where the player is (a bus handed over: the trip back to the depot already happened)
local function companyReturn(aborted, here)
  local c, shift = S.career, S.career.employment
  if not shift then return false, 'No company contract is active.' end
  if S.parts then return false, 'Close the parts preview before ending the contract.' end
  if shift.phase ~= 'settled' then
    if not aborted and not here and not employment.atYard(c, earth.pose()) then return false, 'Park at the company yard first.' end
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
    S.sweepWanted, S.sweepAt = true, S.clock + 1
    S.busDwell = nil
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
  if personal.car and personal.car.freePlay then personal.car = nil end   -- free play keeps no car of its own
  c.garage, c.employment = personal, nil
  S.mode = M.RULES[shift.previousMode] and shift.previousMode or 'courier'
  S.opts, S.offeredAt, S.odometerPose = S.optsByMode[S.mode], nil, nil
  S.companyError, S.companyPreparedAt, S.busHome = nil, nil, nil
  S.phone.lastDone = nil
  if not saveCareer() then return false, S.saveError end
  return true, string.format('Company work ended. Paid %d CZK; %d CZK went to debt.', c.lastContract.net, c.lastContract.toDebt)
end

local function companyStart(id, independent)
  local c, g, p = S.career, S.career.garage, earth.pose()
  if c.employment or S.job or S.parts or g.preview or g.pendingUsed then return false, 'Finish your current work or vehicle preview first.' end
  local free = M.freePlay()
  if not free and (not g.started or not g.car or not garage.inOwnCar(M.G, g)) then
    return false, 'Start your career and drive your own car to the company yard.'
  end
  if earth.status() ~= 'ok' or not p or p.camera or (p.speed or 0) > M.STOP_SPEED then return false, 'Park at the company yard first.' end
  local offer
  for _, row in ipairs(S.companyBoard or {}) do if row.id == id then offer = row break end end
  offer = offer or M.busOffer(id)
  if not offer then return false, 'Refresh the company board.' end
  local radius = offer.tier == 'bus' and require('cargoEarth/bus').depotRadius(offer) or employment.RADIUS
  if jobs.km(p.lat, p.lon, offer.yard.g[1], offer.yard.g[2]) * 1000 > radius then
    return false, 'Drive to the company yard, then park to start.'
  end
  local snapshot
  if free then
    -- free play: the vehicle the player came in is put back after the shift (it is no career car: nothing is owed)
    local v = M.G.vehicle and M.G.vehicle()
    local config = v and v.model and M.G.captureConfig and M.G.captureConfig(v)
    if not config then return false, 'Could not save your vehicle configuration.' end
    snapshot = { model = v.model, config = config, name = v.model, freePlay = true }
    if independent then return false, 'Independent contracts are part of the career.' end
  else
    if not garage.remember(M.G, g) then return false, 'Could not save your car configuration.' end
    local damage = M.G.damage and M.G.damage()
    if damage then garage.trackDamage(g, damage) end
  end
  local want = offer.tier or 'van'
  if want ~= 'bus' and not haul.allowed(c, want) then return false, 'Unlock the ' .. haul.tiers[want].name:lower() .. ' first.' end
  if independent then
    if want ~= 'van' then return false, 'Independent contracts are for vans.' end
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
  local preset, config = haul.loaners[want], nil
  if want == 'bus' then
    local key
    local lent = offer.coach and haul.loaners.coach or haul.loaners.bus
    config, key = M.G.busLoanerConfig and M.G.busLoanerConfig(offer.coach)
    preset = { model = lent.model, key = key, name = lent.name, label = lent.label }
  else
    config = M.G.freightLoanerConfig and M.G.freightLoanerConfig(preset.model, preset.key)
  end
  if not config then return false, 'The company ' .. preset.label .. ' configuration is unavailable in this game version.' end
  local companyGarage = garage.new()
  companyGarage.started = true
  companyGarage.car = { model = preset.model, key = preset.key, name = 'Company ' .. preset.name, config = config,
    km = 0, condition = 1, loaner = true, company = true }
  local ok, why = employment.begin(c, offer, g, companyGarage, S.mode)
  if not ok then return false, why end
  if snapshot then g.car = snapshot end
  c.garage = companyGarage
  c.location = { lat = p.lat, lon = p.lon }
  -- Commit the personal-car snapshot before any spawn can replace it.
  S.skipCapture = true
  local saved = saveCareer()
  S.skipCapture = nil
  if not saved then
    if snapshot then g.car = nil end
    c.garage, c.employment = g, nil
    return false, S.saveError
  end
  releaseStorage()
  local spawned, err = spawnCareerCar(companyGarage)
  if not spawned then
    S.companyError = err .. ' End company work to restore your car.'
    return false, S.companyError
  end
  S.mode = want == 'bus' and 'bus' or 'trucking'
  S.opts, S.companyPreparedAt = S.optsByMode[S.mode], c.activeSeconds or 0
  S.phone.online, S.phone.incoming, S.phone.lastDone = false, nil, nil
  S.offeredAt, S.odometerPose = nil, nil
  saveCareer()
  if want == 'bus' and offer.coach then
    return true, string.format('Your %s is ready. Open the doors for your passengers, then drive them to %s%s.',
      preset.label, offer.jobs[1].bus.stops[2].n, #offer.jobs[1].bus.stops > 2 and ' and back' or '')
  end
  if want == 'bus' then
    return true, string.format('Your %s is ready. Drive %s, open the doors at every stop, then bring the bus back here.',
      preset.label, offer.jobs[1].cargoName)
  end
  return true, 'Company ' .. preset.label .. ' loading. Two deliveries, then return here for wages. The company keeps 20% and covers vehicle costs.'
end

function M.busSelect(id)
  if S.mode ~= 'bus' or S.job or S.career.employment then return end
  local g = S.career.garage
  if not (g.started or M.freePlay()) or not garage.inOwnCar(M.G, g) then
    S.contractMsg = {text = 'Choose a line while driving your own career car.', at = S.clock}
    return
  end
  local offer = M.busOffer(id)
  if offer then
    S.busDepot = {offer = offer, parked = 0}
    earth.gps(offer.yard.g[1], offer.yard.g[2], (offer.coach and 'Coach pickup: ' or 'Bus pickup: ') .. offer.yard.n)
    return
  end
  S.contractMsg = {text = S.busKind == 'coach' and 'Choose the ride again.' or 'Refresh the bus lines and choose a line again.', at = S.clock}
end

function M.busDepotInfo(p)
  local d, bus = S.busDepot, require('cargoEarth/bus')
  if not d or S.job or S.career.employment or not p then return nil end
  local inside = jobs.km(p.lat, p.lon, d.offer.yard.g[1], d.offer.yard.g[2]) * 1000 <= bus.depotRadius(d.offer)
  return {depot = true, inZone = inside, stopping = inside and (d.parked or 0) > 0,
    frac = math.min(1, (d.parked or 0) / bus.PARK_S), leftS = math.max(0, bus.PARK_S - (d.parked or 0)),
    title = d.error and 'Bus unavailable' or (d.offer.coach and 'Park here to collect your coach' or 'Park here to collect your bus'),
    detail = d.error or 'Your own car will be stored when the bus replaces it.', stopS = bus.PARK_S}
end

function M.busDepotTick(p, dt)
  local d, bus = S.busDepot, require('cargoEarth/bus')
  if not d or d.error or S.mode ~= 'bus' or S.job or S.career.employment then return end
  local info = M.busDepotInfo(p)
  local g = S.career.garage
  if not info or not info.inZone or p.camera or (p.speed or 0) > bus.PARK_SPEED
    or S.parts or g.preview or g.pendingUsed or not garage.inOwnCar(M.G, g) then d.parked = 0 return end
  d.parked = d.parked + dt
  if d.parked < bus.PARK_S then return end
  -- Keep the chosen offer even if the nearby board refreshed while driving to it.
  local field = d.offer.coach and 'coachBoard' or 'busBoard'
  S[field] = S[field] or {}
  local found = false
  for i, offer in ipairs(S[field]) do
    if offer.id == d.offer.id then S[field][i], found = d.offer, true break end
  end
  if not found then S[field][#S[field] + 1] = d.offer end
  local ok, why = companyStart(d.offer.id)
  if ok or S.career.employment then S.busDepot = nil else d.error = why end
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
  if shift.tier == 'bus' and (shift.handover or shift.phase == 'returning' and not S.job) then
    M.busHomeTick(shift)
    return
  end
  if shift.phase == 'preparing' and shift.tier == 'bus' then shift.phase = 'working' end
  if shift.phase == 'preparing' then
    S.companyPreparedAt = S.companyPreparedAt or c.activeSeconds or 0
    local v, tier = freightCarrier()
    local store = v and refreshStorage()
    local want = shift.tier or 'van'
    local rows = store and store.rows
    if tier == want and want ~= 'semi' and rows then employment.fit(shift, rows) end
    local first = shift.jobs[shift.index]
    if tier == want and (want == 'semi' or rows and haul.plan(rows, first.haul)) then
      shift.phase, S.companyError = 'working', nil
    elseif (c.activeSeconds or 0) - S.companyPreparedAt >= employment.PREPARE_TIMEOUT then
      S.companyError = 'The company ' .. haul.loaners[want].label .. ' is not ready. End company work to restore your car, then try again.'
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

-- The bus is handed over where the line ends (or where the shift was ended) and the player is taken back to the
-- depot, where the shift is paid and the player's own car comes back. aborted: ended before the last stop; away from
-- the depot that costs bus.COLLECT_FEE.
function M.busHandover(aborted)
  local c, shift, p = S.career, S.career.employment, earth.pose()
  if not shift or shift.tier ~= 'bus' then return false, 'No bus shift is active.' end
  if shift.handover then return false, 'The bus is being handed over.' end
  if employment.atYard(c, p) then return companyReturn(aborted) end
  if aborted then
    local fee = require('cargoEarth/bus').COLLECT_FEE
    local paid = math.max(0, math.min(fee, math.floor(c.money or 0)))
    local what = 'Bus collected: ' .. tostring(shift.companyName)
    if paid > 0 then economy.post(c, -paid, 'fine', economy.nextId(c, 'fine'), what) end
    if paid < fee then garage.addDebt(shift.personalGarage, fee - paid, 'fine', what) end
  end
  if S.busDwell and M.G.busDoors then M.G.busDoors(false) end
  clearFreight()
  S.orders, S.job, S.phase, S.stopT, S.busDwell = {}, nil, 'idle', 0, nil
  earth.gpsClear()
  shift.handover = aborted and 'aborted' or 'done'
  saveCareer()
  return true, (aborted and string.format('Shift ended. The company collects the bus (-%d CZK). ', require('cargoEarth/bus').COLLECT_FEE)
    or 'Line done, the bus is handed over. ') .. 'Taking you back to ' .. shift.yard.n .. '.'
end

-- After the handover: the trip to the depot, then the shift is settled there. When BeamNG.Earth cannot take the
-- player there, the shift is settled where they are.
function M.busHomeTick(shift)
  if not shift.handover then
    local ok, why = M.busHandover(false)
    say(why, 6)
    if not ok then S.companyError = why end
    return
  end
  local p, yard = earth.pose(), { lat = shift.yard.g[1], lon = shift.yard.g[2] }
  local trip = S.busHome
  if not trip then
    -- a moment to read the handover message before the trip
    trip = { goAt = S.clock + M.BUS_HANDOVER_S }
    S.busHome = trip
  end
  if trip.goAt then
    if S.clock < trip.goAt then return end
    trip.goAt, trip.untilT = nil, S.clock + M.RESUME_TIMEOUT_S
    if not atLocation(p, yard, M.RESUME_ARRIVAL_M) then
      local ok = earth.teleport(yard.lat, yard.lon, shift.yard.n)
      if not ok then trip.untilT = S.clock end
    end
  end
  if p and not p.camera and (atLocation(p, yard, M.RESUME_ARRIVAL_M) or S.clock >= trip.untilT) then
    local ok, why = companyReturn(shift.handover == 'aborted', true)
    if ok then say(why, 8) else S.companyError, trip.untilT = why, S.clock + 5 end
  end
end

function M.placesDo(name, value)
  if S.pendingCareer then return M.placesState() end
  local c, p, ok, why = S.career, earth.pose(), false, nil
  if earth.status() ~= 'ok' or not p then S.placesMsg = earth.status() return M.placesState() end
  if name == 'claimHome' then
    if S.job or c.employment or S.parts then why = 'Finish your current work first.'
    elseif not c.garage.started then why = 'A home garage is part of the career. Start one on the phone first.'
    elseif not garage.inOwnCar(M.G, c.garage) then why = 'Sit in your career car to set your home here.'
    else
      local old = c.home
      ok, why = home.claim(c, p, food.addresses(S.fidx, p.lat, p.lon, '')[1])
      if ok and not saveCareer() then c.home, ok, why = old, false, S.saveError end
    end
  elseif name == 'upgradeHome' or name == 'buildRoom' then
    local debt = (c.employment and c.employment.personalGarage or c.garage).debt or 0
    if name == 'upgradeHome' then ok, why = home.upgrade(c, debt) else ok, why = home.build(c, value, debt) end
    if ok and not saveCareer() then why = S.saveError end
  elseif name == 'homeGps' and c.home then
    if S.job or c.employment then why = 'Finish your current work before changing GPS.'
    else ok, why = earth.gps(c.home.g[1], c.home.g[2], c.home.name) end
  elseif name == 'refreshCompanies' then
    S.companyBoard = employment.board(S.idx, p, haul.state(S.career).unlocked, M.companyRanges())
    S.companyBoardDirty, S.nextBoardAt = nil, S.clock + 2
    S.placesMsg = #S.companyBoard > 0 and 'Fictional employers at mapped depot locations. Check access on arrival; you can end work without a cancellation fee.'
      or 'Looking for nearby workplaces through the helper. Contracts appear as local data loads.'
  elseif name == 'companyGps' then
    if S.job then why = 'Follow the current delivery GPS.'
    elseif c.employment then
      ok, why = earth.gps(c.employment.yard.g[1], c.employment.yard.g[2], c.employment.yard.n)
    else
      for _, list in ipairs({ S.companyBoard or {}, S.busBoard or {} }) do
        for _, offer in ipairs(list) do
          if offer.id == value then ok, why = earth.gps(offer.yard.g[1], offer.yard.g[2], offer.yard.n) break end
        end
      end
    end
  elseif name == 'startCompany' then ok, why = companyStart(value)
  elseif name == 'startIndependent' then ok, why = companyStart(value, true)
  elseif name == 'settleCompany' then ok, why = companyReturn(false)
  elseif name == 'endCompany' then
    local shift = c.employment
    -- a bus shift ends the same way from the Menu as from the phone: handed over, with the fee away from the depot
    if shift and shift.tier == 'bus' then ok, why = M.busHandover(shift.phase ~= 'returning')
    else ok, why = companyReturn(true) end
  end
  if why then S.placesMsg = why elseif ok then S.placesMsg = 'GPS updated.' end
  S.placesOk = ok
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

-- nil when no recovery is needed, zero for missing equipment, otherwise the price to reload a dropped car.
local function towRecoveryFee(j)
  if trailers.restoringTow() then return nil end
  if not trailers.id() then return 0 end
  local distances = trailers.towedDistances()
  for _, d in pairs(distances) do
    if d > tow.ON_BOARD_M then return M.TOW_RELOAD_FEE end
  end
  if tow.onBoard(distances) < #j.tow.cars then return 0 end
end

function M.phoneState()
  local c, ph = S.career, S.phone
  local today = (type(c.today) == 'table' and c.today.date == os.date('%Y-%m-%d')) and c.today or { earned = 0, count = 0 }
  local out = { mode = S.mode, online = ph.online, money = c.money or 0, todayEarned = today.earned,
    todayCount = today.count, status = earth.status(), clock = os.date('%H:%M'), hidden = S.phoneHidden,
      helper = M.helperInfo(), saveError = S.saveError, company = c.employment and c.employment.companyName,
      companyDamage = c.employment and (c.employment.vehicleDamage or 0), companyOwnerOperator = c.employment and c.employment.ownerOperator,
      companyVehicle = c.employment and employment.vehicleLabel(c.employment),
      currency = moneyInfo(), update = M.updateInfo(), helperBehind = M.helperBehind(), tab = S.phoneTab or 'orders', radio = M.radioBrief(),
      fold = S.phoneFold or false, dark = M.uiPrefs().dark or false, quiet = M.uiPrefs().quiet or nil, mapPrefs = M.mapPrefs(),
      canSwitch = S.job == nil and not c.employment, helperStart = M.helperStartInfo(), unstuck = M.unstuckInfo() }
  if S.pendingCareer or (not S.career.garage.started and S.career.play ~= 'free' and not c.employment) then
    -- the careers to pick from, on the resume and first-run screens
    local saves = require('cargoEarth/saves')
    out.saves, out.newName, out.savesFull = M.savesList(), saves.suggestName(M.saveIndex()), saves.full(M.saveIndex()) or nil
    out.saveMsg, out.choice = S.saveMsg, M.careerChoice()
    local slot = S.slot and saves.find(M.saveIndex(), S.slot)
    out.saveName = slot and slot.name or nil
  end
  if S.pendingCareer then
    out.screen, out.money = 'resume', S.pendingCareer.money or 0
    local savedGarage = S.pendingCareer.garage
    out.savedCar = type(savedGarage) == 'table' and type(savedGarage.car) == 'table' and savedGarage.car.name or nil
    out.resumeLoading = S.resumeTrip ~= nil
    out.resumeHasLocation = validLocation(S.pendingCareer.location)
    out.resumeError, out.resumeBlocked = S.resumeError, S.loadBlocked and true or nil
    return out
  end
  if S.mode == 'trucking' then out.trucking = truckingState() end
  if S.mode == 'taxi' then out.taxi = M.taxiState() end
  if S.mode == 'bus' then out.bus = M.busState() end
  local gauge = c.garage.started and c.garage.car and fuel.state(c.garage.car)
  if gauge then
    out.fuel = { pct = math.floor(gauge.share * 100 + 0.5), low = gauge.low, empty = gauge.empty, rangeKm = gauge.rangeKm }
    out.pump = M.pumpOffer(gauge)
  end
  if S.job then
    -- the way left to the next stop on Earth's GPS (metres, seconds), for the phone's work bar on every tab
    local rt = earth.route()
    if rt and type(rt.remaining) == 'number' then
      out.routeLeft = { m = math.floor(rt.remaining + 0.5), s = type(rt.eta) == 'number' and math.floor(rt.eta + 0.5) or nil,
        imperial = M.imperial() or nil }
    end
  end
  local here = earth.pose()
  local limit = limitHere(here)
  if limit then
    local kmh = (here.speed or 0) * 3.6
    out.limit = { sign = limit.sign, unit = limit.unit, over = kmh > limit.kmh + M.OVER_KMH,
      well = kmh > limit.kmh + math.max(M.WELL_OVER_KMH, limit.kmh * M.WELL_OVER_SHARE) or nil }
  end
  if camerasOn() then
    local p = here
    if p and not p.camera then out.camera = cameras.ahead(cams, p.lat, p.lon, (p.speed or 0) > M.STOP_SPEED and p.heading or nil) end
    if ph.flash and S.clock < ph.flash.untilT then out.flash = ph.flash else ph.flash = nil end
  end
  if ph.insNote and S.clock < ph.insNote.untilT then out.insNote = ph.insNote.text else ph.insNote = nil end
  out.wreck = M.wreckInfo()
  -- the footer's insured mark, on every screen (also during a job)
  local ig = S.career.garage
  if ig.started and not c.employment and require('cargoEarth/insurance').insured(ig.car) and not ig.car.loaner then out.insured = true end
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
      cargoCondition = receipt.cargoCondition, held = receipt.held, ownerOperator = receipt.ownerOperator, vehicle = receipt.vehicle,
      stars = receipt.stars, note = receipt.note, track = receipt.track, records = receipt.records, premium = receipt.premium,
      tipWhy = receipt.tipWhy, special = receipt.special }
  end
  if ph.dropped and S.clock < ph.dropped.untilT then
    out.dropped = { kg = ph.dropped.kg, left = math.max(0, ph.dropped.left) }
  else
    ph.dropped = nil
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
    local busDue, busMin
    if j.bus then busDue, busMin = require('cargoEarth/bus').due(j, M.elapsed(j)) left = busDue end
    out.screen = 'active'
    local reloadFee = j.tow and S.phase == 'toDelivery' and towRecoveryFee(j) or nil
    out.active = { phase = S.phase, kind = j.kind or 'cargo', cargo = j.cargoName, items = j.items, from = place(j.from), to = place(j.to),
        orderType = j.orderType, handling = cargo.supports(j) and cargo.handling(j) or nil,
      freight = j.haul, freightStatus = S.freightStatus, route = j.route and parcel.state(j),
      canRestoreTrailer = j.trailer and ((not j.tow and not trailers.id() and (S.phase == 'toDelivery' or j.trailerRequested))
        or reloadFee ~= nil) or nil,
        cargoCondition = cargo.supports(j) and S.phase == 'toDelivery' and cargo.condition(j) or nil,
      special = special.info(j), tow = tow.info(j), taxi = require('cargoEarth/taxi').info(j), reloadFee = reloadFee,
      towWaiting = j.tow and j.tow.waiting and S.phase == 'toPickup' or nil,
      towHitch = j.tow and j.tow.stage == 'hitch' and S.phase == 'toPickup' or nil,
      here = j.tow and j.tow.stage and S.phase == 'toPickup' and { name = j.to.n, label = 'Get the trailer here', town = j.to.town or '' } or nil,
      slots = j.kind == 'food' and cargo.size(j) or nil,
      distM = distRoad and math.floor(S.roadM + 0.5)
        or (S.dist and math.floor(S.dist + 0.5)) or nil,
      distRoad = distRoad,
      etaS = S.etaS and math.floor(S.etaS + 0.5) or nil, km = r1(j.km), pay = j.pay, minutes = busMin or j.minutes,
      leftS = math.floor(left + 0.5), arriveM = radius, stop = stopInfo(),
      pickupLeftS = S.phase == 'toPickup' and food.pickupMinutes(j)
        and math.floor(food.pickupMinutes(j) * 60 - M.elapsed(j) + 0.5) or nil,
      cancelAsk = S.phone.cancelAskUntil ~= nil and S.clock <= S.phone.cancelAskUntil, trailer = j.trailer and ((j.tow and tow.CLASSES[j.tow.class].name) or S.idx and S.idx.trailers[j.trailer] or j.trailer) or nil,
      trailerM = j.trailerSpawned and trailers.distanceToPlayer() and math.floor(trailers.distanceToPlayer()) or nil,
      cancelFee = rules(j).cancelFee, count = #S.orders, carrying = carrying, orders = {},
      canHandover = M.canHandover() or nil, handoverPickup = S.phase == 'toPickup' or nil,
      handoverPay = M.canHandover() and (j.handover and j.pay or math.floor(j.pay * M.HANDOVER_PAY + 0.5)) or nil,
      handedOver = j.handover or nil,
      loadKg = r1(cargo.onBoard(S.orders)) }
    -- List the current stop first, then the remaining orders.
    for _, o in ipairs(S.orders) do
      local oj = o.job
      local destination = o.phase == 'toPickup' and oj.from or oj.to
      local l = oj.bus and require('cargoEarth/bus').due(oj, M.elapsed(oj)) or oj.minutes * 60 - M.elapsed(oj)
      local row = { id = oj.id, pickup = o.phase == 'toPickup', name = destination.n,
        cargo = oj.cargoName, leftS = math.floor(l + 0.5), current = oj == j,
        pickupLeftS = o.phase == 'toPickup' and food.pickupMinutes(oj)
          and math.floor(food.pickupMinutes(oj) * 60 - M.elapsed(oj) + 0.5) or nil,
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
  if not g.started and c.play ~= 'free' then
    -- first run: free play (any car, nothing kept) or the career
    out.screen, out.choice = 'choose', M.careerChoice()
    return out
  end
  out.freePlay = not g.started or nil
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
  local why = M.offerWhy()
  -- the vehicle's own reason is already the freight hint
  out.why = why and why.code ~= 'vehicle' and why.text or nil
  return out
end

-- Buttons on the phone: resume, online, offline, accept, decline, gps, selectDelivery, cancel, dismiss.
function M.phoneAction(a, orderId)
  if a == 'helperStart' or a == 'helperHide' then
    M.helperStartDo(a)
    return M.phoneState()
  end
  if a == 'unstuck' then
    if not S.pendingCareer then M.unstuckCar() end
    return M.phoneState()
  end
  -- the write-off window: a free tow home / to the headquarters, or stay
  if a == 'towHome' or a == 'towHq' or a == 'wreckClose' or a == 'wreckRepair' then
    if a == 'wreckClose' then S.phone.wreck = nil
    elseif a == 'wreckRepair' then
      -- repaired on the spot with the claim (the tow is optional)
      if not S.pendingCareer and not S.career.employment then
        local _, msg = M.garageRepair(true)
        if S.phone.wreck then S.phone.wreck.msg = msg end
      end
    elseif not S.pendingCareer then
      local ok, msg = M.insuranceTow(a == 'towHq' and 'hq' or 'home')
      if not ok and S.phone.wreck then S.phone.wreck.msg = msg end
      say(msg, 8)
    end
    return M.phoneState()
  end
  if a == 'loadSave' or a == 'newCareer' or a == 'deleteSave' then
    M.savesDo(a, orderId)
    return M.phoneState()
  end
  if S.pendingCareer then
    if a == 'resume' then requestResume()
    elseif a == 'freePlay' then
      -- the saved career stays on disk; free play starts with its settings
      local p = S.pendingCareer
      M.freshFree(next(p) ~= nil and p or S.career)
      S.career.play = 'free'
      saveCareer()
    end
    return M.phoneState()
  end
  if S.parts and (a == 'online' or a == 'accept') then return M.phoneState() end
  local ph = S.phone
  local unchosen = not S.career.garage.started and S.career.play ~= 'free' and not S.career.employment
  if a == 'freePlay' then
    if not S.career.garage.started then S.career.play = 'free' saveCareer() end
    return M.phoneState()
  elseif a == 'careerInfo' then
    -- back to the choice from free play (only while offline and between orders)
    if not S.career.garage.started and not ph.online and not S.job then S.career.play = nil end
    return M.phoneState()
  elseif a == 'startCareer' then
    ph.online, ph.incoming = false, nil
    M.savesDo('newCareer', orderId)
    return M.phoneState()
  elseif unchosen and (a == 'online' or a == 'accept') then
    return M.phoneState()
  end
  if a == 'pumpFill' then
    -- the fuel offer on the Work screen: up to 25 / 50 / 75 %, or 100 for a full tank
    local pct = tonumber(orderId)
    local page = (pct and pct < 100) and M.garageDo('refuelTo', pct) or M.garageDo('refuel')
    S.pumpMsg = { text = page.msg, untilT = S.clock + 6 }
    return M.phoneState()
  elseif a == 'pumpHide' then
    local near = S.fuelNear
    S.pumpHidden = near and near.station and near.station.id or S.pumpHidden
    return M.phoneState()
  end
  if a == 'online' and S.career.garage.car and S.career.garage.car.loaner and not S.career.employment then
    say('Company vehicles are for contract work only. Use your own car for your own jobs.', 5)
  elseif a == 'online' and S.mode == 'taxi' and not M.taxiState(true).eligible then
    say(M.taxiState().hint, 5)
  elseif a == 'online' then
    ph.online = true
    ph.nextPingAt = S.clock + 2
  elseif a == 'offline' then
    ph.online, ph.incoming = false, nil
  elseif a == 'mode' then
    -- work category, from the phone's offline screen (Settings has the same switch)
    if not ph.online then M.setMode(orderId) end
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
  elseif a == 'towLoad' then
    M.towLoad()
  elseif a == 'towHitch' then
    M.towHitch()
  elseif a == 'busDoors' then
    M.busDoors()
  elseif a == 'busEnd' then
    local shift = S.career.employment
    local ok, why = M.busHandover(not (shift and shift.phase == 'returning'))
    S.contractMsg = why and { text = why, at = S.clock or 0 } or nil
    if ok and why then say(why, 6) end
  elseif a == 'busSkip' then
    M.busSkip()
  elseif a == 'busRetry' then
    if S.mode == 'bus' and not S.career.employment then
      S.busAskAt, S.busRetry = 0, true
      M.busFetch(earth.pose())
    end
  elseif a == 'busGps' or a == 'busStart' then
    M.busSelect(orderId)
  elseif a == 'busKind' then
    -- the Bus page's City lines | Coaches switch (not while a bus is chosen or driven)
    if (orderId == 'coach' or orderId == 'lines') and not S.busDepot and not S.career.employment then
      S.busKind = orderId == 'coach' and 'coach' or nil
      if S.busKind then M.coachTick(earth.pose()) else S.busAskAt = 0 M.busFetch(earth.pose()) end
    end
  elseif a == 'coachRetry' then
    if S.coach then
      S.coach.old = nil
      for _, t in ipairs(S.coach.towns or {}) do if not t.done then t.nextAt = 0 end end
      for _, b in ipairs(S.coach.origin and S.coach.origin.points or {}) do if not b.done then b.nextAt = 0 end end
    end
    M.coachTick(earth.pose())
  elseif a == 'busCancelSelection' then
    if S.busDepot then S.busDepot = nil earth.gpsClear() end
  elseif a == 'contractGps' or a == 'contractStart' then
    -- a failure (not parked at the yard, no van config...) shows on the freight page for a while
    S.placesOk = nil
    M.placesDo(a == 'contractGps' and 'companyGps' or 'startCompany', orderId)
    S.contractMsg = not S.placesOk and S.placesMsg and { text = S.placesMsg, at = S.clock or 0 } or nil
  elseif a == 'handover' then
    M.handover()
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

-- Why no order or freight comes (cargoEarth/offerwhy): { code, text } for the phone's waiting screen, nil while offers
-- are there. Worked out at most once a second; beamng.log gets a line when the reason changes and once a minute while it
-- stays (cargoEarth: no freight offers [code]: ...).
M.OFFER_WHY_LOG_S = 60
function M.offerWhy()
  if (S.mode ~= 'courier' and S.mode ~= 'trucking') or S.pendingCareer then return nil end
  if S.offerWhyAt and S.clock >= S.offerWhyAt and S.clock - S.offerWhyAt < 1 then return S.offerWhyLast end
  S.offerWhyAt = S.clock
  local freight = S.mode == 'trucking'
  local search = S.offerSearch or {}
  local i = { mode = S.mode, offers = #S.offers, generated = S.offeredAt ~= nil, stats = S.offerStats,
    data = (freight and S.idx or S.fidx) ~= nil, helperNeeded = freight and not depotsHere or (not freight and helperWanted),
    helperOff = helper.enabled == false, helper = helper.status(), helperText = type(helper.describe) == 'function' and helper.describe(S.clock) or nil,
    nearKm = search.nearKm, minKm = search.minKm, maxKm = search.maxKm }
  if freight then
    local v, tier = freightCarrier()
    local g = S.career.garage
    if g.car and g.car.loaner and not S.career.employment then v, tier = nil, nil end
    local rows = S.storage and S.storage.rows
    i.vehicle = { hint = M.freightHint(v, tier, rows), tier = tier, model = v and v.model, bodyStyle = v and v.bodyStyle,
      containers = rows and #rows or 0, free = rows and { parcel = haul.capacity(rows, 'parcel'),
        fluid = haul.capacity(rows, 'fluid'), dryBulk = haul.capacity(rows, 'dryBulk') } or nil }
  else
    local plan = storagePlan()
    i.foodRoom = plan and plan.maxFree or nil
  end
  local why = require('cargoEarth/offerwhy').reason(i)
  local last = S.offerWhyLast
  if why and log and (not last or last.log ~= why.log or S.clock >= (S.offerWhyLogAt or 0)) then
    S.offerWhyLogAt = S.clock + M.OFFER_WHY_LOG_S
    log('I', 'cargoEarth', why.log)
  elseif not why and last and log then
    log('I', 'cargoEarth', 'offers found again (' .. #S.offers .. ')')
  end
  S.offerWhyLast = why
  return why
end

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
    if S.autoIdx then fuel.dropArea(S.autoIdx, key) end
  end)
  if type(data.fuel) == 'table' and S.fuelIdx then
    fuel.addArea(S.fuelIdx, data.key, data.fuel)
    fuelNearAt = 0
  end
  if type(data.autos) == 'table' then
    S.autoIdx = S.autoIdx or fuel.index()
    fuel.addArea(S.autoIdx, data.key, data.autos)
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
  log('I', 'cargoEarth', string.format('helper area %s: %d restaurants, %d grocery stores, %d workplaces%s', tostring(data.key),
    n - stores, stores, workplaces, (lat and packDepotsNear(lat, lon)) and ' (built-in depots used here)' or ''))
  if (n > 0 or S.mode == 'taxi') and not S.job then S.offeredAt = nil end
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
  if paid < flash.fine then garage.addDebt(g, flash.fine - paid, 'fine', detail) end
  local rated = 0
  local function mark(job)
    if type(job) == 'table' and not job.starPenalty then job.starPenalty, rated = cameras.STAR_PENALTY, rated + 1 end
  end
  for _, order in ipairs(S.orders) do if order.phase == 'toDelivery' then mark(order.job) end end
  if S.job and S.phase == 'toDelivery' then mark(S.job) end
  c.fines = { count = ((c.fines or {}).count or 0) + 1, paid = ((c.fines or {}).paid or 0) + flash.fine }
  S.lastFlashAt = S.clock   -- a crash soon after counts as reckless for the insurance
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

-- Long hauls: far towns' workplaces for the freight and contract distance settings that reach far (cargoEarth/longhaul).
-- (M. fields: the main chunk is at Lua's 200-local limit)
function M.longHaulRing()
  if S.career.employment or not S.career.garage.started then return nil end
  -- own freight in Freight; company contracts in Freight or while the Companies page is open (any mode)
  local browsing = S.placesRequestedAt and S.clock - S.placesRequestedAt < 30
  if S.mode ~= 'trucking' and not browsing then return nil end
  local profiles = {}
  local tier = S.mode == 'trucking' and freightSettingsTier()
  if tier == 'van' or tier == 'rigid' or tier == 'semi' then profiles[#profiles + 1] = M.jobOptions('freight_' .. tier) end
  local unlocked = haul.state(S.career).unlocked
  for _, t in ipairs(employment.TIERS) do
    profiles[#profiles + 1] = M.jobOptions('company_' .. t)
    if t == (unlocked or 'van') then break end
  end
  return require('cargoEarth/longhaul').rings(profiles)
end

function M.longHaulTick(p)
  local rings = M.longHaulRing()
  if not rings then return end
  local longhaul = require('cargoEarth/longhaul')
  if not S.cities then
    local ok, data = pcall(jsonReadFile, DATA_DIR .. 'cities.json')
    S.cities = longhaul.cities(ok and data or nil)
  end
  S.longHaul = S.longHaul or {}
  longhaul.tick(S.longHaul, S.clock, p, rings, S.cities, helper.ask, packDepotsNear, function(key, depots, city)
    S.idx = S.idx or jobs.streamIndex()
    local n = jobs.addFar(S.idx, key, depots)
    log('I', 'cargoEarth', string.format('long hauls: %d workplaces around %s', n, tostring(city and city.n)))
    if n > 0 then
      S.companyBoardDirty = true
      if not S.job then S.offeredAt = nil end
    end
    return n
  end)
end

local radioAlive   -- (the radio, below)
local radioView    -- (the shared radio, below)
local askUpdate    -- (the update notice, with the support report below)
local function helperTick(p)
  -- an install asked for from the phone goes on to start the helper, even after the notice was closed
  if S.helperStartAt then require('cargoEarth/earthaddon').tick(S.clock) end
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
  local areas = S.mode == 'taxi' or (S.mode == 'trucking' and not depotsHere) or places or helperWanted or stationsWanted or wantsGroceryData()
  local wantCameras = camerasOn() and onHelperCameras or nil
  M.busFetch(p)
  M.coachTick(p)
  M.longHaulTick(p)
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
    local e = radio.player and radio.player.error
    if e and radio.loggedGen ~= gen then -- once per station: beamng.log says why the helper's player is silent
      radio.loggedGen = gen
      log('W', 'cargoEarth', 'radio: the helper could not play it: ' .. tostring(e == 'helper' and 'the helper is not running' or e))
    end
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
  out.radio = radioView()
  -- the phone's <audio> plays the station through the helper: the game's UI refuses web streams, not local ones
  if helper.enabled then out.stream = string.format('http://%s:%d/v1/stream?id=', helper.HOST, helper.PORT) end
  return out
end

------------------------------------------------------------------------------------------ the radio, shared
-- One radio for both phones (the floating UI phone and the phone in its holder on the dash): what should play, how loud,
-- the saved stations, all kept here. Something must turn that into sound:
--   * the game's UI page (the floating phone's app.js keeps one player on the page, alive while the phone app is
--     hidden in the cockpit or folded) checks in with radioDo('page', ...) and plays the stream through the helper;
--   * the helper plays it on the computer when the setting says so, when the game cannot play that station (no AAC,
--     a refused stream), or when no UI page checks in (the dash phone alone: a car screen page plays no sound).
M.RADIO_FILE = '/settings/cargoEarth/radio.json'
M.RADIO_PAGE_S = 5         -- a page player that has not checked in for this long is gone: the helper plays
M.RADIO_SAVED_MAX = 50
radio.want = { on = false, station = nil, vol = 0.6, via = 'page', alone = false, why = '', err = false, seq = 0 }
radio.saved = {}
radio.page = { at = -math.huge, seq = -1, status = 'idle', why = '' }
M.radioStore = {
  read = function() return jsonReadFile and jsonReadFile(M.RADIO_FILE) or nil end,
  write = function(t) if jsonWriteFile then jsonWriteFile(M.RADIO_FILE, t, true) end end,
}

local function isStationId(id) return type(id) == 'string' and #id <= 64 and id:match('^[%w%-]+$') ~= nil end
local function radioClip(v, n) return type(v) == 'string' and v:sub(1, n) or '' end
-- a station as the phones send it, cleaned: nil unless it has an id and a web stream
local function keepStation(st)
  if type(st) ~= 'table' or not isStationId(st.id) or type(st.url) ~= 'string' or not st.url:match('^https?://') then return nil end
  return { id = st.id, name = radioClip(st.name, 120), url = st.url:sub(1, 600), codec = radioClip(st.codec, 20),
    kbps = tonumber(st.kbps) or 0, region = radioClip(st.region, 80),
    country = type(st.country) == 'string' and st.country:match('^%u%u$') and st.country or nil }
end

local function radioApplyPrefs(t)
  local w = radio.want
  if type(t.vol) == 'number' then w.vol = math.max(0, math.min(1, t.vol)) end
  if t.via == 'helper' or t.via == 'page' then w.via = t.via end
  w.station = keepStation(t.last) or w.station
  if type(t.saved) == 'table' then
    radio.saved = {}
    for _, st in ipairs(t.saved) do
      local k = keepStation(st)
      if k and #radio.saved < M.RADIO_SAVED_MAX then radio.saved[#radio.saved + 1] = k end
    end
  end
end
local function radioLoadPrefs()
  if radio.prefsLoaded then return end
  radio.prefsLoaded = true
  local ok, t = pcall(M.radioStore.read)
  if ok and type(t) == 'table' then radio.prefsFound = true radioApplyPrefs(t) end
end
local function radioSavePrefs()
  radio.prefsFound = true
  local w = radio.want
  pcall(M.radioStore.write, { v = 1, vol = w.vol, via = w.via, last = w.station, saved = radio.saved })
end

-- who makes the sound now: 'page' (the game's UI) or 'helper'
local function radioMode()
  local w = radio.want
  if w.via == 'helper' or w.alone or S.clock - radio.page.at > M.RADIO_PAGE_S then return 'helper' end
  return 'page'
end

-- the helper plays what should play, and only then
local function radioSync()
  local w = radio.want
  if w.on and w.station and radioMode() == 'helper' then
    if radio.helperSeq ~= w.seq then
      radio.helperSeq = w.seq
      radio.gen = (radio.gen or 0) + 1
      radio.helperOn, radio.aliveAt = true, S.clock
      radio.player = { playing = true, secs = 0 }
      helper.command(string.format('/v1/player/play?id=%s&vol=%.2f', w.station.id, w.vol), onPlayer(radio.gen), '/v1/player/')
    end
  elseif radio.helperSeq then
    radio.helperSeq = nil
    radio.gen = (radio.gen or 0) + 1
    -- always: a play whose answer was lost (helperOn false) may still be playing on the computer
    helper.command('/v1/player/stop', nil, '/v1/player/')
    radio.helperOn, radio.player = false, nil
  end
end
M.radioSync = radioSync

-- What both phones show: { on, station, status (idle | loading | playing | error), why, vol, via, alone, seq, mode,
-- saved (unless light) }
radioView = function(light)
  radioLoadPrefs()
  local w = radio.want
  local status, why = 'idle', w.why
  if w.err then status = 'error'
  elseif w.on and w.station then
    if radioMode() == 'helper' then
      local p = radio.player
      if not p or radio.helperSeq ~= w.seq then status = 'loading'
      elseif p.playing then status = (p.sound or (tonumber(p.secs) or 0) > 0) and 'playing' or 'loading'
      elseif p.error then
        status = 'error'
        why = p.error == 'old' and 'update the Cargo Earth helper'
          or (p.error == 'helper' and 'the Cargo Earth helper is not running' or tostring(p.error))
      else
        -- the helper's player stopped by itself (restarted, or its watchdog): stopped, so Play starts it again
        w.on = false
        radioSync()
      end
    else
      status = radio.page.seq == w.seq and radio.page.status or 'loading'
      if status == 'error' then status = 'loading' end -- the helper takes over at once (radioDo 'page')
    end
  end
  local out = { on = w.on, station = w.station, status = status, why = why, vol = w.vol, via = w.via, alone = w.alone,
    seq = w.seq, mode = radioMode() }
  if not light then out.saved = radio.saved end
  return out
end

-- For the phones' quick poll: what plays, in short (nil while nothing does).
function M.radioBrief()
  local w = radio.want
  if not (w.on or w.err) or not w.station then return nil end
  local v = radioView(true)
  return { status = v.status, name = w.station.name, seq = w.seq }
end

-- name:
--   play (a = station) | stop | vol (a = 0..1) | via (a = 'page' | 'helper') | fav (a = station: saved or not)
--   page (a = seq, b = status, c = why): the UI page's player checks in; answers in short
--   import (a = { vol, via, last, saved }): the radio settings an older version kept in the UI page, taken once
--   refresh | played (a = station id: Radio Browser counts what is listened to)
function M.radioDo(name, a, b, c)
  radioLoadPrefs()
  local w = radio.want
  if name == 'refresh' then
    radio.askedAt = -math.huge
  elseif name == 'played' and isStationId(a) and #a == 36 then
    helper.ask('/v1/radioclick?id=' .. a, nil)
  elseif name == 'play' then
    local st = keepStation(a)
    if not st then
      w.on, w.err, w.why = false, true, 'not a web stream'
    elseif not (w.on and w.station and w.station.id == st.id and radioView(true).status ~= 'error') then
      -- (the same station again only after an error: then it is tried again, in a new session)
      w.station, w.on, w.err, w.why = st, true, false, ''
      w.seq = w.seq + 1
      -- the game's UI has no AAC, and plays only through the helper's relay: otherwise the helper plays it
      w.alone = w.via ~= 'helper' and (not helper.enabled or st.codec:lower():match('^aac') ~= nil)
      if #st.id == 36 then helper.ask('/v1/radioclick?id=' .. st.id, nil) end
      log('I', 'cargoEarth', string.format('radio: %s (%s), played by %s', st.name, st.codec,
        (w.via == 'helper' or w.alone) and 'the helper' or 'the game'))
      radioSavePrefs()
    end
  elseif name == 'stop' then
    w.on, w.err, w.alone = false, false, false
  elseif name == 'vol' and tonumber(a) then
    w.vol = math.max(0, math.min(1, math.floor(tonumber(a) * 100 + 0.5) / 100))
    if radio.helperOn then
      helper.command(string.format('/v1/player/volume?vol=%.2f', w.vol), onPlayer(radio.gen), '/v1/player/volume')
    end
    radioSavePrefs()
  elseif name == 'via' and (a == 'page' or a == 'helper') then
    if a ~= w.via then
      w.via, w.alone = a, false
      if w.on then w.seq = w.seq + 1 end -- plays again in the other player
      radioSavePrefs()
    end
  elseif name == 'fav' then
    local st = keepStation(a)
    if st then
      local at
      for i, x in ipairs(radio.saved) do if x.id == st.id then at = i end end
      if at then table.remove(radio.saved, at)
      elseif #radio.saved < M.RADIO_SAVED_MAX then radio.saved[#radio.saved + 1] = st end
      radioSavePrefs()
    end
  elseif name == 'page' then
    radio.page.at = S.clock
    if tonumber(a) == w.seq then
      radio.page.seq = w.seq
      radio.page.status = (b == 'playing' or b == 'loading' or b == 'error') and b or 'idle'
      if b == 'error' and w.on and radioMode() == 'page' then
        -- this station only: the helper plays it on the computer (the setting stays as the player set it)
        w.alone, w.why = true, 'the game could not play it' .. (type(c) == 'string' and c ~= '' and ' (' .. c:sub(1, 40) .. ')' or '')
        log('W', 'cargoEarth', 'radio: ' .. w.why .. ', the helper plays it')
      end
    end
    radioSync()
    return { radio = radioView(true),
      stream = helper.enabled and string.format('http://%s:%d/v1/stream?id=', helper.HOST, helper.PORT) or nil }
  elseif name == 'import' and type(a) == 'table' then
    if not radio.prefsFound then radioApplyPrefs(a) radioSavePrefs() end
  end
  radioSync()
  return M.radioState()
end

-- What the phone and window say about the helper: nil when it isn't needed here.
-- The helper is not answering and BeamNG.Earth's add-on list has it: the phone offers a Start button that starts it
-- there (and turns on "Start with BeamNG.Earth"; cargoEarth/earthaddon). nil when there is nothing to offer.
M.HELPER_STARTING_S = 30   -- after Start: "Starting..." this long while the helper comes up (helper.RETRY_S 15)
function M.helperStartInfo()
  local h = helper.status()
  if not helper.enabled or S.helperStartHidden or h.state ~= 'off' or not (h.msg or h.down) then return nil end
  local ea = require('cargoEarth/earthaddon')
  ea.tick(S.clock)
  -- BeamNG.Earth builds its whole Add-ons page for this: once a second is plenty (every phone asks twice a second)
  local kept = S.addonState
  if not kept or S.clock - kept.at >= 1 or S.clock < kept.at then kept = { at = S.clock, e = ea.state() } S.addonState = kept end
  local e = kept.e
  if not e or not e.connected then return nil end
  local starting = S.helperStartAt and S.clock - S.helperStartAt < M.HELPER_STARTING_S
  return { installed = e.installed, running = e.running, busy = e.busy or starting or false,
    error = not starting and (S.helperStartError or e.error) or nil, author = e.author or 'themazzy' }
end

function M.helperStartDo(a)
  if a == 'helperHide' then S.helperStartHidden = true return end
  local ok, why = require('cargoEarth/earthaddon').start(S.clock)
  S.addonState = nil
  S.helperStartAt, S.helperStartError = ok and S.clock or nil, not ok and tostring(why or 'failed') or nil
  -- ask the helper again soon instead of after its retry wait
  if ok and type(helper.retrySoon) == 'function' then helper.retrySoon(S.clock + 5) end
end

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
    if M.G.applyCondition then
      pcall(M.G.applyCondition, g.car.km or 0, g.car.condition or 1, require('cargoEarth/faults').native(g.car))
    end
    if g.car.physicalDamage then
      local car = g.car
      g.restoringDamage = {car = car, bill = g.repair or 0}
      local pending = g.restoringDamage
      if not require('cargoEarth/damage').restore(M.G, g, function(ok)
        if g.restoringDamage == pending then
          pending.ready, pending.ok = S.clock + 1, ok
        end
      end) then pending.ready, pending.ok = S.clock + 1, false end
    end
  end
  fuelTick(own)
  if not own then return end
  if g.restoringDamage then
    local pending = g.restoringDamage
    if pending.car ~= g.car then g.restoringDamage = nil
    elseif not pending.ready or S.clock < pending.ready then return
    else
      g.restoringDamage = nil
      -- the restored state may carry the load the car had when it was saved: read the containers again and empty
      -- what nothing on board explains
      S.storage = nil
      if not S.job then S.sweepWanted, S.sweepAt = true, S.clock + 1 end
      local swapped = pending.car.partsRestore
      pending.car.partsRestore = nil
      if pending.ok and swapped then
        -- after a parts change: the bill keeps the share of the damage still on the car (the rest left with the parts)
        local share = math.min(1, (M.G.damage() or 0) / swapped.damage)
        pending.bill = math.floor(pending.bill * share / 5 + 0.5) * 5
      end
      if pending.ok then
        g.damageBaseline = {damage = M.G.damage() or 0, bill = pending.bill}
        g.lastDamage = g.damageBaseline.damage
        g.carriedRepair = g.lastDamage == 0 and pending.bill or nil
      else
        say('Saved vehicle damage could not be restored. Its repair bill has been kept.', 8)
      end
    end
  end
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
  local damage = M.G.damage()
  M.busDamageTick(damage)
  -- a parts preview respawns the car: the damage counter waits until it is kept (buyParts) or discarded (a respawn)
  local what, amount, insured
  if not S.parts then what, amount, insured = garage.trackDamage(g, damage) end
  if shift and what == 'hit' then employment.damage(S.career, math.max(0, amount)) end
  if shift and not shift.ownerOperator then g.debt = 0 end
  if what == 'hit' then
    S.dirtyAt = S.dirtyAt or (S.clock + 5)
    M.insuranceHit(g, amount)
  elseif what == 'debt' then
    if shift and not shift.ownerOperator then
      say('Company ' .. employment.vehicleLabel(shift) .. ' repaired. Recorded damage still affects employer reputation.', 8)
    elseif (insured or 0) > 0 then
      say(string.format('Your car was fixed in the game menu: insurance paid %d CZK, %d CZK added to your debt.', insured, amount), 8)
    else
      say(string.format('Your car was fixed without paying (menu repair, reset or respawn): %d CZK added to your debt.', amount), 8)
    end
    saveCareer()
  end
  M.insuranceTick(p)
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
        local paid, owed = pending.paid or pending.cost or 0, pending.owed or 0
        if pending.debt then paid, owed = 0, pending.cost or 0 end   -- saved by an older build
        if owed > 0 then garage.cancelDebt(g, owed, 'fuel', 'Refund: refuelling failed') end
        if paid > 0 then economy.post(S.career, paid, 'fuel', economy.nextId(S.career, 'fuel'), 'Refund: refuelling failed') end
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
  -- and the home's fuel tank (it charges electric cars too)
  local h = S.career.home
  if h and h.g and home.has(S.career, 'tank') then
    local d = fuel.km(p.lat, p.lon, h.g[1], h.g[2])
    if not km or d < km or d * 1000 <= home.RADIUS then
      station, km = { id = 'home', g = h.g, n = st.kind == 'electric' and 'Your home charger' or 'Your home tank',
        kind = fuel.stationKind(st.kind), home = true }, d
    end
  end
  S.fuelNear = station and { station = station, km = km, kind = st.kind,
    at = km * 1000 <= fuel.STATION_RADIUS and not p.camera and (p.speed or 0) <= M.STOP_SPEED } or { kind = st.kind }
  return S.fuelNear, st
end

local function fuelFactor(station)
  if station.home then return home.roomById.tank.factor end
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

-- Pays a fuel bill: the wallet pays what it can (shown in Finances), the rest goes on the debt.
-- Returns paid, owed.
-- (on M: core.lua is at Lua's 200-locals limit)
function M.fuelCharge(cost, what, debtWhat)
  local c, g = S.career, S.career.garage
  local paid = math.max(0, math.min(cost, math.floor(c.money or 0)))
  if paid > 0 then economy.post(c, -paid, 'fuel', economy.nextId(c, 'fuel'), what) end
  local owed = cost - paid
  if owed > 0 then garage.addDebt(g, owed, 'fuel', debtWhat or what) end
  return paid, owed
end

function M.owedText(owed)
  return owed > 0 and string.format(' (%d CZK added to your debt)', owed) or ''
end

-- Takes the money (what the wallet cannot cover goes on the debt: nobody is stranded) and fills the tank.
local function fuelBuy(car, quote, extra, detail, onCredit)
  local c = S.career
  local cost = quote.cost + (extra or 0)
  local before = {}
  for name in pairs(quote.levels) do before[name] = car.fuel.tanks[name].ratio end
  if not M.G.setFuel(fuelWatch.id, quote.levels) then return false, 'Could not reach the car’s tank.' end
  local paid, owed = cost, 0
  if cost > 0 then
    if onCredit then
      paid, owed = M.fuelCharge(cost, detail)
    else
      economy.post(c, -cost, 'fuel', economy.nextId(c, 'fuel'), detail)
    end
  end
  fuel.apply(car, quote)
  car.fuel.bought = (car.fuel.bought or 0) + (extra or 0)
  fuelPending = { id = fuelWatch.id, car = car, levels = quote.levels, before = before, cost = cost, paid = paid, owed = owed,
    untilT = S.clock + M.FUEL_VERIFY_S }
  saveCareer()
  return true, cost, owed
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
  local st = gamePump.station
  local free = car.loaner == true
  local quote = fuel.pumpQuote(car, report, fuel.stationFactor(st.id), free)
  if not quote then return false end
  local owed = 0
  if quote.cost > 0 then owed = select(2, M.fuelCharge(quote.cost, st.n, 'Fuel at ' .. tostring(st.n))) end
  fuel.apply(car, quote)
  say(free and string.format('Filled %s at %s on the company fuel card.', unitsText(quote.units), st.n)
    or string.format('Filled %s at %s for %d CZK%s.', unitsText(quote.units), st.n, quote.cost, M.owedText(owed)), 8)
  saveCareer()
  return true
end

-- amount: units to buy, or nil for a full tank; pct: fill the tank up to this percentage instead (25, 50, 75)
local function fuelRefuel(amount, pct)
  local car, why = fuelCar()
  if not car then return false, why end
  local near = fuelNear()
  if not near or not near.station or not near.at then return false, 'Park at a station first. Garage shows the nearest one.' end
  local free = car.loaner == true
  local money = math.max(0, S.career.money or 0)
  local upTo = tonumber(pct) and math.max(0.05, math.min(1, tonumber(pct) / 100)) or nil
  local quote = fuel.quote(car, fuel.sells(near.station.kind), fuelFactor(near.station), tonumber(amount), not free and money or nil, free, upTo)
  if not quote then
    local full = fuel.quote(car, fuel.sells(near.station.kind), fuelFactor(near.station), nil, nil, true, upTo)
    return false, full and 'Not enough money for fuel. Fuel delivery can go on your debt.'
      or (upTo and upTo < 1 and string.format('The tank is already above %d %%.', math.floor(upTo * 100 + 0.5)) or 'The tank is full.')
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
  local ok, cost, owed = fuelBuy(car, quote, free and 0 or fuel.DELIVERY_FEE, 'Roadside fuel delivery', true)
  if not ok then return false, cost end
  return true, free and string.format('The company sent %s.', unitsText(quote.units))
    or string.format('Delivered %s for %d CZK%s.', unitsText(quote.units), cost, M.owedText(owed))
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
      -- part fills: up to 25 / 50 / 75 % of the tank (only the ones above the current level)
      st.partial = {}
      for _, pct in ipairs({ 25, 50, 75 }) do
        local q = fuel.quote(g.car, fuel.sells(s.kind), fuelFactor(s), nil, nil, st.free, pct / 100)
        if q then
          st.partial[#st.partial + 1] = { pct = pct, cost = q.cost, units = unitsText(q.units),
            afford = st.free or q.cost <= money }
        end
      end
    end
  end
  local delivery = fuel.quote(g.car, { gasoline = true, diesel = true, electric = true }, fuel.DELIVERY_FACTOR, fuel.DELIVERY_UNITS, nil, st.free)
  st.delivery = delivery and { cost = delivery.cost + (st.free and 0 or fuel.DELIVERY_FEE), units = unitsText(delivery.units) } or nil
  return st
end

-- The Work screen's fuel offer while the car stands at a station's pumps: { name, free, options = { pct, cost,
-- afford } } or nil. Hidden for that station after "Not now" until the car leaves it; not shown on a near-full tank.
function M.pumpOffer(gauge)
  local g = S.career.garage
  if S.pumpMsg and S.clock > S.pumpMsg.untilT then S.pumpMsg = nil end
  if not g.started or not g.car or S.parts or g.preview or g.pendingUsed or not garage.inOwnCar(M.G, g) then return nil end
  local near = fuelNear()
  local s = near and near.at and near.station
  if not s then S.pumpHidden = nil return nil end
  if S.pumpHidden == s.id then return nil end
  local msg = S.pumpMsg and S.pumpMsg.text
  if fuelPending then return { name = s.n, busy = true, msg = msg, options = {} } end
  if (fuelWatch and fuelWatch.off) or (gauge and gauge.share >= 0.9 and not msg) then return nil end
  local free = g.car.loaner == true
  local money = math.max(0, S.career.money or 0)
  local out = { name = s.n, free = free, msg = msg, options = {} }
  for _, pct in ipairs({ 25, 50, 75, 100 }) do
    local q = fuel.quote(g.car, fuel.sells(s.kind), fuelFactor(s), nil, nil, free, pct < 100 and pct / 100 or nil)
    if q then out.options[#out.options + 1] = { pct = pct, cost = q.cost, afford = free or q.cost <= money } end
  end
  if #out.options == 0 and not msg then return nil end
  return out
end

local function garageSay(ok, msg)
  say(msg)
  -- Garage actions change money directly; give each change its own line in the money history.
  economy.reconcile(S.career, 'garage', msg)
  if ok then saveCareer() end
  return ok, msg
end

-- Keep the outgoing car alive until its latest physical state is checkpointed.
function M.captureOutgoing(run)
  local c, g, G = S.career, S.career.garage, M.G
  if not g.car or not G.vehicleState or not garage.inOwnCar(G, g) then return false end
  if S.pauseSaving or S.replacementSaving then return true, 'Saving vehicle damage. Please wait.' end
  if conditionAt or g.restoringDamage or g.pendingUsed or S.parts then
    return true, 'Wait for your car to finish loading or close the parts editor first.'
  end
  local pending = {car = g.car, id = G.playerId()}
  S.replacementSaving = pending
  local sent = require('cargoEarth/damage').captureFresh(G, g, function(ok)
    if S.replacementSaving ~= pending then return end
    S.replacementSaving = nil
    if S.career ~= c or S.pendingCareer or g.car ~= pending.car or G.playerId() ~= pending.id then return end
    if not ok then say('Vehicle damage could not be saved. Try the garage action again.', 8) return end
    if G.damage then garage.trackDamage(g, G.damage()) end
    if not saveCareer(true) then say('Career could not be saved. Try the garage action again.', 8) return end
    local completed, why = run()
    if not completed and why then say(why) end
  end)
  if not sent then
    S.replacementSaving = nil
    return true, 'Vehicle damage could not be saved. Try the garage action again.'
  end
  return true, 'Saving vehicle damage. Please wait.'
end

function M.garageStart(model, name)
  if S.career.employment then return false, 'End company work first.' end
  if S.career.garage.started then return false, 'Your career has already started.' end
  local saves = require('cargoEarth/saves')
  if saves.full(M.saveIndex()) then return false, 'You have ' .. saves.MAX .. ' careers. Delete one first.' end
  if S.job then M.cancel(true, true) end   -- a new career: orders from before go
  -- Free play keeps nothing: the career starts from a clean save with only the player's settings.
  local fresh = { money = 0, delivered = 0, km = 0, history = {}, garage = garage.new() }
  for _, k in ipairs(M.KEEP_ON_START) do fresh[k] = S.career[k] end
  local ok, msg = garage.start(M.G, fresh.garage, fresh, model or S.config.starterModel)
  if not ok then return garageSay(ok, msg) end
  S.phone.online, S.phone.incoming, S.phone.lastDone, S.phone.lastFailure = false, nil, nil, nil
  local money = fresh.money
  fresh.money = 0
  loadCareer(fresh)
  -- its own save slot, with the name the player gave it
  local slot = saves.create(M.saveIndex(), name, os.time(), M.fileThere)
  S.slot = slot.id
  M.writeIndex()
  economy.post(fresh, money, 'garage', economy.nextId(fresh, 'start'), 'Career start')
  usedAt, conditionAt = S.clock + 1, nil
  fresh.garage.car.fuel = { start = 0.5 }   -- the old starter car comes with half a tank
  return garageSay(ok, msg)
end
function M.garageSell(part) return garageSay(garage.sell(M.G, S.career.garage, S.career, part)) end
-- The cheapest workshop where the car is: the firm's at the headquarters, the home's at home.
function M.repairFactor(p)
  return math.min(firm.repairFactor(S.career, p), home.factorHere(S.career, 'workshop', p) or 1)
end
-- insure: false pays the whole bill yourself (no claim, the premium stays as it is); otherwise the insurer pays its part
function M.garageRepair(insure)
  -- the firm's workshop does the work for less at the headquarters: the discount counts before the money check
  local g = S.career.garage
  local full, factor = g.repair or 0, M.repairFactor(earth.pose())
  local ok, msg, cost, payout = garage.repairCar(M.G, g, S.career, factor, insure ~= false, S.career.activeSeconds or 0)
  if ok and factor < 1 then
    msg = string.format('Repaired in your workshop (-%d CZK, %d CZK saved%s)', cost, full - cost,
      (payout or 0) > 0 and string.format(', insurance paid %d CZK', payout) or '')
  end
  if ok then S.phone.wreck, S.insTow = nil, nil end   -- a paid repair ends the tow's bill guard (Codex)
  return garageSay(ok, msg)
end

------------------------------------------------------------------------------------------ insurance (cargoEarth/insurance)

-- The player's own garage (company work swaps the career's garage for the company's).
function M.insuranceGarage()
  local shift = S.career.employment
  return shift and shift.personalGarage or S.career.garage
end
function M.insuranceCars(g)
  local cars = {}
  if g.car then cars[1] = g.car end
  for _, car in ipairs(g.parked or {}) do cars[#cars + 1] = car end
  return cars
end

-- Every garage tick: speed and limit samples for judging a crash, a free tow's bill kept, the premiums due.
function M.insuranceTick(p)
  local insurance = require('cargoEarth/insurance')
  S.insHist = S.insHist or {}
  if p and not p.camera and p.speed then
    local lim = limitHere(p)
    insurance.sample(S.insHist, S.clock, p.speed * 3.6, lim and lim.kmh)
  end
  local trip = S.insTow
  if trip then
    local g = S.career.garage
    if S.clock > trip.untilT or g.car ~= trip.car then S.insTow = nil
    elseif (g.repair or 0) < trip.bill then
      -- the trip reset the car: it is not repaired for free, the bill stays owed
      local d = M.G.damage and M.G.damage() or 0
      g.damageBaseline, g.lastDamage = { damage = d, bill = trip.bill }, d
      g.carriedRepair = d == 0 and trip.bill or nil
      g.repair, g.car.insCover = trip.bill, trip.cover
    end
  end
end

-- The premiums due (every insured car, also parked ones and during company work), every few seconds.
function M.insuranceBill()
  local insurance = require('cargoEarth/insurance')
  if S.pendingCareer or S.clock < (S.insBillAt or 0) then return end
  S.insBillAt = S.clock + 10
  local c = S.career
  local g = M.insuranceGarage()
  if not g.started then return end
  local due, detail = insurance.bill(g, M.insuranceCars(g), c.activeSeconds or 0)
  if due > 0 then
    local paid = math.max(0, math.min(due, math.floor(c.money or 0)))
    if paid > 0 then economy.post(c, -paid, 'insurance', economy.nextId(c, 'insurance'), detail) end
    if paid < due then garage.addDebt(g, due - paid, 'insurance', detail) end
    S.dirtyAt = S.dirtyAt or (S.clock + 5)
  end
end

-- A crash added `grow` CZK of repairs to the car you drive: an insured car's cover grows by what the verdict allows.
function M.insuranceHit(g, grow)
  local insurance = require('cargoEarth/insurance')
  local car = g.car
  if not insurance.insured(car) or not insurance.eligible(car) then return end
  S.insSess = S.insSess or {}
  local v, fresh = insurance.verdict(S.insSess, S.insHist or {}, S.clock, S.lastFlashAt)
  insurance.hit(car, grow, v)
  if fresh and v.why then
    S.phone.insNote = { text = 'Insurance: ' .. v.why .. '.', untilT = S.clock + 12 }
    say('Insurance: ' .. v.why .. '.', 8)
  end
  if not car.insWreck and insurance.wrecked(car, g.repair, garage.repairCap(g)) then
    car.insWreck = true
    S.phone.wreck = { car = car.name }
    phoneSound('cancelled')
  end
end

-- The write-off window on the phone (nil when none is open).
function M.wreckInfo()
  local w = S.phone.wreck
  local c, g = S.career, S.career.garage
  if not w or not (g.car and g.car.insWreck) then S.phone.wreck = nil return nil end
  local payout, cost = garage.repairInsured(g, 1)
  return { car = w.car, bill = cost, payout = payout, own = cost - payout, home = c.home and c.home.name or nil,
    hq = c.firm and c.firm.hq and c.firm.hq.n or nil, msg = w.msg, company = c.employment ~= nil or nil }
end

-- The insurer's free tow of a write-off to the home garage or the headquarters (where: 'home' | 'hq').
function M.insuranceTow(where)
  local c, g = S.career, S.career.garage
  local car = g.car
  local insurance = require('cargoEarth/insurance')
  if c.employment then return false, 'End the company work first.' end
  if not (car and car.insWreck and insurance.insured(car)) then return false, 'Only an insured write-off is towed for free.' end
  if not garage.inOwnCar(M.G, g) then return false, 'Get in your car first.' end
  if trailers.id() then return false, 'Unhitch the trailer first: the tow takes only your car.' end
  local spot = (where == 'hq' and c.firm and c.firm.hq) or (where == 'home' and c.home) or nil
  if not spot or type(spot.g) ~= 'table' then
    return false, where == 'hq' and 'You have no headquarters.' or 'You have no home garage.'
  end
  local name = spot.n or spot.name or (where == 'hq' and 'Headquarters' or 'Home')
  -- the trip may reset the car in the game: the bill stays (M.insuranceTick), and the drop is not a free repair
  S.insTow = { car = car, bill = g.repair or 0, cover = car.insCover or 0, untilT = S.clock + 30 }
  g.fixUntil = garage.clock() + 30
  local ok, why = earth.teleport(spot.g[1], spot.g[2], name)
  if not ok then
    S.insTow, g.fixUntil = nil, nil
    return false, 'The tow could not start: ' .. tostring(why)
  end
  car.insWreck, S.phone.wreck = nil, nil
  return true, 'Your car is being towed to ' .. name .. ' for free. Repair it there.'
end

-- Garage actions: insure / uninsure (id: a parked car's id, nil: the car you drive), tow.
function M.insuranceDo(name, id, where)
  local insurance = require('cargoEarth/insurance')
  local c = S.career
  local g = M.insuranceGarage()
  if name == 'tow' then return M.insuranceTow(where or id) end
  local car = id and garage.parkedCar(g, tonumber(id)) or g.car
  if name == 'uninsure' then return insurance.cancel(g, car) end
  if name ~= 'insure' then return false, 'Unknown action' end
  if c.employment then return false, 'End the company work first.' end
  if car and car == g.car and not car.value then garage.noteValue(M.G, g) end
  local pose = earth.pose()
  local ctx = { own = car == g.car and garage.inOwnCar(M.G, g), speed = pose and pose.speed or 0,
    onJob = S.job ~= nil or #(S.orders or {}) > 0 }
  local ok, msg, day = insurance.buy(g, c, car, ctx, c.activeSeconds or 0)
  if ok and (day or 0) > 0 then
    economy.post(c, -day, 'insurance', economy.nextId(c, 'insurance'), 'Insurance: first day for ' .. tostring(car.name))
  end
  if ok then saveCareer() end
  return ok, msg
end

-- The Garage page's insurance card.
function M.insuranceState()
  local insurance = require('cargoEarth/insurance')
  local g = M.insuranceGarage()
  local own = not S.career.employment and g.car and not g.car.loaner
  local out = insurance.state(g, own and g.car or nil, M.insuranceCars(g))
  if out.car then
    local pose = earth.pose()
    out.car.why = not out.car.insured and insurance.buyBlock(g, g.car, { own = garage.inOwnCar(M.G, g),
      speed = pose and pose.speed or 0, onJob = S.job ~= nil or #(S.orders or {}) > 0 }) or nil
    out.car.wreck = g.car.insWreck or nil
  end
  local c = S.career
  out.home, out.hq = c.home and c.home.name or nil, c.firm and c.firm.hq and c.firm.hq.n or nil
  out.parked = {}
  for _, car in ipairs(g.parked or {}) do
    if insurance.insured(car) then
      out.parked[#out.parked + 1] = { id = car.fleetId, name = car.name, week = insurance.weekPremium(g, car) }
    end
  end
  return out
end
-- The phone header's Unstuck button: a free repair in place (garage.unstuck).
function M.unstuckInfo()
  local g = S.career and S.career.garage
  if not g or not g.started or not g.car then return nil end
  local pose = earth.pose()
  local why, left = garage.unstuckBlock(M.G, g, os.time(), pose and pose.speed, S.career.unstuckAt)
  return { can = why == nil, why = why, left = left }
end
function M.unstuckCar()
  local g, pose = S.career.garage, earth.pose()
  local ok, msg, saved = garage.unstuck(M.G, g, os.time(), pose and pose.speed, S.career.unstuckAt)
  -- the cooldown is the career's, not the garage's: company work swaps the garage (Codex)
  if ok then S.career.unstuckAt, S.insTow = g.unstuckAt, nil end
  -- in a company vehicle the waived damage no longer counts against the contract (Jan: undo the reputation penalty)
  if ok and S.career.employment then employment.forgive(S.career, saved or 0) end
  -- a bus's passengers get back the comfort the collision cost them
  if ok and S.job and S.job.bus and require('cargoEarth/bus').forgive(S.job) > 0 then
    msg = msg .. string.format('. Passenger comfort back to %d %%', require('cargoEarth/bus').comfort(S.job))
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
function M.garageBringCar(captured)
  if not captured then
    local waiting, why = M.captureOutgoing(function() return M.garageBringCar(true) end)
    if waiting then return false, why end
  end
  local g = S.career.garage
  if not g.started or not g.car then return false, 'No career car yet' end
  local ok, why = spawnCareerCar(g)
  if not ok then return garageSay(false, why) end
  return garageSay(true, 'Here is your ' .. g.car.name .. '.')
end
local function garageSwitchCar(id, captured)
  if S.job then return false, 'Finish your current orders before switching cars.' end
  if not captured then
    local waiting, why = M.captureOutgoing(function() return garageSwitchCar(id, true) end)
    if waiting then return false, why end
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
local function garageRefuel(amount, pct) local ok, msg = fuelRefuel(amount, pct) say(msg) return ok, msg end
local function garageFuelDelivery() local ok, msg = fuelDelivery() say(msg) return ok, msg end
local function garageFuelGps() return fuelGps() end
M.fuelGps = fuelGps   -- (the map's one-tap routes)
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
-- Where a service is possible now: at the headquarters or home (the workshop's share off) or at a fuel station.
local function serviceSpot()
  local p = earth.status() == 'ok' and earth.pose() or nil
  if firm.atHq(S.career, p) then return 'the headquarters', math.min(firm.value(S.career, 'workshop') or 1, home.factorHere(S.career, 'workshop', p) or 1) end
  local homeFactor = p and not p.camera and (p.speed or 0) <= M.STOP_SPEED and home.factorHere(S.career, 'workshop', p)
  if homeFactor then return 'your home workshop', homeFactor end
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
    if not where then return false, 'Drive to a fuel station, your home workshop or your headquarters for a service.' end
  end
  local ok, msg = upkeep.service(c, car, item and item ~= '' and { item } or nil, factor, where)
  if ok and car == g.car then M.reapplyFaults() end   -- serviced brakes stop as new again
  return garageSay(ok, msg)
end
-- Repair a worn component of the car you drive (an engine that misfires, a worn clutch and gearbox), where it is
-- serviced: a fuel station, your home workshop or your headquarters.
function M.garageFixFault(item)
  local g, c = S.career.garage, S.career
  local car = g.car
  if not car or car.loaner then return false, 'There is no car of yours to repair.' end
  if not garage.inOwnCar(M.G, g) then return false, 'Sit in your car first.' end
  local where, factor = serviceSpot()
  if not where then return false, 'Drive to a fuel station, your home workshop or your headquarters for the repair.' end
  local ok, msg = require('cargoEarth/faults').repair(c, car, item, factor, where)
  if ok then M.reapplyFaults() end
  return garageSay(ok, msg)
end
-- The car's condition and worn components again on the car you sit in (after a repair or a service).
function M.reapplyFaults()
  local g = S.career.garage
  if not g.car or not M.G.applyCondition or not garage.inOwnCar(M.G, g) then return end
  pcall(M.G.applyCondition, g.car.km or 0, g.car.condition or 1, require('cargoEarth/faults').native(g.car))
end
local function garageRepairParked(id)
  local c = S.career
  if not (c.firm and c.firm.hq) then return false, 'Parked vehicles are repaired at the headquarters.' end
  return garageSay(garage.repairParked(S.career.garage, c, tonumber(id), firm.value(c, 'workshop') or 1, c.activeSeconds or 0))
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
  -- A damaged car may change parts (player report, 2026-11-25): a config that breaks itself as it spawns (a Segra box
  -- truck with the cab aero kit still on) re-breaks after every repair, so requiring a repair first locked the car.
  -- The repair bill stays owed; the damage counter is frozen while the preview respawns the car (see buyParts).
  if blocked and not fromGame then return false, blocked end
  -- Native Apply may have already changed the live config when its hook arrives.
  -- Keep the last paid snapshot as the baseline, rather than accepting that preview for free.
  if not fromGame or not g.car or type(g.car.parts) ~= 'table' then
    if not garage.remember(G, g, vehicle) then return false, 'The career car configuration is unavailable.' end
  end
  if damage > (g.lastDamage or 0) then garage.trackDamage(g, damage) end
  S.partsRevision = (S.partsRevision or 0) + 1
  S.parts = { before = g.car.parts, id = vehicle.id, blocked = blocked, data = vehicle.data }
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
    return garage.partsQuote(M.G, S.career.garage.inventory, S.parts.before, v, S.career.garage.salvage,
      S.career.garage.car and S.career.garage.car.paidParts,
      S.career.garage.car and S.career.garage.car.salvageParts,
      S.career.garage.car and garage.ownShare(S.career.garage.car))
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

-- Did the preview respawn the car (BeamNG rebuilt it with the previewed parts)? Then it is physically new.
function M.partsRespawned(live)
  live = live or previewVehicle()
  return live ~= nil and S.parts.data ~= nil and live.data ~= S.parts.data
end

local function partsProblem(quote)
  local g = S.career.garage
  if quote.cost > 0 and (g.debt or 0) > 0 then return 'Pay off your debt before buying parts.' end
  if quote.cost > (S.career.money or 0) then return 'Not enough money for these parts.' end
end

local function openParts(captured)
  local g = S.career.garage
  if not garage.inOwnCar(M.G, g) then return false, 'Sit in your career car first.' end
  local opening = not S.parts
  -- A damaged car's latest physical state is saved first (Codex): the preview rebuilds the car mended, and Discard must
  -- bring back this damage, not an older snapshot (or none), or opening and discarding would be a free repair.
  if opening and not captured and ((g.repair or 0) > 0 or (M.G.damage and (M.G.damage() or 0) > 0)) then
    local busy, msg = M.captureOutgoing(function() return openParts(true) end)
    if busy then return false, msg end
  end
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
  local live = previewVehicle()
  why = partsProblem(quote)
  if why then return false, why end
  local c, g = S.career, S.career.garage
  local money, spent, inventory, config, parts, salvage, paid, fitted = c.money, g.spent, g.inventory, g.car.config, g.car.parts, g.salvage, g.car.paidParts, g.car.salvageParts
  local partsPaid = g.car.partsPaid
  if not garage.remember(M.G, g, live) then return false, 'Could not capture the new configuration.' end
  -- A preview that respawned the car is a new build of the new config (Jan, 2026-11-26): swapped parts come new, but
  -- no other part is mended. The saved damage goes back onto every part that stayed (the vehicle side matches nodes and
  -- beams by name and part), and the bill shrinks only by the damage that left with the swapped parts
  -- (car.partsRestore, settled when that restore completes). Like after a respawn, the bill is carried meanwhile.
  -- Part of the purchase, so the checkpoint below has it. A checkout with no respawn keeps its damage and its bill.
  local car = g.car
  local damageWas = { g.damageBaseline, g.carriedRepair, g.lastDamage, car.partsRestore }
  if M.partsRespawned(live) then
    if car.physicalDamage and (g.repair or 0) > 0 then
      car.partsRestore = { bill = g.repair, damage = math.max(1, g.lastDamage or 0) }
    end
    g.damageBaseline, g.carriedRepair, g.lastDamage, g.restoringDamage = nil, g.repair or 0, 0, nil
  end
  c.money, g.spent, g.inventory, g.salvage = (money or 0) - quote.cost, (spent or 0) + quote.cost, quote.inventory, quote.salvage
  g.car.paidParts, g.car.salvageParts = quote.paid, quote.fittedSalvage
  if (quote.invest or 0) ~= 0 then g.car.partsPaid = (partsPaid or 0) + quote.invest end
  economy.reconcile(c, 'parts', 'Parts fitted')
  if not saveCareer() then
    c.money, g.spent, g.inventory, g.car.config, g.car.parts, g.salvage, g.car.paidParts, g.car.salvageParts = money, spent, inventory, config, parts, salvage, paid, fitted
    g.car.partsPaid = partsPaid
    g.damageBaseline, g.carriedRepair, g.lastDamage, car.partsRestore = damageWas[1], damageWas[2], damageWas[3], damageWas[4]
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
      error = why, canBuy = quote ~= nil and not why, blocked = not not S.parts.blocked,
      owed = (g.repair or 0) > 0 and g.repair or nil }
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
    local list = require('cargoEarth/faults').state(g.car, factor)
    out.faults = #list > 0 and list or nil
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
  out.debtInfo = (g.debt or 0) > 0 and garage.debtInfo(g) or nil
  out.income = math.floor(garage.INCOME_PER_HOUR / 10 + 0.5) * 10   -- what an hour of deliveries pays
  out.repairHours = garage.hours(out.repair)
  local cap = garage.repairCap(g)
  out.repairCapped = cap ~= nil and out.repair > 0 and out.repair >= cap or nil
  if out.repair > 0 then
    -- what the repair costs here (workshop discount) and the part the insurance would pay
    local pays, cost = garage.repairInsured(g, M.repairFactor(earth.pose()))
    out.repairCost, out.repairInsured = cost, pays > 0 and pays or nil
  end
  if not S.career.employment then out.insurance = M.insuranceState() end
  if g.preview then
    local l = garage.findListing(g, g.preview.id)
    if l then
      local names = {}
      for i, m in ipairs(g.preview.ready and l.missing or {}) do names[i] = m.name end
      out.preview = { id = l.id, name = l.name, km = l.km, condition = l.condition, price = l.price,
        tradeIn = g.preview.tradeIn, keepCar = g.preview.keepCar, ready = g.preview.ready, error = g.preview.error,
        paint = g.preview.ready and l.finish and l.finish.name or nil, missing = names,
        faults = garage.listingFaults(l) }
    end
  end
  out.damage = g.lastDamage or 0
  if out.own then
    out.value = garage.carWorth(G, g)
    out.tradeIn = garage.tradeInQuote(G, g)
    out.sellPrice = out.tradeIn
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
  -- picture + numbers for each listing, read from the game's vehicle list (no spawn); a missing one stays nil
  for _, c in ipairs(cars) do c.info = M.G.carInfo and M.G.carInfo(c.model, c.key) or nil end
  local inCar = g.car and not g.car.loaner and garage.inOwnCar(M.G, g)
  local credit, gross = 0, 0
  if inCar then credit, gross = garage.tradeInQuote(M.G, g) end
  return { cars = cars, tradeIn = credit, tradeGross = gross, repair = g.repair or 0,
    money = S.career.money or 0, debt = g.debt or 0, kinds = M.vehicleKinds() }
end

-- What each kind of vehicle is and the work it gets (the used-car list's type, cargo and "?"). Follows the job rules:
-- parcel.TIERS, haul.tiers and the freight unlocks, so it stays right when they change.
function M.vehicleKinds()
  local state = haul.state(S.career)
  local function kg(n) return n >= 1000 and (string.format('%g', math.floor(n / 100 + 0.5) / 10) .. ' t') or (n .. ' kg') end
  local function fits(tier)
    local t = haul.tiers[tier]
    return string.format('Fits about %d parcels, up to %s', t.parcel, kg(t.kg))
  end
  local towJob = 'Tow jobs: one broken-down car on a car trailer (with a tow hitch)'
  local out, list = {}, {
    car = { fits('car'), { 'Food delivery', 'Taxi rides with usable passenger seats', towJob } },
    suv = { fits('suv'), { 'Food delivery', 'Taxi rides with usable passenger seats', 'Parts runs from parts suppliers to repair shops', towJob } },
    van = { fits('van'), { 'Food delivery', 'Taxi rides with usable passenger seats', 'Parcel routes from a depot to real addresses', 'Freight jobs between companies', towJob } },
    rigid = { fits('rigid'), { 'Business shipping between companies', towJob } },
    semi = { string.format('Pulls trailers, up to %s', kg(haul.tiers.semi.kg)),
      { 'Freight jobs with trailers', 'Fuel tanker runs to real fuel stations',
        'Tow jobs: two cars on a flatbed trailer' } },
  }
  for _, kind in ipairs(haul.KIND_ORDER) do
    local k = list[kind]
    local jobsOf = {}
    for _, job in ipairs(k[2]) do jobsOf[#jobsOf + 1] = job end
    local locked
    if kind == 'rigid' and state.unlocked == 'van' then
      locked = string.format('Freight unlocks after %d van freight jobs (%d done).', state.vanGoal, state.van)
    elseif kind == 'semi' and state.unlocked ~= 'semi' then
      locked = string.format('Freight unlocks after %d box truck freight jobs (%d done).', state.rigidGoal, state.rigid)
    end
    out[#out + 1] = { id = kind, name = haul.KIND_NAMES[kind], fits = k[1], jobs = jobsOf, locked = locked }
  end
  return out
end
function M.garageBuyListing(id, keepCar, captured)
  if S.job then return false, 'Finish the order first' end
  local g = S.career.garage
  local keeping = keepCar == true
  if g.preview then keeping = g.preview.keepCar == true end
  if keeping and home.count(g) >= firm.capacity(S.career) then
    return garageSay(false, S.career.firm and 'Every parking bay is taken. Build more bays, trade in a car or sell one first.'
      or 'Your garage is full. Trade in a car or sell one first.')
  end
  if keeping and not g.preview and not captured then
    local waiting, why = M.captureOutgoing(function() return M.garageBuyListing(id, keepCar, true) end)
    if waiting then return false, why end
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
function M.garagePreview(id, keepCar, captured)
  if S.job then return false, 'Finish the order first' end
  if not captured then
    local waiting, why = M.captureOutgoing(function() return M.garagePreview(id, keepCar, true) end)
    if waiting then return false, why end
  end
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
  local fuelAction = name == 'refuel' or name == 'refuelTo' or name == 'fuelDelivery' or name == 'fuelGps'
  if S.career.employment and name ~= 'bring' and not fuelAction then
    S.garageMsg = 'Company equipment is fixed. End company work in Places to use your garage.'
    return M.garageState()
  end
  local partsAction = name == 'openParts' or name == 'buyParts' or name == 'cancelParts'
  if S.parts and not partsAction then return M.garageState() end
  local fns = { start = M.garageStart, repair = function() return M.garageRepair(true) end,
    repairOwn = function() return M.garageRepair(false) end,
    insure = function(id) return garageSay(M.insuranceDo('insure', id)) end,
    uninsure = function(id) return garageSay(M.insuranceDo('uninsure', id)) end,
    tow = function(where) return garageSay(M.insuranceDo('tow', nil, where)) end, paydebt = M.garagePayDebt, sellCar = M.garageSellCar,
    buyListing = M.garageBuyListing, preview = M.garagePreview, back = M.garagePreviewEnd, bring = M.garageBringCar,
    switchCar = garageSwitchCar, hireDriver = garageHireDriver, releaseDriver = garageReleaseDriver,
    roadside = garageRoadside, service = garageService, fixFault = M.garageFixFault, repairParked = garageRepairParked,
    refuel = garageRefuel, refuelTo = function(pct) return garageRefuel(nil, pct) end,
    fuelDelivery = garageFuelDelivery, fuelGps = garageFuelGps,
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
      repairCost = owed > 0 and math.floor(owed * workshop / 5 + 0.5) * 5 - garage.parkedInsured(car, workshop) or nil,
      insured = require('cargoEarth/insurance').insured(car) or nil,
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
    fleet.restore(a, 'car')
    a.nets, a.can = {}, {}
    for tier in pairs(fleet.GROSS) do a.nets[tier], a.can[tier] = fleet.netFor(a, tier, factor), fleet.licensed(a, tier) end
    a.licenceNames, a.knowsName = fleet.licenceNames(a), a.knows and fleet.KINDS[a.knows] or nil
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
  -- tow trailers can be taken out at the headquarters and hitched to your own vehicle (M.hqDo takeTrailer)
  local pose = earth.status() == 'ok' and earth.pose() or nil
  local atHq = firm.atHq(c, pose)
  local v, tier = freightCarrier()
  local rig = v and garage.inOwnCar(M.G, g) and tow.class(tier, tow.hasHitch(v)) or nil
  local outId = trailers.ownOut() and S.ownTrailer or nil
  local hauled = 0
  for _, t in ipairs(firm.trailers(c)) do
    local towClass = (t.kind == 'cartrailer' and 'light') or (t.kind == 'smalltrailer' and 'small') or nil
    local busy = nil
    if not towClass then hauled = hauled + 1 busy = hauled <= semiDrivers or nil end
    if t.kind == 'flatbed' then towClass = 'heavy' end
    out.trailers[#out.trailers + 1] = { id = t.id, name = t.name, kind = t.kind, busy = busy,
      tow = towClass ~= nil or nil, out = outId == t.id or nil,
      canTake = towClass ~= nil and not busy and outId == nil and atHq and S.job == nil and tow.fits(rig, towClass) or nil,
      needs = towClass and not tow.fits(rig, towClass) and (towClass == 'heavy' and 'Needs a tractor' or 'Needs a tow hitch') or nil }
  end
  out.atHq = atHq or nil
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
  out.repair = { cost = g.repair or 0, factor = M.repairFactor(earth.pose()) }
  out.repair.insured = garage.repairInsured(g, out.repair.factor)
  out.debt, out.busy, out.company = g.debt or 0, S.job ~= nil, c.employment ~= nil
  return out
end

-- The firm's trailer taken out at the headquarters: once its hitch has latched (or given up), offers are made again.
function M.trailerOffersTick()
  if trailers.hitching() or trailers.latching() then return end
  S.trailerOffersWait = nil
  if not S.job then S.offeredAt = nil end
end

-- name: found (a = name), rename (a = name), setHq, gpsHq, upgrade (a = id). Returns the firm for the phone.
function M.firmDo(name, a)
  if S.pendingCareer then return M.firmState() end
  local c, p = S.career, earth.status() == 'ok' and earth.pose() or nil
  local debt = personalGarage().debt or 0
  local ok, msg = false, 'Unknown action'
  if name == 'found' and not personalGarage().started then ok, msg = false, 'A firm is part of the career. Start one on the phone first.'
  elseif name == 'found' then ok, msg = firm.found(c, a, debt)
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
    elseif name == 'takeTrailer' or name == 'leaveTrailer' then
      local c = S.career
      local ok, msg = false, 'Unknown action'
      local pose = earth.status() == 'ok' and earth.pose() or nil
      local t = nil
      for _, row in ipairs(firm.trailers(c)) do if row.id == tonumber(a) then t = row end end
      if S.job then ok, msg = false, 'Finish your current job first.'
      elseif not firm.atHq(c, pose) then ok, msg = false, 'Drive to your headquarters first.'
      elseif name == 'leaveTrailer' then
        trailers.putAwayOwn()
        S.ownTrailer, ok, msg = nil, true, 'Trailer left in the yard.'
      elseif not t then ok, msg = false, 'That trailer is not in the yard.'
      else
        local v, tier = freightCarrier()
        local towClass = (t.kind == 'cartrailer' and 'light') or (t.kind == 'smalltrailer' and 'small') or (t.kind == 'flatbed' and 'heavy') or nil
        if not towClass then ok, msg = false, 'Only tow trailers can be taken out.'
        elseif not (v and garage.inOwnCar(M.G, personalGarage()) and tow.fits(tow.class(tier, tow.hasHitch(v)), towClass)) then
          ok, msg = false, towClass == 'heavy' and 'The flatbed trailer needs a tractor.' or 'This trailer needs your own car with a tow hitch.'
        else
          ok, msg = trailers.takeOwn(t.kind)
          if ok then
            S.ownTrailer, msg = t.id, string.format('Putting your %s on the hitch. Tow jobs now skip borrowing one.', t.name:lower())
            -- offers are made again with your trailer once it is on the hitch (M.trailerOffersTick); until then
            -- none are shown, so no offer still asks to borrow one
            S.offers, S.offerStats, S.offeredAt, S.phone.incoming = {}, nil, { lat = 0, lon = 0 }, nil
            S.trailerOffersWait = true
          else msg = 'Could not get the trailer out: ' .. tostring(msg) end
        end
      end
      S.firmMsg = msg
      if ok then say(msg) end
    elseif name == 'buyVehicle' or name == 'buyTrailer' or name == 'sellTrailer' then
      local c, g = S.career, personalGarage()
      local ok, msg = false, 'Unknown action'
      if c.employment then ok, msg = false, 'End company work first.'
      elseif not (c.firm and c.firm.hq) then ok, msg = false, 'Choose the headquarters first.'
      elseif name == 'buyTrailer' then ok, msg = firm.buyTrailer(c, a, g.debt)
      elseif name == 'sellTrailer' then
        ok, msg = firm.sellTrailer(c, tonumber(a))
        if ok and S.ownTrailer == tonumber(a) then trailers.putAwayOwn() S.ownTrailer = nil end
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

local aboutHelper   -- (the support report, below)

function M.settingsState()
  local id = M.settingsJobType()
  local profile, opts = M.jobSettings.type(id), M.jobOptions(id)
  local bounds = M.jobSettings.bounds(id)
  local out = { mode = S.mode, jobType = id, jobTypes = M.jobSettings.types, careerEpoch = S.careerEpoch or 0,
    canSwitch = S.job == nil and not S.career.employment, canPause = S.career.savedAt ~= nil and S.career.garage.started == true, window = S.window,
    savingDamage = S.pauseSaving ~= nil, reviewingParts = S.parts ~= nil, paused = S.pendingCareer ~= nil, dark = M.uiPrefs().dark or false, items = {},
    canRestart = S.pendingCareer ~= nil or S.career.garage.started == true or nil, restartWord = M.RESTART_WORD }
  local labels = M.jobSettings.labels(id)
  for _, key in ipairs({'nearKm', 'minKm', 'maxKm'}) do
    if bounds[key] then
      out.items[#out.items + 1] = {key = key, label = labels[key], step = 0.5, min = bounds[key][1], max = bounds[key][2], unit = 'km', value = opts[key]}
    end
  end
  if id == 'courier' then
    out.items[#out.items + 1] = {key = 'maxOrders', label = 'Orders at once', step = 1, min = 1, max = 3, unit = '',
      value = S.optsByMode.courier.maxOrders or food.defaults.maxOrders}
  end
  -- one or two short lines: the holder phone has little room
  out.jobHint = id == 'bus' and 'Bus lines keep their mapped stops and length. Choose a line on Work.'
    or profile.company and 'Distance per delivery; the drives back come on top. Applies to new contracts.'
    or id:find('tow_', 1, true) == 1 and 'Distance with the car loaded. A borrowed trailer adds an empty drive.'
    or id == 'parcels' and 'Length of the whole round. The number of stops stays the same.'
    or id == 'coach' and 'Road km to the far town. Rides go to towns of 30,000 people or more, from the coach station nearest you.'
    or 'Applies to new offers.'
  if id ~= 'bus' and id ~= 'coach' then
    out.jobHint = out.jobHint .. ((profile.tier and id ~= 'parcels')
      and ' Over 120 km, jobs go to real towns; truck access there is not checked.'
      or ' A wider range only finds places already loaded around you.')
  end
  out.dash = dash.state(M.G.vehicle and M.G.vehicle() or nil)
  out.dash.error = S.dashError
  out.dash.moving = M.dashMoving()
  aboutHelper()
  out.update = M.updateInfo() or { mod = M.VERSION, unknown = true }
  out.cameras = { on = not M.CAMERAS_PAUSED and not S.career.camerasOff, paused = M.CAMERAS_PAUSED, known = #cams.list,
    helper = cams.state or (helper.status().cameras == 'off' and 'off' or nil) }
  if id == 'courier' then
    out.autoReach = S.optsByMode.courier.autoReach
    if out.autoReach == nil then out.autoReach = food.defaults.autoReach end
  end
  return out
end

-- name: mode (a = courier | trucking | taxi | bus), step (a = key, b = +1 | -1), autoReach (a = true | false), reset, window,
-- dark (a = true | false), restart (a = the confirm word, see restartCareer), dash (a = on | off | middle | wheel | x+ | x- | y+ | y- | z+ | z- | reset | measure: the phone on the dashboard, see dashDo)
function M.settingsDo(name, a, b)
  -- the dash phone is the player's own choice, outside the career: it works on the resume screen too
  if name == 'dash' then
    local ok, why = M.dashDo(a)
    S.dashError = not ok and why or nil
    return M.settingsState()
  end
  -- dark mode belongs to the player too, not the save
  if name == 'dark' then
    M.setDark(a)
    return M.settingsState()
  end
  -- restart (a = the word the player typed): works on the resume screen too, where it drops the saved career
  if name == 'restart' then
    local ok, why = M.restartCareer(a)
    local out = M.settingsState()
    out.restartError = not ok and why or nil
    out.restartWarning = ok and why or nil
    out.restarted = ok or nil
    return out
  end
  if S.pendingCareer then return M.settingsState() end
  if S.parts then return M.settingsState() end
  if name == 'pause' then
    pauseCareer()
    return M.settingsState()
  end
  if name == 'jobType' then
    if M.jobSettings.type(a) then S.settingsJobType = a end
    return M.settingsState()
  end
  if name == 'jobRange' or name == 'resetJobRange' then
    local ok, why
    if name == 'jobRange' then ok, why = M.jobSettings.set(S.optsByMode, a, b)
    else ok = M.jobSettings.reset(S.optsByMode, a) end
    if ok then
      S.companyBoard, S.companyBoardDirty, S.offeredAt = nil, true, nil
      saveCareer()
    end
    local out = M.settingsState()
    out.rangeSaved, out.rangeReset, out.rangeError = ok and name == 'jobRange', ok and name == 'resetJobRange', not ok and (why or 'Choose a generated job type.') or nil
    out.rangeChanged = a
    return out
  end
  if name == 'mode' then M.setMode(a)
  elseif name == 'step' then
    for _, item in ipairs(M.settingsState().items) do
      if item.key == a then
        local v = item.value + item.step * (tonumber(b) or 0)
        local value = math.max(item.min, math.min(item.max, math.floor(v / item.step + 0.5) * item.step))
        if a == 'maxOrders' then S.optsByMode.courier.maxOrders = value
        elseif S.settingsJobType then
          local range = M.jobOptions(S.settingsJobType)
          range[a] = value
          M.jobSettings.set(S.optsByMode, S.settingsJobType, range)
        else M.setOption(a, value) end
      end
    end
  elseif name == 'autoReach' then S.optsByMode.courier.autoReach = a and true or false
  elseif name == 'cameras' then
    if M.CAMERAS_PAUSED and a then return M.settingsState() end
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
M.UPDATE_ASK_S = 900       -- then this often (the helper asks GitHub at start and every 2 hours)
M.UPDATE_RETRY_S = 300     -- the helper did not answer: ask again after this long
M.UPDATE_LOAD_WAIT_S = 8   -- after a save loads: the helper asks GitHub, its answer is read this long after
M.UPDATE_PENDING_S = 5     -- the helper still waits for GitHub (update.checking): read again after this long
M.UPDATE_PENDING_TRIES = 6 -- at most this many times (GitHub's own timeout is 20 s)
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
  local behind = M.helperBehind()
  if behind and updateSaid ~= 'helper ' .. behind then
    updateSaid = 'helper ' .. behind
    say(string.format('BeamNG.Earth still runs the Cargo Earth helper %s. Open its Add-ons page and press Update on '
      .. 'Cargo Earth helper.', behind), 12)
  end
end

-- The helper's version when it is older than this mod (BeamNG.Earth keeps running the copy it installed until Update
-- is pressed on its Add-ons page, even after the installer put a newer file in place), else nil.
function M.helperBehind()
  local v = helperAbout and helperAbout.version
  if type(v) ~= 'string' or not v:match('^%d+%.%d+%.%d+$') then return nil end
  return M.versionNewer(M.VERSION, v) and v or nil
end

aboutHelper = function()
  if not helper.enabled or S.clock - helperAboutAt < M.HELPER_ABOUT_S then return end
  helperAboutAt = S.clock
  helper.ask('/v1/info', onAbout)
end

-- From the helper tick: ask for the newest release now and then.
askUpdate = function()
  if not helper.enabled then return end
  if M.updateOnLoad then
    -- a save was loaded: the helper asks GitHub again (it skips that when it asked in the last 5 minutes)
    M.updateOnLoad = nil
    helper.ask('/v1/update/check', function() end)
    updateAskAt, M.updatePendingLeft = S.clock + M.UPDATE_LOAD_WAIT_S, M.UPDATE_PENDING_TRIES
    return
  end
  updateAskAt = updateAskAt or S.clock + M.UPDATE_FIRST_S
  if S.clock < updateAskAt then return end
  updateAskAt = S.clock + M.UPDATE_ASK_S
  helperAboutAt = S.clock
  helper.ask('/v1/info', function(data, err)
    if not data then updateAskAt = S.clock + M.UPDATE_RETRY_S
    elseif type(data.update) == 'table' and data.update.checking == true and (M.updatePendingLeft or 0) > 0 then
      -- a slow GitHub answer is still on its way: read it again soon, not in a quarter of an hour
      M.updatePendingLeft, updateAskAt = M.updatePendingLeft - 1, S.clock + M.UPDATE_PENDING_S
    else M.updatePendingLeft = nil end
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
    -- Only a car physically present off the deck incurs the recovery fee.
    if S.phase ~= 'toDelivery' then return end
    if (p.speed or 0) > M.STOP_SPEED then say('Stop before loading the cars again.') return end
    local fee = towRecoveryFee(j)
    if fee == nil then return end
    if fee > 0 and (S.career.money or 0) < fee then say('Not enough money to load the cars again.') return end
    if trailers.id() then
      local ok, why = trailers.recoverTowed(j.tow.cars, tow.wreckPlan(j))
      if not ok then say(why) return end
      if fee > 0 then economy.post(S.career, -fee, 'cancel_fee', economy.nextId(S.career, 'cancel_fee'), 'Tow: loading the cars again') end
      say(string.format('The cars are back on your trailer (%d CZK).', fee))
    else
      local before = j.tow.damage0 and math.max(0, trailers.towedDamage() - j.tow.damage0) or 0
      local ok, why = trailers.spawnTow(tow.CLASSES[j.tow.class].trailer, j.tow.cars, tow.wreckPlan(j))
      if not ok then say('The cars could not be loaded: ' .. tostring(why)) return end
      j.tow.damageDone = (j.tow.damageDone or 0) + before
      j.tow.spawnedAt, j.tow.damage0 = S.clock, nil
      say('Tow trailer restored for free. Couple it again.')
    end
    j.trailerSpawned, j.tow.onBoard = true, #j.tow.cars
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

-- The profile the jobs window's distance sliders change: the one new offers in this mode use.
function M.windowJobType()
  if S.mode ~= 'trucking' then return M.jobSettings.type(S.mode) and S.mode or nil end
  local tier = freightSettingsTier()
  return tier == 'car' and 'tow_light' or tier == 'suv' and 'parts' or 'freight_' .. tier
end

-- Distances go to the job type's own profile (the one generators read), so the old window and the phone agree.
-- (M. field: the main chunk is at Lua's 200-local limit)
function M.setRange(k, v)
  local id = M.windowJobType()
  local n, bounds = tonumber(v), id and M.jobSettings.bounds(id)
  if not (n and bounds and bounds[k]) then return false end
  local range = M.jobOptions(id)
  range[k] = math.max(bounds[k][1], math.min(bounds[k][2], n))
  -- moving one end past the other drags the other along
  if k == 'minKm' and range.minKm > range.maxKm then range.maxKm = range.minKm end
  if k == 'maxKm' and range.maxKm < range.minKm then range.minKm = range.maxKm end
  if not M.jobSettings.set(S.optsByMode, id, range) then return false end
  S.companyBoard, S.companyBoardDirty = nil, true
  return true
end

function M.setOption(k, v)
  if (k == 'nearKm' or k == 'minKm' or k == 'maxKm') and M.setRange(k, v) then return end
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
-- The phone's page (Work or Radio), the same on both phones: each one shows what the other chose last.
function M.phoneTab(t)
  if t == 'orders' or t == 'radio' or t == 'map' then S.phoneTab = t end
  return S.phoneTab or 'orders'
end
-- The phone's live map (Map tab), asked 4 times a second while it shows: the car, the GPS route and the job's stops
-- in game metres (x east, y north), and the roads round the car when they changed. have: the roads key the phone
-- already has (the roads are sent again only on another tile, another graph or after BeamNG.Earth moved the world).
--   { car = { x, y, h (degrees clockwise from north), kmh }, roadsKey, roads = { x1, y1, x2, y2, kind, ... },
--     route = { x, y, ..., false, ... }, routeGps, stops = { { x, y, k = 'next'|'pickup'|'drop'|'stop'|'home'|'hq', n } } }
-- geo (the OSM map, drawn by the phone from OpenFreeMap tiles the helper passes on): no roads; the car, the route
-- (routeLL = { lat, lon, ... }) and the stops come with lat / lon too, and tiles = 'game' when the map can get tiles.
-- The game shows lengths in miles (Options > Display > Units)
function M.imperial()
  local st = rawget(_G, 'settings')
  local ok, v = pcall(function() return st and st.getValue and st.getValue('uiUnitLength') end)
  return ok and v == 'imperial'
end
M.MAP_ON_ROUTE_M = 40   -- the car this close to the GPS line is on it (farther: the GPS is about to plan again)

-- One OSM map tile for the phone (see cargoEarth/osmtiles): the game asks the helper, the phone polls this.
function M.osmTile(z, x, y)
  return require('cargoEarth/osmtiles').get(helper, z, x, y, S.clock)
end

function M.phoneMap(have, perf, geo, whole)
  local pm = require('cargoEarth/phonemap')
  local t0 = os.clock and os.clock()
  local p = earth.pose()
  if not (p and p.x and p.y) then return { status = earth.status() } end
  local out = { status = 'ok', car = { x = r1(p.x), y = r1(p.y), h = r1(p.heading or 0), kmh = math.floor((p.speed or 0) * 3.6 + 0.5) } }
  local frame = tostring(p.anchorLat or '') .. ',' .. tostring(p.anchorLon or '')
  local function r6(v) return math.floor(v * 1e6 + 0.5) / 1e6 end
  if geo and p.lat and p.lon then out.car.lat, out.car.lon = r6(p.lat), r6(p.lon) end
  -- the OSM map's tiles come through the helper (the game's UI cannot load from the web)
  if geo and helper.enabled then out.tiles = 'game' end   -- tiles come through the game (osmTile), not straight from the helper
  local graph = not geo and M.G.graph and M.G.graph()
  if graph then
    local tx, ty, cx, cy = pm.tile(p.x, p.y)
    -- the road index is sorted a few milliseconds per ask, never all at once (a big graph would stall a frame)
    pm.grid(graph, S.clock, pm.SLICE_MS)
    local key = table.concat({ tx, ty, frame, pm.stamp or 0 }, ':')
    out.roadsKey = key
    if key ~= have then out.roads = pm.roads(graph, cx, cy, pm.RADIUS, S.clock, pm.SLICE_MS) end
  end
  local function xy(g)
    if type(g) ~= 'table' or not g[1] then return nil end
    local x, y = earth.worldXY(p, g)
    if x then return math.floor(x + 0.5), math.floor(y + 0.5) end
  end
  -- the GPS route as BeamNG.Earth plans it (1.6+); else a straight line to the next stop
  -- any GPS route counts (home, the workshop, a company yard too), not only the job's
  local d = target()
  local rt = earth.route()
  -- Earth hands out a copy of the whole route: asked only for a new route version or after the world moved
  local routeKey = rt and rt.routeVersion and (tostring(rt.routeVersion) .. '@' .. frame)
  local pts = routeKey and pm.routeCached(routeKey)
  if routeKey and not pts then
    local geo = earth.routeGeometry and earth.routeGeometry()
    if geo then
      pts = pm.routeXY(routeKey, geo.points, function(q) return earth.worldXY(p, q) end)
      pts.steps, pts.dist = geo.steps, tonumber(geo.dist)
    end
  end
  if pts then
    -- only the way still ahead of the car; facing against it while moving: the route is behind you
    local ahead, where = pm.ahead(pts, p.x, p.y, p.heading, routeKey)
    out.route, out.routeGps = pm.clip(ahead, p.x, p.y), true
    if geo then out.routeLL = pm.geoRoute(ahead) end
    -- the whole-route view: all of the way ahead, a few hundred points
    if whole then out.whole = pm.outline(ahead) end
    if where then
      -- the next turn: Earth's steps count metres along its full route, ours is the simplified line (a bit shorter)
      local travelled = where.along * ((pts.dist and where.length > 0) and pts.dist / where.length or 1)
      out.turn = pm.nextTurn(pts.steps, travelled)
      out.offM = math.floor(where.off + 0.5)
      out.behind = where.back and where.off <= M.MAP_ON_ROUTE_M and (p.speed or 0) > M.STOP_SPEED or nil
    end
  end
  local stops = {}
  local function add(g, k, n)
    local x, y = xy(g)
    if x then
      stops[#stops + 1] = { x = x, y = y, k = k, n = n }
      if geo then stops[#stops].lat, stops[#stops].lon = r6(g[1]), r6(g[2]) end
    end
  end
  local c = S.career
  if c.home and c.home.g then add(c.home.g, 'home', 'Home') end
  local hq = c.firm and c.firm.hq
  if hq and hq.g then add(hq.g, 'hq', hq.n or 'Headquarters') end
  if S.job then
    for _, o in ipairs(S.orders) do
      local oj = o.job
      if oj ~= S.job then
        local dest = o.phase == 'toPickup' and oj.from or oj.to
        if dest then add(dest.g, o.phase == 'toPickup' and 'pickup' or 'drop', dest.n) end
      end
    end
    local r = S.job.route
    if r and type(r.stops) == 'table' then
      -- on the way to the depot every address is still ahead; later the current one is the next stop
      local first = S.phase == 'toPickup' and (r.at or 1) or (r.at or 1) + 1
      for i = first, #r.stops do add(r.stops[i].g, 'stop', tostring(i)) end
    end
    if d then
      add(d.g, 'next', d.n)
      local last = stops[#stops]
      if last and last.k == 'next' then
        last.pickup = S.phase == 'toPickup' or nil
        if not out.route then
          local cx, cy = math.floor(p.x + 0.5), math.floor(p.y + 0.5)
          out.route = { cx, cy, last.x, last.y }
          if geo and out.car.lat then out.routeLL = { out.car.lat, out.car.lon, last.lat, last.lon } end
        end
      end
    end
  end
  out.stops = stops
  -- the map's own routes (Home, HQ, fuel) while no work steers the GPS
  if not S.job and not c.employment and not S.pendingCareer then
    out.go = { home = (c.home and c.home.g) and true or nil, hq = (hq and hq.g) and true or nil }
  end
  -- speed cameras within 2 km (the ones the fines watch): where, and their limit in km/h (assumed: a class default)
  if camerasOn() and cams.near and #cams.near > 0 then
    local list = {}
    for _, cam in ipairs(cams.near) do
      local x, y = xy({ cam.lat, cam.lon })
      if x then
        local row = { x = x, y = y, limit = cam.limit, assumed = cam.assumed or nil }
        if geo then row.lat, row.lon = r6(cam.lat), r6(cam.lon) end
        list[#list + 1] = row
      end
    end
    if #list > 0 then out.cams = list end
  end
  -- the way left to the next stop (Earth's GPS: metres, seconds) and the game's units (Options > Display)
  if rt and type(rt.remaining) == 'number' then
    out.leftM = math.floor(rt.remaining + 0.5)
    out.leftS = type(rt.eta) == 'number' and math.floor(rt.eta + 0.5) or nil
  end
  out.imperial = M.imperial() or nil
  -- the timing readout (tap the north dial): what this ask cost and what the road index cost when last sorted
  if perf then
    local f = pm.perf
    local function ms(v) return math.floor((v or 0) * 100 + 0.5) / 100 end
    out.perf = { luaMs = t0 and ms((os.clock() - t0) * 1000) or 0, buildMs = ms(f.buildMs), sliceMaxMs = ms(f.sliceMaxMs),
      slices = f.slices, edges = f.edges, roadsMs = ms(f.roadsMs), building = f.building or nil }
  end
  return out
end

-- One-tap routes from the phone's map: home, the firm's headquarters, the nearest fuel station, or no route at all.
-- Not while a job or a company shift steers the GPS. Returns { ok, msg }.
function M.mapGo(where)
  local c = S.career
  if S.pendingCareer then return { ok = false, msg = 'Start or resume your career first.' } end
  if S.job or c.employment then return { ok = false, msg = 'The GPS follows your work now.' } end
  if earth.status() ~= 'ok' then return { ok = false, msg = tostring(earth.status()) } end
  local ok, msg
  if where == 'home' then
    if not (c.home and c.home.g) then return { ok = false, msg = 'You have no home yet. Set one in the Menu, under Places.' } end
    ok, msg = earth.gps(c.home.g[1], c.home.g[2], c.home.name or 'Home')
    if ok then msg = 'Route set home.' end
  elseif where == 'hq' then
    local hq = c.firm and c.firm.hq
    if not (hq and hq.g) then return { ok = false, msg = 'Your firm has no headquarters yet.' } end
    ok, msg = earth.gps(hq.g[1], hq.g[2], c.firm.name or hq.n or 'Headquarters')
    if ok then msg = 'Route set to your headquarters.' end
  elseif where == 'fuel' then
    if not (c.garage and c.garage.car) then return { ok = false, msg = 'The fuel finder needs your career car.' } end
    return (function(a, b) return { ok = a == true, msg = b } end)(M.fuelGps())
  elseif where == 'clear' then
    earth.gpsClear()
    ok, msg = true, 'Route cleared.'
  else
    return { ok = false, msg = 'Unknown place.' }
  end
  if not ok then msg = 'GPS not set: ' .. tostring(msg or 'BeamNG.Earth did not answer') end
  return { ok = ok == true, msg = msg }
end

-- The floating phone folded or open. The game rebuilds UI apps when the camera changes or the pause menu opens, so
-- the phone asks here on its first answer. Folded keeps the screen it was folded on: a new ring still opens it.
function M.phoneFold(on, screen)
  S.phoneFold = on and (type(screen) == 'string' and screen or '') or nil
  return S.phoneFold or false
end

-- The player's look settings, outside any career (they work before a save loads): { dark = true | nil,
-- quiet = true | nil (no chime when driving over the limit) }
M.UI_FILE = '/settings/cargoEarth/ui.json'
M.uiStore = {
  read = function() return jsonReadFile and jsonReadFile(M.UI_FILE) or nil end,
  write = function(t) if jsonWriteFile then jsonWriteFile(M.UI_FILE, t, true) end end,
}
-- The map's own switches (its ⚙ panel): what it shows. Only true / false, only these names.
M.MAP_PREFS = { streets = true, water = true, food = true, shop = true, fuel = true, health = true, other = false,
  buildings = true, north = false, autoZoom = false, lanes = true, speedo = true, latin = false, numbers = true,
  oneway = true, cams = true }
function M.mapPrefsOf(t)
  local out = {}
  for k, def in pairs(M.MAP_PREFS) do
    local v
    if type(t) == 'table' then v = t[k] end
    if type(v) == 'boolean' then out[k] = v else out[k] = def end
  end
  return out
end
function M.uiPrefs()
  if not S.ui then
    local ok, t = pcall(M.uiStore.read)
    S.ui = { dark = ok and type(t) == 'table' and t.dark == true or nil, quiet = ok and type(t) == 'table' and t.quiet == true or nil,
      map = M.mapPrefsOf(ok and type(t) == 'table' and t.map) }
  end
  if not S.ui.map then S.ui.map = M.mapPrefsOf(nil) end
  return S.ui
end
function M.writeUi(u) pcall(M.uiStore.write, { v = 1, dark = u.dark or false, quiet = u.quiet or false, map = u.map }) end
function M.mapPrefs() return M.uiPrefs().map end
-- One of the map's switches; returns all of them
function M.setMapPref(key, on)
  local u = M.uiPrefs()
  if M.MAP_PREFS[key] ~= nil then
    u.map[key] = on == true
    M.writeUi(u)
  end
  return u.map
end
function M.setDark(on)
  local u = M.uiPrefs()
  u.dark = on and true or nil
  M.writeUi(u)
end
-- The speeding chime on or off (tap the map's speedometer); returns whether it is quiet now
function M.setQuiet(on)
  local u = M.uiPrefs()
  u.quiet = on and true or nil
  M.writeUi(u)
  return u.quiet or false
end

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
  -- the last played career waits on the resume screen (with the others to pick from); none: the first-run choice
  local saves = require('cargoEarth/saves')
  local idx = M.saveIndex()
  if not (idx.last and M.pendSave(idx.last)) then
    local free = S.freeSave or persistence.load(jsonReadFile, saves.FREE)
    if type(free) == 'table' then M.freshFree(free) end
  end
  S.freeSave = nil
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
  -- before a saved career is loaded only Settings has anything to show
  if S.pendingCareer and panel ~= 'toggle' then panel, view = 'settings', nil end
  local now = M.now()
  local function alive(kind) return menuHosts[kind] ~= nil and now - menuHosts[kind] <= 6 end
  local to = alive('menu') and 'menu' or (alive('phone') and 'phone' or nil)
  if not to then return false end
  guihooks.trigger('CargoEarthOpenMenu', { panel = panel, view = type(view) == 'string' and view or nil, to = to })
  return true
end

-- a labelled button beside the dash phone (cargoEarth/dash.lua M.BUTTONS)
function M.dashButton(name)
  if name == 'online' then
    return M.phoneAction(S.phone and S.phone.online and 'offline' or 'online')
  elseif name == 'accept' or name == 'decline' or name == 'gps' then
    return M.phoneAction(name)
  end
end

-- a car's phone holder has started its screen
function M.dashPhonePart(vehId)
  log('I', 'cargoEarth', 'dash phone holder running in car ' .. tostring(vehId))
  dash.partCar(tonumber(vehId))
end

-- The dash phone asks the same few questions over and over (its state twice a second): each is compiled once.
local dashChunks, dashChunkCount = {}, 0
local function dashChunk(cmd)
  local fn = dashChunks[cmd]
  if fn then return fn end
  fn = (loadstring or load)('return ' .. cmd)
  if not fn then return nil end
  -- actions carry their arguments, so their texts vary: keep the cache small
  if dashChunkCount >= 64 then dashChunks, dashChunkCount = {}, 0 end
  dashChunks[cmd], dashChunkCount = fn, dashChunkCount + 1
  return fn
end

function M.dashCall(vehId, id, cmd)
  local veh = getObjectByID and getObjectByID(tonumber(vehId) or -1)
  if not veh or not M.dashAllowed(cmd) then return end
  local fn = dashChunk(cmd)
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
local dashClock, dashCheckAt, dashTried, dashReloaded = 0, nil, {}, {}
local dashMeasureNext = {} -- car id -> true: reloaded to be measured, so measure it once it is back
local dashPending -- a change from Settings the car was too busy for: { rebuild } (done once the car is free)
-- M.dashWhereBack: the phone was just moved (middle / wheel): where it stood before, until the car is back with it there
-- M.dashStale: car id -> true for other cars that still carry the phone where it stood before a move; each is rebuilt
-- when the player gets into it
M.dashStale = {}
-- the car could not be respawned for a move: the setting goes back to where the phone still is
function M.dashGoBack()
  if M.dashWhereBack then dash.setWhere(M.dashWhereBack) M.dashWhereBack = nil end
end
M.DASH_CHECK_S, M.DASH_RETRY_S = 1.5, 20

local function dashMeasure(v)
  local vdata = type(v.data) == 'table' and v.data.vdata or nil
  local eye, camNode = dash.eyeOf(vdata)
  -- the nodes with all their groups, as the car loaded; the loaded car only keeps each node's first group
  local camName = camNode ~= nil and type(vdata) == 'table' and type(vdata.nodes) == 'table' and vdata.nodes[camNode]
  camName = type(camName) == 'table' and camName.name or nil
  local nodes = dash.loadedNodes(v.id, v.model, camName)
  local spot, why = dash.findSpot(nodes or dash.nodesOf(vdata, camNode), eye, dash.where())
  if spot then
    dash.setSpot(v.model, spot)
    log('I', 'cargoEarth', string.format('dash phone: %s measured, phone at %.3f %.3f %.3f on group %s', v.model,
      spot.centre.x, spot.centre.y, spot.centre.z, spot.group))
  else
    log('W', 'cargoEarth', 'dash phone: ' .. tostring(why) .. ' (' .. tostring(v.model) .. (nodes and '' or ', not seen loading') .. ')')
  end
  return spot, why, nodes ~= nil
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
  local reload -- the car is reloaded once, unchanged, so it can be measured as it loads (with all its node groups)
  local measured
  if on and (opts.measure or dashMeasureNext[v.id] or not dash.spot(v.model)) then
    local spot, why, seenLoading = dashMeasure(v)
    if not spot then
      if seenLoading or dashReloaded[v.id] then
        dashMeasureNext[v.id] = nil
        -- moved to a place this car has no dash for: it goes back where it was, once the car is free
        if M.dashWhereBack then
          dash.setWhere(M.dashWhereBack)
          M.dashWhereBack = nil
          dashPending = { rebuild = true, why = why } -- the reason stays shown after the phone is back
          M.dashCheckSoon()
        end
        return false, why
      end
      reload = true
    else
      measured = true
      dashReloaded[v.id], dashMeasureNext[v.id] = nil, nil
    end
  end
  if not reload and not measured and not opts.rebuild and dash.treeHasPhone(tree) == (on and true or false) then return true end
  -- a respawn mends the car: never on a damaged career car (it would be repaired for free, and its bill turned into
  -- debt)
  local g = type(S.career) == 'table' and S.career.garage or nil
  local owned = type(g) == 'table' and g.started and G.isOwned and G.isOwned(v)
  if owned then
    local damage = (G.damage and G.damage(v.id)) or 0
    if (g.repair or 0) > 0 or damage * garage.REPAIR_PER_DAMAGE >= 2.5 then
      M.dashGoBack()
      return false, 'Repair the car first: reloading it for the phone would mend it.'
    end
  end
  if dashBusy() then return false, 'The car is busy: the phone follows as soon as it is free.', 'busy' end
  if reload then dashReloaded[v.id], dashMeasureNext[v.id] = true, true else dashTried[v.id] = dashClock end
  local ok, err = pcall(G.respawnPlayer, function(config) if not reload then dash.setTreePhone(config.partsTree, on) end end)
  if not ok then
    log('W', 'cargoEarth', 'dash phone: ' .. tostring(err))
    M.dashGoBack()
    return false, 'BeamNG could not respawn this car.'
  end
  -- the respawn brings the car back new: its mileage and paint wear go back on, as after buying parts
  if owned and g.car then conditionAt = S.clock + 3 end
  -- a move of the phone is done once the car is back with it (not while it is only reloaded to be measured)
  if not reload then M.dashWhereBack, M.dashStale[v.id] = nil, nil end
  return true
end

-- Settings > Phone on the dashboard. a: on | off | reset | measure | middle | wheel (where it stands), or a nudge: x+ / x- (left / right as the driver
-- sees it), y+ / y- (closer / further), z+ / z- (up / down). Nudges are kept per car model.
local dashDoInner
-- Moving the phone reloads the car, so presses that come close together are applied with one reload, once they stop.
M.DASH_MOVE_S = 1.5
local function dashMoveSoon()
  dashPending = { rebuild = true }
  dashCheckAt = dashClock + M.DASH_MOVE_S
  return true
end
function M.dashMoving() return dashPending ~= nil end
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
  if a == 'middle' or a == 'wheel' then
    local before = dash.where()
    if not dash.setWhere(a) then return true end
    M.dashWhereBack = before
    for _, id in ipairs(dash.partCarIds()) do
      if id ~= v.id then M.dashStale[id] = true end
    end
    local ok, why, busy = M.dashFit(true, { measure = true, rebuild = true })
    -- the car could not take it now (damaged, or no driver camera): the phone stays where it was
    if not ok and not busy then M.dashGoBack() end
    return ok, why, busy
  end
  local axis, sign
  if type(a) == 'string' then axis, sign = a:match('^([xyz])([+-])$') end
  if axis then
    if not dash.nudge(v.model, axis, sign == '+' and 1 or -1) then return false, 'The phone can’t go further that way.' end
    return dashMoveSoon()
  elseif a == 'reset' then
    if not dash.nudge(v.model, 'reset') then return true end
    return dashMoveSoon()
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
    S.dashError = (not ok and why) or pending.why or nil
    return
  end
  -- switched off: a car that still has the phone loses it
  if not on and not dash.treeHasPhone(tree) then return end
  if dashBusy() then dashCheckAt = dashClock + 2 return end
  local stale = on and M.dashStale[v.id]
  if on and not stale and dash.treeHasPhone(tree) and dash.spot(v.model) and not dashMeasureNext[v.id] then return end
  local last = dashTried[v.id]
  if on and not stale and last and dashClock - last < M.DASH_RETRY_S and not dashMeasureNext[v.id] then return end
  local ok, why = M.dashFit(on, { rebuild = stale })
  if not ok then dashTried[v.id] = dashClock end
  S.dashError = not ok and why or nil
end
M.dashTick = dashTick
function M.dashCheckSoon() dashCheckAt = dashClock + M.DASH_CHECK_S end

-- After a reload during a free play shift: once a vehicle is there, swap the company vehicle back to the player's own.
-- Any other vehicle (the game spawned its default car) is left alone.
function M.freeRestoreTick()
  local r = S.freeRestore
  if not r or S.pendingCareer or S.career.employment then return end
  local v = M.G.vehicle and M.G.vehicle()
  if not v or not v.model then return end
  S.freeRestore = nil
  if not r.lent or v.model ~= r.lent then return end
  local ok, why = spawnCareerCar({ car = r.car })
  if ok then say('Your company shift ended with the reload. Your own vehicle is back.', 8)
  else problem('W', 'Free play vehicle not restored: ' .. tostring(why)) end
end

function M.onUpdate(dtReal, dtSim)
  require('cargoEarth/damage').tick(dtReal)
  dashTick(dtReal)
  M.freeRestoreTick()
  if S.pendingCareer then
    stopForceWatch()
    updateResume(dtReal)
    -- the phone's Radio works before the save is loaded: its presses, its station list and the helper's player
    S.clock = S.clock + (dtReal or 0)
    if helper.commanding() then helper.pump(S.clock) end
    if S.clock >= (S.radioSyncAt or 0) then
      S.radioSyncAt = S.clock + 0.5
      M.radioSync()
      radioAlive()
      local p = earth.status() == 'ok' and earth.pose() or nil
      if p and helper.asking() then helper.tick(p.lat, p.lon, S.clock, function() end, nil, true) end
    end
    return
  end
  S.clock = S.clock + (dtReal or 0)
  S.tick = S.tick + (dtReal or 0)
  trailers.update(dtReal, dtSim)                                 -- couples a tow trailer once the game knows its hitch
  if trailers.hitchFailed() and S.job and S.job.tow and S.job.tow.stage == 'hitch' then
    say('The trailer did not latch on. Stand still and press Hitch on the phone to try again.', 8)
  end
  if S.job and S.job.tow and S.phase == 'toPickup' and S.clock >= (S.towStageAt or 0) then
    S.towStageAt = S.clock + 1
    M.towStageTick()
  end
  if M.G.seatTick then M.G.seatTick() end                   -- the player sits in a car the mod just spawned
  M.busDoorWatch()
  if helper.commanding() then helper.pump(S.clock) end     -- radio presses: answered within frames, not ticks
  if S.clock >= (S.radioSyncAt or 0) then S.radioSyncAt = S.clock + 0.5 M.radioSync() end -- the UI page went away: the helper plays
  local worldReady = earth.status() == 'ok'
  local activeDt = careerClock.advance(S.career, dtReal, dtSim, worldReady and not S.parts)
  S.workTick = (S.workTick or 0) + activeDt
  local pose = activeDt > 0 and earth.pose() or nil
  if S.busDwell then
    local busPose = worldReady and (pose or earth.pose()) or nil
    M.busTick(busPose, S.parts and 0 or math.max(0, dtSim or dtReal or 0))
  end
  -- Hired drivers work while you do: on an order or contract, or driving. Standing idle earns nothing.
  if S.job or S.career.employment or (pose and not pose.camera and (pose.speed or 0) > M.STOP_SPEED) then
    S.driverTick = (S.driverTick or 0) + activeDt
  end
  if worldReady then
    if pose and camerasOn() and marker.drawCameras then marker.drawCameras(pose, cams.near, S.clock) end
    -- Rested: a few minutes parked at a home with a Rest room
    local parkedHome = pose and not pose.camera and (pose.speed or 0) <= M.STOP_SPEED and S.career.garage.started
      and home.near(S.career, pose) and garage.inOwnCar(M.G, S.career.garage)
    if S.career.home and home.restTick(S.career, parkedHome, activeDt) then
      say(string.format('Rested: +%d %% pay for the next hour.', math.floor(home.RESTED_BONUS * 100 + 0.5)), 6)
      saveCareer()
    end
    -- where home and the headquarters count (parking, the home's rooms): a blue ring when close
    if pose and not pose.camera and marker.drawArea then
      local myHome = S.career.home
      if myHome and myHome.g then marker.drawArea(pose, 'home', myHome.g, home.RADIUS, 'Home', S.clock) end
      local hq = S.career.firm and S.career.firm.hq
      if hq and hq.g then marker.drawArea(pose, 'hq', hq.g, firm.HQ_RADIUS, 'Headquarters', S.clock) end
      local depot = S.busDepot
      if depot and S.mode == 'bus' and not S.career.employment then
        marker.drawArea(pose, 'busDepot', depot.offer.yard.g, require('cargoEarth/bus').depotRadius(depot.offer),
          depot.offer.coach and 'Park to collect your coach' or 'Park to collect your bus', S.clock)
      end
    end
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
    local okI, errI = pcall(M.insuranceBill)
    if not okI and not S.insuranceErr then S.insuranceErr = tostring(errI) problem('W', 'insurance: ' .. S.insuranceErr) end
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
        local debtPaid = garage.takeForDebt(fg, income, 'Hired drivers\' earnings')
        economy.post(c, income - debtPaid, 'drivers', economy.nextId(c, 'drivers'), 'Fleet shift')
        say(string.format('Drivers earned %d CZK%s.', income,
          debtPaid > 0 and string.format(' (%d CZK toward debt)', debtPaid) or ''))
        saveCareer()
      end
    end
    if ready then helperTick(earth.pose()) end
    if ready and dt > 0 then M.busDepotTick(earth.pose(), dt) end
    if ready then countryTick(earth.pose()) end
    -- Returning a saved company vehicle must not depend on the geographic data cache.
    if ready and activeDt > 0 and S.career.employment then M.companyTick(dt) end
    if ready and (S.taxiSeated or (S.job and S.job.taxi)) then M.taxiTick() end
    if modeReady() and ready then
      S.inCareerWorld = true
      local pose = earth.pose()
      rememberLocation(pose)
      if S.job and not S.parts and dt > 0 then tick(dt) end
      if S.trailerOffersWait then M.trailerOffersTick() end
      if S.phone.online and dt > 0 then phoneTick()
      elseif not S.job and not S.offeredAt and not S.career.employment then M.generate() end
    end
    syncStorage()
    if ready and S.sweepWanted then M.sweepCargo() end
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
    local d, p = target(), pose or earth.pose()   -- (pose is nil only while the career clock stands)
    updateForceWatch(p)
    local st = stopInfo()
    if d and p then
      marker.draw(p, d, S.phase == 'toPickup' and 'pickup' or 'delivery', S.job.kind == 'food',
        arrivalRadius(S.job), st and st.inZone, S.clock)
    end
    ui.drawStop(st)
  else
    stopForceWatch()
    if worldReady then ui.drawStop(M.busDepotInfo(pose or earth.pose())) end
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

-- BeamNG.Earth moved the world's origin (modding API 1.7): positions worked out in the old frame are stale.
function M.onBeamNGEarthRebased()
  S.busDamageWatch = nil
  marker.reset()
  trailers.onRebased()
end

function M.onBeamNGEarthTeleported(info)
  S.busDamageWatch = nil
  if S.busDwell then M.interruptBoarding() end
  trailers.onTeleported()
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
    S.pauseSaving, S.replacementSaving = nil, nil
    pauseCareer(true)
    M.G.clearOwnership()
  end
end

function M.onVehicleDestroyed(id) dash.dropCar(id) dash.dropLoaded(id) dashTried[id] = nil dashReloaded[id] = nil dashMeasureNext[id] = nil end
-- the game is putting a car together: its nodes still carry all their groups (cargoEarth/dash.lua)
function M.onJbeamLoadingPhase2(_, objID, vehicle) dash.captureLoading(objID, vehicle) end
function M.onVehicleSwitched() M.dashCheckSoon() end

function M.onVehicleSpawned(id)
  M.busDoorsForget(id)
  if S.busDamageWatch and S.busDamageWatch.id == id then S.busDamageWatch = nil end
  M.dashCheckSoon()
  if fuelWatch and fuelWatch.id == id then stopFuelWatch() end
  -- A respawn recreates the vehicle-side storage, even when BeamNG reuses its object ID.
  if S.storage and S.storage.id == id then S.storage = nil end
  if forceWatch and forceWatch.id == id then forceWatch = nil end
  if S.freightLoad and S.freightLoad.id == id then S.freightLoad = nil end
end

-- A reset (R, recover, the game's repair) rebuilds the vehicle-side containers empty, so the load the mod set is
-- forgotten there: read the boxes again and put the load back (a meal box at once, freight through workFreight).
function M.onVehicleResetted(id)
  M.busDoorsForget(id)
  -- worn brakes of a used car stay worn: the game's reset puts the brake torque back to new
  -- (during a test drive, the listing's: the car you sit in is the one for sale)
  local g = S.career and S.career.garage
  local worn
  if g and g.preview then
    local l = garage.findListing(g, g.preview.id)
    local native = l and garage.listingNative(l)
    worn = native and native.brakes
  else
    local car = g and g.car
    worn = type(car) == 'table' and type(car.faults) == 'table' and car.faults.brakes
  end
  if worn and M.G.applyBrakes and M.G.ownedVehicle then
    local own = M.G.ownedVehicle()
    if own and own.id == id then pcall(M.G.applyBrakes, worn, id) end
  end
  if S.busDamageWatch and S.busDamageWatch.id == id then S.busDamageWatch = nil end
  if S.storage and S.storage.id == id then S.storage = nil end
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
  dash.forgetLoaded()
  dash.forget()
  S.resumeTrip, S.busHome = nil, nil
  releaseStorage()
  clearFreight()
  stopForceWatch()
  S.pauseSaving, S.replacementSaving = nil, nil
  if S.inCareerWorld then pauseCareer(true) end
end

function M.onExtensionUnloaded()
  dash.remove()
  dash.uninstall()
  releaseStorage()
  clearFreight()
  stopForceWatch()
  S.pauseSaving, S.replacementSaving = nil, nil
  if not S.pendingCareer and S.career.savedAt then saveCareer(true) end
  trailers.remove()
end

return M

