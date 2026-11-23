-- Vehicle insurance (Jan, 2026-11-23, issue #125). One kind of cover, for the player's own cars only (hired drivers'
-- cars and company vehicles are insured by someone else):
--   * a premium per insured car, RATE % of its value per insurance week (WEEK_DAYS days of DAY_S play time each),
--     billed a day ahead and charged also while the car stands parked;
--   * bought only while not on a job and standing still, and it covers from that moment;
--   * a claim pays the real repair bill (from the game's damage) minus a DEDUCTIBLE share;
--   * every claim raises the rate for a while (CLAIM_UP), every claim-free week lowers it (CLEAN_DOWN);
--   * a crash at reckless speed is cut or refused: over the road's limit by more than LENIENCY_KMH, judged against
--     the limit the driver could react to (a limit that just dropped still counts as the old one for a moment), or
--     shortly after a speed camera flashed the car.
-- Pure rules: the clock, money and the road are passed in. Kept on the garage: g.insurance (the driver's record) and on
-- each car: car.insured { since, paidUntil } and car.insCover (CZK of the current repair bill the insurer covers).
local M = {}

M.DAY_S = 3600            -- an insurance day: an hour of play
M.WEEK_DAYS = 7
M.RATE_START, M.RATE_MIN, M.RATE_MAX = 3, 2, 4   -- % of the car's value per week
M.CLAIM_UP = 0.5          -- each claim adds this to the rate
M.CLEAN_DOWN = 0.25       -- each claim-free week takes this off
M.DEDUCTIBLE = 0.10       -- the driver pays this share of every claim
M.LENIENCY_KMH = 15       -- this much over the limit is still a normal crash
M.REFUSE_KMH = 25         -- more than this over the leniency: the claim is refused (up to it: cut in half)
M.CUT = 0.5
M.REACT_S = 1.5           -- a limit that drops counts after a reaction time ...
M.BRAKE = 4               -- ... plus the time to brake down to it at this many m/s²
M.SPEED_S = 2             -- the crash speed: the highest speed in this many seconds before the hit
M.LIMIT_FRESH_S = 3       -- a limit read longer ago than this is not known
M.CAMERA_S = 60           -- a crash this soon after a speed camera flash counts as reckless (cut in half)
M.INCIDENT_S = 3          -- hits this close together are one crash (one verdict)
M.HISTORY_S = 30
M.SAMPLE_S = 0.2
M.LOG_MAX = 20

local function round(x) return math.floor(x + 0.5) end

function M.ensure(g)
  local r = type(g.insurance) == 'table' and g.insurance or {}
  r.rate = math.max(M.RATE_MIN, math.min(M.RATE_MAX, tonumber(r.rate) or M.RATE_START))
  r.claims, r.paid, r.received = tonumber(r.claims) or 0, tonumber(r.paid) or 0, tonumber(r.received) or 0
  r.log = type(r.log) == 'table' and r.log or {}
  g.insurance = r
  return r
end

local function note(r, what, amount)
  table.insert(r.log, 1, { what = what, amount = amount, at = os.date('%Y-%m-%d %H:%M') })
  while #r.log > M.LOG_MAX do table.remove(r.log) end
end

-- Cars the insurance can cover: owned by the player, not a company loaner, not driven by a hired driver.
function M.eligible(car)
  return type(car) == 'table' and not car.loaner and not car.driver and not car.standIn
end
function M.insured(car) return type(car) == 'table' and type(car.insured) == 'table' end

function M.value(car) return math.max(0, tonumber(car and car.value) or tonumber(car and car.paid) or 0) end

function M.weekPremium(g, car)
  return round(M.value(car) * M.ensure(g).rate / 100)
end
function M.dayPremium(g, car)
  local v = M.value(car)
  if v <= 0 then return 0 end
  return math.max(1, round(v * M.ensure(g).rate / 100 / M.WEEK_DAYS))
end

-- Why the car can't be insured now, or nil. ctx: { onJob, speed (m/s), own (the player sits in it) }.
function M.buyBlock(g, car, ctx)
  ctx = ctx or {}
  if not M.eligible(car) then return 'Only your own cars can be insured.' end
  if M.insured(car) then return 'This car is already insured.' end
  if not ctx.own then return 'Get in your car first.' end
  if ctx.onJob then return 'Finish your current work first.' end
  if (ctx.speed or 0) > 1 then return 'Stop the car first.' end
  if M.value(car) <= 0 then return 'The car\'s value is not known yet. Try again in a few seconds.' end
end

-- Insures the car from `now` (play seconds) and charges its first day. Returns ok, message, charged.
function M.buy(g, career, car, ctx, now)
  local why = M.buyBlock(g, car, ctx)
  if why then return false, why end
  local r = M.ensure(g)
  local day = M.dayPremium(g, car)
  if (career.money or 0) < day then return false, string.format('Not enough money for the first day (%d CZK).', day) end
  car.insured = { since = now or 0, paidUntil = (now or 0) + M.DAY_S }
  car.insCover = 0
  r.paid = r.paid + day
  if not r.cleanFrom then r.cleanFrom = now or 0 end
  note(r, 'Insured ' .. tostring(car.name or 'a car'), -day)
  return true, string.format('%s is insured. %d CZK a week (%d CZK charged for the first day).',
    tostring(car.name or 'The car'), M.weekPremium(g, car), day), day
end

function M.cancel(g, car)
  if not M.insured(car) then return false, 'This car is not insured.' end
  car.insured = nil
  note(M.ensure(g), 'Insurance ended: ' .. tostring(car.name or 'a car'), 0)
  return true, string.format('Insurance on %s ended. Crashes already covered can still be claimed.', tostring(car.name or 'the car'))
end

-- The days due since the last bill, for every insured car (cars: the one in use and the parked ones), and the
-- claim-free weeks. Returns the CZK due now and a one-line detail; the caller takes it from the money (the rest is debt).
-- A car a hired driver took over is no longer covered.
function M.bill(g, cars, now)
  local r = M.ensure(g)
  local due, any, names = 0, false, {}
  for _, car in ipairs(cars) do
    if M.insured(car) then
      if not M.eligible(car) then
        car.insured = nil
        note(r, 'Insurance ended (a driver took the car): ' .. tostring(car.name or 'a car'), 0)
      else
        any = true
        local days = 0
        local paidUntil = tonumber(car.insured.paidUntil) or now
        if paidUntil > now + M.DAY_S then paidUntil = now end   -- the clock went back (another save)
        while paidUntil <= now and days < 48 do
          paidUntil, days = paidUntil + M.DAY_S, days + 1
        end
        car.insured.paidUntil = paidUntil
        if days > 0 then
          due = due + M.dayPremium(g, car) * days
          names[#names + 1] = tostring(car.name or 'car')
        end
      end
    end
  end
  -- claim-free weeks lower the rate, only while something is insured
  local week = M.DAY_S * M.WEEK_DAYS
  if not any or not r.cleanFrom or r.cleanFrom > now or r.cleanAgain then r.cleanFrom, r.cleanAgain = now, nil
  else
    while now - r.cleanFrom >= week do
      r.cleanFrom = r.cleanFrom + week
      if r.rate > M.RATE_MIN then
        r.rate = math.max(M.RATE_MIN, r.rate - M.CLEAN_DOWN)
        note(r, string.format('A week without claims: rate down to %g %%', r.rate), 0)
      end
    end
  end
  if due > 0 then
    r.paid = r.paid + due
    note(r, 'Premium: ' .. table.concat(names, ', '), -due)
  end
  return due, 'Insurance premium: ' .. table.concat(names, ', ')
end

------------------------------------------------------------------------------------------ was the crash reckless?

-- One sample per SAMPLE_S of play: the speed (km/h) and the road's limit (km/h, nil off a known limit).
function M.sample(hist, t, kmh, limit)
  local last = hist[#hist]
  if last and t - last.t < M.SAMPLE_S then
    last.kmh = math.max(last.kmh, kmh or 0)   -- keep the top speed of that moment
    if limit then last.limit = limit end
    return
  end
  hist[#hist + 1] = { t = t, kmh = kmh or 0, limit = limit }
  while hist[1] and t - hist[1].t > M.HISTORY_S do table.remove(hist, 1) end
end

-- The verdict on a crash at `t`: { share (of the bill the insurer covers: 1, CUT or 0), why (nil when covered in
-- full), speed, limit }. flashAt: when a speed camera last measured the car too fast (nil: never).
function M.judge(hist, t, flashAt)
  local now, speed = nil, 0
  for i = #hist, 1, -1 do
    local s = hist[i]
    if t - s.t > M.HISTORY_S then break end
    if t - s.t <= M.SPEED_S then speed = math.max(speed, s.kmh or 0) end
    if not now and s.limit and t - s.t <= M.LIMIT_FRESH_S then now = s.limit end
  end
  speed = round(speed)
  local v = { share = 1, speed = speed }
  if now then
    -- a higher limit seen moments ago still counts while the driver could not have slowed down to the new one
    local limit = now
    for _, s in ipairs(hist) do
      if s.limit and s.limit > limit then
        local grace = M.REACT_S + (s.limit - now) / 3.6 / M.BRAKE
        if t - s.t <= grace then limit = s.limit end
      end
    end
    v.limit = limit
    local over = speed - limit - M.LENIENCY_KMH
    if over > M.REFUSE_KMH then
      v.share, v.why = 0, string.format('%d km/h where the limit is %d: claim refused', speed, limit)
      return v
    elseif over > 0 then
      v.share, v.why = M.CUT, string.format('%d km/h where the limit is %d: claim cut in half', speed, limit)
      return v
    end
  end
  if flashAt and t - flashAt >= 0 and t - flashAt <= M.CAMERA_S then
    v.share, v.why = M.CUT, 'a speed camera flashed you just before: claim cut in half'
  end
  return v
end

-- The verdict for a hit at `t`: hits close together share the first one's verdict. sess: session table.
-- fresh is true for the first hit of a crash.
function M.verdict(sess, hist, t, flashAt)
  local last = sess.incident
  if last and t - last.t <= M.INCIDENT_S and t >= last.t then
    last.t = t
    return last.v, false
  end
  local v = M.judge(hist, t, flashAt)
  sess.incident = { t = t, v = v }
  return v, true
end

-- A hit added `grow` CZK to the repair bill of `car`: the insurer covers its share (only on an insured car).
function M.hit(car, grow, v)
  if not M.insured(car) or not M.eligible(car) or (grow or 0) <= 0 then return 0 end
  local add = grow * (v and v.share or 1)
  car.insCover = (tonumber(car.insCover) or 0) + add
  return add
end

-- Keeps the covered part within the bill (a bill can shrink: a restored snapshot, a cap).
function M.clamp(car, bill)
  if car and car.insCover then car.insCover = math.max(0, math.min(tonumber(car.insCover) or 0, bill or 0)) end
end

-- What the insurer pays of a charge `cost` for (part of) a repair bill `bill`.
function M.quote(car, bill, cost)
  local cover = math.min(tonumber(car and car.insCover) or 0, bill or 0)
  if cover <= 0 or (bill or 0) <= 0 or (cost or 0) <= 0 then return 0 end
  return round(cost * cover / bill * (1 - M.DEDUCTIBLE))
end

-- Claims `payout` (from quote) for a repair that cleared `share` of the bill: the covered part shrinks with it, and a
-- claim raises the rate. now: play seconds.
function M.claim(g, car, share, payout, now, what)
  if car and car.insCover then car.insCover = car.insCover * (1 - math.max(0, math.min(1, share or 1))) end
  if car and (car.insCover or 0) < 1 then car.insCover = 0 end
  if (payout or 0) <= 0 then return 0 end
  local r = M.ensure(g)
  r.claims, r.received = r.claims + 1, r.received + payout
  r.rate = math.min(M.RATE_MAX, r.rate + M.CLAIM_UP)
  if now then r.cleanFrom = now else r.cleanAgain = true end   -- (no clock here: the next bill restarts the week)
  note(r, (what or 'Claim') .. string.format(': insurance paid (rate now %g %%)', r.rate), payout)
  return payout
end

-- The insured car is a write-off (the repair reached its cap): the free tow is offered.
function M.wrecked(car, bill, cap)
  return M.insured(car) and M.eligible(car) and cap ~= nil and cap > 0 and (bill or 0) >= cap or false
end

-- For the phone: the driver's record and the car's cover.
function M.state(g, car, cars)
  local r = M.ensure(g)
  local out = { rate = r.rate, claims = r.claims, paid = r.paid, received = r.received, deductible = M.DEDUCTIBLE,
    leniency = M.LENIENCY_KMH, dayHours = M.DAY_S / 3600, weekDays = M.WEEK_DAYS, log = {} }
  for i = 1, math.min(6, #r.log) do out.log[i] = r.log[i] end
  if car and M.eligible(car) then
    out.car = { name = car.name, insured = M.insured(car), week = M.weekPremium(g, car), day = M.dayPremium(g, car),
      cover = round(tonumber(car.insCover) or 0) }
  end
  out.cars, out.weekTotal = 0, 0
  for _, c in ipairs(cars or {}) do
    if M.insured(c) then out.cars, out.weekTotal = out.cars + 1, out.weekTotal + M.weekPremium(g, c) end
  end
  return out
end

return M
