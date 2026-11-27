-- cargoEarth/fillup: Fill up the rest (own trailers, 2026-11-27). With room left after the main load in a box trailer
-- (or a flatbed or an insulated box carrying boxes), the phone offers small extra consignments of the same cargo from the
-- same pickup to other workplaces along the way (at most 15 % detour). Each is a stop before the main drop, and it pays
-- the load part of the freight formula for its own weight and distance plus a stop fee: the trip's fixed part is already
-- in the main load's pay, so a light main load plus fill-ups pays about what a full load would. The stops ride on the
-- parcel route machinery (job.route with fill = true). Pure rules: no game calls here.
local M = {}

M.MAX_DETOUR = 0.15      -- extra road share over the main trip
M.MAX_EXTRAS = 2         -- fill-ups on one job
M.OFFERS = 3
M.STEP = 100             -- slots in one Cargo Box XL
M.MAX_SLOTS = 600        -- one fill-up takes at most six boxes
M.STOP_FEE = 100
M.STOP_MIN = 6           -- minutes added for each stop
M.FAMILIES = { box = true, flatbed = true, reefer = true }

local rad = math.pi / 180
local function km(a, b)
  local x = (b[2] - a[2]) * rad * math.cos((a[1] + b[1]) / 2 * rad)
  local y = (b[1] - a[1]) * rad
  return math.sqrt(x * x + y * y) * 6371
end
M.km = km

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- Can this job take fill-ups now? A parcel load of your own in a box trailer, a flatbed or an insulated box, not yet
-- loaded, with room left, and fewer than MAX_EXTRAS already.
function M.can(job)
  local h = type(job) == 'table' and job.haul
  if not (h and h.pool and h.kind == 'parcel' and M.FAMILIES[h.family]) then return false end
  if job.home or job.companyShift then return false end
  if job.route and not job.route.fill then return false end
  local n = 0
  for _, s in ipairs(job.route and job.route.stops or {}) do if s.fill then n = n + 1 end end
  return n < M.MAX_EXTRAS and M.room(job) >= M.STEP
end

-- Slots still free on the trailer for this cargo.
function M.room(job)
  local h = job.haul
  return math.max(0, (h.most or h.amount or 0) - (h.amount or 0))
end

-- The pay of a fill-up: its load part (slots of tierSpace, or its weight share, as cargoEarth/haul.fill) over the road km
-- from the pickup, times the cargo factor, plus the stop fee.
function M.pay(tierRow, space, slots, kg, roadKm, factor)
  local share = math.max((kg or 0) / tierRow.kg, (space or 0) > 0 and slots / space or 0)
  return round5((M.STOP_FEE + tierRow.rate * roadKm * 0.6 * math.min(1, share)) * (factor or 1))
end

-- acceptors: workplaces that take the job's cargo ({ id, n, town, g }); tierRow: cargoEarth/haul tiers[tier]; roadFactor:
-- road km per straight km. Returns up to OFFERS fill-ups: { to = depot, slots, kg, detourKm, roadKm, pay, minutes }.
function M.offers(job, acceptors, tierRow, roadFactor)
  if not M.can(job) then return {} end
  local from, main = job.from.g, (job.route and job.route.final or job.to).g
  local direct = km(from, main)
  if direct < 1 then return {} end
  local taken = { [tostring(job.from.id)] = true, [tostring((job.route and job.route.final or job.to).id)] = true }
  for _, s in ipairs(job.route and job.route.stops or {}) do taken[tostring(s.id)] = true end
  local room = M.room(job)
  local slots = math.max(M.STEP, math.min(M.MAX_SLOTS, math.floor(room / 2 / M.STEP) * M.STEP))
  if slots > room then slots = math.floor(room / M.STEP) * M.STEP end
  if slots < M.STEP then return {} end
  local h = job.haul
  local list = {}
  for _, d in ipairs(acceptors or {}) do
    if type(d) == 'table' and type(d.g) == 'table' and not taken[tostring(d.id)] then
      local a, b = km(from, d.g), km(d.g, main)
      local extra = a + b - direct
      if a > 0.5 and b > 0.5 and extra <= direct * M.MAX_DETOUR then
        list[#list + 1] = { d = d, a = a, extra = extra }
      end
    end
  end
  table.sort(list, function(x, y) return x.extra < y.extra end)
  local out = {}
  for i = 1, math.min(M.OFFERS, #list) do
    local row = list[i]
    local kg = math.floor(slots * (h.density or 1) + 0.5)
    local roadKm = row.a * (roadFactor or 1.3)
    out[#out + 1] = { to = { id = row.d.id, n = row.d.n, town = row.d.town or '', g = { row.d.g[1], row.d.g[2] }, t = row.d.t },
      slots = slots, kg = kg, detourKm = math.floor(row.extra * (roadFactor or 1.3) * 10 + 0.5) / 10,
      roadKm = math.floor(roadKm * 10 + 0.5) / 10, pay = M.pay(tierRow, h.space, slots, kg, roadKm, job.loadFactor),
      minutes = math.floor(row.extra * (roadFactor or 1.3) / (tierRow.speed or 50) * 60 + M.STOP_MIN + 0.5) }
  end
  return out
end

-- Take a fill-up on the job: a stop before the main drop (stops in order of distance from the pickup), its slots on the
-- load, its pay and time on the job. Returns true.
function M.add(job, offer)
  local h = job.haul
  if not job.route then
    local main = job.to
    job.route = { fill = true, final = main, at = 1, total = h.amount,
      stops = { { id = main.id, n = main.n, town = main.town or '', g = { main.g[1], main.g[2] }, t = main.t, slots = h.amount, main = true } } }
  end
  local r = job.route
  local stop = { id = offer.to.id, n = offer.to.n, town = offer.to.town, g = { offer.to.g[1], offer.to.g[2] }, t = offer.to.t,
    slots = offer.slots, fill = true, pay = offer.pay }
  local at = #r.stops   -- before the main drop, nearest the pickup first
  for i, s in ipairs(r.stops) do
    if s.main or km(job.from.g, s.g) > km(job.from.g, stop.g) then at = i break end
  end
  table.insert(r.stops, at, stop)
  r.total = r.total + offer.slots
  h.amount = h.amount + offer.slots
  h.kg = math.floor(h.amount * (h.density or 1) + 0.5)
  job.tonnes = h.kg / 1000
  job.pay = job.pay + offer.pay
  job.fillPay = (job.fillPay or 0) + offer.pay
  job.minutes = job.minutes + offer.minutes
  job.km = job.km + offer.detourKm
  job.to = r.stops[r.at]
  return true
end

return M
