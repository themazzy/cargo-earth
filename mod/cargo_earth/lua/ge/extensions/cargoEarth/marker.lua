-- In-world stop markers. Courier pickups and drop-offs use rings that follow the ground.
local earth = require('cargoEarth/earth')
local jobs = require('cargoEarth/jobs')
local M = {}

M.PICKUP_RADIUS = 5    -- metres from the centre of the roadside pickup
local RING_RANGE = 250
M.PICKUP_RANGE = RING_RANGE
M.FAR_KM = 6         -- draw distance for the beacon over every stop
-- Freight yards (helper depots, fuel depots, parts suppliers) come as Overture place points: the middle of a site or
-- a building, often far from any road. A yard point with a road within YARD_KEEP_M keeps its spot (its zone reaches
-- the road); else the zone moves to the edge of the nearest road up to YARD_SEARCH_M away, where the GPS ends too.
-- The search starts YARD_FIND_M out (the road graph streams in ahead of the car) and settles within the ring range.
M.YARD_KEEP_M = 20
M.YARD_SEARCH_M = 400
M.YARD_FIND_M = 1500

local CURB_OFFSET = 3.5
local RING_SEGMENTS = 20
local RING_WIDTH = 0.55
local OUTLINE_WIDTH = 5
local SURFACE_LIFT = 0.18  -- keep the ring above the road mesh and its markings
local REFRESH_S = 1
local GROUND_AGAIN_S = 5
local BEACON_M, BEACON_R = 60, 0.8
local COLORS = {
  pickup = { 1.0, 0.55, 0.15 },
  delivery = { 0.2, 0.85, 0.35 },
  area = { 0.25, 0.55, 1.0 },
}

local pickup, delivery, depot = {}, {}, {}
local depotDirections = {}
for i = 1, 8 do depotDirections[i] = { math.cos(math.pi * i / 4), math.sin(math.pi * i / 4) } end
local warned = false
local ringDirections = {}
for i = 1, RING_SEGMENTS do
  local angle = 2 * math.pi * i / RING_SEGMENTS
  ringDirections[i] = { math.cos(angle), math.sin(angle) }
end

-- the ring's colours, made once (not two new colour objects every frame)
local paints = {}
local function paint(c, alpha)
  local byColour = paints[c]
  if not byColour then byColour = {} paints[c] = byColour end
  local col = byColour[alpha]
  if not col then col = ColorF(c[1], c[2], c[3], alpha) byColour[alpha] = col end
  return col
end

local function distance(x, y, p)
  return math.sqrt((x - p.x)^2 + (y - p.y)^2)
end

local function groundZ(x, y, z, above, depth)
  if not (castRayStatic and vec3) then return nil end
  local ok, hit = pcall(castRayStatic, vec3(x, y, z + above), vec3(0, 0, -1), depth)
  if ok and type(hit) == 'number' and hit >= 0 and hit < depth then return z + above - hit end
end

