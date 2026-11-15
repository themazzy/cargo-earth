-- Observe the stock bus controller, including its normal O / toggle_doors input. Only state changes cross VMs.
local M = {}
local token, previous, elapsed = nil, nil, 0

function M.watch(value)
  token, previous, elapsed = value, nil, 0
end

function M.updateGFX(dt)
  if not token or dt <= 0 then return end
  elapsed = elapsed + dt
  if elapsed < 0.1 then return end
  elapsed = 0
  local b = controller and controller.getControllerSafe and controller.getControllerSafe('bus')
  if not b or not b.getState then return end
  local state = b.getState()
  local open = state and state.bus_doorsRequestedOpen
  if type(open) ~= 'boolean' or open == previous then return end
  local initial = previous == nil
  previous = open
  if initial and not open then return end -- an initial closed snapshot must not cancel a just-pressed phone button
  obj:queueGameEngineLua(string.format('extensions.hook("onCargoEarthBusDoors", %d, %d, %s)',
    obj:getID(), token, tostring(open)))
end

function M.onReset() previous, elapsed = nil, 0 end
return M
