-- Delivery ranks use the career's existing totals. Cargo milestones outlive the recent delivery history.
local food = require('cargoEarth/food')
local M = {}
local professional = { name = 'Professional', at = 30 }
M.DRIVER_RANK, M.DRIVER_AT = professional.name, professional.at

local ranks = {
  { name = 'Rookie', at = 0 },
  { name = 'Regular', at = 5 },
  { name = 'Experienced', at = 15 },
  professional,
  { name = 'Veteran', at = 60 },
}

local milestones = {
  { id = 'family', name = 'Family meal',
    detail = string.format('Deliver a family meal. It takes %d free slots in one box.', food.FAMILY_SLOTS) },
  { id = 'batch', name = 'Batched order',
    detail = 'Accept a second order while another is active, then deliver the second order.' },
  { id = 'grocery', name = 'Grocery run',
    detail = string.format('Deliver groceries. It takes %d free slots in one box and a store found by the helper.', food.GROCERY_SLOTS) },
}

local legacyOrderTypes = {
  ['Family meal'] = 'family',
  ['Weekly groceries'] = 'grocery',
  ['Pantry restock'] = 'grocery',
  ['Fresh food shop'] = 'grocery',
}

local function rankIndex(completed)
  for i = #ranks, 2, -1 do
    if completed >= ranks[i].at then return i end
  end
  return 1
end

local function markCargo(earned, kind, orderType, batched)
  if kind ~= 'food' then return end
  if orderType == 'family' or orderType == 'grocery' then earned[orderType] = true end
  if batched then earned.batch = true end
end

function M.restore(career)
  if type(career.cargoMilestones) == 'table' then return end
  local earned = {}
  if type(career.history) == 'table' then
    for _, row in ipairs(career.history) do
      if type(row) == 'table' then markCargo(earned, row.kind, row.orderType or legacyOrderTypes[row.cargo], row.batched) end
    end
  end
  career.cargoMilestones = earned
end

-- Called only when a delivery succeeds. Returns a rank name if this delivery reached it.
function M.complete(career, job)
  career.delivered = (tonumber(career.delivered) or 0) + 1
  M.restore(career)
  markCargo(career.cargoMilestones, job.kind, job.orderType, job.batched)
  local rank = ranks[rankIndex(career.delivered)]
  if career.delivered == rank.at then return rank.name end
end

function M.state(career)
  local completed = tonumber(career.delivered) or 0
  local index = rankIndex(completed)
  local nextRank = ranks[index + 1]
  local out = { rank = ranks[index].name, completed = completed, ruined = career.failed or 0,
    km = math.floor((career.km or 0) * 10 + 0.5) / 10, cargo = {} }
  if nextRank then out.nextRank, out.nextAt = nextRank.name, nextRank.at end
  local earned = career.cargoMilestones or {}
  for _, milestone in ipairs(milestones) do
    out.cargo[#out.cargo + 1] = { id = milestone.id, name = milestone.name, detail = milestone.detail,
      complete = earned[milestone.id] == true }
  end
  return out
end

return M
