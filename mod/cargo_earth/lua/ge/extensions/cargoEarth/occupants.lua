-- People in the seats (BeamNG 0.40's seat system, lua/ge/extensions/gameplay/seatOccupants.lua). Seats are the
-- 'occupant_generic' parts in a car's seat_occupant slots: the player sits in the driver's one, and the game can put
-- dummy people (random shirt colours, real weight) in the others. Pure rules here; gamecar makes the game calls.
local M = {}

M.PASSENGER_KG = 75      -- a seated bus passenger weighs like a person (Jan's pick)

-- Every passenger seat of the stock city bus (content/vehicles/citybus/citybus_seats.jbeam, BeamNG 0.40): most are
-- empty by default, so the lent bus gets a seat occupant part in each one. Unknown slot names are ignored by the game.
M.BUS_SEATS = {
  '1LA', '1LB', '1RA', '1RB', '2LW', '2LA', '2RW', '2RA', '3LW', '3LA', '3RW', '3RA', '4LW', '4LA', '4RW', '4RA',
  '5LA', '5LB', '5LC', '6LW', '6LA', '6RW', '6RA', '7LA', '7LB', '7LC', '7RA', '7RB', '7RC', '8LW', '8LA', '8RW',
  '8RA', '8C' }

-- Puts a seat occupant part in every passenger seat of a city bus config (its parts map, slot name -> part).
function M.fillBusSeats(config)
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return config end
  for _, id in ipairs(M.BUS_SEATS) do config.parts['seat_occupant_' .. id] = 'occupant_generic' end
  return config
end

-- A small string hash, so the same line always seats people in the same scattered order.
local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end

-- The order passengers take the seats: seats is the game's getSeats list ({ seatId, isDriver, occupantType }); the
-- driver's seat and any seat a player sits in are left out. Fixed for a seed, so the first n seats of the order are
-- who is on board and people stay where they sat as others get on and off.
function M.order(seats, seed)
  local out = {}
  for _, s in ipairs(type(seats) == 'table' and seats or {}) do
    if type(s) == 'table' and s.seatId ~= nil and not s.isDriver and s.occupantType ~= 'player' then
      out[#out + 1] = { id = tostring(s.seatId), key = hash(tostring(seed or '') .. ':' .. tostring(s.seatId)),
        dummy = s.occupantType == 'dummy' }
    end
  end
  table.sort(out, function(a, b) if a.key ~= b.key then return a.key < b.key end return a.id < b.id end)
  return out
end

-- What to change so n people sit: { add = { seatId... }, remove = { seatId... }, shown = seated count }.
function M.plan(seats, n, seed)
  local order = M.order(seats, seed)
  n = math.max(0, math.floor(tonumber(n) or 0))
  local add, remove = {}, {}
  for i, s in ipairs(order) do
    if i <= n and not s.dummy then add[#add + 1] = s.id
    elseif i > n and s.dummy then remove[#remove + 1] = s.id end
  end
  return { add = add, remove = remove, shown = math.min(n, #order) }
end

-- Whether the player should be put in a seat: the car uses the seat system, the player is in it and not seated.
-- presence: the game's getPlayerPresence(0) ({ vehicleId, seatId }) or nil.
function M.needsSeat(usesSeats, presence, vehId)
  if not usesSeats or not vehId then return false end
  if type(presence) ~= 'table' then return true end
  return presence.vehicleId ~= vehId or presence.seatId == nil
end

return M
