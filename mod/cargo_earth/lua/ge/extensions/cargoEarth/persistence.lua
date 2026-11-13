-- Atomic JSON checkpoints. Validate before vehicle restoration and verify the entire written snapshot.
local M = { VERSION = 4 }

local function finite(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end
local function optional(t, key, kind) return t[key] == nil or type(t[key]) == kind end
local function point(p)
  return type(p) == 'table' and finite(p[1]) and finite(p[2]) and math.abs(p[1]) <= 90 and math.abs(p[2]) <= 180
end
local function car(c)
  return type(c) == 'table' and type(c.model) == 'string' and c.model ~= ''
    and optional(c, 'config', 'table') and optional(c, 'parts', 'table')
end
local function garage(g)
  if type(g) ~= 'table' or not optional(g, 'started', 'boolean') or not optional(g, 'inventory', 'table') or not optional(g, 'parked', 'table') then return false end
  if g.car ~= nil and not car(g.car) then return false end
  for _, parked in ipairs(g.parked or {}) do if not car(parked) then return false end end
  return g.debt == nil or (finite(g.debt) and g.debt >= 0)
end
local function job(j)
  if not (type(j) == 'table' and type(j.id) == 'string'
    and type(j.from) == 'table' and point(j.from.g) and type(j.to) == 'table' and point(j.to.g)
    and finite(j.pay) and j.pay >= 0 and finite(j.minutes) and j.minutes > 0) then return false end
  for _, key in ipairs({'startedActive', 'startedAt', 'km', 'pickupKm'}) do if j[key] ~= nil and not finite(j[key]) then return false end end
  if j.cargoCondition ~= nil and (not finite(j.cargoCondition) or j.cargoCondition < 0 or j.cargoCondition > 100) then return false end
  if j.haul ~= nil then
    local h = j.haul
    if type(h) ~= 'table' or (h.tier ~= 'van' and h.tier ~= 'rigid' and h.tier ~= 'semi')
      or not finite(h.amount) or h.amount <= 0 or not finite(h.density) or h.density <= 0 then return false end
  end
  return true
end
local phases = {preparing = true, working = true, returning = true, settled = true}
local function valid(c)
  if type(c) ~= 'table' or not finite(c.money) then return false end
  if c.garage ~= nil and not garage(c.garage) then return false end
  for _, key in ipairs({'history', 'companies', 'options'}) do if not optional(c, key, 'table') then return false end end
  for _, company in pairs(c.companies or {}) do
    if type(company) ~= 'table' or not finite(company.reputation) or not finite(company.shifts) or not finite(company.deliveries) then return false end
  end
  if c.activeSeconds ~= nil and (not finite(c.activeSeconds) or c.activeSeconds < 0) then return false end
  if c.home ~= nil and (type(c.home) ~= 'table' or not point(c.home.g) or not finite(c.home.capacity) or c.home.capacity < 1) then return false end
  if c.accounts ~= nil then
    local a = c.accounts
    if type(a) ~= 'table' or not optional(a, 'history', 'table') or not optional(a, 'settled', 'table') then return false end
    for _, key in ipairs({'balance', 'sequence', 'settledThrough'}) do if a[key] ~= nil and not finite(a[key]) then return false end end
    if a.sequence and (a.sequence < 0 or a.sequence ~= math.floor(a.sequence)) then return false end
    if a.settledThrough and (a.settledThrough < 0 or a.settledThrough > (a.sequence or 0)) then return false end
  end
  if c.orders ~= nil then
    if type(c.orders) ~= 'table' or #c.orders > 3 then return false end
    for _, o in ipairs(c.orders) do
      if type(o) ~= 'table' or not job(o.data) or (o.phase ~= 'toPickup' and o.phase ~= 'toDelivery') then return false end
    end
  end
  if c.job ~= nil and (type(c.job) ~= 'table' or not job(c.job.data)) then return false end
  if c.employment ~= nil then
    local s = c.employment
    if type(s) ~= 'table' or not phases[s.phase] or type(s.id) ~= 'string' or type(s.companyId) ~= 'string'
      or type(s.companyName) ~= 'string' or type(s.jobs) ~= 'table' or #s.jobs ~= 2
      or not finite(s.index) or s.index < 1 or s.index > 3 or s.index ~= math.floor(s.index)
      or not finite(s.completed) or s.completed < 0 or s.completed > 2 or not finite(s.gross) or s.gross < 0
      or type(s.yard) ~= 'table' or not point(s.yard.g) then return false end
    if not optional(s, 'ownerOperator', 'boolean') or (s.share ~= nil and (not finite(s.share) or s.share < 0 or s.share > 1)) then return false end
    for _, key in ipairs({'failed', 'quality', 'vehicleDamage'}) do
      if s[key] ~= nil and (not finite(s[key]) or s[key] < 0) then return false end
    end
    if s.failed and (s.failed ~= math.floor(s.failed) or s.failed + s.completed > #s.jobs) then return false end
    if s.ownerOperator and not garage(c.garage) then return false end
    if not s.ownerOperator and not garage(s.personalGarage) then return false end
    for _, j in ipairs(s.jobs) do if not job(j) then return false end end
  end
  return true
end
M.valid = valid

local function read(reader, path)
  local ok, c = pcall(reader, path)
  return ok and valid(c) and c or nil
end

function M.load(reader, path)
  for _, suffix in ipairs({'', '.backup1', '.backup2', '.legacy'}) do
    local ok, c = pcall(reader, path .. suffix)
    if ok and type(c) == 'table' and (tonumber(c.schemaVersion) or 1) > M.VERSION then
      return nil, 'This career was saved by a newer Cargo Earth version.'
    end
    if ok and valid(c) then return c, suffix ~= '' and 'Recovered career from ' .. suffix:sub(2) .. '.' or nil end
  end
end

local function same(a, b, depth)
  if type(a) ~= type(b) then return false end
  if type(a) == 'number' then return a == b or (finite(a) and finite(b) and math.abs(a - b) <= 1e-10 * math.max(1, math.abs(a))) end
  if type(a) ~= 'table' then return a == b end
  if depth > 100 then return false end
  for key, value in pairs(a) do if not same(value, b[key], depth + 1) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function write(writer, reader, path, c)
  -- compact JSON: the game's pretty printer is several times slower, and a save runs on accept, pickup and delivery
  local ok, written = pcall(writer, path, c, false, nil, true)
  if not ok or not written then return false end
  local check = read(reader, path)
  return check ~= nil and check.money == c.money and same(c, check, 0)
end

local function snapshot(c)
  if not c.employment or not c.employment.ownerOperator then return c end
  local out, shift = {}, {}
  for k, v in pairs(c) do out[k] = v end
  for k, v in pairs(c.employment) do shift[k] = v end
  shift.personalGarage = nil -- already stored at the root; reconnected on load
  out.employment = shift
  return out
end

-- Backups rotate at most this often (seconds of play), so an ordinary save is two file writes, not four.
-- A save happens on every accept, pickup and delivery; rotating every time made each one stutter.
M.BACKUP_EVERY_S = 300

function M.save(writer, reader, path, c)
  if not valid(c) then return false end
  local previousRevision, previousBackupAt = c.writeRevision, c.backupAt
  c.schemaVersion, c.writeRevision = M.VERSION, (c.writeRevision or 0) + 1
  local now = tonumber(c.activeSeconds) or 0
  local rotate = type(c.backupAt) ~= 'number' or now - c.backupAt >= M.BACKUP_EVERY_S or now < c.backupAt
  if rotate then c.backupAt = now end
  local function fail() c.writeRevision, c.backupAt = previousRevision, previousBackupAt return false end
  local out = snapshot(c)
  if not write(writer, reader, path .. '.pending', out) then return fail() end
  if rotate then
    local old = read(reader, path)
    if old then
      if (tonumber(old.schemaVersion) or 1) < M.VERSION and not read(reader, path .. '.legacy') then
        if not write(writer, reader, path .. '.legacy', old) then return fail() end
      end
      local prior = read(reader, path .. '.backup1')
      if prior and not write(writer, reader, path .. '.backup2', prior) then return fail() end
      if not write(writer, reader, path .. '.backup1', old) then return fail() end
    end
  end
  if not write(writer, reader, path, out) then return fail() end
  return true
end

return M
