-- Long hauls: far towns in the distance ring, the helper's far workplaces as delivery points, and handing over.
local longhaul = require('cargoEarth/longhaul')
local jobs = require('cargoEarth/jobs')

-- the ring only opens for profiles that reach past the nearby areas
assert(longhaul.rings({{minKm = 20, maxKm = 100}}) == nil)
local rings = longhaul.rings({{minKm = 20, maxKm = 100}, {minKm = 600, maxKm = 800}, {minKm = 20, maxKm = 250}, {minKm = 600, maxKm = 800}})
assert(#rings == 2 and rings[1][1] == 600 and rings[2][1] == 120 and rings[2][2] == 250, 'each profile keeps its own ring')

local cities = longhaul.cities({rows = {
  {'Wien', 'AT', 48.2, 16.37, 1900}, {'Berlin', 'DE', 52.52, 13.4, 3500}, {'Muenchen', 'DE', 48.14, 11.58, 1500},
  {'Brno', 'CZ', 49.2, 16.61, 380}, {'Plzen', 'CZ', 49.75, 13.38, 170}, {'Paris', 'FR', 48.86, 2.35, 11000},
  {'Bad', 'XX', 'x', 1, 1}, {'Graz', 'AT', 47.07, 15.44, 290},
}})
assert(#cities == 7, 'a bad row is skipped')
-- Prague, 300-450 road km: Vienna, Berlin, Munich, Graz; Brno and Pilsen are too near, Paris too far
local picked = longhaul.pick(cities, 50.08, 14.42, 300, 450, 8)
local names = {}
for _, c in ipairs(picked) do names[c.n] = true end
assert(names.Wien and names.Berlin and names.Muenchen and not names.Brno and not names.Plzen and not names.Paris)
assert(#longhaul.pick(cities, 50.08, 14.42, 300, 450, 2) == 2)
-- the same sector: the bigger town first (Vienna before Graz, both south-east)
local one = longhaul.pick({cities[7], cities[1]}, 50.08, 14.42, 300, 600, 1)
assert(one[1].n == 'Wien')

-- the tick asks the helper, skips towns the pack covers, retries a loading town and keeps ready ones
local asked, answers, added = {}, {}, {}
local function ask(path, onDone) asked[#asked + 1] = path answers[path] = onDone end
local st = {}
local p = {lat = 50.08, lon = 14.42}
local covered = function(lat) return lat > 52 end   -- pretend the pack has Berlin
longhaul.tick(st, 0, p, {{300, 450}}, cities, ask, covered, function(key, depots, city) added[#added + 1] = {key, #depots, city.n} end)
assert(#asked == longhaul.IN_FLIGHT, 'only a few requests at once')
for _, path in ipairs(asked) do assert(not path:find('52.52', 1, true), 'covered town not asked') end
answers[asked[1]]({state = 'loading', key = 'k1', depots = {}})
answers[asked[2]]({state = 'ready', key = 'k2', depots = {{id = 'overture:1', n = 'Lager', g = {48.2, 16.37}, t = 'yard'}}})
assert(#added == 1 and added[1][1] == 'k2' and added[1][2] == 1)
longhaul.tick(st, 1, p, {{300, 450}}, cities, ask, covered, function(key, depots) added[#added + 1] = {key, #depots} end)
assert(#asked == 3, 'the third town is asked next; the loading one waits ' .. longhaul.LOADING_S .. ' s')
longhaul.tick(st, 10, p, {{300, 450}}, cities, ask, covered, function() end)
assert(longhaul.status(st).ready == 1 and longhaul.status(st).towns == 3)
-- an old helper (no /v1/sites) stops the asking
answers[asked[#asked]](nil, 'HTTP 404')
local n = #asked
longhaul.tick(st, 100, p, {{300, 450}}, cities, ask, covered, function() end)
assert(#asked == n and longhaul.status(st).old)
-- two rings far apart both get towns (none from the gap between them)
local both = longhaul.pickRings(cities, 50.08, 14.42, {{120, 250}, {1000, 1400}})
local near, far = 0, 0
for _, t in ipairs(both) do
  local c = t.city
  local road = jobs.km(50.08, 14.42, c.lat, c.lon) * jobs.ROAD_FACTOR
  if road <= 250 then near = near + 1 elseif road >= 1000 then far = far + 1 else error('a town in the gap: ' .. c.n) end
end
assert(near >= 1 and far >= 1, near .. ' near, ' .. far .. ' far')
-- a spare of one ring is still free for a later ring where it is the only town
local towns0 = longhaul.TOWNS
longhaul.TOWNS = 2   -- the first ring's two towns leave Berlin as its spare
local spareCase = longhaul.pickRings(cities, 50.08, 14.42, {{120, 800}, {360, 370}})
longhaul.TOWNS = towns0
local berlinRing2 = false
for _, t in ipairs(spareCase) do if t.city.n == 'Berlin' and t.ring == 2 then berlinRing2 = true end end
local road = jobs.km(50.08, 14.42, 52.52, 13.4) * jobs.ROAD_FACTOR
assert(road > 360 and road < 370, road)
assert(berlinRing2, 'Berlin goes to the ring that has only Berlin')
-- a town with no workplaces makes way for the next town of its ring
local st3, asked3 = {}, {}
longhaul.tick(st3, 0, p, {{300, 450}}, cities, function(path, done) asked3[#asked3 + 1] = done end, nil, function() end)
local before = #st3.towns
asked3[1]({state = 'ready', key = 'empty', depots = {}})
assert(#st3.towns == before + 1 or #st3.spares[1] == 0)
-- moving far picks again
local st2 = {}
longhaul.tick(st2, 0, p, {{300, 450}}, cities, function() end, nil, function() end)
local first = st2.towns
longhaul.tick(st2, 0, {lat = 48.2, lon = 16.37}, {{300, 450}}, cities, function() end, nil, function() end)
assert(st2.towns ~= first)

-- far workplaces become delivery points (not pickups) and pass the checked-site rule only as far sites
local idx = jobs.index({depots = {
  {id = 'yard', n = 'Home Yard', t = 'logistics', s = 'M', g = {50.08, 14.42}, access = 'validated'},
}, cargo = {pallets_general = {name = 'Pallets', pay = 1, trailer = 'curtain', tonnes = 18}},
  trailers = {}, types = {logistics = {produces = {'pallets_general'}, accepts = {'pallets_general'}}}})
assert(jobs.addFar(idx, 'k2', {
  {id = 'overture:1', n = 'Lager Wien', g = {48.2, 16.37}, t = 'yard'},
  {id = 'overture:2', n = 'Tank', g = {48.21, 16.37}, t = 'fuel'},        -- no fuel depots as far points
  {id = 'bad', n = 'Bad', g = {200, 1}, t = 'yard'},
}) == 1)
assert(jobs.hasFar(idx, 'k2') and not jobs.hasFar(idx, 'k3'))
local offers = jobs.generate(idx, {minKm = 300, maxKm = 450, nearKm = 5, requireValidatedSites = true, count = 5},
  50.08, 14.42, function() return 1 end)
assert(#offers == 1 and offers[1].to.far and offers[1].to.n == 'Lager Wien' and offers[1].km > 300)
jobs.FAR_UNCHECKED = false
assert(#jobs.generate(idx, {minKm = 300, maxKm = 450, nearKm = 5, requireValidatedSites = true}, 50.08, 14.42) == 0)
jobs.FAR_UNCHECKED = true
-- a far workplace is never a pickup
assert(#jobs.generate(idx, {minKm = 1, maxKm = 900, nearKm = 5}, 48.2, 16.37) == 0)
-- the far store is bounded
for i = 1, jobs.FAR_KEEP + 3 do jobs.addFar(idx, 'f' .. i, {}) end
assert(#idx.stream.farOrder == jobs.FAR_KEEP and not jobs.hasFar(idx, 'k2'))
print('Long hauls: ring, far towns by direction, helper asking and retries, far delivery points and checked-site rule passed')
