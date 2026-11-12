-- Real nonblocking client with deterministic socket/HTTP fixtures; no network access required.
local client = require('cargoEarth/helper')
local passed, requests, replies, dataset, callbacks = 0, {}, {}, 'A', 0
local badArea, bigBody = false, false
local function test(name, fn)
  client._reset()
  requests, replies, dataset, callbacks, badArea, bigBody = {}, {}, 'A', 0, false, false
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  passed = passed + 1
  print('PASS ' .. name)
end
local received = 0
local function response(path)
  local data
  if path:find('/v1/radio', 1, true) then
    data = {state = 'ready', country = 'CZ', top = {{'id', 'Radio', 'http://x'}}, near = {}}
  elseif path:find('/v1/cameras', 1, true) then
    data = {state = 'ready', cells = {'100_28'}, cameras = {{'n1', 50, 14, 50, 'primary'}}}
  elseif path:find('/v1/near', 1, true) then
    local lat, lon = path:match('lat=([%d%.%-]+)&lon=([%d%.%-]+)')
    local key = math.floor(tonumber(lat) / 0.1) .. '_' .. math.floor(tonumber(lon) / 0.1)
    data = {ready = {key}, loading = 0, failed = 0, grocers = true, depots = true, release = dataset, areaFormat = '3'}
  else
    data = {key = badArea and 'wrong' or path:match('key=(.+)'), release = dataset, tiles = {}, restaurants = {}, grocers = {}, depots = {}}
  end
  local body = 'response' .. (#replies + 1)
  replies[#replies + 1] = data
  if bigBody then body = string.rep('x', 70000) end
  return 'HTTP/1.0 200 OK\r\nContent-Length: ' .. #body .. '\r\n\r\n' .. body
end
jsonDecode = function(body)
  local index = tonumber(body:match('^response(%d+)$'))
  assert(index)
  return replies[index]
end
socket = {tcp = function()
  local s = {}
  function s:settimeout() end
  function s:connect() return true end
  function s:send(out)
    local path = out:match('^GET ([^ ]+)')
    requests[#requests + 1] = path
    self.body = response(path)
    return #out
  end
  function s:receive()
    received = received + 1
    local body = self.body
    self.body = ''
    return nil, 'closed', body
  end
  function s:close() end
  return s
end}
local function tick(t, lat, lon)
  client.tick(lat or 50, lon or 14, t, function() callbacks = callbacks + 1 end)
end

test('stationary loaded discovery uses a thirty-second heartbeat', function()
  for i = 0, 200 do tick(i / 2) end
  local near, areas = 0, 0
  for _, request in ipairs(requests) do
    if request:find('/v1/near', 1, true) then near = near + 1 else areas = areas + 1 end
  end
  assert(near <= 5 and areas == 1 and callbacks == 1)
end)

test('teleport prioritizes new location instead of downloading a stale area', function()
  tick(0); tick(0.5); tick(1)
  for i = 3, 20 do tick(i / 2, 42.65, 23.35) end
  assert(callbacks == 1)
  for _, request in ipairs(requests) do assert(not request:find('/v1/area?key=500_140', 1, true)) end
end)

test('wrong-key and oversized helper replies are rejected', function()
  badArea = true
  for i = 0, 10 do tick(i / 2) end
  assert(callbacks == 0 and not client.hasArea('500_140'))
  client._reset()
  local limit = client.MAX_RESPONSE
  client.MAX_RESPONSE, bigBody = 65536, true
  tick(20); tick(20.5); tick(21)
  client.MAX_RESPONSE = limit
  assert(client.status().state == 'off' and client.status().msg:find('size limit'))
end)

test('changing release refreshes previously loaded discovery cells', function()
  for i = 0, 20 do tick(i / 2) end
  assert(callbacks == 1)
  dataset = 'B'
  for i = 21, 150 do tick(i / 2) end
  assert(callbacks == 2 and client.status().release == 'B')
end)

test('helper can be re-enabled and invalid ports do not replace the working port', function()
  client.configure({helper = false})
  tick(0)
  assert(#requests == 0)
  client.configure({helper = true, helperPort = 99999})
  tick(1); tick(1.5); tick(2)
  assert(#requests == 1 and client.PORT == 47820)
end)

test('speed cameras are asked for once a minute, alone where the data pack covers the rest', function()
  local got = 0
  for i = 0, 260 do
    client.tick(50, 14, i / 2, function() callbacks = callbacks + 1 end, function(data)
      got = got + 1
      assert(data.cameras[1][1] == 'n1')
    end, true)
  end
  assert(got == 3 and #requests == 3 and callbacks == 0, got .. ' camera replies, ' .. #requests .. ' requests')
  for _, request in ipairs(requests) do assert(request:find('/v1/cameras?lat=50.00000&lon=14.00000', 1, true)) end
  assert(client.status().cameras == 'ready')
end)

test('one-off requests go first, once each, and answer their caller', function()
  local got = {}
  client.ask('/v1/radio?cc=CZ', function(data) got[#got + 1] = data.country end)
  client.ask('/v1/radio?cc=CZ', function(data) got[#got + 1] = data.country end)
  assert(client.asking())
  for i = 0, 4 do client.tick(50, 14, i / 2, nil, nil, true) end
  assert(#got == 1 and got[1] == 'CZ' and #requests == 1 and requests[1] == '/v1/radio?cc=CZ')
  assert(not client.asking())
  local why
  client.ask('/v1/radio?cc=AT', function(data, err) why = err assert(data == nil) end)
  client.configure({helper = false})
  client.tick(50, 14, 10)
  assert(why == 'helper turned off' and not client.asking())
end)

test('a newer radio command replaces queued ones, so the last press wins in order', function()
  client.ask('/v1/player/stop', nil, '/v1/player/')
  client.ask('/v1/player/play?id=a', nil, '/v1/player/')
  client.ask('/v1/player/stop', nil, '/v1/player/')
  client.ask('/v1/radio?cc=CZ', nil)
  for i = 0, 10 do client.tick(50, 14, i / 2, nil, nil, true) end
  assert(#requests == 2 and requests[1] == '/v1/player/stop' and requests[2] == '/v1/radio?cc=CZ', table.concat(requests, ' '))
end)

client._reset()
socket = nil
package.loaded['cargoEarth/helper'] = nil
print(passed .. ' helper client tests passed')
