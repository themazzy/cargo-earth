-- cargoEarth/rigs: your own trailers in the game (the rules are cargoEarth/trailerpool). Taking one out at home or at
-- the headquarters, parking it, leaving it anywhere and taking it again there, its wear and damage, and the phone's
-- Trailers page. core passes itself in (core.state() is its state table).
local pool = require('cargoEarth/trailerpool')
local trailers = require('cargoEarth/trailers')
local home = require('cargoEarth/home')
local firm = require('cargoEarth/firm')
local jobs = require('cargoEarth/jobs')
local upkeep = require('cargoEarth/upkeep')
local garage = require('cargoEarth/garage')
local tow = require('cargoEarth/tow')
local haul = require('cargoEarth/haul')
local earth = require('cargoEarth/earth')
local economy = require('cargoEarth/economy')
local M = {}

M.LEAVE_M = 300     -- a trailer standing unhitched this far behind is stored where it was left
M.MARKET_EVERY_S = 30
local last = {}     -- [pool id] = last damage number read (this session)

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

local function pose()
  return earth.status() == 'ok' and earth.pose() or nil
end

local function playerId(core) return core.G.playerId and core.G.playerId() or -1 end

-- A pintle hook among the vehicle's parts (drawbar trailers; the game's couplers decide in the end).
function M.hasPintle(vehicle)
  for _, part in pairs(type(vehicle) == 'table' and vehicle.slotPartMap or {}) do
    local name = type(part) == 'string' and part:lower() or ''
    if name:find('pintle', 1, true) and not name:find('delete', 1, true) and not name:find('cover', 1, true) then return true end
  end
  return false
end

-- What the player's vehicle can pull: { semi = fifth wheel, hitch = a tow hitch, pintle = a pintle hook }, and the vehicle.
local function rigOf(core)
  local v = core.G.vehicle and core.G.vehicle()
  if not v then return {}, nil end
  local tier = haul.carrier(v)
  if tier == 'semi' then return { semi = true }, v end
  return { hitch = tow.hasHitch(v) or nil, pintle = (tier == 'rigid' and M.hasPintle(v)) or nil }, v
end
M.rigOf = rigOf

-- Your trailer that is on the player's hitch now: the pool row, its catalogue entry and vehicle id. nil when none.
function M.coupled(core)
  local S = core.state()
  for _, t in ipairs(pool.list(S.career)) do
    if t.place == 'out' and trailers.poolCoupled(t.id, playerId(core)) then
      return { t = t, entry = pool.entry(t), vid = trailers.poolVid(t.id), id = t.id, bulk = t.bulk }
    end
  end
end

-- Where the player stands: at home, at the headquarters, or neither.
local function where(c, p)
  if p and home.near(c, p) then return 'home' end
  if p and firm.atHq(c, p) then return 'hq' end
end

-- Where a fetched trailer is brought: home or the headquarters yard (pool.homeFor). nil when neither.
function M.spotPoint(c, place)
  if place == 'home' then return c.home and c.home.g end
  if place == 'hq' then return c.firm and c.firm.hq and c.firm.hq.g end
end

local function canPull(rig, e) return type(rig) == 'table' and rig[e.pulls] == true end

local NEEDS = { semi = 'Needs a tractor', hitch = 'Needs a tow hitch', pintle = 'Needs a box truck with a pintle hook' }
local function needsText(e) return NEEDS[e.pulls] or 'Needs a tow hitch' end

-- The config a trailer is spawned with: its stock load on it when it carries one (t.load), else empty.
function M.configOf(t, e, bulk)
  local opt = t.load and pool.loadOptions(e, t.load.cargo)[t.load.n]
  if opt then return pool.loadConfig(e, opt, jsonReadFile) end
  return pool.config(e, jsonReadFile, bulk)
end

