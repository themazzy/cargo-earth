-- The home garage: the spot where the player parked their career car when they set it.
local jobs = require('cargoEarth/jobs')
local M = { RADIUS = 60, ADDRESS_RADIUS = 100, CAPACITY = 3 }

function M.valid(p)
  return type(p) == 'table' and type(p.lat) == 'number' and type(p.lon) == 'number'
    and p.lat == p.lat and p.lon == p.lon and math.abs(p.lat) <= 90 and math.abs(p.lon) <= 180
end

function M.near(c, p)
  return c.home and M.valid(p) and jobs.km(p.lat, p.lon, c.home.g[1], c.home.g[2]) * 1000 <= M.RADIUS or false
end

-- The home is where the player's car is parked right now. `near` is the closest known address (food.addresses row
-- with km) or nil; it only names the place: an address within ADDRESS_RADIUS, else its town, else the coordinates.
function M.claim(c, pose, near)
  if not M.valid(pose) or pose.camera or (pose.speed or 0) > 1.5 then
    return false, 'Stop and park your car where you want your home garage.'
  end
  local name, town = string.format('%.5f, %.5f', pose.lat, pose.lon), nil
  if type(near) == 'table' and type(near.n) == 'string' then
    if type(near.km) == 'number' and near.km * 1000 <= M.ADDRESS_RADIUS then
      name, town = near.n, near.town
    elseif type(near.town) == 'string' and near.town ~= '' then
      name, town = 'Near ' .. near.town, near.town
    end
  end
  if town == '' then town = nil end
  c.home = { id = string.format('here:%.6f,%.6f', pose.lat, pose.lon), name = name, town = town,
    address = { pose.lat, pose.lon }, g = { pose.lat, pose.lon }, capacity = M.CAPACITY }
  return true, 'Home garage set here: ' .. name .. '.'
end

function M.count(g)
  local n = g.car and not g.car.loaner and 1 or 0
  for _, car in ipairs(g.parked or {}) do if not car.loaner then n = n + 1 end end
  return n
end

return M
