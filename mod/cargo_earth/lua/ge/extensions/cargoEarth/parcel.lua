-- Parcel routes: load a van or box truck at a depot, then drop parcels at several real addresses in turn. The load
-- sits in BeamNG's own parcel containers and each stop takes its share out. Pure rules: no game calls here.
local M = {}

M.TIERS = { van = { stops = { 4, 7 }, each = { 2, 6 }, radiusKm = 5 }, rigid = { stops = { 5, 8 }, each = { 8, 24 }, radiusKm = 8 } }
M.DENSITY = 2.5        -- kg per parcel slot (mixed consumer goods)
M.ROAD_FACTOR = 1.35
M.BASE, M.PER_STOP, M.PER_KM = { van = 80, rigid = 120 }, { van = 45, rigid = 70 }, { van = 10, rigid = 14 }
M.SPEED_KMH, M.STOP_MIN, M.SLACK_MIN = 30, 3, 10
M.MIN_GAP_M = 150      -- two stops of one route are at least this far apart
M.MIN_SLOTS = 8

local rad = math.pi / 180
local function km(lat1, lon1, lat2, lon2)
  local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) / 2 * rad)
  local y = (lat2 - lat1) * rad
  return math.sqrt(x * x + y * y) * 6371
end
M.km = km

-- depot: { id, n, town, g }; addresses: rows { lat, lon, curbLat, curbLon, label, town } near it; capacity: free parcel
-- slots in the vehicle's containers (nil = the tier's own). Returns a job, or nil when the area has too few addresses.
function M.route(depot, addresses, tier, capacity, rnd, n)
  local t = M.TIERS[tier]
  if not t or not depot or not depot.g then return nil end
  rnd = rnd or math.random
  -- addresses within reach, a few hundred metres from the depot and from each other
  local pool = {}
  for _, a in ipairs(addresses or {}) do
    if type(a) == 'table' and type(a[1]) == 'number' and type(a[2]) == 'number' and type(a[5]) == 'string' then
      local d = km(depot.g[1], depot.g[2], a[1], a[2])
      if d <= t.radiusKm and d >= 0.3 then pool[#pool + 1] = a end
    end
  end
  local want = t.stops[1] + rnd(t.stops[2] - t.stops[1] + 1) - 1
  local picked, tries = {}, 0
  while #picked < want and #pool > 0 and tries < 200 do
    tries = tries + 1
    local i = rnd(#pool)
    local a = table.remove(pool, i)
    local ok = true
    for _, p in ipairs(picked) do
      if km(a[1], a[2], p[1], p[2]) * 1000 < M.MIN_GAP_M then ok = false break end
    end
    if ok then picked[#picked + 1] = a end
  end
  if #picked < t.stops[1] then return nil end
  -- the order of the round: always the nearest stop next
  local stops, here, legs = {}, { depot.g[1], depot.g[2] }, 0
  while #picked > 0 do
    local best, bestD
    for i, a in ipairs(picked) do
      local d = km(here[1], here[2], a[1], a[2])
      if not bestD or d < bestD then best, bestD = i, d end
    end
    local a = table.remove(picked, best)
    legs = legs + bestD
    here = { a[1], a[2] }
    stops[#stops + 1] = { n = a[5], town = a[6] or '', g = { a[3] or a[1], a[4] or a[2] },
      slots = t.each[1] + rnd(t.each[2] - t.each[1] + 1) - 1 }
  end
  -- what does not fit the vehicle is left at the depot: drop parcels from the largest stops first
  local total = 0
  for _, s in ipairs(stops) do total = total + s.slots end
  local room = math.floor(tonumber(capacity) or math.huge)
  while total > room do
    local big = 1
    for i, s in ipairs(stops) do if s.slots > stops[big].slots then big = i end end
    if stops[big].slots <= 1 then return nil end
    stops[big].slots, total = stops[big].slots - 1, total - 1
  end
  if total < M.MIN_SLOTS then return nil end
  local road = legs * M.ROAD_FACTOR
  local pay = M.BASE[tier] + M.PER_STOP[tier] * #stops + M.PER_KM[tier] * road
  local job = {
    id = 'route:' .. tostring(depot.id) .. ':' .. tostring(n or 1) .. ':' .. #stops,
    kind = 'cargo', cargo = 'parcels', cargoName = string.format('Parcel route · %d stops', #stops),
    from = { id = depot.id, n = depot.n, town = depot.town, g = { depot.g[1], depot.g[2] }, t = depot.t },
    to = stops[1], route = { stops = stops, at = 1, total = total },
    straightKm = legs, km = road, tonnes = total * M.DENSITY / 1000,
    pay = math.floor(pay / 5 + 0.5) * 5,
    minutes = math.floor(road / M.SPEED_KMH * 60 + M.STOP_MIN * #stops + M.SLACK_MIN + 0.5),
    haul = { tier = tier, kind = 'parcel', amount = total, kg = math.floor(total * M.DENSITY + 0.5), density = M.DENSITY },
  }
  return job
end

-- Parcel slots still on board after the current stop is served (or before it, with `before`).
function M.left(job, before)
  local r = job.route
  if not r then return 0 end
  local n = 0
  for i = before and r.at or r.at + 1, #r.stops do n = n + r.stops[i].slots end
  return n
end

function M.last(job) return job.route ~= nil and job.route.at >= #job.route.stops end

-- Moves the route on to its next stop. Returns the stop just served.
function M.advance(job)
  local r = job.route
  local served = r.stops[r.at]
  r.at = r.at + 1
  job.to = r.stops[r.at]
  return served
end

-- The container loads that keep `slots` parcels on board: the first boxes of the full load stay filled.
function M.keep(plan, slots, density)
  local ids = {}
  for id in pairs(plan) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  local out, left = {}, slots * (density or M.DENSITY)
  for _, id in ipairs(ids) do
    local volume = math.min(plan[id].volume, left)
    out[id] = { volume = volume, density = plan[id].density }
    left = left - volume
  end
  return out
end

-- For the phone: { at, count, left = parcels still on board, stops = { { name, slots, done } } }
function M.state(job)
  local r = job.route
  if not r then return nil end
  local out = { at = r.at, count = #r.stops, left = M.left(job, true), stops = {} }
  for i, s in ipairs(r.stops) do
    out.stops[i] = { name = s.n, town = s.town, slots = s.slots, done = i < r.at, current = i == r.at }
  end
  return out
end

return M
