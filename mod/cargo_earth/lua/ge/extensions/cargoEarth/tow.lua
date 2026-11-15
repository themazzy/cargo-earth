-- Tow jobs: a broken-down car at a real address waits for recovery. Without a car trailer of your own coupled, you
-- first borrow one at the workshop that takes the car (Jan, 2026-11-15): drive there, hitch it from the phone, fetch the
-- car and bring both back to the same workshop. The empty-trailer legs are paid at BORROW_RATE of the tow rate. At the pickup it stands by the road with your
-- trailer behind you (a car trailer behind a vehicle with a tow hitch, or a flatbed behind a tractor that takes two
-- cars); you park the trailer next to it and press Load on the phone, which puts it on the deck; you couple the trailer
-- and bring the car(s) to a workshop: your firm's headquarters, a real auto repair shop near the car, or (where no shop
-- is known) the workshop at a fuel station. The cars sit on the deck with their brakes on, not strapped down: drive
-- gently or they slide off. Damage to them costs pay.
-- Pure rules: no game calls here (the trailer and cars are spawned by cargoEarth/trailers).
local jobs = require('cargoEarth/jobs')
local M = {}

M.CLASSES = {
  light = { name = 'Car trailer', trailer = 'cartrailer', cars = 1, base = 220, rate = 14, speed = 45, slack = 15 },
  heavy = { name = 'Flatbed trailer', trailer = 'flatbed', cars = 2, base = 380, rate = 20, speed = 50, slack = 20 },
  -- Jan: the 22 ft car trailer (2.4 t) is too big and heavy for a small car. The game's Large Box Utility Trailer
  -- (490 kg, its tailgate left off: cargoEarth/trailers) takes one, behind any car with a tow hitch.
  small = { name = 'Small car trailer', trailer = 'smalltrailer', cars = 1, base = 200, rate = 13, speed = 50, slack = 15 },
}
-- stock BeamNG cars that break down (the first ones found in the game are used)
M.CARS = { 'covet', 'pessima', 'legran', 'midsize', 'fullsize', 'etk800', 'vivace', 'wendover', 'autobello', 'pigeon' }
-- the ones short, narrow and light enough for the small car trailer (floor 4.2 m x 1.9 m)
M.SMALL_CARS = { covet = true, autobello = true, pigeon = true }
M.OFFERS = 2
M.NEAR_KM = 8              -- broken-down cars this close to the player...
M.LIKELY_KM = 3            -- ...all equally likely this close, less and less likely further out
M.WORKSHOP_KM = { 3, 30 }  -- straight km from the car to a workshop
M.ON_BOARD_M = 6           -- a car this close to the trailer's centre is still on it
M.DAMAGE_PER_PCT = 60      -- this much new damage on a towed car costs 1 % of the pay
M.MAX_LOSS = 80
M.BORROW_RATE = 0.5        -- share of the tow rate paid per km of the legs to and from the workshop with no car on
M.HITCH_MINUTES = 5        -- time allowed for hitching the borrowed trailer

-- How the broken-down cars look (done by the vehicle-side cargoEarth_wreck after they spawn): a bent end, broken-off
-- parts, flat tyres. Picked from the address, so the same breakdown always looks the same.
M.WRECKS = {
  { id = 'front', name = 'Front-end crash' },
  { id = 'rear', name = 'Rear-ended' },
  { id = 'side', name = 'Side impact' },
  { id = 'rolled', name = 'Rolled over' },
  { id = 'stripped', name = 'Stripped' },
  { id = 'flat', name = 'Flat tyres' },
}
local WRECK_NAMES = {}
for _, w in ipairs(M.WRECKS) do WRECK_NAMES[w.id] = w.name end

