-- cargoEarth/garage: the courier's own car. A career starts in a cheap old car with little money; the car's real
-- BeamNG parts are bought and swapped in the garage, repairs cost money (a free repair from the pause menu becomes
-- debt), and better cars are bought used with the old one traded in. Pure logic: every game call goes through an adapter G (cargoEarth/gamecar in the game,
-- stubs in the tests).
--
-- G (all may return nil when the game can't answer):
--   G.vehicle()                 -> { model, slotPartMap = { [slotPath] = partName }, tree = partsTree, ioCtx } (player)
--   G.part(ioCtx, name)         -> the part's jbeam table ({ information = { name, value }, slots2 | slots, slotType })
--   G.compatible(ioCtx, slotDef)-> list of part names that fit the slot
--   G.applyTree(tree)           -> puts the parts tree on the player's car (the game respawns it)
--   G.applyConfig(v, config)    -> respawns that specific vehicle with a complete config
--   G.configs()                 -> list of { model, key, name, value, brand, type } of every car config
--   G.spawn(model, key)         -> replaces the player's car
--   G.repair()                  -> fixes the player's car
--
-- Slot paths are the game's: '/' is the car's main part, '/pigeon_engine/' the engine slot under it, and so on; the
-- slot's id is the path's last name, its parent the path without it.
local M = {}

M.USED_CAR = 0.6             -- used cars cost this share of their value
M.TRADE_IN = 0.5             -- the old car is taken for this share of its parts' value
M.SELL_PART = 0.4            -- spare parts sell for this share
M.STARTER_MODEL = 'pigeon'   -- the cheapest config of this model is the starter car
M.CAR_LIMIT = 3              -- owned cars you can keep before choosing a home (a home sets its own capacity)
local STARTER_KM, STARTER_CONDITION = 170000, 0.27
local WEAR_VERSION = 2

-- Prices follow what deliveries pay. M.scale(income) sets every price from a courier's pay for an hour of play
-- (M.courierIncome: cargoEarth/food's pay rules for a typical order); the targets are in hours of deliveries.
M.VALUE_PER_HOUR = 2000      -- an hour of deliveries buys this much BeamNG value (a 10 000 car: 5 hours)
M.REPAIR_SHARE = 0.18        -- a repair: this share of the value rate per unit of the game's damage
M.START_HOURS = 1.5          -- money at the start of a career
M.MIN_PART_HOURS = 0.02      -- the cheapest part (about a minute of deliveries)
M.REPAIR_CAP = 0.5           -- a repair never costs more than this share of the car's parts value (a wreck is a write-off)
M.PRICE_V = 2                -- prices' version in saves (1: the first fixed prices)

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

-- CZK a courier makes in an hour: a typical order (3 km straight from the restaurant, 1.5 km ride to it), a tip for
-- a fairly quick delivery, 30 km/h in town and 4 minutes of stops and waiting per order.
function M.courierIncome(food)
  local road, ride = 3 * food.ROAD_FACTOR, 1.5 * food.ROAD_FACTOR
  local pay = food.pay(road)
  local tip = pay * food.TIP_MAX * 0.4
  local minutes = (road + ride) / 30 * 60 + 4
  return (pay + tip) * 60 / minutes
end

function M.scale(income)
  M.INCOME_PER_HOUR = income
  M.PRICE_PER_VALUE = income / M.VALUE_PER_HOUR             -- CZK per unit of a part's or car's BeamNG value
  M.REPAIR_PER_DAMAGE = M.PRICE_PER_VALUE * M.REPAIR_SHARE   -- repair price: CZK per unit of the game's damage
  M.START_MONEY = math.floor(income * M.START_HOURS / 50 + 0.5) * 50
  M.MIN_PART_PRICE = math.max(5, round5(income * M.MIN_PART_HOURS))
end
do
  local ok, food = pcall(require, 'cargoEarth/food')
  M.scale(ok and type(food) == 'table' and food.pay and M.courierIncome(food) or 430)
end

-- A price in hours of deliveries (for the phone)
function M.hours(price)
  return math.floor((tonumber(price) or 0) / M.INCOME_PER_HOUR * 10 + 0.5) / 10
end

M.DEBT_SHARE = 0.5           -- with a debt, this share of each delivery's pay goes to it
M.FIX_WINDOW_S = 6           -- after our own repair / respawn, a drop in damage within this time is not a free repair

-- the clock for FIX_WINDOW_S (core sets the game's)
M.clock = os.clock

-- Only drivable road vehicles are sold (the game's config list also has props: barrels, mattresses, signs...).
M.CAR_TYPES = { car = true, truck = true }
function M.isCar(c)
  local t = type(c.type) == 'string' and c.type:lower() or nil
  return t ~= nil and M.CAR_TYPES[t] == true
end

function M.new()
  return { started = false, car = nil, repair = 0, debt = 0, lastDamage = 0, inventory = {}, spent = 0, priceV = M.PRICE_V }
end

function M.partPrice(value) return math.max(M.MIN_PART_PRICE, round5((tonumber(value) or 0) * M.PRICE_PER_VALUE)) end

------------------------------------------------------------------------------------------ slots of the car

local function parentPath(path)
  return path:match('^(.*/)[^/]+/$')
end
M.parentPath = parentPath

local function slotId(path) return path:match('([^/]+)/$') end
M.slotId = slotId

local function info(G, ioCtx, name)
  if type(name) ~= 'string' or name == '' then return nil end
  local p = G.part(ioCtx, name)
  local i = type(p) == 'table' and type(p.information) == 'table' and p.information or {}
  return { part = name, name = type(i.name) == 'string' and i.name or name, value = tonumber(i.value) or 0, jbeam = p }
end

-- the definition of slot `id` among a part's child slots (slots2 by name, old slots by type)
local function slotDef(part, id)
  if not part then return nil end
  for _, d in pairs(part.slots2 or part.slots or {}) do
    if type(d) == 'table' and (d.name == id or (d.name == nil and d.type == id) or d[1] == id) then return d end
  end
end

local function vehicleSlot(G, v, path)
  local parent = parentPath(path)
  if not parent then return nil end
  local part = v.slotPartMap[parent]
  if not part and parent == '/' then part = v.tree and v.tree.chosenPartName end
  return part and part ~= '' and slotDef(G.part(v.ioCtx, part), slotId(path))
end

-- Every slot of the player's car with what's in it and what fits: { path, id, title, installed (info or nil),
-- options = { { part, name, value, price, owned } }, canEmpty }, sorted by title. nil, why when no car.
function M.slots(G, g)
  local v = G.vehicle()
  if not v or type(v.slotPartMap) ~= 'table' then return nil, 'No car' end
  local out = {}
  for path, partName in pairs(v.slotPartMap) do
    local def = vehicleSlot(G, v, path)
    if def then
      local opts = {}
      for _, name in ipairs(G.compatible(v.ioCtx, def) or {}) do
        if name ~= partName then
          local o = info(G, v.ioCtx, name)
          if o then
            opts[#opts + 1] = { part = name, name = o.name, value = o.value, price = M.partPrice(o.value),
              owned = (g.inventory[name] or 0) > 0 }
          end
        end
      end
      table.sort(opts, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.name < b.name end)
      local inst = info(G, v.ioCtx, partName)
      if #opts > 0 or inst then
        out[#out + 1] = { path = path, id = slotId(path), title = def.description or def[3] or slotId(path),
          installed = inst and { part = inst.part, name = inst.name, value = inst.value } or nil, options = opts,
          canEmpty = def.coreSlot ~= true and inst ~= nil }
      end
    end
  end
  table.sort(out, function(a, b) if a.title ~= b.title then return a.title < b.title end return a.path < b.path end)
  return out
end

-- The car's worth: its installed parts, in CZK.
local function valueOf(G, v)
  if not v or not G.part or type(v.slotPartMap) ~= 'table' then return 0 end
  local sum = 0
  for _, name in pairs(v.slotPartMap) do
    local i = info(G, v.ioCtx, name)
    if i then sum = sum + i.value end
  end
  return round5(sum * M.PRICE_PER_VALUE)
end
function M.carValue(G) return valueOf(G, G.vehicle()) end

-- Remembers what the car you drive is worth (g.car.value, CZK), which caps its repairs. Needs the game's car.
function M.noteValue(G, g, vehicle)
  if not g.car then return end
  local value = valueOf(G, vehicle or G.vehicle())
  if value > 0 then g.car.value = value end
end

-- The most a repair of the current car can cost, or nil while its value is not known.
function M.repairCap(g)
  local value = g.car and tonumber(g.car.value)
  if value and value > 0 then return round5(value * M.REPAIR_CAP) end
end

-- Puts `partName` ('' = nothing) in the slot at `path` of a parts tree; true when the slot was found.
function M.setInTree(tree, path, partName)
  local node = tree
  for id in path:gmatch('[^/]+') do
    node = node and node.children and node.children[id]
  end
  if not node then return false end
  node.chosenPartName = partName
  node.partPath = partName ~= '' and (path .. partName) or nil
  return true
end

-- A courier's car carries food in BeamNG's own cargo containers. The starter comes with the cheapest parcel box its
-- slots take: { path, part, name } or nil when this car fits none (then the invisible starter bag stands in).
local function isParcelBox(name)
  local n = name:lower()
  return n:find('cargo', 1, true) and n:find('box', 1, true) and not n:find('aggregate', 1, true)
    and not n:find('tank', 1, true) and not n:find('fluid', 1, true)
end

function M.planBox(G, v)
  if type(v.slotPartMap) ~= 'table' then return nil end
  for _, partName in pairs(v.slotPartMap) do
    if type(partName) == 'string' and partName ~= '' and isParcelBox(partName) then return nil end   -- already fitted
  end
  local best
  for path in pairs(v.slotPartMap) do
    local def = vehicleSlot(G, v, path)
    for _, name in ipairs(def and G.compatible(v.ioCtx, def) or {}) do
      if isParcelBox(name) then
        local i = info(G, v.ioCtx, name)
        if i and (not best or i.value < best.value or (i.value == best.value and name < best.part)) then
          best = { path = path, part = name, name = i.name, value = i.value }
        end
      end
    end
  end
  return best
end
M.isParcelBox = isParcelBox

-- The path of the slot on the car `v` that takes the part `partName` (empty or not), or nil.
-- The game's slot map lists only filled slots, so the parts tree (which has every slot, empty ones too) is walked as
-- well: a slot matches when the game lists the part as suitable for it, or when its id is the part's slot type.
function M.slotFor(G, v, partName)
  for path in pairs(type(v.slotPartMap) == 'table' and v.slotPartMap or {}) do
    local def = vehicleSlot(G, v, path)
    for _, name in ipairs(def and G.compatible(v.ioCtx, def) or {}) do
      if name == partName then return path end
    end
  end
  local p = G.part and G.part(v.ioCtx, partName)
  local slotType = type(p) == 'table' and p.slotType or nil
  local function walk(node, path)
    for id, child in pairs(type(node) == 'table' and type(node.children) == 'table' and node.children or {}) do
      local here = path .. id .. '/'
      for _, name in ipairs(type(child) == 'table' and type(child.suitablePartNames) == 'table' and child.suitablePartNames or {}) do
        if name == partName then return here end
      end
      if slotType and id == slotType then return here end
      local deeper = walk(child, here)
      if deeper then return deeper end
    end
  end
  return walk(v.tree, '/')
end

------------------------------------------------------------------------------------------ actions

M.FREE_PART = 'cargo_earth_phone_auto' -- the phone on the dashboard (cargoEarth/dash.lua)

-- Quote the complete difference after BeamNG has resolved the slots and any dependent parts.
-- Matching parts can move between slots without being bought again.
function M.partsQuote(G, inventory, before, vehicle)
  if type(before) ~= 'table' or not vehicle or type(vehicle.slotPartMap) ~= 'table' then
    return nil, 'Waiting for the vehicle parts to load.'
  end
  local delta, spares, items, total = {}, {}, {}, 0
  for part, count in pairs(inventory or {}) do spares[part] = count end
  for _, part in pairs(before) do
    if part == M.FREE_PART then -- the dash phone comes and goes with Settings: never bought
    elseif type(part) == 'string' and part ~= '' then delta[part] = (delta[part] or 0) - 1
    elseif part ~= '' and part ~= false then return nil, 'The saved parts list is unavailable. Discard the preview and try again.' end
  end
  for _, part in pairs(vehicle.slotPartMap) do
    if part == M.FREE_PART then
    elseif type(part) == 'string' and part ~= '' then delta[part] = (delta[part] or 0) + 1
    elseif part ~= '' and part ~= false then return nil, 'Waiting for BeamNG to resolve the selected parts.' end
  end
  for part, count in pairs(delta) do
    if count ~= 0 then
      local detail = info(G, vehicle.ioCtx, part)
      local owned = math.min(math.max(0, count), spares[part] or 0)
      local added, removed = math.max(0, count - owned), math.max(0, -count)
      if added > 0 and not detail.jbeam then return nil, 'Could not price ' .. part end
      local cost = added > 0 and added * M.partPrice(detail.value) or 0
      local left = (spares[part] or 0) + removed - owned
      spares[part] = left > 0 and left or nil
      items[#items + 1] = { part = part, name = detail.name, buy = added, fit = owned, keep = removed, cost = cost }
      total = total + cost
    end
  end
  table.sort(items, function(a, b) return a.name == b.name and a.part < b.part or a.name < b.name end)
  return { items = items, cost = total, inventory = spares }
end

-- Spare parts: { { part, name, count, price (to sell) } }
function M.spares(G, g)
  local v = G.vehicle()
  local out = {}
  for name, n in pairs(g.inventory) do
    local i = v and info(G, v.ioCtx, name)
    local value = i and i.value or 0
    out[#out + 1] = { part = name, name = i and i.name or name, count = n, price = round5(value * M.PRICE_PER_VALUE * M.SELL_PART) }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.sell(G, g, career, partName)
  if (g.inventory[partName] or 0) <= 0 then return false, 'Not in the spare parts' end
  local v = G.vehicle()
  local i = v and info(G, v.ioCtx, partName)
  local price = round5((i and i.value or 0) * M.PRICE_PER_VALUE * M.SELL_PART)
  g.inventory[partName] = g.inventory[partName] - 1
  if g.inventory[partName] <= 0 then g.inventory[partName] = nil end
  career.money = (career.money or 0) + price
  return true, string.format('Sold %s (+%d CZK)', i and i.name or partName, price), price
end

-- Damage. The repair price follows the game's damage number. When that number drops without us fixing the car (the
-- pause menu's repair or reset, a respawn), the car was repaired for free: its price becomes debt.
-- Returns 'hit', grow in CZK, grow in damage | 'debt', amount | nil.
function M.expectFix(g) g.fixUntil = M.clock() + M.FIX_WINDOW_S end

function M.trackDamage(g, damage)
  damage = tonumber(damage)
  if not damage then return nil end
  local last = g.lastDamage or 0
  g.lastDamage = damage
  local before = g.repair or 0
  g.repair = (g.carriedRepair or 0) + round5(math.max(0, damage) * M.REPAIR_PER_DAMAGE)
  local cap = M.repairCap(g)
  if cap and g.repair > cap then g.repair = cap end
  if damage > last then return 'hit', g.repair - before, damage - last end
  if damage < last then
    local ours = g.fixUntil and M.clock() <= g.fixUntil
    g.fixUntil = nil
    local freed = before - g.repair
    if not ours and freed > 0 then
      g.debt = (g.debt or 0) + freed
      return 'debt', freed
    end
  end
  return nil
end

-- factor: share of the bill actually charged (a firm's workshop at the headquarters), 1 when omitted.
function M.repairCar(G, g, career, factor)
  if (g.repair or 0) <= 0 then return false, 'Nothing to repair' end
  local cost = round5((g.repair or 0) * math.max(0, math.min(1, tonumber(factor) or 1)))
  if (career.money or 0) < cost then return false, string.format('Not enough money (%d CZK)', cost) end
  M.expectFix(g)
  local ok, err = pcall(G.repair)
  if not ok then g.fixUntil = nil return false, 'Repair failed: ' .. tostring(err) end
  career.money = career.money - cost
  g.repair, g.carriedRepair = 0, nil
  g.spent = (g.spent or 0) + cost
  return true, string.format('Repaired (-%d CZK)', cost), cost
end

-- Pays as much of the debt as the money allows.
function M.payDebt(g, career)
  local d = g.debt or 0
  if d <= 0 then return false, 'No debt' end
  local pay = math.min(d, math.max(0, math.floor(career.money or 0)))
  if pay <= 0 then return false, 'No money to pay with' end
  career.money = career.money - pay
  g.debt = d - pay
  return true, g.debt > 0 and string.format('Paid %d CZK, %d CZK debt left', pay, g.debt) or string.format('Debt paid off (%d CZK)', pay), pay
end

-- The part of a delivery's earnings that goes to the debt.
function M.takeForDebt(g, earned)
  local d = g.debt or 0
  if d <= 0 or earned <= 0 then return 0 end
  local take = math.min(d, math.floor(earned * M.DEBT_SHARE + 0.5))
  g.debt = d - take
  return take
end

------------------------------------------------------------------------------------------ cars

-- Used cars for sale: { { model, key, name, brand, price } }, cheapest first. filter: text in the name / brand.
function M.dealer(G, filter, limit)
  local out = {}
  filter = filter and filter ~= '' and filter:lower() or nil
  for _, c in ipairs(G.configs() or {}) do
    local value = tonumber(c.value)
    if value and value > 0 and M.isCar(c) then
      local label = ((c.brand and (c.brand .. ' ') or '') .. (c.name or c.key or '?'))
      if not filter or label:lower():find(filter, 1, true) then
        out[#out + 1] = { model = c.model, key = c.key, name = label, price = round5(value * M.PRICE_PER_VALUE * M.USED_CAR) }
      end
    end
  end
  table.sort(out, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.name < b.name end)
  if limit then while #out > limit do table.remove(out) end end
  return out
end

-- Buy a used car, trading in the one you have (its parts; spare parts are kept). Returns ok, message.
-- What a dealer pays for your car: its parts' worth, less for the kilometres on it.
function M.carWorth(G, g)
  if not g.car then return 0 end
  local km = g.car.km or 0
  return round5(M.carValue(G) * (1 - math.min(0.5, km / 300000)))
end

local function captureCurrent(G, g)
  if not g.car or not M.inOwnCar(G, g) then return true end
  if not M.remember(G, g) then return false end
  local damage = G.damage and G.damage()
  if damage and damage > (g.lastDamage or 0) then M.trackDamage(g, damage) end
  return true
end

local function park(g, car)
  if not car.fleetId then
    g.carSequence = (g.carSequence or 0) + 1
    car.fleetId = g.carSequence
  end
  g.parked = g.parked or {}
  g.parked[#g.parked + 1] = car
end

-- A new vehicle bought for the firm: straight into a bay at the headquarters (nothing is spawned).
function M.buyForFirm(g, career, offer, limit)
  if (g.debt or 0) > 0 then return false, 'Pay your debt first.' end
  if M.ownedCount(g) >= limit then return false, 'Every bay is taken. Build more bays or sell a vehicle.' end
  if (career.money or 0) < offer.price then return false, string.format('Not enough money (%d CZK needed).', offer.price) end
  career.money = career.money - offer.price
  park(g, { model = offer.model, key = offer.key, name = offer.name, km = 0, condition = 1, firm = true })
  return true, string.format('%s bought for %d CZK. It is parked at the headquarters.', offer.name, offer.price), offer.price
end

-- The game's price for a new config (its value), or nil.
function M.newPrice(G, model, key)
  for _, c in ipairs(G.configs() or {}) do
    if c.model == model and c.key == key and tonumber(c.value) and tonumber(c.value) > 0 then
      return round5(tonumber(c.value) * M.PRICE_PER_VALUE)
    end
  end
end

-- What a parked vehicle's repair costs before the workshop's share: damage, plus a breakdown you parked it with.
function M.parkedRepairCost(car)
  local broken = type(car.breakdown) == 'table' and tonumber(car.breakdown.cost) or 0
  return (car.parkedRepair or 0) + broken
end

-- Repairs a parked vehicle picked up (an accident or a breakdown), at the headquarters.
function M.repairParked(g, career, id, factor)
  local car = M.parkedCar(g, id)
  if not car then return false, 'That vehicle is not parked here.' end
  local cost = round5(M.parkedRepairCost(car) * (factor or 1))
  if cost <= 0 then return false, car.name .. ' needs no repair.' end
  if (career.money or 0) < cost then return false, string.format('Not enough money (%d CZK needed).', cost) end
  career.money = career.money - cost
  car.parkedRepair = 0
  if type(car.breakdown) == 'table' then
    if type(car.service) == 'table' and car.service[car.breakdown.id] then car.service[car.breakdown.id] = 0 end
    car.breakdown = nil
  end
  if car.driver then car.driver.waiting = nil end
  return true, string.format('%s repaired for %d CZK.', car.name, cost), cost
end

-- Owned cars: the one in use (not a loaner) and every parked one that isn't a loaner.
function M.ownedCount(g)
  local n = g.car and not g.car.loaner and 1 or 0
  for _, car in ipairs(g.parked or {}) do if not car.loaner then n = n + 1 end end
  return n
end

local function parkCurrent(g)
  if not g.car then return end
  g.car.parkedRepair = g.repair or 0
  park(g, g.car)
end

function M.issueFreightLoaner(G, g, career, tier, preset)
  g.freightLoaners = g.freightLoaners or {}
  if g.freightLoaners[tier] then return false, 'Your loaner is already in My cars.' end
  if g.preview or g.pendingUsed then return false, 'Finish preparing your current car first.' end
  local config = G.freightLoanerConfig and G.freightLoanerConfig(preset.model, preset.key)
  if not config then return false, 'The stock loaner configuration is unavailable.' end
  local loaner = { model = preset.model, key = preset.key, name = preset.name .. ' (loaner)', config = config,
    loaner = true, km = 0, condition = 1 }
  park(g, loaner)
  local ok, why = M.switchCar(G, g, loaner.fleetId)
  if not ok then table.remove(g.parked) return false, why end
  if not g.started then
    g.started = true
    career.money = math.max(career.money or 0, M.START_MONEY)
  end
  g.freightLoaners[tier] = true
  return true, 'Your loaner is ready. Go online in Trucking for freight jobs.'
end

function M.parkedCar(g, id)
  if not id then return end
  for i, car in ipairs(g.parked or {}) do
    if car.fleetId == id then return car, i end
  end
end

function M.switchCar(G, g, id)
  if g.preview then return false, 'Leave the dealer preview first.' end
  if g.pendingUsed then return false, 'Wait for your car to finish loading its parts.' end
  local car, index = M.parkedCar(g, id)
  if not car then return false, 'That car is no longer parked.' end
  if car.driver then return false, 'Release the driver before using this car.' end
  if not captureCurrent(G, g) then return false, 'Could not save the current car configuration.' end
  local ok, err = pcall(G.spawn, car.model, car.key, M.savedConfig(car))
  if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  table.remove(g.parked, index)
  parkCurrent(g)
  g.car, g.repair, g.lastDamage, g.fixUntil = car, car.parkedRepair or 0, 0, nil
  g.carriedRepair, car.parkedRepair = g.repair, nil
  return true, 'Now driving ' .. car.name .. '.'
end

-- opts: tradeIn (CZK for a preview), noSpawn (the listing is already live), keepCar (park the current car)
function M.buyCar(G, g, career, offer, opts)
  opts = opts or {}
  if (g.debt or 0) > 0 then return false, 'Pay your debt first' end
  if g.pendingUsed then return false, 'Wait for your car to finish loading its parts' end
  if g.car and g.car.loaner and not opts.keepCar then return false, 'Keep the loaner when buying another vehicle.' end
  if g.car and not opts.keepCar and not opts.noSpawn and not M.inOwnCar(G, g) then
    return false, 'Get into your car before trading it in.'
  end
  if opts.keepCar then
    -- Without a home the same limit applies, or parked cars (and their drivers) could grow without end.
    local limit = require('cargoEarth/firm').capacity(career)
    if M.ownedCount(g) >= limit then return false, 'Your garage is full. Trade in a car or sell one first.' end
  end
  if opts.keepCar and not captureCurrent(G, g) then return false, 'Could not save the current car configuration.' end
  local tradeIn = not opts.keepCar and (opts.tradeIn or
    ((g.car and M.inOwnCar(G, g)) and round5(M.carWorth(G, g) * M.TRADE_IN) or 0)) or 0
  local cost = offer.price - tradeIn
  if (career.money or 0) < cost then return false, string.format('Not enough money (%d CZK needed)', cost) end
  M.expectFix(g)
  if not opts.noSpawn then
    local ok, err = pcall(G.spawn, offer.model, offer.key)
    if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  end
  career.money = career.money - cost
  local kept = opts.keepCar and g.car
  if kept then parkCurrent(g) end
  g.car = { model = offer.model, key = offer.key, name = offer.name, parts = nil, km = offer.km or 0,
    condition = offer.condition or 1 }
  g.repair, g.lastDamage, g.preview, g.carriedRepair = 0, 0, nil, nil
  return true, string.format('Bought %s for %d CZK%s', offer.name, offer.price,
    kept and '. Previous car parked.' or tradeIn > 0 and string.format(' (%d CZK for the old car)', tradeIn) or ''), cost
end

-- Sell your car to a dealer (you must be in it). You are left without a car until you buy one.
function M.sellCar(G, g, career)
  if not g.car then return false, 'You have no car' end
  if g.car.loaner then return false, 'The loaner stays in your garage.' end
  if g.pendingUsed then return false, 'Wait for your car to finish loading its parts' end
  if not M.inOwnCar(G, g) then return false, 'Sit in your car to sell it' end
  local price = math.max(0, round5(M.carWorth(G, g) * M.TRADE_IN) - (g.repair or 0))
  career.money = (career.money or 0) + price
  local name = g.car.name
  local damaged = (g.repair or 0) > 0
  g.carriedRepair = nil
  g.car, g.repair, g.lastDamage = nil, 0, 0
  return true, string.format('Sold %s for %d CZK%s.', name, price, damaged and ' (less the repairs)' or ''), price
end

------------------------------------------------------------------------------------------ the used-car market
-- A changing list of used cars: new ones appear while you play, old ones are sold to someone else. Each has its
-- kilometres and condition; the price follows the car's BeamNG value, its condition and a little luck.
M.MARKET_SIZE = 14             -- listings at most
M.MARKET_NEW_MIN = 8           -- a new listing about every this many minutes of play
M.MARKET_LIFE_MIN = { 40, 150 } -- a listing is gone after this many minutes of play
M.CHEAP_SHARE = 0.5            -- this share of new listings comes from the cheapest third of the cars

local function newListing(G, m, rnd)
  local all = {}
  for _, c in ipairs(G.configs() or {}) do
    if tonumber(c.value) and tonumber(c.value) > 0 and M.isCar(c) then all[#all + 1] = c end
  end
  if #all == 0 then return nil end
  table.sort(all, function(a, b) return tonumber(a.value) < tonumber(b.value) end)
  local pool = rnd() < M.CHEAP_SHARE and math.max(1, math.floor(#all / 3)) or #all
  local c = all[math.floor(rnd() * pool) + 1] or all[1]
  local km = math.floor(rnd() * rnd() * 320000 / 100) * 100          -- most cars have few km, some many
  local condition = math.max(0.15, math.min(1, 1 - km / 450000 - rnd() * 0.35))
  local price = round5(tonumber(c.value) * M.PRICE_PER_VALUE * (0.3 + 0.55 * condition) * (0.88 + 0.24 * rnd()))
  m.seq = (m.seq or 0) + 1
  return { id = m.seq, model = c.model, key = c.key, name = (c.brand and (c.brand .. ' ') or '') .. (c.name or c.key),
    km = km, condition = math.floor(condition * 100 + 0.5) / 100, price = price,
    listedAt = m.t, gone = m.t + M.MARKET_LIFE_MIN[1] + rnd() * (M.MARKET_LIFE_MIN[2] - M.MARKET_LIFE_MIN[1]) }
end

-- Advances the market by dtMin minutes of play (old listings go, new ones come). rnd: math.random-like (0..1).
function M.marketTick(G, g, dtMin, rnd)
  rnd = rnd or math.random
  local m = g.market
  if type(m) ~= 'table' or m.v ~= 3 then m = { v = 3, t = 0, seq = 0, list = {}, nextAt = 0 } g.market = m end   -- v2: cars only, v3: prices from delivery pay
  m.t = m.t + (dtMin or 0)
  for i = #m.list, 1, -1 do
    local l = m.list[i]
    if l.gone <= m.t and not (g.preview and g.preview.id == l.id) then table.remove(m.list, i) end   -- not while you look at it
  end
  if #m.list == 0 and m.t <= (dtMin or 0) + 1e-9 then
    -- the first visit: a market already full of cars
    for _ = 1, math.floor(M.MARKET_SIZE * 0.7) do
      local l = newListing(G, m, rnd)
      if l then l.gone = l.gone - rnd() * M.MARKET_LIFE_MIN[1] m.list[#m.list + 1] = l end
    end
    m.nextAt = m.t + M.MARKET_NEW_MIN
  end
  while m.t >= m.nextAt do
    if #m.list < M.MARKET_SIZE then
      local l = newListing(G, m, rnd)
      if l then m.list[#m.list + 1] = l end
    end
    m.nextAt = m.nextAt + M.MARKET_NEW_MIN * (0.5 + rnd())
  end
  return m
end

-- The listings, cheapest first (filter: text in the name). Each also says how long it has been listed / has left.
function M.market(g, filter)
  local m = g.market
  local out = {}
  filter = filter and filter ~= '' and filter:lower() or nil
  for _, l in ipairs(m and m.list or {}) do
    if not filter or l.name:lower():find(filter, 1, true) then
      out[#out + 1] = { id = l.id, model = l.model, key = l.key, name = l.name, km = l.km, condition = l.condition,
        missing = l.wearVersion == WEAR_VERSION and l.missing and #l.missing or nil,
        price = l.price, hours = M.hours(l.price), isNew = (m.t - l.listedAt) < 15, leftMin = math.max(0, math.floor(l.gone - m.t + 0.5)) }
    end
  end
  table.sort(out, function(a, b) if a.price ~= b.price then return a.price < b.price end return a.id < b.id end)
  return out
end

local function findListing(g, id)
  for i, l in ipairs(g.market and g.market.list or {}) do if l.id == id then return l, i end end
end
M.findListing = findListing

-- Buys listing `id`; your car is traded in. While looking at that car, you keep the one you're in (no respawn).
-- Returns ok, message, listing. A car bought without a look gets its missing parts once it has spawned (core).
function M.buyListing(G, g, career, id, keepCar)
  if g.pendingUsed then return false, 'Wait for your car to finish loading its parts' end
  local l, i = findListing(g, id)
  if not l then return false, 'That car has been sold to someone else' end
  local here = g.preview and g.preview.id == id
  if g.preview and not here then return false, 'Go back to your car first' end
  if here and not g.preview.ready then return false, g.preview.error or 'Wait for the preview to load' end
  if here then
    local v = G.vehicle()
    if not v or v.model ~= l.model or (G.isOwned and not G.isOwned(v)) then
      return false, 'Sit in the car you are looking at first'
    end
  end
  if here then keepCar = g.preview.keepCar end
  local ok, msg = M.buyCar(G, g, career, l, { tradeIn = here and g.preview.tradeIn or nil, noSpawn = here,
    keepCar = keepCar })
  if ok then
    table.remove(g.market.list, i)
    g.preview = nil
    if here then
      g.car.wearVersion = l.wearVersion
    else
      g.pendingUsed = { missing = l.missing, finish = l.finish, wearVersion = l.wearVersion }
    end
  end
  return ok, msg, l
end

------------------------------------------------------------------------------------------ used cars are used
-- Exact stock parts for the Pigeon starter, including older saves. Keep the windshield, lights and driver's door.
local PIGEON_WEAR = { pigeon_door_R = true, pigeon_doorglass_L = true, pigeon_tailgate = true,
  pigeon_hood = true, pigeon_grille = true, pigeon_bumper_F = true }
local PANELS = { 'bumper', 'door', 'hood', 'bonnet', 'tailgate', 'trunk', 'hatch', 'grille', 'glass', 'window', 'fender' }
local PANEL_HARDWARE = { 'panel_', 'detent', 'handle', 'hinge' }
local TRIM = { 'mirror', 'spoiler', 'wing', 'mudflap', 'skirt', 'sunroof', 'bullbar', 'flare',
  'splitter', 'diffuser', 'molding', 'moulding', 'badge', 'lettering', 'runningboard' }
local ESSENTIAL = { 'engine', 'transmission', 'gearbox', 'diff', 'driveshaft', 'axle', 'suspension', 'spring', 'damper',
  'shock', 'strut', 'coilover', 'wheel', 'tire', 'tyre', 'brake', 'steer', 'fuel', 'tank', 'radiator', 'cooling',
  'intake', 'exhaust', 'frame', 'chassis', 'battery', 'pedal', 'shifter', 'seat', 'windshield', 'windscreen',
  'headlight', 'taillight', 'head_light', 'tail_light', 'stoplight', 'bulb', 'lamp', 'signal', 'indicator',
  'foglight', 'sidemarker', 'reverse_light', 'cargo', 'licenseplate', 'swingarm' }

local function containsAny(s, words)
  for _, word in ipairs(words) do if s:find(word, 1, true) then return true end end
  return false
end

local function canRemove(G, v, path, starter)
  local def = vehicleSlot(G, v, path)
  if not def or def.coreSlot then return false end
  local pigeonStarter = starter and v.model == M.STARTER_MODEL
  for childPath, part in pairs(v.slotPartMap) do
    if part ~= '' and part ~= 'none' and childPath:sub(1, #path) == path then
      local child = slotId(childPath)
      if pigeonStarter and childPath ~= path and child ~= part then return false end
      local frontPlate = pigeonStarter and slotId(path) == 'pigeon_bumper_F' and part == 'pigeon_licenseplate_F'
      if not frontPlate and containsAny((child .. ' ' .. part):lower(), ESSENTIAL) then return false end
    end
  end
  return true
end

local function planMissing(G, v, condition, starter, rnd)
  local pigeon = starter and v.model == M.STARTER_MODEL
  local count = math.min(10, math.ceil(math.max(0, 0.85 - (condition or 1)) * 14))
  if count == 0 then return {} end
  local panels, trim = {}, {}
  for path, part in pairs(v.slotPartMap) do
    local id = slotId(path)
    if id and part ~= '' and part ~= 'none' then
      local key = id:lower()
      local visible = containsAny(key, PANELS) and not containsAny(key, PANEL_HARDWARE)
      local eligible = pigeon and id == part and PIGEON_WEAR[id] or not pigeon and (visible or containsAny(key, TRIM))
      if eligible and canRemove(G, v, path, starter) then
        local group = (pigeon or visible) and panels or trim
        group[#group + 1] = { path = path, name = info(G, v.ioCtx, part).name }
      end
    end
  end
  table.sort(panels, function(a, b) return a.path < b.path end)
  if pigeon then return panels end
  table.sort(trim, function(a, b) return a.path < b.path end)
  local missing = {}
  for _, candidates in ipairs({ panels, trim }) do
    while #missing < count and #candidates > 0 do
      local part = table.remove(candidates, math.floor(rnd() * #candidates) + 1)
      local overlaps = false
      for _, other in ipairs(missing) do
        if part.path:sub(1, #other.path) == other.path or other.path:sub(1, #part.path) == part.path then
          overlaps = true
          break
        end
      end
      if not overlaps then missing[#missing + 1] = part end
    end
  end
  table.sort(missing, function(a, b) return a.name < b.name end)
  return missing
end

local PAINT_PATH = '/paint_design/'
local PAINT_FIELDS = { 'roughness', 'metallic', 'clearcoat', 'clearcoatRoughness' }

local function paintSkin(tree)
  local slot = tree and tree.children and tree.children.paint_design
  return slot and slot.chosenPartName
end

local function weatheredSkin(G, v)
  if paintSkin(v.tree) ~= '' then return end
  local def = vehicleSlot(G, v, PAINT_PATH)
  if not def then return end
  local variants = G.compatible and G.compatible(v.ioCtx, def) or {}
  local names = { v.model .. '_skin_rust', v.model .. '_skin_old' }
  if v.model == 'miramar' then
    for _, part in pairs(v.slotPartMap) do
      if part:find('miramar_body_ute', 1, true) then table.insert(names, 1, 'miramar_skin_rust_ute') break end
    end
  end
  local preferred = {}
  for _, name in ipairs(names) do preferred[name] = true end
  for _, name in ipairs(variants) do
    if not preferred[name] then
      local item = info(G, v.ioCtx, name)
      local title = item and item.name:lower() or ''
      if title:match('^old paint') or title:match('^rusted .*paint') or title:match('^weathered paint') then
        names[#names + 1] = name
      end
    end
  end
  for _, name in ipairs(names) do
    local item = info(G, v.ioCtx, name)
    if item.jbeam then return item.part, item.name end
  end
end

local function planFinish(G, v, condition)
  local finish = {}
  if condition >= 0.78 then return finish end
  local original = v.config and v.config.paints
  if type(original) == 'table' and #original > 0 then
    local wear = math.min(1, (0.78 - condition) / 0.56)
    local paints = {}
    for _, paint in ipairs(original) do
      local color = type(paint) == 'table' and paint.baseColor
      if type(color) ~= 'table' or not tonumber(color[1]) or not tonumber(color[2]) or not tonumber(color[3]) then
        paints = {}
        break
      end
      local neutral = 0.22 + (0.21 * color[1] + 0.72 * color[2] + 0.07 * color[3]) * 0.25
      local fade = 0.55 * wear
      paints[#paints + 1] = {
        baseColor = { color[1] * (1 - fade) + neutral * fade, color[2] * (1 - fade) + neutral * fade,
          color[3] * (1 - fade) + neutral * fade, color[4] },
        roughness = math.max(paint.roughness or 0, 0.45 + 0.5 * wear),
        metallic = (paint.metallic or 0) * (1 - 0.95 * wear),
        clearcoat = (paint.clearcoat or 0) * math.max(0, 1 - 1.8 * wear),
        clearcoatRoughness = math.max(paint.clearcoatRoughness or 0, 0.4 + 0.55 * wear),
      }
    end
    if #paints > 0 then finish.paints, finish.name = paints, 'Faded matte paint' end
  end
  if condition <= 0.62 then
    local skin, name = weatheredSkin(G, v)
    if skin then finish.skin, finish.name = skin, name end
  end
  return finish
end

local function closePaint(a, b)
  return type(a) == 'number' and type(b) == 'number' and math.abs(a - b) < 0.002
end

local function finishApplied(v, finish)
  if finish.skin and paintSkin(v.tree) ~= finish.skin then return false end
  local paints = v.config and v.config.paints or {}
  for i, expected in ipairs(finish.paints or {}) do
    local actual = paints[i]
    if not actual or not actual.baseColor then return false end
    for channel = 1, 3 do
      if not closePaint(actual.baseColor[channel], expected.baseColor[channel]) then return false end
    end
    for _, field in ipairs(PAINT_FIELDS) do
      if not closePaint(actual[field], expected[field]) then return false end
    end
  end
  return true
end

-- Prepare and verify against the live slot map. A respawn request alone does not confirm any removal.
function M.prepareUsed(G, g, car, setup, rnd)
  local v = G.vehicle()
  if not v or v.model ~= car.model or (G.isOwned and not G.isOwned(v)) or not v.tree or not v.ioCtx
    or type(v.slotPartMap) ~= 'table' or not next(v.slotPartMap) then
    return false
  end
  if setup.wearVersion ~= WEAR_VERSION or not setup.missing then
    setup.missing = planMissing(G, v, car.condition, setup.starter, rnd or math.random)
    setup.finish = planFinish(G, v, car.condition or 1)
    setup.wearVersion = WEAR_VERSION
  end
  if setup.starter and setup.box == nil then setup.box = M.planBox(G, v) or false end
  local box = setup.box
  if box and v.slotPartMap[box.path] == box.part then car.box = box.name box = nil end
  local remaining = {}
  for _, part in ipairs(setup.missing) do
    local installed = v.slotPartMap[part.path]
    if installed and installed ~= '' and installed ~= 'none' then remaining[#remaining + 1] = part end
  end
  local finish = setup.finish or {}
  -- a box the game would not fit twice is given up: the wear and paint still have to apply
  if box and (setup.attempts or 0) >= 2 then setup.box, box = false, nil end
  if #remaining == 0 and not box and finishApplied(v, finish) then return true end
  setup.attempts = (setup.attempts or 0) + 1
  if setup.attempts > 3 then return false, 'BeamNG could not apply the wear to this car.' end
  local config = G.captureConfig(v)
  if not config then return false end
  for _, part in ipairs(remaining) do
    if not canRemove(G, v, part.path, setup.starter) or not M.setInTree(config.partsTree, part.path, '') then
      return false, 'This car’s parts configuration has changed.'
    end
  end
  if finish.skin and not M.setInTree(config.partsTree, PAINT_PATH, finish.skin) then
    return false, 'This car’s paint slot is unavailable.'
  end
  if finish.paints then config.paints = finish.paints end
  -- (a box slot that has gone with a removed part is no reason to fail: the starter bag stands in)
  if box and not M.setInTree(config.partsTree, box.path, box.part) then setup.box = false end
  M.expectFix(g)
  local ok, err = pcall(G.applyConfig, v, config)
  if not ok and log then log('W', 'cargoEarth', 'Could not apply used car parts: ' .. tostring(err)) end
  return false
end

------------------------------------------------------------------------------------------ a look at a used car
-- You sit in the car for sale (your own is put away with its parts); buy it as it is, or go back to your car.
function M.previewStart(G, g, id, keepCar)
  local l = findListing(g, id)
  if not l then return false, 'That car has been sold to someone else' end
  if g.preview then return false, 'Go back to your car first' end
  if g.pendingUsed then return false, 'Wait for your car to finish loading its parts' end
  if g.car and not M.inOwnCar(G, g) then return false, 'Sit in your car first (Bring my car)' end
  if (g.repair or 0) > 0 then return false, 'Repair your car first' end
  if g.car and g.car.loaner then keepCar = true end
  local tradeIn = not keepCar and g.car and round5(M.carWorth(G, g) * M.TRADE_IN) or 0
  if not captureCurrent(G, g) then return false, 'Could not save the current car configuration.' end
  M.expectFix(g)
  local ok, err = pcall(G.spawn, l.model, l.key)
  if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  g.preview = { id = id, tradeIn = tradeIn, keepCar = keepCar and g.car ~= nil, ready = false,
    missing = l.missing, finish = l.finish, wearVersion = l.wearVersion }
  return true, 'Have a look at the ' .. l.name .. '. Drive it around, then buy it or go back to your car.'
end

-- Once the car for sale has spawned: its missing parts come off (the same ones each time you look). rnd for tests.
function M.previewReady(G, g, rnd)
  local p = g.preview
  if not p or p.ready or p.error then return false end
  local l = findListing(g, p.id)
  if not l then return false end
  local ready, why = M.prepareUsed(G, g, l, p, rnd)
  p.ready, p.error = ready, why
  if ready then
    l.missing, l.finish, l.wearVersion = p.missing, p.finish, p.wearVersion
    if G.applyCondition then pcall(G.applyCondition, l.km, l.condition) end
  end
  return ready
end

-- The configuration that recreates the career car, including older saves.
function M.savedConfig(car)
  if type(car.config) == 'table' then return car.config end
  -- Older saves recorded the chosen part at each slot path, a format BeamNG can also spawn.
  if type(car.parts) == 'table' and next(car.parts) then
    return { format = 2, model = car.model, parts = car.parts }
  end
end

-- Back to your own car after looking at a dealer listing.
function M.previewEnd(G, g)
  if not g.preview then return false, 'Not looking at a car' end
  if not g.car then g.preview = nil return true, 'Back without a car' end
  M.expectFix(g)
  local ok, err = pcall(G.spawn, g.car.model, g.car.key, M.savedConfig(g.car))
  if not ok then return false, 'Car not spawned: ' .. tostring(err) end
  g.preview, g.carriedRepair, g.lastDamage = nil, g.repair or 0, 0
  return true, 'Back in your ' .. g.car.name .. '.'
end

-- The starter: the cheapest config of STARTER_MODEL (or the cheapest car at all).
function M.starter(G, model)
  model = model or M.STARTER_MODEL
  local list = G.configs() or {}
  local best, anyOfModel
  for _, c in ipairs(list) do
    local value = tonumber(c.value)
    if c.model == model then
      anyOfModel = anyOfModel or c
      if value and value > 0 and (not best or value < tonumber(best.value)) then best = c end
    end
  end
  best = best or anyOfModel   -- no prices in this game version: any config of the model
  if not best then
    for _, c in ipairs(list) do
      local value = tonumber(c.value)
      if value and value > 0 and M.isCar(c) and (not best or value < tonumber(best.value)) then best = c end
    end
  end
  return best
end

-- A new career: little money, the starter car. Returns ok, message.
function M.start(G, g, career, model)
  local s = M.starter(G, model)
  if not s then return false, 'No car configs found' .. (G.lastError and (': ' .. G.lastError) or '') end
  M.expectFix(g)
  local ok, err = pcall(G.spawn, s.model, s.key)
  if not ok then return false, 'Starter car not spawned: ' .. tostring(err) end
  career.money = M.START_MONEY
  g.started = true
  g.car = { model = s.model, key = s.key, name = (s.brand and (s.brand .. ' ') or '') .. (s.name or s.key),
    km = STARTER_KM, condition = STARTER_CONDITION, starter = true }
  g.pendingUsed = { starter = true }
  g.repair, g.debt, g.lastDamage, g.inventory, g.spent, g.carriedRepair = 0, 0, 0, {}, 0, nil
  g.priceV = M.PRICE_V
  return true, 'Your car: ' .. g.car.name .. '. ' .. M.START_MONEY .. ' CZK to start.'
end

-- Older starters had no condition, or had the original three stripped slots. Preserve fitted replacements.
function M.updateStarter(g)
  local c = g.car
  if not c or g.pendingUsed or c.loaner or c.wearVersion == WEAR_VERSION then return end
  if not c.starter then
    if c.model ~= M.STARTER_MODEL or c.key ~= 'base' then return end
    if c.condition ~= nil then
      if c.condition ~= STARTER_CONDITION or not c.parts then return end
      local parts = {}
      for path, part in pairs(c.parts) do parts[slotId(path) or path] = part end
      if parts.pigeon_frame ~= 'pigeon_frame' then return end
      if parts.pigeon_door_R and parts.pigeon_door_R ~= '' or parts.pigeon_doorglass_L and parts.pigeon_doorglass_L ~= ''
        or parts.pigeon_tailgate and parts.pigeon_tailgate ~= '' then return end
    end
  end
  c.starter, c.condition = true, c.condition or STARTER_CONDITION
  g.pendingUsed = { starter = true }
end

-- Check the tracked vehicle as well as its model, so another car of the same model stays separate.
local function owns(G, g, v)
  return g.car and not g.preview and v and v.model == g.car.model and (not G.isOwned or G.isOwned(v))
end

function M.inOwnCar(G, g)
  if not g.started then return true end
  return owns(G, g, G.vehicle()) and true or false
end

-- Keep the full spawn configuration and the slot map used by older saves.
function M.remember(G, g, vehicle)
  local v = vehicle or (G.ownedVehicle and G.ownedVehicle()) or G.vehicle()
  if not owns(G, g, v) or type(v.slotPartMap) ~= 'table' then return false end
  local parts = {}
  for k, p in pairs(v.slotPartMap) do parts[k] = p end
  g.car.parts = parts
  M.noteValue(G, g, v)
  if G.captureConfig then g.car.config = G.captureConfig(v) or g.car.config end
  return true
end

-- Puts remembered parts back on a freshly spawned car of the right model. Returns true when it did something.
function M.restore(G, g)
  local v = G.vehicle()
  if not g.car or not g.car.parts or not v or v.model ~= g.car.model or not v.tree then return false end
  local changed = false
  for path, part in pairs(g.car.parts) do
    if v.slotPartMap[path] ~= part and M.setInTree(v.tree, path, part) then changed = true end
  end
  if changed then M.expectFix(g) pcall(G.applyTree, v.tree) end
  return changed
end

return M
