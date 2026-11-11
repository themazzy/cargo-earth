-- The delivery map and personal records. Each finished delivery leaves one small dot (where it was dropped
-- off); the newest TRAIL are kept in the save. Pure rules: the phone draws the dots.
local M = {}

M.TRAIL = 200

local function finite(n) return type(n) == 'number' and n == n and n > -math.huge and n < math.huge end

function M.restore(c)
  if type(c.trail) ~= 'table' then c.trail = {} end
  if type(c.records) ~= 'table' then c.records = {} end
  return c.trail, c.records
end

-- job: the delivered order; result: { pay, tip, minutes, stars, date (YYYY-MM-DD), earnedToday }
-- Returns the names of the records this delivery set.
function M.record(c, job, result)
  local trail, rec = M.restore(c)
  local g = job.to and job.to.g
  if type(g) == 'table' and finite(g[1]) and finite(g[2]) and math.abs(g[1]) <= 90 and math.abs(g[2]) <= 180 then
    table.insert(trail, 1, { math.floor(g[1] * 1e5 + 0.5) / 1e5, math.floor(g[2] * 1e5 + 0.5) / 1e5,
      job.kind == 'food' and 'c' or 'f', result.stars or 5 })
    while #trail > M.TRAIL do table.remove(trail) end
  end
  local set = {}
  local function best(key, value, row)
    if finite(value) and (not rec[key] or value > (rec[key].value or 0)) then
      row.value = value
      rec[key] = row
      set[#set + 1] = key
    end
  end
  local km = math.floor((tonumber(job.km) or 0) * 10 + 0.5) / 10
  local total = (result.pay or 0) + (result.tip or 0)
  best('longest', km, { to = job.to and job.to.n, date = result.date })
  best('bestPay', total, { to = job.to and job.to.n, cargo = job.cargoName, date = result.date })
  best('bestTip', result.tip or 0, { to = job.to and job.to.n, date = result.date })
  if result.earnedToday then best('bestDay', result.earnedToday, { date = result.date }) end
  -- the quickest delivery against its time limit, for orders of at least 1 km
  if km >= 1 and finite(result.minutes) and finite(job.minutes) and job.minutes > 0 then
    local spare = math.floor((1 - result.minutes / job.minutes) * 100 + 0.5)
    if spare > 0 then best('quickest', spare, { to = job.to and job.to.n, minutes = math.floor(result.minutes + 0.5), date = result.date }) end
  end
  rec.streak = (result.stars or 0) >= 5 and (rec.streak or 0) + 1 or 0
  if rec.streak > (rec.bestStreak or 0) then
    rec.bestStreak = rec.streak
    if rec.streak >= 3 then set[#set + 1] = 'streak' end
  end
  return set
end

-- A ruined or cancelled order ends a five-star run.
function M.broken(c)
  local _, rec = M.restore(c)
  rec.streak = 0
end

-- For the phone: dots scaled into a 0..100 square (north up), with the box they cover.
function M.map(c, home, hq)
  local trail = M.restore(c)
  local out = { dots = {}, count = #trail }
  local minLat, maxLat, minLon, maxLon
  local function grow(lat, lon)
    minLat, maxLat = math.min(minLat or lat, lat), math.max(maxLat or lat, lat)
    minLon, maxLon = math.min(minLon or lon, lon), math.max(maxLon or lon, lon)
  end
  for _, d in ipairs(trail) do grow(d[1], d[2]) end
  local marks = {}
  if home and home.g then marks[#marks + 1] = { home.g[1], home.g[2], 'home' } end
  if hq and hq.g then marks[#marks + 1] = { hq.g[1], hq.g[2], 'hq' } end
  if not minLat then return out end
  for _, m in ipairs(marks) do grow(m[1], m[2]) end
  -- the same scale both ways, so the map is not stretched
  local midLat = (minLat + maxLat) / 2
  local kLon = math.max(0.2, math.cos(math.rad(midLat)))
  local span = math.max((maxLat - minLat), (maxLon - minLon) * kLon, 0.004) * 1.12
  local midLon = (minLon + maxLon) / 2
  local function xy(lat, lon)
    return math.floor((50 + (lon - midLon) * kLon / span * 100) * 10 + 0.5) / 10,
      math.floor((50 - (lat - midLat) / span * 100) * 10 + 0.5) / 10
  end
  for i, d in ipairs(trail) do
    local x, y = xy(d[1], d[2])
    out.dots[i] = { x = x, y = y, k = d[3], s = d[4] }
  end
  out.marks = {}
  for i, m in ipairs(marks) do
    local x, y = xy(m[1], m[2])
    out.marks[i] = { x = x, y = y, k = m[3] }
  end
  out.spanKm = math.floor(span * 111.32 * 10 + 0.5) / 10
  return out
end

function M.state(c, home, hq)
  local _, rec = M.restore(c)
  local out = M.map(c, home, hq)
  out.records = { longest = rec.longest, bestPay = rec.bestPay, bestTip = rec.bestTip, bestDay = rec.bestDay,
    quickest = rec.quickest, streak = rec.streak or 0, bestStreak = rec.bestStreak or 0 }
  return out
end

return M
