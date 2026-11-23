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
print('Live map: roads by tile and kind, long edges, route clipping, caching and the route ahead of the car checked')
