-- Full vehicle snapshots travel through a private temporary file between the two Lua VMs.
local M = {}
local requests, capturing, serial = {}, {}, 0
local session, clock = tostring(os.time()), 0
function M.complete(token, id, ok)
  local r = requests[token]
  if not r or r.id ~= id then return end
  requests[token] = nil
  local read, data = pcall(jsonReadFile, r.path)
  ok = ok and read and type(data) == 'table'
  if FS and FS.removeFile then FS:removeFile(r.path) end
  r.done(ok == true, data)
end

local function request(G, action, data, done)
  if not G.vehicleState or not G.playerId or not G.playerId() then return false end
  serial = serial + 1
  local path = '/settings/cargoEarth/vehicleState/' .. session .. '_' .. serial .. '.json'
  if FS and FS.directoryCreate then FS:directoryCreate('/settings/cargoEarth/vehicleState/') end
  if data then
    local written, result = pcall(jsonWriteFile, path, data, false)
    if not written or result == false then return false end
  end
  requests[serial] = {id = G.playerId(), path = path, done = done, at = clock}
  local ok, sent = pcall(G.vehicleState, action, path, serial)
  if not ok or not sent then
    requests[serial] = nil
    if FS and FS.removeFile then FS:removeFile(path) end
    return false
  end
  return true
end

function M.tick(dt)
  clock = clock + math.max(0, dt or 0)
  for token, r in pairs(requests) do
    if clock - r.at > 10 then M.complete(token, r.id, false) end
  end
end

function M.capture(G, g, done)
  local car = g.car
  if not car or capturing[car] then return end
  local revision = car.damageRevision
  capturing[car] = true
  if not request(G, 'capture', nil, function(ok, data)
    capturing[car] = nil
    if ok and type(data) == 'table' and data.format == 'v2' and car.damageRevision == revision then
      car.physicalDamage = data
      done()
    end
  end) then capturing[car] = nil end
end

function M.restore(G, g, done)
  return request(G, 'restore', g.car.physicalDamage, done)
end

function M.clear(car)
  if car then
    car.physicalDamage = nil
    car.damageRevision = (car.damageRevision or 0) + 1
  end
end
return M
