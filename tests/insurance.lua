-- Vehicle insurance (cargoEarth/insurance): premiums, claims, the reckless-crash verdict and the garage's repairs.
local ins = require('cargoEarth/insurance')
local garage = require('cargoEarth/garage')

-- the verdict: up to 15 km/h over is fine, then half, then refused
local function hist(samples)
  local h = {}
  for _, s in ipairs(samples) do ins.sample(h, s[1], s[2], s[3]) end
  return h
end
local h = hist({ { 0, 60, 50 }, { 1, 64, 50 }, { 2, 30, 50 } })
local v = ins.judge(h, 2.1)
assert(v.share == 1 and v.why == nil and v.speed == 64 and v.limit == 50, 'within leniency')
v = ins.judge(hist({ { 0, 70, 50 }, { 1, 72, 50 } }), 1.1)
assert(v.share == ins.CUT and v.why:find('cut in half', 1, true), 'over the leniency: cut')
v = ins.judge(hist({ { 0, 95, 50 }, { 1, 96, 50 } }), 1.1)
assert(v.share == 0 and v.why:find('refused', 1, true), 'far over: refused')
-- the crash speed is the top speed just before the hit, not the speed after it
v = ins.judge(hist({ { 0, 40, 50 }, { 5, 90, 50 }, { 6, 10, 50 } }), 9)
assert(v.share == 1, 'an old top speed is not the crash speed')
-- a limit that just dropped (70 -> 30 for a short stretch) still counts as 70 while the driver could not react
local drop = hist({ { 0, 70, 70 }, { 1, 70, 70 }, { 1.2, 68, 30 }, { 2.0, 66, 30 } })
v = ins.judge(drop, 2.1)
assert(v.share == 1 and v.limit == 70, 'no time to react to the lower limit: ' .. tostring(v.limit))
-- 4.3 s of grace for 70 -> 30 (1.5 s + 40 km/h at 4 m/s²): later the new limit counts
local late = hist({ { 0, 70, 70 }, { 1, 70, 70 }, { 1.2, 68, 30 }, { 7, 66, 30 }, { 8, 66, 30 } })
v = ins.judge(late, 8.1)
assert(v.limit == 30 and v.share == ins.CUT, 'long after the sign: the new limit counts')
-- no known limit: no judgement; a camera flash moments before: cut
assert(ins.judge(hist({ { 0, 150 } }), 0.1).share == 1, 'unknown limit is not reckless')
v = ins.judge(hist({ { 0, 40, 50 } }), 0.1, -20)
assert(v.share == ins.CUT and v.why:find('reckless', 1, true), 'camera flash before the crash')
assert(ins.judge(hist({ { 0, 40, 50 } }), 0.1, -100).share == 1, 'an old flash does not count')
-- one crash = one verdict
local sess = {}
local v1, fresh1 = ins.verdict(sess, hist({ { 0, 95, 50 } }), 0.1)
local v2, fresh2 = ins.verdict(sess, hist({ { 0, 10, 50 } }), 1.5)
assert(fresh1 and not fresh2 and v2 == v1, 'hits of one crash share the verdict')

