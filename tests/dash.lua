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
  assert(c.label == 'New order · 17 s' and c.big == '120 Kč' and c.sub == 'to Dlouhá 5 · 3,4 km' and #c.buttons == 2)
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

local tap = require('cargoEarth/dashtap')

test('VR dash screen buttons follow the phone and press what they show', function()
  local b = tap.buttons({ screen = 'incoming', incoming = {} })
  assert(b[1].action == 'decline' and b[2].action == 'accept')
  assert(tap.actionFor(b, 1) == 'decline' and tap.actionFor(b, 2) == 'accept' and tap.actionFor(b, 3) == nil)
  b = tap.buttons({ screen = 'active', active = {} })
  assert(#b == 1 and tap.actionFor(b, 1) == 'gps' and tap.actionFor(b, 2) == 'gps', 'one button fills the row')
  assert(tap.buttons({ screen = 'offline' })[1].action == 'online')
  assert(tap.buttons({ screen = 'waiting' })[1].action == 'offline')
  assert(tap.buttons({ screen = 'done', done = {} })[1].action == 'dismiss')
  assert(tap.buttons({ screen = 'resume' })[1].action == 'resume')
  assert(#tap.buttons({ screen = 'error' }) == 0 and #tap.buttons(nil) == 0)
  assert(tap.actionFor({}, 1) == nil)
  local incoming = tap.buttons({ screen = 'incoming', incoming = {} })
  local waiting = tap.buttons({ screen = 'waiting' })
  assert(tap.pressed(incoming, incoming, 2) == 'accept')
  assert(tap.pressed(waiting, incoming, 1) == nil, 'a stale Go offline does not decline the new order')
  assert(tap.pressed(waiting, incoming, 2) == nil and tap.pressed({}, incoming, 1) == nil)
  for _, x in ipairs(tap.buttons({ screen = 'incoming', incoming = {} })) do assert(x.action ~= 'cancel') end
end)

test('VR dash screen buttons sit on the bottom row of the picture', function()
  local W, H = dash.CANVAS[1], dash.CANVAS[2]
  local slots, inner = tap.slots(W, H)
  assert(near(slots[1].x, -slots[2].x) and slots[1].x < 0 and near(slots[1].y, slots[2].y))
  assert(near(2 * slots[1].w + tap.ROW.gap, inner) and inner < W)
  assert(near(slots[1].y, -(H / 2 - tap.ROW.bottom - tap.ROW.height / 2)), 'row centre')
  -- in the world: the car points north, its right is +x
  local p = tap.places(V.v(0, 1, 1), 0.16, V.v(1, 0, 0), V.v(0, 0, 1), W, H)
  assert(p[1].pos.x < 0 and p[2].pos.x > 0 and p[1].pos.z < 1 and near(p[1].pos.y, 1))
  assert(near(p[1].pos.z, 1 + slots[1].y * 0.16 / H) and near(p[1].w, slots[1].w * 0.16 / H * tap.GROW))
  local t = dash.template(dash.card({ screen = 'incoming', incoming = { pay = 10 } }, money))
  local row = t.root.children[1].children[#t.root.children[1].children]
  assert(#row.children == 2 and row.children[2].children[1].text == 'Accept')
  assert(row.style.height == tap.ROW.height)
end)

test('VR dash screen buttons are placed in the car frame', function()
  -- the same car in the jbeam (facing -y) and live in the world, turned 90 degrees and moved
  local jr, jl, jb = V.v(0, 0, 0.5), V.v(1, 0, 0.5), V.v(0, 1, 0.5)
  local function live(p) return V.v(10 - p.y, 20 + p.x, p.z + 3) end
  local fl, fj = tap.frame(live(jr), live(jl), live(jb)), tap.frame(jr, jl, jb)
  local point = V.v(0.3, -0.6, 1.1)
  local back = tap.toJbeam(live(point), fl, fj)
  assert(near(back.x, 0.3, 1e-9) and near(back.y, -0.6, 1e-9) and near(back.z, 1.1, 1e-9))
  assert(tap.frame(jr, jr, jb) == nil, 'degenerate nodes')
end)

test('a car with the phone part hides the floating screen until it is respawned', function()
  dash.partCar(7)
  assert(dash.isPartCar(7) and not dash.isPartCar(8))
  dash.dropCar(7)
  assert(not dash.isPartCar(7), 'a respawn without the part brings the floating screen back')
end)

print('Dash phone: ' .. total .. ' checks passed')
