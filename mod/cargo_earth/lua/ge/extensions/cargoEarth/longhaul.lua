-- cargoEarth/longhaul: delivery points for long-distance freight. The nearby helper areas reach only about 15 km, so
-- when a freight or contract distance setting goes far, this picks real towns in that ring (a bundled Natural Earth
-- list, data/cities.json) and asks the helper for their workplaces (/v1/sites). They become delivery points only;
-- pickups stay near the player. Pure rules plus a tick that is handed the helper call, so it runs without the game.
local jobs = require('cargoEarth/jobs')

local M = {}
M.LOCAL_KM = 120       -- a longest distance up to this is served by the nearby areas and the bundled pack
M.TOWNS = 8            -- far towns asked for at once
M.MOVE_KM = 50         -- pick the towns again after moving this far
M.LOADING_S = 4        -- a town the helper is still building: ask again after this long
M.FAILED_S = 300       -- a town that failed: ask again after this long
M.IN_FLIGHT = 2        -- requests to the helper at once
M.SECTORS = 8          -- the ring is split by compass direction, so the towns go every way

-- data/cities.json -> { { n, cc, lat, lon, pop (thousands) }, ... }
function M.cities(data)
  local out = {}
  for _, r in ipairs(type(data) == 'table' and type(data.rows) == 'table' and data.rows or {}) do
    if type(r) == 'table' and type(r[1]) == 'string' and type(r[3]) == 'number' and type(r[4]) == 'number'
      and math.abs(r[3]) <= 90 and math.abs(r[4]) <= 180 then
      out[#out + 1] = { n = r[1], cc = tostring(r[2] or ''), lat = r[3], lon = r[4], pop = tonumber(r[5]) or 0 }
    end
  end
  return out
end

-- The ring (road km) the far towns must lie in: the widest of the given distance profiles that reach past LOCAL_KM.
-- profiles: { { minKm, maxKm }, ... }. Returns minKm, maxKm, or nil when every profile stays local.
function M.ring(profiles)
  local lo, hi
  for _, r in ipairs(profiles or {}) do
    if type(r) == 'table' and tonumber(r.maxKm) and r.maxKm > M.LOCAL_KM then
      local a = math.max(M.LOCAL_KM, tonumber(r.minKm) or 0)
      lo, hi = math.min(lo or a, a), math.max(hi or r.maxKm, r.maxKm)
    end
  end
  return lo, hi
end

local function bearing(lat1, lon1, lat2, lon2)
  local r = math.pi / 180
  local y = math.sin((lon2 - lon1) * r) * math.cos(lat2 * r)
  local x = math.cos(lat1 * r) * math.sin(lat2 * r) - math.sin(lat1 * r) * math.cos(lat2 * r) * math.cos((lon2 - lon1) * r)
  return (math.atan2 and math.atan2(y, x) or math.atan(y, x)) / r % 360
end

-- Up to n towns whose road distance (straight x ROAD_FACTOR) is in [minKm, maxKm]: the biggest of each compass sector
-- first, then the second biggest, and so on. The same place gives the same towns (the offers don't reshuffle).
function M.pick(cities, lat, lon, minKm, maxKm, n)
  local sectors = {}
  for i = 1, M.SECTORS do sectors[i] = {} end
  local lo, hi = minKm / jobs.ROAD_FACTOR, maxKm / jobs.ROAD_FACTOR
  for _, c in ipairs(cities or {}) do
    if math.abs(c.lat - lat) <= hi / 111 then
      local k = jobs.km(lat, lon, c.lat, c.lon)
      if k >= lo and k <= hi then
        local s = math.floor(bearing(lat, lon, c.lat, c.lon) / (360 / M.SECTORS)) % M.SECTORS + 1
        table.insert(sectors[s], c)
      end
    end
  end
  for _, list in ipairs(sectors) do table.sort(list, function(a, b) return a.pop > b.pop end) end
  local out = {}
  for rank = 1, math.huge do
    local any = false
    for _, list in ipairs(sectors) do
      if list[rank] then
        any = true
        if #out < (n or M.TOWNS) then out[#out + 1] = list[rank] end
      end
    end
    if not any or #out >= (n or M.TOWNS) then break end
  end
  return out
end

-- One step, from the helper tick. st: this module's state (kept by the caller). p: the player { lat, lon }.
-- lo, hi: the ring from M.ring (nil: nothing far wanted). cities: from M.cities. ask(path, onDone): the helper call.
-- covered(lat, lon): true where the bundled pack already has workplaces. onSites(key, depots): ready workplaces.
function M.tick(st, now, p, lo, hi, cities, ask, covered, onSites)
  if not (lo and hi and p) or st.old then return end
  local ringKey = string.format('%d-%d', math.floor(lo), math.floor(hi))
  if st.ring ~= ringKey or not st.at or jobs.km(st.at.lat, st.at.lon, p.lat, p.lon) > M.MOVE_KM then
    st.ring, st.at, st.towns = ringKey, { lat = p.lat, lon = p.lon }, {}
    for _, c in ipairs(M.pick(cities, p.lat, p.lon, lo, hi, M.TOWNS)) do
      if not (covered and covered(c.lat, c.lon)) then
        st.towns[#st.towns + 1] = { city = c, nextAt = 0 }
      end
    end
  end
  st.flying = st.flying or 0
  for _, t in ipairs(st.towns) do
    if st.flying >= M.IN_FLIGHT then break end
    if not t.done and not t.asking and now >= t.nextAt then
      t.asking, st.flying = true, st.flying + 1
      local path = string.format('/v1/sites?lat=%.4f&lon=%.4f', t.city.lat, t.city.lon)
      ask(path, function(data, err)
        t.asking, st.flying = false, math.max(0, st.flying - 1)
        if type(data) ~= 'table' then
          if err == 'HTTP 404' then st.old = true end   -- a helper from before long hauls
          t.nextAt = now + M.FAILED_S
          return
        end
        if data.state == 'ready' and type(data.depots) == 'table' then
          t.done, t.count = true, #data.depots
          onSites(tostring(data.key or path), data.depots, t.city)
        elseif data.state == 'failed' then t.nextAt = now + M.FAILED_S
        else t.nextAt = now + M.LOADING_S end
      end)
    end
  end
end

-- For the phone and settings: { towns = n asked, ready = n with workplaces, old = true when the helper is too old }.
function M.status(st)
  local out = { towns = 0, ready = 0, old = st.old or nil }
  for _, t in ipairs(st.towns or {}) do
    out.towns = out.towns + 1
    if t.done then out.ready = out.ready + 1 end
  end
  return out
end

return M
