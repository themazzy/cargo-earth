-- cargoEarth/roads: the driving distance between two points on the game's road graph (map.getMap(), the graph
-- BeamNG.Earth hands to the game for its traffic). Food orders use it to skip customers that are close in a straight
-- line but far by road (across a river, a railway or a motorway). Pure rules: the graph is passed in.
--
--   local km = roads.km(graph, fromNodes, toNodes, maxKm)
--     -> km, or false when the road is longer than maxKm, or nil when the graph cannot say (no road there yet).
local M = {}

M.MAX_VISITS = 40000  -- nodes looked at in one search at most (a search that gives up says nil, not false)

-- Every node's neighbours with the edge length. The graph keeps an edge only once (a.links[b] or b.links[a]);
-- built once per graph table and kept while the game hands out the same one.
local adjFor, adjCache = nil, nil
local function adjacency(graph)
  if adjFor == graph and adjCache then return adjCache end
  local adj, nodes = {}, graph.nodes
  for a, na in pairs(nodes) do
    if na.links and na.pos then
      for b in pairs(na.links) do
        local nb = nodes[b]
        if nb and nb.pos then
          local dx, dy, dz = nb.pos.x - na.pos.x, nb.pos.y - na.pos.y, nb.pos.z - na.pos.z
          local len = math.sqrt(dx * dx + dy * dy + dz * dz)
          adj[a] = adj[a] or {}
          adj[b] = adj[b] or {}
          adj[a][#adj[a] + 1] = { b, len }
          adj[b][#adj[b] + 1] = { a, len }
        end
      end
    end
  end
  adjFor, adjCache = graph, adj
  return adj
end

-- a small binary heap of { f, node }
local function push(h, f, n)
  h[#h + 1] = { f, n }
  local i = #h
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p][1] <= h[i][1] then break end
    h[p], h[i] = h[i], h[p]
    i = p
  end
end
local function pop(h)
  local top, last = h[1], h[#h]
  h[#h] = nil
  if #h > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, m = i * 2, i * 2 + 1, i
      if h[l] and h[l][1] < h[m][1] then m = l end
      if h[r] and h[r][1] < h[m][1] then m = r end
      if m == i then break end
      h[m], h[i] = h[i], h[m]
      i = m
    end
  end
  return top
end

-- from / to: { { node, metres from the point to that node }, ... } (the two ends of the nearest edge).
function M.km(graph, from, to, maxKm)
  if not (graph and graph.nodes and from and to and #from > 0 and #to > 0) then return nil end
  local nodes = graph.nodes
  local goal, goals = {}, {}
  for _, t in ipairs(to) do
    local n = nodes[t[1]]
    if n and n.pos and (goal[t[1]] == nil or t[2] < goal[t[1]]) then goal[t[1]] = t[2] end
  end
  for name, off in pairs(goal) do goals[#goals + 1] = { nodes[name].pos, off } end
  if #goals == 0 then return nil end
  local maxM = (maxKm or math.huge) * 1000
  local best = math.huge
  -- both points on the same edge: the way along it, without a detour to one of its ends
  if #from == 2 and #to == 2 then
    local f1, f2, t1, t2 = from[1][1], from[2][1], to[1][1], to[2][1]
    if (f1 == t1 and f2 == t2) or (f1 == t2 and f2 == t1) then
      local fa = from[1][2]
      local ta = f1 == t1 and to[1][2] or to[2][2]
      best = math.abs(fa - ta)
    end
  end
  local adj = adjacency(graph)
  -- straight line to a goal node plus that node's offset: never more than the real rest of the way
  local function h(name)
    local p, m = nodes[name].pos, math.huge
    for _, g in ipairs(goals) do
      local v = math.sqrt((p.x - g[1].x) ^ 2 + (p.y - g[1].y) ^ 2) + g[2]
      if v < m then m = v end
    end
    return m
  end
  local dist, heap, visits = {}, {}, 0
  for _, f in ipairs(from) do
    if nodes[f[1]] and nodes[f[1]].pos and (dist[f[1]] == nil or f[2] < dist[f[1]]) then
      dist[f[1]] = f[2]
      push(heap, f[2] + h(f[1]), f[1])
    end
  end
  local searched, capped = true, false
  while #heap > 0 do
    local top = pop(heap)
    local f, name = top[1], top[2]
    if f >= best then break end
    if f > maxM then capped = true break end
    local d = dist[name]
    if f - h(name) <= d + 1e-6 then   -- not a stale heap entry
      if goal[name] and d + goal[name] < best then best = d + goal[name] end
      visits = visits + 1
      if visits > M.MAX_VISITS then searched = false break end
      for _, e in ipairs(adj[name] or {}) do
        local nd = d + e[2]
        if dist[e[1]] == nil or nd < dist[e[1]] then
          dist[e[1]] = nd
          push(heap, nd + h(e[1]), e[1])
        end
      end
    end
  end
  if best <= maxM then return best / 1000 end
  if best < math.huge then return false end   -- a way, but longer than the cap
  if not searched then return nil end
  if capped then return false end              -- everything left is longer than the cap
  return nil   -- no road between them in the graph: often just a part of the map not streamed in yet
end

function M._reset() adjFor, adjCache = nil, nil end

return M
