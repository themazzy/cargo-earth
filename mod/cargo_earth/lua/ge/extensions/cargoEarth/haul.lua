-- Freight progression and native container allocation. Parcel capacity is in slots; bulk capacity is in litres.
local M = {}

M.tiers = {
  van = { name = 'Van', minKm = 3, maxKm = 45, base = 80, rate = 11, speed = 40, slack = 12, kg = 500, parcel = 96 },
  rigid = { name = 'Rigid truck', minKm = 12, maxKm = 125, base = 120, rate = 15, speed = 50, slack = 20,
    kg = 8000, parcel = 640, bulk = 4200 },
  semi = { name = 'Articulated truck', minKm = 20, maxKm = 250, base = 300, rate = 22, speed = 55, slack = 30,
    kg = 22000, parcel = 1600, bulk = 16000 },
}
-- Pay per hour (0.3.5, Jan): courier ~450 CZK, van ~590, rigid ~850, semi ~1,250-1,700. Car prices follow courier pay,
-- so trucks are the reward for progressing without making cars nearly free.
-- A loaner runs on the company's fuel card. In your own vehicle you buy the fuel, so the job pays this much
-- more per road km (about 9, 22 and 32 L/100 km of diesel).
M.FUEL_ALLOWANCE = { van = 3, rigid = 8, semi = 12 }
M.VAN_GOAL, M.RIGID_GOAL = 5, 10
M.loaners = {
  van = { model = 'van', key = 'h15_vanster', name = 'H-Series cargo van', label = 'van' },
  rigid = { model = 'md_series', key = 'md_career_shuffleboard_cargobox', name = 'MD-Series box truck', label = 'box truck' },
  semi = { model = 'us_semi', key = 'tc82_base', name = 'T-Series tractor', label = 'tractor' },
}

local parcel = {
  pallets_general = 4, consumer_goods = 2.5, electronics = 2, furniture = 3, car_parts = 5,
  glassware = 3, food_dry = 2, beer = 4, bricks = 5,
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
  return tier == 'van' or tier == 'rigid' and unlocked ~= 'van' or tier == 'semi' and unlocked == 'semi'
end

function M.complete(career, tier)
  if not M.tiers[tier] then return end
  local previous = M.state(career).unlocked
  career.hauls = career.hauls or {}
  career.hauls[tier] = (career.hauls[tier] or 0) + 1
  local unlocked = M.state(career).unlocked
  if unlocked ~= previous then return M.tiers[unlocked].name end
end

function M.carrier(vehicle)
  if not vehicle then return end
  for _, part in pairs(vehicle.slotPartMap or {}) do
    local name = part:lower()
    if name:find('fifthwheel_top', 1, true) or name:find('upfit_fifthwheel', 1, true) then return 'semi' end
  end
  if vehicle.model == 'van' then return 'van' end
  if vehicle.model == 'md_series' or vehicle.model == 'us_semi' or vehicle.model == 'midtruck' then return 'rigid' end
end

local function material(tier, id)
  if parcel[id] then return 'parcel', parcel[id] end
  if tier == 'van' then return end
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
  -- The assigned dry-bulk trailer starts with four 800 L aggregate boxes.
  local capacity = tier == 'semi' and (kind == 'dryBulk' and 3200 or nominal) or M.capacity(rows, kind)
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
