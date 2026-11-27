-- cargoEarth/trailerpool: the trailers you own (Jan, 2026-11-27: owning trailers is the core of freight). One pool for
-- you and your firm's hired drivers. Trailers live in trailer spots at home (and in the headquarters yard), are taken
-- out from there, can be left anywhere and fetched again, wear and get damaged like cars, and are bought new or used.
-- Pure rules: no game calls here (the game side is cargoEarth/rigs).
local economy = require('cargoEarth/economy')
local M = {}

M.SLOT_UNITS = 100       -- parcel slots in one Cargo Box XL (the 48 ft box trailer's 16 boxes are 1,600 slots)
M.BULK_BOX_L = 800       -- litres in one Aggregate Box XL
M.AGGREGATE_SLOTS = { 'FA', 'FB', 'FC', 'FD', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'RA', 'RB', 'RC', 'RD' }

-- The catalogue: every trailer you can own, a stock BeamNG model and config (checked in BeamNG 0.40's content\vehicles,
-- 2026-11-27). base: the stock .pc the parts are laid over. parts: load parts set on it (Cargo Box XL slots).
-- boxes: Cargo Box XL it carries; bulk: the box layout takes the 16 aggregate boxes (dry bulk); tankL: its tank.
-- payload: kg it may carry. pulls: what may pull it (the game's couplers decide in the end). size: upkeep class.
-- tow: the tow job trailer kind it serves (cargoEarth/tow). family: what it carries (M.FAMILIES).
M.CATALOGUE = {
  { id = 'box28', family = 'box', name = 'Box trailer 28 ft', model = 'dryvan', base = 'vehicles/dryvan/28ft.pc',
    parts = { dryvan_load_R_large = 'dryvan_load_R_cargo_load_box_6XL' }, boxes = 6, payload = 9600,
    price = 3000, pulls = 'semi', size = 'l', len = 10 },
  { id = 'box48', family = 'box', name = 'Box trailer 48 ft', model = 'dryvan', base = 'vehicles/dryvan/48ft.pc',
    parts = { dryvan_load_F = 'dryvan_load_F_cargo_load_box_4XL', dryvan_load_M = 'dryvan_load_M_cargo_load_box_8xl',
      dryvan_load_R = 'dryvan_load_R_cargo_load_box_4XL' }, boxes = 16, bulk = true, payload = 19200,
    price = 4500, pulls = 'semi', size = 'l', len = 16 },
  { id = 'box53', family = 'box', name = 'Box trailer 53 ft', model = 'dryvan', base = 'vehicles/dryvan/53ft.pc',
    parts = { dryvan_load_F = 'dryvan_load_F_cargo_load_box_8XL', dryvan_load_M_large = 'dryvan_load_M_cargo_load_box_16xl',
      dryvan_load_R = 'dryvan_load_R_cargo_load_box_8XL' }, boxes = 32, payload = 22400,
    bulkParts = { dryvan_load_F = 'dryvan_load_F_cargo_load_box_4XL', dryvan_load_M_large = 'dryvan_load_M_cargo_load_box_8xl',
      dryvan_load_R = 'dryvan_load_R_cargo_load_box_4XL' }, bulk = true,
    price = 5000, pulls = 'semi', size = 'l', len = 17 },
  { id = 'flatbed48', family = 'flatbed', name = 'Flatbed 48 ft', model = 'flatbed', base = 'vehicles/flatbed/48ft_double.pc',
    parts = { flatbed_load_F = 'flatbed_load_F_cargo_load_box_8XL', flatbed_load_M = 'flatbed_load_M_cargo_load_box_16XL',
      flatbed_load_R = 'flatbed_load_R_cargo_load_box_8XL' }, boxes = 32, payload = 20000,
    price = 4800, pulls = 'semi', size = 'l', len = 16, tow = 'flatbed' },
  { id = 'tanker', family = 'tanker', name = 'Fuel tanker', model = 'tanker', base = 'vehicles/tanker/empty.pc',
    tankL = 34000, payload = 28000, price = 6000, pulls = 'semi', size = 'l', len = 15 },
  { id = 'tanker_short', family = 'tanker', name = 'Short fuel tanker', model = 'tanker', base = 'vehicles/tanker/empty_short.pc',
    tankL = 17700, payload = 15000, price = 4500, pulls = 'semi', size = 'l', len = 10 },
  { id = 'cartrailer', family = 'cartrailer', name = 'Car trailer', model = 'tiltdeck', config = '22ft_standard',
    payload = 5800, price = 1800, pulls = 'hitch', size = 'm', len = 9.5, tow = 'cartrailer' },
  { id = 'smalltrailer', family = 'smalltrailer', name = 'Small car trailer', model = 'boxutility_large',
    configTable = 'small', payload = 1500, price = 1200, pulls = 'hitch', size = 's', len = 6, tow = 'smalltrailer' },
}
local byId = {}
for _, e in ipairs(M.CATALOGUE) do byId[e.id] = e end
M.byId = byId

-- What each family carries: cargo kinds (cargoEarth/haul) and whether it serves tow jobs.
M.FAMILIES = {
  box = { name = 'Box trailer', kinds = { parcel = true, dryBulk = true } },
  flatbed = { name = 'Flatbed', kinds = { parcel = true }, tow = 'heavy' },
  tanker = { name = 'Fuel tanker', kinds = { fluid = true }, cargo = { fuel = true, chemicals = true, lpg = true } },
  cartrailer = { name = 'Car trailer', kinds = {}, tow = 'light' },
  smalltrailer = { name = 'Small car trailer', kinds = {}, tow = 'small' },
}

-- The firm's old trailer kinds (firm.TRAILERS before 2026-11-27) move into the pool as these.
M.FROM_FIRM = { dryvan = 'box48', tanker = 'tanker', flatbed = 'flatbed48', cartrailer = 'cartrailer', smalltrailer = 'smalltrailer' }
-- what a hired driver's shift needs, by the firm's old names (cargoEarth/fleet)
M.FLEET_KIND = { box = 'dryvan', tanker = 'tanker', flatbed = 'flatbed', cartrailer = 'cartrailer', smalltrailer = 'smalltrailer' }

M.SERVICE_SIZE = { s = 0.4, m = 1.2, l = 1.8 }   -- service cost against a car's (cargoEarth/upkeep TIER_COST)
M.RESALE = 0.85          -- a dealer never pays more than this share of what you paid
M.SELL_SHARE = 0.6       -- of the trailer's value now (new price x condition)
M.FETCH_PER_KM = 3       -- bringing a trailer you left somewhere home
M.HQ_YARD = 6            -- trailers the headquarters yard holds
M.NEAR_M = 150           -- a trailer left this close is taken from where you stand

local function round5(x) return math.floor(x / 5 + 0.5) * 5 end
local function finite(x) return type(x) == 'number' and x == x and x > -math.huge and x < math.huge end
local function point(g) return type(g) == 'table' and finite(g[1]) and finite(g[2]) and math.abs(g[1]) <= 90 and math.abs(g[2]) <= 180 end

function M.entry(t) return t and byId[t.cat] or nil end

-- The trailer's own stock config: a table for spawning (format 2) or a config name, and the stock model.
-- read: jsonReadFile (the game's), to lay the load parts over the stock .pc. bulk: aggregate boxes in place of parcel boxes.
function M.config(e, read, bulk)
  if not e then return nil end
  if e.config then return e.model, e.config end
  if e.configTable then return e.model, nil end   -- cargoEarth/trailers builds the small car trailer itself
  local cfg = read and read(e.base)
  if type(cfg) ~= 'table' or type(cfg.parts) ~= 'table' then return e.model, nil end
  for slot, part in pairs((bulk and e.bulkParts) or e.parts or {}) do cfg.parts[slot] = part end
  if bulk and e.bulk then
    for _, suffix in ipairs(M.AGGREGATE_SLOTS) do
      cfg.parts['cargo_load_box_XL_' .. suffix .. '_90deg'] = 'cargo_load_aggregate_box_XL_' .. suffix .. '_90deg'
    end
  end
  return e.model, cfg
end

-- Native capacity of a trailer for a cargo kind: parcel slots or litres; 0 when it cannot carry it.
function M.capacity(e, kind, bulk)
  if not e then return 0 end
  local fam = M.FAMILIES[e.family]
  if not (fam and fam.kinds[kind]) then return 0 end
  if kind == 'fluid' then return e.tankL or 0 end
  if kind == 'dryBulk' then return (bulk and e.bulk) and #M.AGGREGATE_SLOTS * M.BULK_BOX_L or 0 end
  if kind == 'parcel' then return bulk and 0 or (e.boxes or 0) * M.SLOT_UNITS end
  return 0
end

-- May this trailer carry this cargo id of this kind? (A fuel tanker takes no milk: that needs a food tanker.)
function M.carries(e, kind, cargoId, bulk)
  if M.capacity(e, kind, bulk) <= 0 then return false end
  local fam = M.FAMILIES[e.family]
  return not fam.cargo or fam.cargo[cargoId] == true
end

-- The pool in the save: { seq, list = { trailer } }. A trailer: { id, cat, name, km, condition, service = { tyres,
-- brakes }, repair, paid, place = 'home' | 'hq' | 'out' | 'left' | 'driver', at = { lat, lon, n } (where it was left),
-- bulk }. Old firm trailers move in (at the headquarters, as new). Anything that does not make sense is dropped.
function M.restore(c)
  if type(c) ~= 'table' then return nil end
  local p = c.trailers
  if type(p) ~= 'table' then p = { seq = 0, list = {} } c.trailers = p end
  if type(p.list) ~= 'table' then p.list = {} end
  p.seq = math.max(0, math.floor(tonumber(p.seq) or 0))
  local f = type(c.firm) == 'table' and c.firm or nil
  if f and type(f.trailers) == 'table' and #f.trailers > 0 then
    for _, old in ipairs(f.trailers) do
      local cat = type(old) == 'table' and M.FROM_FIRM[old.kind]
      if cat then
        p.seq = p.seq + 1
        p.list[#p.list + 1] = { id = p.seq, cat = cat, name = byId[cat].name, km = 0, condition = 1, repair = 0,
          paid = byId[cat].price, place = 'hq' }
      end
    end
    f.trailers = {}
  end
  for i = #p.list, 1, -1 do
    local t = p.list[i]
    if type(t) ~= 'table' or not byId[t.cat] or type(t.id) ~= 'number' then table.remove(p.list, i)
    else
      t.name = byId[t.cat].name
      t.km = finite(t.km) and math.max(0, t.km) or 0
      t.condition = finite(t.condition) and math.max(0.05, math.min(1, t.condition)) or 1
      t.repair = finite(t.repair) and math.max(0, t.repair) or 0
      t.paid = finite(t.paid) and math.max(0, t.paid) or byId[t.cat].price
      if t.id > p.seq then p.seq = t.id end
      if t.place ~= 'home' and t.place ~= 'hq' and t.place ~= 'out' and t.place ~= 'left' and t.place ~= 'driver' then t.place = 'home' end
      if t.place == 'left' and not (type(t.at) == 'table' and point(t.at.g)) then t.place = 'home' end
      if type(t.service) ~= 'table' then t.service = {} end
      t.isTrailer, t.vclass = true, 'trailer_' .. byId[t.cat].size
      t.bulk = t.bulk == true or nil
    end
  end
  return p
end

function M.list(c) return M.restore(c).list end

function M.find(c, id)
  id = tonumber(id)
  for _, t in ipairs(M.list(c)) do if t.id == id then return t end end
end

-- Trailer spots: home (its step, plus the Trailer yard room) and the headquarters yard.
function M.spots(c, home)
  local n = (home and c.home) and home.trailerSpots(c) or 0
  local hq = (type(c.firm) == 'table' and c.firm.hq) and M.HQ_YARD or 0
  return n, hq
end

function M.count(c, place)
  local n = 0
  for _, t in ipairs(M.list(c)) do if not place or t.place == place then n = n + 1 end end
  return n
end

-- Room for one more: every trailer you own needs a spot to come back to.
function M.room(c, home)
  local h, hq = M.spots(c, home)
  return #M.list(c) < h + hq, h, hq
end

-- Where a trailer goes when parked: home if it has room there, else the headquarters yard.
function M.homeFor(c, home)
  local h, hq = M.spots(c, home)
  local atHome, atHq = 0, 0
  for _, t in ipairs(M.list(c)) do
    if t.place == 'home' then atHome = atHome + 1 elseif t.place == 'hq' then atHq = atHq + 1 end
  end
  if atHome < h then return 'home' end
  if atHq < hq then return 'hq' end
end

-- Its value now: the new price, by condition and kilometres.
function M.value(t)
  local e = M.entry(t)
  if not e then return 0 end
  local wear = math.max(0.3, (t.condition or 1) - math.min(0.3, (t.km or 0) / 400000))
  return round5(e.price * wear)
end

function M.sellQuote(t)
  local q = M.value(t) * M.SELL_SHARE - (t.repair or 0)
  q = math.min(q, (t.paid or 0) * M.RESALE)
  return math.max(0, round5(q))
end

local function add(c, e, fields)
  local p = M.restore(c)
  p.seq = p.seq + 1
  local t = { id = p.seq, cat = e.id, name = e.name, km = 0, condition = 1, repair = 0, paid = e.price, place = 'home',
    service = {}, isTrailer = true, vclass = 'trailer_' .. e.size }
  for k, v in pairs(fields or {}) do t[k] = v end
  p.list[#p.list + 1] = t
  return t
end

-- Buy a new one from the factory: it is delivered to a free spot. home: cargoEarth/home.
function M.buyNew(c, catId, home, debt)
  local e = byId[catId]
  if not e then return false, 'Unknown trailer.' end
  if not c.home then return false, 'Trailers need a home: set your home garage first.' end
  if (debt or 0) > 0 then return false, 'Pay your debt first.' end
  local place = M.room(c, home) and M.homeFor(c, home)
  if not place then return false, 'No free trailer spot. Build a bigger home or a Trailer yard.' end
  if (c.money or 0) < e.price then return false, string.format('Not enough money (%d CZK needed).', e.price) end
  if not economy.post(c, -e.price, 'trailer', economy.nextId(c, 'trailer'), 'New ' .. e.name:lower()) then return false, 'The payment failed.' end
  local t = add(c, e, { place = place })
  return true, string.format('%s bought. It waits %s.', e.name, place == 'home' and 'at home' or 'in the headquarters yard'), t
end

-- Sell a trailer that is parked (home or the headquarters).
function M.sell(c, id)
  local t = M.find(c, id)
  if not t then return false, 'Unknown trailer.' end
  if t.place ~= 'home' and t.place ~= 'hq' then return false, 'Park it at home first.' end
  local price = M.sellQuote(t)
  local p = M.restore(c)
  for i, row in ipairs(p.list) do if row == t then table.remove(p.list, i) break end end
  economy.post(c, price, 'trailer', economy.nextId(c, 'trailer'), 'Sold ' .. t.name:lower())
  return true, string.format('%s sold for %d CZK.', t.name, price), price
end

-- ===== Used trailers =====
-- Listings like used cars: kilometres, condition, faults (worn tyres, worn brakes, a damaged body) and a price of
-- 40-95 % of new. A bought one waits at the seller, a real yard near where it was listed: drive there and take it, or
-- pay to have it delivered home.
M.MARKET_V = 1
M.LIFE_MIN = { 15, 30 }     -- a listing is gone after this many minutes of play
M.PER_FAMILY = 2            -- at least this many listings per family
M.MARKET_SIZE = 14

-- rnd: math.random-like. seller: { n, g = { lat, lon } }.
function M.newListing(e, rnd, seller, seq)
  local condition = 0.35 + rnd() * 0.6
  local km = math.floor((1 - condition) * (250000 + rnd() * 250000) / 100) * 100
  local faults = {}
  local fixes = 0
  if rnd() < (1 - condition) * 1.2 then faults.tyres = true fixes = fixes + 300 * M.SERVICE_SIZE[e.size] end
  if rnd() < (1 - condition) then faults.brakes = true fixes = fixes + 175 * M.SERVICE_SIZE[e.size] end
  local body = 0
  if rnd() < (1 - condition) * 0.8 then body = round5(e.price * (0.05 + rnd() * 0.15)) fixes = fixes + body end
  local price = e.price * (0.4 + 0.55 * condition) - fixes * 0.9
  price = math.max(round5(e.price * 0.4), round5(price))
  return { id = seq, cat = e.id, name = e.name, km = km, condition = math.floor(condition * 100 + 0.5) / 100,
    faults = faults, body = body, price = price, seller = seller }
end

-- The market in the save: { v, seq, list }. Listings age with play minutes; families keep at least PER_FAMILY.
-- sellers: list of { n, g } yards near the player (the newest listings are put there).
function M.marketTick(c, dtMin, rnd, sellers)
  local m = c.trailerMarket
  if type(m) ~= 'table' or m.v ~= M.MARKET_V or type(m.list) ~= 'table' then
    m = { v = M.MARKET_V, seq = 0, list = {} }
    c.trailerMarket = m
  end
  for i = #m.list, 1, -1 do
    local l = m.list[i]
    l.left = (tonumber(l.left) or 0) - (dtMin or 0)
    if l.left <= 0 or not byId[l.cat] then table.remove(m.list, i) end
  end
  if not sellers or #sellers == 0 then return m end
  local per = {}
  for _, l in ipairs(m.list) do local f = byId[l.cat].family per[f] = (per[f] or 0) + 1 end
  local function pick() return sellers[math.floor(rnd() * #sellers) + 1] or sellers[1] end
  for _, e in ipairs(M.CATALOGUE) do
    while (per[e.family] or 0) < M.PER_FAMILY and #m.list < M.MARKET_SIZE + #M.CATALOGUE do
      -- the cheapest of the family when it has more than one size
      local choice = e
      for _, o in ipairs(M.CATALOGUE) do
        if o.family == e.family and rnd() < 0.5 then choice = o end
      end
      m.seq = m.seq + 1
      local l = M.newListing(choice, rnd, pick(), m.seq)
      l.left = M.LIFE_MIN[1] + rnd() * (M.LIFE_MIN[2] - M.LIFE_MIN[1])
      m.list[#m.list + 1] = l
      per[e.family] = (per[e.family] or 0) + 1
    end
  end
  return m
end

function M.listing(c, id)
  local m = c.trailerMarket
  for i, l in ipairs(type(m) == 'table' and m.list or {}) do if l.id == tonumber(id) then return l, i end end
end

-- Buy a used one: it stays at the seller until you take it (or have it delivered home).
function M.buyUsed(c, id, home, debt)
  local l, i = M.listing(c, id)
  if not l then return false, 'That listing is gone.' end
  if not c.home then return false, 'Trailers need a home: set your home garage first.' end
  if (debt or 0) > 0 then return false, 'Pay your debt first.' end
  if not M.room(c, home) then return false, 'No free trailer spot. Build a bigger home or a Trailer yard.' end
  if (c.money or 0) < l.price then return false, string.format('Not enough money (%d CZK needed).', l.price) end
  local e = byId[l.cat]
  if not economy.post(c, -l.price, 'trailer', economy.nextId(c, 'trailer'), 'Used ' .. e.name:lower()) then return false, 'The payment failed.' end
  table.remove(c.trailerMarket.list, i)
  local service = {}
  service.tyres = l.faults.tyres and 2600 or (1 - l.condition) * 1500
  service.brakes = l.faults.brakes and 1700 or (1 - l.condition) * 1000
  local t = add(c, e, { km = l.km, condition = l.condition, repair = l.body or 0, paid = l.price, place = 'left',
    at = { n = l.seller.n, g = { l.seller.g[1], l.seller.g[2] }, seller = true }, service = service })
  return true, string.format('%s bought. It waits at %s: drive there and take it, or have it delivered home.', e.name, l.seller.n), t
end

-- ===== Out and about =====
-- km from where it stands to home (straight), for the fetch price.
function M.fetchCost(km) return math.max(50, round5((km or 0) * 1.3 * M.FETCH_PER_KM)) end

-- Trailer service and wear use cargoEarth/upkeep (no oil on a trailer).

-- The load units of a trailer for a cargo kind: how one step of the load picker counts (one box, one aggregate box,
-- 1,000 L of fluid) and how many of them fit.
function M.unitOf(kind)
  if kind == 'parcel' then return M.SLOT_UNITS, 'box' end
  if kind == 'dryBulk' then return M.BULK_BOX_L, 'bulk box' end
  return 1000, '1,000 L'
end

return M
