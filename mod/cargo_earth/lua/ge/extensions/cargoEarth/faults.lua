-- cargoEarth/faults: used cars with worn or faulty components (Jan, 2026-11-23: more variety in used cars). A listing
-- can come with a misfiring engine, a worn clutch and gearbox, worn brakes, worn tyres or an overdue oil change. They
-- show in the listing, lower its price, and need fixing after you buy it. Every car stays driveable: the game's own
-- part condition is used with levels that keep it on the road (no blown head gasket, no seized gearbox).
--
--   engine, gearbox: BeamNG's part condition (partCondition.initConditions, integrity per part). They survive the
--                    game's reset and repair, like a real worn part; Garage > Repair fixes them at a service spot.
--   brakes:          the wheels' brake torque is lowered (re-applied after each reset), and the brake service is
--                    overdue; a brake service fixes it.
--   tyres, oil:      the service is overdue (cargoEarth/upkeep), with its breakdown risk, until serviced.
-- Pure rules: no game calls here (cargoEarth/gamecar applies them).
local M = {}

-- chance: how likely at the worst condition; lo..hi: the game's integrity (or the brake share) for a native fault.
-- (Integrity floors read from the game's powertrain code, BeamNG 0.40: an engine below 0.3 blows its head gasket,
-- a gearbox's friction grows 50x at 0, so the gearbox stays at 0.88 or more.)
M.KINDS = {
  { id = 'engine', name = 'Engine misfires', text = 'Misfires and a rough idle: less pull until it is repaired.',
    cost = 900, native = true, chance = 0.4, lo = 0.45, hi = 0.7, combustion = true },
  { id = 'gearbox', name = 'Worn clutch and gearbox', text = 'The clutch slips a little and the gearbox drags.',
    cost = 600, native = true, chance = 0.3, lo = 0.88, hi = 0.93, combustion = true },
  { id = 'brakes', name = 'Worn brakes', text = 'The car takes longer to stop until the brakes are serviced.',
    service = 'brakes', native = true, chance = 0.55, lo = 0.72, hi = 0.85 },
  { id = 'tyres', name = 'Worn tyres', text = 'Bald tyres: they can burst until they are replaced.',
    service = 'tyres', chance = 0.6 },
  { id = 'oil', name = 'Oil change overdue', text = 'The oil is old: the engine can overheat until it is changed.',
    service = 'oil', chance = 0.6, combustion = true },
}
M.MAX = 3                -- faults on one car at most
M.ANY = 0.12             -- even a car in good condition has one fault with this chance
M.PRICE_SHARE = 0.9      -- a listing is this share of its faults' repair cost cheaper
M.MIN_PRICE = 0.4        -- ... but never below this share of the price without them
M.OVERDUE = 1.05         -- a worn service item starts this many intervals used

local byId = {}
for _, k in ipairs(M.KINDS) do byId[k.id] = k end
M.byId = byId

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end
local function upkeep() return require('cargoEarth/upkeep') end

-- A small random generator from a seed, so a listing's faults do not change the market's own random numbers.
function M.seeded(seed)
  local s = math.floor(math.abs(tonumber(seed) or 1)) % 2147483647
  if s == 0 then s = 1 end
  return function()
    s = (s * 16807) % 2147483647
    return s / 2147483647
  end
end

-- An electric vehicle (the game's 'Fuel Type') has no engine, oil or clutch to wear.
function M.electric(fuel)
  return type(fuel) == 'string' and (fuel:lower():find('electric', 1, true) or fuel:lower():find('battery', 1, true)) ~= nil
end

-- The faults of a used car of this condition: a list of { id, level }. rnd for tests.
function M.plan(condition, rnd, electric)
  local w = math.max(0, math.min(1, (0.92 - (tonumber(condition) or 1)) / 0.6))
  local eligible, out = {}, {}
  for _, k in ipairs(M.KINDS) do
    if not (electric and k.combustion) then
      eligible[#eligible + 1] = k
      if #out < M.MAX and rnd() < k.chance * w then
        out[#out + 1] = { id = k.id, level = k.lo and math.floor((k.lo + (k.hi - k.lo) * rnd()) * 100 + 0.5) / 100 or nil }
      end
    end
  end
  if #out == 0 and #eligible > 0 and rnd() < M.ANY then
    local k = eligible[math.min(#eligible, math.floor(rnd() * #eligible) + 1)]
    out[1] = { id = k.id, level = k.lo and math.floor((k.lo + (k.hi - k.lo) * rnd()) * 100 + 0.5) / 100 or nil }
  end
  return out
end

-- What fixing one fault costs (car: { model, vclass } or a listing { model, kind }); factor: a workshop's share.
function M.cost(car, id, factor)
  local k = byId[id]
  if not k then return 0 end
  local u = upkeep()
  if k.service then return u.cost(car, k.service, factor) or 0 end
  local tierCar = type(car) == 'table' and { model = car.model, vclass = car.vclass or car.kind } or car
  return round5(k.cost * (u.TIER_COST[u.tier(tierCar)] or 1) * (factor or 1))
end

-- A listing's faults with names and what each costs to fix, and their sum.
function M.describe(listing)
  local out, sum = {}, 0
  for _, f in ipairs(type(listing.faults) == 'table' and listing.faults or {}) do
    local k = byId[f.id]
    if k then
      local cost = M.cost(listing, f.id)
      out[#out + 1] = { id = f.id, name = k.name, text = k.text, cost = cost }
      sum = sum + cost
    end
  end
  return out, sum
end

-- The listing's price with its faults: cheaper by most of what they cost to fix.
function M.price(price, listing)
  local _, sum = M.describe(listing)
  if sum <= 0 then return price end
  return math.max(round5(price * M.MIN_PRICE), round5(price - sum * M.PRICE_SHARE))
end

-- A bought car takes its listing's faults: native ones are kept on car.faults, service ones make that service due.
function M.onBuy(car, list)
  if type(list) ~= 'table' or #list == 0 then return end
  local u = upkeep()
  local s = u.ensure(car)
  for _, f in ipairs(list) do
    local k = byId[f.id]
    if k then
      if k.native then
        car.faults = car.faults or {}
        car.faults[k.id] = tonumber(f.level) or k.lo
      end
      local it = k.service and u.byId[k.service]
      if it then s[it.id] = math.max(s[it.id] or 0, it.every * M.OVERDUE) end
    end
  end
end

-- What the game applies to the car: { engine = integrity, gearbox = integrity, brakes = share } or nil.
function M.native(car)
  if type(car) ~= 'table' or type(car.faults) ~= 'table' then return nil end
  local out
  for id, level in pairs(car.faults) do
    local k = byId[id]
    if k and k.native and tonumber(level) then
      out = out or {}
      out[id] = math.max(k.lo, math.min(1, tonumber(level)))   -- never below the driveable floor
    end
  end
  return out
end

-- The faults a car has that a repair fixes (not the service ones: Service fixes those).
function M.state(car, factor)
  local out, sum = {}, 0
  for _, k in ipairs(M.KINDS) do
    if type(car) == 'table' and type(car.faults) == 'table' and car.faults[k.id] then
      local cost = M.cost(car, k.id, factor)
      out[#out + 1] = { id = k.id, name = k.name, text = k.text, cost = cost, service = k.service }
      if not k.service then sum = sum + cost end
    end
  end
  return out, sum
end

-- What repairing the car's faults costs (no workshop share): lowers what a dealer pays for it.
function M.repairCost(car)
  local _, sum = M.state(car)
  return sum
end

-- A service of `id` (oil / tyres / brakes) also fixes the fault it belongs to.
function M.serviced(car, id)
  if type(car) ~= 'table' or type(car.faults) ~= 'table' then return end
  for _, k in ipairs(M.KINDS) do
    if k.service == id then car.faults[k.id] = nil end
  end
  if not next(car.faults) then car.faults = nil end
end

-- Repairs one fault (engine or gearbox). c: the career (money); factor: the workshop's share. Returns ok, message, cost.
function M.repair(c, car, id, factor, where)
  local k = byId[id]
  if not car or type(car.faults) ~= 'table' or not car.faults[id] or not k then return false, 'Nothing to repair there.' end
  if k.service then return false, 'Service the ' .. k.service .. ' to fix that.' end
  local cost = M.cost(car, id, factor)
  if (c.money or 0) < cost then return false, string.format('Not enough money (%d CZK needed).', cost) end
  local economy = require('cargoEarth/economy')
  local label = string.format('%s: %s%s', car.name or 'Car', k.name:lower(), where and (' at ' .. where) or '')
  if not economy.post(c, -cost, 'upkeep', economy.nextId(c, 'upkeep'), label) then return false, 'The payment failed.' end
  car.faults[id] = nil
  if not next(car.faults) then car.faults = nil end
  return true, string.format('Repaired: %s, for %d CZK.', k.name:lower(), cost), cost
end

return M
