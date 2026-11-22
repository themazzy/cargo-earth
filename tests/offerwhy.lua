-- Why no order comes: each reason in order of what explains an empty offer list first.
local why = require('cargoEarth/offerwhy')
local n = 0
local function check(i, code, text)
  local r = why.reason(i)
  assert(r and r.code == code, code .. ' expected, got ' .. tostring(r and r.code))
  if text then assert(r.text:find(text, 1, true), r.text) end
  assert(r.log:find('[' .. code .. ']', 1, true), r.log)
  n = n + 1
  return r
end
local van = { tier = 'van', model = 'van', bodyStyle = 'Van', containers = 2, free = { parcel = 24, fluid = 0, dryBulk = 0 } }
local stats = { pickups = 5, pairs = 3, noDest = 0 }
assert(why.reason({ mode = 'trucking', offers = 2 }) == nil, 'offers there: nothing to explain')
local r = check({ mode = 'trucking', vehicle = { hint = 'This vehicle counts as a car (body style Bus)', tier = 'car', model = 'capsule',
  bodyStyle = 'Bus', containers = 1, free = { parcel = 12, fluid = 0, dryBulk = 0 } }, helperNeeded = true,
  helper = { state = 'off' }, helperText = 'not running' }, 'vehicle', 'counts as a car')
assert(r.log:find('model', 1, true) == nil and r.log:find('capsule', 1, true) and r.log:find('free parcel 12', 1, true), r.log)
check({ mode = 'trucking', vehicle = van, helperNeeded = true, helper = { state = 'off' },
  helperText = 'The Cargo Earth helper is not running (nothing on port 47821).' }, 'helper', 'not running')
check({ mode = 'trucking', vehicle = van, helperNeeded = true, helperOff = true }, 'helperOff', 'turned off')
check({ mode = 'trucking', vehicle = van, helperNeeded = true, data = true, helper = { state = 'loading', loading = 3 } },
  'loading', '3 areas left')
check({ mode = 'trucking', vehicle = van, helperNeeded = true, data = true, generated = true, stats = { pickups = 0 },
  helper = { state = 'error', msg = 'no internet' } }, 'helper', 'no internet')
check({ mode = 'trucking', vehicle = van, helperNeeded = false, helper = { state = 'off' }, helperText = 'down' }, 'noData')
check({ mode = 'trucking', vehicle = van, data = true }, 'searching')
r = check({ mode = 'trucking', vehicle = van, helperNeeded = true, data = true, generated = true, nearKm = 15,
  stats = { pickups = 0, pairs = 0 }, helper = { state = 'ready' } }, 'empty', 'No depots within 15 km')
assert(r.text:find('helper answered', 1, true) and r.log:find('data from helper', 1, true), r.log)
check({ mode = 'trucking', vehicle = van, data = true, generated = true, minKm = 50, maxKm = 80,
  stats = { pickups = 4, pairs = 0, noDest = 4 } }, 'filters', '50 km–80 km')
check({ mode = 'trucking', vehicle = van, data = true, generated = true, stats = stats }, 'fit', 'free room')
check({ mode = 'courier', foodRoom = 0, data = true }, 'room', 'boxes are full')
check({ mode = 'courier', helperNeeded = true, helper = { state = 'off' }, helperText = 'stopped answering' }, 'helper')
check({ mode = 'courier', data = true, generated = true, nearKm = 3, stats = { pickups = 0, reachKm = 3 } }, 'empty',
  'No restaurants within 3 km')
check({ mode = 'courier', data = true, generated = true, stats = { pickups = 6, noDest = 6, maxKm = 5 } }, 'filters')
print('Offer reasons: ' .. n .. ' cases (vehicle, helper down/off/loading/error, no data, nothing near, filters, room) passed')
