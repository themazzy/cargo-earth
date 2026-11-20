-- cargoEarth/coach: intercity coach rides. A coach leaves from a real bus station near the player (else the railway
-- station: coaches often stop there) and goes to the bus station of a far town (Natural Earth towns of 30,000 people
-- or more, data/cities.json, as long-distance freight). Stations come from the helper (/v1/stations, Overture places,
-- worldwide). A ride is a bus job (cargoEarth/bus) with two stops and `coach = true`: the company lends a Wentward bus
-- in its highway configuration at the first station, people board there and all get off at the far station, then the
-- bus is handed over and you are taken back. Pure rules plus a tick that is handed the helper call.
local jobs = require('cargoEarth/jobs')
local longhaul = require('cargoEarth/longhaul')

local M = {}
M.TOWNS = 8              -- far towns asked for at once
M.RIDES = 6              -- rides on the board
M.MOVE_KM = 40           -- pick the far towns again after moving this far
M.ORIGIN_MOVE_KM = 5     -- ask for the stations around the player again after moving this far
M.TOWN_KM = 6            -- a far town's station is this close to the town's point
M.LOADING_S, M.FAILED_S, M.LOST_S, M.IN_FLIGHT = 4, 300, 60, 2
-- The helper answers one box per point: SITE_HALF (0.12 degrees) around the point snapped to a 0.05 degree grid, so a
-- box surely covers BOX_REACH degrees around the point asked. Around the player, points BOX_STEP apart cover nearKm.
M.BOX_REACH, M.BOX_STEP = 0.095, 0.19
M.defaults = { nearKm = 15, minKm = 40, maxKm = 200 }

