-- Reports this vehicle's fuel tanks and batteries to game Lua every REPORT_S seconds, and sets their level when
-- the career asks (a refill, or putting back the remembered level after a reset). Loaded only for career cars.
local M = {}

local REPORT_S = 2
local token, timer = nil, 0

local function storages()
  local es = rawget(_G, 'energyStorage')
  if not es or not es.getStorages then return {} end
  local ok, list = pcall(es.getStorages)
  return ok and type(list) == 'table' and list or {}
end

local function tracked(s)
  return type(s) == 'table' and (s.type == 'fuelTank' or s.type == 'electricBattery')
end

-- ratio 0..1, capacity in litres (kWh for a battery)
local function read(s)
  local ratio = tonumber(s.remainingRatio)
  if not ratio and tonumber(s.storedEnergy) and tonumber(s.energyCapacity) and s.energyCapacity > 0 then
    ratio = s.storedEnergy / s.energyCapacity
  end
  local cap
  if s.type == 'electricBattery' then
    cap = tonumber(s.energyCapacity) and s.energyCapacity / 3600000 or tonumber(s.capacity)
  else
    cap = tonumber(s.capacity)
    if not ratio and cap and cap > 0 and tonumber(s.remainingVolume) then ratio = s.remainingVolume / cap end
  end
  return ratio, cap
end

local function kindOf(s)
  local t = tostring(s.energyType or ''):lower()
  if s.type == 'electricBattery' or t:find('electric', 1, true) then return 'electric' end
  if t:find('diesel', 1, true) then return 'diesel' end
  return 'gasoline'
end

local function report()
  local parts = {}
  for name, s in pairs(storages()) do
    if tracked(s) then
      local ratio, cap = read(s)
      if ratio and cap and ratio == ratio and cap == cap and cap > 0 then
        parts[#parts + 1] = string.format('[%q]={ratio=%.5f,cap=%.3f,kind=%q}', tostring(name), ratio, cap, kindOf(s))
      end
    end
  end
  obj:queueGameEngineLua(string.format('extensions.hook("onCargoEarthFuel", %d, %d, {%s})',
    obj:getID(), token, table.concat(parts, ',')))
end

function M.watch(newToken)
  token, timer = newToken, 0
end

-- levels: { [storage name] = ratio 0..1 }
function M.set(levels)
  local list = storages()
  for name, ratio in pairs(type(levels) == 'table' and levels or {}) do
    local s = list[name]
    ratio = tonumber(ratio)
    if tracked(s) and ratio and ratio == ratio then
      ratio = math.max(0, math.min(1, ratio))
      if type(s.setRemainingRatio) == 'function' then
        pcall(s.setRemainingRatio, s, ratio)
      elseif type(s.setRemainingVolume) == 'function' and tonumber(s.capacity) then
        pcall(s.setRemainingVolume, s, s.capacity * ratio)
      end
      -- A game version without those setters (or with other arguments): write the fields they keep.
      local now = read(s)
      if not now or math.abs(now - ratio) > 0.01 then
        if tonumber(s.energyCapacity) then s.storedEnergy = s.energyCapacity * ratio end
        if s.type == 'fuelTank' and tonumber(s.capacity) then s.remainingVolume = s.capacity * ratio end
        s.remainingRatio = ratio
      end
    end
  end
  if token then timer = REPORT_S end   -- report the new level at once
end

function M.updateGFX(dt)
  if not token then return end
  timer = timer + dt
  if timer < REPORT_S then return end
  timer = 0
  report()
end

function M.onReset()
  if token then timer = REPORT_S - 0.3 end   -- a reset refills the tank: say so soon
end

return M
