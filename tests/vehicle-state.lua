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
  for _ = 1, 40 do state.updateGFX(0.1) end
  assert(resets.doorsRear == 1)
  tableFromHeaderTable, obj.detachCoupler, v.data.doorsRear, beamstate.nodeNameMap = savedTFHT, nil, nil, nil
end
beamstate.load = load
file.nodeCount=2
state.run('restore','snapshot.json',3)
assert(calls==3 and message:find('false'), 'a different vehicle structure must reject the snapshot')
obj,beamstate,v,quatFromDir,vec3,tableSizeC,jsonReadFile,jsonWriteFile =
  saved.obj,saved.beamstate,saved.v,saved.quatFromDir,saved.vec3,saved.tableSizeC,saved.jsonReadFile,saved.jsonWriteFile
controller = saved.controller
print('Vehicle snapshots: node orientation, broken beams, mechanical state, door latches and incompatible structure checked')
