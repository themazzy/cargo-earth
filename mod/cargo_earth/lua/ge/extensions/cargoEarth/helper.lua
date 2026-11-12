-- cargoEarth/helper: talks to the Cargo Earth helper (helper/cargo_earth_helper.py, a BeamNG.Earth add-on) on this
-- computer, which streams food pickups and customer addresses around the player. Game Lua may only open
-- connections to local addresses, so the helper does the downloading; this side asks it over plain HTTP with
-- non-blocking sockets (one request at a time, never waits in a frame).
--
--   helper.tick(lat, lon, now, onArea)   every frame or tick; onArea(data) gets each new area once
--   helper.status()                      { state = 'off' | 'searching' | 'loading' | 'ready' | 'error', loading, ready, msg }
-- tick also takes onCameras(data) (speed cameras around the player, asked for now and then) and onlyCameras (true
-- where the mod's own data pack covers everything else).
local M = {}

M.HOST, M.PORT = '127.0.0.1', 47820
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
  if port and port == math.floor(port) and port >= 1024 and port <= 65535 then M.PORT = port end
end

function M.status() return st end
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

local function start(path, what, key, now, requestCell)
  socket = socket or rawget(_G, 'socket')
  if not socket then
    local ok, loaded = pcall(require, 'socket')
    if not ok then return false, 'LuaSocket unavailable' end
    socket = loaded
  end
  local s = socket.tcp()
  if not s then return false, 'Could not create helper socket' end
  s:settimeout(0)
  local ok, err = s:connect(M.HOST, M.PORT)
  if not ok and err ~= 'timeout' and err ~= 'Operation already in progress' then
    pcall(function() s:close() end)
    return false, err
  end
  req = { sock = s, phase = 'send', t0 = now, what = what, key = key, cell = requestCell, buf = {}, bytes = 0,
    out = 'GET ' .. path .. ' HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n', sent = 0 }
  return true
end

-- the body of a finished HTTP response, or nil and why
local function parse(raw)
  local head, body = raw:match('^(.-)\r\n\r\n(.*)$')
  if not head then return nil, 'bad response' end
  local code = tonumber(head:match('^HTTP/%d%.%d (%d+)'))
  if code ~= 200 then return nil, 'HTTP ' .. tostring(code) end
  local ok, data = pcall(jsonDecode, body)
  if not ok or type(data) ~= 'table' then return nil, 'bad JSON' end
  return data
end

-- one step of the running request: nil while it runs, else (data) or (nil, err)
local function step(now)
  local s = req.sock
  if now - req.t0 > M.TIMEOUT_S then return nil, 'timeout' end
  if req.phase == 'send' then
    local n, err, last = s:send(req.out, req.sent + 1)
    if n then req.sent = n elseif err == 'timeout' then req.sent = last or req.sent
    elseif err == 'Socket is not connected' then return
    else return nil, err end
    if req.sent >= #req.out then req.phase = 'recv' end
    return
  end
  for _ = 1, M.READ_CHUNKS do
    local data, err, partial = s:receive(65536)
    local chunk = data or partial
    if chunk and #chunk > 0 then
      req.bytes = req.bytes + #chunk
      if req.bytes > M.MAX_RESPONSE then return nil, 'helper response exceeds size limit' end
      req.buf[#req.buf + 1] = chunk
    end
    if err == 'closed' then return parse(table.concat(req.buf)) end
    if err then
      if err ~= 'timeout' then return nil, err end
      return
    end
  end
end

local function finish(data, err, now, lat, lon, onArea)
  local r = req
  close()
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
    st.state, st.msg = 'off', 'Cargo Earth helper unavailable (' .. tostring(err) .. ')'
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

function M.tick(lat, lon, now, onArea, onCameras, onlyCameras)
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
    if ok then req.on = q[2] elseif q[2] then q[2](nil, tostring(err)) end
    return
  end
  if onCameras and now >= nextCameras then
    local ok = start(string.format('/v1/cameras?lat=%.5f&lon=%.5f', lat, lon), 'cameras', nil, now)
    if ok then req.on = onCameras else st.cameras, nextCameras = 'off', now + M.RETRY_S end
    return
  end
  if onlyCameras then return end
  local here = cell(lat, lon)
  -- Fetch the new neighbourhood before any queued cell from the previous location.
  if here ~= nearCell and st.state ~= 'off' then nextAsk = 0 wanted = {} end
  local k = here == nearCell and next(wanted) or nil
  if k then
    local ok, err = start('/v1/area?key=' .. k, 'area', k, now, here)
    if not ok then wanted = {} st.state, st.msg, nextAsk = 'off', tostring(err), now + M.RETRY_S end
    return
  end
  if now >= nextAsk then
    if st.state == 'off' then st.state = 'searching' end
    local ok, err = start(string.format('/v1/near?lat=%.5f&lon=%.5f', lat, lon), 'near', nil, now, here)
    if not ok then
      st.state, st.msg = 'off', 'Cargo Earth helper not running (' .. tostring(err) .. ')'
      nextAsk = now + M.RETRY_S
    end
  end
end

function M._reset()
  close()
  st = { state = 'off', loading = 0, ready = 0 }
  nextAsk, wanted, got = 0, {}, {}
  nearCell, socket, nextCameras, queue = nil, nil, 0, {}
  M.enabled, M.PORT = true, 47820
end

return M
