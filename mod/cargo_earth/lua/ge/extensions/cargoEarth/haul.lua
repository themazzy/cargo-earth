-- Freight progression and native container allocation. Parcel capacity is in slots; bulk capacity is in litres.
local M = {}

M.tiers = {
  van = { name = 'Van', minKm = 3, maxKm = 45, base = 150, rate = 18, speed = 40, slack = 12, kg = 1000, parcel = 96 },
  rigid = { name = 'Rigid truck', minKm = 12, maxKm = 125, base = 250, rate = 22, speed = 50, slack = 20,
    kg = 8000, parcel = 640, bulk = 4200 },
  semi = { name = 'Articulated truck', minKm = 20, maxKm = 250, base = 300, rate = 22, speed = 55, slack = 30,
    kg = 22000, parcel = 1600, bulk = 16000 },
  -- Small work for ordinary cars, by body: a car does short parcel routes, an SUV or a pickup parts runs. Their
  -- distances bound the settings' range filter; the jobs themselves come from cargoEarth/parcel and cargoEarth/parts.
  car = { name = 'Car', minKm = 2, maxKm = 15, base = 40, rate = 8, speed = 35, slack = 10, kg = 150, parcel = 24 },
  suv = { name = 'SUV or pickup', minKm = 5, maxKm = 40, base = 70, rate = 10, speed = 40, slack = 12, kg = 400, parcel = 48 },
  -- a trailer of your own behind a car, an SUV, a van or a box truck (tilt decks: hay and planks), 2026-11-27: the board
  -- is the trailer's. Its pay is measured against a 8 t load, so a 30 ft tilt deck of hay pays about like a food hour.
  -- a box truck with a drawbar trailer of your own (a pintle hook): the load goes in the trailer, so the reference load
  -- is the trailer's
  drawbar = { name = 'Box truck and trailer', minKm = 12, maxKm = 150, base = 250, rate = 22, speed = 50, slack = 20,
    kg = 9000, parcel = 1000, bulk = 8000 },
  trailer = { name = 'Car and trailer', minKm = 5, maxKm = 80, base = 150, rate = 14, speed = 45, slack = 15, kg = 8000, parcel = 0 },
}
M.SEMI_BULK_L = 12800   -- the dry-bulk trailer's 16 aggregate boxes of 800 L
M.SMALL = { car = true, suv = true }   -- these tiers take no board of company freight
-- Pay per hour (career review 2026-11-18, net of fuel): food ~500 CZK, taxi/bus ~550, parts runs ~580, own van ~720-800,
-- own box truck ~1,150, own tractor ~1,370-1,580. Each step up earns more than the one before. Car prices follow courier pay,
-- so trucks are the reward for progressing without making cars nearly free.
-- A loaner runs on the company's fuel card. In your own vehicle you buy the fuel, so the job pays this much
-- more per road km (about 9, 22 and 32 L/100 km of diesel).
M.FUEL_ALLOWANCE = { car = 1, suv = 2, van = 3, rigid = 8, semi = 12, trailer = 4, drawbar = 11 }
M.VAN_GOAL, M.RIGID_GOAL = 3, 5   -- 2026-11-18 (Jan: the first own truck took far too long): was 5, 10
M.loaners = {
  van = { model = 'van', key = 'h15_vanster', name = 'H-Series cargo van', label = 'van' },
  rigid = { model = 'md_series', key = 'md_career_shuffleboard_cargobox', name = 'MD-Series box truck', label = 'box truck' },
  semi = { model = 'us_semi', key = 'tc82_base', name = 'T-Series tractor', label = 'tractor' },
  -- a city bus line (cargoEarth/bus): the stock Wentward city bus, its configuration found in the game
  bus = { model = 'citybus', name = 'city bus', label = 'city bus' },
  -- an intercity coach ride (cargoEarth/coach): the same Wentward bus in its highway configuration (taller gearing)
  coach = { model = 'citybus', name = 'coach', label = 'coach' },
}

