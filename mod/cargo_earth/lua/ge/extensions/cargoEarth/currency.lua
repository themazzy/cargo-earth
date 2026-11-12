-- Local money: the career is paid and pays in the currency of the country you drive in. Crossing a border exchanges
-- your money for free at a fixed rate (currencydata), so nothing is lost; only the numbers and symbol change.
-- Inside, every amount stays in one base unit (CZK, which saves from before local money already use); the phone and
-- messages convert it for display. Pure rules: no game calls here.
local data = require('cargoEarth/currencydata')
local M = {}

M.BASE = 'CZK'        -- the unit all amounts are kept in
M.DEFAULT = 'EUR'     -- shown until the country is known
M.CONFIRM = 2         -- readings in a row of a new country before the money changes (no flicker on a border road)

function M.of(iso) return data.countries[iso] end
function M.name(iso) return data.names[iso] or iso end
function M.known(cur) return data.rates[cur] ~= nil end

-- How many units of cur one base unit is worth.
function M.rate(cur)
  local r = data.rates[cur]
  return r and r / data.rates[M.BASE] or nil
end

-- { code, rate, symbol, prefix, decimals } for the phone.
function M.info(cur)
  cur = M.known(cur) and cur or M.DEFAULT
  local sym, rate = data.symbols[cur], M.rate(cur)
  return { code = cur, rate = rate, symbol = sym and sym[1] or cur, prefix = sym and sym[2] or false,
    decimals = rate < 1 and 2 or 0 }
end

local function group(int, sep)
  local out = tostring(int):reverse():gsub('(%d%d%d)', '%1' .. sep):reverse()
  return (out:gsub('^' .. sep, ''))
end

-- A base amount as local money: '12 400 Kč', '17 418,03 zł', '€508.21', '$1,591.60', 'CHF 480.10'.
function M.format(value, cur)
  local i = M.info(cur)
  local v = (tonumber(value) or 0) * i.rate
  local neg = v < 0 and '-' or ''
  v = math.abs(v)
  local text, sep = nil, i.prefix and ',' or ' '
  if i.decimals > 0 then
    local cents = math.floor(v * 100 + 0.5)
    text = group(math.floor(cents / 100), sep) .. (i.prefix and '.' or ',') .. string.format('%02d', cents % 100)
  else
    text = group(math.floor(v + 0.5), sep)
  end
  if not i.prefix then return neg .. text .. ' ' .. i.symbol end
  return neg .. i.symbol .. (i.symbol:match('%a$') and ' ' or '') .. text
end

-- Messages are written with base amounts ('Fine 300 CZK'); this shows them in local money.
function M.localize(text, cur)
  if type(text) ~= 'string' then return text end
  return (text:gsub('(%-?)(%d+) CZK', function(sign, n) return M.format((sign == '-' and -1 or 1) * tonumber(n), cur) end))
end

-- One reading of the country the player is in (nil: sea or unknown, ignored). track holds the reading streak.
-- Returns { country, from, to } when the player is confirmed in a new country.
function M.observe(c, track, iso)
  if not iso then return nil end
  if iso == c.country then track.iso, track.n = nil, 0 return nil end
  if track.iso ~= iso then track.iso, track.n = iso, 0 end
  track.n = track.n + 1
  if track.n < M.CONFIRM then return nil end
  track.iso, track.n = nil, 0
  local before = c.currency
  c.country, c.currency = iso, M.of(iso) or c.currency or M.DEFAULT
  return { country = iso, from = before, to = c.currency }
end

-- What to tell the player on entering a country (money in base units, for the exchange line).
function M.welcome(change, money)
  local name = M.name(change.country)
  if not change.from then
    return string.format('Money is shown in %s here (%s).', change.to, name)
  end
  if change.from == change.to then return 'Welcome to ' .. name .. '.' end
  return string.format('Welcome to %s. Your money was exchanged for free: %s is now %s.', name,
    M.format(money, change.from), M.format(money, change.to))
end

return M
