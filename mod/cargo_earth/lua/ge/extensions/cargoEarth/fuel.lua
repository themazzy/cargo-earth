-- Fuel and running costs. BeamNG's own engine simulation burns the fuel; this module only keeps the books:
-- what each career car has in its tanks, what it used, what a refill costs and where the stations are.
-- A reset or respawn refills a tank in the game, so every car's level is remembered and put back
-- (observe() returns the levels to set). Pure rules: the vehicle side is cargoEarth/gamecar + vehicle fuel.lua.
local M = {}

-- CZK per litre (per kWh for electric). The currency of the career is CZK everywhere.
-- Scaled to the game's pay, not the real pump price: BeamNG cars burn about 20 L/100 km in town (a Ferax in a
-- 2026-11-12 save: 21.6), so at the real 38 CZK fuel took about 40 % of courier pay. A third of that: about 13 %.
M.PRICE = { gasoline = 13, diesel = 12, electric = 3 }
M.UNIT = { gasoline = 'L', diesel = 'L', electric = 'kWh' }
M.STATION_SPREAD = 0.06      -- a station's price differs by up to this share (fixed per station)
M.STATION_RADIUS = 60        -- metres from a station's point that count as "at the pumps"
M.HQ_DISCOUNT = 0.85         -- the firm's own tank
M.DELIVERY_FACTOR = 1.6      -- roadside fuel costs this much more per unit
M.DELIVERY_FEE = 30          -- and a call-out fee
M.DELIVERY_UNITS = 10        -- litres (or kWh) a roadside delivery brings at most
M.REFILL_JUMP = 0.02         -- a tank this much fuller than remembered was refilled by a reset, not by us
M.LOW, M.EMPTY = 0.15, 0.01  -- shares of a tank: the phone warns, the car is stranded
M.DEFAULT_PER_100 = { gasoline = 8, diesel = 9, electric = 20 }   -- for the range until enough km are measured
M.MEASURE_KM = 5
M.USED_MIN, M.USED_MAX = 0.12, 0.55   -- a used car comes with this share of a tank
M.GRID = 0.1

function M.kind(energyType, storageType)
  local t = tostring(energyType or ''):lower()
  if storageType == 'electricBattery' or t:find('electric', 1, true) then return 'electric' end
  if t:find('diesel', 1, true) then return 'diesel' end
  return 'gasoline'
end

local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end
local function clamp01(n) return math.max(0, math.min(1, n)) end

-- A vehicle report: { [name] = { ratio, cap, kind } }. Only sane tanks are kept.
function M.clean(report)
  local out, n = {}, 0
  for name, t in pairs(type(report) == 'table' and report or {}) do
    if type(name) == 'string' and type(t) == 'table' and finite(t.ratio) and finite(t.cap) and t.cap > 0 and t.cap < 100000 then
      out[name] = { ratio = clamp01(t.ratio), cap = t.cap, kind = M.PRICE[t.kind] and t.kind or 'gasoline' }
      n = n + 1
    end
  end
  return n > 0 and out or nil
end

local function totals(tanks)
  local have, cap = {}, {}
  for _, t in pairs(tanks or {}) do
    have[t.kind] = (have[t.kind] or 0) + t.ratio * t.cap
    cap[t.kind] = (cap[t.kind] or 0) + t.cap
  end
  return have, cap
end

-- The main energy of a car: the kind with the largest capacity (a hybrid: its fuel tank in litres).
function M.mainKind(car)
  local _, cap = totals(car and car.fuel and car.fuel.tanks)
  local best
  for _, kind in ipairs({ 'gasoline', 'diesel', 'electric' }) do
    if cap[kind] and (not best or (kind ~= 'electric' and best == 'electric')) then best = kind end
  end
  return best
end

