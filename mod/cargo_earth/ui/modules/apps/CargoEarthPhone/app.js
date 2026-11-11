// Cargo Earth phone: a UI app that shows the courier's phone. Asks the game for the phone's state 4 times a second
// (cargoEarth_core.phoneState(): one small Lua call) and sends the buttons back (cargoEarth_core.phoneAction(name)).
// Screens: error, offline, waiting, incoming (with a countdown), active (pickup / delivery), done (pay and tip).
// Tabs: Work (deliveries / companies), Garage, Home, Career (progress / money / map / firm) and Settings. The firm's
// headquarters is a full-screen plan of the building (office, workshop, parts storage, yard, tank) opened from Career / Firm. Everything is
// clicked here: the mod has no key bindings. The "–" button folds the phone to a small bar; a ringing order opens it.
angular.module('beamng.apps')
.directive('cargoEarthPhone', [function () {
  var STATE = 'cargoEarth_core and cargoEarth_core.phoneState() or nil'
  var CSS =
    '.cep{--ink:#1d1b19;--paper:#fbf7f2;--card:#fff;--muted:#7b726a;--line:#e8e0d7;--tomato:#e8452c;--ok:#2f8f5b;--warn:#c98a10;' +
    'width:100%;height:100%;box-sizing:border-box;padding:9px;background:#141312;border-radius:34px;' +
    'box-shadow:0 10px 30px rgba(0,0,0,.45),inset 0 0 0 2px #2b2926;font-family:"Segoe UI",Roboto,system-ui,sans-serif;' +
    'color:var(--ink);user-select:none;-webkit-user-select:none}' +
    '.cep *{box-sizing:border-box}' +
    '.cep-screen{position:relative;width:100%;height:100%;border-radius:26px;overflow:hidden;background:var(--paper);' +
    'display:flex;flex-direction:column}' +
    '.cep-bar{display:flex;justify-content:space-between;align-items:center;padding:8px 18px 4px;font-size:12px;font-weight:600}' +
    '.cep-notch{position:absolute;top:6px;left:50%;width:72px;height:18px;margin-left:-36px;border-radius:10px;background:#141312}' +
    '.cep-head{display:flex;justify-content:space-between;align-items:baseline;padding:8px 16px 10px;border-bottom:1px solid var(--line)}' +
    '.cep-brand{font-weight:800;font-size:17px;letter-spacing:-.01em}.cep-brand b{color:var(--tomato)}' +
    '.cep-money{font-size:12px;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums}' +
    '.cep-money strong{display:block;color:var(--ink);font-size:15px}' +
    '.cep-body{flex:1;min-height:0;display:flex;flex-direction:column;padding:12px 14px;gap:10px;overflow:hidden}' +
    '.cep-center{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:10px}' +
    '.cep-big{font-size:22px;font-weight:800;line-height:1.15}' +
    '.cep-sub{font-size:13px;color:var(--muted);line-height:1.35}' +
    '.cep-label{font-size:10px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}' +
    '.cep-btn{display:block;width:100%;border:0;border-radius:14px;padding:13px 10px;font:inherit;font-size:15px;font-weight:700;' +
    'cursor:pointer;background:var(--ink);color:#fff}' +
    '.cep-btn:hover{filter:brightness(1.12)}.cep-btn.go{background:var(--tomato)}.cep-btn.ok{background:var(--ok)}' +
    '.cep-btn.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--line)}' +
    '.cep-row{display:flex;gap:8px}.cep-row .cep-btn{flex:1}' +
    '.cep-card{background:var(--card);border-radius:16px;padding:12px 14px;box-shadow:0 1px 0 var(--line),0 4px 14px rgba(29,27,25,.06)}' +
    '.cep-stop{display:grid;grid-template-columns:14px 1fr;gap:2px 10px;align-items:start}' +
    '.cep-dot{width:12px;height:12px;border-radius:50%;margin-top:3px;background:var(--tomato)}.cep-dot.to{background:var(--ink);border-radius:3px}' +
    '.cep-line{width:2px;height:16px;margin:2px 0 2px 5px;background:var(--line)}' +
    '.cep-name{font-size:14px;font-weight:700;line-height:1.2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.cep-meta{font-size:12px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
    '.cep-stats{display:grid;grid-template-columns:repeat(3,1fr);text-align:center;gap:4px;font-variant-numeric:tabular-nums}' +
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
    '.cep-pulse i{width:22px;height:22px;border-radius:50%;background:var(--tomato);animation:cepP 1.6s ease-in-out infinite}' +
    '@keyframes cepP{0%,100%{transform:scale(.8);opacity:.6}50%{transform:scale(1.15);opacity:1}}' +
    '.cep-adr{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;background:var(--warn);color:#fff;font-size:10px;font-weight:800}' +
    '.cep-foot{padding:6px 16px 4px;font-size:11px;color:var(--muted);text-align:center}' +
    '.cep-storage{font-size:10px;line-height:1.25;margin-bottom:3px;color:var(--ink)}' +
    '.cep-storage.warn{color:#a72f1e}' +
    '.cep-storage-wrap{position:relative}' +
    '.cep-storage-line{display:flex;align-items:center;justify-content:center;gap:6px}' +
    '.cep-storage-help{width:22px;height:22px;flex:0 0 auto;border:1px solid var(--line);border-radius:50%;padding:0;' +
    'background:var(--card);color:var(--ink);font:inherit;font-size:12px;font-weight:800;cursor:pointer}' +
    '.cep-storage-help[aria-expanded="true"]{background:var(--ink);color:var(--card)}' +
    '.cep-storage-tip{position:absolute;z-index:2;bottom:calc(100% + 6px);left:0;right:0;text-align:left;' +
    'border:1px solid var(--line);background:var(--card);box-shadow:0 4px 18px rgba(29,27,25,.18);border-radius:12px;padding:10px 12px;' +
    'font-size:12px;line-height:1.35}.cep-storage-tip p{margin:5px 0 0}' +
    '.cep-min{cursor:pointer;border:0;background:transparent;font:inherit;font-size:16px;font-weight:800;padding:0 4px;color:var(--ink)}' +
    '.cep-pill{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 16px;border-radius:999px;' +
    'background:#141312;color:#fff;font-family:"Segoe UI",Roboto,system-ui,sans-serif;font-weight:700;cursor:pointer;' +
    'box-shadow:0 6px 18px rgba(0,0,0,.4)}.cep-pill b{color:#e8452c}' +
    '.cep-tabs{display:flex;flex-shrink:0;border-top:1px solid var(--line);background:var(--card);padding:4px}' +
    '.cep-section{flex-shrink:0;padding:10px 14px 0;display:flex;align-items:center;justify-content:space-between;gap:8px}' +
    '.cep-section h1{font-size:18px;line-height:1.2;margin:0;letter-spacing:-.02em}' +
    '.cep-settings-link{border:0;background:transparent;padding:6px;color:var(--muted);font:inherit;font-size:11px;cursor:pointer}' +
    '.cep-subtabs{display:flex;flex-shrink:0;gap:4px;margin:10px 14px 0;padding:4px;background:var(--line);border-radius:12px}' +
    '.cep-subtabs button{flex:1;min-width:0;border:0;border-radius:9px;padding:8px 4px;font:inherit;font-size:12px;font-weight:700;background:transparent;color:var(--muted);cursor:pointer}' +
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
    '.cep-order-scroll>*{flex-shrink:0}' +
    '.cep-order-head,.cep-keyval{display:flex;align-items:center;justify-content:space-between;gap:8px}' +
    '.cep-order-head>.cep-ring{flex-shrink:0}' +
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
    '.cep-sm{border:0;border-radius:10px;padding:7px 10px;font:inherit;font-size:12px;font-weight:700;cursor:pointer;' +
    'background:var(--ink);color:#fff;white-space:nowrap}.cep-sm.ok{background:var(--ok)}.cep-sm.go{background:var(--tomato)}' +
    '.cep-sm.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--line)}' +
    '.cep-sm[disabled],.cep-btn[disabled]{opacity:.4;cursor:default}' +
    '.cep-msg{font-size:12px;padding:8px 10px;border-radius:10px;background:#fff4e5;color:#6b4a00}' +
    '.cep-step2{display:flex;align-items:center;gap:8px}.cep-step2 b{min-width:62px;text-align:center;font-variant-numeric:tabular-nums}' +
    '.cep-li>div{min-width:0}' +
    '.cep-input{flex:1;min-width:0;border:1.5px solid var(--line);border-radius:10px;padding:7px 10px;font:inherit;font-size:13px;background:#fff}' +
    '.cep-stars{color:#e0a100;letter-spacing:1px;font-size:15px;white-space:nowrap}.cep-stars.big{font-size:24px}' +
    '.cep-stars i{font-style:normal;color:var(--line)}' +
    '.cep-premium{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;background:#e0a100;color:#fff;font-size:10px;font-weight:800}' +
    '.cep-map{display:block;width:100%;border-radius:12px;background:#f1ebe3}' +
    '.cep-legend{display:flex;gap:12px;flex-wrap:wrap;font-size:11px;color:var(--muted)}' +
    '.cep-legend i{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px}'

  var HQ_CSS =
    '.cehq{position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:99999;display:flex;align-items:center;justify-content:center;' +
    'background:rgba(10,14,18,.72);font-family:"Segoe UI",Roboto,system-ui,sans-serif;color:#e8eef2;pointer-events:auto}' +
    '.cehq *{box-sizing:border-box}' +
    '.cehq-panel{width:94vw;max-width:1180px;height:90vh;max-height:780px;display:flex;flex-direction:column;gap:12px;padding:20px 22px;' +
    'border-radius:18px;background:#15202a;box-shadow:0 24px 60px rgba(0,0,0,.6),inset 0 0 0 1px #2b3c4a;overflow:hidden}' +
    '.cehq-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;flex-shrink:0}' +
    '.cehq-head-right{display:flex;align-items:center;gap:10px}' +
    '.cehq-kicker,.cehq-label{font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#7fb7d1}' +
    '.cehq-label.small{font-size:10px;color:#8ea2b0}' +
    '.cehq-title{font-size:26px;font-weight:800;line-height:1.15;color:#fff}' +
    '.cehq-sub{font-size:13px;color:#9fb2bf;margin-top:2px}' +
    '.cehq-money{font-size:18px;font-weight:800;font-variant-numeric:tabular-nums;text-align:right}' +
    '.cehq-money small{display:block;font-size:11px;font-weight:600;color:#ff9c8a}' +
    '.cehq-msg{flex-shrink:0;font-size:13px;padding:8px 12px;border-radius:10px;background:#22313d;color:#d6e2ea}' +
    '.cehq-empty{margin:auto;max-width:520px;text-align:center}.cehq-empty p{font-size:14px;line-height:1.5;color:#b8c7d1}' +
    '.cehq-btn{border:0;border-radius:10px;padding:9px 14px;font:inherit;font-size:13px;font-weight:700;cursor:pointer;background:#e8eef2;color:#15202a}' +
    '.cehq-btn:hover{filter:brightness(1.1)}.cehq-btn.build{background:#e8452c;color:#fff}' +
    '.cehq-btn.ghost{background:transparent;color:#e8eef2;box-shadow:inset 0 0 0 1.5px #3a4d5c}' +
    '.cehq-btn.small{padding:6px 9px;font-size:12px}.cehq-btn[disabled]{opacity:.4;cursor:default;filter:none}' +
    '.cehq-plan{flex:1;min-height:0;display:grid;grid-template-columns:1.15fr 1fr 1fr;grid-template-rows:auto minmax(240px,1fr);gap:0;' +
    'border:3px solid #7fb7d1;border-radius:6px;background:#101921;overflow:auto}' +
    '.cehq-room{display:flex;flex-direction:column;gap:7px;padding:14px 16px;border-right:3px solid #7fb7d1;border-bottom:3px solid #7fb7d1;' +
    'background-image:linear-gradient(#1a2733 1px,transparent 1px),linear-gradient(90deg,#1a2733 1px,transparent 1px);background-size:22px 22px}' +
    '.cehq-room.stores{border-right:0}.cehq-room.tank{border-right:0;border-bottom:0;grid-column:3;grid-row:2}' +
    '.cehq-yard{grid-column:1 / span 2;grid-row:2;padding:14px 16px;border-right:3px solid #7fb7d1;background:#232a31;overflow:auto}' +
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
    '.cehq-foot{flex-shrink:0;display:flex;justify-content:flex-end}'

  function money(n) { return (Math.round(n || 0)).toLocaleString('cs-CZ') + ' Kč' }
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
      '<div style="width:100%;height:100%"><style>' + CSS + HQ_CSS + '</style>' +
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
        '<div class="cehq-msg" ng-if="hq.msg">{{ hq.msg }}</div>' +
        '<div class="cehq-msg" ng-if="hq && !hq.founded">Start a firm first: phone, Career, Firm.</div>' +
        '<div class="cehq-empty" ng-if="hq.founded && !hq.hq">' +
          '<div class="cehq-title">Choose where the firm lives</div>' +
          '<p>Drive to a yard or warehouse you like, or to your home garage, and park. The first choice is free; moving later costs {{ fmt.money(hq.moveFee) }}.</p>' +
          '<p ng-if="hq.place">You are at <strong>{{ hq.place.name }}</strong>.</p>' +
          '<p ng-if="!hq.place">There is no yard, warehouse or home garage where you are parked.</p>' +
          '<button class="cehq-btn build" ng-disabled="!hq.place || !hq.parked" ng-click="hdo(\'setHq\')">Set the headquarters here</button></div>' +
        '<div class="cehq-plan" ng-if="hq.hq">' +
          '<div class="cehq-room office"><div class="cehq-label">Office</div>' +
            '<div class="cehq-stat">{{ hq.drivers.count }}<small>{{ hq.drivers.count === 1 ? "driver" : "drivers" }} on the road</small></div>' +
            '<div class="cehq-note">Each brings in {{ fmt.money(hq.drivers.pay) }} per {{ hq.drivers.shiftMinutes }} minutes you are working.<span ng-if="hq.drivers.earned > 0"> So far: {{ fmt.money(hq.drivers.earned) }}.</span></div>' +
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
            '<div class="cehq-note" ng-if="!hq.parts.count">Parts you take off a car are kept here. Fit or sell them in Garage on the phone.</div></div>' +
          '<div class="cehq-yard"><div class="cehq-yard-head"><div class="cehq-label">Yard · {{ hq.bays.length }} of {{ hq.capacity }} bays taken</div>' +
        '<button class="cehq-btn small build" ng-if="up(\'bays\').cost" ng-disabled="!up(\'bays\').can" ng-click="hdo(\'upgrade\', \'bays\')" title="{{ up(\'bays\').next }}">Build more bays · {{ fmt.money(up(\'bays\').cost) }}</button></div>' +
            '<div class="cehq-bays">' +
              '<div class="cehq-bay" ng-repeat="b in hq.bays track by $index" ng-class="{current: b.current, out: b.driver}">' +
                '<svg class="cehq-car" viewBox="0 0 60 110" aria-hidden="true"><rect x="8" y="4" width="44" height="102" rx="14"/><path class="glass" d="M14 30h32l-4 16H18zM18 78h24l4 12H14z"/><path class="glass" d="M10 50v24M50 50v24"/></svg>' +
                '<div class="cehq-bay-name">{{ b.name }}</div>' +
                '<div class="cehq-note">{{ fmt.int(b.km) }} km · {{ b.current ? "you drive it" : (b.driver ? "driver earned " + fmt.money(b.driver.earned) : "parked") }}</div>' +
                '<div class="cehq-note warn" ng-if="b.repair > 0">Needs {{ fmt.money(b.repair) }} in repairs</div>' +
                '<div class="cehq-bay-actions" ng-if="!b.current">' +
                  '<button class="cehq-btn small" ng-if="!b.driver" ng-disabled="hq.busy || hq.company" ng-click="hdo(\'switchCar\', b.id)">Drive</button>' +
                  '<button class="cehq-btn small ghost" ng-if="!b.driver && hq.drivers.can" ng-disabled="b.repair > 0 || hq.debt > 0 || hq.money < hq.drivers.hireFee || hq.company" ng-click="hdo(\'hireDriver\', b.id)">Hire driver · {{ fmt.money(hq.drivers.hireFee) }}</button>' +
                  '<button class="cehq-btn small ghost" ng-if="b.driver" ng-disabled="hq.company" ng-click="hdo(\'releaseDriver\', b.id)">Release driver</button></div></div>' +
              '<div class="cehq-bay free" ng-repeat="n in range(hq.free) track by $index"><div class="cehq-bay-free">Free bay</div>' +
                '<div class="cehq-note">Buy a car and keep your current one to fill it.</div></div>' +
            '</div></div>' +
          '<div class="cehq-room tank"><div class="cehq-label">Fuel tank</div>' +
      '<div class="cehq-level"><span class="cehq-pips"><i ng-repeat="on in pips(up(\'tank\')) track by $index" ng-class="{on: on}"></i></span>' +
        '<span>{{ up(\'tank\').now || "Not built" }}</span></div>' +
      '<button class="cehq-btn build" ng-if="up(\'tank\').cost" ng-disabled="!up(\'tank\').can" ng-click="hdo(\'upgrade\', \'tank\')">{{ up(\'tank\').level ? "Extend" : "Build" }} · {{ fmt.money(up(\'tank\').cost) }}</button>' +
      '<div class="cehq-note" ng-if="up(\'tank\').next">{{ up(\'tank\').next }}</div>' +
            '<div class="cehq-sep" ng-if="up(\'tank\').level"></div>' +
            '<div ng-if="up(\'tank\').level">' +
              '<div class="cehq-note" ng-if="hq.fuel.kind === \'electric\'">The tank holds petrol and diesel; your car charges at public chargers.</div>' +
              '<div class="cehq-note" ng-if="hq.fuel.station.hq">{{ fmt.num(hq.fuel.station.price) }} Kč per litre here.</div>' +
              '<button class="cehq-btn" ng-if="hq.fuel.station.hq && hq.fuel.fill" ng-disabled="hq.fuel.busy || hq.fuel.fill.canCost <= 0" ng-click="hdo(\'refuel\')">Fill up · {{ fmt.money(hq.fuel.fill.canCost) }}</button>' +
              '<div class="cehq-note" ng-if="hq.fuel && hq.fuel.kind !== \'electric\' && !(hq.fuel.station.hq && hq.fuel.fill)">Park the car here to fill up.</div></div></div>' +
        '</div>' +
        '<div class="cehq-foot" ng-if="hq.hq && !hq.hq.here && hq.place && hq.parked">' +
          '<button class="cehq-btn ghost" ng-disabled="hq.busy || hq.company" ng-click="moveHq()">{{ moveAsk ? "Press again to move · " + fmt.money(hq.moveFee) : "Move the headquarters to " + hq.place.name }}</button></div>' +
      '</div></div>' +
      '<div class="cep-pill" ng-if="min" ng-click="fold(false)"><span>Cargo<b>Earth</b></span>' +
        '<span>{{ s.online ? "● online" : "" }} {{ fmt.money(s.money) }} ▴</span></div>' +
      '<div class="cep" ng-if="!min"><div class="cep-screen">' +
      '<div class="cep-notch"></div>' +
      '<div class="cep-bar"><span>{{ s.clock }}</span><span>{{ s.online ? "● online" : "" }} ' +
        '<button class="cep-min" title="Fold the phone" ng-click="fold(true)">–</button></span></div>' +
      '<div class="cep-head"><div class="cep-brand">Cargo<b>Earth</b></div>' +
        '<div class="cep-money">balance<strong>{{ fmt.money(s.money) }}</strong></div></div>' +
      '<div class="cep-section" ng-if="s.screen !== \'resume\'"><h1>{{ sectionTitle() }}</h1>' +
        '<button class="cep-settings-link" ng-if="tab === \'orders\'" ng-click="setTab(\'settings\')">{{ s.mode === "courier" ? "Courier" : "Trucking" }} settings</button></div>' +
      '<nav class="cep-subtabs" aria-label="Work views" ng-if="tab === \'orders\' && s.screen !== \'resume\'">' +
        '<button ng-class="{on: workView === \'deliveries\'}" ng-attr-aria-pressed="{{ workView === \'deliveries\' }}" ng-click="setWorkView(\'deliveries\')">Deliveries</button>' +
        '<button ng-class="{on: workView === \'companies\'}" ng-attr-aria-pressed="{{ workView === \'companies\' }}" ng-click="setWorkView(\'companies\')">Companies<span ng-if="s.company"> / Active</span></button></nav>' +
      '<nav class="cep-subtabs" aria-label="Career views" ng-if="tab === \'career\' && s.screen !== \'resume\'">' +
        '<button ng-class="{on: careerView === \'progress\'}" ng-attr-aria-pressed="{{ careerView === \'progress\' }}" ng-click="setCareerView(\'progress\')">Progress</button>' +
        '<button ng-class="{on: careerView === \'money\'}" ng-attr-aria-pressed="{{ careerView === \'money\' }}" ng-click="setCareerView(\'money\')">Finances</button>' +
        '<button ng-class="{on: careerView === \'map\'}" ng-attr-aria-pressed="{{ careerView === \'map\' }}" ng-click="setCareerView(\'map\')">Map</button>' +
        '<button ng-class="{on: careerView === \'firm\'}" ng-attr-aria-pressed="{{ careerView === \'firm\' }}" ng-click="setCareerView(\'firm\')">Firm</button></nav>' +
      '<button class="cep-live" ng-if="showLiveShortcut()" ng-click="openLiveWork()">' +
        '<i class="cep-dot-live"></i><span><strong>{{ liveTitle() }}</strong><small>{{ liveDetail() }}</small></span><b aria-hidden="true">&rsaquo;</b></button>' +

      // error / not ready
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && (!s || s.screen === \'error\')"><div class="cep-center">' +
        '<div class="cep-big">Not available</div><div class="cep-sub">{{ s ? s.error : "Cargo Earth is not loaded." }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
        '<button class="cep-btn" ng-if="s.trucking.canLoan" ng-click="act(\'loanerTruck\')">Use loaner {{ s.trucking.loanerLabel }}</button>' +
      '</div></div>' +

      '<div class="cep-body" ng-if="s.screen === \'resume\'"><div class="cep-center">' +
        '<div class="cep-big">Resume Cargo Earth</div>' +
        '<div class="cep-sub">{{ s.savedCar ? "Return to your " + s.savedCar + " and continue your deliveries." : "Continue from your saved progress." }}</div>' +
        '<div class="cep-sub" ng-if="!s.resumeHasLocation">This save resumes at your current location. Your next save will record where you are.</div>' +
        '<div class="cep-sub" ng-if="!s.resumeLoading && s.status !== \'ok\'">{{ s.status }}</div>' +
        '<div class="cep-sub" ng-if="s.resumeError">{{ s.resumeError }}</div></div>' +
        '<button class="cep-btn go" ng-disabled="s.resumeLoading || s.status !== \'ok\'" ng-click="act(\'resume\')">' +
          '{{ s.resumeLoading ? "Loading saved location…" : "Load latest save" }}</button></div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'parts\'"><div class="cep-center">' +
        '<div class="cep-big">Parts preview open</div><div class="cep-sub">Confirm or cancel your parts changes before taking more orders.</div></div>' +
        '<button class="cep-btn go" ng-click="setTab(\'garage\')">Review parts</button></div>' +

      // offline
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'offline\'"><div class="cep-center">' +
        '<div class="cep-label">{{ s.mode === "courier" ? "Food delivery" : "Freight" }}</div>' +
        '<div class="cep-big">You are offline</div>' +
        '<div class="cep-sub" ng-if="!s.trucking || !s.trucking.hint">Go online and orders from nearby {{ s.mode === "courier" ? "restaurants and shops" : "depots" }} will ring here.</div>' +
        '<div class="cep-sub" ng-if="s.trucking">Trucking stage · {{ s.trucking.label }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.hint">{{ s.trucking.hint }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
      '</div>' +
      '<div class="cep-card cep-stats"><div>{{ s.todayCount }}<span>today</span></div>' +
        '<div>{{ fmt.short(s.todayEarned) }}<span>earned</span></div><div>{{ fmt.short(s.money) }}<span>balance</span></div></div>' +
      '<button class="cep-btn" ng-if="s.trucking.canLoan" ng-click="act(\'loanerTruck\')">Use loaner {{ s.trucking.loanerLabel }}</button>' +
      '<button class="cep-btn go" ng-click="act(\'online\')">Go online</button></div>' +

      // waiting
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'waiting\'"><div class="cep-center">' +
        '<div class="cep-pulse"><i></i></div><div class="cep-big">Looking for orders</div>' +
        '<div class="cep-sub" ng-if="s.trucking">{{ s.trucking.hint || ("Looking for " + s.trucking.carrier + " freight near you.") }}</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && (!s.helper || s.helper.state === \'ready\')">Stay near pickup locations. The next order will ring here.</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && s.helper && !s.helper.outdated && (s.helper.state === \'loading\' || s.helper.state === \'searching\')">' +
          '{{ s.helper.restaurants ? "Loading nearby pickup locations…" : "Loading nearby grocery stores…" }}</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && s.helper && (s.helper.state === \'off\' || s.helper.state === \'error\')">' +
          '{{ s.helper.restaurants ? "Start the Cargo Earth helper to load nearby pickup locations." : "Start the Cargo Earth helper to get local grocery runs." }}</div>' +
        '<div class="cep-sub" ng-if="!s.trucking && s.helper.outdated && (s.helper.state === \'ready\' || s.helper.state === \'loading\')">' +
          'Update the Cargo Earth helper for grocery runs.</div></div>' +
      '<div class="cep-card cep-stats"><div>{{ s.todayCount }}<span>today</span></div>' +
        '<div>{{ fmt.short(s.todayEarned) }}<span>earned</span></div><div>{{ fmt.short(s.money) }}<span>balance</span></div></div>' +
      '<div class="cep-sub" ng-if="s.trucking.error">{{ s.trucking.error }}</div>' +
      '<button class="cep-btn" ng-if="s.trucking.canLoan" ng-click="act(\'loanerTruck\')">Use loaner {{ s.trucking.loanerLabel }}</button>' +
      '<button class="cep-btn ghost" ng-click="act(\'offline\')">Go offline</button></div>' +

      // incoming
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'incoming\'">' +
        '<div class="cep-order-head">' +
          '<div><div class="cep-label">{{ s.incoming.orderType === "grocery" ? "Grocery run" : (s.incoming.orderType === "family" ? "Family meal" : ' +
            '(s.incoming.batch ? "Add to your route" : (s.incoming.kind === "food" ? "New food order" : "New freight job"))) }}</div>' +
          '<div class="cep-pay">{{ fmt.money(s.incoming.pay) }}</div>' +
          '<div class="cep-sub">{{ s.incoming.kind === "food" ? "Order pay · before any tip" : "Job pay" }}' +
            '<span class="cep-adr" ng-if="s.incoming.adr">ADR</span>' +
            '<span class="cep-premium" ng-if="s.incoming.premium">PREMIUM</span></div></div>' +
          '<div class="cep-ring"><svg width="64" height="64"><circle cx="32" cy="32" r="28" fill="none" stroke="#e8e0d7" stroke-width="6"/>' +
            '<circle cx="32" cy="32" r="28" fill="none" stroke="#e8452c" stroke-width="6" stroke-linecap="round" ' +
            'ng-attr-stroke-dasharray="{{ 175.9 * s.incoming.leftS / s.incoming.totalS }} 176"/></svg><b>{{ s.incoming.leftS }}</b></div>' +
        '</div>' +
        '<div class="cep-scroll cep-order-scroll">' +
          '<div class="cep-card cep-route"><div class="cep-stop">' +
            '<span class="cep-dot"></span><div><div class="cep-label">Pickup</div><div class="cep-name">{{ s.incoming.from.name }}</div>' +
              '<div class="cep-meta">{{ fmt.km(s.incoming.pickupKm) }} away<span ng-if="s.incoming.from.town"> · {{ s.incoming.from.town }}</span></div></div>' +
            '<span><span class="cep-line"></span></span><span></span>' +
            '<span class="cep-dot to"></span><div><div class="cep-label">Drop-off</div><div class="cep-name">{{ s.incoming.to.name }}</div>' +
              '<div class="cep-meta">{{ s.incoming.to.town || s.incoming.to.label }}</div></div>' +
          '</div></div>' +
          '<div class="cep-card" ng-if="s.incoming.items.length"><div class="cep-label">{{ s.incoming.orderType === "grocery" ? s.incoming.cargo : "In this order" }}' +
            '<span ng-if="s.incoming.slots"> · {{ s.incoming.slots }} slot{{ s.incoming.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.incoming.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-sub" ng-if="!s.incoming.items.length">{{ s.incoming.cargo }}{{ s.incoming.trailer ? " · " + s.incoming.trailer : "" }}</div>' +
          '<div class="cep-sub" ng-if="s.incoming.freight">{{ fmt.freight(s.incoming.freight) }}</div>' +
          '<div class="cep-sub">{{ fmt.km(s.incoming.km) }} from pickup to drop-off · {{ s.incoming.minutes }} min from acceptance' +
            '<span ng-if="s.incoming.farPickup > 0 && !s.incoming.batch"> · includes {{ fmt.money(s.incoming.farPickup) }} extra for the pickup drive</span></div>' +
          '<div class="cep-sub" ng-if="s.incoming.sizeBonus">Pay includes {{ fmt.money(s.incoming.sizeBonus) }} for the larger load.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.premium">Premium customer: pays more and wants it sooner. Your rating earned this order.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.fuelAllowance">Pay includes {{ fmt.money(s.incoming.fuelAllowance) }} toward fuel for your own vehicle.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay > 1">Your freight reputation adds {{ fmt.pct(s.incoming.reputationPay - 1) }} to this job.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay < 1">Your freight reputation lowers this job by {{ fmt.pct(1 - s.incoming.reputationPay) }}.</div>' +
          '<div class="cep-sub" ng-if="s.incoming.handling">{{ s.incoming.handling }} cargo<span ng-if="s.incoming.handling === \'Fragile\'"> · avoid hard jolts</span></div>' +
          '<div class="cep-sub" ng-if="s.incoming.batch">Adds a stop to your {{ s.incoming.openOrders }} open order{{ s.incoming.openOrders > 1 ? "s" : "" }}. ' +
            'Their timers keep running.</div>' +
          '<div class="cep-meta" ng-if="s.incoming.orderType === \'grocery\'">Pickup data © Overture Maps Foundation</div>' +
        '</div>' +
        '<div class="cep-row"><button class="cep-btn ghost" ng-click="act(\'decline\')">Decline</button>' +
          '<button class="cep-btn go" ng-click="act(\'accept\')">{{ s.incoming.batch ? "Add order" : "Accept" }}</button></div>' +
      '</div>' +

      // active
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'active\'">' +
        '<div class="cep-scroll cep-order-scroll">' +
          '<div class="cep-card cep-next-card">' +
            '<div class="cep-keyval"><span class="cep-step" ng-class="{to: s.active.phase === \'toDelivery\'}">' +
              '{{ s.active.phase === "toPickup" ? (s.active.kind === "food" ? "Pick up" : "Load freight") : "Drop off" }}</span>' +
              '<strong>{{ fmt.money(s.active.pay) }}</strong></div>' +
            '<div><div class="cep-name">{{ here().name }}</div>' +
              '<div class="cep-meta">{{ here().label }}{{ here().town ? " · " + here().town : "" }}</div></div>' +
            '<div class="cep-drive">' +
              '<div class="cep-dist">{{ fmt.dist(s.active.distM).v }}<small>{{ fmt.dist(s.active.distM).u }}</small></div>' +
              '<div class="cep-sub" ng-if="!s.active.stop.inZone">{{ s.active.distRoad ? "by road" : ' +
                '(s.active.kind === "food" && s.active.phase === "toPickup" ? "to the roadside ring" : "straight line") }}' +
                '{{ s.active.etaS && s.active.distRoad ? " · about " + fmt.mins(s.active.etaS) : "" }}</div>' +
              '<div ng-if="s.active.stop.inZone"><strong class="cep-sub">{{ s.active.stop.stopping ? ' +
                '(s.active.phase === "toPickup" ? "Collecting… " : "Handing over… ") + s.active.stop.leftS.toFixed(1).replace(".", ",") + " s" : ' +
                '"Park here for " + s.active.stop.stopS + " seconds" }}</strong>' +
                '<div class="cep-hold"><i ng-style="{width: (s.active.stop.frac * 100) + \'%\'}"></i></div></div>' +
            '</div>' +
            '<div><div class="cep-keyval cep-sub"><span>{{ s.active.leftS >= 0 ? "Time left" : "Overdue by" }}</span>' +
              '<strong class="cep-stop-time" ng-class="{late: s.active.leftS < 0}">{{ fmt.remaining(s.active.leftS) }}</strong></div>' +
              '<div class="cep-time" ng-class="{warn: s.active.leftS < 120 && s.active.leftS >= 0, late: s.active.leftS < 0}">' +
              '<i ng-style="{width: timePct() + \'%\'}"></i></div></div>' +
          '</div>' +
          '<div class="cep-keyval cep-sub" ng-if="s.active.handling"><span>{{ s.active.handling }} cargo</span>' +
            '<strong ng-if="s.active.phase === \'toDelivery\'" ng-style="{color: s.active.cargoCondition < 100 ? \'var(--tomato)\' : \'var(--ok)\'}">' +
              '{{ s.active.cargoCondition }}% intact</strong></div>' +
          '<div class="cep-impact-note" ng-if="s.failure">{{ s.failure.count }} order{{ s.failure.count > 1 ? "s" : "" }} ruined' +
            '<span ng-if="s.failure.g"> · {{ fmt.num(s.failure.g) }} g impact</span>. Continue with your remaining orders.</div>' +
          '<div class="cep-batch-list" ng-if="s.active.count > 1">' +
            '<div class="cep-label">Other stops · {{ s.active.carrying }} on board</div>' +
            '<div class="cep-li cep-order-line" ng-repeat="o in s.active.orders | filter:{current:false}:true track by o.id">' +
              '<div><small>{{ o.pickup ? "Awaiting pickup" : "On board" }}</small>' +
                '<div class="cep-name">{{ o.name }}</div><small>{{ o.cargo }} · ' +
                  '<span class="cep-stop-time" ng-class="{late: o.leftS < 0}">{{ fmt.clock(o.leftS) }}</span>' +
                  '<span ng-if="!o.pickup && o.cargoCondition < 100"> · {{ o.cargoCondition }}% intact</span></small></div>' +
              '<button class="cep-sm ghost" ng-if="o.selectable" ng-click="act(\'selectDelivery\', o.id)">Deliver next</button></div>' +
          '</div>' +
          '<div class="cep-receipt-note" ng-if="s.done">Last drop-off · +{{ fmt.money(s.done.net) }} to balance' +
            '<span ng-if="s.done.tip > 0"> · {{ fmt.money(s.done.tip) }} tip</span>' +
            '<span ng-if="s.done.stars"> · {{ s.done.stars }} of 5 stars</span>' +
            '<span ng-if="s.done.rankUp"> · New rank {{ s.done.rankUp }}</span></div>' +
          '<div class="cep-card" ng-if="s.active.items.length"><div class="cep-label">{{ s.active.orderType ? s.active.cargo : "In this order" }}' +
            '<span ng-if="s.active.slots"> · {{ s.active.slots }} slot{{ s.active.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.active.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-sub" ng-if="!s.active.items.length && s.active.count === 1">{{ s.active.cargo }}</div>' +
          '<div class="cep-sub" ng-if="s.active.freight">{{ fmt.freight(s.active.freight) }}</div>' +
          '<div class="cep-sub" ng-if="s.active.freightStatus">{{ s.active.freightStatus }}</div>' +
          '<button class="cep-sm" ng-if="s.active.canRestoreTrailer" ng-click="act(\'restoreTrailer\')">Restore assigned trailer</button>' +
          '<div class="cep-sub" ng-if="s.active.trailerM !== null && s.active.trailerM !== undefined">Trailer: {{ fmt.dist(s.active.trailerM).v }}{{ fmt.dist(s.active.trailerM).u }} behind</div>' +
        '</div>' +
        '<div class="cep-row"><button class="cep-btn ghost" ng-click="confirmCancel()">{{ s.company ? "Company contract" : ((cancelAsk || s.active.cancelAsk) ? "Cancel −" + fmt.money(s.active.cancelFee) + "?" : "Cancel order") }}</button>' +
          '<button class="cep-btn" ng-click="act(\'gps\')">Navigate</button></div>' +
      '</div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'failed\'"><div class="cep-center">' +
        '<div class="cep-label">Delivery failed</div>' +
        '<div class="cep-big">{{ s.failure.count > 1 ? s.failure.count + " orders ruined" : "Order ruined" }}</div>' +
        '<div class="cep-sub" ng-if="s.failure.g">The cargo on board took a {{ fmt.num(s.failure.g) }} g impact.</div>' +
        '<div class="cep-sub">No delivery pay or tip.</div></div>' +
        '<button class="cep-btn" ng-click="act(\'dismiss\')">Done</button></div>' +

      // done
      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'done\'"><div class="cep-center">' +
        '<div class="cep-label">{{ s.done.held ? "Delivery complete - revenue held" : "Delivery complete - added to balance" }}</div><div class="cep-pay">{{ s.done.held ? "" : "+" }}{{ fmt.money(s.done.net) }}</div>' +
        '<div class="cep-sub" ng-if="s.done.held">Revenue is held until the contract ends. Your share is {{ s.done.ownerOperator ? "100% with your own van" : "80% with the company van" }}.</div>' +
        '<div class="cep-sub">{{ s.done.to }}</div>' +
        '<div ng-if="s.done.stars"><div class="cep-stars big" role="img" ng-attr-aria-label="{{ s.done.stars }} of 5 stars">{{ fmt.stars(s.done.stars) }}<i>{{ fmt.noStars(s.done.stars) }}</i></div>' +
          '<div class="cep-sub">“{{ s.done.note }}”</div></div>' +
        '<div class="cep-step" ng-if="s.done.records" style="background:var(--ok)">New personal record</div>' +
        '<div class="cep-step to" ng-if="s.done.rankUp">New rank · {{ s.done.rankUp }}</div>' +
        '<div class="cep-step to" ng-if="s.done.truckUnlock">{{ s.done.truckUnlock }} unlocked</div>' +
        '<div class="cep-card" style="width:100%;text-align:left">' +
          '<div class="cep-keyval"><span class="cep-sub">Delivery pay</span><strong>{{ fmt.money(s.done.pay) }}</strong></div>' +
          '<div class="cep-keyval"><span class="cep-sub">Customer tip</span><strong style="color:var(--ok)">{{ fmt.money(s.done.tip) }}</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.toDebt > 0"><span class="cep-sub">Paid toward debt</span><strong>−{{ fmt.money(s.done.toDebt) }}</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.cargoCondition"><span class="cep-sub">Reduced pay for damaged cargo</span><strong>{{ s.done.cargoCondition }}% intact</strong></div>' +
          '<div class="cep-keyval" ng-if="s.done.late > 0"><span class="cep-sub">Delivered late</span><strong>{{ s.done.late }} min</strong></div>' +
        '</div></div>' +
        '<button class="cep-btn ok" ng-click="act(\'dismiss\')">Done</button></div>' +

      '<div class="cep-body" ng-if="tab === \'career\' && careerView === \'firm\' && s.screen !== \'resume\'">' +
        '<div class="cep-sub" ng-if="!firm">Loading your firm…</div>' +
        '<div class="cep-scroll" ng-if="firm">' +
          '<div class="cep-msg" ng-if="firm.msg">{{ firm.msg }}</div>' +
          '<div class="cep-card" ng-if="!firm.founded"><div class="cep-label">Your own firm</div>' +
            '<div class="cep-big">Start a firm</div>' +
            '<div class="cep-sub">A firm has a headquarters at a real place, with parking bays, a workshop, a fuel tank and a dispatch office. Only a firm can hire drivers.</div>' +
            '<div class="cep-keyval" ng-repeat="r in firm.requirements track by r.id" style="margin-top:6px;font-size:13px">' +
              '<span><span ng-style="{color: r.done ? \'var(--ok)\' : \'var(--muted)\'}">{{ r.done ? "✓" : "○" }}</span> {{ r.label }}</span>' +
              '<span class="cep-sub">{{ r.detail }}</span></div>' +
            '<div class="cep-row" style="margin-top:10px"><input class="cep-input" maxlength="28" aria-label="Firm name" placeholder="{{ firm.suggested }}" ng-model="names.firm"></div>' +
            '<button class="cep-btn go" ng-disabled="!firm.ready" ng-click="fdo(\'found\', names.firm)">Found the firm · {{ fmt.money(firm.fee) }}</button></div>' +
          '<div class="cep-card" ng-if="firm.founded"><div class="cep-label">Your firm</div>' +
            '<div class="cep-big">{{ firm.name }}</div>' +
            '<div class="cep-sub" ng-if="firm.hq">Headquarters · {{ firm.hq.name }}<span ng-if="firm.hq.town"> · {{ firm.hq.town }}</span></div>' +
            '<div class="cep-sub" ng-if="firm.hq">{{ firm.hq.here ? "You are at the headquarters." : fmt.num(firm.hq.km) + " km away." }} Room for {{ firm.capacity }} vehicles.</div>' +
            '<button class="cep-btn go" ng-click="openHq()">Open headquarters</button>' +
            '<button class="cep-sm ghost" ng-if="firm.hq && !firm.hq.here" ng-click="fdo(\'gpsHq\')">Route to headquarters</button></div>' +
          '<div class="cep-card" ng-if="firm.founded && !firm.hq"><div class="cep-label">Choose the headquarters</div>' +
            '<div class="cep-sub">Drive to a yard or warehouse you like, or to your home garage, park there and set it as the headquarters. The first choice is free; moving later costs {{ fmt.money(firm.moveFee) }}.</div>' +
            '<div class="cep-sub" ng-if="firm.place">You are at <strong>{{ firm.place.name }}</strong>.</div>' +
            '<div class="cep-sub" ng-if="!firm.place">No yard, warehouse or home garage here.</div>' +
            '<button class="cep-btn ok" ng-disabled="!firm.place || !firm.parked" ng-click="fdo(\'setHq\')">Set the headquarters here</button></div>' +
        '</div></div>' +

      // career
      '<div class="cep-body" ng-if="tab === \'career\' && careerView === \'progress\' && s.screen !== \'resume\'">' +
        '<div class="cep-sub" ng-if="!career">Loading career…</div>' +
        '<div class="cep-scroll" ng-if="career">' +
          '<div class="cep-card" ng-if="career.reputation"><div class="cep-label">Reputation</div>' +
            '<div class="cep-keyval"><strong>Courier</strong><span><span class="cep-stars">★</span> <strong>{{ fmt.num(career.reputation.courier.score) }}</strong>' +
              '<span class="cep-sub"> {{ fmt.trend(career.reputation.courier.trend) }}</span></span></div>' +
            '<div class="cep-sub">{{ career.reputation.courier.rated ? "Average of your last " + career.reputation.courier.rated + " food orders." : "No ratings yet. Customers rate every food order." }}' +
              '<span ng-if="career.reputation.courier.premium"> Premium orders are coming in.</span>' +
              '<span ng-if="!career.reputation.courier.premium"> Premium orders from {{ fmt.num(career.reputation.courier.premiumAt) }} after {{ career.reputation.courier.premiumMin }} ratings.</span>' +
              '<span ng-if="career.reputation.courier.slow" style="color:var(--tomato)"> Orders ring less often until your rating recovers.</span></div>' +
            '<div class="cep-keyval" style="margin-top:8px"><strong>Freight</strong><span><span class="cep-stars">★</span> <strong>{{ fmt.num(career.reputation.freight.score) }}</strong>' +
              '<span class="cep-sub"> {{ fmt.trend(career.reputation.freight.trend) }}</span></span></div>' +
            '<div class="cep-sub">{{ career.reputation.freight.rated ? "Average of your last " + career.reputation.freight.rated + " freight and company jobs." : "No ratings yet. Van, truck and company jobs are rated here." }}' +
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
          '<div class="cep-card cep-stats"><div>{{ fmt.int(career.completed) }}<span>completed</span></div>' +
            '<div>{{ fmt.int(career.ruined) }}<span>ruined</span></div>' +
            '<div>{{ fmt.km(career.km) }}<span>route distance</span></div></div>' +
          '<div class="cep-label">Cargo milestones</div>' +
          '<div class="cep-card" ng-repeat="goal in career.cargo track by goal.id">' +
            '<div class="cep-keyval"><strong>{{ goal.name }}</strong>' +
              '<span class="cep-sub" ng-if="goal.complete" style="color:var(--ok)">Completed</span></div>' +
            '<div class="cep-sub">{{ goal.detail }}</div></div>' +
          '<div class="cep-card" ng-if="career.driverRank"><div class="cep-label">Hire drivers</div>' +
            '<div class="cep-sub" ng-if="!career.driverUnlocked">Drivers are hired by your own firm. {{ career.firm.founded ? "Choose its headquarters first." : "Start one in Career → Firm." }}</div>' +
            '<div class="cep-sub" ng-if="career.driverUnlocked">Available in Garage → My cars.</div></div>' +
          '<div class="cep-card" ng-if="career.trucking"><div class="cep-label">Trucking</div>' +
            '<div class="cep-name">{{ career.trucking.label }}</div>' +
            '<div class="cep-sub" ng-if="career.trucking.van < career.trucking.vanGoal">Van hauls {{ career.trucking.van }} / {{ career.trucking.vanGoal }} to unlock rigid trucks</div>' +
            '<div class="cep-sub" ng-if="career.trucking.van >= career.trucking.vanGoal">{{ career.trucking.van }} van hauls · rigid trucks unlocked</div>' +
            '<div class="cep-sub" ng-if="career.trucking.rigid < career.trucking.rigidGoal">Rigid hauls {{ career.trucking.rigid }} / {{ career.trucking.rigidGoal }} to unlock semis</div>' +
            '<div class="cep-sub" ng-if="career.trucking.rigid >= career.trucking.rigidGoal">{{ career.trucking.rigid }} rigid hauls · semis unlocked</div>' +
            '<div class="cep-sub" ng-if="career.trucking.unlocked === \'semi\'">{{ career.trucking.semi }} articulated hauls completed</div></div>' +
          '<button class="cep-sm ghost" ng-click="setTab(\'garage\')">Go to Garage</button>' +
          '<div class="cep-card"><div class="cep-label">Distance driven</div><div class="cep-name">{{ fmt.num(career.drivenKm || 0) }} km</div>' +
            '<div class="cep-sub">Measured driving since this update; completed route distance is tracked separately.</div></div>' +
        '</div></div>' +

      // finances: bounded ledger, liquid balance and wages still held at the company
      '<div class="cep-body" ng-if="tab === \'career\' && careerView === \'money\' && s.screen !== \'resume\'">' +
        '<div class="cep-sub" ng-if="!career">Loading finances.</div>' +
        '<div class="cep-scroll" ng-if="career">' +
          '<div class="cep-card"><div class="cep-label">Available balance</div><div class="cep-pay">{{ fmt.money(s.money) }}</div>' +
            '<div class="cep-sub">Held company wages are paid when you end the contract.</div></div>' +
          '<div class="cep-money-grid"><div class="cep-card"><strong>{{ fmt.money(s.todayEarned) }}</strong><span>Earned today</span></div>' +
            '<div class="cep-card"><strong ng-class="{\'cep-debit\': career.debt > 0}">{{ fmt.money(career.debt) }}</strong><span>Outstanding debt</span></div></div>' +
          '<div class="cep-card" ng-if="s.company"><div class="cep-label">Company wages held</div><div class="cep-name">{{ fmt.money(career.heldWages) }}</div>' +
            '<button class="cep-sm ghost" ng-click="openCompany()">Open active contract</button></div>' +
          '<button class="cep-sm ghost" ng-if="career.debt > 0" ng-click="setTab(\'garage\')">Manage debt in Garage</button>' +
          '<div class="cep-label">Recent transactions</div>' +
          '<div class="cep-empty cep-sub" ng-if="!career.ledger.length">No transactions yet. Payments and purchases will appear here.</div>' +
          '<div class="cep-card" ng-repeat="entry in career.ledger | limitTo:20 track by entry.id">' +
            '<div class="cep-keyval"><strong>{{ fmt.cat(entry.category) }}</strong><strong ng-class="{\'cep-credit\': entry.amount > 0, \'cep-debit\': entry.amount < 0}">{{ entry.amount > 0 ? "+" : "" }}{{ fmt.money(entry.amount) }}</strong></div>' +
            '<div class="cep-sub">{{ entry.detail }}</div><div class="cep-meta">{{ entry.date }} / Balance {{ fmt.money(entry.balance) }}</div></div>' +
          '<div class="cep-meta" ng-if="career.ledger.length">Showing the latest 20 transactions.</div>' +
        '</div></div>' +

      // map: the latest deliveries as dots, and personal records
      '<div class="cep-body" ng-if="tab === \'career\' && careerView === \'map\' && s.screen !== \'resume\'">' +
        '<div class="cep-sub" ng-if="!mapData">Loading your map.</div>' +
        '<div class="cep-scroll" ng-if="mapData">' +
          '<div class="cep-empty cep-sub" ng-if="!mapData.count">No deliveries yet. Each drop-off leaves a dot here.</div>' +
          '<div ng-if="mapData.count"><svg class="cep-map" viewBox="-4 -4 108 108" role="img" aria-label="Map of your latest deliveries">' +
            '<path ng-attr-d="{{ mapPaths.f }}" fill="none" stroke="#1d1b19" stroke-width="2.6" stroke-linecap="round"/>' +
            '<path ng-attr-d="{{ mapPaths.c }}" fill="none" stroke="#e8452c" stroke-width="2.6" stroke-linecap="round" stroke-opacity=".8"/>' +
            '<path ng-attr-d="{{ mapPaths.home }}" fill="none" stroke="#2f8f5b" stroke-width="5.5" stroke-linecap="square"/>' +
            '<path ng-attr-d="{{ mapPaths.hq }}" fill="none" stroke="#c98a10" stroke-width="5.5" stroke-linecap="square"/></svg>' +
            '<div class="cep-legend" style="margin-top:6px"><span><i style="background:#e8452c"></i>Food</span><span><i style="background:#1d1b19"></i>Freight</span>' +
              '<span ng-if="mapPaths.home"><i style="background:#2f8f5b;border-radius:2px"></i>Home</span>' +
              '<span ng-if="mapPaths.hq"><i style="background:#c98a10;border-radius:2px"></i>Firm</span></div>' +
            '<div class="cep-sub">Your last {{ mapData.count }} drop-offs · north is up · about {{ fmt.num(mapData.spanKm) }} km across</div></div>' +
          '<div class="cep-label">Personal records</div>' +
          '<div class="cep-card">' +
            '<div class="cep-keyval"><span class="cep-sub">Five-star run</span><strong>{{ mapData.records.streak }} now · best {{ mapData.records.bestStreak }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestPay"><span class="cep-sub">Best paid order</span><strong>{{ fmt.money(mapData.records.bestPay.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestTip.value > 0"><span class="cep-sub">Biggest tip</span><strong>{{ fmt.money(mapData.records.bestTip.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.longest"><span class="cep-sub">Longest order</span><strong>{{ fmt.km(mapData.records.longest.value) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.quickest"><span class="cep-sub">Quickest against the clock</span><strong>{{ mapData.records.quickest.value }} % of the time to spare</strong></div>' +
            '<div class="cep-keyval" ng-if="mapData.records.bestDay"><span class="cep-sub">Best day</span><strong>{{ fmt.money(mapData.records.bestDay.value) }}</strong></div>' +
            '<div class="cep-meta" ng-if="mapData.records.bestDay">{{ mapData.records.bestDay.date }}</div></div>' +
        '</div></div>' +

      // places: persistent home address and company contracts
      '<div class="cep-body" ng-if="(tab === \'home\' || (tab === \'orders\' && workView === \'companies\')) && s.screen !== \'resume\'"><div class="cep-sub" ng-if="!places">{{ tab === "home" ? "Loading home garage." : "Loading company contracts." }}</div>' +
        '<div class="cep-msg" role="status" ng-if="places.msg">{{ places.msg }}</div>' +
        '<div class="cep-scroll" ng-if="places && !places.blocked">' +
          '<div ng-if="tab === \'home\'" style="display:flex;flex-direction:column;gap:8px">' +
          '<div class="cep-card" ng-if="places.home"><div class="cep-label">Home garage</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.home.name }}</div><div class="cep-sub">{{ places.home.town }}</div>' +
            '<div class="cep-sub">{{ places.used }} / {{ places.capacity || places.home.capacity }} owned vehicles. {{ places.atHome ? "You are home." : fmt.num(places.homeKm) + " km away." }}</div>' +
            '<button class="cep-sm ghost" ng-disabled="places.busy || places.shift" ng-click="pdo(\'homeGps\')">Route home</button></div>' +
          '<div class="cep-label">{{ places.home ? "Change home address" : "Choose your home garage" }}</div>' +
          '<div class="cep-sub">Search addresses within 3 km of your car. Select one, drive there and park in a safe spot to confirm it.</div>' +
          '<input class="cep-search" type="text" maxlength="100" aria-label="Street or town" placeholder="Street or town" ng-model="placeSearch.text">' +
          '<button class="cep-sm ghost" ng-click="pdo(\'search\', placeSearch.text)">Find nearby addresses</button>' +
          '<div class="cep-card" ng-repeat="address in places.addresses track by address.id">' +
            '<div class="cep-name" style="white-space:normal">{{ address.n }}</div><div class="cep-sub">{{ address.town }} - {{ fmt.num(address.km) }} km</div>' +
            '<button class="cep-sm" ng-click="pdo(\'select\', address.id)">{{ places.selected.id === address.id ? "Selected" : "Select address" }}</button></div>' +
          '<div class="cep-card" ng-if="places.selected"><div class="cep-label">Selected address</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.selected.n }}</div>' +
            '<button class="cep-sm ghost" ng-disabled="places.busy || places.shift" ng-click="pdo(\'routeSelected\')">Route to address</button>' +
            '<button class="cep-btn go" ng-disabled="places.busy || places.shift" ng-click="pdo(\'claimHome\')">Make this parking spot my home</button></div></div>' +
          '<div ng-if="tab === \'orders\' && workView === \'companies\'" style="display:flex;flex-direction:column;gap:8px">' +
          '<div class="cep-label">Company contracts</div>' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'loading\' || places.discovery.state === \'searching\'">Discovering workplaces around your current location.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'off\'">Start the Cargo Earth helper for local workplaces outside the bundled data.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.supportsDepots === false">Update the helper to 0.3.0 for workplace discovery.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.msg">{{ places.discovery.msg }}</div>' +
          '<div class="cep-sub">The company supplies a cargo van and covers its vehicle costs. You receive 80% of completed delivery revenue when work ends.</div>' +
          '<div class="cep-sub">Damaged parcels reduce pay; ruined loads pay nothing. Cargo quality and vehicle damage affect employer reputation.</div>' +
          '<div class="cep-card" ng-if="places.shift"><div class="cep-name" style="white-space:normal">{{ places.shift.company }}</div>' +
            '<div class="cep-label" ng-if="places.shift.ownerOperator">Independent contract - your own van</div>' +
            '<div class="cep-sub">{{ places.shift.completed }} / {{ places.shift.total }} deliveries. Wages held: {{ fmt.money(places.shift.held) }}</div>' +
            '<div class="cep-impact-note" ng-if="places.shift.failed">{{ places.shift.failed }} load(s) ruined. No pay for failed deliveries.</div>' +
            '<div class="cep-sub" ng-if="places.shift.vehicleDamage > 0">Vehicle damage recorded: {{ fmt.money(places.shift.vehicleDamage) }}. {{ places.shift.ownerOperator ? "Your vehicle costs apply." : "Company covers repairs; reputation is affected." }}</div>' +
            '<div class="cep-sub">Reputation score so far: {{ places.shift.reputationScore > 0 ? "+" : "" }}{{ places.shift.reputationScore }} if the route ends at the yard.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'preparing\'">Preparing the company van and cargo equipment.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'working\'">Follow the delivery in Work / Deliveries. Wages are held until you return.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'returning\'">Return to the company yard, park and collect your wages.</div>' +
            '<div class="cep-sub" ng-if="places.shift.phase === \'settled\'">Wages recorded. Returning your personal car.</div>' +
            '<div class="cep-sub" ng-if="places.shift.error">{{ places.shift.error }}</div>' +
            '<button class="cep-sm ghost" ng-if="!places.busy" ng-click="pdo(\'companyGps\')">Route to company yard</button>' +
            '<button class="cep-btn ok" ng-if="places.shift.phase === \'returning\' || places.shift.phase === \'settled\'" ' +
              'ng-disabled="!places.shift.atYard && places.shift.phase !== \'settled\'" ng-click="pdo(\'settleCompany\')">Collect wages and return my car</button>' +
            '<button class="cep-sm ghost" ng-click="endCompany()">{{ endCompanyAsk ? "Confirm end - completed work is paid" : "End company work early" }}</button></div>' +
          '<div ng-if="!places.shift"><button class="cep-sm ghost" ng-disabled="places.busy" ng-click="pdo(\'refreshCompanies\')">Find company contracts</button>' +
            '<div class="cep-sub" ng-if="!places.started">Start your career in Garage before taking company work.</div>' +
            '<div class="cep-empty cep-sub" ng-if="!places.companies.length">No contracts available nearby yet. Let local workplace data finish loading, refresh here, or try another area.</div>' +
            '<div class="cep-card" ng-repeat="company in places.companies track by company.id">' +
              '<div class="cep-name" style="white-space:normal">{{ company.name }}</div>' +
              '<div class="cep-sub">Yard {{ fmt.num(company.km) }} km away. Two deliveries, about {{ company.minutes }} min including return travel.</div>' +
              '<div class="cep-keyval"><span class="cep-sub">Estimated wages</span><strong>{{ fmt.money(company.wages) }}</strong></div>' +
              '<div class="cep-sub">Reputation {{ company.reputation }} / 100</div>' +
              '<button class="cep-sm ghost" ng-disabled="places.busy" ng-click="pdo(\'companyGps\', company.id)">Route to yard</button>' +
              '<button class="cep-btn go" ng-disabled="places.busy || !places.started || !company.atYard" ng-click="pdo(\'startCompany\', company.id)">' +
                '{{ company.atYard ? "Start company contract" : "Park at yard to start" }}</button>' +
              '<div class="cep-sub" ng-if="!company.independentUnlocked">Independent contracts unlock at 20 reputation with this employer.</div>' +
              '<button class="cep-btn ghost" ng-if="company.independentUnlocked" ng-disabled="places.busy || !company.atYard" ng-click="pdo(\'startIndependent\', company.id)">' +
                'Use my own van - {{ fmt.money(company.independentPay) }}</button></div></div>' +
          '<div class="cep-card" ng-if="places.last && !places.shift"><div class="cep-label">Last company settlement</div>' +
            '<div class="cep-name" style="white-space:normal">{{ places.last.company }}</div>' +
            '<div class="cep-keyval"><span>Delivery revenue</span><strong>{{ fmt.money(places.last.gross) }}</strong></div>' +
            '<div class="cep-keyval"><span>Company share</span><strong>-{{ fmt.money(places.last.share) }}</strong></div>' +
            '<div class="cep-keyval"><span>Your wages</span><strong>{{ fmt.money(places.last.wages) }}</strong></div>' +
            '<div class="cep-keyval" ng-if="places.last.toDebt"><span>Debt repayment</span><strong>-{{ fmt.money(places.last.toDebt) }}</strong></div>' +
            '<div class="cep-keyval"><span>Added to balance</span><strong>{{ fmt.money(places.last.net) }}</strong></div>' +
            '<div class="cep-sub" ng-if="places.last.failed">Ruined loads: {{ places.last.failed }}. No pay for those deliveries.</div>' +
            '<div class="cep-sub" ng-if="places.last.vehicleDamage > 0">Recorded vehicle damage: {{ fmt.money(places.last.vehicleDamage) }}</div>' +
            '<div class="cep-keyval" ng-if="places.last.reputationChange !== undefined"><span>Reputation change</span><strong>{{ places.last.reputationChange > 0 ? "+" : "" }}{{ places.last.reputationChange }}</strong></div>' +
            '<div class="cep-sub" ng-if="places.last.reputationScore < 0">Performance score {{ places.last.reputationScore }}; employer reputation cannot fall below zero.</div>' +
            '<div class="cep-sub" ng-if="places.last.aborted">Ended early. Completed deliveries paid; no cancellation fee.</div></div></div>' +
        '</div></div>' +

      '<div class="cep-body" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.screen === \'company\'"><div class="cep-center">' +
        '<div class="cep-label">Company contract</div><div class="cep-big">{{ s.company }}</div>' +
        '<div class="cep-sub">Open Companies for your van, return instructions and held wages.</div>' +
        '<button class="cep-btn go" ng-click="openCompany()">Open company contract</button></div></div>' +

      // garage
      '<div class="cep-body" ng-if="tab === \'garage\' && s.screen !== \'resume\'">' +
        '<div class="cep-sub" role="status" ng-if="!g && !pageErrors.g">Loading Garage.</div>' +
        '<div class="cep-msg" role="alert" ng-if="pageErrors.g">{{ pageErrors.g }} <button class="cep-sm ghost" ng-click="retryGarage()">Retry Garage</button></div>' +
        '<div class="cep-card" ng-if="s.screen === \'parts\' && !g.parts"><div class="cep-label">Parts checkout pending</div>' +
          '<div class="cep-sub">Your changes are a preview. Retry checkout or restore the paid configuration.</div>' +
          '<button class="cep-btn ghost" ng-click="gdo(\'cancelParts\')">Discard preview and restore car</button></div>' +
        '<div class="cep-msg" ng-if="g.msg">{{ g.msg }}</div>' +
        '<div ng-if="g && !g.started" class="cep-center">' +
          '<div class="cep-label">Your career</div><div class="cep-big">Start with an old {{ g.starter }}</div>' +
          '<div class="cep-sub">You get the cheapest {{ g.starter }} and {{ fmt.money(g.startMoney) }}. Your money now is replaced. ' +
          'Orders then only come while you drive this car. Buy parts and better cars from what you earn.</div>' +
          '<div class="cep-sub" ng-if="g.busy" style="color:var(--tomato)">Your current order will be cancelled (no fee).</div>' +
          '<button class="cep-btn go" ng-click="gdo(\'start\')">Start my career</button></div>' +
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
          '<button class="cep-btn go" ng-disabled="!g.preview.ready" ng-click="gdo(\'buyListing\', g.preview.id)">Buy it</button>' +
          '<button class="cep-btn ghost" ng-click="gdo(\'back\')">Back to my car</button>' +
        '</div>' +
        '<div ng-if="g && g.started && gview === \'home\' && !g.preview && !g.parts" class="cep-scroll">' +
          '<button class="cep-sm ghost" ng-click="setTab(\'home\')">Home garage and parking</button>' +
          '<div class="cep-card" ng-if="g.car"><div class="cep-label">Your car</div><div class="cep-name" style="font-size:17px;white-space:normal">{{ g.car }}</div>' +
            '<div class="cep-sub">{{ fmt.int(g.km) }} km<span ng-if="g.own"> · {{ fmt.cond(g.condition) }} · worth about {{ fmt.money(g.value) }}</span></div>' +
            '<div class="cep-sub" ng-if="!g.own" style="color:var(--tomato)">You are not in it. Orders only come in your car.</div></div>' +
          '<div class="cep-card" ng-if="g.own && s.storage.capacity">' +
            '<div class="cep-label">Courier storage</div>' +
            '<div class="cep-sub" ng-if="s.storage.boxes">{{ s.storage.boxes }} fitted cargo box{{ s.storage.boxes > 1 ? "es" : "" }}' +
              ' · {{ s.storage.capacity }} slots · {{ fmt.num(s.storage.kg) }} kg loaded</div>' +
            '<div class="cep-sub" ng-if="!s.storage.boxes">Starter bag · 1 slot. Fit a parcel cargo box in the parts editor to carry more.</div></div>' +
          '<div class="cep-card" ng-if="g.fuel"><div class="cep-keyval"><span class="cep-label">{{ g.fuel.unit === "kWh" ? "Battery" : "Fuel" }}</span>' +
              '<strong ng-if="!g.fuel.reading">{{ fmt.num(g.fuel.have) }} / {{ fmt.num(g.fuel.cap) }} {{ g.fuel.unit }}</strong></div>' +
            '<div class="cep-sub" ng-if="g.fuel.reading">Reading the gauge…</div>' +
            '<div ng-if="!g.fuel.reading">' +
              '<div class="cep-time" role="progressbar" aria-label="Fuel level" aria-valuemin="0" aria-valuemax="100" ng-attr-aria-valuenow="{{ fmt.int(g.fuel.share * 100) }}" ' +
                'ng-class="{warn: g.fuel.low && !g.fuel.empty, late: g.fuel.empty}"><i ng-style="{width: (g.fuel.share * 100) + \'%\'}"></i></div>' +
              '<div class="cep-sub">About {{ g.fuel.rangeKm }} km left · ' +
                '{{ g.fuel.per100 ? fmt.num(g.fuel.per100) + " " + g.fuel.unit + "/100 km over " + g.fuel.measuredKm + " km" : "average use shows after 5 km" }}</div>' +
              '<div class="cep-sub" ng-if="g.fuel.per100">Running cost about {{ fmt.num(g.fuel.costPerKm) }} Kč per km.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.free">Company fuel card: this vehicle refuels for free.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.empty" style="color:var(--tomato)">The tank is empty. Order a fuel delivery below.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.locked">This vehicle’s tank cannot be filled from the phone in this game version.</div>' +
              '<div ng-if="g.fuel.station"><div class="cep-name" style="white-space:normal;margin-top:6px">{{ g.fuel.station.name }}</div>' +
                '<div class="cep-sub">{{ g.fuel.station.at ? "You are at the pumps" : fmt.num(g.fuel.station.km) + " km away" }} · ' +
                  '{{ fmt.num(g.fuel.station.price) }} Kč per {{ g.fuel.unit }}</div></div>' +
              '<div class="cep-sub" ng-if="!g.fuel.station">No {{ g.fuel.unit === "kWh" ? "charger" : "fuel station" }} known nearby. The helper loads local stations.</div>' +
              '<button class="cep-btn go" ng-if="g.fuel.fill" ng-disabled="g.fuel.busy || g.fuel.locked || !(g.fuel.fill.canCost > 0 || g.fuel.free)" ng-click="gdo(\'refuel\')">' +
                '{{ g.fuel.busy ? "Refuelling…" : (g.fuel.free ? "Fill up" : (g.fuel.fill.afford ? "Fill up · " + fmt.money(g.fuel.fill.cost) : ' +
                  '(g.fuel.fill.canCost > 0 ? "Buy " + g.fuel.fill.units + " · " + fmt.money(g.fuel.fill.canCost) : "Not enough money"))) }}</button>' +
              '<button class="cep-sm ghost" ng-if="g.fuel.station && !g.fuel.station.at" ng-disabled="g.busy" ng-click="gdo(\'fuelGps\')">Route to this station</button>' +
              '<button class="cep-sm ghost" ng-if="g.fuel.delivery && (!g.fuel.station.at || !g.fuel.fill || g.fuel.fill.canCost <= 0)" ng-disabled="g.fuel.busy || g.fuel.locked" ng-click="confirmDelivery()">' +
                '{{ deliveryAsk ? "Confirm · " + fmt.money(g.fuel.delivery.cost) : "Fuel delivery here · " + g.fuel.delivery.units + " for " + fmt.money(g.fuel.delivery.cost) }}</button>' +
            '</div></div>' +
          '<div class="cep-card" ng-if="!g.car"><div class="cep-label">Your car</div><div class="cep-name" style="font-size:17px">No active car</div>' +
            '<div class="cep-sub">Choose a parked car in My cars or buy one in Used cars.</div></div>' +
          '<button class="cep-btn" ng-if="g.car && !g.own" ng-click="gdo(\'bring\')">Bring my car</button>' +
          '<div class="cep-row"><button class="cep-btn" ng-click="openFleet()">My cars</button>' +
            '<button class="cep-btn" ng-click="openCars()">Used cars</button></div>' +
          '<div class="cep-li" ng-if="g.own"><div><div class="cep-name">Damage</div>' +
            '<small>{{ g.repair > 0 ? "About " + fmt.hrs(g.repairHours) + " of deliveries. Repair here, or the menu repair goes on your debt" : "The car is in one piece" }}</small></div>' +
            '<button class="cep-sm go" ng-disabled="!(g.repair > 0)" ng-click="gdo(\'repair\')">{{ g.repair > 0 ? "Repair " + fmt.money(g.repair) : "No damage" }}</button></div>' +
          '<div class="cep-li" ng-if="g.debt > 0" style="box-shadow:inset 0 0 0 1.5px var(--tomato)"><div><div class="cep-name" style="color:var(--tomato)">Debt {{ fmt.money(g.debt) }}</div>' +
            '<small>{{ g.debtShare * 100 }} % of each delivery pays it. No buying until it is paid.</small></div>' +
            '<button class="cep-sm" ng-disabled="!(g.money > 0)" ng-click="gdo(\'paydebt\')">Pay</button></div>' +
          '<button class="cep-btn" ng-if="g.own && !g.loaner" ng-click="gdo(\'openParts\')">Parts shop</button>' +
          '<button class="cep-sm ghost" ng-if="g.own && !g.loaner" ng-click="confirmSell()">{{ sellAsk ? "Sure? Sell for " + fmt.money(g.sellPrice) : "Sell my car (" + fmt.money(g.sellPrice) + ")" }}</button>' +
          '<div class="cep-label" ng-if="g.spares.length">Spare parts</div>' +

          '<div class="cep-li" ng-repeat="p in g.spares"><div class="cep-name">{{ p.name }}{{ p.count > 1 ? " ×" + p.count : "" }}</div>' +
            '<button class="cep-sm ghost" ng-click="gdo(\'sell\', p.part)">Sell {{ fmt.money(p.price) }}</button></div>' +
          '<button class="cep-sm ghost" ng-click="gdo(\'bring\')" ng-if="g.own">Respawn my car with its parts</button>' +
          '<button class="cep-sm ghost" ng-click="gdo(\'probe\')">Check the parts system (for bug reports)</button>' +
        '</div>' +
        '<div ng-if="g.parts" class="cep-scroll">' +
          '<div class="cep-label">Parts checkout</div>' +
          '<div class="cep-sub">Confirm before driving. Unconfirmed changes are discarded if you drive away.</div>' +
          '<div class="cep-sub" ng-if="!g.parts.blocked">BeamNG’s Apply button previews your choices. Confirm them here to keep the parts.</div>' +
          '<div class="cep-sub" ng-if="g.parts.error">{{ g.parts.error }}</div>' +
          '<button class="cep-sm ghost" ng-if="g.parts.error" ng-click="retryGarage()">Retry checkout</button>' +
          '<div class="cep-sub" ng-if="g.parts.items && !g.parts.items.length">No parts added or removed.</div>' +
          '<div class="cep-li" ng-repeat="p in g.parts.items track by p.part"><div style="min-width:0">' +
            '<div class="cep-name" style="white-space:normal">{{ p.name }}</div><small>' +
              '<span ng-if="p.buy">Buy ×{{ p.buy }} </span><span ng-if="p.fit">Fit spare ×{{ p.fit }} </span>' +
              '<span ng-if="p.keep">Keep as spare ×{{ p.keep }}</span></small></div>' +
            '<b ng-if="p.cost">{{ fmt.money(p.cost) }}</b></div>' +
          '<div class="cep-label" ng-if="g.parts.items">Total {{ fmt.money(g.parts.cost) }}</div>' +
          '<button class="cep-btn go" ng-disabled="!g.parts.canBuy" ng-click="gdo(\'buyParts\', g.parts.revision)">' +
            '{{ g.parts.cost > 0 ? "Buy all for " + fmt.money(g.parts.cost) : "Keep changes" }}</button>' +
          '<button class="cep-btn ghost" ng-click="gdo(\'cancelParts\')">Discard preview and restore car</button>' +
          '<button class="cep-sm ghost" ng-if="!g.parts.blocked" ng-click="gdo(\'openParts\')">Back to parts picker</button>' +
        '</div>' +
        '<div ng-if="g.fleet && gview === \'fleet\' && !g.preview && !g.parts" class="cep-scroll">' +
          '<button class="cep-sm ghost" ng-click="goHome()">‹ Back to Garage</button>' +
          '<div class="cep-label">My cars</div>' +
          '<div class="cep-card" ng-if="g.car"><div class="cep-name">{{ g.car }}</div>' +
            '<div class="cep-sub">Active car · {{ fmt.int(g.km) }} km</div></div>' +
          '<div class="cep-card"><div class="cep-label">Drivers</div>' +
            '<div class="cep-sub" ng-if="!g.fleet.unlocked">Only a firm with a headquarters hires drivers. See Career → Firm.</div>' +
            '<div class="cep-sub" ng-if="g.fleet.unlocked">Hire a driver for a parked car. Each earns {{ fmt.money(g.fleet.pay) }} per {{ g.fleet.shiftMinutes }} minutes of active play.</div>' +
            '<div class="cep-sub" ng-if="g.fleet.earned > 0">Total earned by drivers · {{ fmt.money(g.fleet.earned) }}</div></div>' +
          '<div class="cep-sub" ng-if="!g.fleet.cars.length">Buy another car and keep your current one to build your fleet.</div>' +
          '<div class="cep-sub" ng-if="g.busy && g.fleet.cars.length">Finish your current orders before switching cars.</div>' +
          '<div class="cep-card" ng-repeat="v in g.fleet.cars track by v.id">' +
            '<div class="cep-name" style="white-space:normal">{{ v.name }}</div>' +
            '<div class="cep-sub">{{ fmt.int(v.km) }} km · {{ v.driver ? "Assigned to driver" : "Parked" }}</div>' +
            '<div class="cep-sub" ng-if="v.storageSlots">{{ v.boxCount ? v.boxCount + " fitted boxes" : "Starter bag" }} · {{ v.storageSlots }} slots</div>' +
            '<div class="cep-sub" ng-if="!v.storageSlots">Storage checked when driven.</div>' +
            '<div class="cep-sub" ng-if="v.repair > 0">Needs {{ fmt.money(v.repair) }} in repairs before hiring.</div>' +
            '<div class="cep-sub" ng-if="v.driver">Earned {{ fmt.money(v.driver.earned) }} · next payout in {{ v.driver.nextMin }} min</div>' +
            '<div class="cep-row" style="margin-top:6px">' +
              '<button class="cep-sm go" ng-if="!v.driver" ng-disabled="g.busy" ng-click="gdo(\'switchCar\', v.id)">Drive</button>' +
              '<button class="cep-sm" ng-if="g.fleet.unlocked && !v.driver && !v.loaner" ng-disabled="v.repair > 0 || g.debt > 0 || g.money < g.fleet.hireFee" ' +
                'ng-click="gdo(\'hireDriver\', v.id)">Hire · {{ fmt.money(g.fleet.hireFee) }}</button>' +
              '<button class="cep-sm ghost" ng-if="v.driver" ng-click="gdo(\'releaseDriver\', v.id)">Release driver</button></div>' +
          '</div></div>' +
        '<div ng-if="g && g.started && gview === \'cars\' && !g.parts" class="cep-scroll">' +
          '<div class="cep-row"><button class="cep-sm ghost" ng-click="goHome()">‹ Back</button>' +
            '<input class="cep-input" placeholder="Find a car" ng-model="cf.text">' +
            '<button class="cep-sm" ng-click="loadCars()">Search</button></div>' +
          '<label class="cep-sub" ng-if="market.tradeIn > 0"><input type="checkbox" ng-model="purchase.keep"> Keep my current car</label>' +
          '<div class="cep-sub" ng-if="market.tradeIn > 0 && !purchase.keep">Trade-in credit · {{ fmt.money(market.tradeIn) }}</div>' +
          '<div class="cep-sub" ng-if="market.debt > 0" style="color:var(--tomato)">Pay your debt first ({{ fmt.money(market.debt) }}).</div>' +
          '<div class="cep-sub" ng-if="!cars.length">No cars for sale right now. New ones come every few minutes.</div>' +
          '<div class="cep-li" ng-repeat="c in cars" style="align-items:flex-start;cursor:default"><div style="flex:1">' +
            '<div class="cep-name" style="white-space:normal">{{ c.name }} <span class="cep-adr" ng-if="c.isNew" style="background:var(--ok)">NEW</span></div>' +
            '<small>{{ fmt.int(c.km) }} km · condition {{ fmt.cond(c.condition) }} · gone in {{ fmt.left(c.leftMin) }}' +
              '<span ng-if="c.missing !== undefined && c.missing !== null"> · {{ c.missing }} parts missing</span><br>about {{ fmt.hrs(c.hours) }} of deliveries</small>' +
            '<div class="cep-time" style="height:4px;margin-top:5px" ng-class="{warn: c.condition < 0.6, late: c.condition < 0.35}"><i ng-style="{width: (c.condition * 100) + \'%\'}"></i></div></div>' +
            '<div style="display:flex;flex-direction:column;gap:5px;align-items:stretch">' +
            '<button class="cep-sm" ng-class="{ghost: carPrice(c) > market.money}" ng-click="buyCar(c.id)">' +
              'Buy {{ fmt.money(carPrice(c)) }}</button>' +
            '<button class="cep-sm ghost" ng-click="look(c.id)">Look at it</button></div></div>' +
        '</div>' +
      '</div>' +

      // settings
      '<div class="cep-body" ng-if="tab === \'settings\' && s.screen !== \'resume\'">' +
        '<div class="cep-center" ng-if="st.reviewingParts">' +
          '<div class="cep-sub">Confirm or cancel your parts preview in Garage to change these settings.</div>' +
          '<button class="cep-btn go" ng-click="setTab(\'garage\')">Review parts</button></div>' +
        '<div class="cep-scroll" ng-if="!st.reviewingParts">' +
        '<div class="cep-label">Mode</div>' +
        '<div class="cep-row"><button class="cep-btn" ng-class="{go: st.mode === \'courier\', ghost: st.mode !== \'courier\'}" ' +
          'ng-disabled="!st.canSwitch" ng-click="sdo(\'mode\', \'courier\')">Courier</button>' +
          '<button class="cep-btn" ng-class="{go: st.mode === \'trucking\', ghost: st.mode !== \'trucking\'}" ' +
          'ng-disabled="!st.canSwitch" ng-click="sdo(\'mode\', \'trucking\')">Trucking</button></div>' +
        '<div class="cep-sub" ng-if="!st.canSwitch">Finish the order to switch.</div>' +
        '<div class="cep-label">Orders</div>' +
        '<div class="cep-li" ng-repeat="it in st.items" style="cursor:default"><div class="cep-name">{{ it.label }}</div>' +
          '<div class="cep-step2"><button class="cep-sm ghost" ng-click="sdo(\'step\', it.key, -1)">−</button>' +
          '<b>{{ fmt.num(it.value) }} {{ it.unit }}</b><button class="cep-sm ghost" ng-click="sdo(\'step\', it.key, 1)">+</button></div></div>' +
        '<div class="cep-li" ng-if="st.mode === \'courier\'" ng-click="sdo(\'autoReach\', !st.autoReach)">' +
          '<div><div class="cep-name">Look further in the countryside</div><small>Wider search where restaurants are few</small></div>' +
          '<b>{{ st.autoReach ? "On" : "Off" }}</b></div>' +
        '<div class="cep-li" ng-if="st.cameras" ng-click="sdo(\'cameras\', !st.cameras.on)">' +
          '<div><div class="cep-name">Speed cameras</div><small>{{ !st.cameras.on ? "Off: no fines, no stars lost" : ' +
            '(st.cameras.helper === "off" ? "Needs the Cargo Earth helper 0.4 running" : ' +
            '(st.cameras.helper === "loading" ? "Loading cameras around you…" : ' +
            '(st.cameras.helper === "failed" ? "Could not load cameras; trying again" : st.cameras.known + " real cameras around you (OpenStreetMap)"))) }}</small></div>' +
          '<b>{{ st.cameras.on ? "On" : "Off" }}</b></div>' +
        '<button class="cep-sm ghost" ng-click="sdo(\'reset\')">Back to the defaults</button>' +
        '<button class="cep-sm ghost" ng-if="st.canPause" ng-click="sdo(\'pause\')">Save and pause career</button>' +
        '<button class="cep-sm ghost" ng-click="sdo(\'window\')">{{ st.window ? "Close" : "Open" }} the debug window</button>' +
      '</div></div>' +

      '<div class="cep-msg" role="alert" ng-if="s.saveError">{{ s.saveError }}</div>' +
      '<div class="cep-msg" role="alert" ng-if="s.flash">Speed camera: {{ s.flash.speed }} km/h, limit {{ s.flash.limit }}. Fine {{ fmt.money(s.flash.fine) }}' +
        '<span ng-if="s.flash.owed > 0"> ({{ fmt.money(s.flash.owed) }} added to your debt)</span>' +
        '<span ng-if="s.flash.stars > 0">. One star off the order on board</span>.</div>' +
      '<div class="cep-impact-note" ng-if="s.camera && !s.flash">Speed camera in {{ s.camera.m }} m · limit {{ s.camera.limit }} km/h</div>' +
      '<div class="cep-impact-note" ng-if="s.companyDamage > 0">Vehicle damage recorded. Check Work / Companies for the reputation impact.</div>' +
      '<div class="cep-foot"><div class="cep-storage cep-storage-wrap" ng-if="tab === \'orders\' && workView === \'deliveries\' && s.storage">' +
        '<div class="cep-storage-line">' +
          '<span ng-if="s.storage.checking">Checking cargo storage…</span>' +
          '<span ng-if="s.storage.unavailable">Get in your delivery car to check storage.</span>' +
          '<span ng-if="s.storage.capacity">{{ s.storage.boxes ? "Boxes" : "Starter bag" }} · ' +
            '{{ s.storage.used }} used · {{ s.storage.reserved }} reserved · {{ s.storage.free }} free</span>' +
          '<button type="button" class="cep-storage-help" aria-label="Why fit cargo boxes?" ' +
            'ng-attr-aria-expanded="{{ storageHelpOpen ? \'true\' : \'false\' }}" ng-click="toggleStorageHelp()" ' +
            'title="The starter bag holds one small order. Cargo boxes make room for bigger orders and batches.">?</button></div>' +
        '<div class="cep-storage-tip" ng-if="storageHelpOpen" role="region" aria-label="Cargo box help">' +
          '<strong>Why fit a cargo box?</strong>' +
          '<p>Your starter bag holds one small order. Family meals need 2 free slots in one box. Grocery runs need 4 and the Cargo Earth helper.</p>' +
          '<p>Reserved space is for accepted orders. Used space is for orders on board.</p>' +
          '<p>Fit a parcel box in <strong>Garage → Parts shop</strong>, then confirm it on the phone.</p></div>' +
        '<div class="cep-storage warn" ng-if="s.storage.overflow">Saved orders exceed available space.</div></div>' +
        'Balance {{ fmt.money(s.money) }}<span ng-if="s.repair > 0" style="color:var(--warn)"> · damage {{ fmt.money(s.repair) }}</span>' +
        '<span ng-if="s.fuel.low" ng-style="{color: s.fuel.empty ? \'var(--tomato)\' : \'var(--warn)\'}"> · {{ s.fuel.empty ? "out of fuel" : "fuel " + s.fuel.pct + " %" }}</span>' +
        '<span ng-if="s.debt > 0" style="color:var(--tomato)"> · debt {{ fmt.money(s.debt) }}</span></div>' +
      '<nav class="cep-tabs" aria-label="Phone sections" ng-if="s.screen !== \'resume\'">' +
        '<button ng-class="{on: tab === \'orders\'}" ng-attr-aria-current="{{ tab === \'orders\' ? \'page\' : undefined }}" ng-click="setTab(\'orders\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="18" height="15" rx="2"/><path d="M8 6V3h8v3M3 11h18M10 11v3h4v-3"/></svg>Work</button>' +
        '<button ng-class="{on: tab === \'garage\'}" ng-attr-aria-current="{{ tab === \'garage\' ? \'page\' : undefined }}" ng-click="setTab(\'garage\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 21V8l9-5 9 5v13M7 21V11h10v10M7 15h10M7 18h10"/></svg>Garage</button>' +
        '<button ng-class="{on: tab === \'home\'}" ng-attr-aria-current="{{ tab === \'home\' ? \'page\' : undefined }}" ng-click="setTab(\'home\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 11l9-8 9 8M5 10v11h5v-7h4v7h5V10"/></svg>Home</button>' +
        '<button ng-class="{on: tab === \'career\'}" ng-attr-aria-current="{{ tab === \'career\' ? \'page\' : undefined }}" ng-click="setTab(\'career\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 21V13h4v8M10 21V8h4v13M15 21V3h4v18"/></svg>Career</button>' +
        '<button ng-class="{on: tab === \'settings\'}" ng-attr-aria-current="{{ tab === \'settings\' ? \'page\' : undefined }}" ng-click="setTab(\'settings\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="var(--card)"/><circle cx="15" cy="12" r="2" fill="var(--card)"/><circle cx="9" cy="18" r="2" fill="var(--card)"/></svg>Settings</button></nav>' +
      '</div></div></div>',
    replace: true,
    link: function (scope, element) {
      'use strict'
      scope.s = null
      scope.cancelAsk = false
      scope.fmt = {
        money: money, dist: dist, clock: clock, km: km, mins: mins,
        remaining: function (seconds) { return clock(Math.abs(seconds)) },
        short: function (n) { n = Math.round(n || 0); return Math.abs(n) >= 10000 ? (Math.round(n / 100) / 10).toLocaleString('cs-CZ') + 'k' : n.toLocaleString('cs-CZ') }
      }
      scope.here = function () { var a = scope.s && scope.s.active; return a ? (a.phase === 'toPickup' ? a.from : a.to) : {} }
      scope.near = function () { var a = scope.s && scope.s.active; return a && a.distM !== null && a.distM !== undefined && a.distM <= a.arriveM }
      scope.timePct = function () {
        var a = scope.s && scope.s.active
        if (!a) return 0
        return Math.max(2, Math.min(100, 100 * a.leftS / Math.max(1, a.minutes * 60)))
      }
      var busy = false, destroyed = false, lastPoll = -Infinity
      function apply(r) {
        if (destroyed) return
        scope.$evalAsync(function () {
          if (destroyed) return
          scope.s = r || null
          if (!r || r.screen !== 'active') scope.cancelAsk = false
        })
      }
      function poll() {
        if (busy || destroyed) return
        var now = Date.now()
        if ((scope.min || (scope.s && scope.s.hidden)) && now - lastPoll < 2000) return
        lastPoll = now
        busy = true
        bngApi.engineLua(STATE, function (r) { busy = false; apply(r) })
      }
      scope.act = function (name, value) {
        scope.cancelAsk = false
        var arg = value === undefined ? '' : ', ' + bngApi.serializeToLua(value)
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneAction("' + name + '"' + arg + ') or nil', apply)
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
      scope.min = false
      scope.storageHelpOpen = false
      scope.career = null
      scope.places = null
      scope.placeSearch = { text: '' }
      scope.workView = 'deliveries'
      scope.careerView = 'progress'
      scope.endCompanyAsk = false
      scope.g = null; scope.gview = 'home'; scope.cars = []; scope.st = null
      scope.cf = { text: '' }
      scope.purchase = { keep: true }
      scope.fmt.int = function (v) { return Math.round(v || 0).toLocaleString('cs-CZ') }
      scope.fmt.freight = function (load) {
        return scope.fmt.int(load.amount) + (load.kind === 'parcel' ? ' slots' : ' L') + ' · ' + scope.fmt.int(load.kg) + ' kg'
      }
      var CATS = {delivery: 'Delivery', company_wages: 'Company wages', drivers: 'Drivers', garage: 'Garage', parts: 'Parts',
        cancel_fee: 'Cancel fee', adjustment: 'Other', fuel: 'Fuel', fine: 'Speeding fine', firm: 'Firm'}
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
      scope.fmt.cat = function (c) { return CATS[c] || c || 'Other' }
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
          if (!destroyed) scope.$evalAsync(function () { cb(r) })
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
      scope.toggleStorageHelp = function () { scope.storageHelpOpen = !scope.storageHelpOpen }
      scope.fold = function (v) { scope.min = v; scope.storageHelpOpen = false }
      scope.goHome = function () { scope.gview = 'home'; loadGarage() }
      scope.setTab = function (t) {
        if (['orders', 'garage', 'home', 'career', 'settings'].indexOf(t) === -1) return
        var changed = scope.tab !== t
        scope.tab = t
        scope.storageHelpOpen = false
        scope.endCompanyAsk = false
        scope.sellAsk = false
        scope.deliveryAsk = false
        if (t === 'garage') { if (changed) scope.gview = 'home'; loadGarage() }
        if (t === 'career') loadCareer()
        if (t === 'home' || (t === 'orders' && scope.workView === 'companies')) loadPlaces()
        if (t === 'settings') loadSettings()
      }
      scope.sectionTitle = function () {
        return {orders: 'Work', garage: 'Garage', home: 'Home garage', career: 'Career', settings: 'Settings'}[scope.tab]
      }
      scope.setWorkView = function (view) {
        if (view !== 'deliveries' && view !== 'companies') return
        scope.workView = view
        scope.endCompanyAsk = false
        scope.storageHelpOpen = false
        if (view === 'companies') loadPlaces()
      }
      scope.setCareerView = function (view) {
        if (view !== 'progress' && view !== 'money' && view !== 'map' && view !== 'firm') return
        scope.careerView = view
        loadCareer()
      }
      scope.showLiveShortcut = function () {
        var s = scope.s
        if (!s || s.screen === 'resume') return false
        if (s.active || s.screen === 'incoming') return scope.tab !== 'orders' || scope.workView !== 'deliveries'
        return !!s.company && (scope.tab !== 'orders' || scope.workView !== 'companies')
      }
      scope.liveTitle = function () {
        var s = scope.s || {}
        if (s.screen === 'incoming') return 'New delivery offer'
        if (s.active) return s.active.phase === 'toPickup' ? 'Continue to pickup' : 'Continue delivery'
        return 'Active company contract'
      }
      scope.liveDetail = function () {
        var s = scope.s || {}, stop = scope.here()
        return s.screen === 'incoming' ? 'Review the offer in Work' : (stop.name || s.company || '')
      }
      scope.openLiveWork = function () {
        if (scope.s && (scope.s.active || scope.s.screen === 'incoming')) {
          scope.workView = 'deliveries'; scope.setTab('orders')
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
      scope.loadCars = function () { lua('garageDealer', [scope.cf.text || ''], function (r) { scope.market = r || {}; scope.cars = (r && r.cars) || [] }) }
      scope.carPrice = function (car) { return car.price - (scope.purchase.keep ? 0 : (scope.market.tradeIn || 0)) }
      scope.buyCar = function (id) { scope.gdo('buyListing', id, scope.purchase.keep || !scope.market.tradeIn) }
      scope.look = function (id) { scope.gdo('preview', id, scope.purchase.keep || !scope.market.tradeIn); scope.gview = 'home' }
      scope.openCars = function () { scope.gview = 'cars'; scope.loadCars() }
      scope.openFleet = function () { scope.gview = 'fleet'; loadGarage() }
      scope.pdo = function (name, value) {
        var args = [name]
        if (value !== undefined) args.push(value)
        lua('placesDo', args, function (r) { scope.places = r; poll() })
      }
      scope.openCompany = function () { scope.workView = 'companies'; scope.setTab('orders') }
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
      scope.closeHq = function () { scope.hqOpen = false; if (scope.tab === 'career') loadCareer() }
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
      // moving costs money: the first press asks, the second moves
      scope.moveHq = function () {
        if (scope.moveAsk) { scope.hdo('setHq'); return }
        scope.moveAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.moveAsk = false }) }, 5000)
      }
      // The headquarters covers the whole screen, so it lives on the page body, outside the phone's own box.
      var overlay = element && element[0] && element[0].querySelector && element[0].querySelector('.cehq')
      if (overlay && typeof document !== 'undefined' && document.body) {
        document.body.appendChild(overlay)
        scope.$on('$destroy', function () { if (overlay.parentNode) overlay.parentNode.removeChild(overlay) })
      }
      scope.sdo = function (name, a, b) {
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        lua('settingsDo', args, function (r) { scope.st = r })
      }
      // The editor can remount the phone. Open straight to checkout while a preview is active.
      scope.$watch('s.screen', function (v) {
        scope.storageHelpOpen = false
        if (v === 'incoming' || v === 'resume') { scope.min = false; scope.workView = 'deliveries'; scope.tab = 'orders' }
        if (v === 'parts') { scope.min = false; scope.setTab('garage') }
      })
      var slow = setInterval(function () {
        if (scope.hqOpen) loadHq()
        if (scope.min || (scope.s && (scope.s.hidden || scope.s.screen === 'resume'))) return
        if (scope.tab === 'garage') loadGarage()
        if (scope.tab === 'career') loadCareer()
        if (scope.tab === 'home' || (scope.tab === 'orders' && scope.workView === 'companies')) loadPlaces()
        if (scope.tab === 'settings') loadSettings()
      }, 1000)
      scope.$on('$destroy', function () { clearInterval(slow) })
      var timer = setInterval(poll, 250)
      poll()
      scope.$on('$destroy', function () { destroyed = true; clearInterval(timer) })
    }
  }
}]);
