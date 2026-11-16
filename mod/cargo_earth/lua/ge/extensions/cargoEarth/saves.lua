-- Career save slots. Each career has a name and its own file (with persistence.lua's .pending/.backup copies beside it).
-- saves.json lists them; the first career keeps the old single save's file (career.json), so a save from before the
-- slots becomes "Career 1" without being copied anywhere. Free play is not a slot: it keeps only the player's settings,
-- in freeplay.json.
local M = {}

M.DIR = '/settings/cargoEarth/'
M.INDEX = M.DIR .. 'saves.json'
M.LEGACY = M.DIR .. 'career.json'
M.FREE = M.DIR .. 'freeplay.json'
M.SUFFIXES = { '', '.pending', '.backup1', '.backup2', '.legacy' }
M.NAME_MAX = 32
M.MAX = 20          -- careers on the list
M.MIGRATED_NAME = 'Career 1'   -- the save from before the slots (Jan)

local function blank() return { v = 1, next = 1, slots = {} } end

-- a career, not a free-play save (one that never started a career keeps nothing worth a slot)
-- legacy: a save from before the garage existed counts by its progress
function M.isCareer(c, legacy)
  if type(c) ~= 'table' then return false end
  local g = type(c.garage) == 'table' and c.garage or {}
  if g.started or c.employment then return true end
  return legacy == true and c.play ~= 'free' and ((tonumber(c.delivered) or 0) > 0 or type(c.home) == 'table' or type(c.firm) == 'table')
end

function M.cleanName(name)
  if type(name) ~= 'string' then return nil end
  name = name:gsub('[%c]', ' '):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
  if name == '' then return nil end
  if #name > M.NAME_MAX then
    name = name:sub(1, M.NAME_MAX)
    -- not in the middle of a multi-byte letter (č, ř, ...)
    local i = #name
    while i > 1 and name:byte(i) >= 0x80 and name:byte(i) < 0xC0 do i = i - 1 end
    local lead = name:byte(i)
    local len = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or lead >= 0xC0 and 2 or 1
    if i + len - 1 > #name then name = name:sub(1, i - 1) end
    name = name:gsub(' $', '')
  end
  return name
end

function M.find(idx, id)
  id = tonumber(id)
  for i, s in ipairs(idx and idx.slots or {}) do if s.id == id then return s, i end end
end

-- The name the New career field starts with: the first "Career N" not taken.
function M.suggestName(idx)
  local taken = {}
  for _, s in ipairs(idx.slots) do taken[s.name:lower()] = true end
  local n = #idx.slots + 1
  while taken[('career ' .. n)] do n = n + 1 end
  return 'Career ' .. n
end

function M.full(idx) return #idx.slots >= M.MAX end

local function pathTaken(idx, path)
  for _, s in ipairs(idx.slots) do if s.path == path then return true end end
  return false
end

-- A new slot: career.json when it is free, else career-<n>.json. Not written; the caller writes the index.
function M.create(idx, name, now)
  local id = math.max(tonumber(idx.next) or 1, 1)
  local path = M.LEGACY
  local n = id
  while pathTaken(idx, path) do
    path = M.DIR .. 'career-' .. n .. '.json'
    n = n + 1
  end
  local slot = { id = id, name = M.cleanName(name) or M.suggestName(idx), path = path, created = now }
  idx.slots[#idx.slots + 1] = slot
  idx.next, idx.last = id + 1, id
  return slot
end

function M.remove(idx, id)
  local slot, i = M.find(idx, id)
  if not slot then return nil end
  table.remove(idx.slots, i)
  if idx.last == slot.id then idx.last = nil end
  return slot
end

local function valid(idx)
  if type(idx) ~= 'table' or type(idx.slots) ~= 'table' then return false end
  for _, s in ipairs(idx.slots) do
    if type(s) ~= 'table' or type(s.id) ~= 'number' or type(s.name) ~= 'string' or type(s.path) ~= 'string'
      or s.path:sub(1, #M.DIR) ~= M.DIR then return false end
  end
  return true
end

-- The list of careers. Without saves.json, a save from before the slots (career.json) becomes the first career; a
-- free-play save there is only read for the player's settings. Returns the index, whether it must be written, and the
-- free-play save to take settings from (or nil).
-- load(path) -> career, message: persistence.load; exists(path) -> bool or nil when the game cannot tell
function M.open(reader, load, exists, now)
  local ok, idx = pcall(reader, M.INDEX)
  if ok and valid(idx) then
    idx.next = math.max(tonumber(idx.next) or 1, 1)
    for _, s in ipairs(idx.slots) do idx.next = math.max(idx.next, s.id + 1) end
    if idx.last and not M.find(idx, idx.last) then idx.last = nil end
    return idx, false
  end
  idx = blank()
  local old, why = load(M.LEGACY)
  if old and not M.isCareer(old, true) then return idx, false, old end
  if old or why or exists(M.LEGACY) then
    -- a career, or a save that cannot be read (left as it is, the slot says so when it is picked)
    local slot = M.create(idx, M.MIGRATED_NAME, now)
    slot.path = M.LEGACY
    return idx, true
  end
  return idx, false
end

function M.write(writer, idx)
  local ok, written = pcall(writer, M.INDEX, idx, false, nil, true)
  return ok and written and true or false
end

-- What the list shows about a career (read from the save, or the running career).
function M.summary(c)
  if type(c) ~= 'table' then return { unreadable = true } end
  local g = type(c.garage) == 'table' and c.garage or {}
  return {
    money = tonumber(c.money) or 0,
    car = type(g.car) == 'table' and (g.car.name or g.car.model) or nil,
    savedAt = tonumber(c.savedAt),
    hours = math.floor((tonumber(c.activeSeconds) or 0) / 360 + 0.5) / 10,
    delivered = tonumber(c.delivered) or 0,
  }
end

return M
