-- Tow jobs: a broken-down car at a real address waits for recovery. At the pickup it is put on your trailer (a car
-- trailer behind a vehicle with a tow hitch, or a flatbed behind a tractor that takes two cars); you couple the trailer
-- and bring the car(s) to a workshop: your firm's headquarters, or the workshop at a fuel station. The cars sit on the
-- deck with their brakes on, not strapped down: drive gently or they slide off. Damage to them costs pay.
-- Pure rules: no game calls here (the trailer and cars are spawned by cargoEarth/trailers).
local jobs = require('cargoEarth/jobs')
local M = {}

M.CLASSES = {
  light = { name = 'Car trailer', trailer = 'cartrailer', cars = 1, base = 220, rate = 14, speed = 45, slack = 15 },
  heavy = { name = 'Flatbed trailer', trailer = 'flatbed', cars = 2, base = 380, rate = 20, speed = 50, slack = 20 },
}
-- stock BeamNG cars that break down (the first ones found in the game are used)
M.CARS = { 'covet', 'pessima', 'legran', 'midsize', 'fullsize', 'etk800', 'vivace', 'wendover' }
M.OFFERS = 2
M.NEAR_KM = 8              -- broken-down cars this close to the player...
M.LIKELY_KM = 3            -- ...all equally likely this close, less and less likely further out
M.WORKSHOP_KM = { 3, 30 }  -- straight km from the car to a workshop
M.ON_BOARD_M = 6           -- a car this close to the trailer's centre is still on it
M.DAMAGE_PER_PCT = 60      -- this much new damage on a towed car costs 1 % of the pay
M.MAX_LOSS = 80

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- What the player's rig can tow: 'heavy' (a tractor), 'light' (a vehicle with a tow hitch) or nil.
function M.class(tier, hitch)
  if tier == 'semi' then return 'heavy' end
  if hitch then return 'light' end
end

-- Does this vehicle have a tow hitch? (parts named like a hitch or a tow ball, not a delete or cover)
function M.hasHitch(vehicle)
  for _, part in pairs(type(vehicle) == 'table' and vehicle.slotPartMap or {}) do
    local name = type(part) == 'string' and part:lower() or ''
    if (name:find('hitch', 1, true) or name:find('towball', 1, true) or name:find('tow_ball', 1, true))
      and not name:find('delete', 1, true) and not name:find('cover', 1, true) and not name:find('nohitch', 1, true) then
      return true
    end
  end
  return false
end

function M.pay(class, km)
  local c = M.CLASSES[class]
  return round5((c.base + c.rate * km) * (c.cars > 1 and 1.5 or 1))
end

function M.minutes(class, km, pickupKm)
  local c = M.CLASSES[class]
  return math.floor((km + 1.3 * (pickupKm or 0)) / c.speed * 60 + c.slack + 0.5)
end

-- Tow offers. addresses: rows { lat, lon, stopLat, stopLon, label, town } near the player; workshop(lat, lon) returns
-- the delivery place for a car there (or nil); models: the car models that exist in the game; rnd(n) picks 1..n;
-- roadKm(from, to, maxKm) (optional): the road km to the workshop when the game's road graph knows it.
function M.offers(class, lat, lon, addresses, workshop, models, rnd, count, roadKm)
  rnd = rnd or math.random
  local out, c = {}, M.CLASSES[class]
  if not c or #(models or {}) == 0 or #(addresses or {}) == 0 then return out end
  local tries, used = 0, {}
  while #out < (count or M.OFFERS) and tries < 40 do
    tries = tries + 1
    local a = addresses[math.max(1, math.min(#addresses, rnd(#addresses)))]
    local g = { a[3] or a[1], a[4] or a[2] }
    local key = string.format('%.5f,%.5f', g[1], g[2])
    local pickupKm = jobs.km(lat, lon, g[1], g[2])
    -- addresses are spread evenly, so most are far out: a nearer breakdown is likelier
    local likely = pickupKm <= M.LIKELY_KM or rnd(1000) <= 1000 * (M.LIKELY_KM / pickupKm) ^ 1.5
    local to = not used[key] and pickupKm <= M.NEAR_KM and likely and workshop(g[1], g[2])
    if to then
      used[key] = true
      local cars = {}
      for i = 1, c.cars do cars[i] = models[math.max(1, math.min(#models, rnd(#models)))] end
      local straight = jobs.km(g[1], g[2], to.g[1], to.g[2])
      local road = roadKm and roadKm(g, to.g, straight * 4 + 5)
      if type(road) ~= 'number' then road = straight * jobs.ROAD_FACTOR end   -- paid by the road when it is known
      out[#out + 1] = { id = 'tow:' .. key .. ':' .. #out + 1, kind = 'tow', tow = { class = class, cars = cars },
        from = { id = 'tow:' .. key, n = a[5] or 'Roadside', town = a[6] or '', g = g, label = 'Broken-down car' },
        to = to, cargoName = #cars > 1 and string.format('Tow %d broken-down cars', #cars) or 'Tow a broken-down car',
        trailer = c.trailer, straightKm = straight, km = road, pickupKm = pickupKm, pay = M.pay(class, road),
        minutes = M.minutes(class, road, pickupKm) }
    end
  end
  return out
end

-- How many of the towed cars are still on the trailer (distances: metres from the trailer, one per car).
function M.onBoard(distances)
  local n = 0
  for _, d in ipairs(distances or {}) do if d and d <= M.ON_BOARD_M then n = n + 1 end end
  return n
end

-- The condition (0..100) of the towed cars after `damage` new damage on them.
function M.condition(damage)
  local loss = math.min(M.MAX_LOSS, math.floor(math.max(0, tonumber(damage) or 0) / M.DAMAGE_PER_PCT))
  return 100 - loss
end

-- For the phone.
function M.info(job)
  if not job or not job.tow then return nil end
  local c = M.CLASSES[job.tow.class]
  return { class = job.tow.class, trailer = c.name, cars = #job.tow.cars, onBoard = job.tow.onBoard }
end

return M
