-- Company contracts: fixed two-delivery manifests, held wages, return-to-yard settlement and reputation.
-- Vehicle spawning stays in core/gamecar; all rules here can be exercised without the game.
local jobs = require('cargoEarth/jobs')
local haul = require('cargoEarth/haul')
local economy = require('cargoEarth/economy')
local M = { SHARE = 0.8, RADIUS = 60, PREPARE_TIMEOUT = 25, INDEPENDENT_REP = 20 }
local container = { { id = 1, cargoTypes = { 'parcel' }, capacity = 96 } }

function M.board(idx, pose)
  if not idx or not pose then return {} end
  local options = { nearKm = 25, minKm = 1, maxKm = 20, count = 60, adr = false,
    allowCargo = function(id) return haul.freight('van', id, container) ~= nil end }
  -- Fixed selection for this area: opening the phone repeatedly does not reroll the quote.
  local seed = 19
  local function rnd(n) seed = (seed * 16807.0) % 2147483647 return seed % n + 1 end
  -- Query one yard at a time so a dense city cannot fill the shortlist with one job per yard.
  local near = {}
  for _, d in ipairs(idx.depots) do
    local eligible = false
    for _, id in ipairs((idx.types[d.t] or {}).produces or {}) do
      if jobs.cargoOk(idx, id, options) then eligible = true break end
    end
    if eligible and jobs.inBox(pose.lat, pose.lon, d.g, options.nearKm) then
      local km = jobs.km(pose.lat, pose.lon, d.g[1], d.g[2])
      if km <= options.nearKm then near[#near + 1] = { depot = d, km = km } end
    end
  end
  table.sort(near, function(a, b) if a.km == b.km then return a.depot.id < b.depot.id end return a.km < b.km end)
  local board = {}
  for i = 1, math.min(16, #near) do
    local one = { depots = { near[i].depot }, types = idx.types, cargo = idx.cargo, acceptors = idx.acceptors }
    options.count = 2
    local generated = jobs.generate(one, options, pose.lat, pose.lon, rnd)
    if #generated == 2 then
      local first = generated[1]
      local offer = {id = 'company:' .. first.from.id, name = 'Earth Logistics - ' .. first.from.n,
        yard = first.from, jobs = {}, gross = 0, km = 0, pickupKm = first.pickupKm, fictional = true}
      for _, j in ipairs(generated) do
        if haul.prepare(j, 'van', container, idx) then
          -- Each delivery ends with an empty drive back to the yard: the company pays those km too.
          local back = haul.tiers.van.rate * j.km * (idx.cargo[j.cargo].pay or 1)
          j.pay = math.floor((j.pay + back) / 5 + 0.5) * 5
          offer.jobs[#offer.jobs + 1] = j
          offer.gross, offer.km = offer.gross + j.pay, offer.km + j.km * 2
        end
      end
      if #offer.jobs == 2 then
        offer.wages = math.floor(offer.gross * M.SHARE + 0.5)
        offer.minutes = math.ceil(offer.km / 35 * 60 + 8)
        board[#board + 1] = offer
        if #board == 5 then break end
      end
    end
  end
  return board
end

function M.begin(c, offer, personal, companyGarage, mode, independent)
  if c.employment then return false, 'Finish or end your company contract first.' end
  if not offer or #offer.jobs ~= 2 then return false, 'Refresh the company board.' end
  local reputation = c.companies and c.companies[offer.id] and c.companies[offer.id].reputation or 0
  if independent and reputation < M.INDEPENDENT_REP then return false, 'Build 20 reputation with this company to unlock independent contracts.' end
  local shift = { id = economy.nextId(c, 'shift'), companyId = offer.id, companyName = offer.name, yard = offer.yard,
    jobs = offer.jobs, index = 1, completed = 0, failed = 0, quality = 0, vehicleDamage = 0, gross = 0, phase = independent and 'working' or 'preparing',
    personalGarage = personal, previousMode = mode, ownerOperator = independent == true, share = independent and 1 or M.SHARE }
  c.employment = shift
  return true
end

function M.nextJob(c)
  local s = c.employment
  if not s or s.phase ~= 'working' then return end
  local j = s.jobs[s.index]
  if j then j.companyShift = s.id end
  return j
end

function M.delivered(c, j, gross)
  local s = c.employment
  if not s or s.phase ~= 'working' or s.id ~= j.companyShift or s.jobs[s.index].id ~= j.id then return false end
  s.completed, s.gross, s.index = s.completed + 1, s.gross + gross, s.index + 1
  s.quality = (s.quality or (s.completed - 1) * 100) + math.max(0, math.min(100, tonumber(j.cargoCondition) or 100))
  if s.index > #s.jobs then s.phase = 'returning' end
  return true
end

function M.failed(c, j)
  local s = c.employment
  if not s or s.phase ~= 'working' or s.id ~= j.companyShift or not s.jobs[s.index] or s.jobs[s.index].id ~= j.id then return false end
  s.failed, s.index = (s.failed or 0) + 1, s.index + 1
  if s.index > #s.jobs then s.phase = 'returning' end
  return true
end

function M.damage(c, cost)
  local s = c.employment
  if not s or s.phase == 'settled' or type(cost) ~= 'number' or cost ~= cost or cost <= 0 or cost == math.huge then return end
  s.vehicleDamage = (s.vehicleDamage or 0) + cost
end

function M.reputation(s, aborted)
  local quoted = 0
  for _, j in ipairs(s.jobs) do quoted = quoted + j.pay end
  local gain = not aborted and math.floor((s.quality or s.completed * 100) / (#s.jobs * 100) * 10 + 0.5) or 0
  local damageLoss = math.min(30, math.ceil((s.vehicleDamage or 0) / math.max(1000, quoted) * 20))
  return gain - damageLoss - (s.failed or 0) * 10
end

function M.atYard(c, pose)
  local s = c.employment
  return s and pose and not pose.camera and (pose.speed or 0) <= 1.5
    and jobs.km(pose.lat, pose.lon, s.yard.g[1], s.yard.g[2]) * 1000 <= M.RADIUS or false
end

function M.settle(c, aborted)
  local s = c.employment
  if not s or s.phase == 'settled' then return false end
  if not aborted and s.phase ~= 'returning' then return false end
  local wages = math.floor(s.gross * (s.share or M.SHARE) + 0.5)
  local debt = s.personalGarage.debt or 0
  local toDebt = math.min(debt, math.floor(wages * 0.5 + 0.5))
  if not economy.post(c, wages - toDebt, 'company_wages', s.id, s.companyName) then return false end
  s.personalGarage.debt = debt - toDebt
  c.companies = c.companies or {}
  local company = c.companies[s.companyId] or { reputation = 0, shifts = 0, deliveries = 0 }
  c.companies[s.companyId] = company
  company.deliveries = company.deliveries + s.completed
  local previous = company.reputation
  if not aborted and (s.failed or 0) == 0 then company.shifts = company.shifts + 1 end
  company.reputation = math.max(0, math.min(100, previous + M.reputation(s, aborted)))
  c.lastContract = { company = s.companyName, gross = s.gross, share = s.gross - wages, wages = wages,
    toDebt = toDebt, net = wages - toDebt, completed = s.completed, failed = s.failed or 0,
    vehicleDamage = s.vehicleDamage or 0, reputationChange = company.reputation - previous,
    reputationScore = M.reputation(s, aborted), aborted = aborted == true, ownerOperator = s.ownerOperator }
  s.phase = 'settled'
  return true
end

return M
