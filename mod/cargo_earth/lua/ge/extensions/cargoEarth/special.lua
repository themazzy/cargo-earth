-- Special cargo: some freight jobs carry a load that needs more care and pays more. It still travels in BeamNG's own
-- containers; what changes is how the job is judged.
--   fragile:  a box load that loses condition with every harsh moment (hard braking, accelerating or cornering)
--   chilled:  food or drink that keeps cold for a shorter time limit and spoils for every minute late
--   oversize: a big load in a truck: an escort reports every 10 s above its speed limit, each costs part of the pay
-- Pure rules: no game calls here.
local M = {}

M.CHANCE = 0.3            -- share of freight offers that are special, when the load allows one
M.KINDS = {
  fragile = { name = 'Fragile', bonus = 0.4, harshLoss = 8,
    note = 'Every harsh moment costs %d %% of the load. Brake, accelerate and corner gently.' },
  chilled = { name = 'Chilled', bonus = 0.3, timeFactor = 0.8, lateLoss = 3,
    note = 'It keeps cold for the time limit only: %d %% of the load spoils for every minute late.' },
  oversize = { name = 'Oversize', bonus = 0.5, maxKmh = 60, stepS = 10, stepLoss = 3, maxLoss = 60,
    note = 'Escorted at up to %d km/h: every %d s faster costs %d %% of the pay.' },
}
M.ORDER = { 'fragile', 'chilled', 'oversize' }
M.CHILLED = { milk = true, beer = true, food_dry = true, food_chilled = true }
M.OVERSIZE = { furniture = true, pallets_general = true, car_parts = true, machinery = true, consumer_goods = true }

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- The special loads this job could be (freight only: not parcel routes, not meals).
function M.candidates(job, tier)
  local out = {}
  if type(job) ~= 'table' or job.route or job.kind == 'food' or not job.haul then return out end
  local kind = job.haul.kind
  if kind == 'parcel' then out[#out + 1] = 'fragile' end
  if M.CHILLED[job.cargo] and (kind == 'parcel' or kind == 'fluid') then out[#out + 1] = 'chilled' end
  if M.OVERSIZE[job.cargo] and kind == 'parcel' and (tier == 'rigid' or tier == 'semi') then out[#out + 1] = 'oversize' end
  return out
end

-- Makes the job special: higher pay, the kind's rules. Returns the kind.
function M.apply(job, kind)
  local k = M.KINDS[kind]
  if not k then return nil end
  job.special = kind
  job.specialBonus = round5(job.pay * k.bonus)
  job.pay = job.pay + job.specialBonus
  if k.timeFactor then job.minutes = math.max(10, math.floor(job.minutes * k.timeFactor + 0.5)) end
  if kind == 'fragile' then job.handling = 'Fragile' end
  job.cargoCondition = 100
  return kind
end

-- Rolls whether an offer is special. rnd: math.random-like.
function M.roll(job, tier, rnd)
  rnd = rnd or math.random
  local list = M.candidates(job, tier)
  if #list == 0 or rnd() >= M.CHANCE then return nil end
  return M.apply(job, list[math.min(#list, math.floor(rnd() * #list) + 1)])
end

function M.condition(job)
  return math.max(0, math.min(100, tonumber(job.cargoCondition) or 100))
end

-- A harsh moment with a fragile load on board: it loses condition. Returns the loss (0: not fragile).
function M.harsh(job)
  if job.special ~= 'fragile' then return 0 end
  local before = M.condition(job)
  job.cargoCondition = math.max(0, before - M.KINDS.fragile.harshLoss)
  return before - job.cargoCondition
end

-- Chilled food on the road: from the time limit on it spoils by the minute. Returns the new condition.
function M.warm(job, lateMin)
  if job.special ~= 'chilled' or not lateMin or lateMin <= 0 then return M.condition(job) end
  local lost = math.floor(lateMin) * M.KINDS.chilled.lateLoss
  if lost > (job.chillLoss or 0) then
    job.cargoCondition = math.max(0, M.condition(job) - (lost - (job.chillLoss or 0)))
    job.chillLoss = lost
  end
  return M.condition(job)
end

-- An oversize load driven at kmh for dt seconds. Returns true when this call added a new escort report.
function M.speed(job, kmh, dt)
  if job.special ~= 'oversize' or not kmh or not dt or dt <= 0 then return false end
  local k = M.KINDS.oversize
  if kmh <= k.maxKmh then return false end
  local before = math.floor((job.overS or 0) / k.stepS)
  job.overS = (job.overS or 0) + dt
  return math.floor(job.overS / k.stepS) > before
end

-- The share of pay an oversize load's escort reports take off (0..maxLoss %).
function M.penalty(job)
  if job.special ~= 'oversize' then return 0 end
  local k = M.KINDS.oversize
  return math.min(k.maxLoss, math.floor((job.overS or 0) / k.stepS) * k.stepLoss)
end

-- For the phone: { kind, name, bonus, note, maxKmh, penalty }.
function M.info(job)
  local k = job and M.KINDS[job.special]
  if not k then return nil end
  local note
  if job.special == 'fragile' then note = string.format(k.note, k.harshLoss)
  elseif job.special == 'chilled' then note = string.format(k.note, k.lateLoss)
  else note = string.format(k.note, k.maxKmh, k.stepS, k.stepLoss) end
  return { kind = job.special, name = k.name, bonus = job.specialBonus, note = note, maxKmh = k.maxKmh,
    penalty = M.penalty(job) > 0 and M.penalty(job) or nil }
end

return M
