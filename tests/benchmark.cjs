// Compare geographic work counts using the real depot pack; this is not a BeamNG FPS benchmark.
const fs = require('node:fs')
const path = require('node:path')
const f = require(process.env.FENGARI_PATH || 'fengari')
const L = f.lauxlib.luaL_newstate()
f.lualib.luaL_openlibs(L)
const root = path.resolve(__dirname, '..')
process.chdir(root)
const modules = 'mod/cargo_earth/lua/ge/extensions'
const source = path.resolve(process.argv[2] || root).replaceAll('\\', '/')
function literal(v) {
  if (v === null) return 'nil'
  if (typeof v === 'string') return JSON.stringify(v)
  if (typeof v !== 'object') return String(v)
  if (Array.isArray(v)) return '{' + v.map(literal).join(',') + '}'
  return '{' + Object.entries(v).map(([k, x]) => '[' + literal(k) + ']=' + literal(x)).join(',') + '}'
}
const pack = JSON.parse(fs.readFileSync(`${modules}/cargoEarth/data/depots_CZ.json`, 'utf8'))
const lua = `package.path='${modules}/?.lua;'..package.path
package.loaded['cargoEarth/jobs']=assert(loadfile('${source}/${modules}/cargoEarth/jobs.lua'))()
local jobs=require('cargoEarth/jobs')
local employment=assert(loadfile('${source}/${modules}/cargoEarth/employment.lua'))()
local count, distance=0,jobs.km
jobs.km=function(...) count=count+1; return distance(...) end
local idx=jobs.index(${literal(pack)})
local board=employment.board(idx,{lat=50.0755,lon=14.4378})
print('Companies: '..#board..'; distance calculations: '..count)
local sparse=jobs.index({depots={
  {id='yard',n='Rural Yard',t='producer',s='S',g={50,14}},
  {id='a',n='Village A',t='receiver',s='S',g={50.04,14}},
  {id='b',n='Village B',t='receiver',s='S',g={50.12,14}}
},cargo={pallets_general={name='Goods',pay=1,trailer='box'}},trailers={},
types={producer={produces={'pallets_general'}},receiver={accepts={'pallets_general'}}}})
local rural=employment.board(sparse,{lat=50,lon=14})
print('Sparse area with two reachable recipients: '..#rural..' company')
sparse.depots[3].g={51,14}
print('Sparse area with one reachable recipient: '..#employment.board(jobs.index(sparse.pack),{lat=50,lon=14})..' companies')`
if (f.lauxlib.luaL_dostring(L, f.to_luastring(lua)) !== f.lua.LUA_OK) throw Error(f.to_jsstring(f.lua.lua_tostring(L, -1)))
