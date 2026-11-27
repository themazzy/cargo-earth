-- cargoEarth/homedeliv: home deliveries behind a car (own trailers, 2026-11-27). A store sends furniture or building
-- supplies to a real address; the goods are the stock loaded config of your utility or cargo trailer (a sofa, two
-- armchairs, a pile of planks), put on at the store and taken off at the door. Pure rules: no game calls here.
local M = {}

M.NEAR_KM = 15          -- stores within this straight distance of the player
M.MIN_KM, M.MAX_KM = 1.5, 8   -- straight km from the store to the address
M.ROAD_FACTOR = 1.35
M.STORES = 3            -- the nearest stores each offer one delivery
-- pay: a handling part for the carrying, plus a part per road km; never less than MIN_PAY (car trailer work stays
-- above food delivery, about 500 CZK an hour)
M.BASE, M.PER_KM, M.MIN_PAY = 180, 16, 300
M.SPEED_KMH, M.HANDLING_MIN, M.SLACK_MIN = 35, 10, 15
M.GOODS = { furniture = 'Furniture', lumber = 'Building supplies' }
M.ORDER = { 'furniture', 'lumber' }
-- store names that sound like furniture or building supplies are asked first (any language; any store is fine)
local STORE_WORDS = { 'furnit', 'möbel', 'mobel', 'nábyt', 'nabyt', 'meubl', 'mueble', 'mobili', 'ikea', 'jysk', 'home',
  'bau', 'hardware', 'diy', 'obi', 'hornbach', 'leroy', 'stavebn', 'timber', 'lumber', 'holz', 'dřev', 'drev', 'brico' }

local rad = math.pi / 180
local function km(lat1, lon1, lat2, lon2)
  local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) / 2 * rad)
  local y = (lat2 - lat1) * rad
  return math.sqrt(x * x + y * y) * 6371
end
M.km = km

local function storeScore(d)
  local n = type(d.n) == 'string' and d.n:lower() or ''
  for _, w in ipairs(STORE_WORDS) do if n:find(w, 1, true) then return 1 end end
  return 0
end

function M.isStore(d, types)
  local t = type(d) == 'table' and d.t
  if type(t) ~= 'string' then return false end
  if t:match(':shop$') then return true end
  local ty = types and types[t]
  return ty ~= nil and ty.label == 'Store'
end

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end

function M.pay(roadKm) return math.max(M.MIN_PAY, round5(M.BASE + M.PER_KM * roadKm)) end
function M.minutes(roadKm, pickupKm)
  return math.floor((roadKm + 1.3 * (pickupKm or 0)) / M.SPEED_KMH * 60 + M.HANDLING_MIN + M.SLACK_MIN + 0.5)
end

-- stores: depots { id, n, town, g, t } near the player; near(lat, lon, km): address rows { lat, lon, curbLat, curbLon,
-- label, town }; loads(cargoId): the trailer's stock loads for it (cargoEarth/trailerpool.homeLoads); rnd: math.random-
-- like (rnd(n) gives 1..n). Returns jobs: { id, home = true, cargo, from, to, km, pickupKm, pay, minutes, pick = load index }.
function M.offers(stores, near, lat, lon, loads, rnd)
  rnd = rnd or math.random
  local goods = {}
  for _, id in ipairs(M.ORDER) do
    local l = loads(id)
    if #l > 0 then goods[#goods + 1] = { id = id, loads = l } end
  end
  if #goods == 0 then return {} end
  local list = {}
  for _, d in ipairs(stores or {}) do
    if type(d) == 'table' and type(d.g) == 'table' and type(d.g[1]) == 'number' then
      local k = km(lat, lon, d.g[1], d.g[2])
      if k <= M.NEAR_KM then list[#list + 1] = { d = d, k = k, score = storeScore(d) } end
    end
  end
  table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.k < b.k end)
  local out = {}
  for i = 1, math.min(M.STORES, #list) do
    local d, pickupKm = list[i].d, list[i].k
    local pool = {}
    for _, a in ipairs(near(d.g[1], d.g[2], M.MAX_KM) or {}) do
      if type(a) == 'table' and type(a[1]) == 'number' and type(a[2]) == 'number' and type(a[5]) == 'string' then
        local s = km(d.g[1], d.g[2], a[1], a[2])
        if s >= M.MIN_KM and s <= M.MAX_KM then pool[#pool + 1] = { a = a, s = s } end
      end
    end
    if #pool > 0 then
      local pick = pool[rnd(#pool)]
      local g = goods[rnd(#goods)]
      local n = rnd(#g.loads)
      local road = pick.s * M.ROAD_FACTOR
      local a = pick.a
      out[#out + 1] = {
        id = 'home:' .. tostring(d.id) .. ':' .. tostring(i), home = true, kind = 'cargo', cargo = g.id,
        cargoName = string.format('%s: %s', M.GOODS[g.id], g.loads[n].what),
        from = { id = d.id, n = d.n, town = d.town, g = { d.g[1], d.g[2] }, t = d.t },
        to = { n = a[5], town = a[6] or '', g = { a[3] or a[1], a[4] or a[2] } },
        straightKm = pick.s, km = road, pickupKm = pickupKm, pay = M.pay(road), minutes = M.minutes(road, pickupKm),
        pick = n,
      }
    end
  end
  return out
end

return M
