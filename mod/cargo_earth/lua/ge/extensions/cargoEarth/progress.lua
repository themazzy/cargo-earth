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

-- What each rank opens, for the Progress page (only the Professional rank unlocks anything: the firm).
M.RANK_PERKS = { Professional = 'Lets you found your own firm (with 4.0 stars and 6,000 CZK).' }

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
  out.ranks = {}
  for _, r in ipairs(ranks) do
    out.ranks[#out.ranks + 1] = { name = r.name, at = r.at, perk = M.RANK_PERKS[r.name], reached = completed >= r.at }
  end
  local earned = career.cargoMilestones or {}
  for _, milestone in ipairs(milestones) do
    out.cargo[#out.cargo + 1] = { id = milestone.id, name = milestone.name, detail = milestone.detail,
      complete = earned[milestone.id] == true }
  end
  return out
end

-- Every kind of work, what it asks of you and whether you have it now, for the Progress page and the job tooltips
-- (issue #123). perHour: what a typical clean job earns an hour after fuel, from the career review of 2026-11-18
-- (docs/CAREER_ECONOMY.md, tools/career-economy.py); keep it in step when pay rules change.
-- facts: owned = { car = true, suv = true, ... } (the kinds of vehicle you own), firm = a firm with a headquarters,
-- firmReq = firm.requirements list, independent = 20 reputation with some company.
M.WORK = {
  { id = 'food', mode = 'courier', name = 'Food delivery', perHour = 500,
    what = 'Pick up a meal or groceries at a restaurant or shop and bring it to the customer before the timer runs out. Rough driving spoils food.',
    needs = 'Any car you own. Family meals and groceries need free slots in a cargo box.' },
  { id = 'taxi', mode = 'taxi', name = 'Taxi rides', perHour = 550,
    what = 'Pick up passengers near you and take them to a station, airport, hotel or sight. Comfort riders pay for a smooth ride, rush riders for a quick one. A nicer car earns up to 45 % more.',
    needs = 'Your own car, SUV or van with a free passenger seat.' },
  { id = 'bus', mode = 'bus', name = 'City bus lines', perHour = 550,
    what = 'Take a lent city bus at the depot and drive a real line, stopping at every stop. The company pays when the line ends.',
    needs = 'Nothing: the bus is lent.' },
  { id = 'tow', mode = 'trucking', name = 'Tow jobs', perHour = 600,
    what = 'Load a broken-down car on a trailer and bring it to a workshop. Without a car trailer of your own you borrow one at the workshop first.',
    needs = 'A vehicle with a tow hitch. Your own car trailer (from your firm) saves the trip to borrow one.' },
  { id = 'company', mode = 'trucking', name = 'Company contracts', perHour = 630,
    what = 'Take a company van, box truck or tractor at its yard, make two deliveries and bring it back. The company pays the fuel and repairs and keeps a share.',
    needs = 'Nothing for the van. Box trucks after 5 van hauls, tractors after 10 box truck hauls.' },
  { id = 'parts', mode = 'trucking', name = 'Parts runs', perHour = 580, kind = 'suv',
    what = 'Load car parts at a parts supplier and bring them to a repair workshop.',
    needs = 'Your own SUV or pickup with cargo boxes.' },
  { id = 'parcel', mode = 'trucking', name = 'Parcel routes', perHour = 800, kind = 'van',
    what = 'Load parcels at a depot and drop them at 4 to 7 addresses in turn.',
    needs = 'Your own van with cargo boxes.' },
  { id = 'van', mode = 'trucking', name = 'Van freight', perHour = 720, kind = 'van',
    what = 'Carry goods from one company to another. Counts toward the box truck unlock.',
    needs = 'Your own van with cargo boxes.' },
  { id = 'rigid', mode = 'trucking', name = 'Box truck freight', perHour = 1150, kind = 'rigid', tier = 'rigid',
    what = 'Business shipping between companies. Counts toward the tractor unlock.',
    needs = 'Your own box truck with a cargo box, after 5 van hauls (own or company).' },
  { id = 'semi', mode = 'trucking', name = 'Tractor freight and tanker runs', perHour = 1400, kind = 'semi', tier = 'semi',
    what = 'Pull a trailer between companies, or bring fuel to real fuel stations. A trailer of your own firm pays 12 % more.',
    needs = 'Your own tractor, after 10 box truck hauls (own or company).' },
  { id = 'independent', mode = 'trucking', name = 'Independent contracts',
    what = 'Drive a company contract in your own vehicle and keep all the pay.',
    needs = '20 reputation with that company: about 2 clean contracts.' },
  { id = 'firm', name = 'Your firm',
    what = 'A headquarters at a real yard, with parking bays, a workshop, a fuel tank and a dispatch office to upgrade. It buys new vehicles and trailers.',
    needs = 'Professional rank (30 deliveries), 4.0 stars over 5 ratings, no debt and 6,000 CZK.' },
  { id = 'drivers', name = 'Hired drivers',
    what = 'Drivers work your parked vehicles while you play. After their wage they bring in about 100 CZK an hour in a car, 300 in a van, 500 in a box truck and 900 in a tractor.',
    needs = 'Your firm with a headquarters, 350 CZK per hire and a vehicle for each.' },
}

function M.workTypes(career, facts)
  facts = facts or {}
  local owned = facts.owned or {}
  local hauls = career.hauls or {}
  local van, rigid = hauls.van or 0, hauls.rigid or 0
  local VAN_GOAL, RIGID_GOAL = facts.vanGoal or 5, facts.rigidGoal or 10
  local out = {}
  for _, w in ipairs(M.WORK) do
    local ready, missing = true, nil
    if w.kind and not owned[w.kind] then
      ready, missing = false, ({ suv = 'You own no SUV or pickup.', van = 'You own no van.', rigid = 'You own no box truck.',
        semi = 'You own no tractor.' })[w.kind]
    end
    if w.tier == 'rigid' and van < VAN_GOAL then
      ready, missing = false, string.format('Van hauls: %d of %d.', van, VAN_GOAL)
    elseif w.tier == 'semi' and (van < VAN_GOAL or rigid < RIGID_GOAL) then
      ready, missing = false, van < VAN_GOAL and string.format('Van hauls: %d of %d.', van, VAN_GOAL)
        or string.format('Box truck hauls: %d of %d.', rigid, RIGID_GOAL)
    end
    if w.id == 'independent' and not facts.independent then
      ready, missing = false, 'No company trusts you that far yet.'
    elseif w.id == 'firm' and not facts.firm then
      ready = false
      for _, r in ipairs(facts.firmReq or {}) do
        if not r.done then missing = (missing and missing .. ' ' or '') .. r.label .. ': ' .. r.detail .. '.' end
      end
    elseif w.id == 'drivers' and not facts.firm then
      ready, missing = false, 'Found your firm first.'
    end
    out[#out + 1] = { id = w.id, mode = w.mode, name = w.name, what = w.what, needs = w.needs, perHour = w.perHour,
      ready = ready, missing = missing }
  end
  return out
end


return M
