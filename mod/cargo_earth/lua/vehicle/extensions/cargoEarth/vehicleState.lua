-- Use BeamNG's full state format for deformed nodes, broken beams and persistent mechanical state.
local M = {}
function M.run(action, path, token)
  local ok = pcall(function()
    if action == 'capture' then
      beamstate.save(path)
      local state = assert(jsonReadFile(path), 'Snapshot was not written')
      local rotation = quatFromDir(obj:getDirectionVector(), obj:getDirectionVectorUp()):inversed()
      for _, node in pairs(state.nodes) do node[1] = (rotation * vec3(node[1])):toTable() end
      state.cargoEarthLocalNodes = true
      assert(jsonWriteFile(path, state, false) ~= false)
    else
      local state = assert(jsonReadFile(path), 'Snapshot unavailable')
      assert(state.format == 'v2' and state.cargoEarthLocalNodes and state.vehicleDirectory == v.data.vehicleDirectory)
      assert(state.nodeCount == tableSizeC(v.data.nodes) and state.beamCount == tableSizeC(v.data.beams), 'Vehicle parts changed')
      local rotation = quatFromDir(obj:getDirectionVector(), obj:getDirectionVectorUp())
      for _, node in pairs(state.nodes) do node[1] = (rotation * vec3(node[1])):toTable() end
      assert(jsonWriteFile(path, state, false) ~= false)
      beamstate.load(path)
    end
  end)
  obj:queueGameEngineLua(string.format('require("cargoEarth/damage").complete(%d, %d, %s)', token, obj:getID(), tostring(ok)))
end
return M
