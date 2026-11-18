-- Exercise the actual vehicle-side sampling for bus and cargo thresholds.
local previousObj, previousSensors = obj, sensors
local events = {}
obj = {getID=function() return 1 end,queueGameEngineLua=function(_,text) events[#events+1]=text end}
sensors = {gx=0,gy=0,gz=9.80665}
local forces=dofile('mod/cargo_earth/lua/vehicle/extensions/cargoEarth/gforce.lua')
local function sample(g, seconds)
  sensors.gx=g*9.80665
  for _=1,math.ceil(seconds*60) do forces.updateGFX(1/60) end
end
forces.watch(1,true)
sample(0,1)
sample(0.7,1)
assert(#events==0, 'ordinary bus braking below 0.8 g must not trigger a harsh event')
sample(0.9,1)
assert(#events==1 and events[1]:find('onCargoEarthHarsh'))
sample(0.9,1)
assert(#events==1, 'sustained braking respects the bus cooldown')
forces.watch(2,false)
events={}
sample(0,1)
sample(0.7,1)
assert(#events==1, 'the normal cargo reporter still uses its own threshold')
obj,sensors=previousObj,previousSensors
print('Bus force sensor: 0.8 g braking threshold, cooldown and cargo threshold checked')
