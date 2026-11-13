-- cargoEarth/dash: the phone on the dashboard of any car, for cockpit and VR play.
--
-- The phone is a car part made for the car it goes in, "Cargo Earth phone" (cargo_earth_phone_auto). It has a phone
-- mesh on the dash, turned to face the driver's head, that shows the full phone app as its texture
-- (vehicles/common/cargo_earth_phone/phone.html, run by lua/vehicle/controller/cargoEarthPhone.lua). A grid of the
-- car's own cockpit triggers covers the screen, so you press it by pointing a VR controller and pulling its trigger,
-- or by clicking it.
--
-- No car has a slot for it, and no file describes it. While the switch in Settings > Phone on the dashboard is on,
-- this module steps into the game's jbeam part lookup (lua/common/jbeam/io.lua, wrapped by install()):
--   * every car's main part gets one more slot, "cargo_earth_phone", empty by default;
--   * the part for it is built here, for the car's model, from a spot measured on that car (findSpot: the driver's
--     head from the car's driver camera, the dash from its nodes) plus the player's nudges.
-- Only a car whose parts tree chooses the part gets it: the player's car, which the game side (core.lua) respawns with
-- it. Traffic cars never do. Once fitted, it is in the car's config, so BeamNG keeps it through its own respawns.
-- The game stays in charge of everything else (flexbody, triggers, controller), exactly as for a part from a file.
local M = {}
local cfg_on -- set below: is the switch on

M.PART = 'cargo_earth_phone_auto'
M.SLOT = 'cargo_earth_phone'
M.FILE = '/settings/cargoEarth/dash.json'
M.SPOT_VERSION = 2                     -- bump when findSpot changes, so saved spots are measured again
M.COLS, M.ROWS = 6, 12
M.SCREEN_W = 0.100                     -- must match tools/make-phone-mesh.py
M.SCREEN_H = 0.100 * 560 / 290
M.DEPTH = 0.012                        -- how thick each click box is
M.YAW_STEP, M.YAW_MAX = 5, 70          -- the meshes come turned in 5 degree steps (tools/make-dash-phone.py)
M.NUDGE_STEP, M.NUDGE_MAX = 0.01, 0.25 -- metres per press, and the most a nudge moves the phone
M.OLD_RENDERER = 'cargoEarthDashPhone' -- the old floating picture's scene object

------------------------------------------------------------------------------------------ small vector helpers

local function v3(x, y, z) return { x = x, y = y, z = z } end
local function sub(a, b) return v3(a.x - b.x, a.y - b.y, a.z - b.z) end
local function add(a, b) return v3(a.x + b.x, a.y + b.y, a.z + b.z) end
local function mul(a, s) return v3(a.x * s, a.y * s, a.z * s) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function len(a) return math.sqrt(dot(a, a)) end
local function unit(a) local n = len(a) return n > 0 and mul(a, 1 / n) or a end
local function round(x, d) local m = 10 ^ (d or 4) return math.floor(x * m + 0.5) / m end
local function pos(p)
  local t = type(p)
  if t ~= 'table' and t ~= 'cdata' and t ~= 'userdata' then return nil end -- the game's vec3 is cdata
  local ok, x, y, z = pcall(function()
    if t == 'table' then return tonumber(p.x or p[1]), tonumber(p.y or p[2]), tonumber(p.z or p[3]) end
    return tonumber(p.x), tonumber(p.y), tonumber(p.z)
  end)
  if not ok then return nil end
  if x and y and z and x == x and y == y and z == z then return v3(x, y, z) end
end
M.vec = { sub = sub, add = add, dot = dot, cross = cross, len = len, unit = unit }

-- turns p about the vertical by deg degrees (positive: +y toward -x), like tools/make-phone-mesh.py
local function turn(p, deg)
  local c, s = math.cos(math.rad(deg)), math.sin(math.rad(deg))
  return v3(p.x * c - p.y * s, p.x * s + p.y * c, p.z)
end
M.turn = turn

