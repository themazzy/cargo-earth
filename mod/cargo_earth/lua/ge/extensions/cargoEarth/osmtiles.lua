-- cargoEarth/osmtiles: the phone's OSM map tiles, fetched by the game from the helper and handed to the phone.
-- BeamNG's UI browser cancels the phone's own requests to the helper (127.0.0.1), so the phone asks the game:
-- get(z, x, y) answers { state = 'loading' } until the helper answered, then { state = 'ok', b64 = <the tile as
-- base64> } or { state = 'error', err }. Finished tiles stay a little while, so every phone on screen gets them.
local M = {}

M.KEEP_S = 20        -- a finished tile is handed out this long (the phones ask again within a fraction of a second)
M.MAX_KEPT = 16      -- finished tiles kept at most (the oldest go first)
M.MAX_LOADING = 6    -- tiles asked of the helper at once

local tiles = {}     -- 'z/x/y' -> { state, b64, err, at }
local clock = 0

local function prune(now)
  local done = {}
  for k, t in pairs(tiles) do
    if t.state ~= 'loading' then
      if now - t.at > M.KEEP_S then tiles[k] = nil else done[#done + 1] = k end
    elseif now - t.at > 60 then
      tiles[k] = nil    -- the helper lane dropped it without an answer: ask again
    end
  end
  if #done > M.MAX_KEPT then
    table.sort(done, function(a, b) return tiles[a].at < tiles[b].at end)
    for i = 1, #done - M.MAX_KEPT do tiles[done[i]] = nil end
  end
end

local function loading()
  local n = 0
  for _, t in pairs(tiles) do if t.state == 'loading' then n = n + 1 end end
  return n
end

local function int(v) v = tonumber(v) return v and v == math.floor(v) and v >= 0 and v < 2 ^ 20 and v or nil end

-- helper: the cargoEarth/helper module (tile lane), now: the game clock
function M.get(helper, z, x, y, now)
  clock = now or clock
  z, x, y = int(z), int(x), int(y)
  if not (z and x and y) then return { state = 'error', err = 'bad tile' } end
  prune(clock)
  local key = z .. '/' .. x .. '/' .. y
  local t = tiles[key]
  if t then return { state = t.state, b64 = t.b64, err = t.err } end
  if not helper.enabled then return { state = 'error', err = 'the helper is turned off' } end
  if loading() >= M.MAX_LOADING then return { state = 'loading' } end
  t = { state = 'loading', at = clock }
  local queued = helper.tile(string.format('/v1/osm/tile?z=%d&x=%d&y=%d&as=b64', z, x, y), function(body, err)
    t.at = clock
    if type(body) == 'string' and #body > 0 and not body:find('[^%w%+/=]') then
      t.state, t.b64 = 'ok', body
    elseif type(body) == 'string' and #body == 0 then
      t.state, t.b64 = 'ok', ''          -- an empty tile (open sea, nothing there)
    else
      t.state, t.err = 'error', tostring(err or 'a broken answer')
    end
  end)
  if queued then tiles[key] = t end
  return { state = 'loading' }
end

function M._reset() tiles, clock = {}, 0 end

return M
