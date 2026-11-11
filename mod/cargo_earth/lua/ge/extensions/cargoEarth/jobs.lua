-- cargoEarth/jobs: the job generator. Pure Lua (no game calls), so it runs in tests outside BeamNG.
--
--   local jobs = require('cargoEarth/jobs')
--   local idx = jobs.index(pack)                         -- pack: the decoded depots_<CC>.json
--   local list = jobs.generate(idx, opts, lat, lon, rnd) -- opts: see M.defaults; rnd: math.random-like, optional
--
-- A job is { id, from = depot, to = depot, cargo = id, cargoName, trailer, tonnes, adr, km (estimated road km),
-- straightKm, pickupKm (player to pickup), pay, minutes (time limit) }.
local M = {}

M.ROAD_FACTOR = 1.3     -- road km per straight km (Czech average is about 1.25 to 1.35)
M.RATE = 22             -- CZK per road km for cargo with pay factor 1.0 (same as haul.lua's semi tier)
M.BASE = 300            -- CZK, fixed part of every job's pay
M.ADR_BONUS = 0.15      -- extra share of pay for dangerous goods (on top of the cargo's pay factor)
M.SPEED_KMH = 55        -- planning speed for the time limit
M.SLACK_MIN = 30        -- minutes added to every time limit

M.defaults = {
  minKm = 20,           -- shortest job, road km
  maxKm = 250,          -- longest job, road km
  nearKm = 30,          -- pickups are offered within this straight distance of the player
  count = 10,           -- jobs offered at once
  cargo = nil,          -- one cargo id, or nil for any
  trailer = nil,        -- one trailer id, or nil for any
  fromType = nil,       -- one depot type for the pickup, or nil for any
  toType = nil,         -- one depot type for the delivery, or nil for any
  adr = true,           -- dangerous goods allowed
  minSize = 'S',        -- smallest site size for both ends: S, M, L, XL
}

local SIZE_RANK = { S = 1, M = 2, L = 3, XL = 4 }
local R = 6371.0
local rad = math.pi / 180

function M.km(lat1, lon1, lat2, lon2)
  local dlat, dlon = (lat2 - lat1) * rad, (lon2 - lon1) * rad
  local a = math.sin(dlat / 2) ^ 2 + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dlon / 2) ^ 2
  return 2 * R * math.asin(math.min(1, math.sqrt(a)))
end

-- Cheap conservative bounds before trigonometric distance calculations.
function M.inBox(lat, lon, point, km)
  if math.abs(point[1] - lat) > km / 110.5 then return false end
  local dlon = math.abs((point[2] - lon + 180) % 360 - 180)
  local angular, latitude = km / R, lat * rad
  -- A circle touching a pole spans every longitude. Otherwise use the exact spherical bound.
  if math.abs(latitude) + angular >= math.pi / 2 then return true end
  local bound = math.asin(math.min(1, math.sin(angular) / math.cos(latitude))) / rad
  return dlon <= bound + 0.0000001
end

-- The pack, indexed: depots by cargo they ship (producers) and by cargo they receive (acceptors).
function M.index(pack)
  local idx = { pack = pack, depots = pack.depots, cargo = pack.cargo, types = pack.types, trailers = pack.trailers,
    producers = {}, acceptors = {}, byId = {} }
  for _, d in ipairs(pack.depots) do
    idx.byId[d.id] = d
    local t = pack.types[d.t]
    if t then
      for _, c in ipairs(t.produces or {}) do
        idx.producers[c] = idx.producers[c] or {}
        table.insert(idx.producers[c], d)
      end
      for _, c in ipairs(t.accepts or {}) do
        idx.acceptors[c] = idx.acceptors[c] or {}
        table.insert(idx.acceptors[c], d)
      end
    end
  end
  return idx
end

-- Live helper areas augment the bundled pack. Jobs keep endpoint snapshots when a cache cell is evicted.
function M.streamIndex()
  return M.index({ depots = {}, cargo = { pallets_general = { name = 'General goods', trailer = 'box', tonnes = 0.4, pay = 1 } },
    types = {}, trailers = { box = 'Box trailer' } })
end

function M.addArea(idx, data, onDrop)
  if type(data) ~= 'table' or type(data.key) ~= 'string' or type(data.depots) ~= 'table' then return 0 end
  idx.stream = idx.stream or { base = idx.depots, areas = {}, order = {} }
  local stream = idx.stream
  if not stream.baseByName then
    stream.baseByName = {}
    for _, d in ipairs(stream.base) do
      stream.baseByName[d.n] = stream.baseByName[d.n] or {}
      table.insert(stream.baseByName[d.n], d)
    end
  end
  local rows = {}
  for _, d in ipairs(data.depots) do
    if type(d.id) == 'string' and type(d.n) == 'string' and type(d.g) == 'table'
      and type(d.g[1]) == 'number' and type(d.g[2]) == 'number' and math.abs(d.g[1]) <= 90 and math.abs(d.g[2]) <= 180
      and (d.t == 'yard' or d.t == 'shop') then
      local duplicate = false
      for _, base in ipairs(stream.baseByName[d.n] or {}) do
        if base.n == d.n and math.abs(base.g[1] - d.g[1]) < 0.002 and M.km(base.g[1], base.g[2], d.g[1], d.g[2]) < 0.12 then
          duplicate = true break
        end
      end
      if not duplicate then
        rows[#rows + 1] = { id = d.id, n = d.n, g = { d.g[1], d.g[2] }, t = 'ce:stream:' .. d.t,
          s = 'S', town = d.town, source = d.source or 'Overture', access = 'candidate' }
      end
    end
  end
  if not stream.areas[data.key] then stream.order[#stream.order + 1] = data.key end
  stream.areas[data.key] = rows
  while #stream.order > 25 do
    local key = table.remove(stream.order, 1)
    stream.areas[key] = nil
    if onDrop then onDrop(key) end
  end
  local depots, seen = {}, {}
  for _, d in ipairs(stream.base) do depots[#depots + 1], seen[d.id] = d, true end
  for _, key in ipairs(stream.order) do
    for _, d in ipairs(stream.areas[key]) do
      if not seen[d.id] then depots[#depots + 1], seen[d.id] = d, true end
    end
  end
  idx.cargo.pallets_general = idx.cargo.pallets_general or {name = 'General goods', trailer = 'box', tonnes = 0.4, pay = 1}
  idx.types['ce:stream:yard'] = { produces = {'pallets_general'}, accepts = {'pallets_general'} }
  idx.types['ce:stream:shop'] = { produces = {}, accepts = {'pallets_general'} }
  local rebuilt = M.index({depots = depots, cargo = idx.cargo, types = idx.types, trailers = idx.trailers})
  for k, v in pairs(rebuilt) do idx[k] = v end
  return #rows
end

local function merged(opts)
  local o = {}
  for k, v in pairs(M.defaults) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  if o.maxKm < o.minKm then o.minKm, o.maxKm = o.maxKm, o.minKm end
  return o
end

-- Is cargo c allowed by the options?
function M.cargoOk(idx, c, o)
  local cg = idx.cargo[c]
  if not cg then return false end
  if o.allowCargo and not o.allowCargo(c) then return false end
  if o.cargo and o.cargo ~= c then return false end
  if o.trailer and o.trailer ~= cg.trailer then return false end
  if cg.adr and not o.adr then return false end
  return true
end

function M.pay(idx, c, roadKm)
  local cg = idx.cargo[c]
  local p = (M.BASE + roadKm * M.RATE) * (cg.pay or 1) * (cg.adr and (1 + M.ADR_BONUS) or 1)
  return math.floor(p / 50 + 0.5) * 50
end

function M.minutes(roadKm)
  return math.floor(roadKm / M.SPEED_KMH * 60 + M.SLACK_MIN + 0.5)
end

local function make(idx, from, to, c, straight, pickupKm, n)
  local cg = idx.cargo[c]
  local road = straight * M.ROAD_FACTOR
  return { id = from.id .. '>' .. to.id .. ':' .. c .. ':' .. n, from = from, to = to, cargo = c,
    cargoName = cg.name, trailer = cg.trailer, tonnes = cg.tonnes, adr = cg.adr == true,
    straightKm = straight, km = road, pickupKm = pickupKm, pay = M.pay(idx, c, road), minutes = M.minutes(road) }
end

-- Offered jobs near (lat, lon). Returns jobs (closest pickups first) and a stats table explaining what was found,
-- for the debug window ({ pickups = n depots in reach, cargoTried = n, noDest = n }).
function M.generate(idx, opts, lat, lon, rnd)
  rnd = rnd or math.random
  local o = merged(opts)
  local minRank = SIZE_RANK[o.minSize] or 1
  local stats = { pickups = 0, pairs = 0, noDest = 0 }
  -- pickups in reach, nearest first
  local near = {}
  for _, d in ipairs(idx.depots) do
    if (SIZE_RANK[d.s] or 1) >= minRank and (not o.fromType or d.t == o.fromType)
      and (not o.requireValidatedSites or d.access ~= 'candidate') and M.inBox(lat, lon, d.g, o.nearKm) then
      local k = M.km(lat, lon, d.g[1], d.g[2])
      if k <= o.nearKm then near[#near + 1] = { d = d, k = k } end
    end
  end
  table.sort(near, function(a, b) return a.k < b.k end)
  stats.pickups = #near
  local out, seen, destinations = {}, {}, {}
  -- round robin over the pickups so the list mixes places; each pass gives every pickup one try
  for pass = 1, 6 do
    for _, p in ipairs(near) do
      if #out >= o.count then break end
      local t = idx.types[p.d.t]
      local ships = {}
      for _, c in ipairs(t.produces or {}) do
        if M.cargoOk(idx, c, o) then ships[#ships + 1] = c end
      end
      if #ships > 0 then
        local c = ships[rnd(#ships)]
        destinations[p.d] = destinations[p.d] or {}
        local cands = destinations[p.d][c]
        if not cands then
          cands = {}
          for _, d in ipairs(idx.acceptors[c] or {}) do
            if d ~= p.d and (SIZE_RANK[d.s] or 1) >= minRank and (not o.toType or d.t == o.toType)
              and (not o.requireValidatedSites or d.access ~= 'candidate') and M.inBox(p.d.g[1], p.d.g[2], d.g, o.maxKm / M.ROAD_FACTOR) then
              local s = M.km(p.d.g[1], p.d.g[2], d.g[1], d.g[2])
              local road = s * M.ROAD_FACTOR
              if road >= o.minKm and road <= o.maxKm then cands[#cands + 1] = { d = d, s = s } end
            end
          end
          destinations[p.d][c] = cands
        end
        if #cands == 0 then
          stats.noDest = stats.noDest + 1
        else
          local q = cands[rnd(#cands)]
          local key = p.d.id .. '>' .. q.d.id .. ':' .. c
          if not seen[key] then
            seen[key] = true
            out[#out + 1] = make(idx, p.d, q.d, c, q.s, p.k, #out + 1)
            stats.pairs = stats.pairs + 1
          end
        end
      end
    end
    if #out >= o.count then break end
  end
  table.sort(out, function(a, b) return a.pickupKm < b.pickupKm end)
  return out, stats
end

-- Option lists for the debug window: sorted ids of cargo, trailers and depot types present in the pack.
function M.choices(idx)
  local function keys(t)
    local k = {}
    for id in pairs(t) do k[#k + 1] = id end
    table.sort(k)
    return k
  end
  return { cargo = keys(idx.cargo), trailers = keys(idx.trailers), types = keys(idx.types) }
end

return M