-- Put the stock load on the trailer on your hitch, or take it off (n nil): the trailer is spawned again in its loaded
-- (or empty) stock config and coupled. True, or false and why. The job waits until it is on the hitch again.
function M.swapLoad(core, t, cargoId, n)
  local e = pool.entry(t)
  if not e then return false, 'Unknown trailer.' end
  local opt = n and pool.loadOptions(e, cargoId)[n]
  if n and not opt then return false, 'This trailer cannot take that load.' end
  local was = t.load
  t.load = opt and { cargo = cargoId, n = n } or nil
  local model, config = M.configOf(t, e, t.bulk)
  local ok, why = trailers.takePool(t.id, model, config, nil, e.len, true)
  if not ok then t.load = was return false, tostring(why) end
  last[t.id] = nil   -- a new vehicle: its damage number starts again
  return true
end

-- Take a parked (or left) trailer: spawned behind you and put on your hitch.
local function takeOut(core, t, bulk)
  local S, c = core.state(), core.state().career
  local e = pool.entry(t)
  local p = pose()
  -- the trailer a job in progress needs (after a reload it stands where it was): it may be taken again
  local forJob = S.job and S.job.haul and S.job.haul.pool == t.id
  if S.job and not forJob then return false, 'Finish your current job first.' end
  if c.employment then return false, 'Company work uses the company\'s trailer.' end
  if p and (p.speed or 0) > core.STOP_SPEED then return false, 'Stop first.' end
  if t.place == 'home' and where(c, p) ~= 'home' then return false, 'Drive home to take it out.' end
  if t.place == 'hq' and where(c, p) ~= 'hq' then return false, 'Drive to your headquarters to take it out.' end
  if t.place == 'left' then
    local km = p and t.at and jobs.km(p.lat, p.lon, t.at.g[1], t.at.g[2])
    if not km or km * 1000 > pool.NEAR_M then return false, 'Drive to where it stands first: ' .. (t.at and t.at.n or 'unknown') .. '.' end
  end
  if t.place == 'driver' then return false, 'A hired driver has it.' end
  if t.place == 'out' then return false, 'It is already out.' end
  local rig = rigOf(core)
  if not garage.inOwnCar(core.G, S.career.garage) then return false, 'Sit in your own vehicle first.' end
  if not canPull(rig, e) then return false, 'This trailer ' .. needsText(e):lower() .. '.' end
  for _, other in ipairs(pool.list(c)) do
    if other.place == 'out' and trailers.poolCoupled(other.id, playerId(core)) then return false, 'Park the trailer you have first.' end
  end
  if forJob then bulk = S.job.haul.bulk end   -- the job's own layout (boxes or bulk boxes), whatever was pressed
  bulk = bulk and e.bulk or nil
  local model, config = M.configOf(t, e, bulk)
  local ok, why = trailers.takePool(t.id, model, config, e.tow, e.len)
  if not ok then return false, 'Could not get the trailer out: ' .. tostring(why) end
  t.from, t.place, t.bulk = t.place, 'out', bulk
  if p then t.at = { n = t.at and t.at.n or 'Out with you', g = { p.lat, p.lon } } end
  last[t.id] = nil
  if not forJob then
    S.offers, S.offerStats, S.offeredAt, S.phone.incoming = {}, nil, { lat = 0, lon = 0 }, nil
    S.trailerOffersWait = true   -- offers again once it is on the hitch (core.trailerOffersTick)
  end
  return true, string.format('Putting your %s on the hitch%s.', t.name:lower(), bulk and ' with bulk boxes' or '')
end

-- Park the trailer that is out: at home or at the headquarters (where you stand), into a free spot.
local function park(core, t)
  local S, c = core.state(), core.state().career
  if t.place ~= 'out' then return false, 'It is not out with you.' end
  local vid = trailers.poolVid(t.id)
  if S.job and ((S.job.haul and S.job.haul.pool == t.id) or (vid and trailers.id() == vid)) then
    return false, 'Your job is using it. Finish the job first.'
  end
  local at = where(c, pose())
  if not at then return false, 'Drive home (or to your headquarters) to park it.' end
  local h, hq = pool.spots(c, home)
  local n = 0
  for _, o in ipairs(pool.list(c)) do if o ~= t and o.place == at then n = n + 1 end end
  if n >= (at == 'home' and h or hq) then return false, 'No free trailer spot here.' end
  trailers.parkPool(t.id)
  t.place, t.at, t.from = at, nil, nil
  return true, string.format('%s parked %s.', t.name, at == 'home' and 'at home' or 'at the headquarters')
end

