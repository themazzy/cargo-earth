-- The home garage: the spot where the player parked their career car when they set it. A home is never needed;
-- everything it gives is a bonus at home: room for more cars, cheaper repairs, servicing and fuel there, and the
-- Rested bonus. It grows in steps (LEVELS) and each step has room for more rooms (ROOMS). Pure rules: no game calls.
local jobs = require('cargoEarth/jobs')
local economy = require('cargoEarth/economy')
local M = { RADIUS = 60, ADDRESS_RADIUS = 100, CAPACITY = 3 }

M.LEVELS = {
  -- trailers: trailer spots (Jan, 2026-11-27: the basic home has one; trailers need a home)
  { name = 'Small garage', cars = 3, rooms = 1, cost = 0, trailers = 1 },
  { name = 'Medium garage', cars = 4, rooms = 2, cost = 2500, trailers = 2 },
  { name = 'Large garage', cars = 6, rooms = 3, cost = 6000, trailers = 3 },
  { name = 'Extra large garage', cars = 8, rooms = 4, cost = 12000, trailers = 5 },
}
M.ROOMS = {
  { id = 'workshop', name = 'Workshop', cost = 1500, factor = 0.7,
    text = 'Repairs and servicing at home cost 30 % less' },
  { id = 'tank', name = 'Fuel tank', cost = 1000, factor = 0.8,
    text = 'Fill up or charge at home for 20 % less than at a station' },
  { id = 'rest', name = 'Rest room', cost = 500,
    text = 'Park at home for 3 minutes to get Rested: +10 % pay for the next hour' },
  { id = 'yard', name = 'Trailer yard', cost = 1500, spots = 2,
    text = 'Room for 2 more trailers at home' },
}
local roomById = {}
for _, r in ipairs(M.ROOMS) do roomById[r.id] = r end
M.roomById = roomById
M.REST_S = 180          -- parked at home this long (play time) to get Rested
M.RESTED_S = 3600       -- how long Rested lasts (play time)
M.RESTED_BONUS = 0.10   -- share of pay added while Rested

function M.valid(p)
  return type(p) == 'table' and type(p.lat) == 'number' and type(p.lon) == 'number'
    and p.lat == p.lat and p.lon == p.lon and math.abs(p.lat) <= 90 and math.abs(p.lon) <= 180
end

function M.near(c, p)
  return c.home and M.valid(p) and jobs.km(p.lat, p.lon, c.home.g[1], c.home.g[2]) * 1000 <= M.RADIUS or false
end

