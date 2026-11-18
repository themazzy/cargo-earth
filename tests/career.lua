local clock = require('cargoEarth/clock')
local economy = require('cargoEarth/economy')
local home = require('cargoEarth/home')
local persistence = require('cargoEarth/persistence')
local employment = require('cargoEarth/employment')
local cargo = require('cargoEarth/cargo')
local jobs = require('cargoEarth/jobs')
local food = require('cargoEarth/food')
local earthReal = require('cargoEarth/earth')
local total = 0
local function test(name, fn)
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  total = total + 1
  print('PASS ' .. name)
end
local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, item in pairs(v) do out[k] = copy(item) end
  return out
end

test('deadlines freeze while paused, disconnected or loading', function()
  local c = { activeSeconds = 10 }
  assert(clock.advance(c, 1, 0, true) == 0)
  assert(clock.advance(c, 1, 1, false) == 0)
  assert(clock.advance(c, 60, 60, true) == 0)
  assert(clock.advance(c, 1, 1, true) == 1 and c.activeSeconds == 11)
  local j = { startedAt = 100 }
  c.savedAt = 160
  clock.restoreJob(c, j)
  assert(clock.elapsed(c, j) == 60)
end)

test('BeamNG.Earth 1.10 API: multi-stop GPS, the next stop of a route, Earth\'s own conversion', function()
  local set, setRoute
  local api = {
    version = function() return 1, 8 end, has = function(n) return n == 'gpsRoute' or n == 'transform' end,
    gpsSet = function(lat, lon, name) set = {lat, lon, name} return true end,
    gpsSetRoute = function(points) setRoute = points return true end,
    gps = function()
      return {remaining = 3000, eta = 300, waypoints = {{lat = 1, lon = 1}}, legs = {{500, 50}, {1000, 100}, {1200, 120}}}
    end,
    toGame = function(lat, lon) return lon * 10, lat * 10, 0 end,
  }
  beamngEarth_api = api
  assert(earthReal.canRoute())
  local stops = {}
  for i = 1, 13 do stops[i] = {50 + i / 100, 14, 'Stop ' .. i} end
  assert(earthReal.gpsStops(stops) and #setRoute == earthReal.ROUTE_MAX and setRoute[1][3] == 'Stop 1')
  assert(earthReal.gpsStops({stops[2]}) and set[3] == 'Stop 2', 'one stop: an ordinary destination')
  -- one waypoint ahead: the last leg (1200 m) lies past it
  local r = earthReal.route()
  assert(r.stops == 2 and r.remaining == 1800 and r.toEnd == 3000 and math.abs(r.eta - 180) < 1e-9)
  local x, y = earthReal.worldXY({x = 0, y = 0, lat = 50, lon = 14, anchorLat = 50, anchorLon = 14}, {2, 3})
  assert(x == 30 and y == 20, 'Earth converts')
  -- an older Earth: no multi-stop routes, the stops go one by one, the maths done here
  api.has = function() return false end
  set, setRoute = nil, nil
  assert(not earthReal.canRoute() and earthReal.gpsStops(stops) and set[3] == 'Stop 1' and not setRoute)
  api.gps = function() return {remaining = 900, eta = 90} end
  r = earthReal.route()
  assert(r.stops == 1 and r.remaining == 900)
  x = earthReal.worldXY({x = 0, y = 0, lat = 50, lon = 14, anchorLat = 50, anchorLon = 14}, {50, 14.001})
  assert(math.abs(x - 71.7) < 0.5)
  beamngEarth_api = nil
end)

test('odometer survives rebases and excludes teleport jumps', function()
  local p = { lat = 50, lon = 14, speed = 15, anchorLat = 50, x = 0 }
  local previous = clock.distance(nil, p, 1)
  p.lat, p.anchorLat, p.x = 50.0001, 51, -100000
  local sample, km = clock.distance(previous, p, 1)
  assert(km > 0.01 and km < 0.012)
  p.lat = 51
  local _, jump = clock.distance(sample, p, 1)
  assert(jump == 0)
  assert(clock.distance(sample, p, 0) == nil)
end)

test('settlement identities survive display-history pruning', function()
  local c = { money = 100 }
  assert(economy.post(c, 50, 'wages', 'shift:1'))
  for i = 1, 110 do assert(economy.post(c, 1, 'test', 'test:' .. i)) end
  assert(#c.accounts.history == 100)
  assert(not economy.post(c, 50, 'wages', 'shift:1'))
  assert(c.money == 260)
  c.money = 200
  economy.reconcile(c, 'garage')
  assert(c.accounts.history[1].amount == -60)
  assert(not economy.post(c, 0/0, 'bad', 'bad'))
end)

test('home address requires actual parked proximity and stores an independent point', function()
  local c, address = {}, { id = 'a', n = 'Test Street 12', town = 'Town', g = { 50, 14 } }
  assert(not home.claim(c, address, {lat = 51, lon = 14, speed = 0}))
  assert(not home.claim(c, address, {lat = 50, lon = 14, speed = 10}))
  assert(not home.claim(c, address, {lat = 50, lon = 14, camera = true}))
  assert(home.claim(c, address, {lat = 50.0001, lon = 14, speed = 0}))
  address.g[1] = 70
  assert(home.near(c, {lat = 50.0001, lon = 14}))
  assert(c.home.capacity == 3 and c.home.address[1] == 50)
end)

test('address search combines local tiles, literal punctuation and stable IDs', function()
  local rows = { {50, 14, 50, 14, "O'Neil [12]", 'Town'}, {50.001, 14, 50.001, 14, 'Other 8', 'Town'} }
  local idx = food.index({restaurants = {}, cats = {}, tile = 0.01}, function() return rows end)
  local found = food.addresses(idx, 50, 14, '[12]')
  assert(#found == 1 and found[1].n == "O'Neil [12]")
  assert(#food.addresses(idx, 50, 14, '') == 2)
end)

local disk, failPath = {}, nil
local function read(path) return copy(disk[path]) end
local function write(path, c)
  if path == failPath then return false end
  disk[path] = copy(c)
  return true
end
test('save migration preserves legacy save, rotates backups and recovers corruption', function()
  disk = { save = {money = 100, delivered = 12, orders = {}, garage = {car = {model = 'pigeon'}}} }
  local c = read('save')
  c.money = 125
  assert(persistence.save(write, read, 'save', c))
  assert(disk['save.legacy'].money == 100 and disk['save.legacy'].delivered == 12)
  c.money = 150
  c.activeSeconds = 10
  assert(persistence.save(write, read, 'save', c))
  assert(disk['save.backup1'].money == 100, 'backups do not rotate on every save')
  c.activeSeconds = persistence.BACKUP_EVERY_S + 10
  assert(persistence.save(write, read, 'save', c))
  assert(disk['save.backup1'].money == 150 and disk['save.backup2'].money == 100)
  c.money = 125
  c.activeSeconds = 2 * persistence.BACKUP_EVERY_S + 20
  assert(persistence.save(write, read, 'save', c))
  disk.save = false
  local recovered, msg = persistence.load(read, 'save')
  assert(recovered.money == 150 and msg)
  failPath = 'save.pending'
  assert(not persistence.save(write, read, 'save', c))
  assert(persistence.load(read, 'save').money == 150)
  failPath = nil
end)
test('future save versions are blocked instead of silently reset', function()
  disk = { save = {money = 1, schemaVersion = 999}, ['save.backup1'] = {money = 100} }
  local c, msg = persistence.load(read, 'save')
  assert(not c and msg:find('newer'))
end)

local idx = jobs.index({depots = {
  {id = 'yard', n = 'Warehouse', t = 'producer', s = 'M', g = {50, 14}},
  {id = 'shop1', n = 'Shop One', t = 'receiver', s = 'M', g = {50.03, 14}},
  {id = 'shop2', n = 'Shop Two', t = 'receiver', s = 'M', g = {50.045, 14}},
}, cargo = {pallets_general = {name = 'General goods', pay = 1, trailer = 'box'}}, trailers = {},
  types = {producer = {produces = {'pallets_general'}}, receiver = {accepts = {'pallets_general'}}}})

test('company board quotes two compatible deliveries and is deterministic', function()
  local a = employment.board(idx, {lat = 50, lon = 14})
  local b = employment.board(idx, {lat = 50, lon = 14})
  assert(#a == 1 and #a[1].jobs == 2)
  assert(a[1].wages == b[1].wages and a[1].jobs[1].id == b[1].jobs[1].id)
  assert(a[1].jobs[1].haul.tier == 'van' and not a[1].jobs[1].adr)
  assert(#employment.board(idx, {lat = 0, lon = 0}) == 0)
end)

test('early termination pays only completed work once and preserves personal debt', function()
  local offer = employment.board(idx, {lat = 50, lon = 14})[1]
  local c, personal = {money = 100}, {debt = 100}
  assert(employment.begin(c, offer, personal, {}, 'courier'))
  c.employment.phase = 'working'
  local j = employment.nextJob(c)
  assert(employment.delivered(c, j, 200))
  assert(not employment.delivered(c, j, 200))
  assert(c.money == 100 and c.employment.gross == 200)
  assert(employment.settle(c, true))
  assert(c.money == 180 and personal.debt == 20)
  assert(not employment.settle(c, true))
  assert(c.companies[offer.id].reputation == 0)
end)

test('accepting the same board offer twice starts from clean job copies', function()
  local offer = employment.board(idx, {lat = 50, lon = 14})[1]
  local c = {money = 0}
  assert(employment.begin(c, offer, {}, {}, 'courier'))
  c.employment.phase = 'working'
  local j = employment.nextJob(c)
  j.paymentId, j.cargoCondition = 'delivery:1', 40
  assert(not offer.jobs[1].companyShift and not offer.jobs[1].paymentId and not offer.jobs[1].cargoCondition)
  c.employment = nil
  assert(employment.begin(c, offer, {}, {}, 'courier'))
  local again = c.employment.jobs[1]
  assert(again ~= j and not again.paymentId and not again.cargoCondition and not again.companyShift)
  assert(again.id == j.id and again.haul.tier == j.haul.tier)
end)

-- Integration: real core/job/garage code with isolated game, Earth and filesystem adapters.
local pose, vehicle, boxes, spawnFailure, ready, payWrites = nil, nil, nil, nil, true, 0
local damageValue, impactToken = 0, nil
local gps, gpsRoute, routeCapable
helperAsks = {}
log = function() end
ui_imgui = {}
FS = {findFiles = function() return {} end}
jsonReadFile = read
jsonWriteFile = function(path, c, ...)
  if path == '/settings/cargoEarth/career.json' then payWrites = payWrites + 1 end
  return write(path, c, ...)
end
package.loaded['cargoEarth/ui'] = {drawStop = function() end, drawPartsExit = function() end}
package.loaded['cargoEarth/marker'] = {reset = function() end, draw = function() end}
package.loaded['cargoEarth/helper'] = {configure = function() end, tick = function() end, forget = function() end,
  status = function() return {state = 'off'} end, commanding = function() return false end, pump = function() end,
  asking = function() return false end, ask = function(path, cb) helperAsks[#helperAsks + 1] = { path = path, cb = cb } end}
package.loaded['cargoEarth/earth'] = {
  pose = function() return pose end, status = function() return ready and 'ok' or 'World loading' end,
  notify = function() end, route = function() return gpsRoute end,
  gps = function(lat, lon) gps = {lat = lat, lon = lon} return true end,
  canRoute = function() return routeCapable end, ROUTE_MAX = 11,
  gpsStops = function(stops) gps = {lat = stops[1][1], lon = stops[1][2], stops = #stops} return true end,
  gpsClear = function() gps = nil end,
  teleport = function(lat, lon) pose.lat, pose.lon = lat, lon return true end,
  worldXY = function(p, pt) return p.x + (pt[2] - p.lon) * 71700, p.y + (pt[1] - p.lat) * 111320 end,
}
local seated   -- bus passengers the game was asked to seat
local riders   -- taxi passengers the game was asked to seat
local freeSeats   -- passenger seats the game reports in the player's car (nil: no seat system)
local function adapter()
  return {
    busPassengers = function(n) seated = n return n end,
    carPassengers = function(n) riders = n return n end,
    freeSeats = function() return freeSeats end,
    vehicle = function() return vehicle end, ownedVehicle = function() return vehicle end,
    isOwned = function() return true end, damage = function() return damageValue end, configs = function() return {} end,
    playerId = function() return vehicle and vehicle.id end, ownsVehicleId = function(id) return vehicle and vehicle.id == id end,
    watchForces = function(_, token) impactToken = token return true end,
    captureConfig = function() return {parts = {body = vehicle.model}} end,
    freightLoanerConfig = function() return {parts = {load = 'box'}} end,
    busLoanerConfig = function() return {parts = {body = 'citybus'}}, 'city' end,
    spawn = function(model)
      if spawnFailure == model then error('simulated spawn failure') end
      vehicle = {model = model, id = 1, data = {}, slotPartMap = {body = model}}
      boxes = {{id = 1, cargoTypes = {'parcel'}, capacity = 96, targetVolume = 0, currentVolume = 0, currentDensity = 1}}
    end,
    cargoVehicle = function() return vehicle.id, vehicle.data end,
    readCargoBoxes = function(_, cb) cb(copy(boxes)) return true end,
    setFreightLoad = function(_, plan)
      for _, row in ipairs(boxes) do
        local load = plan[row.id]
        if load then row.currentVolume, row.targetVolume, row.currentDensity = load.volume, load.volume, load.density end
      end
      return true
    end,
    setCargoLoad = function(_, weights)
      for _, row in ipairs(boxes) do
        local kg = weights[row.id]
        if kg then row.currentVolume, row.targetVolume, row.currentDensity = kg, kg, 1 end
      end
      return true
    end,
  }
end
local function fresh()
  disk, failPath, spawnFailure, ready = {}, nil, nil, true
  gps, gpsRoute, routeCapable = nil, nil, nil
  damageValue, impactToken = 0, nil
  pose = {lat = 50, lon = 14, speed = 0}
  local G = adapter()
  G.spawn('pigeon')
  package.loaded['cargoEarth/core'] = nil
  local core = require('cargoEarth/core')
  core.G = G
  -- no chance events unless a test asks: the first applicant, no incident, no breakdown
  core.random = function(a, b) if a then return b and a or 1 end return 0.99 end
  local s = core.state()
  s.idx = idx
  s.career.money = 1000
  s.career.garage = {started = true, car = {model = 'pigeon', key = 'base', name = 'My Pigeon', config = {parts = {body = 'pigeon'}}, km = 1},
    repair = 0, debt = 100, inventory = {}, parked = {}, priceV = 2}
  return core, s
end
local function advance(core, n)
  for _ = 1, n or 20 do core.onUpdate(0.5, 0.5) end
end

test('Jobs settings selects profiles without changing work and saves only the requested range', function()
  local core, s = fresh()
  s.job = {id = 'keep-current-job'}
  local out = core.settingsDo('jobType', 'freight_rigid')
  assert(out.jobType == 'freight_rigid' and s.mode == 'courier' and s.job.id == 'keep-current-job')
  assert(out.items[3].max == 800 and out.items[3].value == 125)
  out = core.settingsDo('jobRange', 'freight_rigid', {nearKm = 30, minKm = 600, maxKm = 800})
  assert(out.rangeSaved and core.jobOptions('freight_rigid').minKm == 600)
  assert(s.job.id == 'keep-current-job' and s.optsByMode.courier.maxKm == nil)
  assert(core.jobOptions('company_rigid').maxKm == 40)
  out = core.settingsDo('jobRange', 'freight_rigid', {nearKm = 30, minKm = 800, maxKm = 600})
  assert(out.rangeError and not out.rangeSaved and core.jobOptions('freight_rigid').maxKm == 800)
  core.settingsDo('jobRange', 'company_rigid', {nearKm = 20, minKm = 80, maxKm = 100})
  assert(s.career.options.trucking.jobRanges.freight_rigid.maxKm == 800, 'stored with the career')
  local saved = copy(s.career)
  s.job = nil
  s.pendingCareer = saved
  core.phoneAction('resume')
  assert(core.jobOptions('freight_rigid').maxKm == 800 and core.companyRanges().rigid.maxKm == 100)
  out = core.settingsDo('resetJobRange', 'freight_rigid')
  assert(out.rangeReset and core.jobOptions('freight_rigid').maxKm == 125)
  assert(core.jobOptions('company_rigid').maxKm == 100)
  out = core.settingsDo('jobType', 'bus')
  assert(#out.items == 0 and out.jobHint:find('mapped'))
end)

test('The old jobs window writes the profile new offers use, after the phone saved one', function()
  local core, s = fresh()
  core.settingsDo('jobRange', 'courier', {nearKm = 2, minKm = 1, maxKm = 3})
  local epoch = core.settingsState().careerEpoch
  core.setOption('maxKm', 6)
  assert(core.jobOptions('courier').maxKm == 6, 'window slider reaches the saved courier profile')
  core.setOption('minKm', 7)
  local r = core.jobOptions('courier')
  assert(r.minKm == 7 and r.maxKm == 7, 'shortest past longest drags the longest along')
  core.setOption('maxKm', 20)
  assert(core.jobOptions('courier').maxKm == 8, 'clamped to the profile bounds')
  core.setOption('count', 4)
  assert(s.opts.count == 4, 'other options keep their old place')
  s.mode, s.opts = 'trucking', s.optsByMode.trucking
  local id = core.windowJobType()
  core.settingsDo('jobRange', id, {nearKm = 30, minKm = 20, maxKm = 100})
  core.setOption('maxKm', 640)
  assert(core.jobOptions(id).maxKm == 640, 'trucking window reaches ' .. id)
  local saved = copy(s.career)
  s.pendingCareer = saved
  core.phoneAction('resume')
  assert(core.settingsState().careerEpoch ~= epoch, 'loading a career gives the phone a new draft scope')
end)
local function start(core)
  local board = core.placesDo('refreshCompanies')
  assert(#board.companies == 1)
  core.placesDo('startCompany', board.companies[1].id)
  advance(core, 2)
  assert(core.state().job and core.state().phase == 'toPickup')
end
local function finishOne(core)
  local s = core.state()
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery')
  pose.lat, pose.lon = s.job.to.g[1], s.job.to.g[2]
  advance(core)
end

test('finance summary shows personal debt and excludes wages already settled', function()
  local core, s = fresh()
  assert(core.careerState().debt == 100 and core.careerState().heldWages == 0)
  start(core)
  local shift = s.career.employment
  shift.gross = 1000
  assert(core.careerState().debt == 100 and core.careerState().heldWages == 800)
  shift.phase = 'settled'
  assert(core.careerState().heldWages == 0)
end)

test('full contract loads native freight, holds pay, returns car and settles once', function()
  local core, s = fresh()
  start(core)
  assert(vehicle.model == 'van' and s.career.employment.personalGarage.car.model == 'pigeon')
  local elapsed = s.career.activeSeconds
  core.onUpdate(1, 0)
  assert(s.career.activeSeconds == elapsed and s.stopT < 3)
  finishOne(core)
  assert(s.career.employment.completed == 1 and s.career.money == 1000)
  finishOne(core)
  assert(s.career.employment.phase == 'returning' and s.career.delivered == 2)
  assert(s.career.money == 1000)
  local far = core.placesDo('settleCompany')
  assert(far.shift and s.career.money == 1000)
  pose.lat, pose.lon = 50, 14
  core.placesDo('settleCompany')
  assert(not s.career.employment and vehicle.model == 'pigeon')
  assert(s.career.garage.car.name == 'My Pigeon' and s.career.lastContract.wages > 0)
  local money = s.career.money
  core.placesDo('settleCompany')
  assert(s.career.money == money)
  assert(s.career.companies['company:yard'].reputation == 10)
end)

test('reload in a loaded van restores the contract, cargo and held wages', function()
  local core, s = fresh()
  start(core)
  advance(core)
  assert(s.phase == 'toDelivery')
  core.onExtensionUnloaded()
  package.loaded['cargoEarth/core'] = nil
  local resumed = require('cargoEarth/core')
  resumed.G = adapter()
  resumed.onExtensionLoaded()
  local state = resumed.state()
  state.idx, state.loadError = idx, nil
  resumed.phoneAction('resume')
  assert(state.career.employment and state.phase == 'toDelivery')
  assert(state.career.employment.personalGarage.car.model == 'pigeon')
  assert(resumed.updateOnLoad, 'a loaded save asks for a newer release')
  advance(resumed)
  assert(boxes[1].currentVolume > 0 and state.career.money == 1000)
  finishOne(resumed)
  finishOne(resumed)
  pose.lat, pose.lon = 50, 14
  resumed.placesDo('settleCompany')
  assert(not state.career.employment and vehicle.model == 'pigeon')
end)

test('failed personal-car spawn retries without a second wage payment', function()
  local core, s = fresh()
  start(core)
  finishOne(core)
  spawnFailure = 'pigeon'
  core.placesDo('endCompany')
  assert(s.career.employment.phase == 'settled')
  local money = s.career.money
  assert(disk['/settings/cargoEarth/career.json'].employment.phase == 'settled')
  spawnFailure = nil
  core.placesDo('settleCompany')
  assert(s.career.money == money and not s.career.employment and vehicle.model == 'pigeon')
end)

test('failed checkpoint blocks equipment replacement and can be retried', function()
  local core, s = fresh()
  local board = core.placesDo('refreshCompanies')
  failPath = '/settings/cargoEarth/career.json.pending'
  core.placesDo('startCompany', board.companies[1].id)
  assert(not s.career.employment and vehicle.model == 'pigeon')
  assert(s.career.garage.car.model == 'pigeon' and s.saveError)
  failPath = nil
  start(core)
  assert(s.career.employment)
end)

test('a personal van does not overwrite the company van configuration before it spawns', function()
  local core, s = fresh()
  vehicle.model = 'van'
  s.career.garage.car.model = 'van'
  spawnFailure = 'van'
  local board = core.placesDo('refreshCompanies')
  core.placesDo('startCompany', board.companies[1].id)
  local saved = disk['/settings/cargoEarth/career.json']
  assert(saved.employment and saved.garage.car.company)
  assert(saved.garage.car.config.parts.load == 'box')
  assert(saved.employment.personalGarage.car.config.parts.body == 'van')
end)

test('hired drivers in the personal garage keep earning during company work', function()
  local core, s = fresh()
  local fleet, garage = require('cargoEarth/fleet'), require('cargoEarth/garage')
  s.career.garage.debt = 0
  s.career.garage.parked = {{fleetId = 'car:1', name = 'Spare', model = 'pigeon', km = 0, driver = {elapsed = 0}}}
  start(core)
  local personal = s.career.employment.personalGarage
  local money = s.career.money
  pose.speed = 10
  for _ = 1, math.ceil(fleet.SHIFT_S / 0.5) + 10 do core.onUpdate(0.5, 0.5) end
  pose.speed = 0
  assert(personal.parked[1].driver.earned == fleet.NET_PER_SHIFT)
  assert(s.career.money >= money + fleet.NET_PER_SHIFT)
end)

test('garage capacity applies when buying a preview that keeps the old car', function()
  local core, s = fresh()
  s.career.home = {g = {50, 14}, capacity = 1}
  s.career.garage.preview = {keepCar = true}
  local ok, why = core.garageBuyListing(123)
  assert(not ok and why:find('full'))
  assert(s.career.garage.car.model == 'pigeon')
end)

test('without a home the owned-car limit still applies', function()
  local garageRules = require('cargoEarth/garage')
  local g = {car = {model = 'pigeon', name = 'Pigeon'}, parked = {{model = 'a'}, {model = 'b'}, {model = 'van', loaner = true}}}
  assert(garageRules.ownedCount(g) == 3)
  local career = {money = 100000}
  local ok, why = garageRules.buyCar({}, g, career, {price = 10, model = 'x', key = 'y'}, {keepCar = true})
  assert(not ok and why:find('full') and career.money == 100000 and #g.parked == 3)
end)

test('home claim persists the selected address through the real phone action', function()
  local core, s = fresh()
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.01}, function()
    return {{50, 14, 50, 14, 'Test Street 12', 'Town'}}
  end)
  local places = core.placesDo('search', 'Test')
  core.placesDo('select', places.addresses[1].id)
  core.placesDo('claimHome')
  assert(s.career.home.name == 'Test Street 12')
  assert(disk['/settings/cargoEarth/career.json'].home.name == 'Test Street 12')
end)

test('independent contracts require reputation and a real owned cargo van', function()
  local core, s = fresh()
  local board = core.placesDo('refreshCompanies')
  core.placesDo('startIndependent', board.companies[1].id)
  assert(not s.career.employment)
  s.career.companies = {['company:yard'] = {reputation = 20, shifts = 2, deliveries = 4}}
  core.placesDo('startIndependent', board.companies[1].id)
  assert(not s.career.employment and vehicle.model == 'pigeon')
  core.G.spawn('van')
  s.career.garage.car.model, s.career.garage.car.name = 'van', 'My Van'
  core.placesDo('startIndependent', board.companies[1].id)
  -- First call begins the asynchronous cargo-space read; retry once it is available.
  if not s.career.employment then core.placesDo('startIndependent', board.companies[1].id) end
  assert(s.career.employment and s.career.employment.ownerOperator)
  local data = vehicle.data
  advance(core, 2)
  finishOne(core)
  finishOne(core)
  pose.lat, pose.lon = 50, 14
  core.placesDo('settleCompany')
  assert(not s.career.employment and vehicle.model == 'van' and vehicle.data == data)
  assert(s.career.garage.car.name == 'My Van')
  assert(s.career.lastContract.share == 0 and s.career.lastContract.wages == s.career.lastContract.gross)
end)

test('streamed workplaces stay out of areas covered by the depot pack', function()
  local core, s = fresh()
  s.packDepots = {{id = 'cz-1', n = 'Checked Depot', t = 'producer', g = {50.05, 14.05}}}
  local before = #s.idx.depots
  core.onHelperArea({key = '500_140', restaurants = {}, grocers = {}, tiles = {}, depots = {
    {id = 'overture:cz-yard', n = 'Candidate Yard', t = 'yard', g = {50.05, 14.05}}}})
  assert(#s.idx.depots == before and not s.idx.byId['overture:cz-yard'])
  core.onHelperArea({key = '426_233', restaurants = {}, grocers = {}, tiles = {}, depots = {
    {id = 'overture:bg-yard', n = 'Sofia Yard', t = 'yard', g = {42.65, 23.35}}}})
  assert(s.idx.byId['overture:bg-yard'])
end)

test('streamed workplaces create local contracts without a country pack', function()
  local core, s = fresh()
  s.idx, s.fidx = nil, nil
  pose.lat, pose.lon = 42.65, 23.35
  core.onHelperArea({key = '426_233', restaurants = {}, grocers = {}, tiles = {}, depots = {
    {id = 'overture:sofia-yard', n = 'Local Distribution', t = 'yard', g = {42.65, 23.35}},
    {id = 'overture:sofia-shop1', n = 'Local Hardware', t = 'shop', g = {42.68, 23.35}},
    {id = 'overture:sofia-shop2', n = 'Local Grocer', t = 'shop', g = {42.70, 23.35}},
  }})
  local board = core.placesDo('refreshCompanies')
  assert(#board.companies == 1 and board.companies[1].name:find('Local Distribution'))
  core.placesDo('startCompany', board.companies[1].id)
  advance(core, 2)
  assert(s.job and s.job.from.n == 'Local Distribution')
  local destination = copy(s.job.to.g)
  for i = 1, 30 do
    jobs.addArea(s.idx, {key = 'cell' .. i, depots = {}})
  end
  assert(not s.idx.byId['overture:sofia-yard'])
  assert(s.job.to.g[1] == destination[1] and s.career.employment.yard.n == 'Local Distribution')
end)

test('malformed nested saves recover before restoring a vehicle', function()
  disk = {save = {money = 123, employment = false}, ['save.backup1'] = {money = 100}}
  local c, msg = persistence.load(read, 'save')
  assert(c.money == 100 and msg)
  disk.save = {money = 200, accounts = 'invalid'}
  assert(persistence.load(read, 'save').money == 100)
end)

test('write verification detects missing nested fields with the same balance', function()
  disk = {save = {money = 100}}
  local c = {money = 125, home = {name = 'Home', g = {50,14}, capacity = 3}}
  local function partial(path, value)
    disk[path] = copy(value)
    disk[path].home = nil
    return true
  end
  assert(not persistence.save(partial, read, 'save', c))
  assert(disk.save.money == 100)
end)

test('payment compaction preserves pending jobs and rejects old replayed payments', function()
  local c = {money = 0, orders = {}}
  local pending = economy.nextId(c, 'delivery')
  c.orders = {{data = {paymentId = pending}}}
  for _ = 1, 1000 do
    assert(economy.post(c, 1, 'drivers', economy.nextId(c, 'drivers')))
  end
  economy.compact(c)
  assert(economy.post(c, 100, 'delivery', pending))
  c.orders = {}
  economy.compact(c)
  assert(next(c.accounts.settled) == nil and c.accounts.settledThrough == 1001)
  assert(not economy.post(c, 100, 'delivery', pending) and c.money == 1100)
end)

test('settled vehicle return works even without loaded geographic data', function()
  local core, s = fresh()
  start(core)
  spawnFailure = 'pigeon'
  core.placesDo('endCompany')
  assert(s.career.employment.phase == 'settled')
  local money = s.career.money
  s.idx, s.fidx, spawnFailure = nil, nil, nil
  advance(core, 2)
  assert(not s.career.employment and vehicle.model == 'pigeon' and s.career.money == money)
end)

test('replacing a streamed release updates addresses and eviction respects tile ownership', function()
  local fidx = food.index({restaurants = {}, cats = {}, tile = 0.01}, function() return nil end)
  food.addArea(fidx, {key = 'a', release = 'old', restaurants = {}, grocers = {}, tiles = {tile = {{1}}}})
  food.addArea(fidx, {key = 'a', release = 'new', restaurants = {}, grocers = {}, tiles = {tile = {{2}}}})
  assert(fidx.extraTiles.tile[1][1] == 2)
  food.addArea(fidx, {key = 'b', release = 'new', restaurants = {}, grocers = {}, tiles = {tile = {{3}}}})
  food.dropArea(fidx, 'a')
  assert(fidx.extraTiles.tile[1][1] == 3)
end)

test('sparse contract search retains both viable recipients and existing range limits', function()
  local sparse = jobs.index({depots = {
    {id = 'rural-yard', n = 'Rural Yard', t = 'producer', s = 'S', g = {50,14}},
    {id = 'rural-a', n = 'Village A', t = 'receiver', s = 'S', g = {50.04,14}},
    {id = 'rural-b', n = 'Village B', t = 'receiver', s = 'S', g = {50.12,14}},
  }, cargo = idx.cargo, types = idx.types, trailers = idx.trailers})
  local board = employment.board(sparse, {lat = 50, lon = 14})
  assert(#board == 1 and #board[1].jobs == 2)
  local found = {}
  for _, j in ipairs(board[1].jobs) do
    found[j.to.id] = true
    assert(j.km >= 1 and j.km <= 20)
  end
  assert(found['rural-a'] and found['rural-b'])
  sparse.depots[3].g = {51,14}
  sparse = jobs.index(sparse.pack)
  assert(#employment.board(sparse, {lat = 50,lon = 14}) == 0)
end)

test('cheap geographic bounds keep valid long routes near poles and across the date line', function()
  local cases = {
    {89, 0, {89.2,180}, 250}, {50,179.95,{50,-179.95},20},
    {-89,0,{-89.2,180},250}, {85,20,{85,21.5},20},
  }
  for _, row in ipairs(cases) do
    assert(jobs.km(row[1],row[2],row[3][1],row[3][2]) <= row[4])
    assert(jobs.inBox(row[1],row[2],row[3],row[4]))
  end
end)

test('independent checkpoints store one garage and reconnect live ownership on resume', function()
  local core, s = fresh()
  core.G.spawn('van')
  s.career.garage.car.model, s.career.garage.car.name = 'van', 'My Van'
  s.career.companies = {['company:yard'] = {reputation = 20, shifts = 2, deliveries = 4}}
  local board = core.placesDo('refreshCompanies')
  core.placesDo('startIndependent', board.companies[1].id)
  if not s.career.employment then core.placesDo('startIndependent', board.companies[1].id) end
  advance(core, 2)
  core.onExtensionUnloaded()
  local saved = disk['/settings/cargoEarth/career.json']
  assert(saved.schemaVersion == persistence.VERSION and saved.employment.personalGarage == nil)
  assert(saved.garage.car.name == 'My Van' and saved.job == nil and saved.currentOrderId)
  package.loaded['cargoEarth/core'] = nil
  local resumed = require('cargoEarth/core')
  resumed.G = adapter()
  resumed.onExtensionLoaded()
  local state = resumed.state()
  state.idx, state.loadError = idx, nil
  resumed.phoneAction('resume')
  assert(state.career.employment.personalGarage == state.career.garage)
  state.career.garage.debt = 80
  resumed.placesDo('endCompany')
  assert(not state.career.employment and state.career.garage.debt == 80 and state.career.garage.car.name == 'My Van')
end)

local function partsFixture()
  local core, s = fresh()
  s.career.money, s.career.garage.debt = 10000, 0
  vehicle.slotPartMap = {body = 'pigeon', engine = 'old_engine', empty = false}
  core.G.openParts = function() return true end
  core.G.partsEditorOpen = function() return false end
  core.G.partsTarget = function() return vehicle end
  core.G.captureConfig = function() return {parts = copy(vehicle.slotPartMap)} end
  core.G.part = function(_, name) return {information = {name = name, value = 200}} end
  return core, s
end

test('native parts edits show a priced checkout and charge only on confirmation', function()
  local core, s = partsFixture()
  -- Native Apply emits its hook before replacing the vehicle's resolved parts map.
  core.onPartsTreeConfigChanged(nil, true)
  local pending = core.garageState()
  assert(pending.parts and not pending.parts.canBuy)
  vehicle.data, vehicle.slotPartMap = {}, {body = 'pigeon', engine = 'new_engine', empty = false}
  local checkout = core.garageState().parts
  assert(checkout and checkout.canBuy and #checkout.items == 2 and checkout.cost > 0)
  assert(s.career.money == 10000 and s.career.garage.car.parts.engine == 'old_engine')
  local paid = core.garageDo('buyParts', checkout.revision)
  assert(not s.parts and not paid.parts and s.career.money == 10000 - checkout.cost)
  assert(s.career.garage.car.parts.engine == 'new_engine' and s.career.garage.inventory.old_engine == 1)
end)

test('parts pricing errors preserve checkout and an unpaid configuration can be discarded', function()
  local core, s = partsFixture()
  core.garageDo('openParts')
  vehicle.slotPartMap.engine = 'new_engine'
  local quote = core.garage.partsQuote
  core.garage.partsQuote = function() error('simulated part metadata failure') end
  local state = core.garageState()
  assert(state.parts and state.parts.error and not state.parts.canBuy)
  assert(core.settingsState().reviewingParts and s.career.money == 10000)
  core.garage.partsQuote = quote
  local restored = core.garageDo('cancelParts')
  assert(not s.parts and not restored.parts and s.career.money == 10000)
  assert(s.career.garage.car.parts.engine == 'old_engine')
end)

test('unknown new parts cannot be bought free and pricing can retry', function()
  local core, s = partsFixture()
  core.garageDo('openParts')
  vehicle.slotPartMap.engine = 'unknown_engine'
  local readPart = core.G.part
  core.G.part = function(_, name) if name ~= 'unknown_engine' then return readPart(nil, name) end end
  local state = core.garageState()
  assert(state.parts and not state.parts.canBuy and state.parts.error:find('price'))
  core.G.part = readPart
  assert(core.garageState().parts.canBuy and s.career.money == 10000)
end)

test('driving an unconfirmed parts preview restores paid equipment without charging', function()
  local core, s = partsFixture()
  core.garageDo('openParts')
  vehicle.slotPartMap.engine = 'new_engine'
  pose.speed = 10
  advance(core, 2)
  assert(not s.parts and s.career.money == 10000)
  assert(s.career.garage.car.parts.engine == 'old_engine')
  assert(s.garageMsg:find('Unconfirmed'))
end)

test('late native Apply hooks cannot overwrite the paid parts snapshot', function()
  local core, s = partsFixture()
  core.garage.remember(core.G, s.career.garage)
  vehicle.slotPartMap.engine = 'new_engine'
  core.onPartsTreeConfigChanged(nil, false)
  local checkout = core.garageState().parts
  assert(checkout and checkout.canBuy and checkout.cost > 0)
  assert(s.career.garage.car.parts.engine == 'old_engine')
  core.garageDo('cancelParts')
  assert(s.career.garage.car.parts.engine == 'old_engine' and s.career.money == 10000)
end)

test('failed parts purchase checkpoint preserves money, inventory and retryable checkout', function()
  local core, s = partsFixture()
  core.garageDo('openParts')
  vehicle.slotPartMap.engine = 'new_engine'
  local checkout = core.garageState().parts
  failPath = '/settings/cargoEarth/career.json.pending'
  local failed = core.garageDo('buyParts', checkout.revision)
  assert(failed.parts and s.parts and s.career.money == 10000)
  assert(s.career.garage.car.parts.engine == 'old_engine' and not s.career.garage.inventory.old_engine)
  failPath = nil
  core.garageDo('buyParts', checkout.revision)
  assert(not s.parts and s.career.money == 10000 - checkout.cost)
end)

local function loadedCompany()
  local core, s = fresh()
  start(core)
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and impactToken)
  return core, s
end

test('company parcel impacts reduce displayed condition, delivery revenue and reputation reward', function()
  local core, s = loadedCompany()
  local job, original = s.job, s.job.pay
  core.onCargoEarthShock(vehicle.id, impactToken, 4.5)
  local condition = cargo.condition(job)
  assert(condition > 0 and condition < 100)
  assert(core.phoneState().active.cargoCondition == condition)
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  local shift = s.career.employment
  assert(shift.completed == 1 and shift.gross == math.floor(original * condition / 100 + 0.5))
  finishOne(core)
  pose.lat, pose.lon = 50, 14
  core.placesDo('settleCompany')
  assert(s.career.lastContract.reputationChange < 10 and s.career.lastContract.reputationChange > 0)
end)

test('ruined company loads fail once, empty physical cargo and advance the manifest without pay', function()
  local core, s = loadedCompany()
  local job = s.job
  core.onCargoEarthShock(vehicle.id, impactToken, 7)
  local shift = s.career.employment
  assert(not s.job and shift.failed == 1 and shift.index == 2 and shift.completed == 0 and shift.gross == 0)
  assert(boxes[1].currentVolume == 0 and s.career.failed == 1)
  assert(not employment.failed(s.career, job))
  core.companyTick()
  assert(core.phoneState().screen == 'failed' and not s.job)
  core.phoneAction('dismiss')
  core.companyTick()
  finishOne(core)
  assert(shift.phase == 'returning' and shift.completed == 1)
  pose.lat, pose.lon = 50, 14
  core.placesDo('settleCompany')
  assert(s.career.lastContract.failed == 1 and s.career.lastContract.reputationScore < 0)
  assert(s.career.companies['company:yard'].shifts == 0)
end)

test('company vehicle damage affects reputation and remains recorded after a free reset', function()
  local core, s = fresh()
  s.career.companies = {['company:yard'] = {reputation = 50, shifts = 0, deliveries = 0}}
  start(core)
  damageValue = 10000
  advance(core, 2)
  local recorded = s.career.employment.vehicleDamage
  assert(recorded > 0 and core.placesState().shift.vehicleDamage == recorded)
  damageValue = 0
  advance(core, 2)
  assert(s.career.employment.vehicleDamage == recorded and s.career.garage.debt == 0)
  core.placesDo('endCompany')
  assert(s.career.lastContract.reputationChange < 0 and s.career.garage.debt == 100)
end)

test('pending pickups and stale impact replies do not damage company freight', function()
  local core, s = fresh()
  start(core)
  assert(not impactToken)
  core.onCargoEarthShock(vehicle.id, 999, 8)
  assert(cargo.condition(s.job) == 100 and (s.career.employment.failed or 0) == 0)
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  core.onCargoEarthShock(vehicle.id, impactToken + 1, 8)
  assert(cargo.condition(s.job) == 100)
end)

test('damaged company cargo and recorded incidents survive saving and resuming', function()
  local core, s = loadedCompany()
  core.onCargoEarthShock(vehicle.id, impactToken, 4.5)
  local condition = cargo.condition(s.job)
  damageValue = 500
  advance(core, 2)
  local recorded = s.career.employment.vehicleDamage
  core.onExtensionUnloaded()
  package.loaded['cargoEarth/core'] = nil
  local resumed = require('cargoEarth/core')
  resumed.G = adapter()
  resumed.onExtensionLoaded()
  resumed.state().idx, resumed.state().loadError = idx, nil
  damageValue = 0
  resumed.phoneAction('resume')
  assert(cargo.condition(resumed.state().job) == condition)
  assert(resumed.state().career.employment.vehicleDamage == recorded and recorded > 0)
end)

test('two ruined company loads still allow yard settlement with zero wages and no completion rewards', function()
  local core, s = loadedCompany()
  core.onCargoEarthShock(vehicle.id, impactToken, 7)
  core.phoneAction('dismiss')
  core.companyTick()
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  core.onCargoEarthShock(vehicle.id, impactToken, 7)
  assert(s.career.employment.phase == 'returning' and s.career.employment.failed == 2)
  assert((s.career.delivered or 0) == 0 and not s.career.hauls)
  pose.lat, pose.lon = 50, 14
  core.placesDo('settleCompany')
  assert(not s.career.employment and s.career.lastContract.wages == 0 and s.career.money == 1000)
  assert(s.career.lastContract.reputationScore == -20 and s.career.garage.car.model == 'pigeon')
end)

test('independent parcel work also receives condition-based pay while retaining personal repair costs', function()
  local core, s = fresh()
  core.G.spawn('van')
  s.career.garage.car.model = 'van'
  s.career.companies = {['company:yard'] = {reputation = 20, shifts = 2, deliveries = 4}}
  local board = core.placesDo('refreshCompanies')
  core.placesDo('startIndependent', board.companies[1].id)
  if not s.career.employment then core.placesDo('startIndependent', board.companies[1].id) end
  advance(core, 2)
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  local job = s.job
  core.onCargoEarthShock(vehicle.id, impactToken, 4.5)
  damageValue = 1000
  advance(core, 2)
  local repair = s.career.garage.repair
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(s.career.employment.gross < job.pay and s.career.employment.share == 1)
  core.placesDo('endCompany')
  assert(s.career.garage.repair == repair and repair > 0)
end)

------------------------------------------------------------------------------------------ 0.4: ratings, fuel, records

local rating = require('cargoEarth/rating')
local fuel = require('cargoEarth/fuel')
local stats = require('cargoEarth/stats')

test('stars follow lateness, cargo condition and penalties, never outside 1 to 5', function()
  assert(rating.stars(10, 20, 100) == 5)
  assert(rating.stars(20, 20, 100) == 5)
  assert(rating.stars(22, 20, 100) == 4, 'up to 20% late costs one star')
  assert(rating.stars(30, 20, 100) == 2)
  assert(rating.stars(200, 20, 100) == 2, 'lateness alone costs at most three stars')
  assert(rating.stars(10, 20, 85) == 4 and rating.stars(10, 20, 60) == 3)
  assert(rating.stars(200, 20, 0) == 1)
  assert(rating.stars(10, 20, 100, 1) == 4 and rating.stars(10, 20, 100, 9) == 1)
  assert(rating.stars(0/0, 0, nil) >= 1)
end)

test('courier and freight reputations are separate, bounded and unlock their own rewards', function()
  local c = {}
  local score, n = rating.score(c, 'courier')
  assert(score == rating.NEW_SCORE and n == 0 and not rating.premium(c) and rating.pingFactor(c) == 1)
  assert(rating.track({kind = 'food'}) == 'courier' and rating.track({haul = {}}) == 'freight')
  for _ = 1, 12 do rating.add(c, 'courier', 5) end
  assert(rating.premium(c) and select(1, rating.score(c, 'freight')) == rating.NEW_SCORE)
  for _ = 1, 60 do rating.add(c, 'courier', 1) end
  score, n = rating.score(c, 'courier')
  assert(score == 1 and n == rating.KEEP.courier and c.reputation.courier.count == 72)
  assert(not rating.premium(c) and rating.pingFactor(c) > 1)
  for _ = 1, 5 do rating.add(c, 'freight', 5) end
  assert(rating.freightPay(c) == rating.PREFERRED_PAY)
  for _ = 1, 30 do rating.add(c, 'freight', 2) end
  assert(rating.freightPay(c) == rating.POOR_PAY)
  assert(rating.add(c, 'nothing', 5) == nil)
  local job = {kind = 'food', pay = 100, minutes = 20, sizeBonus = 20}
  rating.makePremium(job)
  rating.makePremium(job)
  assert(job.pay == 130 and job.minutes == 17 and job.premium)
end)

test('fuel books follow the game level, count use and undo free refills', function()
  local car = {}
  assert(fuel.observe(car, {}) == nil and car.fuel == nil)
  assert(fuel.observe(car, {mainTank = {ratio = 0.8, cap = 50, kind = 'gasoline'}}, 0) == nil)
  assert(car.fuel.tanks.mainTank.ratio == 0.8)
  fuel.observe(car, {mainTank = {ratio = 0.75, cap = 50, kind = 'gasoline'}}, 4)
  local set, used = fuel.observe(car, {mainTank = {ratio = 0.7, cap = 50, kind = 'gasoline'}}, 4)
  assert(not set and math.abs(used - 2.5) < 1e-9 and car.fuel.km == 8)
  fuel.observe(car, {mainTank = {ratio = 0.7, cap = 50, kind = 'gasoline'}}, 900)
  assert(car.fuel.km == 8, 'a teleport is not driven distance')
  -- a reset in the game refills the tank: the remembered level goes back
  set = fuel.observe(car, {mainTank = {ratio = 1, cap = 50, kind = 'gasoline'}}, 0)
  assert(set and math.abs(set.mainTank - 0.7) < 1e-9 and car.fuel.tanks.mainTank.ratio == 0.7)
  local st = fuel.state(car)
  assert(st.kind == 'gasoline' and st.unit == 'L' and st.have == 35 and st.per100 == 62.5 and st.rangeKm == 56)
  -- a bigger tank fitted in the parts shop starts no fuller than the old one
  set = fuel.observe(car, {bigTank = {ratio = 1, cap = 80, kind = 'gasoline'}}, 0)
  assert(set and math.abs(set.bigTank - 0.7) < 1e-9 and not car.fuel.tanks.mainTank)
  -- broken reports change nothing
  assert(fuel.observe(car, {bigTank = {ratio = 0/0, cap = 80}}, 0) == nil and car.fuel.tanks.bigTank.ratio == 0.7)
end)

test('a used car starts with what its last owner left and batteries accept regeneration', function()
  local car = {fuel = {start = 0.3}}
  local set = fuel.observe(car, {mainTank = {ratio = 1, cap = 40, kind = 'diesel'}}, 0)
  assert(car.fuel.tanks.mainTank.ratio == 0.3)
  set = fuel.observe(car, {mainTank = {ratio = 1, cap = 40, kind = 'diesel'}}, 0)
  assert(set and set.mainTank == 0.3)
  local ev = {}
  fuel.observe(ev, {battery = {ratio = 0.5, cap = 60, kind = 'electric'}}, 0)
  assert(fuel.observe(ev, {battery = {ratio = 0.505, cap = 60, kind = 'electric'}}, 0) == nil)
  assert(ev.fuel.tanks.battery.ratio == 0.505 and fuel.state(ev).unit == 'kWh')
  assert(fuel.stationKind(fuel.state(ev).kind) == 'electric')
end)

test('refill quotes respect the pump, the amount asked for and the money at hand', function()
  local car = {}
  fuel.observe(car, {mainTank = {ratio = 0.5, cap = 40, kind = 'gasoline'}}, 0)
  local full = fuel.quote(car, fuel.sells('fuel'), 1)
  assert(full.units.gasoline == 20 and full.cost == 20 * fuel.PRICE.gasoline and full.full and full.levels.mainTank == 1)
  assert(fuel.quote(car, fuel.sells('electric'), 1) == nil, 'a charger does not sell petrol')
  local some = fuel.quote(car, fuel.sells('fuel'), 1, 10)
  assert(some.units.gasoline == 10 and not some.full and some.levels.mainTank == 0.75)
  local poor = fuel.quote(car, fuel.sells('fuel'), 1, nil, 5 * fuel.PRICE.gasoline)
  assert(poor.units.gasoline == 5 and poor.cost == 5 * fuel.PRICE.gasoline and not poor.full)
  assert(fuel.quote(car, fuel.sells('fuel'), 1, nil, 0) == nil)
  assert(fuel.quote(car, fuel.sells('fuel'), 1, nil, nil, true).cost == 0, 'a company card pays nothing')
  fuel.apply(car, full)
  assert(car.fuel.tanks.mainTank.ratio == 1 and car.fuel.bought == full.cost)
  assert(fuel.quote(car, fuel.sells('fuel'), 1) == nil, 'a full tank has nothing to buy')
  local a, b = fuel.stationFactor('s1'), fuel.stationFactor('s1')
  assert(a == b and a >= 1 - fuel.STATION_SPREAD and a <= 1 + fuel.STATION_SPREAD)
end)

test('stations are found by kind and distance and streamed areas can be replaced', function()
  local idx = fuel.index()
  assert(fuel.addPack(idx, {stations = {
    {'a', 50, 14, 'Near pump', 'f', 'Town'}, {'b', 50.2, 14, 'Far pump', 'f', ''}, {'c', 50.001, 14, 'Charger', 'e', ''},
    {'a', 50, 14, 'Duplicate', 'f', ''}, {'bad', 500, 14, 'Nowhere', 'f', ''}, 'junk'}}) == 3)
  local s, km = fuel.nearest(idx, 50.0005, 14, 'fuel', 30)
  assert(s.id == 'a' and km < 0.1)
  assert(fuel.nearest(idx, 50.0005, 14, 'electric', 30).id == 'c')
  assert(fuel.nearest(idx, 50.1, 14, 'fuel', 5) == nil)
  assert(fuel.nearest(idx, 50.19, 14, 'fuel', 30).id == 'b')
  assert(fuel.addArea(idx, '500_140', {{'x', 50.05, 14.05, 'Streamed', 'f', ''}}) == 1 and idx.count == 4)
  assert(fuel.addArea(idx, '500_140', {{'y', 50.06, 14.05, 'Replaced', 'f', ''}}) == 1 and idx.count == 4)
  assert(fuel.nearest(idx, 50.06, 14.05, 'fuel', 1).id == 'y')
  fuel.dropArea(idx, '500_140')
  assert(idx.count == 3 and fuel.nearest(idx, 50.06, 14.05, 'fuel', 1) == nil)
end)

test('delivery records keep a bounded trail and only improve', function()
  local c = {}
  local job = {kind = 'food', km = 3.24, minutes = 20, cargoName = 'Pizza', to = {n = 'Street 1', g = {50.1, 14.1}}}
  local set = stats.record(c, job, {pay = 100, tip = 20, minutes = 10, stars = 5, date = '2026-11-11', earnedToday = 120})
  assert(#set >= 4 and c.records.longest.value == 3.2 and c.records.bestPay.value == 120 and c.records.quickest.value == 50)
  set = stats.record(c, job, {pay = 90, tip = 0, minutes = 19, stars = 4, date = '2026-11-11', earnedToday = 210})
  assert(#set == 1 and set[1] == 'bestDay' and c.records.streak == 0 and c.records.bestStreak == 1)
  for _ = 1, stats.TRAIL + 20 do stats.record(c, job, {pay = 1, tip = 0, minutes = 30, stars = 5, date = '2026-11-11'}) end
  assert(#c.trail == stats.TRAIL and c.records.bestStreak == stats.TRAIL + 20)
  stats.broken(c)
  assert(c.records.streak == 0 and c.records.bestStreak == stats.TRAIL + 20)
  stats.record(c, {kind = 'cargo', km = 1, minutes = 5, to = {n = 'Bad', g = {999, 0}}}, {pay = 1, stars = 5})
  assert(#c.trail == stats.TRAIL, 'a delivery without a valid point leaves no dot')
  local map = stats.state(c, {g = {50.2, 14.2}})
  assert(#map.dots == stats.TRAIL and map.marks[1].k == 'home' and map.spanKm > 0)
  for _, d in ipairs(map.dots) do assert(d.x >= 0 and d.x <= 100 and d.y >= 0 and d.y <= 100) end
  assert(#stats.state({}).dots == 0)
end)

-- The fuel adapter: the "vehicle" reports its tank through the real hook, as the vehicle extension does.
local tank, fuelToken, fuelSets, takesFuel = nil, nil, 0, true
local function fuelAdapter(core)
  tank, fuelToken, fuelSets, takesFuel = {ratio = 0.5, cap = 40, kind = 'gasoline'}, nil, 0, true
  core.G.part = function(_, name) return {information = {name = name, value = 200}} end
  core.G.watchFuel = function(_, token) fuelToken = token return true end
  core.G.setFuel = function(_, levels)
    fuelSets = fuelSets + 1
    if takesFuel and levels.mainTank then tank.ratio = levels.mainTank end
    return true
  end
end
local function fuelReport(core)
  core.onCargoEarthFuel(vehicle.id, fuelToken, {mainTank = copy(tank)})
end
local function withStation(s, lat, lon)
  s.fuelIdx = fuel.index()
  fuel.addPack(s.fuelIdx, {stations = {{'pump', lat, lon, 'Test pump', 'f', 'Town'}}})
end

test('refuelling at a station charges the ledger once and fills the real tank', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  advance(core, 2)
  assert(fuelToken, 'the career car is watched')
  fuelReport(core)
  local state = core.garageState().fuel
  assert(state.have == 20 and state.station.at and state.fill.cost > 0 and state.delivery)
  assert(core.phoneState().fuel.pct == 50)
  local money, cost = s.career.money, state.fill.cost
  local page = core.garageDo('refuel')
  assert(page.msg:find('Filled') and tank.ratio == 1 and s.career.money == money - cost)
  assert(s.career.accounts.history[1].category == 'fuel' and s.career.accounts.history[1].amount == -cost)
  fuelReport(core)
  assert(core.garageState().fuel.have == 40 and not core.garageState().fuel.fill)
  assert(core.garageDo('refuel').msg == 'The tank is full.' and s.career.money == money - cost)
end)

test('a station sells part fills up to 25, 50 or 75 % of the tank', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  advance(core, 2)
  fuelReport(core)   -- tank at 50 % of 40 l
  local partial = core.garageState().fuel.partial
  assert(#partial == 1 and partial[1].pct == 75 and partial[1].afford, 'only levels above the tank are offered')
  local money, cost = s.career.money, partial[1].cost
  local page = core.garageDo('refuelTo', 75)
  assert(page.msg:find('Filled 10.0') and tank.ratio == 0.75 and s.career.money == money - cost)
  assert(s.career.accounts.history[1].category == 'fuel' and s.career.accounts.history[1].amount == -cost)
  fuelReport(core)
  assert(#core.garageState().fuel.partial == 0)
  assert(core.garageDo('refuelTo', 50).msg == 'The tank is already above 50 %.' and s.career.money == money - cost)
end)

test('the Work screen offers fills at the pumps and Not now hides them at that station', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  advance(core, 2)
  fuelReport(core)   -- tank at 50 %
  local pump = core.phoneState().pump
  assert(pump and #pump.options == 2 and pump.options[1].pct == 75 and pump.options[2].pct == 100)
  local money, cost = s.career.money, pump.options[1].cost
  pump = core.phoneAction('pumpFill', 75).pump
  assert(tank.ratio == 0.75 and s.career.money == money - cost and pump.msg:find('Filled'))
  fuelReport(core)
  core.phoneAction('pumpHide')
  assert(core.phoneState().pump == nil, 'hidden at this station')
end)

test('a tank refilled by a game reset is put back and costs nothing', function()
  local core, s = fresh()
  fuelAdapter(core)
  advance(core, 2)
  fuelReport(core)
  tank.ratio = 0.4
  fuelReport(core)
  assert(s.career.garage.car.fuel.tanks.mainTank.ratio == 0.4)
  tank.ratio = 1
  fuelReport(core)
  assert(tank.ratio == 0.4 and fuelSets == 1 and s.career.money == 1000)
end)

test('a fill at one of the game\'s own pumps is kept and paid at that station\'s price', function()
  local core, s = fresh()
  fuelAdapter(core)
  advance(core, 2)
  fuelReport(core)
  local money = s.career.money
  core.onGameRefuel(vehicle.id, {type = 'gasStation', facility = {id = 'bne_fuel_1', name = 'Earth Pump'}}, {gasoline = true})
  tank.ratio = 1
  fuelReport(core)
  local cost = math.ceil(20 * fuel.price('gasoline', fuel.stationFactor('bne_fuel_1')) - 1e-6)
  assert(tank.ratio == 1 and fuelSets == 0, 'the game level stays')
  assert(s.career.garage.car.fuel.tanks.mainTank.ratio == 1 and s.career.money == money - cost)
  local h = s.career.accounts.history[1]
  assert(h.category == 'fuel' and h.amount == -cost and h.detail == 'Earth Pump')
  -- the pump is used once: a later jump (a reset) is put back for free again
  tank.ratio = 0.6
  fuelReport(core)
  tank.ratio = 1
  fuelReport(core)
  assert(tank.ratio == 0.6 and s.career.money == money - cost)
end)

test('a game pump fill without the money goes on the debt; an old pump press expires', function()
  local core, s = fresh()
  fuelAdapter(core)
  advance(core, 2)
  fuelReport(core)
  s.career.money, s.career.garage.debt = 10, 0
  core.onGameRefuel(vehicle.id, {facility = {id = 'p', name = 'Pump'}}, {any = true})
  tank.ratio = 0.75
  fuelReport(core)
  -- the wallet pays what it has (shown in Finances), the rest is owed
  assert(tank.ratio == 0.75 and s.career.money == 0 and s.career.garage.debt == math.ceil(10 * fuel.price('gasoline', fuel.stationFactor('p')) - 1e-6) - 10)
  assert(s.career.accounts.history[1].category == 'fuel' and s.career.accounts.history[1].amount == -10)
  assert(require('cargoEarth/garage').debtInfo(s.career.garage).sources[1].kind == 'fuel')
  core.onGameRefuel(vehicle.id, {facility = {id = 'p'}}, {any = true})
  advance(core, (core.PUMP_WAIT_S + 5) * 2)
  fuelReport(core)
  tank.ratio = 1
  fuelReport(core)
  assert(tank.ratio == 0.75, 'a refill long after the pump press is a reset')
end)

test('the game pump hook wraps refuelCar once and still refuels', function()
  local gamecar = require('cargoEarth/gamecar')
  local calls, heard = 0, nil
  local gs = {refuelCar = function() calls = calls + 1 end}
  local had = rawget(_G, 'freeroam_gasStations')
  rawset(_G, 'freeroam_gasStations', gs)
  assert(gamecar.hookPumps(function(id, st) heard = {id, st} end))
  local wrapped = gs.refuelCar
  assert(gamecar.hookPumps(function() end) and gs.refuelCar == wrapped, 'never wrapped twice')
  gs.refuelCar({facility = {}}, {}, {getID = function() return 7 end})
  assert(calls == 1 and heard[1] == 7)
  rawset(_G, 'freeroam_gasStations', had)
end)

test('refuelling away from a station is refused; delivery works anywhere and can go on debt', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50.2, 14)
  advance(core, 2)
  fuelReport(core)
  assert(not core.garageState().fuel.station.at)
  assert(core.garageDo('refuel').msg:find('Park at a station') and tank.ratio == 0.5)
  pose.speed = 10
  assert(core.garageDo('fuelDelivery').msg == 'Stop the car first.')
  pose.speed = 0
  s.career.money, s.career.garage.debt = 20, 0
  local page = core.garageDo('fuelDelivery')
  assert(page.msg:find('added to your debt') and tank.ratio == 0.75)
  assert(s.career.money == 0 and s.career.garage.debt == math.ceil(10 * fuel.price('gasoline', fuel.DELIVERY_FACTOR)) + fuel.DELIVERY_FEE - 20)
  assert(core.garageDo('fuelGps').msg:find('Test pump') and gps and math.abs(gps.lat - 50.2) < 1e-9)
end)

test('a refill the game does not take is refunded', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  advance(core, 2)
  fuelReport(core)
  takesFuel = false
  local money = s.career.money
  core.garageDo('refuel')
  assert(s.career.money < money)
  fuelReport(core)
  assert(core.garageDo('refuel').msg == 'Refuelling…', 'no second charge while the first is checked')
  advance(core, 14)
  fuelReport(core)
  assert(s.career.money == money and s.career.garage.car.fuel.tanks.mainTank.ratio == 0.5)
end)

test('a tiny refill the game does not take is refunded too', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  tank.ratio = 0.99
  advance(core, 2)
  fuelReport(core)
  takesFuel = false
  local money = s.career.money
  core.garageDo('refuel')
  assert(s.career.money < money, 'a 0.4 l top-up is charged')
  fuelReport(core)
  advance(core, 14)
  fuelReport(core)
  assert(s.career.money == money, 'an unchanged gauge must not confirm a top-up smaller than 2 %')
end)

test('a loaner fills up on the company fuel card', function()
  local core, s = fresh()
  fuelAdapter(core)
  withStation(s, 50, 14)
  s.career.garage.car.loaner = true
  advance(core, 2)
  fuelReport(core)
  assert(core.garageState().fuel.free and core.garageState().fuel.fill.cost == 0)
  assert(core.garageDo('refuel').msg:find('company fuel card') and tank.ratio == 1 and s.career.money == 1000)
end)

test('deliveries are rated, feed the right reputation and leave a dot on the map', function()
  local marker = package.loaded['cargoEarth/marker']
  marker.PICKUP_RADIUS, marker.PICKUP_RANGE, marker.pickupDistance = 5, 250, function() return nil end
  local core, s = fresh()
  s.career.garage.debt = 0
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function() return {{50.02, 14, 50.02, 14, 'Street 5', 'Town'}} end)
  advance(core, 2)
  core.phoneAction('online')
  for _ = 1, 40 do
    advance(core, 2)
    if core.phoneState().screen == 'incoming' then break end
  end
  assert(core.phoneState().screen == 'incoming', 'an order rings')
  core.phoneAction('accept')
  local job = s.job
  assert(job and job.kind == 'food')
  local active = core.phoneState().active
  assert(active.pickupLeftS and active.pickupLeftS > 0 and active.pickupLeftS < active.leftS, 'a pickup target before the delivery one')
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(core.phoneState().active.pickupLeftS == nil, 'collected: only the delivery target is left')
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  local done = core.phoneState().done
  assert(done and done.stars == 5 and done.track == 'courier' and done.note ~= '')
  local rep = core.careerState().reputation
  assert(rep.courier.rated == 1 and rep.courier.score == 5 and rep.freight.rated == 0)
  assert(s.career.history[1].stars == 5 and core.mapState().count == 1 and core.mapState().records.bestPay.value > 0)
end)

test('a ruined company load costs freight reputation', function()
  local core, s = fresh()
  start(core)
  local j = s.job
  pose.lat, pose.lon = j.from.g[1], j.from.g[2]
  advance(core)
  core.onCargoEarthShock(vehicle.id, impactToken, 30)
  local rep = core.careerState().reputation.freight
  assert(rep.rated == 1 and rep.score == 1)
end)

test('the starter car gets the cheapest parcel box its slots take', function()
  local garage = require('cargoEarth/garage')
  local parts = {
    pigeon = {slots2 = {{name = 'pigeon_bed'}}},
    pigeon_bed = {slots2 = {{name = 'pigeon_bed_load'}}},
    cargo_load_box_L = {information = {name = 'Large parcel box', value = 400}},
    cargo_load_box_S = {information = {name = 'Small parcel box', value = 150}},
    cargo_load_aggregate_box_S = {information = {name = 'Aggregate box', value = 50}},
    pigeon_tank_fluid = {information = {name = 'Fluid tank', value = 10}},
  }
  local G = {
    part = function(_, name) return parts[name] end,
    compatible = function(_, def)
      if def.name == 'pigeon_bed_load' then return {'cargo_load_box_L', 'cargo_load_box_S', 'cargo_load_aggregate_box_S', 'pigeon_tank_fluid'} end
      return {}
    end,
  }
  local v = {ioCtx = {}, tree = {chosenPartName = 'pigeon'}, slotPartMap = {['/pigeon_bed/'] = 'pigeon_bed', ['/pigeon_bed/pigeon_bed_load/'] = ''}}
  local box = garage.planBox(G, v)
  assert(box and box.part == 'cargo_load_box_S' and box.path == '/pigeon_bed/pigeon_bed_load/', box and box.part)
  v.slotPartMap['/pigeon_bed/pigeon_bed_load/'] = 'cargo_load_box_L'
  assert(garage.planBox(G, v) == nil, 'a car with a box already gets none')
  v.slotPartMap = {['/pigeon_bed/'] = 'pigeon_bed'}
  assert(garage.planBox(G, v) == nil, 'a car with no box slot keeps the starter bag')
end)

local parcel = require('cargoEarth/parcel')

local function streets(lat0, lon0)
  local rows = {}
  for i = 1, 30 do
    local lat, lon = lat0 + 0.004 * math.floor((i - 1) / 6), lon0 + 0.006 * ((i - 1) % 6) + 0.005
    rows[i] = {lat, lon, lat, lon, 'Street ' .. i, 'Town'}
  end
  return rows
end

test('parcel route rules: real addresses in nearest-first order, sized to the vehicle', function()
  local seq = 0
  local function rnd(n) seq = seq % n + 1 return seq end
  local depot = {id = 'yard', n = 'Warehouse', g = {50, 14}}
  local job = parcel.route(depot, streets(50, 14), 'van', 96, rnd, 1)
  assert(job and job.route and #job.route.stops >= 4 and job.to == job.route.stops[1])
  local total, last, legs = 0, depot.g, {}
  for _, s in ipairs(job.route.stops) do
    total = total + s.slots
    legs[#legs + 1] = parcel.km(last[1], last[2], s.g[1], s.g[2])
    last = s.g
  end
  assert(total == job.haul.amount and job.haul.kind == 'parcel' and job.pay > 0 and job.minutes > 10)
  local small = parcel.route(depot, streets(50, 14), 'van', 9, rnd, 2)
  assert(small and small.haul.amount <= 9, 'the load is cut to the free container space')
  assert(not parcel.route(depot, streets(50, 14), 'van', 3, rnd, 3), 'too little room: no route')
  assert(not parcel.route(depot, streets(51, 15), 'van', 96, rnd, 4), 'no addresses near the depot: no route')
  assert(not parcel.route(depot, streets(50, 14), 'rigid', 640, rnd, 5), 'box trucks do business shipping, not parcel routes')
  local plan = {[7] = {volume = 40, density = 1}, [8] = {volume = 20, density = 1}}
  local kept = parcel.keep(plan, 10, 2.5)
  assert(kept[7].volume == 25 and kept[8].volume == 0)
end)

test('the pickup target is the ride-there share of the order time', function()
  -- 2 km to the restaurant (2.7 km of streets), 2.7 km on to the customer: about half of 20 minutes
  assert(food.pickupMinutes({kind = 'food', minutes = 20, pickupKm = 2, km = 2.7}) == 10)
  -- the courier is at the restaurant already: a minute to collect
  assert(food.pickupMinutes({kind = 'food', minutes = 12, pickupKm = 0, km = 3}) == 1)
  -- a far restaurant still leaves a minute for the delivery
  assert(food.pickupMinutes({kind = 'food', minutes = 10, pickupKm = 50, km = 0.1}) == 9)
  assert(food.pickupMinutes({kind = 'cargo', minutes = 10, pickupKm = 2, km = 3}) == nil, 'food only')
  assert(food.pickupMinutes({kind = 'food', minutes = 10}) == nil)
end)

test('pickup variety: two in a row from one place, then two from other places', function()
  local variety = require('cargoEarth/variety')
  local function job(k) return { from = { id = k } } end
  local h = {}
  assert(not variety.resting(h, 'A'))
  h = variety.note(h, job('A'))
  assert(not variety.resting(h, 'A'), 'a second order from the same place is fine')
  h = variety.note(h, job('A'))
  assert(variety.resting(h, 'A') and not variety.resting(h, 'B'), 'two in a row: the place rests')
  h = variety.note(h, job('B'))
  assert(variety.resting(h, 'A'), 'one other order is not enough')
  assert(not variety.resting(h, 'B'))
  h = variety.note(h, job('C'))
  assert(not variety.resting(h, 'A'), 'two other orders: it rings again')
  -- forced back by a one-restaurant village: still resting until two others came
  assert(variety.resting({'A', 'A', 'B', 'A'}, 'A'))
  assert(variety.resting({'B', 'B'}, 'B') and not variety.resting({'B', 'C', 'B'}, 'B'))
  for _ = 1, 10 do h = variety.note(h, job('D')) end
  assert(#h == variety.KEEP, 'a short memory')
  assert(variety.key({ from = { n = 'Yard' } }) == 'Yard' and variety.key({}) == nil)
  assert(not variety.resting('broken', 'A') and #variety.note('broken', job('A')) == 1, 'a damaged save starts over')
end)

test('the phone skips a resting pickup unless nothing else is in reach', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  core.setMode('trucking')
  advance(core, 2)
  local generate, random = core.generate, math.random
  local places = { 'B', 'A', 'A' }
  core.generate = function()
    s.offers = {}
    for n, k in ipairs(places) do
      s.offers[#s.offers + 1] = { id = k .. n .. '>x', kind = 'cargo', cargoName = 'Pallets', from = { id = k, n = 'Yard ' .. k } }
    end
  end
  math.random = function(a, b) if b then return random(a, b) end return a or random() end   -- always the last candidate
  local ok, why = pcall(function()
    c.pickups = { 'A', 'A' }
    s.phone.online, s.phone.incoming, s.phone.nextPingAt, s.phone.declined = true, nil, 0, {}
    advance(core)
    assert(s.phone.incoming and s.phone.incoming.job.from.id == 'B', 'A just gave two orders: B rings')
    c.pickups = { 'A', 'A', 'B', 'C' }
    s.phone.incoming, s.phone.nextPingAt = nil, 0
    advance(core)
    assert(s.phone.incoming and s.phone.incoming.job.from.id == 'A', 'two others since: A rings again')
    places = { 'A', 'A' }
    c.pickups = { 'A', 'A' }
    s.phone.incoming, s.phone.nextPingAt = nil, 0
    advance(core)
    assert(s.phone.incoming and s.phone.incoming.job.from.id == 'A', 'only A in reach: it still rings')
  end)
  core.generate, math.random = generate, random
  assert(ok, why)
  c.pickups = nil
  core.generate()
  local own
  for k, offer in ipairs(s.offers) do if not offer.companyShift then own = k break end end
  if own then
    core.take(own)
    assert(c.pickups and c.pickups[1] == (s.offers[own].from.id or s.offers[own].from.n), 'a taken job is remembered')
  end
end)

test('a parcel route loads the van, empties the containers stop by stop and pays once at the last address', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if offer.route then i, job = k, offer break end end
  assert(job, 'a parcel route is offered in a van')
  -- the phone rings with it although three ordinary offers come first
  local generate, random = core.generate, math.random
  core.generate = function()
    generate()
    for n = 1, 3 do table.insert(s.offers, 1, { id = 'x' .. n, kind = 'cargo', cargoName = 'Pallets', from = { id = 'x' .. n, n = 'Yard' } }) end
  end
  math.random = function(a, b) if b then return random(a, b) end return a end   -- always the last candidate
  s.phone.online, s.phone.incoming, s.phone.nextPingAt = true, nil, 0
  advance(core)
  core.generate, math.random = generate, random
  assert(s.phone.incoming and s.phone.incoming.job.route, 'a parcel route reaches the phone')
  s.phone.incoming = nil
  core.generate()
  for k, offer in ipairs(s.offers) do if offer.route then i, job = k, offer break end end
  local stops = #job.route.stops
  core.take(i)
  assert(s.job == job and s.phase == 'toPickup')
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and math.abs(boxes[1].currentVolume - job.haul.amount * parcel.DENSITY) < 0.01, 'loaded')
  local money = c.money
  for n = 1, stops do
    local stop = job.route.stops[n]
    assert(job.to == stop)
    pose.lat, pose.lon = stop.g[1], stop.g[2]
    advance(core)
    if n < stops then
      assert(job.route.at == n + 1 and c.money == money, 'paid only at the end')
      assert(math.abs(boxes[1].currentVolume - parcel.left(job, true) * parcel.DENSITY) < 0.01, 'this stop took its parcels')
      -- the phone tells what came out and what is still on board
      local ps = core.phoneState()
      assert(ps.dropped and ps.dropped.kg == math.floor(stop.slots * parcel.DENSITY + 0.5), 'the phone shows the kg dropped')
      assert(math.abs(ps.dropped.left - parcel.left(job, true) * parcel.DENSITY) < 1, 'and the kg left')
      assert(math.abs(ps.active.loadKg - parcel.left(job, true) * parcel.DENSITY) < 0.1, 'the active screen shows the load')
      assert(ps.active.route.kg == math.floor(parcel.left(job, true) * parcel.DENSITY + 0.5), 'the route card too')
    end
  end
  local last = job.route.stops[stops]
  local ps = core.phoneState()
  assert(ps.dropped and ps.dropped.kg == last.slots * parcel.DENSITY and ps.dropped.left == 0, 'the last stop empties it')
  assert(not s.job and c.money > money and boxes[1].currentVolume == 0, 'emptied and paid')
  assert(core.careerState().reputation.freight.rated == 1)
end)

test('freight weighs like real loads: about 1 t in a van, 4-8 t in a box truck, 10-22 t on a semi', function()
  local haul = require('cargoEarth/haul')
  local trailers = require('cargoEarth/trailers')
  local box = function(slots) return { { id = 1, cargoTypes = { 'parcel' }, capacity = slots } } end
  local van = haul.freight('van', 'consumer_goods', box(96))
  assert(van and van.kg >= 600 and van.kg <= 1000, 'a van of consumer goods')
  assert(haul.freight('van', 'bricks', box(96)).kg <= 1000, 'a van never goes over 1 t')
  local rigid = haul.freight('rigid', 'pallets_general', box(640))
  assert(rigid.kg >= 4000 and rigid.kg <= 8000, 'a box truck of pallets')
  local semi = haul.freight('semi', 'consumer_goods')
  assert(semi.kg >= 10000 and semi.kg <= 22000, 'a box trailer of consumer goods')
  local gravel = haul.freight('semi', 'gravel')
  assert(trailers.AGGREGATE_L == haul.SEMI_BULK_L and gravel.amount <= haul.SEMI_BULK_L and gravel.kg >= 20000
    and gravel.kg <= 22000, 'gravel fills the aggregate boxes up to the semi limit')
end)

test('cargo weight: meals, parcel routes and freight count only once picked up', function()
  local meal = { kind = 'food', items = { { name = 'Pizza', qty = 2 }, { name = 'Cola', qty = 1 } } }
  assert(math.abs(cargo.weight(meal) - (0.2 + 2 * 0.55 + 0.25)) < 1e-9, 'a meal')
  local route = { kind = 'cargo', haul = { kind = 'parcel', density = parcel.DENSITY, kg = 80 },
    route = { at = 2, stops = { { slots = 4 }, { slots = 3 }, { slots = 3 } } } }
  assert(cargo.weight(route) == 6 * parcel.DENSITY, 'a route counts the parcels it has not dropped')
  local freight = { kind = 'cargo', haul = { kind = 'fluid', density = 0.83, kg = 3486 } }
  assert(cargo.weight(freight) == 3486 and cargo.weight({ kind = 'tow' }) == 0, 'freight and tow')
  assert(math.abs(cargo.onBoard({ { job = meal, phase = 'toDelivery' }, { job = freight, phase = 'toPickup' },
    { job = route, phase = 'toDelivery' } }) - (cargo.weight(meal) + 6 * parcel.DENSITY)) < 1e-9, 'only what is picked up')
  assert(parcel.DENSITY >= 8, 'parcels weigh enough to feel a stop')
end)

test('a parcel route GPS goes to the next undelivered address only, also after a teleport', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  core.setMode('trucking')
  advance(core, 2)
  routeCapable = true   -- even where Earth could route through every stop
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if offer.route then i, job = k, offer break end end
  assert(job, 'a parcel route is offered in a van')
  core.take(i)
  assert(gps and not gps.stops and gps.lat == job.from.g[1], 'to the depot')
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  local first, last = job.route.stops[1], job.route.stops[#job.route.stops]
  assert(s.phase == 'toDelivery' and gps and not gps.stops and gps.lat == first.g[1], 'loaded: the first address alone')
  -- the map's teleport lands at the round's last address: the current stop is still the first, and the GPS goes back
  -- to it once the world is loaded there
  pose.lat, pose.lon = last.g[1], last.g[2]
  gps = nil
  core.onBeamNGEarthTeleported({lat = last.g[1], lon = last.g[2]})
  core.onBeamNGEarthWorldReady()
  advance(core, 4)
  assert(job.route.at == 1 and gps and gps.lat == first.g[1] and gps.lon == first.g[2], 'back to the first address')
  -- Navigate on the phone: the next address again
  gps = nil
  core.phoneAction('gps')
  assert(gps and gps.lat == first.g[1], 'Navigate: the next undelivered address')
  -- served: on to the second address
  pose.lat, pose.lon = first.g[1], first.g[2]
  advance(core, 4)
  advance(core)
  local second = job.route.stops[2]
  assert(job.route.at == 2 and gps and not gps.stops and gps.lat == second.g[1], 'then the second address alone')
end)

test('a car parcel round and an SUV parts run can be saved', function()
  local persistence = require('cargoEarth/persistence')
  local function career(tier)
    return { money = 100, orders = { { phase = 'toDelivery', data = { id = 'route:x', from = { g = { 50, 14 } },
      to = { g = { 50.01, 14.01 } }, pay = 100, minutes = 30,
      haul = { tier = tier, kind = 'parcel', amount = 10, kg = 80, density = 8 } } } } }
  end
  assert(persistence.valid(career('car')) and persistence.valid(career('suv')) and persistence.valid(career('van')))
  assert(not persistence.valid(career('boat')))
end)

test('the kind of vehicle comes from its body: car, SUV or pickup, van, box truck, tractor', function()
  local haul = require('cargoEarth/haul')
  assert(haul.carrier({model = 'etk800', bodyStyle = 'Sedan'}) == 'car')
  assert(haul.carrier({model = 'roamer', bodyStyle = 'SUV'}) == 'suv')
  assert(haul.carrier({model = 'pickup', bodyStyle = 'Pickup'}) == 'suv')
  assert(haul.carrier({model = 'pickup'}) == 'suv', 'a known pickup without a style')
  assert(haul.carrier({model = 'covet'}) == 'car')
  assert(haul.carrier({model = 'van', bodyStyle = 'Van'}) == 'van')
  assert(haul.carrier({model = 'md_series'}) == 'rigid')
  assert(haul.carrier({model = 'us_semi', slotPartMap = {a = 'us_semi_fifthwheel_top'}}) == 'semi')
  assert(haul.carrier({model = 'unicycle'}) == nil and haul.carrier(nil) == nil)
  assert(haul.allowed({}, 'car') and haul.allowed({}, 'suv') and not haul.allowed({}, 'rigid'))
  -- small vehicles carry boxed goods only
  local rows = {{id = 1, cargoTypes = {'parcel', 'fluid'}, capacity = 100}}
  assert(haul.freight('suv', 'milk', rows) == nil and haul.freight('suv', 'car_parts', rows))
end)

test('a car gets no parcel rounds; an SUV parts runs from a supplier to a workshop', function()
  local seq = 0
  local function rnd(n) seq = seq % n + 1 return seq end
  local depot = {id = 'yard', n = 'Warehouse', g = {50, 14}}
  assert(not parcel.route(depot, streets(50, 14), 'car', 24, rnd, 1), 'parcel routes are for vans')
  local parts = require('cargoEarth/parts')
  local suppliers = {{id = 'p1', n = 'Parts Plus', g = {50.01, 14}, town = 'Town'}, {id = 'far', n = 'Far', g = {51, 14}}}
  local function workshops(lat, lon, a, b)
    local out = {}
    for _, w in ipairs({{id = 'g1', n = 'Auto Fix', g = {50.08, 14}}, {id = 'g0', n = 'Too close', g = {50.011, 14}}}) do
      local k = parts.km(lat, lon, w.g[1], w.g[2])
      if k >= a and k <= b then out[#out + 1] = w end
    end
    return out
  end
  local offers = parts.offers(suppliers, workshops, 50, 14, 10, rnd)
  assert(#offers == 1, 'only the near supplier, to a workshop far enough')
  local o = offers[1]
  assert(o.partsRun and o.from.id == 'p1' and o.to.id == 'g1' and o.haul.tier == 'suv' and o.haul.kind == 'parcel')
  assert(o.haul.amount <= 10 and o.pay > 0 and o.minutes > 0 and o.cargo == 'car_parts')
  assert(#parts.offers(suppliers, workshops, 50, 14, 3, rnd) == 0, 'too little room for parts')
  assert(#parts.offers(suppliers, workshops, 50, 14, 10, rnd, nil, {maxKm = 8}) == 0, 'the longest-job setting holds')
  assert(#parts.offers(suppliers, workshops, 50, 14, 10, rnd, nil, {minKm = 5, maxKm = 15}) == 1)
  assert(#parts.offers(suppliers, workshops, 50, 14, 10, rnd, function() return false end) == 0, 'a long detour is out')
  assert(#parts.offers(suppliers, workshops, 50, 14, 10, rnd, nil, {nearKm = 0.5}) == 0, 'the pickup-distance setting holds')
  local detour = parts.offers(suppliers, workshops, 50, 14, 10, rnd, function(a, b) return parts.km(a[1], a[2], b[1], b[2]) < 1 and 12 or nil end, {minKm = 10})
  assert(#detour == 1 and detour[1].to.id == 'g0' and detour[1].km == 12, 'a near workshop with a long road counts by its road')
  local near = parts.offers(suppliers, workshops, 50, 14, 10, rnd, function() return 8 end, {maxKm = 8.5})
  assert(#near == 1 and near[1].km == 8, 'a workshop just inside the road range is found by its road km')
end)

test('a pickup in freight mode is offered parts runs only, loads the parts into its boxes and is paid', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('pickup')
  vehicle.bodyStyle = 'Pickup'
  c.garage.car.model = 'pickup'
  s.autoIdx = fuel.index()
  fuel.addPack(s.autoIdx, {stations = {{'p1', 50.005, 14, 'Parts Plus', 'p', 'Town'}, {'g1', 50.08, 14, 'Auto Fix', 'g', 'Town'}}})
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do
    assert(offer.partsRun or offer.tow, 'no company freight board in a pickup')
    if offer.partsRun then i, job = k, offer end
  end
  assert(job and job.from.n == 'Parts Plus' and job.to.n == 'Auto Fix', 'a parts run from the helper places')
  assert(c.garage.car.vclass == 'suv' and core.phoneState().trucking.carrier == 'SUV or pickup')
  core.take(i)
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and math.abs(boxes[1].currentVolume - job.haul.amount * job.haul.density) < 0.01, 'loaded')
  local money = c.money
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(not s.job and c.money > money and boxes[1].currentVolume == 0, 'unloaded and paid')
end)

test('a small car in freight mode gets no parcel rounds and still sees company contracts', function()
  local core, s = fresh()
  s.career.garage.debt = 0
  vehicle.bodyStyle = 'Hatchback'
  boxes[1].capacity = 24
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  for _, offer in ipairs(s.offers) do
    assert(offer.tow, 'a car gets tow jobs in Freight; taxi rides have their own category')
  end
  local t = core.phoneState().trucking
  assert(t.carrier == 'Car' and #t.contracts == 1, 'company contracts are still listed')
  assert(t.hint and not t.hint:find('parcel'), 'the hint does not offer parcel rounds')
end)

-- addresses everywhere: a 5 x 5 grid in every 0.05 degree tile
local function everywhere(row, col)
  local rows = {}
  for a = 0, 4 do
    for b = 0, 4 do
      local lat, lon = row * 0.05 + 0.005 + a * 0.01, col * 0.05 + 0.005 + b * 0.01
      rows[#rows + 1] = {lat, lon, lat, lon, string.format('Street %d-%d %d%d', row, col, a, b), 'Town'}
    end
  end
  return rows
end

-- places people take a taxi to (the helper's 't' rows): a ring of sights 3-9 km around 50.02, 14.02
local function sightRows()
  local rows = {}
  for i = 1, 12 do
    local a, d = i * math.pi / 6, 0.03 + (i % 4) * 0.015
    rows[#rows + 1] = {'s' .. i, 50.02 + d * math.sin(a), 14.02 + d * 1.5 * math.cos(a), 'Sight ' .. i, 't', 'Town'}
  end
  rows[#rows + 1] = {'f1', 50.05, 14.05, 'A fuel station', 'f', 'Town'}
  return rows
end

test('taxi rules: a passenger near you, a sight at the ride length, paid by the km', function()
  local taxi = require('cargoEarth/taxi')
  local idx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  local places = fuel.index()
  fuel.addArea(places, 'k', sightRows())
  local function near(lat, lon, k) return food.addressesNear(idx, lat, lon, k) end
  local function sights(lat, lon, a, b)
    local out = {}
    for _, row in ipairs(fuel.within(places, lat, lon, 'sight', a, b)) do
      local d = row.station
      out[#out + 1] = { id = 'sight:' .. d.id, n = d.n, town = d.town, g = d.g }
    end
    return out
  end
  local seq = 0
  local function rnd(n) seq = seq % n + 1 return seq end
  local offers = taxi.offers(near, sights, 50.02, 14.02, rnd, nil, nil, 3)
  assert(#offers == taxi.OFFERS, 'three rides: ' .. #offers)
  local seen = {}
  for _, o in ipairs(offers) do
    assert(o.taxi and o.kind == 'taxi' and o.taxi.people >= 1 and o.taxi.people <= 3)
    assert(o.pickupKm <= taxi.NEAR_KM + 1e-9, 'the passenger waits near you')
    assert(o.to.id:sub(1, 6) == 'sight:' and o.to.n:find('^Sight'), 'rides end at a sight, not an address')
    assert(not seen[o.to.id], 'three different places') seen[o.to.id] = true
    assert(o.km >= taxi.KM[1] * taxi.ROAD_FACTOR - 1e-9 and o.km <= taxi.KM[2] * taxi.ROAD_FACTOR + 1e-9)
    local rules = taxi.MODES[o.taxi.mode]
    assert(rules, 'every ride has a mode: ' .. tostring(o.taxi.mode))
    assert(o.pay == math.floor((taxi.BASE + taxi.PER_KM * o.km) * (1 + 0.2 * (o.taxi.people - 1)) * rules.pay / 5 + 0.5) * 5 and o.minutes > 0)
    assert(cargo.supports(o) and cargo.handling(o) == 'Fragile', 'a rough ride is felt')
  end
  assert(#taxi.offers(near, sights, 50.02, 14.02, rnd, nil, {maxKm = 1}, 3) == 0, 'the longest-job setting holds')
  -- comfort and rush: the same ride, driven fast and rough or slow and smooth
  local function tipFn(pay, m, limit) return m < limit * 0.5 and 50 or 0 end
  local comfortRide, rushRide = { taxi = { people = 1, mode = 'comfort' } }, { taxi = { people = 1, mode = 'rush' } }
  local cp, ct = taxi.settle(comfortRide, 200, 20, 30, 0.02, 0.5, 100, tipFn)
  assert(cp == 200 and ct == 30, 'comfort, smooth: full fare and a 15 % smooth tip: ' .. cp .. ' ' .. ct)
  local cpRough, ctRough = taxi.settle(comfortRide, 200, 10, 30, 0.02, 0.5, 50, tipFn)
  assert(cpRough == 130 and ctRough == 0, 'comfort, rough and fast: speed earns nothing, bumps cost a lot: ' .. cpRough)
  local rp, rt = taxi.settle(rushRide, 200, 10, 30, 0.02, 0.5, 50, tipFn)
  assert(rp == 200 and rt == 100, 'rush, rough and fast: comfort is not counted, a double speed tip: ' .. rp .. ' ' .. rt)
  local rpLate = taxi.settle(rushRide, 200, 40, 30, 0.02, 0.5, 100, tipFn)
  assert(rpLate == 100, 'rush, ten minutes late: half the fare (floor): ' .. rpLate)
  assert(taxi.info({ taxi = { people = 2 } }).mode == 'comfort', 'an older ride counts as comfort')
  assert(#taxi.offers(near, sights, 50.02, 14.02, rnd, function() return false end, nil, 3) == 0, 'a long detour is out')
  assert(#taxi.offers(function() return {} end, sights, 50.02, 14.02, rnd, nil, nil, 3) == 0, 'no addresses, no rides')
  assert(#taxi.offers(near, function() return {} end, 50.02, 14.02, rnd, nil, nil, 3) == 0, 'no sights, no rides')
  assert(#taxi.offers(near, sights, 50.02, 14.02, rnd, nil, nil, 0) == 0, 'no passenger seats, no rides')
  for _ = 1, 5 do
    for _, o in ipairs(taxi.offers(near, sights, 50.02, 14.02, rnd, nil, nil, 1)) do
      assert(o.taxi.people == 1, 'one free seat: one passenger')
    end
  end
end)

test('Taxi is separate from Freight and passenger groups fit cars, SUVs and vans', function()
  local core, s = fresh()
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  s.autoIdx = fuel.index()
  fuel.addArea(s.autoIdx, 'taxi', sightRows())
  s.idx = nil   -- taxi pickup addresses must not depend on the freight depot index
  freeSeats = 1
  core.setMode('taxi')
  for _, row in ipairs({{'pigeon', 'Hatchback'}, {'roamer', 'SUV'}, {'van', 'Van'}}) do
    vehicle.model, vehicle.bodyStyle = row[1], row[2]
    s.career.garage.car.model = row[1]
    core.generate()
    assert(#s.offers > 0, row[2] .. ' with a verified passenger seat gets rides')
    assert(core.phoneState().taxi.eligible and not core.phoneState().trucking)
    for _, offer in ipairs(s.offers) do assert(offer.taxi and offer.taxi.people == 1 and not offer.tow and not offer.haul) end
  end
  local ride = s.offers[1]
  s.idx = idx
  vehicle.model, vehicle.bodyStyle, s.career.garage.car.model = 'pigeon', 'Hatchback', 'pigeon'
  core.setMode('trucking')
  for _, offer in ipairs(s.offers) do assert(not offer.taxi, 'Freight never offers passenger rides') end
  s.offers = {ride}
  core.take(1)
  assert(not s.job, 'a stale taxi offer cannot be accepted from Freight')
  freeSeats = nil
end)

test('Taxi rejects missing, loaned, unsuitable and unverifiable passenger vehicles', function()
  local core, s = fresh()
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  s.autoIdx = fuel.index()
  fuel.addArea(s.autoIdx, 'taxi', sightRows())
  core.setMode('taxi')
  for _, row in ipairs({{'citybus', 'Bus'}, {'md_series', 'Box Truck'}, {'us_semi', 'Truck'}, {'unicycle', ''}}) do
    vehicle.model, vehicle.bodyStyle = row[1], row[2]
    s.career.garage.car.model = row[1]
    freeSeats = 30
    s.freeSeats = nil
    core.generate()
    assert(#s.offers == 0 and not core.phoneState().taxi.eligible, row[1] .. ' cannot do taxi work')
  end
  vehicle.model, vehicle.bodyStyle, s.career.garage.car.model = 'pigeon', 'Hatchback', 'pigeon'
  for _, n in ipairs({0, -1, math.huge}) do
    freeSeats, s.freeSeats = n, nil
    core.generate()
    assert(#s.offers == 0 and not core.phoneState().taxi.eligible, 'only finite positive seat counts qualify')
  end
  freeSeats, s.freeSeats = nil, nil
  core.phoneAction('online')
  assert(not s.phone.online and core.phoneState().taxi.hint:find('could not be verified'))
  freeSeats, s.freeSeats = 3, nil
  s.career.garage.car.loaner = true
  core.generate()
  assert(#s.offers == 0 and not core.phoneState().taxi.eligible, 'loaners are reserved for contract work')
  s.career.garage.car.loaner = nil
  vehicle.model = 'someone_elses'
  assert(not core.taxiState(true).eligible, 'only the owned vehicle qualifies')
  vehicle.model, freeSeats, s.freeSeats = 'pigeon', 1, nil
  assert(core.taxiState().seats == 1)
  vehicle.id, freeSeats = 2, 3
  assert(core.taxiState().seats == 3, 'changing vehicle invalidates the cached seat count immediately')
  freeSeats = nil
end)

test('Taxi distance settings are independent and old saved rides resume in Taxi', function()
  local core, s = fresh()
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  s.autoIdx = fuel.index()
  fuel.addArea(s.autoIdx, 'taxi', sightRows())
  freeSeats = 3
  core.setMode('taxi')
  local defaults = core.settingsState().items
  assert(#defaults == 3 and defaults[2].value < 2 and defaults[3].value > 15, 'taxi-specific distance defaults')
  core.settingsDo('step', 'nearKm', -1)
  assert(core.jobOptions('taxi').nearKm == 1)
  core.setMode('courier')
  assert(core.jobOptions('courier').nearKm == food.defaults.nearKm, 'food pickup range is unchanged')
  core.setMode('taxi')
  assert(core.jobOptions('taxi').nearKm == 1)
  core.take(1)
  assert(s.job and s.job.taxi)
  local id = s.job.id
  core.setMode('bus')
  assert(s.mode == 'taxi', 'active ride locks the category')
  core.saveOptions()
  local saved = copy(s.career)
  saved.mode = 'trucking'   -- the format used before Taxi was split out
  s.pendingCareer = saved
  core.phoneAction('resume')
  assert(s.mode == 'taxi' and s.opts == s.optsByMode.taxi and core.jobOptions('taxi').nearKm == 1)
  assert(s.job.id == id and s.phase == 'toPickup', 'the active ride is preserved')
  freeSeats = nil
end)

test('Taxi requests helper locations even with a complete restaurant pack and refreshes sight-only updates', function()
  local core, s = fresh()
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  s.fuelIdx = nil
  freeSeats = 3
  core.HELPER_MIN = 0   -- the restaurant pack is sufficient
  core.setMode('taxi')
  local helper = require('cargoEarth/helper')
  local original, asked = helper.tick, 0
  helper.tick = function(_, _, _, _, _, camerasOnly) if not camerasOnly then asked = asked + 1 end end
  advance(core, 4)
  helper.tick = original
  assert(asked > 0, 'Taxi always streams pickup addresses and destinations')
  s.offeredAt = {lat = 50, lon = 14}
  core.onHelperArea({key = '500_140', restaurants = {}, autos = sightRows()})
  assert(s.offeredAt == nil, 'sights arriving without new restaurants must refresh offers')
  local originalStatus = helper.status
  helper.status = function() return {state = 'ready', supportsAutos = false} end
  assert(core.taxiState().search:find('Update'), 'old helper capabilities have an explicit explanation')
  helper.status = function() return {state = 'error', msg = 'Offline'} end
  assert(core.taxiState().search:find('Offline'), 'helper errors reach the Taxi screen')
  helper.status = function() return {state = 'loading'} end
  assert(core.taxiState().search:find('Loading passenger'), 'search progress is specific to Taxi')
  helper.status, freeSeats = originalStatus, nil
end)

test('a taxi ride in a car: the passenger sits in, rides to the sight, pays and gets out', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  vehicle.bodyStyle = 'Hatchback'
  riders, freeSeats = nil, nil
  s.config.spawnTrailer, s.config.requireTrailer = true, true   -- the game's defaults: a taxi needs no trailer
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    everywhere)
  core.setMode('taxi')
  advance(core, 2)
  s.autoIdx = fuel.index()
  core.generate()
  for _, offer in ipairs(s.offers) do assert(not offer.taxi, 'no sights known, no taxi rides') end
  fuel.addArea(s.autoIdx, 'k', sightRows())
  core.generate()
  freeSeats = 0   -- a car with no passenger seats (a two-seater with the seat on the cargo side, say)
  s.freeSeats = nil
  core.generate()
  for _, offer in ipairs(s.offers) do assert(not offer.taxi, 'no passenger seats, no taxi rides') end
  freeSeats = 4
  s.freeSeats = nil
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if offer.taxi then i, job = k, offer end end
  assert(job, 'a car is offered taxi rides')
  assert(job.to.n:find('^Sight'), 'to a sight')
  freeSeats = job.taxi.people - 1   -- switched to a smaller car after the offer came
  core.take(i)
  assert(s.job ~= job, 'more passengers than free seats: the ride is refused')
  freeSeats = nil   -- a mod car without the seat system: the group must fit verified seats
  core.take(i)
  assert(s.job ~= job, 'unknown seat count cannot guarantee room for the group')
  freeSeats = 4
  core.take(i)
  assert(s.job == job and s.phase == 'toPickup')
  assert(core.phoneState().active.taxi.people == job.taxi.people)
  pose.lat, pose.lon, pose.speed = job.from.g[1], job.from.g[2], 0
  local ownModel = vehicle.model
  vehicle.model = 'someone_elses'
  advance(core, 10)
  assert(s.phase == 'toPickup', 'nobody gets into another car')
  vehicle.model = ownModel
  freeSeats = 0
  advance(core, 10)
  assert(s.phase == 'toPickup', 'seat changes after acceptance must also prevent boarding')
  freeSeats = 4
  advance(core)
  assert(s.phase == 'toDelivery' and riders == job.taxi.people, 'the passengers sit in the car')
  s.taxiSeated, riders = nil, 0   -- as a loaded save: the ride is on, nobody seated yet
  advance(core)
  assert(riders == job.taxi.people, 'a resumed ride seats its passengers again')
  local money = c.money
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(not s.job and c.money > money, 'paid at the sight')
  advance(core, 4)
  assert(riders == 0, 'and they get out')
end)

test('taxi seating retries and passengers clear on cancel and pause and return on resume', function()
  local core, s = fresh()
  vehicle.model, vehicle.bodyStyle, s.career.garage.car.model = 'van', 'Van', 'van'
  s.career.garage.debt = 0
  s.fidx = food.index({restaurants = {}, cats = {}, tile = 0.05}, everywhere)
  s.autoIdx = fuel.index()
  fuel.addArea(s.autoIdx, 'taxi', sightRows())
  freeSeats = 7
  core.random = function(n) return n or 0.99 end
  core.setMode('taxi')
  local ride = assert(s.offers[1])
  assert(ride.taxi.people == 7)
  assert(ride.pay == ride.taxi.fare.fare + ride.fuelAllowance, 'fuel is added separately from the passenger fare')
  s.phone.online, s.phone.incoming = true, {job = ride, expiresAt = s.clock + 20}
  assert(core.phoneState().incoming.taxi.fare.passengerBonus == ride.taxi.fare.passengerBonus, 'offer exposes its stored breakdown')
  core.take(1)
  pose.lat, pose.lon = ride.from.g[1], ride.from.g[2]
  local bad = true
  core.G.carPassengers = function(n)
    if n > 0 and bad then return nil end
    riders = n
    return n
  end
  advance(core, 10)
  assert(s.phase == 'toPickup' and riders == 0 and core.phoneState().active.taxi.boardingError, 'failed seating does not start a paid ride')
  bad = false
  advance(core)
  assert(s.phase == 'toDelivery' and riders == 7 and not ride.taxi.boardingError)
  local pay = ride.pay
  core.saveOptions()
  core.settingsDo('pause')
  assert(s.pendingCareer and riders == 0, 'pausing removes passenger mass')
  core.phoneAction('resume')
  s.fidx = nil -- restoring occupants must not wait for geographic data
  advance(core, 2)
  assert(s.phase == 'toDelivery' and riders == 7 and s.job.pay == pay and s.job.taxi.fare.passengerRate > 1)
  local clearFails = true
  core.G.carPassengers = function(n)
    if n == 0 and clearFails then return nil end
    riders = n
    return n
  end
  core.cancel(true)
  assert(not s.job and s.taxiSeated and s.taxiSeated.n == 0, 'a failed removal is kept for retry')
  clearFails = false
  advance(core, 12)
  assert(riders == 0 and not s.taxiSeated, 'cancelled passengers clear even while map data is unavailable')
  freeSeats = nil
end)

local cameras = require('cargoEarth/cameras')

test('camera rules: tolerance, fine bands, assumed limits and one fine per pass', function()
  local idx = cameras.index()
  assert(cameras.set(idx, {{'a', 50, 14, 50, 'primary'}, {'b', 50.1, 14, 0, 'residential'}, {'c', 50.2, 14, 0, ''},
    {'bad', 500, 14, 50, ''}}, 'ready') == 2, 'a camera with no limit and no road class is left out')
  assert(cameras.refresh(idx, 49.999, 14) == 1)
  assert(cameras.fine(7) == 200 and cameras.fine(20) == 500 and cameras.fine(21) == 1500 and cameras.fine(80) == 3000)
  local function drive(kmh, t)
    local flash
    for step = -5, 5 do flash = cameras.pass(idx, 50 + step * 0.0001, 14, kmh, t + step) or flash end
    return flash
  end
  assert(not drive(56, 0), 'six over is let go')
  local flash = drive(72, 100)
  assert(flash and flash.speed == 72 and flash.limit == 50 and flash.over == 22 and flash.fine == 1500 and not flash.assumed)
  assert(not drive(90, 130), 'the same camera does not fine again at once')
  assert(drive(90, 300).fine == 1500)
  local ahead = cameras.ahead(idx, 49.998, 14, 0)
  assert(ahead and ahead.limit == 50 and ahead.m == 220, 'a camera ahead is named')
  assert(not cameras.ahead(idx, 49.998, 14, 180), 'a camera behind is not')
  cameras.refresh(idx, 50.1, 14)
  for step = -5, 5 do flash = cameras.pass(idx, 50.1 + step * 0.0001, 14, 75, 500 + step) or flash end
  assert(flash.limit == 60 and flash.assumed and flash.fine == 500)
end)

test('a speed camera fines the driver and costs a star on the order on board', function()
  local core, s = fresh()
  core.CAMERAS_PAUSED = false -- exercise dormant camera rules independently of the feature pause
  s.career.garage.debt = 0
  core.onHelperCameras({state = 'ready', cameras = {{'n1', 50.001, 14, 50, 'primary'}}})
  advance(core, 2)
  s.job = {id = 'j1', kind = 'food', from = {g = {50, 14}}, to = {g = {50.05, 14}}, pay = 100, minutes = 30}
  s.phase = 'toDelivery'
  s.orders[1] = {job = s.job, phase = 'toDelivery'}
  pose.speed, pose.heading = 80 / 3.6, 0
  assert(core.phoneState().camera.limit == 50)
  for step = 0, 20 do
    pose.lat = 50 + step * 0.0001
    core.onUpdate(0.1, 0.1)
  end
  assert(s.career.money == 1000 - 1500 + 500 and s.career.garage.debt == 500, 'the wallet pays what it has; the rest is owed')
  assert(s.job.starPenalty == 1 and s.career.fines.count == 1 and s.career.fines.paid == 1500)
  local flash = core.phoneState().flash
  assert(flash and flash.speed == 80 and flash.fine == 1500 and flash.owed == 500 and flash.stars == 1)
  assert(rating.stars(10, 30, 100, s.job.starPenalty) == 4)
  -- switched off in the settings: nothing is measured
  assert(core.settingsDo('cameras', false).cameras.on == false)
  -- dark mode and the folded phone live outside the career, in the player's own file and the game's state
  local written
  core.uiStore.write = function(t) written = t end
  assert(core.settingsDo('dark', true).dark == true and written.dark == true and core.phoneState().dark == true)
  assert(core.settingsDo('dark', false).dark == false and written.dark == false)
  core.phoneFold(true, 'waiting')
  assert(core.phoneState().fold == 'waiting')
  core.phoneFold(false)
  assert(core.phoneState().fold == false)
  s.career.money = 5000
  pose.lat = 49.999
  for step = 0, 30 do
    pose.lat = 49.999 + step * 0.0001
    core.onUpdate(0.1, 0.1)
  end
  assert(s.career.money == 5000 and not core.phoneState().camera)
end)

local speedlimit = require('cargoEarth/speedlimit')

-- a straight road along x, a node every 50 m from -500 to 500; speed(i) is the m/s of the edge from node i to i + 1
local function straightRoad(speed)
  local nodes = {}
  for i = -10, 10 do nodes['n' .. i] = {pos = {x = i * 50, y = 0}, links = {}} end
  for i = -10, 9 do
    local l = {speedLimit = speed(i)}
    nodes['n' .. i].links['n' .. (i + 1)], nodes['n' .. (i + 1)].links['n' .. i] = l, l
  end
  return {nodes = nodes}
end

test('speed limit from the road graph: bends do not lower it, a change ahead is not shown early, mph signs', function()
  assert(speedlimit.at(straightRoad(function() return 13.89 end), 'n0', 'n1') == 50)
  -- a sharp bend: Earth slows its traffic there, the sign does not change; a faster crossing road does not count
  local bend = straightRoad(function(i) return (i >= -1 and i <= 1) and 8 or 13.89 end)
  local cross = {speedLimit = 36.11}
  bend.nodes.side = {pos = {x = 0, y = 50}, links = {n0 = cross}}
  bend.nodes.n0.links.side = cross
  assert(speedlimit.at(bend, 'n0', 'n1') == 50, 'the bend keeps the limit of the road on both sides')
  -- a short posted 30 between stretches of 50 is a real limit, not a bend
  local zone = straightRoad(function(i) return (i >= 0 and i <= 1) and 8.33 or 13.89 end)
  assert(speedlimit.at(zone, 'n0', 'n1') == 30 and speedlimit.at(zone, 'n1', 'n2') == 30)
  -- a bend whose road around it is not in the graph: shown, but not a posted limit
  local short = straightRoad(function(i) return (i == 0) and 8 or 0 end)
  local kmh, _, _, sure = speedlimit.at(short, 'n0', 'n1')
  assert(kmh == 29 and sure == false)
  assert(select(4, speedlimit.at(bend, 'n0', 'n1')) == true)
  -- 50 now, 90 from x = 0 on
  local change = straightRoad(function(i) return i < 0 and 13.89 or 25 end)
  assert(speedlimit.at(change, 'n-1', 'n0') == 50 and speedlimit.at(change, 'n0', 'n1') == 90)
  assert(speedlimit.at(change, 'n1', 'n0') == 90, 'either node order')
  local kmh, sign, unit = speedlimit.at(straightRoad(function() return 13.41 end), 'n0', 'n1')
  assert(kmh == 48 and sign == 30 and unit == 'mph')
  assert(select(3, speedlimit.at(straightRoad(function() return 22.22 end), 'n0', 'n1')) == 'km/h', '80 km/h stays km/h')
  assert(speedlimit.at(straightRoad(function() return 0 end), 'n0', 'n1') == nil)
  -- with the country known: Earth's 35 mph fallback in Czechia is no sign; in the US it is
  local kmhCz, signCz, unitCz, sureCz = speedlimit.at(straightRoad(function() return 15.65 end), 'n0', 'n1', speedlimit.unitsFor('CZ'))
  assert(kmhCz == 56 and signCz == nil and unitCz == 'km/h' and sureCz == false)
  local _, signUs, unitUs = speedlimit.at(straightRoad(function() return 15.65 end), 'n0', 'n1', speedlimit.unitsFor('US'))
  assert(signUs == 35 and unitUs == 'mph')
  assert(select(2, speedlimit.at(straightRoad(function() return 13.89 end), 'n0', 'n1', 'km/h')) == 50)
  assert(select(3, speedlimit.at(straightRoad(function() return 26.82 end), 'n0', 'n1', 'mph')) == 'mph', '60 mph in the UK')
  assert(speedlimit.unitsFor('gb') == 'mph' and speedlimit.unitsFor('DE') == 'km/h' and speedlimit.unitsFor(nil) == nil)
  -- BeamNG.Earth 1.10 keeps the legal limit on each edge (posted: + the map's, - the road class default): no guess
  local legal = straightRoad(function() return 15.65 end)
  for _, n in pairs(legal.nodes) do for _, l in pairs(n.links) do l.speedLimit, l.posted = 8, -13.89 end end
  local kmhP, signP, unitP, sureP = speedlimit.at(legal, 'n0', 'n1', speedlimit.unitsFor('CZ'))
  assert(kmhP == 50 and signP == 50 and unitP == 'km/h' and sureP == true, 'a bend speed does not hide the posted 50')
  legal.nodes.n0.links.n1.posted = 15.65
  assert(select(2, speedlimit.at(legal, 'n0', 'n1', 'mph')) == 35, 'a mapped 35 mph')
  assert(speedlimit.postedOf({posted = 0}) == nil and speedlimit.postedOf({}) == nil)
  assert(speedlimit.at({}, 'n0', 'n1') == nil and speedlimit.at(nil, 'a', 'b') == nil)
end)

test('the phone shows the limit under the car, red when too fast, and a camera without a limit takes its road one', function()
  local core, s = fresh()
  core.CAMERAS_PAUSED = false
  s.career.garage.debt = 0
  local road = straightRoad(function() return 13.89 end)
  local near = 3
  core.G.road = function() return road, 'n0', 'n1', near end
  pose.x, pose.y, pose.z, pose.speed = 0, 0, 0, 45 / 3.6
  advance(core, 2)
  local limit = core.phoneState().limit
  assert(limit and limit.sign == 50 and limit.unit == 'km/h' and not limit.over)
  pose.speed = 60 / 3.6
  assert(core.phoneState().limit.over, 'red at 60 in a 50')
  near = 60
  advance(core, 2)
  assert(core.phoneState().limit == nil, 'off the road: no sign')
  core.onHelperCameras({state = 'ready', cameras = {{'n9', 50.001, 14, 0, 'primary'}}})
  pose.speed, pose.heading = 0, 0
  advance(core, 6)
  assert(core.phoneState().camera.limit == 100, 'the class default while the graph does not reach the camera')
  near = 3
  advance(core, 6)
  assert(core.phoneState().camera.limit == 50, 'the road graph gives the camera its limit')
  -- a camera in a bend the graph cannot resolve yet keeps the default and is asked again
  local bendOnly = straightRoad(function(i) return (i == 0) and 8 or 0 end)
  core.G.road = function() return bendOnly, 'n0', 'n1', 3 end
  core.onHelperCameras({state = 'ready', cameras = {{'n8', 50.001, 14, 0, 'primary'}}})
  advance(core, 6)
  assert(core.phoneState().camera.limit == 100, 'a bend speed never fines')
  core.G.road = function() return road, 'n0', 'n1', 3 end
  advance(core, 6)
  assert(core.phoneState().camera.limit == 50, 'learned once the road is known')
  pose.x, pose.y, pose.z = nil, nil, nil
end)

local firm = require('cargoEarth/firm')
local fleet = require('cargoEarth/fleet')

local function established()
  local c = {money = 20000, delivered = 30, home = {town = 'Brno', g = {50, 14}, capacity = 3}}
  for _ = 1, 5 do rating.add(c, 'courier', 5) end
  return c
end

test('a firm needs rank, reputation, no debt and the fee', function()
  local c = {money = 20000, delivered = 29}
  local list, ok = firm.requirements(c, 0)
  assert(not ok and not list[1].done and not list[2].done and list[3].done and list[4].done)
  assert(not firm.found(c, 'Early'))
  c = established()
  assert(not firm.found(c, 'Owing', 50) and c.money == 20000, 'a debt blocks founding')
  c.money = firm.FEE - 1
  assert(not firm.found(c, 'Poor'))
  c.money = 20000
  local okFound = firm.found(c, '  <b>Rychlá   kola</b> s. r. o. a velmi dlouhý název  ')
  assert(okFound and c.money == 20000 - firm.FEE and #c.firm.name <= firm.NAME_MAX and not c.firm.name:find('[<>]'))
  assert(c.accounts.history[1].category == 'firm')
  assert(not firm.found(c, 'Again') and c.money == 20000 - firm.FEE, 'only one firm')
  local empty = established()
  assert(firm.found(empty, '') and empty.firm.name == 'Brno Cargo', 'no name: one is suggested')
end)

test('headquarters, upgrades and what they change', function()
  local c = established()
  assert(firm.found(c, 'Kola'))
  assert(not firm.upgrade(c, 'bays', 0), 'no upgrades before a headquarters')
  local yard = {id = 'd1', n = 'Sklad Sever', town = 'Brno', g = {50.01, 14}}
  assert(not firm.setHq(c, yard, {lat = 50.01, lon = 14, speed = 10}), 'must be parked')
  assert(not firm.setHq(c, nil, {lat = 50.3, lon = 14, speed = 0}), 'must be at a real place')
  assert(firm.setHq(c, yard, {lat = 50.0101, lon = 14.0001, speed = 0}))
  assert(c.firm.hq.n == 'Sklad Sever' and c.firm.hq.g[1] == 50.0101, 'the parking point is the gate')
  assert(firm.atHq(c, {lat = 50.0103, lon = 14.0001}) and not firm.atHq(c, {lat = 50.02, lon = 14}))
  local before = c.money
  assert(firm.capacity(c) == 3 and firm.driverFactor(c) == 1 and firm.repairFactor(c, {lat = 50.0101, lon = 14.0001}) == 1)
  assert(not firm.upgrade(c, 'bays', 10), 'a debt blocks upgrades')
  assert(firm.upgrade(c, 'bays', 0) and firm.capacity(c) == 5 and c.money == before - 4000)
  assert(firm.upgrade(c, 'workshop', 0) and firm.repairFactor(c, {lat = 50.0101, lon = 14.0001}) == 0.85)
  assert(firm.repairFactor(c, {lat = 50.2, lon = 14}) == 1, 'the workshop only works at the headquarters')
  c.money = 100
  assert(not firm.upgrade(c, 'office', 0))
  c.money = 50000
  assert(firm.upgrade(c, 'office', 0) and firm.upgrade(c, 'office', 0) and not firm.upgrade(c, 'office', 0))
  assert(firm.driverFactor(c) == 1.3)
  local moved = c.money
  assert(firm.setHq(c, {id = 'home', n = 'Home office', g = {50, 14}}, {lat = 50, lon = 14, speed = 0}) and c.money == moved - firm.MOVE_FEE)
  local state = firm.state(c, {lat = 50, lon = 14}, 0)
  assert(state.founded and state.hq.here and state.capacity == 5 and state.upgrades[1].level == 1 and state.upgrades[4].cost == nil)
  -- a damaged save is repaired, not trusted
  c.firm.upgrades = {bays = 99, bogus = 2, tank = 'x'}
  c.firm.hq = {g = {500, 14}}
  firm.restore(c)
  assert(c.firm.upgrades.bays == 3 and c.firm.upgrades.bogus == nil and c.firm.upgrades.tank == nil and c.firm.hq == nil)
end)

test('drivers are hired by a firm with a headquarters; the office raises what they bring in', function()
  local c = established()
  local g = {parked = {{fleetId = 1, name = 'Van', model = 'van'}}, debt = 0}
  local ok, why = fleet.hire(g, c, 1)
  assert(not ok and why:find('Start a firm'))
  assert(firm.found(c, 'Kola'))
  ok, why = fleet.hire(g, c, 1)
  assert(not ok and why:find('headquarters'))
  assert(firm.setHq(c, {id = 'home', n = 'Home office', g = {50, 14}}, {lat = 50, lon = 14, speed = 0}))
  local calm = function() return 0.99 end   -- no incident
  local list = fleet.applicants(c.firm, 0, function() return 0.5 end)
  assert(#list == fleet.APPLICANTS and math.abs(list[1].speed - 1.03) < 0.015 and list[1].care == 1
    and list[1].wage == fleet.wage(list[1].speed, 1) and list[1].wage >= 15 and list[1].wage <= 70)
  local pick = list[2]
  assert(fleet.hire(g, c, 1, pick.id) and g.parked[1].driver.name == pick.name and #c.firm.applicants == 2)
  local van = g.parked[1]
  local net = math.floor(fleet.GROSS.van * pick.speed + 0.5) - pick.wage
  assert(fleet.net(van.driver, van, 1) == net and fleet.advance(g, fleet.SHIFT_S, firm.driverFactor(c), c, calm) == net)
  assert(van.km > 0 and van.service.oil > 0, 'the van wears')
  c.money = 50000
  assert(firm.upgrade(c, 'office', 0))
  assert(fleet.advance(g, fleet.SHIFT_S, firm.driverFactor(c), c, calm) == math.floor(fleet.GROSS.van * pick.speed * 1.15 + 0.5) - pick.wage)
  -- a driver from before 0.4 keeps working without a firm: an average driver (wage 25) in a car
  local old = {parked = {{fleetId = 1, name = 'Pigeon', model = 'pigeon', driver = {elapsed = 0, earned = 0}}}}
  assert(fleet.advance(old, fleet.SHIFT_S, 1, nil, calm) == fleet.NET_PER_SHIFT and old.parked[1].driver.name)
end)

test('the firm in the game: founded from the phone, headquarters at a real yard, bays lift the car limit', function()
  local core, s = fresh()
  fuelAdapter(core)
  local c = s.career
  c.garage.debt, c.money, c.delivered = 0, 30000, 30
  for _ = 1, 5 do rating.add(c, 'freight', 5) end
  local state = core.careerState().firm
  assert(not state.founded and state.ready and state.fee == firm.FEE)
  state = core.firmDo('found', 'Kola')
  assert(state.founded and state.name == 'Kola' and not state.hq and c.money == 30000 - firm.FEE)
  local yard = idx.depots[1]
  pose.lat, pose.lon = yard.g[1] + 0.0003, yard.g[2]
  state = core.firmState()
  assert(state.place and state.place.name == yard.n, 'the yard beside the car is offered')
  pose.lat = yard.g[1] + 0.3
  assert(not core.firmDo('setHq').hq, 'nowhere near a real place')
  pose.lat = yard.g[1] + 0.0003
  state = core.firmDo('setHq')
  assert(state.hq and state.hq.name == yard.n and state.hq.here)
  assert(core.garageState().capacity == 3)
  state = core.firmDo('upgrade', 'bays')
  assert(core.garageState().capacity == 5 and state.upgrades[1].level == 1)
  local hq = core.hqState()
  assert(#hq.bays == 1 and hq.bays[1].current and hq.free == 4 and hq.drivers.can and hq.drivers.count == 0)
  -- the workshop repairs for less at the headquarters
  core.firmDo('upgrade', 'workshop')
  core.G.repair = function() end
  c.garage.repair = 1000
  local money = c.money
  hq = core.hqDo('repair')
  assert(c.money == money - 850 and c.garage.repair == 0 and hq.msg:find('workshop'), tostring(hq.msg))
  -- the discounted price is what has to be affordable
  c.garage.repair, c.money = 1000, 900
  hq = core.hqDo('repair')
  assert(c.money == 50 and c.garage.repair == 0, tostring(hq.msg))
  c.garage.repair, c.money = 1000, 800
  core.hqDo('repair')
  assert(c.money == 800 and c.garage.repair == 1000, 'not enough even after the discount')
  -- it survives a save and a reload
  package.loaded['cargoEarth/core'] = nil
  assert(disk['/settings/cargoEarth/career.json'].firm.hq.n == yard.n)
end)

local upkeep = require('cargoEarth/upkeep')

test('upkeep: wear by km, service at a price, overdue service makes breakdowns likelier', function()
  local car = {name = 'Pigeon', model = 'pigeon', starter = true}
  local st = upkeep.state(car)
  assert(st.items[1].id == 'oil' and st.items[1].share == 0.6 and not st.items[1].due, 'a starter comes worn')
  assert(upkeep.chance(car, 10) == 0, 'nothing overdue, no breakdowns')
  upkeep.wear(car, 800)
  st = upkeep.state(car)
  assert(st.items[1].due and st.items[2].soon == false and st.due >= 1)
  assert(upkeep.chance(car, 100) > 0 and upkeep.chance(car, 100000) == upkeep.MAX_CHANCE)
  assert(upkeep.cost({model = 'us_semi'}, 'oil') == math.floor(upkeep.byId.oil.cost * 3.2 / 5 + 0.5) * 5, 'a tractor costs more')
  local c = {money = 50}
  local ok, why = upkeep.service(c, car, nil, 1)
  assert(not ok and why:find('Not enough'))
  c.money = 5000
  ok = upkeep.service(c, car, nil, 0.7, 'the headquarters')
  assert(ok and car.service.oil == 0 and c.money == 5000 - upkeep.cost(car, 'oil', 0.7) - upkeep.cost(car, 'brakes', 0.7))
  assert(c.accounts.history[1].category == 'upkeep')
  -- a breakdown: the most overdue item fails; what the wallet cannot pay is owed
  upkeep.wear(car, 5000)
  local failure = upkeep.breakdown(car)
  assert(failure.id == 'oil' and failure.cost > 0 and failure.text:find('oil'))
  local g = {debt = 0}
  c.money = 10
  local paid, owed = upkeep.roadside(c, g, car, failure)
  assert(paid == 10 and owed == failure.cost - 10 and g.debt == owed and car.service.oil == 0)
  -- a used car is as worn as its condition
  assert(upkeep.state({model = 'pigeon', condition = 0.5}).items[1].share == 0.5)
end)

test('the debt lists where it comes from and what paid it off', function()
  local garage = require('cargoEarth/garage')
  local g = {debt = 100}   -- an older save: a debt with no charges listed
  garage.addDebt(g, 200, 'fine', 'Speed camera: 80 km/h, limit 50')
  garage.addDebt(g, 50, 'fuel', 'Roadside fuel delivery')
  garage.addDebt(g, 30, 'fuel', 'Fuel at Pump')
  local info = garage.debtInfo(g)
  assert(info.total == 380 and g.debt == 380)
  assert(info.sources[1].kind == 'fine' and info.sources[1].amount == 200)
  assert(info.sources[2].kind == 'earlier' and info.sources[2].amount == 100)
  assert(info.sources[3].kind == 'fuel' and info.sources[3].amount == 80 and info.sources[3].count == 2)
  -- payments clear the oldest charges first
  assert(garage.takeForDebt(g, 300, 'Delivery to Mělník') == 150 and g.debt == 230)
  info = garage.debtInfo(g)
  assert(#info.sources == 2 and info.sources[1].kind == 'fine' and info.sources[1].amount == 150)
  assert(info.log[1].amount == -150 and info.log[1].left == 230 and info.log[1].what == 'Delivery to Mělník')
  assert(info.log[2].amount == 30 and info.log[2].kind == 'fuel')
  local career = {money = 1000}
  assert(garage.payDebt(g, career) and g.debt == 0 and career.money == 770)
  info = garage.debtInfo(g)
  assert(#info.sources == 0 and #info.open == 0 and info.log[1].kind == 'paid')
  -- something set the number alone (the debug editor, a company shift): the list follows it
  g.debt = 40
  info = garage.debtInfo(g)
  assert(#info.sources == 1 and info.sources[1].amount == 40)
  g.debt = 0
  assert(#garage.debtInfo(g).open == 0)
  -- a free repair and roadside help are listed too
  local h = {repair = 0, lastDamage = 0}
  garage.trackDamage(h, 1000)
  assert(garage.trackDamage(h, 0) == 'debt' and garage.debtInfo(h).sources[1].kind == 'repair')
  local car = {model = 'pigeon', service = {}}
  upkeep.ensure(car)
  local failure = {id = 'oil', cost = 100}
  upkeep.roadside({money = 0}, h, car, failure)
  assert(garage.debtInfo(h).log[1].kind == 'roadside' and garage.debtInfo(h).log[1].amount == 100)
  -- a failed refuel takes back its own charge, not older ones
  local r = {debt = 0}
  garage.addDebt(r, 100, 'fine', 'Speed camera')
  garage.addDebt(r, 50, 'fuel', 'Roadside fuel delivery')
  assert(garage.cancelDebt(r, 50, 'fuel', 'Refund') == 50 and r.debt == 100)
  local ri = garage.debtInfo(r)
  assert(#ri.sources == 1 and ri.sources[1].kind == 'fine' and ri.sources[1].amount == 100 and ri.log[1].kind == 'refund')
  for _ = 1, 50 do garage.addDebt(h, 1, 'fuel', 'x') end
  assert(#h.debtParts <= garage.DEBT_PARTS_MAX and #h.debtLog <= garage.DEBT_LOG_MAX)
  local sum = 0
  for _, p in ipairs(h.debtParts) do sum = sum + p.left end
  assert(sum == h.debt)
end)

test('your car breaks down after skipped service; roadside help gets it going', function()
  local core, s = fresh()
  fuelAdapter(core)
  local g = s.career.garage
  g.debt = 0
  local stalls = {}
  core.G.stall = function(on) stalls[#stalls + 1] = on return true end
  upkeep.ensure(g.car).oil = 3000
  core.random = function(a, b) if a then return b and a or 1 end return 0 end   -- every roll fails
  pose.speed = 40
  advance(core, 70)   -- 35 s: over a km
  pose.speed = 0
  assert(g.car.breakdown and g.car.breakdown.id == 'oil' and stalls[1] == true, 'the engine stops')
  local state = core.garageState()
  assert(state.breakdown and state.breakdown.cost == g.car.breakdown.cost)
  local cost = g.car.breakdown.cost
  -- the breakdown is saved with the car
  local saved = copy(s.career)
  assert(saved.garage.car.breakdown and saved.garage.car.breakdown.id == 'oil', 'a breakdown survives a save')
  s.career.money = 5000
  state = core.garageDo('roadside')
  assert(not g.car.breakdown and stalls[#stalls] == false and s.career.money == 5000 - cost and g.car.service.oil == 0)
  -- a parked car keeps its breakdown: no driver for it until the headquarters repairs it
  local fleet, garage = require('cargoEarth/fleet'), require('cargoEarth/garage')
  local parkedCar = { fleetId = 99, name = 'Broken Pigeon', model = 'pigeon', km = 0,
    breakdown = { id = 'tyres', text = 'A worn tyre burst.', cost = 500 }, service = { oil = 0, tyres = 3000, brakes = 0 } }
  g.parked = g.parked or {}
  g.parked[#g.parked + 1] = parkedCar
  assert(garage.parkedRepairCost(parkedCar) == 500)
  local ok, why = fleet.hire(g, { firm = { hq = {}, applicants = {} }, money = 1000 }, 99, nil)
  assert(not ok and why:find('Repair'), 'no driver for a broken-down car')
  local fixed = garage.repairParked(g, { money = 1000 }, 99, 1)
  assert(fixed and not parkedCar.breakdown and parkedCar.service.tyres == 0)
  for i, c in ipairs(g.parked) do if c == parkedCar then table.remove(g.parked, i) break end end
  -- a service needs the headquarters or a fuel station
  core.random = function(a, b) if a then return b and a or 1 end return 0.99 end
  upkeep.ensure(g.car).tyres = 2400
  state = core.garageDo('service')
  assert(state.msg:find('fuel station') and g.car.service.tyres == 2400)
  withStation(s, 50, 14)
  pose.lat, pose.lon = 50, 14
  advance(core, 2)
  state = core.garageState()
  assert(state.upkeep.where and state.upkeep.due >= 1)
  state = core.garageDo('service')
  assert(g.car.service.tyres == 0, tostring(state.msg))
end)

test('the firm buys trucks and trailers; skilled drivers work them and wait for repairs and trailers', function()
  local core, s = fresh()
  fuelAdapter(core)
  local c = s.career
  c.garage.debt, c.money, c.delivered = 0, 200000, 30
  for _ = 1, 5 do rating.add(c, 'freight', 5) end
  core.firmDo('found', 'Kola')
  local yard = idx.depots[1]
  pose.lat, pose.lon = yard.g[1] + 0.0003, yard.g[2]
  assert(core.firmDo('setHq').hq)
  local hq = core.hqState()
  assert(#hq.shop == 3 and hq.shop[3].id == 'semi' and hq.shop[3].price == firm.VEHICLES[3].fallback and hq.shop[3].can)
  assert(#hq.drivers.applicants == fleet.APPLICANTS and hq.drivers.applicants[1].nets.semi)
  local money = c.money
  hq = core.hqDo('buyVehicle', 'semi')
  assert(c.money == money - firm.VEHICLES[3].fallback and #hq.bays == 2 and hq.bays[2].tier == 'semi', tostring(hq.msg))
  assert(c.accounts.history[1].category == 'firm')
  -- a driver for the tractor needs an articulated licence; then nothing happens without a trailer
  local pick = hq.drivers.applicants[1]
  assert(not pick.can.semi and pick.can.van and #pick.licenceNames == 1, 'this applicant holds only a car licence')
  hq = core.hqDo('hireDriver', hq.bays[2].id, pick.id)
  assert(not c.garage.parked[1].driver and hq.msg:find('articulated licence'), tostring(hq.msg))
  c.firm.applicants[1].licences = { car = true, truck = true, artic = true }
  hq = core.hqDo('hireDriver', hq.bays[2].id, pick.id)
  local truck = c.garage.parked[1]
  assert(truck.driver and truck.driver.name == pick.name, tostring(hq.msg))
  money = c.money
  s.driverTick = fleet.SHIFT_S
  advance(core, 1)
  assert(truck.driver.waiting == 'trailer' and c.money == money, 'no trailer: no shift')
  hq = core.hqDo('buyTrailer', 'dryvan')
  assert(#hq.trailers == 1 and firm.ownsTrailer(c, 'dryvan'), tostring(hq.msg))
  money = c.money
  s.driverTick = fleet.SHIFT_S
  advance(core, 1)
  local net = fleet.net(truck.driver, truck, 1)
  assert(not truck.driver.waiting and c.money == money + net and truck.km > 0, 'a shift with the trailer')
  -- an accident: the truck waits at the headquarters until it is repaired
  core.random = function(a, b) if a then return b and a or 1 end return 0 end
  s.driverTick = fleet.SHIFT_S
  advance(core, 1)
  core.random = function(a, b) if a then return b and a or 1 end return 0.99 end
  assert(truck.parkedRepair > 0 and truck.driver.waiting == 'repair')
  hq = core.hqState()
  assert(hq.bays[2].repairCost > 0 and hq.bays[2].driver.waiting == 'repair')
  money = c.money
  hq = core.hqDo('repairParked', truck.fleetId)
  assert(truck.parkedRepair == 0 and not truck.driver.waiting and c.money < money, tostring(hq.msg))
  -- service of a parked vehicle at the headquarters
  upkeep.ensure(truck).oil = 900
  hq = core.hqDo('service', truck.fleetId)
  assert(truck.service.oil == 0, tostring(hq.msg))
  -- the trailer sells back for half
  money = c.money
  core.hqDo('sellTrailer', hq.trailers[1].id)
  assert(c.money == money + 3000 and #firm.trailers(c) == 0)
  -- a tow trailer of the firm's is taken out here and goes on your hitch (Jan: how do I get my own trailer?)
  local tr = require('cargoEarth/trailers')
  local saved = { tr.takeOwn, tr.ownOut, tr.putAwayOwn }
  local out = nil
  tr.takeOwn = function(kind) out = kind return true end
  tr.ownOut = function() return out and 5 or nil end
  tr.putAwayOwn = function() out = nil end
  local ok, err = pcall(function()
    c.money = c.money + 5000
    vehicle.slotPartMap = { body = 'pigeon', hitch = 'pigeon_tow_hitch' }
    hq = core.hqDo('buyTrailer', 'smalltrailer')
    local row = hq.trailers[#hq.trailers]
    assert(row.tow and row.canTake and not row.out, 'a tow trailer can be taken out: ' .. tostring(hq.msg) .. ' ' .. tostring(row.needs))
    hq = core.hqDo('takeTrailer', row.id)
    row = hq.trailers[#hq.trailers]
    assert(out == 'smalltrailer' and row.out and not row.canTake, tostring(hq.msg))
    hq = core.hqDo('leaveTrailer', row.id)
    assert(out == nil and not hq.trailers[#hq.trailers].out, 'left in the yard')
    -- not without a tow hitch
    vehicle.slotPartMap = { body = 'pigeon' }
    hq = core.hqState()
    assert(not hq.trailers[#hq.trailers].canTake and hq.trailers[#hq.trailers].needs == 'Needs a tow hitch')
  end)
  tr.takeOwn, tr.ownOut, tr.putAwayOwn = saved[1], saved[2], saved[3]
  assert(ok, err)
end)

test('customers tip by speed and the order\'s condition, not by how it was driven', function()
  local marker = package.loaded['cargoEarth/marker']
  marker.PICKUP_RADIUS, marker.PICKUP_RANGE, marker.pickupDistance = 5, 250, function() return nil end
  local core, s = fresh()
  s.career.garage.debt = 0
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function() return {{50.02, 14, 50.02, 14, 'Street 5', 'Town'}} end)
  local function deliver(harsh, condition)
    advance(core, 2)
    core.phoneAction('online')
    for _ = 1, 60 do
      advance(core, 2)
      if core.phoneState().screen == 'incoming' then break end
    end
    core.phoneAction('accept')
    local job = s.job
    pose.lat, pose.lon = job.from.g[1], job.from.g[2]
    advance(core)
    for _ = 1, harsh do core.onCargoEarthHarsh(vehicle.id, 1, 0.7) end
    if condition then job.cargoCondition = condition end
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core)
    return core.phoneState().done, job
  end
  -- tips for one job: for speed (delivered at once here) and 6 % for an order in perfect condition
  local function fast(j) return food.tip(j.pay, 0, j.minutes) end
  local function intact(j) return math.floor(j.pay * core.INTACT_TIP / 5 + 0.5) * 5 end
  local done, job = deliver(0)
  assert(done.tipWhy and done.tipWhy.intact and done.tip == fast(job) + intact(job), 'fast + intact')
  -- harsh driving alone changes nothing: the customer cannot feel it
  s.phone.lastDone = nil
  pose.lat, pose.lon = 50, 14
  done, job = deliver(3)
  assert(job.harsh == nil and done.tipWhy.intact and not done.tipWhy.harsh and done.tip == fast(job) + intact(job),
    'no tip lost for driving')
  -- a damaged order: no tip for its state, and the speed tip shrinks with its condition
  s.phone.lastDone = nil
  pose.lat, pose.lon = 50, 14
  done, job = deliver(0, 50)
  assert(done.tipWhy and done.tipWhy.damaged == 50 and not done.tipWhy.intact)
  assert(done.tip == math.floor(fast(job) * 0.5 + 0.5), 'speed tip halved, no intact tip')
end)

------------------------------------------------------------------------------------------ 0.6: special cargo

local special = require('cargoEarth/special')

test('special cargo rules: which loads qualify, pay, fragile jolts, chilled spoiling, oversize escort', function()
  local function job(cargoId, kind) return { cargo = cargoId, haul = { kind = kind }, pay = 1000, minutes = 50 } end
  local list = special.candidates(job('furniture', 'parcel'), 'rigid')
  assert(#list == 2 and list[1] == 'fragile' and list[2] == 'oversize')
  assert(#special.candidates(job('furniture', 'parcel'), 'van') == 1, 'no oversize load in a van')
  assert(special.candidates(job('milk', 'fluid'), 'semi')[1] == 'chilled')
  assert(#special.candidates(job('gravel', 'dryBulk'), 'semi') == 0)
  assert(#special.candidates({ route = {}, haul = { kind = 'parcel' } }, 'van') == 0, 'parcel routes stay ordinary')
  assert(special.roll(job('furniture', 'parcel'), 'rigid', function() return 0.99 end) == nil)
  -- fragile: more pay, every harsh moment costs condition
  local f = job('electronics', 'parcel')
  special.apply(f, 'fragile')
  assert(f.pay == 1400 and f.specialBonus == 400 and f.handling == 'Fragile' and cargo.handling(f) == 'Fragile')
  assert(special.harsh(f) == 8 and special.condition(f) == 92)
  assert(special.harsh(job('electronics', 'parcel')) == 0, 'an ordinary load does not mind')
  -- chilled: a shorter limit, then it spoils by the minute (counted once)
  local c = job('milk', 'fluid')
  special.apply(c, 'chilled')
  assert(c.minutes == 40 and c.pay == 1300)
  assert(special.warm(c, -5) == 100 and special.warm(c, 2.5) == 94 and special.warm(c, 2.9) == 94 and special.warm(c, 4) == 88)
  -- oversize: escort reports every 10 s too fast
  local o = job('furniture', 'parcel')
  special.apply(o, 'oversize')
  assert(not special.speed(o, 55, 30) and special.penalty(o) == 0)
  assert(not special.speed(o, 80, 9) and special.speed(o, 80, 2) and special.penalty(o) == 3)
  special.speed(o, 90, 1000)
  assert(special.penalty(o) == special.KINDS.oversize.maxLoss, 'the escort takes at most a share')
  assert(special.info(o).penalty == 60 and special.info(f).note:find('8'))
end)

test('a special freight job shows on the phone, a fragile load cracks with harsh driving and pays less', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if not offer.route and offer.haul and offer.haul.kind == 'parcel' then i, job = k, offer break end end
  assert(job, 'a parcel freight job is offered in a van')
  assert(not job.special, 'tests roll no special loads unless asked')
  local base = job.pay
  special.apply(job, 'fragile')
  assert(job.pay > base)
  core.take(i)
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery')
  local state = core.phoneState()
  assert(state.active.special and state.active.special.kind == 'fragile' and state.active.cargoCondition == 100)
  core.onCargoEarthHarsh(vehicle.id, 1, 0.7)
  core.onCargoEarthHarsh(vehicle.id, 1, 0.7)
  assert(job.cargoCondition == 84, 'two harsh moments cost 16 %')
  local money = c.money
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(not s.job and c.money > money)
  assert(s.phone.lastDone.pay <= math.floor(job.pay * 0.84 + 0.5) and s.phone.lastDone.special.kind == 'fragile')
end)

test('an oversize load driven too fast loses pay to escort reports; a ruined fragile load fails', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if not offer.route and offer.haul and offer.haul.kind == 'parcel' then i, job = k, offer break end end
  special.apply(job, 'oversize')
  core.take(i)
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  pose.speed = 25   -- 90 km/h
  advance(core, 50)
  pose.speed = 0
  assert(special.penalty(job) > 0 and core.phoneState().active.special.penalty == special.penalty(job))
  local penalty = special.penalty(job)
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(not s.job and s.phone.lastDone.special.penalty == penalty)
  assert(s.phone.lastDone.pay <= math.floor(job.pay * (1 - penalty / 100) + 0.5))
  -- a fragile load shaken to pieces is lost
  core.generate()
  for k, offer in ipairs(s.offers) do if not offer.route and offer.haul and offer.haul.kind == 'parcel' then i, job = k, offer break end end
  special.apply(job, 'fragile')
  core.take(i)
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  local failed = c.failed or 0
  for _ = 1, 13 do core.onCargoEarthHarsh(vehicle.id, 1, 0.7) end
  assert(not s.job and (c.failed or 0) == failed + 1, 'ruined')
end)

local resupply = require('cargoEarth/resupply')
local haul = require('cargoEarth/haul')

test('fuel station resupply: tanker runs from a fuel depot to real stations, paid by the litre on top', function()
  local fidx = jobs.index({ depots = {
    { id = 'depot', n = 'Fuel Depot', t = 'fuel_depot', s = 'L', g = { 50, 14 } },
    { id = 'far', n = 'Far Depot', t = 'fuel_depot', s = 'L', g = { 52, 14 } },
  }, cargo = { fuel = { name = 'Fuel', trailer = 'tanker', tonnes = 25, pay = 1.55, adr = true } }, trailers = {},
    types = { fuel_depot = { produces = { 'fuel' } } } })
  local stations = fuel.index()
  fuel.addPack(stations, { stations = {
    { 'near', 50.01, 14, 'Too Close', 'f', 'Town' },     -- about 1 km: too short a run
    { 'a', 50.2, 14, 'Station A', 'f', 'Aville' },       -- about 22 km
    { 'b', 50.4, 14, 'Station B', 'f', 'Beetown' },      -- about 44 km
    { 'ev', 50.3, 14, 'Chargers', 'e', 'Town' },
  } })
  local ring = fuel.within(stations, 50, 14, 'fuel', 10, 60)
  assert(#ring == 2 and ring[1].station.id == 'a' and ring[2].station.id == 'b', 'stations in the ring, nearest first')
  local within = function(lat, lon, a, b) return fuel.within(stations, lat, lon, 'fuel', a, b) end
  local offers = resupply.offers(fidx, 50, 14, within, function(n) return n end)
  assert(#offers == 1, 'only the depot near the player')
  local job = offers[1]
  assert(job.to.label == 'Fuel station' and job.to.id == 'station:b' and job.resupply and job.adr and job.cargo == 'fuel')
  assert(job.from.id == 'depot' and job.km > 50 and job.pay == jobs.pay(fidx, 'fuel', job.km))
  assert(haul.prepare(job, 'semi', nil, fidx), 'the tanker takes it')
  local before = job.pay
  assert(resupply.bonus(job) == math.floor(job.haul.amount * resupply.PER_LITRE / 5 + 0.5) * 5 and job.pay > before)
  assert(job.trailer == 'tanker' and job.litres == job.haul.amount)
  assert(#resupply.offers(jobs.index({ depots = {}, cargo = {}, types = {}, trailers = {} }), 50, 14, within) == 0)
  -- streamed fuel depots (helper, anywhere) ship fuel too
  local stream = jobs.streamIndex()
  jobs.addArea(stream, { key = 'k', depots = { { id = 'overture:x', n = 'Oil Terminal', g = { 50, 14 }, t = 'fuel' } } })
  assert(#resupply.offers(stream, 50, 14, within, function(n) return 1 end) == 1)
end)

test('a tractor gets resupply offers among its freight jobs', function()
  local core, s = fresh()
  local c = s.career
  core.G.spawn('us_semi')
  c.garage.car.model = 'us_semi'
  vehicle.slotPartMap = { body = 'us_semi', fifthwheel = 'fifthwheel_top' }
  c.hauls = { van = haul.VAN_GOAL, rigid = haul.RIGID_GOAL }
  s.idx = jobs.index({ depots = { { id = 'depot', n = 'Fuel Depot', t = 'fuel_depot', s = 'L', g = { 50, 14 } } },
    cargo = { fuel = { name = 'Fuel', trailer = 'tanker', tonnes = 25, pay = 1.55, adr = true } }, trailers = {},
    types = { fuel_depot = { produces = { 'fuel' } } } })
  withStation(s, 50.3, 14)
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local job
  for _, offer in ipairs(s.offers) do if offer.resupply then job = offer end end
  assert(job and job.resupplyBonus > 0 and job.to.n == 'Test pump' and not job.special, 'a resupply job is offered')
end)

local tow = require('cargoEarth/tow')
local trailers = require('cargoEarth/trailers')

test('tow rules: who can tow, offers to a workshop, cars on board, damage costs pay', function()
  assert(tow.class('semi', false) == 'heavy' and tow.class(nil, true) == 'light' and tow.class('van', false) == nil)
  assert(tow.hasHitch({ slotPartMap = { a = 'pickup_tow_hitch' } }))
  assert(not tow.hasHitch({ slotPartMap = { a = 'pickup_hitch_delete' } }) and not tow.hasHitch({ slotPartMap = { a = 'engine' } }))
  -- power check (warn only): a 30 hp, 600 kg car is weak for a car trailer, a 200 hp, 1500 kg one is not; unknown = no warning
  assert(tow.weak('light', { power = 30, weight = 600 }) and not tow.weak('light', { power = 200, weight = 1500 }))
  assert(not tow.weak('light', nil) and not tow.weak('light', { power = 30 }))
  assert(tow.info({ tow = { class = 'light', cars = { 'covet' }, weak = true } }).weak == true)
  local addresses = { { 50.01, 14, 50.0101, 14, 'Main Street 1', 'Town' }, { 50.5, 14, 50.5, 14, 'Far Away 2', 'Far' } }
  local workshop = function(lat, lon) return { id = 'w', n = 'Workshop', g = { lat + 0.1, lon } } end
  local offers = tow.offers('light', 50, 14, addresses, workshop, { 'covet' }, function() return 1 end)
  assert(#offers == 1, 'one car near the player; the far one and repeats are skipped')
  local job = offers[1]
  assert(job.kind == 'tow' and job.tow.class == 'light' and #job.tow.cars == 1 and job.trailer == 'cartrailer')
  assert(job.from.n == 'Main Street 1' and job.from.g[1] == 50.0101 and job.to.n == 'Workshop' and job.pay == tow.pay('light', job.km))
  local heavy = tow.offers('heavy', 50, 14, addresses, workshop, { 'covet', 'pessima' }, function() return 1 end)[1]
  assert(#heavy.tow.cars == 2 and heavy.trailer == 'flatbed' and heavy.pay > tow.pay('light', heavy.km))
  assert(#tow.offers('light', 50, 14, addresses, function() return nil end, { 'covet' }) == 0, 'no workshop near: no job')
  assert(#tow.offers('light', 50, 14, addresses, workshop, {}) == 0, 'no cars in the game: no job')
  local byRoad = tow.offers('light', 50, 14, addresses, workshop, { 'covet' }, function() return 1 end, nil, function() return 17.5 end)[1]
  assert(byRoad.km == 17.5 and byRoad.pay == tow.pay('light', 17.5), 'paid by the road when the graph knows it')
  -- far breakdowns are rarer: with rnd always at the top, an address 7 km out is never picked, one 2 km out is
  local far = { { 50.063, 14, 50.063, 14, 'Edge 1', 'Village' } }
  assert(#tow.offers('light', 50, 14, far, workshop, { 'covet' }, function(n) return n end) == 0)
  local near = { { 50.018, 14, 50.018, 14, 'Close 1', 'Town' } }
  assert(#tow.offers('light', 50, 14, near, workshop, { 'covet' }, function(n) return n end) == 1)
  -- each car has a wreck look, the same one for the same address; the game side gets a kind and a seed per car
  assert(job.tow.wrecks and #job.tow.wrecks == 1 and tow.info(job).wreck, 'a wreck look')
  assert(tow.wreckFor('50.01010,14.00000', 1) == tow.wreckFor('50.01010,14.00000', 1))
  local plan = tow.wreckPlan(heavy)
  assert(#plan == 2 and plan[1][1] == heavy.tow.wrecks[1] and plan[1][2] ~= plan[2][2])
  assert(tow.wreckPlan({ tow = { class = 'light', cars = { 'covet' } } }) == nil, 'an old saved job: no wreck')
  local kinds = {}
  for n = 1, 60 do kinds[tow.wreckFor(tostring(n), 1)] = true end
  for _, w in ipairs(tow.WRECKS) do assert(kinds[w.id], 'every look comes up: ' .. w.id) end
  -- Jan: a small car goes on the small, light car trailer (TSFB) when the game has it and no big one of yours is coupled
  local small = tow.offers('light', 50, 14, addresses, workshop, { 'covet' }, function() return 1 end, nil, nil, true, { small = true })[1]
  assert(small.tow.class == 'small' and small.trailer == 'smalltrailer' and tow.info(small).trailer == 'Small car trailer')
  assert(small.pay < tow.pay('light', small.km) + tow.CLASSES.light.rate * tow.BORROW_RATE * small.borrowKm, 'the small trailer pays a little less')
  local big = tow.offers('light', 50, 14, addresses, workshop, { 'midsize' }, function() return 1 end, nil, nil, false, { small = true })[1]
  assert(big.tow.class == 'light' and big.trailer == 'cartrailer', 'a big car still goes on the 22 ft car trailer')
  assert(#tow.offers('light', 50, 14, addresses, workshop, { 'midsize' }, function() return 1 end, nil, nil, false, { small = true, onlySmall = true }) == 0,
    'your own small trailer coupled: no big cars')
  assert(tow.fits('light', 'small') and tow.fits('light', 'light') and not tow.fits('light', 'heavy') and not tow.fits('heavy', 'small'))
  assert(tow.weak('small', { power = 55, weight = 900 }) == false and tow.weak('light', { power = 55, weight = 900 }), 'the small trailer is light')
  assert(tow.onBoard({ 1, 5.9, 7, nil }) == 2)
  assert(tow.condition(0) == 100 and tow.condition(600) == 90 and tow.condition(1e9) == 100 - tow.MAX_LOSS)
end)

test('a tow job: the car goes on the trailer, slides off, is loaded again and towed to a workshop', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  vehicle.slotPartMap = { body = 'pigeon', hitch = 'pigeon_tow_hitch' }
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  withStation(s, 50.1, 14)
  -- the game side, stubbed: what trailers.lua would do in BeamNG
  local saved = {}
  for _, k in ipairs({ 'existing', 'towModel', 'spawnTow', 'recoverTowed', 'withPlayer', 'towedDistances', 'towedDamage', 'towedCount', 'remove', 'id',
    'spawnRoadside', 'towedNear', 'loadTowed', 'towedAlive', 'removeTow', 'ownTowTrailer', 'adopt',
    'stageTowed', 'towedStaged', 'towedPlaced', 'placeTowed' }) do
    saved[k] = trailers[k]
  end
  -- the cars are spawned out of sight as the job starts; putting them by the road fails here (no ground loaded), so
  -- they are spawned at the stop as before
  local stagedN, placeTries = 0, 0
  trailers.stageTowed = function(cars) stagedN = stagedN + 1 return #cars == 1 end
  trailers.towedStaged = function() return stagedN > 0 end
  trailers.towedPlaced = function() return false end
  trailers.placeTowed = function() placeTries = placeTries + 1 return false end
  -- your own car trailer is coupled: the job goes straight to the car (the borrowed one has its own test)
  trailers.ownTowTrailer = function() return 9, 'tiltdeck' end
  trailers.adopt = function() return true end
  local spawned, distances, damage = 0, {}, 0
  local hitched = false
  trailers.recoverTowed = function()
    if not hitched then return false, 'Hitch the job trailer to your vehicle first.' end
    distances = { 1 }
    return true
  end
  trailers.existing = function(list) return { list[1] } end
  trailers.towModel = function() return 'cartrailer' end
  trailers.spawnTow = function(kind, cars) spawned = spawned + 1 distances = { 1 } return kind == 'cartrailer' and #cars == 1 end
  trailers.withPlayer = function() return true end
  trailers.towedDistances = function() return distances end
  trailers.towedDamage = function() return damage end
  trailers.towedCount = function() return #distances end
  trailers.remove = function() distances = {} end
  local towRemoved = 0
  trailers.removeTow = function() towRemoved = towRemoved + 1 distances = {} end
  trailers.id = function() return #distances > 0 and 7 or nil end
  local roadside, nearTrailer, loaded = 0, false, 0
  local alive = true
  trailers.towedAlive = function() return alive and #distances or 0 end
  trailers.spawnRoadside = function(kind, cars) roadside = roadside + 1 distances = { 20 } alive = true return kind == 'cartrailer' and #cars == 1 end
  trailers.towedNear = function() if nearTrailer then return true end return false, 'Park the trailer next to the broken-down car first.' end
  trailers.loadTowed = function(cars) loaded = loaded + 1 distances = { 1 } return #cars == 1 end
  local here = { pose.lat, pose.lon }
  local ok, err = pcall(function()
    core.setMode('trucking')
    advance(core, 2)
    core.generate()
    local i, job
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    assert(job and job.to.n == 'Workshop at Test pump', 'a tow job to the workshop at a fuel station')
    -- with a real repair shop known nearby, the car goes there instead
    s.autoIdx = fuel.index()
    fuel.addPack(s.autoIdx, {stations = {{'g1', 50.08, 14, 'Auto Fix', 'g', 'Town'}}})
    s.offers = {}
    core.generate()
    local shop
    for _, offer in ipairs(s.offers) do if offer.tow then shop = offer break end end
    assert(shop and shop.to.n == 'Auto Fix' and shop.to.id == 'garage:g1' and shop.to.label == 'Repair shop', 'a tow job to a real repair shop')
    s.autoIdx = nil
    s.offers = {}
    core.generate()
    -- the phone rings with it although three ordinary offers come first
    local generate, random = core.generate, math.random
    core.generate = function()
      generate()
      for n = 1, 3 do table.insert(s.offers, 1, { id = 'x' .. n, kind = 'cargo', cargoName = 'Pallets', from = { id = 'x' .. n, n = 'Yard' } }) end
    end
    math.random = function(a, b) if b then return random(a, b) end return a end   -- always the last candidate
    s.phone.online, s.phone.incoming, s.phone.nextPingAt = true, nil, 0
    advance(core)
    core.generate, math.random = generate, random
    assert(s.phone.incoming and s.phone.incoming.job.tow, 'a tow job reaches the phone')
    s.phone.incoming, s.phone.online = nil, false
    core.generate()
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    core.take(i)
    assert(s.job == job)
    damage = 500                    -- the damage it broke down with
    pose.lat, pose.lon = job.from.g[1], job.from.g[2]
    advance(core)
    -- the car waits by the road; Load puts it on once the trailer is next to it
    assert(stagedN == 1, 'the broken-down car was spawned out of sight once: ' .. stagedN)
    assert(roadside == 1 and spawned == 0 and s.phase == 'toPickup' and job.tow.waiting and job.tow.onBoard == 0)
    assert(core.phoneState().active.towWaiting, 'the phone offers Load')
    assert(core.towWaiting() and core.stopInfo() == nil and s.stopT == 0, 'no stop countdown while the car waits for Load')
    advance(core, 40)
    assert(s.stopT == 0, 'the countdown does not run over and over')
    assert(roadside == 1, 'stopping again does not spawn the car twice')
    alive = false                   -- the waiting car was deleted: stopping again brings it back
    advance(core, 40)
    assert(roadside == 2 and job.tow.waiting, 'a lost car is placed again')
    core.phoneAction('towLoad')
    assert(loaded == 0 and s.phase == 'toPickup', 'not loaded while the trailer is away')
    nearTrailer = true
    core.phoneAction('towLoad')
    assert(loaded == 1 and s.phase == 'toDelivery' and job.tow.onBoard == 1 and not job.tow.waiting)
    assert(not core.phoneState().active.towWaiting)
    advance(core)
    assert(job.tow.damage0 == 500, 'damage before the tow is not yours ' .. tostring(job.tow.damage0) .. ' ' .. tostring(job.tow.spawnedAt) .. ' ' .. tostring(s.clock))
    local balance = c.money
    core.phoneAction('restoreTrailer')
    assert(c.money == balance and spawned == 0, 'an already loaded car cannot be charged again')
    -- it is damaged and slides off
    damage = damage + 300
    distances = { 12 }
    advance(core, 4)
    local state = core.phoneState()
    assert(job.tow.onBoard == 0 and state.active.tow.onBoard == 0 and state.active.canRestoreTrailer)
    assert(state.active.reloadFee == 150)
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core)
    assert(s.job == job, 'not delivered without the car')
    c.money = 1000
    core.phoneAction('restoreTrailer')
    assert(spawned == 0 and c.money == 1000 and distances[1] == 12)
    hitched = true
    core.phoneAction('restoreTrailer')
    core.phoneAction('restoreTrailer')
    assert(spawned == 0 and c.money == 1000 - core.TOW_RELOAD_FEE and job.tow.onBoard == 1)
    assert(job.tow.damage0 == 500 and damage == 800)
    advance(core, 8)
    damage = damage + 600           -- 10 % worse on the way, 5 % before the reload
    advance(core, 30)
    assert(not s.job, 'delivered')
    assert(s.phone.lastDone.cargoCondition == 85 and s.phone.lastDone.pay <= math.floor(job.pay * 0.85 + 0.5))
    assert(c.history[1].kind == 'tow')
    -- a cancelled tow job takes its trailer and car(s) along
    pose.lat, pose.lon = here[1], here[2]
    s.offers = {}
    core.generate()
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    core.take(i)
    pose.lat, pose.lon = job.from.g[1], job.from.g[2]
    advance(core)
    assert(job.tow.waiting and #distances == 1)
    local before = towRemoved
    core.cancel(true)
    assert(not s.job and towRemoved == before + 1 and #distances == 0, 'cancel clears the tow trailer and cars')
  end)
  for k, f in pairs(saved) do trailers[k] = f end
  assert(ok, err)
end)

local bus = require('cargoEarth/bus')

-- a line of five stops 400 m apart going north from the player, a bus station beside the first stop
local function busData()
  local stops = {}
  for i = 1, 5 do stops[i] = { i == 3 and '' or ('Stop ' .. string.char(64 + i)), 50 + (i - 1) * 0.0036, 14.002 } end
  return { state = 'ready', lines = {
    { id = 'r1', ref = '136', name = 'Bus 136', from = 'Stop A', to = 'Stop E', operator = 'City Transit', stops = stops },
    { id = 'bad', ref = 'X', stops = { { 'A', 50, 14 }, { 'B', 50.01, 14 } } },
  }, depots = { { id = 'w7', name = 'Bus Garage', kind = 'depot', lat = 50.0005, lon = 14.0005 } } }
end

test('bus discovery uses nearby stops and only offers mapped directions', function()
  local data, idx = busData(), bus.index()
  local line = data.lines[1]
  line.stops = {}
  -- Model the reported Kottayam case: the first stop is beyond 4 km and the last is nearby.
  for i = 1, 28 do
    local f = (i - 1) / 27
    line.stops[i] = { 'Stop ' .. i, 9.55902 + 0.03155*f, 76.492311 + 0.029039*f }
  end
  local function offers()
    bus.set(idx, data)
    return bus.board(idx, 9.591238, 76.514068)
  end
  local board = offers()
  assert(#board == 1 and board[1].bus.singleDirection and board[1].pickupKm > 4)
  assert(board[1].bus.stops == 28 and board[1].bus.to == 'Stop 28')
  local reverse = { id = 'mapped-return', ref = line.ref, operator = line.operator, stops = {} }
  for i = #line.stops, 1, -1 do
    local stop = line.stops[i]
    table.insert(reverse.stops, { stop[1] .. ' inbound', stop[2], stop[3] + 0.0002 })
  end
  table.insert(data.lines, reverse)
  board = offers()
  assert(#board == 2 and not board[1].bus.singleDirection and not board[2].bus.singleDirection)
  for _, offer in ipairs(board) do
    if offer.id == 'bus:mapped-return' then
      assert(offer.jobs[1].bus.stops[1].g[2] == reverse.stops[1][3])
      assert(offer.bus.from == 'Stop 28 inbound' and offer.bus.to == 'Stop 1 inbound')
    end
  end
end)

test('bus lines: offers at the depot, passengers on and off, fares', function()
  local idx = bus.index()
  bus.set(idx, busData())
  assert(#idx.lines == 1 and #idx.depots == 1, 'a line with two stops is left out')
  assert(idx.lines[1].stops[3].n == 'Stop 3', 'a stop without a name gets one')
  local board = bus.board(idx, 50, 14)
  assert(#board == 1)
  local o = board[1]
  assert(o.tier == 'bus' and o.yard.n == 'Bus Garage' and o.jobCount == 1 and #o.jobs == 1 and o.name == 'City Transit')
  local j = o.jobs[1]
  assert(j.kind == 'bus' and j.from.n == 'Stop A' and j.to.n == 'Stop B' and j.pay > 0 and j.minutes > 0)
  assert(j.cargoName == 'Line 136 to Stop E')
  assert(#bus.board(idx, 50.2, 14) == 0, 'no line near')
  -- no depot near the first stop: the bus waits at the terminus
  local far = bus.index()
  local data = busData()
  data.depots[1].lat = 50.5
  bus.set(far, data)
  assert(bus.board(far, 50, 14)[1].yard.n == 'Terminus Stop A')
  -- people: none get off at the first stop, everyone at the last, never more than the bus takes
  local top = function(n) return n end
  local off, on, dwell = bus.passengers(j, top)
  assert(off == 0 and on > 0 and dwell > bus.DWELL_S)
  bus.served(j, off, on)
  assert(j.bus.at == 2 and j.to.n == 'Stop B' and j.bus.onBoard == on and j.bus.boarded == on)
  j.bus.onBoard = bus.CAPACITY
  local fullOff, full = bus.passengers(j, top)
  assert(full <= fullOff, 'a full bus takes only as many as got off')
  j.bus.at, j.bus.onBoard = 5, 12
  local offEnd, onEnd = bus.passengers(j, top)
  assert(offEnd == 12 and onEnd == 0 and bus.last(j))
  assert(bus.fares(j) == bus.PER_PASSENGER * j.bus.boarded)
end)

test('bus timetable: each stop has its own time from its distance, late minutes add up stop by stop', function()
  -- slow on short hops, faster on long ones, never under the floor
  assert(bus.legMinutes(0.1) == bus.LEG_MIN)
  local short, long = bus.legMinutes(0.5), bus.legMinutes(4)
  assert(0.5 / (short / 60) < 4 / (long / 60), 'a long hop is driven faster on average')
  assert(long < 4 / bus.LEG_KMH[1] * 60 * bus.LEG_SLACK + 1, 'a long hop is not driven at the slow city speed')
  local idx = bus.index()
  bus.set(idx, busData())
  local j = bus.board(idx, 50, 14)[1].jobs[1]
  local sum = 0
  for i, st in ipairs(j.bus.stops) do
    assert(st.min and st.min >= bus.LEG_MIN, 'stop ' .. i .. ' has its time')
    sum = sum + st.min
  end
  assert(j.minutes == math.ceil(sum), 'the line takes the sum of its stops')
  assert(j.bus.stops[1].min > j.bus.stops[2].min, 'the first stop includes getting out of the depot')
  -- the pay follows the timetable's minutes
  assert(j.pay == math.floor((bus.BASE + bus.PER_MIN * sum + bus.PER_STOP * 5) / 5 + 0.5) * 5)
  -- the first stop: on time
  local left, min = bus.due(j, 30)
  assert(min == j.bus.stops[1].min and math.abs(left - (min * 60 - 30)) < 1e-6)
  assert(bus.arrived(j, 30) == 0 and bus.arrived(j, 9999) == 0, 'counted once per stop')
  bus.served(j, 0, 3, 60)
  -- the second stop: the GPS road is longer than the guess, the time grows; once only
  local before, total = j.bus.stops[2].min, j.minutes
  assert(bus.roadKnown(j, 2, 90) and j.bus.stops[2].min > before and j.minutes > total)
  assert(not bus.roadKnown(j, 9, 95), 'the road is taken once per stop')
  -- two minutes late at the second stop
  local due = 60 + j.bus.stops[2].min * 60
  assert(math.abs(bus.arrived(j, due + 120) - 2) < 1e-6 and math.abs(bus.lateMinutes(j) - 2) < 1e-6)
  bus.served(j, 0, 0, due + 140)
  assert(bus.due(j, due + 140) == j.bus.stops[3].min * 60, 'the next stop gets its own time from the doors closing')
  -- a skipped stop starts the next one's time too
  bus.skip(j, due + 500)
  assert(j.bus.at == 4 and j.bus.legStart == due + 500)
  local st = bus.state(j, nil, due + 500)
  assert(st.dueMin == j.bus.stops[4].min and st.late == 2)
  -- a line saved before the timetable existed: its stops have no times, nothing counts as late
  j.bus.stops[5].min = nil
  bus.served(j, 0, 0, due + 600)
  assert(bus.arrived(j, due + 99999) == 0 and math.abs(bus.lateMinutes(j) - 2) < 1e-6)
end)

test('bus comfort: passengers feel harsh moments and bumps, an empty bus does not', function()
  local idx = bus.index()
  bus.set(idx, busData())
  local j = bus.board(idx, 50, 14)[1].jobs[1]
  assert(bus.harsh(j) == 0 and bus.bump(j, 9) == 0 and bus.comfort(j) == 100, 'nobody on board')
  bus.served(j, 0, 5, 60)
  assert(bus.harsh(j) == bus.HARSH_LOSS and bus.comfort(j) == 100 - bus.HARSH_LOSS)
  assert(bus.bump(j, 3) == 0, 'below a bump')
  assert(bus.bump(j, 99) == bus.BUMP_LOSS[2])
  assert(bus.state(j, nil, 60).comfort == bus.comfort(j))
  for _ = 1, 40 do bus.harsh(j) end
  assert(bus.comfort(j) == 0)
end)

test('bus collisions combine damage and G reports once, with stronger reports upgrading the penalty', function()
  local function ride()
    return {bus={onBoard=5,comfort=100}}
  end
  local j = ride()
  assert(bus.impact(j, 3, bus.DAMAGE_MIN - 1, 10) == 0)
  assert(bus.impact(j, 3, bus.DAMAGE_MIN, 10) == 10)
  assert(bus.impact(j, 3.5, nil, 11) == 0)
  assert(bus.impact(j, 5.5, nil, 11) == 30 and bus.comfort(j) == 60)
  assert(bus.impact(j, nil, bus.DAMAGE_FULL, 12) == 0)
  assert(bus.impact(j, nil, bus.DAMAGE_MIN, 14) == 10)
  local reverse = ride()
  bus.impact(reverse, 5.5, nil, 10)
  bus.impact(reverse, nil, bus.DAMAGE_MIN, 11)
  assert(bus.comfort(reverse) == 60)
  j.bus.onBoard = 0
  assert(bus.impact(j, 10, bus.DAMAGE_FULL, 20) == 0)
end)

test('bus comfort tolerates ordinary braking and catches damage below the G threshold', function()
  local core, s = fresh()
  core.setMode('bus')
  s.busIdx = bus.index()
  bus.set(s.busIdx, busData())
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  pose.lat, pose.lon = 50.0005, 14.0005
  core.busSelect(s.busBoard[1].id)
  core.busDepotTick(pose, 2)
  advance(core, 2)
  local j = s.job
  j.bus.onBoard = 5
  advance(core, 6)
  core.onCargoEarthHarsh(vehicle.id, impactToken, 0.7)
  assert(bus.comfort(j) == 100, 'routine braking should not cost comfort')
  core.onCargoEarthHarsh(vehicle.id, impactToken + 1, 0.9)
  assert(bus.comfort(j) == 100, 'an expired force reporter must be ignored')
  core.onCargoEarthHarsh(vehicle.id, impactToken, 0.9)
  assert(bus.comfort(j) == 98)
  core.onCargoEarthHarsh(vehicle.id, impactToken, 0.9)
  assert(bus.comfort(j) == 98, 'one harsh moment must not produce repeated penalties')
  core.busDamageTick(bus.DAMAGE_MIN - 1)
  assert(bus.comfort(j) == 98)
  core.busDamageTick(bus.DAMAGE_MIN)
  assert(bus.comfort(j) == 90, 'the collision penalty includes the recent harsh-driving penalty')
  core.busDamageTick(bus.DAMAGE_MIN)
  assert(bus.comfort(j) == 90)
  local watched = s.busDamageWatch
  core.onVehicleSpawned(vehicle.id + 10)
  core.onVehicleResetted(vehicle.id + 10)
  assert(s.busDamageWatch == watched, 'traffic spawn and reset must preserve the bus baseline')
  s.clock = s.clock + 4
  -- One collision whose damage arrives over two garage ticks.
  core.busDamageTick(bus.DAMAGE_MIN + 10000)
  local afterFirst = bus.comfort(j)
  assert(afterFirst == 66)
  s.clock = s.clock + 0.5
  core.busDamageTick(bus.DAMAGE_MIN + 20000)
  assert(bus.comfort(j) == 50, 'the two increments must total a 40-point loss')
  core.busDamageTick(bus.DAMAGE_MIN + 20000)
  assert(bus.comfort(j) == 50, 'the unchanged damage total must not be counted again')
  core.onVehicleResetted(vehicle.id)
  assert(not s.busDamageWatch, 'resetting the watched bus clears its baseline')
  core.busDamageTick(0)
  assert(bus.comfort(j) == 50, 'a reset is not another crash')
end)

test('bus signs: the line number, the destination in plain letters and the stops ahead', function()
  local idx = bus.index()
  local data = busData()
  data.lines[1].stops[5][1] = 'Nedomice, Škola u Křížku a kostela'
  data.lines[1].colour = '#ff8800'
  bus.set(idx, data)
  local j = bus.board(idx, 50, 14)[1].jobs[1]
  local sg = bus.sign(j)
  assert(sg.routeID == '136' and sg.routeColor == '#ff8800')
  assert(sg.direction == ('Nedomice, Skola u Krizku a kostela'):sub(1, bus.SIGN_CHARS), sg.direction)
  assert(#sg.tasklist == 5 and sg.tasklist[1][2] == 'Stop A' and sg.tasklist[5][2] == 'Nedomice, Škola u Křížku a kostela')
  bus.served(j, 0, 1, 60)
  assert(#bus.sign(j).tasklist == 4 and bus.sign(j).tasklist[1][2] == 'Stop B', 'the next stop first')
  assert(bus.plain('ŽLUŤOUČKÝ kůň') == 'ZLUTOUCKY kun')
end)

test('bus names: escapes that lost their backslash on the way into the game are letters again', function()
  assert(bus.text('Tiu0161ice, Chru00e1st') == 'Tišice, Chrást')
  assert(bus.text('Ku0159u00edu017eek') == 'Křížek')
  assert(bus.text('\\u010cerven\\u00e1') == 'Červená')
  assert(bus.text('Nádraží 12') == 'Nádraží 12', 'right text stays')
  assert(bus.text('Bus 0041') == 'Bus 0041' and bus.text('u0041') == 'u0041', 'plain letters are not guessed')
  local idx = bus.index()
  local data = busData()
  data.lines[1].stops[1][1] = 'Ovu010du00e1ry'
  data.lines[1].to = 'Nedomice, u0160kola'
  data.depots[1].name = 'Garu00e1u017e'
  bus.set(idx, data)
  assert(idx.lines[1].stops[1].n == 'Ovčáry' and idx.lines[1].to == 'Nedomice, Škola' and idx.depots[1].n == 'Garáž')
end)

test('career review: company trucks keep a bigger share, and each work type says what it needs', function()
  assert(employment.shareFor('van') == 0.8 and employment.shareFor('bus') == 0.8)
  assert(employment.shareFor('rigid') == 0.65 and employment.shareFor('semi') == 0.65)
  local progress = require('cargoEarth/progress')
  local function byId(list) local out = {} for _, w in ipairs(list) do out[w.id] = w end return out end
  local w = byId(progress.workTypes({ hauls = { van = 2 } }, { owned = { car = true } }))
  assert(w.food.ready and w.taxi.ready and w.bus.ready and w.company.ready)
  assert(not w.parcel.ready and w.parcel.missing == 'You own no van.')
  assert(not w.rigid.ready and not w.semi.ready and not w.firm.ready and not w.drivers.ready)
  w = byId(progress.workTypes({}, { taxi = { ready = false, why = 'No seats.' }, tow = { ready = false, why = 'No hitch.' } }))
  assert(not w.taxi.ready and w.taxi.missing == 'No seats.' and not w.tow.ready and w.tow.missing == 'No hitch.')
  w = byId(progress.workTypes({ hauls = { van = 2 } }, { owned = { rigid = true } }))
  assert(w.rigid.missing == 'Van hauls: 2 of 3.', 'an owned box truck still waits for the van hauls')
  w = byId(progress.workTypes({}, { owned = { van = true }, boxless = { van = true } }))
  assert(not w.parcel.ready and w.parcel.missing:find('cargo boxes', 1, true) and not w.van.ready)
  w = byId(progress.workTypes({ hauls = { van = 3, rigid = 5 } }, { owned = { semi = true }, firm = true, independent = true }))
  assert(w.semi.ready and w.firm.ready and w.drivers.ready and w.independent.ready)
  w = byId(progress.workTypes({}, { firmReq = { { label = 'Founding fee', detail = '100 CZK of 6000 CZK', done = false } } }))
  assert(w.firm.missing == 'Founding fee: 100 CZK of 6000 CZK.' and not w.firm.ready)
  w = byId(progress.workTypes({}, { firmReq = { { label = 'Founding fee', detail = '6000 CZK of 6000 CZK', done = true } } }))
  assert(w.firm.ready and w.firm.missing == nil and not w.drivers.ready, 'every requirement met: the firm can be founded')
  local core = fresh()
  assert(#core.careerState().work == #progress.WORK and core.careerState().ranks[4].perk ~= nil)
end)

test('bus board: the fares a line is expected to bring are shown with its pay', function()
  local idx = bus.index()
  bus.set(idx, busData())
  local o = bus.board(idx, 50, 14)[1]
  assert(o.fares == math.floor(bus.PER_PASSENGER * bus.expectedRiders(5) + 0.5) and o.fares > 0)
end)

test('speed cameras are paused even for a save that previously enabled them', function()
  local core, s = fresh()
  s.career.camerasOff = nil
  core.onHelperCameras({state = 'ready', cameras = {{'n1', 50.001, 14, 50, 'primary'}}})
  local h = package.loaded['cargoEarth/helper']
  local tick, called = h.tick, 0
  h.tick = function(_, _, _, _, onCameras)
    called = called + 1
    assert(onCameras == nil, 'no camera downloads while paused')
  end
  local money = s.career.money
  pose.speed, pose.heading = 80 / 3.6, 0
  for step = 0, 20 do
    pose.lat = 50 + step * 0.0001
    advance(core, 2)
  end
  h.tick = tick
  assert(s.career.money == money and core.phoneState().camera == nil and core.phoneState().flash == nil)
  assert(core.settingsState().cameras.paused and not core.settingsState().cameras.on)
  assert(not core.settingsDo('cameras', true).cameras.on, 'settings cannot turn the paused feature back on')
end)

test('bus discovery: request errors, area progress, distant depots and manual retry', function()
  local core, s = fresh()
  core.setMode('bus')
  helperAsks = {}
  s.busAskAt = 0
  core.busFetch(pose)
  local ask = helperAsks[#helperAsks]
  ask.cb(nil, 'timeout')
  assert(s.busIdx.state ~= 'old' and s.busIdx.error:find('timeout'), 'a timeout never says update the helper')
  s.busAskAt = 0
  core.busFetch(pose)
  helperAsks[#helperAsks].cb(nil, 'HTTP 404')
  assert(s.busIdx.state == 'old', 'a missing endpoint means an old helper')
  core.phoneAction('busRetry')
  assert(helperAsks[#helperAsks].path:find('&retry=1', 1, true))
  helperAsks[#helperAsks].cb({state = 'loading', lines = {}, total = 4, ready = 1, loading = 2, queued = 1,
    failed = 1, errors = {'Query timed out'}, elapsed = 21, retryAfter = 250, server = 'overpass-api.de', attempt = 2})
  local b = core.busState()
  assert(b.progress.ready == 1 and b.progress.queued == 1 and b.error == 'Query timed out')
  assert(b.progress.attempt == 2 and b.progress.retryAfter == 250)
  local data = busData()
  bus.set(s.busIdx, data)
  pose.lat = 51
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  b = core.busState()
  assert(#b.lines == 0 and b.found == 1 and b.nearestKm > b.radiusKm)
end)

test('bus depot marker: selection never spawns a bus until your car parks inside it', function()
  local core, s = fresh()
  core.setMode('bus')
  s.busIdx = bus.index()
  bus.set(s.busIdx, busData())
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  local id = s.busBoard[1].id
  local spawns, spawn = 0, core.G.spawn
  core.G.spawn = function(...) spawns = spawns + 1 return spawn(...) end
  core.phoneAction('busStart', id)
  assert(s.busDepot and spawns == 0 and core.phoneState().bus.selected.id == id)
  core.busDepotTick(pose, 10)
  assert(spawns == 0, 'not inside the 12 m parking marker')
  pose.lat, pose.lon, pose.speed = 50.0005, 14.0005, 2
  core.busDepotTick(pose, 10)
  assert(spawns == 0 and s.busDepot.parked == 0, 'driving through never spawns the bus')
  pose.speed = 0
  core.busDepotTick(pose, 1)
  assert(spawns == 0 and core.busDepotInfo(pose).frac == 0.5)
  core.phoneAction('busCancelSelection')
  assert(not s.busDepot and spawns == 0)
  core.phoneAction('busStart', id)
  core.busDepotTick(pose, 2)
  assert(spawns == 1 and not s.busDepot and s.career.garage.car.model == 'citybus')
  assert(s.career.employment.personalGarage.car.model == 'pigeon', 'your own car is stored before replacement')
end)

test('bus pickup preserves the selected depot when discovery refreshes or removes its board entry', function()
  for _, refreshed in ipairs({true, false}) do
    local core, s = fresh()
    core.setMode('bus')
    s.busIdx = bus.index()
    bus.set(s.busIdx, busData())
    s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
    core.busSelect(s.busBoard[1].id)
    local selected = s.busDepot.offer
    local other = copy(selected)
    other.id = 'bus:other'
    if refreshed then
      local data = busData()
      data.depots = {{id = 'newDepot', name = 'Newly discovered depot', lat = 50.012, lon = 14.002}}
      bus.set(s.busIdx, data)
      s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
      assert(s.busBoard[1].id == selected.id and s.busBoard[1].yard.id ~= selected.yard.id,
        'same line discovered with a different depot')
      s.busBoard[#s.busBoard + 1] = other
    else
      s.busBoard = {other}
    end
    pose.lat, pose.lon = selected.yard.g[1], selected.yard.g[2]
    assert(core.busDepotInfo(pose).inZone, 'the displayed marker still uses the selected depot')
    core.busDepotTick(pose, bus.PARK_S)
    local shift = s.career.employment
    assert(shift and not s.busDepot and s.career.garage.car.model == 'citybus',
      'parking at the selected marker starts the shift after a board refresh')
    assert(shift.yard.id == selected.yard.id and shift.yard.g[1] == selected.yard.g[1],
      'the saved shift uses the selected depot for returning the personal car')
    local kept = false
    for _, offer in ipairs(s.busBoard) do
      if offer.id == selected.id then assert(offer == selected, 'start uses the selected offer snapshot') end
      if offer == other then kept = true end
    end
    assert(kept and #s.busBoard == 2, 'unrelated offers are preserved')
  end
end)

test('the native bus doors and phone share boarding; closing early cancels without serving the stop', function()
  local core, s = fresh()
  core.setMode('bus')
  s.busIdx = bus.index()
  bus.set(s.busIdx, busData())
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  pose.lat, pose.lon = 50.0005, 14.0005
  core.busSelect(s.busBoard[1].id)
  core.busDepotTick(pose, 2)
  advance(core, 2)
  local j, watched, commands = s.job, nil, 0
  core.G.watchBusDoors = function(id, token) watched = {id = id, token = token} return true end
  core.G.busDoors = function() commands = commands + 1 end
  core.busDoorWatch()
  local stop = j.bus.stops[1]
  pose.lat, pose.lon = stop.g[1], stop.g[2]
  core.onCargoEarthBusDoors(watched.id + 1, watched.token, true)
  assert(not s.busDwell, 'another bus cannot start this boarding timer')
  core.onCargoEarthBusDoors(watched.id, watched.token, true)
  local dwell = s.busDwell
  assert(dwell and commands == 0, 'native O opens the timer without toggling the real doors again')
  assert(core.stopInfo().leftS == core.busState().line.doors.left and core.stopInfo().frac == 0)
  core.phoneAction('busDoors')
  assert(s.busDwell == dwell, 'a second press cannot duplicate passengers')
  core.onCargoEarthBusDoors(watched.id, watched.token, false)
  assert(not s.busDwell and j.bus.at == 1 and j.bus.boarded == 0)
  core.phoneAction('busDoors')
  assert(s.busDwell and commands == 1, 'the phone opens the same boarding flow')
  local function interrupted()
    assert(not s.busDwell and j.bus.at == 1 and j.bus.boarded == 0 and j.bus.onBoard == 0)
  end
  pose.lat = pose.lat + 0.01
  core.onUpdate(0.01, 0.01)
  interrupted()
  pose.lat = stop.g[1]
  core.phoneAction('busDoors')
  local originalId = core.G.playerId
  core.G.playerId = function() return watched.id + 1 end
  core.onUpdate(0.01, 0.01)
  interrupted()
  core.G.playerId = originalId
  core.phoneAction('busDoors')
  local earth = require('cargoEarth/earth')
  local originalPose = earth.pose
  earth.pose = function() return nil end
  core.onUpdate(0.01, 0.01)
  interrupted()
  earth.pose = originalPose
  core.phoneAction('busDoors')
  core.onBeamNGEarthTeleported(stop)
  interrupted()
  core.phoneAction('busDoors')
  core.onUpdate(0.5, 0.25)
  local remaining, fraction = s.busDwell.remaining, core.stopInfo().frac
  assert(remaining == s.busDwell.duration - 0.25)
  for _ = 1, 40 do core.onUpdate(0.5, 0) end
  assert(s.busDwell.remaining == remaining and core.stopInfo().frac == fraction)
  assert(core.stopInfo().leftS == math.ceil(remaining) and core.busState().line.doors.left == math.ceil(remaining))
  local beforeClose = commands
  advance(core, 4)
  assert(core.stopInfo().frac > 0 and core.stopInfo().leftS == core.busState().line.doors.left)
  advance(core, 32)
  assert(j.bus.at == 2 and not s.busDwell and commands == beforeClose + 1)
  pose.lat, pose.lon = j.bus.stops[2].g[1], j.bus.stops[2].g[2]
  advance(core, 40)
  assert(j.bus.at == 2 and not core.stopInfo().stopping and core.stopInfo().stopS == 0,
    'a bus stop never runs the generic one-second cargo timer')
end)

test('bus GPS road distance and ETA refresh before bypassing the cargo stop timer', function()
  local core, s = fresh()
  core.setMode('bus')
  s.busIdx = bus.index()
  bus.set(s.busIdx, busData())
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  pose.lat, pose.lon = 50.0005, 14.0005
  core.busSelect(s.busBoard[1].id)
  core.busDepotTick(pose, 2)
  advance(core, 2)
  local j = s.job
  gpsRoute = {remaining = 1200, eta = 100}
  advance(core, 2)
  local active = core.phoneState().active
  assert(active.distRoad and active.distM == 1200 and active.etaS == 100, 'bus navigation uses GPS distance and ETA')
  gpsRoute = {remaining = 860, eta = 70}
  advance(core, 2)
  active = core.phoneState().active
  assert(active.distM == 860 and active.etaS == 70, 'bus route metrics keep updating')
  gpsRoute = {planning = true, remaining = 500, eta = 40}
  advance(core, 2)
  active = core.phoneState().active
  assert(not active.distRoad and active.etaS == nil and s.roadM == nil, 'planning clears stale bus metrics')
  gpsRoute = {remaining = 700, eta = 60}
  advance(core, 2)
  gpsRoute = nil
  advance(core, 2)
  assert(s.roadM == nil and s.etaS == nil, 'clearing GPS clears old bus distance and ETA')
  pose.lat, pose.lon = j.bus.stops[1].g[1], j.bus.stops[1].g[2]
  gpsRoute = {remaining = 20, eta = 3}
  advance(core, 40)
  assert(j.bus.at == 1 and not s.busDwell and s.roadM == 20 and s.etaS == 3,
    'bus metrics refresh while waiting for doors, without serving the stop automatically')
end)

test('an active bus shift repairs corrupted saved stop names from fresh OSM coordinates', function()
  local core, s = fresh()
  core.setMode('bus')
  s.busIdx = bus.index()
  bus.set(s.busIdx, busData())
  s.busBoard = bus.board(s.busIdx, pose.lat, pose.lon)
  pose.lat, pose.lon = 50.0005, 14.0005
  core.busSelect(s.busBoard[1].id)
  core.busDepotTick(pose, 2)
  advance(core, 2)
  local j = s.job
  j.bus.stops[2].n, j.to.n = 'Chvatu011bruby', 'Chvatu011bruby'
  assert(core.busNamesNeedRefresh())
  local before = j.paymentId
  local data = busData()
  data.lines[1].stops[2][1] = 'Chvatěruby'
  helperAsks, s.busAskAt = {}, 0
  core.busFetch(pose)
  assert(#helperAsks == 1, 'an active line can refresh its corrupted names')
  helperAsks[1].cb(data)
  assert(j.bus.stops[2].n == 'Chvatěruby' and j.to.n == 'Chvatěruby' and not core.busNamesNeedRefresh())
  assert(j.paymentId == before and j.bus.at == 1, 'names are repaired without restarting or paying the shift')
end)

test('a bus shift: the lent bus, doors at every stop, the line paid and your car back', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  helperAsks = {}
  core.random = function(a, b) if b then return b end return a or 0.5 end   -- the most people every time
  core.setMode('bus')
  assert(s.mode == 'bus' and not s.phone.online)
  local set = core.settingsState()
  assert(set.mode == 'bus' and #set.items == 0, 'Settings open in bus mode')
  assert(core.settingsDo('mode', 'bus').mode == 'bus')
  advance(core, 2)
  local ask
  for _, a in ipairs(helperAsks) do if a.path:find('/v1/buslines', 1, true) then ask = a end end
  assert(ask, 'the helper is asked for the lines around you')
  ask.cb(busData())
  local state = core.phoneState()
  assert(state.bus and #state.bus.lines == 1, 'the board shows the line')
  local line = state.bus.lines[1]
  assert(line.ref == '136' and line.depot == 'Bus Garage' and line.pay > 0 and not line.atDepot)
  core.phoneAction('busStart', line.id)
  assert(s.busDepot and c.garage.car.model == 'pigeon', 'choosing a line only shows the depot marker')
  assert(not c.employment, 'not started away from the depot')
  pose.lat, pose.lon = 50.0005, 14.0005
  assert(core.phoneState().bus.lines[1].atDepot)
  local money = c.money
  core.phoneAction('busStart', line.id)
  advance(core, 4)
  local shift = c.employment
  assert(shift and shift.tier == 'bus' and c.garage.car.model == 'citybus' and c.garage.car.loaner, 'the city lends a bus: ' .. tostring(s.placesMsg) .. ' ' .. tostring(shift and shift.tier) .. ' ' .. tostring(c.garage.car.model))
  advance(core, 2)
  local j = s.job
  assert(j and j.bus and s.phase == 'toPickup' and j.from.n == 'Stop A')
  -- at each stop: stop, open the doors, wait while people get off and on
  local function atStop(n)
    local st = j.bus.stops[n]
    pose.lat, pose.lon, pose.speed = st.g[1], st.g[2], 0
    advance(core, 4)
    assert(j.bus.at == n, 'it waits for the doors at stop ' .. n)
    local bs = core.phoneState().bus
    assert(bs.canDoors, 'the doors can open at stop ' .. n .. ' dist ' .. tostring(s.dist) .. ' ' .. tostring(bs.line) .. ' ' .. tostring(s.mode))
    core.phoneAction('busDoors')
    assert(core.stopInfo().bus and core.stopInfo().leftS == core.phoneState().bus.line.doors.left,
      'the upper overlay and phone share the boarding clock')
    assert(core.phoneState().bus.line.doors, 'the doors are open')
    advance(core, 40)
  end
  atStop(1)
  assert(s.phase == 'toDelivery' and j.bus.at == 2 and j.bus.onBoard > 0)
  assert(seated == j.bus.onBoard, 'the people on board sit in the bus')
  -- driving off with the doors open: nobody moves, open them again
  local st = j.bus.stops[2]
  pose.lat, pose.lon = st.g[1], st.g[2]
  advance(core, 4)
  core.phoneAction('busDoors')
  pose.speed = 5
  advance(core, 2)
  assert(j.bus.at == 2 and not core.phoneState().bus.line.doors, 'the stop is not served')
  pose.speed = 0
  atStop(2)
  -- a stop the bus cannot reach is skipped: nobody gets on and it is not paid
  local quote, boarded = j.pay, j.bus.boarded
  core.phoneAction('busSkip')
  assert(j.bus.at == 4 and j.bus.skipped == 1 and j.bus.boarded == boarded, 'stop 3 skipped')
  assert(core.phoneState().bus.line.skipped == 1)
  atStop(4)
  atStop(5)
  assert(not s.job, 'the line is done')
  assert(j.pay == math.floor(quote * 4 / 5 / 5 + 0.5) * 5 + bus.fares(j), 'the skipped stop is not paid')
  assert(seated == 0, 'everyone got off at the last stop')
  -- the bus is handed over at the last stop and you are taken back to the depot, to your own car
  advance(core, 4)
  assert(math.abs(pose.lat - 50.0005) < 1e-9 and math.abs(pose.lon - 14.0005) < 1e-9, 'back at the depot')
  advance(core, 2)
  assert(not c.employment and c.garage.car.model == 'pigeon', 'your car is back')
  assert(c.money > money and c.lastContract.completed == 1 and c.lastContract.gross == j.pay)
  assert(s.mode == 'bus', 'still on the bus board')
end)

test('a bus shift ended with the doors open leaves nothing behind for the next shift', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  helperAsks = {}
  core.setMode('bus')
  advance(core, 2)
  for _, a in ipairs(helperAsks) do if a.path:find('/v1/buslines', 1, true) then a.cb(busData()) end end
  pose.lat, pose.lon, pose.speed = 50.0005, 14.0005, 0
  local id = core.phoneState().bus.lines[1].id
  core.phoneAction('busStart', id)
  advance(core, 6)
  local st = s.job.bus.stops[1]
  pose.lat, pose.lon = st.g[1], st.g[2]
  advance(core, 4)
  core.phoneAction('busDoors')
  assert(s.busDwell, 'the doors are open')
  local money = c.money
  core.placesDo('endCompany')   -- the Menu's End early ends it the same way as the phone
  assert(not s.job and not s.busDwell, 'the open doors go with the shift')
  advance(core, 4)
  assert(c.employment and pose.lat == st.g[1], 'a moment to read the message first')
  advance(core, 6)
  assert(not c.employment and c.money == money - bus.COLLECT_FEE, 'ended away from the depot: the bus is collected for a fee')
  assert(math.abs(pose.lat - 50.0005) < 1e-9, 'and you are back at the depot')
  -- a new shift at the depot: its first stop is not served by the old doors
  c.garage.pendingUsed = nil   -- your car finished loading its parts
  pose.lat, pose.lon = 50.0005, 14.0005
  core.phoneAction('busStart', id)
  advance(core, 40)
  assert(s.job and s.job.bus.at == 1 and s.phase == 'toPickup', 'the new line still waits at its first stop')
end)

test('ending a bus shift: free at the depot; settled where you are when BeamNG.Earth cannot take you back', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  helperAsks = {}
  core.setMode('bus')
  advance(core, 2)
  for _, a in ipairs(helperAsks) do if a.path:find('/v1/buslines', 1, true) then a.cb(busData()) end end
  pose.lat, pose.lon, pose.speed = 50.0005, 14.0005, 0
  local id = core.phoneState().bus.lines[1].id
  local money = c.money
  core.phoneAction('busStart', id)
  advance(core, 6)
  core.phoneAction('busEnd')
  assert(not c.employment and c.money == money and c.garage.car.model == 'pigeon', 'ended at the depot: no fee')
  c.garage.pendingUsed = nil
  core.phoneAction('busStart', id)
  advance(core, 6)
  local st = s.job.bus.stops[2]
  pose.lat, pose.lon = st.g[1], st.g[2]
  local earth = package.loaded['cargoEarth/earth']
  local teleport = earth.teleport
  earth.teleport = function() return false, 'not now' end
  core.phoneAction('busEnd')
  advance(core, 10)
  earth.teleport = teleport
  assert(not c.employment and c.garage.car.model == 'pigeon' and pose.lat == st.g[1], 'your car comes where you are')
end)

test('local money: country borders, exchange rates and free exchange at the border', function()
  local borders, currency = require('cargoEarth/borders'), require('cargoEarth/currency')
  -- two square countries side by side; the second has a hole (a lake) and an island
  local idx = borders.index({ scale = 1000, countries = {
    { 'CZ', { 12000, 48000, 14000, 50000 }, { { 12000, 48000, 14000, 48000, 14000, 50000, 12000, 50000 } } },
    { 'DE', { 14000, 48000, 18000, 52000 }, { { 14000, 48000, 16000, 48000, 16000, 50000, 14000, 50000 },
      { 14500, 48500, 15000, 48500, 15000, 49000, 14500, 49000 }, { 17000, 51000, 18000, 51000, 18000, 52000, 17000, 52000 } } },
  } })
  assert(borders.find(idx, 49, 13) == 'CZ' and borders.find(idx, 49, 15.5) == 'DE' and borders.find(idx, 51.5, 17.5) == 'DE')
  assert(borders.find(idx, 48.7, 14.7) == nil, 'a lake inside a country is not land')
  assert(borders.find(idx, 30, 13) == nil and borders.find(nil, 49, 13) == nil)
  -- conversion: amounts are kept in the base unit
  assert(currency.of('DE') == 'EUR' and currency.of('CZ') == 'CZK' and currency.of('US') == 'USD' and currency.name('DE') == 'Germany')
  assert(currency.format(12400, 'CZK') == '12 400 Kč', currency.format(12400, 'CZK'))
  local eur = currency.format(12400, 'EUR')
  assert(eur == '€508.20' and currency.format(100000, 'USD'):match('^%$4,%d%d%d%.%d%d$'), eur)
  assert(currency.format(-300, 'USD'):match('^%-%$%d+%.%d%d$'), currency.format(-300, 'USD'))
  assert(currency.info('XXX').code == currency.DEFAULT and currency.info('JPY').decimals == 0)
  assert(currency.localize('Fine 300 CZK (-200 CZK)', 'CZK') == 'Fine 300 Kč (-200 Kč)')
  assert(not currency.localize('Fine 300 CZK', 'EUR'):find('CZK'))
  -- the border: two readings in a row before the money changes, and the exchange is free
  local c, track = { money = 24400 }, {}
  assert(currency.observe(c, track, nil) == nil)
  assert(currency.observe(c, track, 'CZ') == nil, 'one reading is not enough')
  local first = currency.observe(c, track, 'CZ')
  assert(first and first.from == nil and c.currency == 'CZK' and c.country == 'CZ')
  assert(currency.observe(c, track, 'DE') == nil and currency.observe(c, track, 'CZ') == nil, 'a blip on a border road')
  assert(currency.observe(c, track, 'DE') == nil)
  local change = currency.observe(c, track, 'DE')
  assert(change and change.from == 'CZK' and change.to == 'EUR' and c.money == 24400, 'free: the value stays')
  assert(currency.welcome(change, c.money):find('Germany', 1, true))
  -- in the game: the phone shows the currency, messages are converted
  local core, s = fresh()
  s.borders = idx
  pose.lat, pose.lon = 49, 15.5
  advance(core, 30)
  assert(s.career.currency == 'EUR' and s.career.country == 'DE')
  local state = core.phoneState()
  assert(state.currency.code == 'EUR' and state.currency.country == 'Germany' and state.money == s.career.money)
  assert(s.log[1]:find('Money is shown in EUR', 1, true), s.log[1])
  pose.lat, pose.lon = 49, 13
  advance(core, 30)
  assert(s.career.currency == 'CZK' and s.log[1]:find('exchanged for free', 1, true) and s.log[1]:find('Kč', 1, true), s.log[1])
  assert(currency.localize('+244 CZK + 24 CZK tip', 'EUR') == '+€10.00 + €0.98 tip')
  -- a saved career waiting to be resumed shows its money in its own currency
  s.pendingCareer = { money = 500, currency = 'USD', country = 'US' }
  state = core.phoneState()
  assert(state.screen == 'resume' and state.currency.code == 'USD' and state.currency.country == 'United States of America')
  s.pendingCareer = nil
end)

test('the support report has versions, helper state and recent problems, but no exact position', function()
  local core = fresh()
  pose.lat, pose.lon = 50.08765, 14.42132
  local copied
  setClipboard = function(text) copied = text end
  local r = core.supportReport({'20:01:02 garageState: boom'})
  setClipboard = nil
  assert(r.copied and copied == r.text, 'copied to the clipboard')
  assert(r.text:find('Mod: ' .. core.VERSION, 1, true), r.text)
  assert(r.text:find('about 50.1, 14.4', 1, true) and not r.text:find('50.08', 1, true), 'position only to 0.1 degree')
  assert(r.text:find('Helper: ', 1, true) and r.text:find('Recent problems:', 1, true))
  assert(r.text:find('garageState: boom', 1, true), 'the phone\'s own errors are in it')
  local again = core.supportReport()
  assert(not again.copied and again.text:find('Phone errors', 1, true) == nil)
end)

test('the phone says when a newer release is out (the helper looks it up)', function()
  local helper = require('cargoEarth/helper')
  local ask, enabled = helper.ask, helper.enabled
  local asked, opened = {}, nil
  helper.enabled = true
  helper.ask = function(path, cb) asked[#asked + 1] = { path, cb } end
  local ok, why = pcall(function()
    local core, s = fresh()
    assert(core.versionNewer('0.10.0', '0.9.9') and core.versionNewer('v1.0', '0.8.0'))
    assert(not core.versionNewer('0.8.0', '0.8.0') and not core.versionNewer('0.9.0-beta', '0.8.0') and not core.versionNewer(nil, '1'))
    assert(core.phoneState().update == nil, 'nothing known yet')
    advance(core, 60)
    local info
    for _, a in ipairs(asked) do if a[1] == '/v1/info' then info = a end end
    assert(info, 'asked the helper for its info')
    -- a save was loaded: the helper looks on GitHub, its answer is read a few seconds later
    core.updateOnLoad = true
    local n = #asked
    advance(core, 1)
    assert(asked[n + 1] and asked[n + 1][1] == '/v1/update/check' and not core.updateOnLoad)
    advance(core, 2 * core.UPDATE_LOAD_WAIT_S + 2)
    local reread = false
    for i = n + 2, #asked do if asked[i][1] == '/v1/info' then reread = true end end
    assert(reread, 'info read again after the check')
    -- GitHub is slow: the helper still checks, so the game reads again in a few seconds, not in 15 minutes
    local n2 = #asked
    asked[#asked][2]({ version = core.VERSION, update = { latest = core.VERSION, checking = true } })
    advance(core, 2 * core.UPDATE_PENDING_S + 2)
    local again = false
    for i = n2 + 1, #asked do if asked[i][1] == '/v1/info' then again = true end end
    assert(again, 'info read again while the check was pending')
    info[2]({ version = core.VERSION, update = { latest = '99.0.0' } })
    local u = core.phoneState().update
    assert(u and u.available and u.modOld and u.helperOld and u.latest == '99.0.0' and not u.hidden)
    assert(s.log[1]:find('Cargo Earth 99.0.0 is out', 1, true), s.log[1])
    assert(core.settingsState().update.latest == '99.0.0')
    core.updateDo('open')
    assert(asked[#asked][1] == '/v1/update/open')
    openWebBrowser = function(url) opened = url end
    asked[#asked][2]({ opened = false })
    openWebBrowser = nil
    assert(opened == 'https://github.com/themazzy/cargo-earth/releases/latest')
    u = core.updateDo('hide')
    assert(u.hidden and s.career.updateHidden == '99.0.0')
    -- up to date: no notice
    info[2]({ version = core.VERSION, update = { latest = core.VERSION } })
    assert(not core.phoneState().update.available)
  end)
  helper.ask, helper.enabled = ask, enabled
  assert(ok, why)
end)

test('a rush taxi ride is never ended by a rough ride; only the speed counts', function()
  local core = fresh()
  assert(core.speedOnly({ taxi = { mode = 'rush' } }) and not core.speedOnly({ taxi = { mode = 'comfort' } }))
  assert(not core.speedOnly({ kind = 'food' }) and not core.speedOnly(nil))
end)

test('the phone starts a helper that is not running through BeamNG.Earth\'s add-on list', function()
  local helper = require('cargoEarth/helper')
  local enabled, status = helper.enabled, helper.status
  local h = { state = 'off' }
  helper.status = function() return h end
  local sent, card = {}, { id = 'cargo-earth-helper', author = 'themazzy', installed = false, running = false, canInstall = true }
  package.loaded['beamngEarth/addons'] = {
    uiState = function() return { connected = true, addons = { card } } end,
    install = function(id, agreed) sent[#sent + 1] = 'install:' .. id .. ':' .. tostring(agreed) return true end,
    manage = function(id, op) sent[#sent + 1] = op return true end,
  }
  package.loaded['cargoEarth/earthaddon'] = nil
  local ok, why = pcall(function()
    local core, s = fresh()
    helper.enabled = true
    assert(core.phoneState().helperStart == nil, 'not before a failed ask')
    h.msg = 'Cargo Earth helper not running (connection refused)'
    local hs = core.phoneState().helperStart
    assert(hs and not hs.installed and hs.author == 'themazzy' and not hs.busy, 'offered')
    core.phoneAction('helperStart')
    assert(sent[1] == 'install:cargo-earth-helper:true' and #sent == 1, table.concat(sent, ','))
    assert(core.phoneState().helperStart.busy, 'starting')
    card.installed = true
    core.phoneState()
    assert(sent[2] == 'start' and sent[3] == 'autostart_on', table.concat(sent, ','))
    -- already installed: Start only
    s.clock = s.clock + 60
    sent = {}
    core.phoneAction('helperStart')
    assert(sent[1] == 'start' and sent[2] == 'autostart_on' and #sent == 2)
    core.phoneAction('helperHide')
    assert(core.phoneState().helperStart == nil, 'hidden')
    -- closing the notice while the install runs: it still starts once installed (from the update loop)
    s.helperStartHidden, card.installed, sent = nil, false, {}
    core.phoneAction('helperStart')
    core.phoneAction('helperHide')
    card.installed = true
    advance(core, 2)
    assert(sent[2] == 'start' and sent[3] == 'autostart_on', 'started while hidden: ' .. table.concat(sent, ','))
    -- only cameras / radio asked (Czech data covers the rest): a failed connection still offers Start
    s.helperStartHidden, h.msg, h.down = nil, nil, 'connection refused'
    assert(core.phoneState().helperStart, 'offered on a failed camera ask')
    h.down = nil
    -- no BeamNG.Earth add-on list: nothing offered
    package.loaded['beamngEarth/addons'] = nil
    s.helperStartHidden = nil
    assert(core.phoneState().helperStart == nil)
    h.state, h.msg = 'ready', nil
  end)
  package.loaded['beamngEarth/addons'], helper.enabled, helper.status = nil, enabled, status
  assert(ok, why)
end)

test('the dash phone part only runs the phone app\'s own calls', function()
  local core = fresh()
  assert(core.dashAllowed('cargoEarth_core and cargoEarth_core.phoneAction("online") or nil'))
  assert(core.dashAllowed('(function() if not cargoEarth_core then return nil end; local ok, value = pcall(cargoEarth_core.garageDo, "x") end)()'))
  assert(not core.dashAllowed('os.exit()'))
  assert(not core.dashAllowed('be:getPlayerVehicle(0)'))
  assert(not core.dashAllowed(nil) and not core.dashAllowed(string.rep('a', 5000)))
end)

test('a wreck never costs more to repair than the car is worth', function()
  local garage = require('cargoEarth/garage')
  local values = {body = 4000, engine = 2000}
  local G = {
    vehicle = function() return {slotPartMap = {['/'] = 'body', ['/engine/'] = 'engine'}} end,
    part = function(_, name) return {information = {name = name, value = values[name]}} end,
  }
  local g = {started = true, car = {model = 'pigeon'}, repair = 0, debt = 0, lastDamage = 0}
  -- the value is not known yet: the plain damage price
  garage.trackDamage(g, 1000)
  local plain = g.repair
  assert(plain > 0 and garage.repairCap(g) == nil)
  garage.noteValue(G, g)
  local cap = garage.repairCap(g)
  assert(g.car.value == garage.carValue(G) and cap == math.floor(g.car.value * garage.REPAIR_CAP / 5 + 0.5) * 5)
  -- a small hit is priced as before, a total wreck stops at the cap
  garage.trackDamage(g, 1000)
  assert(g.repair == plain)
  local what = garage.trackDamage(g, 300000)
  assert(what == 'hit' and g.repair == cap, 'repair ' .. g.repair .. ' cap ' .. cap)
  local _, grow = garage.trackDamage(g, 400000)
  assert(grow == 0 and g.repair == cap, 'more damage on a wreck adds nothing')
  -- a free menu repair of a wreck puts only the capped price on the debt
  assert(garage.trackDamage(g, 0) == 'debt' and g.debt == cap and g.repair == 0)
end)

test('trade-in credit uses market mileage, deducts repairs and guarantees a quarter of installed value', function()
  local garage = require('cargoEarth/garage')
  local G = {vehicle = function() return {slotPartMap = {body = 'body'}} end,
    part = function() return {information = {value = 10000 / garage.PRICE_PER_VALUE}} end,
    spawn = function() end}
  local offer = {model = 'etk', name = 'Replacement', price = 8000}
  for _, row in ipairs({{0, 0, 5000}, {0, 1000, 4000}, {40000, 0, 3750}, {40000, 1000, 2750},
                        {80000, 0, 2500}, {80000, 1000, 2500}, {200000, 5000, 2500}}) do
    local g, c = {car = {km = row[1]}, repair = row[2]}, {money = offer.price - row[3] - 1}
    assert(garage.tradeInQuote(G, g) == row[3])
    assert(not garage.buyCar(G, g, c, offer) and g.repair == row[2] and g.car.km == row[1])
    c.money = c.money + 1
    assert(garage.buyCar(G, g, c, offer) and c.money == 0 and g.repair == 0)
    g = {car = {name = 'My car', km = row[1]}, repair = row[2]}
    c = {money = 1000}
    local ok, _, paid = garage.sellCar(G, g, c)
    assert(ok and paid == row[3] and c.money == 1000 + row[3])
    assert(not g.car and g.repair == 0)

  end
end)

test('buying after a test drive uses the trade-in quote from the owned car', function()
  local garage = require('cargoEarth/garage')
  local owned = {model = 'pigeon', slotPartMap = {body = 'body'}}
  local current = owned
  local G = {vehicle = function() return current end, isOwned = function() return true end,
    part = function() return {information = {value = 10000 / garage.PRICE_PER_VALUE}} end,
    spawn = function(model) current = {model = model, slotPartMap = {}} end}
  local offer = {id = 9, model = 'etk', name = 'Replacement', price = 8000}
  local g = {started = true, car = {model = 'pigeon', km = 80000}, market = {list = {offer}}}
  assert(garage.previewStart(G, g, 9, false) and g.preview.tradeIn == 2500)
  g.preview.ready = true
  local career = {money = 5500}
  assert(garage.buyListing(G, g, career, 9) and career.money == 0 and g.car.model == 'etk')
end)

test('a restored damaged car keeps its repair bill once and a paid repair clears its snapshot', function()
  local core, s = fresh()
  local g = s.career.garage
  g.debt, g.repair = 0, 500
  g.car.key = 'custom'
  g.car.physicalDamage = {format = 'v2', cargoEarthLocalNodes = true, nodes = {}, beams = {}}
  local snapshots, restored = require('cargoEarth/damage'), 0
  core.G.vehicleState = function(action, path, token)
    if action == 'restore' then
      restored = restored + 1
      damageValue = 12000
    else
      disk[path] = {format = 'v2', cargoEarthLocalNodes = true, nodes = {}, beams = {}}
    end
    snapshots.complete(token, 1, true)
    return true
  end
  assert(core.garageBringCar(true))
  advance(core, 12)
  assert(restored == 1 and g.repair == 500 and g.debt == 0, 'restore must neither double the repair bill nor create debt ' .. tostring(restored) .. '/' .. tostring(g.repair) .. '/' .. tostring(g.debt))
  damageValue = damageValue + 1000
  advance(core, 4)
  assert(g.repair > 500)
  local bill = g.repair
  core.G.vehicleState = nil
  core.G.repair = function() damageValue = 0 end
  assert(core.garageRepair())
  assert(not g.car.physicalDamage and not g.damageBaseline)
  assert(s.career.money == 1000 - bill)
end)

test('an older car save loads normally and starts capturing its current state', function()
  local core, s = fresh()
  local g = s.career.garage
  g.car.key = 'custom'
  g.repair, g.debt = 100, 0
  local captures, restores = 0, 0
  core.G.vehicleState = function(action, path, token)
    if action == 'capture' then captures = captures + 1 else restores = restores + 1 end
    disk[path] = {format = 'v2'}
    require('cargoEarth/damage').complete(token, 1, true)
    return true
  end
  assert(core.garageBringCar(true))
  advance(core, 22)
  core.saveOptions()
  assert(restores == 0 and captures > 0 and g.car.physicalDamage)
  assert(g.repair == 100 and g.debt == 0)
end)

test('pausing waits for the completed damage snapshot to reach the career file', function()
  local core, s = fresh()
  s.career.garage.car.key = 'custom'
  core.saveOptions()
  local g, c = s.career.garage, s.career
  local request
  core.G.vehicleState = function(action, path, token)
    request = {path = path, token = token}
    return true
  end
  core.settingsDo('pause')
  assert(request and not s.pendingCareer and s.pauseSaving == c)
  disk[request.path] = {format = 'v2', nodes = {latestDamage = 123}}
  require('cargoEarth/damage').complete(request.token, 1, true)
  assert(s.pendingCareer == c and not s.pauseSaving)
  local saved = disk[core.savePath(c)]
  assert(saved.garage.car.physicalDamage.nodes.latestDamage == 123)
  assert(not saved.pauseSaving)
end)

test('repairing a parked car clears its damage snapshot and invalidates pending captures', function()
  local module, garage = require('cargoEarth/damage'), require('cargoEarth/garage')
  local car = {fleetId = 7, name = 'Parked car', model = 'pigeon', parkedRepair = 500,
    physicalDamage = {format = 'v2', nodes = {oldDamage = true}}}
  local g, c, request = {car = car}, {money = 1000}, nil
  local G = {playerId = function() return 1 end, vehicleState = function(action, path, token)
    request = {path = path, token = token}
    return true
  end}
  module.capture(G, g, function() end)
  g.car, g.parked = nil, {car}
  assert(garage.repairParked(g, c, 7))
  assert(c.money == 500 and car.parkedRepair == 0 and not car.physicalDamage and car.damageRevision == 1)
  disk[request.path] = {format = 'v2', nodes = {oldDamage = true}}
  module.complete(request.token, 1, true)
  assert(not car.physicalDamage, 'the late capture must not undo the paid repair')
end)

test('external vehicle replacement checkpoints and pauses even if the vehicle VM cannot answer', function()
  local core, s = fresh()
  s.career.garage.car.key = 'custom'
  core.saveOptions()
  local path, request = core.savePath(s.career), nil
  core.G.vehicleState = function(action, file, token) request = {path=file, token=token} return true end
  local cleared = false
  core.G.clearOwnership = function() cleared = true end
  core.settingsDo('pause')
  assert(s.pauseSaving and not s.pendingCareer)
  core.onBeforeVehicleReplaced(1)
  assert(cleared and s.pendingCareer == s.career and not s.pauseSaving)
  assert(disk[path].garage.car.model == 'pigeon')
  require('cargoEarth/damage').tick(11)
  assert(s.pendingCareer == s.career, 'a late timeout must not reactivate the career')
end)

test('owned car switches capture fresh outgoing damage before spawning the parked vehicle', function()
  local core, s = fresh()
  local g, request = s.career.garage, nil
  local old = g.car
  old.key = 'custom'
  g.parked = {{fleetId=5,model='etk',name='Parked car',key='base'}}
  core.G.vehicleState = function(action, file, token) request = {path=file,token=token} return true end
  damageValue = 10000
  require('cargoEarth/damage').capture(core.G, g, function() end)
  core.garageDo('switchCar', 5)
  assert(g.car == old and vehicle.model == 'pigeon', 'the outgoing vehicle must survive until capture completes')
  local earlier = request
  disk[earlier.path] = {format='v2',nodes={earlierDamage=true}}
  require('cargoEarth/damage').complete(earlier.token,1,true)
  assert(request.token ~= earlier.token and g.car == old, 'replacement requires a fresh snapshot after an in-flight save')
  disk[request.path] = {format='v2',nodes={freshDamage=true}}
  require('cargoEarth/damage').complete(request.token,1,true)
  assert(g.car.model == 'etk' and old.physicalDamage.nodes.freshDamage)
  assert(g.parked[1] == old and old.parkedRepair > 0)
end)

test('dealer previews and keep-car purchases capture the outgoing car before spawning', function()
  for _, action in ipairs({'preview','buyListing'}) do
    local core, s = fresh()
    local g, request = s.career.garage, nil
    local old = g.car
    old.key = 'custom'
    g.repair, g.debt = 0, 0
    s.career.money = 100000
    g.market = {list={{id=9,model='etk',name='Dealer car',key='base',price=100}}}
    core.G.vehicleState = function(op, file, token) request={path=file,token=token} return true end
    core.garageDo(action, 9, true)
    assert(vehicle.model == 'pigeon' and request)
    disk[request.path] = {format='v2',nodes={latestDealerState=true}}
    require('cargoEarth/damage').complete(request.token,1,true)
    assert(vehicle.model == 'etk' and old.physicalDamage.nodes.latestDealerState)
    if action == 'preview' then assert(g.preview and g.car == old)
    else assert(g.parked[1] == old and g.car.model == 'etk') end
  end
end)

test('snapshot capture rejects late results after a paid repair and retries a lost callback', function()
  local module = require('cargoEarth/damage')
  local request, writes = nil, 0
  local g = {car = {}}
  local G = {playerId = function() return 1 end, vehicleState = function(action, path, token)
    request = {path = path, token = token}
    return true
  end}
  module.capture(G, g, function(ok) if ok then writes = writes + 1 end end)
  module.clear(g.car)
  disk[request.path] = {format = 'v2'}
  module.complete(request.token, 1, true)
  assert(not g.car.physicalDamage and writes == 0)
  module.capture(G, g, function(ok) if ok then writes = writes + 1 end end)
  module.tick(11)
  module.capture(G, g, function(ok) if ok then writes = writes + 1 end end)
  disk[request.path] = {format = 'v2'}
  module.complete(request.token, 1, true)
  assert(g.car.physicalDamage and writes == 1)
end)

test('Settings puts the phone on the dash of the car you drive, and each new car gets it', function()
  local core = fresh()
  local dash = require('cargoEarth/dash')
  dash.store = { read = function() return nil end, write = function() end }
  dash.load()
  -- a small right-hand drive car: dash nodes across the car, and the driver camera
  local nodes, cid = {}, 0
  for i = -3, 3 do
    for _, row in ipairs({ { 'dsh2_', 0.87 }, { 'dsh1_', 0.99 } }) do
      nodes[cid] = { cid = cid, name = row[1] .. i, pos = { x = i * 0.2, y = -0.457, z = row[2] }, group = { [0] = 'dash' } }
      cid = cid + 1
    end
  end
  local vdata = { nodes = nodes, cameras = { onboard = { { name = 'driver', x = -0.316, y = 0.1, z = 1.25 } } } }
  local function copy(t) local o = {} for k, x in pairs(t) do o[k] = type(x) == 'table' and copy(x) or x end return o end
  local respawns = {}
  local v = { id = 9, model = 'pigeon', config = { partsTree = { chosenPartName = 'pigeon', children = { pigeon_mod = { chosenPartName = '' } } } },
    data = { vdata = vdata } }
  core.G.vehicle = function() return v end
  core.G.respawnPlayer = function(edit)
    local config = copy(v.config)
    edit(config)
    respawns[#respawns + 1] = config
  end
  local st = core.settingsState().dash
  assert(st.car and not st.on and not st.fitted)
  st = core.settingsDo('dash', 'on').dash
  assert(st.on and st.placed and not st.error and #respawns == 1, 'measured and respawned with the phone')
  assert(dash.treeHasPhone(respawns[1].partsTree) and respawns[1].partsTree.children.pigeon_mod)
  assert(not dash.treeHasPhone(v.config.partsTree), 'the car\'s own tree is left for the game to change')
  v.config = respawns[1]
  assert(core.settingsState().dash.fitted)
  core.settingsDo('dash', 'on')
  assert(#respawns == 1, 'already on this car')
  -- each press moves it 1 cm and rebuilds the car
  -- presses close together are applied with one reload, once they stop
  st = core.settingsDo('dash', 'z+').dash
  assert(st.moving and #respawns == 1 and st.nudge.z == 1, 'not reloaded at once')
  core.settingsDo('dash', 'z+')
  core.settingsDo('dash', 'z-')
  advance(core, 2)
  assert(#respawns == 1, 'still waiting for the presses to stop')
  advance(core, 2)
  st = core.settingsState().dash
  assert(#respawns == 2 and not st.moving, 'respawns ' .. #respawns .. ' ' .. tostring(st.error)) assert(st.nudge.z == 1, tostring(st.nudge.z)) assert(dash.treeHasPhone(respawns[2].partsTree))
  core.settingsDo('dash', 'reset')
  advance(core, 4)
  assert(#respawns == 3 and not core.settingsState().dash.nudged)
  -- a new car: a moment after it appears, it gets the phone too, and only one try
  v = { id = 10, model = 'pigeon', config = { partsTree = { children = {} } }, data = { vdata = vdata } }
  core.onVehicleSpawned(10)
  assert(#respawns == 3)
  advance(core, 4)
  assert(#respawns == 4 and dash.treeHasPhone(respawns[4].partsTree), 'the new car got it')
  core.onVehicleSpawned(10)
  advance(core, 4)
  assert(#respawns == 4, 'a car the phone did not stay in is not respawned again and again')
  -- switched off while the car is busy being changed: it is taken out once the car is free
  v.config = respawns[4]
  core.G.applyingParts = true
  st = core.settingsDo('dash', 'off').dash
  assert(not st.on and st.error and #respawns == 4, 'busy: nothing changes yet')
  advance(core, 4)
  assert(#respawns == 4)
  core.G.applyingParts = false
  advance(core, 8)
  assert(#respawns == 5 and not dash.treeHasPhone(respawns[5].partsTree), 'taken out once the car is free')
  v.config = respawns[5]
  advance(core, 8)
  assert(#respawns == 5)
  -- a nudge while the car is busy moves the phone once the car is free, and so does switching back on right after
  -- switching off (the retry cooldown is for new cars only)
  core.G.applyingParts = true
  st = core.settingsDo('dash', 'on').dash
  assert(st.on and #respawns == 5)
  core.G.applyingParts = false
  advance(core, 8)
  assert(#respawns == 6 and dash.treeHasPhone(respawns[6].partsTree), 'back on despite the cooldown')
  v.config = respawns[6]
  core.G.applyingParts = true
  st = core.settingsDo('dash', 'y+').dash
  assert(#respawns == 6 and st.nudge.y == 1)
  core.G.applyingParts = false
  advance(core, 8)
  assert(#respawns == 7 and dash.treeHasPhone(respawns[7].partsTree), 'the nudge is applied once the car is free')
  v.config = respawns[7]
  advance(core, 8)
  assert(#respawns == 7)
  core.settingsDo('dash', 'reset')
  advance(core, 4)
  assert(#respawns == 8)
  -- switched off normally: taken out of the car
  v.config = respawns[4]
  v.id = 12
  st = core.settingsDo('dash', 'off').dash
  assert(not st.on and #respawns == 9 and not dash.treeHasPhone(respawns[9].partsTree))
  v.config = respawns[9]
  core.onVehicleSpawned(12)
  advance(core, 4)
  assert(#respawns == 9, 'off: new cars stay as they are')
  -- a damaged career car is not reloaded for the phone (the reload would mend it)
  local g = core.state().career.garage
  core.G.isOwned = function(car) return car == v end
  g.repair = 50
  st = core.settingsDo('dash', 'on').dash
  assert(st.on and st.error and #respawns == 9, 'damaged: not reloaded')
  g.repair = 0
  -- an undamaged career car: reloaded, then its mileage and paint wear go back on
  local conditions = 0
  core.G.applyCondition = function() conditions = conditions + 1 end
  st = core.settingsDo('dash', 'on').dash
  assert(#respawns == 10 and not st.error)
  advance(core, 10)
  assert(conditions >= 1, 'condition restored after the reload')
  core.G.isOwned = function() return false end
  -- a loaded car keeps no node groups (the game deletes them): the car is reloaded once, unchanged, and measured from
  -- its nodes as it loads
  local bare = {}
  for k, n in pairs(nodes) do bare[k] = { cid = n.cid, name = n.name, pos = n.pos } end
  v = { id = 12, model = 'ferax', config = { partsTree = { chosenPartName = 'ferax', children = {} } },
    data = { vdata = { nodes = bare, cameras = vdata.cameras } } }
  local before = #respawns
  st = core.settingsDo('dash', 'on').dash
  assert(not st.error and #respawns == before + 1 and not dash.treeHasPhone(respawns[#respawns].partsTree), 'reloaded unchanged')
  local loading = {}
  for _, n in pairs(nodes) do loading[n.name] = { name = n.name, cid = n.cid, pos = n.pos, group = n.group } end
  core.onJbeamLoadingPhase2(nil, 12, { model = 'ferax', nodes = loading })
  core.onVehicleSpawned(12)
  advance(core, 5)
  assert(#respawns == before + 2 and dash.treeHasPhone(respawns[#respawns].partsTree) and dash.spot('ferax'), 'measured as it loaded')
  -- measured again: a car from the game's cache is reloaded, and the measurement is not forgotten on the way
  v.config = copy(respawns[#respawns])
  dash.forgetLoaded()
  local old = dash.spot('ferax')
  st = core.settingsDo('dash', 'measure').dash
  assert(not st.error and #respawns == before + 3, 'reloaded to measure')
  core.onJbeamLoadingPhase2(nil, 12, { model = 'ferax', nodes = loading })
  core.onVehicleSpawned(12)
  advance(core, 25)
  assert(#respawns == before + 4 and dash.spot('ferax') ~= old, 'measured again after the reload')
  dash.setOn(false)
  -- no dash to stand on
  v = { id = 11, model = 'unicycle', config = { partsTree = { children = {} } }, data = {} }
  st = core.settingsDo('dash', 'on').dash
  assert(st.error and #respawns == before + 4)
  dash.setOn(false)
end)

test('the phone\'s offline screen switches between food delivery and freight', function()
  local core, s = fresh()
  assert(s.mode == 'courier' and core.phoneState().canSwitch)
  core.phoneAction('mode', 'trucking')
  assert(s.mode == 'trucking', 'switched from the phone')
  core.phoneAction('online')
  core.phoneAction('mode', 'courier')
  assert(s.mode == 'trucking', 'not while online')
  core.phoneAction('offline')
  core.phoneAction('mode', 'os.exit')
  assert(s.mode == 'trucking')
  core.phoneAction('mode', 'courier')
  assert(s.mode == 'courier')
end)

test('the buttons beside the dash phone switch online and offline, and pass the rest to the phone', function()
  local core, s = fresh()
  assert(not s.phone.online)
  core.dashButton('online')
  assert(s.phone.online, 'online')
  core.dashButton('online')
  assert(not s.phone.online, 'and offline again')
  local asked = {}
  local real = core.phoneAction
  core.phoneAction = function(a) asked[#asked + 1] = a end
  core.dashButton('accept') core.dashButton('decline') core.dashButton('gps') core.dashButton('os.exit')
  core.phoneAction = real
  assert(#asked == 3 and asked[1] == 'accept' and asked[2] == 'decline' and asked[3] == 'gps')
end)

test('one radio for both phones: the UI page plays it while it checks in, else the helper', function()
  local helper = require('cargoEarth/helper')
  local ask, command, enabled, commanding = helper.ask, helper.command, helper.enabled, helper.commanding
  local cmds, stored = {}, nil
  local host, port = helper.HOST, helper.PORT
  helper.enabled, helper.HOST, helper.PORT = true, '127.0.0.1', 47821
  helper.ask = function() end
  helper.command = function(path, cb) cmds[#cmds + 1] = { path, cb } end
  helper.commanding = function() return false end
  local ok, why = pcall(function()
    local core = fresh()
    core.radioStore = { read = function() return stored end, write = function(t) stored = t end }
    local ID = '96202f73-0601-11e8-ae97-52543be04c81'
    local st = { id = ID, name = 'Rádio Jih', url = 'http://a/stream', codec = 'MP3', kbps = 128, country = 'CZ', ['$$hashKey'] = 'x' }
    local function last() return cmds[#cmds] and cmds[#cmds][1] or '' end
    assert(core.phoneState().radio == nil and core.radioState().radio.status == 'idle')
    -- the dash phone alone (no UI page checks in): the helper plays
    local r = core.radioDo('play', st).radio
    assert(r.on and r.seq == 1 and r.mode == 'helper' and r.status == 'loading' and r.station.name == 'Rádio Jih')
    assert(last():find('/v1/player/play?id=' .. ID, 1, true), last())
    assert(stored and stored.last.id == ID, 'the last station is kept')
    assert(core.phoneState().radio.name == 'Rádio Jih' and core.phoneState().radio.seq == 1)
    -- the UI page checks in: it plays, the helper stops
    local n = #cmds
    local p = core.radioDo('page', -1, 'idle', '')
    assert(p.radio.mode == 'page' and p.radio.on and p.stream and p.radio.saved == nil, 'the page hears it in short')
    assert(#cmds == n + 1 and last() == '/v1/player/stop')
    core.radioDo('page', 1, 'playing', '')
    assert(core.radioState().radio.status == 'playing' and core.phoneState().radio.status == 'playing')
    -- the page cannot play a stream: the helper plays that one
    core.radioDo('page', 1, 'error', 'error 4')
    r = core.radioState().radio
    assert(r.alone and r.mode == 'helper' and r.why:find('error 4', 1, true) and last():find('/v1/player/play', 1, true))
    cmds[#cmds][2]({ playing = true, sound = true, secs = 2 })
    assert(core.radioState().radio.status == 'playing')
    -- the helper's player stopped by itself: stopped, Play works again
    cmds[#cmds][2]({ playing = false })
    assert(core.radioState().radio.status == 'idle' and not core.radioState().radio.on)
    -- a new station from the other phone, played by the page again
    local two = { id = '96202f73-0601-11e8-ae97-52543be04c82', name = 'Two', url = 'https://b/s', codec = 'OGG' }
    r = core.radioDo('play', two).radio
    assert(r.seq == 2 and not r.alone and r.mode == 'page')
    assert(core.radioDo('play', two).radio.seq == 2, 'pressing the playing station again changes nothing')
    -- the page went away (the UI reloaded): after a few seconds the helper plays
    advance(core, math.ceil(core.RADIO_PAGE_S / 0.5) + 2)
    assert(core.radioState().radio.mode == 'helper' and last():find('/v1/player/play?id=' .. two.id, 1, true))
    core.radioDo('stop')
    assert(last() == '/v1/player/stop' and not core.radioState().radio.on)
    -- the helper failed (not running): Play on the same station tries again
    core.radioDo('play', st)
    cmds[#cmds][2](nil, 'connection refused')
    assert(core.radioState().radio.status == 'error')
    local n2 = #cmds
    local again = core.radioDo('play', st).radio
    assert(#cmds == n2 + 1 and last():find('/v1/player/play?id=' .. ID, 1, true) and again.status == 'loading', 'tried again')
    core.radioDo('stop')
    -- AAC goes to the helper, bad streams to an error
    r = core.radioDo('play', { id = 'c', name = 'AAC', url = 'http://c/s', codec = 'AAC+' }).radio
    assert(r.alone)
    r = core.radioDo('play', { id = 'x', name = 'Bad', url = 'javascript:alert(1)' }).radio
    assert(r.status == 'error' and not r.on)
    -- volume, the player setting and saved stations are kept for both phones
    core.radioDo('vol', 0.3)
    core.radioDo('via', 'helper')
    core.radioDo('fav', st)
    core.radioDo('fav', two)
    core.radioDo('fav', st)
    r = core.radioState().radio
    assert(r.vol == 0.3 and r.via == 'helper' and #r.saved == 1 and r.saved[1].id == two.id and r.saved[1]['$$hashKey'] == nil)
    assert(stored.vol == 0.3 and stored.via == 'helper' and #stored.saved == 1)
    -- an older version's settings from the UI page come in once, and only when nothing is kept yet
    core.radioDo('import', { vol = 0.9, saved = {} })
    assert(core.radioState().radio.vol == 0.3, 'kept settings win')
    local again = fresh()
    stored = nil
    again.radioStore = { read = function() return stored end, write = function(t) stored = t end }
    again.radioDo('import', { vol = 0.9, via = 'page', last = st, saved = { st, { id = 'bad' } } })
    r = again.radioState().radio
    assert(r.vol == 0.9 and #r.saved == 1 and r.station.id == ID and not r.on)
    -- Work or Radio is the same on both phones; a ringing order shows Work
    assert(again.phoneState().tab == 'orders')
    again.phoneTab('radio')
    assert(again.phoneState().tab == 'radio')
    again.phoneTab('os.exit')
    assert(again.phoneState().tab == 'radio')
  end)
  helper.ask, helper.command, helper.enabled, helper.commanding = ask, command, enabled, commanding
  helper.HOST, helper.PORT = host, port
  assert(ok, why)
end)

test('the Menu window opens in the Menu app, else the floating phone, else on the asking phone', function()
  local core = fresh()
  local sent = {}
  guihooks = {trigger = function(name, data) sent[#sent + 1] = {name, data} end}
  local t = 100
  core.now = function() return t end
  assert(core.dashAllowed('cargoEarth_core and cargoEarth_core.openMenu("career","firm")'))
  assert(core.openMenu('career', 'firm') == false and #sent == 0, 'no floating phone: the dash shows it itself')
  core.menuHost('phone')
  assert(core.openMenu('career', 'firm') == true)
  assert(sent[1][1] == 'CargoEarthOpenMenu' and sent[1][2].panel == 'career' and sent[1][2].view == 'firm' and sent[1][2].to == 'phone')
  assert(core.openMenu('os.exit', nil) == false and #sent == 1)
  core.menuHost('menu')
  assert(core.openMenu('settings') == true and sent[2][2].to == 'menu', 'the Menu app wins over the floating phone')
  assert(core.openMenu('toggle') == true and sent[3][2].panel == 'toggle' and sent[3][2].to == 'menu', 'the Menu button toggles the window where it is')
  t = 110
  assert(core.openMenu('settings') == false, 'apps not heard from lately are gone')
  guihooks = nil
end)

test('before a saved career is loaded the Menu opens on Settings, where only the dash phone can change', function()
  local core = fresh()
  local s = core.state()
  local sent = {}
  guihooks = {trigger = function(name, data) sent[#sent + 1] = {name, data} end}
  core.now = function() return 100 end
  core.menuHost('phone')
  s.pendingCareer = { money = 500 }
  assert(core.phoneState().screen == 'resume')
  assert(core.openMenu('garage') == true and sent[1][2].panel == 'settings', 'career sections wait for the save')
  assert(core.openMenu('toggle') == true and sent[2][2].panel == 'toggle')
  local st = core.settingsState()
  assert(st.paused and st.dash, 'Settings shows the dash phone while paused')
  local mode = s.mode
  core.settingsDo('mode', mode == 'courier' and 'trucking' or 'courier')
  assert(s.mode == mode, 'job settings belong to the save')
  -- the Radio tab works too: the helper's asks (the station list) and presses go on while the save waits
  local helper = require('cargoEarth/helper')
  local tick, asking, commanding, pump = helper.tick, helper.asking, helper.commanding, helper.pump
  local ticked, pumped = 0, 0
  helper.asking = function() return true end
  helper.commanding = function() return true end
  helper.tick = function(_, _, _, _, _, onlyAsks) assert(onlyAsks) ticked = ticked + 1 end
  helper.pump = function() pumped = pumped + 1 end
  local ok, why = pcall(function()
    pose.lat, pose.lon = 50.08, 14.42
    for _ = 1, 5 do core.onUpdate(0.3, 0.3) end
    assert(pumped == 5 and ticked >= 2, 'radio requests are worked while paused')
  end)
  helper.tick, helper.asking, helper.commanding, helper.pump = tick, asking, commanding, pump
  assert(ok, why)
  s.pendingCareer = nil
  assert(not core.settingsState().paused)
  guihooks = nil
end)

test('drivers hold licences, know one kind of vehicle best and need a vehicle fit for its work', function()
  local fleet = require('cargoEarth/fleet')
  local seq = {0.5, 0.5, 0.1, 0.1, 0.1, 0.1, 0.01}
  local n = 0
  local function rnd() n = n + 1 return seq[n] or 0.5 end
  local a = fleet.applicant(rnd, 1)
  assert(a.licences.car and a.licences.truck and a.licences.artic and a.knows == 'car')
  local plain = fleet.applicant(function() return 0.99 end, 2)
  assert(plain.licences.car and not plain.licences.truck)
  assert(a.wage == fleet.wage(a.speed, a.care) + 25, 'truck licences cost more')
  assert(fleet.licensed(plain, 'van') and fleet.licensed(plain, 'suv') and not fleet.licensed(plain, 'rigid'))
  assert(fleet.licensed(a, 'semi') and fleet.licensed(a, 'rigid'))
  -- the kind they know best brings in more
  local d = {speed = 1, care = 1, wage = 20, licences = {car = true}, knows = 'van'}
  assert(fleet.netFor(d, 'van', 1) > fleet.netFor(d, 'car', 1) + (fleet.GROSS.van - fleet.GROSS.car) - 1)
  -- a driver from before licences keeps driving what they drive
  local old = fleet.restore({name = 'Old', speed = 1, care = 1, wage = 25}, 'semi')
  assert(fleet.licensed(old, 'semi'))
  -- a car with no cargo boxes leaves its driver waiting
  local g = {parked = {{fleetId = 1, name = 'Hatch', model = 'covet', vclass = 'car', boxCount = 0, km = 0,
    driver = {name = 'D', speed = 1, care = 1, wage = 20, licences = {car = true}}}}}
  fleet.advance(g, fleet.SHIFT_S, 1, {firm = {}}, function() return 0.99 end)
  assert(g.parked[1].driver.waiting == 'boxes')
  g.parked[1].boxCount = 2
  local income = fleet.advance(g, fleet.SHIFT_S, 1, {firm = {}}, function() return 0.99 end)
  assert(not g.parked[1].driver.waiting and income > 0)
  -- no truck licence: the box truck stands
  g.parked[1].vclass, g.parked[1].model = 'rigid', 'md_series'
  fleet.advance(g, fleet.SHIFT_S, 1, {firm = {}}, function() return 0.99 end)
  assert(g.parked[1].driver.waiting == 'licence')
end)

print(string.format('%d career tests passed', total))

do
  local layout = require('cargoEarth/layout')
  local written, added, current = nil, {}, nil
  local layouts = {
    {type = 'freeroam', filename = '/settings/ui_apps/layouts/default/freeroam.uilayout.json', apps = {}},
    {type = 'beamngEarth', filename = '/settings/ui_apps/layouts/default/beamngEarth.uilayout.json', apps = {{appName = 'tacho2'}}},
  }
  local api = {layouts = function() return layouts end,
    addApp = function(fn, name, placement) added[#added + 1] = {fn, name, placement}; return true end,
    current = function() return layouts[2] end, setCurrent = function(fn) current = fn end}
  local flag = {read = function() return written end, write = function(t) written = t end}
  assert(layout.ensure(api, flag) == 'added')
  assert(#added == 2 and added[1][1]:find('beamngEarth') and added[1][2] == 'cargoEarthPhone' and added[1][3].bottom == '310px')
  assert(added[2][2] == 'cargoEarthMenu', 'the Menu app comes along')
  assert(current == layouts[2].filename and written.phoneAdded and written.menuAdded)
  assert(layout.ensure(api, flag) == 'done' and #added == 2, 'only once: a player who removes it keeps that')
  written = {phoneAdded = true}
  assert(layout.ensure(api, flag) == 'added' and #added == 3 and added[3][2] == 'cargoEarthMenu', 'players from before get the Menu app once')
  written = nil
  layouts[2].apps[2] = {appName = 'cargoEarthPhone'}
  layouts[2].apps[3] = {appName = 'cargoEarthMenu'}
  assert(layout.ensure(api, flag) == 'present' and #added == 3, 'apps the player placed are left alone')
  written = nil
  assert(layout.ensure({layouts = function() return {layouts[1]} end}, flag) == 'none' and written == nil)
  assert(layout.ensure(nil, flag) == nil)
  written = nil
  local refuse = {layouts = function() return {{type = 'beamngEarth', filename = 'x/beamngEarth.uilayout.json', apps = {}}} end,
    addApp = function() return false end, current = function() return nil end, setCurrent = function() end}
  assert(layout.ensure(refuse, flag) == nil and written == nil, 'a refused insert is not recorded as done')
  print('PASS the phone goes into the .Earth layout above the speedometer, once')
end

test('food customers: nearer and same-town addresses are likelier, a long road detour is skipped', function()
  assert(food.customerWeight(1, true) == 1)
  assert(food.customerWeight(1, false) == food.OTHER_TOWN, 'another village is less likely')
  assert(food.customerWeight(4, true) < 0.3, 'a far address is less likely')
  assert(food.customerWeight(1, nil) == 1, 'no town known: no town weight')
  -- a city: the address names its quarter, the restaurants the city
  local city = food.index({cats = {}, tile = 0.05, restaurants = {{'a', 50.08, 14.42, 50.08, 14.42, 'A', 'pizza', 'Praha'},
    {'b', 50.03, 14.49, 50.03, 14.49, 'B', 'pizza', 'Praha'}, {'c', 50.2, 14.6, 50.2, 14.6, 'C', 'pizza', 'Libiš'}}}, function() end)
  assert(food.inTown(city, city.restaurants[1], 50.031, 14.491, 'Chodov') == true, 'Chodov is in Praha')
  assert(food.inTown(city, city.restaurants[1], 50.2, 14.601, 'Libiš') == false, 'Libiš is not')
  assert(food.inTown(city, {town = ''}, 50.2, 14.601, 'Libiš') == nil)
  local north = food.index({cats = {}, tile = 0.05, restaurants = {{'n', 60, 18.0301, 60, 18.0301, 'N', 'pizza', 'Uppsala'}}}, function() end)
  assert(food.inTown(north, north.restaurants[1], 60, 18.0149, 'Luthagen') == true, 'narrow longitude cells far north')
  -- a town of 9 addresses next to the restaurant and a village of 30 further out
  local rows = {}
  for i = 1, 9 do rows[#rows + 1] = {50 + 0.007 + 0.001 * (i % 3), 14 + 0.001 * math.floor(i / 3), 50 + 0.007, 14, 'Town ' .. i, 'Town'} end
  for i = 1, 30 do rows[#rows + 1] = {50 + 0.03 + 0.001 * (i % 6), 14 + 0.001 * math.floor(i / 6), 50.03, 14, 'Village ' .. i, 'Village'} end
  local pack = {cats = {pizza = 'Pizza'}, tile = 0.05, restaurants = {{'r1', 50, 14, 50, 14, 'Pizza', 'pizza', 'Town'}}}
  local idx = food.index(pack, function(row, col) if row == 1000 and col == 280 then return rows end end)
  local seed, town, total = 7, 0, 0
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return seed % n + 1 end
  for _ = 1, 60 do
    local list = food.generate(idx, {count = 1, autoReach = false, nearKm = 3, minKm = 0.5, maxKm = 5}, 50, 14, rnd, 1)
    if list[1] then total = total + 1; if list[1].to.town == 'Town' then town = town + 1 end end
  end
  assert(total > 40 and town / total > 0.6, 'most orders stay in the restaurant\'s town: ' .. town .. '/' .. total)
  -- the road graph says the village is 9 km away by road: never offered; an unknown road falls back to the estimate
  local road = function(_, to) if to[1] > 50.02 then return false end return 0.9 end
  for _ = 1, 20 do
    local list = food.generate(idx, {count = 1, autoReach = false, nearKm = 3, minKm = 0.5, maxKm = 5}, 50, 14, rnd, 1, road)
    assert(not list[1] or (list[1].to.town == 'Town' and list[1].km == 0.9 and list[1].roadKnown), 'paid by the road: ' .. tostring(list[1] and list[1].to.town) .. ' ' .. tostring(list[1] and list[1].km))
  end
end)

test('road distance on the game graph: shortest way, a cap, and nil where the graph has no way', function()
  local roads = require('cargoEarth/roads')
  roads._reset()
  local function n(x, y, links) return {pos = {x = x, y = y, z = 0}, links = links or {}} end
  -- a river between A and B: the only bridge is 2 km upstream
  local graph = {nodes = {A = n(0, 0, {U = {}}), U = n(0, 2000, {V = {}}), V = n(300, 2000, {B = {}}), B = n(300, 0), C = n(5000, 5000)}}
  local km = roads.km(graph, {{'A', 10}}, {{'B', 10}}, 10)
  assert(km and math.abs(km - 4.32) < 0.01, tostring(km))
  assert(roads.km(graph, {{'A', 0}}, {{'B', 0}}, 1) == false, 'longer than the cap')
  assert(roads.km(graph, {{'A', 0}}, {{'C', 0}}, 50) == nil, 'not connected: unknown, not too far')
end)

test('road distance: two points on one edge, and the nearer end of the goal edge', function()
  local roads = require('cargoEarth/roads')
  roads._reset()
  local function n(x, y, links) return {pos = {x = x, y = y, z = 0}, links = links or {}} end
  local graph = {nodes = {P = n(0, 0, {Q = {}}), Q = n(2000, 0)}}
  local km = roads.km(graph, {{'P', 700}, {'Q', 1300}}, {{'P', 1300}, {'Q', 700}}, 5)
  assert(km and math.abs(km - 0.6) < 0.001, 'along the shared edge: ' .. tostring(km))
  -- the goal edge's far end is reached first by the heuristic, but its near end is the shorter way
  roads._reset()
  local g2 = {nodes = {S = n(0, 0, {A = {}, B = {}}), A = n(1000, 0), B = n(0, 1000)}}
  local k2 = roads.km(g2, {{'S', 0}}, {{'A', 900}, {'B', 50}}, 5)
  assert(k2 and math.abs(k2 - 1.05) < 0.001, tostring(k2))
  assert(roads.km(g2, {{'S', 0}}, {{'A', 900}, {'B', 50}}, 1) == false, 'the cap counts the whole way')
end)

local truckIdx = jobs.index({depots = {
  {id = 'yard', n = 'Warehouse', t = 'producer', s = 'M', g = {50, 14}},
  {id = 'shop1', n = 'Shop One', t = 'receiver', s = 'M', g = {50.03, 14}},
  {id = 'shop2', n = 'Shop Two', t = 'receiver', s = 'M', g = {50.045, 14}},
  {id = 'far1', n = 'Far One', t = 'receiver', s = 'M', g = {50.14, 14}},
  {id = 'far2', n = 'Far Two', t = 'receiver', s = 'M', g = {50.2, 14}},
}, cargo = idx.cargo, trailers = {}, types = idx.types})

test('company board: trucks only once unlocked, quoted for the truck, reputation shared per yard', function()
  local vanOnly = employment.board(truckIdx, {lat = 50, lon = 14})
  for _, o in ipairs(vanOnly) do assert(o.tier == 'van', 'no trucks before they unlock') end
  local board = employment.board(truckIdx, {lat = 50, lon = 14}, 'rigid')
  local van, rigid
  for _, o in ipairs(board) do if o.tier == 'van' then van = o elseif o.tier == 'rigid' then rigid = o end end
  assert(van and rigid and not employment.board(truckIdx, {lat = 50, lon = 14}, 'rigid')[3], 'one van and one box truck contract')
  assert(rigid.id ~= van.id and rigid.companyId == van.companyId and van.id == van.companyId)
  assert(rigid.vehicle == haul.loaners.rigid.name)
  for _, j in ipairs(rigid.jobs) do assert(j.haul.tier == 'rigid' and j.km >= 12 and j.km <= 40, tostring(j.km)) end
  assert(rigid.wages > van.wages)
  -- the truck's real boxes hold less than the quote: it loads what fits
  local c = {money = 0}
  assert(employment.begin(c, rigid, {}, {}, 'trucking'))
  assert(c.employment.tier == 'rigid' and c.employment.companyId == van.companyId)
  local rows = {{id = 1, cargoTypes = {'parcel'}, capacity = 96, targetVolume = 0, currentVolume = 0}}
  employment.fit(c.employment, rows)
  assert(c.employment.jobs[1].haul.amount == 96 and haul.plan(rows, c.employment.jobs[1].haul))
end)

test('an unlocked box truck comes with its contract; company vehicles do no other work', function()
  local core, s = fresh()
  s.idx = truckIdx
  s.career.hauls = {van = 5}
  core.setMode('trucking')
  advance(core, 2)
  local list = core.phoneState().trucking.contracts
  local truck
  for _, c in ipairs(list) do if c.vehicle == haul.loaners.rigid.name then truck = c end end
  assert(truck and #list == 2, 'the nearest van and box truck contracts')
  core.phoneAction('contractStart', truck.id)
  advance(core, 2)
  assert(vehicle.model == 'md_series' and s.career.garage.car.company and s.job and s.job.haul.tier == 'rigid')
  -- the company truck cannot take food orders or the player's own freight
  local own = {id = 'own', kind = 'cargo', from = s.job.from, to = s.job.to, km = 1, pay = 100}
  local before = #s.orders
  s.offers = {own}
  core.take(1)
  assert(#s.orders == before, 'own job refused in the company truck')
end)

test('old freight loaners leave My cars and cannot work for the player', function()
  local garage = require('cargoEarth/garage')
  local core, s = fresh()
  s.career.garage.parked = {{model = 'van', key = 'h15_vanster', name = 'H-Series cargo van (loaner)', loaner = true, fleetId = 7},
    {model = 'pigeon', key = 'base', name = 'Old Pigeon', fleetId = 8}}
  s.career.garage.freightLoaners = {van = true}
  garage.retireLoaners(s.career.garage)
  assert(#s.career.garage.parked == 1 and s.career.garage.parked[1].fleetId == 8 and not s.career.garage.freightLoaners)
  s.career.garage.car.loaner = true
  core.phoneAction('online')
  assert(not s.phone.online, 'no going online in a loaner')
  core.setMode('trucking')
  advance(core, 2)
  local t = core.phoneState().trucking
  assert(not t.carrier and t.contracts, 'a loaner is not your own carrier')
end)

test('freight without a van of your own lists company contracts and no loaner; a contract starts from the phone', function()
  local core, s = fresh()
  core.setMode('trucking')
  advance(core, 2)
  local state = core.phoneState()
  assert(state.trucking and state.trucking.carrier == 'Car' and state.trucking.canLoan == nil, 'a car: no loaner offer')
  assert(#state.trucking.contracts == 1 and state.trucking.contracts[1].wages > 0, 'the nearby contract is listed')
  local id = state.trucking.contracts[1].id
  pose.speed = 15
  local moving = core.phoneAction('contractStart', id)
  assert(not s.career.employment and moving.trucking.error == 'Park at the company yard first.', tostring(moving.trucking.error))
  pose.speed = 0
  core.phoneAction('contractStart', id)
  advance(core, 2)
  assert(core.phoneState().trucking == nil or core.phoneState().trucking.error == nil, 'the failure clears')
  assert(s.career.employment and s.job, 'the company van and the first delivery come with the contract')
end)

test('first run asks free play or career; free play keeps nothing when a career starts', function()
  local core, s = fresh()
  local garage = require('cargoEarth/garage')
  s.career.garage = garage.new()
  s.career.money, s.career.delivered, s.career.camerasOff = 777, 5, true
  s.career.home = {g = {50, 14}}
  advance(core, 2)
  local state = core.phoneState()
  assert(state.screen == 'choose' and state.choice.startMoney == garage.START_MONEY, 'the first run asks')
  core.phoneAction('online')
  assert(not s.phone.online, 'no orders before a choice')
  assert(core.firmDo('found', 'Early') and not s.career.firm, 'no firm in free play')
  state = core.phoneAction('freePlay')
  assert(state.screen == 'offline' and state.freePlay and s.career.play == 'free')
  assert(core.phoneAction('careerInfo').screen == 'choose', 'the choice can be seen again')
  core.phoneAction('freePlay')
  core.G.configs = function() return {{model = 'pigeon', key = 'base', value = 900, brand = 'Ibishu', name = 'Pigeon'}} end
  s.starterName = nil
  assert(core.phoneAction('careerInfo').choice.starter == 'Ibishu Pigeon')
  core.phoneAction('startCareer')
  local c = s.career
  assert(c.garage.started and c.garage.car.model == 'pigeon', 'the starter car')
  assert(c.money == garage.START_MONEY and (c.delivered or 0) == 0 and c.home == nil and c.play == nil, 'progress starts again')
  assert(c.camerasOff == true, 'settings stay')
  assert(core.phoneState().screen ~= 'choose')
end)

test('Settings restarts the career only after DELETE and leaves no copy of the old save', function()
  local core, s = fresh()
  s.career.camerasOff, s.career.delivered, s.career.home = true, 9, {g = {50, 14}, capacity = 1}
  core.settingsDo('cameras', false)
  assert(disk['/settings/cargoEarth/career.json'].money == 1000)
  disk['/settings/cargoEarth/career.json.backup1'] = copy(disk['/settings/cargoEarth/career.json'])
  local st = core.settingsState()
  assert(st.canRestart and st.restartWord == 'DELETE')
  -- anything but the word deletes nothing
  for _, word in ipairs({'', 'delete', 'DELETE ', 'yes'}) do
    local out = core.settingsDo('restart', word)
    assert(out.restartError and not out.restarted and s.career.money == 1000 and s.career.garage.started, word)
  end
  s.job = {id = 'j1', kind = 'food', from = {g = {50, 14}}, to = {g = {50.05, 14}}, pay = 100, minutes = 30}
  s.phase, s.orders[1] = 'toDelivery', {job = s.job, phase = 'toDelivery'}
  local out = core.settingsDo('restart', 'DELETE')
  assert(out.restarted and not out.restartError and not out.canRestart)
  assert(not s.job and #s.orders == 0 and not s.career.garage.started and s.career.money == 0)
  assert(s.career.home == nil and (s.career.delivered or 0) == 0 and s.career.camerasOff == true, 'settings stay')
  assert(core.phoneState().screen == 'choose', 'the phone asks Career or Free play again')
  for _, suffix in ipairs({'', '.backup1', '.backup2', '.legacy'}) do
    local c = disk['/settings/cargoEarth/career.json' .. suffix]
    assert(c == nil or (c.money == 0 and not c.garage.started), 'no copy of the old career: ' .. suffix)
  end
end)

test('on the resume screen Restart career drops the saved career instead of loading it', function()
  local core, s = fresh()
  s.pendingCareer = {money = 5000, mode = 'trucking', currency = 'EUR', garage = {started = true, car = {model = 'pigeon'}}}
  assert(core.phoneState().screen == 'resume' and core.settingsState().canRestart)
  core.settingsDo('restart', 'nope')
  assert(s.pendingCareer and s.pendingCareer.money == 5000)
  assert(core.settingsDo('restart', 'DELETE').restarted)
  assert(not s.pendingCareer and s.career.money == 0 and s.career.currency == 'EUR' and s.mode == 'trucking')
  assert(core.phoneState().screen == 'choose')
end)

test('Restart career says so when the old save cannot be replaced', function()
  local core, s = fresh()
  core.settingsDo('cameras', false)
  failPath = '/settings/cargoEarth/career.json.backup1'
  local out = core.settingsDo('restart', 'DELETE')
  failPath = nil
  assert(out.restarted and out.restartWarning and out.restartWarning:find('installer'), 'the player hears the old save stayed')
  assert(not s.career.garage.started)
  core, s = fresh()
  core.settingsDo('cameras', false)
  failPath = '/settings/cargoEarth/career.json'
  out = core.settingsDo('restart', 'DELETE')
  failPath = nil
  assert(out.restarted and out.restartWarning, 'a failed new save is reported too')
end)

test('an old single save becomes Career 1 and more careers get their own names and files', function()
  local core, s = fresh()
  local garage = require('cargoEarth/garage')
  disk['/settings/cargoEarth/career.json'] = {money = 4321, delivered = 7, history = {}, savedAt = 100,
    garage = {started = true, car = {model = 'pigeon', key = 'base', name = 'Old Pigeon'}, inventory = {}, parked = {}}}
  package.loaded['cargoEarth/core'] = nil
  core = require('cargoEarth/core')
  core.G = adapter()
  core.G.configs = function() return {{model = 'pigeon', key = 'base', value = 900, brand = 'Ibishu', name = 'Pigeon'}} end
  core.onExtensionLoaded()
  s = core.state()
  s.idx, s.loadError = idx, nil
  local st = core.phoneState()
  assert(st.screen == 'resume' and st.saveName == 'Career 1', 'the old save is Career 1, waiting to be loaded')
  assert(#st.saves == 1 and st.saves[1].money == 4321 and st.saves[1].car == 'Old Pigeon')
  assert(disk['/settings/cargoEarth/saves.json'].slots[1].path == '/settings/cargoEarth/career.json', 'nothing is copied')
  assert(st.newName == 'Career 2')
  -- a new career with a name, from the resume screen
  st = core.phoneAction('newCareer', '  Prague   courier ')
  assert(s.career.garage.started and s.career.money == garage.START_MONEY and not s.pendingCareer)
  assert(st.screen ~= 'resume' and st.screen ~= 'choose')
  local list = disk['/settings/cargoEarth/saves.json']
  assert(#list.slots == 2 and list.slots[2].name == 'Prague courier' and list.last == 2)
  assert(disk[list.slots[2].path].money == garage.START_MONEY, 'the new career has its own file')
  assert(disk['/settings/cargoEarth/career.json'].money == 4321, 'Career 1 is untouched')
  -- pause, pick Career 1, it loads
  core.settingsDo('pause')
  st = core.phoneState()
  assert(st.screen == 'resume' and #st.saves == 2 and st.saves[1].name == 'Prague courier', 'last played first')
  core.phoneAction('loadSave', 1)
  assert(not s.pendingCareer and s.career.money == 4321 and s.career.delivered == 7, 'Career 1 is back')
  s.career.money = 5000
  core.settingsDo('cameras', false)
  assert(disk['/settings/cargoEarth/career.json'].money == 5000 and disk[list.slots[2].path].money == garage.START_MONEY)
  -- the running career cannot be deleted from the list; another can, from the start screen
  core.settingsDo('pause')
  core.phoneAction('deleteSave', 2)
  st = core.phoneState()
  assert(#st.saves == 1 and st.saves[1].name == 'Career 1' and st.saveMsg == 'Prague courier deleted.')
  -- free play from the start screen keeps the career on disk
  st = core.phoneAction('freePlay')
  assert(not s.pendingCareer and s.career.play == 'free' and not s.career.garage.started and st.freePlay)
  assert(disk['/settings/cargoEarth/career.json'].money == 5000, 'free play does not write over a career')
  assert(disk['/settings/cargoEarth/freeplay.json'].play == 'free')
  st = core.phoneAction('careerInfo')
  assert(st.screen == 'choose' and #st.saves == 1)
  core.phoneAction('loadSave', 1)
  assert(s.career.money == 5000 and s.career.garage.started)
end)

test('a free-play save from before the slots gives only its settings; the first career is Career 1', function()
  local core, s = fresh()
  disk['/settings/cargoEarth/career.json'] = {money = 80, play = 'free', currency = 'EUR', history = {}, garage = {inventory = {}, parked = {}}}
  package.loaded['cargoEarth/core'] = nil
  core = require('cargoEarth/core')
  core.G = adapter()
  core.G.configs = function() return {{model = 'pigeon', key = 'base', value = 900, brand = 'Ibishu', name = 'Pigeon'}} end
  core.onExtensionLoaded()
  s = core.state()
  s.idx, s.loadError = idx, nil
  advance(core, 2)
  local st = core.phoneState()
  assert(st.screen == 'choose' and #st.saves == 0 and st.newName == 'Career 1' and s.career.currency == 'EUR')
  core.phoneAction('startCareer', '')
  local list = disk['/settings/cargoEarth/saves.json']
  assert(#list.slots == 1 and list.slots[1].name == 'Career 1' and s.career.garage.started)
end)

test('a career list that could not be written is written again before the save counts', function()
  local core, s = fresh()
  failPath = '/settings/cargoEarth/saves.json'
  core.settingsDo('cameras', false)
  assert(s.slot == 1 and s.saveError, 'the career is not called saved while the list is missing')
  failPath = nil
  advance(core, 20)
  assert(not s.saveError and disk['/settings/cargoEarth/saves.json'].slots[1].id == 1, 'the list is written on the retry')
  -- a resume that failed for a while can be tried again; an unreadable save cannot
  core.settingsDo('pause')
  s.resumeError = 'The saved location did not load. Try again when the world is ready.'
  local st = core.phoneState()
  assert(st.screen == 'resume' and not st.resumeBlocked)
end)

test('a career saved without a name gets a slot; a missing save is said, not loaded', function()
  local saves = require('cargoEarth/saves')
  assert(saves.cleanName(string.rep('ř', 20)) == string.rep('ř', 16), 'names are cut between letters')
  assert(saves.cleanName(' \t ') == nil)
  local core, s = fresh()
  core.settingsDo('cameras', false)
  assert(s.slot == 1 and disk['/settings/cargoEarth/saves.json'].slots[1].name == 'Career 1')
  core.settingsDo('pause')
  for _, suffix in ipairs({'', '.backup1', '.backup2', '.legacy'}) do disk['/settings/cargoEarth/career.json' .. suffix] = nil end
  core.phoneAction('loadSave', 1)
  assert(s.loadBlocked and core.phoneState().resumeError:find('not found'))
end)

test('cancelling a picked-up meal takes its weight out of the car', function()
  local marker = package.loaded['cargoEarth/marker']
  marker.PICKUP_RADIUS, marker.PICKUP_RANGE, marker.pickupDistance = 5, 250, function() return nil end
  local core, s = fresh()
  s.career.garage.debt = 0
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function() return {{50.02, 14, 50.02, 14, 'Street 5', 'Town'}} end)
  advance(core, 2)
  core.phoneAction('online')
  for _ = 1, 40 do
    advance(core, 2)
    if core.phoneState().screen == 'incoming' then break end
  end
  core.phoneAction('accept')
  local job = s.job
  assert(job and job.kind == 'food')
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and boxes[1].currentVolume > 0, 'the meal is in the box')
  core.cancel()
  assert(not s.job and boxes[1].currentVolume == 0, 'cancelled: the box is empty again')
end)

test('cancelling a loaded parcel route empties the van', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  core.G.spawn('van')
  c.garage.car.model = 'van'
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  core.setMode('trucking')
  advance(core, 2)
  core.generate()
  local i, job
  for k, offer in ipairs(s.offers) do if offer.route then i, job = k, offer break end end
  core.take(i)
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and boxes[1].currentVolume > 0, 'loaded')
  pose.lat, pose.lon = job.to.g[1], job.to.g[2]
  advance(core)
  assert(job.route.at == 2 and boxes[1].currentVolume > 0, 'one stop done, parcels left')
  core.cancel()
  assert(not s.job and boxes[1].currentVolume == 0, 'cancelled: the van is empty again')
end)

local function mealOnBoard()
  local marker = package.loaded['cargoEarth/marker']
  marker.PICKUP_RADIUS, marker.PICKUP_RANGE, marker.pickupDistance = 5, 250, function() return nil end
  local core, s = fresh()
  s.career.garage.debt = 0
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function() return {{50.02, 14, 50.02, 14, 'Street 5', 'Town'}} end)
  advance(core, 2)
  core.phoneAction('online')
  for _ = 1, 40 do
    advance(core, 2)
    if core.phoneState().screen == 'incoming' then break end
  end
  core.phoneAction('accept')
  pose.lat, pose.lon = s.job.from.g[1], s.job.from.g[2]
  advance(core)
  assert(s.phase == 'toDelivery' and boxes[1].currentVolume > 0, 'the meal is in the box')
  return core, s
end

test('a reset forgets the load in the car: the meal\'s weight goes back in', function()
  local core, s = mealOnBoard()
  local kg = boxes[1].currentVolume
  boxes[1].currentVolume, boxes[1].targetVolume = 0, 0   -- the game rebuilt its containers empty
  core.onVehicleResetted(1)
  advance(core, 4)
  assert(math.abs(boxes[1].currentVolume - kg) < 1e-9, 'put back after the reset')
  core.cancel()
  assert(boxes[1].currentVolume == 0, 'and taken out on cancel')
end)

test('a load the mod lost track of is emptied once nothing is on board', function()
  local core, s = mealOnBoard()
  s.storage = nil   -- the bookkeeping is lost (a Lua reload): the box still holds the meal
  advance(core, 4)
  assert(boxes[1].currentVolume > 0)
  core.cancel()
  advance(core, 6)
  assert(not s.job and boxes[1].currentVolume == 0, 'the left-over weight is gone')
  -- an idle car that comes back with something in its boxes is emptied too
  boxes[1].currentVolume, boxes[1].targetVolume = 12, 12
  s.sweepWanted, s.sweepAt = true, 0
  advance(core, 2)
  assert(boxes[1].currentVolume == 0, 'emptied while idle')
  boxes[1].cargoTypes = {'passenger'}
  boxes[1].currentVolume, boxes[1].targetVolume = 3, 3
  s.sweepWanted, s.sweepAt = true, 0
  advance(core, 2)
  assert(boxes[1].currentVolume == 3, 'passenger seats are left alone')
end)

test('seat occupants: bus seats, a fixed scattered order, and seating the player', function()
  local occ = require('cargoEarth/occupants')
  local cfg = occ.fillBusSeats({ parts = { citybus_seats = 'citybus_seats', seat_occupant_1RA = 'occupant_generic' } })
  local n = 0
  for k, v in pairs(cfg.parts) do if k:find('^seat_occupant_') then n = n + 1 assert(v == 'occupant_generic') end end
  assert(n == 34, 'every passenger seat of the city bus: ' .. n)
  local seats = { { seatId = 'FL', isDriver = true, occupantType = 'player' } }
  for _, id in ipairs(occ.BUS_SEATS) do seats[#seats + 1] = { seatId = id } end
  assert(occ.freeSeats(seats) == 34 and occ.freeSeats(nil) == nil, 'free seats: all but the driver')
  assert(occ.freeSeats({ { seatId = 'FL', isDriver = true } }) == 0, 'a one-seater has none')
  local p = occ.plan(seats, 5, '136')
  assert(#p.add == 5 and #p.remove == 0 and p.shown == 5)
  for _, id in ipairs(p.add) do assert(id ~= 'FL', 'never the driver seat') end
  -- the same five stay seated when two more get on
  local set = {}
  for _, id in ipairs(p.add) do set[id] = true end
  for _, s in ipairs(seats) do if set[s.seatId] then s.occupantType = 'dummy' end end
  local p2 = occ.plan(seats, 7, '136')
  assert(#p2.add == 2 and #p2.remove == 0)
  local p3 = occ.plan(seats, 2, '136')
  assert(#p3.add == 0 and #p3.remove == 3)
  assert(occ.plan(seats, 100, '136').shown == 34, 'standing people are not shown')
  local other = occ.plan(seats, 5, '9')
  local same = 0
  for _, id in ipairs(other.add) do if set[id] then same = same + 1 end end
  assert(same < 5 or #other.add < 5, 'another line seats people elsewhere')
  assert(occ.needsSeat(true, nil, 5) and occ.needsSeat(true, { vehicleId = 5 }, 5))
  assert(not occ.needsSeat(true, { vehicleId = 5, seatId = 'FL' }, 5) and not occ.needsSeat(false, nil, 5))
end)

test('a tow job without your own trailer: borrow it at the workshop, hitch it, fetch the car, bring both back', function()
  local core, s = fresh()
  local c = s.career
  c.garage.debt = 0
  vehicle.slotPartMap = { body = 'pigeon', hitch = 'pigeon_tow_hitch' }
  s.fidx = food.index({restaurants = {{'r1', 50, 14, 50, 14, 'Test Pizza', 'pizza', 'Town'}}, cats = {'pizza'}, tile = 0.05},
    function(row, col) if row == 1000 and col == 280 then return streets(50, 14) end end)
  withStation(s, 50.1, 14)
  local saved = {}
  for _, k in ipairs({ 'existing', 'towModel', 'withPlayer', 'towedDistances', 'towedDamage', 'towedCount', 'remove', 'id',
    'spawnRoadside', 'towedNear', 'loadTowed', 'towedAlive', 'removeTow', 'ownTowTrailer', 'adopt', 'spawnBorrowed',
    'hitch', 'coupled' }) do
    saved[k] = trailers[k]
  end
  local trailerOut, hitched, coupled, roadside = false, 0, false, 0
  local distances = {}
  trailers.existing = function() return { 'midsize' } end   -- a big car: the 22 ft car trailer
  trailers.towModel = function() return 'tiltdeck' end
  trailers.ownTowTrailer = function() return nil end
  trailers.adopt = function() return false end
  trailers.spawnBorrowed = function(kind) trailerOut = kind == 'cartrailer' return trailerOut end
  trailers.hitch = function() if not trailerOut then return false end hitched = hitched + 1 return true end
  trailers.coupled = function() return coupled end
  trailers.id = function() return trailerOut and 7 or nil end
  local nearTrailer = true
  trailers.withPlayer = function() return trailerOut and nearTrailer end
  trailers.towedDistances = function() return distances end
  trailers.towedDamage = function() return 0 end
  trailers.towedCount = function() return #distances end
  trailers.towedAlive = function() return #distances end
  trailers.remove = function() trailerOut, distances = false, {} end
  trailers.removeTow = function() trailerOut, distances = false, {} end
  trailers.spawnRoadside = function(_, cars) roadside = roadside + 1 distances = { 20 } return #cars == 1 end
  trailers.towedNear = function() return true end
  trailers.loadTowed = function() distances = { 1 } return true end
  local ok, err = pcall(function()
    core.setMode('trucking')
    advance(core, 2)
    core.generate()
    local i, job
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    assert(job and job.tow.borrow and job.tow.stage == 'shop', 'no trailer of your own: it is borrowed')
    local direct = tow.pay('light', job.km)
    assert(job.pay > direct and job.borrowKm > job.km, 'the empty-trailer legs are paid')
    core.take(i)
    assert(s.job == job)
    -- the GPS and the phone go to the workshop first
    local a = core.phoneState().active
    assert(a.here and a.here.name == job.to.n and a.here.label == 'Get the trailer here')
    pose.lat, pose.lon = job.from.g[1], job.from.g[2]
    advance(core, 30)
    assert(roadside == 0 and job.tow.stage == 'shop', 'the car is not there before the trailer')
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core)
    assert(trailerOut and job.tow.stage == 'hitch' and core.phoneState().active.towHitch, 'the trailer stands behind you')
    assert(core.towWaiting() and core.stopInfo() == nil, 'no countdown while it waits for Hitch')
    advance(core, 30)
    assert(job.tow.stage == 'hitch' and s.phase == 'toPickup', 'nothing happens until Hitch')
    pose.speed = 10
    core.phoneAction('towHitch')
    assert(job.tow.stage == 'hitch' and hitched == 0, 'not while moving')
    pose.speed = 0
    nearTrailer = false
    core.phoneAction('towHitch')
    assert(job.tow.stage == 'hitch' and hitched == 0, 'not from far away (it would pull the trailer across the map)')
    nearTrailer = true
    core.phoneAction('towHitch')
    assert(hitched == 1 and job.tow.stage == 'hitch', 'hitched again, but not done before the game reports it coupled')
    coupled = true
    advance(core, 2)
    assert(job.tow.stage == nil and s.phase == 'toPickup', 'coupled: on to the car')
    coupled = false
    assert(core.phoneState().active.here == nil, 'now the broken-down car')
    pose.lat, pose.lon = job.from.g[1], job.from.g[2]
    advance(core)
    assert(roadside == 1 and job.tow.waiting)
    core.phoneAction('towLoad')
    assert(s.phase == 'toDelivery')
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core, 30)
    assert(not s.job and c.history[1].kind == 'tow' and not trailerOut, 'delivered at the same workshop, trailer left there')
    -- coupling it with the game's own coupling counts too; a save in the middle puts it back at the workshop step
    s.offers = {}
    pose.lat, pose.lon = 50, 14
    core.generate()
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    core.take(i)
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core)
    assert(job.tow.stage == 'hitch')
    coupled = true
    advance(core, 2)
    assert(job.tow.stage == nil and hitched == 1, 'coupled by hand')
    core.cancel(true)
    assert(not s.job and not trailerOut, 'cancel takes the borrowed trailer away')
    -- offered with your own trailer coupled, uncoupled before taking it: borrowed, with the extra legs paid and timed
    s.offers = {}
    pose.lat, pose.lon = 50, 14
    trailers.ownTowTrailer = function() return 9, 'tiltdeck' end
    core.generate()
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    assert(not job.tow.borrow)
    local pay, minutes = job.pay, job.minutes
    core.take(i)
    assert(job.tow.stage == 'shop' and job.pay > pay and job.minutes > minutes and job.borrowKm, 'the detour is paid')
  end)
  for k, f in pairs(saved) do trailers[k] = f end
  assert(ok, err)
end)

test('your own coupled car trailer is used and never deleted', function()
  local trailers = require('cargoEarth/trailers')
  local deleted = 0
  local objs = { [9] = { getJBeamFilename = function() return 'tiltdeck' end, delete = function() deleted = deleted + 1 end,
    getID = function() return 9 end } }
  local oldScene, oldPlayer, oldCv = scenetree, getPlayerVehicle, core_vehicles
  scenetree = { findObjectById = function(id) return objs[id] end }
  getPlayerVehicle = function() return { getID = function() return 1 end } end
  core_vehicles = { vehsCouplings = { [1] = { [9] = true } }, getModel = function(m) return { model = m } end }
  local ok, err = pcall(function()
    assert(trailers.ownTowTrailer('cartrailer') == 9)
    assert(trailers.ownTowTrailer('flatbed') == nil, 'a tilt deck is not a flatbed')
    assert(trailers.ownTowTrailer('smalltrailer') == nil, 'nor the small car trailer')
    -- the large box utility trailer counts as the small car trailer only (the game has the tilt deck for the big one)
    objs[9].getJBeamFilename = function() return 'boxutility_large' end
    assert(trailers.ownTowTrailer('smalltrailer') == 9 and trailers.ownTowTrailer('cartrailer') == nil)
    objs[9].getJBeamFilename = function() return 'tiltdeck' end
    assert(trailers.adopt('cartrailer') and trailers.id() == 9 and trailers.adopted())
    trailers.removeTow()
    trailers.remove()
    assert(deleted == 0 and trailers.id() == nil, 'your own trailer stays in the world')
  end)
  scenetree, getPlayerVehicle, core_vehicles = oldScene, oldPlayer, oldCv
  assert(ok, err)
end)

test('a car goes on the deck by the middle of its body, not its ref node', function()
  local V = {}
  V.__index = V
  local oldVec = rawget(_G, 'vec3')
  vec3 = function(x, y, z)
    if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
    return setmetatable({ x = x, y = y, z = z }, V)
  end
  function V:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
  function V:normalized() local l = math.sqrt(self:dot(self)) return vec3(self.x / l, self.y / l, self.z / l) end
  -- a car facing +y whose ref node sits 1 m behind its middle and 0.3 m to the left of it; a broken-off part lies
  -- further away in another cluster
  local nodes = { { -0.9, -1.0 }, { 0.3, -1.0 }, { -0.9, 3.0 }, { 0.3, 3.0 }, { 5, 9 } }
  local o = {
    getDirectionVector = function() return vec3(0, 1, 0) end,
    getNodeClusters = function() return { 1, 1, 1, 1, 2 } end,
    getRefNodeId = function() return 0 end,
    getNodeCount = function() return #nodes end,
    getNodePosition = function(_, i) return vec3(nodes[i + 1][1], nodes[i + 1][2], 0) end,
  }
  local f, r = trailers.bodyOffset(o)
  -- right of a car facing +y is +x here (the trailer side's own convention): middle at x = -0.3, y = 1.0
  assert(math.abs(f - 1.0) < 1e-9 and math.abs(r + 0.3) < 1e-9, 'body middle from the ref node: ' .. f .. ' ' .. r)
  -- a game without these calls: no shift
  local f0, r0 = trailers.bodyOffset({})
  vec3 = oldVec
  assert(f0 == 0 and r0 == 0)
end)

test('used-car market: every vehicle kind has eight listings at cheap, middle and dear prices', function()
  local garage, haul = require('cargoEarth/garage'), require('cargoEarth/haul')
  assert(haul.configClass('van', 'Van', 'H-Series Vanster') == 'van')
  assert(haul.configClass('us_semi', nil, 'T-Series T75 Box Truck') == 'rigid')
  assert(haul.configClass('us_semi', nil, 'T-Series TC82 Sleeper') == 'semi')
  assert(haul.configClass('md_series', nil, 'MD-Series Flatbed') == 'rigid')
  assert(haul.configClass('pickup', 'Pickup', 'D15') == 'suv')
  assert(haul.configClass('covet', 'Hatchback', 'Covet') == 'car')
  assert(haul.configClass('citybus', 'Bus', 'City bus') == nil)
  -- a spawned vehicle gets the same kind as its listing (a modded van or box truck too)
  assert(haul.carrier({ model = 'modvan', bodyStyle = 'Van' }) == 'van')
  assert(haul.carrier({ model = 'modtruck', bodyStyle = 'Box Truck' }) == 'rigid')
  assert(haul.carrier({ model = 'covet', bodyStyle = 'Minivan' }) == 'car')
  local configs = {}
  local function add(model, style, n, typ)
    for i = 1, n do
      configs[#configs + 1] = { model = model, key = model .. i, name = model .. ' ' .. i, value = 1000 * i,
        type = typ or 'Car', bodyStyle = style }
    end
  end
  add('covet', 'Hatchback', 20) add('pickup', 'Pickup', 9, 'Truck') add('van', 'Van', 4, 'Truck')
  add('md_series', 'Box Truck', 2, 'Truck') add('us_semi', 'Semi Truck', 7, 'Truck') add('citybus', 'Bus', 3, 'Truck')
  local G = { configs = function() return configs end, spawn = function() end }
  local seed = 7
  local rnd = function() seed = (seed * 16807) % 2147483647 return seed / 2147483647 end
  local g = {}
  garage.marketTick(G, g, 0, rnd)
  local function counts()
    local n, bands = {}, {}
    for _, l in ipairs(g.market.list) do
      assert(l.kind, 'every listing has its kind')
      assert(l.model ~= 'citybus', 'no buses for sale')
      n[l.kind] = (n[l.kind] or 0) + 1
      bands[l.kind] = bands[l.kind] or {}
      bands[l.kind][l.band] = true
    end
    return n, bands
  end
  local n, bands = counts()
  for _, kind in ipairs(haul.KIND_ORDER) do
    assert((n[kind] or 0) == 8, kind .. ' has ' .. tostring(n[kind]))
  end
  assert(bands.car[1] and bands.car[2] and bands.car[3], 'cars at varied prices')
  assert(bands.semi[1] and bands.semi[3], 'tractors at varied prices')
  -- a sold listing is replaced by one of its kind; the list says each listing's kind
  local vanId
  for _, l in ipairs(g.market.list) do if l.kind == 'van' then vanId = l.id break end end
  for i, l in ipairs(g.market.list) do if l.id == vanId then table.remove(g.market.list, i) break end end
  garage.marketTick(G, g, 0, rnd)
  n = counts()
  assert(n.van >= garage.MIN_PER_KIND)
  for _, c in ipairs(garage.market(g)) do assert(c.kind and c.hours == nil) end
  assert(#g.market.list == 40, 'eight slots for each of five categories')
  local held = g.market.list[1]
  held.gone = g.market.t
  g.preview = {id = held.id}
  garage.marketTick(G, g, 31, rnd)
  assert(#g.market.list == 40 and garage.findListing(g, held.id) == held, 'test-drive selection stays reserved')
  for _, l in ipairs(g.market.list) do
    assert(l == held or l.gone - l.listedAt <= garage.MARKET_LIFE_MIN[2])
  end
  g.preview = nil
  garage.marketTick(G, g, 0, rnd)
  assert(not garage.findListing(g, held.id) and #g.market.list == 40)
  -- A legacy oversized category shrinks while the preview survives.
  for _ = 1, 20 do
    g.market.seq = g.market.seq + 1
    table.insert(g.market.list, {id = g.market.seq, model = 'covet', key = 'covet1', kind = 'car', band = 1,
      name = 'Legacy', km = 0, condition = 1, price = 100, listedAt = g.market.t, gone = g.market.t + 150})
  end
  held = g.market.list[#g.market.list]
  g.preview = {id = held.id}
  garage.marketTick(G, g, 0, rnd)
  assert(#g.market.list == 40 and garage.findListing(g, held.id))
  assert(held.gone - held.listedAt == garage.MARKET_LIFE_MIN[2], 'legacy expiry shortened to the new maximum')
  g.preview = nil
  local listing = g.market.list[1]
  assert(garage.buyListing(G, g, {money = 1000000}, listing.id))
  assert(#g.market.list == 40 and not garage.findListing(g, listing.id), 'buying refills the freed slot immediately')
  -- an older save's market keeps its listings and learns their kinds
  local old = { market = { v = 3, t = 5, seq = 1, nextAt = 100,
    list = { { id = 1, model = 'van', key = 'van2', name = 'van 2', km = 0, condition = 1, price = 10, listedAt = 0, gone = 90 } } } }
  garage.marketTick(G, old, 0, rnd)
  assert(old.market.v == garage.MARKET_V and old.market.list[1].id == 1 and old.market.list[1].kind == 'van')
  assert(old.market.list[1].price == 5, 'an older listing of a work vehicle is repriced once')
  garage.marketTick(G, old, 0, rnd)
  assert(old.market.list[1].price == 5, 'and only once')
  -- work vehicles cost a share of their value-based price; a new tractor for the firm too
  assert(garage.kindFactor('car') == 1 and garage.kindFactor('suv') == 1 and garage.kindFactor('van') == 0.5)
  assert(garage.kindFactor('rigid') == 0.35 and garage.kindFactor('semi') == 0.35)
  assert(garage.newPrice(G, 'us_semi', 'us_semi7') == math.floor(7000 * garage.PRICE_PER_VALUE * 0.35 / 5 + 0.5) * 5)
  assert(garage.newPrice(G, 'covet', 'covet7') == math.floor(7000 * garage.PRICE_PER_VALUE / 5 + 0.5) * 5)
  -- parts stripped off a discounted truck sell at the truck's discount, so buy-and-strip can't beat the price
  local PG = { part = function(_, name) return { information = { name = name, value = 1000 } } end }
  local truck = { model = 'us_semi', slotPartMap = { a = 'fifthwheel_top', b = 'engine' }, ioCtx = {} }
  local stripped = { model = 'us_semi', slotPartMap = { a = 'fifthwheel_top', b = '' }, ioCtx = {} }
  local q = garage.partsQuote(PG, {}, truck.slotPartMap, stripped)
  assert(q.inventory.engine == 1 and q.salvage.engine.n == 1 and q.salvage.engine.f == 0.35)
  PG.vehicle = function() return stripped end
  local sg = { inventory = { engine = 2 }, salvage = q.salvage }
  local full = math.floor(1000 * garage.PRICE_PER_VALUE * garage.SELL_PART / 5 + 0.5) * 5
  local cheap = math.floor(1000 * garage.PRICE_PER_VALUE * garage.SELL_PART * 0.35 / 5 + 0.5) * 5
  assert(garage.spares(PG, sg)[1].price == cheap)
  local _, _, got = garage.sell(PG, sg, { money = 0 }, 'engine')
  assert(got == cheap and sg.salvage == nil)
  _, _, got = garage.sell(PG, sg, { money = 0 }, 'engine')
  assert(got == full, 'a spare bought at full price still sells at the full share')
  -- fitting a spare again uses the full-price ones first; the salvage count never exceeds the spares
  q = garage.partsQuote(PG, { engine = 2 }, stripped.slotPartMap, truck, { engine = { n = 1, f = 0.35 } })
  assert(q.inventory.engine == 1 and q.salvage.engine.n == 1)
  q = garage.partsQuote(PG, { engine = 1 }, stripped.slotPartMap, truck, { engine = { n = 1, f = 0.35 } })
  assert(q.inventory.engine == nil and q.salvage == nil)
  -- a part bought at full price for the truck comes off as a full-price spare, not salvage
  q = garage.partsQuote(PG, {}, stripped.slotPartMap, truck)
  assert(q.cost > 0 and q.paid.engine == 1)
  local back = garage.partsQuote(PG, q.inventory, truck.slotPartMap, stripped, q.salvage, q.paid)
  assert(back.inventory.engine == 1 and back.salvage == nil and back.paid == nil)
  -- a full-price spare fitted to the truck stays full price when it comes off again
  local fit = garage.partsQuote(PG, back.inventory, stripped.slotPartMap, truck, back.salvage, back.paid)
  assert(fit.cost == 0 and fit.paid.engine == 1)
  back = garage.partsQuote(PG, fit.inventory, truck.slotPartMap, stripped, fit.salvage, fit.paid)
  assert(back.inventory.engine == 1 and back.salvage == nil)
  -- a salvage spare fitted back stays salvage
  fit = garage.partsQuote(PG, { engine = 1 }, stripped.slotPartMap, truck, { engine = { n = 1, f = 0.35 } })
  assert(fit.paid == nil and fit.salvage == nil)
  back = garage.partsQuote(PG, fit.inventory, truck.slotPartMap, stripped, fit.salvage, fit.paid, fit.fittedSalvage)
  assert(back.salvage.engine.n == 1)
  -- a salvage spare moved onto an ordinary car keeps its discount when it comes off there
  local car = { model = 'covet', slotPartMap = { b = 'engine' }, ioCtx = {} }
  local bare = { model = 'covet', slotPartMap = { b = '' }, ioCtx = {} }
  fit = garage.partsQuote(PG, { engine = 1 }, bare.slotPartMap, car, { engine = { n = 1, f = 0.35 } })
  assert(fit.cost == 0 and fit.salvage == nil and fit.fittedSalvage.engine.n == 1 and fit.fittedSalvage.engine.f == 0.35)
  back = garage.partsQuote(PG, fit.inventory, car.slotPartMap, bare, fit.salvage, fit.paid, fit.fittedSalvage)
  assert(back.salvage.engine.n == 1 and back.salvage.engine.f == 0.35 and back.fittedSalvage == nil)
  -- the car's own part comes off at full price
  back = garage.partsQuote(PG, {}, car.slotPartMap, bare)
  assert(back.inventory.engine == 1 and back.salvage == nil)
end)

test('a save whose car mod is gone: another owned car, else a base Pigeon; the missing car is kept', function()
  local garage = require('cargoEarth/garage')
  local installed = { pigeon = true, van = true }
  local G = {
    modelExists = function(m) return installed[m] == true end,
    configs = function()
      return { { model = 'pigeon', key = 'cheap', name = 'Cheap', brand = 'Ibishu', value = 900, type = 'Car' },
        { model = 'pigeon', key = 'base', name = 'Base', brand = 'Ibishu', value = 1000, type = 'Car' } }
    end,
  }
  -- the car is there: nothing changes
  local g = { started = true, car = { model = 'van', name = 'Van' }, parked = {} }
  assert(garage.fallbackCar(G, g) == nil and g.car.model == 'van')
  -- unknown answer from the game: nothing changes either
  assert(garage.fallbackCar({ modelExists = function() return nil end }, { car = { model = 'x' } }) == nil)
  -- another owned car (a driver's car and a missing one are skipped)
  g = { started = true, repair = 120, pendingUsed = { starter = true },
    car = { model = 'modcar', name = 'Mod car', fleetId = 1 },
    parked = { { model = 'van', name = 'Busy van', driver = { name = 'D' }, fleetId = 2 },
      { model = 'othermod', name = 'Other mod', fleetId = 3 },
      { model = 'van', name = 'Van', fleetId = 4, parkedRepair = 30 } } }
  local note = garage.fallbackCar(G, g)
  assert(note and note:find('Mod car') and note:find('Now driving Van'), note)
  assert(g.car.fleetId == 4 and g.repair == 30 and g.pendingUsed == nil)
  local kept
  for _, c in ipairs(g.parked) do if c.fleetId == 1 then kept = c end end
  assert(kept and kept.parkedRepair == 120 and #g.parked == 3, 'the missing car stays in My cars with its repairs')
  -- switching back while its mod is still gone says why
  local ok, why = garage.switchCar(G, g, 1)
  assert(not ok and why:find('not installed'), why)
  -- no installed car at all: a base Pigeon stands in, worth nothing when sold
  g = { started = true, car = { model = 'modcar', name = 'Mod car' }, parked = { { model = 'othermod', name = 'Other' } } }
  note = garage.fallbackCar(G, g)
  assert(note and note:find('stands in'), note)
  assert(g.car.model == 'pigeon' and g.car.key == 'base' and g.car.standIn and #g.parked == 2)
  assert(garage.carWorth(G, g) == 0)
  garage.updateStarter(g)
  assert(g.pendingUsed == nil, 'the stand-in is not stripped like a new starter')
  -- a later load with the mod still gone keeps the same stand-in (no second Pigeon)
  local standIn = g.car
  g.car = g.parked[1]
  table.remove(g.parked, 1)
  g.parked[#g.parked + 1] = standIn
  standIn.driver = { name = 'D' }
  local busy = g.car
  garage.fallbackCar(G, g)
  assert(g.car ~= standIn and g.car.standIn and standIn.driver, 'a stand-in with a driver keeps working')
  g.car, standIn.driver = busy, nil
  for i, c in ipairs(g.parked) do if c.standIn and c ~= standIn then table.remove(g.parked, i) break end end
  for i, c in ipairs(g.parked) do if c == busy then table.remove(g.parked, i) break end end
  garage.fallbackCar(G, g)
  assert(g.car == standIn and #g.parked == 2)
  -- a company loaner is left alone
  g = { car = { model = 'modcar', loaner = true }, parked = {} }
  assert(garage.fallbackCar(G, g) == nil)
  -- no Pigeon in this game either: nothing to fall back to
  installed.pigeon = false
  g = { car = { model = 'modcar', name = 'Mod car' }, parked = {} }
  assert(garage.fallbackCar(G, g) == nil and g.car.model == 'modcar')
end)


test('used-car list: picture and numbers come from the game list without a spawn, mod cars fall back', function()
  local gamecar = require('cargoEarth/gamecar')
  local oldCv = core_vehicles
  local asked = 0
  core_vehicles = { getModel = function(m)
    asked = asked + 1
    if m == 'pigeon' then
      return { model = { Brand = 'Ibishu', Country = 'Japan', preview = '/vehicles/pigeon/default.jpg' }, configs = {
        base = { key = 'base', preview = '/vehicles/pigeon/base.jpg', Power = 40, Torque = 80, Weight = 610,
          ['Top Speed'] = 25, ['0-100 km/h'] = 21.34, Drivetrain = 'RWD', Transmission = 'Manual', ['Fuel Type'] = 'Gasoline',
          aggregates = { ['Body Style'] = { Pickup = true }, Years = { min = 1990, max = 2004 } } } } }
    elseif m == 'modcar' then
      return { model = { preview = '/ui/images/appDefault.png' }, configs = { a = { key = 'a', preview = '/ui/images/appDefault.png' } } }
    end
    return {}
  end }
  local ok, err = pcall(function()
    gamecar._reset()
    local i = gamecar.carInfo('pigeon', 'base')
    assert(i.preview == '/vehicles/pigeon/base.jpg' and i.power == 40 and i.weight == 610 and i.topSpeed == 90)
    assert(i.sprint == 21.3 and i.drivetrain == 'RWD' and i.body == 'Pickup' and i.brand == 'Ibishu' and i.years.min == 1990)
    gamecar.carInfo('pigeon', 'base')
    assert(asked == 1, 'cached per config')
    local m = gamecar.carInfo('modcar', 'a')
    assert(m and m.preview == nil and m.power == nil, 'the game\'s default picture means no picture')
    assert(gamecar.carInfo('gone', 'x') == nil and gamecar.carInfo(nil, 'x') == nil)
  end)
  core_vehicles = oldCv
  gamecar._reset()
  assert(ok, err)
end)

test('experience pay grows with each job of a kind, higher for later-unlocked work', function()
  local experience = require('cargoEarth/experience')
  local employment = require('cargoEarth/employment')
  local c = {}
  assert(experience.rate(c, 'semi') == 0 and experience.kind({ kind = 'food' }) == 'food')
  assert(experience.kind({ taxi = {} }) == 'taxi' and experience.kind({ route = {} }) == 'parcel')
  assert(experience.kind({ partsRun = true }) == 'parts' and experience.kind({ haul = { tier = 'rigid' } }) == 'rigid')
  assert(experience.kind({ haul = { tier = 'car' } }) == nil)
  experience.add(c, 'food', 50)
  assert(experience.rate(c, 'food') == 0.05)
  experience.add(c, 'food', 500)
  assert(experience.rate(c, 'food') == 0.10, 'capped')
  experience.add(c, 'semi', 40)
  assert(experience.rate(c, 'semi') == 0.25 and experience.KINDS.semi.max > experience.KINDS.van.max)
  local job = experience.apply(c, { kind = 'food', pay = 200 })
  assert(job.pay == 220 and job.expBonus == 20 and job.expRate == 0.10)
  experience.apply(c, job)
  assert(job.pay == 220, 'only once')
  assert(experience.apply(c, { kind = 'food', pay = 200, companyShift = 's1' }).pay == 200, 'company jobs are paid by share')
  -- company work: the driver's share grows, never past the whole contract
  assert(employment.shareFor('semi', c) == 0.65 * 1.25 and employment.shareFor('semi') == 0.65)
  assert(employment.shareFor('bus', c) == employment.SHARE)
  c.experience.van = 1000
  assert(employment.shareFor('van', c) == math.min(1, employment.SHARE * 1.15))
  -- the Progress page shows it per work type; company van contracts share the van's experience
  local progress = require('cargoEarth/progress')
  local rows = {}
  for _, w in ipairs(progress.workTypes(c, { owned = {} })) do rows[w.id] = w end
  assert(rows.food.exp.jobs == 550 and rows.food.exp.rate == 0.10 and rows.company.exp.rate == 0.15)
  assert(rows.firm.exp == nil)
end)

test('freight pays the distance rate for a full load and less for a light one', function()
  local haul = require('cargoEarth/haul')
  assert(haul.fill({ tier = 'van', kind = 'parcel', amount = 96, kg = 864 }) == 1)
  assert(haul.fill({ tier = 'van', kind = 'parcel', amount = 48, kg = 432 }) == 0.5)
  assert(haul.fill({ tier = 'rigid', kind = 'parcel', amount = 200, kg = 2800 }) == 0.35, 'heavy goods count by weight')
  assert(haul.fill({ tier = 'semi', kind = 'dryBulk', amount = 12800, kg = 4480 }) == 1, 'the bulk trailer full by space')
  local idx = { cargo = { pallets_general = { pay = 1 } } }
  local rowsFor = function(n) return { { id = 1, capacity = n, cargoTypes = { 'parcel' } } } end
  local full = { cargo = 'pallets_general', km = 10, pickupKm = 1 }
  assert(haul.prepare(full, 'van', rowsFor(96), idx) and full.pay == 150 + 18 * 10 and full.loadBonus == 0)
  local light = { cargo = 'pallets_general', km = 10, pickupKm = 1 }
  assert(haul.prepare(light, 'van', rowsFor(48), idx))
  assert(light.loadFill == 0.5 and light.pay == math.floor(330 * 0.875 / 5 + 0.5) * 5 and light.loadBonus == light.pay - 330)
end)
