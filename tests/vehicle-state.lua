-- Validate the VM boundary and orientation handling without a running BeamNG process.
local saved = {obj=obj, beamstate=beamstate, v=v, quatFromDir=quatFromDir, vec3=vec3, tableSizeC=tableSizeC,
  jsonReadFile=jsonReadFile, jsonWriteFile=jsonWriteFile, controller=controller}
local file, heading, calls, message = nil, 1, 0, ''
vec3 = function(value)
  return {x=value[1], y=value[2], z=value[3], toTable=function(self) return {self.x,self.y,self.z} end}
end
local rotation = {}
rotation.__index = rotation
rotation.__mul = function(q,p)
  return vec3(q.sign == 1 and {p.x,p.y,p.z} or {-p.x,-p.y,p.z})
end
rotation.inversed = function(self) return self end
quatFromDir = function() return setmetatable({sign=heading},rotation) end
tableSizeC = function(t) return #t end
obj = {getDirectionVector=function() end, getDirectionVectorUp=function() end, getID=function() return 12 end,
  queueGameEngineLua=function(_,command) message=command end}
v = {data={vehicleDirectory='vehicles/test/',nodes={1},beams={1}}}
jsonWriteFile = function(_,data) file=data return true end
jsonReadFile = function() return file end
beamstate = {save=function()
  file={format='v2',vehicleDirectory=v.data.vehicleDirectory,nodeCount=1,beamCount=1,
    nodes={{{2,3,4}}},beams={{1.1,true,0.7}},luaState='saved mechanical state'}
end,load=function()
  calls=calls+1
  assert(file.nodes[1][1][1]==-2 and file.nodes[1][1][2]==-3)
  assert(file.beams[1][2] and file.beams[1][3]==0.7 and file.luaState=='saved mechanical state')
end}
-- door latches: the hood was open when saved, the doors shut; loading the state makes them all come loose
local resets, impulses = {}, {}
local function latch(name, groupState)
  local c = {name=name, state=groupState}
  c.getGroupState = function() return c.state end
  c.reset = function() resets[name] = (resets[name] or 0) + 1 if name ~= 'tailgate' then c.state = 'autoCoupling' end end
  c.setState = function(data) impulses[name] = data[name .. '_groupState'] end
  return c
