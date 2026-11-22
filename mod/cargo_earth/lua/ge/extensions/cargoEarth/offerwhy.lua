-- cargoEarth/offerwhy: why no food order or freight job is coming, in one short line for the phone's waiting screen
-- and a longer one for beamng.log. Pure rules: core gathers the facts, this module picks the first thing that explains
-- an empty offer list.
--
--   offerwhy.reason(i) -> nil (offers are there) or { code, text, log }
--
-- i = { mode = 'courier' | 'trucking', offers = n, generated = true once a search ran here, stats = the search's stats
--       ({ pickups, pairs, noDest }), data = true when the place data is loaded at all,
--       helperNeeded = the places here come from the helper (outside the built-in Czech data), helperOff = the helper
--       is turned off in settings, helper = helper.status(), helperText = helper.describe(now) (a sentence or nil),
--       vehicle = { hint = why this vehicle takes no freight (nil when it does), tier, model, bodyStyle, containers,
--       free = { parcel, fluid, dryBulk } }, foodRoom = free food slots (nil when unknown),
--       nearKm, minKm, maxKm = the search's reach and distance settings }
--
-- codes: 'vehicle' (this vehicle takes no such work), 'helperOff', 'helper' (not running, crashed, not answering,
-- errors), 'loading', 'noData', 'empty' (nothing within reach), 'filters' (places found, no destination within the
-- distance settings), 'fit' (routes found, nothing fits the free room), 'room' (food boxes full), 'searching'.
local M = {}

local function km(v) return v and string.format('%g km', math.floor(v * 10 + 0.5) / 10) or '?' end

local function vehicleLog(v)
  if not v then return '' end
  local free = v.free and string.format('free parcel %d, fluid %d, dry bulk %d', v.free.parcel or 0, v.free.fluid or 0,
    v.free.dryBulk or 0) or 'containers not read yet'
  return string.format('; vehicle %s, body style %s, class %s, %d containers, %s', tostring(v.model),
    tostring(v.bodyStyle), tostring(v.tier), v.containers or 0, free)
end

function M.reason(i)
  if (i.offers or 0) > 0 then return nil end
  local freight = i.mode == 'trucking'
  local places = freight and 'depots' or 'restaurants'
  local tail = freight and vehicleLog(i.vehicle) or ''
  local function out(code, text, detail)
    return { code = code, text = text, log = string.format('no %s offers [%s]: %s%s', freight and 'freight' or 'food',
      code, detail or text, tail) }
  end
  -- 1. the vehicle (freight): the phone already shows the hint under "Looking for orders"
  if freight and i.vehicle and i.vehicle.hint then return out('vehicle', i.vehicle.hint) end
  if not freight and i.foodRoom == 0 then return out('room', 'Your food boxes are full. Deliver what is on board first.') end
  -- 2. where the places come from: the helper, outside the built-in data
  if i.helperNeeded then
    if i.helperOff then
      return out('helperOff', 'The Cargo Earth helper is turned off in Settings, and there is no built-in data here.')
    end
    local h = i.helper or {}
    if h.state == 'off' and i.helperText then return out('helper', i.helperText) end
    if h.state == 'error' and (i.stats == nil or (i.stats.pickups or 0) == 0) then
      return out('helper', 'The helper could not load this area' .. (h.msg and (': ' .. tostring(h.msg)) or '.'))
    end
    if (h.state == 'loading' or h.state == 'searching') and (i.stats == nil or (i.stats.pickups or 0) == 0) then
      local n = h.loading or 0
      return out('loading', n > 0 and string.format('The helper is still loading %s around you (%d %s left).', places, n,
        n == 1 and 'area' or 'areas') or ('Asking the helper for ' .. places .. ' around you…'))
    end
  end
  if not i.data then
    return out('noData', i.helperNeeded and ('No ' .. places .. ' loaded yet: waiting for the helper.')
      or ('No ' .. places .. ' loaded yet.'))
  end
  -- 3. the search itself
  local s = i.stats
  if not i.generated or not s then return out('searching', 'Searching for ' .. (freight and 'freight' or 'orders') .. ' near you…') end
  if (s.pickups or 0) == 0 then
    local where = i.helperNeeded and ' The helper answered but found none in this area.' or ''
    return out('empty', string.format('No %s within %s of you.%s Drive somewhere busier or raise the pickup distance.',
      places, km(i.nearKm or s.reachKm), where),
      string.format('0 %s within %s (data from %s, helper %s)', places, km(i.nearKm or s.reachKm),
        i.helperNeeded and 'helper' or 'built-in pack', tostring(i.helper and i.helper.state)))
  end
  if freight and (s.pairs or 0) == 0 then
    return out('filters', string.format('%d %s nearby, but none ships to a place %s–%s away. Change the distance settings.',
      s.pickups, places, km(i.minKm), km(i.maxKm)),
      string.format('%d %s in reach, 0 routes within %s-%s (%d with no destination)', s.pickups, places, km(i.minKm),
        km(i.maxKm), s.noDest or 0))
  end
  if freight then
    return out('fit', string.format('%d routes nearby, but none fits this vehicle\'s free room.', s.pairs),
      string.format('%d %s in reach, %d routes, none fits', s.pickups, places, s.pairs))
  end
  return out('filters', string.format('%d restaurants nearby, but no customer within your distance settings.', s.pickups),
    string.format('%d restaurants in reach, %d with no customer within %s', s.pickups, s.noDest or 0, km(s.maxKm)))
end

return M
