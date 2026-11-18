// Cargo Earth phone: a UI app that shows the courier's phone. Asks the game for the phone's state 4 times a second
// (cargoEarth_core.phoneState(): one small Lua call) and sends the buttons back (cargoEarth_core.phoneAction(name)).
// Screens: error, offline, waiting, incoming (with a countdown), active (pickup / delivery), done (pay and tip).
// The phone has Work and Radio; Menu opens a big window (Garage, Home, Companies, Progress, Finances, Delivery map, Firm, Settings). The firm's
// headquarters is a full-screen plan of the building (office, workshop, parts storage, yard, tank) opened from Menu → Firm. Everything is
// clicked here: the mod has no key bindings. The "–" button folds the phone to a small bar; a ringing order opens it.
// The radio's player on the game's UI page: one per page, started by the first floating phone (or Menu app) and kept
// for the page's life, so the radio plays on while the phone app is hidden (in the cockpit, or removed). The game keeps
// the radio (cargoEarth_core.radioDo); this player checks in twice a second, plays the station when the game says the
// page should, and says how it goes. A station the page cannot play goes to the helper (the game decides).
var cargoEarthRadioPlayer = null
// The Menu window, one per page: the app whose window is open. Opening one closes any other, so two never lie over
// each other, however many copies of an app the page holds (a layout reload can leave an old one listening).
var cargoEarthMenu = {open: null, last: null} // last: the section shown last, where the Menu button reopens
// How the phone looked last (folded, dark), kept by the page and its storage. The game rebuilds the UI apps when the
// camera changes (cockpit and back): a rebuilt phone draws its first frame from this, not open and light until the
// game answers. With nothing kept yet (the very first start) the phone stays invisible until the game's first answer.
var cargoEarthLook = (function () {
  var look = {known: false, min: false, dark: false}
  try {
    var kept = JSON.parse(localStorage.getItem('cargoEarth.look') || 'null')
    if (kept && typeof kept === 'object') { look.known = true; look.min = !!kept.min; look.dark = !!kept.dark }
  } catch (e) { /* private storage */ }
  return look
})()
function keepLook(min, dark) {
  var look = cargoEarthLook
  if (min !== undefined && min !== null) look.min = !!min
  if (dark !== undefined && dark !== null) look.dark = !!dark
  if (look.known && look.saved === look.min + '/' + look.dark) return
  look.known = true; look.saved = look.min + '/' + look.dark
  try { localStorage.setItem('cargoEarth.look', JSON.stringify({min: look.min, dark: look.dark})) } catch (e) { /* private storage */ }
}
function pagePlayer() {
  if (cargoEarthRadioPlayer || typeof Audio === 'undefined' || typeof bngApi === 'undefined') return cargoEarthRadioPlayer
  var audio = new Audio(), me = {seq: -1, status: 'idle', why: '', busy: false, on: false, at: 0, retries: 0, retry: null}
  cargoEarthRadioPlayer = me
  audio.preload = 'none'
  audio.addEventListener('playing', function () { me.status = 'playing'; me.retries = 0 })
  audio.addEventListener('waiting', function () { if (!audio.paused) me.status = 'loading' })
  // A dropped connection (the station, or the game's browser) is tried again twice before the game hears of it.
  // A live stream that "ends" has dropped too.
  function failed(code) {
    var src = audio.getAttribute('src')
    if (!src) return
    if (me.retries < 2) {
      me.retries++
      var seq = me.seq
      stop()
      me.status = 'loading'
      // the check-ins leave the stream alone while this waits, and drop it when the station goes elsewhere
      me.retry = setTimeout(function () {
        me.retry = null
        if (me.seq !== seq || !me.on || audio.getAttribute('src')) return
        audio.src = src
        var again = audio.play()
        if (again && again.catch) again.catch(function () { /* the error event decides */ })
      }, 1500)
      return
    }
    me.status = 'error'; me.why = 'error ' + code
    stop()
    me.at = 0; tick()
  }
  audio.addEventListener('error', function () { failed((audio.error && audio.error.code) || '?') })
  audio.addEventListener('ended', function () { failed('ended') })
  // pause and unload: only removing src ends the stream (and its connection to the helper)
  function stop() { audio.pause(); audio.removeAttribute('src'); try { audio.load() } catch (e) { /* nothing loaded */ } }
  function tick() {
    var now = Date.now()
    if (me.busy || (!me.on && now - me.at < 2000)) return // nothing playing: every 2 s is enough
    me.busy = true; me.at = now
    bngApi.engineLua('cargoEarth_core and cargoEarth_core.radioDo("page", ' + me.seq + ', "' + me.status + '", ' +
      bngApi.serializeToLua(me.why) + ') or nil', function (r) {
      me.busy = false
      var w = r && r.radio
      if (!w) return
      audio.volume = Math.max(0, Math.min(1, w.vol || 0))
      me.on = !!w.on
      if (!w.on || w.mode !== 'page' || !w.station || !r.stream) {
        if (me.retry) { clearTimeout(me.retry); me.retry = null }
        if (audio.getAttribute('src')) stop()
        if (me.status !== 'error' || w.seq !== me.seq) me.status = 'idle'
        me.seq = w.seq
        return
      }
      if (w.seq !== me.seq || (!audio.getAttribute('src') && !me.retry)) {
        if (w.seq !== me.seq) { me.retries = 0; if (me.retry) { clearTimeout(me.retry); me.retry = null } }
        me.seq = w.seq; me.status = 'loading'; me.why = ''
        audio.src = r.stream + encodeURIComponent(w.station.id)
        var started = audio.play()
        if (started && started.catch) started.catch(function () { /* the error event decides */ })
      }
    })
  }
  // the radio settings an older version kept in this page's storage go to the game once
  try {
    var old = JSON.parse(localStorage.getItem('cargoEarth.radio') || 'null')
    if (old && typeof old === 'object' && old.v === 2) {
      bngApi.engineLua('cargoEarth_core and cargoEarth_core.radioDo("import", ' + bngApi.serializeToLua(
        {vol: old.vol, via: old.via, last: old.last, saved: old.saved}) + ') and nil', function () {})
    }
  } catch (e) { /* private storage */ }
  setInterval(tick, 500)
  tick()
  return me
}

