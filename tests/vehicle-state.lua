-- Validate the VM boundary and orientation handling without a running BeamNG process.
local saved = {obj=obj, beamstate=beamstate, v=v, quatFromDir=quatFromDir, vec3=vec3, tableSizeC=tableSizeC,
  jsonReadFile=jsonReadFile, jsonWriteFile=jsonWriteFile}
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
local state=dofile('mod/cargo_earth/lua/vehicle/extensions/cargoEarth/vehicleState.lua')
state.run('capture','snapshot.json',1)
assert(file.cargoEarthLocalNodes and message:find('true'))
heading=-1
state.run('restore','snapshot.json',2)
assert(calls==1 and message:find('true'))
file.nodeCount=2
state.run('restore','snapshot.json',3)
assert(calls==1 and message:find('false'), 'a different vehicle structure must reject the snapshot')
obj,beamstate,v,quatFromDir,vec3,tableSizeC,jsonReadFile,jsonWriteFile =
  saved.obj,saved.beamstate,saved.v,saved.quatFromDir,saved.vec3,saved.tableSizeC,saved.jsonReadFile,saved.jsonWriteFile
print('Vehicle snapshots: node orientation, broken beams, mechanical state and incompatible structure checked')
