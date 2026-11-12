-- Read BeamNG's vehicle accelerometer locally. Only a qualifying jolt crosses into game Lua.
local M = {}

local STANDARD_GRAVITY = 9.80665  -- metres per second squared in one g
-- Allow some extra force and time for the way people drive in the game.
local SHOCK_G, SHOCK_S = 3.5, 0.18
local IMPACT_G, IMPACT_S = 5.0, 0.07
local WARMUP_S = 0.5   -- ignore the first samples after arming or resetting the car
-- A harsh moment for a fragile load: hard braking, accelerating or cornering (horizontal g) held this long.
-- Reported at most every HARSH_GAP_S, while the watch lasts (also after a shock).
local HARSH_G, HARSH_S, HARSH_GAP_S = 0.55, 0.4, 3

local token, warmup, shockTime, impactTime, peak
local harshToken, harshTime, harshWait = nil, 0, 0

local function reset()
  warmup, shockTime, impactTime, peak = WARMUP_S, 0, 0, 0
  harshTime = 0
end

function M.watch(newToken)
  token = newToken
  harshToken, harshWait = newToken, 0
  reset()
end

function M.updateGFX(dt)
  if not (token or harshToken) or dt <= 0 then return end
  if warmup > 0 then
    warmup = warmup - dt
    return
  end
  local x, y, z = sensors.gx, sensors.gy, sensors.gz
  local g = math.sqrt(x * x + y * y + z * z) / STANDARD_GRAVITY
  if g ~= g or g == math.huge then return end
  -- A stalled frame must not count as a sustained impact.
  local sampleTime = math.min(dt, 1 / 30)
  if harshToken then
    local flat = math.sqrt(x * x + y * y) / STANDARD_GRAVITY
    harshWait = math.max(0, harshWait - dt)
    harshTime = (flat >= HARSH_G and flat < SHOCK_G) and harshTime + sampleTime or 0
    if harshTime >= HARSH_S and harshWait <= 0 then
      harshTime, harshWait = 0, HARSH_GAP_S
      obj:queueGameEngineLua(string.format('extensions.hook("onCargoEarthHarsh", %d, %d, %.3f)', obj:getID(), harshToken, flat))
    end
  end
  if not token then return end
  shockTime = g >= SHOCK_G and shockTime + sampleTime or 0
  impactTime = g >= IMPACT_G and impactTime + sampleTime or 0
  peak = shockTime > 0 and math.max(peak, g) or 0
  if shockTime >= SHOCK_S or impactTime >= IMPACT_S then
    obj:queueGameEngineLua(string.format('extensions.hook("onCargoEarthShock", %d, %d, %.3f)', obj:getID(), token, peak))
    token = nil
  end
end

M.onReset = reset

return M
