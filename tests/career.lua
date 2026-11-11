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

print(string.format('%d career tests passed', total))
