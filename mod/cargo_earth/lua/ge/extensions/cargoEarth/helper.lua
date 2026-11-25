-- cargoEarth/helper: talks to the Cargo Earth helper (helper/cargo_earth_helper.py, a BeamNG.Earth add-on) on this
-- computer, which streams food pickups and customer addresses around the player. Game Lua may only open
-- connections to local addresses, so the helper does the downloading; this side asks it over plain HTTP with
-- non-blocking sockets (one request at a time, never waits in a frame).
--
--   helper.tick(lat, lon, now, onArea)   every frame or tick; onArea(data) gets each new area once
--   helper.command(path, onDone, replace) / helper.pump(now)   the fast lane, every frame, for presses (radio)
--   helper.tile(path, onDone)            the map lane, also worked by pump(): the phone's map tiles, raw text answers
--   helper.status()                      { state = 'off' | 'searching' | 'loading' | 'ready' | 'error', loading, ready, msg }
-- tick also takes onCameras(data) (speed cameras around the player, asked for now and then) and onlyCameras (true
-- where the mod's own data pack covers everything else).
local M = {}

M.DEFAULT_PORT, M.LEGACY_PORT = 47821, 47820 -- EarthRadio uses the retired Cargo Earth port.
M.HOST, M.PORT = '127.0.0.1', M.DEFAULT_PORT
M.ASK_EVERY_S = 3          -- ask which areas around the player are ready this often
M.IDLE_ASK_S = 30          -- loaded and stationary: a release/version heartbeat, not constant polling
M.RETRY_S = 15             -- helper not answering: try again after this long
M.TIMEOUT_S = 20           -- a request that takes longer is dropped
M.MAX_RESPONSE = 8 * 1024 * 1024 + 8192
M.READ_CHUNKS = 8          -- at most 512 KiB of socket work in one game tick
M.CAMERAS_S = 60           -- ask for the speed cameras around the player this often
M.CAMERAS_LOADING_S = 4    -- ... and this often while the helper is still fetching them
M.CAMERAS_OLD_S = 600      -- a helper without cameras (before 0.4): look again after this long

local socket
local req = nil            -- { sock, phase = 'connect' | 'send' | 'recv', out, buf, t0, what, key }
local st = { state = 'off', loading = 0, ready = 0, msg = nil }
local nextAsk, wanted, got = 0, {}, {}
local nearCell
local nextCameras = 0
local queue = {}           -- { { path, on } } one-off requests
M.enabled = true

function M.configure(cfg)
  cfg = cfg or {}
  M.enabled = cfg.helper ~= false
  local port = tonumber(cfg.helperPort)
  if port == M.LEGACY_PORT then
    port, cfg.helperPort = M.DEFAULT_PORT, M.DEFAULT_PORT
    M.PORT = port
    return true -- persist the migrated configuration
  end
  if port and port == math.floor(port) and port >= 1024 and port <= 65535 then M.PORT = port end
  return false
end

function M.status() return st end
local function unavailable(err)
  return 'Cargo Earth helper not answering on port ' .. M.PORT .. ' (' .. tostring(err)
    .. '). Update both the mod and helper with CargoEarthSetup, then restart BeamNG.Earth.'
end
-- ask again by time t (the helper was just started: no need to wait out RETRY_S)
function M.retrySoon(t) if st.state == 'off' and t < nextAsk then nextAsk, nextCameras = t, math.min(nextCameras, t) end end
function M.hasArea(key) return got[key] == true end
function M.forget(key) got[key] = nil end

local function cell(lat, lon)
  return math.floor(lat / 0.1) .. '_' .. math.floor(((lon + 180) % 360 - 180) / 0.1)
end

local function nearby(key, lat, lon)
  local row, col = key:match('^(-?%d+)_(-?%d+)$')
  if not row then return false end
  local r = math.floor(lat / 0.1)
  local c = math.floor(((lon + 180) % 360 - 180) / 0.1)
  local gap = math.abs(tonumber(col) - c)
  return math.abs(tonumber(row) - r) <= 1 and math.min(gap, 3600 - gap) <= 1
end

local function close()
  if req and req.sock then pcall(function() req.sock:close() end) end
  req = nil
end

-- a new non-blocking request to the helper, or nil and why
local function open(path, now)
  socket = socket or rawget(_G, 'socket')
  if not socket then
    local ok, loaded = pcall(require, 'socket')
    if not ok then return nil, 'LuaSocket unavailable' end
    socket = loaded
  end
  local s = socket.tcp()
  if not s then return nil, 'Could not create helper socket' end
  s:settimeout(0)
  local ok, err = s:connect(M.HOST, M.PORT)
  if not ok and err ~= 'timeout' and err ~= 'Operation already in progress' then
    pcall(function() s:close() end)
    return nil, err
  end
  return { sock = s, phase = 'send', t0 = now, buf = {}, bytes = 0, sent = 0,
    out = 'GET ' .. path .. ' HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' }
end

local function start(path, what, key, now, requestCell)
  local r, err = open(path, now)
  if not r then return false, err end
  r.what, r.key, r.cell = what, key, requestCell
  req = r
  return true
end

-- the body of a finished HTTP response, or nil and why
local function parse(raw, plain)
  local head, body = raw:match('^(.-)\r\n\r\n(.*)$')
  if not head then return nil, 'bad response' end
  local code = tonumber(head:match('^HTTP/%d%.%d (%d+)'))
  if code ~= 200 then
    if plain and #body < 2000 then         -- the helper's own reason, when it sent one
      local ok, d = pcall(jsonDecode, body)
      if ok and type(d) == 'table' and d.error then return nil, 'HTTP ' .. tostring(code) .. ': ' .. tostring(d.error) end
    end
    return nil, 'HTTP ' .. tostring(code)
  end
  if plain then return body end            -- text as it came (no JSON decoding of big answers)
  local ok, data = pcall(jsonDecode, body)
  if not ok or type(data) ~= 'table' then return nil, 'bad JSON' end
  return data
end

-- one step of the running request: nil while it runs, else (data) or (nil, err)
local function stepReq(r, now)
  local s = r.sock
  if now - r.t0 > M.TIMEOUT_S then return nil, 'timeout' end
  if r.phase == 'send' then
    local n, err, last = s:send(r.out, r.sent + 1)
    if n then r.sent = n elseif err == 'timeout' then r.sent = last or r.sent
    elseif err == 'Socket is not connected' then return
    else return nil, err end
    if r.sent >= #r.out then r.phase = 'recv' end
    return
  end
  for _ = 1, M.READ_CHUNKS do
    local data, err, partial = s:receive(65536)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      r.bytes = r.bytes + #chunk
      if r.bytes > M.MAX_RESPONSE then return nil, 'helper response exceeds size limit' end
      r.buf[#r.buf + 1] = chunk
    end
    if err == 'closed' then return parse(table.concat(r.buf), r.plain) end
    if err then
      if err ~= 'timeout' then return nil, err end
      return
    end
  end
end

local function step(now) return stepReq(req, now) end

-- Did the helper answer at all? A connection that failed (not an HTTP error, which the helper itself sends) marks it
-- down (st.down, for the phone's Start helper button); any answer clears that.
-- Every answer and every failure is also kept for the "why no orders" line (describe): when the helper last answered
-- (st.okAt), the last failure (st.err, st.errKind, st.errAt).
local clockNow = 0
local function seen(data, err)
  if data or (type(err) == 'string' and err:match('^HTTP ')) then st.down = nil
  elseif err then st.down = tostring(err) end
  if data then st.okAt, st.err, st.errKind = clockNow, nil, nil
  elseif err then st.err, st.errKind, st.errAt = tostring(err), M.errorKind(err), clockNow end
end

-- What kind of failure an error is: 'down' (nothing listens on the port: not running or crashed), 'timeout' (it took
-- the connection but did not answer in TIMEOUT_S: busy or stuck), 'http' (it answered with an error code), 'bad' (an
-- answer the game cannot read), 'socket' (the game itself could not open a connection).
function M.errorKind(err)
  err = tostring(err)
  if err == 'timeout' then return 'timeout' end
  if err:match('^HTTP ') then return 'http' end
  if err == 'bad JSON' or err == 'bad response' or err:find('size limit', 1, true) then return 'bad' end
  if err == 'LuaSocket unavailable' or err:find('Could not create', 1, true) then return 'socket' end
  return 'down'
end

-- One sentence on what is wrong with the helper, or nil when it answers.
function M.describe(now)
  if not M.enabled then return 'The Cargo Earth helper is turned off in Settings.' end
  if st.state ~= 'off' or not st.err then return nil end
  local kind, port = st.errKind, M.PORT
  if kind == 'timeout' then
    return string.format('The helper did not answer within %d s: it is busy or stuck. Restart it if this stays.', M.TIMEOUT_S)
  elseif kind == 'http' then
    return 'The helper answered with an error (' .. st.err .. '). Update it with CargoEarthSetup.'
  elseif kind == 'bad' then
    return 'The helper sent an answer the game could not read (' .. st.err .. '). Update it with CargoEarthSetup.'
  elseif kind == 'socket' then
    return 'The game could not open a connection to the helper (' .. st.err .. ').'
  end
  if st.okAt then
    local mins = math.max(0, math.floor(((now or clockNow) - st.okAt) / 60))
    return string.format('The helper stopped answering%s: it may have crashed. Start it again from BeamNG.Earth\'s Add-ons page.',
      mins >= 1 and string.format(' %d min ago', mins) or '')
  end
  return string.format('The Cargo Earth helper is not running (nothing on port %d). Start it from BeamNG.Earth\'s Add-ons page.', port)
end

local function finish(data, err, now, lat, lon, onArea)
  local r = req
  close()
  seen(data, err)
  if r.what == 'ask' then
    if r.on then r.on(data, err) end
    return
  end
  if r.what == 'cameras' then
    if data then
      st.cameras = data.state
      nextCameras = now + (data.state == 'loading' and M.CAMERAS_LOADING_S or M.CAMERAS_S)
      if r.on then r.on(data) end
    else
      st.cameras = 'off'
      nextCameras = now + (err == 'HTTP 404' and M.CAMERAS_OLD_S or M.RETRY_S)
    end
    return
  end
  if not data then
    st.state, st.msg = 'off', unavailable(err)
    wanted = {}
    nextAsk = now + M.RETRY_S
    return
  end
  if r.what == 'near' then
    if r.cell ~= cell(lat, lon) then nextAsk = 0 return end
    nearCell = r.cell
    if st.release and data.release and (st.release ~= data.release or st.areaFormat ~= data.areaFormat) then got = {} end
    st.release, st.areaFormat = data.release, data.areaFormat
    local supportsGrocers = data.grocers == true
    local supportsDepots = data.depots == true
    if st.supportsDepots == false and supportsDepots then got, wanted = {}, {} end
    st.supportsDepots = supportsDepots
    if st.supportsGrocers == false and supportsGrocers then got, wanted = {}, {} end
    st.supportsGrocers = supportsGrocers
    local supportsFuel = data.fuel == true
    if st.supportsFuel == false and supportsFuel then got, wanted = {}, {} end
    st.supportsFuel = supportsFuel
    local supportsAutos = data.autos == true
    if st.supportsAutos == false and supportsAutos then got, wanted = {}, {} end
    st.supportsAutos = supportsAutos
    st.loading, st.ready = data.loading or 0, #(data.ready or {})
    st.msg = (data.failed or 0) > 0 and data.errors and data.errors[1] or nil
    st.state = (data.loading or 0) > 0 and 'loading' or ((data.failed or 0) > 0 and st.ready == 0 and 'error' or 'ready')
    wanted = {}
    for _, k in ipairs(data.ready or {}) do
      if type(k) == 'string' and nearby(k, lat, lon) and not got[k] then wanted[k] = true end
    end
    local busy = st.loading > 0 or (data.failed or 0) > 0 or next(wanted) ~= nil
    nextAsk = now + (busy and M.ASK_EVERY_S or M.IDLE_ASK_S)
  else
    if data.key ~= r.key then
      st.state, st.msg, nextAsk = 'error', 'Helper returned a different area', now + M.RETRY_S
      wanted[r.key] = nil
      return
    end
    if not nearby(r.key, lat, lon) then wanted[r.key] = nil return end
    got[r.key] = true
    wanted[r.key] = nil
    if onArea then onArea(data) end
  end
end

-- replace: a path prefix; queued requests starting with it are dropped first, so only the newest command of that kind
-- is sent (play / stop / volume of the radio: the last press wins, in order).
function M.ask(path, onDone, replace)
  if replace then
    for i = #queue, 1, -1 do
      if queue[i][1]:sub(1, #replace) == replace then table.remove(queue, i) end
    end
  end
  for _, q in ipairs(queue) do if q[1] == path then return end end
  if #queue < 8 then queue[#queue + 1] = { path, onDone } end
end

function M.asking() return #queue > 0 or (req ~= nil and req.what == 'ask') end

-- A second lane for commands a player waits on (the radio's play / stop / volume): its own socket, worked every
-- frame by pump(), so a press never waits behind an area download or for the half-second tick. A third lane, the same
-- way, carries the phone's map tiles (plain text answers), so tiles never hold up a radio press.
M.FAST_STEPS = 4           -- socket steps per frame (connect, send and reading are each one)
M.TILE_QUEUE = 8
local fastLane = { queue = {} }
local tileLane = { queue = {}, plain = true }

local function enqueue(lane, path, onDone, replace, max)
  if replace then
    for i = #lane.queue, 1, -1 do
      if lane.queue[i][1]:sub(1, #replace) == replace then table.remove(lane.queue, i) end
    end
  end
  for _, q in ipairs(lane.queue) do if q[1] == path then return true end end
  if #lane.queue >= max then return false end
  lane.queue[#lane.queue + 1] = { path, onDone }
  return true
end

function M.command(path, onDone, replace) return enqueue(fastLane, path, onDone, replace, 8) end
-- false when the map lane is full (ask again later)
function M.tile(path, onDone) return enqueue(tileLane, path, onDone, nil, M.TILE_QUEUE) end

local function busy(lane) return lane.cur ~= nil or #lane.queue > 0 end
function M.commanding() return busy(fastLane) or busy(tileLane) end

local function stopLane(lane)
  if lane.cur then local s = lane.cur.sock pcall(function() s:close() end) lane.cur = nil end
  for _, q in ipairs(lane.queue) do if q[2] then q[2](nil, 'helper turned off') end end
  lane.queue = {}
end

local function pumpLane(lane, now)
  for _ = 1, M.FAST_STEPS do
    if not lane.cur then
      local q = table.remove(lane.queue, 1)
      if not q then return end
      local r, err = open(q[1], now)
      if not r then
        seen(nil, tostring(err))
        if q[2] then q[2](nil, tostring(err)) end
        return
      end
      r.on, r.plain, lane.cur = q[2], lane.plain, r
    end
    local reading = lane.cur.phase == 'recv'
    local data, err = stepReq(lane.cur, now)
    if data or err then
      local r = lane.cur
      pcall(function() r.sock:close() end)
      lane.cur = nil
      seen(data, err)
      if r.on then r.on(data, err) end
    elseif reading then
      return       -- the helper is still answering: next frame
    end
  end
end

function M.pump(now)
  clockNow = now or clockNow
  if not M.enabled then stopLane(fastLane) stopLane(tileLane) return end
  pumpLane(fastLane, now)
  pumpLane(tileLane, now)
end

function M.tick(lat, lon, now, onArea, onCameras, onlyCameras)
  clockNow = now or clockNow
  if not M.enabled then
    close()
    for _, q in ipairs(queue) do if q[2] then q[2](nil, 'helper turned off') end end
    queue = {}
    return
  end
  if type(lat) ~= 'number' or type(lon) ~= 'number' or lat ~= lat or lon ~= lon or math.abs(lat) > 90 or math.abs(lon) > 180 then return end
  if req then
    local data, err = step(now)
    if data or err then finish(data, err, now, lat, lon, onArea) end
    return
  end
  if #queue > 0 then
    local q = table.remove(queue, 1)
    local ok, err = start(q[1], 'ask', nil, now)
    if ok then req.on = q[2] else
      seen(nil, tostring(err))
      if q[2] then q[2](nil, tostring(err)) end
    end
    return
  end
  if onCameras and now >= nextCameras then
    local ok, err = start(string.format('/v1/cameras?lat=%.5f&lon=%.5f', lat, lon), 'cameras', nil, now)
    if ok then req.on = onCameras else
      seen(nil, tostring(err))
      st.cameras, nextCameras = 'off', now + M.RETRY_S
    end
    return
  end
  if onlyCameras then return end
  local here = cell(lat, lon)
  -- Fetch the new neighbourhood before any queued cell from the previous location.
  if here ~= nearCell and st.state ~= 'off' then nextAsk = 0 wanted = {} end
  local k = here == nearCell and next(wanted) or nil
  if k then
    local ok, err = start('/v1/area?key=' .. k, 'area', k, now, here)
    if not ok then seen(nil, tostring(err)) wanted = {} st.state, st.msg, nextAsk = 'off', unavailable(err), now + M.RETRY_S end
    return
  end
  if now >= nextAsk then
    if st.state == 'off' then st.state = 'searching' end
    local ok, err = start(string.format('/v1/near?lat=%.5f&lon=%.5f', lat, lon), 'near', nil, now, here)
    if not ok then
      seen(nil, tostring(err))
      st.state, st.msg = 'off', unavailable(err)
      nextAsk = now + M.RETRY_S
    end
  end
end

function M._reset()
  close()
  st = { state = 'off', loading = 0, ready = 0 }
  nextAsk, wanted, got = 0, {}, {}
  nearCell, socket, nextCameras, queue, clockNow = nil, nil, 0, {}, 0
  for _, lane in ipairs({ fastLane, tileLane }) do
    if lane.cur then local sk = lane.cur.sock pcall(function() sk:close() end) end
    lane.cur, lane.queue = nil, {}
  end
  M.enabled, M.PORT = true, M.DEFAULT_PORT
end

return M