-- Takes what the vehicle reports. Returns the tank levels the game must be set back to (or nil)
-- and the units used since the last report. km: distance driven since then.
function M.observe(car, report, km)
  local seen = M.clean(report)
  if not seen then return nil, 0 end
  local f = car.fuel
  if type(f) ~= 'table' or type(f.tanks) ~= 'table' then
    f = { tanks = {}, used = {}, km = 0 }
    -- A car bought used arrives with what its last owner left in it.
    local start = type(car.fuel) == 'table' and tonumber(car.fuel.start) or nil
    for name, t in pairs(seen) do
      f.tanks[name] = { ratio = start and math.min(t.ratio, clamp01(start)) or t.ratio, cap = t.cap, kind = t.kind }
    end
    car.fuel = f
  end
  f.used, f.km = type(f.used) == 'table' and f.used or {}, tonumber(f.km) or 0
  -- the share the remembered tanks hold per kind: a new tank (parts changed) starts no fuller than that
  local have, cap = totals(f.tanks)
  local set, used = nil, 0
  for name, t in pairs(seen) do
    local known = f.tanks[name]
    if not known then
      local share = cap[t.kind] and cap[t.kind] > 0 and have[t.kind] / cap[t.kind] or nil
      known = { ratio = share and math.min(t.ratio, share) or t.ratio, cap = t.cap, kind = t.kind }
      f.tanks[name] = known
    end
    known.cap, known.kind = t.cap, t.kind
    local diff = t.ratio - known.ratio
    if diff > M.REFILL_JUMP then
      set = set or {}
      set[name] = known.ratio
    elseif diff > 0 then
      if t.kind == 'electric' then known.ratio = t.ratio end   -- regenerative braking
    elseif diff < 0 then
      local units = -diff * t.cap
      f.used[t.kind] = (f.used[t.kind] or 0) + units
      used = used + units
      known.ratio = t.ratio
    end
  end
  for name in pairs(f.tanks) do if not seen[name] then f.tanks[name] = nil end end
  if finite(km) and km > 0 and km < 5 then f.km = f.km + km end
  return set, used
end

-- Every remembered level, to put on a freshly spawned car.
function M.levels(car)
  local out
  for name, t in pairs(car and car.fuel and car.fuel.tanks or {}) do
    out = out or {}
    out[name] = t.ratio
  end
  return out
end

function M.usedStart(rnd)
  return M.USED_MIN + (M.USED_MAX - M.USED_MIN) * (rnd or math.random)()
end

-- What the phone shows: share of the main tank, units, average use and range.
function M.state(car)
  local f = car and car.fuel
  if type(f) ~= 'table' or type(f.tanks) ~= 'table' or not next(f.tanks) then return nil end
  local have, cap = totals(f.tanks)
  local kind = M.mainKind(car)
  if not kind then return nil end
  local out = { kind = kind, unit = M.UNIT[kind], have = math.floor(have[kind] * 10 + 0.5) / 10,
    cap = math.floor(cap[kind] * 10 + 0.5) / 10, share = cap[kind] > 0 and have[kind] / cap[kind] or 0, tanks = {} }
  out.low, out.empty = out.share <= M.LOW, out.share <= M.EMPTY
  local km, used = tonumber(f.km) or 0, f.used and f.used[kind] or 0
  local per100 = M.DEFAULT_PER_100[kind]
  if km >= M.MEASURE_KM and used > 0 then
    per100 = used / km * 100
    out.per100 = math.floor(per100 * 10 + 0.5) / 10
    out.measuredKm = math.floor(km)
  end
  out.rangeKm = math.floor(have[kind] / per100 * 100 + 0.5)
  out.costPerKm = math.floor(per100 * M.PRICE[kind]) / 100
  for _, k in ipairs({ 'gasoline', 'diesel', 'electric' }) do
    if cap[k] then
      out.tanks[#out.tanks + 1] = { kind = k, unit = M.UNIT[k], have = math.floor(have[k] * 10 + 0.5) / 10,
        cap = math.floor(cap[k] * 10 + 0.5) / 10 }
    end
  end
  return out
end

-- A station's own price factor, fixed by its id (0.94 to 1.06).
function M.stationFactor(id)
  local h = 7
  for i = 1, #tostring(id or '') do h = (h * 31 + tostring(id):byte(i)) % 1000003 end
  return 1 - M.STATION_SPREAD + (h % 1001) / 1000 * 2 * M.STATION_SPREAD
