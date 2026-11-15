-- cargoEarth/earthaddon: starts the Cargo Earth helper through BeamNG.Earth's own Add-ons page functions, so a player
-- whose helper is not running can start it from the phone (players had to find it on the Add-ons page and start it
-- by hand, 2026-11-16).
--
-- BeamNG.Earth runs the helper as a "companion" add-on (its server's addonrun.Runner). Its game side,
-- require('beamngEarth/addons') (BeamNG.Earth 1.9+, the Add-ons page's own functions), lists the add-ons
-- (uiState().addons: id, installed, running, autostart, consented, canInstall, status {state, text}), installs one
-- (install(id, agreed): the player agrees to the notice naming its author) and runs one (manage(id, 'start' |
-- 'autostart_on')). These are not part of beamngEarth_api, so every call is guarded: an Earth without them shows no
-- button.
--
--   earthaddon.state()       nil (no BeamNG.Earth add-on list, or the helper is not on it), or
--                            { installed, running, autostart, busy, text, error, canInstall, author }
--   earthaddon.start(now)    installs the helper when needed, starts it and turns on "Start with BeamNG.Earth"
--   earthaddon.tick(now)     the install finishing: start it then
local M = {}

M.ID = 'cargo-earth-helper'
M.INSTALL_WAIT_S = 90      -- an install this long without an installed copy: given up (its status says why)

local pending = nil        -- { at } an install asked for: start it once it is installed

-- BeamNG.Earth's add-on module, only when BeamNG.Earth has loaded it (never a second copy of it)
function M.addons()
  local a = package.loaded['beamngEarth/addons']
  if type(a) == 'table' and type(a.uiState) == 'function' and type(a.manage) == 'function' then return a end
  return nil
end

local function card()
  local a = M.addons()
  if not a then return nil end
  local ok, ui = pcall(a.uiState)
  if not ok or type(ui) ~= 'table' or type(ui.addons) ~= 'table' then return nil end
  for _, c in ipairs(ui.addons) do
    if type(c) == 'table' and c.id == M.ID then return c, a, ui end
  end
  return nil, a, ui
end

function M.state()
  local c, _, ui = card()
  if not c then return nil end
  local st = type(c.status) == 'table' and c.status or {}
  return { installed = c.installed == true, running = c.running == true, autostart = c.autostart == true,
    canInstall = c.canInstall == true, author = type(c.author) == 'string' and c.author or nil,
    busy = pending ~= nil or st.state == 'progress' or c.busy == true,
    text = type(st.text) == 'string' and st.text ~= '' and st.text or nil,
    error = st.state == 'error' and (type(st.text) == 'string' and st.text or 'failed') or nil,
    connected = ui.connected ~= false }
end

local function run(a)
  local ok1, started = pcall(a.manage, M.ID, 'start')
  -- (a player who pressed Start wants it running every time: "Start with BeamNG.Earth" on)
  pcall(a.manage, M.ID, 'autostart_on')
  if not ok1 then return false, tostring(started) end
  return started == true
end

-- true, or false and why
function M.start(now)
  local c, a = card()
  if not a then return false, 'BeamNG.Earth\'s add-on list is not available' end
  if not c then return false, 'the helper is not on BeamNG.Earth\'s add-on list (run CargoEarthSetup.exe)' end
  if c.running == true then return true end
  if c.installed == true then return run(a) end
  if type(a.install) ~= 'function' then return false, 'this BeamNG.Earth cannot install it from here' end
  -- the press is the player's agreement to the notice the phone shows (the helper by its author, beside the game)
  local ok, done, why = pcall(a.install, M.ID, true)
  if not ok then return false, tostring(done) end
  if not done then return false, why end
  pending = { at = now or 0 }
  return true
end

function M.tick(now)
  if not pending then return end
  local c, a = card()
  if c and c.installed == true and a then
    pending = nil
    run(a)
  elseif (now or 0) - pending.at > M.INSTALL_WAIT_S
      or (c and type(c.status) == 'table' and c.status.state == 'error') then
    pending = nil
  end
end

function M._reset() pending = nil end

return M
