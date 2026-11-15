-- City bus lines: real lines from OpenStreetMap (route relations, streamed by the helper's /v1/buslines). The city lends
-- you a bus at a bus station or depot near the line's first stop (or at that stop when none is mapped); you drive the
-- line stop by stop, open the doors at each one (people get off and on), and bring the bus back where you got it.
-- The shift runs as a company contract (cargoEarth/employment) with one job of kind 'bus'. Pure rules: no game calls.
local jobs = require('cargoEarth/jobs')
local M = {}

M.NEAR_KM = 4            -- lines whose depot is this close to the player are offered
M.DEPOT_KM = 3           -- a bus station or depot this close to the first stop is where the bus is lent
M.OFFERS = 6
M.ROAD_FACTOR = 1.15     -- the line's straight stop-to-stop km to road km
M.BASE, M.PER_KM, M.PER_STOP, M.PER_PASSENGER = 120, 12, 6, 2
M.SPEED_KMH, M.SLACK_MIN, M.STOP_MIN = 24, 6, 0.4
M.CAPACITY = 70          -- people a city bus takes
M.DWELL_S, M.PER_PERSON_S, M.MAX_DWELL_S = 3, 0.6, 15
M.MAX_STOPS = 40         -- a longer line is cut here (its last stop is the end of this run)
M.STOP_ARRIVE_M = 30     -- a stop counts as reached this close

local function place(id, n, lat, lon)
  return { id = id, n = n, town = '', g = { lat, lon } }
end

local function finite(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end

function M.index() return { lines = {}, depots = {}, state = nil } end

-- data: the helper's answer { state, lines, depots }. Rows that do not look right are left out.
function M.set(idx, data)
  if type(idx) ~= 'table' or type(data) ~= 'table' then return end
  idx.state = data.state
  local lines, depots = {}, {}
  for _, l in ipairs(type(data.lines) == 'table' and data.lines or {}) do
    if type(l) == 'table' and type(l.id) == 'string' and type(l.stops) == 'table' and #l.stops >= 4 then
      local stops = {}
      for _, s in ipairs(l.stops) do
        if type(s) == 'table' and finite(s[2]) and finite(s[3]) and math.abs(s[2]) <= 90 and math.abs(s[3]) <= 180 then
          stops[#stops + 1] = { n = type(s[1]) == 'string' and s[1] ~= '' and s[1] or ('Stop ' .. (#stops + 1)), g = { s[2], s[3] } }
        end
      end
      if #stops >= 4 then
        lines[#lines + 1] = { id = l.id, ref = type(l.ref) == 'string' and l.ref or '', name = type(l.name) == 'string' and l.name or '',
          from = type(l.from) == 'string' and l.from ~= '' and l.from or stops[1].n,
          to = type(l.to) == 'string' and l.to ~= '' and l.to or stops[#stops].n,
          operator = type(l.operator) == 'string' and l.operator or '', colour = type(l.colour) == 'string' and l.colour or nil,
          stops = stops }
      end
    end
  end
  for _, d in ipairs(type(data.depots) == 'table' and data.depots or {}) do
    if type(d) == 'table' and type(d.id) == 'string' and finite(d.lat) and finite(d.lon) then
      depots[#depots + 1] = place('busdepot:' .. d.id, type(d.name) == 'string' and d.name or 'Bus depot', d.lat, d.lon)
    end
  end
  idx.lines, idx.depots = lines, depots
end

-- The line's straight km over its stops.
local function lineKm(stops)
  local k = 0
  for i = 2, #stops do k = k + jobs.km(stops[i - 1].g[1], stops[i - 1].g[2], stops[i].g[1], stops[i].g[2]) end
  return k
end

-- Where the bus for this line is lent and given back: the nearest bus station or depot to its first stop, else the
-- first stop itself.
function M.depotFor(idx, line)
  local first, best, bestKm = line.stops[1], nil, M.DEPOT_KM
  for _, d in ipairs(idx.depots or {}) do
    local k = jobs.km(first.g[1], first.g[2], d.g[1], d.g[2])
    if k <= bestKm then best, bestKm = d, k end
  end
  if best then return best, bestKm end
  return place('busstop:' .. line.id, 'Terminus ' .. first.n, first.g[1], first.g[2]), 0
end

local function title(line)
  local ref = line.ref ~= '' and line.ref or nil
  return ref and ('Line ' .. ref) or (line.name ~= '' and line.name or 'Bus line')
end

-- The job for one run of the line.
function M.job(line, depot)
  local stops = {}
  for i = 1, math.min(#line.stops, M.MAX_STOPS) do stops[i] = { n = line.stops[i].n, g = { line.stops[i].g[1], line.stops[i].g[2] } } end
  local km = lineKm(stops) * M.ROAD_FACTOR
  local depotKm = jobs.km(depot.g[1], depot.g[2], stops[1].g[1], stops[1].g[2])
  local function stopPlace(i) return place('bus:' .. line.id .. ':' .. i, stops[i].n, stops[i].g[1], stops[i].g[2]) end
  return {
    id = 'bus:' .. line.id, kind = 'bus', cargoName = title(line) .. ' to ' .. stops[#stops].n,
    from = stopPlace(1), to = stopPlace(2), km = km, straightKm = lineKm(stops), pickupKm = depotKm,
    pay = math.floor((M.BASE + M.PER_KM * km + M.PER_STOP * #stops) / 5 + 0.5) * 5,
    minutes = math.ceil((km + depotKm) / M.SPEED_KMH * 60 + M.SLACK_MIN + M.STOP_MIN * #stops),
    bus = { line = line.id, ref = line.ref, name = title(line), colour = line.colour, stops = stops, at = 1,
      onBoard = 0, boarded = 0 },
  }
end

-- Lines near the player as company offers (cargoEarth/employment): one job each, the depot as the yard.
function M.board(idx, lat, lon)
  if type(idx) ~= 'table' or not finite(lat) or not finite(lon) then return {} end
  local rows = {}
  for _, line in ipairs(idx.lines or {}) do
    local depot = M.depotFor(idx, line)
    local k = jobs.km(lat, lon, depot.g[1], depot.g[2])
    if k <= M.NEAR_KM then rows[#rows + 1] = { line = line, depot = depot, km = k } end
  end
  table.sort(rows, function(a, b) if a.km == b.km then return a.line.id < b.line.id end return a.km < b.km end)
  local out = {}
  for _, r in ipairs(rows) do
    if #out >= M.OFFERS then break end
    local j = M.job(r.line, r.depot)
    local operator = r.line.operator ~= '' and r.line.operator or 'City buses'
    out[#out + 1] = { id = 'bus:' .. r.line.id, companyId = 'bus:' .. operator, tier = 'bus', vehicle = 'City bus',
      name = operator, yard = r.depot, jobs = { j }, jobCount = 1, gross = j.pay, km = j.km, pickupKm = r.km,
      minutes = j.minutes, wages = j.pay, bus = { ref = r.line.ref, name = j.bus.name, from = j.from.n,
      to = j.bus.stops[#j.bus.stops].n, stops = #j.bus.stops, colour = r.line.colour } }
  end
  return out
end

function M.last(job) return job.bus.at >= #job.bus.stops end

-- People at the current stop: some get off (everyone at the last stop), some get on (fewer near the end, none at the
-- last stop, never more than the bus takes). rnd(n) picks 1..n. Returns off, on and the seconds the doors stay open.
function M.passengers(job, rnd)
  local b = job.bus
  local n, at = #b.stops, b.at
  local off, on
  if at >= n then
    off, on = b.onBoard, 0
  else
    off = at == 1 and 0 or math.floor(b.onBoard * (rnd(5) - 1) / 10 + 0.5)       -- 0..40 % of those on board
    local most = math.max(1, math.ceil(14 * (1 - (at - 1) / n)))
    on = math.min(rnd(most + 1) - 1, M.CAPACITY - (b.onBoard - off))
  end
  local dwell = math.min(M.MAX_DWELL_S, M.DWELL_S + M.PER_PERSON_S * (off + on))
  return off, math.max(0, on), dwell
end

-- After the doors closed: the counts change and the bus heads for the next stop (the job's `to` becomes it).
function M.served(job, off, on)
  local b = job.bus
  b.onBoard = math.max(0, b.onBoard - off) + on
  b.boarded = b.boarded + on
  if b.at < #b.stops then
    b.at = b.at + 1
    local s = b.stops[b.at]
    job.to = place('bus:' .. b.line .. ':' .. b.at, s.n, s.g[1], s.g[2])
  end
end

-- What the line pays at its end: the quote and the fares of the people who rode.
function M.fares(job) return M.PER_PASSENGER * (job.bus.boarded or 0) end

-- For the phone: the line, where you are on it and the next few stops.
function M.state(job, dwell, clock)
  if not job or not job.bus then return nil end
  local b, next = job.bus, {}
  for i = b.at, math.min(#b.stops, b.at + 3) do next[#next + 1] = { n = b.stops[i].n, current = i == b.at or nil } end
  return { ref = b.ref, name = b.name, colour = b.colour, at = b.at, count = #b.stops, onBoard = b.onBoard,
    boarded = b.boarded, next = next, last = M.last(job), capacity = M.CAPACITY,
    doors = dwell and { off = dwell.off, on = dwell.on, left = math.max(0, math.ceil(dwell.untilT - (clock or 0))) } or nil }
end

return M