-- Store a trailer that is out where it stands (it was unhitched and left behind).
local function leave(core, t, p)
  trailers.parkPool(t.id)
  local c = core.state().career
  local at = p and where(c, p)
  if at and pool.homeFor(c, home) then
    t.place, t.at = at, nil
    return
  end
  t.place = 'left'
  if not (t.at and t.at.g) then t.at = { n = 'Where you left it', g = p and { p.lat, p.lon } or { 0, 0 } } end
  if t.at.n == 'Out with you' then t.at.n = 'Where you left it' end
end

-- Track wear and damage of the trailer on your hitch, and store trailers left behind. Called every frame.
function M.tick(core, dt)
  local S = core.state()
  local c = S.career
  if not (c and c.trailers) or S.pendingCareer then return end
  local p = pose()
  local pid = playerId(core)
  for _, t in ipairs(c.trailers.list or {}) do
    if t.place == 'out' then
      local vid = trailers.poolVid(t.id)
      if not vid then
        -- gone (the game removed it, a reload): it stays where it was last seen
        leave(core, t, nil)
      else
        local on = trailers.coupledIds(pid, vid)
        local dist = trailers.poolDistance(t.id)
        if on and p then
          t.at = t.at or {}
          t.at.g = { p.lat, p.lon }
          local km = (p.speed or 0) * dt / 1000
          if km > 0 then
            t.km = (t.km or 0) + km
            upkeep.wear(t, km)
            S.trailerWearKm = (S.trailerWearKm or 0) + km
            if S.trailerWearKm >= 1 then
              local chance = upkeep.chance(t, S.trailerWearKm)
              S.trailerWearKm = 0
              if chance > 0 and core.random() < chance then
                local failure = upkeep.breakdown(t)
                upkeep.roadside(c, c.garage, t, failure)
                core.sayText(string.format('Your trailer: %s Roadside help: %d CZK.', (failure.text:gsub('the car', 'the trailer')), failure.cost), 8)
              end
            end
          end
        elseif dist and dist > M.LEAVE_M and not (S.job and ((S.job.haul and S.job.haul.pool == t.id) or trailers.id() == vid)) then
          leave(core, t, p and { lat = t.at and t.at.g and t.at.g[1] or p.lat, lon = t.at and t.at.g and t.at.g[2] or p.lon })
          core.sayText(string.format('Your %s stays %s.', t.name:lower(), t.place == 'left' and 'where you left it' or
            (t.place == 'home' and 'at home' or 'at the headquarters')), 5)
        end
        -- crash damage: repairs owed, like a car's (capped at half its value)
        local damage = trailers.poolDamage(t.id)
        if damage then
          local before = last[t.id]
          last[t.id] = damage
          if before and damage > before then
            -- kept unrounded, so many small scrapes add up as one big knock would
            t.damageOwed = (tonumber(t.damageOwed) or t.repair or 0) + (damage - before) * garage.REPAIR_PER_DAMAGE
            t.repair = math.min(round5(pool.value(t) * garage.REPAIR_CAP), round5(t.damageOwed))
          end
        end
      end
    end
  end
  -- the used trailer market ages with play time
  S.trailerMarketT = (S.trailerMarketT or 0) + dt
  if S.trailerMarketT >= M.MARKET_EVERY_S then
    pool.marketTick(c, S.trailerMarketT / 60, core.random, M.sellers(core, p))
    S.trailerMarketT = 0
  end
end

-- After a career is loaded: the trailers that were out are where they were last seen.
function M.onLoad(c)
  trailers.clearPool()   -- none of another career's (or this one's last session's) trailers stay in the world
  pool.restore(c)
  for _, t in ipairs(c.trailers.list) do
    if t.place == 'out' then
      if t.at and t.at.g then t.place = 'left' t.at.n = t.at.n == 'Out with you' and 'Where you left it' or t.at.n
      else t.place = 'home' end
    elseif t.place == 'driver' then t.place = 'hq' end
  end
  last = {}
end

