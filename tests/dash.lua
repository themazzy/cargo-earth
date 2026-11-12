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
local cam = { pos = seat, fwd = fwd, right = V.v(1, 0, 0), up = up, fov = math.rad(60) }

test('dash phone sits ahead, below the eyes, near the middle of the car, facing the driver', function()
  local c = dash.corners(seat, fwd, up, centre, place)
  assert(#c == 4)
  local mid = V.mul(V.add(V.add(c[1], c[2]), V.add(c[3], c[4])), 0.25)
  assert(near(mid.y, dash.FORWARD, 1e-9) and near(mid.z, 1.2 + dash.DROP, 1e-9))
  assert(near(mid.x, -0.37 + 0.37 * dash.CENTRE, 1e-9), 'moved toward the middle')
  assert(near(V.dot(V.sub(c[1], c[4]), V.sub(c[1], c[4])) ^ 0.5, dash.HEIGHT, 1e-9), 'height')
  assert(near((V.dot(V.sub(c[2], c[1]), V.sub(c[2], c[1]))) ^ 0.5, dash.HEIGHT * dash.ASPECT, 1e-9), 'width')
  local normal = V.unit(V.cross(V.sub(c[2], c[1]), V.sub(c[4], c[1])))
  local look = V.unit(V.sub(mid, seat))
  assert(near(math.abs(V.dot(normal, look)), 1, 1e-9), 'faces the eyes')
  assert(c[2].x > c[1].x and c[1].z > c[4].z, 'top left is up and to the left')
end)

test('right-hand drive cars get the phone on their own side of the middle', function()
  local c = dash.corners(V.v(0.37, 0, 1.2), fwd, up, centre, place)
  local mid = V.mul(V.add(c[1], c[3]), 0.5)
  assert(near(mid.x, 0.37 - 0.37 * dash.CENTRE, 1e-9))
end)

test('dash phone projects into the lower middle of the screen, the right way up', function()
  local p = dash.project(dash.corners(seat, fwd, up, centre, place), cam)
  assert(#p == 8)
  for i = 2, 8, 2 do assert(p[i] < 0 and p[i] > -1, 'below the middle and on screen') end
  assert(p[1] < p[3] and p[7] < p[5], 'left before right')
  assert(p[2] > p[8] and p[4] > p[6], 'top above bottom')
  assert(p[1] > 0, 'right of a left-hand driver')
end)

test('dash phone hides when it is behind the camera', function()
  local back = { pos = seat, fwd = V.v(0, -1, 0), right = V.v(-1, 0, 0), up = up, fov = math.rad(60) }
  assert(dash.project(dash.corners(seat, fwd, up, centre, place), back) == nil)
end)

test('dash phone place is kept per car model, clamped and reset by clicks', function()
  local p = dash.fit({ on = false, rate = 99, models = { van = { x = 5, size = 'big', y = -0.1 }, [3] = {} } })
  assert(p.on == false and p.rate == 30)
  assert(p.models.van.x == dash.LIMITS.x[2] and p.models.van.size == nil and p.models.van.y == -0.1)
  dash.adjust(p, 'pickup', 'size', 1)
  dash.adjust(p, 'pickup', 'size', 1)
  assert(near(dash.placement(p, 'pickup').size, 1.2, 1e-9))
  assert(dash.placement(p, 'van').size == 1)
  for _ = 1, 40 do dash.adjust(p, 'pickup', 'z', -1) end
  assert(near(dash.placement(p, 'pickup').z, dash.LIMITS.z[1], 1e-9))
  dash.adjust(p, 'pickup', 'reset')
  assert(p.models.pickup == nil)
  dash.adjust(p, nil, 'x', 1)
  dash.adjust(p, nil, 'on')
  assert(p.on == true)
  dash.adjust(p, nil, 'rate')
  assert(p.rate == 60)
  dash.adjust(p, nil, 'rate')
  assert(p.rate == 15)
end)

print('Dash phone: ' .. total .. ' checks passed')
