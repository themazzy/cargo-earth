-- cargoEarth/phonemap: the phone's live map. The roads round the car come from the game's road graph (map.getMap(), the
-- graph BeamNG.Earth hands to the game for its traffic), the route from BeamNG.Earth's GPS. Nothing is downloaded:
-- the phone draws a flat sat-nav sketch from these lines. Pure rules: the graph and the points are passed in.
--
--   phonemap.roads(graph, x, y, radius, now, budget) -> flat list { x1, y1, x2, y2, kind, ... } of road edges near x, y
--   phonemap.clip(points, x, y, radius)  -> flat list { x, y, ... } of the route near x, y (false where it leaves the view)
local M = {}

M.RADIUS = 1000      -- metres of road sent round the tile the car is in
M.TILE = 300         -- the roads are sent again only when the car moves to another tile this size
M.CELL = 250         -- the size of the cells the edges are sorted into
M.MAX_EDGES = 9000   -- never more edges than this in one answer (a dense city centre)
M.ROUTE_RADIUS = 1400
M.ROUTE_STEP = 6     -- route points closer than this to the one before are left out

local floor, sqrt = math.floor, math.sqrt
local function round(v) return floor(v + 0.5) end

-- kind: 0 a track or a service road the game drives slowly, 1 a street, 2 a main road (60 km/h and more),
-- 3 a fast road (90 km/h and more)
local function kindOf(l)
  local drive = tonumber(l.drivability) or 1
  local posted = tonumber(l.posted)
  local ms = posted and posted ~= 0 and math.abs(posted) or tonumber(l.speedLimit) or 0
  if ms >= 25 then return 3 end
  if ms >= 16.6 then return 2 end
  if drive < 0.5 then return 0 end
  return 1
end

-- The edges of a graph sorted into cells, kept while the game hands out the same graph table (built again after
-- M.REBUILD_S, so roads BeamNG.Earth streams into the same table show up). A big graph takes 15 to 100 ms to sort,
-- far too long for one frame, so with a budget the sorting is done a few milliseconds at a time over several asks;
-- the last finished grid is used meanwhile (none for a new graph: the roads appear once it is done).
M.REBUILD_S = 30
M.SLICE_MS = 3       -- milliseconds of sorting per ask
local gridFor, gridAt, grid, job = nil, -math.huge, nil, nil
local function cellKey(cx, cy) return cx * 65536 + cy end
M.clock = os.clock or function() return 0 end
local function clock() return M.clock() end

-- the numbers the phone's timing readout shows
M.perf = { buildMs = 0, sliceMaxMs = 0, slices = 0, edges = 0, roadsMs = 0, building = false }

local function newJob(graph, now)
  return { graph = graph, started = now, edges = {}, cells = {}, ms = 0, slices = 0, sliceMax = 0 }
end

