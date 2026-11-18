-- Independent distance profiles. Defaults describe normal jobs; editable limits are separate.
local M = {}
M.MAX_KM = 800
M.types = {
  {id = 'courier', name = 'Food and groceries', mode = 'courier'},
  {id = 'taxi', name = 'Taxi rides', mode = 'taxi'},
  {id = 'parts', name = 'Parts runs (SUV/pickup)', mode = 'trucking', legacyTier = 'suv'},
  {id = 'parcels', name = 'Parcel rounds (van)', mode = 'trucking', legacyTier = 'van'},
  {id = 'tow_light', name = 'Tow jobs (car trailer)', mode = 'trucking'},
  {id = 'tow_heavy', name = 'Tow jobs (flatbed trailer)', mode = 'trucking'},
  {id = 'fuel', name = 'Fuel station resupply', mode = 'trucking'},
  {id = 'freight_van', name = 'Freight: own van', mode = 'trucking', tier = 'van', legacyTier = 'van'},
  {id = 'freight_rigid', name = 'Freight: own box truck', mode = 'trucking', tier = 'rigid', legacyTier = 'rigid'},
  {id = 'freight_semi', name = 'Freight: own semi', mode = 'trucking', tier = 'semi', legacyTier = 'semi'},
  {id = 'company_van', name = 'Company contracts: van', mode = 'trucking', tier = 'van', company = true},
  {id = 'company_rigid', name = 'Company contracts: box truck', mode = 'trucking', tier = 'rigid', company = true},
  {id = 'company_semi', name = 'Company contracts: semi', mode = 'trucking', tier = 'semi', company = true},
  {id = 'bus', name = 'Mapped bus lines', mode = 'bus'},
}

function M.type(id)
  for _, t in ipairs(M.types) do if t.id == id then return t end end
end

function M.defaults(id)
  local t = M.type(id)
  if not t then return nil end
  if id == 'courier' then return require('cargoEarth/food').defaults end
  if id == 'taxi' then return require('cargoEarth/taxi').defaults end
  if id == 'bus' then return {} end -- mapped lines keep their actual routes
  if t.company then
    local range = require('cargoEarth/employment').KM[t.tier]
    return {nearKm = 25, minKm = range[1], maxKm = range[2]}
  end
  if t.tier then
    local tier = require('cargoEarth/haul').tiers[t.tier]
    return {nearKm = 30, minKm = tier.minKm, maxKm = tier.maxKm}
  end
  if id == 'parts' then return {nearKm = 15, minKm = 5.2, maxKm = 39} end
  if id == 'parcels' then return {nearKm = 20, minKm = 0.5, maxKm = 100} end
  if id == 'fuel' then return {nearKm = 40, minKm = 15, maxKm = 150} end
  return {nearKm = 8, minKm = 3.9, maxKm = 39} -- loaded tow leg, before borrowed-trailer legs
end

function M.bounds(id)
  if id == 'bus' then return {} end
  local max = id == 'courier' and 8 or id == 'taxi' and 15.6 or id == 'parcels' and 100 or M.MAX_KM
  return {nearKm = {0.5, id == 'courier' and 25 or 200}, minKm = {0.5, max}, maxKm = {0.5, max}}
end

local function finite(value)
  return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

function M.resolve(byMode, id)
  local t, defaults = M.type(id), M.defaults(id)
  if not t then return nil end
  local source = byMode[t.mode] or {}
  local saved = source.jobRanges and source.jobRanges[id]
  local legacy = {}
  if saved == nil then
    if id == 'courier' or id == 'taxi' then legacy = source
    elseif t.legacyTier then
      local range = source.freightRanges and source.freightRanges[t.legacyTier] or {}
      legacy = {nearKm = range.nearKm or source.nearKm,
        minKm = range.minKm or (t.legacyTier == 'semi' and source.minKm),
        maxKm = range.maxKm or (t.legacyTier == 'semi' and source.maxKm)}
      -- Older shared settings were restricted by these generators before use.
      if id == 'parts' then
        legacy.nearKm = math.min(tonumber(legacy.nearKm) or defaults.nearKm, defaults.nearKm)
        legacy.minKm = math.max(tonumber(legacy.minKm) or defaults.minKm, defaults.minKm)
        legacy.maxKm = math.min(tonumber(legacy.maxKm) or defaults.maxKm, defaults.maxKm)
      elseif id == 'parcels' then
        legacy.nearKm = math.min(tonumber(legacy.nearKm) or defaults.nearKm, defaults.nearKm)
      end
    elseif id == 'fuel' then legacy = {nearKm = source.nearKm} end
  end
  local out, bounds = {}, M.bounds(id)
  for _, key in ipairs({'nearKm', 'minKm', 'maxKm'}) do
    if bounds[key] then
      local value = saved and saved[key] or legacy[key]
      if not finite(value) then value = defaults[key] end
      out[key] = math.max(bounds[key][1], math.min(bounds[key][2], value))
    end
  end
  if out.minKm and out.minKm > out.maxKm then out.minKm = out.maxKm end
  return out
end

function M.set(byMode, id, values)
  local t, bounds = M.type(id), M.bounds(id)
  if not t or id == 'bus' or type(values) ~= 'table' then return false, 'Choose a generated job type.' end
  local out = {}
  for _, key in ipairs({'nearKm', 'minKm', 'maxKm'}) do
    local n = tonumber(values[key])
    if not finite(n) or n < bounds[key][1] or n > bounds[key][2] then
      return false, string.format('%s must be between %g and %g km.', key, bounds[key][1], bounds[key][2])
    end
    out[key] = n
  end
  if out.minKm > out.maxKm then return false, 'The shortest distance must not exceed the longest distance.' end
  byMode[t.mode] = byMode[t.mode] or {}
  local source = byMode[t.mode]
  source.jobRanges = source.jobRanges or {}
  source.jobRanges[id] = out
  return true
end

function M.reset(byMode, id)
  local t = M.type(id)
  if not t or id == 'bus' then return false end
  byMode[t.mode] = byMode[t.mode] or {}
  local source = byMode[t.mode]
  source.jobRanges = source.jobRanges or {}
  source.jobRanges[id] = {} -- explicit defaults override any older shared settings
  return true
end

return M
