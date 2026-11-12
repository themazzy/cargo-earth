-- cargoEarth/dash: a phone screen on the dashboard, for VR.
-- In VR, BeamNG shows the UI on a floating panel that is not tied to the car. So for VR the mod puts a small phone
-- screen in the 3D world, at the centre of the dash: a Skia billboard (WorldBillboardRenderer, the engine's own path
-- for name tags and world icons). It is not a browser view, and nothing is drawn per frame in Lua.
--   * Each frame only its position is set: ahead of the driver's seat, below the eyes, most of the way to the middle
--     of the car. A billboard always faces the camera, so it always faces the driver's head.
--   * Its picture is rebuilt only when what it shows changes, at most once a second: the current order, distance,
--     time left, pay, an incoming order with its countdown, the speed limit, the clock and the money.
--   * Its buttons (accept, decline, route, go online ...) are pressed like the car's own cockpit buttons: point a VR
--     controller at them and pull its trigger, or click them with the mouse (see cargoEarth/dashtap).
-- Settings (on the phone): show it in VR only (default), always (also on a monitor, handy for placing it) or never;
-- move it and resize it. Every car model keeps its own place (settings/cargoEarth/dash.json).
local tap = require('cargoEarth/dashtap')
local M = {}

M.FILE = '/settings/cargoEarth/dash.json'
M.HEIGHT = 0.16      -- metres, at size 1
M.FORWARD = 0.55     -- metres ahead of the driver's eyes
M.DROP = -0.14       -- metres below the eyes
M.CENTRE = 0.85      -- share of the way from the driver's seat to the middle of the car
M.SHOWS = { 'vr', 'always', 'off' }
M.LIMITS = { x = { -0.6, 0.6, 0.03 }, y = { -0.4, 0.4, 0.03 }, z = { -0.4, 0.4, 0.03 }, size = { 0.5, 2, 0.1 } }
M.CANVAS = { 360, 640 } -- pixels of the picture
M.REFRESH = 1           -- seconds between rebuilding the picture (only when it changed)
M.RENDERER = 'cargoEarthDashPhone'

------------------------------------------------------------------------------------------ vector maths (plain tables)

local function v(x, y, z) return { x = x, y = y, z = z } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function unit(a)
  local l = math.sqrt(dot(a, a))
  if l < 1e-9 then return nil end
  return mul(a, 1 / l)
end
M.vec = { v = v, add = add, sub = sub, mul = mul, dot = dot, cross = cross, unit = unit }

------------------------------------------------------------------------------------------ preferences

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

function M.defaults() return { show = 'vr', models = {} } end

function M.fit(p)
  local out = M.defaults()
  if type(p) ~= 'table' then return out end
  for _, s in ipairs(M.SHOWS) do if p.show == s then out.show = s end end
  for model, m in pairs(type(p.models) == 'table' and p.models or {}) do
    if type(model) == 'string' and type(m) == 'table' then
      local fitted = {}
      for key, lim in pairs(M.LIMITS) do
        local n = tonumber(m[key])
        if n and n == n then fitted[key] = clamp(n, lim[1], lim[2]) end
      end
      out.models[model] = fitted
    end
  end
  return out
end

-- this model's placement, filled with the defaults
function M.placement(p, model)
  local m = (p and p.models and model and p.models[model]) or {}
  return { x = m.x or 0, y = m.y or 0, z = m.z or 0, size = m.size or 1 }
end