-- Every surface straight down the column (roof, tree crown, pole, bridge deck, ground), top first.
local MAX_HITS = 6
local function columnHits(x, y, top, depth)
  local hits = {}
  if not (castRayStatic and vec3) then return hits end
  local z, left = top, depth
  for _ = 1, MAX_HITS do
    local ok, hit = pcall(castRayStatic, vec3(x, y, z), vec3(0, 0, -1), left)
    if not (ok and type(hit) == 'number' and hit >= 0 and hit < left) then break end
    hits[#hits + 1] = z - hit
    z, left = z - hit - 0.05, left - hit - 0.05
    if left <= 0 then break end
  end
  return hits
end

-- The ground under x, y: of all surfaces in the column, the one closest to `ref` (the road there, or the ring
-- point next to it), so trees, lamp posts, power pylons and roofs above it are skipped. With no reference, the
-- lowest surface. nil when the column hits nothing (ground not streamed in yet).
local function surfaceZ(x, y, ref, top, depth)
  local hits = columnHits(x, y, top, depth)
  local best
  for _, z in ipairs(hits) do
    if not best or (ref and math.abs(z - ref) < math.abs(best - ref)) or (not ref and z < best) then best = z end
  end
  return best
end

-- Height of the nearest streamed road at x, y (a good guess of the ground at a stop next to it).
local function roadZNear(x, y, z)
  if not (map and map.findClosestRoad and map.getMap and vec3) then return nil end
  local ok, a, b = pcall(map.findClosestRoad, vec3(x, y, z), 60)
  local graph = ok and map.getMap()
  local nodes = graph and graph.nodes
  local n1, n2 = nodes and nodes[a], nodes and nodes[b]
  if not (n1 and n2) then return nil end
  local p1, p2 = n1.pos, n2.pos
  local dx, dy = p2.x - p1.x, p2.y - p1.y
  local len2 = dx * dx + dy * dy
  local t = len2 > 0.01 and math.max(0, math.min(1, ((x - p1.x) * dx + (y - p1.y) * dy) / len2)) or 0
  local gx, gy = p1.x + t * dx, p1.y + t * dy
  if (gx - x)^2 + (gy - y)^2 > 60 * 60 then return nil end
  return p1.z + (p2.z - p1.z) * t
end

local function matches(cache, target, p)
  return cache.target == target and cache.anchorLat == p.anchorLat and cache.anchorLon == p.anchorLon
end

local function newCache(target, p)
  return { target = target, anchorLat = p.anchorLat, anchorLon = p.anchorLon, nextRoad = 0, nextGround = 0 }
end

-- Use the streamed road's width and the restaurant's side of that road. The bundled curb
-- is already snapped near a road. Worldwide helper rows can have only a building coordinate.
local function roadEdge(x, y, z, doorX, doorY, search)
  local a, b = map.findClosestRoad(vec3(x, y, z), search)
  local graph = map.getMap()
  local nodes = graph and graph.nodes
  local n1, n2 = nodes and nodes[a], nodes and nodes[b]
  if not (n1 and n2) then return nil end
  local p1, p2 = n1.pos, n2.pos
  local dx, dy = p2.x - p1.x, p2.y - p1.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.1 then return nil end
  local t = math.max(0, math.min(1, ((x - p1.x) * dx + (y - p1.y) * dy) / (len * len)))
  local cx, cy = p1.x + t * dx, p1.y + t * dy
  local nx, ny = -dy / len, dx / len
  if (doorX - cx) * nx + (doorY - cy) * ny < 0 then nx, ny = -nx, -ny end
  local r1, r2 = n1.radius or CURB_OFFSET, n2.radius or CURB_OFFSET
  local width = math.max(2, math.min(7, r1 + (r2 - r1) * t))
  return cx + nx * width, cy + ny * width, p1.z + (p2.z - p1.z) * t
end

-- Address-like stops (restaurants, customers, parcel stops, taxi and tow places: everything but a freight yard,
-- which has a type `t`) stand at the roadside. The helper's rows carry only the address or building point (often
-- inside the house), so the ring moves to the edge of the nearest streamed road, on the building's side.
function M.roadside(stop)
  return type(stop) == 'table' and stop.t == nil
end

-- The stop's roadside point in world x, y (and the road's z once found), cached in `cache` until the stop or the
-- map anchor changes. Before the road is known (out of `range`, roads still streaming), the stop's own point.
local function roadsidePosition(cache, p, stop, now, range)
  if not (p and p.lat and p.lon and stop.g)
    or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) * 1000 > range + 80 then return nil end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) then return nil end
  if cache.x then return cache.x, cache.y, cache.roadZ end
  if distance(x, y, p) > range then return x, y end
  local doorX, doorY
  if stop.d then doorX, doorY = earth.worldXY(p, stop.d) end
  doorX, doorY = doorX or x, doorY or y
  local dx, dy = doorX - x, doorY - y
  local gap = math.sqrt(dx * dx + dy * dy)
  if map and map.findClosestRoad and map.getMap and vec3 and now >= cache.nextRoad then
    cache.nextRoad = now + REFRESH_S
    -- a point that is already a curb (apart from its door) looks close by; a bare address point looks further
    local search = gap < 1 and 80 or 15
    local z = p.z
    if search == 80 then z = surfaceZ(x, y, nil, p.z + 30, 150) or z end
    local ok, rx, ry, rz = pcall(roadEdge, x, y, z, doorX, doorY, search)
    if ok and rx then
      cache.x, cache.y, cache.roadZ = rx, ry, rz
      cache.nextGround = 0
      return rx, ry, rz
    end
  end
  -- While roads stream in, use the known curb, nudged towards the address.
  local fraction = gap > 0 and math.min(1, CURB_OFFSET / gap) or 0
  return x + dx * fraction, y + dy * fraction