-- Old saves: a home without a level is the first step; nothing it had is taken away.
function M.restore(c)
  local h = type(c) == 'table' and c.home
  if type(h) ~= 'table' then return nil end
  local level = math.floor(tonumber(h.level) or 1)
  h.level = math.max(1, math.min(#M.LEVELS, level))
  if type(h.rooms) ~= 'table' then h.rooms = {} end
  for id in pairs(h.rooms) do if not roomById[id] then h.rooms[id] = nil end end
  h.capacity = math.max(tonumber(h.capacity) or M.CAPACITY, M.LEVELS[h.level].cars)
  h.spent = math.max(0, tonumber(h.spent) or 0)
  return h
end

-- The home is where the player's car is parked right now. `near` is the closest known address (food.addresses row
-- with km) or nil; it only names the place: an address within ADDRESS_RADIUS, else its town, else the coordinates.
-- Moving an existing home keeps its step and rooms.
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
  local old = M.restore(c)
  c.home = { id = string.format('here:%.6f,%.6f', pose.lat, pose.lon), name = name, town = town,
    address = { pose.lat, pose.lon }, g = { pose.lat, pose.lon }, capacity = M.CAPACITY,
    level = old and old.level or 1, rooms = old and old.rooms or {}, spent = old and old.spent or 0 }
  M.restore(c)
  return true, (old and 'Home garage moved here: ' or 'Home garage set here: ') .. name .. '.'
end

function M.level(c)
  local h = M.restore(c)
  return h and M.LEVELS[h.level] or nil
end

function M.has(c, id)
  local h = M.restore(c)
  return h ~= nil and h.rooms[id] == true
end

local function roomCount(h)
  local n = 0
  for _ in pairs(h.rooms) do n = n + 1 end
  return n
end

local function pay(c, cost, what)
  economy.post(c, -cost, 'home', economy.nextId(c, 'home'), what)
  c.home.spent = (c.home.spent or 0) + cost
end

function M.upgrade(c, debt)
  local h = M.restore(c)
  if not h then return false, 'Set your home garage first.' end
  local nextLevel = M.LEVELS[h.level + 1]
  if not nextLevel then return false, 'Your home is fully built.' end
  if (debt or 0) > 0 then return false, 'Pay your debt first.' end
  if (c.money or 0) < nextLevel.cost then return false, string.format('Not enough money (%d CZK needed).', nextLevel.cost) end
  pay(c, nextLevel.cost, nextLevel.name)
  h.level = h.level + 1
  h.capacity = math.max(h.capacity, nextLevel.cars)
  return true, string.format('Upgraded to %s: room for %d cars, %d trailers and %d rooms.', nextLevel.name, nextLevel.cars,
    nextLevel.trailers, nextLevel.rooms)
end

function M.build(c, id, debt)
  local h, room = M.restore(c), roomById[id]
  if not h then return false, 'Set your home garage first.' end
  if not room then return false, 'Unknown room.' end
  if h.rooms[id] then return false, room.name .. ' is already built.' end
  if roomCount(h) >= M.LEVELS[h.level].rooms then return false, 'No free room. Upgrade your home first.' end
  if (debt or 0) > 0 then return false, 'Pay your debt first.' end
  if (c.money or 0) < room.cost then return false, string.format('Not enough money (%d CZK needed).', room.cost) end
  pay(c, room.cost, room.name)
  h.rooms[id] = true
  return true, room.name .. ' built: ' .. room.text .. '.'
end

-- A room's price factor when the player is at home with it built, else nil.
function M.factorHere(c, id, p)
  return M.has(c, id) and M.near(c, p) and roomById[id].factor or nil
end

-- Rested: counts play time parked at home with a Rest room; true once it has just started.
function M.restTick(c, parkedHome, dt)
  if (c.restedLeft or 0) > 0 then c.restedLeft = math.max(0, c.restedLeft - dt) end
  if not (parkedHome and M.has(c, 'rest')) then c.restingT = nil return false end
  c.restingT = (c.restingT or 0) + dt
  if c.restingT < M.REST_S then return false end
  c.restingT = nil
  local fresh = (c.restedLeft or 0) <= 0
  c.restedLeft = M.RESTED_S
  return fresh
end

function M.rested(c)
  return (tonumber(c.restedLeft) or 0) > 0
end

function M.restedPay(c, amount)
  if not M.rested(c) then return amount, 0 end
  local extra = math.floor(amount * M.RESTED_BONUS + 0.5)
  return amount + extra, extra
end

-- Trailer spots at home: the step's, plus the Trailer yard room's.
function M.trailerSpots(c)
  local level = M.level(c)
  if not level then return 0 end
  return (level.trailers or 0) + (M.has(c, 'yard') and roomById.yard.spots or 0)
end

-- Everything the home screen shows.
function M.state(c, p, debt)
  local h = M.restore(c)
  if not h then return nil end
  local cur, nextLevel = M.LEVELS[h.level], M.LEVELS[h.level + 1]
  local out = { name = h.name, town = h.town, level = h.level, levelName = cur.name, cars = h.capacity,
    slots = cur.rooms, used = roomCount(h), here = M.near(c, p), rooms = {},
    rested = M.rested(c) and math.ceil((c.restedLeft or 0) / 60) or nil,
    resting = c.restingT and math.max(1, math.ceil((M.REST_S - c.restingT) / 60)) or nil,
    trailerSpots = M.trailerSpots(c), trailersHere = 0 }
  for _, t in ipairs(type(c.trailers) == 'table' and type(c.trailers.list) == 'table' and c.trailers.list or {}) do
    if type(t) == 'table' and t.place == 'home' then out.trailersHere = out.trailersHere + 1 end
  end
  if nextLevel then
    out.next = { name = nextLevel.name, cars = nextLevel.cars, rooms = nextLevel.rooms, cost = nextLevel.cost, trailers = nextLevel.trailers,
      can = (debt or 0) <= 0 and (c.money or 0) >= nextLevel.cost }
  end
  for i, r in ipairs(M.ROOMS) do
    out.rooms[i] = { id = r.id, name = r.name, text = r.text, cost = r.cost, built = h.rooms[r.id] == true,
      can = not h.rooms[r.id] and out.used < cur.rooms and (debt or 0) <= 0 and (c.money or 0) >= r.cost }
  end
  return out
end

function M.count(g)
  local n = g.car and not g.car.loaner and 1 or 0
  for _, car in ipairs(g.parked or {}) do if not car.loaner then n = n + 1 end end
  return n
end

return M