-- kg per parcel slot of freight. Real loads (Jan, 2026-11-15): a van leaves with about 0.6-1 t, a box truck with 4-8 t and a
-- semi's box trailer with 10-20 t; the slots the containers hold are fixed, so the weight per slot carries it.
local parcel = {
  pallets_general = 9, consumer_goods = 7, electronics = 6, furniture = 7, car_parts = 11,
  glassware = 8, food_dry = 8, beer = 11, bricks = 14,
  food_chilled = 8,   -- only in an insulated box (cargoEarth/trailerpool CHILLED_ONLY)
}
local fluid = { milk = 1.03, fuel = 0.83, chemicals = 1.25 }
local dryBulk = { gravel = 1.8, sand = 1.6, grain = 0.75, wood_chips = 0.35, fertilizer = 0.9,
  plastics = 0.6, animal_feed = 0.65, malt = 0.6, cement = 1.45 }

-- Free play ("Just drive", no career started): every vehicle class is open, nothing has to be unlocked.
function M.freePlay(career)
  local g = career.employment and career.employment.personalGarage or career.garage
  return career.play == 'free' and not (type(g) == 'table' and g.started)
end

function M.state(career)
  local h = career.hauls or {}
  local van, rigid = h.van or 0, h.rigid or 0
  local free = M.freePlay(career)
  local unlocked = (free or van >= M.VAN_GOAL) and ((free or rigid >= M.RIGID_GOAL) and 'semi' or 'rigid') or 'van'
  return { van = van, rigid = rigid, semi = h.semi or 0, unlocked = unlocked, label = M.tiers[unlocked].name,
    vanGoal = M.VAN_GOAL, rigidGoal = M.RIGID_GOAL, free = free or nil }
end

function M.allowed(career, tier)
  if tier == 'trailer' then return true end   -- car trailers from the start
  if tier == 'drawbar' then tier = 'rigid' end   -- drawbar trailers with the box truck
  local unlocked = M.state(career).unlocked
  return tier == 'van' or M.SMALL[tier] == true or tier == 'rigid' and unlocked ~= 'van' or tier == 'semi' and unlocked == 'semi'
end

function M.complete(career, tier)
  if tier == 'drawbar' then tier = 'rigid' end   -- a box truck's haul, whatever it pulls
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

local function material(tier, id, rig)
  local pool = require('cargoEarth/trailerpool')
  -- a stock load part (coils, logs, planks, a container...): only on a trailer of your own that takes it
  if rig and pool.carries(rig.entry, 'load', id) then return 'load', 1 end
  if pool.CHILLED_ONLY[id] and not (rig and pool.carries(rig.entry, 'parcel', id)) then return end
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

-- rig: the player's own trailer behind a tractor (cargoEarth/trailerpool entry + bulk mode), or nil for the trailer the
-- company or free play assigns. amount: the load picker's choice (parcel slots or litres), or nil for as much as fits.
function M.freight(tier, id, rows, rig, amount)
  local kind, density = material(tier, id, rig)
  if not kind then return end
  local t = M.tiers[tier]
  if kind == 'load' then
    -- whole stock loads: the picker's step is one of them (lightest first), its weight is the load part's
    local opts = require('cargoEarth/trailerpool').loadOptions(rig.entry, id)
    local kgs, whats = {}, {}
    for i, o in ipairs(opts) do kgs[i], whats[i] = o.kg, o.what end
    local most = #opts
    local n = most
    if amount then n = math.max(1, math.min(most, math.floor(tonumber(amount) or most))) end
    return { tier = tier, kind = 'load', amount = n, most = most, space = 0, kgCap = rig.entry.payload or t.kg,
      kg = kgs[n], density = 1, loadKg = kgs, loadWhat = whats, what = whats[n] }
  end
  local nominal = kind == 'parcel' and t.parcel or t.bulk
  local kgCap = t.kg
  -- the space the pay is measured against: the class's (your own trailer can be smaller or bigger than that)
  local tierSpace = nominal or 0
  if tier == 'semi' and kind == 'dryBulk' and not rig then tierSpace = math.min(tierSpace, M.SEMI_BULK_L) end
  local capacity
  if rig then
    local pool = require('cargoEarth/trailerpool')
    if not pool.carries(rig.entry, kind, id, rig.bulk) then return end
    capacity = pool.capacity(rig.entry, kind, rig.bulk)
    nominal = capacity
    kgCap = rig.entry.payload or kgCap
  else
    -- The assigned dry-bulk trailer has an 800 L aggregate box in each of its 16 box slots (cargoEarth/trailers).
    capacity = tier == 'semi' and (kind == 'dryBulk' and M.SEMI_BULK_L or nominal) or M.capacity(rows, kind)
  end
  if not nominal then return end
  local most = math.min(nominal, capacity, math.floor(kgCap / density))
  if most < (kind == 'parcel' and 8 or 100) then return end
  local n = most
  if amount then n = math.max(1, math.min(most, math.floor(tonumber(amount) or most))) end
  return { tier = tier, kind = kind, amount = n, most = most, space = tierSpace, kgCap = kgCap,
    kg = math.floor(n * density + 0.5), density = density }
