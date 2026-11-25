-- The live map's pure rules: roads round a point from the road graph, the route clipped to the view.
local pm = require('cargoEarth/phonemap')
pm._reset()
local nodes = {}
for i = 0, 40 do nodes['a' .. i] = {pos = {x = i * 100, y = 0}, links = {}} end
for i = 0, 39 do nodes['a' .. i].links['a' .. (i + 1)] = {speedLimit = i < 20 and 13.89 or 27.78, drivability = 1} end
nodes.t = {pos = {x = 0, y = 50}, links = {a0 = {speedLimit = 5, drivability = 0.2}}}
nodes.p = {pos = {x = 100, y = 50}, links = {a1 = {speedLimit = 8, posted = -22.22}}}
local graph = {nodes = nodes}
local r = pm.roads(graph, 0, 0, 1000, 0)
local n, kinds = #r / 5, {}
for i = 5, #r, 5 do kinds[r[i]] = (kinds[r[i]] or 0) + 1 end
assert(n == 12, 'the street edges within 1 km and the two side roads: ' .. n)
assert(kinds[0] == 1 and kinds[2] == 1 and kinds[1] == 10, 'a track, a 80 km/h road by its posted limit, streets')
r = pm.roads(graph, 3500, 0, 600, 0)
for i = 5, #r, 5 do assert(r[i] == 3, 'a fast road') end
assert(#pm.roads(nil, 0, 0) == 0 and #pm.roads({}, 0, 0) == 0)
-- a long edge is found from a cell it only crosses
local long = {nodes = {l1 = {pos = {x = -2000, y = 10}, links = {l2 = {speedLimit = 30}}}, l2 = {pos = {x = 2000, y = 10}, links = {}}}}
pm._reset()
assert(#pm.roads(long, 1500, 0, 600, 0) == 0, 'its middle is too far away')
assert(#pm.roads(long, 0, 0, 600, 0) == 5)
-- the same graph table: built once; another table or later: built again
pm._reset()
pm.grid(graph, 0)
local stamp = pm.stamp
pm.grid(graph, 10)
assert(pm.stamp == stamp)
pm.grid(graph, 10 + pm.REBUILD_S)
assert(pm.stamp == stamp + 1)
pm.grid({nodes = {}}, 50)
assert(pm.stamp == stamp + 2)
-- with a budget the sorting is spread over several asks; the last finished grid is used meanwhile
pm._reset()
local big = {}
for i = 0, 199 do big['b' .. i] = {pos = {x = i * 10, y = 0}, links = {}} end
for i = 0, 198 do big['b' .. i].links['b' .. (i + 1)] = {speedLimit = 13.89} end
local bigGraph = {nodes = big}
local fake, realClock = 0, pm.clock
pm.clock = function() fake = fake + 0.001 return fake end   -- every look at the clock: 1 ms later
assert(pm.grid(bigGraph, 0, 3) == nil and pm.perf.building, 'a new graph: no grid until it is sorted')
assert(#pm.roads(bigGraph, 0, 0, 1000, 0, 3) == 0)
local asks = 1
while pm.perf.building do pm.grid(bigGraph, 0, 3) asks = asks + 1 assert(asks < 100) end
assert(asks > 3 and pm.perf.slices == asks and pm.perf.edges == 199, 'several slices: ' .. asks)
assert(pm.perf.sliceMaxMs <= 6, 'no slice much over its budget: ' .. pm.perf.sliceMaxMs)
local full = #pm.roads(bigGraph, 0, 0, 5000, 0, 3)
assert(full == 199 * 5)
stamp = pm.stamp
pm.grid(bigGraph, pm.REBUILD_S, 3)
assert(pm.perf.building and pm.grid(bigGraph, pm.REBUILD_S, 3) ~= nil, 'the old grid serves while the new one sorts')
assert(pm.stamp == stamp)
while pm.perf.building do pm.grid(bigGraph, pm.REBUILD_S, 3) end
assert(pm.stamp == stamp + 1 and #pm.roads(bigGraph, 0, 0, 5000, 0, 3) == full)
-- another graph while sorting: the sorting starts again for it
pm.grid(bigGraph, 2 * pm.REBUILD_S, 3)
assert(pm.perf.building)
pm.grid(graph, 2 * pm.REBUILD_S, 3)   -- small: done in one slice
while pm.perf.building do pm.grid(graph, 2 * pm.REBUILD_S, 3) end
assert(pm.perf.edges == 42 and pm.grid(graph, 2 * pm.REBUILD_S, 3) ~= nil)
pm.clock = realClock
-- tiles
local tx, ty, cx, cy = pm.tile(140, -160)
assert(tx == 0 and ty == -1 and cx == 0 and cy == -300)
-- the route: near points kept, thinned, a gap where it leaves the view
local pts = {}
for i = 0, 100 do pts[#pts + 1] = {i * 2, 0} end           -- 0..200 m east, every 2 m
pts[#pts + 1] = {5000, 0}                                    -- far away
pts[#pts + 1] = {200, 50}                                    -- back
local c = pm.clip(pts, 0, 0, 1000)
local gaps = 0
for _, v in ipairs(c) do if v == false then gaps = gaps + 1 end end
assert(#c < 90 and c[1] == 0 and c[2] == 0, 'thinned to about one point per ' .. pm.ROUTE_STEP .. ' m')
assert(c[#c - 1] == 200 and c[#c] == 50, 'the way back is kept')
assert(gaps == 0, 'a point just outside next to one inside keeps the line whole')
local far = {{0, 0}, {10, 0}, {3000, 0}, {6000, 0}, {9000, 0}, {20, 0}}
c = pm.clip(far, 0, 0, 1000)
gaps = 0
for _, v in ipairs(c) do if v == false then gaps = gaps + 1 end end
assert(gaps == 1 and c[#c - 1] == 20, 'the pen lifts where the route is far away')
assert(#pm.clip(nil, 0, 0) == 0)
-- the route's game points: converted once per key
local calls = 0
local function toXY(p) calls = calls + 1 return p[2], p[1] end
pm.routeXY('v1', {{1, 2}, {3, 4}}, toXY)
pm.routeXY('v1', {{1, 2}, {3, 4}}, toXY)
assert(calls == 2)
assert(pm.routeXY('v2', {{1, 2}}, toXY)[1][1] == 2 and calls == 3)
-- the route ahead: cut where the car is, out-and-back keeps the stretch the car was on, facing against it is "behind"
pm._reset()
local line = {{0, 0}, {0, 100}, {0, 200}, {0, 300}}
local ahead, where = pm.ahead(line, 3, 150, 0, 'r1')
assert(ahead[1][1] == 0 and ahead[1][2] == 150 and ahead[2][2] == 200 and #ahead == 3, 'starts at the car, the rest ahead')
assert(where.off == 3 and not where.back)
_, where = pm.ahead(line, 3, 150, 180, 'r1')
assert(where.back, 'driving south on a route going north')
-- out and back along the same street: the first half while the car came that way, then the way back
local outBack = {{0, 0}, {0, 100}, {0, 200}, {1, 100}, {1, 0}}
pm._reset()
ahead = pm.ahead(outBack, 0.5, 50, 0, 'r2')
assert(#ahead == 5, 'on the way out: the turn and the way back still ahead')
pm.ahead(outBack, 0.5, 180, 0, 'r2')
pm.ahead(outBack, 1, 190, 180, 'r2')
ahead = pm.ahead(outBack, 0.6, 50, 180, 'r2')
assert(#ahead == 2, 'on the way back: only the last piece')
pm._reset()
pm.ahead(outBack, 0.5, 50, 0, 'r3')
pm.ahead(outBack, 0.5, 180, 0, 'r3')
pm.ahead(outBack, 1, 190, 180, 'r3')
ahead, where = pm.ahead(outBack, 1, 150, 180, 'r3')
assert(#ahead == 3 and ahead[2][2] == 100 and not where.back, 'just after the turn: the return leg, not the way out')
assert(#pm.ahead({}, 0, 0) == 0)
-- the full map's route: lat / lon of the way ahead, thinned, up to a length along the route
pm._reset()
local geoPts = {}
for i = 0, 100 do geoPts[#geoPts + 1] = {0, i * 2, 50 + i * 0.00002, 14} end
local gr = pm.geoRoute(geoPts, 100)
assert(gr[1] == 50 and #gr % 2 == 0 and #gr <= 2 * 18 and math.abs(gr[#gr - 1] - 50.001) < 1e-9, 'every 6 m, up to 100 m: ' .. #gr)
assert(#pm.geoRoute({{0, 0}, {0, 10}}) == 0 and #pm.geoRoute(nil) == 0, 'no lat / lon: nothing')
local la = pm.ahead({{0, 0, 50, 14}, {0, 100, 50.001, 14}}, 0, 50, 0, 'g')
assert(math.abs(la[1][3] - 50.0005) < 1e-9 and la[1][4] == 14, 'the point of the car on the route gets its lat / lon')
print('Live map: roads by tile and kind, long edges, route clipping, caching and the route ahead of the car checked')
-- the next turn from Earth's route steps
local steps = {
  {type = 'depart', offset = 0, name = 'Dlouha'},
  {type = 'new name', offset = 50, name = 'Kratka'},
  {type = 'turn', modifier = 'left', offset = 200, name = 'Vodickova'},
  {type = 'continue', modifier = 'straight', offset = 300},
  {type = 'roundabout', modifier = 'right', exit = 2, offset = 500, name = '', ref = 'D1'},
  {type = 'arrive', offset = 900},
}
local t = pm.nextTurn(steps, 20)
assert(t.type == 'turn' and t.modifier == 'left' and t.m == 180 and t.name == 'Vodickova', 'the left turn in 180 m')
assert(pm.nextTurn(steps, 195).type == 'turn', 'just before it: still that turn')
t = pm.nextTurn(steps, 201)
assert(t.type == 'roundabout' and t.exit == 2 and t.name == 'D1' and t.m == 299, 'passed: the roundabout, by its road number')
assert(pm.nextTurn(steps, 600).type == 'arrive' and pm.nextTurn(steps, 901) == nil)
assert(pm.nextTurn(nil, 0) == nil and pm.nextTurn(steps, nil) == nil)
local ah, wh = pm.ahead({{0, 0}, {0, 100}, {100, 100}}, 50, 101, 90, 'len')
assert(math.abs(wh.along - 150) < 1e-6 and wh.length == 200, 'metres along the route: ' .. wh.along)
-- lanes at a turn: the arrow of each lane, the ones to use marked
local laneSteps = {{type = 'turn', modifier = 'left', offset = 100, lanes = {
  {valid = true, indications = {'left'}}, {valid = true, indications = {'straight', 'left'}}, {valid = false, indications = {'straight'}},
  {valid = false, indications = {'none'}}}}}
local lt = pm.nextTurn(laneSteps, 0)
assert(#lt.lanes == 4 and lt.lanes[1].ok and lt.lanes[1].dir == 'left', 'a left lane to use')
assert(lt.lanes[2].ok and lt.lanes[2].dir == 'left', 'a lane with two arrows shows the way the route goes')
assert(not lt.lanes[3].ok and lt.lanes[3].dir == 'straight' and lt.lanes[4].dir == 'straight', 'others dim; none = straight')
assert(pm.nextTurn({{type = 'turn', offset = 100, lanes = {{valid = true, indications = {'left'}}}}}, 0).lanes == nil, 'one lane: nothing to show')
