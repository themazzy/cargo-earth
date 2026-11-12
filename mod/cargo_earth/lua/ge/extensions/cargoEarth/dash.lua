-- cargoEarth/dash: the phone on the dashboard, for cockpit and VR play.
-- It is a car part, "Cargo Earth phone holder" (vehicles/<model>/cargo_earth_phone.jbeam): a phone mesh fixed to the
-- dash, turned to face the driver's head, showing the full phone app (vehicles/common/cargo_earth_phone/phone.html)
-- and pressed through the car's own cockpit triggers (point a VR controller and pull its trigger, or click it).
-- Fitting it: Settings > Phone on the dashboard, or BeamNG's Vehicle Config (the car's Additional Modification slot).
-- (Before 0.9 this was a floating picture in front of the driver. A floating picture always turns toward the camera
-- and rides on the seat, so it could not stay still, and its buttons could not be pressed; it is gone.)
local M = {}

M.MODELS = { pigeon = true } -- cars with a holder; tools/make-dash-phone.py makes more
M.OLD_RENDERER = 'cargoEarthDashPhone' -- the old floating picture's scene object

function M.partName(model) return model and M.MODELS[model] and ('cargo_earth_phone_' .. model) or nil end

local partCars = {} -- cars whose holder controller has started: their phone is on the dash
function M.partCar(id) if id then partCars[id] = true end end
-- the car is being respawned (maybe without the part) or removed: its new controller registers again if the part is there
function M.dropCar(id) if id then partCars[id] = nil end end
function M.isPartCar(id) return partCars[id] == true end

-- for the phone's Settings. v: the player's car as gamecar describes it (model, id, slotPartMap) or nil.
function M.state(v)
  if not v or not v.model then return { car = false } end
  local part = M.partName(v.model)
  local fitted = false
  for _, name in pairs(part and type(v.slotPartMap) == 'table' and v.slotPartMap or {}) do
    if name == part then fitted = true end
  end
  return { car = true, model = v.model, supported = part ~= nil, fitted = fitted, running = M.isPartCar(v.id) }
end

-- the level is going away and its cars with it
function M.forget() partCars = {} end

-- the mod is unloading, or an old version left its floating picture in the scene: take it away
function M.remove()
  local r = scenetree and scenetree[M.OLD_RENDERER]
  if r then pcall(function() r:delete() end) end
end

return M
