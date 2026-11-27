local taxi = require('cargoEarth/taxi')

for _, example in ipairs({{1, 'comfort', 175}, {2, 'comfort', 210}, {5, 'comfort', 315}, {5, 'rush', 395}, {8, 'comfort', 420}, {8, 'rush', 525}}) do
  local quote = taxi.quote(10, example[1], example[2])
  assert(quote.fare == example[3], '10 km fare for ' .. example[1] .. ' passengers, ' .. example[2])
  assert(quote.baseFare + quote.passengerBonus + quote.modeBonus == quote.fare, 'displayed components sum to the quote')
end
-- a nicer car earns more: nothing up to 10 000 CZK of value, +15 % per doubling, at most +45 %
assert(taxi.carRate(nil) == 0 and taxi.carRate(4000) == 0 and taxi.carRate(10000) == 0, 'ordinary cars earn the plain fare')
assert(taxi.carRate(20000) == 0.15 and taxi.carRate(40000) == 0.3 and taxi.carRate(80000) == 0.45 and taxi.carRate(500000) == 0.45)
local old = {taxi = {people = 5, mode = 'comfort'}, pay = 321}
assert(taxi.info(old).fare == nil and old.pay == 321, 'existing agreed fares are never recalculated')

local near = function() return {{50, 14.003, 50, 14.004, 'Pickup', 'Town'}} end
local sights = function(lat, lon, minimum)
  assert(lat == 50 and lon == 14.004 and minimum == 0, 'destinations are searched from the curb without a straight-line minimum')
  return {{id = 'station', n = 'Station', g = {50, 14.01}}}
end
local pickupCalls, tripCalls = 0, 0
local function road(from, to)
  if from[2] == 14 then
    pickupCalls = pickupCalls + 1
    assert(to[2] == 14.004, 'pickup road ends at the curb')
    return 3
  end
  tripCalls = tripCalls + 1
  assert(from[2] == 14.004 and to[2] == 14.01)
  return 2.5 -- short straight-line trips can still meet the road-distance minimum
