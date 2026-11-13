const fs = require('node:fs')
const vm = require('node:vm')
const assert = require('node:assert/strict')
let directive
const audios = []
const commands = []
const timers = [], destroy = [], pending = [], watches = {}, later = []
let now = 0, hold = false, answer = {screen: 'offline'}, digests = 0
vm.runInNewContext(fs.readFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', 'utf8'), {
  angular: { module: () => ({ directive: (name, factory) => { directive = factory[factory.length - 1]() } }) },
  bngApi: { serializeToLua: JSON.stringify, engineLua: (command, callback) => {
    // BeamNG runs a command without a callback as a Lua statement: an expression like ours would not run at all
    assert(typeof callback === 'function', 'engineLua without a callback never runs: ' + command)
    commands.push(command); if (hold) pending.push(callback); else callback(JSON.parse(JSON.stringify(answer))) } },
  Date: {now: () => now},
  Audio: class { constructor () { this.paused = true; this.attrs = {}; this.on = {}; audios.push(this) } addEventListener (n, f) { this.on[n] = f }
    play () { this.paused = false; this.played = this.src; return {catch () {}} } pause () { this.paused = true }
    getAttribute (n) { return n === 'src' ? this.src : null } removeAttribute () { this.src = undefined } load () {} },
  localStorage: { data: {}, getItem (k) { return this.data[k] || null }, setItem (k, v) { this.data[k] = v } },
  setInterval: (fn, interval) => { timers.push({fn, interval}); return timers.length }, clearInterval: () => {}, setTimeout: fn => { later.push(fn); return later.length }, clearTimeout: id => { if (later[id - 1]) later[id - 1] = () => {} }
})
assert(directive.template.includes('placeSearch.text'))
assert(directive.template.includes('startCompany'))
// Validate template nesting independently of the string concatenation used to author it.
const voids = new Set(['input', 'br', 'img', 'hr', 'meta', 'link'])
const stack = []
for (const tag of directive.template.matchAll(/<(\/?)([a-z][\w-]*)(?:\s+(?:"[^"]*"|'[^']*'|[^'">])*)?\s*\/?\s*>/gi)) {
  const name = tag[2].toLowerCase()
  if (voids.has(name)) continue
  if (tag[1]) assert.equal(stack.pop(), name, `Mismatched closing ${name}`)
  else if (!tag[0].endsWith('/>')) stack.push(name)
}
assert.deepEqual(stack, [])
const scope = {$evalAsync: fn => { digests++; fn() }, $watch: (name, fn) => { watches[name] = fn }, $on: (name, fn) => { if (name === '$destroy') destroy.push(fn) }}
directive.link(scope)
scope.pdo('search', 'Dlouhá \"12\"')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.placesDo, ' + JSON.stringify('search') + ', ' + JSON.stringify('Dlouhá \"12\"'))))
scope.openCompany()
assert.equal(scope.tab, 'orders', 'The phone stays on Work')
assert.equal(scope.panel, 'companies', 'Company contracts open in the menu window')
assert(commands.at(-1).includes('pcall(cargoEarth_core.placesState'))
scope.setTab('home')
assert.equal(scope.panel, 'home', 'Old tab names open their menu section')
assert(commands.at(-1).includes('pcall(cargoEarth_core.placesState'))
scope.setTab('garage')
scope.gview = 'fleet'
scope.setTab('garage')
assert.equal(scope.gview, 'fleet', 'Reselecting Garage should preserve its subpage')
scope.setTab('career')
scope.setCareerView('money')
assert.equal(scope.careerView, 'money')
assert.equal(scope.panelTitle(), 'Finances')
assert(scope.panelOn('career', 'money') && !scope.panelOn('career', 'map'))
assert(commands.at(-1).includes('pcall(cargoEarth_core.careerState'))
scope.setCareerView('map')
assert(commands.at(-1).includes('pcall(cargoEarth_core.mapState'))
scope.setCareerView('firm')
assert(commands.at(-1).includes('pcall(cargoEarth_core.firmState'))
scope.fdo('found', 'Rychlá "kola"')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.firmDo, "found", ' + JSON.stringify('Rychlá "kola"'))))
scope.openHq()
assert(scope.hqOpen && commands.at(-1).includes('pcall(cargoEarth_core.hqState'))
scope.hdo('upgrade', 'bays')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.hqDo, "upgrade", "bays"')))
scope.hq = {upgrades: [{id: 'bays', level: 1, max: 3}]}
assert.deepEqual(Array.from(scope.pips(scope.up('bays'))), [true, false, false])
assert.equal(scope.range(99).length, 12)
scope.moveHq()
assert(scope.moveAsk, 'Moving the headquarters asks first')
scope.closeHq()
assert(!scope.hqOpen)
scope.setCareerView('money')
assert(directive.template.includes('!g.fuel.station.at || !g.fuel.fill || g.fuel.fill.canCost <= 0'), 'Fuel delivery stays available at a station you cannot pay')
assert(directive.template.includes('Parcel route · stop'), 'Template is missing the parcel route card')
for (const text of ['Open headquarters', 'Found the firm', 'Speed camera in', 'class="cehq"', 'Fill up']) {
  assert(directive.template.includes(text), 'Template is missing: ' + text)
}
scope.setTab('home')
scope.s = {screen: 'active', active: {phase: 'toDelivery', to: {name: 'Shop'}}}
assert(scope.showLiveShortcut())
assert.equal(scope.liveDetail(), 'Shop')
scope.openLiveWork()
assert.equal(scope.tab, 'orders')
assert.equal(scope.panel, null, 'Going back to the delivery closes the menu window')
assert(!scope.showLiveShortcut())
scope.setTab('radio')
scope.s = {screen: 'company', company: 'Employer'}
assert(scope.showLiveShortcut())
scope.openLiveWork()
assert.equal(scope.panel, 'companies')
assert(!scope.showLiveShortcut(), 'No shortcut to the page already open')
scope.s = {screen: 'incoming'}
watches['s.screen']('incoming')
assert.equal(scope.tab, 'radio', 'A ringing offer leaves Radio playing on screen')
assert(scope.showLiveShortcut() && scope.liveTitle() === 'New delivery offer', 'the offer bar is on top of Radio')
assert.equal(scope.panel, null, 'Incoming work closes the menu window')
// the Menu button opens the last section again and closes the window
scope.openPanel('settings')
scope.togglePanel()
assert.equal(scope.panel, null)
scope.togglePanel()
assert.equal(scope.panel, 'settings')
scope.closePanel()
for (const text of ['class="cem"', 'cem-close', 'Delivery map']) assert(directive.template.includes(text), 'Template is missing: ' + text)
// radio: one radio for both phones, kept by the game; the page's player makes the sound
hold = false
scope.setTab('orders')
scope.setTab('radio')
assert.equal(scope.tab, 'radio')
assert(commands.some(command => command.includes('cargoEarth_core.phoneTab("radio")')), 'The game hears which page the phone shows')
assert(commands.at(-1).includes('pcall(cargoEarth_core.radioState'))
const stations = [{id: 'a', name: 'Rádio Jih', url: 'http://a/stream', codec: 'MP3', kbps: 128}, {id: 'b', name: 'Two', url: 'https://b/s', codec: 'OGG'}]
const STREAM = 'http://127.0.0.1:47820/v1/stream?id='
scope.rs = {country: 'CZ', countryName: 'Czechia', state: 'ready', top: stations, near: [], stream: STREAM}
scope.radioPlay(stations[0], stations)
assert.equal(scope.radio.status, 'loading')
assert.equal(scope.radio.station.country, 'CZ')
assert(commands.at(-1).includes('pcall(cargoEarth_core.radioDo, "play", {"id":"a"'), 'The press goes to the game')
scope.radioSkip(1)
assert.equal(scope.radio.station.id, 'b')
scope.radioSkip(1)
assert.equal(scope.radio.station.id, 'a', 'Next wraps around the list')
scope.radioVol(1); scope.radioVol(1)
assert.equal(scope.radio.vol, 0.8)
assert(commands.at(-1).includes('"vol", 0.8'))
scope.radioFav(stations[1], {stopPropagation () {}})
assert(scope.isSaved(stations[1]) && commands.at(-1).includes('"fav", {"id":"b"'))
scope.radioToggle()
assert.equal(scope.radio.status, 'idle')
assert(commands.at(-1).includes('"stop"'))
// the game's answer is what both phones show
answer = {country: 'CZ', top: stations, near: [], stream: STREAM,
  radio: {on: true, station: stations[1], status: 'playing', vol: 0.4, via: 'helper', seq: 7, saved: [stations[0]], mode: 'helper'}}
