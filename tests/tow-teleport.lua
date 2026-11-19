-- Engine adapters for the real trailer loading, teleport hook and frame updates.
local trailers = require('cargoEarth/trailers')
local Vector = {}
Vector.__index = Vector
function vec3(x, y, z)
  if type(x) == 'table' then return vec3(x.x, x.y, x.z) end
  return setmetatable({ x = x, y = y, z = z }, Vector)
end
function Vector.__add(a,b) return vec3(a.x+b.x,a.y+b.y,a.z+b.z) end
function Vector.__sub(a,b) return vec3(a.x-b.x,a.y-b.y,a.z-b.z) end
function Vector.__mul(a,b) return vec3(a.x*b,a.y*b,a.z*b) end
function Vector:dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
function Vector:cross(b) return vec3(self.y*b.z-self.z*b.y,self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x) end
function Vector:length() return math.sqrt(self:dot(self)) end
function Vector:normalized() return self*(1/self:length()) end

local rotation = { x=0, y=0, z=0, w=1 }
rotation.inversed = function() return rotation end
setmetatable(rotation, { __mul=function() return rotation end })
quatFromDir = function() return rotation end
castRayStatic = function() return nil end
local function vehicle(id)
  return {
    p=vec3(0,0,0), dir=vec3(0,1,0), getID=function() return id end,
    getPosition=function(self) return self.p end,
    getDirectionVector=function(self) return vec3(self.dir) end,
    getDirectionVectorUp=function() return vec3(0,0,1) end,
    setPosition=function(self,p) self.p=p end, queueLuaCommand=function() end,
    getRefNodeId=function() return 0 end, applyClusterVelocityScaleAdd=function() end,
    setClusterPosRelRot=function(self,ref,x,y,z)
      assert(not self.unavailable, 'physics object busy')
      self.p=vec3(x,y,z)
    end,
    delete=function() end
  }
end
local trailer,car=vehicle(1),vehicle(2)
local objects={trailer,car}
scenetree={findObjectById=function(id) return objects[id] end}
getPlayerVehicle=function() return nil end
core_vehicles={spawnNewVehicle=function() return car end}
trailers.ownTowTrailer=function() return 1,'tiltdeck' end
local loading=false
require('cargoEarth/earth').towWorldMoving=function() return loading end
assert(trailers.adopt('cartrailer'))
assert(trailers.loadTowed({'covet'}))
local offset=car.p-trailer.p
local function tick() trailers.update(0.016,0.016) end
local function onDeck() return (car.p-trailer.p-offset):length()<0.001 end
-- Teleport immediately after loading, before any regular frame. Retry a busy physics object.
trailer.p=vec3(30,0,0)
trailers.onTeleported()
car.unavailable=true
tick()
assert(trailers.restoringTow())
car.unavailable=false
tick()
assert(onDeck() and not trailers.restoringTow())

-- The first ready frame can precede the completion callback.
loading=true
trailer.p=vec3(36,0,0)
tick()
loading=false
tick()
trailers.onTeleported()
tick()
assert(onDeck())

-- A rebase moves the whole rig. A game teleport can also occur without an Earth callback.
local shift=vec3(500,0,0)
car.p=car.p+shift
trailer.p=trailer.p+shift
trailers.onRebased()
tick()
assert(onDeck())
trailer.p=trailer.p+shift
tick()
assert(onDeck())

-- A car that has already fallen off stays behind when its trailer teleports.
car.p=car.p+vec3(15,0,0)
tick()
local dropped=car.p
trailers.onTeleported()
trailer.p=trailer.p+shift
tick()
assert(car.p==dropped and not trailers.restoringTow())
print('Tow teleport: immediate load, short hop, late hook, retry, rebase, long jump and dropped cargo passed')

-- The same adopted rig can recover a dropped car without disturbing its other load.
trailer.p=vec3(0,0,0)
assert(trailers.adopt('cartrailer'))
local second=vehicle(3)
objects[3]=second
local spawned=0
core_vehicles.spawnNewVehicle=function()
  spawned=spawned+1
  return spawned==1 and car or second
end
local models={'covet','pessima'}
assert(trailers.loadTowed(models))
local untouched=car.p
second.p=vec3(20,0,0)
local player=vehicle(4)
getPlayerVehicle=function() return player end
local attached=false
trailers.coupled=function(vid) return attached and vid==4 end
local ok,why=trailers.recoverTowed(models)
assert(not ok and why:find('Hitch') and second.p.x==20)
attached=true
second.unavailable=true
assert(not trailers.recoverTowed(models))
assert(second.p.x==20 and car.p==untouched)
second.unavailable=false
assert(trailers.recoverTowed(models))
assert(trailers.id()==1 and trailers.adopted() and spawned==2)
assert(car.p==untouched and second.p:length()<6 and trailers.towedCount()==2)
print('Tow recovery: original trailer, dropped car only, hitch requirement and retry passed')