end

-- A freight yard's stop point in world x, y (and the road's z when it moved to a road), cached in `cache`.
local function yardPosition(cache, p, stop, now)
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) then return nil end
  if cache.locked or now < cache.nextRoad or distance(x, y, p) > M.YARD_FIND_M
    or not (map and map.findClosestRoad and map.getMap and vec3) then
    return cache.x or x, cache.y or y, cache.roadZ
  end
  cache.nextRoad = now + REFRESH_S
  local z = surfaceZ(x, y, nil, p.z + 300, 1000) or p.z
  local ok, rx, ry, rz = pcall(roadEdge, x, y, z, x, y, M.YARD_SEARCH_M)
  local found = ok and rx ~= nil
  local moved = found and math.sqrt((rx - x)^2 + (ry - y)^2) > M.YARD_KEEP_M
  local nx, ny = moved and rx or nil, moved and ry or nil
  if nx ~= cache.x or ny ~= cache.y then
    -- another spot: the ring and the beacon find their ground again
    cache.x, cache.y, cache.roadZ = nx, ny, moved and rz or nil
    cache.outer, cache.cz, cache.beaconZ, cache.nextGround = nil, nil, nil, 0
  end
  -- close by, the roads around the yard are all streamed in: the spot stays
  if found and distance(cache.x or x, cache.y or y, p) <= RING_RANGE then cache.locked = true end
  return cache.x or x, cache.y or y, cache.roadZ
end

-- A tall beacon over the stop, seen from FAR_KM away, with its name. Its foot is the ring's ground when known.
local function drawBeacon(cache, p, x, y, label, c, inZone, now, ground)
  if distance(x, y, p) > M.FAR_KM * 1000 then return end
  if ground then
    cache.beaconZ = ground
  elseif cache.cz and cache.cx == x and cache.cy == y then
    cache.beaconZ = cache.cz
  elseif now >= (cache.nextBeacon or 0) then
    cache.nextBeacon = now + REFRESH_S
    cache.beaconZ = surfaceZ(x, y, cache.roadZ, (cache.roadZ or p.z) + 500, 2000) or cache.beaconZ
  end
  local z = cache.beaconZ or p.z
  debugDrawer:drawCylinder(vec3(x, y, z), vec3(x, y, z + BEACON_M), BEACON_R, paint(c, inZone and 0.75 or 0.45))
  debugDrawer:drawTextAdvanced(vec3(x, y, z + 4), String(label), ColorF(1, 1, 1, 1), true, false,
    ColorI(math.floor(c[1] * 160), math.floor(c[2] * 160), math.floor(c[3] * 160), 220))
end

local function pickupPosition(p, stop, now)
  if not matches(pickup, stop, p) then pickup = newCache(stop, p) end
  return roadsidePosition(pickup, p, stop, now, M.PICKUP_RANGE)
end

function M.pickupDistance(p, stop, now)
  local x, y = pickupPosition(p, stop, now)
  if x then return distance(x, y, p) end
end

-- Metres from the car to where the ring of `stop` stands once it was moved to the roadside, else nil.
function M.roadsideDistance(p, stop)
  if not (p and p.x and p.y and stop) then return nil end
  for _, cache in ipairs({ pickup, delivery, depot }) do
    if cache.target == stop and cache.x and matches(cache, stop, p) then return distance(cache.x, cache.y, p) end
  end
end

-- One ring point may climb or drop this much from the one before it (a kerb or a steep street is fine, a tree
-- crown or a roof is not).
local POINT_STEP = 3

-- The ground at x, y, `apart` metres from a point at height `ref`: the surface nearest `ref`, and no further from
-- it than a steep street allows over that distance (else `ref`).
local function groundNear(x, y, ref, apart)
  local limit = math.max(POINT_STEP, 0.25 * apart)
  local z = surfaceZ(x, y, ref, ref + 4 + limit, 12 + 2 * limit)
  if not z or math.abs(z - ref) > limit then return ref end
  return z
