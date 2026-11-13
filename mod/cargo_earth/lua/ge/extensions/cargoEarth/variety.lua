-- cargoEarth/variety: spread the pickups. At most two orders in a row from one place; after two, at least two orders
-- from other places before that place rings again. Pure Lua (no game calls), tested outside BeamNG.
local M = {}

M.IN_A_ROW = 2   -- orders from one place before it rests
M.BETWEEN = 2    -- orders from other places before it rings again
M.KEEP = 6       -- pickups remembered

-- The place a job is picked up at: a restaurant, a shop, a depot. nil when it has none.
function M.key(job)
  local from = type(job) == 'table' and job.from
  if type(from) ~= 'table' then return nil end
  local k = from.id or from.n
  return k ~= nil and tostring(k) or nil
end

-- Is place k resting? It is when it gave IN_A_ROW orders in a row and fewer than BETWEEN orders came from other
-- places since.
function M.resting(history, k)
  if k == nil or type(history) ~= 'table' then return false end
  local others, streak = 0, 0
  for i = #history, 1, -1 do
    if history[i] == k then
      streak = streak + 1
      if streak >= M.IN_A_ROW then return true end   -- fewer than BETWEEN others came after it
    else
      streak = 0
      others = others + 1
      if others >= M.BETWEEN then return false end   -- any older run has had its break
    end
  end
  return false
end

-- Remember an accepted order's pickup. Returns the (new or trimmed) history.
function M.note(history, job)
  history = type(history) == 'table' and history or {}
  local k = M.key(job)
  if not k then return history end
  history[#history + 1] = k
  while #history > M.KEEP do table.remove(history, 1) end
  return history
end

return M
