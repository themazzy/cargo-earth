-- Freight progression and native container allocation. Parcel capacity is in slots; bulk capacity is in litres.
local M = {}

M.tiers = {
  van = { name = 'Van', minKm = 3, maxKm = 45, base = 80, rate = 11, speed = 40, slack = 12, kg = 1000, parcel = 96 },
  rigid = { name = 'Rigid truck', minKm = 12, maxKm = 125, base = 120, rate = 15, speed = 50, slack = 20,
    kg = 8000, parcel = 640, bulk = 4200 },
  semi = { name = 'Articulated truck', minKm = 20, maxKm = 250, base = 300, rate = 22, speed = 55, slack = 30,
    kg = 22000, parcel = 1600, bulk = 16000 },
  -- Small work for ordinary cars, by body: a car does short parcel routes, an SUV or a pickup parts runs. Their
  -- distances bound the settings' range filter; the jobs themselves come from cargoEarth/parcel and cargoEarth/parts.
  car = { name = 'Car', minKm = 2, maxKm = 15, base = 40, rate = 8, speed = 35, slack = 10, kg = 150, parcel = 24 },
  suv = { name = 'SUV or pickup', minKm = 5, maxKm = 40, base = 70, rate = 10, speed = 40, slack = 12, kg = 400, parcel = 48 },
}
M.SEMI_BULK_L = 12800   -- the dry-bulk trailer's 16 aggregate boxes of 800 L
M.SMALL = { car = true, suv = true }   -- these tiers take no board of company freight
-- Pay per hour (0.3.5, Jan): courier ~450 CZK, van ~590, rigid ~850, semi ~1,250-1,700. Car prices follow courier pay,
-- so trucks are the reward for progressing without making cars nearly free.
-- A loaner runs on the company's fuel card. In your own vehicle you buy the fuel, so the job pays this much
-- more per road km (about 9, 22 and 32 L/100 km of diesel).
M.FUEL_ALLOWANCE = { car = 1, suv = 2, van = 3, rigid = 8, semi = 12 }
M.VAN_GOAL, M.RIGID_GOAL = 5, 10
M.loaners = {
  van = { model = 'van', key = 'h15_vanster', name = 'H-Series cargo van', label = 'van' },
  rigid = { model = 'md_series', key = 'md_career_shuffleboard_cargobox', name = 'MD-Series box truck', label = 'box truck' },
  semi = { model = 'us_semi', key = 'tc82_base', name = 'T-Series tractor', label = 'tractor' },
  -- a city bus line (cargoEarth/bus): the stock Wentward city bus, its configuration found in the game
  bus = { model = 'citybus', name = 'city bus', label = 'city bus' },
}

-- kg per parcel slot of freight. Real loads (Jan, 2026-11-15): a van leaves with about 0.6-1 t, a box truck with 4-8 t and a
-- semi's box trailer with 10-20 t; the slots the containers hold are fixed, so the weight per slot carries it.
local parcel = {
  pallets_general = 9, consumer_goods = 7, electronics = 6, furniture = 7, car_parts = 11,
  glassware = 8, food_dry = 8, beer = 11, bricks = 14,
}
local fluid = { milk = 1.03, fuel = 0.83, chemicals = 1.25 }
local dryBulk = { gravel = 1.8, sand = 1.6, grain = 0.75, wood_chips = 0.35, fertilizer = 0.9,
  plastics = 0.6, animal_feed = 0.65, malt = 0.6, cement = 1.45 }

function M.state(career)
  local h = career.hauls or {}
  local van, rigid = h.van or 0, h.rigid or 0
  local unlocked = van >= M.VAN_GOAL and (rigid >= M.RIGID_GOAL and 'semi' or 'rigid') or 'van'
  return { van = van, rigid = rigid, semi = h.semi or 0, unlocked = unlocked, label = M.tiers[unlocked].name,
    vanGoal = M.VAN_GOAL, rigidGoal = M.RIGID_GOAL }
end