end

-- Walk round a circle of `radius` about x, y, z (the centre's ground). Returns the ground height of each point
-- (directions from `dirs`) and the slope of the plane through them: z = z0 + sx * dx + sy * dy.
local function groundRing(x, y, z, radius, dirs)
  local heights, prev, sumC, sumS = {}, z, 0, 0
  local seg = 2 * radius * math.sin(math.pi / #dirs)
  for i, dir in ipairs(dirs) do
    local h = groundNear(x + dir[1] * radius, y + dir[2] * radius, prev, i == 1 and radius or seg)
    heights[i], prev = h, h
    sumC, sumS = sumC + (h - z) * dir[1], sumS + (h - z) * dir[2]
  end
  return heights, 2 * sumC / (#dirs * radius), 2 * sumS / (#dirs * radius)
end

local function drawRing(cache, p, x, y, roadZ, radius, c, inZone, now)
  if distance(x, y, p) > RING_RANGE then return end
  if now >= cache.nextGround then
    -- every second until the ring stands, then only now and then (late ground tiles still lift it)
    cache.nextGround = now + (cache.outer and GROUND_AGAIN_S or REFRESH_S)
    local ref = roadZ or roadZNear(x, y, p.z)
    local z = ref and (surfaceZ(x, y, ref, ref + 4, 12) or ref) or surfaceZ(x, y, nil, p.z + 30, 150)
    if not z and distance(x, y, p) <= 50 then z = surfaceZ(p.x, p.y, p.z - 0.5, p.z + 2, 12) end
    if z then
      local outer, inner = {}, {}
      local heights, sx, sy = groundRing(x, y, z, radius, ringDirections)
      for i, dir in ipairs(ringDirections) do
        local oz = heights[i]
        local ix, iy = x + dir[1] * (radius - RING_WIDTH), y + dir[2] * (radius - RING_WIDTH)
        local iz = surfaceZ(ix, iy, oz, oz + 2, 6)
        if not iz or math.abs(iz - oz) > 1 then iz = oz end
        outer[i] = vec3(x + dir[1] * radius, y + dir[2] * radius, oz + SURFACE_LIFT)
        inner[i] = vec3(ix, iy, iz + SURFACE_LIFT)
      end
      -- the ground inside the ring as a tilted plane through the centre: the stop counts only on that level
      cache.cx, cache.cy, cache.cz, cache.slopeX, cache.slopeY = x, y, z, sx, sy
      cache.outer, cache.inner = outer, inner
    end
  end
  local outer, inner = cache.outer, cache.inner
  if not outer then return end
  local outline, fill = paint(c, 1), paint(c, inZone and 0.85 or 0.55)
  for i = 1, RING_SEGMENTS do
    local j = i % RING_SEGMENTS + 1
    if debugDrawer.drawLineInstance then
      debugDrawer:drawLineInstance(outer[i], outer[j], OUTLINE_WIDTH, outline)
    elseif debugDrawer.drawLine then
      debugDrawer:drawLine(outer[i], outer[j], outline)
    end
  end
  if debugDrawer.drawTriSolid then
    for i = 1, RING_SEGMENTS do
      local j = i % RING_SEGMENTS + 1
      debugDrawer:drawTriSolid(inner[i], outer[i], outer[j], fill)
      debugDrawer:drawTriSolid(inner[i], outer[j], inner[j], fill)
    end
  end
end

local function drawPickup(p, stop, inZone, now)
  if not (p.lat and p.lon and stop.g) or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) > M.FAR_KM then return end
  local x, y, roadZ = pickupPosition(p, stop, now)
  if not x then x, y = earth.worldXY(p, stop.g) end
  if not (x and p.z) then return end
  drawRing(pickup, p, x, y, roadZ, M.PICKUP_RADIUS, COLORS.pickup, inZone, now)
  drawBeacon(pickup, p, x, y, 'Pick up: ' .. (stop.n or ''), COLORS.pickup, inZone, now)
end

-- The drop-off: a ring on the ground near by, and a beacon from afar (a freight yard's ring used to show only within
-- the ring range of the yard's point, which can lie deep in a site, so nothing showed where the road ends).
local function drawDelivery(p, stop, radius, inZone, now)
  if not (p.lat and p.lon and stop.g) or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) > M.FAR_KM then return end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) then return end
  if not matches(delivery, stop, p) or delivery.radius ~= radius then
    delivery = newCache(stop, p)
    delivery.radius = radius
  end
  local roadZ
  if M.roadside(stop) then
    local rx, ry, rz = roadsidePosition(delivery, p, stop, now, RING_RANGE)
    if rx then x, y, roadZ = rx, ry, rz end
  else
    x, y, roadZ = yardPosition(delivery, p, stop, now)
    if not x then return end
  end
  drawRing(delivery, p, x, y, roadZ, radius, COLORS.delivery, inZone, now)
  drawBeacon(delivery, p, x, y, 'Deliver: ' .. (stop.n or ''), COLORS.delivery, inZone, now)
end

local function drawDepotPickup(p, stop, radius, inZone, now)
  if not (p.lat and p.lon and stop.g) or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) > M.FAR_KM then return end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) or distance(x, y, p) > M.FAR_KM * 1000 then return end
  if not matches(depot, stop, p) then depot = newCache(stop, p) end
  local roadZ
  if M.roadside(stop) then   -- a taxi passenger or a broken-down car waits by the road, not in the house
    local rx, ry, rz = roadsidePosition(depot, p, stop, now, RING_RANGE)
    if rx then x, y, roadZ = rx, ry, rz end
  else
    local yx, yy, yz = yardPosition(depot, p, stop, now)
    if yx ~= depot.drawnX or yy ~= depot.drawnY then depot.nextGround, depot.z = 0, nil end
    depot.drawnX, depot.drawnY = yx, yy
    if not yx then return end
    x, y, roadZ = yx, yy, yz
  end
  if now >= depot.nextGround then
    local ref = distance(x, y, p) <= RING_RANGE and (roadZ or roadZNear(x, y, p.z)) or nil
    depot.z = surfaceZ(x, y, ref, (ref or p.z) + 500, 2000) or depot.z
    depot.cx, depot.cy, depot.cz, depot.slopeX, depot.slopeY = x, y, nil, 0, 0
    if ref and depot.z then
      -- the yard's tilt from eight ground points across it, so a sloping yard still counts as one level
      local _, sx, sy = groundRing(x, y, depot.z, math.max(5, radius * 0.6), depotDirections)
      depot.cz, depot.slopeX, depot.slopeY = depot.z, sx, sy
    end
    depot.nextGround = now + REFRESH_S
  end
  local z = depot.z or p.z
  local c = COLORS.pickup
  debugDrawer:drawCylinder(vec3(x, y, z), vec3(x, y, z + 0.15), radius, paint(c, inZone and 0.28 or 0.16))
  drawBeacon(depot, p, x, y, 'Pick up: ' .. (stop.n or ''), c, inZone, now, z)
