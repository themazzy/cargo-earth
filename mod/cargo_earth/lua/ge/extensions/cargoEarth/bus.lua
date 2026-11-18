-- City bus lines: real lines from OpenStreetMap (route relations, streamed by the helper's /v1/buslines). The city lends
-- you a bus at a bus station or depot near the line's first stop (or at that stop when none is mapped); you drive the
-- line one way, stop by stop, and open the doors at each one (people get off and on). At the last stop the bus is
-- handed over and you are taken back to the depot, to your own car.
-- The shift runs as a company contract (cargoEarth/employment) with one job of kind 'bus'. Pure rules: no game calls.
local jobs = require('cargoEarth/jobs')
local M = {}

M.NEAR_KM = 4            -- lines with a mapped stop this close to the player are offered
M.DEPOT_KM = 3           -- a bus station or depot this close to the first stop is where the bus is lent
M.ROAD_FACTOR = 1.25     -- the line's straight stop-to-stop km to road km (until the GPS knows the road)
-- Pay goes by the timetable's minutes, as a driver's wage does, plus a little per stop and the fares.
-- Career review 2026-11-18 (issue #123): the bus is lent, needs no unlock and costs no fuel, and a line is usually driven
-- well inside its timetable, so after the company's share it pays about as much as taxi (about 550 CZK/h), below the
-- work you buy a vehicle for.
M.BASE, M.PER_MIN, M.PER_STOP, M.PER_PASSENGER = 40, 4.5, 3, 1.5
-- The timetable: each stop has its own time from the one before. A bus is slow on short hops (pulling out, braking
-- for the next stop) and faster between stops far apart: its speed grows with the hop's road km, within LEG_KMH.
M.LEG_KMH, M.LEG_KMH_PER_KM = { 18, 45 }, 8
M.LEG_STOP_MIN = 0.6     -- pulling in, the doors and pulling out again
M.LEG_SLACK = 1.15       -- the time on the road times this
M.LEG_MIN = 1.5          -- no stop is due sooner than this
M.BOARD_MIN = 1          -- the first stop: getting the bus out of the depot
M.CAPACITY = 70          -- people a city bus takes
-- Comfort (as a taxi's): the people on board feel a rough ride. Each harsh moment (hard braking, accelerating or
-- cornering) costs HARSH_LOSS points, a bump or crash from BUMP_G[1] g costs BUMP_LOSS[1]..[2] (the most from
-- BUMP_G[2] g). An empty bus feels nothing. Comfort sets the line's pay (0.6 + 0.004 x comfort, as a taxi ride) and
-- its stars.
M.HARSH_LOSS = 2
M.HARSH_G, M.HARSH_GAP_S = 0.8, 5
M.IMPACT_GAP_S = 3
M.DAMAGE_MIN, M.DAMAGE_FULL = 1000, 20000
M.BUMP_G, M.BUMP_LOSS = { 3.5, 5.5 }, { 10, 40 }
M.DWELL_S, M.PER_PERSON_S, M.MAX_DWELL_S = 3, 0.6, 15
M.MAX_STOPS = 40         -- a longer line is cut here (its last stop is the end of this run)
M.STOP_ARRIVE_M = 30     -- a stop counts as reached this close
M.COLLECT_FEE = 150      -- CZK: ending a shift away from the depot, the company fetches the bus
M.DEPOT_RADIUS, M.PARK_S, M.PARK_SPEED = 12, 2, 0.5  -- choose a line, then park in its marker to collect the bus

local function place(id, n, lat, lon)
  return { id = id, n = n, town = '', g = { lat, lon } }
end

local function finite(x) return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge end

-- Text from an older helper lost the backslash of its JSON escapes on the way into the game ("u0161" for "š"):
-- such sequences are turned back into the letters (UTF-8). Text that is already right is left as it is.
local function utf8char(c)
  if c < 0x80 then return string.char(c) end
  if c < 0x800 then return string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40) end
  return string.char(0xE0 + math.floor(c / 0x1000), 0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
end

function M.text(v)
  if type(v) ~= 'string' then return nil end
  return (v:gsub('\\?u(%x%x%x%x)', function(h)
    local c = tonumber(h, 16)
    if c < 0x80 or (c >= 0xD800 and c <= 0xDFFF) then return nil end   -- plain ASCII or half of a pair: kept as written
    return utf8char(c)
  end))
end
local text = M.text

function M.index() return { lines = {}, depots = {}, state = nil } end

-- data: the helper's answer { state, lines, depots }. Rows that do not look right are left out.
function M.set(idx, data)
  if type(idx) ~= 'table' or type(data) ~= 'table' then return end
  idx.state = data.state
  idx.progress = type(data.total) == 'number' and {
    total = data.total, ready = data.ready or 0, loading = data.loading or 0, queued = data.queued or 0,
    failed = data.failed or 0, elapsed = data.elapsed or 0, retryAfter = data.retryAfter or 0,
    server = data.server, attempt = data.attempt,
  } or nil
  idx.error = type(data.errors) == 'table' and data.errors[1] or nil
  local lines, depots = {}, {}
  for _, l in ipairs(type(data.lines) == 'table' and data.lines or {}) do
    if type(l) == 'table' and type(l.id) == 'string' and type(l.stops) == 'table' and #l.stops >= 4 then
      local stops = {}
      for _, s in ipairs(l.stops) do
        if type(s) == 'table' and finite(s[2]) and finite(s[3]) and math.abs(s[2]) <= 90 and math.abs(s[3]) <= 180 then
          stops[#stops + 1] = { n = type(s[1]) == 'string' and s[1] ~= '' and text(s[1]) or ('Stop ' .. (#stops + 1)), g = { s[2], s[3] } }
        end
      end
      if #stops >= 4 then
        lines[#lines + 1] = { id = l.id, ref = text(l.ref) or '', name = text(l.name) or '',
          from = type(l.from) == 'string' and l.from ~= '' and text(l.from) or stops[1].n,
          to = type(l.to) == 'string' and l.to ~= '' and text(l.to) or stops[#stops].n,
          operator = text(l.operator) or '', colour = type(l.colour) == 'string' and l.colour or nil,
          stops = stops }
      end
    end
  end
  for _, d in ipairs(type(data.depots) == 'table' and data.depots or {}) do
    if type(d) == 'table' and type(d.id) == 'string' and finite(d.lat) and finite(d.lon) then
      depots[#depots + 1] = place('busdepot:' .. d.id, text(d.name) or 'Bus depot', d.lat, d.lon)
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

-- Minutes the timetable gives a hop of this many road km (the doors at its end included).
function M.legMinutes(roadKm)
  roadKm = math.max(0, tonumber(roadKm) or 0)
  local kmh = math.max(M.LEG_KMH[1], math.min(M.LEG_KMH[2], M.LEG_KMH[1] + M.LEG_KMH_PER_KM * roadKm))
  return math.max(M.LEG_MIN, roadKm / kmh * 60 * M.LEG_SLACK + M.LEG_STOP_MIN)
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

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

-- The job for one run of the line. Every stop has `min`, the minutes from the stop before (from the depot for the
-- first one); the job's minutes are their sum.
function M.job(line, depot)
  local stops = {}
  for i = 1, math.min(#line.stops, M.MAX_STOPS) do stops[i] = { n = line.stops[i].n, g = { line.stops[i].g[1], line.stops[i].g[2] } } end
  local km = lineKm(stops) * M.ROAD_FACTOR
  local depotKm = jobs.km(depot.g[1], depot.g[2], stops[1].g[1], stops[1].g[2])
  local total = 0
  for i, st in ipairs(stops) do
    local from = i == 1 and depot.g or stops[i - 1].g
    st.min = round1(M.legMinutes(jobs.km(from[1], from[2], st.g[1], st.g[2]) * M.ROAD_FACTOR) + (i == 1 and M.BOARD_MIN or 0))
    total = total + st.min
  end
  local function stopPlace(i) return place('bus:' .. line.id .. ':' .. i, stops[i].n, stops[i].g[1], stops[i].g[2]) end
  return {
    id = 'bus:' .. line.id, kind = 'bus', cargoName = title(line) .. ' to ' .. stops[#stops].n,
    from = stopPlace(1), to = stopPlace(2), km = km, straightKm = lineKm(stops), pickupKm = depotKm,
    pay = math.floor((M.BASE + M.PER_MIN * total + M.PER_STOP * #stops) / 5 + 0.5) * 5,
    minutes = math.ceil(total),
    bus = { line = line.id, ref = line.ref, name = title(line), colour = line.colour, stops = stops, at = 1,
      onBoard = 0, boarded = 0, legStart = 0, late = 0 },
  }
end

-- About how many people ride the whole line (M.passengers on average with nobody turned away): for the fares the
-- board shows.
function M.expectedRiders(n)
  local sum = 0
  for at = 1, n - 1 do sum = sum + math.max(1, math.ceil(14 * (1 - (at - 1) / n))) / 2 end
  return math.floor(sum + 0.5)
end

-- The current stop's timetable: seconds left until it is due (below 0: late) and the minutes it was given.
-- nowS: the job's elapsed seconds.
function M.due(job, nowS)
  local b = job.bus
  local st = b.stops[b.at]
  local min = st and st.min or M.LEG_MIN
  return (b.legStart or 0) + min * 60 - (nowS or 0), min
end

-- The GPS knows the road to the current stop: its time follows that road's km instead of the straight-line guess
-- (once per stop). roadKm: the road left to the stop, nowS: the job's elapsed seconds. True when the time changed.
function M.roadKnown(job, roadKm, nowS)
  local b = job.bus
  local st = b.stops[b.at]
  if not st or b.timed == b.at or b.arrivedAt == b.at or not finite(roadKm) or roadKm < 0 then return false end
  b.timed = b.at
  local driven = math.max(0, (nowS or 0) - (b.legStart or 0)) / 60
  local min = round1(driven + M.legMinutes(roadKm) + (b.at == 1 and M.BOARD_MIN or 0))
  if math.abs(min - (st.min or 0)) < 0.2 then return false end
  job.minutes = math.max(1, math.ceil(job.minutes + min - (st.min or 0)))
  st.min = min
  return true
end

-- The bus reached the current stop (the doors open): the minutes it is behind the timetable are added up (once per
-- stop). Returns them.
function M.arrived(job, nowS)
  local b = job.bus
  if b.arrivedAt == b.at then return 0 end
  b.arrivedAt = b.at
  if not (b.stops[b.at] and b.stops[b.at].min) then return 0 end   -- a line taken before the timetable: not counted
  local late = math.max(0, -M.due(job, nowS) / 60)
  b.late = (b.late or 0) + late
  return late
end

-- Minutes the bus was behind the timetable over the whole line.
function M.lateMinutes(job) return job.bus.late or 0 end

local function nearbyStopKm(line, lat, lon)
  local nearest = math.huge
  for _, stop in ipairs(line.stops) do
    nearest = math.min(nearest, jobs.km(lat, lon, stop.g[1], stop.g[2]))
  end
  return nearest
end

-- Match distinct mapped relations at opposite termini. Platforms can be across the road.
-- A shared route number alone also matches branches and short workings.
local function stopDistance(a, b)
  return jobs.km(a.g[1], a.g[2], b.g[1], b.g[2])
end

local function oppositeStops(first, last, a, b)
  local startKm, endKm = stopDistance(first, b), stopDistance(last, a)
  return startKm <= 0.5 and endKm <= 0.5 and startKm < stopDistance(first, a) and endKm < stopDistance(last, b)
end

local function mappedReturn(line, other)
  if line.id == other.id or (line.operator ~= '' and other.operator ~= '' and line.operator ~= other.operator) then return false end
  local s, t = line.stops, other.stops
  if oppositeStops(s[1], s[#s], t[1], t[#t]) then return true end
  -- Loops can share both termini. Check points around the loop to distinguish its two orientations.
  if stopDistance(s[1], s[#s]) > 0.5 or stopDistance(s[1], t[1]) > 0.5 or stopDistance(t[1], t[#t]) > 0.5 then return false end
  local i, k = math.floor(#s / 4), math.floor(#t / 4)
  return oppositeStops(s[1+i], s[#s-i], t[1+k], t[#t-k])
end

-- Lines near the player as company offers (cargoEarth/employment): one job each, the depot as the yard.
function M.board(idx, lat, lon)
  if type(idx) ~= 'table' or not finite(lat) or not finite(lon) then return {} end
  local rows, groups, nearest = {}, {}, nil
  for _, line in ipairs(idx.lines or {}) do
    local k = nearbyStopKm(line, lat, lon)
    nearest = math.min(nearest or k, k)
    groups[line.ref] = groups[line.ref] or {}
    table.insert(groups[line.ref], { line = line, km = k })
  end
  for _, group in pairs(groups) do
    for _, row in ipairs(group) do
      if row.km <= M.NEAR_KM then
        row.offer = true
        for _, other in ipairs(group) do
          if mappedReturn(row.line, other.line) then
            row.hasReturn, other.hasReturn, other.offer = true, true, true
          end
        end
      end
    end
    for _, row in ipairs(group) do
      if row.offer then
        row.depot = M.depotFor(idx, row.line)
        rows[#rows + 1] = row
      end
    end
  end
  table.sort(rows, function(a, b) if a.km == b.km then return a.line.id < b.line.id end return a.km < b.km end)
  local out = {}
  for _, r in ipairs(rows) do
    local j = M.job(r.line, r.depot)
    local operator = r.line.operator ~= '' and r.line.operator or 'City buses'
    out[#out + 1] = { id = 'bus:' .. r.line.id, companyId = 'bus:' .. operator, tier = 'bus', vehicle = 'City bus',
      name = operator, yard = r.depot, jobs = { j }, jobCount = 1, gross = j.pay, km = j.km, pickupKm = jobs.km(lat, lon, r.depot.g[1], r.depot.g[2]),
      minutes = j.minutes, wages = j.pay, fares = math.floor(M.PER_PASSENGER * M.expectedRiders(#j.bus.stops) + 0.5), bus = { ref = r.line.ref, name = j.bus.name, from = j.from.n,
      to = j.bus.stops[#j.bus.stops].n, stops = #j.bus.stops, limited = #r.line.stops > #j.bus.stops,
      singleDirection = not r.hasReturn, colour = r.line.colour } }
  end
  idx.nearestKm = nearest
  return out
end

-- Comfort of the people on board, 0..100.
function M.comfort(job) return math.max(0, math.min(100, tonumber(job.bus.comfort) or 100)) end
function M.riding(job) return job ~= nil and job.bus ~= nil and (job.bus.onBoard or 0) > 0 end

-- A harsh moment with people on board: comfort drops. Returns the loss (0: nobody felt it).
function M.harsh(job)
  if not M.riding(job) then return 0 end
  local before = M.comfort(job)
  job.bus.comfort = math.max(0, before - M.HARSH_LOSS)
  return before - job.bus.comfort
end

-- A bump or crash of `peak` g with people on board. Returns the loss.
function M.bump(job, peak)
  if type(peak) ~= 'number' or peak ~= peak or peak == math.huge then return 0 end
  return M.impact(job, peak)
end

-- Combine accelerometer and damage reports from one collision. A stronger later
-- report adds only the difference, so callback order does not change the total.
function M.impact(job, peak, damage, now)
  if not M.riding(job) then return 0 end
  local loss = 0
  if peak and peak >= M.BUMP_G[1] then
    local share = math.min(1, (peak - M.BUMP_G[1]) / (M.BUMP_G[2] - M.BUMP_G[1]))
    loss = math.floor(M.BUMP_LOSS[1] + share * (M.BUMP_LOSS[2] - M.BUMP_LOSS[1]) + 0.5)
  end
  local hasDamage = damage and damage >= M.DAMAGE_MIN
  if loss == 0 and not hasDamage then return 0 end
  local b = job.bus
  if now then
    if not b.impactAt or now < b.impactAt or now - b.impactAt >= M.IMPACT_GAP_S then
      b.impactAt, b.impactDamage = now, 0
      b.impactLoss = b.harshAt and now >= b.harshAt and now - b.harshAt < M.IMPACT_GAP_S and M.HARSH_LOSS or 0
    end
    if hasDamage then
      b.impactDamage = (b.impactDamage or 0) + damage
      damage = b.impactDamage
    end
  end
  if hasDamage then
    local share = math.min(1, (damage - M.DAMAGE_MIN) / (M.DAMAGE_FULL - M.DAMAGE_MIN))
    loss = math.max(loss, math.floor(M.BUMP_LOSS[1] + share * (M.BUMP_LOSS[2] - M.BUMP_LOSS[1]) + 0.5))
  end
  local extra = loss
  if now then
    extra = math.max(0, loss - b.impactLoss)
    b.impactLoss = math.max(loss, b.impactLoss)
  end
  local before = M.comfort(job)
  b.comfort = math.max(0, before - extra)
  return before - b.comfort
end

-- The bus's own signs (the citybus's destination sign and next-stop screen, vehicles/citybus/lua/controller/bus.lua,
-- event bus_onRouteChange): the line number, where it goes and the stops still ahead. The destination sign draws from
-- a plain-letter atlas, so its text loses accents (Škola -> Skola); the next-stop screen is a web page and keeps them.
local FOLD = {
  ['á'] = 'a', ['Á'] = 'A', ['à'] = 'a', ['À'] = 'A', ['â'] = 'a', ['Â'] = 'A',
  ['ä'] = 'a', ['Ä'] = 'A', ['ã'] = 'a', ['Ã'] = 'A', ['å'] = 'a', ['Å'] = 'A',
  ['ą'] = 'a', ['Ą'] = 'A', ['ă'] = 'a', ['Ă'] = 'A', ['ā'] = 'a', ['Ā'] = 'A',
  ['č'] = 'c', ['Č'] = 'C', ['ć'] = 'c', ['Ć'] = 'C', ['ç'] = 'c', ['Ç'] = 'C',
  ['ď'] = 'd', ['Ď'] = 'D', ['đ'] = 'd', ['Đ'] = 'D', ['é'] = 'e', ['É'] = 'E',
  ['è'] = 'e', ['È'] = 'E', ['ê'] = 'e', ['Ê'] = 'E', ['ë'] = 'e', ['Ë'] = 'E',
  ['ě'] = 'e', ['Ě'] = 'E', ['ę'] = 'e', ['Ę'] = 'E', ['ē'] = 'e', ['Ē'] = 'E',
  ['í'] = 'i', ['Í'] = 'I', ['ì'] = 'i', ['Ì'] = 'I', ['î'] = 'i', ['Î'] = 'I',
  ['ï'] = 'i', ['Ï'] = 'I', ['ī'] = 'i', ['Ī'] = 'I', ['ľ'] = 'l', ['Ľ'] = 'L',
  ['ĺ'] = 'l', ['Ĺ'] = 'L', ['ł'] = 'l', ['Ł'] = 'L', ['ň'] = 'n', ['Ň'] = 'N',
  ['ń'] = 'n', ['Ń'] = 'N', ['ñ'] = 'n', ['Ñ'] = 'N', ['ó'] = 'o', ['Ó'] = 'O',
  ['ò'] = 'o', ['Ò'] = 'O', ['ô'] = 'o', ['Ô'] = 'O', ['ö'] = 'o', ['Ö'] = 'O',
  ['õ'] = 'o', ['Õ'] = 'O', ['ő'] = 'o', ['Ő'] = 'O', ['ø'] = 'o', ['Ø'] = 'O',
  ['ř'] = 'r', ['Ř'] = 'R', ['ŕ'] = 'r', ['Ŕ'] = 'R', ['š'] = 's', ['Š'] = 'S',
  ['ś'] = 's', ['Ś'] = 'S', ['ş'] = 's', ['Ş'] = 'S', ['ș'] = 's', ['Ș'] = 'S',
  ['ß'] = 'ss', ['ẞ'] = 'SS', ['ť'] = 't', ['Ť'] = 'T', ['ţ'] = 't', ['Ţ'] = 'T',
  ['ț'] = 't', ['Ț'] = 'T', ['ú'] = 'u', ['Ú'] = 'U', ['ù'] = 'u', ['Ù'] = 'U',
  ['û'] = 'u', ['Û'] = 'U', ['ü'] = 'u', ['Ü'] = 'U', ['ů'] = 'u', ['Ů'] = 'U',
  ['ű'] = 'u', ['Ű'] = 'U', ['ū'] = 'u', ['Ū'] = 'U', ['ý'] = 'y', ['Ý'] = 'Y',
  ['ÿ'] = 'y', ['Ÿ'] = 'Y', ['ž'] = 'z', ['Ž'] = 'Z', ['ź'] = 'z', ['Ź'] = 'Z',
  ['ż'] = 'z', ['Ż'] = 'Z',
}
M.SIGN_CHARS = 20         -- the destination sign shows this many letters

function M.plain(s)
  s = tostring(s or '')
  return (s:gsub('[\xC0-\xF4][\x80-\xBF]+', function(ch) return FOLD[ch] or '' end))
end

function M.sign(job)
  local b = job and job.bus
  if not b then return nil end
  local list = {}
  for i = b.at, #b.stops do list[#list + 1] = { 'cargoEarth:' .. i, b.stops[i].n } end
  local last = b.stops[#b.stops].n
  return { routeID = M.plain(b.ref):sub(1, 6), direction = M.plain(last):sub(1, M.SIGN_CHARS),
    routeColor = type(b.colour) == 'string' and b.colour:match('^#%x%x%x%x?%x?%x?$') or nil, tasklist = list }
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

-- After the doors closed: the counts change and the bus heads for the next stop (the job's `to` becomes it); its
-- time starts now (nowS: the job's elapsed seconds).
function M.served(job, off, on, nowS)
  local b = job.bus
  b.legStart = nowS or b.legStart or 0
  b.onBoard = math.max(0, b.onBoard - off) + on
  b.boarded = b.boarded + on
  if b.at < #b.stops then
    b.at = b.at + 1
    local s = b.stops[b.at]
    job.to = place('bus:' .. b.line .. ':' .. b.at, s.n, s.g[1], s.g[2])
  end
end

-- A stop the bus cannot reach: nobody gets on (everyone gets off at the last one) and the stop is not paid.
-- Returns how many got off.
function M.skip(job, nowS)
  local b = job.bus
  local off = M.last(job) and b.onBoard or 0
  b.skipped = (b.skipped or 0) + 1
  M.served(job, off, 0, nowS)
  return off
end

-- What the line pays at its end: the quote and the fares of the people who rode.
function M.fares(job) return math.floor(M.PER_PASSENGER * (job.bus.boarded or 0) + 0.5) end

-- The line's pay at its end: the quote less the skipped stops' share, and the fares.
function M.linePay(job)
  local b = job.bus
  local served = math.max(0, #b.stops - (b.skipped or 0)) / #b.stops
  return math.floor(job.pay * served / 5 + 0.5) * 5 + M.fares(job)
end

-- For the phone: the line, where you are on it and the next few stops.
function M.state(job, dwell, nowS)
  if not job or not job.bus then return nil end
  local b, next = job.bus, {}
  local dueS, dueMin = M.due(job, nowS)
  for i = b.at, math.min(#b.stops, b.at + 3) do next[#next + 1] = { n = b.stops[i].n, current = i == b.at or nil } end
  return { ref = b.ref, name = b.name, colour = b.colour, at = b.at, count = #b.stops, onBoard = b.onBoard,
    boarded = b.boarded, skipped = b.skipped or 0, next = next, dueS = math.floor(dueS + 0.5), dueMin = dueMin,
    late = math.floor(M.lateMinutes(job) + 0.5), comfort = M.comfort(job), last = M.last(job), capacity = M.CAPACITY,
    doors = dwell and { off = dwell.off, on = dwell.on, left = math.ceil(dwell.remaining) } or nil }
end

return M
