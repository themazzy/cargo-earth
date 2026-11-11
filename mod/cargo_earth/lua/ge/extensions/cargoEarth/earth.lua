-- cargoEarth/earth: the only place that talks to BeamNG.Earth, through its versioned modding API (beamngEarth_api,
-- docs/ADDONS.md in the BeamNG.Earth repo). Everything returns nil / false and a reason when BeamNG.Earth is missing.
local M = {}

local function api()
  local a = rawget(_G, 'beamngEarth_api')
  if a and a.version and a.version() == 1 then return a end
  return nil
end

function M.available() return api() ~= nil end

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

function M.worldXY(p, pt)
  if not (p and p.x and p.y and p.lat and p.lon and pt and pt[1] and pt[2]) then return nil end
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

-- { remaining (m), eta (s), planning } of the current GPS route, or nil
function M.route()
  local a = api()
  return a and a.gps() or nil
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
