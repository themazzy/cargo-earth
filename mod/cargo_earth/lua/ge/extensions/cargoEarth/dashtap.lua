-- cargoEarth/dashtap: buttons on the VR dash screen, pressed with the game's own cockpit interaction.
-- BeamNG cars have clickable parts in the cockpit (doors, lights, parking brake): jbeam "triggers". In VR they are
-- pressed by pointing a controller at them and pulling its trigger; on a monitor by clicking them with the mouse.
-- The dash screen uses the same system: while it is shown, the player's car gets two invisible trigger boxes over the
-- screen's two button spots (left and right). Pressing one runs cargoEarth_core.dashTap(slot), which reads the phone's
-- current state and does what that button says right now (accept, decline, go online, route, ...).
--   * The boxes are added to the car at runtime with the same calls the game uses for jbeam triggers, and linked to
--     two small input actions in the car's data, so the game's hover label shows the button's name.
--   * They are placed once (and again only when the screen moves, is resized or the car is reloaded), in the car's
--     own frame, so they ride along with the car without any per-frame work.
--   * When the screen is hidden, the boxes are shrunk to nothing and their links removed.
local M = {}

-- the button row on the screen picture (pixels, see dash.template)
M.ROW = { height = 96, padX = 14, gap = 12, bottom = 26 } -- bottom: the frame (12) and the screen's padding (14)
M.DEPTH = 0.05   -- metres: how thick the boxes are, so a slightly-off laser still hits
M.GROW = 1.1     -- boxes are a bit larger than the drawn buttons
M.ACTION = 'cargoEarthDash'

------------------------------------------------------------------------------------------ what the buttons do

-- The buttons for a phone state: up to two { label, action, tone }. One button fills the whole row.
function M.buttons(s)
  local screen = s and s.screen
  if screen == 'incoming' and s.incoming then
    return { { label = 'Decline', action = 'decline', tone = 'quiet' }, { label = 'Accept', action = 'accept', tone = 'go' } }
  elseif screen == 'active' and s.active then
    return { { label = 'Route', action = 'gps', tone = 'main' } }
  elseif screen == 'done' and s.done then
    return { { label = 'OK', action = 'dismiss', tone = 'main' } }
  elseif screen == 'waiting' then
    return { { label = 'Go offline', action = 'offline', tone = 'quiet' } }
  elseif screen == 'offline' then
    return { { label = 'Go online', action = 'online', tone = 'go' } }
  elseif screen == 'resume' then
    return { { label = 'Resume', action = 'resume', tone = 'go' } }
  end
  return {}
end

-- slot 1 = left, 2 = right. With one button both halves press it.
function M.actionFor(buttons, slot)
  if #buttons == 1 then return buttons[1].action end
  local b = buttons[slot]
  return b and b.action or nil
end

------------------------------------------------------------------------------------------ where the boxes go

-- The two slots on a W x H picture, as offsets from its centre in pixels (x right, y up) and sizes.
function M.slots(W, H)
  local R = M.ROW
  local inner = W - 24 - 2 * R.padX -- the screen's width inside the 12 px frame, minus the row's padding
  local w = (inner - R.gap) / 2
  local cy = H / 2 - (H - R.bottom - R.height / 2)
  local dx = w / 2 + R.gap / 2
  return { { x = -dx, y = cy, w = w, h = R.height }, { x = dx, y = cy, w = w, h = R.height } }, inner
end

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

-- World centres of the two slots. centre: middle of the picture; height: its height in metres; right, up: the car's.
function M.places(centre, height, right, up, W, H)
  local px = height / H
  local out = {}
  for i, s in ipairs((M.slots(W, H))) do
    out[i] = { pos = add(add(centre, mul(right, s.x * px)), mul(up, s.y * px)),
      w = s.w * px * M.GROW, h = s.h * px * M.GROW }
  end
  return out
end

-- An orthonormal frame from three nodes: origin r, first axis toward a, second toward b.
function M.frame(r, a, b)
  local a1 = unit(sub(a, r))
  if not a1 then return nil end
  local d = sub(b, r)
  local a2 = unit(sub(d, mul(a1, dot(d, a1))))
  if not a2 then return nil end
  return { o = r, a1 = a1, a2 = a2, a3 = cross(a1, a2) }
end

-- a world point to the car's jbeam coordinates, through the same three nodes seen live and in the jbeam
function M.toJbeam(p, live, jb)
  local d = sub(p, live.o)
  local c1, c2, c3 = dot(d, live.a1), dot(d, live.a2), dot(d, live.a3)
  return add(add(add(jb.o, mul(jb.a1, c1)), mul(jb.a2, c2)), mul(jb.a3, c3))
end

------------------------------------------------------------------------------------------ game adapter

local car = nil -- { id, vdata, abids = { [slot] = abid }, key }

local function xyz(a) return v(a.x, a.y, a.z) end

local function vdataOf(id)
  local vm = rawget(_G, 'extensions') and extensions.core_vehicle_manager
  local d = vm and vm.getVehicleData and vm.getVehicleData(id)
  return d and d.vdata or nil
