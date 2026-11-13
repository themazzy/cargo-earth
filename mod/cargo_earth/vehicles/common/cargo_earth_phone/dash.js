// The phone page on the dash. In the game's UI the phone app talks to the game with bngApi.engineLua(command, callback);
// a car's screen page has no bngApi, only beamng.sendEngineLua (one way). So this file stands in for bngApi: each
// question goes to cargoEarth_core.dashCall with a number, and the answer comes back as cargoEarthDash.reply(number,
// value) through the car (controller cargoEarthPhone). Presses on the screen come in as cargoEarthDash.tap(u, v):
// u, v from 0 to 1 across and down the screen; the element there is clicked. The scroll buttons beside the phone come in
// as scroll(dir); the page sees the other buttons' effect at its next look (twice a second).
(function () {
  'use strict'
  var params = new URLSearchParams(window.location.search)
  var vehicle = Number(params.get('vehicle'))
  var pending = {}
  var next = 1

  function luaString(s) {
    return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r') + '"'
  }

  // JavaScript value -> Lua literal, like the game UI's bngApi.serializeToLua
  function toLua(v) {
    if (v === null || v === undefined) return 'nil'
    if (typeof v === 'boolean') return v ? 'true' : 'false'
    if (typeof v === 'number') return isFinite(v) ? String(v) : 'nil'
    if (typeof v === 'string') return luaString(v)
    if (Array.isArray(v)) return '{' + v.map(toLua).join(',') + '}'
    if (typeof v === 'object') {
      return '{' + Object.keys(v).map(function (k) { return '[' + luaString(k) + ']=' + toLua(v[k]) }).join(',') + '}'
    }
    return 'nil'
  }

  function engineLua(command, callback) {
    if (typeof beamng === 'undefined' || !beamng.sendEngineLua || !Number.isInteger(vehicle)) return
    var id = next++
    if (next > 1e9) next = 1
    if (callback) pending[id] = { cb: callback, at: Date.now() }
    beamng.sendEngineLua('if cargoEarth_core and cargoEarth_core.dashCall then cargoEarth_core.dashCall(' + vehicle + ',' +
      id + ',' + luaString(command) + ') end')
  }

  // answers that never came (game busy, mod reloaded) must not block the app's next poll forever
  setInterval(function () {
    var now = Date.now()
    Object.keys(pending).forEach(function (id) {
      if (now - pending[id].at > 3000) { var cb = pending[id].cb; delete pending[id]; try { cb(null) } catch (e) { /* app gone */ } }
    })
  }, 1000)

  function reply(id, value) {
    var p = pending[id]
    if (!p) return
    delete pending[id]
    p.cb(value)
  }

  function tap(u, v) {
    var x = u * window.innerWidth, y = v * window.innerHeight
    var el = document.elementFromPoint(x, y)
    var dot = document.createElement('div')
    dot.className = 'cep-dot'
    dot.style.left = x + 'px'
    dot.style.top = y + 'px'
    document.body.appendChild(dot)
    setTimeout(function () { dot.style.opacity = '0'; dot.style.transform = 'scale(1.8)' }, 30)
    setTimeout(function () { if (dot.parentNode) dot.parentNode.removeChild(dot) }, 450)
    if (!el) return
    var target = el.closest ? (el.closest('button, a, input, select, [ng-click]') || el) : el
    if (target.focus) target.focus()
    target.click()
  }


  // Scrolling: a cockpit trigger can only press, not drag, so the buttons beside the phone scroll the longest part of
  // the screen that can scroll (the car's controller calls scroll(-1) or scroll(1)).
  function scroller() {
    var best = null
    var list = document.querySelectorAll('.cep-scroll')
    for (var i = 0; i < list.length; i++) {
      var el = list[i]
      if (!el.getClientRects().length || el.scrollHeight <= el.clientHeight + 2) continue
      if (!best || el.clientHeight > best.clientHeight) best = el
    }
    return best
  }
  function scroll(dir) {
    var el = scroller()
    if (el) el.scrollTop += dir * Math.round(el.clientHeight * 0.7)
  }
  window.bngApi = { engineLua: engineLua, serializeToLua: toLua }
  window.cargoEarthDash = { tap: tap, reply: reply, page: true, scroller: scroller, scroll: scroll }
}())
