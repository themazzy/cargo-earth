-- Use BeamNG's full state format for deformed nodes, broken beams and persistent mechanical state.
local M = {}

-- Door, hood and tailgate latches (the game's advancedCouplerControl controllers). Loading a saved state moves every
-- node and lets the physics take over again, and the latches come out of step with their controllers: a latch can
-- let go without its controller hearing of it, so the controller still says "attached" while the door hangs open.
-- Such a door can never be shut again: a click on it only asks to open it (player report, 2026-11-24). So after a
-- restore every latch (but one broken when saved) starts over like on a fresh spawn: its couplers are let go for a
-- moment, then its controller is reset, which latches it again where the door is shut. For a few seconds after
-- that, a latch that was shut when saved and is still open gets its own close impulse.
local CLOSED = { attached = true, desyncedAttached = true, autoCoupling = true, coupling = true }
local OPEN = { detached = true, desyncedDetached = true }
M.RELEASE_S = 0.2   -- how long the couplers stay let go before the controllers are reset
M.RELATCH_S = 3
M.PUSH_AFTER_S = 0.5 -- a shut latch not latched this long after its reset gets the close impulse
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

-- Each of the latch's coupler pairs { cid1, { cid2, ... } }, as the controller reads them from the car's jbeam (its
-- own section, named like the controller, or its row in the controller list).
local pairsCache = {}
local function couplerPairs(name)
  if pairsCache[name] then return pairsCache[name] end
  local data = v and v.data
  if type(data) ~= 'table' then return {} end
  local rows = type(data[name]) == 'table' and data[name].couplerNodes or nil
  if not rows then
    for _, c in pairs(type(data.controller) == 'table' and data.controller or {}) do
      if type(c) == 'table' and (c.name or c.fileName) == name then rows = c.couplerNodes end
    end
  end
  if type(rows) ~= 'table' or type(tableFromHeaderTable) ~= 'function' then return {} end
  local ok, list = pcall(tableFromHeaderTable, deepcopy and deepcopy(rows) or rows)
  local map = beamstate and beamstate.nodeNameMap or {}
  local out = {}
  for _, row in ipairs(ok and type(list) == 'table' and list or {}) do
    local cid = type(row) == 'table' and map[row.cid1]
    if cid then
      local seconds = {}
      for _, n in ipairs(type(row.cid2) == 'table' and row.cid2 or { row.cid2 }) do
        if map[n] then seconds[#seconds + 1] = map[n] end
      end
      out[#out + 1] = { cid, seconds }
    end
  end
  pairsCache[name] = out
  return out
end

-- Lets go of the latch's couplers, so the physics and the controller agree again: nothing is latched.
local function release(c)
  local list = couplerPairs(c.name)
  for _, p in ipairs(list) do pcall(function() obj:detachCoupler(p[1], 0) end) end
  return #list > 0
end

-- The watch: at any time, a latch whose controller says "attached" while one of its pairs is far apart has come loose
-- without its controller hearing of it (the same fault as after a restore; a player saw it again after taking a
-- contract). Seen on two checks in a row, it is let go and reset, so a click shuts the door again.
M.WATCH_S, M.LOOSE_M, M.LOOSE_CHECKS = 0.5, 0.1, 2
local watchClock, loose, fixing = 0, {}, {}

local function pairGap(p)
  local best
  for _, cid2 in ipairs(p[2]) do
    local ok, d = pcall(function() return obj:nodeLength(p[1], cid2) end)
    if ok and type(d) == 'number' and (not best or d < best) then best = d end
  end
  return best
end

function M.watchTick()
  for _, c in ipairs(latches()) do
    if fixing[c.name] then
      fixing[c.name] = nil
      if c.reset then pcall(c.reset) end
    else
      local ok, s = pcall(c.getGroupState)
      local far = false
      if ok and s == 'attached' then
        for _, p in ipairs(couplerPairs(c.name)) do
          local gap = pairGap(p)
          if gap and gap > M.LOOSE_M then far = true end
        end
      end
      loose[c.name] = far and (loose[c.name] or 0) + 1 or nil
      if (loose[c.name] or 0) >= M.LOOSE_CHECKS then
        loose[c.name] = nil
        if c.reset and release(c) then
          fixing[c.name] = true
          if log then log('I', 'cargoEarth', 'latch ' .. tostring(c.name) .. ' had come loose unnoticed: latched again') end
        end
      end
    end
  end
end

function M.relatchTick()
  if not relatch or relatch.releasing then return end
  for _, c in ipairs(latches()) do
    local want = relatch.shut[c.name]
    local ok, s = pcall(c.getGroupState)
    -- still latching half a second after its reset: the door is not where it latches (a save made while it hung
    -- open), so it gets pushed shut too
    local waiting = s == 'autoCoupling' and relatch.reset[c.name] and relatch.since >= M.PUSH_AFTER_S
    if want and ok and (OPEN[s] or waiting) and (relatch.tries[c.name] or 0) < M.RELATCH_TRIES then
      relatch.tries[c.name] = (relatch.tries[c.name] or 0) + 1
      -- its reset asks for the same start latching as a fresh spawn; when that is not enough (a latch with no start
      -- radius) the next try uses its own close impulse
      if relatch.tries[c.name] == 1 and not relatch.reset[c.name] and c.reset then pcall(c.reset)
      elseif c.setState then pcall(c.setState, { [c.name .. '_groupState'] = 'attached' }) end
    end
  end
end

-- The couplers have been let go long enough: every released latch starts over like on a fresh spawn.
local function resetReleased()
  for _, c in ipairs(latches()) do
    if relatch.reset[c.name] and c.reset then pcall(c.reset) end
  end
  relatch.releasing = nil
end

function M.updateGFX(dt)
  dt = dt or 0
  if not relatch then
    watchClock = watchClock + dt
    if watchClock >= M.WATCH_S then
      watchClock = 0
      M.watchTick()
    end
    return
  end
  if relatch.releasing then
    relatch.releasing = relatch.releasing - dt
    if relatch.releasing > 0 then return end
    resetReleased()
  end
  relatch.left = relatch.left - dt
  relatch.since = relatch.since + dt
  M.relatchTick()
  if relatch.left <= 0 then relatch = nil end
end

-- Which node and beam each snapshot entry is, by name and by the part it comes from (BeamNG numbers them in load
-- order, so another config numbers them differently). A node: 'name|part'; a beam: 'node1|node2|part'.
local function nodeKeys()
  local out = {}
  for _, n in pairs(v.data.nodes) do
    if type(n) == 'table' and n.cid then out[n.cid + 1] = tostring(n.name) .. '|' .. tostring(n.partOrigin) end
  end
  return out
end
local function beamKeys()
  local out = {}
  for _, b in pairs(v.data.beams) do
    local n1 = type(b) == 'table' and b.id1 and v.data.nodes[b.id1]
    local n2 = n1 and b.id2 and v.data.nodes[b.id2]
    if type(n1) == 'table' and type(n2) == 'table' and b.cid then
      out[b.cid + 1] = tostring(n1.name) .. '|' .. tostring(n2.name) .. '|' .. tostring(b.partOrigin)
    end
  end
  return out
end
local function sameKeys(saved, now)
  if type(saved) ~= 'table' then return true end   -- an older snapshot: the counts are all there is to check
  for i, k in pairs(now) do if saved[i] ~= k then return false end end
  return true
end

-- After a parts change (Jan, 2026-11-26: a swap must not mend the other parts): the saved deformation goes back onto
-- every node and beam the new build still has from the same part. Swapped parts stay new. The powertrain and other
-- lua state of the old build are not loaded (they belong to its parts), so only the body's damage carries over.
-- lift: how far the saved shape was raised (M.liftOffGround); the new parts are raised with it, so nothing stretches.
function M.partialLoad(state, lift)
  local keys = state.cargoEarthKeys
  local nodeCid, beamCid = {}, {}
  for i, k in pairs(nodeKeys()) do nodeCid[k] = i - 1 end
  for i, k in pairs(beamKeys()) do beamCid[k] = i - 1 end
  local moved, set = 0, {}
  for i, node in pairs(state.nodes) do
    local cid = nodeCid[keys.nodes[tonumber(i)] or false]
    if cid then
      obj:setNodePosition(cid, vec3(node[1]))
      if #node > 1 then obj:setNodeMass(cid, node[2]) end
      moved, set[cid] = moved + 1, true
    end
  end
  if (lift or 0) > 0 then
    for _, cid in pairs(nodeCid) do
      if not set[cid] then
        local ok, now = pcall(function() return obj:getNodePosition(cid) end)
        if ok and now and type(now.z) == 'number' then obj:setNodePosition(cid, vec3({ now.x, now.y, now.z + lift })) end
      end
    end
  end
  for i, beam in pairs(state.beams) do
    local cid = beamCid[keys.beams[tonumber(i)] or false]
    if cid then
      obj:setBeamLength(cid, beam[1])
      if beam[2] == true then obj:breakBeam(cid) end
      if beam[3] > 0 and beamstate.onBeamDeformed then beamstate.onBeamDeformed(cid, beam[3]) end
    end
  end
  obj:commitLoad()
  return moved
end

-- The saved shape goes onto a car that already stands on the ground here. The wheels in that shape sit where they sat
-- when it was saved: on another road, with the suspension compressed over a bump, or on a kerb. Put on uneven ground
-- (a forest floor, a kerb), a wheel would land inside the ground and the tyre burst as the physics pushed it out
-- (player report, 2026-11-27: busted tyres on loading a career). So the whole saved shape is raised until no wheel
-- node is lower than it is now, plus a little: the car then drops those few centimetres onto its wheels.
M.LIFT_CLEAR_M, M.LIFT_MAX_M = 0.03, 1.5
M.wheelSet = {}
local function wheelNodes()
  local out = {}
  for _, wd in pairs(type(wheels) == 'table' and type(wheels.wheels) == 'table' and wheels.wheels or {}) do
    for _, list in ipairs({ wd.nodes, wd.treadNodes }) do
      for _, cid in pairs(type(list) == 'table' and list or {}) do
        if type(cid) == 'number' then out[cid] = true end
      end
    end
  end
  return out
end

-- cidOf(i): the car's node for the snapshot's i-th node (nil when the build no longer has it). Returns the lift.
function M.liftOffGround(state, cidOf)
  local lift = 0
  for i, node in pairs(state.nodes) do
    local cid = cidOf(tonumber(i))
    if cid and M.wheelSet[cid] then
      local ok, now = pcall(function() return obj:getNodePosition(cid) end)
      local saved = type(node[1]) == 'table' and node[1][3]
      if ok and now and type(now.z) == 'number' and type(saved) == 'number' then lift = math.max(lift, now.z - saved) end
    end
  end
  if lift <= 0 then return 0 end
  lift = math.min(lift, M.LIFT_MAX_M) + M.LIFT_CLEAR_M
  for _, node in pairs(state.nodes) do
    if type(node[1]) == 'table' and type(node[1][3]) == 'number' then node[1][3] = node[1][3] + lift end
  end
  return lift
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
      state.cargoEarthKeys = { nodes = nodeKeys(), beams = beamKeys() }
      assert(jsonWriteFile(path, state, false) ~= false)
    else
      local state = assert(jsonReadFile(path), 'Snapshot unavailable')
      assert(state.format == 'v2' and state.cargoEarthLocalNodes and state.vehicleDirectory == v.data.vehicleDirectory)
      local keys = type(state.cargoEarthKeys) == 'table' and state.cargoEarthKeys or nil
      local same = state.nodeCount == tableSizeC(v.data.nodes) and state.beamCount == tableSizeC(v.data.beams)
        and (not keys or (sameKeys(keys.nodes, nodeKeys()) and sameKeys(keys.beams, beamKeys())))
      assert(same or (keys and type(keys.nodes) == 'table' and type(keys.beams) == 'table'), 'Vehicle parts changed')
      local rotation = quatFromDir(obj:getDirectionVector(), obj:getDirectionVectorUp())
      for _, node in pairs(state.nodes) do node[1] = (rotation * vec3(node[1])):toTable() end
      local cidOf
      if same then
        cidOf = function(i) return i - 1 end
      else
        local nodeCid = {}
        for i, k in pairs(nodeKeys()) do nodeCid[k] = i - 1 end
        cidOf = function(i) return nodeCid[keys.nodes[i] or false] end
      end
      M.wheelSet = wheelNodes()
      local lift = M.liftOffGround(state, cidOf)
      if lift > 0.05 and log then log('I', 'cargoEarth', string.format('saved damage put back %.2f m higher, so no wheel lands in the ground', lift)) end
      assert(jsonWriteFile(path, state, false) ~= false)
      -- Which latches should be shut: as saved, or (an older snapshot) as the freshly spawned car has them. A latch
      -- that was open when saved stays open (it latches again when the door is pushed shut); one broken stays broken.
      local saved, now = type(state.cargoEarthLatches) == 'table' and state.cargoEarthLatches or nil, latchStates()
      local shut, keep = {}, {}
      for name, s in pairs(now) do
        local was = saved and saved[name] or (not saved and s) or nil
        if was and CLOSED[was] then shut[name] = true end
        keep[name] = was == 'broken' or s == 'broken'
      end
      if same then beamstate.load(path) else M.partialLoad(state, lift) end
      relatch = { left = M.RELATCH_S, since = 0, shut = shut, tries = {}, reset = {} }
      for _, c in ipairs(latches()) do
        if not keep[c.name] and c.reset and release(c) then relatch.reset[c.name] = true relatch.releasing = M.RELEASE_S end
      end
      M.relatchTick()
    end
  end)
  obj:queueGameEngineLua(string.format('require("cargoEarth/damage").complete(%d, %d, %s)', token, obj:getID(), tostring(ok)))
end
return M
