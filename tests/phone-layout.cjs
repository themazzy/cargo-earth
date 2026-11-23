const assert = require('node:assert/strict')

// Structural reachability audit of the actual directive. This is not a pixel/layout engine.
module.exports = function auditPhoneLayout (directive) {
  const template = directive.template
  const nodes = [], parents = []
  const voids = new Set(['input', 'br', 'img', 'hr', 'meta', 'link'])
  for (const tag of template.matchAll(/<(\/?)([a-z][\w-]*)(?:\s+(?:"[^"]*"|'[^']*'|[^'">])*)?\s*\/?\s*>/gi)) {
    const name = tag[2].toLowerCase()
    if (tag[1]) { assert.equal(parents.pop().name, name); continue }
    const attrs = Object.fromEntries(Array.from(tag[0].matchAll(/([\w:-]+)\s*=\s*"([^"]*)"/g), m => [m[1], m[2]]))
    const node = {name, attrs, ancestors: parents.slice(), classes: new Set((attrs.class || '').split(/\s+/))}
    nodes.push(node)
    if (!voids.has(name) && !tag[0].endsWith('/>')) parents.push(node)
  }
  assert.equal(parents.length, 0)
  const fare = nodes.find(n => n.attrs['aria-label'] === 'Taxi fare breakdown')
  assert(fare && fare.ancestors.some(n => n.classes.has('cep-order-scroll')), 'Taxi fare details must scroll without displacing Accept/Decline')
  assert(fare.ancestors.some(n => (n.attrs['ng-if'] || '').includes("s.screen === 'incoming'")), 'Fare breakdown belongs to the incoming offer')
  const scrollAncestor = n => n.ancestors.find(p => p.classes.has('cep-scroll') || p.classes.has('cep-center'))
  const buttons = nodes.filter(n => n.name === 'button')
  let actionGroups = 0
  const pinned = (name, match, context = () => true) => {
    const found = buttons.filter(n => match(n.attrs['ng-click'] || '') && context(n))
    assert(found.length > 0, 'Missing action: ' + name)
    for (const node of found) assert(!scrollAncestor(node), name + ' is buried in scrolling content')
    actionGroups++
  }
  for (const command of ['accept', 'decline', 'resume', 'freePlay', 'dismiss', 'busDoors',
    'busSkip', 'busEnd', 'busRetry', 'coachRetry', 'busCancelSelection', 'towLoad', 'towHitch', 'restoreTrailer']) {
    pinned(command, click => click === "act('" + command + "')")
  }
  const screenForAction = {
    accept: ['incoming'], decline: ['incoming'], resume: ['resume'], freePlay: ['choose', 'resume'],
    dismiss: ['done', 'failed'], busDoors: ['active'], busSkip: ['active'], busEnd: ['active', 'offline'],
    busRetry: ['offline'], coachRetry: ['offline'], busCancelSelection: ['offline'], towLoad: ['active'], towHitch: ['active'], restoreTrailer: ['active']
  }
  for (const [command, screens] of Object.entries(screenForAction)) {
    for (const button of buttons.filter(n => n.attrs['ng-click'] === "act('" + command + "')")) {
      const body = button.ancestors.find(n => n.classes.has('cep-body'))
      assert(body && screens.some(screen => (body.attrs['ng-if'] || '').includes("s.screen === '" + screen + "'")),
        command + ' escaped its screen when it was moved out of the scroller')
    }
  }
  pinned('start a named career', click => click === 'newCareer()', n =>
    (n.ancestors.find(a => a.classes.has('cep-body')).attrs['ng-if'] || '').includes("s.screen === 'choose'"))
  pinned('navigate', click => click === "act('gps')")
  pinned('cancel or view contract', click => click === 'confirmCancel()')
  pinned('parts checkout', click => click.startsWith("gdo('buyParts'"))
  pinned('discard parts preview', click => click === "gdo('cancelParts')")
  pinned('buy previewed car', click => click.startsWith("gdo('buyListing'"))
  pinned('return from preview', click => click === "gdo('back')")
  pinned('garage career start', click => click === "gdo('start')")
  pinned('company settlement', click => click === "pdo('settleCompany')")
  pinned('end company work', click => click === 'endCompany()')
  pinned('open contract', click => click === 'openCompany()', n =>
    n.ancestors.some(p => (p.attrs['ng-if'] || '').includes("s.screen === 'company'")))
  pinned('all contracts', click => click === "setTab('companies')")
  pinned('radio play/stop', click => click === 'radioToggle()')
  pinned('radio previous/next', click => click.startsWith('radioSkip('))
  pinned('radio volume', click => click.startsWith('radioVol('))
  pinned('menu close', click => click === 'closePanel()')
  pinned('headquarters close', click => click === 'closeHq()')
  pinned('claim home', click => click === 'claimHome()')
  for (const command of ['towHome', 'towHq', 'wreckRepair', 'wreckClose']) pinned('write-off ' + command, click => click === "act('" + command + "')")
  for (const command of ['homeGps', 'companyGps']) {
    pinned(command, click => click === "pdo('" + command + "')")
  }
  for (const command of ['repair', 'roadside', 'openParts']) {
    pinned(command, click => click === "gdo('" + command + "')")
  }
  for (const action of ['openFleet()', 'openCars()', 'goHome()']) {
    pinned('garage navigation ' + action, click => click === action,
      n => n.ancestors.some(p => p.attrs['aria-label'] === 'Garage sections'))
  }
  const screens = ['error', 'resume', 'parts', 'choose', 'offline', 'waiting', 'incoming', 'active', 'failed', 'done', 'company']
  for (const screen of screens) {
    const found = nodes.filter(n => n.classes.has('cep-body') && (n.attrs['ng-if'] || '').includes("s.screen === '" + screen + "'"))
    assert.equal(found.length, 1, 'Work screen is missing or duplicated: ' + screen)
  }
  for (const panel of ['garage', 'settings', 'home', 'companies', 'career']) {
    assert(nodes.some(n => n.classes.has('cep-body') && (n.attrs['ng-if'] || '').includes("panel === '" + panel + "'")),
      'Missing menu section: ' + panel)
  }
  assert(nodes.some(n => n.classes.has('cep-notices')), 'Unbounded alerts can displace the action bar')
  // Work: one row of job type buttons (no pop-up: it could not be scrolled with the holder's buttons in VR)
  const workModes = nodes.filter(n => n.name === 'button' && n.ancestors.some(p => p.classes.has('cep-work-modes')))
  assert.equal(workModes.length, 1, 'Work has one repeated job type button')
  assert(workModes[0].attrs['ng-disabled'].includes('canSwitch'), 'An active job or shift must lock its work category')
  assert(!scrollAncestor(workModes[0]), 'Work category must stay above the scroll area')
  assert(template.includes('Finish or cancel the current job to switch.'), 'A locked switcher says why')
  const jobSelect = nodes.filter(n => n.name === 'button' && n.classes.has('cep-mode-select'))
  assert.equal(jobSelect.length, 1, 'Jobs settings keeps its job type list')
  assert.equal(jobSelect[0].attrs['aria-label'], 'Job type to configure')
  assert(!jobSelect[0].attrs['ng-disabled'], 'Editing future job settings must not require switching active work')
  const modeMenus = nodes.filter(n => n.classes.has('cep-mode-menu'))
  assert.equal(modeMenus.length, 1)
  assert(modeMenus[0].ancestors.some(p => p.classes.has('cep-scroll')), 'The job type list opens inside the scroll area (VR scroll buttons)')
  assert(!/\.cep-mode-menu\{[^}]*(position:absolute|overflow-y)/.test(template), 'The job type list must not scroll on its own')
  pinned('Jobs settings back', click => click === 'closeJobsSettings()')
  pinned('Apply job distances', click => click === 'saveJobRange()')
  pinned('Reset selected job type', click => click === 'resetJobRange()')
  for (const command of ['online', 'offline']) pinned(command, click => click === "act('" + command + "')")
  assert(template.includes('.cep-actionbar{flex:0 0 auto;'), 'Actions must not shrink with the detail list')
  assert(template.includes('.cep-body>.cep-row'), 'Incoming Accept/Decline row must not shrink')
  assert(template.includes('.cep-center{flex:1;min-height:0;overflow-y:auto;'), 'Long receipts/errors need their own scroller')
  assert(template.includes('.cep-radio-now{flex:0 0 auto;'), 'Radio controls must stay above the station browser')
  assert(template.includes('.cem-main{flex:1;min-width:0;min-height:0;'), 'Menu sections must shrink inside the dialog')
  assert(template.includes('.cep-row{display:flex;flex-wrap:wrap;'), 'Narrow action rows must wrap')
  assert(template.includes('.cep-foot{') && !template.includes('.cep-foot{padding:5px 12px;font-size:11px;white-space:nowrap;'),
    'Fuel/damage status must wrap instead of being silently truncated')
  assert(template.includes('@media(max-width:700px)'), 'The headquarters needs a narrow-screen layout')
  console.log('Phone layout: 11 work states, all menu sections and ' + actionGroups + ' critical action groups structurally audited')
}
