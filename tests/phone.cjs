const fs = require('node:fs')
const vm = require('node:vm')
const assert = require('node:assert/strict')
let directive
const commands = []
const timers = [], destroy = [], pending = [], watches = {}
let now = 0, hold = false
vm.runInNewContext(fs.readFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', 'utf8'), {
  angular: { module: () => ({ directive: (name, factory) => { directive = factory[factory.length - 1]() } }) },
  bngApi: { serializeToLua: JSON.stringify, engineLua: (command, callback) => { commands.push(command); if (hold) pending.push(callback); else callback({screen: 'offline'}) } },
  Date: {now: () => now},
  setInterval: (fn, interval) => { timers.push({fn, interval}); return timers.length }, clearInterval: () => {}, setTimeout: () => 1
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
const scope = {$evalAsync: fn => fn(), $watch: (name, fn) => { watches[name] = fn }, $on: (name, fn) => { if (name === '$destroy') destroy.push(fn) }}
directive.link(scope)
scope.pdo('search', 'Dlouhá \"12\"')
assert(commands.some(command => command.includes('pcall(cargoEarth_core.placesDo, ' + JSON.stringify('search') + ', ' + JSON.stringify('Dlouhá \"12\"'))))
scope.openCompany()
assert.equal(scope.tab, 'orders')
assert.equal(scope.workView, 'companies')
assert(commands.at(-1).includes('pcall(cargoEarth_core.placesState'))
scope.setTab('home')
assert(commands.at(-1).includes('pcall(cargoEarth_core.placesState'))
scope.setTab('garage')
scope.gview = 'fleet'
scope.setTab('garage')
assert.equal(scope.gview, 'fleet', 'Reselecting Garage should preserve its subpage')
scope.setTab('career')
scope.setCareerView('money')
assert.equal(scope.careerView, 'money')
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
assert.equal(scope.workView, 'deliveries')
assert(!scope.showLiveShortcut())
scope.setTab('home')
scope.s = {screen: 'company', company: 'Employer'}
scope.openLiveWork()
assert.equal(scope.workView, 'companies')
watches['s.screen']('incoming')
assert.equal(scope.workView, 'deliveries', 'Incoming work must open the actual delivery view')
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
scope.s = {screen: 'offline'}
hold = true
const start = commands.length
scope.setTab('career')
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
pending.shift()({_phoneError: 'pricing failed'})
assert(scope.pageErrors.g.includes('pricing failed'))
scope.s = {screen: 'parts'}
scope.retryGarage()
pending.shift()({started: true, parts: {error: 'Unknown part', canBuy: false}})
assert(scope.g.parts && !scope.g.parts.canBuy)
assert.equal(scope.pageErrors.g, null)
assert(directive.template.includes('Discard preview and restore car'))
// Leave a late response queued to verify teardown.
scope.setTab('career')
for (const fn of destroy) fn()
const stopped = commands.length
now += 10000; poll()
assert.equal(commands.length, stopped)
pending.shift()({rank: 'late response'})
assert.notEqual(scope.career && scope.career.rank, 'late response')
console.log('Phone: navigation, active-work shortcuts, template, Unicode, folded polling, backpressure and teardown verified')
// The dash phone matrix puts the phone's four corners exactly on the points the game projected.
{
  const c = [0.8166, -0.1234, 1.1807, -0.1351, 1.1948, -0.8142, 0.8049, -0.739]
  const W = 1920, H = 1080
  const m = directive.dashMatrix(c, W, H)
  assert(m && m.length === 16)
  const corners = [[0, 0], [290, 0], [290, 560], [0, 560]]
  corners.forEach(([x, y], i) => {
    const X = m[0] * x + m[4] * y + m[12], Y = m[1] * x + m[5] * y + m[13], Wt = m[3] * x + m[7] * y + m[15]
    assert(Wt > 0)
    assert(Math.abs(X / Wt - (W / 2 + c[2 * i] * H / 2)) < 1e-6, 'x of corner ' + i)
    assert(Math.abs(Y / Wt - (H / 2 - c[2 * i + 1] * H / 2)) < 1e-6, 'y of corner ' + i)
  })
  assert.equal(directive.dashMatrix([1, 2], W, H), null)
  console.log('Dash phone: the phone lands on the projected corners')
}
