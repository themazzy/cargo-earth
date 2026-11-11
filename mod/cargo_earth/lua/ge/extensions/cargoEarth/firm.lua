-- Your own firm: founded once the career is established, with a headquarters at a real place and upgrades bought
-- for it. Drivers can only be hired by a firm. Pure rules: no game calls here.
local rating = require('cargoEarth/rating')
local progress = require('cargoEarth/progress')
local economy = require('cargoEarth/economy')
local jobs = require('cargoEarth/jobs')
local M = {}

M.FEE = 6000                           -- founding the firm
M.MIN_DELIVERIES = progress.DRIVER_AT  -- the Professional rank
M.MIN_SCORE, M.MIN_RATINGS = 4.0, 5    -- on either reputation
M.HQ_RADIUS = 80                       -- metres: "at the headquarters"
M.PLACE_RADIUS = 150                   -- a yard or warehouse this close can become the headquarters
M.MOVE_FEE = 1500                      -- moving the headquarters later
M.BASE_BAYS = 3                        -- cars without a home garage or any upgrade (as garage.CAR_LIMIT)
M.NAME_MAX = 28

-- value: bays = extra cars, workshop = share of a repair paid at the headquarters, tank = share of the fuel price
-- there, office = what hired drivers bring in.
M.UPGRADES = {
  { id = 'bays', name = 'Parking bays', levels = { { cost = 4000, value = 2 }, { cost = 9000, value = 4 }, { cost = 18000, value = 6 } },
    text = function(v) return string.format('Room for %d more vehicles', v) end },
  { id = 'workshop', name = 'Workshop', levels = { { cost = 5000, value = 0.85 }, { cost = 12000, value = 0.7 } },
    text = function(v) return string.format('Repairs at the headquarters cost %d %% less', math.floor((1 - v) * 100 + 0.5)) end },
  { id = 'tank', name = 'Fuel tank', levels = { { cost = 7000, value = 0.85 } },
    text = function(v) return string.format('Petrol and diesel at the headquarters for %d %% less', math.floor((1 - v) * 100 + 0.5)) end },
  { id = 'office', name = 'Dispatch office', levels = { { cost = 6000, value = 1.15 }, { cost = 14000, value = 1.3 } },
    text = function(v) return string.format('Hired drivers bring in %d %% more', math.floor((v - 1) * 100 + 0.5)) end },
}
local byId = {}
for _, u in ipairs(M.UPGRADES) do byId[u.id] = u end

local function point(g)
  return type(g) == 'table' and type(g[1]) == 'number' and type(g[2]) == 'number' and g[1] == g[1] and g[2] == g[2]
    and math.abs(g[1]) <= 90 and math.abs(g[2]) <= 180
end