-- what = show | reset | x | y | z | size; dir = +1 | -1 for the steps
function M.adjust(p, model, what, dir)
  if what == 'show' then
    local i = 1
    for k, s in ipairs(M.SHOWS) do if s == p.show then i = k end end
    p.show = M.SHOWS[i % #M.SHOWS + 1]
    return p
  end
  if not model then return p end
  if what == 'reset' then p.models[model] = nil return p end
  local lim = M.LIMITS[what]
  if not lim then return p end
  local m = p.models[model] or {}
  local now = M.placement(p, model)[what]
  local n = now + lim[3] * ((tonumber(dir) or 0) < 0 and -1 or 1)
  m[what] = clamp(math.floor(n / lim[3] + 0.5) * lim[3], lim[1], lim[2])
  p.models[model] = m
  return p
end

-- should it be drawn now?
function M.wanted(p, vr, cockpit)
  if not cockpit or p.show == 'off' then return false end
  return p.show == 'always' or vr
end

------------------------------------------------------------------------------------------ where it sits

-- seat: the driver's eyes; fwd, up: the car's axes; centre: middle of the car. Returns the centre of the phone.
function M.spot(seat, fwd, up, centre, place)
  fwd, up = unit(fwd), unit(up)
  if not fwd or not up then return nil end
  local right = unit(cross(fwd, up))
  if not right then return nil end
  up = cross(right, fwd)
  local lateral = dot(sub(seat, centre), right) -- where the driver sits across the car (negative: left)
  return add(add(add(seat, mul(fwd, M.FORWARD + place.y)), mul(right, place.x - lateral * M.CENTRE)), mul(up, M.DROP + place.z))
end

------------------------------------------------------------------------------------------ what it shows

local function clockOf(s)
  s = math.max(0, math.floor((tonumber(s) or 0) + 0.5))
  return string.format('%d:%02d', math.floor(s / 60), s % 60)
end

local function distOf(m)
  m = tonumber(m)
  if not m then return '–' end
  if m >= 1000 then
    local km = m / 1000
    return (km < 10 and string.format('%.1f', km) or tostring(math.floor(km + 0.5))):gsub('%.', ',') .. ' km'
  end
  return tostring(m < 100 and math.floor(m + 0.5) or math.floor(m / 10 + 0.5) * 10) .. ' m'
end

local function name(p) return type(p) == 'table' and (p.name or p.n) or nil end

-- The phone state (core.phoneState) as a few lines for the dash. money(n) formats an amount in local money.
-- Returns { clock, money, limit, over, label, title, big, sub, note, tone }.
function M.card(s, money)
  local fmt = money or function(n) return tostring(math.floor(n + 0.5)) end
  money = function(n) return fmt(tonumber(n) or 0) end
  local c = { clock = s and s.clock or '', money = s and money(s.money) or '', tone = 'idle', buttons = tap.buttons(s) }
  if not s then
    c.title = 'Cargo Earth'
    c.sub = 'Starting…'
    return c
  end
  if s.limit then c.limit, c.over = tostring(s.limit.sign), s.limit.over == true end
  local screen = s.screen
  if screen == 'incoming' and s.incoming then
    local i = s.incoming
    c.tone, c.label = 'ring', 'New order · ' .. tostring(math.max(0, math.floor(i.leftS or 0))) .. ' s'
    c.title = name(i.from) or i.cargo or 'Order'
    c.big = money(i.pay)
    c.sub = (name(i.to) and ('to ' .. name(i.to)) or '') .. (i.km and (' · ' .. tostring(i.km):gsub('%.', ',') .. ' km') or '')
  elseif screen == 'active' and s.active then
    local a = s.active
    local pickup = a.phase == 'toPickup'
    c.tone, c.label = pickup and 'pickup' or 'drop', pickup and 'Pick up' or 'Drop off'
    c.title = name(pickup and a.from or a.to) or ''
    c.big = distOf(a.distM)
    c.sub = (a.leftS and a.leftS < 0 and ('late ' .. clockOf(-a.leftS)) or ('time left ' .. clockOf(a.leftS))) .. ' · ' .. money(a.pay)
    c.late = a.leftS ~= nil and a.leftS < 0
    if a.stop and a.stop.inZone then c.note = a.stop.stopping and 'Hold still…' or 'Stop here' end
  elseif screen == 'done' and s.done then
    c.tone, c.label, c.title = 'done', 'Delivered', name(s.done) or s.done.to or ''
    c.big = money((s.done.pay or 0) + (s.done.tip or 0))
    if (s.done.tip or 0) > 0 then c.sub = 'with a tip of ' .. money(s.done.tip) end
  elseif screen == 'waiting' then
    c.label, c.title, c.sub = 'Online', 'Waiting for orders', 'Today ' .. money(s.todayEarned)
  elseif screen == 'offline' then
    c.label, c.title, c.sub = 'Offline', 'Not taking orders', 'Today ' .. money(s.todayEarned)
  elseif screen == 'company' then
    c.label, c.title, c.sub = 'Company work', s.company or 'Contract', 'Details on the phone'
  elseif screen == 'resume' then
    c.title, c.sub = 'Career paused', 'Your saved career is ready'
  else
    c.title, c.sub = 'Cargo Earth', s.error and tostring(s.error):sub(1, 60) or 'Open the phone'
  end
  return c
end

function M.buttonKey(buttons)
  local out = {}
  for i, b in ipairs(buttons or {}) do out[i] = b.label end
  return table.concat(out, '/')
end

-- a string that changes only when the picture would change
function M.signature(c)
  return table.concat({ c.clock or '', c.money or '', c.limit or '', tostring(c.over), c.label or '', c.title or '',
    c.big or '', c.sub or '', c.note or '', c.tone or '', tostring(c.late), M.buttonKey(c.buttons) }, '|')
end

local BUTTONS = { go = '#2f8f5b', quiet = '#7b726a', main = '#1d1b19' }
local TONES = { idle = '#7b726a', ring = '#e8452c', pickup = '#e8452c', drop = '#1d1b19', done = '#2f8f5b' }

local function text(t, size, color, extra)
  local n = { type = 'text', text = t, fontSize = size, color = color, fit = 'shrink', style = { width = '100%', height = size * 1.3 } }
  for k, val in pairs(extra or {}) do n[k] = val end
  return n
end

-- The Skia template (see BeamNG's template reference: box, group, text, flex style) for one card.
function M.template(c, font)
  local W, H = M.CANVAS[1], M.CANVAS[2]
  local f = font and { font = font } or nil
  local function t(s, size, color, align)
    local extra = { textAlign = align }
    if f then extra.font = f.font end
    return text(s, size, color, extra)
  end
  local top = { type = 'group', style = { flexDirection = 'row', justifyContent = 'space-between', alignItems = 'center',
    width = '100%', height = 44, paddingHorizontal = 22 }, children = {
      t(c.clock or '', 22, '#1d1b19', 'left'), t(c.money or '', 22, '#1d1b19', 'right') } }
  top.children[1].style.width, top.children[2].style.width = '45%', '55%'
  local body = { type = 'group', style = { flexDirection = 'column', justifyContent = 'center', alignItems = 'center',
    flexGrow = 1, width = '100%', paddingHorizontal = 22, gap = 8 }, children = {} }
  local kids = body.children
  if c.label then
    kids[#kids + 1] = { type = 'box', color = TONES[c.tone] or TONES.idle, radius = 16,
      style = { paddingHorizontal = 16, height = 34, justifyContent = 'center', alignItems = 'center', minWidth = 120 },
      children = { t(c.label, 20, '#ffffff') } }
  end
  if c.title then kids[#kids + 1] = t(c.title, 30, '#1d1b19') end
  if c.big then kids[#kids + 1] = t(c.big, 64, c.late and '#e8452c' or '#1d1b19') end
  if c.sub then kids[#kids + 1] = t(c.sub, 22, c.late and '#e8452c' or '#7b726a') end
  if c.note then kids[#kids + 1] = t(c.note, 22, '#c98a10') end
  local screen = { type = 'box', color = '#fbf7f2', radius = 30,
    style = { flexDirection = 'column', width = '100%', height = '100%', paddingVertical = 14, alignItems = 'center' },
    children = { top, body } }
  if c.limit then
    screen.children[#screen.children + 1] = { type = 'box', color = c.over and '#d62d20' or '#ffffff', radius = '50%',
      stroke = '#d62d20', strokeWidth = 9, style = { width = 92, height = 92, justifyContent = 'center', alignItems = 'center',
      marginBottom = 18 }, children = { t(c.limit, 36, c.over and '#ffffff' or '#111111') } }
  end
  local buttons = c.buttons or {}
  if #buttons > 0 then
    local R = tap.ROW
    local _, inner = tap.slots(W, H)
    local row = { type = 'group', style = { flexDirection = 'row', justifyContent = 'space-between', width = '100%',
      height = R.height, paddingHorizontal = R.padX }, children = {} }
    for _, b in ipairs(buttons) do
      row.children[#row.children + 1] = { type = 'box', color = BUTTONS[b.tone] or BUTTONS.main, radius = 22,
        style = { width = #buttons == 1 and inner or (inner - R.gap) / 2, height = R.height, justifyContent = 'center',
        alignItems = 'center' }, children = { t(b.label, 30, '#ffffff') } }
    end
    screen.children[#screen.children + 1] = row
  end
  return {
    type = 'skiaIcon', size = { W, H }, -- the same template shape the game's world icons use
    root = { type = 'box', color = '#141312', radius = 44, style = { width = W, height = H, padding = 12 }, children = { screen } },
  }
end

------------------------------------------------------------------------------------------ game adapter

local prefs, loaded = nil, false
local renderer, rid, sig, nextBuild = nil, nil, nil, 0
local font, fontRead = nil, false
local hidden = true
local shownButtons = {} -- the buttons on the current picture

function M.prefs()
  if not loaded then
    loaded = true
    prefs = M.fit(jsonReadFile and jsonReadFile(M.FILE) or nil)
  end
  return prefs
end

local function save()
  if jsonWriteFile then pcall(jsonWriteFile, M.FILE, prefs, true) end
end

local function vrOn()
  local s = rawget(_G, 'render_openxr') and render_openxr.state
  return type(s) == 'table' and (s.enabled == true or s.sessionRunning == true)
end

local function playerCar()
  return (be and be.getPlayerVehicle and be:getPlayerVehicle(0)) or (getPlayerVehicle and getPlayerVehicle(0)) or nil
end

local function modelOf(veh)
  local ok, m = pcall(function() return veh.getJBeamFilename and veh:getJBeamFilename() or veh.jbeam end)
  return ok and type(m) == 'string' and m ~= '' and m or nil
end

local function xyz(a) return v(a.x, a.y, a.z) end

-- the game's own label font, the one its world icons use
local function gameFont()
  if not fontRead then
    fontRead = true
    local cfg = jsonReadFile and jsonReadFile('ui/ui-vue/src/assets/fonts/bngIcons/iconMarkerConfig.json')
    font = type(cfg) == 'table' and type(cfg.label) == 'table' and cfg.label.path or nil
  end
  return font
end

-- the live renderer, made on first use and found again after a level change
local function getRenderer()
  if renderer and renderer.create then return renderer end
  rid, sig = nil, nil
  local live = scenetree and scenetree[M.RENDERER]
  if live then renderer = live return live end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then renderer = nil return nil end
  local r = WorldBillboardRenderer()
  if not r then return nil end
  r:registerObject(M.RENDERER)
  scenetree.MissionGroup:addObject(r)
  renderer = r
  return r
end

local function hide()
  pcall(tap.off)
  if hidden then return end
  hidden = true
  if renderer and rid then pcall(function() renderer:update(rid, vec3(0, 0, -10000), 0, false) end) end
end

-- rebuild the picture when what it shows has changed
local function build(r, phoneState, money, now)
  if rid and now < nextBuild then return end
  local c = M.card(phoneState(), money)
  local s = M.signature(c)
  if rid and s == sig then nextBuild = now + M.REFRESH return end
  local id = r:create(jsonEncode(M.template(c, gameFont())), false)
  if not id or id == 0 then return end
  r:render(id, '{}')
  if rid then local old = rid pcall(function() r:destroy(old) end) end
  rid, sig, nextBuild = id, s, now + M.REFRESH
  shownButtons = c.buttons or {}
end

local function spotNow(veh)
  local node = core_camera.getDriverData(veh)
  if not node then return nil end
  local seat = v(veh:getNodeAbsPositionXYZ(node))
  local centre = v(be:getObjectOOBBCenterXYZ(veh:getId()))
  local place = M.placement(M.prefs(), modelOf(veh))
  return M.spot(seat, xyz(veh:getDirectionVector()), xyz(veh:getDirectionVectorUp()), centre, place), place
end

local clock = 0
-- every frame before drawing. phoneState() and money(n) come from core.
function M.tick(dt, phoneState, money)
  clock = clock + (dt or 0)
  local ok, err = pcall(function()
    local veh = core_camera and be and playerCar()
    local cockpit = veh and core_camera.isCameraInside and core_camera.isCameraInside(0, core_camera.getPosition()) == 1
    if not veh or not M.wanted(M.prefs(), vrOn(), cockpit) then hide() return end
    local pos, place = spotNow(veh)
    local r = pos and getRenderer()
    if not r then hide() return end
    build(r, phoneState, money, clock)
    if not rid then return end
    r:update(rid, vec3(pos.x, pos.y, pos.z), M.HEIGHT * place.size, true)
    hidden = false
    tap.sync(veh, pos, M.HEIGHT * place.size, shownButtons, M.CANVAS[1], M.CANVAS[2])
  end)
  if not ok then
    hide()
    if not M.err then M.err = tostring(err) log('W', 'cargoEarth', 'dash phone: ' .. M.err) end
  end
end

-- the mod is unloading: take the billboard and its scene object away, or a frozen phone would stay in the car
function M.remove()
  pcall(tap.off)
  local r, id = renderer, rid
  renderer, rid, sig, hidden = nil, nil, nil, true
  if not r then r = scenetree and scenetree[M.RENDERER] end
  if not r then return end
  if id then pcall(function() r:destroy(id) end) end
  pcall(function() r:delete() end)
end

-- the level is going away and takes the renderer with it
function M.forget()
  tap.forget()
  renderer, rid, sig, hidden = nil, nil, nil, true
end

-- for the phone's Settings
function M.state()
  local p = M.prefs()
  local veh = playerCar()
  local model = veh and modelOf(veh)
  local place = M.placement(p, model)
  return { show = p.show, vr = vrOn(), shown = not hidden, model = model, size = place.size,
    moved = model ~= nil and p.models[model] ~= nil }
end

function M.act(what, dir)
  local veh = playerCar()
  M.adjust(M.prefs(), veh and modelOf(veh), what, dir)
  save()
  return M.state()
end

return M
