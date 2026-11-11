-- cargoEarth/trailers: the job's trailer as a real BeamNG vehicle. It is spawned behind the player's truck at the
-- pickup (no lat/lon to game coordinate conversion needed: the player is standing at the gate), the player backs up
-- and couples it, and at the delivery the trailer has to be near the truck.
--
-- Model names are BeamNG's stock trailers; override them in /settings/cargoEarth/config.json:
--   { "trailerModels": { "tanker": { "model": "tanker", "config": "" } } }
local M = {}

-- cargo trailer kind -> stock BeamNG model (not verified for every kind yet: check in game, see README "To check")
M.models = {
  curtain   = { model = 'dryvan' },
  box       = { model = 'dryvan' },
  reefer    = { model = 'dryvan' },
  flatbed   = { model = 'flatbed' },
  lowloader = { model = 'flatbed' },
  log       = { model = 'flatbed' },
  container = { model = 'flatbed' },
  tipper    = { model = 'frameless_dump' },
  silo      = { model = 'tanker' },
  tanker    = { model = 'tanker' },
  livestock = { model = 'dryvan' },
}
M.BEHIND_M = 16      -- spawn distance behind the truck's centre
M.NEAR_M = 30        -- a trailer this close to the truck counts as with it

local id = nil       -- the job trailer's vehicle id

function M.configure(cfg)
  for k, v in pairs((cfg and cfg.trailerModels) or {}) do
    if type(v) == 'table' and type(v.model) == 'string' then M.models[k] = v end
  end
end

local function obj()
  if not id then return nil end
  local o = scenetree.findObjectById(id)
  if not o then id = nil end
  return o
end

function M.exists() return obj() ~= nil end

function M.id() return obj() and id or nil end

local function freightConfig(kind)
  if kind == 'fluid' then
    return 'tanker', 'vehicles/tanker/career_shuffleboard_empty_long.pc'
  end
  local config = jsonReadFile('vehicles/dryvan/48ft.pc')
  if type(config) ~= 'table' or type(config.parts) ~= 'table' then return end
  local parts = config.parts
  parts.dryvan_load_F = 'dryvan_load_F_cargo_load_box_4XL'
  if kind == 'dryBulk' then
    for _, suffix in ipairs({ 'FA', 'FB', 'FC', 'FD' }) do
      parts['cargo_load_box_XL_' .. suffix .. '_90deg'] = 'cargo_load_aggregate_box_XL_' .. suffix .. '_90deg'
    end
  else
    parts.dryvan_load_M = 'dryvan_load_M_cargo_load_box_8xl'
    parts.dryvan_load_R = 'dryvan_load_R_cargo_load_box_4XL'
  end
  return 'dryvan', config
end

-- Spawn the trailer for this kind behind the player's vehicle. True, or false and why.
function M.spawn(kind, freightKind)
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not veh then return false, 'no player vehicle' end
  local m = M.models[kind] or M.models.curtain
  if freightKind then
    local model, config = freightConfig(freightKind)
    if not model then return false, 'The stock freight trailer configuration is unavailable.' end
    m = { model = model, config = config }
  end
  local pos, dir = veh:getPosition(), veh:getDirectionVector()
  dir.z = 0
  if dir:length() < 1e-3 then return false, 'vehicle has no direction' end
  dir = dir:normalized()
  local p = pos - dir * M.BEHIND_M
  -- set it on the ground: a ray down from above
  local d = castRayStatic(vec3(p.x, p.y, p.z + 20), vec3(0, 0, -1), 60)
  if d and d < 60 then p.z = p.z + 20 - d + 0.3 else p.z = pos.z + 0.5 end
  M.remove()
  local opt = { pos = p, rot = quatFromDir(dir, vec3(0, 0, 1)), autoEnterVehicle = false }
  if m.config and m.config ~= '' then opt.config = m.config end
  local ok, v = pcall(core_vehicles.spawnNewVehicle, m.model, opt)
  if not ok or not v then return false, 'could not spawn ' .. tostring(m.model) .. ': ' .. tostring(v) end
  id = v:getID()
  -- spawning can switch the camera to the new vehicle: give it back
  if be and be.enterVehicle then pcall(be.enterVehicle, be, 0, veh) end
  return true
end

function M.coupled(vehicleId)
  local couplings = core_vehicles and core_vehicles.vehsCouplings
  local attached = couplings and couplings[vehicleId]
  return id ~= nil and attached ~= nil and attached[id] == true
end

-- Metres between the trailer and the player's vehicle, or nil.
function M.distanceToPlayer()
  local o = obj()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if not o or not veh then return nil end
  return (o:getPosition() - veh:getPosition()):length()
end

function M.withPlayer()
  local d = M.distanceToPlayer()
  return d ~= nil and d <= M.NEAR_M
end

function M.remove()
  local o = obj()
  if o then o:delete() end
  id = nil
end

return M
