// The phone's OSM map: the vector tile decoder, street name places and the tile loader's failure reasons.
const assert = require('assert')
const fs = require('fs')
const vm = require('vm')
const src = fs.readFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', 'utf8')
const start = src.indexOf('var cargoEarthOsm = ')
const end = src.indexOf("angular.module('beamng.apps')")
assert(start > 0 && end > start, 'the OSM module sits before the directive')
const ctx = {TextDecoder, DataView, Uint8Array, Math, JSON, Object, String, Date}
vm.runInNewContext(src.slice(start, end) + ';this.osm = cargoEarthOsm', ctx)
const osm = ctx.osm

const tile = osm.decode(new Uint8Array(fs.readFileSync('tests/fixtures/osm-tile.pbf')))
assert(tile.transportation && tile.water && tile.transportation_name, 'the layers the map draws')
assert(tile.poi && tile.poi.features.length === 1, 'places too')
// places: named, without street furniture, the most important first, coloured by kind
{
  const P = (name, cls, rank, x) => ({type: 1, tags: {name, 'class': cls, rank}, parts: [[x, 10]]})
  const pois = osm.poisOf({poi: {extent: 4096, features: [P('Parking A', 'parking', 1, 1), P('Bistro', 'restaurant', 2, 2),
    P('Lékárna', 'pharmacy', 1, 3), {type: 1, tags: {'class': 'shop', rank: 1}, parts: [[4, 4]]}, P('Shell', 'fuel', 3, 5),
    P('A very very long business name indeed', 'shop', 4, 6), P('Kemp', 'campsite', 9, 7)]}})
  assert.equal(JSON.stringify(pois.map(p => [p.name, p.kind])),
    JSON.stringify([['Lékárna', 'health'], ['Bistro', 'food'], ['Shell', 'fuel'], ['A very very long business…', 'shop'], ['Kemp', 'other']]), 'lodging and the rest under Other')
}
const road = tile.transportation.features.find(f => f.tags.class === 'primary')
assert.equal(road.type, 2)
assert.equal(road.tags.brunnel, 'bridge')
assert.equal(road.tags.oneway, 1, 'one-way kept for its arrows')
assert(Object.keys(road.tags).every(k => ['class', 'subclass', 'name', 'name:latin', 'brunnel', 'ref', 'rank', 'oneway', 'housenumber'].includes(k)), 'only the tags the map uses')
assert.equal(JSON.stringify(Array.from(road.parts[0])), '[100,100,1100,100,1100,900]', 'the line in tile units')
assert.equal(JSON.stringify(road.box), '[100,100,1100,900]')
const water = tile.water.features[0]
assert.equal(water.type, 3)
assert(water.parts[0].closed, 'a polygon ring is closed')
const labels = osm.labelsOf(tile)
assert.equal(labels.length, 1, 'each named line')
assert.equal(labels[0].name, 'Vodičkova', 'UTF-8 names')
assert.equal(labels[0].len, 1800, 'its whole length')
assert.equal(JSON.stringify(Array.from(labels[0].pts)), '[100,100,1100,100,1100,900]', 'the whole line, so the name can follow its bends')
{
  // each name keeps its Latin spelling too, for the Latin names switch
  const sr = osm.labelsOf({transportation_name: {extent: 4096, features: [{type: 2, tags: {name: 'Кнез Михаилова', 'name:latin': 'Knez Mihailova'}, parts: [[0, 0, 500, 0]]},
    {type: 2, tags: {name: 'Vodičkova', 'name:latin': 'Vodičkova'}, parts: [[0, 10, 400, 10]]}]}})
  assert.equal(JSON.stringify(sr.map(r => [r.name, r.lat])), '[["Кнез Михаилова","Knez Mihailova"],["Vodičkova",null]]')
  const pp = osm.poisOf({poi: {extent: 4096, features: [{type: 1, tags: {name: 'Пекара', 'name:latin': 'Pekara', 'class': 'bakery', rank: 1}, parts: [[1, 1]]}]}})
  assert.equal(pp[0].lat, 'Pekara')
}
{
  // a tile with a river but no street names still names the river
  const river = osm.labelsOf({waterway: {extent: 4096, features: [{type: 2, tags: {name: 'Vltava'}, parts: [[0, 0, 500, 0]]}]}})
  assert.equal(JSON.stringify(river.map(r => [r.name, r.water])), '[["Vltava",true]]')
}

