-- cargoEarth/food: food delivery orders, restaurant -> house address. Pure Lua (no game calls), tested outside BeamNG.
--
--   local food = require('cargoEarth/food')
--   local idx = food.index(restaurantsPack, loadTile)     -- loadTile(row, col) -> address rows or nil
--   local list, stats = food.generate(idx, opts, lat, lon, rnd)
--
-- A job has the same shape as a trucking job (cargoEarth/jobs): { id, from, to, cargo, cargoName, km, pay, minutes,
-- pickupKm, kind = 'food', items }; from / to are { id, n (name), g (curb point), d (door), town, label }.
local M = {}

M.ROAD_FACTOR = 1.35   -- city streets wind more than the trucking network
M.BASE = 49            -- CZK per order
M.PER_KM = 16          -- CZK per road km (0.4: +2 for the fuel the courier now pays, about 6 L/100 km)
M.SPEED_KMH = 24       -- planning speed in town
M.SLACK_MIN = 4        -- minutes added to every time limit
M.TIP_MAX = 0.25       -- largest tip as a share of pay, for delivering at once
M.TIP_FROM = 0.7       -- tips start below this share of the time limit
M.TILE_CACHE = 48      -- address tiles kept in memory
M.REACH_GROW = 1.6     -- auto reach: the search radius grows by this factor per step
M.REACH_MIN_SPOTS = 6  -- auto reach: grow until this many restaurants are in reach (or reachMaxKm)
M.FAR_PICKUP_FROM = 3  -- km: pickups further than this pay extra (the ride there is part of the job)
M.FAR_PICKUP_PER_KM = 8 -- CZK per straight km beyond FAR_PICKUP_FROM
M.DATA_MAX_KM = 8      -- customer addresses ship only within 8 km of a restaurant
M.FAMILY_SLOTS, M.FAMILY_BONUS, M.FAMILY_ONE_IN = 2, 40, 3
M.GROCERY_SLOTS, M.GROCERY_BONUS = 4, 80
-- Who orders: most customers live near the restaurant and in its own town. Addresses are spread evenly over the
-- map (one per 100 m), so a town's ring of villages has far more of them than the town; without these weights a
-- small-town restaurant sent most orders out to the villages around it.
M.NEAR_KM = 1.5        -- customers this close are all equally likely; further ones less and less
M.FAR_FALLOFF = 1.5    -- likelihood (NEAR_KM / km) ^ this beyond NEAR_KM
M.OTHER_TOWN = 0.3     -- a customer in another town (village) than the restaurant is this much less likely
-- A customer close in a straight line can be far by road (a river, a railway, a motorway between them). When the
-- game's road graph knows the way, the order is skipped if the road is longer than this, and is paid by the road.
M.DETOUR = 1.8         -- road km at most this many times the straight km...
M.DETOUR_KM = 0.6      -- ...plus this
M.ROAD_CHECKS = 4      -- road searches per restaurant and offer list at most

-- Sample orders by cuisine. The map data describes restaurants, so the dishes are generated for gameplay.
local menus = {
  pizza = { { 'Margherita pizza', 'Pepperoni pizza', 'Four-cheese pizza', 'Mushroom pizza' },
    { 'Garlic knots', 'Mixed salad', 'Cola' } },
  burger = { { 'Double cheeseburger', 'Crispy chicken burger', 'BBQ bacon burger', 'Veggie burger' },
    { 'Fries', 'Onion rings', 'Chocolate shake' } },
  asian = { { 'Chicken fried rice', 'Vegetable noodles', 'Teriyaki chicken bowl', 'Tofu curry' },
    { 'Spring rolls', 'Edamame', 'Iced tea' } },
  kebab = { { 'Chicken döner wrap', 'Beef kebab box', 'Falafel pita', 'Mixed kebab platter' },
    { 'Fries', 'Hummus', 'Ayran' } },
  italian = { { 'Penne arrabbiata', 'Mushroom risotto', 'Beef lasagna', 'Basil pesto gnocchi' },
    { 'Bruschetta', 'Caprese salad', 'Tiramisu' } },
  mexican = { { 'Chicken burrito', 'Pork tacos', 'Bean quesadilla', 'Steak burrito bowl' },
    { 'Chips and guacamole', 'Street corn', 'Lime soda' } },
  cafe = { { 'Ham and cheese croissant', 'Egg salad sandwich', 'Berry pancakes', 'Cinnamon roll' },
    { 'Cappuccino', 'Iced latte', 'Orange juice' } },
  fastfood = { { 'Chicken tenders', 'Fish sandwich', 'Grilled chicken wrap', 'Nugget meal' },
    { 'Fries', 'Coleslaw', 'Lemonade' } },
  czech = { { 'Pork schnitzel', 'Goulash with dumplings', 'Fried cheese', 'Roast pork and cabbage' },
    { 'Potato pancakes', 'Cucumber salad', 'Kofola' } },
  pub = { { 'Roast chicken', 'Sausage and mash', 'Grilled pork chops', 'Mushroom stew' },
    { 'Roast potatoes', 'Pickles', 'Sparkling water' } },
  other = { { 'Grilled chicken bowl', 'Roasted vegetable wrap', 'Soup and sandwich', 'Baked pasta' },
    { 'Mixed salad', 'Bread roll', 'Lemonade' } },
}

