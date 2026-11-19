// Helper-like workplaces for the offline tools (benchmark, payout statistics): the mod no longer bundles real
// workplaces, so these spread a fixed, reproducible set of catalogue-typed sites around given centres.
const fs = require('node:fs')
const path = require('node:path')
const catalogue = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'mod/cargo_earth/lua/ge/extensions/cargoEarth/data/freight.json'), 'utf8'))
const KINDS = Object.keys(catalogue.types)
// centres: [[lat, lon], ...]; per: sites around each, out to about `km`.
function pack(centres, per = 150, km = 40) {
  const depots = []
  centres.forEach(([lat, lon], c) => {
    for (let i = 0; i < per; i++) {
      const a = i * 2.39996, r = (km / 111) * Math.sqrt((i + 1) / per)
      depots.push({id: `site-${c}-${i}`, n: `Site ${c}-${i}`, t: KINDS[(i * 7 + c) % KINDS.length], s: 'M',
        g: [lat + r * Math.sin(a), lon + r * Math.cos(a) / Math.cos(lat * Math.PI / 180)], access: 'candidate'})
    }
  })
  return {cargo: catalogue.cargo, types: catalogue.types, trailers: catalogue.trailers, depots}
}
module.exports = {catalogue, pack}
