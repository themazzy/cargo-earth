-- Speed cameras: real ones from OpenStreetMap, streamed by the helper for wherever the player drives. Passing one
-- too fast costs a fine and a star on every order on board. Pure rules: no game calls here.
local M = {}

M.RADIUS = 30            -- metres: the camera measures a car that comes this close
M.WARN_M = 400           -- the phone names a camera ahead from this far
M.TOLERANCE = 6          -- km/h over the limit that is let go (as real cameras do)
M.AGAIN_S = 90           -- the same camera does not fine twice within this time
M.STAR_PENALTY = 1       -- stars an order on board loses (once per order)
-- { up to this many km/h over, fine in CZK }
M.FINES = { { 10, 200 }, { 20, 500 }, { 40, 1500 }, { math.huge, 3000 } }
-- Where OpenStreetMap has no limit for the camera or its road: a limit no country's default exceeds for that class,
-- so nobody is fined for a limit the game cannot know. A camera on a road of unknown class is ignored.
M.DEFAULT = { motorway = 130, trunk = 110, primary = 100, secondary = 100, tertiary = 100, unclassified = 100,
  residential = 60, living_street = 30 }

local function metres(lat1, lon1, lat2, lon2)
  local k = math.cos(math.rad((lat1 + lat2) / 2))
  local dx, dy = (lon2 - lon1) * k * 111320, (lat2 - lat1) * 111320
  return math.sqrt(dx * dx + dy * dy)
end

function M.index() return { list = {}, near = {}, seen = {}, inside = {}, state = nil } end

-- rows from the helper: { id, lat, lon, limit km/h (0 = unknown), road class }. Replaces what was known.
function M.set(idx, rows, state)
  local list = {}
  for _, row in ipairs(type(rows) == 'table' and rows or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'number' and type(row[3]) == 'number'
      and math.abs(row[2]) <= 90 and math.abs(row[3]) <= 180 then
      local known = tonumber(row[4]) and row[4] >= 5 and row[4] <= 200
      local limit = known and row[4] or M.DEFAULT[row[5]]
      if limit then list[#list + 1] = { id = row[1], lat = row[2], lon = row[3], limit = limit, assumed = not known } end
    end
  end
  idx.list, idx.near, idx.state = list, {}, state
  return #list
end

-- Call every second or so: keeps the cameras within reach (2 km) for the per-frame check.
function M.refresh(idx, lat, lon)
  local near = {}
  for _, cam in ipairs(idx.list) do
    if math.abs(cam.lat - lat) < 0.02 and metres(lat, lon, cam.lat, cam.lon) < 2000 then near[#near + 1] = cam end
  end
  idx.near = near
  return #near
end

function M.fine(over)
  for _, band in ipairs(M.FINES) do
    if over <= band[1] then return band[2] end
  end
end

-- Call every frame while driving. Returns a flash { id, limit, speed, over, fine, assumed } when a camera caught the
-- car this frame, else nil. The speed is the highest measured while inside the camera's circle.
function M.pass(idx, lat, lon, kmh, now)
  local flash
  for _, cam in ipairs(idx.near) do
    local inside = metres(lat, lon, cam.lat, cam.lon) <= M.RADIUS
    local top = idx.inside[cam.id]
    if inside then
      idx.inside[cam.id] = math.max(top or 0, kmh)
    elseif top then
      idx.inside[cam.id] = nil
      local over = math.floor(top + 0.5) - cam.limit
      if over > M.TOLERANCE and now - (idx.seen[cam.id] or -math.huge) >= M.AGAIN_S then
        idx.seen[cam.id] = now
        flash = { id = cam.id, limit = cam.limit, speed = math.floor(top + 0.5), over = over, fine = M.fine(over),
          assumed = cam.assumed }
      end
    end
  end
  return flash
end

-- The nearest camera ahead for the phone: { m, limit } or nil. heading: the car's travel direction in degrees
-- (0 = north, clockwise) or nil to count every direction.
function M.ahead(idx, lat, lon, heading)
  local best
  for _, cam in ipairs(idx.near) do
    local m = metres(lat, lon, cam.lat, cam.lon)
    if m <= M.WARN_M and (not best or m < best.m) then
      local ok = true
      if heading and m > M.RADIUS then
        local k = math.cos(math.rad(lat))
        local bearing = math.deg((math.atan2 or math.atan)((cam.lon - lon) * k, cam.lat - lat))
        ok = math.abs((bearing - heading + 540) % 360 - 180) <= 60
      end
      if ok then best = { m = math.floor(m / 10 + 0.5) * 10, limit = cam.limit } end
    end
  end
  return best
end

-- The limit of the camera's road from the game's road graph (km/h, or nil when the graph has none there). Asked once
-- per camera; a limit learned this way replaces the generous class default.
function M.learn(cam, kmh)
  cam.road = true
  if kmh and kmh >= 5 and kmh <= 200 then cam.limit, cam.assumed = kmh, false end
end

-- Leaving the car, a teleport or a reset: nothing half-measured is kept.
-- (called every frame while not driving: a new table only when something was half measured)
function M.clear(idx) if next(idx.inside) then idx.inside = {} end end

return M
