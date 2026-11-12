local clock = require('cargoEarth/clock')
local economy = require('cargoEarth/economy')
local home = require('cargoEarth/home')
local persistence = require('cargoEarth/persistence')
local employment = require('cargoEarth/employment')
local cargo = require('cargoEarth/cargo')
local jobs = require('cargoEarth/jobs')
local food = require('cargoEarth/food')
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
local gps
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
  status = function() return {state = 'off'} end}
package.loaded['cargoEarth/earth'] = {
  pose = function() return pose end, status = function() return ready and 'ok' or 'World loading' end,
  notify = function() end, route = function() return nil end,
  gps = function(lat, lon) gps = {lat = lat, lon = lon} return true end,
  gpsClear = function() gps = nil end,
  teleport = function(lat, lon) pose.lat, pose.lon = lat, lon return true end,
  worldXY = function(p, pt) return p.x + (pt[2] - p.lon) * 71700, p.y + (pt[1] - p.lat) * 111320 end,
}
local function adapter()
  return {
    vehicle = function() return vehicle end, ownedVehicle = function() return vehicle end,
    isOwned = function() return true end, damage = function() return damageValue end, configs = function() return {} end,
    playerId = function() return vehicle and vehicle.id end, ownsVehicleId = function(id) return vehicle and vehicle.id == id end,
    watchForces = function(_, token) impactToken = token return true end,
    captureConfig = function() return {parts = {body = vehicle.model}} end,
    freightLoanerConfig = function() return {parts = {load = 'box'}} end,
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
    setCargoLoad = function() return true end,
  }
end
local function fresh()
  disk, failPath, spawnFailure, ready = {}, nil, nil, true
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
  local poor = fuel.quote(car, fuel.sells('fuel'), 1, nil, 190)
  assert(poor.units.gasoline == 5 and poor.cost == 190 and not poor.full)
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
  assert(s.career.money == 20 and s.career.garage.debt == math.ceil(10 * fuel.price('gasoline', fuel.DELIVERY_FACTOR)) + fuel.DELIVERY_FEE)
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
  pose.lat, pose.lon = job.from.g[1], job.from.g[2]
  advance(core)
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
  local plan = {[7] = {volume = 40, density = 1}, [8] = {volume = 20, density = 1}}
  local kept = parcel.keep(plan, 10, 2.5)
  assert(kept[7].volume == 25 and kept[8].volume == 0)
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
    end
  end
  assert(not s.job and c.money > money and boxes[1].currentVolume == 0, 'emptied and paid')
  assert(core.careerState().reputation.freight.rated == 1)
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
  assert(speedlimit.at({}, 'n0', 'n1') == nil and speedlimit.at(nil, 'a', 'b') == nil)
end)

test('the phone shows the limit under the car, red when too fast, and a camera without a limit takes its road one', function()
  local core, s = fresh()
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
  assert(upkeep.cost({model = 'us_semi'}, 'oil') == math.floor(120 * 3.2 / 5 + 0.5) * 5, 'a tractor costs more')
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
  -- a driver for the tractor: nothing happens without a trailer
  local pick = hq.drivers.applicants[1]
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
  for _, k in ipairs({ 'existing', 'towModel', 'spawnTow', 'withPlayer', 'towedDistances', 'towedDamage', 'towedCount', 'remove', 'id' }) do
    saved[k] = trailers[k]
  end
  local spawned, distances, damage = 0, {}, 0
  trailers.existing = function(list) return { list[1] } end
  trailers.towModel = function() return 'cartrailer' end
  trailers.spawnTow = function(kind, cars) spawned = spawned + 1 distances = { 1 } return kind == 'cartrailer' and #cars == 1 end
  trailers.withPlayer = function() return true end
  trailers.towedDistances = function() return distances end
  trailers.towedDamage = function() return damage end
  trailers.towedCount = function() return #distances end
  trailers.remove = function() distances = {} end
  trailers.id = function() return #distances > 0 and 7 or nil end
  local ok, err = pcall(function()
    core.setMode('trucking')
    advance(core, 2)
    core.generate()
    local i, job
    for k, offer in ipairs(s.offers) do if offer.tow then i, job = k, offer break end end
    assert(job and job.to.n == 'Workshop at Test pump', 'a tow job to the workshop at a fuel station')
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
    assert(spawned == 1 and s.phase == 'toDelivery' and job.tow.onBoard == 1)
    assert(job.tow.damage0 == 500, 'damage before the tow is not yours ' .. tostring(job.tow.damage0) .. ' ' .. tostring(job.tow.spawnedAt) .. ' ' .. tostring(s.clock))
    -- it is damaged and slides off
    damage = damage + 300
    distances = { 12 }
    advance(core, 4)
    local state = core.phoneState()
    assert(job.tow.onBoard == 0 and state.active.tow.onBoard == 0 and state.active.canRestoreTrailer)
    pose.lat, pose.lon = job.to.g[1], job.to.g[2]
    advance(core)
    assert(s.job == job, 'not delivered without the car')
    c.money = 1000
    core.phoneAction('restoreTrailer')
    assert(spawned == 2 and c.money == 1000 - core.TOW_RELOAD_FEE and job.tow.onBoard == 1)
    damage = 0                      -- the cars spawned again are undamaged; the 300 stays counted
    advance(core, 8)
    damage = damage + 600           -- 10 % worse on the way, 5 % before the reload
    advance(core, 30)
    assert(not s.job, 'delivered')
    assert(s.phone.lastDone.cargoCondition == 85 and s.phone.lastDone.pay <= math.floor(job.pay * 0.85 + 0.5))
    assert(c.history[1].kind == 'tow')
  end)
  for k, f in pairs(saved) do trailers[k] = f end
  assert(ok, err)
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
  assert(#added == 1 and added[1][1]:find('beamngEarth') and added[1][2] == 'cargoEarthPhone' and added[1][3].bottom == '310px')
  assert(current == layouts[2].filename and written.phoneAdded)
  assert(layout.ensure(api, flag) == 'done' and #added == 1, 'only once: a player who removes it keeps that')
  written = nil
  layouts[2].apps[2] = {appName = 'cargoEarthPhone'}
  assert(layout.ensure(api, flag) == 'present' and #added == 1, 'a phone the player placed is left alone')
  written = nil
  assert(layout.ensure({layouts = function() return {layouts[1]} end}, flag) == 'none' and written == nil)
  assert(layout.ensure(nil, flag) == nil)
  written = nil
  local refuse = {layouts = function() return {{type = 'beamngEarth', filename = 'x/beamngEarth.uilayout.json', apps = {}}} end,
    addApp = function() return false end, current = function() return nil end, setCurrent = function() end}
  assert(layout.ensure(refuse, flag) == nil and written == nil, 'a refused insert is not recorded as done')
  print('PASS the phone goes into the .Earth layout above the speedometer, once')
end
