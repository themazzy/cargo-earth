-- cargoEarth/ui: the jobs window (imgui). Mode, job options, offered jobs, the active job and its debug actions, log.
local M = {}

local im
local open, ptr = nil, {}
local SIZES = { 'S', 'M', 'L', 'XL' }

local function txt(s) im.TextUnformatted(tostring(s)) end

local function wrapped(s)
  im.PushTextWrapPos(0)
  im.TextUnformatted(tostring(s))
  im.PopTextWrapPos()
end

local function intPtr(key, v)
  if not ptr[key] then ptr[key] = im.IntPtr(v) end
  return ptr[key]
end

local function floatPtr(key, v)
  if not ptr[key] then ptr[key] = im.FloatPtr(v) end
  return ptr[key]
end

local function boolPtr(key, v)
  if not ptr[key] then ptr[key] = im.BoolPtr(v) end
  return ptr[key]
end

-- "<  value  >" picker over list (nil = Any). Returns the new value.
local function picker(label, list, cur, name)
  local i = 0
  for k, v in ipairs(list) do if v == cur then i = k end end
  if im.Button('<##' .. label) then i = i - 1 end
  im.SameLine()
  if im.Button('>##' .. label) then i = i + 1 end
  if i < 0 then i = #list end
  if i > #list then i = 0 end
  local v = list[i]
  im.SameLine()
  txt(label .. ': ' .. (v and name(v) or 'Any'))
  return v
end

local function km(v)
  if v < 10 then return string.format('%.1f km', v) end
  return string.format('%d km', math.floor(v + 0.5))
end

local function placeLine(d, S)
  local label = d.label
  if not label and S.idx and d.t then label = S.idx.types[d.t] and S.idx.types[d.t].label end
  local town = (d.town and d.town ~= '') and (', ' .. d.town) or ''
  return string.format('%s (%s%s)', d.n, label or '?', town)
end

local function courierOptions(core, S, mods)
  local o, d = S.opts, mods.food.defaults
  local minKm = floatPtr('c.minKm', o.minKm or d.minKm)
  local maxKm = floatPtr('c.maxKm', o.maxKm or d.maxKm)
  local nearKm = floatPtr('c.nearKm', o.nearKm or d.nearKm)
  local count = intPtr('c.count', o.count or d.count)
  if im.SliderFloat('Shortest order (km)', minKm, 0.2, 15, '%.1f') then core.setOption('minKm', minKm[0]) end
  if im.SliderFloat('Longest order (km)', maxKm, 0.5, 20, '%.1f') then core.setOption('maxKm', maxKm[0]) end
  if im.SliderFloat('Restaurant within (km)', nearKm, 0.3, 15, '%.1f') then core.setOption('nearKm', nearKm[0]) end
  if im.SliderInt('Orders offered', count, 1, 30) then core.setOption('count', count[0]) end
  local auto = boolPtr('c.autoReach', o.autoReach ~= false)
  if im.Checkbox('Widen the search where restaurants are few', auto) then core.setOption('autoReach', auto[0]) end
  if auto[0] then
    local reachMax = floatPtr('c.reachMaxKm', o.reachMaxKm or d.reachMaxKm)
    if im.SliderFloat('Widen up to (km)', reachMax, 3, 50, '%.0f') then core.setOption('reachMaxKm', reachMax[0]) end
  end
  S.fchoices = S.fchoices or mods.food.choices(S.fidx)
  core.setOption('cat', picker('Food', S.fchoices.cats, o.cat, function(v) return S.fidx.cats[v] end))
end