{
  // names follow the line: letters along an L-shaped street turn with it, and read left to right
  const ctx = {measureText: t => ({width: 6 * t.length})}
  const pl = {xy: [0, 0, 100, 0, 100, 100], d: [0, 100, 200]}
  const spot = osm.labelSpot(pl, 'Ulice', 30, ctx)
  assert(spot && spot.chars.length === 5, 'placed on the long L')
  assert(spot.chars.every(c => Math.abs(c[3]) < 0.01), 'the middle of the first leg, written along it')
  const back = osm.labelSpot({xy: [100, 0, 0, 0], d: [0, 100]}, 'Ulice', 30, ctx)
  assert(back.chars[0][1] < back.chars[4][1], 'a line drawn right to left is still read left to right')
  assert.equal(osm.labelSpot({xy: [0, 0, 20, 0, 20, 20, 40, 20], d: [0, 20, 40, 60]}, 'Zigzag', 36, ctx), null, 'too bendy')
  // right-to-left and joined scripts: the whole name at once, so the browser keeps its direction and shaping
  const he = osm.labelSpot({xy: [0, 0, 100, 0], d: [0, 100]}, 'רחוב', 24, ctx)
  assert(he && he.chars.length === 1 && he.chars[0][0] === 'רחוב' && he.chars[0][1] === 50, 'one piece in the middle')
  assert.equal(osm.labelSpot(pl, 'شارع', 150, ctx), null, 'never bent round a corner')
  // names stay on their street while the map moves: fixed spots along the line, the last one kept while it fits
  const line = dx => ({xy: [-600 + dx, 50, 900 + dx, 50], d: [0, 1500]})
  const box = [0, 0, 300, 100]
  const s1 = osm.anchoredStarts(line(0), 30, box, 'Ulice@t')
  assert(s1.length >= 1, 'a spot in view')
  osm.rememberLabel('Ulice@t', line(0), 30, s1[0])
  const x1 = -600 + s1[0]
  const s2 = osm.anchoredStarts(line(-20), 30, box, 'Ulice@t')
  assert.equal(s2[0], s1[0], 'the same spot on the line after the map moved 20 px')
  assert.equal(-600 - 20 + s2[0], x1 - 20, 'so the name moves with the map, not with the car')
  assert(osm.anchoredStarts(line(0), 30, box, 'x').every(st => (st + 15) % 187.5 === 93.75), 'spots in the middle of equal stretches')
  assert.equal(osm.anchoredStarts({xy: [0, 200, 300, 200], d: [0, 300]}, 30, box, 'y').length, 0, 'outside the box: none')
  // a piece crossing the whole screen counts, clipped to it
  assert.equal(JSON.stringify(osm.clipTo([-50, 10], [150, 10], 0, 0, 100, 100)), '[0.25,0.75,0,10,100,10]')
  assert.equal(osm.clipTo([-50, -10], [150, -10], 0, 0, 100, 100), null)
}

{
  // house numbers: points with a number, long ones cut
  const hn = osm.numbersOf({housenumber: {extent: 4096, features: [{type: 1, tags: {housenumber: '12a'}, parts: [[5, 6]]},
    {type: 1, tags: {}, parts: [[1, 1]]}, {type: 1, tags: {housenumber: 1234567890}, parts: [[2, 2]]}]}})
  assert.equal(JSON.stringify(hn), '[{"n":"12a","x":5,"y":6},{"n":"1234567…","x":2,"y":2}]')
}

