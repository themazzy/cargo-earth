-- cargoEarth/dash: the phone on the dashboard in cockpit view.
-- The phone stays the UI app; in a cockpit camera the app draws it in perspective where the centre of the dash is,
-- so the 3D world needs no extra object, texture or browser. Each update the game places a phone-sized rectangle in
-- the car (from the driver's seat, toward the middle of the car, below the eyes, facing the driver), works out where
-- its corners fall in the camera and sends those four points to the app (hook CargoEarthDash). The app bends the
-- phone onto them with one CSS matrix, so every button stays clickable with the mouse.
-- In VR the game shows the UI on a floating panel that is not tied to the car, so the dash phone turns itself off.
-- Position and size are kept per vehicle model; everything is changed by clicking in the phone's Settings.
local M = {}

M.FILE = '/settings/cargoEarth/dash.json'
M.ASPECT = 290 / 560 -- width / height of the phone app, as drawn by app.js
M.HEIGHT = 0.2       -- metres, at size 1
M.FORWARD = 0.55     -- metres ahead of the driver's eyes
M.DROP = -0.14       -- metres below the eyes
M.CENTRE = 0.85      -- share of the way from the driver's seat to the middle of the car
M.RATES = { 15, 30, 60 }
M.LIMITS = { x = { -0.6, 0.6, 0.03 }, y = { -0.4, 0.4, 0.03 }, z = { -0.4, 0.4, 0.03 }, size = { 0.5, 2, 0.1 } }

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

function M.defaults() return { on = true, rate = 30, models = {} } end

function M.fit(p)
  local out = M.defaults()
  if type(p) ~= 'table' then return out end
  if p.on == false then out.on = false end
  for _, r in ipairs(M.RATES) do if p.rate == r then out.rate = r end end
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

-- what = on | rate | reset | x | y | z | size; dir = +1 | -1 for the steps
function M.adjust(p, model, what, dir)
  if what == 'on' then p.on = not p.on return p end
  if what == 'rate' then
    local i = 1
    for k, r in ipairs(M.RATES) do if r == p.rate then i = k end end
    p.rate = M.RATES[i % #M.RATES + 1]
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

------------------------------------------------------------------------------------------ placing and projecting

-- seat: the driver's eyes; fwd, up: the car's axes; centre: middle of the car. Returns the phone's four corners
-- (top left, top right, bottom right, bottom left) facing the seat.
function M.corners(seat, fwd, up, centre, place)
  fwd, up = unit(fwd), unit(up)
  if not fwd or not up then return nil end
  local right = unit(cross(fwd, up))
  if not right then return nil end
  up = cross(right, fwd)
  local lateral = dot(sub(seat, centre), right) -- where the driver sits across the car (negative: left)
  local p = add(add(add(seat, mul(fwd, M.FORWARD + place.y)), mul(right, place.x - lateral * M.CENTRE)), mul(up, M.DROP + place.z))
  local look = unit(sub(p, seat))
  if not look then return nil end
  local pUp = unit(sub(up, mul(look, dot(up, look))))
  if not pUp then return nil end
  local pRight = cross(look, pUp)
  local h = M.HEIGHT * place.size
  local hw, hh = mul(pRight, h * M.ASPECT / 2), mul(pUp, h / 2)
  return { sub(add(p, hh), hw), add(add(p, hh), hw), sub(add(p, hw), hh), sub(sub(p, hw), hh) }
end

-- cam = { pos, fwd, right, up, fov (vertical, radians) }. Returns the corners as screen units of half the screen
-- height from the centre ({u1, v1, ... u4, v4}, v up), or nil when a corner is behind the camera.
function M.project(corners, cam)
  local t = math.tan(cam.fov / 2)
  if not corners or t <= 0 then return nil end
  local out = {}
  for i, c in ipairs(corners) do
    local d = sub(c, cam.pos)
    local z = dot(d, cam.fwd)
    if z < 0.05 then return nil end
    out[2 * i - 1] = math.floor(dot(d, cam.right) / (z * t) * 10000 + 0.5) / 10000
    out[2 * i] = math.floor(dot(d, cam.up) / (z * t) * 10000 + 0.5) / 10000
  end
  return out
end

------------------------------------------------------------------------------------------ game adapter

local prefs, loaded = nil, false
local acc, sent, last = 0, false, nil

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

-- the four projected corners, or nil when the camera is not in the cabin
local function frame()
  if not core_camera or not be or vrOn() then return nil end
  local veh = playerCar()
  if not veh then return nil end
  local camPos = core_camera.getPosition()
  if not core_camera.isCameraInside or core_camera.isCameraInside(0, camPos) ~= 1 then return nil end
  local node = core_camera.getDriverData(veh)
  if not node then return nil end
  local id = veh:getId()
  local seat = v(veh:getNodeAbsPositionXYZ(node))
  local centre = v(be:getObjectOOBBCenterXYZ(id))
  local corners = M.corners(seat, xyz(veh:getDirectionVector()), xyz(veh:getDirectionVectorUp()), centre,
    M.placement(M.prefs(), modelOf(veh)))
  return M.project(corners, { pos = xyz(camPos), fwd = xyz(core_camera.getForward()), right = xyz(core_camera.getRight()),
    up = xyz(core_camera.getUp()), fov = core_camera.getFovRad() })
end

local function same(a, b)
  if not a or not b then return false end
  for i = 1, 8 do if math.abs(a[i] - b[i]) > 0.0005 then return false end end
  return true
end

-- called every frame before drawing
function M.tick(dt)
  local p = M.prefs()
  acc = acc + (dt or 0)
  if acc < 1 / p.rate then return end
  acc = 0
  local ok, c = pcall(function() return p.on and frame() or nil end)
  if not ok then
    if not M.err then M.err = tostring(c) log('W', 'cargoEarth', 'dash phone: ' .. M.err) end
    c = nil
  end
  if c then
    -- compare with what was last sent, so slow drifts add up and are sent once they cross the threshold
    if not same(c, last) then
      guihooks.trigger('CargoEarthDash', { on = true, c = c })
      last = c
    end
    sent = true
  elseif sent then
    guihooks.trigger('CargoEarthDash', { on = false })
    sent, last = false, nil
  end
end

-- for the phone's Settings
function M.state()
  local p = M.prefs()
  local veh = playerCar()
  local model = veh and modelOf(veh)
  local place = M.placement(p, model)
  return { on = p.on, rate = p.rate, vr = vrOn(), cockpit = sent, model = model, size = place.size,
    moved = model ~= nil and p.models[model] ~= nil }
end

function M.act(what, dir)
  local veh = playerCar()
  M.adjust(M.prefs(), veh and modelOf(veh), what, dir)
  last = nil -- send the new place at once
  acc = 1
  save()
  return M.state()
end

return M
