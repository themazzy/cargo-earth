-- Taxi rides: a car's freight-mode work (Jan, 2026-11-15, in place of parcel rounds). A passenger (or a few) waits at a
-- real address near you, sits in the car (BeamNG's seat occupants, real weight) and rides to a place people take a
-- taxi to: an airport, a railway or bus station, a museum, a sight, a hotel (Jan: not to ordinary addresses).
-- A rough ride is felt: harsh jolts cost comfort, as a fragile load would, and comfort sets the pay, the tip and the
-- stars. Pure rules: no game calls here.
local M = {}

M.NEAR_KM = 1.5          -- the passenger waits this close to you (straight km)
M.KM = { 1.5, 12 }       -- straight km of the ride
M.ROAD_FACTOR = 1.3
M.PEOPLE = { 1, 3 }
M.BASE, M.PER_KM = 50, 18
M.SPEED_KMH, M.SLACK_MIN = 35, 6
M.OFFERS = 3
M.TRIES = 8

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
-- range: the player's { nearKm, minKm, maxKm } (road km). Returns up to OFFERS rides.
function M.offers(near, sights, lat, lon, rnd, roadKm, range)
  rnd = rnd or math.random
  if type(near) ~= 'function' or type(sights) ~= 'function' or type(lat) ~= 'number' or type(lon) ~= 'number' then return {} end
  local nearKm = math.min(M.NEAR_KM, tonumber(range and range.nearKm) or M.NEAR_KM)
  local minRoad = math.max(M.KM[1] * M.ROAD_FACTOR, tonumber(range and range.minKm) or 0)
  local maxRoad = math.min(M.KM[2] * M.ROAD_FACTOR, tonumber(range and range.maxKm) or math.huge)
  if maxRoad < minRoad then return {} end
  local pool = {}
  for _, a in ipairs(near(lat, lon, nearKm) or {}) do
    local p = place(a)
    if p and km(lat, lon, a[1], a[2]) <= nearKm then pool[#pool + 1] = { p = p, a = a } end
  end
  local out, used = {}, {}
  for _ = 1, M.TRIES do
    if #out >= M.OFFERS or #pool == 0 then break end
    local pick = table.remove(pool, rnd(#pool))
    local cands = {}
    for _, d in ipairs(sights(pick.a[1], pick.a[2], minRoad / M.ROAD_FACTOR / 1.5, maxRoad) or {}) do
      if type(d) == 'table' and type(d.g) == 'table' and type(d.n) == 'string' and d.id ~= nil and not used[d.id] then
        cands[#cands + 1] = d
      end
    end
    -- the road km decides: a place whose road is outside the range is left out
    local drop, straight, road
    while #cands > 0 and not drop do
      local cand = table.remove(cands, rnd(#cands))
      local s = km(pick.a[1], pick.a[2], cand.g[1], cand.g[2])
      local r = roadKm and roadKm(pick.p.g, cand.g, math.min(s * 4 + 5, maxRoad + 1))
      if r ~= false then
        if type(r) ~= 'number' or r ~= r or r < s then r = s * M.ROAD_FACTOR end
        if r >= minRoad and r <= maxRoad then drop, straight, road = cand, s, r end
      end
    end
    if drop then
      used[drop.id] = true
      local people = M.PEOPLE[1] + rnd(M.PEOPLE[2] - M.PEOPLE[1] + 1) - 1
      local pickupKm = km(lat, lon, pick.a[1], pick.a[2])
      out[#out + 1] = {
        id = 'taxi:' .. pick.p.id .. '>' .. tostring(drop.id), kind = 'taxi', cargo = 'passengers',
        cargoName = people == 1 and 'Passenger' or (people .. ' passengers'), handling = 'Fragile',
        taxi = { people = people },
        from = pick.p, to = { id = drop.id, n = drop.n, town = drop.town or '', g = { drop.g[1], drop.g[2] } },
        straightKm = straight, km = road, pickupKm = pickupKm,
        pay = math.floor((M.BASE + M.PER_KM * road) / 5 + 0.5) * 5,
        minutes = math.floor((road + 1.3 * pickupKm) / M.SPEED_KMH * 60 + M.SLACK_MIN + 0.5),
      }
    end
  end
  return out
end

-- For the phone.
function M.info(job)
  if type(job) ~= 'table' or type(job.taxi) ~= 'table' then return nil end
  return { people = job.taxi.people }
end

return M