// tile numbers and sizes
const t = osm.tileXY(50.087, 14.421)
assert.equal(Math.floor(t[0]), 8848)
assert.equal(Math.floor(t[1]), 5550)
assert(Math.abs(osm.tileMetres(50) - 1572) < 2, 'a z14 tile is about 1.57 km wide at 50 degrees')

// the loader: decoded tiles kept; failures name the reason once three tiles failed and none came
let calls = []
const map = new osm.TileMap({xhr: (url, done) => calls.push({url, done}), canvas: () => ({})})
map.setBase('http://127.0.0.1:47821/v1/osm/tile')
map.want(8848, 5550, 0)
assert.equal(calls[0].url, 'http://127.0.0.1:47821/v1/osm/tile?z=14&x=8848&y=5550')
calls[0].done(200, Uint8Array.from(fs.readFileSync('tests/fixtures/osm-tile.pbf')).buffer)
assert.equal(map.tiles['8848/5550'].state, 'ok')
assert.equal(map.ok, 1)
const fresh = new osm.TileMap({xhr: (url, done) => done(0, null), canvas: () => ({})})
fresh.setBase('http://127.0.0.1:47821/v1/osm/tile')
for (let i = 0; i < 3; i++) fresh.want(i, 0, 0)
assert(fresh.failed.includes('did not answer'), 'no helper: ' + fresh.failed)
const old = new osm.TileMap({xhr: (url, done) => done(403, null), canvas: () => ({})})
old.setBase('x')
for (let i = 0; i < 3; i++) old.want(i, 0, 0)
assert(old.failed.includes('too old'), old.failed)
const off = new osm.TileMap({xhr: (url, done) => done(502, new TextEncoder().encode('{"error": "no internet"}').buffer), canvas: () => ({})})
off.setBase('x')
for (let i = 0; i < 3; i++) off.want(i, 0, 0)
assert(off.failed.includes('no internet'), off.failed)
// at most 4 at once; an error is asked again only after a while
const busy = new osm.TileMap({xhr: () => {}, canvas: () => ({})})
busy.setBase('x')
for (let i = 0; i < 6; i++) busy.want(i, 0, 0)
assert.equal(busy.loading, 4)

// a sharp screen (ratio 3) at the 1000 m zoom: the pieces it shows fit the cache, so a parked car's map settles
const fixture = Uint8Array.from(fs.readFileSync('tests/fixtures/osm-tile.pbf')).buffer
const nop = new Proxy({}, {get: (o, k) => (k in o ? o[k] : () => ({width: 10}))})
let made = 0
const sharp = new osm.TileMap({xhr: (url, done) => done(200, fixture), canvas: () => { made++; return {getContext: () => nop} }})
sharp.setBase('x')
const view = {w: 320, h: 500, ox: 160, oy: 340, scale: 500 / 1000, ratio: 3, lat: 50.087, lon: 14.421, heading: 30}
let last
for (let i = 1; i <= 100; i++) last = sharp.draw(nop, view, false, i)
assert.equal(last.missing, false, 'every piece drawn after a while')
assert(Object.keys(sharp.pieces).length <= osm.TileMap.MAX_PIECES, 'within the cache')
const settled = made
for (let i = 101; i <= 110; i++) sharp.draw(nop, view, false, i)
assert.equal(made, settled, 'a parked car draws no new pieces')
// a map that had tiles, then lost the helper and was switched off and on again, falls back again
let gone = false
const again = new osm.TileMap({xhr: (url, done) => gone ? done(0, null) : done(200, fixture), canvas: () => ({})})
again.setBase('x')
again.want(8848, 5550, 0)
assert.equal(again.ok, 1)
gone = true
again.reset()
for (let i = 0; i < 3; i++) again.want(i, 0, 0)
assert(again.failed.includes('did not answer'), 'fallback after a reset: ' + again.failed)
console.log('OSM map: vector tile decoder, street names, tile numbers and the loader checked')
