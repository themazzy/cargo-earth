local dash = require('cargoEarth/dash')
local total = 0
local function test(name, fn)
  local ok, why = pcall(fn)
  assert(ok, name .. ': ' .. tostring(why))
  total = total + 1
  print('PASS ' .. name)
end

test('a car\'s phone holder is forgotten when it is respawned', function()
  dash.partCar(7)
  assert(dash.isPartCar(7) and not dash.isPartCar(8))
  dash.dropCar(7)
  assert(not dash.isPartCar(7), 'a respawn without the part forgets it')
end)

test('only cars with a holder offer one, and its state follows the car\'s parts', function()
  assert(dash.partName('pigeon') == 'cargo_earth_phone_pigeon' and dash.partName('covet') == nil and dash.partName(nil) == nil)
  assert(dash.state(nil).car == false)
  local st = dash.state({ id = 3, model = 'pigeon', slotPartMap = { ['/pigeon_mod/'] = 'cargo_earth_phone_pigeon' } })
  assert(st.supported and st.fitted and not st.running)
  dash.partCar(3)
  assert(dash.state({ id = 3, model = 'pigeon', slotPartMap = {} }).running)
  dash.forget()
  assert(not dash.isPartCar(3))
end)

print('Dash phone: ' .. total .. ' checks passed')
