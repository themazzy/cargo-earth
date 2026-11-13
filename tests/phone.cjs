const fs = require('node:fs')
const vm = require('node:vm')
const assert = require('node:assert/strict')
let directive
const audios = []
const commands = []
const timers = [], destroy = [], pending = [], watches = {}
let now = 0, hold = false, answer = {screen: 'offline'}, digests = 0
vm.runInNewContext(fs.readFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', 'utf8'), {
  angular: { module: () => ({ directive: (name, factory) => { directive = factory[factory.length - 1]() } }) },
  bngApi: { serializeToLua: JSON.stringify, engineLua: (command, callback) => { commands.push(command); if (hold) pending.push(callback); else callback(JSON.parse(JSON.stringify(answer))) } },
  Date: {now: () => now},
  Audio: class { constructor () { this.paused = true; this.attrs = {}; this.on = {}; audios.push(this) } addEventListener (n, f) { this.on[n] = f }
    play () { this.paused = false; this.played = this.src; return {catch () {}} } pause () { this.paused = true }
    getAttribute (n) { return n === 'src' ? this.src : null } removeAttribute () { this.src = undefined } load () {} },
  localStorage: { data: {}, getItem (k) { return this.data[k] || null }, setItem (k, v) { this.data[k] = v } },
  setInterval: (fn, interval) => { timers.push({fn, interval}); return timers.length }, clearInterval: () => {}, setTimeout: () => 1, clearTimeout: () => {}
})
assert(directive.template.includes('Find nearby addresses'))
assert(directive.template.includes('Start company contract'))
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
watches['s.screen']('incoming')
assert.equal(scope.tab, 'orders', 'Incoming work must open the actual delivery view')
assert.equal(scope.panel, null, 'Incoming work closes the menu window')
// the Menu button opens the last section again and closes the window
scope.openPanel('settings')
scope.togglePanel()
assert.equal(scope.panel, null)
scope.togglePanel()
assert.equal(scope.panel, 'settings')
scope.closePanel()
for (const text of ['class="cem"', 'Back to the phone', 'Delivery map']) assert(directive.template.includes(text), 'Template is missing: ' + text)
// radio: the list comes from the game, the stream plays in the page and keeps playing on other tabs
hold = false
scope.setTab('radio')
assert.equal(scope.tab, 'radio')
assert(commands.at(-1).includes('pcall(cargoEarth_core.radioState'))
const stations = [{id: 'a', name: 'Rádio Jih', url: 'http://a/stream', codec: 'MP3', kbps: 128}, {id: 'b', name: 'Two', url: 'https://b/s', codec: 'OGG'}]
const STREAM = 'http://127.0.0.1:47820/v1/stream?id='
scope.rs = {country: 'CZ', countryName: 'Czechia', state: 'ready', top: stations, near: [], stream: STREAM}
scope.radioPlay(stations[0], stations)
assert.equal(scope.radio.status, 'loading')
assert.equal(audios[0].src, STREAM + 'a', 'The game plays the station through the helper, not straight from the web')
assert.equal(scope.radio.station.country, 'CZ')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.radioDo, "played", "a"')))
scope.radioSkip(1)
assert.equal(scope.radio.station.id, 'b')
scope.radioSkip(1)
assert.equal(scope.radio.station.id, 'a', 'Next wraps around the list')
scope.radioVol(1); scope.radioVol(1)
assert.equal(scope.radio.vol, 0.8)
scope.radioFav(stations[1], {stopPropagation () {}})
assert(scope.isSaved(stations[1]))
scope.radioToggle()
assert.equal(scope.radio.status, 'idle')
// the game's browser refuses the stream: the helper plays it, and keeps doing so
scope.radioPlay(stations[0], stations)
audios[0].error = {code: 4}
audios[0].on.error()
assert.equal(scope.radio.via, 'page', 'One station the game cannot play does not change the setting')
assert(scope.radio.alone, 'but the helper plays that one')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.radioDo, "helperPlay", "a", 0.8')))
scope.rs = {country: 'CZ', top: stations, near: [], stream: STREAM, player: {playing: true, sound: false, secs: 0, player: 'powershell'}}
scope.setTab('orders'); scope.setTab('radio')
assert.equal(scope.radio.status, 'loading', 'No sound from the helper yet: still tuning in, not "playing"')
scope.radioVol(-1)
assert(commands.some(command => command.includes('"helperVolume", 0.7')))
pending.length = 0; hold = true
scope.setTab('radio')
pending.shift()({country: 'CZ', top: stations, near: [], stream: STREAM, player: {playing: false, error: null}})
hold = false
assert.equal(scope.radio.status, 'idle', 'A player that stopped by itself shows as stopped, so Play works again')
scope.radioPlay(stations[0], stations)
scope.radioStop()
assert(commands.at(-1).includes('"helperStop"'))
assert(!scope.radio.alone)
scope.radioPlay(stations[1], stations)
assert(!audios[0].paused)
scope.radioPlay({id: 'c', name: 'AAC', url: 'http://c/s', codec: 'AAC+'}, stations)
assert(scope.radio.alone, 'The game has no AAC: the helper plays those')
assert(audios[0].paused && !audios[0].src, 'The station the game played stops when the helper takes over')
scope.radioStop()
scope.radioVia('helper')
assert.equal(scope.radio.via, 'helper')
scope.radioVia('page')
assert.equal(scope.radio.via, 'page')
scope.radioPlay({id: 'x', name: 'Bad', url: 'javascript:alert(1)'})
assert.equal(scope.radio.status, 'error', 'Only web streams are played')
assert(directive.template.includes('Stations from Radio Browser'))
scope.setTab('orders')
scope.setTab('invalid')
assert.equal(scope.tab, 'orders')
assert(directive.template.includes('aria-label="Phone sections"'))
assert(directive.template.includes('Recent transactions'))
const poll = timers.find(timer => timer.interval === 250).fn
const slow = timers.find(timer => timer.interval === 1000).fn
scope.fold(true)
const before = commands.length
for (now = 250; now <= 10000; now += 250) poll()
assert.equal(commands.length - before, 5, 'Folded phone should poll once every two seconds')
scope.fold(false)
// Open: twice a second; an answer equal to the last one is not handed to Angular (no digest, no redraw).
let asked = commands.length, digested = digests
for (now = 10250; now <= 20000; now += 250) poll()
assert.equal(commands.length - asked, 20, 'An open phone polls twice a second')
assert(digests - digested <= 1, 'Unchanged answers must not start a digest')
// Standing in the stop zone the bar fills: four times a second.
answer = {screen: 'active', active: {stop: {inZone: true, frac: 0}}}
poll(); now += 250
asked = commands.length
for (let i = 0; i < 8; i++) { answer.active.stop.frac = i / 8; poll(); now += 250 }
assert.equal(commands.length - asked, 8, 'The stop bar polls four times a second')
assert.equal(scope.s.active.stop.frac, 7 / 8, 'A changed answer reaches the phone')
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
