local profiles = require('cargoEarth/jobSettings')
local haul = require('cargoEarth/haul')
local jobs = require('cargoEarth/jobs')
local employment = require('cargoEarth/employment')
local function equal(a, b)
  for _, k in ipairs({'nearKm', 'minKm', 'maxKm'}) do
    assert(a[k] == b[k] or (a[k] and b[k] and math.abs(a[k] - b[k]) < 1e-8), k .. ': ' .. tostring(a[k]))
  end
end

local options = {}
for _, item in ipairs(profiles.types) do
  equal(profiles.resolve(options, item.id), profiles.defaults(item.id))
end
assert(profiles.set(options, 'freight_rigid', {nearKm = 40, minKm = 600, maxKm = 800}))
equal(profiles.resolve(options, 'freight_rigid'), {nearKm = 40, minKm = 600, maxKm = 800})
equal(profiles.resolve(options, 'company_rigid'), profiles.defaults('company_rigid'))
equal(profiles.resolve(options, 'freight_van'), profiles.defaults('freight_van'))
assert(profiles.set(options, 'company_rigid', {nearKm = 10, minKm = 80, maxKm = 100}))
for _, values in ipairs({
  {nearKm = 40, minKm = 801, maxKm = 800}, {nearKm = 40, minKm = 20, maxKm = 801},
  {nearKm = 201, minKm = 20, maxKm = 800}, {nearKm = 0/0, minKm = 20, maxKm = 800},
  {nearKm = 40, minKm = math.huge, maxKm = 800}, {},
}) do
  assert(not profiles.set(options, 'freight_rigid', values))
  equal(profiles.resolve(options, 'freight_rigid'), {nearKm = 40, minKm = 600, maxKm = 800})
end
assert(not profiles.set(options, 'bus', {nearKm = 1, minKm = 1, maxKm = 10}))
assert(not profiles.set(options, 'unknown', {}))
assert(profiles.reset(options, 'freight_rigid'))
equal(profiles.resolve(options, 'freight_rigid'), profiles.defaults('freight_rigid'))
equal(profiles.resolve(options, 'company_rigid'), {nearKm = 10, minKm = 80, maxKm = 100})

local legacy = {trucking = {nearKm = 30, minKm = 50, maxKm = 200,
  freightRanges = {rigid = {minKm = 25, maxKm = 100}, suv = {minKm = 5, maxKm = 40}}}}
equal(profiles.resolve(legacy, 'freight_semi'), {nearKm = 30, minKm = 50, maxKm = 200})
equal(profiles.resolve(legacy, 'freight_rigid'), {nearKm = 30, minKm = 25, maxKm = 100})
equal(profiles.resolve(legacy, 'parts'), profiles.defaults('parts'))
assert(profiles.reset(legacy, 'freight_semi'))
equal(profiles.resolve(legacy, 'freight_semi'), profiles.defaults('freight_semi'))
equal(profiles.resolve(legacy, 'company_semi'), profiles.defaults('company_semi'))

-- A distant-data fixture proves the increased ceiling reaches both generators.
local idx = jobs.index({depots = {
  {id = 'yard', n = 'Warehouse', t = 'producer', s = 'M', g = {50, 14}},
  {id = 'far1', n = 'Far One', t = 'receiver', s = 'M', g = {55, 14}},
  {id = 'far2', n = 'Far Two', t = 'receiver', s = 'M', g = {55.2, 14}},
}, cargo = {pallets_general = {name = 'General goods', pay = 1, trailer = 'box'}}, trailers = {},
  types = {producer = {produces = {'pallets_general'}}, receiver = {accepts = {'pallets_general'}}}})
local rows = {{id = 1, cargoTypes = {'parcel'}, capacity = 640}}
local range = {nearKm = 30, minKm = 600, maxKm = 800}
local opts = haul.options('rigid', range, rows)
assert(opts.minKm == 600 and opts.maxKm == 800)
local seed = 19
local offers = jobs.generate(idx, opts, 50, 14, function(n) seed = (seed * 16807.0) % 2147483647 return seed % n + 1 end)
assert(#offers == 2 and offers[1].km >= 600 and offers[1].km <= 800)
assert(#employment.board(idx, {lat = 50, lon = 14}, 'rigid') == 0)
local board = employment.board(idx, {lat = 50, lon = 14}, 'rigid', {rigid = range})
assert(#board == 1 and board[1].tier == 'rigid')
for _, j in ipairs(board[1].jobs) do assert(j.km >= 600 and j.km <= 800) end
print('Job settings: defaults, independent profiles, validation, legacy migration, reset and 600-800 km generators passed')
