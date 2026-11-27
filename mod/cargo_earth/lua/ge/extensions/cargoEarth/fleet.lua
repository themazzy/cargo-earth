-- Hired drivers: people with a speed, a level of care, the licences they hold, a kind of vehicle they know best and a
-- wage, each driving one of the firm's parked vehicles. A driver only takes a vehicle their licence covers, and the
-- vehicle has to be fit for its work (a car, an SUV or a van needs cargo boxes, a tractor one of your parked trailers).
-- Their runs are simulated while the career is active (10-minute shifts of play). What a shift brings in depends on
-- the vehicle (a car does small jobs, a tractor long hauls and needs one of your parked trailers), the driver's speed
-- and the dispatch office; the wage is paid out of it. Careless drivers wear the vehicle faster and have more
-- incidents; an incident or a breakdown leaves the vehicle waiting for a repair at the headquarters.
-- Pure rules: no game calls here.
local garage = require('cargoEarth/garage')
local progress = require('cargoEarth/progress')
local upkeep = require('cargoEarth/upkeep')
local M = {}

M.SHIFT_S = 600
M.NET_PER_SHIFT = 45       -- an average driver (wage 25) in a car: what drivers earned before 0.5
M.HIRE_FEE = 350
M.GROSS = { car = 70, suv = 90, van = 110, rigid = 170, semi = 260 }   -- CZK a shift brings in, before the wage
M.KM = { car = 8, suv = 10, van = 10, rigid = 12, semi = 15 }           -- km a shift drives
M.INCIDENT = 0.03          -- chance a shift ends in an incident for an average driver (care 1)
M.INCIDENT_COST = { car = 150, suv = 180, van = 210, rigid = 420, semi = 600 }   -- 2026-11-22: 40 % less, as repairs
-- Licences: every driver may drive cars, SUVs and vans; some also hold a truck licence (box trucks), and some of those
-- an articulated one (tractors). Each one adds to the wage.
M.LICENCES = {
  { id = 'car', name = 'Car', covers = { car = true, suv = true, van = true }, wage = 0 },
  { id = 'truck', name = 'Truck', covers = { rigid = true }, wage = 10, chance = 0.45 },
  { id = 'artic', name = 'Articulated', covers = { semi = true }, wage = 15, chance = 0.5 },   -- of the truck holders
}
M.KNOWS_BONUS = 1.15       -- a driver brings in this much more in the kind of vehicle they know best
M.KINDS = { car = 'cars', suv = 'SUVs and pickups', van = 'vans', rigid = 'box trucks', semi = 'tractors' }
M.APPLICANTS = 3           -- people looking for work at a time
M.APPLICANT_MIN = 20       -- minutes of play before a new list of applicants
M.SPEED = { 0.8, 1.25 }
M.CARE = { 0.75, 1.25 }
-- (first names from many countries: players drive everywhere)
M.NAMES = { 'Ana', 'Ben', 'Chen', 'Dara', 'Elif', 'Femi', 'Gita', 'Hugo', 'Ines', 'Jonas', 'Kofi', 'Lena', 'Marek',
  'Nadia', 'Omar', 'Pia', 'Quinn', 'Rosa', 'Sami', 'Tomás', 'Uma', 'Viktor', 'Wen', 'Yara', 'Zoe', 'Aiko', 'Bruno',
  'Carmen', 'Dmitri', 'Eva', 'Farah', 'Goran', 'Hana', 'Ivo', 'Jana', 'Kai', 'Leila', 'Mateo', 'Nina', 'Oskar' }
M.INITIALS = 'ABCDEFGHJKLMNOPRSTVWZ'

-- Only a firm with a headquarters employs drivers. (Drivers hired before 0.4 keep working.)
function M.unlocked(career)
  return type(career.firm) == 'table' and career.firm.hq ~= nil
end

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end
local function between(r, rnd) return r[1] + (r[2] - r[1]) * rnd() end

-- A skilled driver asks for more: 15 to 70 CZK a shift, and more for each truck licence.
function M.wage(speed, care, licences)
  local s = (speed - M.SPEED[1]) / (M.SPEED[2] - M.SPEED[1])
  local k = (care - M.CARE[1]) / (M.CARE[2] - M.CARE[1])
  local extra = 0
  for _, l in ipairs(M.LICENCES) do
    if type(licences) == 'table' and licences[l.id] then extra = extra + l.wage end
  end
  return round5(15 + 30 * s + 25 * k + extra)
