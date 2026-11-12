-- Car upkeep: oil, tyres and brakes wear with the kilometres a car drives (you, or a hired driver in it) and are
-- serviced at the firm's headquarters (its workshop takes a share off) or at any fuel station. Skipped service makes a
-- breakdown more likely: the more overdue, the likelier per kilometre. Pure rules: no game calls here.
local economy = require('cargoEarth/economy')
local M = {}

-- every: km between services (game distances: a long evening of driving is a few hundred km); cost in CZK for a car
-- (halved 2026-11-12: a used car often needs all three at once, which cost over two hours of deliveries)
M.ITEMS = {
  { id = 'oil', name = 'Oil change', every = 800, cost = 60,
    breakdown = 'The engine overheated and stopped: the oil change was overdue.' },
  { id = 'tyres', name = 'Tyres', every = 2500, cost = 300,
    breakdown = 'A worn tyre burst.' },
  { id = 'brakes', name = 'Brakes', every = 1600, cost = 175,
    breakdown = 'The worn brakes overheated: the car is not safe to drive.' },
}
M.TIER_COST = { car = 1, van = 1.3, rigid = 2.4, semi = 3.2 }  -- bigger vehicles cost more to service
M.SOON = 0.85            -- a service shows as soon due from this share of its interval
M.PER_KM = 0.004         -- breakdown chance per km for each whole interval overdue (half overdue: 0.2 % per km)
M.MAX_CHANCE = 0.5
M.ROADSIDE = 2           -- a breakdown's roadside help costs this many services of the failed item
M.ROADSIDE_FEE = 75
M.STARTER_WEAR = { oil = 0.6, tyres = 0.5, brakes = 0.4 }   -- a beat-up starter car starts with this much used

local byId = {}
for _, it in ipairs(M.ITEMS) do byId[it.id] = it end
M.byId = byId

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- The vehicle class by model: car, van, rigid (box truck) or semi (tractor).
function M.tier(car)
  local model = type(car) == 'table' and car.model or car
  if model == 'van' then return 'van' end
  if model == 'md_series' or model == 'midtruck' then return 'rigid' end
  if model == 'us_semi' then return 'semi' end
  return 'car'
end

-- km since each service, created on first use. A starter car comes worn, a used car as worn as its condition.
function M.ensure(car)
  if type(car.service) ~= 'table' then
    car.service = {}
    local used = math.max(0, math.min(0.9, 1 - (tonumber(car.condition) or 1)))
    for _, it in ipairs(M.ITEMS) do
      car.service[it.id] = (car.starter and M.STARTER_WEAR[it.id] or used) * it.every
    end
  end
  for _, it in ipairs(M.ITEMS) do
    local v = tonumber(car.service[it.id])
    car.service[it.id] = (v and v == v and v >= 0) and v or 0
  end
  return car.service
end

-- factor: how hard the car is driven (a careless hired driver wears it faster).
function M.wear(car, km, factor)
  if not car or not km or km <= 0 then return end
  local s = M.ensure(car)
  for _, it in ipairs(M.ITEMS) do s[it.id] = s[it.id] + km * (factor or 1) end
end

-- How many intervals overdue, all items together (0 = nothing overdue).
function M.overdue(car)
  local s, sum = M.ensure(car), 0
  for _, it in ipairs(M.ITEMS) do sum = sum + math.max(0, s[it.id] / it.every - 1) end
  return sum
end

function M.chance(car, km)
  return math.min(M.MAX_CHANCE, M.overdue(car) * M.PER_KM * (km or 1))
end

-- The item that fails in a breakdown: the most overdue one.
function M.worst(car)
  local s, best, bestShare = M.ensure(car), nil, 0
  for _, it in ipairs(M.ITEMS) do
    local share = s[it.id] / it.every
    if share > bestShare then best, bestShare = it, share end
  end
  return best
end

function M.cost(car, id, factor)
  local it = byId[id]
  if not it then return nil end
  return round5(it.cost * (M.TIER_COST[M.tier(car)] or 1) * (factor or 1))
end

-- { items = { { id, name, share, due, soon, cost, kmLeft } }, due = count due, dueCost = cost of what is due }
function M.state(car, factor)
  local s = M.ensure(car)
  local out = { items = {}, due = 0, dueCost = 0 }
  for _, it in ipairs(M.ITEMS) do
    local share = s[it.id] / it.every
    local row = { id = it.id, name = it.name, share = math.floor(share * 100 + 0.5) / 100, due = share >= 1,
      soon = share >= M.SOON, cost = M.cost(car, it.id, factor), kmLeft = math.max(0, math.floor(it.every - s[it.id])) }
    out.items[#out.items + 1] = row
    if row.soon then out.due, out.dueCost = out.due + 1, out.dueCost + row.cost end
  end
  return out
end

-- Service `ids` (a list, or nil for everything due or soon due). Returns ok, message, cost.
function M.service(c, car, ids, factor, where)
  if not car then return false, 'There is no car to service.' end
  local list = {}
  if ids then
    for _, id in ipairs(ids) do if byId[id] then list[#list + 1] = id end end
  else
    for _, row in ipairs(M.state(car).items) do if row.soon then list[#list + 1] = row.id end end
  end
  if #list == 0 then return false, 'Nothing needs a service yet.' end
  local cost, names = 0, {}
  for _, id in ipairs(list) do
    cost = cost + M.cost(car, id, factor)
    names[#names + 1] = byId[id].name:lower()
  end
  if (c.money or 0) < cost then return false, string.format('Not enough money (%d CZK needed).', cost) end
  local label = string.format('%s: %s%s', car.name or 'Car', table.concat(names, ', '), where and (' at ' .. where) or '')
  if not economy.post(c, -cost, 'upkeep', economy.nextId(c, 'upkeep'), label) then return false, 'The payment failed.' end
  local s = M.ensure(car)
  for _, id in ipairs(list) do s[id] = 0 end
  return true, string.format('Serviced %s (%s) for %d CZK.', car.name or 'the car', table.concat(names, ', '), cost), cost
end

-- A breakdown of the most overdue item: { id, text, cost } (what the roadside help costs).
function M.breakdown(car)
  local it = M.worst(car)
  if not it then return nil end
  return { id = it.id, text = it.breakdown, cost = round5(M.cost(car, it.id) * M.ROADSIDE + M.ROADSIDE_FEE) }
end

-- Roadside help: the failed item is serviced; what the wallet cannot cover is owed. Returns paid, owed.
function M.roadside(c, g, car, failure)
  local cost = failure.cost
  local paid = math.max(0, math.min(cost, math.floor(c.money or 0)))
  if paid > 0 then economy.post(c, -paid, 'upkeep', economy.nextId(c, 'upkeep'), 'Roadside help: ' .. byId[failure.id].name:lower()) end
  if paid < cost then g.debt = (g.debt or 0) + cost - paid end
  M.ensure(car)[failure.id] = 0
  return paid, cost - paid
end

return M
