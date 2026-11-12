-- Fuel station resupply: a tanker run from a fuel depot to a real fuel station from the map data (the stations the
-- phone already uses for refuelling, bundled or streamed by the helper, so it works wherever there are stations).
-- It is an articulated job with the tanker trailer; the station pays a little extra by the litre on top of the haul.
-- Pure rules: no game calls here.
local jobs = require('cargoEarth/jobs')
local M = {}

M.CARGO = 'fuel'
M.PER_LITRE = 0.02       -- CZK a litre on top of the haul's pay
M.OFFERS = 2             -- resupply offers at most among the freight offers
M.MIN_KM, M.MAX_KM = 15, 150   -- road km from the depot to the station
M.NEAR_KM = 40           -- depots this close to the player

-- Fuel depots near the player, nearest first: { { d, k } }.
function M.depots(idx, lat, lon, nearKm)
  local out = {}
  for _, d in ipairs(idx and idx.producers and idx.producers[M.CARGO] or {}) do
    if d.g and jobs.inBox(lat, lon, d.g, nearKm or M.NEAR_KM) then
      local k = jobs.km(lat, lon, d.g[1], d.g[2])
      if k <= (nearKm or M.NEAR_KM) then out[#out + 1] = { d = d, k = k } end
    end
  end
  table.sort(out, function(a, b) return a.k < b.k end)
  return out
end

-- A station as a delivery place.
function M.place(s)
  return { id = 'station:' .. s.id, n = s.n, g = { s.g[1], s.g[2] }, town = s.town or '', label = 'Fuel station' }
end

-- Resupply jobs from the nearest depots. within(lat, lon, minKm, maxKm) lists stations ({ station, km }).
-- rnd: math.random-like (rnd(n) picks 1..n). Returns jobs shaped like jobs.generate's.
function M.offers(idx, lat, lon, within, rnd, count, nearKm)
  rnd = rnd or math.random
  local out, used = {}, {}
  local cg = idx and idx.cargo and idx.cargo[M.CARGO]
  if not cg then return out end
  for _, p in ipairs(M.depots(idx, lat, lon, nearKm)) do
    if #out >= (count or M.OFFERS) then break end
    local list = within(p.d.g[1], p.d.g[2], M.MIN_KM / jobs.ROAD_FACTOR, M.MAX_KM / jobs.ROAD_FACTOR)
    local free = {}
    for _, row in ipairs(list) do if not used[row.station.id] then free[#free + 1] = row end end
    if #free > 0 then
      local pick = free[math.max(1, math.min(#free, rnd(#free)))]
      used[pick.station.id] = true
      local road = pick.km * jobs.ROAD_FACTOR
      out[#out + 1] = { id = p.d.id .. '>station:' .. pick.station.id, from = p.d, to = M.place(pick.station),
        cargo = M.CARGO, cargoName = 'Fuel for ' .. pick.station.n, trailer = cg.trailer or 'tanker', tonnes = cg.tonnes,
        adr = cg.adr == true, straightKm = pick.km, km = road, pickupKm = p.k, pay = jobs.pay(idx, M.CARGO, road),
        minutes = jobs.minutes(road), resupply = true }
    end
  end
  return out
end

-- After the haul is prepared (litres known): the station's extra by the litre.
function M.bonus(job)
  if not job.resupply or not job.haul then return 0 end
  local extra = math.floor(job.haul.amount * M.PER_LITRE / 5 + 0.5) * 5
  job.resupplyBonus, job.litres = extra, job.haul.amount
  job.pay = job.pay + extra
  return extra
end

return M
