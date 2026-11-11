-- Customer ratings and the two reputations built from them: Courier (food orders) and Freight (van, truck and
-- company work). Every finished, ruined or cancelled order leaves 1 to 5 stars; a reputation is the average of the
-- latest ones. Pure rules: no game calls here.
local M = {}

M.KEEP = { courier = 50, freight = 30 }   -- ratings a reputation is averaged over
M.NEW_SCORE = 4.5                         -- shown and used until the first rating arrives
M.PREMIUM_AT, M.PREMIUM_MIN = 4.7, 10     -- courier: premium orders from this score, after this many ratings
M.PREMIUM_ONE_IN = 4                      -- then about one order in four is a premium one
M.PREMIUM_PAY, M.PREMIUM_TIME = 1.4, 0.85 -- a premium order pays more and wants the food sooner
M.SLOW_BELOW, M.SLOWER_BELOW = 4.0, 3.5   -- courier: orders ring less often below these
M.PREFERRED_AT, M.PREFERRED_MIN = 4.7, 5  -- freight: a preferred carrier is paid a bonus
M.PREFERRED_PAY, M.POOR_BELOW, M.POOR_PAY = 1.08, 3.5, 0.9
M.LATE_STEP = 0.2                         -- a star lost per this share of the time limit over it
M.CONDITION_STEP = 20                     -- a star lost per this many % of cargo damage

function M.track(job)
  return (type(job) == 'table' and job.kind == 'food') and 'courier' or 'freight'
end

local function clamp(n) return math.max(1, math.min(5, n)) end

-- Stars for a delivered order. minutes: time used, limit: time allowed, condition: cargo 0..100,
-- penalty: stars already lost on the way (a speed camera).
function M.stars(minutes, limit, condition, penalty)
  local stars = 5
  local over = (tonumber(minutes) or 0) / math.max(1, tonumber(limit) or 1) - 1
  if over > 0 then stars = stars - math.min(3, math.ceil(over / M.LATE_STEP - 1e-9)) end
  local lost = 100 - math.max(0, math.min(100, tonumber(condition) or 100))
  if lost > 0 then stars = stars - math.min(3, math.ceil(lost / M.CONDITION_STEP - 1e-9)) end
  return clamp(stars - (tonumber(penalty) or 0))
end

local NOTES = {
  courier = {
    [5] = { 'Still hot, thank you!', 'Fast and careful. Perfect.', 'Great delivery.' },
    [4] = { 'Good, thanks.', 'Arrived fine.' },
    [3] = { 'It was okay.', 'Took a while.' },
    [2] = { 'Late and a bit of a mess.', 'Not great.' },
    [1] = { 'Never again.', 'Cold and shaken.' },
  },
  freight = {
    [5] = { 'On time and intact.', 'Clean delivery.' },
    [4] = { 'Delivered as agreed.' },
    [3] = { 'Accepted with remarks.' },
    [2] = { 'Late or damaged goods noted.' },
    [1] = { 'Complaint filed.' },
  },
}

-- A short customer line for the receipt. `late` and `damaged` pick the wording that fits what went wrong.
function M.note(track, stars, late, damaged, seed)
  if stars <= 3 and track == 'courier' then
    if damaged and not late then return 'The food was shaken up.' end
    if late and not damaged then return 'It arrived late.' end
  elseif stars <= 3 then
    if damaged and not late then return 'Goods arrived damaged.' end
    if late and not damaged then return 'Delivered late.' end
  end
  local list = (NOTES[track] or NOTES.courier)[stars] or { '' }
  return list[((tonumber(seed) or 0) % #list) + 1]
end

function M.restore(c)
  if type(c.reputation) ~= 'table' then c.reputation = {} end
  for track in pairs(M.KEEP) do
    local r = c.reputation[track]
    if type(r) ~= 'table' then r = {} c.reputation[track] = r end
    if type(r.recent) ~= 'table' then r.recent = {} end
    r.count = tonumber(r.count) or #r.recent
  end
  return c.reputation
end

-- Records one rating (newest first) and returns the stars kept.
function M.add(c, track, stars)
  local r = M.restore(c)[track]
  if not r then return nil end
  stars = clamp(math.floor((tonumber(stars) or 1) + 0.5))
  table.insert(r.recent, 1, stars)
  while #r.recent > M.KEEP[track] do table.remove(r.recent) end
  r.count = r.count + 1
  return stars
end

-- score (one decimal), how many ratings it is averaged over, and the lifetime count
function M.score(c, track)
  local r = M.restore(c)[track]
  local n = r and #r.recent or 0
  if n == 0 then return M.NEW_SCORE, 0, 0 end
  local sum = 0
  for _, s in ipairs(r.recent) do sum = sum + s end
  return math.floor(sum / n * 10 + 0.5) / 10, n, r.count
end

-- The change between the older and newer half of the kept ratings: 'up', 'down' or 'steady'.
function M.trend(c, track)
  local recent = M.restore(c)[track].recent
  local n = #recent
  if n < 6 then return 'steady' end
  local half, new, old = math.floor(n / 2), 0, 0
  for i = 1, half do new = new + recent[i] end
  for i = n - half + 1, n do old = old + recent[i] end
  local d = (new - old) / half
  return d >= 0.25 and 'up' or (d <= -0.25 and 'down' or 'steady')
end

function M.premium(c)
  local score, n = M.score(c, 'courier')
  return n >= M.PREMIUM_MIN and score >= M.PREMIUM_AT
end

-- How much longer the phone waits before the next order rings (1 = normal).
function M.pingFactor(c)
  local score, n = M.score(c, 'courier')
  if n < 5 then return 1 end
  if score < M.SLOWER_BELOW then return 1.8 end
  if score < M.SLOW_BELOW then return 1.4 end
  return 1
end

-- The pay factor freight customers offer this carrier.
function M.freightPay(c)
  local score, n = M.score(c, 'freight')
  if n >= M.PREFERRED_MIN and score >= M.PREFERRED_AT then return M.PREFERRED_PAY end
  if n >= 5 and score < M.POOR_BELOW then return M.POOR_PAY end
  return 1
end

-- Turns an offered food order into a premium one (once).
function M.makePremium(job)
  if job.premium or job.kind ~= 'food' then return job end
  local bonus = job.sizeBonus or 0
  job.premium = true
  job.pay = math.floor(((job.pay - bonus) * M.PREMIUM_PAY) / 5 + 0.5) * 5 + bonus
  job.minutes = math.max(3, math.ceil(job.minutes * M.PREMIUM_TIME))
  return job
end

function M.state(c)
  local out = {}
  for _, track in ipairs({ 'courier', 'freight' }) do
    local score, n, count = M.score(c, track)
    out[track] = { score = score, rated = n, count = count, trend = M.trend(c, track), keep = M.KEEP[track] }
  end
  out.courier.premium, out.courier.premiumAt, out.courier.premiumMin = M.premium(c), M.PREMIUM_AT, M.PREMIUM_MIN
  out.courier.slow = M.pingFactor(c) > 1
  out.freight.payFactor, out.freight.preferredAt = M.freightPay(c), M.PREFERRED_AT
  return out
end

return M
