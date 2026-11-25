-- Real nonblocking client with deterministic socket/HTTP fixtures; no network access required.
local client = require('cargoEarth/helper')
local passed, requests, replies, dataset, callbacks = 0, {}, {}, 'A', 0
local badArea, bigBody, refuse, httpErr = false, false, false, false
local function test(name, fn)
  client._reset()
  requests, replies, dataset, callbacks, badArea, bigBody, refuse, httpErr = {}, {}, 'A', 0, false, false, false, false
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  passed = passed + 1
  print('PASS ' .. name)
end
local received, connectedPort = 0, nil
local function response(path)
  local data
  if path:find('/v1/osm/tile', 1, true) then
    if path:find('y=9', 1, true) then
      local why = '{"error": "no internet"}'
      return 'HTTP/1.0 502 Bad Gateway\r\nContent-Length: ' .. #why .. '\r\n\r\n' .. why
    end
    return 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nAQID'
  end
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
  if httpErr then return 'HTTP/1.0 500 Internal Server Error\r\n\r\n' end
  return 'HTTP/1.0 200 OK\r\nContent-Length: ' .. #body .. '\r\n\r\n' .. body
end
jsonDecode = function(body)
  if body == '{"error": "no internet"}' then return {error = 'no internet'} end
  local index = tonumber(body:match('^response(%d+)$'))
  assert(index)
  return replies[index]
end
socket = {tcp = function()
  local s = {}
  function s:settimeout() end
  function s:connect(_, port) connectedPort = port if refuse then return nil, 'connection refused' end return true end
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
  assert(#requests == 1 and client.PORT == 47821 and connectedPort == 47821)
end)

test('legacy ports migrate while custom helper ports remain usable', function()
  local cfg = {helperPort = '47820', helper = true, other = 'kept'}
  assert(client.configure(cfg) == true and cfg.helperPort == 47821 and cfg.other == 'kept')
  tick(0)
  assert(connectedPort == 47821, 'the client never connects to EarthRadio during migration')
  client._reset()
  assert(client.configure({helperPort = 53100}) == false and client.PORT == 53100)
  tick(0)
  assert(connectedPort == 53100)
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

test('radio presses go through their own lane in one frame, even while an area download is open', function()
  tick(0)                                          -- the slow lane opens a request and keeps it
  local slow = #requests
  local got
  client.command('/v1/player/play?id=a', function() got = 'a' end, '/v1/player/')
  client.command('/v1/player/play?id=b', function(data) got = data end, '/v1/player/')
  assert(client.commanding())
  client.pump(0.01)
  assert(requests[#requests] == '/v1/player/play?id=b' and #requests == slow + 1, table.concat(requests, ' '))
  assert(type(got) == 'table' and not client.commanding(), 'answered within the same frame')
  local why
  client.command('/v1/player/stop', function(data, err) why = err end)
  client.configure({helper = false})
  client.pump(0.02)
  assert(why == 'helper turned off' and not client.commanding())
end)

test('map tiles: their own lane, plain text answers, the helper\'s reason on errors, radio presses go first', function()
  local tiles = require('cargoEarth/osmtiles')
  tiles._reset()
  local first = tiles.get(client, 14, 8848, 5550, 0)
  assert(first.state == 'loading' and client.commanding())
  client.command('/v1/player/stop', function() end)
  client.pump(0.01)
  assert(requests[1] == '/v1/player/stop' and requests[2] == '/v1/osm/tile?z=14&x=8848&y=5550&as=b64', table.concat(requests, ' '))
  local ok = tiles.get(client, 14, 8848, 5550, 0.02)
  assert(ok.state == 'ok' and ok.b64 == 'AQID', tostring(ok.state))
  assert(#requests == 2, 'a finished tile is handed out again without asking')
  tiles.get(client, 14, 8848, 9, 0.03)
  client.pump(0.04)
  local bad = tiles.get(client, 14, 8848, 9, 0.05)
  assert(bad.state == 'error' and bad.err == 'HTTP 502: no internet', tostring(bad.err))
  assert(tiles.get(client, 14, 8848, 5550, 30).state == 'loading', 'asked again after a while')
  assert(tiles.get(client, 14, 'x', 1, 30).state == 'error')
  for i = 1, 10 do tiles.get(client, 14, 100, i, 31) end
  assert(#requests == 3 + 0 and client.commanding(), 'queued, at most a few at once')
  client.configure({helper = false})
  assert(tiles.get(client, 14, 5, 5, 32).err == 'the helper is turned off')
  tiles._reset()
end)

test('describe tells a helper that never ran from one that stopped, a timeout and an HTTP error', function()
  assert(client.describe(0) == nil, 'nothing asked yet: nothing to say')
  refuse = true
  tick(0)
  local st = client.status()
  assert(st.state == 'off' and st.errKind == 'down', tostring(st.errKind))
  assert(client.describe(0):find('not running', 1, true), client.describe(0))
  client._reset()
  refuse = false
  tick(0) tick(0.5) tick(1)                        -- answers once (areas found)...
  assert(client.status().okAt == 1 and client.describe(1) == nil, tostring(client.status().okAt))
  refuse = true
  for t = 1, 400 do tick(t) end                    -- ...then nothing listens any more
  assert(client.status().state == 'off')
  local text = client.describe(400)
  assert(text:find('stopped answering 6 min ago', 1, true) and text:find('crashed', 1, true), text)
  client._reset()
  refuse, httpErr = false, true
  tick(0) tick(0.5) tick(1)
  assert(client.status().errKind == 'http' and client.describe(1):find('HTTP 500', 1, true), tostring(client.describe(1)))
  assert(client.errorKind('timeout') == 'timeout' and client.errorKind('bad JSON') == 'bad'
    and client.errorKind('Connection refused') == 'down')
  client.configure({helper = false})
  assert(client.describe(0):find('turned off', 1, true))
end)

client._reset()
socket = nil
package.loaded['cargoEarth/helper'] = nil
print(passed .. ' helper client tests passed')