end

-- May this driver take a vehicle of this kind (car, suv, van, rigid, semi)?
function M.licensed(driver, kind)
  local held = type(driver) == 'table' and driver.licences
  for _, l in ipairs(M.LICENCES) do
    if l.covers[kind] and type(held) == 'table' and held[l.id] then return true end
  end
  return false
end

function M.licenceFor(kind)
  for _, l in ipairs(M.LICENCES) do if l.covers[kind] then return l end end
end

-- The licence names a driver holds, for the screen.
function M.licenceNames(driver)
  local out = {}
  for _, l in ipairs(M.LICENCES) do
    if type(driver) == 'table' and type(driver.licences) == 'table' and driver.licences[l.id] then out[#out + 1] = l.name end
  end
  return out
end

function M.applicant(rnd, n)
  rnd = rnd or math.random
  local speed = math.floor(between(M.SPEED, rnd) * 100 + 0.5) / 100
  local care = math.floor(between(M.CARE, rnd) * 100 + 0.5) / 100
  local i = math.floor(rnd() * #M.NAMES) + 1
  local j = math.floor(rnd() * #M.INITIALS) + 1
  local licences = { car = true }
  if rnd() < M.LICENCES[2].chance then
    licences.truck = true
    if rnd() < M.LICENCES[3].chance then licences.artic = true end
  end
  -- the kind of vehicle they know best, among those they may drive
  local kinds = { 'car', 'suv', 'van' }
  if licences.truck then kinds[#kinds + 1] = 'rigid' end
  if licences.artic then kinds[#kinds + 1] = 'semi' end
  local knows = kinds[math.min(#kinds, math.floor(rnd() * #kinds) + 1)]
  return { id = 'a' .. tostring(n or 1), name = M.NAMES[math.min(i, #M.NAMES)] .. ' ' .. M.INITIALS:sub(j, j) .. '.',
    speed = speed, care = care, licences = licences, knows = knows, wage = M.wage(speed, care, licences) }
end

-- The applicants now; a new list after APPLICANT_MIN minutes of play (playMin: the career's play clock in minutes).
function M.applicants(f, playMin, rnd)
  if type(f) ~= 'table' then return {} end
  if type(f.applicants) ~= 'table' or #f.applicants == 0 or (playMin or 0) >= (f.applicantsAt or 0) + M.APPLICANT_MIN
    or (playMin or 0) < (f.applicantsAt or 0) then
    f.applicantSeq = (f.applicantSeq or 0)
    local list = {}
    for _ = 1, M.APPLICANTS do
      f.applicantSeq = f.applicantSeq + 1
      list[#list + 1] = M.applicant(rnd, f.applicantSeq)
    end
    f.applicants, f.applicantsAt = list, playMin or 0
  end
  return f.applicants
end

-- A driver from before 0.5 (no skills): an average one. A driver hired before licences holds the one for the
-- vehicle they already drive (kind), so nobody is stopped by the change.
function M.restore(driver, kind)
  if type(driver) ~= 'table' then return nil end
  driver.name = type(driver.name) == 'string' and driver.name or 'Your driver'
  driver.speed = tonumber(driver.speed) or 1
  driver.care = tonumber(driver.care) or 1
  driver.wage = tonumber(driver.wage) or 25
  if type(driver.licences) ~= 'table' then
    driver.licences = { car = true }
    if kind == 'rigid' or kind == 'semi' then driver.licences.truck = true end
    if kind == 'semi' then driver.licences.artic = true end
  end
  if not M.KINDS[driver.knows] then driver.knows = nil end
  return driver
end

function M.hire(g, career, id, applicantId)
  if not career.firm then return false, 'Start a firm before hiring drivers (Menu → Firm).' end
  if not M.unlocked(career) then return false, 'Choose your firm’s headquarters before hiring drivers.' end
  local car = garage.parkedCar(g, id)
  if not car then return false, 'Choose a parked vehicle for the driver.' end
  if car.loaner then return false, 'Drivers need a vehicle you own.' end
  if car.driver then return false, 'This vehicle already has a driver.' end
  if garage.parkedRepairCost(car) > 0 then return false, 'Repair this vehicle before assigning a driver.' end
  if (g.debt or 0) > 0 then return false, 'Pay off your debt before hiring.' end
  if (career.money or 0) < M.HIRE_FEE then return false, 'Not enough money to hire a driver.' end
  local list, pick, index = career.firm.applicants or {}, nil, nil
  for i, a in ipairs(list) do if a.id == applicantId then pick, index = a, i end end
  if not pick then pick, index = list[1], 1 end
  if not pick then return false, 'Nobody is looking for work right now.' end
  local kind = upkeep.tier(car)
  M.restore(pick, 'car')
  if not M.licensed(pick, kind) then
    return false, string.format('%s has no %s licence for %s.', pick.name, M.licenceFor(kind).name:lower(), car.name)
  end
  career.money = career.money - M.HIRE_FEE
  table.remove(list, index)
  car.driver = { name = pick.name, speed = pick.speed, care = pick.care, wage = pick.wage, licences = pick.licences,
    knows = pick.knows, elapsed = 0, earned = 0, km = 0, shifts = 0 }
  return true, string.format('%s now drives %s.', pick.name, car.name)
end

function M.release(g, id)
  local car = garage.parkedCar(g, id)
  if not car or not car.driver then return false, 'There is no driver assigned to this vehicle.' end
  local name = car.driver.name or 'The driver'
  car.driver = nil
  return true, string.format('%s has left. %s is available to drive.', name, car.name)
end

-- A trailer of yours for a hired tractor driver: one parked at the headquarters or at home (the pool is shared with
-- you, cargoEarth/trailerpool), that can haul freight and needs no repair. used: trailers already taken this round.
-- What a shift earns with each trailer family (2026-11-27, own trailers part 3): the box trailer is the reference;
-- a flatbed, a reefer or a tanker earns more (heavier or fussier cargo). A drawbar trailer behind a box truck about
-- doubles what the box truck carries.
M.FAMILY_PAY = { box = 1, reefer = 1.15, flatbed = 1.1, log = 1.05, container = 1.1, tanker = 1.2, foodtanker = 1.15 }
M.DRAWBAR_PAY = 1.45
local function trailerFor(career, used, pulls)
  local pool = require('cargoEarth/trailerpool')
  local best, bestPay
  for _, t in ipairs(type(career) == 'table' and pool.list(career) or {}) do
    local e = pool.entry(t)
    if (t.place == 'hq' or t.place == 'home') and e and M.FAMILY_PAY[e.family] and e.pulls == pulls
      and (t.repair or 0) <= 0 and not used[t] then
      local pay = M.FAMILY_PAY[e.family]
      if not bestPay or pay > bestPay then best, bestPay = t, pay end   -- the best-paying free trailer goes first
    end
  end
  return best
end

-- The pay factor of the trailer a car took this round (1 without one).
function M.trailerPay(car, used)
  local pool = require('cargoEarth/trailerpool')
  for t, by in pairs(used or {}) do
    if by == car then
      local e = pool.entry(t)
      if e and e.pulls == 'pintle' then return M.DRAWBAR_PAY end
      return e and M.FAMILY_PAY[e.family] or 1
    end
  end
  return 1
end

-- What a shift of this driver in a vehicle of this kind brings in after the wage (an estimate, without incidents).
function M.netFor(driver, kind, factor)
  local knows = driver.knows == kind and M.KNOWS_BONUS or 1
  return math.floor((M.GROSS[kind] or M.GROSS.car) * (driver.speed or 1) * knows * (tonumber(factor) or 1) + 0.5)
    - (driver.wage or 0)
end
function M.net(driver, car, factor) return M.netFor(driver, upkeep.tier(car), factor) end

-- Why a driver cannot work right now, or nil. used: trailers already taken this round.
local function blocked(car, career, used, driver)
  local kind = upkeep.tier(car)
  if not M.licensed(driver, kind) then return 'licence' end
  -- a car, an SUV or a van needs cargo boxes (known once you have driven it: boxCount 0 means none fitted)
  if (kind == 'car' or kind == 'suv' or kind == 'van') and car.boxCount == 0 then return 'boxes' end
  if garage.parkedRepairCost(car) > 0 then return 'repair' end
  if kind == 'semi' then
    local t = trailerFor(career, used, 'semi')
    if not t then return 'trailer' end
    used[t] = car
  elseif kind == 'rigid' then
    local t = trailerFor(career, used, 'pintle')   -- a drawbar trailer when one is free (optional)
    if t then used[t] = car end
  end
end

-- factor: the dispatch office (1 = none). Returns the income of the shifts that ended, and what happened
-- ({ text } list: incidents, breakdowns).
function M.advance(g, dt, factor, career, rnd)
  rnd = rnd or math.random
  local income, events, used = 0, {}, {}
  if dt <= 0 then return income, events end
  for _, car in ipairs(g.parked or {}) do
    local driver = M.restore(car.driver, upkeep.tier(car))
    if driver then
      driver.waiting = blocked(car, career, used, driver)
      if not driver.waiting then
        local elapsed = (driver.elapsed or 0) + dt
        local shifts = math.floor(elapsed / M.SHIFT_S)
        driver.elapsed = elapsed - shifts * M.SHIFT_S
        local tier = upkeep.tier(car)
        for _ = 1, shifts do
          local net = M.net(driver, car, (tonumber(factor) or 1) * M.trailerPay(car, used))
          local km = M.KM[tier] * driver.speed
          driver.earned, driver.km, driver.shifts = (driver.earned or 0) + net, (driver.km or 0) + km, (driver.shifts or 0) + 1
          car.km = (car.km or 0) + km
          upkeep.wear(car, km, 2 - driver.care)
          for t, by in pairs(used) do
            if by == car then t.km = (t.km or 0) + km upkeep.wear(t, km, 2 - driver.care) end   -- your trailer wears too
          end
          income = income + net
          local careless = (2 - driver.care) * (2 - driver.care)
          if rnd() < M.INCIDENT * careless then
            local cost = round5(M.INCIDENT_COST[tier] * (0.5 + rnd()))
            car.parkedRepair = (car.parkedRepair or 0) + cost
            events[#events + 1] = { text = string.format('%s had an accident with %s: %d CZK of repairs at the headquarters.',
              driver.name, car.name, cost) }
            driver.waiting = 'repair'
            break
          elseif rnd() < upkeep.chance(car, km) then
            local failure = upkeep.breakdown(car)
            car.parkedRepair = (car.parkedRepair or 0) + failure.cost
            upkeep.ensure(car)[failure.id] = 0
            events[#events + 1] = { text = string.format('%s broke down with %s (%s overdue): %d CZK at the headquarters.',
              driver.name, car.name, upkeep.byId[failure.id].name:lower(), failure.cost) }
            driver.waiting = 'repair'
            break
          end
        end
      end
    end
  end
  if income ~= 0 then g.driverEarnings = (g.driverEarnings or 0) + income end
  return income, events
end

function M.driverState(driver, car, factor)
  if not driver then return nil end
  M.restore(driver, upkeep.tier(car))
  return { name = driver.name, speed = driver.speed, care = driver.care, wage = driver.wage, earned = driver.earned or 0,
    licences = M.licenceNames(driver), knows = driver.knows and M.KINDS[driver.knows] or nil,
    km = math.floor(driver.km or 0), net = M.net(driver, car, factor), waiting = driver.waiting,
    nextMin = math.max(1, math.ceil((M.SHIFT_S - (driver.elapsed or 0)) / 60)) }
end

function M.state(g, career, factor)
  local out = { cars = {}, hireFee = M.HIRE_FEE, shiftMinutes = M.SHIFT_S / 60, rank = progress.DRIVER_RANK,
    at = progress.DRIVER_AT, unlocked = M.unlocked(career), firm = career.firm ~= nil, earned = g.driverEarnings or 0,
    pay = M.GROSS.car - 25 }
  for _, car in ipairs(g.parked or {}) do
    out.cars[#out.cars + 1] = { id = car.fleetId, name = car.name, km = math.floor(car.km or 0), condition = car.condition,
      storageSlots = car.storageSlots, boxCount = car.boxCount, repair = garage.parkedRepairCost(car), loaner = car.loaner,
      tier = upkeep.tier(car), driver = M.driverState(car.driver, car, factor) }
  end
  return out
end

return M
