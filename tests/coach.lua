-- Intercity coaches: stations from the helper, rides to far towns, the coach timetable, boarding and pay.
local coach = require('cargoEarth/coach')
local bus = require('cargoEarth/bus')
local longhaul = require('cargoEarth/longhaul')
local profiles = require('cargoEarth/jobSettings')

-- job settings: their own distances
local d = profiles.defaults('coach')
assert(d.nearKm == 15 and d.minKm == 40 and d.maxKm == 200)
local options = {}
assert(profiles.set(options, 'coach', {nearKm = 10, minKm = 50, maxKm = 300}))
local r = profiles.resolve(options, 'coach')
assert(r.nearKm == 10 and r.minKm == 50 and r.maxKm == 300)
assert(not profiles.set(options, 'coach', {nearKm = 31, minKm = 50, maxKm = 300}), 'a station within 30 km at most')
assert(profiles.labels('coach').nearKm == 'Coach station within')

-- rows: bad ones are left out; the surest station wins, then the nearest
local rows = coach.rows({stations = {
  {id = 'a', n = 'Steel Fish', g = {50.0810, 14.4295}, k = 'bus', s = 0},
  {id = 'b', n = 'Prague Bus Station', g = {50.0894, 14.4404}, k = 'bus', s = 2},
  {id = 'c', n = 'Na Knížecí (tram, bus)', g = {50.0687, 14.4047}, k = 'bus', s = 1},
  {id = 'd', n = 'Praha hlavní nádraží', g = {50.0831, 14.4353}, k = 'rail', s = 1},
  {id = 'x', n = '', g = {50, 14}, k = 'bus'}, {id = 'y', n = 'Bad', g = {91, 14}, k = 'bus'}, {id = 'z', n = 'Tram', g = {50, 14}, k = 'tram'},
}})
assert(#rows == 4, 'bad rows dropped: ' .. #rows)
assert(coach.best(rows, 50.08, 14.43, 15).id == 'b', 'a named bus station before a closer unrelated name')
assert(coach.best({rows[1], rows[3], rows[4]}, 50.08, 14.43, 15).id == 'c', 'a bus stop before the railway station')
assert(coach.best({rows[1], rows[4]}, 50.08, 14.43, 15).id == 'd', 'the railway station before an unrelated name')
assert(coach.best(rows, 50.08, 14.43, 0.5) == nil or coach.best(rows, 50.08, 14.43, 0.5).id ~= 'b')

-- the tick: the player's stations first, then far towns; a town without a station gives way to the next one
local cities = longhaul.cities({rows = {
  {'Brno', 'CZ', 49.2, 16.61, 380}, {'Plzen', 'CZ', 49.75, 13.38, 170}, {'Liberec', 'CZ', 50.77, 15.06, 100},
  {'Kladno', 'CZ', 50.15, 14.10, 70}, {'Wien', 'AT', 48.2, 16.37, 1900}, {'Ceske Budejovice', 'CZ', 48.97, 14.47, 95},
}})
local asked, answers = {}, {}
local function ask(path, onDone) asked[#asked + 1] = path answers[path] = onDone end
local st, p, range = {}, {lat = 50.08, lon = 14.43}, {nearKm = 15, minKm = 40, maxKm = 200}
-- the boxes around the player cover the whole station radius (a box reaches about 0.095 degrees)
local pts = coach.points(50.08, 14.43, 15)
assert(#pts == 9 and pts[1].lat == 50.08 and pts[1].lon == 14.43, 'the player first, then the boxes around: ' .. #pts)
assert(#coach.points(50.08, 14.43, 5) == 1 and #coach.points(50.08, 14.43, 30) == 15, "3 rows x 5 columns at 50 degrees")
local saved = coach.TOWNS
coach.TOWNS = 2
coach.tick(st, 0, p, range, cities, ask)
assert(#asked == coach.IN_FLIGHT and asked[1] == '/v1/stations?lat=50.0800&lon=14.4300', 'the stations near the player first')
assert(coach.status(st).origin == 'loading')
local answered = {}
local noStation = 0
for tick = 1, 40 do
  coach.tick(st, tick, p, range, cities, ask)
  for _, path in ipairs(asked) do
    if not answered[path] then
      answered[path] = true
      local lat, lon = path:match('lat=([%d%.%-]+)&lon=([%d%.%-]+)')
      lat, lon = tonumber(lat), tonumber(lon)
      local found = {}
      if path == asked[1] then
        found = {{id = 'b', n = 'Prague Bus Station', g = {50.0894, 14.4404}, k = 'bus', s = 2}}
      elseif path == asked[2] then
        -- a station 12 km east of the player, in a neighbouring box: found, but the surer one nearer wins
        found = {{id = 'east', n = 'AN East', g = {50.08, 14.60}, k = 'bus', s = 2}}
      elseif math.abs(lat - 50.08) > 0.3 or math.abs(lon - 14.43) > 0.4 then
        if noStation == 0 then noStation = 1 found = {{id = 'far', n = 'Somewhere', g = {lat - 1, lon}, k = 'bus', s = 2}}
        else found = {{id = path, n = 'AN ' .. path, g = {lat + 0.01, lon}, k = 'bus', s = 2}} end
      end
      answers[path]({state = 'ready', stations = found})
    end
  end
end
assert(#st.towns == 3, 'a spare town replaces the one without a station')
assert(coach.status(st).ready == 2 and coach.status(st).origin == 'ready')
assert(#coach.originRows(st) == 2)
assert(coach.best(coach.originRows(st), 50.08, 14.60, 15).id == 'east', 'a station in another box is a start too')
coach.TOWNS = saved
-- two towns that picked the same station make one ride
do
  local same = {origin = st.origin, towns = {
    {city = {n = 'A', lat = 50.6, lon = 14.4}, station = {id = 'shared', n = 'AN Shared', g = {50.6, 14.4}, k = 'bus', s = 2}},
    {city = {n = 'B', lat = 50.62, lon = 14.42}, station = {id = 'shared', n = 'AN Shared', g = {50.6, 14.4}, k = 'bus', s = 2}}}}
  local list = coach.board(same, p, range)
  assert(#list == 2 and list[1].bus.town == 'A' and list[2].bus.back and list[2].id == list[1].id .. '+back',
    'one ride per destination station, one way and return')
end
local offers, from = coach.board(st, p, range)
assert(from and from.id == 'b', 'rides leave from the bus station near the player')
assert(#offers >= 1, 'rides to the far towns with stations')
for _, o in ipairs(offers) do
  assert(o.tier == 'bus' and o.coach and o.yard.n == 'Prague Bus Station' and #o.jobs == 1)
  assert(#o.jobs[1].bus.stops == (o.bus.back and 3 or 2))
  local legKm = o.km / (#o.jobs[1].bus.stops - 1)
  assert(legKm >= range.minKm and legKm <= range.maxKm, 'ride within the distances: ' .. legKm)
  local j = o.jobs[1]
  assert(j.bus.coach and j.kind == 'bus')
end
-- outside the station radius: no rides
assert(#coach.board(st, {lat = 49.5, lon = 15.5}, range) == 0)

-- a 100 km ride: highway timetable and pay
local line = {id = 'coach:a>b', ref = '', coach = true, roadFactor = 1.3, name = 'Coach to Brno', operator = '',
  stops = {{n = 'Praha', g = {50.0894, 14.4404}}, {n = 'Brno', g = {49.4, 15.0}}}}
local j = bus.job(line, {id = 'y', n = 'Praha', g = {50.0894, 14.4404}})
local straight = j.straightKm
assert(math.abs(j.km - straight * 1.3) < 1e-6)
local cityMinutes = bus.legMinutes(j.km)
local coachMinutes = bus.legMinutes(j.km, true)
assert(coachMinutes < cityMinutes * 0.7, 'a coach runs at road speeds')
assert(j.minutes >= j.km / 78 * 60, 'never faster than the top leg speed')
assert(j.cargoName == 'Coach to Brno' and j.bus.name == 'Coach to Brno')
assert(j.pay > 800 and j.pay < 1300, 'a 100 km ride pays: ' .. j.pay)
-- boarding: many at the first station, nobody gets off before the end, everyone at the end; seats only
local function rnd(n) return n end    -- the most
local off, on = bus.passengers(j, rnd)
assert(off == 0 and on == bus.COACH.SEATS, 'a full coach: ' .. on)
bus.served(j, off, on, 0)
assert(j.bus.at == 2 and j.bus.onBoard == bus.COACH.SEATS and bus.last(j))
off, on = bus.passengers(j, rnd)
assert(off == bus.COACH.SEATS and on == 0)
bus.served(j, off, on, 60)
assert(j.bus.onBoard == 0)
assert(bus.fares(j) == bus.coachFares(j.km, bus.COACH.SEATS) and bus.fares(j) > 0, 'fares by the km')
assert(bus.linePay(j) == j.pay + bus.fares(j))
assert(bus.state(j, nil, 0).capacity == bus.COACH.SEATS and bus.state(j, nil, 0).coach)
-- the fewest riders
local j2 = bus.job(line, {id = 'y', n = 'Praha', g = {50.0894, 14.4404}})
local _, few = bus.passengers(j2, function() return 1 end)
assert(few == bus.COACH.RIDERS[1])
-- a return trip: everyone off at the far station, new people on for the way back, all off where it started
local back = bus.job({id = 'coach:a>b+back', ref = '', coach = true, roadFactor = 1.3, name = 'Coach to Brno and back',
  stops = {line.stops[1], line.stops[2], line.stops[1]}}, {id = 'y', n = 'Praha', g = {50.0894, 14.4404}})
local oneWay = bus.job(line, {id = 'y', n = 'Praha', g = {50.0894, 14.4404}})
assert(math.abs(back.km - 2 * oneWay.km) < 1e-6 and back.pay > 1.8 * oneWay.pay, 'twice the road, about twice the pay')
local o1, n1 = bus.passengers(back, function() return 5 end)
assert(o1 == 0 and n1 == 20)
bus.served(back, o1, n1, 0)
local o2, n2 = bus.passengers(back, function() return 10 end)
assert(o2 == 20 and n2 == 25 and not bus.last(back), 'all off at the far station, new people on')
bus.served(back, o2, n2, 100)
assert(back.bus.onBoard == 25 and bus.last(back))
local o3, n3 = bus.passengers(back, rnd)
assert(o3 == 25 and n3 == 0)
bus.served(back, o3, n3, 200)
assert(bus.fares(back) == bus.coachFares(oneWay.km, 45), 'each rider pays one leg')
-- a city line keeps its own rules
local city = bus.job({id = 'l', ref = '7', name = '', stops = {{n = 'A', g = {50, 14}}, {n = 'B', g = {50.01, 14}}, {n = 'C', g = {50.02, 14}}, {n = 'D', g = {50.03, 14}}}},
  {id = 'dep', n = 'Depot', g = {50, 14}})
assert(not city.bus.coach and bus.state(city, nil, 0).capacity == bus.CAPACITY and city.cargoName == 'Line 7 to D')
print('Coaches: stations ranked, ' .. #offers .. ' rides from Prague, 100 km ride ' .. j.minutes .. ' min, ' .. j.pay .. ' CZK + fares')
