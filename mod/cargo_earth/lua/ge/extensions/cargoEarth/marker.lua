-- In-world stop markers. Courier pickups and drop-offs use rings that follow the ground.
local earth = require('cargoEarth/earth')
local jobs = require('cargoEarth/jobs')
local M = {}

M.PICKUP_RADIUS = 5    -- metres from the centre of the roadside pickup
local RING_RANGE = 250
M.PICKUP_RANGE = RING_RANGE
M.FAR_KM = 6         -- draw distance for the freight pickup beacon

local CURB_OFFSET = 3.5
local RING_SEGMENTS = 20
local RING_WIDTH = 0.55
local OUTLINE_WIDTH = 5
local SURFACE_LIFT = 0.18  -- keep the ring above the road mesh and its markings
local REFRESH_S = 1
local BEACON_M, BEACON_R = 60, 0.8
local COLORS = {
  pickup = { 1.0, 0.55, 0.15 },
  delivery = { 0.2, 0.85, 0.35 },
}

local pickup, delivery, depot = {}, {}, {}
local warned = false
local ringDirections = {}
for i = 1, RING_SEGMENTS do
  local angle = 2 * math.pi * i / RING_SEGMENTS
  ringDirections[i] = { math.cos(angle), math.sin(angle) }
end

local function distance(x, y, p)
  return math.sqrt((x - p.x)^2 + (y - p.y)^2)
end

local function groundZ(x, y, z, above, depth)
  if not (castRayStatic and vec3) then return nil end
  local ok, hit = pcall(castRayStatic, vec3(x, y, z + above), vec3(0, 0, -1), depth)
  if ok and type(hit) == 'number' and hit >= 0 and hit < depth then return z + above - hit end
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

local function pickupPosition(p, stop, now)
  if not (p and p.lat and p.lon and stop.g)
    or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) * 1000 > M.PICKUP_RANGE + 80 then return nil end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) then return nil end
  if not matches(pickup, stop, p) then pickup = newCache(stop, p) end
  if pickup.x then return pickup.x, pickup.y, pickup.roadZ end
  if distance(x, y, p) > M.PICKUP_RANGE then return x, y end
  local doorX, doorY = earth.worldXY(p, stop.d)
  doorX, doorY = doorX or x, doorY or y
  local dx, dy = doorX - x, doorY - y
  local gap = math.sqrt(dx * dx + dy * dy)
  if map and map.findClosestRoad and map.getMap and vec3 and now >= pickup.nextRoad then
    pickup.nextRoad = now + REFRESH_S
    local search = gap < 1 and 80 or 15
    local z = p.z
    if search == 80 then z = groundZ(x, y, p.z, 30, 150) or z end
    local ok, rx, ry, rz = pcall(roadEdge, x, y, z, doorX, doorY, search)
    if ok and rx then
      pickup.x, pickup.y, pickup.roadZ = rx, ry, rz
      pickup.nextGround = 0
      return rx, ry, rz
    end
  end
  -- While roads stream in, use the known curb, nudged towards the address.
  local fraction = gap > 0 and math.min(1, CURB_OFFSET / gap) or 0
  return x + dx * fraction, y + dy * fraction
end

function M.pickupDistance(p, stop, now)
  local x, y = pickupPosition(p, stop, now)
  if x then return distance(x, y, p) end
end

local function drawRing(cache, p, x, y, roadZ, radius, c, inZone, now)
  if distance(x, y, p) > RING_RANGE then return end
  if now >= cache.nextGround then
    cache.nextGround = now + REFRESH_S
    local z = roadZ and (groundZ(x, y, roadZ, 4, 12) or roadZ) or groundZ(x, y, p.z, 30, 150)
    if not z and distance(x, y, p) <= 50 then z = groundZ(p.x, p.y, p.z, 2, 12) end
    if z then
      local outer, inner = {}, {}
      for i, dir in ipairs(ringDirections) do
        local ox, oy = x + dir[1] * radius, y + dir[2] * radius
        local ix, iy = x + dir[1] * (radius - RING_WIDTH), y + dir[2] * (radius - RING_WIDTH)
        outer[i] = vec3(ox, oy, (groundZ(ox, oy, z, 4, 12) or z) + SURFACE_LIFT)
        inner[i] = vec3(ix, iy, (groundZ(ix, iy, z, 4, 12) or z) + SURFACE_LIFT)
      end
      cache.outer, cache.inner = outer, inner
    end
  end
  local outer, inner = cache.outer, cache.inner
  if not outer then return end
  local outline = ColorF(c[1], c[2], c[3], 1)
  local fill = ColorF(c[1], c[2], c[3], inZone and 0.85 or 0.55)
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
  local x, y, roadZ = pickupPosition(p, stop, now)
  if x then drawRing(pickup, p, x, y, roadZ, M.PICKUP_RADIUS, COLORS.pickup, inZone, now) end
end

local function drawDelivery(p, stop, radius, inZone, now)
  if not (p.lat and p.lon and stop.g) or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) * 1000 > RING_RANGE then return end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) then return end
  if not matches(delivery, stop, p) or delivery.radius ~= radius then
    delivery = newCache(stop, p)
    delivery.radius = radius
  end
  drawRing(delivery, p, x, y, nil, radius, COLORS.delivery, inZone, now)
end

local function drawDepotPickup(p, stop, radius, inZone, now)
  if not (p.lat and p.lon and stop.g) or jobs.km(p.lat, p.lon, stop.g[1], stop.g[2]) > M.FAR_KM then return end
  local x, y = earth.worldXY(p, stop.g)
  if not (x and p.z) or distance(x, y, p) > M.FAR_KM * 1000 then return end
  if not matches(depot, stop, p) then depot = newCache(stop, p) end
  if now >= depot.nextGround then
    depot.z = groundZ(x, y, p.z, 500, 2000)
    depot.nextGround = now + REFRESH_S
  end
  local z = depot.z or p.z
  local c = COLORS.pickup
  local base = vec3(x, y, z)
  debugDrawer:drawCylinder(base, vec3(x, y, z + BEACON_M), BEACON_R, ColorF(c[1], c[2], c[3], inZone and 0.75 or 0.45))
  debugDrawer:drawCylinder(base, vec3(x, y, z + 0.15), radius, ColorF(c[1], c[2], c[3], inZone and 0.28 or 0.16))
  local label = 'Pick up: ' .. (stop.n or '')
  debugDrawer:drawTextAdvanced(vec3(x, y, z + 4), String(label), ColorF(1, 1, 1, 1), true, false,
    ColorI(math.floor(c[1] * 160), math.floor(c[2] * 160), math.floor(c[3] * 160), 220))
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
          pole.z, pole.nextGround = groundZ(x, y, p.z, 30, 150), now + REFRESH_S
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

function M.reset() pickup, delivery, depot, poles, warned = {}, {}, {}, {}, false end

return M