end

function M.options(tier, source, rows, rig)
  local t, o = M.tiers[tier], {}
  for k, v in pairs(source or {}) do o[k] = v end
  o.requireValidatedSites = tier ~= 'van'
  o.minKm = math.max(0.5, math.min(800, o.minKm or t.minKm))
  o.maxKm = math.max(o.minKm, math.min(800, o.maxKm or t.maxKm))
  o.allowCargo = function(id) return M.freight(tier, id, rows, rig) ~= nil end
  return o
end

-- Load pay (Jan, 2026-11-27, own trailers): a fixed part for the trip plus a part that follows how full you load,
-- pay = (base + rate x km x (0.4 + 0.6 x fill)) x the cargo's factor. A full load pays the distance pay, a half load
-- about 70 % of it. fill = the share of the class's weight limit or of its space, whichever is higher, so light, bulky
-- cargo still pays for the room it takes; above a full class load (a big trailer of your own) it counts half, up to 1.3.
M.LOAD_PAY = { 0.4, 0.6 }
function M.fill(freight)
  local t = freight and M.tiers[freight.tier]
  if not t then return 1 end
  local space = freight.space or (freight.kind == 'parcel' and t.parcel or t.bulk or 0)
  if not freight.space and freight.tier == 'semi' and freight.kind == 'dryBulk' then space = math.min(space, M.SEMI_BULK_L) end
  local share = math.max((freight.kg or 0) / t.kg, space > 0 and (freight.amount or 0) / space or 0)
  if share > 1 then share = 1 + (share - 1) / 2 end   -- a bigger trailer than the class's earns more, at half the rate
  return math.floor(math.max(0, math.min(1.3, share)) * 100 + 0.5) / 100
end

-- The pay for a load: the distance pay scaled by fill (see above). factor: the cargo's pay factor (and dangerous goods).
function M.loadPay(tier, km, fill, factor)
  local t = M.tiers[tier]
  return math.floor((t.base + t.rate * km * (M.LOAD_PAY[1] + M.LOAD_PAY[2] * fill)) * (factor or 1) / 5 + 0.5) * 5
end

function M.prepare(job, tier, rows, idx, rig, amount)
  local freight = M.freight(tier, job.cargo, rows, rig, amount)
  if not freight then return false end
  job.haul, job.kind, job.tonnes = freight, 'cargo', freight.kg / 1000
  local t = M.tiers[tier]
  local factor = (idx.cargo[job.cargo].pay or 1) * (job.adr and 1.15 or 1)
  local fill = M.fill(freight)
  local base = math.floor((t.base + t.rate * job.km) * factor / 5 + 0.5) * 5
  job.pay = M.loadPay(tier, job.km, fill, factor)
  job.loadFill, job.loadBonus, job.loadFactor = fill, job.pay - base, factor
  job.minutes = math.floor((job.km + 1.3 * job.pickupKm) / t.speed * 60 + t.slack + 0.5)
  job.trailer = tier == 'semi' and (freight.kind == 'fluid' and 'tanker' or 'box') or nil
  if rig then job.trailer = rig.entry.family end   -- your own (its name is freight.trailerName)
  if freight.kind == 'load' then
    job.cargoName = string.format('%s (%s)', job.cargoName or job.cargo, freight.what)
  end
  if tier == 'semi' or tier == 'trailer' or tier == 'drawbar' then
    freight.trailerName = rig and rig.entry.name or (freight.kind == 'fluid' and 'Tanker' or freight.kind == 'dryBulk' and 'Aggregate box trailer' or 'Box trailer')
  end
  if rig then freight.pool, freight.bulk, freight.family = rig.id, rig.bulk or nil, rig.entry.family end
  return true
