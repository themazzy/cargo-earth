-- Courier packing rules. BeamNG parcel capacity is in slots, and payload is sent separately in kg.
local M = {}

local STARTER_BAG = { key = 'starter', capacity = 1 }
local PACKAGING_KG, MEAL_KG, EXTRA_KG = 0.2, 0.55, 0.25
local IMPACT = { Fragile = { 3.5, 5 }, Standard = { 4, 5.35 }, Sturdy = { 4.6, 6.4 } }
local FRAGILE_WORDS = { 'egg', 'soup', 'stew', 'cola', 'shake', 'iced tea', 'ayran', 'soda', 'cappuccino', 'latte',
  'juice', 'lemonade', 'kofola', 'sparkling water' }

function M.supports(job)
  return job.kind == 'food' or (job.haul ~= nil and (job.haul.kind == 'parcel' or job.special ~= nil))
end

function M.handling(job)
  if IMPACT[job.handling] then return job.handling end
  if job.haul and job.haul.kind == 'parcel' then
    if job.cargo == 'glassware' or job.cargo == 'electronics' then return 'Fragile' end
    if job.cargo == 'bricks' or job.cargo == 'car_parts' then return 'Sturdy' end
  end
  if job.orderType == 'grocery' then return job.cargoName == 'Pantry restock' and 'Sturdy' or 'Fragile' end
  for _, item in ipairs(job.items or {}) do
    local name = (item.name or ''):lower()
    for _, word in ipairs(FRAGILE_WORDS) do
      if name:find(word, 1, true) then return 'Fragile' end
    end
  end
  return 'Standard'
end

function M.condition(job)
  return math.max(0, math.min(100, tonumber(job.cargoCondition) or 100))
end

-- One qualifying jolt can damage a load. Repeated jolts can ruin it even below the crash threshold.
function M.shock(job, peak)
  local limits = IMPACT[M.handling(job)]
  if peak < limits[1] then return false end
  local loss = peak >= limits[2] and 100 or math.floor(12 + 43 * (peak - limits[1]) / (limits[2] - limits[1]))
  job.cargoCondition = math.max(0, M.condition(job) - loss)
  return true
end

function M.size(job)
  if job.cargoSlots and job.cargoKg then return job.cargoSlots, job.cargoKg end
  local meals, extras = 1, 0
  if job.items and job.items[1] then
    meals = math.max(1, tonumber(job.items[1].qty) or 1)
    for i = 2, #job.items do extras = extras + math.max(1, tonumber(job.items[i].qty) or 1) end
  end
  return math.ceil((meals + extras) / 2), PACKAGING_KG + meals * MEAL_KG + extras * EXTRA_KG
end

function M.boxes(rows)
  local boxes = {}
  for _, row in ipairs(rows) do
    local capacity = tonumber(row.capacity) or 0
    for _, kind in ipairs(row.cargoTypes or {}) do
      -- Leave other payloads alone when they are already using a box.
      if kind == 'parcel' and type(row.id) == 'number' and capacity >= 1 and (row.targetVolume or 0) <= 0 then
        local key = row.partPath and row.groupId and (row.partPath .. '|' .. row.groupId) or tostring(row.id)
        boxes[#boxes + 1] = { id = row.id, key = key, capacity = math.floor(capacity) }
        break
      end
    end
  end
  table.sort(boxes, function(a, b) return a.capacity == b.capacity and a.key < b.key or a.capacity < b.capacity end)
  return boxes
end

-- Keep a saved box assignment when it still fits. Otherwise use the tightest available box.
local function findBox(bins, slots, preferred)
  local best
  for _, bin in ipairs(bins) do
    if bin.free >= slots then
      if bin.box.key == preferred then return bin end
      if not best or bin.free < best.free then best = bin end
    end
  end
  return best
end

function M.layout(boxes, orders)
  local plan = { bins = {}, weights = {}, used = 0, reserved = 0, capacity = 0, free = 0, maxFree = 0, overflow = 0, kg = 0 }
  local available = #boxes == 0 and { STARTER_BAG } or boxes
  for _, box in ipairs(available) do
    plan.bins[#plan.bins + 1] = { box = box, free = box.capacity }
    plan.capacity = plan.capacity + box.capacity
  end
  -- If an older save has too much cargo, prioritize the orders already in the car.
  for _, phase in ipairs({ 'toDelivery', 'toPickup' }) do
    for _, order in ipairs(orders) do
      if order.job.kind == 'food' and order.phase == phase then
        local slots, kg = M.size(order.job)
        local loaded = phase == 'toDelivery'
        if loaded then plan.used = plan.used + slots else plan.reserved = plan.reserved + slots end
        local bin = findBox(plan.bins, slots, order.job.cargoBox)
        if bin then
          bin.free = bin.free - slots
          if loaded and bin.box.id then
            plan.weights[bin.box.id] = (plan.weights[bin.box.id] or 0) + kg
            plan.kg = plan.kg + kg
          end
        else
          plan.overflow = plan.overflow + slots
        end
      end
    end
  end
  for _, bin in ipairs(plan.bins) do
    plan.free = plan.free + bin.free
    plan.maxFree = math.max(plan.maxFree, bin.free)
  end
  return plan
end

function M.fit(plan, job)
  if not plan or plan.overflow > 0 then return nil end
  local slots = M.size(job)
  local bin = findBox(plan.bins, slots)
  return bin and bin.box
end

return M
