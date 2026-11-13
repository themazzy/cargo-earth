-- Puts the phone (and the Menu app) into BeamNG.Earth's UI layout (".Earth", type beamngEarth) the first time Cargo Earth runs, just
-- above the speedometer (tacho2, bottom right), so new players do not have to find the UI Apps editor. Only that
-- layout, only when the phone is not in it, and only once: a player who moves or removes the phone afterwards keeps
-- their choice. Uses the game's own layout extension (ui_appLayouts), so the file is written the way the editor
-- writes it.
local M = {}

M.TYPE = 'beamngEarth'
M.FLAG = '/settings/cargoEarth/layout.json'
-- Each app is added once (its own flag): the phone just above the speedometer (tacho2 in Earth's layout: bottom 5px,
-- right 5px, 300 x 300), and the Menu app (the Menu window's host, a small corner box) top left.
M.APPS = {
  { name = 'cargoEarthPhone', flag = 'phoneAdded',
    placement = { position = 'absolute', bottom = '310px', right = '5px', width = '290px', height = '540px' } },
  { name = 'cargoEarthMenu', flag = 'menuAdded',
    placement = { position = 'absolute', top = '0px', left = '0px', width = '24px', height = '24px' } },
}

local function hasApp(layout, name)
  for _, app in ipairs(type(layout.apps) == 'table' and layout.apps or {}) do
    if type(app) == 'table' and type(app.appName) == 'string' and app.appName:lower() == name:lower() then return true end
  end
  return false
end

-- api: { layouts = function() -> list, addApp = function(filename, appName, placement) -> bool,
--        current = function() -> layout or nil, setCurrent = function(filename) }
-- flag: { read = function() -> table or nil, write = function(table) }
-- Returns 'added', 'present', 'done' (already handled once), 'none' (no Earth layout) or nil (no layout API).
function M.ensure(api, flag)
  if not api then return nil end
  local seen = flag.read()
  seen = type(seen) == 'table' and seen or {}
  local todo = {}
  for _, app in ipairs(M.APPS) do if not seen[app.flag] then todo[#todo + 1] = app end end
  if #todo == 0 then return 'done' end
  local ok, list = pcall(api.layouts)
  if not ok or type(list) ~= 'table' then return nil end
  local target
  for _, layout in ipairs(list) do
    if type(layout) == 'table' and layout.type == M.TYPE and type(layout.filename) == 'string' then
      -- the type's own file (beamngEarth.uilayout.json) before any copy the player made
      if not target or layout.filename:match('/' .. M.TYPE .. '%.uilayout%.json$') then target = layout end
    end
  end
  if not target then return 'none' end
  local result = 'present'
  for _, app in ipairs(todo) do
    if not hasApp(target, app.name) then
      local placement = {}
      for k, v in pairs(app.placement) do placement[k] = v end
      local okAdd, added = pcall(api.addApp, target.filename, app.name, placement)
      if not okAdd or added == false then return nil end     -- tried again next time
      result = 'added'
    end
  end
  if result == 'added' then
    -- the layout on screen is this one: show the apps now, not after a reload
    local okCur, cur = pcall(api.current)
    if okCur and type(cur) == 'table' and cur.filename == target.filename then pcall(api.setCurrent, target.filename) end
  end
  for _, app in ipairs(todo) do seen[app.flag] = true end
  seen.result, seen.layout = result, target.filename
  flag.write(seen)
  return result
end

-- The game's adapter.
function M.gameApi()
  local ext = rawget(_G, 'ui_appLayouts')
  if not ext and extensions and extensions.load then
    pcall(extensions.load, 'ui_appLayouts')
    ext = rawget(_G, 'ui_appLayouts')
  end
  if not (ext and ext.getAvailableLayouts and ext.addApp) then return nil end
  return {
    layouts = ext.getAvailableLayouts,
    addApp = ext.addApp,
    current = ext.getCurrentLayout or function() return nil end,
    setCurrent = ext.setCurrentLayout or function() end,
  }
end

function M.gameFlag()
  return {
    read = function() return jsonReadFile and jsonReadFile(M.FLAG) or nil end,
    write = function(t) if jsonWriteFile then jsonWriteFile(M.FLAG, t, true) end end,
  }
end

return M