end

-- A home delivery (cargoEarth/homedeliv) on your utility or cargo trailer: its goods are the trailer's stock load
-- number job.pick. False when the trailer cannot take them.
function M.homeLoad(job, rig)
  local opts = rig and require('cargoEarth/trailerpool').homeLoads(rig.entry, job.cargo) or {}
  local o = opts[job.pick]
  if not o then return false end
  local kgs, whats = {}, {}
  for i, x in ipairs(opts) do kgs[i], whats[i] = x.kg, x.what end
  job.haul = { tier = 'trailer', kind = 'load', amount = job.pick, most = #opts, space = 0, kgCap = rig.entry.payload,
    kg = o.kg, density = 1, loadKg = kgs, loadWhat = whats, what = o.what, pool = rig.id, family = rig.entry.family,
    trailerName = rig.entry.name }
  job.tonnes, job.trailer = o.kg / 1000, rig.entry.family
  return true
end

-- The load picker: one step of the amount (a box, a bulk box, 1,000 L) and the steps that fit. nil without a load.
function M.steps(freight)
  if not freight then return nil end
  local unit = require('cargoEarth/trailerpool').unitOf(freight.kind)
  local most = freight.most or freight.amount
  local n = math.max(1, math.ceil((freight.amount or 0) / unit - 1e-6))
  return { unit = unit, n = n, max = math.max(1, math.ceil(most / unit - 1e-6)), kind = freight.kind,
    what = freight.loadWhat and freight.loadWhat[n] or nil, kg = freight.kg }
end

-- Change a job's load to n steps: its amount, weight, fill and pay change; what was added on top of the load pay
-- (fuel allowance, special cargo, resupply, reputation) stays. Returns true when it changed.
function M.setSteps(job, n)
  local f = job and job.haul
  local st = M.steps(f)
  if not st then return false end
  n = math.max(1, math.min(st.max, math.floor(tonumber(n) or st.n)))
  local amount = math.min(f.most or f.amount, n * st.unit)
  if amount == f.amount then return false end
  -- the pay as offered is the baseline: every amount is priced from it, so going back and forth never drifts
  if not job.loadPay0 then
    job.loadPay0, job.pay0, job.resupply0 = M.loadPay(f.tier, job.km, M.fill(f), job.loadFactor or 1), job.pay, job.resupplyBonus
  end
  f.amount, f.kg = amount, math.floor(amount * f.density + 0.5)
  if f.kind == 'load' and f.loadKg then
    f.kg = f.loadKg[amount] or f.kg
    local what = f.loadWhat and f.loadWhat[amount]
    if what and f.what and job.cargoName then job.cargoName = job.cargoName:gsub('%(' .. f.what:gsub('%p', '%%%0') .. '%)$', '(' .. what .. ')') end
    f.what = what or f.what
  end
  job.tonnes = f.kg / 1000
  local fill = M.fill(f)
  local after = M.loadPay(f.tier, job.km, fill, job.loadFactor or 1)
  local rep = tonumber(job.reputationPay) or 1
  local change = after - job.loadPay0
  if job.resupply and job.resupply0 then
    -- the fuel station's per-litre bonus follows the amount delivered too
    local resupply = require('cargoEarth/resupply')
    local extra = math.floor(amount * resupply.PER_LITRE / 5 + 0.5) * 5
    change = change + extra - job.resupply0
    job.resupplyBonus = extra
  end
  job.pay = math.max(5, job.pay0 + math.floor(change * rep / 5 + 0.5) * 5)
  local base = math.floor((M.tiers[f.tier].base + M.tiers[f.tier].rate * job.km) * (job.loadFactor or 1) / 5 + 0.5) * 5
  job.loadFill, job.loadBonus = fill, after - base
  if job.litres and f.kind == 'fluid' then job.litres = amount end
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
