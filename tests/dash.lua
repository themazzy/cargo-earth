local dash = require('cargoEarth/dash')
local V = dash.vec
local total = 0
local function test(name, fn)
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  total = total + 1
  print('PASS ' .. name)
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- a car pointing north (+y), up +z, driver 0.37 m left of the middle, eyes 1.2 m up
local fwd, up = V.v(0, 1, 0), V.v(0, 0, 1)
local seat, centre = V.v(-0.37, 0, 1.2), V.v(0, -0.5, 0.8)
local place = dash.placement(dash.defaults(), 'pickup')

test('VR dash screen sits ahead, below the eyes, near the middle of the car', function()
  local p = dash.spot(seat, fwd, up, centre, place)
  assert(near(p.y, dash.FORWARD, 1e-9) and near(p.z, 1.2 + dash.DROP, 1e-9))
  assert(near(p.x, -0.37 + 0.37 * dash.CENTRE, 1e-9), 'moved toward the middle')
  local rhd = dash.spot(V.v(0.37, 0, 1.2), fwd, up, centre, place)
  assert(near(rhd.x, 0.37 - 0.37 * dash.CENTRE, 1e-9), 'right-hand drive stays on its own side')
  local moved = dash.spot(seat, fwd, up, centre, { x = 0.03, y = -0.06, z = 0.09, size = 1 })
  assert(near(moved.x - p.x, 0.03, 1e-9) and near(moved.y - p.y, -0.06, 1e-9) and near(moved.z - p.z, 0.09, 1e-9))
end)

test('VR dash screen shows in VR by default, always or never on request, only in the cockpit', function()
  local p = dash.defaults()
  assert(dash.wanted(p, true, true) and not dash.wanted(p, false, true) and not dash.wanted(p, true, false))
  dash.adjust(p, nil, 'show')
  assert(p.show == 'always' and dash.wanted(p, false, true))
  dash.adjust(p, nil, 'show')
  assert(p.show == 'off' and not dash.wanted(p, true, true))
  dash.adjust(p, nil, 'show')
  assert(p.show == 'vr')
end)

test('VR dash screen place is kept per car model, clamped and reset', function()
  local p = dash.fit({ show = 'sometimes', rate = 30, models = { van = { x = 5, size = 'big', y = -0.1 }, [3] = {} } })
  assert(p.show == 'vr' and p.rate == nil)
  assert(p.models.van.x == dash.LIMITS.x[2] and p.models.van.size == nil and p.models.van.y == -0.1)
  dash.adjust(p, 'pickup', 'size', 1)
  dash.adjust(p, 'pickup', 'size', 1)
  assert(near(dash.placement(p, 'pickup').size, 1.2, 1e-9))
  assert(dash.placement(p, 'van').size == 1)
  for _ = 1, 40 do dash.adjust(p, 'pickup', 'z', -1) end
  assert(near(dash.placement(p, 'pickup').z, dash.LIMITS.z[1], 1e-9))
  dash.adjust(p, 'pickup', 'reset')
  assert(p.models.pickup == nil)
  dash.adjust(p, nil, 'x', 1) -- no car: nothing to move
end)

local function money(n) return tostring(math.floor(n + 0.5)) .. ' Kč' end

test('VR dash screen shows the current stop, an incoming order and the idle states', function()
  local c = dash.card({ screen = 'active', clock = '14:52', money = 2480, limit = { sign = 50, over = true },
    active = { phase = 'toDelivery', from = { name = 'Pho' }, to = { name = 'Korunní 88' }, distM = 1840, leftS = 640, pay = 115,
      stop = { inZone = true, stopping = false } } }, money)
  assert(c.label == 'Drop off' and c.title == 'Korunní 88' and c.big == '1,8 km', c.big)
  assert(c.sub == 'time left 10:40 · 115 Kč' and c.note == 'Stop here' and c.limit == '50' and c.over)
  c = dash.card({ screen = 'active', active = { phase = 'toPickup', from = { name = 'Pho' }, distM = 85, leftS = -75, pay = 90 } }, money)
  assert(c.label == 'Pick up' and c.big == '85 m' and c.sub == 'late 1:15 · 90 Kč' and c.late)
  c = dash.card({ screen = 'incoming', incoming = { from = { name = 'Pizza' }, to = { name = 'Dlouhá 5' }, pay = 120, km = 3.4, leftS = 17.6 } }, money)
  assert(c.label == 'New order · 17 s' and c.big == '120 Kč' and c.sub == 'to Dlouhá 5 · 3,4 km' and c.note)
  assert(dash.card({ screen = 'waiting', todayEarned = 300 }, money).title == 'Waiting for orders')
  assert(dash.card({ screen = 'done', done = { to = 'Dlouhá 5', pay = 100, tip = 20 } }, money).big == '120 Kč')
  assert(dash.card(nil, money).sub == 'Starting…')
  assert(dash.card({ screen = 'error', error = 'Load the BeamNG.Earth level' }, money).sub == 'Load the BeamNG.Earth level')
end)

test('VR dash screen picture is rebuilt only when what it shows changes', function()
  local a = dash.card({ screen = 'waiting', clock = '10:00', money = 1, todayEarned = 0 }, money)
  local b = dash.card({ screen = 'waiting', clock = '10:00', money = 1, todayEarned = 0 }, money)
  assert(dash.signature(a) == dash.signature(b))
  b = dash.card({ screen = 'waiting', clock = '10:01', money = 1, todayEarned = 0 }, money)
  assert(dash.signature(a) ~= dash.signature(b))
  local t = dash.template(dash.card({ screen = 'active', limit = { sign = 50 }, active = { phase = 'toPickup', from = { name = 'Pho' }, distM = 85, leftS = 60, pay = 90 } }, money), 'font.ttf')
  assert(t.size[1] == dash.CANVAS[1] and t.root.type == 'box')
  local texts = 0
  local function walk(n) if n.type == 'text' then texts = texts + 1 assert(n.font == 'font.ttf') end for _, k in ipairs(n.children or {}) do walk(k) end end
  walk(t.root)
  assert(texts >= 7, texts)
end)

print('Dash phone: ' .. total .. ' checks passed')
