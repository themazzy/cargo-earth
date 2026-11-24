-- Use BeamNG's full state format for deformed nodes, broken beams and persistent mechanical state.
local M = {}

-- Door, hood and tailgate latches (the game's advancedCouplerControl controllers). Loading a saved state moves every
-- node and lets the physics take over again, and the latches can come loose doing it: the doors swing open with no real
-- damage. So the latch states go into the snapshot, and for a few seconds after a restore every latch that was shut
-- is latched again.
local CLOSED = { attached = true, desyncedAttached = true, autoCoupling = true, coupling = true }
local OPEN = { detached = true, desyncedDetached = true }
M.RELATCH_S = 3
M.RELATCH_TRIES = 3
local relatch = nil

local function latches()
  local list = {}
  local ok, found = pcall(function()
    return controller and controller.getControllersByType and controller.getControllersByType('advancedCouplerControl')
  end)
  for _, c in ipairs(ok and type(found) == 'table' and found or {}) do
    if type(c) == 'table' and c.name and c.getGroupState then list[#list + 1] = c end
  end
  return list
end

local function latchStates()
  local out = {}
  for _, c in ipairs(latches()) do
    local ok, s = pcall(c.getGroupState)
    if ok and type(s) == 'string' then out[c.name] = s end
  end
  return out
end

-- Latches one controller again: its reset asks for the same start latching as a fresh spawn; when that is not enough
-- (a latch with no start radius) the next try uses its own close impulse.
local function latch(c, try)
  if try == 1 and c.reset then
    pcall(c.reset)
  elseif c.setState then
    pcall(c.setState, { [c.name .. '_groupState'] = 'attached' })
  end
end

function M.relatchTick()
  if not relatch then return end
  for _, c in ipairs(latches()) do
    local want = relatch.shut[c.name]
    local ok, s = pcall(c.getGroupState)
    if want and ok and OPEN[s] and (relatch.tries[c.name] or 0) < M.RELATCH_TRIES then
      relatch.tries[c.name] = (relatch.tries[c.name] or 0) + 1
      latch(c, relatch.tries[c.name])
    end
  end
end

function M.updateGFX(dt)
  if not relatch then return end
  relatch.left = relatch.left - (dt or 0)
  M.relatchTick()
  if relatch.left <= 0 then relatch = nil end
end

function M.run(action, path, token)
  local ok = pcall(function()
    if action == 'capture' then
      beamstate.save(path)
      local state = assert(jsonReadFile(path), 'Snapshot was not written')
      local rotation = quatFromDir(obj:getDirectionVector(), obj:getDirectionVectorUp()):inversed()
      for _, node in pairs(state.nodes) do node[1] = (rotation * vec3(node[1])):toTable() end
      state.cargoEarthLocalNodes = true
      state.cargoEarthLatches = latchStates()
      assert(jsonWriteFile(path, state, false) ~= false)
    else
      local state = assert(jsonReadFile(path), 'Snapshot unavailable')
      assert(state.format == 'v2' and state.cargoEarthLocalNodes and state.vehicleDirectory == v.data.vehicleDirectory)
      assert(state.nodeCount == tableSizeC(v.data.nodes) and state.beamCount == tableSizeC(v.data.beams), 'Vehicle parts changed')
      local rotation = quatFromDir(obj:getDirectionVector(), obj:getDirectionVectorUp())
      for _, node in pairs(state.nodes) do node[1] = (rotation * vec3(node[1])):toTable() end
      assert(jsonWriteFile(path, state, false) ~= false)
      -- Which latches should be shut: as saved, or (an older snapshot) as the freshly spawned car has them. A latch
      -- that was open or broken when saved stays so.
      local saved, now = type(state.cargoEarthLatches) == 'table' and state.cargoEarthLatches or nil, latchStates()
      local shut = {}
      for name, s in pairs(now) do
        local was = saved and saved[name] or (not saved and s) or nil
        if was and CLOSED[was] then shut[name] = true end
      end
      beamstate.load(path)
      relatch = { left = M.RELATCH_S, shut = shut, tries = {} }
      M.relatchTick()
    end
  end)
  obj:queueGameEngineLua(string.format('require("cargoEarth/damage").complete(%d, %d, %s)', token, obj:getID(), tostring(ok)))
end
return M
