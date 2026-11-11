-- The selected address is permanent; the player confirms the actual safe parking point on arrival.
local jobs = require('cargoEarth/jobs')
local M = { RADIUS = 60, ADDRESS_RADIUS = 100, CAPACITY = 3 }

function M.valid(p)
  return type(p) == 'table' and type(p.lat) == 'number' and type(p.lon) == 'number'
    and p.lat == p.lat and p.lon == p.lon and math.abs(p.lat) <= 90 and math.abs(p.lon) <= 180
end

function M.near(c, p)
  return c.home and M.valid(p) and jobs.km(p.lat, p.lon, c.home.g[1], c.home.g[2]) * 1000 <= M.RADIUS or false
end

function M.claim(c, address, pose)
  if not address or not address.g or not M.valid({lat = address.g[1], lon = address.g[2]}) then
    return false, 'Select an address first.'
  end
  if not M.valid(pose) or pose.camera or (pose.speed or 0) > 1.5 then return false, 'Park your car at the selected address first.' end
  if jobs.km(pose.lat, pose.lon, address.g[1], address.g[2]) * 1000 > M.ADDRESS_RADIUS then
    return false, 'Drive to the selected address, then park safely nearby.'
  end
  c.home = { id = address.id, name = address.n, town = address.town, address = { address.g[1], address.g[2] },
    g = { pose.lat, pose.lon }, capacity = M.CAPACITY }
  return true, 'Home garage set to ' .. address.n .. '.'
end

function M.count(g)
  local n = g.car and not g.car.loaner and 1 or 0
  for _, car in ipairs(g.parked or {}) do if not car.loaner then n = n + 1 end end
  return n
end

return M