scope.setTab('orders'); scope.setTab('radio')
assert.equal(scope.radio.status, 'playing')
assert.equal(scope.radio.station.id, 'b')
assert.equal(scope.radio.vol, 0.4)
assert(scope.radio.via === 'helper' && scope.isSaved(stations[0]) && !scope.isSaved(stations[1]))
// the other phone changes the station: the quick poll says so, and this phone asks for the rest
let asking = commands.length
watches['s.radio']({status: 'loading', seq: 8, name: 'Other'})
assert(commands.length > asking && commands.at(-1).includes('pcall(cargoEarth_core.radioState'))
asking = commands.length
watches['s.radio']({status: 'playing', seq: 9, name: 'Two'})
assert.equal(commands.length, asking + 1, 'a new number each time asks again')
watches['s.radio'](undefined)
assert.equal(scope.radio.status, 'idle', 'Nothing plays: the phone shows it stopped')
scope.radioVia('page')
assert(commands.at(-1).includes('"via", "page"'))
scope.radioPlay({id: 'x', name: 'Bad', url: 'javascript:alert(1)'})
assert.equal(scope.radio.status, 'error', 'Only web streams are played')
// The page's player: one on the page, it checks in with the game and plays what the game says the page should play
assert.equal(audios.length, 1, 'one player for the page')
const player = timers.find(timer => timer.interval === 500).fn
answer = {radio: {on: true, mode: 'page', station: stations[0], seq: 3, vol: 0.5}, stream: STREAM}
now += 3000; player()
assert(commands.at(-1).includes('cargoEarth_core.radioDo("page", -1, "idle"'))
assert.equal(audios[0].src, STREAM + 'a', 'The game plays the station through the helper, not straight from the web')
assert.equal(audios[0].volume, 0.5)
audios[0].on.playing()
now += 500; player()
assert(commands.at(-1).includes('radioDo("page", 3, "playing"'), 'it says the sound is on')
audios[0].error = {code: 4}
// a dropped stream is tried again twice, then the game hears of it (and the helper plays the station)
asking = commands.length
audios[0].on.error()
assert(!audios[0].src && commands.length === asking, 'the first drop is not reported')
now += 500; player()
assert(!audios[0].src, 'the check-in waits for the retry')
later.splice(0).forEach(fn => fn())
assert.equal(audios[0].src, STREAM + 'a', 'the same stream is asked again')
audios[0].on.ended()
later.splice(0).forEach(fn => fn())
assert.equal(audios[0].src, STREAM + 'a', 'a live stream that ends has dropped too')
audios[0].on.error()
assert(commands.at(-1).includes('radioDo("page", 3, "error", "error 4")'), 'the third drop in a row is reported')
later.splice(0).forEach(fn => fn())
answer = {radio: {on: true, mode: 'helper', station: stations[0], seq: 3, vol: 0.5}, stream: STREAM}
now += 500; player()
assert(!audios[0].src, 'the helper plays it: the page stays silent')
answer = {radio: {on: false, mode: 'page', station: stations[0], seq: 3, vol: 0.5}, stream: STREAM}
now += 500; player()
asking = commands.length
now += 500; player()
assert.equal(commands.length, asking, 'with nothing playing the player checks in every 2 s')
now += 2000; player()
assert.equal(commands.length, asking + 1)
// a Work/Radio choice made on the other phone shows here
answer = {screen: 'offline', tab: 'radio'}
scope.setTab('orders')
now += 2000
for (const t of timers.filter(timer => timer.interval === 250)) t.fn()
assert.equal(scope.tab, 'radio', 'the phone follows the page chosen on the other phone')
answer = {screen: 'offline', tab: 'orders'}
scope.setTab('radio')
now += 300
for (const t of timers.filter(timer => timer.interval === 250)) t.fn()
assert.equal(scope.tab, 'radio', 'a choice made here a moment ago is not undone by an older answer')
answer = {screen: 'offline'}
assert(directive.template.includes('radio-browser.info'))
assert(directive.template.includes('aria-label="Job type"') && directive.template.includes("act('mode', 'trucking')"), 'the offline screen switches the job type')
scope.setTab('orders')
scope.setTab('invalid')
assert.equal(scope.tab, 'orders')
assert(directive.template.includes('aria-label="Phone sections"'))
assert(directive.template.includes('Latest transactions'))
const poll = timers.find(timer => timer.interval === 250).fn
const slow = timers.find(timer => timer.interval === 1000).fn
scope.fold(true)
const before = commands.length
const t0 = now
for (now = t0 + 250; now <= t0 + 10000; now += 250) poll()
assert.equal(commands.length - before, 5, 'Folded phone should poll once every two seconds')
scope.fold(false)
// Open: twice a second; an answer equal to the last one is not handed to Angular (no digest, no redraw).
let asked = commands.length, digested = digests
for (now = t0 + 10250; now <= t0 + 20000; now += 250) poll()
assert.equal(commands.length - asked, 20, 'An open phone polls twice a second')
assert(digests - digested <= 1, 'Unchanged answers must not start a digest')
// Standing in the stop zone the bar fills: four times a second.
answer = {screen: 'active', active: {stop: {inZone: true, frac: 0}}}
poll(); now += 250
asked = commands.length
for (let i = 0; i < 8; i++) { answer.active.stop.frac = i / 8; poll(); now += 250 }
assert.equal(commands.length - asked, 8, 'The stop bar polls four times a second')
assert.equal(scope.s.active.stop.frac, 7 / 8, 'A changed answer reaches the phone')
// Clearing the shown state (closing the Menu window) must not make the same answer be ignored.
scope.s = null
now += 500; poll()
assert.equal(scope.s && scope.s.screen, 'active', 'The same answer comes back after the state was cleared')
answer = {screen: 'offline'}
poll(); now += 500; poll()
scope.s = {screen: 'offline'}
hold = true
scope.setTab('career')
// the phone first asks the game to show the Menu window elsewhere (the Menu app); no Menu app here, so it opens on the phone
assert(commands[commands.length - 1].includes('cargoEarth_core.openMenu("career"'))
const start = commands.length
pending.shift()(false)
slow(); slow()
assert.equal(commands.length - start, 1, 'A delayed page response must not create overlapping requests')
// A lost callback must time out, and an old response must not replace a newer page.
now += 6000
slow()
assert.equal(commands.length - start, 2)
pending.shift()({rank: 'stale'})
assert.notEqual(scope.career && scope.career.rank, 'stale')
pending.shift()({rank: 'fresh'})
assert.equal(scope.career.rank, 'fresh')
scope.setTab('garage')
pending.shift()(false)
pending.shift()({_phoneError: 'pricing failed'})
assert(scope.pageErrors.g.includes('pricing failed'))
scope.s = {screen: 'parts'}
scope.retryGarage()
pending.shift()({started: true, parts: {error: 'Unknown part', canBuy: false}})
assert(scope.g.parts && !scope.g.parts.canBuy)
assert.equal(scope.pageErrors.g, null)
assert(directive.template.includes('Discard preview and restore car'))
assert.equal(fs.readFileSync('mod/cargo_earth/lua/ge/extensions/cargoEarth/core.lua', 'utf8').match(/M\.VERSION = '([^']+)'/)[1],
  JSON.parse(fs.readFileSync('package.json', 'utf8')).version, 'core.lua VERSION matches package.json (bump both)')