end
local doors, hood, tailgate = latch('doors', 'attached'), latch('hood', 'detached'), latch('tailgate', 'attached')
local broken = latch('trunk', 'broken')
controller = {getControllersByType=function(kind) assert(kind == 'advancedCouplerControl') return {doors, hood, tailgate, broken} end}
local state=dofile('mod/cargo_earth/lua/vehicle/extensions/cargoEarth/vehicleState.lua')
state.run('capture','snapshot.json',1)
assert(file.cargoEarthLocalNodes and message:find('true'))
assert(file.cargoEarthLatches.doors == 'attached' and file.cargoEarthLatches.hood == 'detached')
heading=-1
-- the fresh car has everything latching; the load then lets go of every latch
for _, c in ipairs({doors, hood, tailgate}) do c.state = 'autoCoupling' end
local load = beamstate.load
beamstate.load = function(...) load(...) for _, c in ipairs({doors, hood, tailgate, broken}) do c.state = 'detached' end end
state.run('restore','snapshot.json',2)
assert(calls==1 and message:find('true'))
assert(resets.doors == 1 and doors.state == 'autoCoupling', 'shut doors are latched again')
assert(not resets.hood and hood.state == 'detached', 'a hood saved open stays open')
assert(not resets.trunk, 'a latch broken when saved stays broken')
state.updateGFX(0.1)
assert(resets.tailgate == 1 and impulses.tailgate == 'attached', 'a latch reset cannot shut gets the close impulse')
for _ = 1, 10 do state.updateGFX(0.1) end
assert(resets.tailgate == 1, 'gives up after a few tries')
for _ = 1, 40 do state.updateGFX(0.1) end
local before = resets.doors
doors.state = 'detached'
state.updateGFX(0.1)
assert(resets.doors == before, 'nothing is latched once the window is over')
-- an older snapshot without latch states: what the fresh car latches stays latched
file.cargoEarthLatches = nil
heading = 1
resets = {}
for _, c in ipairs({doors, hood, tailgate}) do c.state = 'autoCoupling' end
broken.state = 'broken'
state.run('restore','snapshot.json',4)
assert(resets.doors == 1 and resets.hood == 1 and not resets.trunk)
for _ = 1, 40 do state.updateGFX(0.1) end
-- a latch the load let go of while its controller still says attached (player report 2026-11-24: the door could
-- never be shut again): its couplers are let go, then its controller is reset like on a fresh spawn
do
  local detached = {}
  obj.detachCoupler = function(_, cid, force) detached[#detached + 1] = cid assert(force == 0) end
  v.data.doorsRear = {couplerNodes = {{'cid1', 'cid2', 'couplingStartRadius'}, {'rl1', 'rl2', 0.05}, {'rr1', 'rr2', 0.05}}}
  beamstate.nodeNameMap = {rl1 = 41, rr1 = 42, rl2 = 51, rr2 = 52}
  local savedTFHT = tableFromHeaderTable
  tableFromHeaderTable = function(t)
    local out = {}
    for i = 2, #t do local row = {} for k, key in ipairs(t[1]) do row[key] = t[i][k] end out[#out + 1] = row end
    return out
  end
  local rear = latch('doorsRear', 'attached')
  controller = {getControllersByType=function() return {rear, broken} end}
  file.cargoEarthLatches = {doorsRear = 'attached', trunk = 'broken'}
  resets = {}
  beamstate.load = function(...) load(...) end   -- the controller keeps saying attached
  state.run('restore','snapshot.json',5)
  assert(#detached == 2 and detached[1] == 41 and detached[2] == 42, 'its couplers are let go')
  assert(not resets.doorsRear, 'the reset waits for the release')
  state.updateGFX(0.1)
  assert(not resets.doorsRear)
  state.updateGFX(0.15)
  assert(resets.doorsRear == 1 and rear.state == 'autoCoupling', 'then it latches again like on a fresh spawn')
  assert(not resets.trunk, 'a latch broken when saved is left alone')
  impulses = {}
  state.updateGFX(0.6)
  assert(impulses.doorsRear == 'attached', 'a door saved hanging open (an older broken save) is pushed shut')
  for _ = 1, 40 do state.updateGFX(0.1) end
  assert(resets.doorsRear == 1)
  rear.state = 'attached'
  tableFromHeaderTable, obj.detachCoupler, v.data.doorsRear, beamstate.nodeNameMap = savedTFHT, nil, nil, nil
end
beamstate.load = load
-- a parts change (Jan, 2026-11-26): the old build's damage goes back onto the parts that stayed, a swapped part
-- stays new. Old build: body nodes b1, b2 and the aero kit's a1; new build: b1, b2 and a box's x1 (other numbers).
do
  local nodesOld = { {cid=0, name='b1', partOrigin='body'}, {cid=1, name='a1', partOrigin='aero'}, {cid=2, name='b2', partOrigin='body'} }
  local beamsOld = { {cid=0, id1=0, id2=2, partOrigin='body'}, {cid=1, id1=0, id2=1, partOrigin='aero'} }
  local nodesNew = { {cid=0, name='x1', partOrigin='box'}, {cid=1, name='b1', partOrigin='body'}, {cid=2, name='b2', partOrigin='body'},
    {cid=3, name='x2', partOrigin='box'} }
  local beamsNew = { {cid=0, id1=0, id2=3, partOrigin='box'}, {cid=1, id1=1, id2=2, partOrigin='body'} }
  local function index(list) local t = {} for _, x in ipairs(list) do t[x.cid] = x end return t end
  local setPos, setLen, broke, deformed, committed, fullLoads = {}, {}, {}, {}, 0, 0
  obj.setNodePosition = function(_, cid, p) setPos[cid] = p end
  obj.setNodeMass = function() end
  obj.setBeamLength = function(_, cid, l) setLen[cid] = l end
  obj.breakBeam = function(_, cid) broke[cid] = true end
  obj.commitLoad = function() committed = committed + 1 end
  v.data.nodes, v.data.beams = index(nodesOld), index(beamsOld)
  tableSizeC = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  heading = 1
  beamstate.save = function()
    file = {format='v2', vehicleDirectory=v.data.vehicleDirectory, nodeCount=3, beamCount=2,
      nodes={{{1,1,1}}, {{9,9,9}}, {{2,2,2}}}, beams={{1.5,true,0.4}, {0.9,false,0.8}}, luaState='old'}
  end
  beamstate.load = function() fullLoads = fullLoads + 1 end
  beamstate.onBeamDeformed = function(cid, r) deformed[cid] = r end
  controller = {getControllersByType=function() return {} end}
  state.run('capture','snapshot.json',6)
  assert(file.cargoEarthKeys and file.cargoEarthKeys.nodes[2] == 'a1|aero' and file.cargoEarthKeys.beams[1] == 'b1|b2|body')
  v.data.nodes, v.data.beams = index(nodesNew), index(beamsNew)
  state.run('restore','snapshot.json',7)
  assert(message:find('true') and fullLoads == 0 and committed == 1, 'another build is loaded part by part')
  assert(setPos[1] and setPos[1].x == 1 and setPos[2] and setPos[2].x == 2, 'the body keeps its dents')
  assert(not setPos[0] and not setPos[3], 'the new box stays new')
  assert(setLen[1] == 1.5 and broke[1] and deformed[1] == 0.4, 'the body beam keeps its damage')
  assert(not setLen[0] and not broke[0], 'the new part beam is untouched')
  -- the same build again is a full load
  v.data.nodes, v.data.beams = index(nodesOld), index(beamsOld)
  state.run('capture','snapshot.json',8)
  state.run('restore','snapshot.json',9)
  assert(fullLoads == 1)
  obj.setNodePosition, obj.setNodeMass, obj.setBeamLength, obj.breakBeam, obj.commitLoad = nil, nil, nil, nil, nil
  v.data.nodes, v.data.beams = {1}, {1}
  tableSizeC = function(t) return #t end
  file.cargoEarthKeys = nil
  beamstate.save, beamstate.load, beamstate.onBeamDeformed = saved.beamstateSave or beamstate.save, load, nil
end
file.nodeCount=2
state.run('restore','snapshot.json',3)
assert(calls==3 and message:find('false'), 'a different vehicle structure must reject the snapshot')
obj,beamstate,v,quatFromDir,vec3,tableSizeC,jsonReadFile,jsonWriteFile =
  saved.obj,saved.beamstate,saved.v,saved.quatFromDir,saved.vec3,saved.tableSizeC,saved.jsonReadFile,saved.jsonWriteFile
controller = saved.controller
print('Vehicle snapshots: node orientation, broken beams, mechanical state, door latches and incompatible structure checked')