function M.wreckFor(key, i)
  local sum = 0
  for n = 1, #key do sum = sum + key:byte(n) * n end
  return M.WRECKS[(sum + (i or 1) * 7) % #M.WRECKS + 1].id
end

-- { kind, seed } per car for the game side (trailers.spawnRoadside), or nil for a job saved before wrecks
function M.wreckPlan(job)
  local w = job and job.tow and job.tow.wrecks
  if type(w) ~= 'table' or #w == 0 then return nil end
  local key, out = tostring(job.from and job.from.id or job.id), {}
  for i, kind in ipairs(w) do
    local seed = 0
    for n = 1, #key do seed = (seed * 31 + key:byte(n)) % 2147483647 end
    out[i] = { kind, seed + i }
  end
  return out
end

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- What the player's rig can tow: 'heavy' (a tractor), 'light' (a vehicle with a tow hitch) or nil.
function M.class(tier, hitch)
  if tier == 'semi' then return 'heavy' end
  if hitch then return 'light' end
end

-- Can a rig of this class (M.class) take a tow job of this class? A tow hitch takes both car trailers.
function M.fits(rig, jobClass)
  return rig ~= nil and (rig == jobClass or (rig == 'light' and jobClass == 'small'))
end

-- The class of a job for a rig of `class` towing `model`: a small car goes on the small car trailer when it may.
-- opts.small: the small trailer is in the game and no big car trailer of your own is coupled.
function M.jobClass(class, model, opts)
  if class == 'light' and opts and opts.small and M.SMALL_CARS[model] then return 'small' end
  return class
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

-- Power check (Jan: warn only, the job can still be taken): tonnes a tow job adds behind the vehicle (trailer and
-- the cars on it), and the power per tonne of the whole rig below which the phone says the car may struggle.
M.ADDED_T = { light = 2.6, heavy = 9, small = 1.6 }
M.MIN_HP_PER_T = 20

-- Is this vehicle short on power for this class of tow job? specs = { power = hp, weight = kg } from the game's
-- vehicle list; false when the numbers are unknown (no warning then).
function M.weak(class, specs)
  if type(specs) ~= 'table' or not specs.power or not specs.weight or not M.ADDED_T[class] then return false end
  return specs.power / (specs.weight / 1000 + M.ADDED_T[class]) < M.MIN_HP_PER_T
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
-- borrow: the player has no car trailer coupled, so the job starts at the workshop with a borrowed one.
-- opts (optional): small = small cars go on the small car trailer (M.jobClass); onlySmall = only small cars (your
-- own small trailer is coupled: a big car does not fit on it).
function M.offers(class, lat, lon, addresses, workshop, models, rnd, count, roadKm, borrow, opts)
  rnd = rnd or math.random
  local out = {}
  if opts and opts.onlySmall then
    local small = {}
    for _, m in ipairs(models or {}) do if M.SMALL_CARS[m] then small[#small + 1] = m end end
    models = small
  end
  if not M.CLASSES[class] or #(models or {}) == 0 or #(addresses or {}) == 0 then return out end
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
      local wrecks = {}
      local first = models[math.max(1, math.min(#models, rnd(#models)))]
      local jobClass = M.jobClass(class, first, opts)
      local c = M.CLASSES[jobClass]
      for i = 1, c.cars do
        cars[i] = i == 1 and first or models[math.max(1, math.min(#models, rnd(#models)))]
        wrecks[i] = M.wreckFor(key, i)
      end
      local straight = jobs.km(g[1], g[2], to.g[1], to.g[2])
      local road = roadKm and roadKm(g, to.g, straight * 4 + 5)
      if type(road) ~= 'number' then road = straight * jobs.ROAD_FACTOR end   -- paid by the road when it is known
      local offer = { id = 'tow:' .. key .. ':' .. #out + 1, kind = 'tow', tow = { class = jobClass, cars = cars, wrecks = wrecks },
        from = { id = 'tow:' .. key, n = a[5] or 'Roadside', town = a[6] or '', g = g, label = 'Broken-down car' },
        to = to, cargoName = #cars > 1 and string.format('Tow %d broken-down cars', #cars) or 'Tow a broken-down car',
        trailer = c.trailer, straightKm = straight, km = road, pickupKm = pickupKm, pay = M.pay(jobClass, road),
        minutes = M.minutes(jobClass, road, pickupKm) }
      if borrow then M.borrow(offer, lat, lon) end
      out[#out + 1] = offer
    end
  end
  return out
end

-- The job starts at its workshop: the trailer is borrowed there, taken to the car empty and brought back with it.
-- The ride to the workshop and on to the car is paid at BORROW_RATE and timed.
function M.borrow(job, lat, lon)
  local c = M.CLASSES[job.tow.class]
  local toShop = jobs.km(lat, lon, job.to.g[1], job.to.g[2]) * jobs.ROAD_FACTOR
  local empty = toShop + job.km                        -- to the workshop, then from there to the car
  job.tow.borrow, job.tow.stage = true, 'shop'
  job.pickupKm, job.borrowKm = toShop, empty
  job.pay = round5(job.pay + c.rate * M.BORROW_RATE * empty)
  job.minutes = math.floor((empty + job.km) / c.speed * 60 + c.slack + M.HITCH_MINUTES + 0.5)
  return job
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
  local looks = {}
  for i, id in ipairs(job.tow.wrecks or {}) do looks[i] = WRECK_NAMES[id] end
  return { class = job.tow.class, trailer = c.name, cars = #job.tow.cars, onBoard = job.tow.onBoard,
    wreck = #looks > 0 and table.concat(looks, ', ') or nil, borrow = job.tow.borrow, stage = job.tow.stage,
    weak = job.tow.weak or nil }
end

return M