local function finite(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end

-- The helper's rows -> { { id, n, g = { lat, lon }, k = 'bus' | 'rail', town } }; rows that do not look right are left out.
function M.rows(data)
  local out = {}
  for _, r in ipairs(type(data) == 'table' and type(data.stations) == 'table' and data.stations or {}) do
    local g = type(r) == 'table' and r.g
    if type(g) == 'table' and type(r.id) == 'string' and type(r.n) == 'string' and r.n ~= ''
      and (r.k == 'bus' or r.k == 'rail') and finite(g[1]) and finite(g[2]) and math.abs(g[1]) <= 90 and math.abs(g[2]) <= 180 then
      out[#out + 1] = { id = r.id, n = r.n, g = { g[1], g[2] }, k = r.k, s = math.max(0, math.min(2, tonumber(r.s) or 0)),
        town = type(r.town) == 'string' and r.town or '' }
    end
  end
  return out
end

-- How sure a row is a coach stop. Overture files shops and travel agencies under bus_station too, so the helper
-- says how much the name reads as a station (s: 2 bus/coach station or terminal, 1 a bus or station, 0 neither):
-- a named bus station first, then a bus stop, then a railway station, a bus_station row with an unrelated name last.
function M.rank(s)
  if s.k == 'bus' then return s.s >= 2 and 5 or s.s == 1 and 4 or 1 end
  return s.s >= 1 and 3 or 2
end

-- The station a coach uses within maxKm of a point: the surest (M.rank), the nearest of those.
function M.best(rows, lat, lon, maxKm)
  local best, bestKm, bestRank
  for _, s in ipairs(rows or {}) do
    local k = jobs.km(lat, lon, s.g[1], s.g[2])
    local r = M.rank(s)
    if k <= maxKm and (not best or r > bestRank or (r == bestRank and k < bestKm)) then
      best, bestKm, bestRank = s, k, r
    end
  end
  return best, bestKm
end

-- One step, from the helper tick. st: this module's state (kept by the caller). p: the player { lat, lon }. range:
-- the job settings { nearKm, minKm, maxKm } (road km). cities: longhaul.cities(). ask(path, onDone): the helper call.
function M.tick(st, now, p, range, cities, ask)
  if not (p and finite(p.lat) and finite(p.lon) and range) or st.old then return end
  local ringKey = string.format('%d-%d', math.floor(range.minKm or 0), math.floor(range.maxKm or 0))
  if st.ring ~= ringKey or not st.at or jobs.km(st.at.lat, st.at.lon, p.lat, p.lon) > M.MOVE_KM then
    st.ring, st.at, st.towns = ringKey, { lat = p.lat, lon = p.lon }, {}
    local picked = longhaul.pick(cities, p.lat, p.lon, range.minKm or 0, range.maxKm or 0, M.TOWNS * 3)
    st.spares = {}
    for i, c in ipairs(picked) do
      if i <= M.TOWNS then st.towns[#st.towns + 1] = { city = c, nextAt = 0 } else st.spares[#st.spares + 1] = c end
    end
  end
  local near = range.nearKm or M.defaults.nearKm
  if not st.origin or st.origin.near ~= near or jobs.km(st.origin.lat, st.origin.lon, p.lat, p.lon) > M.ORIGIN_MOVE_KM then
    st.origin = { lat = p.lat, lon = p.lon, near = near, points = M.points(p.lat, p.lon, near) }
  end
  st.pending = st.pending or {}
  local flying = 0
  for path, at in pairs(st.pending) do
    if now - at > M.LOST_S then st.pending[path] = nil else flying = flying + 1 end
  end
  -- the stations around the player first (the board needs a start; the nearest box first), then the far towns
  local wanted = {}
  for _, b in ipairs(st.origin.points) do wanted[#wanted + 1] = b end
  for _, t in ipairs(st.towns) do wanted[#wanted + 1] = t end
  for _, w in ipairs(wanted) do
    if flying >= M.IN_FLIGHT then break end
    local lat, lon = w.city and w.city.lat or w.lat, w.city and w.city.lon or w.lon
    local path = string.format('/v1/stations?lat=%.4f&lon=%.4f', lat, lon)
    if not w.done and not st.pending[path] and now >= (w.nextAt or 0) then
      st.pending[path], flying = now, flying + 1
      ask(path, function(data, err)
        st.pending[path] = nil
        local own = w.box and M.isOrigin(st, w)
        if not own and not M.scheduled(st, w) then return end   -- picked again meanwhile
        if type(data) ~= 'table' then
          if err == 'HTTP 404' then st.old = true end    -- a helper from before coach rides
          w.nextAt, w.failed = now + M.FAILED_S, true
          return
        end
        if data.state == 'ready' then
          w.done, w.failed = true, nil
          local rows = M.rows(data)
          if w.box then
            w.rows = rows
          else
            w.station = M.best(rows, w.city.lat, w.city.lon, M.TOWN_KM)
            if not w.station then
              -- no station mapped there: the next town instead
              local spare = table.remove(st.spares or {}, 1)
              if spare then st.towns[#st.towns + 1] = { city = spare, nextAt = 0 } end
            end
          end
        elseif data.state == 'failed' then w.nextAt, w.failed = now + M.FAILED_S, true
        else w.nextAt = now + M.LOADING_S end
      end)
    end
  end
end

-- The points whose helper boxes together cover nearKm around (lat, lon), the point itself first, then by distance.
function M.points(lat, lon, nearKm)
  local dLat = nearKm / 111.32
  local dLon = nearKm / (111.32 * math.max(0.05, math.cos(math.rad(lat))))
  local nLat = math.max(0, math.ceil((dLat - M.BOX_REACH) / M.BOX_STEP))
  local nLon = math.max(0, math.ceil((dLon - M.BOX_REACH) / M.BOX_STEP))
  local out = {}
  for i = -nLat, nLat do
    for k = -nLon, nLon do
      local la = math.max(-90, math.min(90, lat + i * M.BOX_STEP))
      local lo = k == 0 and lon or (lon + k * M.BOX_STEP + 180) % 360 - 180
      out[#out + 1] = { lat = la, lon = lo, box = true, nextAt = 0, d = i * i + k * k }
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
end

function M.isOrigin(st, w)
  for _, b in ipairs(st.origin and st.origin.points or {}) do if b == w then return true end end
  return false
end

-- Every station found around the player so far.
function M.originRows(st)
  local out, seen = {}, {}
  for _, b in ipairs(st.origin and st.origin.points or {}) do
    for _, r in ipairs(b.rows or {}) do
      if not seen[r.id] then seen[r.id] = true out[#out + 1] = r end
    end
  end
  return out
end

function M.scheduled(st, w)
  for _, t in ipairs(st.towns or {}) do if t == w then return true end end
  return false
end

-- A station as a job place.
local function place(prefix, s)
  return { id = prefix .. s.id, n = s.n, town = s.town or '', g = { s.g[1], s.g[2] } }
end

-- The rides on the board, as bus offers (cargoEarth/bus board rows): from the player's station to each far town's.
-- Returns the offers and the station they leave from (nil: none near).
function M.board(st, p, range)
  local bus = require('cargoEarth/bus')
  if not (st and p and range and st.origin) then return {}, nil end
  local from = M.best(M.originRows(st), p.lat, p.lon, range.nearKm or M.defaults.nearKm)
  if not from then return {}, nil end
  local rows, seen = {}, {}
  for _, t in ipairs(st.towns or {}) do
    local to = t.station
    -- two towns close together can pick the same station: one ride to it (the first town, the bigger one)
    if to and to.id ~= from.id and not seen[to.id] then
      seen[to.id] = true
      local straight = jobs.km(from.g[1], from.g[2], to.g[1], to.g[2])
      local road = straight * jobs.ROAD_FACTOR
      if road >= (range.minKm or 0) and road <= (range.maxKm or math.huge) then
        rows[#rows + 1] = { to = to, city = t.city, road = road }
      end
    end
  end
  table.sort(rows, function(a, b) if a.road == b.road then return a.to.id < b.to.id end return a.road < b.road end)
  local out = {}
  for i = 1, math.min(#rows, M.RIDES) do
    local r = rows[i]
    local town = r.city.n
    local line = { id = 'coach:' .. from.id .. '>' .. r.to.id, ref = '', coach = true, roadFactor = jobs.ROAD_FACTOR,
      name = 'Coach to ' .. town, operator = '', stops = { { n = from.n, g = from.g }, { n = r.to.n, g = r.to.g } } }
    local yard = place('coachstation:', from)
    local j = bus.job(line, yard)
    out[#out + 1] = { id = line.id, companyId = 'coach:' .. from.id, tier = 'bus', coach = true, vehicle = 'Coach',
      name = 'Intercity coaches', yard = yard, jobs = { j }, jobCount = 1, gross = j.pay, km = j.km,
      pickupKm = jobs.km(p.lat, p.lon, from.g[1], from.g[2]), minutes = j.minutes, wages = j.pay,
      fares = bus.coachFares(j.km, bus.COACH.RIDERS_AVG),
      bus = { ref = '', name = j.bus.name, from = from.n, to = r.to.n, town = town, stops = 2, coach = true,
        station = r.to.k, fromKind = from.k } }
  end
  return out, from
end

-- For the phone: how far the search got.
function M.status(st)
  local out = { towns = 0, ready = 0, old = st and st.old or nil }
  if not st then return out end
  -- ready once every box around the player answered (a failed one is asked again later)
  local pts = st.origin and st.origin.points or {}
  local done, failed = 0, 0
  for _, b in ipairs(pts) do
    if b.done then done = done + 1 elseif b.failed then failed = failed + 1 end
  end
  out.origin = #pts > 0 and (done == #pts and 'ready' or done + failed == #pts and done == 0 and 'failed' or 'loading') or 'loading'
  out.originBoxes, out.originReady = #pts, done
  for _, t in ipairs(st.towns or {}) do
    out.towns = out.towns + 1
    if t.station then out.ready = out.ready + 1 end
  end
  return out
end

return M
