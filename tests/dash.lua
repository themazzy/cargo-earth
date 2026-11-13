local dash = require('cargoEarth/dash')
local total = 0
local function test(name, fn)
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  total = total + 1
  print('PASS ' .. name)
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- a store that keeps the settings in memory
local saved
dash.store = { read = function() return saved end, write = function(t) saved = t end }
local function reset(t) saved = t dash.load() end

-- A small car like the Pigeon (right-hand drive: the driver sits at -x): a dashboard of nodes across the car, a
-- windscreen above it, the steering column in front of the driver, and the driver camera.
local EYE = { x = -0.316, y = 0.1, z = 1.25 }
local function car(eye)
  local nodes = {}
  local function n(name, x, y, z, group) nodes[#nodes + 1] = { name = name, pos = { x = x, y = y, z = z }, groups = { group } } end
  for i = -3, 3 do
    n('dsh2_' .. i, i * 0.2, -0.457, 0.87, 'pigeon_dash')
    n('dsh1_' .. i, i * 0.2, -0.457, 0.99, 'pigeon_dash')
    n('ws_' .. i, i * 0.2, -0.75, 1.32, 'pigeon_body')
  end
  n('steer1', eye.x, -0.25, 1.0, 'pigeon_steer')
  n('steer2', eye.x, -0.3, 0.9, 'pigeon_steer')
  n('floor', 0, -0.4, 0.3, 'pigeon_body')
  return nodes
end

test('a car\'s phone is forgotten when it is respawned', function()
  dash.partCar(7)
  assert(dash.isPartCar(7) and not dash.isPartCar(8))
  dash.dropCar(7)
  assert(not dash.isPartCar(7), 'a respawn without the part forgets it')
  dash.partCar(3)
  dash.forget()
  assert(not dash.isPartCar(3))
end)

test('the driver\'s head comes from the car\'s driver camera', function()
  local vdata = { nodes = { [0] = { name = 'a', pos = { x = 0, y = 0, z = 0 } }, [5] = { pos = { x = -0.3, y = 0.1, z = 1.2 } } },
    cameras = { onboard = { { name = 'driver', camNodeID = 5, x = 9, y = 9, z = 9 } } } }
  local eye, node = dash.eyeOf(vdata)
  assert(eye and near(eye.x, -0.3) and near(eye.z, 1.2) and node == 5, 'the camera\'s own node, where the game put it')
  vdata.cameras = { occupant = { FL = { x = 0.3, y = 0.1, z = 1.2, defaultPermissionMode = 'passenger' },
    FR = { x = -0.31, y = 0.12, z = 1.21, defaultPermissionMode = 'driver' } },
    onboard = { { name = 'hood', x = 0, y = -0.55, z = 1.18 } } }
  eye = dash.eyeOf(vdata)
  assert(near(eye.x, -0.31), 'the driver\'s seat, not a passenger\'s')
  vdata.cameras = { onboard = { { name = 'hood', x = 0, y = -0.55, z = 1.18 } } }
  assert(dash.eyeOf(vdata) == nil, 'never the hood camera')
  assert(dash.eyeOf({ nodes = {} }) == nil and dash.eyeOf(nil) == nil)
  local list = dash.nodesOf({ nodes = { [0] = { name = 'a', pos = { x = 1, y = 2, z = 3 }, group = { [0] = 'g' } },
    [1] = { name = 'cam', pos = { x = 0, y = 0, z = 0 } }, [2] = { pos = { x = 0, y = 0, z = 0 } } } }, 1)
  assert(#list == 1 and list[1].name == 'a' and list[1].groups[1] == 'g', 'named nodes only, not the camera\'s')
end)

test('the phone stands on the dash, toward the middle, below the eyes, facing the driver', function()
  local spot = assert(dash.findSpot(car(EYE), EYE))
  assert(spot.group == 'pigeon_dash', 'it hangs on the dash, not the steering column or the windscreen: ' .. spot.group)
  assert(near(spot.centre.y, -0.43, 1e-6) and near(spot.centre.z, 1.07, 1e-6), 'on top of the dash, at its back edge')
  assert(spot.centre.x > EYE.x and spot.centre.x < 0, 'between the driver and the middle of the car')
  assert(spot.ref.name ~= spot.x.name and spot.ref.name ~= spot.y.name and spot.x.name ~= spot.y.name)
  local _, yaw = dash.placement(spot)
  assert(yaw > 0 and yaw % dash.YAW_STEP == 0, 'turned toward a driver on the right, in mesh steps: ' .. yaw)
  -- left-hand drive: the same car mirrored
  local lhd = { x = 0.316, y = 0.1, z = 1.25 }
  local spot2 = assert(dash.findSpot(car(lhd), lhd))
  local _, yaw2 = dash.placement(spot2)
  assert(yaw2 == -yaw and spot2.centre.x > 0, 'mirrored for a driver on the left')
  -- a tall truck: the phone never sits above the driver's line of sight
  local truck = { x = -0.5, y = 0.3, z = 1.12 }
  local spot3 = assert(dash.findSpot(car(truck), truck))
  assert(spot3.centre.z <= truck.z - 0.12 + 1e-9)
  local none, why = dash.findSpot({}, EYE)
  assert(none == nil and why, 'no dash, no phone')
  assert(dash.findSpot(car(EYE), nil) == nil, 'no driver camera, no phone')
end)

test('the part covers the screen with a 6 x 12 click grid and moves with the nudges', function()
  local spot = assert(dash.findSpot(car(EYE), EYE))
  local part = dash.buildPart(spot)
  assert(part.slotType == dash.SLOT and part.partName == dash.PART and part.information.value == 0)
  local n = 1 + dash.COLS * dash.ROWS + #dash.BUTTONS
  assert(#part.triggers2 == n and #part.triggerEventLinks2 == n)
  local centre, yaw = dash.placement(spot)
  assert(part.flexbodies[2][1] == 'cargo_earth_phone_body' .. dash.meshSuffix(yaw))
  assert(part.flexbodies[3][1] == 'cargo_earth_phone_screen' .. dash.meshSuffix(yaw))
  assert(part.flexbodies[2][2][1] == spot.group and near(part.flexbodies[2][4].pos.z, centre.z, 1e-4))
  local first, last = part.triggers2[2], part.triggers2[1 + dash.COLS * dash.ROWS]
  -- the game reads every part's rows in the first part's header order, so the header is the stock cars' one, in order
  local stock = { 'id', 'idRef:', 'idX:', 'idY:', 'type', 'size', 'baseRotation', 'rotation', 'translation', 'baseTranslation' }
  for i, h in ipairs(stock) do assert(part.triggers2[1][i] == h, 'header column ' .. i) end
  assert(#part.triggers2[1] == #stock and #first == #stock + 1 and first[5] == 'box' and type(first[#first].baseTranslationGlobal) == 'table')
  assert(first[1] == 'cep_1_1' and first[2] == spot.ref.name and first[3] == spot.x.name and first[4] == spot.y.name)
  local a, b = first[11].baseTranslationGlobal, last[11].baseTranslationGlobal
  assert(a.z > b.z and near(a.z - b.z, dash.SCREEN_H * (dash.ROWS - 1) / dash.ROWS, 1e-3), 'top row above the bottom row')
  assert(near((a.x + b.x) / 2, centre.x, 3e-3) and near((a.z + b.z) / 2, centre.z, 1e-3), 'the grid is centred on the screen')
  local size = first[6]
  assert(size.x > 0 and size.y > 0 and size.z > 0)
  assert(part.triggerEventLinks2[2][3] == 'cargoEarthTap_1_1')
  -- the labelled buttons stand beside the screen, left and right of it, and run their own actions
  local accept, up
  for i = n - #dash.BUTTONS + 1, n do
    local row = part.triggers2[i]
    if row[1] == 'ceb_accept' then accept = row end
    if row[1] == 'ceb_up' then up = row end
    assert(type(row[11].label) == 'string' and row[11].label ~= '')
  end
  assert(accept and up and part.triggerEventLinks2[n][3] == dash.buttonAction(dash.BUTTONS[#dash.BUTTONS].id))
  local pa, pu = accept[11].baseTranslationGlobal, up[11].baseTranslationGlobal
  local function side(p) return dash.vec.dot(dash.vec.sub(p, centre), { x = math.cos(math.rad(yaw)), y = math.sin(math.rad(yaw)), z = 0 }) end
  assert(side(pa) > dash.SCREEN_W / 2 and side(pu) < -dash.SCREEN_W / 2, 'left and right of the screen')
  -- nudged 3 cm up: everything moves with it
  local up = dash.buildPart(spot, { x = 0, y = 0, z = 0.03 })
  assert(near(up.flexbodies[2][4].pos.z, part.flexbodies[2][4].pos.z + 0.03, 1e-4))
  assert(near(up.triggers2[2][11].baseTranslationGlobal.z, a.z + 0.03, 1e-4))
  assert(dash.meshSuffix(30) == '_yp30' and dash.meshSuffix(-5) == '_ym5' and dash.meshSuffix(0) == '_yp0')
end)

test('the click boxes lie flat on the turned phone, as the game turns a box trigger', function()
  local spot = assert(dash.findSpot(car(EYE), EYE))
  local v = dash.vec
  for _, yaw in ipairs({ 0, 15, -35, 70 }) do
    local rot, err = dash.boxTurn(spot, yaw)
    assert(err < 1e-6, 'exact at yaw ' .. yaw .. ': ' .. err)
    local bx, by, bz = dash.boxAxes(spot, { x = math.rad(rot.x), y = math.rad(rot.y), z = math.rad(rot.z) })
    local across = dash.turn({ x = 1, y = 0, z = 0 }, yaw)
    local out = dash.turn({ x = 0, y = 1, z = 0 }, yaw)
    assert(near(v.dot(bx, across), 1, 1e-5) and near(bz.z, 1, 1e-5) and near(math.abs(v.dot(by, out)), 1, 1e-5))
  end
  -- a slanted frame (nodes not square to the car) still gives flat boxes
  local skew = { ref = { name = 'a', pos = { x = 0, y = -0.5, z = 0.9 } }, x = { name = 'b', pos = { x = 0.5, y = -0.42, z = 0.95 } },
    y = { name = 'c', pos = { x = 0.1, y = -0.7, z = 1.1 } } }
  local _, err = dash.boxTurn(skew, 25)
  assert(err < 1e-6, 'slanted frame: ' .. err)
  -- without a turn the game lays the box with its y through the frame (the reason a turn is needed at all)
  local _, by = dash.boxAxes(spot, { x = 0, y = 0, z = 0 })
  assert(by and math.abs(by.z) < 1.000001)
  local part = dash.buildPart(spot)
  local row = part.triggers2[2]
  assert(row[7].x == dash.boxTurn(spot, select(2, dash.placement(spot))).x, 'the grid rows carry the turn')
  assert(near(row[6].x, dash.SCREEN_W / dash.COLS * 0.98) and near(row[6].y, dash.DEPTH), 'boxes the size of a cell')
end)

test('Settings: the switch, the measured spots and the nudges are kept, per car model', function()
  reset(nil)
  assert(not dash.isOn() and dash.partFor('pigeon') == nil)
  local spot = assert(dash.findSpot(car(EYE), EYE))
  dash.setOn(true)
  assert(dash.partFor('pigeon') == nil, 'not measured yet')
  dash.setSpot('pigeon', spot)
  assert(dash.partFor('pigeon') and dash.partFor('covet') == nil)
  assert(dash.nudge('pigeon', 'z', 1) and dash.nudge('pigeon', 'z', 1) and dash.nudge('pigeon', 'y', -1))
  assert(near(dash.nudgeOf('pigeon').z, 0.02) and near(dash.nudgeOf('pigeon').y, -0.01) and dash.nudgeOf('covet').z == 0)
  assert(not dash.nudge('pigeon', 'w', 1), 'only x, y and z')
  for _ = 1, 40 do dash.nudge('pigeon', 'x', 1) end
  assert(near(dash.nudgeOf('pigeon').x, dash.NUDGE_MAX) and not dash.nudge('pigeon', 'x', 1), 'it stops at the limit')
  -- read back from the file
  dash.load()
  assert(dash.isOn() and dash.spot('pigeon') and near(dash.spot('pigeon').centre.z, spot.centre.z))
  assert(near(dash.nudgeOf('pigeon').z, 0.02))
  local st = dash.state({ id = 4, model = 'pigeon', config = { partsTree = { children = {} } } })
  assert(st.on and st.car and st.placed and not st.fitted and st.nudged and st.nudge.z == 2)
  assert(dash.nudge('pigeon', 'reset') and not dash.state({ id = 4, model = 'pigeon' }).nudged)
  -- a spot measured by an older way of measuring is measured again
  saved.spots.pigeon.v = dash.SPOT_VERSION - 1
  dash.load()
  assert(dash.spot('pigeon') == nil)
  assert(dash.state(nil).car == false)
end)

test('the parts tree chooses the phone, or not', function()
  local tree = { chosenPartName = 'pigeon', children = { pigeon_mod = { chosenPartName = '' } } }
  assert(not dash.treeHasPhone(tree))
  assert(dash.setTreePhone(tree, true) and dash.treeHasPhone(tree) and tree.children.pigeon_mod)
  assert(tree.children[dash.SLOT].partPath == '/' .. dash.SLOT .. '/' .. dash.PART)
  dash.setTreePhone(tree, false)
  assert(not dash.treeHasPhone(tree) and tree.children[dash.SLOT] == nil)
  assert(not dash.setTreePhone(nil, true))
end)

test('the game\'s part lookup gets the slot and the part, only while the switch is on and the car is measured', function()
  reset(nil)
  local main = { partName = 'pigeon', slotType = 'main', slots2 = { { name = 'pigeon_mod', allowTypes = { 'pigeon_mod' } } } }
  local function copy(t) local o = {} for k, v in pairs(t) do o[k] = type(v) == 'table' and copy(v) or v end return o end
  local io = {
    getPart = function(_, name) if name == 'pigeon' then return copy(main), 'pigeon.jbeam' end end,
    getAvailableParts = function() return { pigeon = { description = 'Pigeon' } } end,
    getAvailableSlotNameMap = function() return { main = { 'pigeon' } } end,
    getCompatiblePartNamesForSlot = function() return { 'other' }, {} end,
  }
  local orig = io.getPart
  local ctx = { preloadedDirs = { '/vehicles/pigeon/', '/vehicles/common/' } }
  assert(dash.modelOf(ctx) == 'pigeon')
  assert(dash.install(io) and dash.install(io), 'installs once')
  local function slots() return #io.getPart(ctx, 'pigeon').slots2 end
  assert(slots() == 1 and io.getPart(ctx, dash.PART) == nil, 'off: the car is untouched')
  dash.setOn(true)
  assert(slots() == 1, 'on, but this model is not measured yet')
  dash.setSpot('pigeon', assert(dash.findSpot(car(EYE), EYE)))
  local p = io.getPart(ctx, 'pigeon')
  assert(#p.slots2 == 2 and p.slots2[2].name == dash.SLOT and p.slots2[2].default == '', 'an empty slot: traffic stays without')
  assert(#main.slots2 == 1, 'the game\'s cached part is not changed')
  local part = io.getPart(ctx, dash.PART)
  assert(part and part.slotType == dash.SLOT)
  local names = io.getCompatiblePartNamesForSlot(ctx, p.slots2[2])
  assert(#names == 1 and names[1] == dash.PART)
  assert(io.getCompatiblePartNamesForSlot(ctx, p.slots2[1])[1] == 'other')
  assert(io.getAvailableParts(ctx)[dash.PART] and io.getAvailableSlotNameMap(ctx)[dash.SLOT][1] == dash.PART)
  assert(io.getPart({ preloadedDirs = { '/vehicles/covet/' } }, dash.PART) == nil, 'another model has its own spot')
  dash.uninstall()
  assert(io.getPart == orig, 'the game\'s own functions are put back')
  dash.setOn(false)
end)

test('a loaded car keeps only first groups; the car as it loaded keeps them all', function()
  -- after loading, the game deletes node.group and leaves node.firstGroup (a number from vdata.groups)
  local vdata = { groups = { ferax_dash = 3, ferax_body = 0 },
    nodes = { [0] = { name = 'dsh', cid = 0, pos = { x = 0, y = -0.55, z = 0.72 }, firstGroup = 3 },
      [1] = { name = 'cam', cid = 1, pos = { x = 0.3, y = 0.2, z = 1.1 } } } }
  local list = dash.nodesOf(vdata, 1)
  assert(#list == 1 and list[1].groups[1] == 'ferax_dash', 'first group read back by number')
  reset({ on = false })
  dash.captureLoading(7, { model = 'ferax', nodes = { dsh = { name = 'dsh', pos = { x = 0, y = 0, z = 0 }, group = { [0] = 'b', [3] = 'a' } } } })
  assert(dash.loadedNodes(7) == nil, 'nothing kept while the switch is off')
  reset({ on = true })
  dash.captureLoading(7, { model = 'ferax', nodes = { dsh = { name = 'dsh', pos = { x = 0, y = 0, z = 0 }, group = { [0] = 'b', [3] = 'a' } },
    cam = { name = 'cam', pos = { x = 1, y = 0, z = 0 } } } })
  local l = dash.loadedNodes(7, 'ferax', 'cam')
  assert(#l == 1 and l[1].groups[1] == 'a' and l[1].groups[2] == 'b', 'all groups kept, camera node left out')
  assert(dash.loadedNodes(7, 'pigeon') == nil, 'another model is not mixed up')
  reset({ on = false })
  dash.captureLoading(7, { model = 'ferax', nodes = {} })
  reset({ on = true })
  assert(dash.loadedNodes(7) == nil, 'a reload while the switch is off forgets the old nodes')
  for i = 1, dash.KEEP_LOADED do dash.captureLoading(100 + i, { model = 'x', nodes = { a = { name = 'a', pos = { x = 0, y = 0, z = 0 } } } }) end
  assert(dash.loadedNodes(7) == nil, 'only the last few cars are kept')
  dash.forgetLoaded()
end)

print('Dash phone: ' .. total .. ' checks passed')
