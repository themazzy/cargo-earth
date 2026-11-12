-- Which country a point is in, from simplified country borders bundled with the mod (data/borders.json, Natural Earth
-- 1:10m, public domain; about 500 m accurate, small islands left out). Works offline, everywhere.
-- Pure rules: the decoded file is passed in.
local M = {}

M.CELL = 2   -- degrees per grid cell

local function cellKey(x, y) return math.floor(x / M.CELL) .. '_' .. math.floor(y / M.CELL) end

-- data: { scale, countries = { { iso, { minX, minY, maxX, maxY }, { ring, ... } } } }, rings flat x, y lists (lon, lat)
function M.index(data)
  local idx = { scale = tonumber(type(data) == 'table' and data.scale) or 1000, countries = {}, cells = {} }
  for _, row in ipairs(type(data) == 'table' and data.countries or {}) do
    if type(row) == 'table' and type(row[1]) == 'string' and type(row[2]) == 'table' and type(row[3]) == 'table' then
      local c = { iso = row[1], bbox = row[2], rings = row[3] }
      idx.countries[#idx.countries + 1] = c
      local s = idx.scale
      for x = math.floor(c.bbox[1] / s / M.CELL), math.floor(c.bbox[3] / s / M.CELL) do
        for y = math.floor(c.bbox[2] / s / M.CELL), math.floor(c.bbox[4] / s / M.CELL) do
          local key = x .. '_' .. y
          idx.cells[key] = idx.cells[key] or {}
          table.insert(idx.cells[key], c)
        end
      end
    end
  end
  return idx
end

local function inside(c, x, y)
  local b = c.bbox
  if x < b[1] or x > b[3] or y < b[2] or y > b[4] then return false end
  local odd = false
  for _, ring in ipairs(c.rings) do
    local n = #ring
    local jx, jy = ring[n - 1], ring[n]
    for i = 1, n - 1, 2 do
      local ix, iy = ring[i], ring[i + 1]
      if (iy > y) ~= (jy > y) and x < (jx - ix) * (y - iy) / (jy - iy) + ix then odd = not odd end
      jx, jy = ix, iy
    end
  end
  return odd
end

-- The ISO 3166 alpha-2 code of the country at (lat, lon), or nil (sea, or a gap in the simplified borders).
function M.find(idx, lat, lon)
  if not idx or type(lat) ~= 'number' or type(lon) ~= 'number' then return nil end
  local s = idx.scale
  local x, y = lon * s, lat * s
  for _, c in ipairs(idx.cells[cellKey(lon, lat)] or {}) do
    if inside(c, x, y) then return c.iso end
  end
end

return M