end

-- How far the car sits above (+) or below (-) the ground of the stop's ring, in metres, or nil while that ground
-- is not known. The stop zone is a column only a few metres tall: a bridge above it or a road under it doesn't count.
M.LEVEL_ABOVE, M.LEVEL_BELOW = 4.5, 3.5
function M.heightGap(p, stop)
  if not (p and p.x and p.y and p.z and stop) then return nil end
  for _, cache in ipairs({ pickup, delivery, depot }) do
    if cache.target == stop and cache.cz and matches(cache, stop, p) then
      local ground = cache.cz + (p.x - cache.cx) * (cache.slopeX or 0) + (p.y - cache.cy) * (cache.slopeY or 0)
      return p.z - ground
    end
  end
end

function M.offLevel(p, stop)
  local gap = M.heightGap(p, stop)
  return gap ~= nil and (gap > M.LEVEL_ABOVE or gap < -M.LEVEL_BELOW)
end

function M.draw(p, stop, phase, courier, radius, inZone, now)
  if not (p and stop and debugDrawer and vec3 and ColorF) then return end
  local ok, err
  if phase == 'delivery' then
    ok, err = pcall(drawDelivery, p, stop, radius, inZone, now)
  elseif courier then
    ok, err = pcall(drawPickup, p, stop, inZone, now)
  else
    ok, err = pcall(drawDepotPickup, p, stop, radius, inZone, now)
  end
  if not ok and not warned then
    warned = true
    if log then log('W', 'cargoEarth', 'stop marker draw failed: ' .. tostring(err)) end
  end