angular.module('beamng.apps')
.directive('cargoEarthPhone', [function () {
  var STATE = 'cargoEarth_core and cargoEarth_core.phoneState() or nil'
  // the careers on the start screens (resume and first run): load one, delete one (asks first)
  var SAVES_HTML =
    '<div class="cep-label" ng-if="s.saves.length">Your careers</div>' +
    '<div class="cep-li" ng-repeat="v in s.saves track by v.id" ng-class="{on: v.current && s.screen === \'resume\'}">' +
      '<div><div class="cep-name">{{ v.name }}</div>' +
        '<small ng-if="v.unreadable">This save cannot be read.</small>' +
        '<small ng-if="!v.unreadable">{{ fmt.money(v.money) }}{{ v.car ? " · " + v.car : "" }}{{ v.hours ? " · " + v.hours + " h" : "" }}</small>' +
        '<small ng-if="v.when">Played {{ v.when }}</small></div>' +
      '<div class="cep-row" style="flex:none;gap:4px">' +
        '<button class="cep-sm" style="flex:none;white-space:nowrap" ng-if="!(v.current && s.screen === \'resume\')" ng-click="act(\'loadSave\', v.id)">Load</button>' +
        '<button class="cep-sm" style="flex:none;white-space:nowrap" ng-class="delAsk === v.id ? \'go\' : \'ghost\'" ng-click="askDelete(v.id)" ' +
          'title="Delete this career" aria-label="Delete {{ v.name }}">{{ delAsk === v.id ? "Delete?" : "✕" }}</button></div></div>' +
    '<div class="cep-sub" ng-if="s.saveMsg">{{ s.saveMsg }}</div>'
  // a new career: its name (the field starts empty; the suggestion is used when nothing is typed)
  var NEW_CAREER_HTML =
    '<div class="cep-row" style="margin-top:6px"><input class="cep-input" type="text" maxlength="32" autocomplete="off" spellcheck="false" ' +
      'aria-label="Name of the new career" placeholder="{{ s.newName }}" ng-model="newSave.name"></div>'
  var CSS =
    '.cep{--ink:#1d1b19;--paper:#fbf7f2;--card:#fff;--muted:#7b726a;--line:#e8e0d7;--tomato:#e8452c;--ok:#2f8f5b;--warn:#c98a10;' +
    'width:100%;height:100%;box-sizing:border-box;padding:9px;background:#141312;border-radius:34px;' +
    'box-shadow:0 10px 30px rgba(0,0,0,.45),inset 0 0 0 2px #2b2926;font-family:"Segoe UI",Roboto,system-ui,sans-serif;' +
    'color:var(--ink);user-select:none;-webkit-user-select:none}' +
    '.cep *{box-sizing:border-box}' +
    '.cep-screen{position:relative;width:100%;height:100%;border-radius:26px;overflow:hidden;background:var(--paper);' +
    'display:flex;flex-direction:column}' +
    '.cep-bar{display:flex;justify-content:space-between;align-items:center;min-height:34px;padding:2px 12px 2px 18px;font-size:12px;font-weight:600;border-bottom:1px solid var(--line)}' +
    '.cep-bar-l,.cep-bar-r{display:flex;align-items:center;gap:5px;white-space:nowrap}' +
    '.cep-bar .cep-limit{width:24px;height:24px;border-width:3px;font-size:10px}' +
    '.cep-bal{font-size:13px;font-weight:800;font-variant-numeric:tabular-nums}' +
    '.cep-on{width:8px;height:8px;border-radius:50%;background:var(--ok)}' +
    '.cep-limit{align-self:center;display:inline-flex;flex-direction:column;align-items:center;justify-content:center;width:34px;height:34px;' +
      'border-radius:50%;border:4px solid #d62d20;background:#fff;color:#111;font-weight:800;font-size:13px;line-height:1;' +
      'font-variant-numeric:tabular-nums;box-sizing:border-box}.cep-limit small{font-size:6px;font-weight:700;margin-top:1px}' +
    '.cep-limit.over{background:#d62d20;color:#fff;border-color:#a31d13}' +
    '.cep-pill .cep-limit{width:24px;height:24px;border-width:3px;font-size:10px;vertical-align:middle;margin-right:4px}' +
    '.cep-report{width:100%;box-sizing:border-box;font:11px/1.35 monospace;background:rgba(0,0,0,.25);color:inherit;border:1px solid rgba(255,255,255,.15);border-radius:6px;padding:6px;resize:none;margin:6px 0}' +
    '.cep-body{flex:1;min-height:0;min-width:0;display:flex;flex-direction:column;padding:12px 14px;gap:10px;overflow:hidden}' +
    '.cep-perks{margin:4px 0;padding-left:16px;font-size:12px;line-height:1.35}.cep-perks li{margin:1px 0}' +
    '.cep-body.cep-fit{overflow-y:auto}.cep-fit .cep-center{flex:1 0 auto}.cep-fit .cep-pulse{width:56px;height:56px}' +
    '.cep-center{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;align-items:center;justify-content:flex-start;text-align:center;gap:10px;padding:12px 0}' +
    '.cep-center>*{flex-shrink:0;max-width:100%}.cep-body>button,.cep-body>.cep-row,.cep-body>.cep-order-head,.cep-body>.cep-stats{flex-shrink:0}' +
    '.cep-actionbar{flex:0 0 auto;display:flex;flex-direction:column;gap:6px;min-width:0}' +
    '.cep-actionbar .cep-btn{padding:10px 8px;min-height:38px}.cep-actionbar .cep-row{margin:0}' +
    '.cep-body>.cep-msg,.cep-body>.cep-sub{flex:0 1 auto;min-height:0;max-height:72px;overflow-y:auto}' +
    '.cep-bar,.cep-foot,.cep-tabs,.cep-pump{flex-shrink:0}.cep-bar-r{min-width:0}.cep-bal{white-space:normal;overflow-wrap:anywhere;max-width:112px;text-align:right}' +
    '.cep-notices{flex:0 1 auto;min-height:0;max-height:88px;overflow-y:auto}.cep-notices:empty{display:none}' +
    '.cep-notices>*{margin:0 0 4px;overflow-wrap:anywhere}.cep-notices>*:last-child{margin-bottom:0}' +
    '.cep-body.cep-work-board{overflow:hidden}.cep-work-board>button{flex-shrink:0}' +
    '.cep-work-board .cep-freight-summary{flex:0 0 auto;max-height:100px;align-items:stretch;text-align:left;gap:4px;padding:0}' +
    '.cep-freight-summary .cep-big{font-size:17px}.cep-contracts .cep-keyval{align-items:flex-start;gap:8px}' +
    '.cep-contracts .cep-keyval>strong:first-child{min-width:0;overflow-wrap:anywhere}' +
    '.cep-contracts .cep-keyval>strong:last-child{flex-shrink:0}.cep-contracts .cep-card{padding:10px 12px}' +
    '.cep-big{font-size:22px;font-weight:800;line-height:1.15}' +
    '.cep-sub{font-size:13px;color:var(--muted);line-height:1.35}.cep-sub.cep-warn{color:var(--warn);font-weight:700}' +
    '.cep-label{font-size:10px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}' +
    '.cep-btn{display:block;width:100%;border:0;border-radius:14px;padding:13px 10px;font:inherit;font-size:15px;font-weight:700;' +
    'cursor:pointer;background:var(--ink);color:#fff}' +
    '.cep-btn:hover{filter:brightness(1.12)}.cep-btn.go{background:var(--tomato)}.cep-btn.ok{background:var(--ok)}' +
    '.cep-btn.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--line)}' +
    '.cep-row{display:flex;flex-wrap:wrap;gap:8px;min-width:0}.cep-row .cep-btn,.cep-row .cep-sm{flex:1;min-width:0}' +
    '.cep-card{background:var(--card);border-radius:16px;padding:12px 14px;box-shadow:0 1px 0 var(--line),0 4px 14px rgba(29,27,25,.06)}' +
    '.cep-stop{display:grid;grid-template-columns:14px 1fr;gap:2px 10px;align-items:start}' +
    '.cep-busref{display:inline-block;min-width:22px;padding:0 5px;border-radius:4px;background:var(--ink);color:#fff;text-align:center;font-weight:700}' +
    '.cep-dot{width:12px;height:12px;border-radius:50%;margin-top:3px;background:var(--tomato)}.cep-dot.to{background:var(--ink);border-radius:3px}' +
    '.cep-line{width:2px;height:16px;margin:2px 0 2px 5px;background:var(--line)}' +
    '.cep-name{font-size:14px;font-weight:700;line-height:1.2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.cep-meta{font-size:12px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.cep-stats{display:grid;grid-auto-flow:column;grid-auto-columns:1fr;text-align:center;gap:4px;font-variant-numeric:tabular-nums}' +
    '.cep-stats div{font-size:16px;font-weight:800}.cep-stats span{display:block;font-size:10px;font-weight:600;color:var(--muted);' +
    'letter-spacing:.06em;text-transform:uppercase}' +
    '.cep-pay{font-size:34px;font-weight:800;letter-spacing:-.02em;font-variant-numeric:tabular-nums}' +
    '.cep-ring{position:relative;width:64px;height:64px}.cep-ring svg{transform:rotate(-90deg)}' +
    '.cep-ring b{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:18px;font-variant-numeric:tabular-nums}' +
    '.cep-dist{font-size:40px;font-weight:800;letter-spacing:-.03em;font-variant-numeric:tabular-nums;line-height:1}' +
    '.cep-dist small{font-size:16px;font-weight:700;margin-left:3px}' +
    '.cep-time{height:6px;border-radius:3px;background:var(--line);overflow:hidden}.cep-time i{display:block;height:100%;background:var(--ok)}' +
    '.cep-hold{margin-top:8px;height:10px;border-radius:5px;background:var(--line);overflow:hidden}' +
    '.cep-hold i{display:block;height:100%;background:var(--tomato);transition:width .25s linear}' +
    '.cep-time.warn i{background:var(--warn)}.cep-time.late i{background:var(--tomato)}' +
    '.cep-step{display:inline-block;padding:3px 9px;border-radius:999px;font-size:11px;font-weight:700;background:var(--tomato);color:#fff}' +
    '.cep-step.to{background:var(--ink)}' +
    '.cep-pulse{width:74px;height:74px;border-radius:50%;background:rgba(232,69,44,.12);display:flex;align-items:center;justify-content:center}' +
    '.cep-pulse i{width:22px;height:22px;border-radius:50%;background:var(--tomato);animation:cepP 1.6s ease-in-out 3}' +
    '@keyframes cepP{0%,100%{transform:scale(.8);opacity:.6}50%{transform:scale(1.15);opacity:1}}' +
    '.cep-adr{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;background:var(--warn);color:#fff;font-size:10px;font-weight:800}' +
    '.cep-foot{padding:5px 10px;font-size:10px;display:flex;flex-wrap:wrap;justify-content:center;gap:2px 4px;color:var(--muted);text-align:center}' +
    '.cep-foot-warn{color:var(--tomato)}' +
    '.cep-min{cursor:pointer;border:0;background:transparent;font:inherit;font-size:16px;font-weight:800;padding:0 4px;color:var(--ink)}' +
    '.cep-pill{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 16px;border-radius:999px;' +
    'background:#141312;color:#fff;font-family:"Segoe UI",Roboto,system-ui,sans-serif;font-weight:700;cursor:pointer;' +
    'box-shadow:0 6px 18px rgba(0,0,0,.4)}.cep-pill b{color:#e8452c}' +
    '.cep-tabs{display:flex;flex-shrink:0;border-top:1px solid var(--line);background:var(--card);padding:4px}' +
    '.cep-settings-link{border:0;background:transparent;padding:4px 6px;color:var(--muted);font:inherit;font-size:15px;line-height:1;cursor:pointer}' +
    '.cep-subtabs{display:flex;flex-shrink:0;gap:4px;margin:10px 14px 0;padding:4px;background:var(--line);border-radius:12px}' +
    '.cep-subtabs button{flex:1;min-width:0;border:0;border-radius:9px;padding:8px 4px;font:inherit;font-size:12px;font-weight:700;background:transparent;color:var(--muted);cursor:pointer}' +
    '.cep-modes{display:block;position:relative;flex:0 0 auto;min-width:0;margin:0}.cep-modes>span{display:block;font-size:11px;font-weight:700;color:var(--muted);margin-bottom:4px}' +
    '.cep-mode-select{display:block;box-sizing:border-box;width:100%;max-width:100%;min-width:0;min-height:42px;padding:8px 10px;border:1px solid var(--line);border-radius:10px;' +
      'background:var(--card);color:var(--ink);font:inherit;font-size:14px;font-weight:700;text-align:left;cursor:pointer}.cep-mode-select:disabled{cursor:default;opacity:.65}' +
    '.cep-mode-select>b{float:right}.cep-mode-menu{position:absolute;z-index:10;top:100%;left:0;right:0;max-height:200px;overflow-y:auto;padding:4px;' +
      'border:1px solid var(--line);border-radius:10px;background:var(--card);box-shadow:0 6px 18px rgba(0,0,0,.25)}' +
    '.cep-mode-menu>button{display:block;width:100%;min-height:42px;padding:9px 10px;border:0;border-radius:7px;text-align:left;font:inherit;' +
      'background:transparent;color:var(--ink);cursor:pointer}.cep-mode-menu>button.on{background:var(--line);font-weight:700}' +
    '.cep-subtabs button.on{background:var(--card);color:var(--ink);box-shadow:0 1px 3px rgba(29,27,25,.1)}' +
    '.cep-live{display:flex;flex-shrink:0;align-items:center;gap:8px;margin:8px 14px 0;padding:9px 10px;border:1px solid #f2c5b7;border-radius:12px;background:#fff0ea;color:var(--ink);font:inherit;text-align:left;cursor:pointer}' +
    '.cep-live>span{flex:1;min-width:0}.cep-live strong,.cep-live small{display:block}.cep-live strong{font-size:12px}.cep-live small{font-size:11px;color:var(--muted);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}' +
    '.cep-live>b{font-size:17px;color:var(--tomato)}.cep-dot-live{width:7px;height:7px;border-radius:50%;background:var(--tomato);flex:0 0 7px}' +
    '.cep-body button{white-space:normal;overflow-wrap:anywhere}.cep-card .cep-btn{margin-top:8px}.cep-card .cep-sm{margin-top:6px}' +
    '.cep-scroll>*{flex-shrink:0}.cep-empty{padding:16px 12px;text-align:center;border:1px dashed var(--line);border-radius:14px}' +
    '.cep-money-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.cep-money-grid strong{display:block;font-size:17px}.cep-money-grid span{font-size:11px;color:var(--muted)}' +
    '.cep-credit{color:var(--ok)}.cep-debit{color:#a72f1e}.cep-tabs svg{display:block;margin:0 auto 3px;width:19px;height:19px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}' +
    '.cep button:focus-visible,.cep input:focus-visible{outline:2px solid var(--tomato);outline-offset:2px}' +
    '.cep-search{width:100%;border:1px solid var(--line);border-radius:10px;padding:10px;background:var(--card);color:var(--ink);font:inherit;font-size:14px;user-select:text;-webkit-user-select:text}' +
    '.cep-tabs button{flex:1;min-width:0;border:0;border-radius:10px;background:transparent;font:inherit;font-size:10px;font-weight:700;padding:7px 0;' +
    'color:var(--muted);cursor:pointer}.cep-tabs button.on{color:var(--tomato);background:#fff0ea}' +
    '.cep-scroll{flex:1;min-height:0;overflow-y:auto;display:flex;flex-direction:column;gap:8px;padding-right:2px}' +
    '.cep-chips{display:flex;flex-wrap:wrap;align-items:center;gap:5px}.cep-chip{border:0;border-radius:999px;padding:5px 10px;font:inherit;font-size:11px;' +
    'font-weight:700;background:var(--line);color:var(--muted);cursor:pointer}.cep-chip.on{background:var(--ink);color:var(--card)}' +
    '.cep-kind{display:flex;flex-wrap:wrap;align-items:center;gap:2px 6px;margin:3px 0 2px;font-size:12px}' +
    '.cep-kind span{flex-basis:100%;color:var(--muted)}' +
    '.cep-q{width:18px;height:18px;padding:0;border:0;border-radius:50%;background:var(--line);color:var(--ink);font:inherit;' +
    'font-size:11px;font-weight:800;line-height:18px;text-align:center;cursor:pointer}.cep-q.on{background:var(--tomato);color:#fff}' +
    '.cep-jobs{margin:4px 0;padding:7px 9px;border-radius:10px;background:var(--line);font-size:12px}' +
    '.cep-jobs ul{margin:3px 0 0;padding-left:16px}.cep-jobs .cep-sub{margin-top:4px}' +
    '.cep-order-scroll>*{flex-shrink:0}' +
    '.cep-order-head,.cep-keyval{display:flex;align-items:center;justify-content:space-between;gap:8px}' +
    '.cep-order-head>.cep-ring{flex-shrink:0}.cep-order-head>div:first-child,.cep-keyval>*{min-width:0;overflow-wrap:anywhere}' +
    '.cep-order-head .cep-pay{font-size:26px}.cep-keyval>strong{max-width:65%}.cep-card,.cep-sub,.cep-big{overflow-wrap:anywhere}' +
    '.cep-route .cep-name,.cep-order-line .cep-name{white-space:normal;overflow-wrap:anywhere}' +
    '.cep-route .cep-meta{white-space:normal}.cep-route .cep-label{margin-bottom:3px}' +
    '.cep-order-items{display:grid;gap:3px;margin:5px 0 0;padding:0;list-style:none;font-size:13px;line-height:1.3}' +
    '.cep-order-items b{color:var(--muted);font-size:11px;margin-right:4px}' +
    '.cep-next-card,.cep-batch-list{display:grid;gap:8px}.cep-next-card .cep-name{font-size:17px;white-space:normal}' +
    '.cep-drive{text-align:center;border-top:1px solid var(--line);padding-top:8px}.cep-drive .cep-dist{font-size:34px}' +
    '.cep-order-line{cursor:default}' +
    '.cep-stop-time{white-space:nowrap;font-variant-numeric:tabular-nums}.cep-stop-time.late{color:var(--tomato)}' +
    '.cep-receipt-note{font-size:12px;color:var(--ok);background:#eaf6ed;border-radius:11px;padding:8px 10px}' +
    '.cep-impact-note{font-size:12px;color:#a72f1e;background:#fff0ea;border-radius:11px;padding:8px 10px}' +
    '.cep-li{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:9px 12px;background:var(--card);' +
    'border-radius:12px;box-shadow:0 1px 0 var(--line);cursor:pointer}' +
    '.cep-li .cep-name{font-size:13px}.cep-li small{display:block;font-size:11px;color:var(--muted);font-weight:500;' +
    'line-height:1.3}' +
    '.cep-sm{border:0;border-radius:10px;padding:7px 10px;min-height:32px;font:inherit;font-size:12px;font-weight:700;cursor:pointer;' +
    'background:var(--ink);color:#fff;white-space:nowrap}.cep-sm.ok{background:var(--ok)}.cep-sm.go{background:var(--tomato)}' +
    '.cep-sm.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--line)}' +
    '.cep-sm[disabled],.cep-btn[disabled]{opacity:.4;cursor:default}' +
    '.cep-msg{font-size:12px;padding:8px 10px;border-radius:10px;background:#fff4e5;color:#6b4a00}' +
    '.cep-update{display:flex;align-items:center;gap:6px;font-size:12px;padding:6px 8px 6px 10px;border-radius:10px;background:#e8f1ff;color:#123a73}' +
    '.cep-update{flex-shrink:0}.cep-update span{flex:1;min-width:0;overflow-wrap:anywhere}.cep-update .cep-sm{margin:0;padding:4px 8px;flex-shrink:0}' +
    '.cep-pump{font-size:12px;padding:6px 8px 8px 10px;border-radius:10px;background:#fff4dc;color:#5a3d00}' +
    '.cep-pump-head{display:flex;align-items:center;gap:6px}.cep-pump-head span{flex:1;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.cep-pump-head .cep-sm{margin:0;padding:3px 8px}.cep-pump-msg{margin-top:3px}' +
    '.cep-pump-row{display:flex;gap:4px;margin-top:5px}.cep-pump-row .cep-sm{flex:1;margin:0;padding:4px 2px;display:flex;flex-direction:column;align-items:center;line-height:1.2}' +
    '.cep-pump-row small{font-size:10px;font-weight:500;color:inherit;opacity:.85}' +
    '.cep-step2{display:flex;align-items:center;gap:8px}.cep-step2 b{min-width:62px;text-align:center;font-variant-numeric:tabular-nums}' +
    '.cep-li>div{min-width:0}' +
    // used-car pictures: the game's config preview over a plain car outline (shown when a mod car has no picture)
    '.cep-thumb{position:relative;flex:0 0 auto;width:78px;height:48px;border:0;padding:0;border-radius:8px;overflow:hidden;cursor:pointer;' +
    'background:var(--line) url("data:image/svg+xml;utf8,<svg xmlns=%27http://www.w3.org/2000/svg%27 viewBox=%270 0 64 32%27><path fill=%27%23999%27 d=%27M8 21l3-7c1-2 3-3 5-3h22c2 0 4 1 6 3l5 5 7 1c1 0 2 1 2 2v3c0 1-1 2-2 2h-4a5 5 0 0 0-10 0H23a5 5 0 0 0-10 0H9c-1 0-2-1-2-2z%27/></svg>") center/70% no-repeat}' +
    // a background picture, not <img>: Angular's img sanitizer (dash phone page) refuses local:// game files, and a
    // missing file just leaves the outline underneath showing
    '.cep-thumb i{position:absolute;top:0;left:0;right:0;bottom:0;background:center/cover no-repeat}' +
    '.cep-thumb.big{width:100%;height:0;padding-top:56%;cursor:default;margin-bottom:6px}.cep-thumb.big i{background-size:contain}' +
    '.cem .cep-scroll.cep-market-list{display:flex}.cep-market-card{flex-shrink:0;display:flex;flex-direction:column;gap:12px;padding:14px;margin:12px 0;border-radius:12px;background:var(--card);min-width:0}' +
    '.cep-market-card .cep-cartop{flex-direction:column}.cep-market-card .cep-thumb{width:100%;height:130px}' +
    '.cep-market-card .cep-thumb i{background-size:contain}.cep-market-card .cep-name{font-size:17px;line-height:1.3}' +
    '.cep-market-card .cep-market-actions{display:flex;flex-direction:column;gap:8px;width:100%}' +
    '.cep-market-card .cep-market-actions button{min-height:38px;width:100%;white-space:normal}' +
    '.cep-market-expiry{font-variant-numeric:tabular-nums;margin-top:8px}' +
    '.cep-cartop{display:flex;gap:8px;align-items:flex-start}.cep-cartop>div{flex:1;min-width:0}' +
    '.cep-cardetail{flex:0 0 100%;border-top:1px solid var(--line);padding-top:8px}' +
    '.cep-specs{display:grid;grid-template-columns:1fr 1fr;gap:3px 10px;font-size:12px}.cep-specs span{color:var(--muted)}.cep-specs b{font-weight:700}' +
    '.cep-specs div{display:flex;justify-content:space-between;gap:6px;min-width:0}' +
    '.cep-radio-now{flex:0 0 auto;display:flex;flex-direction:column;gap:6px;padding:10px 12px}.cep-radio-now .cep-name{font-size:16px;white-space:normal}' +
    '.cep-radio-now>.cep-name{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}.cep-scroll .cep-name{white-space:normal;overflow-wrap:anywhere}' +
    '.cep-radio-ctl{display:flex;gap:6px;align-items:center}.cep-radio-ctl .cep-btn{flex:1;margin-top:0;padding:10px 6px}' +
    '.cep-radio-ctl .cep-sm{padding:10px 12px;font-size:14px}' +
    '.cep-vol{flex:1;height:6px;border-radius:3px;background:var(--line);overflow:hidden}.cep-vol i{display:block;height:100%;background:var(--tomato)}' +
    '.cep-li.on{box-shadow:inset 0 0 0 2px var(--tomato)}.cep-fav{border:0;background:transparent;font-size:17px;cursor:pointer;color:#e0a100;padding:0 2px}' +
    '.cep-eq{display:inline-flex;gap:2px;align-items:flex-end;height:12px;margin-right:6px;vertical-align:-1px}' +
    '.cep-eq i{width:3px;height:7px;background:var(--tomato);animation:cepEq .9s ease-in-out 4}.cep-eq i:nth-child(2){animation-delay:.3s}.cep-eq i:nth-child(3){animation-delay:.6s}' +
    '@keyframes cepEq{0%,100%{height:3px}50%{height:12px}}' +
    '.cep-input{flex:1;min-width:0;border:1.5px solid var(--line);border-radius:10px;padding:7px 10px;font:inherit;font-size:13px;background:#fff}' +
    '.cep-stars{color:#e0a100;letter-spacing:1px;font-size:15px;white-space:nowrap}.cep-stars.big{font-size:24px}' +
    '.cep-stars i{font-style:normal;color:var(--line)}' +
    '.cep-premium{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;background:#e0a100;color:#fff;font-size:10px;font-weight:800}' +
    '.cep-special{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;color:#fff;font-size:10px;font-weight:800;text-transform:uppercase}' +
    '.cep-special.fragile{background:#c2416b}.cep-special.chilled{background:#2b7bb9}.cep-special.oversize{background:#d9822b}' +
    '.cep-map{display:block;width:100%;border-radius:12px;background:#f1ebe3}' +
    '.cep-legend{display:flex;gap:12px;flex-wrap:wrap;font-size:11px;color:var(--muted)}' +
    '.cep-legend i{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px}'

  var DASH_CSS = '.cep-nudge{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-top:6px}.cep-nudge .cep-sm{padding:7px 4px}'

  // The menu window: centred over the game, a list of sections on the left and the section on the right.
  var MENU_CSS =
    '.cem{--ink:#1d1b19;--paper:#fbf7f2;--card:#fff;--muted:#7b726a;--line:#e8e0d7;--tomato:#e8452c;--ok:#2f8f5b;--warn:#c98a10;' +
    'position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99998;display:flex;align-items:center;justify-content:center;' +
    'background:rgba(20,19,18,.55);font-family:"Segoe UI",Roboto,system-ui,sans-serif;color:var(--ink);pointer-events:auto;user-select:none;-webkit-user-select:none}' +
    '.cem *{box-sizing:border-box}' +
    '.cem-pad{position:fixed;left:16px;bottom:16px;z-index:9999;width:270px;padding:12px;border-radius:16px;background:rgba(20,19,18,.92);' +
    'color:#f3eee8;font-family:inherit;font-size:13px;box-shadow:0 10px 30px rgba(0,0,0,.35)}' +
    '.cem-pad-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}.cem-pad-head span{color:#ff8a73;font-size:12px}' +
    '.cem-pad-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}' +
    '.cem-pad button{border:0;border-radius:10px;padding:9px 4px;font:inherit;font-weight:700;background:#2b2825;color:#fff;cursor:pointer}' +
    '.cem-pad button:hover{background:#3a3631}.cem-pad button.ok{background:#e8452c}' +
    '.cem-pad-foot{display:flex;gap:6px;margin-top:8px}.cem-pad-foot button{flex:1}.cem-pad-error{margin-top:8px;color:#ff8a73;font-size:12px}' +
    '.cem-panel{width:92vw;max-width:980px;height:86vh;max-height:700px;display:flex;border-radius:20px;overflow:hidden;' +
    'background:var(--paper);box-shadow:0 24px 60px rgba(0,0,0,.5),inset 0 0 0 1px #2b2926}' +
    '.cem-side{width:200px;flex-shrink:0;display:flex;flex-direction:column;gap:2px;padding:18px 12px;background:#141312;color:#f3eee8;overflow-y:auto}' +
    '.cem-brand{font-weight:800;font-size:19px;padding:0 8px}.cem-brand b{color:var(--tomato)}' +
    '.cem-money{padding:2px 8px 14px;font-size:14px;font-weight:700;font-variant-numeric:tabular-nums;color:#f3eee8}' +
    '.cem-money small{display:block;font-size:11px;font-weight:600;color:#ff8a73}' +
    '.cem-side button{display:flex;align-items:center;gap:10px;width:100%;border:0;border-radius:10px;padding:9px 10px;background:transparent;' +
    'color:#bdb4ab;font:inherit;font-size:14px;font-weight:600;text-align:left;cursor:pointer}' +
    '.cem-side button:hover{background:#26231f;color:#fff}.cem-side button.on{background:var(--tomato);color:#fff}' +
    '.cem-side svg{width:18px;height:18px;flex-shrink:0;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}' +
    '.cem-side svg circle[fill]{fill:#141312}.cem-side button.on svg circle[fill]{fill:var(--tomato)}' +
    '.cem-main{flex:1;min-width:0;min-height:0;display:flex;flex-direction:column}' +
    '.cem-head{display:flex;flex-shrink:0;align-items:center;justify-content:space-between;gap:10px;padding:18px 24px 6px}' +
    '.cem-head h1{margin:0;min-width:0;overflow-wrap:anywhere;font-size:22px;font-weight:800}.cem-close{flex-shrink:0}' +
    '.cem-close{border:0;border-radius:10px;padding:8px 14px;font:inherit;font-size:13px;font-weight:700;background:var(--ink);color:#fff;cursor:pointer}' +
    '.cem .cep-body{padding:8px 24px 20px}.cem .cem-live{margin:4px 24px 0;width:auto}.cem .cep-name{white-space:normal;overflow-wrap:anywhere}' +
    '.cem .cep-scroll{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));align-content:start;gap:10px}' +
    '.cem .cep-scroll>.cep-label,.cem .cep-scroll>.cep-sub,.cem .cep-scroll>.cep-msg,.cem .cep-scroll>.cep-search,.cem .cep-scroll>.cep-sm,.cem .cep-scroll>.cep-chips,.cem .cep-scroll>div[ng-if]:not(.cep-card){grid-column:1/-1}' +
    '@media (max-width:620px){.cem-panel{flex-direction:column;width:100vw;height:100vh;max-height:none;border-radius:0}' +
    '.cem-side{width:auto;flex-direction:row;flex-wrap:wrap;max-height:28vh;padding:14px 16px 8px}.cem-brand,.cem-money{display:none}' +
    '.cem-side button{width:auto;padding:6px 8px;font-size:12px}.cem-head{padding:12px 16px 4px}.cem .cep-body{padding:6px 16px 14px}.cem .cem-live{margin:4px 16px 0}' +
    '.cem .cep-scroll{display:flex}}'

  // Dark mode (Settings → Dark mode, kept by the game for both phones and the Menu): the same colour names, darker.
  var DARK_CSS =
    '.cep.dark,.cem.dark{--ink:#ece6df;--paper:#181716;--card:#24221f;--muted:#a59b91;--line:#3a3631;--tomato:#ff6b4f;--ok:#43a96f;--warn:#d99a2b}' +
    '.dark .cep-btn,.dark .cep-sm,.dark .cem-close{color:#181716}' +
    '.dark .cep-btn.go,.dark .cep-btn.ok,.dark .cep-sm.go,.dark .cep-sm.ok{color:#fff}' +
    '.dark .cep-btn.ghost,.dark .cep-sm.ghost{color:var(--ink)}.dark .cep-step.to{color:#181716}' +
    '.dark .cep-card{box-shadow:0 1px 0 var(--line),0 4px 14px rgba(0,0,0,.3)}' +
    '.dark .cep-live{background:#3a221c;border-color:#6b3326}.dark .cep-tabs button.on{background:#3a221c}' +
    '.dark .cep-receipt-note{background:#1d3226;color:#7fd19b}.dark .cep-impact-note{background:#3a221c;color:#ff9c8a}' +
    '.dark .cep-msg{background:#3a2e14;color:#ffd58a}.dark .cep-update{background:#17283f;color:#a9c8ff}' +
    '.dark .cep-pump{background:#3a2e14;color:#ffd58a}.dark .cep-input{background:var(--card);color:var(--ink)}' +
    '.dark .cep-map{background:#2a2724}.dark .cep-search{background:var(--card);color:var(--ink)}'

  var HQ_CSS =
    '.cehq{position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99999;display:flex;align-items:center;justify-content:center;' +
    'background:rgba(10,14,18,.72);font-family:"Segoe UI",Roboto,system-ui,sans-serif;color:#e8eef2;pointer-events:auto}' +
    '.cehq *{box-sizing:border-box}' +
    '.cehq-panel{width:94vw;max-width:1180px;height:90vh;max-height:780px;display:flex;flex-direction:column;gap:12px;padding:20px 22px;' +
    'border-radius:18px;background:#15202a;box-shadow:0 24px 60px rgba(0,0,0,.6),inset 0 0 0 1px #2b3c4a;overflow:hidden}' +
    '.cehq-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-shrink:0}' +
    '.cehq-head-right{display:flex;flex-shrink:0;flex-wrap:wrap;align-items:center;justify-content:flex-end;gap:10px;max-width:50%}.cehq-head>div:first-child{min-width:0;overflow-wrap:anywhere}' +
    '.cehq-kicker,.cehq-label{font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#7fb7d1}' +
    '.cehq-label.small{font-size:10px;color:#8ea2b0}' +
    '.cehq-title{font-size:26px;font-weight:800;line-height:1.15;color:#fff}' +
    '.cehq-sub{font-size:13px;color:#9fb2bf;margin-top:2px}' +
    '.cehq-money{font-size:18px;font-weight:800;font-variant-numeric:tabular-nums;text-align:right}' +
    '.cehq-money small{display:block;font-size:11px;font-weight:600;color:#ff9c8a}' +
    '.cehq-msg{flex-shrink:0;max-height:72px;overflow-y:auto;overflow-wrap:anywhere;font-size:13px;padding:8px 12px;border-radius:10px;background:#22313d;color:#d6e2ea}' +
    '.cehq-empty{margin:auto;max-width:520px;text-align:center}.cehq-empty p{font-size:14px;line-height:1.5;color:#b8c7d1}' +
    '.cehq-btn{border:0;border-radius:10px;padding:9px 14px;font:inherit;font-size:13px;font-weight:700;cursor:pointer;background:#e8eef2;color:#15202a}' +
    '.cehq-btn:hover{filter:brightness(1.1)}.cehq-btn.build{background:#e8452c;color:#fff}' +
    '.cehq-btn.ghost{background:transparent;color:#e8eef2;box-shadow:inset 0 0 0 1.5px #3a4d5c}' +
    '.cehq-btn.small{padding:6px 9px;font-size:12px}.cehq-btn[disabled]{opacity:.4;cursor:default;filter:none}' +
    '.cehq-plan{flex:1;min-height:0;display:grid;grid-template-columns:1.15fr 1fr 1fr;grid-template-rows:max-content max-content;align-content:start;gap:0;' +
    'border:3px solid #7fb7d1;border-radius:6px;background:#101921;overflow:auto}' +
    '.cehq-room{display:flex;flex-direction:column;gap:7px;padding:14px 16px;border-right:3px solid #7fb7d1;border-bottom:3px solid #7fb7d1;' +
    'background-image:linear-gradient(#1a2733 1px,transparent 1px),linear-gradient(90deg,#1a2733 1px,transparent 1px);background-size:22px 22px}' +
    '.cehq-room.stores{border-right:0}.cehq-room.tank{border-right:0;border-bottom:0;grid-column:3;grid-row:2}' +
    '.cehq-yard{grid-column:1 / span 2;grid-row:2;min-height:300px;padding:14px 16px;border-right:3px solid #7fb7d1;background:#232a31}' +
    '.cehq-stat{font-size:30px;font-weight:800;line-height:1;color:#fff}.cehq-stat small{font-size:12px;font-weight:600;color:#9fb2bf;margin-left:6px}' +
    '.cehq-note{font-size:12px;line-height:1.4;color:#9fb2bf}.cehq-note.warn{color:#ffb86b}' +
    '.cehq-sep{height:1px;background:#2b3c4a;margin:3px 0}' +
    '.cehq-level{display:flex;align-items:center;gap:8px;font-size:13px;font-weight:600;color:#e8eef2}' +
    '.cehq-pips{display:flex;gap:3px}.cehq-pips i{width:14px;height:6px;border-radius:2px;background:#2b3c4a}.cehq-pips i.on{background:#7fd19b}' +
    '.cehq-rename{display:flex;gap:6px}.cehq-rename input{flex:1;min-width:0;border:1.5px solid #3a4d5c;border-radius:10px;padding:7px 10px;font:inherit;' +
    'font-size:13px;background:#101921;color:#e8eef2}' +
    '.cehq-shelf{display:flex;flex-wrap:wrap;gap:5px}.cehq-shelf span{font-size:11px;padding:3px 7px;border-radius:5px;background:#22313d;color:#d6e2ea}' +
    '.cehq-bays{display:flex;flex-wrap:wrap;margin-top:10px}' +
    '.cehq-bay{flex:1 1 128px;max-width:176px;min-height:196px;display:flex;flex-direction:column;align-items:center;gap:4px;padding:10px 8px;text-align:center;' +
    'border-left:3px dashed #e8eef2;border-bottom:3px solid transparent}.cehq-bay:last-child{border-right:3px dashed #e8eef2}' +
    '.cehq-bay-name{font-size:13px;font-weight:700;color:#fff;overflow-wrap:anywhere}' +
    '.cehq-bay-free{margin-top:38px;font-size:13px;font-weight:700;color:#8ea2b0}' +
    '.cehq-yard-head{display:flex;justify-content:space-between;align-items:center;gap:10px}' +
    '.cehq-bay-actions{display:flex;flex-direction:column;gap:5px;margin-top:auto;width:100%}' +
    '.cehq-car{width:44px;height:80px;flex-shrink:0}.cehq-car rect{fill:#c9d4dc}.cehq-car .glass{fill:#15202a;stroke:#15202a;stroke-width:3;stroke-linecap:round}' +
    '.cehq-bay.current .cehq-car rect{fill:#e8452c}.cehq-bay.out .cehq-car{opacity:.3}' +
    '.cehq-foot{flex-shrink:0;display:flex;justify-content:flex-end}' +
    '.cehq-app{padding:7px 9px;border-radius:9px;background:#1d2a35;cursor:pointer;box-shadow:inset 0 0 0 1.5px transparent}' +
    '.cehq-app:hover{background:#22313d}.cehq-app.picked{box-shadow:inset 0 0 0 2px #e8452c;background:#2a2421}' +
    '.cehq-app b{display:block;font-size:13px;color:#fff}.cehq-app span{font-size:11px;color:#9fb2bf}.cehq-app>span{display:block}' +
    '.cehq-wear{display:flex;flex-direction:column;gap:3px;width:100%;margin:2px 0}' +
    '.cehq-wear div{display:flex;align-items:center;gap:5px;font-size:10px;color:#9fb2bf}' +
    '.cehq-wear span{flex:0 0 38px;text-align:left}.cehq-wear em{flex:1;height:5px;border-radius:3px;background:#2b3c4a;overflow:hidden}' +
    '.cehq-wear em i{display:block;height:100%;background:#7fd19b}.cehq-wear .soon em i{background:#ffb86b}.cehq-wear .due em i{background:#ff6b57}' +
    '.cehq-driver{font-size:12px;font-weight:700;color:#e8eef2}' +
    '.cehq-shop{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:8px;margin-top:8px}' +
    '.cehq-item{display:flex;flex-direction:column;gap:4px;padding:9px 10px;border-radius:10px;background:#1b242c;box-shadow:inset 0 0 0 1px #34424e}' +
    '.cehq-item b{font-size:13px;color:#fff}' +
    '.cehq-section{margin-top:14px}.cehq-room,.cehq-yard{min-width:0;overflow-wrap:anywhere}.cehq-btn{white-space:normal;overflow-wrap:anywhere}' +
    '@media(max-width:700px){.cehq-panel{width:100vw;height:100vh;max-height:none;border-radius:0;padding:12px;gap:8px}' +
    '.cehq-head{gap:8px}.cehq-title{font-size:20px}.cehq-head-right{max-width:45%}.cehq-money{font-size:14px}' +
    '.cehq-plan{display:flex;flex-direction:column}.cehq-plan>*{flex-shrink:0}.cehq-yard{min-height:200px}.cehq-room{border-right:0}}'

  // Local money: amounts arrive in the game's base unit and are shown in the currency of the country you drive in
  // (the phone state says which; crossing a border exchanges the money for free).
  var CUR = { code: 'EUR', rate: 0.041, symbol: '€', prefix: false, decimals: 2 }
  function withSymbol(text, neg) {
    if (!CUR.prefix) return (neg ? '−' : '') + text + ' ' + CUR.symbol
    return (neg ? '−' : '') + CUR.symbol + (/[A-Za-z]$/.test(CUR.symbol) ? ' ' : '') + text
  }
  function number(v, decimals) {
    return v.toLocaleString(CUR.prefix ? 'en-US' : 'cs-CZ', { minimumFractionDigits: decimals, maximumFractionDigits: decimals })
  }
  function money(n) {
    var v = (n || 0) * CUR.rate
    return withSymbol(number(Math.abs(v), CUR.decimals), v < 0 && Math.abs(v) >= 0.005)
  }
  // a price per litre or km: two decimals more than whole money, at least two
  function unitPrice(n) { return withSymbol(number((n || 0) * CUR.rate, Math.max(2, CUR.decimals)), false) }
  function shortMoney(n) {
    var v = (n || 0) * CUR.rate
    if (Math.abs(v) >= 10000) return (Math.round(v / 100) / 10).toLocaleString('cs-CZ') + 'k'
    return number(v, Math.abs(v) >= 1000 ? 0 : CUR.decimals)
  }
  // messages from the game name amounts as '300 CZK'
  function localText(t) {
    if (typeof t !== 'string') return t
    return t.replace(/(-?)(\d+) CZK/g, function (all, sign, n) { return money((sign ? -1 : 1) * Number(n)) })
  }
  function dist(m) {
    if (m === null || m === undefined) return { v: '–', u: '' }
    if (m >= 1000) return { v: (m / 1000).toFixed(m >= 10000 ? 0 : 1).replace('.', ','), u: 'km' }
    return { v: String(m < 100 ? Math.round(m) : Math.round(m / 10) * 10), u: 'm' }
  }
  function clock(s) {
    var neg = s < 0, a = Math.abs(s), m = Math.floor(a / 60), r = a % 60
    return (neg ? '−' : '') + m + ':' + (r < 10 ? '0' : '') + r
  }
  function mins(s) { return s < 60 ? 'under 1 min' : Math.ceil(s / 60) + ' min' }
  function km(v) { return v === null || v === undefined ? '–' : String(v).replace('.', ',') + ' km' }

  return {
    template:
      '<div style="width:100%;height:100%"><style>' + CSS + DASH_CSS + MENU_CSS + DARK_CSS + HQ_CSS + '</style>' +
      '<div class="cehq" ng-show="hqOpen" role="dialog" aria-label="Headquarters">' +
      '<div class="cehq-panel" ng-if="hqOpen">' +
        '<div class="cehq-head">' +
          '<div><div class="cehq-kicker">Headquarters</div>' +
            '<div class="cehq-title">{{ hq.name || "Your firm" }}</div>' +
            '<div class="cehq-sub" ng-if="hq.hq">{{ hq.hq.name }}<span ng-if="hq.hq.town"> · {{ hq.hq.town }}</span> · {{ hq.hq.here ? "you are here" : fmt.num(hq.hq.km) + " km away" }}</div>' +
            '<div class="cehq-sub" ng-if="hq.founded && !hq.hq">No headquarters chosen yet</div></div>' +
          '<div class="cehq-head-right">' +
            '<div class="cehq-money" ng-if="hq.founded">{{ fmt.money(hq.money) }}<small ng-if="hq.debt > 0">debt {{ fmt.money(hq.debt) }}</small></div>' +
            '<button class="cehq-btn ghost" ng-if="hq.hq && !hq.hq.here" ng-click="hdo(\'gpsHq\')">Route here</button>' +
            '<button class="cehq-btn" ng-click="closeHq()">Close</button></div></div>' +
        '<div class="cehq-msg" ng-if="!hq">Loading the headquarters…</div>' +
        '<div class="cehq-msg" ng-if="hq.msg">{{ fmt.text(hq.msg) }}</div>' +
        '<div class="cehq-msg" ng-if="hq && !hq.founded">Start a firm first in Menu → Firm.</div>' +
        '<div class="cehq-empty" ng-if="hq.founded && !hq.hq">' +
          '<div class="cehq-title">Choose where the firm lives</div>' +
          '<p>Park at a yard, a warehouse or your home garage. The first choice is free; moving later costs {{ fmt.money(hq.moveFee) }}.</p>' +
          '<p ng-if="hq.place">You are at <strong>{{ hq.place.name }}</strong>.</p>' +
          '<p ng-if="!hq.place">No yard, warehouse or home garage here.</p>' +
          '<button class="cehq-btn build" ng-disabled="!hq.place || !hq.parked" ng-click="hdo(\'setHq\')">Set the headquarters here</button></div>' +
        '<div class="cehq-plan" ng-if="hq.hq">' +
          '<div class="cehq-room office"><div class="cehq-label">Office</div>' +
            '<div class="cehq-stat">{{ hq.drivers.count }}<small>{{ hq.drivers.count === 1 ? "driver" : "drivers" }} on the road</small></div>' +
            '<div class="cehq-note">Drivers work {{ hq.drivers.shiftMinutes }}-minute shifts while you play and are paid from what each shift earns.<span ng-if="hq.drivers.earned"> So far: {{ fmt.money(hq.drivers.earned) }}.</span></div>' +
            '<div class="cehq-label small" ng-if="hq.drivers.can">Looking for work · new faces in {{ hq.drivers.nextMin }} min</div>' +
            '<div class="cehq-app" ng-repeat="a in hq.drivers.applicants track by a.id" ng-if="hq.drivers.can" ng-class="{picked: pick.id === a.id}" ' +
              'ng-click="pick.id = (pick.id === a.id ? null : a.id)">' +
              '<b>{{ a.name }}</b><span>speed {{ pct(a.speed) }} · care {{ pct(a.care) }} · wage {{ fmt.money(a.wage) }} a shift</span>' +
              '<span>Licences: {{ a.licenceNames.join(", ") }}<span ng-if="a.knowsName"> · best with {{ a.knowsName }}</span></span></div>' +
            '<div class="cehq-note" ng-if="hq.drivers.can && !hq.drivers.applicants.length">Nobody is looking for work right now.</div>' +
            '<div class="cehq-note warn" ng-if="pickedApplicant()">Now pick a vehicle in the yard for {{ pickedApplicant().name }} (hiring costs {{ fmt.money(hq.drivers.hireFee) }}).</div>' +
            '<div class="cehq-sep"></div><div class="cehq-label small">Dispatch</div>' +
      '<div class="cehq-level"><span class="cehq-pips"><i ng-repeat="on in pips(up(\'office\')) track by $index" ng-class="{on: on}"></i></span>' +
        '<span>{{ up(\'office\').now || "Not built" }}</span></div>' +
      '<button class="cehq-btn build" ng-if="up(\'office\').cost" ng-disabled="!up(\'office\').can" ng-click="hdo(\'upgrade\', \'office\')">{{ up(\'office\').level ? "Extend" : "Build" }} · {{ fmt.money(up(\'office\').cost) }}</button>' +
      '<div class="cehq-note" ng-if="up(\'office\').next">{{ up(\'office\').next }}</div>' +
            '<div class="cehq-sep"></div>' +
            '<div class="cehq-rename"><input maxlength="28" aria-label="Firm name" placeholder="{{ hq.name }}" ng-model="names.firm">' +
              '<button class="cehq-btn ghost" ng-disabled="!names.firm" ng-click="hdo(\'rename\', names.firm); names.firm = \'\'">Rename</button></div></div>' +
          '<div class="cehq-room workshop"><div class="cehq-label">Workshop</div>' +
      '<div class="cehq-level"><span class="cehq-pips"><i ng-repeat="on in pips(up(\'workshop\')) track by $index" ng-class="{on: on}"></i></span>' +
        '<span>{{ up(\'workshop\').now || "Not built" }}</span></div>' +
      '<button class="cehq-btn build" ng-if="up(\'workshop\').cost" ng-disabled="!up(\'workshop\').can" ng-click="hdo(\'upgrade\', \'workshop\')">{{ up(\'workshop\').level ? "Extend" : "Build" }} · {{ fmt.money(up(\'workshop\').cost) }}</button>' +
      '<div class="cehq-note" ng-if="up(\'workshop\').next">{{ up(\'workshop\').next }}</div>' +
            '<div class="cehq-sep"></div>' +
            '<div class="cehq-note" ng-if="hq.repair.cost <= 0">The car you drive needs no repair.</div>' +
            '<button class="cehq-btn" ng-if="hq.repair.cost > 0" ng-disabled="!hq.hq.here || hq.company" ng-click="hdo(\'repair\')">Repair your car · {{ fmt.money(hq.repair.cost * hq.repair.factor) }}</button>' +
            '<div class="cehq-note" ng-if="hq.repair.cost > 0 && !hq.hq.here">Bring the car here to use the workshop.</div></div>' +
          '<div class="cehq-room stores"><div class="cehq-label">Parts storage</div>' +
            '<div class="cehq-stat">{{ hq.parts.count }}<small>spare {{ hq.parts.count === 1 ? "part" : "parts" }}</small></div>' +
            '<div class="cehq-shelf"><span ng-repeat="p in hq.parts.items track by $index">{{ p.name }}<b ng-if="p.count > 1"> × {{ p.count }}</b></span>' +
              '<span ng-if="hq.parts.kinds > hq.parts.items.length">and {{ hq.parts.kinds - hq.parts.items.length }} more</span></div>' +
            '<div class="cehq-note" ng-if="!hq.parts.count">Parts you take off a car are kept here.</div></div>' +
          '<div class="cehq-yard"><div class="cehq-yard-head"><div class="cehq-label">Yard · {{ hq.bays.length }} of {{ hq.capacity }} bays taken</div>' +
        '<button class="cehq-btn small build" ng-if="up(\'bays\').cost" ng-disabled="!up(\'bays\').can" ng-click="hdo(\'upgrade\', \'bays\')" title="{{ up(\'bays\').next }}">Build more bays · {{ fmt.money(up(\'bays\').cost) }}</button></div>' +
            '<div class="cehq-bays">' +
              '<div class="cehq-bay" ng-repeat="b in hq.bays track by $index" ng-class="{current: b.current, out: b.driver}">' +
                '<svg class="cehq-car" viewBox="0 0 60 110" aria-hidden="true"><rect x="8" y="4" width="44" height="102" rx="14"/><path class="glass" d="M14 30h32l-4 16H18zM18 78h24l4 12H14z"/><path class="glass" d="M10 50v24M50 50v24"/></svg>' +
                '<div class="cehq-bay-name">{{ b.name }}</div>' +
                '<div class="cehq-note">{{ fmt.int(b.km) }} km · {{ b.current ? "you drive it" : (b.driver ? "on the road" : "parked") }}</div>' +
                '<div class="cehq-driver" ng-if="b.driver">{{ b.driver.name }}</div>' +
                '<div class="cehq-note" ng-if="b.driver && !b.driver.waiting">{{ fmt.money(b.driver.net) }} a shift · earned {{ fmt.money(b.driver.earned) }}</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'repair\'">Waiting for a repair</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'trailer\'">Needs a free trailer</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'licence\'">No licence for this vehicle</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'boxes\'">Needs cargo boxes fitted</div>' +
                '<div class="cehq-wear" ng-if="b.upkeep"><div ng-repeat="it in b.upkeep.items track by it.id" ng-class="{soon: it.soon, due: it.due}" ' +
                  'title="{{ it.name }}: {{ it.due ? \'overdue\' : it.kmLeft + \' km left\' }}"><span>{{ it.id }}</span><em><i ng-style="{width: Math.min(100, it.share * 100) + \'%\'}"></i></em></div></div>' +
                '<button class="cehq-btn small" ng-if="b.upkeep.due > 0" ng-disabled="hq.company || (b.current && !hq.hq.here) || hq.money < b.upkeep.dueCost" ' +
                  'ng-click="hdo(\'service\', b.current ? \'current\' : b.id)" title="{{ b.current && !hq.hq.here ? \'Bring the car here\' : \'\' }}">Service · {{ fmt.money(b.upkeep.dueCost) }}</button>' +
                '<button class="cehq-btn small build" ng-if="b.repairCost > 0" ng-disabled="hq.company || hq.money < b.repairCost" ng-click="hdo(\'repairParked\', b.id)">Repair · {{ fmt.money(b.repairCost) }}</button>' +
                '<div class="cehq-bay-actions" ng-if="!b.current">' +
                  '<button class="cehq-btn small" ng-if="!b.driver" ng-disabled="hq.busy || hq.company" ng-click="hdo(\'switchCar\', b.id)">Drive</button>' +
                  '<button class="cehq-btn small ghost" ng-if="!b.driver && hq.drivers.can && !b.loaner" ng-disabled="!pickedApplicant() || !pickedApplicant().can[b.tier] || b.repair > 0 || hq.debt > 0 || hq.money < hq.drivers.hireFee || hq.company" ' +
                    'ng-click="hdo(\'hireDriver\', b.id, pick.id); pick.id = null">' +
                    '{{ pickedApplicant() ? (pickedApplicant().can[b.tier] ? "Hire " + pickedApplicant().name + " · " + fmt.money(pickedApplicant().nets[b.tier]) + " a shift" : "No licence for this") : "Hire: choose in the office" }}</button>' +
                  '<button class="cehq-btn small ghost" ng-if="b.driver" ng-disabled="hq.company" ng-click="hdo(\'releaseDriver\', b.id)">Release driver</button></div></div>' +
              '<div class="cehq-bay free" ng-repeat="n in range(hq.free) track by $index"><div class="cehq-bay-free">Free bay</div>' +
                '<div class="cehq-note">Buy a vehicle below.</div></div>' +
            '</div>' +
            '<div class="cehq-section"><div class="cehq-label">Buy new for the firm · delivered to a free bay</div>' +
              '<div class="cehq-shop"><div class="cehq-item" ng-repeat="v in hq.shop track by v.id"><b>{{ v.name }}</b>' +
                '<div class="cehq-note">{{ fmt.text(v.text) }}</div>' +
                '<button class="cehq-btn small build" ng-disabled="!v.can || hq.company" ng-click="hdo(\'buyVehicle\', v.id)">Buy · {{ fmt.money(v.price) }}</button></div></div></div>' +
            '<div class="cehq-section"><div class="cehq-label">Trailers · {{ hq.trailers.length }} in the yard</div>' +
              '<div class="cehq-note">Hired tractor drivers need one. Your own semi jobs pay {{ hq.trailerBonus }} % more on a firm trailer. ' +
                'Tow trailers: take one out here and it goes on your hitch, so tow jobs skip borrowing one at the workshop.</div>' +
              '<div class="cehq-shop">' +
                '<div class="cehq-item" ng-repeat="t in hq.trailers track by t.id"><b>{{ t.name }}</b>' +
                  '<div class="cehq-note">{{ t.out ? "Out with you" : (t.busy ? "With a driver" : "In the yard") }}' +
                    '<span ng-if="t.tow && !t.out && !t.canTake && t.needs"> · {{ t.needs }}</span>' +
                    '<span ng-if="t.tow && !t.out && !t.needs && !hq.atHq"> · Take it out at the headquarters</span></div>' +
                  '<button class="cehq-btn small build" ng-if="t.tow && !t.out" ng-disabled="!t.canTake || hq.company || hq.busy" ng-click="hdo(\'takeTrailer\', t.id)">Take it out</button>' +
                  '<button class="cehq-btn small" ng-if="t.out" ng-disabled="!hq.atHq || hq.busy" ng-click="hdo(\'leaveTrailer\', t.id)">Leave it here</button>' +
                  '<button class="cehq-btn small ghost" ng-disabled="hq.company" ng-click="hdo(\'sellTrailer\', t.id)">Sell for half</button></div>' +
                '<div class="cehq-item" ng-repeat="t in hq.trailerShop track by t.id"><b>New {{ t.name.toLowerCase() }}</b>' +
                  '<div class="cehq-note">{{ fmt.text(t.text) }}</div>' +
                  '<button class="cehq-btn small build" ng-disabled="!t.can || hq.company" ng-click="hdo(\'buyTrailer\', t.id)">Buy · {{ fmt.money(t.price) }}</button></div>' +
              '</div></div>' +
            '</div>' +
          '<div class="cehq-room tank"><div class="cehq-label">Fuel tank</div>' +
      '<div class="cehq-level"><span class="cehq-pips"><i ng-repeat="on in pips(up(\'tank\')) track by $index" ng-class="{on: on}"></i></span>' +
        '<span>{{ up(\'tank\').now || "Not built" }}</span></div>' +
      '<button class="cehq-btn build" ng-if="up(\'tank\').cost" ng-disabled="!up(\'tank\').can" ng-click="hdo(\'upgrade\', \'tank\')">{{ up(\'tank\').level ? "Extend" : "Build" }} · {{ fmt.money(up(\'tank\').cost) }}</button>' +
      '<div class="cehq-note" ng-if="up(\'tank\').next">{{ up(\'tank\').next }}</div>' +
            '<div class="cehq-sep" ng-if="up(\'tank\').level"></div>' +
            '<div ng-if="up(\'tank\').level">' +
              '<div class="cehq-note" ng-if="hq.fuel.kind === \'electric\'">Petrol and diesel only; your car charges at public chargers.</div>' +
              '<div class="cehq-note" ng-if="hq.fuel.station.hq">{{ fmt.price(hq.fuel.station.price) }} per litre here.</div>' +
              '<button class="cehq-btn" ng-if="hq.fuel.station.hq && hq.fuel.fill" ng-disabled="hq.fuel.busy || hq.fuel.fill.canCost <= 0" ng-click="hdo(\'refuel\')">Fill up · {{ fmt.money(hq.fuel.fill.canCost) }}</button>' +
              '<div class="cehq-note" ng-if="hq.fuel && hq.fuel.kind !== \'electric\' && !(hq.fuel.station.hq && hq.fuel.fill)">Park the car here to fill up.</div></div></div>' +
        '</div>' +
        '<div class="cehq-foot" ng-if="hq.hq && !hq.hq.here && hq.place && hq.parked">' +
          '<button class="cehq-btn ghost" ng-disabled="hq.busy || hq.company" ng-click="moveHq()">{{ moveAsk ? "Press again to move · " + fmt.money(hq.moveFee) : "Move the headquarters to " + hq.place.name }}</button></div>' +
      '</div></div>' +
      // the menu: a big window outside the phone for everything that is not driving (garage, home, companies, career, settings)
      // moving the dash phone: a small pad in the corner, so the phone on the dash stays in sight
      '<div class="cem-pad" ng-show="movePad" role="dialog" aria-label="Move the dash phone">' +
        '<div class="cem-pad-head"><b>Move the dash phone</b><span ng-if="st.dash.moving">moving…</span></div>' +
        '<div class="cem-pad-grid">' +
          '<span></span><button ng-click="sdo(\'dash\', \'z+\')">Up</button><span></span>' +
          '<button ng-click="sdo(\'dash\', \'x+\')">Left</button><button ng-click="sdo(\'dash\', \'y+\')">Closer</button><button ng-click="sdo(\'dash\', \'x-\')">Right</button>' +
          '<span></span><button ng-click="sdo(\'dash\', \'z-\')">Down</button><button ng-click="sdo(\'dash\', \'y-\')">Further</button></div>' +
        '<div class="cem-pad-foot"><button ng-click="sdo(\'dash\', \'reset\')">Start over</button>' +
          '<button class="ok" ng-click="closeMovePad()">Done</button></div>' +
        '<div class="cem-pad-error" ng-if="st.dash.error">{{ st.dash.error }}</div></div>' +
      '<div class="cem" ng-class="{dark: dark}" ng-show="panel" role="dialog" aria-label="Cargo Earth menu">' +
      '<div class="cem-panel" ng-if="panel">' +
      '<nav class="cem-side" aria-label="Menu sections">' +
        '<div class="cem-brand">Cargo<b>Earth</b></div>' +
        '<div class="cem-money" ng-if="!paused()">{{ fmt.money(s.money) }}<small ng-if="s.debt > 0" style="cursor:pointer" title="Where it came from" ng-click="openPanel(\'career\', \'money\')">debt {{ fmt.money(s.debt) }}</small></div>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'garage\')}" ng-attr-aria-current="{{ panelOn(\'garage\') ? \'page\' : undefined }}" ng-click="openPanel(\'garage\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 21V8l9-5 9 5v13M7 21V11h10v10M7 15h10M7 18h10"/></svg>Garage</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'home\')}" ng-attr-aria-current="{{ panelOn(\'home\') ? \'page\' : undefined }}" ng-click="openPanel(\'home\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 11l9-8 9 8M5 10v11h5v-7h4v7h5V10"/></svg>Home</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'companies\')}" ng-attr-aria-current="{{ panelOn(\'companies\') ? \'page\' : undefined }}" ng-click="openPanel(\'companies\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 21h18M5 21V9l7-4v16M12 9h7v12M8 12h1M8 16h1M15 13h1M15 17h1"/></svg>Companies</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'career\', \'progress\')}" ng-attr-aria-current="{{ panelOn(\'career\', \'progress\') ? \'page\' : undefined }}" ng-click="openPanel(\'career\', \'progress\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 21V13h4v8M10 21V8h4v13M15 21V3h4v18"/></svg>Progress</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'career\', \'money\')}" ng-attr-aria-current="{{ panelOn(\'career\', \'money\') ? \'page\' : undefined }}" ng-click="openPanel(\'career\', \'money\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="18" height="13" rx="2"/><path d="M3 10h18M7 15h4"/></svg>Finances</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'career\', \'map\')}" ng-attr-aria-current="{{ panelOn(\'career\', \'map\') ? \'page\' : undefined }}" ng-click="openPanel(\'career\', \'map\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14"/></svg>Delivery map</button>' +
        '<button ng-if="!paused()" ng-class="{on: panelOn(\'career\', \'firm\')}" ng-attr-aria-current="{{ panelOn(\'career\', \'firm\') ? \'page\' : undefined }}" ng-click="openPanel(\'career\', \'firm\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 21V7l8-4 8 4v14M9 21v-6h6v6M8 10h2M14 10h2"/></svg>Firm</button>' +
        '<button ng-class="{on: panelOn(\'settings\')}" ng-attr-aria-current="{{ panelOn(\'settings\') ? \'page\' : undefined }}" ng-click="openPanel(\'settings\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="var(--card)"/><circle cx="15" cy="12" r="2" fill="var(--card)"/><circle cx="9" cy="18" r="2" fill="var(--card)"/></svg>Settings</button></nav>' +
      '<div class="cem-main"><div class="cem-head"><h1>{{ panelTitle() }}</h1>' +
        '<button class="cem-close" ng-click="closePanel()">Close</button></div>' +
      '<button class="cep-live cem-live" ng-if="showLiveShortcut() && (s.active || s.screen === \'incoming\')" ng-click="openLiveWork()">' +
        '<i class="cep-dot-live"></i><span><strong>{{ liveTitle() }}</strong><small>{{ liveDetail() }}</small></span><b aria-hidden="true">&rsaquo;</b></button>' +
      '<div class="cep-body" ng-if="panel === \'career\' && careerView === \'firm\'">' +
        '<div class="cep-sub" ng-if="!firm">Loading your firm…</div>' +
        '<div class="cep-scroll" ng-if="firm">' +
          '<div class="cep-msg" ng-if="firm.msg">{{ fmt.text(firm.msg) }}</div>' +
          '<div class="cep-card" ng-if="!firm.founded"><div class="cep-label">Your own firm</div>' +
            '<div class="cep-big">Start a firm</div>' +
            '<div class="cep-sub">A headquarters at a real place, with parking bays, a workshop, a fuel tank and an office. Only a firm can hire drivers.</div>' +
            '<div class="cep-keyval" ng-repeat="r in firm.requirements track by r.id" style="margin-top:6px;font-size:13px">' +
              '<span><span ng-style="{color: r.done ? \'var(--ok)\' : \'var(--muted)\'}">{{ r.done ? "✓" : "○" }}</span> {{ r.label }}</span>' +
              '<span class="cep-sub">{{ fmt.text(r.detail) }}</span></div>' +
            '<div class="cep-row" style="margin-top:10px"><input class="cep-input" maxlength="28" aria-label="Firm name" placeholder="{{ firm.suggested }}" ng-model="names.firm"></div>' +
            '<button class="cep-btn go" ng-disabled="!firm.ready" ng-click="fdo(\'found\', names.firm)">Found the firm · {{ fmt.money(firm.fee) }}</button></div>' +
          '<div class="cep-card" ng-if="firm.founded"><div class="cep-label">Your firm</div>' +
            '<div class="cep-big">{{ firm.name }}</div>' +
            '<div class="cep-sub" ng-if="firm.hq">Headquarters · {{ firm.hq.name }}<span ng-if="firm.hq.town"> · {{ firm.hq.town }}</span></div>' +
            '<div class="cep-sub" ng-if="firm.hq">{{ firm.hq.here ? "You are at the headquarters." : fmt.num(firm.hq.km) + " km away." }} Room for {{ firm.capacity }} vehicles.</div>' +
            '<button class="cep-btn go" ng-click="openHq()">Open headquarters</button>' +
            '<button class="cep-sm ghost" ng-if="firm.hq && !firm.hq.here" ng-click="fdo(\'gpsHq\')">Route to headquarters</button></div>' +
          '<div class="cep-card" ng-if="firm.founded && !firm.hq"><div class="cep-label">Choose the headquarters</div>' +
            '<div class="cep-sub">Park at a yard, a warehouse or your home garage and set it here. The first choice is free; moving later costs {{ fmt.money(firm.moveFee) }}.</div>' +
            '<div class="cep-sub" ng-if="firm.place">You are at <strong>{{ firm.place.name }}</strong>.</div>' +
            '<div class="cep-sub" ng-if="!firm.place">No yard, warehouse or home garage here.</div>' +
            '<button class="cep-btn ok" ng-disabled="!firm.place || !firm.parked" ng-click="fdo(\'setHq\')">Set the headquarters here</button></div>' +
        '</div></div>' +

      // career
      '<div class="cep-body" ng-if="panel === \'career\' && careerView === \'progress\'">' +
        '<div class="cep-sub" ng-if="!career">Loading career…</div>' +
        '<div class="cep-scroll" ng-if="career">' +
          '<div class="cep-card" ng-if="career.reputation"><div class="cep-label">Reputation</div>' +
            '<div class="cep-keyval"><strong>Courier</strong><span><span class="cep-stars">★</span> <strong>{{ fmt.num(career.reputation.courier.score) }}</strong>' +
              '<span class="cep-sub"> {{ fmt.trend(career.reputation.courier.trend) }}</span></span></div>' +
            '<div class="cep-sub">{{ career.reputation.courier.rated ? "Average of your last " + career.reputation.courier.rated + " food orders." : "No ratings yet." }}' +
              '<span ng-if="career.reputation.courier.premium"> Premium orders are coming in.</span>' +
              '<span ng-if="!career.reputation.courier.premium"> Premium orders from {{ fmt.num(career.reputation.courier.premiumAt) }} after {{ career.reputation.courier.premiumMin }} ratings.</span>' +
              '<span ng-if="career.reputation.courier.slow" style="color:var(--tomato)"> Orders ring less often until your rating recovers.</span></div>' +
            '<div class="cep-keyval" style="margin-top:8px"><strong>Freight</strong><span><span class="cep-stars">★</span> <strong>{{ fmt.num(career.reputation.freight.score) }}</strong>' +
              '<span class="cep-sub"> {{ fmt.trend(career.reputation.freight.trend) }}</span></span></div>' +
            '<div class="cep-sub">{{ career.reputation.freight.rated ? "Average of your last " + career.reputation.freight.rated + " freight and company jobs." : "No ratings yet." }}' +
              '<span ng-if="career.reputation.freight.payFactor > 1"> Preferred carrier: freight pays {{ fmt.pct(career.reputation.freight.payFactor - 1) }} more.</span>' +
              '<span ng-if="career.reputation.freight.payFactor < 1" style="color:var(--tomato)"> Freight pays {{ fmt.pct(1 - career.reputation.freight.payFactor) }} less until it recovers.</span></div></div>' +
          '<div class="cep-card" ng-if="career.fines.count"><div class="cep-label">Speed cameras</div>' +
            '<div class="cep-keyval"><span>Fines</span><strong>{{ career.fines.count }} · {{ fmt.money(career.fines.paid) }}</strong></div></div>' +
          '<div class="cep-card"><div class="cep-label">Delivery rank</div>' +
            '<div class="cep-big">{{ career.rank }}</div>' +
            '<div ng-if="career.nextRank">' +
              '<div class="cep-sub">Next rank · {{ career.nextRank }}</div>' +
              '<div class="cep-time" role="progressbar" aria-label="Progress toward next rank" aria-valuemin="0" ' +
                'ng-attr-aria-valuemax="{{ career.nextAt }}" ng-attr-aria-valuenow="{{ career.completed }}">' +
                '<i ng-style="{width: (career.completed / career.nextAt * 100) + \'%\'}"></i></div>' +
              '<div class="cep-sub">{{ fmt.int(career.completed) }} of {{ fmt.int(career.nextAt) }} deliveries</div></div>' +
            '<div class="cep-sub" ng-if="!career.nextRank">Highest rank reached</div></div>' +
          '<div class="cep-card cep-stats"><div>{{ fmt.int(career.completed) }}<span>delivered</span></div>' +
            '<div>{{ fmt.int(career.ruined) }}<span>ruined</span></div>' +
            '<div>{{ fmt.int(career.drivenKm || 0) }} km<span>driven</span></div></div>' +
          '<div class="cep-label">Cargo milestones</div>' +
          '<div class="cep-card" ng-repeat="goal in career.cargo track by goal.id">' +
            '<div class="cep-keyval"><strong>{{ goal.name }}</strong>' +
              '<span class="cep-sub" ng-if="goal.complete" style="color:var(--ok)">Completed</span></div>' +
            '<div class="cep-sub">{{ fmt.text(goal.detail) }}</div></div>' +
          '<div class="cep-card" ng-if="career.trucking"><div class="cep-label">Freight</div>' +
            '<div class="cep-name">{{ career.trucking.label }}</div>' +
            '<div class="cep-sub" ng-if="career.trucking.van < career.trucking.vanGoal">Van hauls {{ career.trucking.van }} / {{ career.trucking.vanGoal }} to unlock rigid trucks</div>' +
            '<div class="cep-sub" ng-if="career.trucking.van >= career.trucking.vanGoal">{{ career.trucking.van }} van hauls · rigid trucks unlocked</div>' +
            '<div class="cep-sub" ng-if="career.trucking.rigid < career.trucking.rigidGoal">Rigid hauls {{ career.trucking.rigid }} / {{ career.trucking.rigidGoal }} to unlock semis</div>' +
            '<div class="cep-sub" ng-if="career.trucking.rigid >= career.trucking.rigidGoal">{{ career.trucking.rigid }} rigid hauls · semis unlocked</div>' +
            '<div class="cep-sub" ng-if="career.trucking.unlocked === \'semi\'">{{ career.trucking.semi }} articulated hauls completed</div></div>' +
        '</div></div>' +

      // finances: bounded ledger, liquid balance and wages still held at the company
      '<div class="cep-body" ng-if="panel === \'career\' && careerView === \'money\'">' +
        '<div class="cep-sub" ng-if="!career">Loading finances.</div>' +
        '<div class="cep-scroll" ng-if="career">' +
          '<div class="cep-card"><div class="cep-label">Available balance</div><div class="cep-pay">{{ fmt.money(s.money) }}</div>' +
            '<div class="cep-sub" ng-if="s.currency">In {{ s.currency.code }}<span ng-if="s.currency.country"> ({{ s.currency.country }})</span>. Exchanged for free at borders.</div></div>' +
          '<div class="cep-money-grid"><div class="cep-card"><strong>{{ fmt.money(s.todayEarned) }}</strong><span>Earned today</span></div>' +
            '<div class="cep-card"><strong ng-class="{\'cep-debit\': career.debt > 0}">{{ fmt.money(career.debt) }}</strong><span>Outstanding debt</span></div></div>' +
          '<div class="cep-card" ng-if="s.company"><div class="cep-label">Company wages held</div><div class="cep-name">{{ fmt.money(career.heldWages) }}</div><div class="cep-sub">Paid when the contract ends.</div>' +
            '<button class="cep-sm ghost" ng-click="openCompany()">Open active contract</button></div>' +
          // debt: what it is made of (open charges by source) and what added to it or paid it off
          '<div class="cep-card" style="grid-column:1/-1" ng-if="career.debtInfo && (career.debt > 0 || career.debtInfo.log.length)" ng-style="career.debt > 0 ? {\'box-shadow\': \'inset 0 0 0 1.5px var(--tomato)\'} : {}">' +
            '<div class="cep-label">Debt</div>' +
            '<div class="cep-name" ng-class="{\'cep-debit\': career.debt > 0}">{{ career.debt > 0 ? fmt.money(career.debt) : "Nothing owed" }}</div>' +
            '<div class="cep-sub" ng-if="career.debt > 0">{{ career.debtInfo.share * 100 }} % of each delivery goes to it. No buying until it is paid.</div>' +
            '<div ng-if="career.debt > 0"><div class="cep-label" style="margin-top:8px">Where it comes from</div>' +
              '<div class="cep-keyval" ng-repeat="src in career.debtInfo.sources track by src.kind"><span>{{ src.label }}<small class="cep-sub" ng-if="src.count > 1"> · {{ src.count }} charges</small></span><strong class="cep-debit" style="white-space:nowrap;margin-left:12px">{{ fmt.money(src.amount) }}</strong></div>' +
              '<button class="cep-sm ghost" ng-click="toggleDebtCharges()">{{ debtCharges ? "Hide the charges" : "Show each charge" }}</button>' +
              '<div ng-if="debtCharges"><div class="cep-keyval" ng-repeat="ch in career.debtInfo.open track by $index"><span>{{ fmt.text(ch.what) }}<small class="cep-meta" ng-if="ch.at"> · {{ ch.at }}</small></span><strong class="cep-debit" style="white-space:nowrap;margin-left:12px">{{ fmt.money(ch.left) }}</strong></div></div>' +
              '<div class="cep-row" style="margin-top:6px"><button class="cep-sm" ng-if="!s.company" ng-disabled="!(s.money > 0)" ng-click="payDebt()">Pay what I can</button>' +
                '<button class="cep-sm ghost" ng-click="setTab(\'garage\')">Garage</button></div></div>' +
            '<div ng-if="career.debtInfo.log.length"><div class="cep-label" style="margin-top:8px">Debt history</div>' +
              '<div class="cep-keyval" ng-repeat="e in career.debtInfo.log track by $index"><span>{{ fmt.text(e.what) || (e.amount > 0 ? "Added" : "Paid") }}<small class="cep-meta"> · {{ e.at }} · owed after {{ fmt.money(e.left) }}</small></span>' +
                '<strong style="white-space:nowrap;margin-left:12px" ng-class="{\'cep-debit\': e.amount > 0, \'cep-credit\': e.amount < 0}">{{ e.amount > 0 ? "+" : "−" }}{{ fmt.money(e.amount > 0 ? e.amount : -e.amount) }}</strong></div></div>' +
          '</div>' +
          '<div class="cep-label">Latest transactions</div>' +
          '<div class="cep-empty cep-sub" ng-if="!career.ledger.length">No transactions yet.</div>' +
          '<div class="cep-card" ng-repeat="entry in career.ledger | limitTo:20 track by entry.id">' +
            '<div class="cep-keyval"><strong>{{ fmt.cat(entry.category) }}</strong><strong ng-class="{\'cep-credit\': entry.amount > 0, \'cep-debit\': entry.amount < 0}">{{ entry.amount > 0 ? "+" : "" }}{{ fmt.money(entry.amount) }}</strong></div>' +
            '<div class="cep-sub">{{ fmt.text(entry.detail) }}</div><div class="cep-meta">{{ entry.date }} / Balance {{ fmt.money(entry.balance) }}</div></div>' +
        '</div></div>' +

      // map: the latest deliveries as dots, and personal records
      '<div class="cep-body" ng-if="panel === \'career\' && careerView === \'map\'">' +
        '<div class="cep-sub" ng-if="!mapData">Loading your map.</div>' +
        '<div class="cep-scroll" ng-if="mapData">' +
          '<div class="cep-empty cep-sub" ng-if="!mapData.count">No deliveries yet. Each drop-off leaves a dot.</div>' +
          '<div ng-if="mapData.count"><svg class="cep-map" viewBox="-4 -4 108 108" role="img" aria-label="Map of your latest deliveries">' +
            '<path ng-attr-d="{{ mapPaths.f }}" fill="none" style="stroke:var(--ink)" stroke-width="2.6" stroke-linecap="round"/>' +
            '<path ng-attr-d="{{ mapPaths.c }}" fill="none" stroke="#e8452c" stroke-width="2.6" stroke-linecap="round" stroke-opacity=".8"/>' +
            '<path ng-attr-d="{{ mapPaths.home }}" fill="none" stroke="#2f8f5b" stroke-width="5.5" stroke-linecap="square"/>' +
            '<path ng-attr-d="{{ mapPaths.hq }}" fill="none" stroke="#c98a10" stroke-width="5.5" stroke-linecap="square"/></svg>' +
            '<div class="cep-legend" style="margin-top:6px"><span><i style="background:#e8452c"></i>Food</span><span><i style="background:var(--ink)"></i>Freight</span>' +
              '<span ng-if="mapPaths.home"><i style="background:#2f8f5b;border-radius:2px"></i>Home</span>' +
              '<span ng-if="mapPaths.hq"><i style="background:#c98a10;border-radius:2px"></i>Firm</span></div>' +
            '<div class="cep-sub">Your last {{ mapData.count }} drop-offs · north is up · about {{ fmt.num(mapData.spanKm) }} km across</div></div>' +
          '<div class="cep-label">Personal records</div>' +
          '<div class="cep-card">' +
            '<div class="cep-keyval"><span class="cep-sub">Five-star run</span><strong>{{ mapData.records.streak }} now · best {{ mapData.records.bestStreak }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestPay"><span class="cep-sub">Best paid order</span><strong>{{ fmt.money(mapData.records.bestPay.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestTip.value > 0"><span class="cep-sub">Biggest tip</span><strong>{{ fmt.money(mapData.records.bestTip.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.longest"><span class="cep-sub">Longest order</span><strong>{{ fmt.km(mapData.records.longest.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.quickest"><span class="cep-sub">Most time to spare</span><strong>{{ mapData.records.quickest.value }} %</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestDay"><span class="cep-sub">Best day</span><strong>{{ fmt.money(mapData.records.bestDay.value) }}</strong></div>' +
            '<div class="cep-meta" ng-if="mapData.records.bestDay">{{ mapData.records.bestDay.date }}</div></div>' +
        '</div></div>' +

      // places: persistent home address and company contracts
      '<div class="cep-body" ng-if="(panel === \'home\' || panel === \'companies\')"><div class="cep-sub" ng-if="!places">{{ panel === "home" ? "Loading home garage." : "Loading company contracts." }}</div>' +
        '<div class="cep-msg" role="status" ng-if="places.msg">{{ fmt.text(places.msg) }}</div>' +
        '<div class="cep-scroll" ng-if="places && !places.blocked">' +
          '<div ng-if="panel === \'home\'" style="display:flex;flex-direction:column;gap:8px">' +
          '<div class="cep-card" ng-if="places.home"><div class="cep-label">Home garage</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.home.name }}</div><div class="cep-sub">{{ places.home.town }}</div>' +
            '<div class="cep-sub">{{ places.used }} / {{ places.capacity || places.home.capacity }} owned vehicles. {{ places.atHome ? "You are home." : fmt.num(places.homeKm) + " km away." }}</div>' +
          '</div>' +
          '<div class="cep-label">{{ places.home ? "Change home address" : "Choose your home garage" }}</div>' +
          '<div class="cep-sub">Find an address within 3 km, drive there and park to make it home.</div>' +
          '<input class="cep-search" type="text" maxlength="100" aria-label="Street or town" placeholder="Street or town" ng-model="placeSearch.text">' +
          '<button class="cep-sm ghost" ng-click="pdo(\'search\', placeSearch.text)">Search</button>' +
          '<div class="cep-card" ng-repeat="address in places.addresses track by address.id">' +
            '<div class="cep-name" style="white-space:normal">{{ address.n }}</div><div class="cep-sub">{{ address.town }} · {{ fmt.num(address.km) }} km</div>' +
            '<button class="cep-sm" ng-click="pdo(\'select\', address.id)">{{ places.selected.id === address.id ? "Selected" : "Select address" }}</button></div>' +
          '<div class="cep-card" ng-if="places.selected"><div class="cep-label">Selected address</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.selected.n }}</div>' +
          '</div></div>' +
          '<div ng-if="panel === \'companies\'" style="display:flex;flex-direction:column;gap:8px">' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'loading\' || places.discovery.state === \'searching\'">Finding workplaces around you…</div>' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'off\'">Start the Cargo Earth helper to find workplaces here.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.supportsDepots === false">Update the helper to 0.3.0 for workplace discovery.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.msg">{{ fmt.text(places.discovery.msg) }}</div>' +
          '<div class="cep-sub">The company lends you a van, or a truck once you unlock it, and pays its costs. You get 80 % of the delivery pay when the work ends; damaged loads pay less, ruined ones nothing.</div>' +
          '<div class="cep-card" ng-if="places.shift"><div class="cep-name" style="white-space:normal">{{ places.shift.company }}</div>' +
            '<div class="cep-label" ng-if="places.shift.ownerOperator">Your own {{ places.shift.vehicle || "van" }}</div>' +
            '<div class="cep-sub">{{ places.shift.completed }} of {{ places.shift.total }} deliveries · {{ fmt.money(places.shift.held) }} held</div>' +
            '<div class="cep-impact-note" ng-if="places.shift.failed">{{ places.shift.failed }} ruined, unpaid.</div>' +
            '<div class="cep-sub" ng-if="places.shift.vehicleDamage > 0">Vehicle damage {{ fmt.money(places.shift.vehicleDamage) }}{{ places.shift.ownerOperator ? "" : ": the company pays, your reputation suffers" }}.</div>' +
            '<div class="cep-sub">Reputation {{ places.shift.reputationScore > 0 ? "+" : "" }}{{ places.shift.reputationScore }} so far.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'preparing\'">Getting the {{ places.shift.vehicle || "vehicle" }} ready…</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'working\'">The deliveries are on the phone under Work.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'returning\'">Drive back to the yard and park to collect your wages.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'settled\'">Wages paid. Bringing back your car…</div>' +
            '<div class="cep-sub" ng-if="places.shift.error">{{ places.shift.error }}</div>' +
          '</div>' +
          '<div ng-if="!places.shift"><button class="cep-sm ghost" ng-disabled="places.busy" ng-click="pdo(\'refreshCompanies\')">Find company contracts</button>' +
            '<div class="cep-sub" ng-if="!places.started">Start your career in Garage first.</div>' +
            '<div class="cep-empty cep-sub" ng-if="!places.companies.length">No contracts nearby yet. Try again in a moment or somewhere else.</div>' +
            '<div class="cep-card" ng-repeat="company in places.companies track by company.id">' +
              '<div class="cep-name" style="white-space:normal">{{ company.name }}</div>' +
              '<div class="cep-sub">{{ company.vehicle }} · yard {{ fmt.num(company.km) }} km away · 2 deliveries · about {{ company.minutes }} min</div>' +
              '<div class="cep-keyval"><span class="cep-sub">Wages</span><strong>about {{ fmt.money(company.wages) }}</strong></div>' +
              '<div class="cep-sub">Reputation {{ company.reputation }} / 100</div>' +
              '<button class="cep-sm ghost" ng-disabled="places.busy" ng-click="pdo(\'companyGps\', company.id)">Route to yard</button>' +
              '<button class="cep-btn go" ng-disabled="places.busy || !places.started || !company.atYard" ng-click="pdo(\'startCompany\', company.id)">' +
                '{{ company.atYard ? "Start" : "Park at the yard to start" }}</button>' +
              '<div class="cep-sub" ng-if="company.van && !company.independentUnlocked">Your own van: at 20 reputation.</div>' +
              '<button class="cep-btn ghost" ng-if="company.van && company.independentUnlocked" ng-disabled="places.busy || !company.atYard" ng-click="pdo(\'startIndependent\', company.id)">' +
                'Use my own van · {{ fmt.money(company.independentPay) }}</button></div></div>' +
          '<div class="cep-card" ng-if="places.last && !places.shift"><div class="cep-label">Last company settlement</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.last.company }}</div>' +
            '<div class="cep-keyval"><span>Delivery revenue</span><strong>{{ fmt.money(places.last.gross) }}</strong></div>' +
            '<div class="cep-keyval"><span>Company share</span><strong>-{{ fmt.money(places.last.share) }}</strong></div>' +
            '<div class="cep-keyval"><span>Your wages</span><strong>{{ fmt.money(places.last.wages) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="places.last.toDebt"><span>Debt repayment</span><strong>-{{ fmt.money(places.last.toDebt) }}</strong></div>' +
            '<div class="cep-keyval"><span>Added to balance</span><strong>{{ fmt.money(places.last.net) }}</strong></div>' +
            '<div class="cep-sub" ng-if="places.last.failed">{{ places.last.failed }} ruined, unpaid.</div>' +
            '<div class="cep-sub" ng-if="places.last.vehicleDamage > 0">{{ places.last.ownerOperator ? "Your" : "Company" }} {{ places.last.vehicle || "vehicle" }} damage {{ fmt.money(places.last.vehicleDamage) }}</div>' +
            '<div class="cep-keyval" ng-if="places.last.reputationChange !== undefined"><span>Reputation change</span><strong>{{ places.last.reputationChange > 0 ? "+" : "" }}{{ places.last.reputationChange }}</strong></div>' +
            '<div class="cep-sub" ng-if="places.last.reputationScore < 0">Score {{ places.last.reputationScore }} (reputation stops at zero).</div>' +
            '<div class="cep-sub" ng-if="places.last.aborted">Ended early; done deliveries paid.</div></div></div>' +
        '</div>' +
        '<div class="cep-actionbar" aria-label="Home address actions" ng-if="panel === \'home\' && (places.selected || places.home) && !places.blocked">' +
          '<div class="cep-label" ng-if="places.selected">Selected: {{ places.selected.n }}</div><div class="cep-row" ng-if="places.selected">' +
            '<button class="cep-btn ghost" ng-disabled="places.busy || places.shift" ng-click="pdo(\'routeSelected\')">Route to address</button>' +
            '<button class="cep-btn go" ng-disabled="places.busy || places.shift" ng-click="pdo(\'claimHome\')">Make this my home</button></div>' +
          '<button class="cep-sm ghost" ng-if="places.home" ng-disabled="places.busy || places.shift" ng-click="pdo(\'homeGps\')">Route home</button></div>' +
        '<div class="cep-actionbar" aria-label="Company shift actions" ng-if="panel === \'companies\' && places.shift && !places.blocked">' +
          '<button class="cep-btn ok" ng-if="places.shift.phase === \'returning\' || places.shift.phase === \'settled\'" ' +
            'ng-disabled="!places.shift.atYard && places.shift.phase !== \'settled\'" ng-click="pdo(\'settleCompany\')">Collect wages and return my car</button>' +
          '<div class="cep-row"><button class="cep-sm ghost" ng-if="!places.busy" ng-click="pdo(\'companyGps\')">Route to yard</button>' +
            '<button class="cep-sm ghost" ng-click="endCompany()">{{ endCompanyAsk ? "Press again: end shift" : "End early" }}</button></div></div>' +
        '</div>' +
      // garage
      '<div class="cep-body" ng-if="panel === \'garage\'">' +
        '<div class="cep-sub" role="status" ng-if="!g && !pageErrors.g">Loading Garage.</div>' +
        '<div class="cep-msg" role="alert" ng-if="pageErrors.g">{{ pageErrors.g }} <button class="cep-sm ghost" ng-click="retryGarage()">Retry Garage</button></div>' +
        '<div class="cep-card" ng-if="s.screen === \'parts\' && !g.parts"><div class="cep-label">Parts checkout pending</div>' +
          '<div class="cep-sub">Your changes are a preview. Retry checkout or restore the paid configuration.</div>' +
          '<button class="cep-btn ghost" ng-click="gdo(\'cancelParts\')">Discard preview and restore car</button></div>' +
        '<div class="cep-msg" ng-if="g.msg">{{ fmt.text(g.msg) }}</div>' +
        '<div class="cep-subtabs" style="margin:0" ng-if="g.started && !g.preview && !g.parts" aria-label="Garage sections">' +
          '<button ng-class="{on: gview === \'home\'}" ng-click="goHome()">My car</button>' +
          '<button ng-class="{on: gview === \'fleet\'}" ng-click="openFleet()">My cars</button>' +
          '<button ng-class="{on: gview === \'cars\'}" ng-click="openCars()">Used cars</button></div>' +
        '<div ng-if="g && !g.started" class="cep-center">' +
          '<div class="cep-label">Your career</div><div class="cep-big">Start with an old {{ g.starter }}</div>' +
          '<div class="cep-sub">You get the cheapest {{ g.starter }} and {{ fmt.money(g.startMoney) }}. Free play money, ratings and stats do not carry over. ' +
          'Orders then only come while you drive this car. Buy parts and better cars from what you earn.</div>' +
          '<div class="cep-sub" ng-if="g.busy" style="color:var(--tomato)">Your current order will be cancelled (no fee).</div>' +
        '</div><button class="cep-btn go" ng-if="g && !g.started" ng-click="gdo(\'start\')">Start my career</button>' +
        '<div ng-if="g && g.started && gview === \'home\' && g.preview && !g.parts" class="cep-scroll">' +
          '<div class="cep-card"><div class="cep-label">For sale · you are sitting in it</div>' +
            '<div class="cep-name" style="font-size:17px;white-space:normal">{{ g.preview.name }}</div>' +
            '<div class="cep-sub">{{ fmt.int(g.preview.km) }} km · condition {{ fmt.cond(g.preview.condition) }}</div>' +
            '<div class="cep-time" style="height:4px;margin-top:6px" ng-class="{warn: g.preview.condition < 0.6, late: g.preview.condition < 0.35}">' +
              '<i ng-style="{width: (g.preview.condition * 100) + \'%\'}"></i></div></div>' +
          '<div class="cep-label">Missing parts</div>' +
          '<div class="cep-sub" ng-if="g.preview.error">{{ g.preview.error }}</div>' +
          '<div class="cep-sub" ng-if="!g.preview.ready && !g.preview.error">Checking the car…</div>' +
          '<div class="cep-sub" ng-if="g.preview.ready && !g.preview.missing.length">Nothing missing.</div>' +
          '<div class="cep-sub" ng-if="g.preview.missing.length" style="color:var(--ink)">{{ g.preview.missing.join(", ") }}</div>' +
          '<div class="cep-sub" ng-if="g.preview.paint">Paint finish · {{ g.preview.paint }}</div>' +
          '<div class="cep-sub">Price {{ fmt.money(g.preview.price) }}<span ng-if="g.preview.tradeIn > 0">, your car is taken in for ' +
            '{{ fmt.money(g.preview.tradeIn) }}: you pay {{ fmt.money(g.preview.price - g.preview.tradeIn) }}</span>.</div>' +
          '<div class="cep-sub" ng-if="g.preview.keepCar">Your current car will be parked in My cars.</div>' +
        '</div>' +

        '<div ng-if="g && g.started && gview === \'home\' && !g.preview && !g.parts" class="cep-scroll">' +
          '<div class="cep-card" ng-if="g.car"><div class="cep-label">Your car</div><div class="cep-name" style="font-size:17px;white-space:normal">{{ g.car }}</div>' +
            '<div class="cep-sub">{{ fmt.int(g.km) }} km<span ng-if="g.own"> · {{ fmt.cond(g.condition) }} · worth about {{ fmt.money(g.value) }}</span></div>' +
            '<div class="cep-sub" ng-if="!g.own" style="color:var(--tomato)">You are not in it. Orders only come in your own car.</div></div>' +
          '<div class="cep-card" ng-if="g.own && s.storage.capacity">' +
            '<div class="cep-label">Cargo space</div>' +
            '<div class="cep-sub" ng-if="s.storage.boxes">{{ s.storage.boxes }} fitted cargo box{{ s.storage.boxes > 1 ? "es" : "" }}' +
              ' · {{ s.storage.capacity }} slots · {{ fmt.num(s.storage.kg) }} kg loaded</div>' +
            '<div class="cep-sub" ng-if="!s.storage.boxes">Starter bag · 1 slot. Fit a parcel box in the Parts shop to carry more.</div></div>' +
          '<div class="cep-card" ng-if="g.fuel"><div class="cep-keyval"><span class="cep-label">{{ g.fuel.unit === "kWh" ? "Battery" : "Fuel" }}</span>' +
              '<strong ng-if="!g.fuel.reading">{{ fmt.num(g.fuel.have) }} / {{ fmt.num(g.fuel.cap) }} {{ g.fuel.unit }}</strong></div>' +
            '<div class="cep-sub" ng-if="g.fuel.reading">Reading the fuel gauge…</div>' +
            '<div ng-if="!g.fuel.reading">' +
              '<div class="cep-time" role="progressbar" aria-label="Fuel level" aria-valuemin="0" aria-valuemax="100" ng-attr-aria-valuenow="{{ fmt.int(g.fuel.share * 100) }}" ' +
                'ng-class="{warn: g.fuel.low && !g.fuel.empty, late: g.fuel.empty}"><i ng-style="{width: (g.fuel.share * 100) + \'%\'}"></i></div>' +
              '<div class="cep-sub">About {{ g.fuel.rangeKm }} km left · ' +
                '{{ g.fuel.per100 ? fmt.num(g.fuel.per100) + " " + g.fuel.unit + "/100 km over " + g.fuel.measuredKm + " km" : "average use shows after 5 km" }}</div>' +
              '<div class="cep-sub" ng-if="g.fuel.per100">Running cost about {{ fmt.price(g.fuel.costPerKm) }} per km.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.free">Company fuel card: free fuel.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.empty" style="color:var(--tomato)">The tank is empty.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.locked">This tank cannot be filled from here; use a pump.</div>' +
              '<div ng-if="g.fuel.station"><div class="cep-name" style="white-space:normal;margin-top:6px">{{ g.fuel.station.name }}</div>' +
                '<div class="cep-sub">{{ g.fuel.station.at ? "You are at the pumps" : fmt.num(g.fuel.station.km) + " km away" }} · ' +
                  '{{ fmt.price(g.fuel.station.price) }} per {{ g.fuel.unit }}</div></div>' +
              '<div class="cep-sub" ng-if="!g.fuel.station">No {{ g.fuel.unit === "kWh" ? "charger" : "fuel station" }} known nearby.</div>' +
              '<button class="cep-btn go" ng-if="g.fuel.fill" ng-disabled="g.fuel.busy || g.fuel.locked || !(g.fuel.fill.canCost > 0 || g.fuel.free)" ng-click="gdo(\'refuel\')">' +
                '{{ g.fuel.busy ? "Refuelling…" : (g.fuel.free ? "Fill up" : (g.fuel.fill.afford ? "Fill up · " + fmt.money(g.fuel.fill.cost) : ' +
                  '(g.fuel.fill.canCost > 0 ? "Buy " + g.fuel.fill.units + " · " + fmt.money(g.fuel.fill.canCost) : "Not enough money"))) }}</button>' +
              '<div class="cep-row" ng-if="g.fuel.fill && g.fuel.partial.length" style="margin-top:6px;flex-wrap:wrap;gap:6px">' +
                '<button class="cep-sm" ng-repeat="p in g.fuel.partial track by p.pct" ng-disabled="g.fuel.busy || g.fuel.locked || !p.afford" ' +
                  'title="{{ p.units }}" ng-click="gdo(\'refuelTo\', p.pct)">To {{ p.pct }} %{{ g.fuel.free ? "" : " · " + fmt.money(p.cost) }}</button></div>' +
              '<button class="cep-sm ghost" ng-if="g.fuel.station && !g.fuel.station.at" ng-disabled="g.busy" ng-click="gdo(\'fuelGps\')">Route there</button>' +
              '<button class="cep-sm ghost" ng-if="g.fuel.delivery && (!g.fuel.station.at || !g.fuel.fill || g.fuel.fill.canCost <= 0)" ng-disabled="g.fuel.busy || g.fuel.locked" ng-click="confirmDelivery()">' +
                '{{ deliveryAsk ? "Press again · " + fmt.money(g.fuel.delivery.cost) : "Bring fuel here · " + g.fuel.delivery.units + " for " + fmt.money(g.fuel.delivery.cost) }}</button>' +
            '</div></div>' +
          '<div class="cep-card" ng-if="!g.car"><div class="cep-label">Your car</div><div class="cep-name" style="font-size:17px">No active car</div>' +
            '<div class="cep-sub">Pick one in My cars or buy one in Used cars.</div></div>' +

          '<div class="cep-li" ng-if="g.own"><div><div class="cep-name">Damage</div>' +
            '<small>{{ g.repair > 0 ? "About " + fmt.hrs(g.repairHours) + " of deliveries" + (g.repairCapped ? " (capped at half the car\'s value)" : "") + ". The game\'s own repair adds it to your debt." : "None" }}</small></div>' +
          '</div>' +
          '<div class="cep-card" ng-if="g.breakdown" role="alert" style="box-shadow:inset 0 0 0 1.5px var(--tomato)"><div class="cep-label" style="color:var(--tomato)">Breakdown</div>' +
            '<div class="cep-sub">{{ fmt.text(g.breakdown.text) }}</div>' +
          '</div>' +
          '<div class="cep-li" ng-if="g.upkeep && g.own"><div><div class="cep-name">Service</div>' +
            '<small ng-repeat="it in g.upkeep.items track by it.id" ng-style="it.due ? {color: \'var(--tomato)\'} : {}">{{ it.name }}: {{ it.due ? "overdue" : fmt.int(it.kmLeft) + " km left" }}{{ $last ? "" : " · " }}</small>' +
            '<div><small ng-if="g.upkeep.due > 0 && !g.upkeep.where">Service at a fuel station or your headquarters. Overdue parts can break down.</small></div></div>' +
            '<button class="cep-sm go" ng-if="g.upkeep.due > 0" ng-disabled="!g.upkeep.where || g.money < g.upkeep.dueCost" ng-click="gdo(\'service\')">Service {{ fmt.money(g.upkeep.dueCost) }}</button></div>' +
          '<div class="cep-li" ng-if="g.debt > 0" style="box-shadow:inset 0 0 0 1.5px var(--tomato)"><div><div class="cep-name" style="color:var(--tomato)">Debt {{ fmt.money(g.debt) }}</div>' +
            '<small>{{ g.debtShare * 100 }} % of each delivery goes to it. No buying until it is paid.</small>' +
            '<div ng-repeat="src in g.debtInfo.sources track by src.kind"><small>{{ src.label }}: {{ fmt.money(src.amount) }}</small></div>' +
            '<button class="cep-sm ghost" ng-click="openPanel(\'career\', \'money\')">Where it came from</button></div>' +
            '<button class="cep-sm" ng-disabled="!(g.money > 0)" ng-click="gdo(\'paydebt\')">Pay</button></div>' +
          '<button class="cep-sm ghost" ng-if="g.own && !g.loaner" ng-click="confirmSell()">{{ sellAsk ? "Press again to sell · " + fmt.money(g.sellPrice) : "Sell my car · " + fmt.money(g.sellPrice) }}</button>' +
          '<div class="cep-label" ng-if="g.spares.length">Spare parts</div>' +

          '<div class="cep-li" ng-repeat="p in g.spares"><div class="cep-name">{{ p.name }}{{ p.count > 1 ? " ×" + p.count : "" }}</div>' +
            '<button class="cep-sm ghost" ng-click="gdo(\'sell\', p.part)">Sell {{ fmt.money(p.price) }}</button></div>' +
          '<button class="cep-sm ghost" ng-click="gdo(\'bring\')" ng-if="g.own">Respawn my car with its parts</button>' +
        '</div>' +
        '<div ng-if="g.parts" class="cep-scroll">' +
          '<div class="cep-label">Parts checkout</div>' +
          '<div class="cep-sub">The game\'s Apply only previews parts. Confirm here before you drive off, or the changes are dropped.</div>' +
          '<div class="cep-sub" ng-if="g.parts.error">{{ g.parts.error }}</div>' +
          '<button class="cep-sm ghost" ng-if="g.parts.error" ng-click="retryGarage()">Retry checkout</button>' +
          '<div class="cep-sub" ng-if="g.parts.items && !g.parts.items.length">No parts added or removed.</div>' +
          '<div class="cep-li" ng-repeat="p in g.parts.items track by p.part"><div style="min-width:0">' +
            '<div class="cep-name" style="white-space:normal">{{ p.name }}</div><small>' +
              '<span ng-if="p.buy">Buy ×{{ p.buy }} </span><span ng-if="p.fit">Fit spare ×{{ p.fit }} </span>' +
              '<span ng-if="p.keep">Keep as spare ×{{ p.keep }}</span></small></div>' +
            '<b ng-if="p.cost">{{ fmt.money(p.cost) }}</b></div>' +
        '</div>' +
        '<div ng-if="g.parts" class="cep-actionbar" aria-label="Parts checkout actions">' +
          '<div class="cep-label" ng-if="g.parts.items">Total {{ fmt.money(g.parts.cost) }}</div>' +
          '<button class="cep-btn go" ng-disabled="!g.parts.canBuy" ng-click="gdo(\'buyParts\', g.parts.revision)">' +
            '{{ g.parts.cost > 0 ? "Buy all for " + fmt.money(g.parts.cost) : "Keep changes" }}</button>' +
          '<button class="cep-btn ghost" ng-click="gdo(\'cancelParts\')">Discard preview and restore car</button>' +
          '<button class="cep-sm ghost" ng-if="!g.parts.blocked" ng-click="gdo(\'openParts\')">Back to parts picker</button>' +
        '</div>' +
        '<div ng-if="g.fleet && gview === \'fleet\' && !g.preview && !g.parts" class="cep-scroll">' +
          '<button class="cep-sm ghost" ng-click="goHome()">‹ Back</button>' +
          '<div class="cep-label">My cars</div>' +
          '<div class="cep-card" ng-if="g.car"><div class="cep-name">{{ g.car }}</div>' +
            '<div class="cep-sub">Active car · {{ fmt.int(g.km) }} km</div></div>' +
          '<div class="cep-card"><div class="cep-label">Drivers</div>' +
            '<div class="cep-sub" ng-if="!g.fleet.unlocked">Only a firm with a headquarters can hire drivers (Menu → Firm).</div>' +
            '<div class="cep-sub" ng-if="g.fleet.unlocked">Hire them in the headquarters, where you pick who drives what.</div>' +
            '<div class="cep-sub" ng-if="g.fleet.earned > 0">Drivers have earned {{ fmt.money(g.fleet.earned) }}</div></div>' +
          '<div class="cep-sub" ng-if="!g.fleet.cars.length">No other cars yet. Tick "Keep my current car" when buying one.</div>' +
          '<div class="cep-sub" ng-if="g.busy && g.fleet.cars.length">Finish your orders before switching cars.</div>' +
          '<div class="cep-card" ng-repeat="v in g.fleet.cars track by v.id">' +
            '<div class="cep-name" style="white-space:normal">{{ v.name }}</div>' +
            '<div class="cep-sub">{{ fmt.int(v.km) }} km · {{ v.driver ? "With a driver" : "Parked" }}</div>' +
            '<div class="cep-sub" ng-if="v.storageSlots">{{ v.boxCount ? v.boxCount + " fitted boxes" : "Starter bag" }} · {{ v.storageSlots }} slots</div>' +
                        '<div class="cep-sub" ng-if="v.repair > 0">Needs {{ fmt.money(v.repair) }} of repairs.</div>' +
            '<div class="cep-sub" ng-if="v.driver">{{ v.driver.name }} · earned {{ fmt.money(v.driver.earned) }}{{ v.driver.waiting === "repair" ? " · waiting for a repair" : (v.driver.waiting === "trailer" ? " · needs a trailer" : (v.driver.waiting === "licence" ? " · no licence for it" : (v.driver.waiting === "boxes" ? " · needs cargo boxes" : " · next shift in " + v.driver.nextMin + " min"))) }}</div>' +
            '<div class="cep-sub" ng-if="v.upkeep && v.upkeep.due > 0" style="color:var(--tomato)">Service due · {{ fmt.money(v.upkeep.dueCost) }} at the headquarters</div>' +
            '<div class="cep-row" style="margin-top:6px">' +
              '<button class="cep-sm go" ng-if="!v.driver" ng-disabled="g.busy" ng-click="gdo(\'switchCar\', v.id)">Drive</button>' +
              '<button class="cep-sm" ng-if="g.fleet.unlocked && !v.driver && !v.loaner" ng-click="openHq()">Hire a driver</button>' +
              '<button class="cep-sm ghost" ng-if="v.driver" ng-click="gdo(\'releaseDriver\', v.id)">Release driver</button></div>' +
          '</div></div>' +
        '<div ng-if="g && g.started && gview === \'cars\' && !g.parts" class="cep-scroll cep-market-list">' +
          // the car being looked at stays on top of the list, so the next one is a tap away
          '<div class="cep-card" ng-if="g.preview"><div class="cep-label">Looking at</div>' +
            '<div class="cep-keyval"><strong style="white-space:normal">{{ g.preview.name }}</strong><strong style="white-space:nowrap">{{ fmt.money(g.preview.price - (g.preview.tradeIn || 0)) }}</strong></div>' +
            '<div class="cep-sub" ng-if="g.preview.keepCar">Your current car will be parked in My cars.</div>' +
            '<div class="cep-sub" ng-if="!g.preview.keepCar && g.preview.tradeIn > 0">Trade-in credit · {{ fmt.money(g.preview.tradeIn) }}</div>' +
            '<div class="cep-sub" ng-if="!g.preview.ready && !g.preview.error">Checking the car…</div>' +
            '<div class="cep-sub" ng-if="g.preview.error">{{ g.preview.error }}</div>' +
          '</div>' +

          '<div class="cep-row"><button class="cep-sm ghost" ng-click="goHome()">‹ Back</button>' +
            '<input class="cep-input" placeholder="Find a car" aria-label="Find a car" ng-model="cf.text">' +
            '<button class="cep-sm" ng-click="loadCars()">Search</button></div>' +
          '<label class="cep-sub" ng-if="market.tradeIn > 0 && !g.preview"><input type="checkbox" ng-model="purchase.keep"> Keep my current car</label>' +
          '<div class="cep-sub" ng-if="market.tradeIn > 0 && !purchase.keep && !g.preview"><span ng-if="market.repair">Before repairs {{ fmt.money(market.tradeGross) }} · Repair bill {{ fmt.money(market.repair) }}<br></span>Trade-in credit · {{ fmt.money(market.tradeIn) }}</div>' +
          '<div class="cep-sub" ng-if="market.debt > 0" style="color:var(--tomato)">Pay your debt first ({{ fmt.money(market.debt) }}).</div>' +
          '<div class="cep-sub" ng-if="g.preview">Go back to your car to look at another one.</div>' +
          // filters: tap to pick (no typing needed); counts follow the other filters
          '<div class="cep-chips" role="group" aria-label="Vehicle type">' +
            '<button class="cep-chip" ng-class="{on: !cf.kind}" ng-click="cf.kind = null">All {{ carCount(null) }}</button>' +
            '<button class="cep-chip" ng-repeat="k in market.kinds track by k.id" ng-class="{on: cf.kind === k.id}" ' +
              'ng-click="cf.kind = (cf.kind === k.id ? null : k.id)">{{ k.name }} {{ carCount(k.id) }}</button></div>' +
          '<div class="cep-chips" role="group" aria-label="Price and order">' +
            '<button class="cep-chip" ng-class="{on: cf.afford}" ng-click="cf.afford = !cf.afford">I can afford</button>' +
            '<button class="cep-chip" ng-class="{on: cf.sort === \'price\'}" ng-click="cf.sort = \'price\'">Cheapest</button>' +
            '<button class="cep-chip" ng-class="{on: cf.sort === \'dear\'}" ng-click="cf.sort = \'dear\'">Dearest</button>' +
            '<button class="cep-chip" ng-class="{on: cf.sort === \'km\'}" ng-click="cf.sort = \'km\'">Fewest km</button>' +
            '<button class="cep-chip" ng-class="{on: cf.sort === \'cond\'}" ng-click="cf.sort = \'cond\'">Best condition</button></div>' +
          '<div class="cep-sub" ng-if="!cars.length">No vehicles are available for these categories.</div>' +
          '<div class="cep-sub" ng-if="cars.length && !shownCars().length">No car fits these filters. ' +
            '<button class="cep-chip" ng-click="cf.kind = null; cf.afford = false">Show all</button></div>' +
          '<div class="cep-market-card" ng-repeat="c in shownCars() track by c.id"><div style="flex:1;min-width:0">' +
            // the picture and numbers come from the game's vehicle list: nothing is spawned (Look at it does that)
            '<div class="cep-cartop"><button class="cep-thumb" ng-click="cf.detail = (cf.detail === c.id ? null : c.id)" ' +
              'aria-label="Show details" title="Show details"><i ng-if="c.info.preview" ng-style="carPic(c)"></i></button><div>' +
            '<div class="cep-name" style="white-space:normal">{{ c.name }} <span class="cep-adr" ng-if="c.isNew" style="background:var(--ok)">NEW</span></div>' +
            '<div class="cep-kind" ng-if="kindOf(c)"><b>{{ kindOf(c).name }}</b>' +
              '<button class="cep-q" ng-class="{on: cf.help === c.id}" ng-click="cf.help = (cf.help === c.id ? null : c.id)" ' +
                'aria-label="Jobs this vehicle can do" title="Jobs this vehicle can do">?</button>' +
              '<span>{{ kindOf(c).fits }}</span></div></div></div>' +
            '<div class="cep-jobs" ng-if="cf.help === c.id && kindOf(c)"><div class="cep-label">Jobs it can do</div>' +
              '<ul><li ng-repeat="j in kindOf(c).jobs">{{ j }}</li></ul>' +
              '<div class="cep-sub" ng-if="kindOf(c).locked">{{ kindOf(c).locked }}</div></div>' +
            '<small>{{ fmt.int(c.km) }} km · condition {{ fmt.cond(c.condition) }}' +
              '<span ng-if="c.missing !== undefined && c.missing !== null"> · {{ c.missing }} parts missing</span></small>' +
            '<div class="cep-sub cep-market-expiry">{{ c.held ? "Reserved during your test drive" : "Expires in " + carExpiry(c) + " of play" }}</div>' +
            '<div class="cep-time" style="height:4px;margin-top:5px" ng-class="{warn: c.condition < 0.6, late: c.condition < 0.35}"><i ng-style="{width: (c.condition * 100) + \'%\'}"></i></div></div>' +
            // while looking at a car, only that car can be bought (from the card above) and the deal is fixed
            '<div class="cep-market-actions" style="align-items:stretch" ng-if="!g.preview">' +
            '<button class="cep-sm" ng-class="{ghost: carPrice(c) > market.money}" ng-click="buyCar(c.id)">' +
              'Buy {{ fmt.money(carPrice(c)) }}</button>' +
            '<button class="cep-sm ghost" ng-click="look(c.id)">Look at it</button></div>' +
            '<button class="cep-sm ghost" style="flex:0 0 100%;min-height:26px;padding:4px" ng-if="cf.detail !== c.id" ' +
              'ng-click="cf.detail = c.id">Details ▾</button>' +
            '<div class="cep-cardetail" ng-if="cf.detail === c.id">' +
              '<div class="cep-thumb big" role="img" aria-label="{{ c.name }}"><i ng-if="c.info.preview" ng-style="carPic(c)"></i></div>' +
              '<div class="cep-specs"><div ng-repeat="r in carSpecs(c) track by r[0]"><span>{{ r[0] }}</span><b>{{ r[1] }}</b></div></div>' +
              '<div class="cep-sub" ng-if="!carSpecs(c).length">The game has no details for this car.</div>' +
              '<button class="cep-sm ghost" style="width:100%;margin-top:6px;min-height:26px;padding:4px" ng-click="cf.detail = null">Hide details ▴</button>' +
            '</div></div>' +
        '</div>' +
        '<div class="cep-actionbar" aria-label="Garage car actions" ng-if="g.started && gview === \'home\' && !g.preview && !g.parts">' +
          '<button class="cep-btn" ng-if="g.car && !g.own" ng-click="gdo(\'bring\')">Bring my car</button>' +
          '<div class="cep-row" ng-if="g.own"><button class="cep-btn" ng-if="!g.loaner" ng-click="gdo(\'openParts\')">Parts shop</button>' +
            '<button class="cep-btn go" ng-disabled="!(g.repair > 0)" ng-click="gdo(\'repair\')">{{ g.repair > 0 ? "Repair: " + fmt.money(g.repair) : "No damage" }}</button></div>' +
          '<div ng-if="g.breakdown">' +
            '<button class="cep-btn" style="margin-top:6px" ng-click="gdo(\'roadside\')">Call roadside help · {{ fmt.money(g.breakdown.cost) }}</button>' +
          '</div></div>' +
        '<div ng-if="g && g.started && g.preview && !g.parts" class="cep-actionbar" aria-label="Vehicle preview actions">' +
          '<button class="cep-btn go" ng-disabled="!g.preview.ready" ng-click="gdo(\'buyListing\', g.preview.id)">Buy {{ g.preview.name }}</button>' +
          '<div class="cep-row"><button class="cep-sm ghost" ng-if="gview === \'home\'" ng-click="openCars()">Other cars</button>' +
            '<button class="cep-sm ghost" ng-if="gview === \'cars\'" ng-click="goHome()">Details</button>' +
            '<button class="cep-sm ghost" ng-click="gdo(\'back\')">Back to my car</button></div></div>' +
      '</div>' +

      // settings
      '<div class="cep-body" ng-if="panel === \'settings\'">' +
        '<div class="cep-center" ng-if="st.reviewingParts">' +
          '<div class="cep-sub">Confirm or cancel your parts preview in Garage to change these settings.</div>' +
          '<button class="cep-btn go" ng-click="setTab(\'garage\')">Review parts</button></div>' +
        '<div class="cep-scroll" ng-if="!st.reviewingParts">' +
        '<div class="cep-card" ng-if="st.paused"><div class="cep-sub">Job settings, speed cameras and pausing come with your save. ' +
          'Load it on the phone to change them. Dark mode, the phone on the dashboard and the help below work now.</div></div>' +
        '<div ng-if="!st.paused">' +
        '<div class="cep-modes" ng-keydown="$event.keyCode === 27 && (modePicker.settings = false)"><span>Job type</span>' +
          '<button class="cep-mode-select" aria-label="Job type" aria-haspopup="menu" aria-expanded="{{ modePicker.settings && st.canSwitch }}" ' +
            'ng-disabled="!st.canSwitch" ng-click="modePicker.settings = !modePicker.settings">{{ workModeName(st.mode) }}<b aria-hidden="true">▾</b></button>' +
          '<div class="cep-mode-menu" role="menu" aria-label="Job types" ng-if="modePicker.settings && st.canSwitch">' +
            '<button ng-repeat="m in workModes" role="menuitemradio" aria-checked="{{ st.mode === m.id }}" ng-class="{on: st.mode === m.id}" ' +
              'ng-click="chooseWorkMode(\'settings\', m.id)">{{ m.name }}</button></div></div>' +
        '<div class="cep-sub" ng-if="!st.canSwitch">Finish the job or company shift to switch.</div>' +
        '<div class="cep-label">Orders</div>' +
        '<div class="cep-li" ng-repeat="it in st.items" style="cursor:default"><div class="cep-name">{{ it.label }}</div>' +
          '<div class="cep-step2"><button class="cep-sm ghost" ng-click="sdo(\'step\', it.key, -1)">−</button>' +
          '<b>{{ fmt.num(it.value) }} {{ it.unit }}</b><button class="cep-sm ghost" ng-click="sdo(\'step\', it.key, 1)">+</button></div></div>' +
        '<div class="cep-li" ng-if="st.mode === \'courier\'" ng-click="sdo(\'autoReach\', !st.autoReach)">' +
          '<div><div class="cep-name">Look further in the countryside</div><small>Search wider where restaurants are few</small></div>' +
          '<b>{{ st.autoReach ? "On" : "Off" }}</b></div>' +
        '<div class="cep-li" ng-if="st.cameras" ng-click="!st.cameras.paused && sdo(\'cameras\', !st.cameras.on)">' +
          '<div><div class="cep-name">Speed cameras</div><small>{{ st.cameras.paused ? "Temporarily paused: no downloads, fines or lost stars" : (!st.cameras.on ? "Off: no fines, no stars lost" : ' +
            '(st.cameras.helper === "off" ? "Needs the Cargo Earth helper running" : ' +
            '(st.cameras.helper === "loading" ? "Loading cameras around you…" : ' +
            '(st.cameras.helper === "failed" ? "Could not load cameras; trying again" : st.cameras.known + " real cameras around you (OpenStreetMap)")))) }}</small></div>' +
          '<b>{{ st.cameras.paused ? "Paused" : (st.cameras.on ? "On" : "Off") }}</b></div></div>' +
        '<div class="cep-label">Look</div>' +
        '<div class="cep-li" ng-click="sdo(\'dark\', !st.dark)">' +
          '<div><div class="cep-name">Dark mode</div><small>Dark phone and Menu, easier on the eyes at night and with HDR</small></div>' +
          '<b>{{ st.dark ? "On" : "Off" }}</b></div>' +
        '<div class="cep-label" ng-if="st.dash">VR</div>' +
        '<div class="cep-li" ng-if="st.dash" ng-click="sdo(\'dash\', st.dash.on ? \'off\' : \'on\')">' +
          '<div><div class="cep-name">Phone on the dashboard</div><small>{{ !st.dash.on ? "Puts this phone on the dash of any car. In VR, point a controller at it and pull the trigger." : ' +
            '(!st.dash.car ? "Sit in a car: the phone appears on its dash." : ' +
            '(st.dash.fitted ? ("On the dash" + (st.dash.running ? "" : " (its screen starts when the car is loaded)") + ". Point a controller at the screen and pull the trigger.") : "Putting it on this car’s dash…")) }}</small></div>' +
          '<b>{{ st.dash.on ? "On" : "Off" }}</b></div>' +
        '<div class="cep-sub" ng-if="st.dash.error">{{ st.dash.error }}</div>' +
        '<div class="cep-card" ng-if="st.dash.on && st.dash.car && st.dash.placed">' +
          '<div class="cep-sub">Position in this {{ st.dash.model }}. Each press is 1 cm; the car reloads when you stop.</div>' +
          '<button class="cep-sm" ng-if="!dash" ng-click="openMovePad()">Move it with a small pad</button>' +
          '<div class="cep-li" style="cursor:default"><div class="cep-name">Up / down</div><div class="cep-step2">' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'z-\')">Down</button><b>{{ st.dash.nudge.z }}</b>' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'z+\')">Up</button></div></div>' +
          '<div class="cep-li" style="cursor:default"><div class="cep-name">Closer / further</div><div class="cep-step2">' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'y-\')">Further</button><b>{{ st.dash.nudge.y }}</b>' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'y+\')">Closer</button></div></div>' +
          '<div class="cep-li" style="cursor:default"><div class="cep-name">Left / right</div><div class="cep-step2">' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'x+\')">Left</button><b>{{ -st.dash.nudge.x }}</b>' +
            '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'x-\')">Right</button></div></div>' +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm ghost" ng-if="st.dash.nudged" ng-click="sdo(\'dash\', \'reset\')">Back to where it started</button>' +
          '<button class="cep-sm ghost" ng-click="sdo(\'dash\', \'measure\')">Measure this car again</button></div></div>' +
        '<button class="cep-sm ghost" ng-if="!st.paused" ng-click="sdo(\'reset\')">Reset settings</button>' +
        '<button class="cep-sm ghost" ng-if="st.canPause" ng-disabled="st.savingDamage" ng-click="sdo(\'pause\')">{{ st.savingDamage ? "Saving vehicle damage..." : "Save and switch career" }}</button>' +
        '<button class="cep-sm ghost" ng-if="st.canRestart && !restart.open" ng-click="restartOpen()">Delete this career</button>' +
        '<div class="cep-card" ng-if="st.canRestart && restart.open">' +
          '<div class="cep-name">Delete this career</div>' +
          '<div class="cep-sub">This deletes your whole career: money, cars, home, firm, reputation and progress. ' +
            'It cannot be undone. Your settings and other careers stay.</div>' +
          '<div class="cep-sub" style="margin-top:6px">Type {{ st.restartWord }} to confirm.</div>' +
          '<div class="cep-row" style="margin-top:6px"><input class="cep-input" type="text" maxlength="12" autocomplete="off" spellcheck="false" ' +
            'aria-label="Type {{ st.restartWord }} to confirm" placeholder="{{ st.restartWord }}" ng-model="restart.word"></div>' +
          '<div class="cep-sub" ng-if="restart.error">{{ restart.error }}</div>' +
          '<div class="cep-row"><button class="cep-sm go" ng-disabled="restart.word !== st.restartWord" ng-click="restartGo()">Delete career</button>' +
          '<button class="cep-sm ghost" ng-click="restartClose()">Cancel</button></div></div>' +
        '<div class="cep-label">Help</div>' +
        '<div class="cep-li" style="padding:6px 10px"><div><div class="cep-name" style="font-size:12px">Updates</div>' +
          '<small ng-if="st.update.unknown">Mod {{ st.update.mod }}. Start the Cargo Earth helper to check for updates.</small>' +
          '<small ng-if="!st.update.unknown">Mod {{ st.update.mod }}, helper {{ st.update.helper }}. ' +
            '{{ st.update.available ? "Newest: " + st.update.latest : "Up to date" }}</small></div>' +
          '<button class="cep-sm" ng-if="st.update.available" ng-click="updateDo(\'open\')">Get {{ st.update.latest }}</button></div>' +
        '<div class="cep-row"><button class="cep-sm ghost" ng-disabled="report.busy" ng-click="copyReport()">{{ report.busy ? "Making the report…" : "Copy support report" }}</button>' +
        '<button class="cep-sm ghost" ng-if="!st.paused" ng-click="sdo(\'window\')">{{ st.window ? "Close" : "Open" }} debug window</button></div>' +
        '<div class="cep-card" ng-if="report && !report.busy">' +
          '<div class="cep-sub">{{ report.copied ? "Copied. Paste it into Discord or a GitHub issue." : "Could not copy it. Select the text below and copy it." }} ' +
            'It has versions, the helper\'s state and recent errors; your position only to about 10 km.</div>' +
          '<textarea class="cep-report" readonly rows="8" ng-model="report.text" onclick="this.select()"></textarea>' +
          '<button class="cep-sm ghost" ng-click="closeReport()">Close</button></div>' +
      '</div></div>' +
      '</div></div></div>' +
      '<div class="cep-pill" ng-if="ready && min && !menuOnly" ng-click="fold(false)"><span>Cargo<b>Earth</b><span ng-if="radio.status === \'playing\'" style="font-weight:500"> ♪ {{ radio.station.name | limitTo: 18 }}</span></span>' +
        '<span><span class="cep-limit" ng-if="s.limit" ng-class="{over: s.limit.over}">{{ s.limit.sign }}</span>' +
        '{{ s.online ? "● online" : "" }} {{ fmt.money(s.money) }} ▴</span></div>' +
      '<div class="cep" ng-class="{dark: dark}" ng-if="ready && !min && !menuOnly"><div class="cep-screen">' +
      // one slim status row for everything around the content: clock and the job's settings on the left,
      // the speed limit, the balance and online on the right (the tabs at the bottom say whether this is Work or Radio)
      '<div class="cep-bar"><span class="cep-bar-l">{{ s.clock }}' +
        '<button class="cep-settings-link" title="{{ s.mode === \'courier\' ? \'Food delivery\' : \'Freight\' }} settings" ' +
          'aria-label="Job settings" ng-click="setTab(\'settings\')">⚙</button></span>' +
        '<span class="cep-bar-r"><span class="cep-limit" ng-if="s.limit" ng-class="{over: s.limit.over}" title="Speed limit here">{{ s.limit.sign }}' +
          '<small ng-if="s.limit.unit === \'mph\'">mph</small></span>' +
        '<strong class="cep-bal">{{ fmt.money(s.money) }}</strong>' +
        '<i class="cep-on" ng-if="s.online" title="Online"></i>' +
        '<button class="cep-min" title="Fold the phone" ng-if="!dash" ng-click="fold(true)">–</button></span></div>' +
      '<button class="cep-live" ng-if="showLiveShortcut()" ng-click="openLiveWork()">' +
        '<i class="cep-dot-live"></i><span><strong>{{ liveTitle() }}</strong><small>{{ liveDetail() }}</small></span><b aria-hidden="true">&rsaquo;</b></button>' +

      // error / not ready
      '<div class="cep-body" ng-if="tab === \'orders\' && (!s || s.screen === \'error\')"><div class="cep-center">' +
        '<div class="cep-big">Not available</div><div class="cep-sub">{{ s ? s.error : "Cargo Earth is not loaded." }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
      '</div></div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'resume\'"><div class="cep-scroll">' +
        '<div class="cep-card"><div class="cep-label">{{ s.saveName || "Your career" }}</div>' +
        '<div class="cep-sub">{{ s.savedCar ? "Back to your " + s.savedCar + ", where you left off." : "Continue where you left off." }}</div>' +
        '<div class="cep-sub" ng-if="!s.resumeHasLocation">This save has no location, so you continue from here.</div>' +
        '<div class="cep-sub" ng-if="!s.resumeLoading && s.status !== \'ok\'">{{ s.status }}</div>' +
        '<div class="cep-sub" ng-if="s.resumeError">{{ s.resumeError }}</div></div>' +
        SAVES_HTML +
        '<div class="cep-card"><div class="cep-label">New career</div>' +
          '<div class="cep-sub">An old {{ s.choice.starter || "car" }} and a fresh start. Your other careers stay.</div>' + NEW_CAREER_HTML +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm go" ng-disabled="s.savesFull" ng-click="newCareer()">Start new career</button></div></div></div>' +
        '<div class="cep-actionbar" aria-label="Resume options">' +
          '<button class="cep-btn go" ng-disabled="s.resumeLoading || s.status !== \'ok\' || s.resumeBlocked" ng-click="act(\'resume\')">' +
          '{{ s.resumeLoading ? "Loading saved location…" : "Load " + (s.saveName || "latest save") }}</button>' +
          '<button class="cep-btn ghost" ng-click="act(\'freePlay\')">Just drive</button></div></div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'parts\'"><div class="cep-center">' +
        '<div class="cep-big">Parts preview open</div><div class="cep-sub">Confirm or drop your parts changes to take orders again.</div></div>' +
        '<button class="cep-btn go" ng-click="setTab(\'garage\')">Review parts</button></div>' +

      // first run: free play (nothing kept) or the career with progress
      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'choose\'"><div class="cep-scroll">' +
        '<div class="cep-card"><div class="cep-label">Career</div>' +
          '<div class="cep-name" style="white-space:normal">An old {{ s.choice.starter || "car" }} and {{ fmt.money(s.choice.startMoney) }}</div>' +
          '<ul class="cep-perks"><li>Repair and upgrade your car</li><li>Buy used cars and a home garage</li>' +
            '<li>Ranks unlock vans, trucks and semis</li><li>Found a firm and hire drivers</li></ul>' +
          '<div class="cep-sub">Progress is saved. Orders come only in your own car.</div>' +
          '<div class="cep-sub" ng-if="s.choice.busy" style="color:var(--tomato)">Your current order will be cancelled (no fee).</div>' +
        '</div>' +
        '<div class="cep-card"><div class="cep-label">Free play</div>' +
          '<div class="cep-sub">Orders in any car, just for fun. Nothing carries over.</div>' +
        '</div>' +
        '<div class="cep-card"><div class="cep-label">Name your career</div>' + NEW_CAREER_HTML + '</div>' +
        SAVES_HTML + '</div>' +
        '<div class="cep-actionbar" aria-label="Start options"><button class="cep-btn go" ng-disabled="s.savesFull" ng-click="newCareer()">Start my career</button>' +
          '<button class="cep-btn ghost" ng-click="act(\'freePlay\')">Just drive</button></div></div>' +

      // offline: the job type can be switched here too (Settings has the same switch)
      '<div class="cep-body" ng-class="{\'cep-work-board\': s.trucking || s.bus}" ng-if="tab === \'orders\' && s.screen === \'offline\'">' +
      '<div class="cep-card cep-helperstart" ng-if="s.helperStart"><b>The Cargo Earth helper is not running</b>' +
        '<div class="cep-sub">{{ s.helperStart.installed ? "Start it in BeamNG.Earth. It will start with BeamNG.Earth from now on." : "BeamNG.Earth installs and starts the helper by " + s.helperStart.author + " beside the game. It finds places, addresses and radio near you, and starts with BeamNG.Earth from now on." }}</div>' +
        '<div class="cep-sub" ng-if="s.helperStart.error">Could not start it: {{ s.helperStart.error }}</div>' +
        '<button class="cep-btn ok" ng-disabled="s.helperStart.busy" ng-click="act(\'helperStart\')">{{ s.helperStart.busy ? "Starting…" : (s.helperStart.installed ? "Start helper" : "Install and start") }}</button>' +
        '<button class="cep-sm ghost" ng-click="act(\'helperHide\')">Not now</button></div>' +
      '<div class="cep-modes" ng-keydown="$event.keyCode === 27 && (modePicker.work = false)"><span>Job type</span>' +
        '<button class="cep-mode-select" aria-label="Job type" aria-haspopup="menu" aria-expanded="{{ modePicker.work && s.canSwitch }}" ' +
          'ng-disabled="!s.canSwitch" ng-click="modePicker.work = !modePicker.work">{{ workModeName(s.mode) }}<b aria-hidden="true">▾</b></button>' +
        '<div class="cep-mode-menu" role="menu" aria-label="Job types" ng-if="modePicker.work && s.canSwitch">' +
          '<button ng-repeat="m in workModes" role="menuitemradio" aria-checked="{{ s.mode === m.id }}" ng-class="{on: s.mode === m.id}" ' +
            'ng-click="chooseWorkMode(\'work\', m.id)">{{ m.name }}</button></div></div>' +
      // city bus lines: the lines near you (the bus is lent at a depot near the first stop), or the shift you are on
      '<div class="cep-scroll" ng-if="s.bus">' +
        '<div class="cep-card" ng-if="s.bus.shift"><div class="cep-label">{{ s.bus.shift.name }}</div>' +
          '<div class="cep-big" style="font-size:15px" ng-if="s.bus.shift.handover">Taking you back to {{ s.bus.shift.depot }}</div>' +
          '<div class="cep-sub" ng-if="s.bus.shift.handover">The bus is handed over. Your car is waiting at the depot.</div>' +
          '<div class="cep-big" style="font-size:15px" ng-if="!s.bus.shift.handover">Your bus is getting ready</div>' +
          '<div class="cep-sub" ng-if="s.bus.shift.error" style="color:var(--tomato)">{{ s.bus.shift.error }}</div>' +
        '</div>' +
        '<div class="cep-label" ng-if="!s.bus.shift">Bus lines nearby</div>' +
        '<div class="cep-card" ng-if="s.bus.selected"><strong>{{ s.bus.selected.name }}</strong>' +
          '<div class="cep-sub">Park inside the marker at {{ s.bus.selected.depot }} for {{ s.bus.selected.leftS }} s. Your car will be stored, then replaced by the bus.</div>' +
          '<div class="cep-sub" ng-if="s.bus.selected.error" style="color:var(--tomato)">{{ s.bus.selected.error }}</div>' +
        '</div>' +
        '<div class="cep-sub" role="status" ng-if="!s.bus.shift">{{ busStatus(s.bus) }}</div>' +
        '<div class="cep-sub" ng-if="!s.bus.shift && s.bus.progress">{{ s.bus.progress.ready }} of {{ s.bus.progress.total }} areas checked' +
          '<span ng-if="s.bus.progress.queued"> · {{ s.bus.progress.queued }} queued</span>' +
          '<span ng-if="s.bus.progress.failed"> · {{ s.bus.progress.failed }} failed</span>' +
          '<span ng-if="s.bus.progress.loading"> · {{ s.bus.progress.elapsed }} s elapsed</span>' +
          '<span ng-if="s.bus.progress.server && s.bus.progress.loading"> · {{ s.bus.progress.server }} (server {{ s.bus.progress.attempt }})</span>' +
          '<span ng-if="s.bus.progress.failed && s.bus.progress.retryAfter"> · automatic retry in {{ s.bus.progress.retryAfter }} s</span></div>' +
        '<div class="cep-sub" ng-if="!s.bus.shift && s.bus.error" style="color:var(--tomato);overflow-wrap:anywhere">{{ s.bus.error }}</div>' +
        '<div class="cep-sub" ng-if="s.bus.message" style="color:var(--tomato)">{{ s.bus.message }}</div>' +
        '<div class="cep-card" ng-repeat="l in s.bus.lines track by l.id">' +
          '<div class="cep-keyval"><strong style="white-space:normal"><span class="cep-busref" ng-style="l.colour ? {background: l.colour} : {}">{{ l.ref || "Bus" }}</span> to {{ l.to }}</strong>' +
            '<strong style="white-space:nowrap">{{ fmt.money(l.pay) }}</strong></div>' +
          '<div class="cep-sub">From {{ l.from }} · {{ l.stops }} stops · {{ fmt.km(l.km) }} · about {{ l.minutes }} min<span ng-if="l.fares"> · plus about {{ fmt.money(l.fares) }} in fares</span></div>' +
          '<div class="cep-sub" ng-if="l.singleDirection">Only this direction found in local map data.</div>' +
          '<div class="cep-sub" ng-if="l.limited">This shift serves the first {{ l.stops }} mapped stops.</div>' +
          '<div class="cep-sub">Bus at {{ l.depot }}<span ng-if="l.depotM !== undefined"> · {{ fmt.dist(l.depotM).v }}{{ fmt.dist(l.depotM).u }} away</span></div>' +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm ghost" ng-click="act(\'busGps\', l.id)">Route</button>' +
            '<button class="cep-sm go" ng-click="act(\'busStart\', l.id)">Choose line</button></div></div>' +
        '<div class="cep-sub" ng-if="!s.bus.shift && s.bus.lines.length">Choose a line, then park your own car in its depot marker to collect the bus.</div>' +
      '</div>' +
      '<div class="cep-center" ng-if="!s.bus" ng-class="{\'cep-freight-summary\': s.trucking}">' +
        '<div class="cep-big">{{ s.trucking && !s.trucking.carrier ? "No work vehicle of your own" : "You are offline" }}</div>' +
        '<div class="cep-sub" ng-if="!s.taxi && (!s.trucking || !s.trucking.hint)">Go online to get orders from nearby {{ s.mode === "courier" ? "restaurants and shops" : "depots" }}.</div>' +
        '<div class="cep-sub" ng-if="s.taxi">{{ s.taxi.hint }}</div>' +
        '<div class="cep-sub" role="status" ng-if="s.taxi.eligible">{{ s.taxi.search }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.carrier">{{ s.trucking.label }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.hint">{{ s.trucking.hint }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
      '</div>' +
      // freight without a van or truck of your own (or in a car or an SUV, beside its own small work): the nearest
      // company contracts, the vehicle comes at the yard
      '<div class="cep-scroll cep-contracts" aria-label="Nearby freight contracts" ng-if="s.trucking && (!s.trucking.carrier || (s.trucking.contracts && s.trucking.contracts.length))">' +
        '<div class="cep-label">Contracts nearby</div>' +
        '<div class="cep-sub" ng-if="!s.trucking.contracts.length">Looking for workplaces nearby…</div>' +
        '<div class="cep-card" ng-repeat="c in s.trucking.contracts track by c.id">' +
          '<div class="cep-keyval"><strong style="white-space:normal">{{ c.name }}</strong><strong style="white-space:nowrap">{{ fmt.money(c.wages) }}</strong></div>' +
          '<div class="cep-sub">{{ c.vehicle }} · yard {{ fmt.km(c.km) }} away · 2 deliveries · about {{ c.minutes }} min</div>' +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm ghost" ng-click="act(\'contractGps\', c.id)">Route</button>' +
            '<button class="cep-sm go" ng-disabled="!c.atYard" ng-click="act(\'contractStart\', c.id)">Start</button></div></div>' +
      '</div>' +
      '<button class="cep-sm ghost" ng-if="s.bus.shift && !s.bus.shift.handover" ng-click="act(\'busEnd\')">End shift</button>' +
      '<div class="cep-row" ng-if="s.bus && !s.bus.shift"><button class="cep-sm ghost" ng-disabled="s.bus.state === \'loading\'" ng-click="act(\'busRetry\')">Retry bus search</button>' +
        '<button class="cep-sm ghost" ng-if="s.bus.selected" ng-click="act(\'busCancelSelection\')">Cancel selection</button></div>' +
      '<button class="cep-sm ghost" ng-if="s.trucking" ng-click="setTab(\'companies\')">All contracts</button>' +
      '<div class="cep-card cep-stats" ng-if="!s.bus && !s.trucking"><div>{{ s.todayCount }}<span>orders today</span></div>' +
        '<div>{{ fmt.short(s.todayEarned) }}<span>earned today</span></div></div>' +
      '<button class="cep-btn go" ng-if="!s.bus && (!s.trucking || s.trucking.carrier)" ng-disabled="s.taxi && !s.taxi.eligible" ng-click="act(\'online\')">Go online</button>' +
      '<button class="cep-sm ghost" ng-if="s.freePlay" style="margin-top:6px" ng-click="act(\'careerInfo\')">Free play · Start a career</button></div>' +

      // waiting
      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'waiting\'">' +
      '<div class="cep-card cep-helperstart" ng-if="s.helperStart"><b>The Cargo Earth helper is not running</b>' +
        '<div class="cep-sub">{{ s.helperStart.installed ? "Start it in BeamNG.Earth. It will start with BeamNG.Earth from now on." : "BeamNG.Earth installs and starts the helper by " + s.helperStart.author + " beside the game. It finds places, addresses and radio near you, and starts with BeamNG.Earth from now on." }}</div>' +
        '<div class="cep-sub" ng-if="s.helperStart.error">Could not start it: {{ s.helperStart.error }}</div>' +
        '<button class="cep-btn ok" ng-disabled="s.helperStart.busy" ng-click="act(\'helperStart\')">{{ s.helperStart.busy ? "Starting…" : (s.helperStart.installed ? "Start helper" : "Install and start") }}</button>' +
        '<button class="cep-sm ghost" ng-click="act(\'helperHide\')">Not now</button></div>' +
      '<button class="cep-btn ghost" ng-click="act(\'offline\')">Go offline</button><div class="cep-center">' +
        '<div class="cep-pulse"><i></i></div><div class="cep-big">Looking for orders</div>' +
        '<div class="cep-sub" ng-if="s.trucking">{{ s.trucking.hint || ("Looking for " + s.trucking.carrier + " freight near you.") }}</div>' +
        '<div class="cep-sub" ng-if="s.taxi">{{ s.taxi.hint }}</div>' +
        '<div class="cep-sub" role="status" ng-if="s.taxi.eligible">{{ s.taxi.search }}</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && !s.taxi && (!s.helper || s.helper.state === \'ready\')">The next order will ring here.</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && !s.taxi && s.helper && !s.helper.outdated && (s.helper.state === \'loading\' || s.helper.state === \'searching\')">' +
          '{{ s.helper.restaurants ? "Loading nearby pickup locations…" : "Loading nearby grocery stores…" }}</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && !s.taxi && s.helper && s.helper.state === \'off\'">' +
          '{{ s.helper.restaurants ? "Start the Cargo Earth helper to load nearby pickup locations." : "Start the Cargo Earth helper to get local grocery runs." }}' +
          '<span ng-if="s.helper.msg"> ({{ s.helper.msg }})</span></div>' +
        // the helper answers, but could not build this area (no Python libraries, no internet...): not "start it"
        '<div class="cep-sub" ng-if="!s.trucking && !s.taxi && s.helper && s.helper.state === \'error\'">' +
          'The helper could not load this area{{ s.helper.msg ? ": " + s.helper.msg : "." }} ' +
          'A support report (Menu → Settings) helps us find out why.</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && !s.taxi && s.helper.outdated && (s.helper.state === \'ready\' || s.helper.state === \'loading\')">' +
          'Update the Cargo Earth helper for grocery runs.</div></div>' +
      '<div class="cep-card cep-stats"><div>{{ s.todayCount }}<span>orders today</span></div>' +
        '<div>{{ fmt.short(s.todayEarned) }}<span>earned today</span></div></div>' +
      '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
      '</div>' +

      // incoming
      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'incoming\'">' +
        '<div class="cep-order-head">' +
          '<div><div class="cep-label">{{ s.incoming.orderType === "grocery" ? "Grocery run" : (s.incoming.orderType === "family" ? "Family meal" : ' +
            '(s.incoming.batch ? "Add to your route" : (s.incoming.kind === "food" ? "New food order" : (s.incoming.tow ? "Tow job" : (s.incoming.taxi ? "Taxi ride · " + (s.incoming.taxi.modeName || "Comfort") : "New freight job"))))) }}</div>' +
          '<div class="cep-pay">{{ fmt.money(s.incoming.pay) }}</div>' +
          '<div class="cep-sub">{{ s.incoming.kind === "food" ? "before tip" : "" }}' +
            '<span class="cep-adr" ng-if="s.incoming.adr">ADR</span>' +
            '<span class="cep-premium" ng-if="s.incoming.premium">PREMIUM</span>' +
            '<span class="cep-special {{ s.incoming.special.kind }}" ng-if="s.incoming.special">{{ s.incoming.special.name }}</span></div></div>' +
          '<div class="cep-ring"><svg width="64" height="64"><circle cx="32" cy="32" r="28" fill="none" stroke="#e8e0d7" stroke-width="6"/>' +
            '<circle cx="32" cy="32" r="28" fill="none" stroke="#e8452c" stroke-width="6" stroke-linecap="round" ' +
            'ng-attr-stroke-dasharray="{{ 175.9 * s.incoming.leftS / s.incoming.totalS }} 176"/></svg><b>{{ s.incoming.leftS }}</b></div>' +
        '</div>' +
        '<div class="cep-scroll cep-order-scroll">' +
          '<div class="cep-card cep-route"><div class="cep-stop">' +
            '<span class="cep-dot"></span><div><div class="cep-label">Pickup</div><div class="cep-name">{{ s.incoming.from.name }}</div>' +
              '<div class="cep-sub">{{ fmt.km(s.incoming.taxi.pickupRoadKm || s.incoming.pickupKm) }} away<span ng-if="s.incoming.taxi.pickupRoadKm !== undefined">{{ s.incoming.taxi.pickupEstimated ? " est. by road" : " by road" }}</span>' +
                '<span ng-if="s.incoming.from.town"> · {{ s.incoming.from.town }}</span></div></div>' +
            '<span><span class="cep-line"></span></span><span></span>' +
            '<span class="cep-dot to"></span><div><div class="cep-label">{{ s.incoming.route ? s.incoming.route.count + " drop-offs, nearest first" : "Drop-off" }}</div>' +
              '<div class="cep-name">{{ s.incoming.route ? s.incoming.route.stops[0].name + " and " + (s.incoming.route.count - 1) + " more" : s.incoming.to.name }}</div>' +
              '<div class="cep-meta">{{ s.incoming.route ? s.incoming.route.left + " parcels in your containers" : (s.incoming.to.town || s.incoming.to.label) }}</div></div>' +
          '</div></div>' +
          '<div class="cep-card" ng-if="s.incoming.items.length"><div class="cep-label">{{ s.incoming.orderType === "grocery" ? s.incoming.cargo : "In this order" }}' +
            '<span ng-if="s.incoming.slots"> · {{ s.incoming.slots }} slot{{ s.incoming.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.incoming.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-sub" ng-if="!s.incoming.items.length">{{ s.incoming.cargo }}{{ s.incoming.trailer ? " · " + s.incoming.trailer : "" }}</div>' +
          '<div class="cep-sub" ng-if="s.incoming.freight">{{ fmt.freight(s.incoming.freight) }}</div>' +
          '<div class="cep-sub">{{ fmt.km(s.incoming.km) }} trip · {{ s.incoming.minutes }} min to deliver' +
            '<span ng-if="s.incoming.farPickup > 0 && !s.incoming.batch"> · +{{ fmt.money(s.incoming.farPickup) }} for the far pickup</span></div>' +
          '<div class="cep-sub" ng-if="s.incoming.sizeBonus">+{{ fmt.money(s.incoming.sizeBonus) }} for the larger load</div>' +
          '<div class="cep-sub" ng-if="s.incoming.premium">Premium customer: pays more, wants it sooner.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.taxi">{{ s.incoming.taxi.people > 1 ? s.incoming.taxi.people + " passengers ride" : "One passenger rides" }} with you. {{ s.incoming.taxi.mode === "rush" ? "Rush: in a hurry, only speed counts. Arriving early pays a big tip, late minutes cost more." : "Comfort: no hurry, a smooth ride pays a big tip and bumps cost a lot." }}</div>' +
          '<div class="cep-card" aria-label="Taxi fare breakdown" ng-if="s.incoming.taxi.fare">' +
            '<div class="cep-label">Fare breakdown</div>' +
            '<div class="cep-keyval"><span>Base + trip distance</span><strong>{{ fmt.money(s.incoming.taxi.fare.baseFare) }}</strong></div>' +
            '<div class="cep-sub">{{ fmt.money(s.incoming.taxi.fare.base) }} base + {{ fmt.money(s.incoming.taxi.fare.perKm) }}/km</div>' +
            '<div class="cep-keyval" ng-if="s.incoming.taxi.fare.passengerRate > 0"><span>Extra passengers +{{ fmt.pct(s.incoming.taxi.fare.passengerRate) }}</span>' +
              '<strong>+{{ fmt.money(s.incoming.taxi.fare.passengerBonus) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="s.incoming.taxi.fare.modeRate > 0"><span>Rush +{{ fmt.pct(s.incoming.taxi.fare.modeRate) }}</span>' +
              '<strong>+{{ fmt.money(s.incoming.taxi.fare.modeBonus) }}</strong></div>' +
            '<div class="cep-sub">Fuel and reputation adjustments are included in the offer above. Time allowance includes the pickup drive.</div></div>' +
          '<div class="cep-sub" ng-if="s.incoming.tow && s.incoming.tow.wreck"><b>{{ s.incoming.tow.wreck }}</b></div>' +
          '<div class="cep-sub cep-warn" ng-if="s.incoming.tow && s.incoming.tow.weak">Your car may struggle: little power for this load.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.tow">{{ s.incoming.tow.cars > 1 ? s.incoming.tow.cars + " cars go" : "The car goes" }} ' +
            'on {{ s.incoming.tow.borrow ? "a borrowed" : "your" }} {{ s.incoming.tow.trailer.toLowerCase() }}, not strapped down. Drive gently: damage costs pay.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.tow && s.incoming.tow.borrow">You first pick the trailer up at the workshop. ' +
            'With your own (your firm buys one at its headquarters, then Take it out there) you skip that.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.trailerBonus">+{{ fmt.money(s.incoming.trailerBonus) }} for your firm\'s trailer</div>' +
          '<div class="cep-sub" ng-if="s.incoming.resupplyBonus">+{{ fmt.money(s.incoming.resupplyBonus) }} from the station for {{ s.incoming.litres }} L</div>' +
          '<div class="cep-sub" ng-if="s.incoming.special"><b>{{ s.incoming.special.name }}:</b> +{{ fmt.money(s.incoming.special.bonus) }}. ' +
            '{{ s.incoming.special.note }}</div>' +
          '<div class="cep-sub" ng-if="s.incoming.fuelAllowance">+{{ fmt.money(s.incoming.fuelAllowance) }} toward your fuel</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay > 1">+{{ fmt.pct(s.incoming.reputationPay - 1) }} for your reputation</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay < 1">−{{ fmt.pct(1 - s.incoming.reputationPay) }} for your reputation</div>' +
          '<div class="cep-sub" ng-if="s.incoming.handling">{{ s.incoming.handling }} cargo<span ng-if="s.incoming.handling === \'Fragile\'"> · avoid hard jolts</span></div>' +
          '<div class="cep-sub" ng-if="s.incoming.batch">Adds a stop to your {{ s.incoming.openOrders }} open order{{ s.incoming.openOrders > 1 ? "s" : "" }}. ' +
            'Their timers keep running.</div>' +
          '<div class="cep-meta" ng-if="s.incoming.orderType === \'grocery\'">Pickup data © Overture Maps Foundation</div>' +
        '</div>' +
        '<div class="cep-row"><button class="cep-btn ghost" ng-click="act(\'decline\')">Decline</button>' +
          '<button class="cep-btn go" ng-click="act(\'accept\')">{{ s.incoming.batch ? "Add order" : "Accept" }}</button></div>' +
      '</div>' +

      // active
      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'active\'">' +
        '<div class="cep-scroll cep-order-scroll">' +
          '<div class="cep-card cep-next-card">' +
            '<div class="cep-keyval"><span class="cep-step" ng-class="{to: s.active.phase === \'toDelivery\'}">' +
              '{{ s.bus.line ? "Bus stop" : (s.active.here ? "Trailer" : (s.active.phase === "toPickup" ? (s.active.kind === "food" ? "Pick up" : (s.active.tow ? "Load the car" : (s.active.taxi ? "Pick up" : "Load freight"))) : "Drop off")) }}</span>' +
              '<strong>{{ fmt.money(s.active.pay) }}</strong></div>' +
            '<div><div class="cep-name">{{ here().name }}</div>' +
              '<div class="cep-meta">{{ here().label }}{{ here().town ? " · " + here().town : "" }}</div>' +
              '<div class="cep-sub" ng-if="s.active.taxi">{{ s.active.taxi.people }} passenger{{ s.active.taxi.people === 1 ? "" : "s" }} · {{ s.active.taxi.mode === "rush" ? "Rush: only speed counts" : "Comfort: drive smoothly" }}</div>' +
              '<div class="cep-sub" role="status" ng-if="s.active.taxi && s.active.phase === \'toPickup\' && (!s.taxi.eligible || s.taxi.seats < s.active.taxi.people)">' +
                '{{ !s.taxi.eligible ? s.taxi.hint : "Not enough passenger seats for this group." }}</div>' +
              '<div class="cep-sub" role="status" ng-if="s.active.taxi.boardingError">Passengers could not be seated. Stay at the pickup to retry.</div></div>' +
            '<div class="cep-drive">' +
              '<div class="cep-dist">{{ fmt.dist(s.active.distM).v }}<small>{{ fmt.dist(s.active.distM).u }}</small></div>' +
              '<div class="cep-sub" ng-if="!s.active.stop.inZone">{{ s.active.distRoad ? "by road" : ' +
                '(s.active.kind === "food" && s.active.phase === "toPickup" ? "to the roadside ring" : "straight line") }}' +
                '{{ s.active.etaS && s.active.distRoad ? " · about " + fmt.mins(s.active.etaS) : "" }}</div>' +
              '<div ng-if="s.active.stop.inZone"><strong class="cep-sub">{{ s.active.stop.bus ? ' +
                '(s.active.stop.title + (s.active.stop.stopping ? ": " + s.active.stop.leftS + " s" : "")) : (s.active.stop.stopping ? ' +
                '(s.active.phase === "toPickup" ? "Collecting… " : "Handing over… ") + s.active.stop.leftS.toFixed(1).replace(".", ",") + " s" : ' +
                '"Park here for " + s.active.stop.stopS + " seconds") }}</strong>' +
                '<div class="cep-hold" ng-if="!s.active.stop.bus || s.active.stop.stopping"><i ng-style="{width: (s.active.stop.frac * 100) + \'%\'}"></i></div></div>' +
            '</div>' +
            '<div><div class="cep-keyval cep-sub" ng-if="s.active.pickupLeftS !== undefined && s.active.pickupLeftS !== null">' +
              '<span>{{ s.active.pickupLeftS >= 0 ? "Pick up in" : "Pickup late by" }}</span>' +
              '<strong class="cep-stop-time" ng-class="{late: s.active.pickupLeftS < 0}">{{ fmt.remaining(s.active.pickupLeftS) }}</strong></div>' +
              '<div class="cep-keyval cep-sub"><span>{{ s.active.kind === "bus" ? (s.active.leftS >= 0 ? "Stop due in" : "Behind by") : s.active.leftS >= 0 ? (s.active.kind === "food" ? "Deliver in" : "Time left") : "Overdue by" }}</span>' +
              '<strong class="cep-stop-time" ng-class="{late: s.active.leftS < 0}">{{ fmt.remaining(s.active.leftS) }}</strong></div>' +
              '<div class="cep-time" ng-class="{warn: s.active.leftS < 120 && s.active.leftS >= 0, late: s.active.leftS < 0}">' +
              '<i ng-style="{width: timePct() + \'%\'}"></i></div></div>' +
          '</div>' +
          '<div class="cep-keyval cep-sub" ng-if="s.active.special"><span><span class="cep-special {{ s.active.special.kind }}" style="margin-left:0">' +
            '{{ s.active.special.name }}</span> {{ s.active.special.note }}</span>' +
            '<strong ng-if="s.active.special.penalty" style="color:var(--tomato)">−{{ s.active.special.penalty }}% pay</strong></div>' +
          '<div class="cep-keyval cep-sub" ng-if="s.active.handling"><span>{{ s.active.handling }} cargo</span>' +
            '<strong ng-if="s.active.phase === \'toDelivery\'" ng-style="{color: s.active.cargoCondition < 100 ? \'var(--tomato)\' : \'var(--ok)\'}">' +
              '{{ s.active.cargoCondition }}% intact</strong></div>' +
          '<div class="cep-keyval cep-sub" ng-if="s.active.loadKg > 0"><span>On board</span><strong>{{ fmt.kg(s.active.loadKg) }}</strong></div>' +
          '<div class="cep-receipt-note" ng-if="s.dropped">Dropped {{ fmt.kg(s.dropped.kg) }}' +
            '<span ng-if="s.dropped.left > 0"> · {{ fmt.kg(s.dropped.left) }} still on board</span></div>' +
          '<div class="cep-impact-note" ng-if="s.failure">{{ s.failure.count }} order{{ s.failure.count > 1 ? "s" : "" }} ruined' +
            '<span ng-if="s.failure.g"> · {{ fmt.num(s.failure.g) }} g impact</span></div>' +
          '<div class="cep-batch-list" ng-if="s.active.count > 1">' +
            '<div class="cep-label">Other stops · {{ s.active.carrying }} on board</div>' +
            '<div class="cep-li cep-order-line" ng-repeat="o in s.active.orders | filter:{current:false}:true track by o.id">' +
              '<div><small>{{ o.pickup ? "Awaiting pickup" : "On board" }}</small>' +
                '<div class="cep-name">{{ o.name }}</div><small>{{ o.cargo }} · ' +
                  '<span ng-if="o.pickupLeftS !== undefined && o.pickupLeftS !== null">pick up ' +
                    '<span class="cep-stop-time" ng-class="{late: o.pickupLeftS < 0}">{{ fmt.clock(o.pickupLeftS) }}</span> · deliver </span>' +
                  '<span class="cep-stop-time" ng-class="{late: o.leftS < 0}">{{ fmt.clock(o.leftS) }}</span>' +
                  '<span ng-if="!o.pickup && o.cargoCondition < 100"> · {{ o.cargoCondition }}% intact</span></small></div>' +
              '<button class="cep-sm ghost" ng-if="o.selectable" ng-click="act(\'selectDelivery\', o.id)">Deliver next</button></div>' +
          '</div>' +
          '<div class="cep-receipt-note" ng-if="s.done">Last drop-off +{{ fmt.money(s.done.net) }}' +
            '<span ng-if="s.done.tip > 0"> · {{ fmt.money(s.done.tip) }} tip</span>' +
            '<span ng-if="s.done.stars"> · {{ s.done.stars }} of 5 stars</span>' +
            '<span ng-if="s.done.rankUp"> · New rank {{ s.done.rankUp }}</span></div>' +
          '<div class="cep-card" ng-if="s.active.items.length"><div class="cep-label">{{ s.active.orderType ? s.active.cargo : "In this order" }}' +
            '<span ng-if="s.active.slots"> · {{ s.active.slots }} slot{{ s.active.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.active.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-sub" ng-if="!s.active.items.length && s.active.count === 1">{{ s.active.cargo }}</div>' +
          '<div class="cep-card" ng-if="s.active.route"><div class="cep-label">Parcel route · stop {{ s.active.route.at }} of {{ s.active.route.count }} · {{ s.active.route.left }} parcels on board</div>' +
            '<ul class="cep-order-items"><li ng-repeat="st in s.active.route.stops track by $index" ng-style="{opacity: st.done ? 0.45 : 1, fontWeight: st.current ? 700 : 400}">' +
              '<b>{{ st.done ? "✓" : st.slots + "×" }}</b>{{ st.name }}<small ng-if="!st.done"> · {{ fmt.kg(st.kg) }}</small></li></ul></div>' +
          '<div class="cep-sub" ng-if="s.active.freight && !s.active.route">{{ fmt.freight(s.active.freight) }}</div>' +
          '<div class="cep-sub" ng-if="s.active.freightStatus">{{ s.active.freightStatus }}</div>' +
          '<div class="cep-card" ng-if="s.bus && s.bus.line"><div class="cep-label"><span class="cep-busref" ng-style="s.bus.line.colour ? {background: s.bus.line.colour} : {}">{{ s.bus.line.ref || "Bus" }}</span> ' +
            'stop {{ s.bus.line.at }} of {{ s.bus.line.count }} · {{ s.bus.line.onBoard }} of {{ s.bus.line.capacity }} on board</div>' +
            '<ul class="cep-order-items"><li ng-repeat="st in s.bus.line.next track by $index" ng-style="{fontWeight: st.current ? 700 : 400}">' +
              '<b>{{ st.current ? "›" : "" }}</b>{{ st.n }}</li></ul>' +
            '<div class="cep-sub" ng-if="s.bus.line.doors">Doors open: {{ s.bus.line.doors.off }} off, {{ s.bus.line.doors.on }} on · {{ s.bus.line.doors.left }} s</div>' +
            '<div class="cep-sub" ng-if="!s.bus.line.doors && s.bus.stop">{{ s.bus.stop.inZone ? s.bus.stop.title : ("Drive to the stop: " + s.bus.stop.distM + " m away") }}</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.skipped">{{ s.bus.line.skipped }} skipped (not paid)</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.comfort < 100" ng-style="s.bus.line.comfort < 70 ? {color: \'var(--tomato)\'} : {}">Passenger comfort {{ s.bus.line.comfort }} % (brake, accelerate and corner gently)</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.late">{{ s.bus.line.late }} min behind the timetable so far (lowers the pay)</div>' +
            '<div class="cep-sub">Skip a stop you cannot reach. Ending early costs {{ fmt.money(s.bus.collectFee) }}.</div></div>' +
          '<div class="cep-keyval cep-sub" ng-if="s.active.tow && s.active.phase === \'toDelivery\'"><span>{{ s.active.tow.trailer }}</span>' +
            '<strong ng-style="{color: s.active.tow.onBoard < s.active.tow.cars ? \'var(--tomato)\' : \'var(--ok)\'}">' +
            '{{ s.active.tow.onBoard }} of {{ s.active.tow.cars }} car{{ s.active.tow.cars > 1 ? "s" : "" }} on board</strong></div>' +
          '<div class="cep-sub" ng-if="s.active.here && !s.active.towHitch">Borrow the {{ s.active.tow.trailer.toLowerCase() }} here, then fetch the car and bring both back.</div>' +
          '<div class="cep-sub" ng-if="s.active.towHitch">The trailer goes on your hitch. If it does not latch, stand still and press Hitch again.</div>' +
          '<div class="cep-sub" ng-if="s.active.towWaiting">{{ s.active.tow.wreck ? s.active.tow.wreck + ". " : "" }}Park the trailer next to the car, stop, then load.</div>' +
          '<div class="cep-sub" ng-if="s.active.trailerM !== null && s.active.trailerM !== undefined">Trailer: {{ fmt.dist(s.active.trailerM).v }}{{ fmt.dist(s.active.trailerM).u }} behind</div>' +
        '</div>' +
        '<div class="cep-actionbar" aria-label="Current job actions">' +
        '<div ng-if="s.bus.line" class="cep-actionbar"><div class="cep-row">' +
          '<button class="cep-btn go" ng-if="!s.bus.line.doors" ng-disabled="!s.bus.canDoors" ng-click="act(\'busDoors\')">Open doors (O)</button>' +
          '<button class="cep-btn" ng-if="s.bus.line.doors" disabled>Boarding: {{ s.bus.line.doors.left }} s</button>' +
          '<button class="cep-sm ghost" ng-click="act(\'gps\')">Navigate</button></div>' +
          '<div class="cep-row"><button class="cep-sm ghost" ng-disabled="s.bus.line.doors" ng-click="act(\'busSkip\')">Skip stop</button>' +
            '<button class="cep-sm ghost" ng-click="act(\'busEnd\')">End shift</button></div></div>' +
        '<div ng-if="!s.bus.line" class="cep-actionbar">' +
        '<button class="cep-btn go" ng-if="s.active.towHitch" ng-click="act(\'towHitch\')">Hitch trailer again</button>' +
        '<button class="cep-btn go" ng-if="s.active.towWaiting" ng-click="act(\'towLoad\')">Load {{ s.active.tow.cars > 1 ? "cars" : "car" }} on trailer</button>' +
        '<button class="cep-btn go" ng-if="s.active.canRestoreTrailer && !s.active.towWaiting && !s.active.towHitch" ng-click="act(\'restoreTrailer\')">' +
          '{{ s.active.tow ? (s.active.reloadFee ? "Reload cars: " + fmt.money(s.active.reloadFee) : "Restore tow load (free)") : "Restore assigned trailer" }}</button>' +
        '<button class="cep-sm ghost" ng-if="!s.company" ng-click="act(s.online ? \'offline\' : \'online\')">' +
          '{{ s.online ? "Go offline" : "Go online" }}</button>' +
        '<div class="cep-row"><button class="cep-btn ghost" ng-click="confirmCancel()">{{ s.company ? "Company contract" : ((cancelAsk || s.active.cancelAsk) ? "Cancel −" + fmt.money(s.active.cancelFee) + "?" : "Cancel order") }}</button>' +
          '<button class="cep-btn" ng-click="act(\'gps\')">Navigate</button></div></div></div>' +
      '</div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'failed\'"><div class="cep-center">' +
        '<div class="cep-label">Delivery failed</div>' +
        '<div class="cep-big">{{ s.failure.count > 1 ? s.failure.count + " orders ruined" : "Order ruined" }}</div>' +
        '<div class="cep-sub" ng-if="s.failure.g">The cargo on board took a {{ fmt.num(s.failure.g) }} g impact.</div>' +
        '<div class="cep-sub">No delivery pay or tip.</div></div>' +
        '<button class="cep-btn" ng-click="act(\'dismiss\')">Done</button></div>' +

      // done
      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'done\'"><div class="cep-center">' +
        '<div class="cep-label">{{ s.done.held ? "Delivered · pay held" : "Delivered" }}</div><div class="cep-pay">{{ s.done.held ? "" : "+" }}{{ fmt.money(s.done.net) }}</div>' +
        '<div class="cep-sub" ng-if="s.done.held">Paid when the contract ends: {{ s.done.ownerOperator ? "all of it with your own " + (s.done.vehicle || "van") : "80 % with the company " + (s.done.vehicle || "vehicle") }}.</div>' +
        '<div class="cep-sub">{{ s.done.to }}</div>' +
        '<div class="cep-sub" ng-if="s.dropped">Dropped {{ fmt.kg(s.dropped.kg) }}<span ng-if="s.dropped.left > 0"> · {{ fmt.kg(s.dropped.left) }} still on board</span></div>' +
        '<div ng-if="s.done.stars"><div class="cep-stars big" role="img" ng-attr-aria-label="{{ s.done.stars }} of 5 stars">{{ fmt.stars(s.done.stars) }}<i>{{ fmt.noStars(s.done.stars) }}</i></div>' +
          '<div class="cep-sub">“{{ s.done.note }}”</div></div>' +
        '<div class="cep-step" ng-if="s.done.records" style="background:var(--ok)">New personal record</div>' +
        '<div class="cep-step to" ng-if="s.done.rankUp">New rank · {{ s.done.rankUp }}</div>' +
        '<div class="cep-step to" ng-if="s.done.truckUnlock">{{ s.done.truckUnlock }} unlocked</div>' +
        '<div class="cep-card" style="width:100%;text-align:left">' +
          '<div class="cep-keyval"><span class="cep-sub">Delivery pay</span><strong>{{ fmt.money(s.done.pay) }}</strong></div>' +
          '<div class="cep-keyval"><span class="cep-sub">Customer tip<span ng-if="s.done.tipWhy"> · {{ tipWhy(s.done.tipWhy) }}</span></span>' +
            '<strong style="color:var(--ok)">{{ fmt.money(s.done.tip) }}</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.toDebt > 0"><span class="cep-sub">Paid toward debt</span><strong>−{{ fmt.money(s.done.toDebt) }}</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.cargoCondition"><span class="cep-sub">Damaged cargo</span><strong>{{ s.done.cargoCondition }}% intact</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.special.penalty"><span class="cep-sub">Too fast for an oversize load</span><strong>−{{ s.done.special.penalty }}% pay</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.late > 0"><span class="cep-sub">Delivered late</span><strong>{{ s.done.late }} min</strong></div>' +
        '</div></div>' +
        '<button class="cep-btn ok" ng-click="act(\'dismiss\')">Done</button></div>' +


      '<div class="cep-body" ng-if="tab === \'orders\' && s.screen === \'company\'"><div class="cep-center">' +
        '<div class="cep-label">Company contract</div><div class="cep-big">{{ s.company }}</div>' +
        '</div><button class="cep-btn go" ng-click="openCompany()">Open the contract</button></div>' +

      // radio: stations of the country you drive in (Radio Browser through the helper); the phone plays the stream
      '<div class="cep-body" ng-if="tab === \'radio\'">' +
        '<div class="cep-card cep-radio-now">' +
          '<div class="cep-label">{{ radio.station ? (radio.status === "playing" ? "Now playing" : (radio.status === "loading" ? "Tuning in…" : (radio.status === "error" ? "Cannot play" : "Paused"))) : "Radio" }}</div>' +
          '<div class="cep-name" title="{{ radio.station.name }}"><span class="cep-eq" ng-if="radio.status === \'playing\'"><i></i><i></i><i></i></span>{{ radio.station ? radio.station.name : "Pick a station below" }}</div>' +
          '<div class="cep-meta" ng-if="radio.why && radio.status !== \'error\'">{{ radio.why }}</div>' +
          '<div class="cep-meta" ng-if="radio.station">{{ stationMeta(radio.station) }}</div>' +
          '<div class="cep-sub" ng-if="radio.status === \'error\'">This stream does not play{{ radio.why ? " (" + radio.why + ")" : "" }}.</div>' +
          '<div class="cep-radio-ctl">' +
            '<button class="cep-sm ghost" title="Previous station" ng-disabled="!radio.station" ng-click="radioSkip(-1)">⏮</button>' +
            '<button class="cep-btn" ng-class="{go: radio.status !== \'playing\' && radio.status !== \'loading\'}" ng-disabled="!radio.station" ng-click="radioToggle()">' +
              '{{ radio.status === "playing" || radio.status === "loading" ? "Stop" : "Play" }}</button>' +
            '<button class="cep-sm ghost" title="Next station" ng-disabled="!radio.station" ng-click="radioSkip(1)">⏭</button></div>' +
          '<div class="cep-radio-ctl"><button class="cep-sm ghost" title="Quieter" ng-click="radioVol(-1)">−</button>' +
            '<div class="cep-vol" title="Volume"><i ng-style="{width: Math.round(radio.vol * 100) + \'%\'}"></i></div>' +
            '<button class="cep-sm ghost" title="Louder" ng-click="radioVol(1)">+</button></div>' +
        '</div><div class="cep-scroll" aria-label="Radio stations">' +
          '<div class="cep-li" style="padding:6px 10px" ng-click="radioVia(radio.via === \'helper\' ? \'page\' : \'helper\')">' +
            '<div><div class="cep-name" style="font-size:12px">Play through the helper</div>' +
            '<small>{{ radio.via === "helper" ? "The helper plays it on this PC" : "The game plays it; the helper steps in if needed" }}</small></div>' +
            '<b>{{ radio.via === "helper" ? "On" : "Off" }}</b></div>' +
        '<div class="cep-msg" ng-if="radio.moved">You are in {{ rs.countryName }} now.</div>' +
        '<div class="cep-label" ng-if="radio.saved.length">Saved stations</div>' +
        '<div class="cep-li" ng-repeat="st in radio.saved track by st.id" ng-class="{on: radio.station.id === st.id}" ng-click="radioPlay(st, radio.saved)">' +
          '<div><div class="cep-name">{{ st.name }}</div><small>{{ stationMeta(st) }}</small></div>' +
          '<button class="cep-fav" title="Remove from saved" ng-click="radioFav(st, $event)">★</button></div>' +
        '<div class="cep-sub" ng-if="!rs || rs.state === \'loading\'">Finding stations{{ rs && rs.countryName ? " in " + rs.countryName : "" }}…</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'off\' || rs.state === \'disabled\'">Start the Cargo Earth helper to find stations.</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'old\'">Update the Cargo Earth helper to get the radio.</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'failed\'">Cannot reach the station list. Trying again soon.</div>' +
        '<div class="cep-sub" ng-if="rs.state === \'nowhere\'">No country here, so no local stations.</div>' +
        '<div class="cep-sub" ng-if="rs.state === \'noworld\'">Load a BeamNG.Earth map to find local stations.</div>' +
        '<div class="cep-label" ng-if="rs.near.length">Near you</div>' +
        '<div class="cep-li" ng-repeat="st in rs.near track by st.id" ng-class="{on: radio.station.id === st.id}" ng-click="radioPlay(st, rs.near)">' +
          '<div><div class="cep-name">{{ st.name }}</div><small>{{ st.km }} km · {{ stationMeta(st) }}</small></div>' +
          '<button class="cep-fav" title="Save station" ng-click="radioFav(st, $event)">{{ isSaved(st) ? "★" : "☆" }}</button></div>' +
        '<div class="cep-label" ng-if="rs.top.length">Popular in {{ rs.countryName }}</div>' +
        '<div class="cep-li" ng-repeat="st in rs.top | limitTo: radio.show track by st.id" ng-class="{on: radio.station.id === st.id}" ng-click="radioPlay(st, rs.top)">' +
          '<div><div class="cep-name">{{ st.name }}</div><small>{{ stationMeta(st) }}</small></div>' +
          '<button class="cep-fav" title="Save station" ng-click="radioFav(st, $event)">{{ isSaved(st) ? "★" : "☆" }}</button></div>' +
        '<button class="cep-sm ghost" ng-if="rs.top.length > radio.show" ng-click="radioMore()">More stations</button>' +
        '<div class="cep-sub" ng-if="rs.state === \'ready\' && !rs.top.length">No working stations listed for {{ rs.countryName }}.</div>' +
        '<div class="cep-sub" style="font-size:11px">Stations: radio-browser.info</div>' +
      '</div></div>' +


      '<div class="cep-update" ng-if="s.helperBehind"><span>BeamNG.Earth still runs helper {{ s.helperBehind }}: press Update on Cargo Earth helper in its Add-ons page</span></div>' +
      '<div class="cep-update" ng-if="s.update.available && !s.update.hidden && !s.helperBehind">' +
        '<span>Cargo Earth {{ s.update.latest }} is out{{ s.update.modOld && s.update.helperOld ? "" : (s.update.modOld ? " (new mod)" : " (new helper)") }}</span>' +
        '<button class="cep-sm" ng-click="updateDo(\'open\')">Get it</button>' +
        '<button class="cep-sm ghost" aria-label="Hide until the next update" ng-click="updateDo(\'hide\')">Later</button></div>' +
      // at a station's pumps: fill from the Work screen (Not now hides it until the car leaves the station)
      '<div class="cep-pump" ng-if="tab === \'orders\' && s.pump && s.screen !== \'incoming\'">' +
        '<div class="cep-pump-head"><span>⛽ {{ s.pump.name }}</span>' +
          '<button class="cep-sm ghost" aria-label="Hide until you leave this station" ng-click="act(\'pumpHide\')">Not now</button></div>' +
        '<div class="cep-pump-msg" ng-if="s.pump.msg">{{ s.pump.msg }}</div>' +
        '<div class="cep-pump-msg" ng-if="s.pump.busy">Refuelling…</div>' +
        '<div class="cep-pump-row" ng-if="s.pump.options.length">' +
          '<button class="cep-sm" ng-repeat="o in s.pump.options track by o.pct" ng-disabled="!o.afford" ng-click="act(\'pumpFill\', o.pct)">' +
            '{{ o.pct === 100 ? "Full" : o.pct + " %" }}<small ng-if="!s.pump.free">{{ fmt.money(o.cost) }}</small></button></div></div>' +
      '<div class="cep-notices" aria-label="Job notifications">' +
      '<div class="cep-msg" role="alert" ng-if="s.saveError">{{ s.saveError }}</div>' +
      '<div class="cep-msg" role="alert" ng-if="s.flash">Speed camera: {{ s.flash.speed }} km/h, limit {{ s.flash.limit }}. Fine {{ fmt.money(s.flash.fine) }}' +
        '<span ng-if="s.flash.owed > 0"> ({{ fmt.money(s.flash.owed) }} added to your debt)</span>' +
        '<span ng-if="s.flash.stars > 0">. One star off the order on board</span>.</div>' +
      '<div class="cep-impact-note" ng-if="s.camera && !s.flash">Speed camera in {{ s.camera.m }} m · limit {{ s.camera.limit }} km/h</div>' +
      '<div class="cep-impact-note" ng-if="s.companyDamage > 0">{{ s.companyOwnerOperator ? "Your" : "Company" }} {{ s.companyVehicle || "vehicle" }} damage noted. It costs company reputation.</div>' +
      '</div>' +
      // one quiet line under the content: cargo space (Work only), fuel and damage. Debt is in the Menu.
      '<div class="cep-foot" ng-if="s.screen !== \'resume\'">' +
        '<span ng-if="tab === \'orders\' && s.storage.checking">Checking cargo space… · </span>' +
        '<span ng-if="tab === \'orders\' && s.storage.capacity" ng-class="{\'cep-foot-warn\': s.storage.overflow}">' +
          '{{ s.storage.boxes ? "Boxes" : "Bag" }} {{ s.storage.free }}/{{ s.storage.capacity }} free · </span>' +
        '<span ng-if="s.fuel" ng-style="{color: s.fuel.empty ? \'var(--tomato)\' : (s.fuel.low ? \'var(--warn)\' : \'\')}">{{ s.fuel.empty ? "Out of fuel" : "Fuel " + s.fuel.pct + " %" }}<span ng-if="s.fuel.rangeKm && !s.fuel.empty"> · {{ s.fuel.rangeKm }} km</span></span>' +
        '<span ng-if="s.repair > 0" style="color:var(--warn)"> · damage {{ fmt.money(s.repair) }}</span></div>' +
      '<nav class="cep-tabs" aria-label="Phone sections">' +
        '<button ng-class="{on: tab === \'orders\' && !panel}" ng-attr-aria-current="{{ tab === \'orders\' && !panel ? \'page\' : undefined }}" ng-click="setTab(\'orders\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="18" height="15" rx="2"/><path d="M8 6V3h8v3M3 11h18M10 11v3h4v-3"/></svg>Work</button>' +
        '<button ng-class="{on: tab === \'radio\' && !panel}" ng-attr-aria-current="{{ tab === \'radio\' && !panel ? \'page\' : undefined }}" ng-click="setTab(\'radio\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="8" width="18" height="13" rx="2"/><path d="M7 8l10-5"/><circle cx="15" cy="14.5" r="3"/><path d="M6 12h4M6 15h4M6 18h4"/></svg>Radio</button>' +
        '<button ng-class="{on: panel}" ng-attr-aria-expanded="{{ panel ? \'true\' : \'false\' }}" ng-click="togglePanel()">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>Menu</button></nav>' +
      '</div></div></div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.s = null
      scope.cancelAsk = false
      scope.fmt = {
        money: money, price: unitPrice, text: localText, dist: dist, clock: clock, km: km, mins: mins,
        remaining: function (seconds) { return clock(Math.abs(seconds)) },
        short: shortMoney
      }
      scope.here = function () { var a = scope.s && scope.s.active; return a ? (a.here || (a.phase === 'toPickup' ? a.from : a.to)) : {} }
      scope.near = function () { var a = scope.s && scope.s.active; return a && a.distM !== null && a.distM !== undefined && a.distM <= a.arriveM }
      scope.timePct = function () {
        var a = scope.s && scope.s.active
        if (!a) return 0
        return Math.max(2, Math.min(100, 100 * a.leftS / Math.max(1, a.minutes * 60)))
      }
      var foldKnown = false, busy = false, destroyed = false, lastPoll = -Infinity, lastState = null, shown
      function apply(r) {
        if (destroyed) return
        // Most answers are the same as the last one (waiting, offline, driving between ticks). An unchanged answer
        // needs no Angular digest, so the UI is not re-checked and redrawn for nothing. (Only while the phone still
        // shows that answer: closing the Menu window clears scope.s, and the next answer must bring it back.)
        var key = JSON.stringify(r === undefined ? null : r)
        if (key === lastState && scope.s === shown) return
        lastState = key
        scope.$evalAsync(function () {
          if (destroyed) return
          scope.s = shown = r || null
          if (r && r.currency) CUR = r.currency
          if (r && r.dark !== undefined) scope.dark = !!r.dark
          // The game rebuilds the UI apps when the camera changes (cockpit and back) or the pause menu opens: the
          // phone comes back folded if it was folded (the game keeps it, like the tab).
          if (r && !foldKnown) { foldKnown = true; if (!scope.dash && !scope.menuOnly) scope.min = !!r.fold }
          scope.ready = true // any answer, even none (the game without the mod) shows the phone
          if (r) keepLook(scope.dash || scope.menuOnly ? null : scope.min, r.dark)
          // the other phone chose Work or Radio (a choice made here a moment ago wins while the game hears of it)
          if (r && (r.tab === 'orders' || r.tab === 'radio') && r.tab !== scope.tab && !scope.menuOnly &&
            Date.now() - tabAt > 1500) showTab(r.tab, true)
          if (!r || r.screen !== 'active') scope.cancelAsk = false
        })
      }
      // How often the phone asks the game: 4 times a second only while the stop bar fills; twice a second otherwise
      // (the game moves the order's distance and timers on its 0.5 s tick anyway); folded or hidden every 2 s.
      function pollGap() {
        var s = scope.s
        if (scope.min || (s && s.hidden)) return 2000
        var stop = s && s.screen === 'active' && s.active && s.active.stop
        return stop && stop.inZone ? 250 : 500
      }
      function poll() {
        if (busy || destroyed) return
        if (scope.menuOnly && !scope.panel) return // the Menu app asks only while its window is open
        var now = Date.now()
        if (scope.panel === 'garage' && scope.gview === 'cars' && !(scope.g && scope.g.parts) && (!scope.min || scope.menuOnly) && now - marketPollAt >= 1000) scope.loadCars()
        if (now - lastPoll < pollGap()) return
        lastPoll = now
        busy = true
        bngApi.engineLua(STATE, function (r) { busy = false; apply(r) })
      }
      scope.busStatus = function (b) {
        if (!b) return ''
        if (b.state === 'old') return 'Update the Cargo Earth helper to get bus lines.'
        if (b.state === 'off') return 'Cannot reach the Cargo Earth helper. Check that it is running.'
        if (b.state === 'failed') return b.lines && b.lines.length
          ? 'Search incomplete. Previously found lines are available below.'
          : 'Bus search failed. Check the error below, then retry.'
        var p = b.progress || {}
        if (b.state !== 'ready') return p.queued && p.queued === p.loading
          ? 'Bus search is queued for OpenStreetMap. You can drive while this loads.'
          : 'Loading bus lines from OpenStreetMap. You can drive while this loads.'
        if (b.lines && b.lines.length) return 'Choose a line, then drive to its depot to start.'
        if (b.found) return b.found + ' routes found, but none have a stop within ' + b.radiusKm + ' km.' +
          (b.nearestKm !== undefined ? ' Nearest stop: ' + b.nearestKm.toFixed(1) + ' km away.' : '')
        return 'No usable bus routes found in the checked areas. Try another part of town or retry the search.'
      }
      // career saves: the New career name, and Delete asks once before it deletes
      scope.newSave = {name: ''}
      scope.delAsk = null
      scope.newCareer = function () {
        var name = (scope.newSave.name || '').trim()
        scope.newSave.name = ''
        scope.act('newCareer', name)
      }
      scope.askDelete = function (id) {
        if (scope.delAsk === id) { scope.delAsk = null; scope.act('deleteSave', id); return }
        scope.delAsk = id
        setTimeout(function () { scope.$evalAsync(function () { if (scope.delAsk === id) scope.delAsk = null }) }, 4000)
      }
      scope.act = function (name, value) {
        scope.cancelAsk = false
        var arg = value === undefined ? '' : ', ' + bngApi.serializeToLua(value)
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneAction("' + name + '"' + arg + ') or nil', apply)
      }
      // Buttons keep the dropdown inside the rendered dashboard texture; native select popups cannot receive its taps.
      scope.workModes = [{id: 'courier', name: 'Food delivery'}, {id: 'trucking', name: 'Freight'}, {id: 'taxi', name: 'Taxi'}, {id: 'bus', name: 'Bus'}]
      scope.modePicker = {work: false, settings: false}
      scope.workModeName = function (id) {
        for (var i = 0; i < scope.workModes.length; i++) if (scope.workModes[i].id === id) return scope.workModes[i].name
        return 'Choose job type'
      }
      scope.chooseWorkMode = function (where, id) {
        scope.modePicker.work = scope.modePicker.settings = false
        var state = where === 'settings' ? scope.st : scope.s
        if (!state || !state.canSwitch || id === state.mode || !scope.workModes.some(function (m) { return m.id === id })) return
        if (where === 'settings') scope.sdo('mode', id)
        else scope.act('mode', id)
      }
      // cancelling costs money: the first press asks, the second cancels
      scope.confirmCancel = function () {
        if (scope.s && scope.s.company) { scope.openCompany(); return }
        if (scope.cancelAsk || (scope.s && scope.s.active && scope.s.active.cancelAsk)) { scope.act('cancel'); return }
        scope.cancelAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.cancelAsk = false }) }, 4000)
      }
      // tabs, folding, garage and settings
      scope.tab = 'orders'
      scope.dash = !!(typeof window !== 'undefined' && window.cargoEarthDash && window.cargoEarthDash.page) // on a car screen
      // The "Cargo Earth: Menu" app (<cargo-earth-phone mode="menu">): no phone, only the Menu window, opened from either
      // phone. It is its own UI app so the Menu works with the floating phone, the dash phone, or both.
      scope.menuOnly = !!(element && element.attr && element.attr('mode') === 'menu')
      // first frame as it looked last (cargoEarthLook); the dash phone never folds
      scope.min = !scope.dash && !scope.menuOnly && cargoEarthLook.min
      scope.dark = cargoEarthLook.dark
      scope.ready = cargoEarthLook.known || scope.dash || scope.menuOnly
      scope.career = null
      scope.places = null
      scope.placeSearch = { text: '' }
      scope.panel = null // the menu window's section, or null while it is closed
      scope.careerView = 'progress'
      scope.endCompanyAsk = false
      scope.g = null; scope.gview = 'home'; scope.cars = []; scope.st = null
      scope.cf = { text: '', kind: null, afford: false, sort: 'price', help: null, detail: null }
      scope.purchase = { keep: true }
      scope.fmt.int = function (v) { return Math.round(v || 0).toLocaleString('cs-CZ') }
      // weight for the phone: one decimal under 10 kg (a meal), whole kg up to a tonne, then tonnes
      scope.fmt.kg = function (kg) {
        kg = kg || 0
        if (kg >= 1000) return (Math.round(kg / 100) / 10).toLocaleString('cs-CZ') + ' t'
        return (kg < 10 ? Math.round(kg * 10) / 10 : Math.round(kg)).toLocaleString('cs-CZ') + ' kg'
      }
      scope.fmt.freight = function (load) {
        return scope.fmt.int(load.amount) + (load.kind === 'parcel' ? ' slots' : ' L') + ' · ' + scope.fmt.int(load.kg) + ' kg'
      }
      var CATS = {delivery: 'Delivery', company_wages: 'Company wages', drivers: 'Drivers', garage: 'Garage', parts: 'Parts',
        cancel_fee: 'Cancel fee', adjustment: 'Other', fuel: 'Fuel', fine: 'Speeding fine', firm: 'Firm', upkeep: 'Upkeep'}
      scope.fmt.stars = function (n) { return '★★★★★'.slice(0, Math.max(0, Math.min(5, Math.round(n || 0)))) }
      scope.fmt.noStars = function (n) { return '★★★★★'.slice(0, 5 - Math.max(0, Math.min(5, Math.round(n || 0)))) }
      scope.fmt.pct = function (share) { return Math.round((share || 0) * 100) + ' %' }
      scope.fmt.trend = function (t) { return t === 'up' ? '▲ rising' : (t === 'down' ? '▼ falling' : '') }
      scope.mapData = null
      scope.mapPaths = {c: '', f: '', home: '', hq: ''}
      scope.deliveryAsk = false
      // roadside fuel is dear: the first press asks, the second orders
      scope.confirmDelivery = function () {
        if (scope.deliveryAsk) { scope.deliveryAsk = false; scope.gdo('fuelDelivery'); return }
        scope.deliveryAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.deliveryAsk = false }) }, 4000)
      }
      // Every dot is a zero-length line with a round cap: one path per colour instead of 200 elements.
      function dots(list, kind) {
        var d = ''
        for (var i = 0; i < (list || []).length; i++) if (list[i].k === kind) d += 'M' + list[i].x + ' ' + list[i].y + 'h0'
        return d
      }
      function drawMap(r) {
        scope.mapPaths = {c: dots(r.dots, 'c'), f: dots(r.dots, 'f'), home: dots(r.marks, 'home'), hq: dots(r.marks, 'hq')}
      }
      scope.fmt.cat = function (c) { return CATS[c] || (c ? (c.charAt(0).toUpperCase() + c.slice(1)).replace(/_/g, ' ') : 'Other') }
      scope.tipWhy = function (w) {
        var parts = []
        if (w.fast) parts.push('fast')
        if (w.intact) parts.push('arrived intact')
        if (w.smooth) parts.push('smooth ride')
        if (w.rough) parts.push('comfort ' + w.rough + ' %')
        else if (w.damaged) parts.push('arrived ' + w.damaged + ' % intact')
        return parts.join(', ')
      }
      scope.fmt.cond = function (c) { return c >= 0.85 ? 'very good' : c >= 0.6 ? 'good' : c >= 0.35 ? 'worn' : 'rough' }
      scope.fmt.left = function (m) { return m >= 60 ? Math.floor(m / 60) + ' h ' + (m % 60) + ' min' : m + ' min' }
      scope.fmt.hrs = function (h) { h = h || 0; return h < 1 ? Math.max(1, Math.round(h * 60)) + ' min' : (Math.round(h * 10) / 10).toLocaleString('cs-CZ') + ' h' }
      scope.market = {}
      scope.sellAsk = false
      scope.confirmSell = function () {
        if (scope.sellAsk) { scope.sellAsk = false; scope.gdo('sellCar'); return }
        scope.sellAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.sellAsk = false }) }, 4000)
      }
      scope.fmt.num = function (v) { return String(Math.round(v * 10) / 10).replace('.', ',') }
      function q(v) {
        return bngApi.serializeToLua(v === undefined || v === null ? '' : v)
      }
      function lua(fn, args, cb) {
        var a = (args || []).map(q).join(', ')
        bngApi.engineLua('(function() if not cargoEarth_core then return nil end; local ok, value = pcall(cargoEarth_core.' + fn +
          (a ? ', ' + a : '') + '); if ok then return value end; return { _phoneError = tostring(value) } end)()', function (r) {
          if (r && r._phoneError) {      // kept for the support report
            var sec = Math.floor(Date.now() / 1000) % 86400, two = function (n) { return (n < 10 ? '0' : '') + n }
            phoneNotes.push(two(Math.floor(sec / 3600)) + ':' + two(Math.floor(sec / 60) % 60) + ':' + two(sec % 60) + ' UTC ' + fn + ': ' + String(r._phoneError).slice(0, 300))
            if (phoneNotes.length > 10) phoneNotes.shift()
          }
          if (!destroyed) scope.$evalAsync(function () { cb(r) })
        })
      }
      var phoneNotes = []
      scope.report = null
      scope.copyReport = function () {
        scope.report = {busy: true}
        lua('supportReport', [phoneNotes], function (r) {
          scope.report = r && !r._phoneError ? r : {text: 'Could not make the report: ' + (r && r._phoneError), copied: false}
        })
      }
      scope.closeReport = function () { scope.report = null }
      // Settings > Restart career: the player types the word (DELETE) before the button works; the game checks it again
      scope.restart = {open: false, word: '', error: null}
      scope.restartOpen = function () { scope.restart = {open: true, word: '', error: null} }
      scope.restartClose = function () { scope.restart = {open: false, word: '', error: null} }
      scope.restartGo = function () {
        if (!scope.st || scope.restart.word !== scope.st.restartWord) return
        lua('settingsDo', ['restart', scope.restart.word], function (r) {
          if (r && r.restarted) {
            scope.restartClose()
            scope.st = r
            scope.closePanel() // the phone shows the first-run choice: Career or Free play
          } else {
            scope.restart.error = (r && (r.restartError || r._phoneError)) || 'Nothing was deleted.'
          }
        })
      }
      scope.updateDo = function (name) {
        lua('updateDo', [name], function (u) {
          if (!u || u._phoneError) return
          if (scope.s) scope.s.update = u
          if (scope.st) scope.st.update = u
        })
      }
      var loadingPage = {}
      scope.pageErrors = {}
      function page(fn, field, then) {
        if (destroyed) return
        if (loadingPage[fn] && Date.now() - loadingPage[fn].at < 5000) return
        var request = {at: Date.now()}
        loadingPage[fn] = request
        lua(fn, [], function (r) {
          if (loadingPage[fn] !== request) return
          delete loadingPage[fn]
          if (!r || r._phoneError) {
            scope.pageErrors[field] = r && r._phoneError ? 'Could not load this page: ' + r._phoneError : 'The game did not return this page. Retry in a moment.'
            return
          }
          scope.pageErrors[field] = null
          scope[field] = r
          if (then) then(r)
        })
      }
      function loadGarage() { page('garageState', 'g') }
      function loadCareer() {
        if (scope.careerView === 'map') { page('mapState', 'mapData', drawMap); return }
        if (scope.careerView === 'firm') { page('firmState', 'firm'); return }
        page('careerState', 'career')
      }
      function loadPlaces() { page('placesState', 'places') }
      function loadSettings() { page('settingsState', 'st') }
      scope.retryGarage = function () { delete loadingPage.garageState; loadGarage() }
      // (ng-if makes child scopes: changes go through functions so they land on this scope)
      // folded or open: the game keeps it (with the screen it was folded on), so a rebuilt phone stays folded
      scope.fold = function (v) {
        v = !!v
        var was = scope.min
        scope.min = v
        if (!scope.dash && !scope.menuOnly) keepLook(v)
        if (scope.dash || scope.menuOnly || (was === v && !v)) return
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneFold(' + (v ? 'true' : 'false') + ', ' +
          bngApi.serializeToLua((scope.s && scope.s.screen) || '') + ') and nil', function () {})
      }
      scope.goHome = function () { scope.gview = 'home'; loadGarage() }
      // The phone keeps what you need while driving (Work, Radio). Everything else opens in the menu window.
      var PANELS = ['garage', 'home', 'companies', 'career', 'settings']
      function loadPanel(p) {
        if (p === 'garage') loadGarage()
        if (p === 'career') loadCareer()
        if (p === 'home' || p === 'companies') loadPlaces()
        if (p === 'settings') loadSettings()
      }
      function resetAsks() {
        scope.endCompanyAsk = false
        scope.sellAsk = false
        scope.deliveryAsk = false
      }
      scope.setTab = function (t) {
        if (PANELS.indexOf(t) !== -1) { scope.openPanel(t); return }
        if (t !== 'orders' && t !== 'radio') return
        showTab(t)
        scope.panel = null
        resetAsks()
      }
      // Work or Radio: the game keeps which, so the other phone (floating or on the dash) follows within a moment
      var tabAt = -Infinity
      function showTab(t, fromGame) {
        if (!fromGame) {
          tabAt = Date.now()
          // with a callback: the game runs a command without one as a statement, and this expression alone is not one
          if (!scope.menuOnly) bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneTab(' + bngApi.serializeToLua(t) + ') and nil', function () {})
        }
        if (scope.tab === t) return
        scope.tab = t
        if (t === 'radio') loadRadio()
      }
      // a saved career waiting on the resume screen: only Settings (the dash phone, help) has anything to show yet
      scope.paused = function () { return !!(scope.s && scope.s.screen === 'resume') }
      scope.openPanel = function (p, view, local) {
        if (PANELS.indexOf(p) === -1) return
        if (scope.paused()) { p = 'settings'; view = undefined }
        // A phone asks the game to open the Menu window: the game sends it to the Menu app when that is in the UI,
        // else to the floating phone (CargoEarthOpenMenu). In VR it shows on BeamNG's UI panel. When neither is there
        // the game says no, and the section opens on this phone after all.
        if (!local && !scope.menuOnly) {
          bngApi.engineLua('cargoEarth_core and cargoEarth_core.openMenu(' + bngApi.serializeToLua(p) + ',' +
            bngApi.serializeToLua(view || null) + ')', function (shown) {
            if (shown !== true) scope.$evalAsync(function () { scope.openPanel(p, view, true) })
          })
          return
        }
        // another section → Garage starts on its first page; reopening the Menu keeps the page it was on (the car list…)
        if (p === 'garage' && scope.panel && scope.panel !== 'garage') scope.gview = 'home'
        if (p === 'career' && view) scope.careerView = view
        if (!scope.dash) {
          var other = cargoEarthMenu.open
          if (other && other !== scope && other.panel) other.$evalAsync(function () { other.closePanel() })
          cargoEarthMenu.open = scope
        }
        scope.panel = cargoEarthMenu.last = p
        scope.fold(false)
        resetAsks()
        loadPanel(p)
      }
      scope.closePanel = function () {
        scope.panel = null
        resetAsks()
        if (scope.menuOnly) scope.s = null // stops asking while closed: forget the old answer, it is no news on reopening
      }
      if (!scope.dash) {
        var hostKind = scope.menuOnly ? 'menu' : 'phone'
        scope.$on('CargoEarthOpenMenu', function (event, d) {
          if (!d || !d.panel || (d.to || 'phone') !== hostKind) return
          if (d.taken) return // one request, one app: every listener gets the same message
          d.taken = true
          scope.$evalAsync(function () {
            if (d.panel !== 'toggle') scope.openPanel(d.panel, d.view || undefined, true)
            else if (cargoEarthMenu.open && cargoEarthMenu.open.panel) cargoEarthMenu.open.closePanel()
            else if (scope.panel) scope.closePanel()
            else scope.openPanel(cargoEarthMenu.last || 'garage', undefined, true)
          })
        })
        // tell the game this app is here to show the Menu window
        var hostHere = function () { bngApi.engineLua('cargoEarth_core and cargoEarth_core.menuHost("' + hostKind + '")', function () {}) }
        hostHere()
        var hostTimer = setInterval(hostHere, 3000)
        scope.$on('$destroy', function () {
          clearInterval(hostTimer)
          if (cargoEarthMenu.open === scope) cargoEarthMenu.open = null
        })
      }
      // Menu button: closes an open window, else opens the last section. A window in another app (the Menu app or the
      // floating phone) is toggled there, where its open/closed state and last section live.
      scope.togglePanel = function () {
        if (scope.panel) { scope.closePanel(); return }
        if (scope.menuOnly) { scope.openPanel(cargoEarthMenu.last || 'garage', undefined, true); return }
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.openMenu("toggle")', function (shown) {
          if (shown !== true) scope.$evalAsync(function () { scope.openPanel(cargoEarthMenu.last || 'garage', undefined, true) })
        })
      }
      scope.panelOn = function (p, view) { return scope.panel === p && (!view || scope.careerView === view) }
      scope.panelTitle = function () {
        if (scope.panel === 'career') return {progress: 'Progress', money: 'Finances', map: 'Delivery map', firm: 'Firm'}[scope.careerView]
        return {garage: 'Garage', home: 'Home garage', companies: 'Company contracts', settings: 'Settings'}[scope.panel]
      }
      scope.setCareerView = function (view) {
        if (view !== 'progress' && view !== 'money' && view !== 'map' && view !== 'firm') return
        scope.openPanel('career', view)
      }
      scope.showLiveShortcut = function () {
        var s = scope.s
        if (!s || s.screen === 'resume') return false
        if (s.active || s.screen === 'incoming') return scope.tab !== 'orders' || !!scope.panel
        return !!s.company && scope.tab !== 'orders' && scope.panel !== 'companies'
      }
      scope.liveTitle = function () {
        var s = scope.s || {}
        if (s.screen === 'incoming') return 'New delivery offer'
        if (s.active) return s.active.phase === 'toPickup' ? 'Continue to pickup' : 'Continue delivery'
        return 'Active company contract'
      }
      scope.liveDetail = function () {
        var s = scope.s || {}, stop = scope.here()
        return s.screen === 'incoming' ? 'Review the offer on the phone' : (stop.name || s.company || '')
      }
      scope.openLiveWork = function () {
        if (scope.s && (scope.s.active || scope.s.screen === 'incoming')) {
          scope.setTab('orders')
        } else scope.openCompany()
      }
      scope.gdo = function (name, a, b) {
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        lua('garageDo', args, function (r) {
          if (!r || r._phoneError) { scope.pageErrors.g = r && r._phoneError || 'The garage action did not respond. Retry Garage.'; return }
          scope.pageErrors.g = null
          scope.g = r
          if (name === 'buyListing') { if (r && r.msg && r.msg.indexOf('Bought') === 0) scope.gview = 'home'; else scope.loadCars() }
          if (name === 'start' || name === 'sellCar') scope.gview = 'home'
        })
      }
      scope.toggleDebtCharges = function () { scope.debtCharges = !scope.debtCharges }
      scope.payDebt = function () {
        lua('garageDo', ['paydebt'], function (r) {
          if (r && !r._phoneError) scope.g = r
          loadCareer()
        })
      }
      var marketBusy = false, marketPollAt = 0
      scope.loadCars = function () {
        if (marketBusy || destroyed) return
        marketBusy = true
        marketPollAt = Date.now()
        var filter = scope.cf.text || ''
        lua('garageDealer', [filter], function (r) {
          marketBusy = false
          if (destroyed || filter !== (scope.cf.text || '') || !r || r._phoneError) return
          scope.market = r
          scope.cars = r.cars || []
        })
      }
      scope.carExpiry = function (car) {
        var seconds = Math.max(0, car.leftS || 0)
        return Math.floor(seconds / 60) + ':' + ('0' + (seconds % 60)).slice(-2)
      }
      scope.carPrice = function (car) { return car.price - (scope.purchase.keep ? 0 : (scope.market.tradeIn || 0)) }
      // the used-car list: vehicle kinds (type, cargo, jobs for the ?) and the tap filters
      scope.kindOf = function (car) {
        var kinds = scope.market.kinds || []
        for (var i = 0; i < kinds.length; i++) if (kinds[i].id === car.kind) return kinds[i]
        return null
      }
      var carFits = function (car, kind) {
        if (kind && car.kind !== kind) return false
        return !scope.cf.afford || scope.carPrice(car) <= (scope.market.money || 0)
      }
      scope.carCount = function (kind) {
        var n = 0
        ;(scope.cars || []).forEach(function (c) { if (carFits(c, kind)) n++ })
        return n
      }
      var shown = { key: null, list: [] }
      scope.shownCars = function () {
        var cf = scope.cf
        var key = [cf.kind, cf.afford, cf.sort, scope.purchase.keep, scope.market.money].join('|')
        if (shown.src === scope.cars && shown.key === key) return shown.list
        var list = (scope.cars || []).filter(function (c) { return carFits(c, cf.kind) })
        var by = {
          price: function (a, b) { return a.price - b.price },
          dear: function (a, b) { return b.price - a.price },
          km: function (a, b) { return a.km - b.km },
          cond: function (a, b) { return b.condition - a.condition }
        }[cf.sort] || function (a, b) { return a.price - b.price }
        list.sort(function (a, b) { return by(a, b) || a.id - b.id })
        shown.src = scope.cars; shown.key = key; shown.list = list
        return list
      }
      // the details card's rows, from the game's own vehicle info (mod cars often lack some, so only known ones show)
      scope.carPic = function (car) {
        var p = car.info && car.info.preview
        if (car.picStyle && car.picStyle.src === p) return car.picStyle.css
        car.picStyle = { src: p, css: { 'background-image': 'url("' + String(p).replace(/["\\]/g, '') + '")' } }
        return car.picStyle.css
      }
      scope.carSpecs = function (car) {
        var i = car.info || {}, rows = []
        if (car.specRows && car.specRows.src === i) return car.specRows.list
        var num = function (n) { return Math.round(n).toLocaleString('cs-CZ') }
        if (i.brand) rows.push(['Make', i.brand + (i.country ? ' · ' + i.country : '')])
        if (i.years) rows.push(['Years', i.years.min === i.years.max ? String(i.years.min) : i.years.min + '–' + i.years.max])
        if (i.body) rows.push(['Body', i.body])
        if (i.power) rows.push(['Power', num(i.power) + ' hp'])
        if (i.torque) rows.push(['Torque', num(i.torque) + ' Nm'])
        if (i.weight) rows.push(['Weight', num(i.weight) + ' kg'])
        if (i.topSpeed) rows.push(['Top speed', num(i.topSpeed) + ' km/h'])
        if (i.sprint) rows.push(['0–100 km/h', i.sprint + ' s'])
        if (i.drivetrain) rows.push(['Drive', i.drivetrain])
        if (i.gearbox) rows.push(['Gearbox', i.gearbox])
        if (i.fuel) rows.push(['Fuel', i.fuel])
        car.specRows = { src: i, list: rows }
        return rows
      }
      scope.buyCar = function (id) { scope.gdo('buyListing', id, scope.purchase.keep || !scope.market.tradeIn) }
      scope.look = function (id) { scope.gdo('preview', id, scope.purchase.keep || !scope.market.tradeIn) } // stays on the car list
      scope.openCars = function () { scope.gview = 'cars'; scope.loadCars() }
      scope.openFleet = function () { scope.gview = 'fleet'; loadGarage() }
      scope.pdo = function (name, value) {
        var args = [name]
        if (value !== undefined) args.push(value)
        lua('placesDo', args, function (r) { scope.places = r; poll() })
      }
      scope.openCompany = function () { scope.openPanel('companies') }
      scope.endCompany = function () {
        if (scope.endCompanyAsk) { scope.endCompanyAsk = false; scope.pdo('endCompany'); return }
        scope.endCompanyAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.endCompanyAsk = false }) }, 5000)
      }
      // the firm (Career / Firm) and its full-screen headquarters
      scope.firm = null; scope.hq = null; scope.hqOpen = false; scope.moveAsk = false
      scope.names = {firm: ''}
      function loadHq() { page('hqState', 'hq') }
      scope.fdo = function (name, a) {
        var args = [name]
        if (a !== undefined) args.push(a)
        lua('firmDo', args, function (r) { if (r && !r._phoneError) { scope.firm = r; if (name === 'found' && r.founded) scope.names.firm = '' } poll() })
      }
      scope.hdo = function (name, a, b) {
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        scope.moveAsk = false
        lua('hqDo', args, function (r) { if (r && !r._phoneError) scope.hq = r; poll() })
      }
      scope.openHq = function () { scope.hqOpen = true; scope.moveAsk = false; loadHq() }
      scope.closeHq = function () { scope.hqOpen = false; if (scope.panel === 'career') loadCareer() }
      scope.up = function (id) {
        var list = (scope.hq && scope.hq.upgrades) || []
        for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
        return {}
      }
      scope.pips = function (u) {
        var out = []
        for (var i = 0; i < (u.max || 0); i++) out.push(i < u.level)
        return out
      }
      scope.range = function (n) { return new Array(Math.max(0, Math.min(12, n || 0))) }
      scope.Math = Math
      scope.pick = { id: null }
      scope.pct = function (v) { return Math.round((v || 0) * 100) + ' %' }
      scope.pickedApplicant = function () {
        var list = (scope.hq && scope.hq.drivers && scope.hq.drivers.applicants) || []
        for (var i = 0; i < list.length; i++) if (list[i].id === scope.pick.id) return list[i]
        return null
      }
      // moving costs money: the first press asks, the second moves
      scope.moveHq = function () {
        if (scope.moveAsk) { scope.hdo('setHq'); return }
        scope.moveAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.moveAsk = false }) }, 5000)
      }
      // The headquarters covers the whole screen, so it lives on the page body, outside the phone's own box.
      // The menu window does the same, except on the dash screen: there it stays in the phone and covers just the phone.
      ;(scope.dash ? ['.cehq'] : ['.cem', '.cehq', '.cem-pad']).forEach(function (sel) {
        var overlay = element && element[0] && element[0].querySelector && element[0].querySelector(sel)
        if (!overlay || typeof document === 'undefined' || !document.body) return
        document.body.appendChild(overlay)
        scope.$on('$destroy', function () { if (overlay.parentNode) overlay.parentNode.removeChild(overlay) })
      })
      // moving the dash phone with the small pad: the big window closes so the dash stays in sight, and opens again after
      var padTimer = null
      scope.openMovePad = function () {
        scope.movePad = true
        scope.closePanel()
        if (!padTimer) padTimer = setInterval(function () { if (scope.movePad) loadSettings() }, 1000) // "moving…" ends
      }
      scope.closeMovePad = function () {
        scope.movePad = false
        if (padTimer) { clearInterval(padTimer); padTimer = null }
        scope.openPanel('settings', undefined, true)
      }
      scope.$on('$destroy', function () { if (padTimer) clearInterval(padTimer) })
      scope.sdo = function (name, a, b) {
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        lua('settingsDo', args, function (r) {
          scope.st = r
          if (r && r.dark !== undefined) { scope.dark = !!r.dark; keepLook(null, r.dark) }
        })
      }
      // The radio. One radio for both phones, kept by the game (cargoEarth_core.radioDo): what plays, the volume, the
      // saved stations. The sound comes from the page player below (on the game's UI page, kept while this app is
      // hidden) or from the helper; the phone only shows the radio and sends the presses.
      var radioLoadedAt = 0, lastCountry = null, radioSeq = null
      if (!scope.dash) pagePlayer()
      scope.radio = {station: null, list: [], status: 'idle', show: 25, moved: false, via: 'page', why: '', alone: false, vol: 0.6, saved: []}
      scope.rs = null
      function applyView(v) {
        if (!v) return
        var r = scope.radio
        r.station = v.station || r.station; r.status = v.status || 'idle'; r.why = v.why || ''; r.alone = !!v.alone
        if (typeof v.vol === 'number') r.vol = v.vol
        if (v.via) r.via = v.via
        if (Array.isArray(v.saved)) r.saved = v.saved
        radioSeq = v.seq
      }
      // while the radio tunes in, ask how it goes often (one timer, however many presses)
      var radioTimer = null
      function radioSoon() {
        if (radioTimer) clearTimeout(radioTimer)
        radioTimer = setTimeout(function () { radioTimer = null; if (!destroyed) loadRadio() }, 400)
      }
      function applyRadio(r) {
        if (!r || r._phoneError) return
        if (lastCountry && r.country && r.country !== lastCountry) scope.radio.moved = true
        if (r.country) lastCountry = r.country
        scope.rs = r
        applyView(r.radio)
        if (scope.radio.status === 'loading') radioSoon()
      }
      function loadRadio() {
        radioLoadedAt = Date.now()
        lua('radioState', [], applyRadio)
      }
      function radioDo(name, a) { lua('radioDo', a === undefined ? [name] : [name, a], applyRadio) }
      function withCountry(st, cc) {
        var out = {}
        for (var k in st) if (Object.prototype.hasOwnProperty.call(st, k) && k.charAt(0) !== '$') out[k] = st[k]
        out.country = cc || null
        return out
      }
      scope.stationMeta = function (st) {
        var bits = []
        if (st.region) bits.push(st.region)
        if (st.codec) bits.push(st.codec + (st.kbps ? ' ' + st.kbps + ' kbps' : ''))
        if (!st.region && st.tags) bits.push(st.tags)
        return bits.join(' · ')
      }
      scope.isSaved = function (st) {
        for (var i = 0; i < scope.radio.saved.length; i++) if (scope.radio.saved[i].id === st.id) return true
        return false
      }
      scope.radioPlay = function (st, list) {
        var r = scope.radio
        r.moved = false
        if (list) r.list = list
        if (!st || !/^https?:\/\//.test(st.url || '')) { r.status = 'error'; return }
        if (r.station && r.station.id === st.id && (r.status === 'playing' || r.status === 'loading')) return
        r.station = withCountry(st, (scope.rs && scope.rs.country) || st.country)
        r.status = 'loading'; r.why = ''
        radioDo('play', r.station)
      }
      scope.radioStop = function () {
        scope.radio.status = 'idle'; scope.radio.alone = false
        radioDo('stop')
      }
      scope.radioToggle = function () {
        var r = scope.radio
        if (r.status === 'playing' || r.status === 'loading') scope.radioStop()
        else if (r.station) scope.radioPlay(r.station)
      }
      scope.radioSkip = function (d) {
        var r = scope.radio, list = r.list && r.list.length ? r.list : ((scope.rs && scope.rs.top) || r.saved)
        if (!list || !list.length) return
        var at = -1
        for (var i = 0; i < list.length; i++) if (r.station && list[i].id === r.station.id) at = i
        scope.radioPlay(list[(at + d + list.length) % list.length], list)
      }
      scope.radioVol = function (d) {
        var r = scope.radio
        r.vol = Math.max(0, Math.min(1, Math.round((r.vol + d * 0.1) * 10) / 10))
        radioDo('vol', r.vol)
      }
      scope.radioFav = function (st, ev) {
        if (ev) ev.stopPropagation()
        var r = scope.radio
        if (scope.isSaved(st)) r.saved = r.saved.filter(function (x) { return x.id !== st.id })
        else r.saved = r.saved.concat([st])
        radioDo('fav', withCountry(st, st.country || (scope.rs && scope.rs.country)))
      }
      scope.radioMore = function () { scope.radio.show += 25 }
      scope.radioVia = function (v) {
        scope.radio.via = v === 'helper' ? 'helper' : 'page'
        radioDo('via', scope.radio.via)
      }
      // the quick poll says what plays in short: another phone changed the station, or the sound came on
      scope.$watch('s.radio', function (b) {
        var r = scope.radio
        if (!b) { if (r.status !== 'error') r.status = 'idle'; return }
        r.status = b.status
        if (b.seq !== radioSeq) { radioSeq = b.seq; loadRadio() }
      })
      // a section opened before the phone knew the save is still waiting (the Menu app's first answer): Settings instead
      scope.$watch('paused()', function (v) {
        if (v && scope.panel && scope.panel !== 'settings') scope.openPanel('settings', undefined, true)
      })
      // The editor can remount the phone. Open straight to checkout while a preview is active.
      scope.$watch('s.screen', function (v, old) {
        // the Menu app asks only while its window is open: its first answer after opening is no new offer
        if (scope.menuOnly && (old === null || old === undefined)) return
        // a phone the game just rebuilt, folded on this same screen: it stays folded
        if ((old === null || old === undefined) && scope.min && scope.s && scope.s.fold === v) return
        // a ringing offer unfolds the phone; on Radio it stays on Radio with the offer bar on top (tap it for Work)
        if (v === 'incoming') { scope.fold(false); scope.panel = null }
        if (v === 'resume') { scope.fold(false); if (scope.panel !== 'settings') scope.panel = null; showTab('orders') }
        if (v === 'parts') { scope.fold(false); scope.setTab('garage') }
      })
      var slowTicks = 0
      var slow = setInterval(function () {
        if (scope.hqOpen) loadHq()
        if (scope.min || (scope.s && scope.s.hidden)) return
        // an open Menu section follows the game every 2 s (an action's answer updates it at once)
        if (scope.panel && slowTicks++ % 2 === 0) loadPanel(scope.panel)
        if (scope.tab === 'radio' && Date.now() - radioLoadedAt > 4000) loadRadio()
      }, 1000)
      scope.$on('$destroy', function () { clearInterval(slow) })
      var timer = setInterval(poll, 250)
      poll()
      scope.$on('$destroy', function () { destroyed = true; clearInterval(timer) })
    }
  }
}]);