------------------------------------------------------------------------------------------ measuring a car

-- The driver's head (jbeam coordinates: the car faces -y, z is up, +x is the driver's left) from the car's processed
-- jbeam data (core_vehicle_manager.getVehicleData(id).vdata), and the node the driver camera rides on, if any.
function M.eyeOf(vdata)
  local cams = type(vdata) == 'table' and type(vdata.cameras) == 'table' and vdata.cameras or {}
  local nodes = type(vdata) == 'table' and type(vdata.nodes) == 'table' and vdata.nodes or {}
  local function fromNode(id) local n = id ~= nil and nodes[id] return n and pos(n.pos) end
  local occ = type(cams.occupant) == 'table' and cams.occupant or {}
  local onboard = type(cams.onboard) == 'table' and cams.onboard or {}
  local candidates = {}
  local function consider(c) if type(c) == 'table' then candidates[#candidates + 1] = c end end
  -- the occupant seat the driver sits in (BeamNG 0.38+), then the older driver camera; never the hood camera
  local seats = {}
  for id, c in pairs(occ) do if type(c) == 'table' and c.defaultPermissionMode == 'driver' then seats[#seats + 1] = tostring(id) end end
  table.sort(seats)
  for _, id in ipairs(seats) do consider(occ[id]) end
  consider(occ.driver)
  consider(cams.driver)
  for _, c in pairs(onboard) do if type(c) == 'table' and c.name == 'driver' then consider(c) end end
  local rest = {}
  for id in pairs(occ) do rest[#rest + 1] = tostring(id) end
  table.sort(rest)
  for _, id in ipairs(rest) do consider(occ[id]) end
  for _, c in ipairs(candidates) do
    local p = fromNode(c.camNodeID) or pos(c)
    if p then return p, c.camNodeID end
  end
end

-- a node's groups as a sorted list of names. While the car loads, n.group is a list (or, after the game's group
-- pass, a table keyed by group number); once it has loaded the game deletes it, and only n.firstGroup is left, which
-- names the node's first group through vdata.groups (name -> number).
local function groupsOf(n, byNumber)
  local groups = {}
  if type(n.group) == 'string' and n.group ~= '' then groups[1] = n.group
  elseif type(n.group) == 'table' then
    for _, g in pairs(n.group) do if type(g) == 'string' and g ~= '' then groups[#groups + 1] = g end end
    table.sort(groups)
  elseif byNumber and n.firstGroup ~= nil and byNumber[n.firstGroup] then
    groups[1] = byNumber[n.firstGroup]
  end
  return groups
end

-- The car's named nodes as a plain list: { name, pos, groups = { name, ... } }, leaving out the camera's own node.
-- vdata: the loaded car (core_vehicle_manager.getVehicleData(id).vdata) or the car while it loads.
function M.nodesOf(vdata, skip)
  local out = {}
  local byNumber = {}
  if type(vdata) == 'table' and type(vdata.groups) == 'table' then
    for name, num in pairs(vdata.groups) do if type(name) == 'string' then byNumber[num] = name end end
  end
  for id, n in pairs(type(vdata) == 'table' and type(vdata.nodes) == 'table' and vdata.nodes or {}) do
    local name = type(n) == 'table' and (type(n.name) == 'string' and n.name or type(id) == 'string' and id) or nil
    local p = name and (skip == nil or (id ~= skip and n.cid ~= skip)) and pos(n.pos)
    if p then out[#out + 1] = { name = name, pos = p, groups = groupsOf(n, byNumber) } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The nodes of cars as they loaded, with all their groups (the loaded car keeps only each node's first group).
-- Filled from the game's onJbeamLoadingPhase2 hook, for the last few cars, while the switch is on.
M.KEEP_LOADED = 6
local loaded, loadedOrder = {}, {}
function M.captureLoading(objID, vehicle)
  if not cfg_on() or objID == nil or type(vehicle) ~= 'table' then return end
  local nodes = M.nodesOf(vehicle)
  if #nodes == 0 then return end
  if not loaded[objID] then loadedOrder[#loadedOrder + 1] = objID end
  loaded[objID] = { model = vehicle.model, nodes = nodes }
  while #loadedOrder > M.KEEP_LOADED do loaded[table.remove(loadedOrder, 1)] = nil end
end
-- the nodes car id had when it loaded (nil when it loaded from the game's cache, before the switch, or is another model)
function M.loadedNodes(objID, model, skipName)
  local l = loaded[objID]
  if not l or (model and l.model and l.model ~= model) then return nil end
  if not skipName then return l.nodes end
  local out = {}
  for _, n in ipairs(l.nodes) do if n.name ~= skipName then out[#out + 1] = n end end
  return out
end
function M.forgetLoaded() loaded, loadedOrder = {}, {} end

local function quantYaw(deg)
  local q = math.floor(deg / M.YAW_STEP + 0.5) * M.YAW_STEP
  return math.max(-M.YAW_MAX, math.min(M.YAW_MAX, q))
end

-- degrees to turn the phone's face (+y at 0) toward the eyes, about the vertical, in the meshes' steps
function M.yaw(centre, eye)
  local d = sub(eye, centre)
  return quantYaw(math.deg((math.atan2 or math.atan)(-d.x, d.y)))
end

local DASH_WORDS = { 'dash' }
local OTHER_WORDS = { 'windshield', 'windscreen', 'glass', 'window', 'hood', 'bonnet', 'shifter', 'gearbox', 'steer',
  'seat', 'wiper', 'mirror', 'door', 'occupant' }
-- true when any of the node groups has one of the words in its name
local function hasWord(groups, words)
  for _, g in ipairs(groups or {}) do
    local low = g:lower()
    for _, w in ipairs(words) do if low:find(w, 1, true) then return true end end
  end
  return false
end

-- Where the phone goes in a car: in front of the driver, toward the middle of the car (so left- and right-hand drive
-- both work), standing on the dash near its back edge, below the driver's eyes. nodes: M.nodesOf, eye: M.eyeOf.
-- Returns spot = { v, eye, centre, group, ref, x, y } (ref/x/y: { name, pos }, the click grid's frame) or nil, why.
function M.findSpot(nodes, eye)
  eye = pos(eye)
  if not eye then return nil, 'This car has no driver camera.' end
  local x0 = eye.x * 0.15
  local function around(width, keep)
    local out = {}
    for _, n in ipairs(nodes) do
      local p = n.pos
      if math.abs(p.x - x0) < width and p.y < eye.y - 0.25 and p.y > eye.y - 1.1
        and p.z < eye.z - 0.05 and p.z > eye.z - 0.65 and keep(n) then out[#out + 1] = n end
    end
    return out
  end
  -- the dashboard's own nodes when the car names them so (most do: <model>_dash), else anything that is not glass,
  -- the hood, the gear lever, the steering or a seat
  local dashNamed = function(n) return hasWord(n.groups, DASH_WORDS) end
  local notOther = function(n) return not hasWord(n.groups, OTHER_WORDS) end
  local dash = around(0.3, dashNamed)
  if #dash < 2 then
    dash = around(0.2, notOther)
    if #dash < 3 then dash = around(0.3, notOther) end
  end
  if #dash < 2 then return nil, 'The dashboard of this car could not be found.' end
  local top = -math.huge
  for _, n in ipairs(dash) do top = math.max(top, n.pos.z) end
  local back = -math.huge
  for _, n in ipairs(dash) do if n.pos.z >= top - 0.1 then back = math.max(back, n.pos.y) end end
  local centre = v3(x0,
    math.max(eye.y - 0.75, math.min(eye.y - 0.4, back + 0.027)),
    math.min(top + 0.08, eye.z - 0.12))

  -- the node group the phone hangs on: the one with most nodes near it
  local count, near = {}, {}
  for _, n in ipairs(nodes) do
    if len(sub(n.pos, centre)) < 0.45 and #n.groups > 0 then
      near[#near + 1] = n
      for _, g in ipairs(n.groups) do count[g] = (count[g] or 0) + 1 end
    end
  end
  local group
  local function better(g, c)
    if not group then return true end
    local d, dg = hasWord({ g }, DASH_WORDS), hasWord({ group }, DASH_WORDS)
    if d ~= dg then return d end
    return c > count[group] or (c == count[group] and g < group)
  end
  for g, c in pairs(count) do
    if not hasWord({ g }, OTHER_WORDS) and better(g, c) then group = g end
  end
  if not group then return nil, 'The dashboard of this car could not be found.' end
  local members = {}
  for _, n in ipairs(nodes) do
    for _, g in ipairs(n.groups) do if g == group then members[#members + 1] = n break end end
  end
  -- the click grid's frame: three nodes of that group, one near the phone, one across the car from it, one off that line
  local ref
  for _, n in ipairs(members) do
    if not ref or len(sub(n.pos, centre)) < len(sub(ref.pos, centre)) then ref = n end
  end
  local xn, xScore
  for _, n in ipairs(members) do
    local d = sub(n.pos, ref.pos)
    local l = len(d)
    if l > 0.08 and l < 0.9 then
      local s = math.abs(d.x) / l
      if not xScore or s > xScore + 1e-9 then xn, xScore = n, s end
    end
  end
  if not xn then return nil, 'The dashboard of this car could not be found.' end
  local xdir = unit(sub(xn.pos, ref.pos))
  local yn, yScore
  for _, n in ipairs(members) do
    local d = sub(n.pos, ref.pos)
    local l = len(d)
    if l > 0.05 and l < 0.9 and n ~= xn then
      local s = len(cross(mul(d, 1 / l), xdir))
      if not yScore or s > yScore + 1e-9 then yn, yScore = n, s end
    end
  end
  if not yn or yScore < 0.3 then return nil, 'The dashboard of this car could not be found.' end
  local function keep(n) return { name = n.name, pos = n.pos } end
  return { v = M.SPOT_VERSION, eye = eye, centre = centre, group = group, ref = keep(ref), x = keep(xn), y = keep(yn) }
end

------------------------------------------------------------------------------------------ the part

local function clampNudge(n)
  local out = {}
  for _, k in ipairs({ 'x', 'y', 'z' }) do
    local v = tonumber(type(n) == 'table' and n[k]) or 0
    out[k] = math.max(-M.NUDGE_MAX, math.min(M.NUDGE_MAX, v))
  end
  return out
end

function M.meshSuffix(yaw)
  return '_y' .. (yaw < 0 and 'm' or 'p') .. math.floor(math.abs(yaw) + 0.5)
end

local function frame(spot)
  local o = spot.ref.pos
  local x = unit(sub(spot.x.pos, o))
  local y0 = sub(spot.y.pos, o)
  local y = unit(sub(y0, mul(x, dot(y0, x))))
  return o, x, y, cross(x, y)
end

-- where the phone's screen is: its middle and how far it is turned
function M.placement(spot, nudge)
  local n = clampNudge(nudge)
  local centre = add(spot.centre, n)
  return centre, M.yaw(centre, spot.eye)
end

function M.cellCentre(centre, yaw, col, row)
  local cw, ch = M.SCREEN_W / M.COLS, M.SCREEN_H / M.ROWS
  -- seen by the driver, +x is on the left: the page's left edge (column 1) is at +x; 4 mm in front of the screen
  return add(centre, turn(v3(M.SCREEN_W / 2 - (col - 0.5) * cw, 0.004, M.SCREEN_H / 2 - (row - 0.5) * ch), yaw))
end

-- The size of each click box in its trigger's frame: the box is square to that frame while the cell is turned, so it
-- is made as large as the turned cell along each of the frame's axes.
function M.boxSize(spot, yaw)
  local _, fx, fy, fz = frame(spot)
  local cw, ch = M.SCREEN_W / M.COLS * 0.98, M.SCREEN_H / M.ROWS * 0.98
  local across, up, out = turn(v3(1, 0, 0), yaw), v3(0, 0, 1), turn(v3(0, 1, 0), yaw)
  local function along(a) return round(cw * math.abs(dot(across, a)) + ch * math.abs(dot(up, a)) + M.DEPTH * math.abs(dot(out, a)), 4) end
  return { x = along(fx), y = along(fy), z = along(fz) }
end

local function xyz(p) return { x = round(p.x, 4), y = round(p.y, 4), z = round(p.z, 4) } end

function M.action(col, row) return 'cargoEarthTap_' .. col .. '_' .. row end

-- The part as a jbeam file would hold it (the game's own loader turns it into a car part).
function M.buildPart(spot, nudge)
  local centre, yaw = M.placement(spot, nudge)
  local suffix = M.meshSuffix(yaw)
  local size = M.boxSize(spot, yaw)
  local triggers = { { 'id', 'idRef:', 'idX:', 'idY:', 'type', 'size', 'baseRotation', 'rotation', 'translation' } }
  local links = { { 'triggerId:triggers2', 'triggerInput', 'inputAction' } }
  for row = 1, M.ROWS do
    for col = 1, M.COLS do
      local id = 'cep_' .. col .. '_' .. row
      triggers[#triggers + 1] = { id, spot.ref.name, spot.x.name, spot.y.name, 'box', size,
        { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 },
        -- the box's middle in jbeam coordinates: the game turns it into the trigger's own frame
        -- (lua/common/jbeam/sections/events.lua)
        { baseTranslationGlobal = xyz(M.cellCentre(centre, yaw, col, row)), color = { 0.91, 0.27, 0.17, 0.6 } } }
      links[#links + 1] = { id, 'action0', M.action(col, row) }
    end
  end
  local at = { pos = xyz(centre) }
  return {
    partName = M.PART,
    slotType = M.SLOT,
    information = { authors = 'Cargo Earth', name = 'Cargo Earth phone', value = 0 },
    flexbodies = {
      { 'mesh', '[group]:', 'nonFlexMaterials' },
      { 'cargo_earth_phone_body' .. suffix, { spot.group }, {}, at },
      { 'cargo_earth_phone_screen' .. suffix, { spot.group }, {}, { pos = xyz(centre) } },
    },
    controller = {
      { 'fileName' },
      { 'cargoEarthPhone', { webViewTag = '@cargo_earth_phone', cols = M.COLS, rows = M.ROWS,
        width = 580, height = 1120, fps = 15 } },
    },
    triggers2 = triggers,
    triggerEventLinks2 = links,
  }
end

------------------------------------------------------------------------------------------ settings

-- { on = bool, spots = { [model] = spot }, nudge = { [model] = { x, y, z } } }
local cfg = { on = false, spots = {}, nudge = {} }
M.store = {
  read = function() return jsonReadFile and jsonReadFile(M.FILE) or nil end,
  write = function(t) if jsonWriteFile then jsonWriteFile(M.FILE, t, true) end end,
}

function M.load()
  local ok, t = pcall(M.store.read)
  t = ok and type(t) == 'table' and t or {}
  cfg = { on = t.on == true, spots = {}, nudge = {} }
  for model, s in pairs(type(t.spots) == 'table' and t.spots or {}) do
    if type(s) == 'table' and s.v == M.SPOT_VERSION and pos(s.eye) and pos(s.centre) and type(s.group) == 'string' then
      local ok2 = true
      for _, k in ipairs({ 'ref', 'x', 'y' }) do
        if type(s[k]) ~= 'table' or type(s[k].name) ~= 'string' or not pos(s[k].pos) then ok2 = false end
      end
      if ok2 then
        cfg.spots[model] = { v = s.v, eye = pos(s.eye), centre = pos(s.centre), group = s.group,
          ref = { name = s.ref.name, pos = pos(s.ref.pos) }, x = { name = s.x.name, pos = pos(s.x.pos) },
          y = { name = s.y.name, pos = pos(s.y.pos) } }
      end
    end
  end
  for model, n in pairs(type(t.nudge) == 'table' and t.nudge or {}) do cfg.nudge[model] = clampNudge(n) end
end

local function save() pcall(M.store.write, cfg) end

function M.isOn() return cfg.on end
cfg_on = M.isOn
function M.setOn(on) cfg.on = on and true or false save() end
function M.spot(model) return model and cfg.spots[model] or nil end
function M.setSpot(model, spot) if model then cfg.spots[model] = spot save() end end
function M.nudgeOf(model) return clampNudge(model and cfg.nudge[model]) end

-- moves the phone of this model by one step along axis ('x' = left, 'y' = back toward the driver, 'z' = up), or puts
-- it back where it was measured (axis 'reset'). Returns true when it moved.
function M.nudge(model, axis, dir)
  if not model then return false end
  if axis == 'reset' then
    local had = cfg.nudge[model] ~= nil
    cfg.nudge[model] = nil
    save()
    return had
  end
  if axis ~= 'x' and axis ~= 'y' and axis ~= 'z' then return false end
  local n = M.nudgeOf(model)
  local before = n[axis]
  n[axis] = math.max(-M.NUDGE_MAX, math.min(M.NUDGE_MAX, round(before + (tonumber(dir) or 0) * M.NUDGE_STEP, 3)))
  if n[axis] == before then return false end
  cfg.nudge[model] = n
  save()
  return true
end

-- the part for a car of this model, or nil when the switch is off or the car is not measured yet
function M.partFor(model)
  local spot = cfg.on and M.spot(model)
  return spot and M.buildPart(spot, cfg.nudge[model]) or nil
end

------------------------------------------------------------------------------------------ the parts tree

-- true when a car's parts tree (config.partsTree) chooses the phone
function M.treeHasPhone(tree)
  local c = type(tree) == 'table' and type(tree.children) == 'table' and tree.children[M.SLOT]
  return type(c) == 'table' and c.chosenPartName == M.PART
end

-- puts the phone into (on) or takes it out of a parts tree; the slot entry is the shape the game's slot system writes
function M.setTreePhone(tree, on)
  if type(tree) ~= 'table' then return false end
  tree.children = type(tree.children) == 'table' and tree.children or {}
  if on then
    tree.children[M.SLOT] = { id = M.SLOT, path = '/' .. M.SLOT .. '/', chosenPartName = M.PART,
      partPath = '/' .. M.SLOT .. '/' .. M.PART }
  else
    tree.children[M.SLOT] = nil
  end
  return true
end

------------------------------------------------------------------------------------------ the jbeam lookup

local function modelOf(ioCtx)
  local dirs = type(ioCtx) == 'table' and ioCtx.preloadedDirs
  local first = type(dirs) == 'table' and dirs[1]
  return type(first) == 'string' and first:match('/vehicles/([^/]+)/') or nil
end
M.modelOf = modelOf

local SLOT_DEF = function()
  return { name = M.SLOT, allowTypes = { M.SLOT }, denyTypes = {}, default = '', description = 'Cargo Earth phone' }
end

local wrapped -- { io = module, getPart = original, ... }

-- Wraps the game's jbeam part lookup (lua/common/jbeam/io.lua). The slot system and the parts menu call it through the
-- module (jbeamIO.getPart(...)), so they see the slot and the part; nothing else changes. Safe to call again.
function M.install(io)
  if type(io) ~= 'table' or type(io.getPart) ~= 'function' then return false end
  if wrapped and wrapped.io == io and io.getPart == wrapped.getPartWrapper then return true end
  local orig = {
    getPart = io.getPart,
    getAvailableParts = io.getAvailableParts,
    getAvailableSlotNameMap = io.getAvailableSlotNameMap,
    getCompatiblePartNamesForSlot = io.getCompatiblePartNamesForSlot,
  }
  local w = { io = io, orig = orig }
  local function active(ioCtx)
    local model = modelOf(ioCtx)
    return model and cfg.on and cfg.spots[model] and model or nil
  end
  w.getPartWrapper = function(ioCtx, partName, ...)
    if partName == M.PART then
      local model = active(ioCtx)
      local ok, part = pcall(M.partFor, model)
      if ok and part then return part, '/vehicles/common/cargo_earth_phone/' .. M.PART .. '.jbeam' end
      return nil
    end
    local part, file = orig.getPart(ioCtx, partName, ...)
    if type(part) == 'table' and part.slotType == 'main' and active(ioCtx) then
      -- a fresh copy every call, so adding to it is safe
      part.slots2 = type(part.slots2) == 'table' and part.slots2 or {}
      local has = false
      for _, s in ipairs(part.slots2) do if type(s) == 'table' and s.name == M.SLOT then has = true end end
      if not has then part.slots2[#part.slots2 + 1] = SLOT_DEF() end
    end
    return part, file
  end
  io.getPart = w.getPartWrapper
  if orig.getCompatiblePartNamesForSlot then
    io.getCompatiblePartNamesForSlot = function(ioCtx, slotDef, ...)
      if type(slotDef) == 'table' and slotDef.name == M.SLOT then
        if active(ioCtx) then return { M.PART }, {} end
        return {}, {}
      end
      return orig.getCompatiblePartNamesForSlot(ioCtx, slotDef, ...)
    end
  end
  if orig.getAvailableParts then
    io.getAvailableParts = function(ioCtx, ...)
      local res = orig.getAvailableParts(ioCtx, ...)
      if type(res) == 'table' and active(ioCtx) then
        res[M.PART] = { description = 'Cargo Earth phone', authors = 'Cargo Earth', slotInfoUi = {} }
      end
      return res
    end
  end
  if orig.getAvailableSlotNameMap then
    io.getAvailableSlotNameMap = function(ioCtx, ...)
      local res = orig.getAvailableSlotNameMap(ioCtx, ...)
      if type(res) == 'table' and active(ioCtx) then res[M.SLOT] = { M.PART } end
      return res
    end
  end
  wrapped = w
  return true
end

-- puts the game's own functions back (the mod is unloading)
function M.uninstall()
  if not wrapped then return end
  for k, f in pairs(wrapped.orig) do if f then wrapped.io[k] = f end end
  wrapped = nil
end

------------------------------------------------------------------------------------------ cars with a running phone

local partCars = {} -- cars whose phone controller has started: their phone is on the dash
function M.partCar(id) if id then partCars[id] = true end end
-- the car is being respawned (maybe without the part) or removed: its new controller registers again if the part is there
function M.dropCar(id) if id then partCars[id] = nil end end
function M.isPartCar(id) return partCars[id] == true end

-- for the phone's Settings. v: the player's car as gamecar describes it (model, id, config) or nil.
function M.state(v)
  local out = { on = cfg.on, car = v ~= nil and v.model ~= nil }
  if not out.car then return out end
  out.model = v.model
  out.placed = cfg.spots[v.model] ~= nil
  out.fitted = M.treeHasPhone(type(v.config) == 'table' and v.config.partsTree or v.tree)
  out.running = M.isPartCar(v.id)
  local n = M.nudgeOf(v.model)
  out.nudged = n.x ~= 0 or n.y ~= 0 or n.z ~= 0
  out.nudge = { x = math.floor(n.x * 100 + 0.5), y = math.floor(n.y * 100 + 0.5), z = math.floor(n.z * 100 + 0.5) }
  return out
end

-- the level is going away and its cars with it
function M.forget() partCars = {} end

-- the mod is unloading, or an old version left its floating picture in the scene: take it away
function M.remove()
  local r = scenetree and scenetree[M.OLD_RENDERER]
  if r then pcall(function() r:delete() end) end
end

return M