end

-- Speed cameras near the car: a grey pole with a yellow box, and the limit above it.
local CAMERA_RANGE = 300
local poles = {}

local function drawCameras(p, list, now)
  if poles.anchorLat ~= p.anchorLat or poles.anchorLon ~= p.anchorLon then
    poles = { anchorLat = p.anchorLat, anchorLon = p.anchorLon }
  end
  for _, cam in ipairs(list) do
    if math.abs(cam.lat - p.lat) < 0.004 and jobs.km(p.lat, p.lon, cam.lat, cam.lon) * 1000 <= CAMERA_RANGE then
      local x, y = earth.worldXY(p, { cam.lat, cam.lon })
      if x and p.z then
        local pole = poles[cam.id] or { nextGround = 0 }
        poles[cam.id] = pole
        if not pole.z and now >= pole.nextGround then
          pole.z, pole.nextGround = surfaceZ(x, y, nil, p.z + 30, 150), now + REFRESH_S
        end
        local z = pole.z or p.z
        debugDrawer:drawCylinder(vec3(x, y, z), vec3(x, y, z + 3.2), 0.09, ColorF(0.45, 0.45, 0.48, 1))
        debugDrawer:drawCylinder(vec3(x, y, z + 3.2), vec3(x, y, z + 3.9), 0.28, ColorF(1, 0.8, 0.1, 1))
        debugDrawer:drawTextAdvanced(vec3(x, y, z + 4.4), String('Speed camera ' .. cam.limit), ColorF(1, 1, 1, 1), true,
          false, ColorI(40, 40, 40, 220))
      end
    end
  end
end

function M.drawCameras(p, list, now)
  if not (p and p.lat and list and #list > 0 and debugDrawer and vec3 and ColorF) then return end
  local ok, err = pcall(drawCameras, p, list, now)
  if not ok and not warned then
    warned = true
    if log then log('W', 'cargoEarth', 'camera marker draw failed: ' .. tostring(err)) end
  end
end

-- Places that count as being somewhere (home, the headquarters): a blue ring on the ground with its name, drawn
-- within RING_RANGE of the car. Fainter outside, brighter when the car is inside.
local areas = {}

local function drawArea(p, key, g, radius, label, now)
  if not (p.lat and p.lon and g) or jobs.km(p.lat, p.lon, g[1], g[2]) * 1000 > RING_RANGE + radius then return end
  local x, y = earth.worldXY(p, g)
  if not (x and p.z) then return end
  local cache = areas[key]
  if not (cache and matches(cache, g, p) and cache.radius == radius) then
    cache = newCache(g, p)
    cache.radius = radius
    areas[key] = cache
  end
  local inside = distance(x, y, p) <= radius
  drawRing(cache, p, x, y, nil, radius, COLORS.area, inside, now)
  local z = cache.outer and cache.outer[1] and cache.outer[1].z
  if z and label then
    local c = COLORS.area
    debugDrawer:drawTextAdvanced(vec3(x, y, z + 3), String(label), ColorF(1, 1, 1, 1), true, false,
      ColorI(math.floor(c[1] * 160), math.floor(c[2] * 160), math.floor(c[3] * 160), 220))
  end
end

function M.drawArea(p, key, g, radius, label, now)
  if not (p and debugDrawer and vec3 and ColorF) then return end
  local ok, err = pcall(drawArea, p, key, g, radius, label, now)
  if not ok and not warned then
    warned = true
    if log then log('W', 'cargoEarth', 'area marker draw failed: ' .. tostring(err)) end
  end
end

M.roadEdge, M.groundZ, M.surfaceZ, M.columnHits = roadEdge, groundZ, surfaceZ, columnHits

function M.reset() pickup, delivery, depot, poles, areas, warned = {}, {}, {}, {}, {}, false end

return M