function M.allowed(career, tier)
  local unlocked = M.state(career).unlocked
  return tier == 'van' or M.SMALL[tier] == true or tier == 'rigid' and unlocked ~= 'van' or tier == 'semi' and unlocked == 'semi'
end

function M.complete(career, tier)
  if not M.tiers[tier] then return end
  local previous = M.state(career).unlocked
  career.hauls = career.hauls or {}
  career.hauls[tier] = (career.hauls[tier] or 0) + 1
  local unlocked = M.state(career).unlocked
  if unlocked ~= previous then return M.tiers[unlocked].name end
end

-- An ordinary car by its body: BeamNG lists a "Body Style" for every config (Sedan, Hatchback, SUV, Pickup...).
-- Models known to be SUVs or pickups count even when the game gives no style.
M.SUV_MODELS = { pickup = true, roamer = true, hopper = true }
local SUV_WORDS = { 'suv', 'pickup', 'pick-up', 'crossover', 'off-road', 'offroad', '4x4' }
function M.bodyClass(model, style)
  local s = type(style) == 'string' and style:lower() or ''
  for _, w in ipairs(SUV_WORDS) do
    if s:find(w, 1, true) then return 'suv' end
  end
  if s == '' and M.SUV_MODELS[model] then return 'suv' end
  return 'car'
end

-- The used-car market sorts a config (not yet spawned) by the same kinds, from what the game's vehicle list says: the
-- model, its "Body Style" and the config's name. A tractor is told by its name here (the fifth wheel is only known once
-- it has spawned). nil for what the market doesn't sell (buses and the like).
M.KIND_ORDER = { 'car', 'suv', 'van', 'rigid', 'semi' }
M.KIND_NAMES = { car = 'Car', suv = 'SUV or pickup', van = 'Van', rigid = 'Box truck', semi = 'Tractor' }
local RIGID_WORDS = { 'box', 'cargo', 'flatbed', 'dump', 'tipper', 'mixer', 'tank', 'plow', 'ramp', 'crane', 'rollback',
  'utility', 'stake', 'garbage', 'refuse' }
local NOT_SOLD = { citybus = true, unicycle = true }
function M.configClass(model, style, name)
  if type(model) ~= 'string' or NOT_SOLD[model] then return nil end
  local s = type(style) == 'string' and style:lower() or ''
  local n = type(name) == 'string' and name:lower() or ''
  if s:find('bus', 1, true) then return nil end
  local function any(words)
    for _, w in ipairs(words) do if n:find(w, 1, true) then return true end end
  end
  if model == 'us_semi' then return any(RIGID_WORDS) and 'rigid' or 'semi' end
  if s:find('semi', 1, true) or s:find('tractor', 1, true) then return 'semi' end
  if model == 'md_series' or model == 'midtruck' or s:find('box truck', 1, true) then return 'rigid' end
  if model == 'van' or (s:find('van', 1, true) and not s:find('minivan', 1, true)) then return 'van' end
  return M.bodyClass(model, style)
end

-- What kind of vehicle this is: 'semi' (a tractor), 'rigid' (a box truck), 'van', 'suv' (an SUV or a pickup) or
-- 'car'; nil without a vehicle.
function M.carrier(vehicle)
  if not vehicle then return end
  for _, part in pairs(vehicle.slotPartMap or {}) do
    local name = type(part) == 'string' and part:lower() or ''
    if name:find('fifthwheel_top', 1, true) or name:find('upfit_fifthwheel', 1, true) then return 'semi' end
  end
  if type(vehicle.model) ~= 'string' or vehicle.model == 'unicycle' then return end
  if vehicle.model == 'us_semi' then return 'rigid' end   -- no fifth wheel: a box, flatbed or dump body
  -- the same rules as the used-car market's listings (configClass), so a listing gets the work it advertises
  local kind = M.configClass(vehicle.model, vehicle.bodyStyle)
  if kind == 'semi' then return 'rigid' end
  return kind or M.bodyClass(vehicle.model, vehicle.bodyStyle)
end

