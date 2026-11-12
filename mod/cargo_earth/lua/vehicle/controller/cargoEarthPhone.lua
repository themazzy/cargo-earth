-- cargoEarthPhone: the phone in a holder on the dash (vehicle Lua, loaded by the Cargo Earth phone part's jbeam).
-- It opens the phone page as the screen's texture (a vehicle web view, the way navigation screens work), and turns
-- presses on the screen into clicks on the page. The screen is covered by a grid of the car's own cockpit triggers
-- (see the part's jbeam): pointing a VR controller (or the mouse) at a cell and pulling the trigger runs tap(col, row),
-- which clicks the middle of that cell on the page. The page asks the game for the phone's state itself
-- (beamng.sendEngineLua), and the game answers through queueWebViewJS.
local M = {}
M.type = 'auxiliary'

local tag, cols, rows = '@cargo_earth_phone', 6, 12

local function js(code)
  obj:queueWebViewJS(tag, code)
end

local function init(jbeamData)
  tag = jbeamData.webViewTag or tag
  cols = tonumber(jbeamData.cols) or cols
  rows = tonumber(jbeamData.rows) or rows
  local width = tonumber(jbeamData.width) or 580
  local height = tonumber(jbeamData.height) or 1120
  local fps = tonumber(jbeamData.fps) or 15
  local page = jbeamData.page or 'local://local/vehicles/common/cargo_earth_phone/phone.html'
  page = page .. '?vehicle=' .. tostring(obj:getId()) .. '&tag=' .. tag:gsub('@', '%%40')
  obj:createWebView(tag, page, width, height, 1, fps) -- 1 = automatic: redrawn up to fps times a second
  log('I', 'cargoEarthPhone', 'phone holder screen started: ' .. page)
  -- tell the game this car has its phone on the dash (Settings shows it running)
  obj:queueGameEngineLua(string.format('if cargoEarth_core and cargoEarth_core.dashPhonePart then cargoEarth_core.dashPhonePart(%d) end', obj:getId()))
end

-- a press on cell (col, row), counted from 1 at the top left
local function tap(col, row)
  col, row = tonumber(col), tonumber(row)
  if not col or not row then return end
  js(string.format('window.cargoEarthDash && cargoEarthDash.tap(%.4f, %.4f)', (col - 0.5) / cols, (row - 0.5) / rows))
end

-- the game's answer to one of the page's questions (id), already JSON
local function reply(id, json)
  js(string.format('window.cargoEarthDash && cargoEarthDash.reply(%d, %s)', tonumber(id) or 0, json or 'null'))
end

M.init = init
M.tap = tap
M.reply = reply

return M