end

local function refNodes(vdata)
  local r = type(vdata.refNodes) == 'table' and vdata.refNodes[0] or nil
  if not (r and r.ref and r.left and r.back) then return nil end
  return r
end

local function actionName(slot) return M.ACTION .. tostring(slot) end

-- the car's data: the two input actions the boxes run, and their link rows
local function link(vdata, slot, abid, on, label)
  vdata.inputActions = vdata.inputActions or {}
  vdata.triggerEventLinksDict = vdata.triggerEventLinksDict or {}
  local name = actionName(slot)
  vdata.inputActions[name] = { title = label or 'Cargo Earth', ctx = 'elua', cat = 'vehicle_specific',
    onDown = 'if cargoEarth_core then cargoEarth_core.dashTap(' .. slot .. ') end' }
  if on then
    vdata.triggerEventLinksDict[abid] = { action0 = { { version = 2, namespace = 'vehicle', inputAction = name,
      triggerId = abid, triggerInput = 'action0' } } }
  else
    vdata.triggerEventLinksDict[abid] = nil
  end
end

local function shape(abo, nodes, jbPos, w, h)
  abo:set(nodes.ref, nodes.left, nodes.back)
  abo:setBaseTranslationGlobal(vec3(jbPos.x, jbPos.y, jbPos.z))
  abo.typeId = 0
  abo:setBoxSize(vec3(w, M.DEPTH, h)) -- x along the car (toward its left node), y toward its back, z up
  abo:update(vec3(0, 0, 0), vec3(0, 0, 0), true, 0)
end

local function inert(c)
  local veh = c and getObjectByID and getObjectByID(c.id)
  if not veh then return end
  for slot, abid in pairs(c.abids) do
    pcall(function()
      link(c.vdata, slot, abid, false)
      local abo = veh:getTrigger(abid)
      if abo then abo:setBoxSize(vec3(0.001, 0.001, 0.001)) abo:update(vec3(0, 0, 0), vec3(0, 0, 0), true, 0) end
    end)
  end
  c.key = nil
end

-- Place (or keep) the boxes on the player's car. centre/height: the screen as drawn now; buttons: from M.buttons.
function M.sync(veh, centre, height, buttons, W, H)
  local id = veh:getId()
  local vdata = vdataOf(id)
  if not vdata then return end
  if car and (car.id ~= id or car.vdata ~= vdata) then
    if car.id ~= id then inert(car) end
    car = nil
  end
  local nodes = refNodes(vdata)
  if not nodes or not vdata.nodes then return end
  if not car then
    car = { id = id, vdata = vdata, abids = {} }
    for slot = 1, 2 do
      local abid = veh:addTrigger()
      if not abid or abid < 0 then car = nil return end
      car.abids[slot] = abid
      vdata.triggers = vdata.triggers or {}
      vdata.triggers[abid] = { cid = abid, id = actionName(slot), name = 'Cargo Earth', label = '', type = 'box' }
    end
    if extensions and not rawget(_G, 'core_vehicleTriggers') then extensions.load('core_vehicleTriggers') end
  end
  local labels = {}
  for i, b in ipairs(buttons) do labels[i] = b.label end
  -- the boxes ride with the car, so only a moved screen (in the car's frame) needs them placed again
  local live = M.frame(v(veh:getNodeAbsPositionXYZ(nodes.ref)), v(veh:getNodeAbsPositionXYZ(nodes.left)), v(veh:getNodeAbsPositionXYZ(nodes.back)))
  local function jpos(cid) local p = vdata.nodes[cid] and vdata.nodes[cid].pos return p and xyz(p) end
  local jr, jl, jbk = jpos(nodes.ref), jpos(nodes.left), jpos(nodes.back)
  local jb = jr and jl and jbk and M.frame(jr, jl, jbk)
  if not live or not jb then return end
  local cj = M.toJbeam(centre, live, jb)
  local localKey = string.format('%.2f|%.2f|%.2f|%.3f|%s', cj.x, cj.y, cj.z, height, table.concat(labels, '|'))
  if car.key == localKey then return end
  car.key = localKey
  local fwd, up = xyz(veh:getDirectionVector()), xyz(veh:getDirectionVectorUp())
  local right = unit(cross(fwd, up))
  if not right then return end
  up = cross(right, fwd)
  local spots = M.places(centre, height, right, up, W, H)
  for slot, abid in pairs(car.abids) do
    local abo = veh:getTrigger(abid)
    if abo then
      local s = spots[slot]
      local on = M.actionFor(buttons, slot) ~= nil
      shape(abo, nodes, M.toJbeam(s.pos, live, jb), on and s.w or 0.001, on and s.h or 0.001)
      local b = #buttons == 1 and buttons[1] or buttons[slot]
      link(vdata, slot, abid, on, b and b.label)
    end
  end
end

-- the screen is not shown: nothing to press
function M.off()
  if car and car.key then inert(car) end
end

-- the level is going away and the car with it
function M.forget() car = nil end

return M