local function truckOptions(core, S, mods)
  local o, d = S.opts, mods.jobs.defaults
  S.choices = S.choices or mods.jobs.choices(S.idx)
  local ch, idx = S.choices, S.idx
  local minKm = intPtr('t.minKm', o.minKm or d.minKm)
  local maxKm = intPtr('t.maxKm', o.maxKm or d.maxKm)
  local nearKm = intPtr('t.nearKm', o.nearKm or d.nearKm)
  local count = intPtr('t.count', o.count or d.count)
  if im.SliderInt('Shortest job (km)', minKm, 5, 600) then core.setOption('minKm', minKm[0]) end
  if im.SliderInt('Longest job (km)', maxKm, 10, 800) then core.setOption('maxKm', maxKm[0]) end
  if im.SliderInt('Pickup within (km)', nearKm, 1, 150) then core.setOption('nearKm', nearKm[0]) end
  if im.SliderInt('Jobs offered', count, 1, 40) then core.setOption('count', count[0]) end
  local adr = boolPtr('t.adr', o.adr ~= false)
  if im.Checkbox('Dangerous goods (ADR)', adr) then core.setOption('adr', adr[0]) end
  core.setOption('cargo', picker('Cargo', ch.cargo, o.cargo, function(v) return idx.cargo[v].name end))
  core.setOption('trailer', picker('Trailer', ch.trailers, o.trailer, function(v) return idx.trailers[v] end))
  core.setOption('fromType', picker('Pickup type', ch.types, o.fromType, function(v) return idx.types[v].label end))
  core.setOption('toType', picker('Delivery type', ch.types, o.toType, function(v) return idx.types[v].label end))
  core.setOption('minSize', picker('Smallest site', SIZES, o.minSize, function(v) return v end))
end

local function options(core, S, mods)
  if S.mode == 'courier' then courierOptions(core, S, mods) else truckOptions(core, S, mods) end
  if im.Button('Generate jobs') then
    core.saveOptions()
    core.generate()
  end
  im.SameLine()
  if im.Button('Reset options') then
    core.resetOptions()
    ptr = {}
  end
end

local function offers(core, S)
  local st = S.offerStats
  if not S.offeredAt then txt('No jobs yet: they are offered once the world has loaded.') return end
  if #S.offers == 0 then
    wrapped(string.format('No jobs with these options. Pickups in reach: %d, pickups with no destination in range: %d.',
      st and st.pickups or 0, st and st.noDest or 0))
    return
  end
  if st and st.widened then
    wrapped(string.format('Few restaurants here: searched within %s and orders up to %s.', km(st.reachKm), km(st.maxKm)))
  end
  for i, j in ipairs(S.offers) do
    im.Separator()
    if j.kind == 'food' then
      txt(string.format('%d. %s  |  %s  |  %d CZK  |  %d min', i, j.cargoName, km(j.km), j.pay, j.minutes))
    else
      txt(string.format('%d. %s%s  |  %s  |  %d t  |  %s  |  %d CZK  |  %d min', i, j.cargoName, j.adr and ' [ADR]' or '',
        S.idx.trailers[j.trailer] or j.trailer, j.tonnes, km(j.km), j.pay, j.minutes))
    end
    txt('   from ' .. placeLine(j.from, S) .. ', ' .. km(j.pickupKm) .. ' away' ..
      ((j.farPickup or 0) > 0 and string.format(' (+%d CZK for the ride)', j.farPickup) or ''))
    txt('   to   ' .. placeLine(j.to, S))
    if im.Button('Take##o' .. i) then core.take(i) end
    im.SameLine()
    if im.Button('Teleport to pickup##o' .. i) then core.teleport('offer', i) end
  end
end

local function active(core, S, trailers)
  local j = S.job
  local r = core.rules(j)
  if j.kind == 'food' then txt(j.cargoName)
  else
    txt(string.format('%s%s, %s, %d t', j.cargoName, j.adr and ' [ADR]' or '', S.idx and S.idx.trailers[j.trailer] or
      j.trailer, j.tonnes or 0))
  end
  txt('From: ' .. placeLine(j.from, S))
  txt('To:   ' .. placeLine(j.to, S))
  local mins = core.elapsed(j) / 60
  txt(string.format('%s  |  pay %d CZK  |  time %d / %d min', km(j.km), j.pay, mins, j.minutes))
  txt(S.phase == 'toPickup' and 'Now: drive to the pickup' or 'Now: deliver')
  if S.dist then
    txt(string.format('Distance: %s  (stop within %d m for %d s)',
      S.dist >= 1000 and string.format('%.1f km', S.dist / 1000) or string.format('%d m', S.dist), core.arrivalRadius(j), r.stopS))
    if S.roadM then txt(string.format('By road: %s%s', S.roadM >= 1000 and string.format('%.1f km', S.roadM / 1000) or
      string.format('%d m', S.roadM), S.etaS and string.format(', about %d min', math.ceil(S.etaS / 60)) or '')) end
  end
  if j.trailerSpawned then
    local d = trailers.distanceToPlayer()
    txt('Trailer: ' .. (d and string.format('%d m from the truck', d) or 'gone'))
  end
  if im.Button('Teleport to pickup') then core.teleport('pickup') end
  im.SameLine()
  if im.Button('Teleport to delivery') then core.teleport('delivery') end
  im.SameLine()
  if im.Button('GPS again') then core.gpsAgain() end
  if im.Button(S.phase == 'toPickup' and 'Force pickup' or 'Force deliver') then core.forceArrive() end
  if j.trailer then
    im.SameLine()
    if im.Button('Spawn trailer here') then core.spawnTrailer() end
  end
  im.SameLine()
  if im.Button('Cancel (free)') then core.cancel(true) end
