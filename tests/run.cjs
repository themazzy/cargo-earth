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
console.log('Lua syntax: all career modules compile')
run(`package.path = '${extensions}/?.lua;' .. package.path`, 'test-path')
run(fs.readFileSync('tests/helper.lua', 'utf8'), 'tests/helper.lua')
run(fs.readFileSync('tests/career.lua', 'utf8'), 'tests/career.lua')
// Exercise the actual supplied freight pack as well as the small rule fixtures.
function toLua(value) {
  if (value === null) return 'nil'
  if (typeof value === 'string') return JSON.stringify(value).replace(/\\u([0-9a-f]{4})/gi, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return '{' + value.map(toLua).join(',') + '}'
  return '{' + Object.entries(value).map(([key, item]) => '[' + toLua(key) + ']=' + toLua(item)).join(',') + '}'
}
const pack = JSON.parse(fs.readFileSync(`${extensions}/cargoEarth/data/depots_CZ.json`, 'utf8'))
run('local jobs=require("cargoEarth/jobs"); local employment=require("cargoEarth/employment"); local pack=' + toLua(pack) +
  '; local board=employment.board(jobs.index(pack),{lat=50.0755,lon=14.4378}); assert(#board>0,"No Prague company contracts"); print("Czech data: "..#board.." Prague company contracts available")', 'actual-depot-data')
require('./phone.cjs')
