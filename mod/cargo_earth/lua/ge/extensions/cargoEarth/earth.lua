-- cargoEarth/earth: the only place that talks to BeamNG.Earth, through its versioned modding API (beamngEarth_api,
-- docs/ADDONS.md in the BeamNG.Earth repo). Everything returns nil / false and a reason when BeamNG.Earth is missing.
local M = {}

local function api()
  local a = rawget(_G, 'beamngEarth_api')
  if a and a.version and a.version() == 1 then return a end
  return nil
end

function M.towWorldMoving()
  local a = api()
  return a and (not a.ready() or (a.rebasing and a.rebasing()))
end

function M.available() return api() ~= nil end

-- A feature of a newer modding API (BeamNG.Earth 1.10: 'gpsRoute', 'transform', 'rebase', ...); false on an older one.
local function has(a, name)
  if not a or type(a.has) ~= 'function' then return false end
  local ok, yes = pcall(a.has, name)
  return ok and yes == true
end
function M.has(name) return has(api(), name) end

-- 'ok', or why not: 'BeamNG.Earth not installed', 'not connected', 'not in the BeamNG.Earth level', 'loading'
function M.status()
  local a = api()
  if not a then return 'BeamNG.Earth not installed (or older than modding API 1)' end
  if not a.connected() then return 'BeamNG.Earth app not connected' end
  if not a.inWorld() then return 'Load the BeamNG.Earth level' end
  if not a.ready() then return 'World loading' end
  return 'ok'
end

-- { lat, lon, speed (m/s), heading, x, y, z, anchorLat, anchorLon, camera } or nil
function M.pose()
  local a = api()
  return a and a.pose() or nil
end

-- BeamNG.Earth measures x/y east and north from its current WGS84 anchor, at zero altitude.
local rad, sin, cos = math.rad, math.sin, math.cos
local WGS84_A, WGS84_E2 = 6378137, 0.0066943799901413165

-- Earth's own conversion (modding API 1.6, toGame) when it has it, in the frame of the pose `p` came from;
-- otherwise the same east / north maths done here.
function M.worldXY(p, pt)
  if not (p and p.x and p.y and p.lat and p.lon and pt and pt[1] and pt[2]) then return nil end
  local a = p.anchorLat and api()
  if has(a, 'transform') and type(a.toGame) == 'function' then
    local ok, x, y = pcall(a.toGame, pt[1], pt[2])
    if ok and tonumber(x) and tonumber(y) then return x, y end
  end
  local lat, lon = rad(pt[1]), rad(pt[2])
  if not (p.anchorLat and p.anchorLon) then
    local deltaLon = (pt[2] - p.lon + 180) % 360 - 180
    return p.x + WGS84_A * cos(rad(p.lat)) * rad(deltaLon), p.y + WGS84_A * (lat - rad(p.lat))
  end
  local lat0, deltaLon = rad(p.anchorLat), lon - rad(p.anchorLon)
  local s, s0 = sin(lat), sin(lat0)
  local r = WGS84_A / math.sqrt(1 - WGS84_E2 * s * s)
  local r0 = WGS84_A / math.sqrt(1 - WGS84_E2 * s0 * s0)
  local east = r * cos(lat) * sin(deltaLon)
  local north = cos(lat0) * (r * s - r0 * s0) * (1 - WGS84_E2)
    - s0 * (r * cos(lat) * cos(deltaLon) - r0 * cos(lat0))
  return east, north
end

function M.place()
  local a = api()
  return a and a.place and a.place() or nil
end

function M.gps(lat, lon, name)
  local a = api()
  if not a then return false, 'BeamNG.Earth not installed' end
  return a.gpsSet(lat, lon, name)
end

function M.gpsClear()
  local a = api()
  if a then a.gpsClear() end
end

-- At most this many points in one GPS route (BeamNG.Earth: 10 waypoints and the destination).
M.ROUTE_MAX = 11

-- Can the GPS go through several stops in one route (modding API 1.2)?
function M.canRoute()
  local a = api()
  return has(a, 'gpsRoute') and type(a.gpsSetRoute) == 'function'
end

-- The GPS through stops { { lat, lon, name }... } in order, the last the destination (only the first ROUTE_MAX);
-- one stop, or an Earth without multi-stop routes: straight to the first. True, or false and why.
function M.gpsStops(stops)
  local a = api()
  if not a then return false, 'BeamNG.Earth not installed' end
  if type(stops) ~= 'table' or not stops[1] then return false, 'no stops' end
  if #stops == 1 or not M.canRoute() then return a.gpsSet(stops[1][1], stops[1][2], stops[1][3]) end
  local points = {}
  for i = 1, math.min(#stops, M.ROUTE_MAX) do points[i] = { stops[i][1], stops[i][2], stops[i][3] } end
  return a.gpsSetRoute(points)
end

-- { remaining (m), eta (s), planning, stops } of the current GPS route, or nil. remaining and eta are to the NEXT stop
-- of a route through several (toEnd: to its last); stops: how many stops the GPS still has ahead, the destination
-- included.
function M.route()
  local a = api()
  local r = a and a.gps() or nil
  if type(r) ~= 'table' then return r end
  local ahead = type(r.waypoints) == 'table' and #r.waypoints or 0
  r.stops = ahead + 1
  -- legs: the planned { dist, dur } from the start through each waypoint; the last `ahead` of them lie past the next
  if ahead > 0 and type(r.legs) == 'table' and #r.legs > ahead and type(r.remaining) == 'number' then
    local past = 0
    for i = #r.legs - ahead + 1, #r.legs do
      past = past + (type(r.legs[i]) == 'table' and tonumber(r.legs[i][1]) or 0)
    end
    local whole = r.remaining
    local toNext = math.max(0, whole - past)
    if type(r.eta) == 'number' then r.eta = whole > 0 and r.eta * toNext / whole or 0 end
    r.toEnd, r.remaining = whole, toNext
  end
  return r
end

-- The planned GPS route as the map draws it (modding API 1.6): { version, points = { { lat, lon }, ... } }, or nil.
-- Earth hands out a copy: ask only when gps().routeVersion changes.
function M.routeGeometry()
  local a = api()
  if not has(a, 'routeGeometry') or type(a.gpsRoute) ~= 'function' then return nil end
  local ok, r = pcall(a.gpsRoute)
  if ok and type(r) == 'table' and type(r.points) == 'table' then return r end
  return nil
end

function M.teleport(lat, lon, name)
  local a = api()
  if not a then return false, 'BeamNG.Earth not installed' end
  if not a.teleport then return false, 'BeamNG.Earth teleport is unavailable' end
  return a.teleport(lat, lon, name)
end

function M.notify(text, seconds)
  local a = api()
  if a then return a.notify(text, seconds) end
  if ui_message then pcall(ui_message, text, seconds or 5, 'cargoEarth') end
end

return M
