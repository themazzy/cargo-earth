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
assert.equal(road.tags.oneway, undefined, 'only the tags the map uses')
assert.equal(JSON.stringify(Array.from(road.parts[0])), '[100,100,1100,100,1100,900]', 'the line in tile units')
assert.equal(JSON.stringify(road.box), '[100,100,1100,900]')
const water = tile.water.features[0]
assert.equal(water.type, 3)
assert(water.parts[0].closed, 'a polygon ring is closed')
const labels = osm.labelsOf(tile)
assert.equal(labels.length, 2, 'each straight piece')
assert.equal(labels[0].name, 'Vodičkova', 'UTF-8 names')
assert.equal(labels[0].len, 1000, 'the longest straight piece first')
assert.equal(JSON.stringify([labels[0].x1, labels[0].y1, labels[0].x2, labels[0].y2]), '[100,100,1100,100]')
{
  // a tile with a river but no street names still names the river
  const river = osm.labelsOf({waterway: {extent: 4096, features: [{type: 2, tags: {name: 'Vltava'}, parts: [[0, 0, 500, 0]]}]}})
  assert.equal(JSON.stringify(river.map(r => [r.name, r.water])), '[["Vltava",true]]')
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