-- Yards near the player that sell used trailers: real workplaces from the freight index (anywhere on Earth).
function M.sellers(core, p)
  local S = core.state()
  if not (p and S.idx) then return nil end
  local near = {}
  for _, d in ipairs(S.idx.depots or {}) do
    if d.g and d.n and jobs.inBox(p.lat, p.lon, d.g, 30) then
      local k = jobs.km(p.lat, p.lon, d.g[1], d.g[2])
      if k <= 30 then near[#near + 1] = { n = d.n, g = { d.g[1], d.g[2] }, k = k } end
    end
  end
  table.sort(near, function(a, b) return a.k < b.k end)
  local out = {}
  for i = 1, math.min(8, #near) do out[i] = { n = near[i].n, g = near[i].g } end
  return out
end

-- The service spot for a trailer: on your hitch where cars are serviced, or parked at home or the headquarters.
local function serviceFactor(core, t)
  local c = core.state().career
  if t.place == 'home' then return home.has(c, 'workshop') and home.roomById.workshop.factor or 1, 'at home' end
  if t.place == 'hq' then return firm.value(c, 'workshop') or 1, 'at the headquarters' end
  if t.place == 'out' and trailers.poolCoupled(t.id, playerId(core)) then
    local spot, factor = core.serviceSpot()
    if spot then return factor, spot end
  end
end

function M.act(core, name, a, b)
  local S = core.state()
  local c = S.career
  pool.restore(c)
  local debt = (c.garage and c.garage.debt) or 0
  local ok, msg = false, 'Unknown action'
  if not (c.garage and c.garage.started) then return false, 'Trailers are part of the career.' end
  if name == 'buyNew' then ok, msg = pool.buyNew(c, a, home, debt)
  elseif name == 'buyUsed' then ok, msg = pool.buyUsed(c, a, home, debt)
  else
    local t = pool.find(c, a)
    if not t then return false, 'Unknown trailer.' end
    if name == 'takeOut' then ok, msg = takeOut(core, t, b == 'bulk')
    elseif name == 'park' then ok, msg = park(core, t)
    elseif name == 'hitch' then
      if t.place ~= 'out' then ok, msg = false, 'It is not out.'
      elseif (trailers.poolDistance(t.id) or 999) > trailers.NEAR_M then ok, msg = false, 'Back up to it first.'
      else ok, msg = trailers.hitchPool(t.id), 'Hitching your trailer…' end
    elseif name == 'fetch' then
      if t.place ~= 'left' then ok, msg = false, 'It is not out anywhere.'
      else
        local place = pool.homeFor(c, home)
        local g = M.spotPoint(c, place)
        if not place or not g then ok, msg = false, 'No free trailer spot to bring it to.'
        else
          local cost = pool.fetchCost(jobs.km(t.at.g[1], t.at.g[2], g[1], g[2]))
          if (c.money or 0) < cost then ok, msg = false, string.format('Not enough money (%d CZK needed).', cost)
          else
            economy.post(c, -cost, 'trailer', economy.nextId(c, 'trailer'), 'Delivery of ' .. t.name:lower())
            t.place, t.at = place, nil
            ok, msg = true, string.format('%s is brought %s for %d CZK.', t.name, place == 'home' and 'home' or 'to the headquarters', cost)
          end
        end
      end
    elseif name == 'service' then
      local factor, spot = serviceFactor(core, t)
      if not factor then ok, msg = false, 'Service it parked at home or the headquarters, or on your hitch at a fuel station.'
      else ok, msg = upkeep.service(c, t, nil, factor, spot) end
    elseif name == 'repair' then
      local factor = (t.place == 'home' or t.place == 'hq') and serviceFactor(core, t)
      if (t.repair or 0) <= 0 then ok, msg = false, 'It needs no repair.'
      elseif not factor then ok, msg = false, 'Park it at home or at the headquarters to repair it.'
      else
        local cost = round5(t.repair * factor)
        if (c.money or 0) < cost then ok, msg = false, string.format('Not enough money (%d CZK needed).', cost)
        else
          economy.post(c, -cost, 'trailer', economy.nextId(c, 'trailer'), 'Repair of ' .. t.name:lower())
          t.repair, t.damageOwed = 0, nil
          ok, msg = true, string.format('%s repaired for %d CZK.', t.name, cost)
        end
      end
    elseif name == 'sell' then ok, msg = pool.sell(c, t.id)
    end
  end
  return ok, msg
end

-- The phone's Trailers page.
function M.state(core)
  local S = core.state()
  local c = S.career
  pool.restore(c)
  local p = pose()
  local at = where(c, p)
  local rig = rigOf(core)
  local h, hq = pool.spots(c, home)
  local debt = (c.garage and c.garage.debt) or 0
  local out = { home = c.home ~= nil, homeSpots = h, hqSpots = hq, owned = #c.trailers.list, at = at, money = c.money or 0,
    busy = S.job ~= nil or nil, company = c.employment ~= nil or nil, list = {}, shop = {}, used = {},
    room = pool.homeFor(c, home) ~= nil, msg = S.trailerMsg }
  local onHitch = M.coupled(core)
  for _, t in ipairs(c.trailers.list) do
    local e = pool.entry(t)
    local row = { id = t.id, name = t.name, place = t.place, km = math.floor(t.km or 0), condition = t.condition,
      repair = t.repair or 0, value = pool.value(t), sellFor = pool.sellQuote(t), bulk = t.bulk, canBulk = e.bulk or nil,
      what = pool.FAMILIES[e.family].name, upkeep = upkeep.state(t, 1), hitched = onHitch and onHitch.id == t.id or nil,
      at = t.at and t.at.n or nil, needs = not canPull(rig, e) and needsText(e) or nil,
      loaded = t.load and (pool.loadOptions(e, t.load.cargo)[t.load.n] or {}).what or nil,
      carries = M.carriesText(e) }
    if t.place == 'left' and p and t.at then
      local km = jobs.km(p.lat, p.lon, t.at.g[1], t.at.g[2])
      row.km_away = math.floor(km * 10 + 0.5) / 10
      row.near = km * 1000 <= pool.NEAR_M or nil
      local g = M.spotPoint(c, pool.homeFor(c, home))
      row.fetch = g and pool.fetchCost(jobs.km(t.at.g[1], t.at.g[2], g[1], g[2])) or nil
    end
    row.canTake = (not S.job or (S.job.haul and S.job.haul.pool == t.id)) and not c.employment and not row.needs and (
      (t.place == 'home' and at == 'home') or (t.place == 'hq' and at == 'hq') or (t.place == 'left' and row.near)) or nil
    row.canPark = t.place == 'out' and at ~= nil or nil
    local factor = serviceFactor(core, t)
    row.canService = factor ~= nil and row.upkeep.due > 0 or nil
    row.serviceCost = factor and round5(row.upkeep.dueCost * factor) or nil
    row.repairCost = (t.place == 'home' or t.place == 'hq') and factor and round5((t.repair or 0) * factor) or nil
    out.list[#out.list + 1] = row
  end
  for _, e in ipairs(pool.CATALOGUE) do
    out.shop[#out.shop + 1] = { id = e.id, name = e.name, price = e.price, what = pool.FAMILIES[e.family].name,
      boxes = e.boxes, tankL = e.tankL, payload = e.payload, pulls = e.pulls, carries = M.carriesText(e),
      can = c.home ~= nil and out.room and debt <= 0 and (c.money or 0) >= e.price or nil }
  end
  local m = c.trailerMarket
  for _, l in ipairs(type(m) == 'table' and m.list or {}) do
    local e = pool.byId[l.cat]
    local km = p and l.seller and jobs.km(p.lat, p.lon, l.seller.g[1], l.seller.g[2]) or nil
    out.used[#out.used + 1] = { id = l.id, name = l.name, price = l.price, km = l.km, condition = l.condition,
      faults = l.faults, body = l.body, seller = l.seller and l.seller.n, away = km and math.floor(km * 10 + 0.5) / 10 or nil,
      what = pool.FAMILIES[e.family].name, minutesLeft = math.max(1, math.floor(l.left or 1)),
      can = c.home ~= nil and out.room and debt <= 0 and (c.money or 0) >= l.price or nil }
  end
  table.sort(out.used, function(a, b) return (a.away or 1e9) < (b.away or 1e9) end)
  return out
end

-- What a trailer carries, for the phone: "Boxes, coils, pipes, planks".
local LOAD_NAMES = { steel_coils = 'steel coils', steel_beams = 'steel pipes', lumber = 'planks', stone_blocks = 'marble',
  logs = 'logs', containers = 'containers', hay = 'hay bales', furniture = 'furniture' }
local LOAD_ORDER = { 'steel_coils', 'steel_beams', 'lumber', 'stone_blocks', 'logs', 'containers', 'hay', 'furniture' }
function M.carriesText(e)
  local out = {}
  local fam = pool.FAMILIES[e.family] or {}
  if (e.boxes or 0) > 0 then out[#out + 1] = string.format('%d cargo boxes', e.boxes) end
  if e.bulk then out[#out + 1] = 'dry bulk' end
  if e.tankL then out[#out + 1] = string.format('%d L tank', e.tankL) end
  if fam.chilled then out[#out + 1] = 'chilled food' end
  for _, id in ipairs(LOAD_ORDER) do
    if #pool.loadOptions(e, id) > 0 then out[#out + 1] = LOAD_NAMES[id] end
  end
  if fam.home then out[#out + 1] = 'home deliveries' end
  if e.tow then out[#out + 1] = 'tow jobs' end
  local text = table.concat(out, ', ')
  return text:sub(1, 1):upper() .. text:sub(2)
end

-- The trailer you pull for your own semi jobs: its catalogue entry and bulk mode, as cargoEarth/haul wants it.
function M.haulRig(core)
  local r = M.coupled(core)
  if not r then return nil end
  return { id = r.id, entry = r.entry, bulk = r.bulk }
end

-- What your trailers at home could do (for the board when nothing is on your hitch).
function M.parkedSummary(c)
  local out = {}
  for _, t in ipairs(pool.list(c)) do
    if t.place == 'home' or t.place == 'hq' or t.place == 'left' then out[#out + 1] = t.name end
  end
  return out
end

-- A stock load job at the pickup (unload false) or at the drop (true): the trailer is spawned again in its loaded (or
-- empty) stock config and the job goes on once it is back on the hitch. True when done. Uses core's freight load state
-- (S.freightLoad, marked load = true) so the delivery knows unloading has started.
M.SWAP_WAIT_S = 4
function M.loadWork(core, job, unload)
  local S = core.state()
  local t = pool.find(S.career, job.haul.pool)
  if not t then S.freightStatus = 'Your trailer for this load is gone.' return false end
  local state = S.freightLoad
  if not state or state.job ~= job or not state.load then
    state = { job = job, load = true }
    S.freightLoad = state
  end
  local command = unload and 'unload' or 'load'
  if state.command == command .. 'Done' or (not unload and state.command == 'unloadDone') then return true end
  local want = not unload and job.haul.amount or nil
  local done = (want == nil and t.load == nil) or (want ~= nil and t.load ~= nil and t.load.cargo == job.cargo and t.load.n == want)
  if done then
    if trailers.poolCoupled(t.id, playerId(core)) then
      state.command, S.freightStatus = command .. 'Done', nil
      return true
    end
    S.freightStatus = (trailers.hitching() or trailers.latching()) and (unload and 'Unloading…' or 'Loading…') or 'Couple your trailer.'
    return false
  end
  if state.command == command and S.clock < (state.sentAt or 0) + M.SWAP_WAIT_S then return false end
  -- the load comes on or off only with the trailer on your hitch here (no paid drop with the trailer left behind)
  if not trailers.poolCoupled(t.id, playerId(core)) then S.freightStatus = 'Couple your trailer.' return false end
  local ok, why = M.swapLoad(core, t, job.cargo, want)
  state.command, state.sentAt = command, S.clock
  S.freightStatus = ok and (unload and 'Unloading…' or 'Loading…') or ('The load could not be put on: ' .. why)
  return false
end

-- A stock load job left (cancelled or failed): its load comes off the trailer.
function M.dropLoad(core, job)
  local t = job and job.haul and job.haul.pool and pool.find(core.state().career, job.haul.pool)
  if not (t and t.load) then return end
  -- on your hitch it is spawned again empty; standing elsewhere, it comes out empty the next time it is taken
  if t.place == 'out' and trailers.poolCoupled(t.id, playerId(core)) then
    if not M.swapLoad(core, t, nil, nil) then t.load = nil end
  else
    t.load = nil
  end
end

return M
