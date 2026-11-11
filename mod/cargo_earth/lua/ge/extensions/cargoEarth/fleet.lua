-- Drivers use parked career cars. Their runs are simulated while the career is active.
local garage = require('cargoEarth/garage')
local progress = require('cargoEarth/progress')
local M = {}

M.SHIFT_S = 600
M.HIRE_FEE = 350
M.NET_PER_SHIFT = 45
M.KM_PER_SHIFT = 3

function M.unlocked(career)
  return (tonumber(career.delivered) or 0) >= progress.DRIVER_AT
end

function M.hire(g, career, id)
  if not M.unlocked(career) then return false, 'Driver hiring unlocks at ' .. progress.DRIVER_RANK .. ' rank.' end
  local car = garage.parkedCar(g, id)
  if not car then return false, 'Choose a parked car for the driver.' end
  if car.loaner then return false, 'Drivers need a car you own.' end
  if car.driver then return false, 'This car already has a driver.' end
  if (car.parkedRepair or 0) > 0 then return false, 'Repair this car before assigning a driver.' end
  if (g.debt or 0) > 0 then return false, 'Pay off your debt before hiring.' end
  if (career.money or 0) < M.HIRE_FEE then return false, 'Not enough money to hire a driver.' end
  career.money = career.money - M.HIRE_FEE
  car.driver = { elapsed = 0, earned = 0 }
  return true, 'Driver hired for ' .. car.name .. '.'
end

function M.release(g, id)
  local car = garage.parkedCar(g, id)
  if not car or not car.driver then return false, 'There is no driver assigned to this car.' end
  car.driver = nil
  return true, car.name .. ' is available to drive.'
end

function M.advance(g, dt)
  local income = 0
  if dt <= 0 then return income end
  for _, car in ipairs(g.parked or {}) do
    local driver = car.driver
    if driver then
      local elapsed = (driver.elapsed or 0) + dt
      local shifts = math.floor(elapsed / M.SHIFT_S)
      local earned = shifts * M.NET_PER_SHIFT
      driver.elapsed = elapsed - shifts * M.SHIFT_S
      driver.earned = (driver.earned or 0) + earned
      car.km = (car.km or 0) + shifts * M.KM_PER_SHIFT
      income = income + earned
    end
  end
  if income > 0 then g.driverEarnings = (g.driverEarnings or 0) + income end
  return income
end

function M.state(g, career)
  local out = { cars = {}, hireFee = M.HIRE_FEE, pay = M.NET_PER_SHIFT, shiftMinutes = M.SHIFT_S / 60,
    rank = progress.DRIVER_RANK, at = progress.DRIVER_AT, unlocked = M.unlocked(career), earned = g.driverEarnings or 0 }
  for _, car in ipairs(g.parked or {}) do
    local driver = car.driver
    out.cars[#out.cars + 1] = { id = car.fleetId, name = car.name, km = math.floor(car.km or 0), condition = car.condition,
      storageSlots = car.storageSlots, boxCount = car.boxCount, repair = car.parkedRepair or 0, loaner = car.loaner,
      driver = driver and { earned = driver.earned or 0, nextMin = math.max(1, math.ceil((M.SHIFT_S - (driver.elapsed or 0)) / 60)) } or nil }
  end
  return out
end

return M