// Settings > Help: the support report carries the phone's own errors
assert(directive.template.includes('Copy support report'))
scope.copyReport()
assert(commands.at(-1).includes('cargoEarth_core.supportReport'))
assert(commands.at(-1).includes('garageState: pricing failed'), 'the phone error from before is in the report request')
pending.shift()({text: 'report', copied: true})
assert.equal(scope.report.text, 'report')
scope.closeReport()
assert.equal(scope.report, null)
// Leave a late response queued to verify teardown.
scope.setTab('career')
for (const fn of destroy) fn()
const stopped = commands.length
now += 10000; poll()
assert.equal(commands.length, stopped)
pending.shift()({rank: 'late response'})
assert.notEqual(scope.career && scope.career.rank, 'late response')
console.log('Phone: navigation, active-work shortcuts, template, Unicode, folded polling, backpressure and teardown verified')
// The holder page's own styles must not reuse a class of the phone app's (a fixed .cep-dot squeezed the stop names)
{
  const page = fs.readFileSync('mod/cargo_earth/vehicles/common/cargo_earth_phone/phone.html', 'utf8')
  const app = fs.readFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', 'utf8')
  const own = [...page.matchAll(/^\s*\.(cep-[\w-]+)\s*\{/gm)].map(m => m[1])
  assert(own.length > 0)
  for (const c of own) assert(!new RegExp('\\.' + c + '(?![\\w-])').test(app), 'phone.html styles .' + c + ', a class of the phone app')
}
// The Menu window: two copies of the Menu app on the page (a layout reload can leave an old one listening) answer one
// request once, and a window opened anywhere closes the other, so two never lie over each other
{
  const menus = [0, 1].map(() => {
    const on = {}
    const s = {$evalAsync: fn => fn(), $watch: () => {}, $on: (name, fn) => { on[name] = fn }}
    directive.link(s, {attr: () => 'menu', 0: {querySelector: () => null}})
    return {s, on}
  })
  const request = {panel: 'settings', to: 'menu'}
  for (const m of menus) m.on.CargoEarthOpenMenu({}, request)
  assert.equal(menus.filter(m => m.s.panel).length, 1, 'one request opens one window')
  menus[1].s.openPanel('garage', undefined, true)
  assert(!menus[0].s.panel && menus[1].s.panel === 'garage', 'opening a window closes the other one')
  const toggle = {panel: 'toggle', to: 'menu'}
  for (const m of menus) m.on.CargoEarthOpenMenu({}, toggle)
  assert(!menus[0].s.panel && !menus[1].s.panel, 'the Menu button closes the open window, wherever it is')
  // the Menu button reopens the page shown last: the car list while looking at cars
  menus[0].s.openPanel('garage', undefined, true)
  menus[0].s.openCars()
  menus[0].s.look('listing-1')
  assert.equal(menus[0].s.gview, 'cars', 'looking at a car stays on the car list')
  menus[0].s.closePanel()
  const again = {panel: 'toggle', to: 'menu'}
  for (const m of menus) m.on.CargoEarthOpenMenu({}, again)
  assert(menus[0].s.panel === 'garage' && menus[0].s.gview === 'cars', 'the Menu reopens on the car list')
  menus[0].s.openPanel('settings', undefined, true)
  menus[0].s.openPanel('garage', undefined, true)
  assert.equal(menus[0].s.gview, 'home', 'Garage chosen from another section starts on its first page')
}
