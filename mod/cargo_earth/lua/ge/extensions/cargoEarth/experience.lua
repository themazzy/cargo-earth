-- Experience pay (Jan, 2026-11-18): every kind of work pays a little more as you do more of it. You learn the
-- routes and the customers learn your name. Driving work that took longer to unlock has a higher ceiling, so the
-- later rungs of the ladder keep growing ahead of the early ones. Pure rules: no game calls here.
local M = {}

-- [kind] = { max share of extra pay, jobs to reach it }
M.KINDS = {
  food = { max = 0.10, full = 100 },
  taxi = { max = 0.10, full = 60 },
  bus = { max = 0.10, full = 30 },
  parts = { max = 0.10, full = 40 },
  parcel = { max = 0.10, full = 30 },
  tow = { max = 0.15, full = 30 },
  van = { max = 0.15, full = 40 },
  rigid = { max = 0.20, full = 40 },
  semi = { max = 0.25, full = 40 },
  trailer = { max = 0.15, full = 40 },   -- a trailer of your own behind a car (tilt decks, home deliveries)
}

-- The work kind a job counts toward (nil: none).
function M.kind(job)
  if type(job) ~= 'table' then return nil end
  if job.kind == 'food' then return 'food' end
  if job.taxi then return 'taxi' end
  if job.bus then return 'bus' end
  if job.tow then return 'tow' end
  if job.partsRun then return 'parts' end
  if job.route and not job.route.fill then return 'parcel' end
  local tier = job.haul and job.haul.tier
  if tier and M.KINDS[tier] then return tier end
  return nil
end

function M.count(c, kind) return (type(c) == 'table' and type(c.experience) == 'table' and tonumber(c.experience[kind])) or 0 end

-- Extra pay share for this kind: grows evenly with every job up to the kind's maximum.
function M.rate(c, kind)
  local k = M.KINDS[kind]
  if not k then return 0 end
  local share = math.min(1, M.count(c, kind) / k.full)
  return math.floor(k.max * share * 100 + 0.5) / 100
end

function M.add(c, kind, n)
  if not M.KINDS[kind] or type(c) ~= 'table' then return end
  n = tonumber(n) or 1
  if n <= 0 then return end
  c.experience = type(c.experience) == 'table' and c.experience or {}
  c.experience[kind] = M.count(c, kind) + n
end

-- An offered job of your own: adds the experience bonus once.
function M.apply(c, job)
  if type(job) ~= 'table' or job.expBonus or job.companyShift then return job end
  local kind = M.kind(job)
  local rate = M.rate(c, kind)
  if rate <= 0 or not tonumber(job.pay) then return job end
  job.expRate, job.expBonus = rate, math.floor(job.pay * rate / 5 + 0.5) * 5
  job.pay = job.pay + job.expBonus
  return job
end

-- For the Progress page: { jobs, rate, max, full }.
function M.state(c, kind)
  local k = M.KINDS[kind]
  if not k then return nil end
  return { jobs = M.count(c, kind), rate = M.rate(c, kind), max = k.max, full = k.full }
end

return M
