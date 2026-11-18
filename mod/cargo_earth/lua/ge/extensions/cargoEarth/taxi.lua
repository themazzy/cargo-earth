-- Taxi rides: passenger work in its own category. A passenger (or a few) waits at a
-- real address near you, sits in the car (BeamNG's seat occupants, real weight) and rides to a place people take a
-- taxi to: an airport, a railway or bus station, a museum, a sight, a hotel (Jan: not to ordinary addresses).
-- A rough ride is felt: harsh jolts cost comfort, as a fragile load would, and comfort sets the pay, the tip and the
-- stars. Pure rules: no game calls here.
local M = {}

M.NEAR_KM = 1.5          -- the passenger waits this close to you (straight km)
M.KM = { 1.5, 12 }       -- nominal range, converted to road km below
M.ROAD_FACTOR = 1.3
M.defaults = { nearKm = M.NEAR_KM, minKm = M.KM[1] * M.ROAD_FACTOR, maxKm = M.KM[2] * M.ROAD_FACTOR }
M.BASE, M.PER_KM = 50, 18
M.PASSENGER_BONUS = 0.20 -- each passenger after the first adds 20% to the base-and-distance fare
M.SPEED_KMH, M.SLACK_MIN = 35, 6
M.OFFERS = 3
M.TRIES = 8
M.DEST_TRIES = 16 -- road routing stays bounded even when a city has many inaccessible destinations

-- What a passenger wants (Jan, 2026-11-15). comfort: no hurry, a smooth ride is everything (rough driving costs much
-- more, a smooth one earns a big tip, speed earns nothing). rush: late for something, only speed counts (tighter time,
-- higher fare, a bigger tip for arriving early, a bigger loss per late minute; comfort is not counted at all, Jan).
-- time: share of the normal minutes; pay: fare factor; late: factor on the per-minute late loss; floor and slope: pay
-- factor = floor + slope * comfort (comfort 0-100); fastTip: factor on the speed tip; smoothTip: share of the fare
-- tipped for a ride kept at 100 % comfort; share: how often the mode comes.
M.MODES = {
  comfort = { name = 'Comfort', time = 1.3, pay = 1.0, late = 0.5, floor = 0.3, slope = 0.007, fastTip = 0, smoothTip = 0.15, share = 0.5 },
  rush = { name = 'Rush', time = 0.8, pay = 1.25, late = 2.5, floor = 1, slope = 0, fastTip = 2, smoothTip = 0, share = 0.5, speedOnly = true },
}

-- The rules of a ride's mode (an older ride without one counts as comfort).
function M.mode(job)
  local m = type(job) == 'table' and type(job.taxi) == 'table' and job.taxi.mode
  return M.MODES[m] or M.MODES.comfort, M.MODES[m] and m or 'comfort'
end

local function round5(value) return math.floor(value / 5 + 0.5) * 5 end

-- Store the accepted quote with the ride. Loading an older ride must not recalculate its agreed fare.
function M.quote(roadKm, people, mode)
  local rules = M.MODES[mode] or M.MODES.comfort
  local raw = M.BASE + M.PER_KM * roadKm
  local passengerRate = M.PASSENGER_BONUS * math.max(0, people - 1)
  local baseFare, groupFare = round5(raw), round5(raw * (1 + passengerRate))
  local fare = round5(raw * (1 + passengerRate) * rules.pay)
  return {base = M.BASE, perKm = M.PER_KM, baseFare = baseFare,
    passengerRate = passengerRate, passengerBonus = groupFare - baseFare,
    modeRate = rules.pay - 1, modeBonus = fare - groupFare, fare = fare}
end

local rad = math.pi / 180
local function km(lat1, lon1, lat2, lon2)
  local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) / 2 * rad)
  local y = (lat2 - lat1) * rad
  return math.sqrt(x * x + y * y) * 6371
end
M.km = km

-- an address row { lat, lon, curbLat, curbLon, label, town } as a place; the car stops at the curb point
local function place(a)
  if type(a) ~= 'table' or type(a[1]) ~= 'number' or type(a[2]) ~= 'number' or type(a[5]) ~= 'string' then return nil end
  local lat, lon = type(a[3]) == 'number' and a[3] or a[1], type(a[4]) == 'number' and a[4] or a[2]
  return { id = string.format('address:%.6f,%.6f', a[1], a[2]), n = a[5], town = type(a[6]) == 'string' and a[6] or '',
    g = { lat, lon } }
end