local function material(tier, id)
  if parcel[id] then return 'parcel', parcel[id] end
  if tier == 'van' or M.SMALL[tier] then return end
  if fluid[id] then return 'fluid', fluid[id] end
  if dryBulk[id] then return 'dryBulk', dryBulk[id] end
end

local function available(row, kind)
  if type(row.id) ~= 'number' or (row.targetVolume or 0) > 0.01 or (row.currentVolume or 0) > 0.01 then return 0 end
  for _, cargoType in ipairs(row.cargoTypes or {}) do
    if cargoType == kind then return math.max(0, math.floor(tonumber(row.capacity) or 0)) end
  end
  return 0
end

function M.capacity(rows, kind)
  local total = 0
  for _, row in ipairs(rows or {}) do total = total + available(row, kind) end
  return total
end

function M.freight(tier, id, rows)
  local kind, density = material(tier, id)
  if not kind then return end
  local t = M.tiers[tier]
  local nominal = kind == 'parcel' and t.parcel or t.bulk
  -- The assigned dry-bulk trailer has an 800 L aggregate box in each of its 16 box slots (cargoEarth/trailers).
  local capacity = tier == 'semi' and (kind == 'dryBulk' and M.SEMI_BULK_L or nominal) or M.capacity(rows, kind)
  local amount = math.min(nominal, capacity, math.floor(t.kg / density))
  if amount < (kind == 'parcel' and 8 or 100) then return end
  return { tier = tier, kind = kind, amount = amount, kg = math.floor(amount * density + 0.5), density = density }
end

function M.options(tier, source, rows)
  local t, o = M.tiers[tier], {}
  for k, v in pairs(source or {}) do o[k] = v end
  o.requireValidatedSites = tier ~= 'van'
  o.minKm = math.max(t.minKm, math.min(t.maxKm, o.minKm or t.minKm))
  o.maxKm = math.max(t.minKm, math.min(t.maxKm, o.maxKm or t.maxKm))
  o.allowCargo = function(id) return M.freight(tier, id, rows) ~= nil end
  return o
end

function M.prepare(job, tier, rows, idx)
  local freight = M.freight(tier, job.cargo, rows)
  if not freight then return false end
  job.haul, job.kind, job.tonnes = freight, 'cargo', freight.kg / 1000
  local t = M.tiers[tier]
  local factor = idx.cargo[job.cargo].pay or 1
  local pay = (t.base + t.rate * job.km) * factor * (job.adr and 1.15 or 1)
  job.pay = math.floor(pay / 5 + 0.5) * 5
  job.minutes = math.floor((job.km + 1.3 * job.pickupKm) / t.speed * 60 + t.slack + 0.5)
  job.trailer = tier == 'semi' and (freight.kind == 'fluid' and 'tanker' or 'box') or nil
  if tier == 'semi' then
    freight.trailerName = freight.kind == 'fluid' and 'Tanker' or freight.kind == 'dryBulk' and 'Aggregate box trailer' or 'Box trailer'
  end
  return true
end

function M.plan(rows, freight)
  local left, plan = freight.amount, {}
  for _, row in ipairs(rows or {}) do
    local amount = math.min(left, available(row, freight.kind))
    if amount > 0 then
      local parcelLoad = freight.kind == 'parcel'
      plan[row.id] = { volume = parcelLoad and amount * freight.density or amount, density = parcelLoad and 1 or freight.density }
      left = left - amount
    end
    if left == 0 then return plan end
  end
end

function M.empty(plan)
  local out = {}
  for id in pairs(plan) do out[id] = { volume = 0, density = 1 } end
  return out
end

function M.reached(rows, plan, targetOnly)
  local remaining = 0
  for _ in pairs(plan) do remaining = remaining + 1 end
  for _, row in ipairs(rows or {}) do
    local load = plan[row.id]
    if load and math.abs((row.targetVolume or -1) - load.volume) < 0.1
      and (targetOnly or (math.abs((row.currentVolume or -1) - load.volume) < 0.1
        and (load.volume == 0 or math.abs((row.currentDensity or -1) - load.density) < 0.01))) then
      remaining = remaining - 1
    end
  end
  return remaining == 0
end

return M