-- buying: own car, standing, not on a job; active at once; first day charged
local g = { car = { name = 'Pigeon', value = 7000 } }
local c = { money = 1000 }
assert(ins.buyBlock(g, g.car, { own = true, onJob = true }):find('Finish'), 'not on a job')
assert(ins.buyBlock(g, g.car, { own = true, speed = 5 }):find('Stop'), 'standing still')
assert(ins.buyBlock(g, { loaner = true, value = 1 }, { own = true }), 'no company vehicles')
assert(ins.buyBlock(g, { driver = {}, value = 1 }, { own = true }), 'no hired drivers\' cars')
local ok, _, day = ins.buy(g, c, g.car, { own = true, speed = 0 }, 100)
assert(ok and day == ins.hourPremium(g, g.car) and day == 10, 'first hour: 3 % of 7000 / 21 = 10, got ' .. tostring(day))
assert(ins.weekPremium(g, g.car) == 210)
-- billing: a day per hour of play, parked cars too; a car a driver took over is dropped
local parked = { name = 'Van', value = 3500, insured = { since = 100, paidUntil = 100 } }
local due = ins.bill(g, { g.car, parked }, 100 + ins.BILL_S - 1)
assert(due == 5, 'parked van hour due at once: ' .. due)
due = ins.bill(g, { g.car, parked }, 100 + ins.BILL_S * 3)
assert(due == 10 * 3 + 5 * 3, 'three more hours each: ' .. due)
parked.driver = { name = 'Eva' }
due = ins.bill(g, { g.car, parked }, 100 + ins.BILL_S * 4)
assert(due == 10 and parked.insured == nil, 'a hired driver\'s car is not insured')
-- a claim-free week lowers the rate, a claim raises it and restarts the week
ins.bill(g, { g.car }, 100 + 3600 * ins.WEEK_HOURS + 1)
assert(g.insurance.rate == 2.75, 'clean week: ' .. g.insurance.rate)
g.car.insCover = 1000
assert(ins.quote(g.car, 1000, 1000) == 900, '10 % deductible')
assert(ins.quote(g.car, 2000, 2000) == 900, 'only the covered part')
local claimAt = 100 + 3600 * (ins.WEEK_HOURS + 1)
ins.claim(g, g.car, 1, 900, claimAt)
assert(ins.rate(g) == 3.25 and g.car.insCover == 0 and g.insurance.claims == 1, 'claim raises the rate')
-- the claim surcharge lasts 3 hours of play, then the base rate is back
ins.bill(g, { g.car }, claimAt + 3600 * 3 - 1)
assert(ins.rate(g) == 3.25, 'surcharge still on')
ins.bill(g, { g.car }, claimAt + 3600 * 3)
assert(ins.rate(g) == 2.75 and g.insurance.rate == 2.75, 'surcharge over: ' .. ins.rate(g))
assert(ins.wrecked(g.car, 3500, 3500) and not ins.wrecked(g.car, 100, 3500), 'write-off at the repair cap')

-- the garage: a hit on an insured car adds its covered share; repair with or without the claim
local gg = { car = { name = 'Pigeon', value = 10000, insured = { since = 0, paidUntil = 1e9 } }, repair = 0, lastDamage = 0 }
local what, grow = garage.trackDamage(gg, 10000)
assert(what == 'hit' and grow > 0)
ins.hit(gg.car, grow, { share = 1 })
local G = { repair = function() end }
local career = { money = 100000 }
local pays, cost = garage.repairInsured(gg, 1)
assert(pays == math.floor(cost * 0.9 + 0.5), 'insurer pays 90 %')
local ok2, msg, own, paid = garage.repairCar(G, gg, career, 1, false, 10)
assert(ok2 and own == cost and paid == 0 and gg.insurance == nil, 'paying it all yourself makes no claim')
-- a half-covered reckless crash, claimed
gg.repair, gg.lastDamage, gg.damageBaseline = 0, 0, nil
what, grow = garage.trackDamage(gg, 10000)
ins.hit(gg.car, grow, { share = 0.5 })
local before = career.money
ok2, msg, own, paid = garage.repairCar(G, gg, career, 1, true, 20)
assert(ok2 and paid == math.floor(grow * 0.5 * 0.9 + 0.5) and before - career.money == grow - paid, msg)
assert(gg.insurance.claims == 1 and gg.car.insCover == 0)
-- the game menu's free repair: the insurer pays its share, only the rest is debt
gg.repair, gg.lastDamage, gg.damageBaseline, gg.debt, gg.fixUntil = 0, 0, nil, 0, nil
what, grow = garage.trackDamage(gg, 10000)
ins.hit(gg.car, grow, { share = 1 })
local w, toDebt, insPaid = garage.trackDamage(gg, 0)
assert(w == 'debt' and insPaid == math.floor(grow * 0.9 + 0.5) and toDebt == grow - insPaid and gg.debt == toDebt, 'menu repair')
-- a write-off fully fixed in the game menu is no longer a write-off
gg.car.insWreck, gg.fixUntil = true, nil
garage.trackDamage(gg, 10000)
garage.trackDamage(gg, 0)
assert(gg.car.insWreck == nil, 'menu repair clears the write-off')
print('Insurance: leniency, limit drops, camera flash, premiums, claim-free weeks, claims, deductible and repairs passed')