-- near(lat, lon, maxKm): address rows around a point (where passengers wait); sights(lat, lon, minKm, maxKm): the
-- places a taxi takes people to, { id, n, town, g } (airports, stations, museums, sights, hotels: the helper's 't'
-- places), nearest first; roadKm(a, b, maxKm): the real road km when known, false for a detour, nil when unknown;
-- range: the player's { nearKm, minKm, maxKm } (road km); seats: verified passenger capacity. Unknown or invalid
-- capacity offers no rides; a group can fill every usable passenger seat. Returns up to OFFERS rides.
function M.offers(near, sights, lat, lon, rnd, roadKm, range, seats)
  rnd = rnd or math.random
  local most = type(seats) == 'number' and seats == seats and seats >= 1 and seats < math.huge and math.floor(seats) or 0
  if most < 1 then return {} end
  if type(near) ~= 'function' or type(sights) ~= 'function' or type(lat) ~= 'number' or type(lon) ~= 'number' then return {} end
  local nearKm = math.min(M.NEAR_KM, tonumber(range and range.nearKm) or M.NEAR_KM)
  local minRoad = math.max(M.KM[1] * M.ROAD_FACTOR, tonumber(range and range.minKm) or 0)
  local maxRoad = math.min(M.KM[2] * M.ROAD_FACTOR, tonumber(range and range.maxKm) or math.huge)
  if maxRoad < minRoad then return {} end
  local pool = {}
  for _, a in ipairs(near(lat, lon, nearKm) or {}) do
    local p = place(a)
    if p and km(lat, lon, p.g[1], p.g[2]) <= nearKm then
      pool[#pool + 1] = {p = p, pickupKm = km(lat, lon, p.g[1], p.g[2])}
    end
  end
  local out, used = {}, {}
  for _ = 1, M.TRIES do
    if #out >= M.OFFERS or #pool == 0 then break end
    local pick = table.remove(pool, rnd(#pool))
    -- Route only sampled pickups, not every address in a densely mapped city.
    local pickupRoad = roadKm and roadKm({lat, lon}, pick.p.g, pick.pickupKm * 4 + 5)
    local pickupOK = pickupRoad ~= false
    local pickupEstimated = type(pickupRoad) ~= 'number' or pickupRoad ~= pickupRoad or pickupRoad == math.huge or pickupRoad < pick.pickupKm
    if pickupEstimated then pickupRoad = pick.pickupKm * M.ROAD_FACTOR end
    local cands = {}
    if pickupOK then
      for _, d in ipairs(sights(pick.p.g[1], pick.p.g[2], 0, maxRoad) or {}) do
        if type(d) == 'table' and type(d.g) == 'table' and type(d.n) == 'string' and d.id ~= nil and not used[d.id] then
          cands[#cands + 1] = d
        end
      end
    end
    -- the road km decides: a place whose road is outside the range is left out
    local drop, straight, road
    local tries = 0
    while #cands > 0 and not drop and tries < M.DEST_TRIES do
      tries = tries + 1
      local cand = table.remove(cands, rnd(#cands))
      local s = km(pick.p.g[1], pick.p.g[2], cand.g[1], cand.g[2])
      local r = roadKm and roadKm(pick.p.g, cand.g, math.min(s * 4 + 5, maxRoad + 1))
      if r ~= false then
        if type(r) ~= 'number' or r ~= r or r < s then r = s * M.ROAD_FACTOR end
        if r >= minRoad and r <= maxRoad then drop, straight, road = cand, s, r end
      end
    end
    if drop then
      used[drop.id] = true
      local people = rnd(most)
      local mode = rnd(100) <= M.MODES.rush.share * 100 and 'rush' or 'comfort'
      local rules = M.MODES[mode]
      local quote = M.quote(road, people, mode)
      out[#out + 1] = {
        id = 'taxi:' .. pick.p.id .. '>' .. tostring(drop.id), kind = 'taxi', cargo = 'passengers',
        cargoName = people == 1 and 'Passenger' or (people .. ' passengers'), handling = 'Fragile',
        taxi = { people = people, mode = mode, fare = quote, pickupRoadKm = pickupRoad, pickupEstimated = pickupEstimated },
        from = pick.p, to = { id = drop.id, n = drop.n, town = drop.town or '', g = { drop.g[1], drop.g[2] } },
        straightKm = straight, km = road, pickupKm = pick.pickupKm,
        pay = quote.fare,
        minutes = math.max(3, math.ceil(((road + pickupRoad) / M.SPEED_KMH * 60 + M.SLACK_MIN) * rules.time)),
      }
    end
  end
  return out
end

-- For the phone.
function M.info(job)
  if type(job) ~= 'table' or type(job.taxi) ~= 'table' then return nil end
  local rules, mode = M.mode(job)
  return { people = job.taxi.people, mode = mode, modeName = rules.name, fare = job.taxi.fare,
    pickupRoadKm = job.taxi.pickupRoadKm, pickupEstimated = job.taxi.pickupEstimated, boardingError = job.taxi.boardingError }
end

-- What a finished ride pays: fare after lateness and comfort, and the tip. fare: the ride's offered pay, minutes taken
-- and allowed, perMin: the usual share of the fare lost per late minute, floor: the least share of it, comfort 0-100,
-- fastTip(pay, minutes, limit): the speed tip (food.tip). Returns pay, tip, why ({ fast, smooth, rough = comfort %;
-- damaged repeats rough so the receipt keeps it }).
function M.settle(job, fare, minutes, limit, perMin, floor, comfort, fastTip)
  local rules = M.mode(job)
  local late = math.max(0, minutes - limit)
  local pay = fare * math.max(floor, 1 - late * perMin * rules.late)
  pay = math.floor(pay * math.min(1, rules.floor + rules.slope * comfort) + 0.5)
  local fast = rules.fastTip > 0 and fastTip and math.floor(fastTip(fare, minutes, limit) * rules.fastTip + 0.5) or 0
  local smooth = comfort >= 100 and math.floor(fare * rules.smoothTip / 5 + 0.5) * 5 or 0
  if rules.speedOnly then return pay, fast, { fast = fast > 0 or nil } end
  local tip = math.floor((fast + smooth) * comfort / 100 + 0.5)
  local rough = comfort < 100 and math.floor(comfort + 0.5) or nil
  return pay, tip, { fast = fast > 0 or nil, smooth = smooth > 0 or nil, rough = rough, damaged = rough }
end

return M
