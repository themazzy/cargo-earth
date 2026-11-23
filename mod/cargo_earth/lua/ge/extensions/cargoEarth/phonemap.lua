-- cargoEarth/phonemap: the phone's live map. The roads round the car come from the game's road graph (map.getMap(), the
-- graph BeamNG.Earth hands to the game for its traffic), the route from BeamNG.Earth's GPS. Nothing is downloaded:
-- the phone draws a flat sat-nav sketch from these lines. Pure rules: the graph and the points are passed in.
--
--   phonemap.roads(graph, x, y, radius) -> flat list { x1, y1, x2, y2, kind, ... } of road edges near x, y
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
-- M.REBUILD_S, so roads BeamNG.Earth streams into the same table show up).
M.REBUILD_S = 30
local gridFor, gridAt, grid = nil, -math.huge, nil
local function cellKey(cx, cy) return cx * 65536 + cy end

local function build(graph)
  local edges, cells = {}, {}
  local nodes = graph.nodes
  for a, na in pairs(nodes) do
    if type(na) == 'table' and na.links and na.pos then
      for b, l in pairs(na.links) do
        local nb = nodes[b]
        -- an edge the graph keeps on both of its ends is drawn once
        local twice = nb and nb.links and nb.links[a] ~= nil and tostring(b) < tostring(a)
        if nb and nb.pos and type(l) == 'table' and not twice then
          local x1, y1, x2, y2 = na.pos.x, na.pos.y, nb.pos.x, nb.pos.y
          local e = { x1, y1, x2, y2, kindOf(l) }
          edges[#edges + 1] = e
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
  end
  return { edges = edges, cells = cells }
end

function M.grid(graph, now)
  now = now or 0
  if gridFor ~= graph or not grid or now - gridAt >= M.REBUILD_S then
    grid, gridFor, gridAt = build(graph), graph, now
    M.stamp = (M.stamp or 0) + 1
  end
  return grid
end

-- The tile the point is in, as a string key (the phone keeps the roads it has while the key stays the same).
function M.tile(x, y)
  local tx, ty = floor(x / M.TILE + 0.5), floor(y / M.TILE + 0.5)
  return tx, ty, tx * M.TILE, ty * M.TILE
end

function M.roads(graph, x, y, radius, now)
  if not (type(graph) == 'table' and type(graph.nodes) == 'table' and x and y) then return {} end
  radius = radius or M.RADIUS
  local g = M.grid(graph, now)
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
              if n > M.MAX_EDGES then return out end
              local k = #out
              out[k + 1], out[k + 2], out[k + 3], out[k + 4] = round(e[1]), round(e[2]), round(e[3]), round(e[4])
              out[k + 5] = e[5]
            end
          end
        end
      end
    end
  end
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
local routeKey, routeXY = nil, nil
function M.routeXY(key, latlon, toXY)
  if key ~= nil and key == routeKey and routeXY then return routeXY end
  local out = {}
  for _, p in ipairs(type(latlon) == 'table' and latlon or {}) do
    local x, y = toXY(p)
    if x then out[#out + 1] = { x, y } end
  end
  routeKey, routeXY = key, out
  return out
end

-- The converted route for this key, or nil when it has to be asked for again.
function M.routeCached(key)
  if key ~= nil and key == routeKey then return routeXY end
  return nil
end

function M._reset() gridFor, gridAt, grid, routeKey, routeXY = nil, -math.huge, nil, nil, nil end

-- distance in metres, for the tests
function M.len(ax, ay, bx, by) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

return M
