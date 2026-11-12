-- Hired drivers: people with a speed, a level of care and a wage, each driving one of the firm's parked vehicles.
-- Their runs are simulated while the career is active (10-minute shifts of play). What a shift brings in depends on
-- the vehicle (a car does small jobs, a tractor long hauls and needs one of the firm's trailers), the driver's speed
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
M.GROSS = { car = 70, van = 110, rigid = 170, semi = 260 }     -- CZK a shift brings in, before the wage
M.KM = { car = 8, van = 10, rigid = 12, semi = 15 }            -- km a shift drives
M.INCIDENT = 0.03          -- chance a shift ends in an incident for an average driver (care 1)
M.INCIDENT_COST = { car = 250, van = 350, rigid = 700, semi = 1000 }
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

-- A skilled driver asks for more: 15 to 70 CZK a shift.
function M.wage(speed, care)
  local s = (speed - M.SPEED[1]) / (M.SPEED[2] - M.SPEED[1])
  local k = (care - M.CARE[1]) / (M.CARE[2] - M.CARE[1])
  return round5(15 + 30 * s + 25 * k)
end

function M.applicant(rnd, n)
  rnd = rnd or math.random
  local speed = math.floor(between(M.SPEED, rnd) * 100 + 0.5) / 100
  local care = math.floor(between(M.CARE, rnd) * 100 + 0.5) / 100
  local i = math.floor(rnd() * #M.NAMES) + 1
  local j = math.floor(rnd() * #M.INITIALS) + 1
  return { id = 'a' .. tostring(n or 1), name = M.NAMES[math.min(i, #M.NAMES)] .. ' ' .. M.INITIALS:sub(j, j) .. '.',
    speed = speed, care = care, wage = M.wage(speed, care) }
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

-- A driver from before 0.5 (no skills): an average one.
function M.restore(driver)
  if type(driver) ~= 'table' then return nil end
  driver.name = type(driver.name) == 'string' and driver.name or 'Your driver'
  driver.speed = tonumber(driver.speed) or 1
  driver.care = tonumber(driver.care) or 1
  driver.wage = tonumber(driver.wage) or 25
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
  career.money = career.money - M.HIRE_FEE
  table.remove(list, index)
  car.driver = { name = pick.name, speed = pick.speed, care = pick.care, wage = pick.wage, elapsed = 0, earned = 0,
    km = 0, shifts = 0 }
  return true, string.format('%s now drives %s.', pick.name, car.name)
end

function M.release(g, id)
  local car = garage.parkedCar(g, id)
  if not car or not car.driver then return false, 'There is no driver assigned to this vehicle.' end
  local name = car.driver.name or 'The driver'
  car.driver = nil
  return true, string.format('%s has left. %s is available to drive.', name, car.name)
end

local function trailerFor(f, kind, used)
  for _, t in ipairs(type(f) == 'table' and f.trailers or {}) do
    if t.kind == kind and not used[t] then return t end
  end
end

-- What a shift of this driver in this vehicle brings in after the wage (an estimate, without incidents).
function M.net(driver, car, factor)
  local tier = upkeep.tier(car)
  return math.floor(M.GROSS[tier] * (driver.speed or 1) * (tonumber(factor) or 1) + 0.5) - (driver.wage or 0)
end

-- Why a driver cannot work right now, or nil. used: trailers already taken this round.
local function blocked(car, f, used)
  if garage.parkedRepairCost(car) > 0 then return 'repair' end
  if upkeep.tier(car) == 'semi' then
    local t = trailerFor(f, 'dryvan', used) or trailerFor(f, 'tanker', used) or trailerFor(f, 'flatbed', used)
    if not t then return 'trailer' end
    used[t] = true
  end
end

-- factor: the dispatch office (1 = none). Returns the income of the shifts that ended, and what happened
-- ({ text } list: incidents, breakdowns).
function M.advance(g, dt, factor, career, rnd)
  rnd = rnd or math.random
  local income, events, used = 0, {}, {}
  local f = career and career.firm
  if dt <= 0 then return income, events end
  for _, car in ipairs(g.parked or {}) do
    local driver = M.restore(car.driver)
    if driver then
      driver.waiting = blocked(car, f, used)
      if not driver.waiting then
        local elapsed = (driver.elapsed or 0) + dt
        local shifts = math.floor(elapsed / M.SHIFT_S)
        driver.elapsed = elapsed - shifts * M.SHIFT_S
        local tier = upkeep.tier(car)
        for _ = 1, shifts do
          local net = M.net(driver, car, factor)
          local km = M.KM[tier] * driver.speed
          driver.earned, driver.km, driver.shifts = (driver.earned or 0) + net, (driver.km or 0) + km, (driver.shifts or 0) + 1
          car.km = (car.km or 0) + km
          upkeep.wear(car, km, 2 - driver.care)
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
  M.restore(driver)
  return { name = driver.name, speed = driver.speed, care = driver.care, wage = driver.wage, earned = driver.earned or 0,
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