end

function M.price(kind, factor)
  return math.floor(M.PRICE[kind] * (factor or 1) * 10 + 0.5) / 10
end

-- What a refill would take. sells: { gasoline = true, ... } the kinds on offer; factor: price factor;
-- limit: units at most (nil: full); budget: money at hand (nil: no limit); free: a company car;
-- upTo: fill each tank to this share (0..1, nil: full).
-- Returns { units = { kind = n }, cost, levels = { name = ratio }, full } or nil when nothing fits.
function M.quote(car, sells, factor, limit, budget, free, upTo)
  local f = car and car.fuel
  if type(f) ~= 'table' or type(f.tanks) ~= 'table' then return nil end
  local names = {}
  for name in pairs(f.tanks) do names[#names + 1] = name end
  table.sort(names)
  local q = { units = {}, cost = 0, levels = {}, full = true }
  local left, money, any = limit, budget, false
  for _, name in ipairs(names) do
    local t = f.tanks[name]
    if sells[t.kind] then
      local want = math.max(0, (upTo or 1) - t.ratio) * t.cap
      local price = free and 0 or M.price(t.kind, factor)
      local take = want
      if left then take = math.min(take, left) end
      if money and price > 0 then take = math.min(take, math.max(0, money) / price) end
      if take < want - 1e-6 then q.full = false end
      if take > 0.05 then
        any = true
        q.units[t.kind] = (q.units[t.kind] or 0) + take
        q.levels[name] = clamp01(t.ratio + take / t.cap)
        local cost = take * price
        q.cost = q.cost + cost
        if left then left = left - take end
        if money then money = money - cost end
      end
    end
  end
  if not any then return nil end
  q.cost = math.ceil(q.cost - 1e-6)
  for kind, n in pairs(q.units) do q.units[kind] = math.floor(n * 10 + 0.5) / 10 end
  return q
end

-- Books a quote on the car (the caller takes the money and sets the levels in the game).
function M.apply(car, quote)
  for name, ratio in pairs(quote.levels) do
    local t = car.fuel.tanks[name]
    if t then t.ratio = ratio end
  end
  car.fuel.bought = (tonumber(car.fuel.bought) or 0) + quote.cost
end

-- A refuel at one of the game's own pumps (the stock "Refuel" prompt): what the vehicle now reports above the
-- remembered levels was bought there. Returns a quote like M.quote (cost at this price factor, 0 when free) or nil.
function M.pumpQuote(car, report, factor, free)
  local f = car and car.fuel
  local seen = M.clean(report)
  if type(f) ~= 'table' or type(f.tanks) ~= 'table' or not seen then return nil end
  local q, cost, any = { units = {}, cost = 0, levels = {}, full = true }, 0, false
  for name, t in pairs(seen) do
    local known = f.tanks[name]
    local added = known and (t.ratio - known.ratio) * t.cap or 0
    if added > 0.05 then
      any = true
      q.units[t.kind] = (q.units[t.kind] or 0) + added
      q.levels[name] = t.ratio
      cost = cost + added * (free and 0 or M.price(t.kind, factor))
    end
  end
  if not any then return nil end
  q.cost = math.ceil(cost - 1e-6)
  for kind, n in pairs(q.units) do q.units[kind] = math.floor(n * 10 + 0.5) / 10 end
  return q
end

------------------------------------------------------------------------------------------ stations

local function cell(lat, lon) return math.floor(lat / M.GRID) .. '_' .. math.floor(lon / M.GRID) end

function M.index()
  return { cells = {}, count = 0, areas = {}, ids = {} }
end

local function add(idx, row, area)
  local id, lat, lon, name, kind, town = row[1], row[2], row[3], row[4], row[5], row[6]
  if type(id) ~= 'string' or not finite(lat) or not finite(lon) or math.abs(lat) > 90 or math.abs(lon) > 180
    or type(name) ~= 'string' or idx.ids[id] then return false end
  local s = { id = id, g = { lat, lon }, n = name, kind = kind == 'e' and 'electric' or 'fuel', town = town or '', area = area }
  local key = cell(lat, lon)
  idx.cells[key] = idx.cells[key] or {}
  table.insert(idx.cells[key], s)
  idx.ids[id], idx.count = true, idx.count + 1
  return true
end

-- A bundled pack: { stations = { { id, lat, lon, name, 'f' | 'e', town } } }
function M.addPack(idx, pack)
  local n = 0
  for _, row in ipairs(type(pack) == 'table' and type(pack.stations) == 'table' and pack.stations or {}) do
    if type(row) == 'table' and add(idx, row) then n = n + 1 end
  end
  return n
end

-- Stations streamed by the helper for one area (replaces that area's earlier rows).
function M.addArea(idx, key, rows)
  M.dropArea(idx, key)
  local n = 0
  for _, row in ipairs(type(rows) == 'table' and rows or {}) do
    if type(row) == 'table' and add(idx, row, key) then n = n + 1 end
  end
  idx.areas[key] = true
  return n
end

function M.dropArea(idx, key)
  if not idx.areas[key] then return end
  idx.areas[key] = nil
  for cellKey, list in pairs(idx.cells) do
    for i = #list, 1, -1 do
      if list[i].area == key then
        idx.ids[list[i].id], idx.count = nil, idx.count - 1
        table.remove(list, i)
      end
    end
    if #list == 0 then idx.cells[cellKey] = nil end
  end
end

local R = 6371.0
local function km(lat1, lon1, lat2, lon2)
  local p1, p2 = math.rad(lat1), math.rad(lat2)
  local a = math.sin((p2 - p1) / 2) ^ 2 + math.cos(p1) * math.cos(p2) * math.sin(math.rad(lon2 - lon1) / 2) ^ 2
  return 2 * R * math.asin(math.min(1, math.sqrt(a)))
end
M.km = km

-- The nearest station that sells `kind` ('fuel' or 'electric') within maxKm: station, km.
function M.nearest(idx, lat, lon, kind, maxKm)
  if not idx or not finite(lat) or not finite(lon) then return nil end
  maxKm = maxKm or 30
  local rows = math.ceil(maxKm / 111.32 / M.GRID)
  local cols = math.ceil(maxKm / (111.32 * math.max(0.2, math.cos(math.rad(lat)))) / M.GRID)
  local r0, c0 = math.floor(lat / M.GRID), math.floor(lon / M.GRID)
  local best, bestKm
  for r = r0 - rows, r0 + rows do
    for c = c0 - cols, c0 + cols do
      for _, s in ipairs(idx.cells[r .. '_' .. c] or {}) do
        if s.kind == kind then
          local d = km(lat, lon, s.g[1], s.g[2])
          if d <= maxKm and (not bestKm or d < bestKm or (d == bestKm and s.id < best.id)) then best, bestKm = s, d end
        end
      end
    end
  end
  return best, bestKm
end

-- Every station that sells `kind` between minKm and maxKm (straight km), nearest first: { { station, km } }.
function M.within(idx, lat, lon, kind, minKm, maxKm)
  local out = {}
  if not idx or not finite(lat) or not finite(lon) then return out end
  local rows = math.ceil(maxKm / 111.32 / M.GRID)
  local cols = math.ceil(maxKm / (111.32 * math.max(0.2, math.cos(math.rad(lat)))) / M.GRID)
  local r0, c0 = math.floor(lat / M.GRID), math.floor(lon / M.GRID)
  for r = r0 - rows, r0 + rows do
    for c = c0 - cols, c0 + cols do
      for _, s in ipairs(idx.cells[r .. '_' .. c] or {}) do
        if s.kind == kind then
          local d = km(lat, lon, s.g[1], s.g[2])
          if d >= minKm and d <= maxKm then out[#out + 1] = { station = s, km = d } end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.km == b.km and a.station.id < b.station.id or a.km < b.km end)
  return out
end

-- What a station kind sells.
function M.sells(stationKind)
  if stationKind == 'electric' then return { electric = true } end
  return { gasoline = true, diesel = true }
end

function M.stationKind(fuelKind)
  return fuelKind == 'electric' and 'electric' or 'fuel'
end

return M
