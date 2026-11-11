-- Persistent play time. Wall time is only used for display and migrating old deadlines.
local jobs = require('cargoEarth/jobs')
local M = {}

function M.advance(career, real, sim, ready)
  local dt = tonumber(real) or 0
  if not ready or (sim ~= nil and sim <= 0) or dt <= 0 or dt > 5 then return 0 end
  career.activeSeconds = (career.activeSeconds or 0) + dt
  return dt
end

function M.elapsed(career, job)
  return math.max(0, (career.activeSeconds or 0) - (job.startedActive or career.activeSeconds or 0))
end

function M.restoreJob(career, job)
  if type(job.startedActive) ~= 'number' then
    local elapsed = job.startedAt and math.max(0, (career.savedAt or job.startedAt) - job.startedAt) or 0
    job.startedActive = (career.activeSeconds or 0) - elapsed
  end
end

-- The sample belongs to this session, never the save. Geographic coordinates survive origin shifts.
function M.distance(previous, pose, dt)
  if not pose or pose.camera or not pose.lat or not pose.lon or dt <= 0 then return nil, 0 end
  local sample = { lat = pose.lat, lon = pose.lon, speed = pose.speed or 0 }
  if not previous then return sample, 0 end
  local metres = jobs.km(previous.lat, previous.lon, pose.lat, pose.lon) * 1000
  local limit = math.max(12, (math.max(sample.speed, previous.speed) + 15) * dt * 1.5)
  if metres > limit or metres > 500 then return sample, 0 end
  return sample, metres / 1000
end

return M
