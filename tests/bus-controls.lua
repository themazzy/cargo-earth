-- Native bus-door observation and the actual upper overlay, with game rendering stubbed.
local savedController, savedObj, savedUi = controller, obj, ui_imgui
local opened, events = false, {}
controller = {getControllerSafe = function() return {getState = function() return {bus_doorsRequestedOpen = opened} end} end}
obj = {getID = function() return 7 end, queueGameEngineLua = function(_, command) events[#events + 1] = command end}
local doors = dofile('mod/cargo_earth/lua/vehicle/extensions/cargoEarth/busdoors.lua')
doors.watch(42)
doors.updateGFX(0.11)
assert(#events == 0, 'an initial closed snapshot must not cancel a phone boarding request')
opened = true
doors.updateGFX(0.11)
assert(#events == 1 and events[1]:find('7, 42, true', 1, true))
doors.updateGFX(0.11)
assert(#events == 1, 'holding the door open never duplicates boarding')
doors.onReset()
doors.updateGFX(0.11)
assert(#events == 2, 'the reset bus reports its doors again')
doors.watch(nil)
doors.updateGFX(1)
assert(#events == 2)
controller, obj = savedController, savedObj

local texts, bars = {}, {}
local im = {
  GetIO = function() return {DisplaySize = {x = 1280}} end,
  ImVec2 = function(x, y) return {x = x, y = y} end,
  SetNextWindowPos = function() end, SetNextWindowSize = function() end, SetNextWindowBgAlpha = function() end,
  Begin = function() return true end, End = function() end,
  TextUnformatted = function(text) texts[#texts + 1] = text end,
  ProgressBar = function(frac, size, label) bars[#bars + 1] = {frac = frac, label = label} end,
}
for _, flag in ipairs({'NoTitleBar', 'NoResize', 'NoMove', 'NoScrollbar', 'NoSavedSettings', 'NoInputs', 'NoFocusOnAppearing', 'AlwaysAutoResize'}) do
  im['WindowFlags_' .. flag] = 0
end
ui_imgui = im
local overlay = dofile('mod/cargo_earth/lua/ge/extensions/cargoEarth/ui.lua')
overlay.drawStop({bus = true, inZone = true, stopping = true, title = 'Passengers getting off and on',
  detail = '4 off, 8 on', frac = 0.5, leftS = 7})
assert(texts[1] == 'Passengers getting off and on' and texts[2] == '4 off, 8 on')
assert(#bars == 1 and bars[1].frac == 0.5 and bars[1].label == '7 s')
texts, bars = {}, {}
overlay.drawStop({bus = true, inZone = true, stopping = false, title = 'Open doors: O or phone'})
assert(texts[1] == 'Open doors: O or phone' and #bars == 0, 'no one-second freight countdown at a bus stop')
ui_imgui = savedUi
print('Bus controls: native door changes, reset, boarding overlay and waiting hint verified')