end

-- The stop overlay at the top of the screen: a progress bar while you wait at the pickup / delivery, or a hint to stop
-- when you're in the zone but still rolling. st: core.stopInfo().
local stopFailed = false
function M.drawStop(st)
  im = im or ui_imgui
  if not im or stopFailed or not st or not st.inZone then return end
  local ok, err = pcall(function()
    local w = 380
    local io = im.GetIO()
    local sw = io and io.DisplaySize and io.DisplaySize.x or 1280
    im.SetNextWindowPos(im.ImVec2((sw - w) / 2, 90), im.Cond_Always)
    im.SetNextWindowSize(im.ImVec2(w, 0), im.Cond_Always)
    im.SetNextWindowBgAlpha(0.8)
    local flags = im.WindowFlags_NoTitleBar + im.WindowFlags_NoResize + im.WindowFlags_NoMove +
      im.WindowFlags_NoScrollbar + im.WindowFlags_NoSavedSettings + im.WindowFlags_NoInputs +
      im.WindowFlags_NoFocusOnAppearing + im.WindowFlags_AlwaysAutoResize
    if im.Begin('##cargoEarthStop', nil, flags) then
      local what = st.pickup and 'Picking up the order' or 'Handing over the order'
      if st.stopping then
        txt(what)
        im.ProgressBar(st.frac, im.ImVec2(w - 16, 26), string.format('%.1f s', st.leftS))
      else
        txt(st.pickup and 'You are at the pickup: stop to pick up' or 'You are at the customer: stop to deliver')
        im.ProgressBar(0, im.ImVec2(w - 16, 26), string.format('stand still %d s', st.stopS))
      end
    end
    im.End()
  end)
  if not ok then
    stopFailed = true
    if log then log('W', 'cargoEarth', 'stop overlay turned off: ' .. tostring(err)) end
  end
end

-- BeamNG's configuration screen can hide the HUD phone. Keep a return button on the game overlay.
local partsExitError
function M.drawPartsExit(leave, summary, hasPreview)
  if not leave then partsExitError = nil return end
  im = im or ui_imgui
  if not im then return end
  local w = 300
  local io = im.GetIO()
  local sw = io and io.DisplaySize and io.DisplaySize.x or 1280
  im.SetNextWindowPos(im.ImVec2(math.max(8, sw - w - 24), 84), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(w, 0), im.Cond_Always)
  local flags = im.WindowFlags_NoResize + im.WindowFlags_NoMove + im.WindowFlags_NoSavedSettings
    + im.WindowFlags_NoFocusOnAppearing + im.WindowFlags_AlwaysAutoResize
  if im.Begin('Cargo Earth · Parts preview##cargoEarthPartsExit', nil, flags) then
    wrapped('Search for a part or expand a slot to browse. If Live updates is off, click Apply to preview your choices.')
    if summary then wrapped(summary) end
    if im.Button(hasPreview and 'Review on phone' or 'Back to phone') then
      local ok, why = leave()
      partsExitError = not ok and why or nil
    end
    if partsExitError then wrapped(partsExitError) end
  end
  im.End()
end