local function addNode(j, nodes, a, na)
  if type(na) ~= 'table' or not na.links or not na.pos then return end
  local edges, cells = j.edges, j.cells
  for b, l in pairs(na.links) do
    local nb = nodes[b]
    -- an edge the graph keeps on both of its ends is drawn once
    local twice = nb and nb.links and nb.links[a] ~= nil and tostring(b) < tostring(a)
    if nb and nb.pos and type(l) == 'table' and not twice then
      local x1, y1, x2, y2 = na.pos.x, na.pos.y, nb.pos.x, nb.pos.y
      edges[#edges + 1] = { x1, y1, x2, y2, kindOf(l) }
      local i = #edges
      local c1x, c2x = floor(math.min(x1, x2) / M.CELL), floor(math.max(x1, x2) / M.CELL)
      local c1y, c2y = floor(math.min(y1, y2) / M.CELL), floor(math.max(y1, y2) / M.CELL)
      if (c2x - c1x + 1) * (c2y - c1y + 1) <= 64 then
        for cx = c1x, c2x do
          for cy = c1y, c2y do
            local k = cellKey(cx, cy)
            local list = cells[k]
            if not list then list = {} cells[k] = list end
            list[#list + 1] = i
          end
        end
      end
    end
  end
end

-- Sorts nodes until the budget (ms) is spent; true when the whole graph is done. No budget: all of it at once.
local function run(j, budget)
  local nodes = j.graph.nodes
  local t0 = clock()
  local a, n = j.at, 0
  while true do
    local na
    a, na = next(nodes, a)
    if a == nil then j.at = nil break end
    addNode(j, nodes, a, na)
    n = n + 1
    if budget and n % 16 == 0 and (clock() - t0) * 1000 >= budget then j.at = a break end
  end
  local ms = (clock() - t0) * 1000
  j.ms, j.slices = j.ms + ms, j.slices + 1
  if ms > j.sliceMax then j.sliceMax = ms end
  return j.at == nil
end

function M.grid(graph, now, budget)
  now = now or 0
  if job and job.graph ~= graph then job = nil end
  if not job and (gridFor ~= graph or not grid or now - gridAt >= M.REBUILD_S) then job = newJob(graph, now) end
  if job then
    -- BeamNG.Earth may change the table between two asks (a node taken out stops next()): start the sorting again
    local ok, done = pcall(run, job, budget)
    if not ok then
      job = newJob(graph, now)
    elseif done then
      grid, gridFor, gridAt = { edges = job.edges, cells = job.cells }, graph, job.started
      M.stamp = (M.stamp or 0) + 1
      local p = M.perf
      p.buildMs, p.sliceMaxMs, p.slices, p.edges = job.ms, job.sliceMax, job.slices, #job.edges
      job = nil
    end
  end
  M.perf.building = job ~= nil
  if gridFor ~= graph then return nil end
  return grid
end

-- The tile the point is in, as a string key (the phone keeps the roads it has while the key stays the same).
function M.tile(x, y)
  local tx, ty = floor(x / M.TILE + 0.5), floor(y / M.TILE + 0.5)
  return tx, ty, tx * M.TILE, ty * M.TILE
end

function M.roads(graph, x, y, radius, now, budget)
  if not (type(graph) == 'table' and type(graph.nodes) == 'table' and x and y) then return {} end
  radius = radius or M.RADIUS
  -- with a budget the caller already gave the sorting its slice this ask: use the grid as it is
  local g
  if budget then g = gridFor == graph and grid or nil else g = M.grid(graph, now) end
  if not g then return {} end
  local t0 = clock()
  local out, seen, n = {}, {}, 0
  local r2 = radius * radius
  for cx = floor((x - radius) / M.CELL), floor((x + radius) / M.CELL) do
    for cy = floor((y - radius) / M.CELL), floor((y + radius) / M.CELL) do
      local list = g.cells[cellKey(cx, cy)]
      if list then
        for _, i in ipairs(list) do
          if not seen[i] then
            seen[i] = true
            local e = g.edges[i]
            local mx, my = (e[1] + e[3]) / 2 - x, (e[2] + e[4]) / 2 - y
            if mx * mx + my * my <= r2 then
              n = n + 1
              if n > M.MAX_EDGES then M.perf.roadsMs = (clock() - t0) * 1000 return out end
              local k = #out
              out[k + 1], out[k + 2], out[k + 3], out[k + 4] = round(e[1]), round(e[2]), round(e[3]), round(e[4])
              out[k + 5] = e[5]
            end
          end
        end
      end
    end
  end
  M.perf.roadsMs = (clock() - t0) * 1000
  return out
end

-- The route { { x, y }, ... } near x, y: a point is kept when it or a neighbour is within radius, so a line that
-- leaves the view and comes back is drawn as two pieces ({ false } marks the gap: the phone lifts the pen there).
function M.clip(points, x, y, radius)
  local out = {}
  if type(points) ~= 'table' or not x then return out end
  radius = radius or M.ROUTE_RADIUS
  local r2, step2 = radius * radius, M.ROUTE_STEP * M.ROUTE_STEP
  local function near(p) return p and ((p[1] - x) ^ 2 + (p[2] - y) ^ 2) <= r2 end
  local lastX, lastY, gap = nil, nil, false
  local n = #points
  for i = 1, n do
    local p = points[i]
    if near(p) or near(points[i - 1]) or near(points[i + 1]) then
      local keep = lastX == nil or gap or i == n or (p[1] - lastX) ^ 2 + (p[2] - lastY) ^ 2 >= step2
        or not near(points[i + 1])
      if keep then
        if gap and #out > 0 then out[#out + 1] = false end
        out[#out + 1] = round(p[1])
        out[#out + 1] = round(p[2])
        lastX, lastY, gap = p[1], p[2], false
      end
    elseif lastX then
      gap = true
    end
  end
  return out   -- { x, y, x, y, false, x, y }: the phone reads pairs and lifts the pen at a false
end

-- The route's game points from Earth's lat / lon ones, kept while the route and the world's frame stay the same.
-- Each point is { x, y, lat, lon }: the full map draws the same route by lat / lon.
local routeKey, routeXY = nil, nil
function M.routeXY(key, latlon, toXY)
  if key ~= nil and key == routeKey and routeXY then return routeXY end
  local out = {}
  for _, p in ipairs(type(latlon) == 'table' and latlon or {}) do
    local x, y = toXY(p)
    if x then out[#out + 1] = { x, y, p[1], p[2] } end
  end
  routeKey, routeXY = key, out
  return out
end

-- Where the car is on the route: the nearest point of it, so only the way still ahead is drawn. A route that passes
-- the same place twice (out and back) follows the car: of the near enough pieces, those running the way the car faces
-- count first, and of them the first from the last answer's piece on wins. Returns the route from that point on ({ x, y } list, starting at the point), and
-- { off = metres from the route, back = true when the car faces against the route's direction there }.
M.SAME_M = 15         -- candidates this much farther than the nearest still count as "on it"
M.BACK_DEG = 120      -- facing more than this against the route: it is behind you
local lastFor, lastIdx = nil, nil
function M.ahead(points, x, y, heading, key)
  local n = type(points) == 'table' and #points or 0
  if n < 2 or not x then return points or {}, nil end
  if lastFor ~= key then lastFor, lastIdx = key, nil end
  local best, cands = math.huge, {}
  for i = 1, n - 1 do
    local a, b = points[i], points[i + 1]
    local dx, dy = b[1] - a[1], b[2] - a[2]
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((x - a[1]) * dx + (y - a[2]) * dy) / l2)) or 0
    local px, py = a[1] + dx * t, a[2] + dy * t
    local d = sqrt((x - px) ^ 2 + (y - py) ^ 2)
    if d <= best + M.SAME_M then
      cands[#cands + 1] = { i, px, py, d, dx, dy, t }
      if d < best then best = d end
    end
  end
  -- the first near piece from the last one on (the car moves along the route); none there (the car went back on
  -- purpose, or this is the first answer): simply the nearest
  -- Pieces that run the way the car faces come first: on an out-and-back street both legs are near, and the one
  -- the car drives along is the one it is on.
  local function facing(c)
    if not heading or (c[5] == 0 and c[6] == 0) then return true end
    local dir = math.deg((math.atan2 or math.atan)(c[5], c[6]))
    return math.abs((dir - heading + 540) % 360 - 180) <= 90
  end
  local function choose(want)
    local pick, nearest
    for _, c in ipairs(cands) do
      if c[4] <= best + M.SAME_M and (want == nil or facing(c) == want) then
        if not nearest or c[4] < nearest[4] then nearest = c end
        if lastIdx and c[1] >= lastIdx and (not pick or c[1] < pick[1]) then pick = c end
      end
    end
    return pick or nearest
  end
  local pick = choose(true) or choose(nil)
  lastIdx = pick[1]
  local first = { pick[2], pick[3] }
  local a, b, t = points[pick[1]], points[pick[1] + 1], pick[7]
  if a[3] and b[3] then first[3], first[4] = a[3] + (b[3] - a[3]) * t, a[4] + (b[4] - a[4]) * t end
  local out = { first }
  for i = pick[1] + 1, n do out[#out + 1] = points[i] end
  -- metres along the route to the car's point on it (the route's own length kept on the list once worked out)
  local cum = points.cum
  if not cum then
    cum = { 0 }
    for i = 2, n do cum[i] = cum[i - 1] + sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2) end
    points.cum = cum
  end
  local info = { off = pick[4], along = cum[pick[1]] + (cum[pick[1] + 1] - cum[pick[1]]) * pick[7], length = cum[n] }
  if heading and (pick[5] ~= 0 or pick[6] ~= 0) then
    local dir = math.deg((math.atan2 or math.atan)(pick[5], pick[6]))   -- clockwise from north, like the heading
    info.back = math.abs((dir - heading + 540) % 360 - 180) > M.BACK_DEG
  end
  return out, info
end

-- The full map's route: lat / lon pairs { lat, lon, lat, lon, ... } of the way ahead (from M.ahead), along the route
-- up to `metres`, a point at least every M.ROUTE_STEP. Points without lat / lon are left out.
M.GEO_ROUTE_M = 4000
function M.geoRoute(points, metres)
  local out = {}
  if type(points) ~= 'table' then return out end
  metres = metres or M.GEO_ROUTE_M
  local function r6(v) return floor(v * 1e6 + 0.5) / 1e6 end
  local run, lastX, lastY, keptX, keptY = 0, nil, nil, nil, nil
  local n = #points
  for i = 1, n do
    local p = points[i]
    if lastX then run = run + sqrt((p[1] - lastX) ^ 2 + (p[2] - lastY) ^ 2) end
    lastX, lastY = p[1], p[2]
    local last = i == n or run >= metres
    if p[3] and (not keptX or last or (p[1] - keptX) ^ 2 + (p[2] - keptY) ^ 2 >= M.ROUTE_STEP * M.ROUTE_STEP) then
      out[#out + 1], out[#out + 2] = r6(p[3]), r6(p[4])
      keptX, keptY = p[1], p[2]
    end
    if run >= metres then break end
  end
  return out
end

-- The whole way ahead for the map's whole-route view: about `most` points spread along it, in game metres
-- { x, y, ... } and, where the points have them, lat / lon { lat, lon, ... }.
M.OUTLINE_POINTS = 240
function M.outline(points, most)
  local xy, ll = {}, {}
  if type(points) ~= 'table' or #points == 0 then return { xy = xy, ll = ll } end
  most = most or M.OUTLINE_POINTS
  local total, n = 0, #points
  for i = 2, n do total = total + sqrt((points[i][1] - points[i - 1][1]) ^ 2 + (points[i][2] - points[i - 1][2]) ^ 2) end
  local step, run, keptAt = math.max(M.ROUTE_STEP, total / most), 0, -math.huge
  local function r6(v) return floor(v * 1e6 + 0.5) / 1e6 end
  for i = 1, n do
    local p = points[i]
    if i > 1 then run = run + sqrt((p[1] - points[i - 1][1]) ^ 2 + (p[2] - points[i - 1][2]) ^ 2) end
    if i == 1 or i == n or run - keptAt >= step then
      keptAt = run
      xy[#xy + 1], xy[#xy + 2] = round(p[1]), round(p[2])
      if p[3] then ll[#ll + 1], ll[#ll + 2] = r6(p[3]), r6(p[4]) end
    end
  end
  return { xy = xy, ll = ll }
end

-- The next turn: of Earth's route steps (OSRM maneuvers, 1.7: { type, modifier, exit, name, ref, offset = metres
-- from the route's start }), the first still ahead of `travelled` metres. Returns { type, modifier, exit, name, m }
-- with m the metres to it, or nil (no steps, or only the arrival left and it is far).
local SKIP = { depart = true, ['new name'] = true, notification = true }
-- The lanes at a turn, left to right: { { ok = true | nil, dir = 'left' | 'slight right' | ... }, ... }, or nil with
-- fewer than 2 lanes. dir: the lane's arrow; a lane with several arrows shows the one the route takes when it is a
-- lane to use, else its first.
M.MAX_LANES = 8
local function lanesOf(raw, modifier)
  if type(raw) ~= 'table' or #raw < 2 or #raw > M.MAX_LANES then return nil end
  local want = type(modifier) == 'string' and modifier or 'straight'
  local out = {}
  for i, lane in ipairs(raw) do
    if type(lane) ~= 'table' then return nil end
    local list = type(lane.indications) == 'table' and lane.indications or {}
    local dir = list[1]
    if lane.valid == true then
      for _, d in ipairs(list) do if d == want then dir = d end end
    end
    out[i] = { ok = lane.valid == true or nil, dir = type(dir) == 'string' and dir ~= 'none' and dir or 'straight' }
  end
  return out
end
function M.nextTurn(steps, travelled)
  if type(steps) ~= 'table' or not travelled then return nil end
  for _, st in ipairs(steps) do
    local at = type(st) == 'table' and tonumber(st.offset)
    if at and at > travelled and not SKIP[st.type] and not (st.type == 'continue' and (st.modifier or 'straight') == 'straight') then
      local name = type(st.name) == 'string' and st.name or ''
      if name == '' and type(st.ref) == 'string' then name = st.ref end
      return { type = st.type, modifier = type(st.modifier) == 'string' and st.modifier or nil,
        exit = tonumber(st.exit), name = name ~= '' and name or nil, m = floor(at - travelled + 0.5), lanes = lanesOf(st.lanes, st.modifier) }
    end
  end
  return nil
end

-- The converted route for this key, or nil when it has to be asked for again.
function M.routeCached(key)
  if key ~= nil and key == routeKey then return routeXY end
  return nil
end

function M._reset() job = nil gridFor, gridAt, grid, routeKey, routeXY, lastFor, lastIdx = nil, -math.huge, nil, nil, nil, nil, nil end

-- distance in metres, for the tests
function M.len(ax, ay, bx, by) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

return M
