// Install fengari as a development dependency, or set FENGARI_PATH to an existing installation.
const fs = require('node:fs')
const path = require('node:path')
const fengari = require(process.env.FENGARI_PATH || 'fengari')
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)
function run(source, name) {
  const code = lauxlib.luaL_loadbuffer(L, to_luastring(source), null, to_luastring(name))
  if (code !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
}
const base = path.resolve(__dirname, '..')
process.chdir(base)
const extensions = 'mod/cargo_earth/lua/ge/extensions'
for (const file of fs.readdirSync(`${extensions}/cargoEarth`).filter(name => name.endsWith('.lua'))) {
  const status = lauxlib.luaL_loadbuffer(L, to_luastring(fs.readFileSync(`${extensions}/cargoEarth/${file}`, 'utf8')), null, to_luastring(file))
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
  lua.lua_pop(L, 1)
}
for (const file of fs.readdirSync('mod/cargo_earth/lua/vehicle/extensions/cargoEarth').filter(name => name.endsWith('.lua'))) {
  const status = lauxlib.luaL_loadbuffer(L, to_luastring(fs.readFileSync(`mod/cargo_earth/lua/vehicle/extensions/cargoEarth/${file}`, 'utf8')), null, to_luastring(file))
  if (status !== lua.LUA_OK) throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
  lua.lua_pop(L, 1)
}
console.log('Lua syntax: all career modules compile')
run(`package.path = '${extensions}/?.lua;' .. package.path`, 'test-path')
run(fs.readFileSync('tests/helper.lua', 'utf8'), 'tests/helper.lua')
run(fs.readFileSync('tests/offerwhy.lua', 'utf8'), 'tests/offerwhy.lua')
run(fs.readFileSync('tests/insurance.lua', 'utf8'), 'tests/insurance.lua')
run(fs.readFileSync('tests/career.lua', 'utf8'), 'tests/career.lua')
run(fs.readFileSync('tests/dash.lua', 'utf8'), 'tests/dash.lua')
run(fs.readFileSync('tests/wreck.lua', 'utf8'), 'tests/wreck.lua')
run(fs.readFileSync('tests/bus-controls.lua', 'utf8'), 'tests/bus-controls.lua')
// Exercise the actual supplied freight pack as well as the small rule fixtures.
function toLua(value) {
  if (value === null || value === undefined) return 'nil'
  if (typeof value === 'string') return JSON.stringify(value).replace(/\\u([0-9a-f]{4})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return '{' + value.map(toLua).join(',') + '}'
  return '{' + Object.entries(value).map(([key, item]) => '[' + toLua(key) + ']=' + toLua(item)).join(',') + '}'
}
const catalogue = JSON.parse(fs.readFileSync(`${extensions}/cargoEarth/data/freight.json`, 'utf8'))
// Helper-style workplaces (unchecked, with catalogue types) around Prague: trucks get contracts without any bundled pack.
const helperDepots = []
const kinds = ['logistics', 'factory', 'sawmill', 'brewery', 'food', 'steelworks', 'quarry', 'concrete', 'farm', 'industrial']
for (let i = 0; i < 120; i++) {
  const a = i * 2.39996, r = 0.02 + (i % 30) * 0.012
  helperDepots.push({id: 'overture:' + i, n: 'Site ' + i, t: i % 11 === 0 ? 'shop' : 'yard', k: i % 11 === 0 ? null : kinds[i % kinds.length],
    g: [50.0755 + r * Math.sin(a), 14.4378 + r * 1.5 * Math.cos(a)], source: 'Overture', access: 'candidate'})
}
run('local jobs=require("cargoEarth/jobs"); local employment=require("cargoEarth/employment"); local cat=' + toLua(catalogue) +
  '; local idx=jobs.index({depots={},cargo=cat.cargo,types=cat.types,trailers=cat.trailers}); jobs.addArea(idx,{key="1_1",depots=' + toLua(helperDepots) + '});' +
  ' assert(idx.byId["overture:1"].t=="factory","catalogue type kept"); assert(idx.byId["overture:0"].t=="ce:stream:shop");' +
  ' local board=employment.board(idx,{lat=50.0755,lon=14.4378}); assert(#board>0,"No Prague company contracts"); local all=employment.board(idx,{lat=50.0755,lon=14.4378},"semi"); local n={van=0,rigid=0,semi=0}; for _,o in ipairs(all) do n[o.tier]=n[o.tier]+1 end; assert(n.rigid>0 and n.semi>0,"No Prague truck contracts");' +
  ' local cargos={}; for _,o in ipairs(all) do for _,j in ipairs(o.jobs or {}) do cargos[j.cargo]=true end end; local kinds=0; for _ in pairs(cargos) do kinds=kinds+1 end; assert(kinds>=3,"cargo variety");' +
  ' print("Helper workplaces, no bundled pack: "..#board.." Prague van contracts; with trucks unlocked "..n.rigid.." box truck and "..n.semi.." tractor contracts, "..kinds.." kinds of cargo")', 'helper-workplaces')
require('./phone.cjs')
require('./osm.cjs')

run(fs.readFileSync('tests/tow-teleport.lua', 'utf8'), 'tests/tow-teleport.lua')

run(fs.readFileSync('tests/vehicle-state.lua', 'utf8'), 'tests/vehicle-state.lua')

run(fs.readFileSync('tests/gforce.lua', 'utf8'), 'tests/gforce.lua')

run(fs.readFileSync('tests/taxi.lua', 'utf8'), 'tests/taxi.lua')

run(fs.readFileSync('tests/marker.lua', 'utf8'), 'tests/marker.lua')
run(fs.readFileSync('tests/job-settings.lua', 'utf8'), 'tests/job-settings.lua')
run(fs.readFileSync('tests/longhaul.lua', 'utf8'), 'tests/longhaul.lua')
run(fs.readFileSync('tests/coach.lua', 'utf8'), 'tests/coach.lua')
run(fs.readFileSync('tests/phonemap.lua', 'utf8'), 'tests/phonemap.lua')
{
  // The dash phone screen must be lit like the game's own screens: the page only as the emissive map (as base colour
  // too, the cabin light shaded it grey and washed out) at a fixed brightness in nits.
  const mats = JSON.parse(fs.readFileSync('mod/cargo_earth/vehicles/common/cargo_earth_phone/cargo_earth_phone.materials.json', 'utf8'))
  const stage = mats.cargo_earth_phone_screen.Stages[0]
  if (stage.baseColorMap) throw new Error('Dash phone screen must not use the page as its base colour')
  if (stage.emissive !== true || stage.emissiveMap !== '@cargo_earth_phone' || !(stage.emissiveIntensityNits >= 500)) {
    throw new Error('Dash phone screen must glow: emissive true, emissiveMap @cargo_earth_phone, emissiveIntensityNits >= 500')
  }
  console.log('Dash phone screen: emissive at ' + stage.emissiveIntensityNits + ' nits')
}