-- A one-line text box; returns its text ('' when the game's imgui has no text boxes).
local bufs = {}
local function textInput(key, label)
  if not im.ArrayChar or not im.InputText then return '' end
  if not bufs[key] then bufs[key] = im.ArrayChar(64) end
  im.InputText(label .. '##' .. key, bufs[key], 64)
  local ok, s = pcall(function() return require('ffi').string(bufs[key]) end)
  return ok and s or ''
end

local garageView = { dealer = nil, msg = nil }

local function czk(n) return string.format('%d CZK', math.floor((n or 0) + 0.5)) end

-- The garage: the career car, repairs, its real parts (bought and swapped), spare parts and used cars.
local function garageSection(core, S)
  local G, garage, g = core.G, core.garage, S.career.garage
  local function did(ok, msg) garageView.msg = msg if ok then garageView.dealer = nil end end
  if garageView.msg then wrapped(garageView.msg) end
  if not g.started then
    wrapped('Start a courier career: you get a cheap old ' .. tostring(S.config.starterModel or garage.STARTER_MODEL) ..
      ' and ' .. garage.START_MONEY .. ' CZK. Your money now is replaced. Orders then only come while you drive this car.')
    if im.Button('Start a career with the starter car') then did(core.garageStart()) end
    return
  end
  txt('Your car: ' .. (g.car and g.car.name or '?') .. '   worth about ' .. czk(garage.carValue(G)))
  if not garage.inOwnCar(G, g) then
    txt('You are not in it.')
    im.SameLine()
    if im.Button('Bring my car') then did(core.garageBringCar()) end
    return
  end
  txt('Repair: ' .. czk(g.repair) .. string.format('   (game damage %d)', g.lastDamage or 0) .. '   Debt: ' .. czk(g.debt))
  if (g.repair or 0) > 0 then
    im.SameLine()
    if im.Button('Repair (' .. czk(g.repair) .. ')') then did(core.garageRepair()) end
  end
  if (g.debt or 0) > 0 then
    im.SameLine()
    if im.Button('Pay the debt') then did(core.garagePayDebt()) end
  end
  if im.Button('Bring my car') then did(core.garageBringCar()) end
  im.SameLine()
  if im.Button('Check the parts system (writes garage_probe.json)') then
    local r = core.garageProbe()
    garageView.msg = string.format('Probe: model %s, %d slots, %d in the shop, %d car configs, damage %s. Saved to settings/cargoEarth/garage_probe.json.',
      tostring(r.model), r.slotPaths or 0, r.shopSlots or 0, r.configs or 0, tostring(r.damage))
  end

  wrapped('Use Menu → Garage on the phone to open BeamNG’s parts editor and review the purchase.')

  if im.TreeNode1('Spare parts##ceSpares') then
    local sp = garage.spares(G, g)
    if #sp == 0 then txt('None. Parts you take off are kept here.') end
    for _, s in ipairs(sp) do
      if im.Button('Sell ' .. czk(s.price) .. '##sell' .. s.part) then did(core.garageSell(s.part)) end
      im.SameLine()
      txt(s.name .. (s.count > 1 and (' x' .. s.count) or ''))
    end
    im.TreePop()
  end

  if im.TreeNode1('Used cars##ceCars') then
    local f = textInput('carFilter', 'Find a car')
    if f ~= garageView.dealerFilter then garageView.dealer, garageView.dealerFilter = nil, f end
    garageView.dealer = garageView.dealer or garage.dealer(G, f, 25)
    local tradeIn = math.floor(garage.carValue(G) * garage.TRADE_IN / 5 + 0.5) * 5
    txt('Your car is taken in for ' .. czk(tradeIn) .. '. Spare parts stay yours.')
    for i, o in ipairs(garageView.dealer) do
      if im.Button('Buy ' .. czk(o.price) .. '##car' .. i) then did(core.garageBuy(o)) end
      im.SameLine()
      txt(o.name)
    end
    im.TreePop()
  end
end

-- Debug: edit the money and the career numbers.
local editing = {}
local function careerDebug(core, S)
  local c, g = S.career, S.career.garage
  local fields = {
    { 'Money (CZK)', function() return c.money or 0 end, function(v) c.money = v end },
    { 'Deliveries', function() return c.delivered or 0 end, function(v) c.delivered = v end },
    { 'Driven (km)', function() return c.km or 0 end, function(v) c.km = v end },
    { 'Earned today (CZK)', function() return type(c.today) == 'table' and c.today.earned or 0 end,
      function(v) if type(c.today) ~= 'table' then c.today = { date = os.date('%Y-%m-%d'), earned = 0, count = 0 } end c.today.earned = v end },
    { 'Orders today', function() return type(c.today) == 'table' and c.today.count or 0 end,
      function(v) if type(c.today) ~= 'table' then c.today = { date = os.date('%Y-%m-%d'), earned = 0, count = 0 } end c.today.count = v end },
    { 'Debt (CZK)', function() return g.debt or 0 end, function(v) g.debt = math.max(0, v) end },
    { 'Car odometer (km)', function() return g.car and g.car.km or 0 end, function(v) if g.car then g.car.km = math.max(0, v) end end },
  }
  for i, f in ipairs(fields) do
    local p = intPtr('dbg' .. i, 0)
    if not editing[i] then p[0] = math.floor(f[2]() + 0.5) end   -- follows the game unless being typed in
    if im.InputInt(f[1] .. '##dbg' .. i, p) then f[3](p[0]) core.saveOptions() end
    editing[i] = im.IsItemActive and im.IsItemActive() or false
  end
  if im.Button('+10 000 CZK') then c.money = (c.money or 0) + 10000 core.saveOptions() end
  im.SameLine()
  if im.Button('New market') then g.market = nil core.garageDealer('') end
  if g.started and im.Button('Reset the career (back to the start screen)') then
    S.career.garage = core.garage.new()
    core.saveOptions()
  end
end

-- Draws the window. Returns false when the player closed it.
function M.draw(core, S, mods, earth, trailers)
  im = im or ui_imgui
  if not im then return true end
  open = open or im.BoolPtr(true)
  open[0] = true
  im.SetNextWindowSize(im.ImVec2(640, 660), im.Cond_FirstUseEver)
  if im.Begin('Cargo Earth##cargoEarth', open) then
    if S.loadError then
      wrapped(S.loadError)
    else
      local p = earth.pose()
      txt(string.format('Money: %d CZK   Delivered: %d   Driven: %s', S.career.money or 0, S.career.delivered or 0,
        km(S.career.km or 0)))
      txt('BeamNG.Earth: ' .. earth.status() .. (p and string.format('   at %.5f, %.5f   %d km/h', p.lat, p.lon,
        (p.speed or 0) * 3.6) or ''))
      if not S.job then
        if im.Button((S.mode == 'courier' and '[Courier]' or 'Courier') .. '##mode1') then core.setMode('courier') end
        im.SameLine()
        if im.Button((S.mode == 'trucking' and '[Trucking]' or 'Trucking') .. '##mode2') then core.setMode('trucking') end
        im.SameLine()
        txt(S.mode == 'courier' and 'Food orders, any car' or 'Cargo with a trailer')
      end
      wrapped(S.packInfo)
      local hi = core.helperInfo and core.helperInfo()
      if hi then
        wrapped(string.format('Helper (restaurants anywhere): %s%s%s', hi.state,
          (hi.loading or 0) > 0 and string.format(', %d areas loading', hi.loading) or '', hi.msg and (': ' .. hi.msg) or ''))
      end
      im.Separator()
      if S.job then
        if im.CollapsingHeader1('Active job', im.TreeNodeFlags_DefaultOpen) then active(core, S, trailers) end
      elseif (S.mode == 'courier' and not S.fidx) or (S.mode == 'trucking' and not S.idx) then
        txt('No data pack for this mode.')
      else
        if im.CollapsingHeader1('Options', im.TreeNodeFlags_DefaultOpen) then options(core, S, mods) end
        if im.CollapsingHeader1('Offered jobs', im.TreeNodeFlags_DefaultOpen) then offers(core, S) end
      end
      if S.mode == 'courier' and im.CollapsingHeader1('Garage') then garageSection(core, S) end
      if im.CollapsingHeader1('Money and stats (debug)') then careerDebug(core, S) end
      if im.CollapsingHeader1('Log') then
        for _, l in ipairs(S.log) do txt(l) end
      end
    end
  end
  im.End()
  return open[0]
end

return M
