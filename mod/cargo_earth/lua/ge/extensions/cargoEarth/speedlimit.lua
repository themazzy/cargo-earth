-- The speed limit of the road under the car, read from the road graph BeamNG.Earth hands to the game for its traffic
-- (map.getMap(): every edge has speedLimit in m/s, from Overture's limits or the country's default for the road,
-- the same limits Earth's own road signs show). Earth lowers an edge's speed in a sharp bend so its traffic slows
-- down; such a bend speed is not a whole posted limit (5 km/h or 5 mph steps), and only then is the legal limit taken
-- from the road on both sides of the bend: a stretch of road is read in both directions and the lower of the two
-- highest values counts. A posted lower limit, however short, is kept; a limit that changes ahead is not shown early.
-- Pure rules: the graph is passed in.
local M = {}

M.REACH_M = 250       -- metres of road read each way
M.TURN_DEG = 40       -- a road that turns more than this at a node is another road
M.MIN_KMH = 5
-- Countries whose road signs are in mph. Everywhere else signs are in km/h, so an edge speed that is a whole number of
-- mph there (BeamNG.Earth falls back to 35 mph = 56 km/h where it knows no limit) is not a posted limit.
M.MPH = { US = true, GB = true, LR = true, MM = true, PR = true, GU = true, VI = true, AS = true, MP = true, BS = true,
  BZ = true, KY = true, VG = true, AI = true, MS = true, TC = true, FK = true, SH = true, GG = true, JE = true, IM = true,
  AG = true, DM = true, GD = true, KN = true, LC = true, VC = true, WS = true }

-- 'mph' or 'km/h' for a country (ISO alpha-2), nil when the country is not known.
function M.unitsFor(iso)
  if type(iso) ~= 'string' or #iso ~= 2 then return nil end
  return M.MPH[iso:upper()] and 'mph' or 'km/h'
end

local function link(nodes, a, b)
  local na, nb = nodes[a], nodes[b]
  return na and na.links and na.links[b] or nb and nb.links and nb.links[a]
end

local function dir(p, q)
  local dx, dy = q.x - p.x, q.y - p.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return nil end
  return dx / len, dy / len, len
end

local function speedOf(l) return tonumber(l and l.speedLimit) or 0 end

-- A speed (m/s) that is a posted limit: a whole 5 km/h or 5 mph step (Earth stores m/s to 2 decimals); only the
-- country's own unit counts when it is known.
local function posted(ms, units)
  local kmh, mph = ms * 3.6, ms / 0.44704
  local isKmh = math.abs(kmh - math.floor(kmh / 5 + 0.5) * 5) <= 0.2
  local isMph = math.abs(mph - math.floor(mph / 5 + 0.5) * 5) <= 0.1
  if units == 'km/h' then return isKmh elseif units == 'mph' then return isMph end
  return isKmh or isMph
end
M.posted = posted

-- The highest edge speed met walking on from `at` away from `from`, straight on at each node, up to REACH_M.
local function walk(nodes, from, at)
  local best, travelled, cosMax = 0, 0, math.cos(math.rad(M.TURN_DEG))
  local seen = { [from] = true }
  while travelled < M.REACH_M do
    seen[at] = true
    local na, nf = nodes[at], nodes[from]
    if not (na and nf and na.pos and nf.pos and na.links) then break end
    local ux, uy = dir(nf.pos, na.pos)
    if not ux then break end
    local nextNode, nextCos, nextLen
    for other, l in pairs(na.links) do
      local no = nodes[other]
      if not seen[other] and no and no.pos and l then
        local vx, vy, len = dir(na.pos, no.pos)
        if vx and ux * vx + uy * vy >= cosMax and (not nextCos or ux * vx + uy * vy > nextCos) then
          nextNode, nextCos, nextLen = other, ux * vx + uy * vy, len
        end
      end
    end
    if not nextNode then break end
    best = math.max(best, speedOf(na.links[nextNode]))
    travelled = travelled + nextLen
    from, at = at, nextNode
  end
  return best
end

-- km/h of the road edge a-b, then what its sign says and in which unit ('km/h', or 'mph' where the limit is a whole
-- number of mph and not of km/h, as in the US or the UK), and whether it is a posted limit (false: a bend speed the
-- graph around it could not resolve yet); nil when the graph has no limit there. units: the country's sign unit
-- (M.unitsFor); with it, a speed that is no posted limit in that unit gives no sign (nil) but still its km/h.
function M.at(graph, a, b, units)
  local nodes = type(graph) == 'table' and graph.nodes
  if type(nodes) ~= 'table' or a == nil or b == nil then return nil end
  local l = link(nodes, a, b)
  local base = speedOf(l)
  if base <= 0 then return nil end
  local ms = base
  if not posted(base, units) then ms = math.max(base, math.min(walk(nodes, a, b), walk(nodes, b, a))) end
  local kmh = ms * 3.6
  if kmh < M.MIN_KMH then return nil end
  local five = math.floor(kmh / 5 + 0.5) * 5
  local mph = ms / 0.44704
  local fiveMph = math.floor(mph / 5 + 0.5) * 5
  local sure = posted(ms, units)
  if units and not sure then return math.floor(kmh + 0.5), nil, units, false end
  if units == 'mph' or (not units and math.abs(kmh - five) > 0.2 and math.abs(mph - fiveMph) <= 0.1) then
    return math.floor(kmh + 0.5), fiveMph, 'mph', sure
  end
  if math.abs(kmh - five) <= 1 then kmh = five end    -- a posted limit, not the rounding of m/s
  kmh = math.floor(kmh + 0.5)
  return kmh, kmh, 'km/h', sure
end

return M