local groceryBaskets = {
  { name = 'Weekly groceries', kg = 9.5, items = {
    { name = 'Produce bag', qty = 1 }, { name = 'Egg carton', qty = 1 },
    { name = 'Chilled groceries bag', qty = 1 }, { name = 'Pantry bag', qty = 1 } } },
  { name = 'Pantry restock', kg = 11, items = {
    { name = 'Dry groceries bag', qty = 3 }, { name = 'Drinks carrier', qty = 1 } } },
  { name = 'Fresh food shop', kg = 7.5, items = {
    { name = 'Fruit and vegetables bag', qty = 2 }, { name = 'Bakery bag', qty = 1 }, { name = 'Chilled groceries bag', qty = 1 } } },
}

function M.orderItems(category, rnd, family)
  rnd = rnd or math.random
  local menu = menus[category] or menus.other
  local mains, extras = menu[1], menu[2]
  local items = { { name = mains[rnd(#mains)], qty = family and 3 or (rnd(4) == 1 and 2 or 1) } }
  if family or rnd(3) ~= 1 then items[#items + 1] = { name = extras[rnd(#extras)], qty = 1 } end
  return items
end

M.defaults = {
  minKm = 0.5,         -- shortest order, straight km from the restaurant
  maxKm = 5,           -- longest order
  nearKm = 3,          -- restaurants offered within this straight distance of the player
  count = 8,           -- orders offered at once
  cat = nil,           -- one food category (pizza, burger, asian, ...), or nil for any
  autoReach = true,    -- widen the restaurant radius (and the order length) where restaurants are few
  reachMaxKm = 25,     -- auto reach: never look for restaurants further than this
  maxOrders = 2,       -- orders carried at once (core: batched orders)
}

local R, rad = 6371.0, math.pi / 180

function M.km(lat1, lon1, lat2, lon2)
  local dlat, dlon = (lat2 - lat1) * rad, (lon2 - lon1) * rad
  local a = math.sin(dlat / 2) ^ 2 + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dlon / 2) ^ 2
  return 2 * R * math.asin(math.min(1, math.sqrt(a)))
end

function M.index(pack, loadTile)
  local idx = { pack = pack, cats = pack.cats, tile = pack.tile, loadTile = loadTile, tiles = {}, order = {},
    restaurants = {} }
  for _, r in ipairs(pack.restaurants) do
    -- id, lat, lon, curbLat, curbLon, name, cat, town
    idx.restaurants[#idx.restaurants + 1] = { id = r[1], d = { r[2], r[3] }, g = { r[4], r[5] }, n = r[6], cat = r[7],
      town = r[8] or '', label = pack.cats[r[7]] or 'Restaurant', kind = 'restaurant' }
  end
  return idx
end

-- Areas from the helper carry restaurants, grocers, and address tiles in the pack's row formats.
-- Skip duplicate pickups near the local pack and evict the oldest streamed areas first.
M.MAX_AREAS = 25
M.DUP_M = 120

local function dupKey(lat, lon) return math.floor(lat / 0.002) .. ':' .. math.floor(lon / 0.003) end

local function rowToRestaurant(idx, r)
  -- (the pack's "czech" category is local and pub food; outside Czechia it isn't Czech)
  return { id = r[1], d = { r[2], r[3] }, g = { r[4], r[5] }, n = r[6], cat = r[7], town = r[8] or '',
    label = r[7] == 'czech' and 'Local and pub' or (idx.cats[r[7]] or 'Restaurant'), kind = 'restaurant' }
end

function M.addArea(idx, data, onDrop)
  if type(data) ~= 'table' or type(data.key) ~= 'string' then return 0 end
  idx.areas = idx.areas or { order = {}, byKey = {} }
  idx.extraTiles = idx.extraTiles or {}
  idx.extraTileOwners = idx.extraTileOwners or {}
  local old = idx.areas.byKey[data.key]
  local hasGrocers = type(data.grocers) == 'table'
  local revision = tostring(data.release or '') .. ':' .. tostring(data.areaFormat or '')
  if old then
    if (old.hasGrocers or not hasGrocers) and old.revision == revision then return 0 end
    M.dropArea(idx, data.key)
  end
  -- nearby names of what is there, for the duplicate check
  local grid, existing = {}, {}
  local function remember(r)
    existing[r.id] = true
    local k = dupKey(r.g[1], r.g[2])
    grid[k] = grid[k] or {}
    table.insert(grid[k], r)
  end
  for _, r in ipairs(idx.restaurants) do remember(r) end
  local function dup(row)
    local lat, lon = row[4], row[5]
    for dy = -1, 1 do
      for dx = -1, 1 do
        local k = math.floor(lat / 0.002) + dy .. ':' .. math.floor(lon / 0.003) + dx
        for _, r in ipairs(grid[k] or {}) do
          if r.n == row[6] and (r.cat == 'grocery') == (row[7] == 'grocery')
            and M.km(lat, lon, r.g[1], r.g[2]) * 1000 <= M.DUP_M then return true end
        end
      end
    end
    return false
  end
  local ids, added, grocers = {}, 0, 0
  for _, rows in ipairs({ data.restaurants or {}, hasGrocers and data.grocers or {} }) do
    for _, row in ipairs(rows) do
      if type(row) == 'table' and #row >= 7 and not existing[row[1]] and not dup(row) then
        if row[7] == 'grocery' then
          idx.cats.grocery = 'Grocery store'
          grocers = grocers + 1
        end
        local pickup = rowToRestaurant(idx, row)
        idx.restaurants[#idx.restaurants + 1] = pickup
        remember(pickup)
        ids[row[1]] = true
        added = added + 1
      end
    end
  end
  local tiles = {}
  for k, rows in pairs(data.tiles or {}) do
    idx.extraTiles[k] = rows
    idx.extraTileOwners[k] = data.key
    tiles[#tiles + 1] = k
  end
  idx.areas.byKey[data.key] = { ids = ids, tiles = tiles, hasGrocers = hasGrocers, revision = revision }
  table.insert(idx.areas.order, data.key)
  while #idx.areas.order > M.MAX_AREAS do
    local key = idx.areas.order[1]
    M.dropArea(idx, key)
    if onDrop then onDrop(key) end
  end
  return added, grocers
end

function M.dropArea(idx, key)
  local a = idx.areas and idx.areas.byKey[key]
  if not a then return end
  local keep = {}
  for _, r in ipairs(idx.restaurants) do if not a.ids[r.id] then keep[#keep + 1] = r end end
  idx.restaurants = keep
  for _, k in ipairs(a.tiles) do
    if not idx.extraTileOwners or idx.extraTileOwners[k] == key then
      idx.extraTiles[k] = nil
      if idx.extraTileOwners then idx.extraTileOwners[k] = nil end
    end
  end
  idx.areas.byKey[key] = nil
  for i, k in ipairs(idx.areas.order) do if k == key then table.remove(idx.areas.order, i) break end end
end

function M.hasArea(idx, key) return idx.areas ~= nil and idx.areas.byKey[key] ~= nil end

local function tile(idx, row, col)
  local key = row .. '_' .. col
  local t = idx.tiles[key]
  if t == nil then
    t = idx.loadTile(row, col) or false
    idx.tiles[key] = t
    idx.order[#idx.order + 1] = key
    if #idx.order > M.TILE_CACHE then idx.tiles[table.remove(idx.order, 1)] = nil end
  end
  -- The bundled addresses already have road-side stop points. Fill the gaps with streamed tiles.
  return t or (idx.extraTiles and idx.extraTiles[key]) or nil
end

-- address rows in the tiles touching a box of maxKm round (lat, lon)
local function addressesAround(idx, lat, lon, maxKm)
  local dLat = maxKm / 111.32
  local dLon = maxKm / (111.32 * math.max(0.1, math.abs(math.cos(lat * rad))))
  local out = {}
  for row = math.floor((lat - dLat) / idx.tile), math.floor((lat + dLat) / idx.tile) do
    for col = math.floor((lon - dLon) / idx.tile), math.floor((lon + dLon) / idx.tile) do
      local t = tile(idx, row, col)
      if t then out[#out + 1] = t end
    end
  end
  return out
end

-- Every known customer address within about maxKm (rows as in the tiles), for parcel routes.
function M.addressesNear(idx, lat, lon, maxKm)
  local out = {}
  if not idx or not lat or not lon then return out end
  for _, rows in ipairs(addressesAround(idx, lat, lon, maxKm)) do
    for _, a in ipairs(rows) do out[#out + 1] = a end
  end
  return out
end

-- Address picker shares the courier's bundled/streamed tiles. Called only on explicit search.
function M.addresses(idx, lat, lon, query)
  if not idx or not lat or not lon then return {} end
  query = tostring(query or ''):sub(1, 100):lower()
  local out, seen = {}, {}
  for _, rows in ipairs(addressesAround(idx, lat, lon, 3)) do
    for _, a in ipairs(rows) do
      local label = tostring(a[5] or 'Address')
      local town = tostring(a[6] or '')
      local id = string.format('address:%.6f,%.6f', a[1], a[2])
      local km = M.km(lat, lon, a[1], a[2])
      if km <= 3 and not seen[id] and (query == '' or (label .. ' ' .. town):lower():find(query, 1, true)) then
        seen[id] = true
        out[#out + 1] = { id = id, n = label, town = town, g = { a[3], a[4] }, d = { a[1], a[2] }, km = km }
      end
    end
  end
  table.sort(out, function(a, b) if a.km == b.km then return a.id < b.id end return a.km < b.km end)
  while #out > 25 do table.remove(out) end
  return out
end

function M.pay(roadKm)
  return math.floor((M.BASE + roadKm * M.PER_KM) / 5 + 0.5) * 5
end

-- Extra pay for a restaurant far from the courier: the ride there isn't free in the countryside.
function M.farPickup(pickupKm)
  local extra = (pickupKm or 0) - M.FAR_PICKUP_FROM
  if extra <= 0 then return 0 end
  return math.floor(extra * M.FAR_PICKUP_PER_KM / 5 + 0.5) * 5
end

function M.minutes(roadKm)
  return math.ceil(roadKm / M.SPEED_KMH * 60 + M.SLACK_MIN)
end

-- The pickup target in minutes after Accept: the ride-there share of the order's whole time (which may be stretched for
-- premium or special orders). Only a guide on the phone: pay, tips and stars go by the delivery time alone.
-- nil for jobs whose clock does not include the ride to the pickup.
function M.pickupMinutes(job)
  if type(job) ~= 'table' or job.kind ~= 'food' or not job.minutes or not job.pickupKm or not job.km then return nil end
  local there, total = job.pickupKm * M.ROAD_FACTOR, job.pickupKm * M.ROAD_FACTOR + job.km
  if total <= 0 then return nil end
  return math.max(1, math.min(job.minutes - 1, math.ceil(job.minutes * there / total)))
end

-- The tip for a delivery that took `minutes` of a `limit`: up to TIP_MAX of pay when quick, nothing past TIP_FROM.
function M.tip(pay, minutes, limit)
  local share = minutes / math.max(1, limit)
  if share >= M.TIP_FROM then return 0 end
  return math.floor(pay * M.TIP_MAX * (1 - share / M.TIP_FROM) / 5 + 0.5) * 5
end

local function merged(opts)
  local o = {}
  for k, v in pairs(M.defaults) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  if o.maxKm < o.minKm then o.minKm, o.maxKm = o.maxKm, o.minKm end
  return o
end

-- Orders near (lat, lon), nearest restaurant first. stats: { pickups = restaurants in reach, noDest = without an
-- address in range, reachKm = restaurant radius used, maxKm = longest order used, widened = reach grew }.
-- How likely a customer s km away orders from restaurant r (0..1); inTown false: in another town or village.
function M.customerWeight(s, inTown)
  local w = s <= M.NEAR_KM and 1 or (M.NEAR_KM / s) ^ M.FAR_FALLOFF
  if inTown == false then w = w * M.OTHER_TOWN end
  return w
end

-- Is an address in the restaurant's town? Address labels name the part of town (Chodov, Vinohrady, Lobkovice), the
-- restaurants the town itself (Praha, Neratovice), so an address counts as in town when a restaurant of that town is
-- within TOWN_KM of it. nil when the restaurant has no town.
M.TOWN_KM = 1.0
local GRID_LAT, GRID_LON = 0.01, 0.015
local function townGrid(idx)
  local list = idx.restaurants
  if idx._grid and idx._gridFor == list and idx._gridN == #list then return idx._grid end
  local grid = {}
  for _, r in ipairs(list) do
    if r.g and type(r.town) == 'string' and r.town ~= '' then
      local key = math.floor(r.g[1] / GRID_LAT) .. ':' .. math.floor(r.g[2] / GRID_LON)
      grid[key] = grid[key] or {}
      table.insert(grid[key], r)
    end
  end
  idx._grid, idx._gridFor, idx._gridN = grid, list, #list
  return grid
end

function M.inTown(idx, r, lat, lon, label)
  if type(r.town) ~= 'string' or r.town == '' then return nil end
  if label == r.town then return true end
  local grid, row, col = townGrid(idx), math.floor(lat / GRID_LAT), math.floor(lon / GRID_LON)
  -- cells to look at each way: a longitude cell narrows away from the equator
  local rows = math.ceil(M.TOWN_KM / (111.2 * GRID_LAT))
  local cols = math.min(60, math.ceil(M.TOWN_KM / (111.32 * math.max(0.01, math.cos(lat * rad)) * GRID_LON)))
  for i = -rows, rows do
    for j = -cols, cols do
      for _, o in ipairs(grid[(row + i) .. ':' .. (col + j)] or {}) do
        if o.town == r.town and M.km(lat, lon, o.g[1], o.g[2]) <= M.TOWN_KM then return true end
      end
    end
  end
  return false
end

-- roadKm(fromPoint, toPoint, maxKm) (optional): the road distance in km, false when longer than maxKm, nil unknown.
function M.generate(idx, opts, lat, lon, rnd, maxSlots, roadKm)
  rnd = rnd or math.random
  local o = merged(opts)
  -- every restaurant within the largest radius we might use, nearest first
  local limit = o.autoReach and math.max(o.nearKm, o.reachMaxKm) or o.nearKm
  local all = {}
  -- a degree of latitude is 111.2 km here: farther north or south is out of reach without the full distance
  local dLat = limit / 110
  for _, r in ipairs(idx.restaurants) do
    if math.abs(r.g[1] - lat) <= dLat and (not o.cat or r.cat == o.cat)
      and (r.cat ~= 'grocery' or (maxSlots or 0) >= M.GROCERY_SLOTS) then
      local k = M.km(lat, lon, r.g[1], r.g[2])
      if k <= limit then all[#all + 1] = { r = r, k = k } end
    end
  end
  table.sort(all, function(a, b) return a.k < b.k end)
  -- auto reach: in the countryside, grow the radius until enough restaurants are in it
  local reach = o.nearKm
  if o.autoReach then
    local want = math.min(M.REACH_MIN_SPOTS, o.count)
    local function inReach(km) local n = 0 for _, p in ipairs(all) do if p.k <= km then n = n + 1 end end return n end
    while inReach(reach) < want and reach < o.reachMaxKm do reach = math.min(o.reachMaxKm, reach * M.REACH_GROW) end
  end
  local near, grocer = {}, nil
  for _, p in ipairs(all) do
    if p.k <= reach then
      near[#near + 1] = p
      if p.r.cat == 'grocery' and not grocer then grocer = #near end
    end
  end
  -- Make room for one nearby supermarket when restaurants would fill the shortlist.
  if grocer and grocer > o.count and o.count > 1 then table.insert(near, o.count, table.remove(near, grocer)) end
  -- with few restaurants around, orders go further too (villages are spread out), up to the data's limit
  local maxKm = o.maxKm
  if o.autoReach and reach > o.nearKm then
    maxKm = math.min(math.max(o.maxKm, o.maxKm * reach / o.nearKm), math.max(o.maxKm, M.DATA_MAX_KM))
  end
  local stats = { pickups = #near, noDest = 0, reachKm = reach, maxKm = maxKm, widened = reach > o.nearKm }
  local out, used = {}, {}
  -- spread the offers: every restaurant in reach once before any twice, nearest first
  for pass = 1, 3 do
    for _, p in ipairs(near) do
      if #out >= o.count then break end
      if not used[p.r.id] or pass > 1 then
        local tiles = addressesAround(idx, p.r.g[1], p.r.g[2], maxKm)
        local n = 0
        for _, t in ipairs(tiles) do n = n + #t end
        local found, checks, detours = nil, 0, false
        for _ = 1, (n > 0 and 80 or 0) do
          -- a random address: pick a tile weighted by its size, then a row in it; near and same-town ones are likelier
          local pick = rnd(n)
          for _, t in ipairs(tiles) do
            if pick <= #t then
              local a = t[pick]
              local s = M.km(p.r.g[1], p.r.g[2], a[1], a[2])
              if s >= o.minKm and s <= maxKm and rnd(1000) <= 1000 * M.customerWeight(s, M.inTown(idx, p.r, a[1], a[2], a[6])) then
                found = { a = a, s = s }
                if roadKm and checks < M.ROAD_CHECKS then
                  checks = checks + 1
                  local road = roadKm(p.r.g, { a[3], a[4] }, s * M.DETOUR + M.DETOUR_KM)
                  if road == false then found, detours = nil, true else found.road = road end
                elseif detours then
                  found = nil   -- out of road searches after a detour: unchecked addresses are not offered
                end
              end
              break
            end
            pick = pick - #t
          end
          if found then break end
        end
        if not found then
          stats.noDest = stats.noDest + 1
        else
          used[p.r.id] = true
          local a, road = found.a, found.road or found.s * M.ROAD_FACTOR
          local to = { id = string.format('%.6f,%.6f', a[1], a[2]), d = { a[1], a[2] }, g = { a[3], a[4] }, n = a[5],
            town = a[6] or '', label = 'Customer', kind = 'address' }
          local job = { id = p.r.id .. '>' .. to.id, kind = 'food', from = p.r, to = to, cargo = p.r.cat,
            straightKm = found.s, km = road, roadKnown = found.road ~= nil, pickupKm = p.k, farPickup = M.farPickup(p.k),
            minutes = M.minutes(road + p.k * M.ROAD_FACTOR) }  -- the clock starts at Accept, so the ride there counts
          if p.r.cat == 'grocery' then
            local basket = groceryBaskets[rnd(#groceryBaskets)]
            job.orderType, job.sizeBonus = 'grocery', M.GROCERY_BONUS
            job.cargoName, job.items = basket.name, basket.items
            job.cargoSlots, job.cargoKg = M.GROCERY_SLOTS, basket.kg
          else
            local family = (maxSlots or 0) >= M.FAMILY_SLOTS and rnd(M.FAMILY_ONE_IN) == 1
            job.items = M.orderItems(p.r.label == 'Local and pub' and 'pub' or p.r.cat, rnd, family)
            if family then
              job.orderType, job.sizeBonus = 'family', M.FAMILY_BONUS
            elseif #job.items > 1 then
              -- Keep the standard offer in one slot. Larger loads use the paid tiers.
              job.items[1].qty = 1
            end
            job.cargoName = family and 'Family meal' or job.items[1].name
          end
          job.pay = M.pay(road) + job.farPickup + (job.sizeBonus or 0)
          out[#out + 1] = job
        end
      end
    end
    if #out >= o.count then break end
  end
  table.sort(out, function(a, b) return a.pickupKm < b.pickupKm end)
  return out, stats
end

function M.choices(idx)
  local k = {}
  for id in pairs(idx.cats) do k[#k + 1] = id end
  table.sort(k)
  return { cats = k }
end

return M