-- A saved firm that does not make sense is dropped rather than trusted.
function M.restore(c)
  local f = c.firm
  if f == nil then return nil end
  if type(f) ~= 'table' or type(f.name) ~= 'string' then c.firm = nil return nil end
  if f.hq ~= nil and (type(f.hq) ~= 'table' or not point(f.hq.g)) then f.hq = nil end
  if type(f.upgrades) ~= 'table' then f.upgrades = {} end
  for id, level in pairs(f.upgrades) do
    local u = byId[id]
    level = tonumber(level)
    f.upgrades[id] = (u and level and level >= 1) and math.min(#u.levels, math.floor(level)) or nil
  end
  return f
end

function M.cleanName(name)
  name = tostring(name or ''):gsub('[%c<>]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if #name > M.NAME_MAX then
    name = name:sub(1, M.NAME_MAX)
    while #name > 0 and name:byte(#name) >= 128 and name:byte(#name) < 192 do name = name:sub(1, -2) end  -- whole UTF-8 letters
    if #name > 0 and name:byte(#name) >= 192 then name = name:sub(1, -2) end
  end
  return name
end

function M.defaultName(c)
  local town = type(c.home) == 'table' and type(c.home.town) == 'string' and c.home.town ~= '' and c.home.town or nil
  return M.cleanName((town and town .. ' ' or '') .. 'Cargo')
end

-- What founding needs: { { id, label, done, have, need } }, and whether all of it is met.
function M.requirements(c, debt)
  local delivered = tonumber(c.delivered) or 0
  local best, bestN = 0, 0
  for _, track in ipairs({ 'courier', 'freight' }) do
    local score, n = rating.score(c, track)
    if n >= M.MIN_RATINGS and score > best then best, bestN = score, n end
  end
  local list = {
    { id = 'rank', label = progress.DRIVER_RANK .. ' rank', done = delivered >= M.MIN_DELIVERIES,
      detail = string.format('%d / %d deliveries', math.min(delivered, M.MIN_DELIVERIES), M.MIN_DELIVERIES) },
    { id = 'reputation', label = string.format('Reputation %.1f or better', M.MIN_SCORE), done = bestN > 0 and best >= M.MIN_SCORE,
      detail = bestN > 0 and string.format('Your best is %.1f', best) or string.format('After %d ratings, courier or freight', M.MIN_RATINGS) },
    { id = 'debt', label = 'No debt', done = (debt or 0) <= 0,
      detail = (debt or 0) > 0 and string.format('%d CZK owed', debt) or 'Nothing owed' },
    { id = 'fee', label = 'Founding fee', done = (c.money or 0) >= M.FEE,
      detail = string.format('%d of %d CZK', math.max(0, math.min(M.FEE, math.floor(c.money or 0))), M.FEE) },
  }
  local ok = true
  for _, r in ipairs(list) do ok = ok and r.done end
  return list, ok
end

function M.found(c, name, debt)
  if c.firm then return false, 'You already run ' .. c.firm.name .. '.' end
  local list, ok = M.requirements(c, debt)
  if not ok then
    for _, r in ipairs(list) do
      if not r.done then return false, 'Not yet: ' .. r.label .. ' (' .. r.detail .. ').' end
    end
  end
  name = M.cleanName(name)
  if name == '' then name = M.defaultName(c) end
  if not economy.post(c, -M.FEE, 'firm', economy.nextId(c, 'firm'), 'Founded ' .. name) then return false, 'The payment failed.' end
  c.firm = { name = name, founded = os.date('%Y-%m-%d'), upgrades = {}, spent = M.FEE }
  return true, name .. ' is founded. Choose its headquarters next.'
end

function M.rename(c, name)
  if not c.firm then return false, 'Start a firm first.' end
  name = M.cleanName(name)
  if name == '' then return false, 'Type a name first.' end
  c.firm.name = name
  return true, 'The firm is now ' .. name .. '.'
end

function M.atHq(c, p)
  local hq = c.firm and c.firm.hq
  return hq and type(p) == 'table' and type(p.lat) == 'number' and type(p.lon) == 'number'
    and jobs.km(p.lat, p.lon, hq.g[1], hq.g[2]) * 1000 <= M.HQ_RADIUS or false
end

-- place: { id, n, town, g } the yard, warehouse or home the car is parked at. The parking point becomes the gate.
function M.setHq(c, place, pose)
  local f = c.firm
  if not f then return false, 'Start a firm first.' end
  if type(pose) ~= 'table' or pose.camera or (pose.speed or 0) > 1.5 or not point({ pose.lat, pose.lon }) then
    return false, 'Park your car where the headquarters should be.'
  end
  if type(place) ~= 'table' or not point(place.g) then
    return false, 'Park at a yard, a warehouse or your home garage to set up the headquarters.'
  end
  local fee = f.hq and M.MOVE_FEE or 0
  if fee > 0 and (c.money or 0) < fee then return false, string.format('Moving the headquarters costs %d CZK.', fee) end
  if fee > 0 then
    economy.post(c, -fee, 'firm', economy.nextId(c, 'firm'), 'Headquarters moved')
    f.spent = (f.spent or 0) + fee
  end
  f.hq = { id = place.id, n = place.n or 'Headquarters', town = place.town, g = { pose.lat, pose.lon } }
  return true, 'Headquarters set at ' .. f.hq.n .. '.'
end

function M.level(c, id)
  return c.firm and c.firm.upgrades and tonumber(c.firm.upgrades[id]) or 0
end

-- The upgrade's value at its current level, or nil when it is not built.
function M.value(c, id)
  local u, level = byId[id], M.level(c, id)
  return u and level > 0 and u.levels[math.min(level, #u.levels)].value or nil
end

function M.upgrade(c, id, debt)
  local f, u = c.firm, byId[id]
  if not f then return false, 'Start a firm first.' end
  if not u then return false, 'Unknown upgrade.' end
  if not f.hq then return false, 'Choose the headquarters first.' end
  local nextLevel = u.levels[M.level(c, id) + 1]
  if not nextLevel then return false, u.name .. ' is fully built.' end
  if (debt or 0) > 0 then return false, 'Pay your debt first.' end
  if (c.money or 0) < nextLevel.cost then return false, string.format('Not enough money (%d CZK needed).', nextLevel.cost) end
  economy.post(c, -nextLevel.cost, 'firm', economy.nextId(c, 'firm'), u.name)
  f.upgrades[id] = M.level(c, id) + 1
  f.spent = (f.spent or 0) + nextLevel.cost
  return true, u.name .. ': ' .. u.text(nextLevel.value) .. '.'
end

-- Vehicles the player may own: the home garage (or the first three) plus the firm's bays.
function M.capacity(c)
  local base = type(c.home) == 'table' and tonumber(c.home.capacity) or M.BASE_BAYS
  return base + (M.value(c, 'bays') or 0)
end

function M.repairFactor(c, p)
  return M.atHq(c, p) and M.value(c, 'workshop') or 1
end

function M.driverFactor(c)
  return M.value(c, 'office') or 1
end

-- Everything the phone and the headquarters screen show.
function M.state(c, p, debt)
  local f = c.firm
  if not f then
    local list, ok = M.requirements(c, debt)
    return { founded = false, requirements = list, ready = ok, fee = M.FEE, suggested = M.defaultName(c), nameMax = M.NAME_MAX }
  end
  local out = { founded = true, name = f.name, since = f.founded, spent = f.spent or 0, moveFee = M.MOVE_FEE,
    capacity = M.capacity(c), money = math.floor(c.money or 0), nameMax = M.NAME_MAX, upgrades = {} }
  if f.hq then
    out.hq = { name = f.hq.n, town = f.hq.town, g = f.hq.g, here = M.atHq(c, p),
      km = p and p.lat and math.floor(jobs.km(p.lat, p.lon, f.hq.g[1], f.hq.g[2]) * 10 + 0.5) / 10 or nil }
  end
  for i, u in ipairs(M.UPGRADES) do
    local level = M.level(c, u.id)
    local nextLevel = u.levels[level + 1]
    out.upgrades[i] = { id = u.id, name = u.name, level = level, max = #u.levels,
      now = level > 0 and u.text(u.levels[level].value) or nil,
      next = nextLevel and u.text(nextLevel.value) or nil, cost = nextLevel and nextLevel.cost or nil,
      can = nextLevel ~= nil and f.hq ~= nil and (debt or 0) <= 0 and (c.money or 0) >= nextLevel.cost }
  end
  return out
end

return M
