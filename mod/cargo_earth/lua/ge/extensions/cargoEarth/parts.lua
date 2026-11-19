-- Parts runs: an SUV or a pickup brings car parts from a parts supplier (a parts shop, or a car plant or factory that
-- makes them) to a repair workshop. The parts ride in BeamNG's own parcel containers in the boot or the bed, like any
-- other parcel freight. Pure rules: no game calls here.
local M = {}
local jobs = require('cargoEarth/jobs')

M.NEAR_KM = 15          -- suppliers this close to the player (straight km)
M.KM = { 4, 30 }        -- straight km from the supplier to the workshop
M.ROAD_FACTOR = 1.3
M.SLOTS = { 6, 20 }     -- parcel slots of parts a run carries (cut to the free space)
M.MIN_SLOTS = 4
M.DENSITY = 8           -- kg per slot, as parcel routes: a run carries about 50-160 kg
M.BASE, M.PER_KM, M.PER_SLOT = 110, 16, 4   -- career review 2026-11-18: above food (the ride to the supplier is unpaid)
M.SPEED_KMH, M.SLACK_MIN = 40, 12
M.OFFERS = 3

local rad = math.pi / 180
local function km(lat1, lon1, lat2, lon2)
  local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) / 2 * rad)
  local y = (lat2 - lat1) * rad
  return math.sqrt(x * x + y * y) * 6371
end
M.km = km

local function place(p)
  return type(p) == 'table' and type(p.g) == 'table' and type(p.g[1]) == 'number' and type(p.g[2]) == 'number'
    and type(p.n) == 'string' and p.id ~= nil
end

-- suppliers: places { id, n, town, g } (any distance; the ones within NEAR_KM are used); workshops(lat, lon, minKm,
-- maxKm): places around a supplier, nearest first (searched from 0: the road km decides the minimum); capacity: free parcel slots in the vehicle; roadKm(a, b, maxKm)
-- (points { lat, lon }): the real road km when known, or nil/false; range: { minKm, maxKm } road km from the player's
-- settings (optional). Returns up to OFFERS jobs, nearest supplier first.
function M.offers(suppliers, workshops, lat, lon, capacity, rnd, roadKm, range)
  rnd = rnd or math.random
  local room = math.floor(tonumber(capacity) or 0)
  if room < M.MIN_SLOTS then return {} end
  local minRoad = tonumber(range and range.minKm) or M.KM[1] * M.ROAD_FACTOR
  local maxRoad = tonumber(range and range.maxKm) or M.KM[2] * M.ROAD_FACTOR
  if maxRoad < minRoad then return {} end
  local nearKm = tonumber(range and range.nearKm) or M.NEAR_KM
  local near = {}
  for _, s in ipairs(suppliers or {}) do
    if place(s) and jobs.inBox(lat, lon, s.g, nearKm) then
      local k = km(lat, lon, s.g[1], s.g[2])
      if k <= nearKm then near[#near + 1] = { s = s, k = k } end
    end
  end
  table.sort(near, function(a, b) if a.k == b.k then return tostring(a.s.id) < tostring(b.s.id) end return a.k < b.k end)
  local out, used = {}, {}
  for _, n in ipairs(near) do
    if #out >= M.OFFERS then break end
    local list = {}
    for _, w in ipairs(workshops and workshops(n.s.g[1], n.s.g[2], 0, maxRoad) or {}) do
      if place(w) and not used[w.id] and w.id ~= n.s.id then list[#list + 1] = w end
    end
    -- the road km decides: a workshop whose road is outside the range is left out
    local w, straight, road
    while #list > 0 and not w do
      local i = rnd(math.min(#list, 4))
      local cand = table.remove(list, i)
      local s = km(n.s.g[1], n.s.g[2], cand.g[1], cand.g[2])
      -- false: the road is longer than the cap (a detour), so it is out; nil: unknown, estimated from the straight km
      local r = roadKm and roadKm(n.s.g, cand.g, math.min(s * 4 + 5, maxRoad + 1))
      if r ~= false then
        if type(r) ~= 'number' or r ~= r or r < s then r = s * M.ROAD_FACTOR end
        if r >= minRoad and r <= maxRoad then w, straight, road = cand, s, r end
      end
    end
    if w then
      used[w.id] = true
      local slots = math.min(room, M.SLOTS[1] + rnd(M.SLOTS[2] - M.SLOTS[1] + 1) - 1)
      local from = { id = n.s.id, n = n.s.n, town = n.s.town or '', g = { n.s.g[1], n.s.g[2] }, t = n.s.t }
      local to = { id = w.id, n = w.n, town = w.town or '', g = { w.g[1], w.g[2] }, label = w.label }
      out[#out + 1] = {
        id = 'parts:' .. tostring(from.id) .. '>' .. tostring(to.id),
        kind = 'cargo', cargo = 'car_parts', cargoName = 'Car parts', partsRun = true,
        from = from, to = to, straightKm = straight, km = road, pickupKm = n.k,
        tonnes = slots * M.DENSITY / 1000,
        pay = math.floor((M.BASE + M.PER_KM * road + M.PER_SLOT * slots) / 5 + 0.5) * 5,
        minutes = math.floor((road + 1.3 * n.k) / M.SPEED_KMH * 60 + M.SLACK_MIN + 0.5),
        haul = { tier = 'suv', kind = 'parcel', amount = slots, kg = math.floor(slots * M.DENSITY + 0.5), density = M.DENSITY },
      }
    end
  end
  return out
end

return M