end
local offers = taxi.offers(near, sights, 50, 14, function(n) return n end, road, nil, 7)
local ride = assert(offers[1])
assert(#offers == 1 and ride.taxi.people == 7, 'a passenger van can carry a group larger than three')
assert(ride.km == 2.5 and ride.taxi.pickupRoadKm == 3 and not ride.taxi.pickupEstimated)
assert(ride.minutes == 21, 'allowance includes both road legs and rounds up')
assert(pickupCalls == 1 and tripCalls == 1)
assert(#taxi.offers(near, sights, 50, 14) == 0, 'unknown capacity offers no rides')
for _, seats in ipairs({0, -1, math.huge}) do assert(#taxi.offers(near, sights, 50, 14, nil, nil, nil, seats) == 0) end
assert(#taxi.offers(near, sights, 50, 14, nil, function(from) return from[2] ~= 14 and 2.5 or false end, nil, 7) == 0,
  'an explicitly rejected pickup detour is not offered')
local fallback = taxi.offers(near, function() return {{id = 'far', n = 'Airport', g = {50.04, 14.004}}} end,
  50, 14, function(n) return n end, nil, nil, 1)[1]
assert(fallback and fallback.taxi.pickupEstimated and math.abs(fallback.taxi.pickupRoadKm - fallback.pickupKm * 1.3) < 1e-9)

local addresses = {}
for i = 1, 1000 do addresses[i] = {50, 14.001, 50, 14.001, 'Address ' .. i} end
local routed = 0
taxi.offers(function() return addresses end, function() return {} end, 50, 14, function(n) return n end,
  function() routed = routed + 1 return nil end, nil, 7)
assert(routed == taxi.TRIES, 'only sampled pickup addresses are routed, not the entire city')
local inaccessible = {}
for i = 1, 1000 do inaccessible[i] = {id = i, n = 'Destination ' .. i, g = {50.03, 14.01}} end
routed = 0
taxi.offers(function() return addresses end, function() return inaccessible end, 50, 14, function(n) return n end,
  function(from) routed = routed + 1 return from[2] == 14 and 0.1 or false end, nil, 7)
assert(routed <= 200, 'failed destination routing cannot scan thousands of roads in one generation')

-- Exercise the actual game adapter and seat-system calls, including physical passenger mass.
local saved = {be = be, extensions = extensions, getPlayerVehicle = getPlayerVehicle,
  core_vehicle_manager = core_vehicle_manager, gameplay_seatOccupants = gameplay_seatOccupants,
  gamecar = package.loaded['cargoEarth/gamecar']}
local car = {getID = function() return 51 end}
local other = {getID = function() return 52 end}
local player = car
local seats = {{seatId = 'driver', isDriver = true, occupantType = 'player'}}
for i = 1, 7 do seats[#seats + 1] = {seatId = 'p' .. i} end
local weights, adds, failAdd, failClear = {}, 0, false, false
local function seat(id)
  for _, s in ipairs(seats) do if s.seatId == id then return s end end
  error('unknown seat')
end
be = nil
getPlayerVehicle = function() return player end
extensions = {core_vehicles = {replaceVehicle = function() return car end}}
core_vehicle_manager = {getVehicleData = function() return {} end}
gameplay_seatOccupants = {
  usesSeatSystem = function() return true end,
  getSeats = function(id) assert(id == 51) return seats end,
  setDummyOccupant = function(id, key, kg)
    assert(id == 51 and key ~= 'driver' and kg == 75)
    if failAdd then return false end
    adds, weights[key], seat(key).occupantType = adds + 1, kg, 'dummy'
  end,
  clearDummyOccupant = function(id, key)
    assert(id == 51 and key ~= 'driver')
    if failClear then error('seat system rebuilding') end
    weights[key], seat(key).occupantType = nil, nil
  end,
}
package.loaded['cargoEarth/gamecar'] = nil
local G = require('cargoEarth/gamecar')
G.spawn('van')
assert(G.freeSeats() == 7 and G.carPassengers(7, 'ride') == 7)
local mass = 0
for _, kg in pairs(weights) do mass = mass + kg end
assert(mass == 525 and adds == 7, 'seven passengers contribute 525 kg')
assert(G.carPassengers(7, 'ride') == 7 and adds == 7, 'repeated updates do not duplicate occupants or weight')
player = other
assert(G.carPassengers(2, 'ride') == nil, 'passengers never board a different vehicle')
failClear = true
assert(G.carPassengers(0) == nil, 'failed removal is reported to the caller')
failClear = false
assert(G.carPassengers(0) == 0 and next(weights) == nil, 'cleanup targets the owned vehicle after the player switches cars')
player, failAdd = car, true
assert(G.carPassengers(7, 'ride') == nil, 'a refused dummy spawn is not reported as successful boarding')
failAdd = false
assert(G.carPassengers(7, 'ride') == 7 and G.carPassengers(0) == 0)
assert(seats[1].occupantType == 'player', 'the driver is untouched')
-- Free play: a car the mod did not spawn takes passengers, and they leave it after the player switched cars.
local freeCar = {getID = function() return 51 end}
G.clearOwnership()
player = freeCar
assert(G.carPassengers(3, 'ride') == nil, 'without free play an unowned car takes no passengers')
assert(G.carPassengers(3, 'ride', true) == 3 and next(weights) ~= nil, 'free play seats passengers in the car driven')
player = other
assert(G.carPassengers(0) == 0 and next(weights) == nil, 'free play passengers leave the car they boarded')
be, extensions, getPlayerVehicle = saved.be, saved.extensions, saved.getPlayerVehicle
core_vehicle_manager, gameplay_seatOccupants = saved.core_vehicle_manager, saved.gameplay_seatOccupants
package.loaded['cargoEarth/gamecar'] = saved.gamecar
print('Taxi: group fares, road timing, seat capacity, bounded routing, physical mass and occupant cleanup passed')
