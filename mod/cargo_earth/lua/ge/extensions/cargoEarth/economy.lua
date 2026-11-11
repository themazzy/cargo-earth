-- One ledger for new settlements. Reconcile also records balance changes made by legacy garage code.
local M = { LIMIT = 100 }

local function sequence(id)
  return type(id) == 'string' and tonumber(id:match('^[%a_%-]+:(%d+)$')) or nil
end

function M.restore(c)
  c.accounts = c.accounts or { balance = c.money or 0, sequence = 0, history = {}, settled = {} }
  local a = c.accounts
  a.history, a.settled = a.history or {}, a.settled or {}
  a.sequence = a.sequence or 0
  if a.balance == nil then a.balance = c.money or 0 end
  return a
end

function M.nextId(c, prefix)
  local a = M.restore(c)
  a.sequence = a.sequence + 1
  return (prefix or 'transaction') .. ':' .. a.sequence
end

local function record(c, amount, kind, id, detail)
  local a = M.restore(c)
  table.insert(a.history, 1, { id = id, amount = amount, category = kind, detail = detail,
    balance = c.money or 0, at = c.activeSeconds or 0, date = os.date('%Y-%m-%d %H:%M') })
  while #a.history > M.LIMIT do table.remove(a.history) end
  a.balance = c.money or 0
end

function M.reconcile(c, kind, detail)
  local a = M.restore(c)
  local change = (c.money or 0) - a.balance
  if change ~= 0 then record(c, change, kind or 'adjustment', M.nextId(c), detail) end
end

function M.post(c, amount, kind, id, detail)
  if type(amount) ~= 'number' or amount ~= amount or amount == math.huge or amount == -math.huge
    or amount ~= math.floor(amount) or type(id) ~= 'string' then return false end
  local a = M.restore(c)
  if M.isSettled(c, id) then return false end
  M.reconcile(c)
  c.money = (c.money or 0) + amount
  a.settled[id] = true
  record(c, amount, kind, id, detail)
  return true
end

function M.isSettled(c, id)
  local a, n = M.restore(c), sequence(id)
  return a.settled[id] == true or (n ~= nil and n <= (a.settledThrough or 0))
end

-- All internally allocated IDs use one monotonic sequence. Keep old replay protection as a
-- watermark, retaining individual identities only above the oldest still-open settlement.
function M.compact(c)
  local a = M.restore(c)
  local floor = a.sequence
  local function open(id)
    local n = sequence(id)
    if n then floor = math.min(floor, n - 1) end
  end
  for _, o in ipairs(c.orders or {}) do if o.data then open(o.data.paymentId) end end
  if c.employment and c.employment.phase ~= 'settled' then open(c.employment.id) end
  a.settledThrough = math.max(a.settledThrough or 0, floor)
  for id in pairs(a.settled) do
    local n = sequence(id)
    if n and n <= a.settledThrough then a.settled[id] = nil end
  end
end

return M
