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
// A bus line's number badge: the line's own colours from the map data (OSM colour / text_colour). Light lines (white,
// yellow) need dark text, so a missing or unreadable text colour is replaced by black or white, whichever reads better.
var cargoEarthBadge = (function () {
  var NAMED = {white: '#ffffff', black: '#000000', red: '#ff0000', green: '#008000', blue: '#0000ff', yellow: '#ffff00',
    orange: '#ffa500', purple: '#800080', pink: '#ffc0cb', brown: '#a52a2a', grey: '#808080', gray: '#808080',
    silver: '#c0c0c0', gold: '#ffd700', cyan: '#00ffff', magenta: '#ff00ff', lime: '#00ff00', navy: '#000080',
    maroon: '#800000', olive: '#808000', teal: '#008080', aqua: '#00ffff', fuchsia: '#ff00ff', beige: '#f5f5dc',
    lightblue: '#add8e6', lightgreen: '#90ee90', darkblue: '#00008b', darkgreen: '#006400', darkred: '#8b0000', violet: '#ee82ee'}
  var cache = {}
  // '#abc', '#aabbcc', 'abc123' or a colour name -> [r, g, b] 0-255, or null when it is not a colour
  function rgb(c) {
    if (typeof c !== 'string') return null
    c = c.split(';')[0].trim().toLowerCase().replace(/[\s_-]/g, '')
    if (!c) return null
    if (NAMED[c]) c = NAMED[c]
    var m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/.exec(c)
    if (!m) return null
    var h = m[1].length === 3 ? m[1].replace(/./g, '$&$&') : m[1]
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
  }
  function hex(v) { return '#' + v.map(function (n) { return (n < 16 ? '0' : '') + n.toString(16) }).join('') }
  function lum(v) { // WCAG relative luminance
    var l = v.map(function (n) { n /= 255; return n <= 0.03928 ? n / 12.92 : Math.pow((n + 0.055) / 1.055, 2.4) })
    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
  }
  function contrast(a, b) { var x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05) }
  return function (colour, text) {
    var key = colour + '|' + text
    if (cache[key]) return cache[key]
    var bg = rgb(colour)
    if (!bg) return (cache[key] = {})
    var fg = rgb(text)
    if (!fg || contrast(bg, fg) < 3) fg = contrast(bg, [0, 0, 0]) >= contrast(bg, [255, 255, 255]) ? [17, 17, 17] : [255, 255, 255]
    var style = {background: hex(bg), color: hex(fg)}
    // a white badge on a white card would lose its edge
    if (lum(bg) > 0.8) style['box-shadow'] = 'inset 0 0 0 1px rgba(0,0,0,.35)'
    return (cache[key] = style)
  }
})()
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

// ---- The phone's OSM map: OpenStreetMap vector tiles (OpenFreeMap, OpenMapTiles schema) decoded and drawn on the
// phone's 2D canvas. The game's browser has no WebGL (GPU drawing is off) and cannot load from the web, so the tiles
// come through the Cargo Earth helper (/v1/osm/tile) and the phone draws them itself. Each z14 tile is cut into
// 512 px pieces drawn north-up once and kept; every frame only turns and places those pictures under the car.
var cargoEarthOsm = (function () {
  var Z = 14, PIECE = 512

  // Mapbox Vector Tile = protobuf: varints, length-delimited fields, fixed 32 / 64
  function Reader(buf) { this.b = buf; this.p = 0; this.dv = null }
  Reader.prototype.varint = function () {
    var b = this.b, v = 0, mul = 1, c
    do { c = b[this.p++]; v += (c & 0x7f) * mul; mul *= 128 } while (c >= 128 && this.p < b.length)
    return v
  }
  Reader.prototype.skip = function (wire) {
    if (wire === 0) this.varint()
    else if (wire === 1) this.p += 8
    else if (wire === 2) this.p += this.varint()
    else if (wire === 5) this.p += 4
    else throw new Error('bad tile')
  }
  Reader.prototype.view = function () {
    if (!this.dv) this.dv = new DataView(this.b.buffer, this.b.byteOffset, this.b.byteLength)
    return this.dv
  }
  function utf8(b, s, e) {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(b.subarray(s, e))
    var out = ''
    for (var i = s; i < e;) {
      var c = b[i++]
      if (c < 0x80) out += String.fromCharCode(c)
      else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (b[i++] & 0x3f))
      else if (c < 0xf0) { out += String.fromCharCode(((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f)) }
      else {
        var cp = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f)
        cp -= 0x10000
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff))
      }
    }
    return out
  }
  function zz(n) { return n % 2 === 1 ? -(n + 1) / 2 : n / 2 }

  // the layers and tags the phone draws
  var LAYERS = {water: 1, waterway: 1, landcover: 1, park: 1, landuse: 1, building: 1, transportation: 1, transportation_name: 1, poi: 1,
    housenumber: 1}
  var TAGS = {'class': 1, subclass: 1, name: 1, 'name:latin': 1, brunnel: 1, ref: 1, rank: 1, oneway: 1, housenumber: 1}

  function value(r, end) {
    var v = null
    while (r.p < end) {
      var key = r.varint(), f = key >> 3, w = key & 7
      if (f === 1 && w === 2) { var l = r.varint(); v = utf8(r.b, r.p, r.p + l); r.p += l }
      else if (f === 2 && w === 5) { v = r.view().getFloat32(r.p, true); r.p += 4 }
      else if (f === 3 && w === 1) { v = r.view().getFloat64(r.p, true); r.p += 8 }
      else if (f === 4 || f === 5) v = r.varint()
      else if (f === 6) v = zz(r.varint())
      else if (f === 7) v = r.varint() !== 0
      else r.skip(w)
    }
    return v
  }

  // geometry commands to parts: [[x, y, x, y, ...], ...] in tile units (0..extent), and the feature's box
  function geometry(r, end, f) {
    var parts = [], cur = null, x = 0, y = 0, cmd = 0, count = 0
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
    while (r.p < end) {
      if (count === 0) { var c = r.varint(); cmd = c & 7; count = c >> 3 }
      count--
      if (cmd === 1 || cmd === 2) {
        x += zz(r.varint()); y += zz(r.varint())
        if (cmd === 1) { cur = [x, y]; parts.push(cur) } else if (cur) cur.push(x, y)
        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y
      } else if (cmd === 7) {
        if (cur) cur.closed = true
      } else break
    }
    f.parts = parts
    f.box = [x0, y0, x1, y1]
  }

  function feature(r, end, keys, values) {
    var f = {type: 0, tags: {}, parts: null}
    var tags = null
    while (r.p < end) {
      var key = r.varint(), n = key >> 3, w = key & 7
      if (n === 2 && w === 2) {
        var te = r.varint() + r.p
        tags = []
        while (r.p < te) tags.push(r.varint())
      } else if (n === 3) f.type = r.varint()
      else if (n === 4 && w === 2) { var ge = r.varint() + r.p; geometry(r, ge, f); r.p = ge }
      else r.skip(w)
    }
    if (tags) for (var i = 0; i + 1 < tags.length; i += 2) if (TAGS[keys[tags[i]]]) f.tags[keys[tags[i]]] = values[tags[i + 1]]
    return f
  }

  function layer(r, end) {
    var name = '', extent = 4096, keys = [], values = [], raw = []
    while (r.p < end) {
      var key = r.varint(), n = key >> 3, w = key & 7
      if (n === 1 && w === 2) { var l = r.varint(); name = utf8(r.b, r.p, r.p + l); r.p += l }
      else if (n === 2 && w === 2) { var fl = r.varint(); raw.push([r.p, r.p + fl]); r.p += fl }
      else if (n === 3 && w === 2) { var kl = r.varint(); keys.push(utf8(r.b, r.p, r.p + kl)); r.p += kl }
      else if (n === 4 && w === 2) { var ve = r.varint() + r.p; values.push(value(r, ve)); r.p = ve }
      else if (n === 5) extent = r.varint()
      else r.skip(w)
    }
    if (!LAYERS[name]) return null
    var feats = []
    for (var i = 0; i < raw.length; i++) { r.p = raw[i][0]; feats.push(feature(r, raw[i][1], keys, values)) }
    return {name: name, extent: extent, features: feats}
  }

  // bytes (Uint8Array) -> { layerName: { extent, features: [{ type (1 point, 2 line, 3 polygon), tags, parts, box }] } }
  function decode(bytes) {
    var r = new Reader(bytes), out = {}
    while (r.p < bytes.length) {
      var key = r.varint(), n = key >> 3, w = key & 7
      if (n === 3 && w === 2) {
        var end = r.varint() + r.p
        var l = layer(r, end)
        r.p = end
        if (l) out[l.name] = l
      } else r.skip(w)
    }
    return out
  }

  // ---- looks
  var LOOK = {
    light: {bg: '#f2efe9', water: '#aad3df', green: '#d6e9c6', wood: '#c5dfb0', landuse: '#ebe6de', building: '#dcd6cd',
      rail: '#b5aca2', label: '#3d3833', waterLabel: '#3f7fa8', halo: '#ffffff', casing: '#c3b8aa', mwCasing: '#d0913a', number: '#8a8178', arrow: '#8a7f74',
      road: {motorway: '#f4b860', trunk: '#f7c978', primary: '#fbdc8f', secondary: '#fdf0b5', tertiary: '#ffffff', minor: '#ffffff',
        service: '#ffffff', track: '#e6dccb', path: '#d8cbb8'}},
    dark: {bg: '#1f1d1b', water: '#1c3346', green: '#233020', wood: '#20301c', landuse: '#262320', building: '#2f2b28',
      rail: '#4a4540', label: '#e6e0da', waterLabel: '#7fb3d8', halo: '#151412', casing: '#0f0e0d', mwCasing: '#0f0e0d', number: '#9a9188', arrow: '#b8afa5',
      road: {motorway: '#a2692a', trunk: '#8d6831', primary: '#7a6838', secondary: '#5f5848', tertiary: '#4f4943', minor: '#4a4540',
        service: '#423d38', track: '#3a3530', path: '#37322e'}}
  }
  // road width in metres and never thinner than this many pixels; drawn small first
  var ROADS = ['path', 'track', 'service', 'minor', 'tertiary', 'secondary', 'primary', 'trunk', 'motorway']
  var ROAD_W = {motorway: [16, 3], trunk: [14, 3], primary: [12, 2.5], secondary: [11, 2.5], tertiary: [10, 2], minor: [8, 2],
    service: [5, 1.5], track: [3.5, 1], path: [2, 1]}
  var ROAD_OF = {motorway: 'motorway', trunk: 'trunk', primary: 'primary', secondary: 'secondary', tertiary: 'tertiary',
    minor: 'minor', service: 'service', track: 'track', path: 'path', raceway: 'minor', busway: 'service', bus_guideway: 'service'}

  // z: the tile zoom (Z close up; the whole-route view asks coarser tiles)
  function tileMetres(lat, z) { return 40075016.686 * Math.cos(lat * Math.PI / 180) / Math.pow(2, z || Z) }
  function tileXY(lat, lon, z) {
    var n = Math.pow(2, z || Z), r = lat * Math.PI / 180
    return [(lon + 180) / 360 * n, (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n]
  }

  function hit(box, x0, y0, x1, y1) { return !(box[2] < x0 || box[0] > x1 || box[3] < y0 || box[1] > y1) }
  function path(ctx, parts) {
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i]
      ctx.moveTo(p[0], p[1])
      for (var j = 2; j + 1 < p.length; j += 2) ctx.lineTo(p[j], p[j + 1])
      if (p.closed) ctx.closePath()
    }
  }

  // one 512 px piece of a z14 tile, north up: k = how many times the tile is halved (piece = tile / 2^k)
  function renderPiece(canvas, data, k, px, py, look, mPerUnit, noBuildings, noArrows) {
    var ctx = canvas.getContext('2d')
    var ext = 4096
    for (var name in data) { ext = data[name].extent; break }
    var unit = ext / Math.pow(2, k)                     // tile units across the piece
    var s = PIECE / unit                                 // pixels per tile unit
    var x0 = px * unit, y0 = py * unit, x1 = x0 + unit, y1 = y0 + unit
    var pad = unit * 0.03
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.fillStyle = look.bg
    ctx.fillRect(0, 0, PIECE, PIECE)
    ctx.setTransform(s, 0, 0, s, -x0 * s, -y0 * s)
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    function fill(layerName, color, test) {
      var l = data[layerName]
      if (!l) return
      ctx.beginPath()
      var any = false
      for (var i = 0; i < l.features.length; i++) {
        var f = l.features[i]
        if (f.type !== 3 || !hit(f.box, x0 - pad, y0 - pad, x1 + pad, y1 + pad) || (test && !test(f.tags))) continue
        path(ctx, f.parts)
        any = true
      }
      if (any) { ctx.fillStyle = color; ctx.fill('evenodd') }
    }
    function greenOf(t) { return t['class'] === 'grass' || t['class'] === 'park' || t['class'] === 'recreation_ground' || t['class'] === 'meadow' }
    function woodOf(t) { return t['class'] === 'wood' || t['class'] === 'forest' }
    fill('landuse', look.landuse, function (t) { return t['class'] === 'residential' || t['class'] === 'commercial' || t['class'] === 'industrial' || t['class'] === 'retail' })
    fill('landcover', look.wood, woodOf)
    fill('landcover', look.green, greenOf)
    fill('park', look.green)
    fill('water', look.water)
    // rivers and streams
    var ww = data.waterway
    if (ww) {
      ctx.beginPath()
      for (var i = 0; i < ww.features.length; i++) {
        var f = ww.features[i]
        if (f.type === 2 && hit(f.box, x0 - pad, y0 - pad, x1 + pad, y1 + pad)) path(ctx, f.parts)
      }
      ctx.strokeStyle = look.water
      ctx.lineWidth = Math.max(1.5 / s, 4 / mPerUnit)
      ctx.stroke()
    }
    // buildings only close up (a piece of 400 m or less)
    if (k >= 2 && !noBuildings) fill('building', look.building)
    var tr = data.transportation
    if (!tr) return
    var byKind = {}
    var rail = []
    for (var j = 0; j < tr.features.length; j++) {
      var g = tr.features[j]
      if (g.type !== 2 || !hit(g.box, x0 - pad, y0 - pad, x1 + pad, y1 + pad)) continue
      var cls = g.tags['class']
      if (cls === 'rail' || cls === 'transit') { rail.push(g); continue }
      var kind = ROAD_OF[cls]
      if (!kind) continue
      if (g.tags.brunnel === 'tunnel' && kind !== 'motorway' && kind !== 'trunk') continue
      ;(byKind[kind] = byKind[kind] || []).push(g)
    }
    if (rail.length) {
      ctx.beginPath()
      for (var q = 0; q < rail.length; q++) path(ctx, rail[q].parts)
      ctx.strokeStyle = look.rail
      ctx.lineWidth = 1.5 / s
      ctx.stroke()
    }
    // casings first, then the fills, small roads under big ones
    for (var pass = 0; pass < 2; pass++) {
      for (var n = 0; n < ROADS.length; n++) {
        var kd = ROADS[n], list = byKind[kd]
        if (!list) continue
        var w = Math.max(ROAD_W[kd][1] / s, ROAD_W[kd][0] / mPerUnit)
        if (pass === 0 && (kd === 'path' || kd === 'track')) continue
        ctx.beginPath()
        for (var m = 0; m < list.length; m++) path(ctx, list[m].parts)
        ctx.strokeStyle = pass === 0 ? (kd === 'motorway' || kd === 'trunk' ? look.mwCasing : look.casing) : look.road[kd]
        ctx.lineWidth = pass === 0 ? w + 2 / s : w
        ctx.stroke()
      }
    }
    // one-way streets: small chevrons along them, close up only (motorways and main roads are one-way anyway)
    if (k < 2 || noArrows) return
    var gap = ONEWAY_GAP_M / mPerUnit, size = Math.max(4 / s, 2.6 / mPerUnit)   // about 2.6 m from the tip back
    ctx.beginPath()
    for (var ak in ONEWAY_KINDS) {
      var al = byKind[ak]
      if (!al) continue
      for (var ai = 0; ai < al.length; ai++) {
        var dirn = +al[ai].tags.oneway
        if (dirn !== 1 && dirn !== -1) continue
        for (var aj = 0; aj < al[ai].parts.length; aj++) chevrons(ctx, al[ai].parts[aj], dirn, gap, size)
      }
    }
    ctx.strokeStyle = look.arrow
    ctx.lineWidth = Math.max(1.5 / s, 0.8 / mPerUnit)
    ctx.stroke()
  }
  var ONEWAY_GAP_M = 70
  var ONEWAY_KINDS = {primary: 1, secondary: 1, tertiary: 1, minor: 1, service: 1}
  // chevrons every `gap` tile units along a line, pointing the way traffic goes (dirn -1: against the drawing)
  function chevrons(ctx, p, dirn, gap, size) {
    var run = gap / 2
    for (var i = 0; i + 3 < p.length; i += 2) {
      var dx = p[i + 2] - p[i], dy = p[i + 3] - p[i + 1], len = Math.sqrt(dx * dx + dy * dy)
      if (!len) continue
      var ux = dx / len * dirn, uy = dy / len * dirn
      while (run <= len) {
        var cx = p[i] + dx * run / len, cy = p[i + 1] + dy * run / len
        ctx.moveTo(cx - ux * size - uy * size, cy - uy * size + ux * size)
        ctx.lineTo(cx + ux * size * 0.6, cy + uy * size * 0.6)
        ctx.lineTo(cx - ux * size + uy * size, cy - uy * size - ux * size)
        run += gap
      }
      run -= len
    }
  }

  // One named line for the labels: its points (tile units) and its length. The name is written along the line,
  // letter by letter, so it follows bends.
  function lineOf(p, name, water, out, lat) {
    var len = 0
    for (var k = 0; k + 3 < p.length; k += 2) len += Math.sqrt(Math.pow(p[k + 2] - p[k], 2) + Math.pow(p[k + 3] - p[k + 1], 2))
    if (len < 60) return
    var r = {name: name, pts: p, len: len}
    if (water) r.water = true
    if (lat && lat !== name) r.lat = lat      // the Latin spelling, for the 'Latin names' switch
    out.push(r)
  }

  // street names: each named line, longest first (each frame writes a name once, along the part of a line that is
  // on the screen)
  function labelsOf(data) {
    var l = data.transportation_name, out = []
    for (var i = 0; l && i < l.features.length; i++) {
      var f = l.features[i]
      var name = f.tags.name || f.tags['name:latin'] || f.tags.ref
      if (f.type !== 2 || !name || f.tags['class'] === 'path' || f.tags['class'] === 'track') continue
      for (var j = 0; j < f.parts.length; j++) lineOf(f.parts[j], name, false, out, f.tags['name:latin'])
    }
    // rivers and canals by name, along their line (water names are drawn blue and slanted)
    var ww = data.waterway
    if (ww) {
      for (var wi = 0; wi < ww.features.length; wi++) {
        var wf = ww.features[wi], wname = wf.tags.name || wf.tags['name:latin']
        if (wf.type !== 2 || !wname) continue
        for (var wj = 0; wj < wf.parts.length; wj++) lineOf(wf.parts[wj], wname, true, out, wf.tags['name:latin'])
      }
    }
    out.sort(function (a, b) { return b.len - a.len })
    return out.slice(0, 300)
  }

  // places (OpenMapTiles poi layer): named businesses and landmarks, the most important of each tile first (rank),
  // without street furniture and the like. Each gets a dot coloured by kind and its name beside it.
  var POI_SKIP = {parking: 1, bicycle_parking: 1, information: 1, waste_basket: 1, gate: 1, lift_gate: 1, bollard: 1,
    toilets: 1, drinking_water: 1, recycling: 1, shelter: 1, swimming_pool: 1, pitch: 1, playground: 1, bench: 1,
    atm: 1, bus: 1, railway: 1, entrance: 1, garden: 1, brownfield: 1, cemetery: 1, park: 1}
  var POI_KIND = {
    food: ['restaurant', 'fast_food', 'cafe', 'bar', 'beer', 'ice_cream', 'bakery', 'pub'],
    shop: ['shop', 'grocery', 'clothing_store', 'alcohol_shop', 'butcher', 'hairdresser', 'car', 'bicycle', 'furniture',
      'jewelry', 'mobile_phone', 'books', 'florist', 'hardware', 'laundry', 'optician', 'shoes', 'toys', 'gift', 'music',
      'electronics', 'doityourself', 'garden_centre', 'pet', 'stationery', 'confectionery', 'deli', 'wine'],
    health: ['hospital', 'pharmacy', 'doctors', 'dentist', 'veterinary'],
    fuel: ['fuel', 'charging_station']
  }                                    // hotels, campsites and the rest show under Other
  var POI_OF = {}
  for (var pk in POI_KIND) for (var pi = 0; pi < POI_KIND[pk].length; pi++) POI_OF[POI_KIND[pk][pi]] = pk
  var POI_ORDER = {food: 0, shop: 1, fuel: 2, health: 3, other: 4}
  // house numbers (OpenMapTiles housenumber layer, z14 only): { n, x, y } in tile units
  function numbersOf(data) {
    var l = data.housenumber, out = []
    for (var i = 0; l && i < l.features.length && out.length < 2000; i++) {
      var f = l.features[i], n = f.tags.housenumber
      if (f.type !== 1 || n === undefined || n === null || !f.parts.length) continue
      n = String(n)
      out.push({n: n.length > 8 ? n.slice(0, 7) + '…' : n, x: f.parts[0][0], y: f.parts[0][1]})
    }
    return out
  }
  function shortName(n) { n = String(n); return n.length > 26 ? n.slice(0, 25) + '…' : n }
  function poisOf(data) {
    var l = data.poi, out = []
    if (!l) return out
    for (var i = 0; i < l.features.length; i++) {
      var f = l.features[i], c = f.tags['class']
      var name = f.tags.name || f.tags['name:latin']
      if (f.type !== 1 || !name || POI_SKIP[c] || !f.parts.length) continue
      var kind = POI_OF[c] || POI_OF[f.tags.subclass] || 'other'
      var lat = f.tags['name:latin']
      var pl = {name: shortName(name), kind: kind, x: f.parts[0][0], y: f.parts[0][1], rank: +f.tags.rank || 99}
      if (lat && lat !== name) pl.lat = shortName(lat)
      out.push(pl)
    }
    out.sort(function (a, b) { return a.rank - b.rank || POI_ORDER[a.kind] - POI_ORDER[b.kind] })
    return out.slice(0, 150)
  }

  // ---- tiles through the helper
  function TileMap(opts) {
    this.base = null
    this.tiles = {}          // 'x/y' -> { state: 'loading' | 'ok' | 'error', data, labels, at, used, why }
    this.pieces = {}         // 'x/y/k/px/py/dark' -> { canvas, used }
    this.drawn = 0           // time of the last frame drawn (its pieces stay in the cache)
    this.loading = 0
    this.ok = 0
    this.errors = 0
    this.failed = ''
    this.version = 0
    this.renderMs = 0
    this.lastError = ''
    this.make = (opts && opts.canvas) || function (w, h) {
      var c = document.createElement('canvas')
      c.width = w; c.height = h
      return c
    }
    this.xhr = (opts && opts.xhr) || function (url, done) {
      var x = new XMLHttpRequest()
      x.open('GET', url)
      x.responseType = 'arraybuffer'
      x.timeout = 20000
      x.onload = function () { done(x.status, x.response) }
      x.onerror = function () { done(0, null) }
      x.ontimeout = function () { done(0, null) }
      x.send()
    }
  }
  TileMap.MAX_TILES = 30
  TileMap.MAX_PIECES = 48
  TileMap.RETRY_MS = 30000
  TileMap.prototype.setBase = function (base) {
    if (base === this.base) return
    this.base = base
    this.failed = ''
    this.errors = 0
    for (var k in this.tiles) if (this.tiles[k].state === 'error') delete this.tiles[k]
  }
  TileMap.prototype.reset = function () { this.failed = ''; this.errors = 0; this.ok = 0; this.tiles = {}; this.pieces = {}; this.version++ }
  TileMap.prototype.fail = function (status, why) {
    this.errors++
    this.lastError = why
    if (this.ok === 0 && this.errors >= 3) {
      this.failed = status === 0 ? 'the helper did not answer (is it running?)'
        : status === 403 || status === 404 ? 'the helper is too old for the map: update it'
          : 'the helper could not get map tiles (' + why + ')'
    }
  }
  TileMap.prototype.want = function (x, y, now, z) {
    z = z || Z
    var key = (z === Z ? '' : z + ':') + x + '/' + y, t = this.tiles[key], me = this
    if (t) {
      t.used = now
      if (t.state !== 'error' || now - t.at < TileMap.RETRY_MS) return t
    }
    if (!this.base || this.loading >= 4) return t || null
    t = this.tiles[key] = {state: 'loading', at: now, used: now}
    this.loading++
    this.xhr(this.base + '?z=' + z + '&x=' + x + '&y=' + y, function (status, buf) {
      me.loading--
      t.at = Date.now()
      if (status === 200 && buf) {
        try {
          t.data = decode(new Uint8Array(buf))
          t.labels = labelsOf(t.data)
          t.pois = poisOf(t.data)
          t.numbers = numbersOf(t.data)
          t.state = 'ok'
          me.ok++
          me.errors = 0
          me.failed = ''
        } catch (e) { t.state = 'error'; me.fail(200, 'a broken tile') }
      } else {
        t.state = 'error'
        var why = 'HTTP ' + status
        try { if (buf) why = JSON.parse(utf8(new Uint8Array(buf), 0, buf.byteLength)).error || why } catch (e) {}
        me.fail(status, String(why).slice(0, 80))
      }
      me.version++
      me.trim()
    })
    return t
  }
  TileMap.prototype.trim = function () {
    var keys = Object.keys(this.tiles), me = this
    if (keys.length > TileMap.MAX_TILES) {
      keys.sort(function (a, b) { return me.tiles[a].used - me.tiles[b].used })
      for (var i = 0; i < keys.length - TileMap.MAX_TILES; i++) if (me.tiles[keys[i]].state !== 'loading') delete me.tiles[keys[i]]
    }
    var pk = Object.keys(this.pieces)
    if (pk.length > TileMap.MAX_PIECES) {
      pk.sort(function (a, b) { return me.pieces[a].used - me.pieces[b].used })
      // never the pieces this frame is showing (used now)
      for (var j = 0; j < pk.length - TileMap.MAX_PIECES; j++) if (me.pieces[pk[j]].used < me.drawn) delete me.pieces[pk[j]]
    }
  }

  // Draws the map under the car: view = { w, h, ox, oy, scale (px / m), ratio, lat, lon, heading }, dark.
  // Returns a projector (lat, lon) -> [x, y] in CSS pixels, and whether pieces are still missing (draw again soon).
  TileMap.prototype.draw = function (ctx, v, dark, now) {
    var look = LOOK[dark ? 'dark' : 'light'], opts = v.opts || {}, z = v.z || Z
    var tm = tileMetres(v.lat, z)
    var c = tileXY(v.lat, v.lon, z)
    var rad = v.heading * Math.PI / 180, cs = Math.cos(rad), sn = Math.sin(rad)
    var scale = v.scale, ox = v.ox, oy = v.oy, ratio = v.ratio || 1
    function E(tx) { return (tx - c[0]) * tm }
    function N(ty) { return -(ty - c[1]) * tm }
    function proj(lat, lon) {
      var t = tileXY(lat, lon, z), e = E(t[0]), n = N(t[1])
      return [ox + scale * (cs * e - sn * n), oy - scale * (sn * e + cs * n)]
    }
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    ctx.fillStyle = look.bg
    ctx.fillRect(0, 0, v.w, v.h)
    // pieces: halve the tile until a piece's pixels are about the screen's
    var k = Math.max(0, Math.min(3, Math.ceil(Math.log(scale * ratio * tm / PIECE) / Math.LN2)))
    var reach = Math.sqrt(Math.pow(Math.max(ox, v.w - ox), 2) + Math.pow(Math.max(oy, v.h - oy), 2)) / scale / tm   // in tiles
    // fewer, coarser pieces when the view would need more than the cache keeps (sharp screens, far zoom)
    while (k > 0 && Math.PI * Math.pow(reach * Math.pow(2, k) + 1.5, 2) > TileMap.MAX_PIECES) k--
    var n2 = Math.pow(2, k)
    var missing = false, budget = 2
    var q = tm / (PIECE * n2)                                // metres per piece pixel
    var labels = [], pois = [], numbers = []
    for (var tx = Math.floor(c[0] - reach); tx <= Math.floor(c[0] + reach); tx++) {
      for (var ty = Math.floor(c[1] - reach); ty <= Math.floor(c[1] + reach); ty++) {
        var t = this.want(tx, ty, now, z)
        if (!t || t.state !== 'ok') { missing = missing || !t || t.state === 'loading'; continue }
        for (var px = 0; px < n2; px++) {
          for (var py = 0; py < n2; py++) {
            var gx = tx + px / n2, gy = ty + py / n2
            // is this piece near enough the view? (its centre within reach plus half a piece diagonal)
            var dxp = gx + 0.5 / n2 - c[0], dyp = gy + 0.5 / n2 - c[1]
            if (Math.sqrt(dxp * dxp + dyp * dyp) > reach + 0.71 / n2) continue
            var key = (z === Z ? '' : z + ':') + tx + '/' + ty + '/' + k + '/' + px + '/' + py + '/' + (dark ? 1 : 0) +
              (opts.buildings === false ? 'n' : '') + (opts.oneway === false ? 'o' : '')
            var pc = this.pieces[key]
            if (!pc) {
              if (budget <= 0) { missing = true; continue }
              budget--
              var t0 = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now()
              pc = this.pieces[key] = {canvas: this.make(PIECE, PIECE), used: now}
              renderPiece(pc.canvas, t.data, k, px, py, look, (tm / 4096), opts.buildings === false, opts.oneway === false || z !== Z)
              this.renderMs = ((typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now()) - t0
            }
            pc.used = now
            var e0 = E(gx), n0 = N(gy)
            var a = scale * q * cs, b = -scale * q * sn
            ctx.setTransform(ratio * a, ratio * b, ratio * scale * q * sn, ratio * scale * q * cs,
              ratio * (ox + scale * (cs * e0 - sn * n0)), ratio * (oy - scale * (sn * e0 + cs * n0)))
            ctx.drawImage(pc.canvas, -0.5, -0.5, PIECE + 1, PIECE + 1)
          }
        }
        if (t.labels) for (var li = 0; li < t.labels.length; li++) labels.push([tx, ty, t.labels[li], t.data])
        if (t.pois) for (var pj = 0; pj < t.pois.length; pj++) pois.push([tx, ty, t.pois[pj], t.data])
        if (t.numbers) for (var nj = 0; nj < t.numbers.length; nj++) numbers.push([tx, ty, t.numbers[nj], t.data])
      }
    }
    this.drawn = now
    this.trim()
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
    return {proj: proj, missing: missing, labels: function () { drawLabels(ctx, labels, E, N, cs, sn, scale, ox, oy, v, look, tm, pois, opts, numbers) }}
  }

  // a screen segment a-b clipped to a box (Liang-Barsky): [t0, t1, x0, y0, x1, y1], or null when it misses it
  function clipTo(a, b, x0, y0, x1, y1) {
    var t0 = 0, t1 = 1, dx = b[0] - a[0], dy = b[1] - a[1]
    var pq = [[-dx, a[0] - x0], [dx, x1 - a[0]], [-dy, a[1] - y0], [dy, y1 - a[1]]]
    for (var c = 0; c < 4; c++) {
      var pp = pq[c][0], qq = pq[c][1]
      if (pp === 0) { if (qq < 0) return null; continue }
      var r = qq / pp
      if (pp < 0) { if (r > t1) return null; if (r > t0) t0 = r } else { if (r < t0) return null; if (r < t1) t1 = r }
    }
    return [t0, t1, a[0] + dx * t0, a[1] + dy * t0, a[0] + dx * t1, a[1] + dy * t1]
  }
  // a point on a screen polyline {xy, d} at distance t along it
  function pathAt(pl, t) {
    var d = pl.d, i = 1
    while (i < d.length - 1 && d[i] < t) i++
    var seg = d[i] - d[i - 1], f = seg > 0 ? Math.max(0, Math.min(1, (t - d[i - 1]) / seg)) : 0
    return [pl.xy[2 * i - 2] + (pl.xy[2 * i] - pl.xy[2 * i - 2]) * f, pl.xy[2 * i - 1] + (pl.xy[2 * i + 1] - pl.xy[2 * i - 1]) * f]
  }
  // Where a name goes along a screen polyline: the letters (char, x, y, angle) and dots along it for the overlap
  // test. It tries the middle first, then spots nearer the ends, and skips spots where the line bends too sharply
  // between letters. Names always read left to right.
  var LABEL_BEND = 0.5      // radians between two letters
  // scripts whose letters must not be drawn one by one (right to left, or joined / shaped): Hebrew, Arabic, Syriac,
  // Thaana, Indic, Thai, Lao, Tibetan, Myanmar, Khmer and the Arabic / Hebrew presentation forms
  var COMPLEX_SCRIPT = /[\u0590-\u08FF\u0900-\u0DFF\u0E00-\u0FFF\u1000-\u109F\u1780-\u17FF\uFB1D-\uFDFF\uFE70-\uFEFF]/
  function labelSpot(pl, name, tw, ctx, starts) {
    var L = pl.d[pl.d.length - 1], tries = starts || [0.5, 0.35, 0.65, 0.2, 0.8].map(function (f) { return L * f - tw / 2 })
    for (var q = 0; q < tries.length; q++) {
      var s0 = Math.max(2, Math.min(L - tw - 2, tries[q]))
      var a = pathAt(pl, s0), b = pathAt(pl, s0 + tw)
      if (COMPLEX_SCRIPT.test(name)) {     // right-to-left or joined letters: the whole name on a straight stretch
        var ca = Math.atan2(b[1] - a[1], b[0] - a[0]), clen = Math.sqrt(Math.pow(b[0] - a[0], 2) + Math.pow(b[1] - a[1], 2)), off = false
        for (var st = 6; st < tw && !off; st += 6) {
          var sp = pathAt(pl, s0 + st)
          off = clen > 0 && Math.abs((sp[0] - a[0]) * (b[1] - a[1]) - (sp[1] - a[1]) * (b[0] - a[0])) / clen > 3
        }
        if (off || clen < tw * 0.9) continue
        if (ca > Math.PI / 2) ca -= Math.PI
        if (ca < -Math.PI / 2) ca += Math.PI
        var wd = []
        for (var wt = 0; wt <= tw; wt += 12) wd.push(pathAt(pl, s0 + wt))
        wd.push(b)
        return {chars: [[name, (a[0] + b[0]) / 2, (a[1] + b[1]) / 2, ca]], dots: wd, start: tries[q]}
      }
      var flip = b[0] < a[0]               // the line runs right to left here: write from its far end
      var chars = [], at = 0, last = null, ok = true
      for (var c = 0; c < name.length; c++) {
        var cw = ctx.measureText(name[c]).width
        var t1 = flip ? s0 + tw - at : s0 + at, t2 = flip ? t1 - cw : t1 + cw
        var p1 = pathAt(pl, t1), p2 = pathAt(pl, t2), pm = pathAt(pl, (t1 + t2) / 2)
        var ang = Math.atan2(p2[1] - p1[1], p2[0] - p1[0])
        if (last !== null) {
          var dif = Math.abs(ang - last)
          if (dif > Math.PI) dif = 2 * Math.PI - dif
          if (dif > LABEL_BEND) { ok = false; break }
        }
        if (cw > 0) last = ang
        chars.push([name[c], pm[0], pm[1], ang])
        at += cw
      }
      if (!ok) continue
      var dots = []
      for (var t = 0; t <= tw; t += 12) dots.push(pathAt(pl, s0 + t))
      dots.push(pathAt(pl, s0 + tw))
      return {chars: chars, dots: dots, start: tries[q]}
    }
    return null
  }
  // Fixed spots for a name along its whole line, so it stays on its street while the map moves (it never slides
  // with the car): the line is cut into equal stretches of at least LABEL_STEP px, a name sits in the middle of one.
  // Only spots whose whole name fits the box count; the one the name had last time first, then the nearest the
  // middle of the screen.
  var LABEL_STEP = 180
  var labelMemo = {}, labelMemoSize = 0
  function anchoredStarts(pl, tw, box, memoKey) {
    var L = pl.d[pl.d.length - 1], n = Math.max(1, Math.floor(L / Math.max(LABEL_STEP, tw + 60))), out = []
    var mx = (box[0] + box[2]) / 2, my = (box[1] + box[3]) / 2
    for (var j = 0; j < n; j++) {
      var s0 = (j + 0.5) * L / n - tw / 2
      if (s0 < 2 || s0 + tw > L - 2) continue
      var inside = true
      for (var t = 0; t <= tw && inside; t += 8) {
        var p = pathAt(pl, s0 + Math.min(t, tw))
        inside = p[0] >= box[0] && p[0] <= box[2] && p[1] >= box[1] && p[1] <= box[3]
      }
      if (!inside) continue
      var c = pathAt(pl, s0 + tw / 2)
      out.push({s0: s0, j: j, d: (c[0] - mx) * (c[0] - mx) + (c[1] - my) * (c[1] - my)})
    }
    var was = labelMemo[memoKey]
    out.sort(function (a, b) { return (a.j === was ? -1e12 : a.d) - (b.j === was ? -1e12 : b.d) })
    return out.map(function (o) { return o.s0 })
  }
  function rememberLabel(memoKey, pl, tw, s0) {
    var L = pl.d[pl.d.length - 1], n = Math.max(1, Math.floor(L / Math.max(LABEL_STEP, tw + 60)))
    if (labelMemoSize > 600) { labelMemo = {}; labelMemoSize = 0 }
    if (labelMemo[memoKey] === undefined) labelMemoSize++
    labelMemo[memoKey] = Math.round((s0 + tw / 2) * n / L - 0.5)
  }

  function drawLabels(ctx, list, E, N, cs, sn, scale, ox, oy, v, look, tm, pois, opts, numbers) {
    opts = opts || {}
    ctx.font = '600 11px sans-serif'
    ctx.textAlign = 'center'
    ctx.textBaseline = 'middle'
    ctx.lineJoin = 'round'
    var placed = [[v.carX === undefined ? ox : v.carX, v.carY === undefined ? oy : v.carY, 16, 1]], count = 0, done = {}     // the car's arrow stays clear
    var labelFont = scale < POI_MIN_SCALE ? '600 10px sans-serif' : '600 11px sans-serif'   // a bit smaller far out
    // the screen box labels go in (clear of the banner on top and the speed at the bottom)
    var bx0 = 12, bx1 = v.w - 12, by0 = 100, by1 = v.h - 64
    // and never under the zoom buttons (bottom right) or the north and settings buttons (top left)
    var keepOut = [[v.w - 54, v.h - 106, v.w, v.h], [0, 0, 46, 152]]
    function under(x, y, r) {
      for (var u = 0; u < keepOut.length; u++) {
        var ko = keepOut[u]
        if (x + r > ko[0] && x - r < ko[2] && y + r > ko[1] && y - r < ko[3]) return true
      }
      return false
    }
    function scr(tx, ty, ux, uy, ext) {
      var e = E(tx + ux / ext), n = N(ty + uy / ext)
      return [ox + scale * (cs * e - sn * n), oy - scale * (sn * e + cs * n)]
    }
    for (var i = 0; i < list.length && count < 18; i++) {
      var tx = list[i][0], ty = list[i][1], lb = list[i][2]
      var lname = opts.latin && lb.lat || lb.name
      if (done[lname] || (lb.water ? opts.water === false : opts.streets === false)) continue
      var ext = 4096
      for (var nm in list[i][3]) { ext = list[i][3][nm].extent; break }
      ctx.font = (lb.water ? 'italic ' : '') + labelFont
      var tw = ctx.measureText(lname).width
      // the whole line on the screen (pixels, distances along it); skipped when none of it is in the box
      var pts = lb.pts, prev = scr(tx, ty, pts[0], pts[1], ext), full = {xy: [prev[0], prev[1]], d: [0]}, seen = false
      for (var k = 2; k + 1 < pts.length; k += 2) {
        var sp = scr(tx, ty, pts[k], pts[k + 1], ext)
        if (!seen && clipTo(prev, sp, bx0, by0, bx1, by1)) seen = true
        full.d.push(full.d[full.d.length - 1] + Math.sqrt(Math.pow(sp[0] - prev[0], 2) + Math.pow(sp[1] - prev[1], 2)))
        full.xy.push(sp[0], sp[1])
        prev = sp
      }
      if (!seen || full.d[full.d.length - 1] < tw + 4) continue
      // fixed spots along the line (they move with the map, never with the car)
      var memoKey = lname + '@' + tx + '/' + ty + '/' + (v.z || 14) + '/' + pts[0] + ',' + pts[1]
      var starts = anchoredStarts(full, tw, [bx0, by0, bx1, by1], memoKey)
      var spot = starts.length ? labelSpot(full, lname, tw, ctx, starts) : null
      if (!spot) continue
      var clash = false
      for (var g0 = 0; g0 < spot.dots.length && !clash; g0++) clash = under(spot.dots[g0][0], spot.dots[g0][1], 6)
      for (var j = 0; j < placed.length && !clash; j++) {
        var p = placed[j]
        for (var g = 0; g < spot.dots.length; g++) {
          var dg = spot.dots[g]
          if ((p[0] - dg[0]) * (p[0] - dg[0]) + (p[1] - dg[1]) * (p[1] - dg[1]) < (p[2] + 9) * (p[2] + 9)) { clash = true; break }
        }
      }
      if (clash) continue
      done[lname] = true
      rememberLabel(memoKey, full, tw, spot.start)
      for (var g2 = 0; g2 < spot.dots.length; g2++) placed.push([spot.dots[g2][0], spot.dots[g2][1], 9])
      count++
      ctx.strokeStyle = look.halo
      ctx.lineWidth = 3
      ctx.fillStyle = lb.water ? look.waterLabel : look.label
      for (var pass = 0; pass < 2; pass++) {
        for (var ch = 0; ch < spot.chars.length; ch++) {
          var cc = spot.chars[ch]
          ctx.save()
          ctx.translate(cc[1], cc[2])
          ctx.rotate(cc[3])
          if (pass) ctx.fillText(cc[0], 0, 0); else ctx.strokeText(cc[0], 0, 0)
          ctx.restore()
        }
      }
    }
    // places: a few at a time (fewer on the 1000 m view), never over a street name or each other
    if (pois) drawPois()
    // house numbers: only in the closest view, small and grey, never over anything else
    if (numbers && scale >= NUMBER_MIN_SCALE && opts.numbers !== false) {
      ctx.font = '500 9px sans-serif'
      ctx.textAlign = 'center'
      ctx.lineWidth = 2.5
      var shownN = 0
      for (var hn = 0; hn < numbers.length && shownN < NUMBER_MAX; hn++) {
        var nb = numbers[hn][2], next = 4096
        for (var hk in numbers[hn][3]) { next = numbers[hn][3][hk].extent; break }
        var at2 = scr(numbers[hn][0], numbers[hn][1], nb.x, nb.y, next), hx = at2[0], hy = at2[1]
        if (hx < bx0 || hx > bx1 || hy < by0 || hy > by1) continue
        var hw = ctx.measureText(nb.n).width / 2 + 2
        if (under(hx, hy, hw)) continue
        var over = false
        for (var pm2 = 0; pm2 < placed.length && !over; pm2++) {
          var o2 = placed[pm2]
          over = Math.abs(o2[0] - hx) < o2[2] + hw && Math.abs(o2[1] - hy) < o2[2] * (o2[3] ? 1 : 0.8) + 6
        }
        if (over) continue
        placed.push([hx, hy, hw])
        shownN++
        ctx.strokeStyle = look.halo
        ctx.strokeText(nb.n, hx, hy)
        ctx.fillStyle = look.number
        ctx.fillText(nb.n, hx, hy)
      }
      ctx.textAlign = 'center'
    }
    return
    function drawPois() {
    var poiMax = scale < POI_MIN_SCALE ? POI_FAR_MAX : POI_MAX
    ctx.font = '500 10px sans-serif'
    ctx.textAlign = 'left'
    var shown = 0, seen = {}
    for (var q = 0; q < pois.length && shown < poiMax; q++) {
      var pt = pois[q][2], pext = 4096
      if (opts[pt.kind] === false || (pt.kind === 'other' && !opts.other)) continue
      for (var pn in pois[q][3]) { pext = pois[q][3][pn].extent; break }
      var at = scr(pois[q][0], pois[q][1], pt.x, pt.y, pext), px0 = at[0], py0 = at[1]
      var pname = opts.latin && pt.lat || pt.name
      var pw = ctx.measureText(pname).width
      // the dot on the place, the name to its right (left when that runs off the screen)
      var left = px0 + 7 + pw > bx1
      var cx = left ? px0 - 7 - pw / 2 : px0 + 7 + pw / 2
      if (px0 < bx0 || px0 > bx1 || py0 < by0 || py0 > by1 || cx - pw / 2 < bx0 - 4) continue
      if (seen[pname] && Math.abs(seen[pname][0] - px0) + Math.abs(seen[pname][1] - py0) < 200) continue
      var pr = pw / 2 + 10, hit = under(px0, py0, 5) || under(cx, py0, pw / 2)
      for (var m = 0; m < placed.length; m++) {
        var o = placed[m]
        if ((o[0] - cx) * (o[0] - cx) + (o[1] - py0) * (o[1] - py0) < (o[2] + pr) * (o[2] + pr) * (o[3] ? 1 : 0.55)) { hit = true; break }
      }
      if (hit) continue
      placed.push([cx, py0, pr, 1])
      seen[pname] = [px0, py0]
      shown++
      ctx.beginPath()
      ctx.arc(px0, py0, 3.5, 0, Math.PI * 2)
      ctx.fillStyle = POI_COLOR[pt.kind] || POI_COLOR.other
      ctx.fill()
      ctx.lineWidth = 1.5
      ctx.strokeStyle = look.halo
      ctx.stroke()
      ctx.textAlign = left ? 'right' : 'left'
      var lx = left ? px0 - 7 : px0 + 7
      ctx.lineWidth = 3
      ctx.strokeText(pname, lx, py0)
      ctx.fillStyle = look.poi || look.label
      ctx.fillText(pname, lx, py0)
    }
    ctx.textAlign = 'center'
    }
  }
  var NUMBER_MIN_SCALE = 1.2     // pixels per metre: the 250 m view only
  var NUMBER_MAX = 60
  var POI_MIN_SCALE = 0.65    // pixels per metre: below it (the 1000 m view) only POI_FAR_MAX places
  var POI_MAX = 12, POI_FAR_MAX = 5
  var POI_COLOR = {food: '#e8833a', shop: '#9b6ad6', health: '#d9534f', fuel: '#2a9d8f', other: '#8a8580'}

  function fromBase64(b64) {
    var bin = atob(b64), out = new Uint8Array(bin.length)
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
    return out
  }
  function utf8Bytes(text) { return new TextEncoder().encode(text) }
  return {decode: decode, TileMap: TileMap, tileXY: tileXY, tileMetres: tileMetres, labelsOf: labelsOf, poisOf: poisOf, numbersOf: numbersOf, labelSpot: labelSpot, anchoredStarts: anchoredStarts, rememberLabel: rememberLabel, clipTo: clipTo,
    fromBase64: fromBase64, utf8Bytes: utf8Bytes}
})()

angular.module('beamng.apps')
.directive('cargoEarthPhone', [function () {
  var STATE = 'cargoEarth_core and cargoEarth_core.phoneState() or nil'
  // the careers on the start screens (resume and first run): load one, delete one (asks first)
  var SAVES_HTML =
    '<div class="cep-label" ng-if="s.saves.length">Your careers</div>' +
    '<div class="cep-li" ng-repeat="v in s.saves track by v.id" ng-class="{on: v.current && s.screen === \'resume\'}">' +
      '<div><div class="cep-name">{{ v.name }}</div>' +
        '<small ng-if="v.unreadable">This save cannot be read.</small>' +
        '<div class="cep-pills" ng-if="!v.unreadable"><span>{{ fmt.money(v.money) }}</span><span ng-if="v.car">{{ v.car }}</span><span ng-if="v.hours">{{ v.hours }} h</span></div>' +
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
    '.cep-unstuck{border:1px solid var(--line);background:transparent;color:inherit;border-radius:10px;padding:2px 7px;font:inherit;font-size:11px;line-height:1.2;cursor:pointer}' +
    '.cep-unstuck.wait{opacity:.5}.cep-unstuck small{font-size:10px;font-weight:500}' +
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
    '.cep-sub{font-size:13px;color:var(--muted);line-height:1.35}.cep-sub.cep-warn{color:var(--warn);font-weight:700}.cep-sub.cep-why{margin-top:6px;font-weight:600}' +
    '.cep-label{font-size:10px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}' +
    '.cep-btn{display:block;width:100%;border:0;border-radius:14px;padding:13px 10px;font:inherit;font-size:15px;font-weight:700;' +
    'cursor:pointer;background:var(--ink);color:#fff}' +
    '.cep-btn:hover{filter:brightness(1.12)}.cep-btn.go{background:var(--tomato)}.cep-btn.ok{background:var(--ok)}' +
    '.cep-btn.ghost{background:transparent;color:var(--ink);box-shadow:inset 0 0 0 1.5px var(--line)}' +
    '.cep-row{display:flex;flex-wrap:wrap;gap:8px;min-width:0}.cep-row .cep-btn,.cep-row .cep-sm{flex:1;min-width:0}' +
    '.cep-card{background:var(--card);border-radius:16px;padding:12px 14px;box-shadow:0 1px 0 var(--line),0 4px 14px rgba(29,27,25,.06)}' +
    '.cep-stop{display:grid;grid-template-columns:14px 1fr;gap:2px 10px;align-items:start}' +
    '.cep-coachtrip{margin-top:8px;padding:8px;border-radius:10px;background:var(--paper);box-shadow:inset 0 0 0 1px var(--line);display:flex;flex-direction:column;gap:4px}' +
    '.cep-coachtrip .cep-sm{margin-top:2px}' +
    '.cep-busref{display:inline-block;min-width:22px;padding:0 5px;border-radius:4px;background:var(--ink);color:var(--card);text-align:center;font-weight:700}' +
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
    // facts about one thing (km, time, slots...) as small pills, not a line joined with dots
    '.cep-pills{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px;min-width:0}.cep-pills>span{display:inline-block;max-width:100%;box-sizing:border-box;' +
      'padding:1px 8px;border-radius:999px;background:var(--line);color:var(--ink);font-size:11px;font-weight:600;line-height:1.6;' +
      'white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.cep-pills>span.warn{color:var(--warn)}.cep-pills>span.late{color:var(--tomato)}' +
    '.cep-pills-mid{justify-content:center}.cep-badge{margin-left:6px;padding:0 6px;border-radius:999px;background:var(--line);font-size:10px;font-weight:600}' +
    '.cep-keyval .cep-pills{display:inline-flex;margin:0 0 0 6px;vertical-align:middle}' +
    '.cep-ins-help{margin-top:6px;font-size:12px;line-height:1.35;color:var(--muted)}.cep-ins-help>div{margin-top:4px}.cep-ins-help b{color:var(--ink)}' +
    '.cep-foot.cep-pills{margin:0;padding:2px 10px}.cep-foot.cep-pills>span{font-size:10px;padding:0 7px}' +
    '.cep-foot-warn{color:var(--tomato)}' +
    '.cep-min{cursor:pointer;border:0;background:transparent;font:inherit;font-size:16px;font-weight:800;padding:0 4px;color:var(--ink)}' +
    '.cep-pill{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 16px;border-radius:999px;' +
    'background:#141312;color:#fff;font-family:"Segoe UI",Roboto,system-ui,sans-serif;font-weight:700;cursor:pointer;' +
    'box-shadow:0 6px 18px rgba(0,0,0,.4)}.cep-pill b{color:#e8452c}' +
    '.cep-tabs{display:flex;flex-shrink:0;gap:2px;border-top:1px solid var(--line);background:var(--card);padding:3px}' +
    '.cep-settings-link{border:0;background:transparent;padding:4px 6px;color:var(--muted);font:inherit;font-size:15px;line-height:1;cursor:pointer}' +
    '.cep-subtabs{display:flex;flex-shrink:0;gap:4px;margin:10px 14px 0;padding:4px;background:var(--line);border-radius:12px}' +
    '.cep-subtabs button{flex:1;min-width:0;border:0;border-radius:9px;padding:8px 4px;font:inherit;font-size:12px;font-weight:700;background:transparent;color:var(--muted);cursor:pointer}' +
    '.cep-modes{display:block;position:relative;flex:0 0 auto;min-width:0;margin:0}.cep-modes>span{display:block;font-size:11px;font-weight:700;color:var(--muted);margin-bottom:4px}' +
    '.cep-modes>small{display:block;margin-top:4px;font-size:11px;color:var(--muted)}.cep-work-modes{margin:0}.cep-work-modes button{min-height:36px;font-size:13px}' +
    '.cep-work-modes button:disabled{cursor:default;opacity:.45}' +
    '.cep-mode-select{display:block;box-sizing:border-box;width:100%;max-width:100%;min-width:0;min-height:42px;padding:8px 10px;border:1px solid var(--line);border-radius:10px;' +
      'background:var(--card);color:var(--ink);font:inherit;font-size:14px;font-weight:700;text-align:left;cursor:pointer}.cep-mode-select:disabled{cursor:default;opacity:.65}' +
    '.cep-mode-select>b{float:right}.cep-mode-menu{margin-top:4px;padding:4px;' +
      'border:1px solid var(--line);border-radius:10px;background:var(--card)}' +
    '.cep-mode-menu>button{display:block;width:100%;min-height:36px;padding:7px 10px;border:0;border-radius:7px;text-align:left;font:inherit;' +
      'background:transparent;color:var(--ink);cursor:pointer}.cep-mode-menu>button.on{background:var(--line);font-weight:700}' +
    '.cep-mode-menu>button>small{display:block;margin-top:2px;font-size:11px;font-weight:400;line-height:1.3;color:var(--muted)}' +
    '.cep-subtabs button.on{background:var(--card);color:var(--ink);box-shadow:0 1px 3px rgba(29,27,25,.1)}' +
    '.cep-live{display:flex;flex-shrink:0;align-items:center;gap:8px;margin:8px 14px 0;padding:9px 10px;border:1px solid #f2c5b7;border-radius:12px;background:#fff0ea;color:var(--ink);font:inherit;text-align:left;cursor:pointer}' +
    '.cep-live>span{flex:1;min-width:0}.cep-live strong,.cep-live small{display:block}.cep-live strong{font-size:12px}.cep-live small{font-size:11px;color:var(--muted);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}' +
    '.cep-live-left{flex:0 0 auto;font-style:normal;text-align:right}.cep-live .cep-live-left strong{font-size:13px;color:var(--tomato)}.cep-live .cep-live-left small{font-size:10px}' +
    '.cep-live>b{font-size:17px;color:var(--tomato)}.cep-dot-live{width:7px;height:7px;border-radius:50%;background:var(--tomato);flex:0 0 7px}' +
    '.cep-body button{white-space:normal;overflow-wrap:anywhere}.cep-card .cep-btn{margin-top:8px}.cep-card .cep-sm{margin-top:6px}' +
    '.cep-scroll>*{flex-shrink:0}.cep-empty{padding:16px 12px;text-align:center;border:1px dashed var(--line);border-radius:14px}' +
    '.cep-money-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.cep-money-grid strong{display:block;font-size:17px}.cep-money-grid span{font-size:11px;color:var(--muted)}' +
    '.cep-credit{color:var(--ok)}.cep-debit{color:#a72f1e}.cep-tabs svg{flex:none;width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}' +
    '.cep button:focus-visible,.cep input:focus-visible{outline:2px solid var(--tomato);outline-offset:2px}' +
    '.cep-search{width:100%;border:1px solid var(--line);border-radius:10px;padding:10px;background:var(--card);color:var(--ink);font:inherit;font-size:14px;user-select:text;-webkit-user-select:text}' +
    '.cep-tabs button{flex:1;min-width:0;display:flex;align-items:center;justify-content:center;gap:4px;border:0;border-radius:9px;background:transparent;' +
    'font:inherit;font-size:11px;font-weight:700;padding:0;min-height:30px;color:var(--muted);cursor:pointer}.cep-tabs button.on{color:var(--tomato);background:#fff0ea}' +
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
    '.cep-km{padding:8px 10px}.cep-km small{color:var(--muted);font-size:11px}.cep-km-row{display:flex;align-items:center;gap:6px;margin-top:4px}' +
    '.cep-card .cep-km-row .cep-sm{margin:0;flex:0 0 44px;min-height:40px;font-size:20px;padding:0}.cep-km-row .cep-input{flex:1;min-width:0;text-align:center;font-size:16px;font-weight:700}' +
    '.cep-km-row>span{color:var(--muted);font-size:12px}' +
    '.cep-step2>.cep-sm{min-width:44px;min-height:40px}.cep-step2{display:flex;align-items:center;gap:8px}.cep-step2 b{min-width:62px;text-align:center;font-variant-numeric:tabular-nums}' +
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
    '.cep-job-input{display:block;width:100%;box-sizing:border-box;margin-top:5px}' +
    '.cep-stars{color:#e0a100;letter-spacing:1px;font-size:15px;white-space:nowrap}.cep-stars.big{font-size:24px}' +
    '.cep-stars i{font-style:normal;color:var(--line)}' +
    '.cep-premium{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;background:#e0a100;color:#fff;font-size:10px;font-weight:800}' +
    '.cep-special{display:inline-block;margin-left:6px;padding:1px 6px;border-radius:4px;color:#fff;font-size:10px;font-weight:800;text-transform:uppercase}' +
    '.cep-special.fragile{background:#c2416b}.cep-special.chilled{background:#2b7bb9}.cep-special.oversize{background:#d9822b}' +
    '.cep-map{display:block;width:100%;border-radius:12px;background:#f1ebe3}' +
    // the live map (Map tab): a canvas the size of the phone's body with zoom buttons (the job's own bar sits above it)
    '.cep-mapbody{padding:0;gap:0}.cep-mapbox{position:relative;flex:1;min-height:0;overflow:hidden;background:#ece6dd}' +
    '.cep-livemap{position:absolute;inset:0;width:100%;height:100%;display:block}' +
    '.cep-map-zoom{position:absolute;right:8px;bottom:14px;display:flex;flex-direction:column;gap:6px}' +
    '.cep-map-btn{width:40px;height:40px;padding:0;border:0;border-radius:10px;font:inherit;font-size:22px;font-weight:800;line-height:1;cursor:pointer;' +
      'background:var(--card);color:var(--ink);box-shadow:0 1px 4px rgba(0,0,0,.3)}.cep-map-btn:disabled{opacity:.45;cursor:default}' +
    '.cep-map-note{position:absolute;left:12px;right:60px;bottom:12px;padding:7px 10px;border-radius:10px;background:var(--card);font-size:12px;color:var(--muted)}' +
    '.cep-map-head{position:absolute;left:44px;right:8px;top:8px;z-index:1;display:flex;flex-direction:column;align-items:stretch;gap:0}' +
    '.cep-map-job{display:flex;align-items:center;gap:6px;width:100%;min-height:24px;padding:3px 10px;border:0;border-radius:10px;font:inherit;font-size:11px;' +
      'text-align:left;cursor:pointer;background:var(--card);color:var(--ink);box-shadow:0 1px 4px rgba(0,0,0,.3)}' +
      '.cep-map-job span{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.cep-map-job b{font-weight:800}.cep-map-job>i{font-style:normal;font-size:15px;line-height:1;opacity:.8}' +
      '.cep-map-job.offer{background:var(--tomato);color:#fff}' +
      '.cep-map-dir+.cep-map-job{border-radius:0 0 10px 10px;background:#185a3c;color:#fff;box-shadow:0 2px 4px rgba(0,0,0,.3)}.cep-map-head .cep-map-dir.joined{border-radius:10px 10px 0 0}' +
      '.cep-map-head .cep-map-lanes{margin-top:4px;align-self:flex-start}' +
    '.cep-map-turn{padding:7px 10px;border-radius:10px;background:var(--card);font-size:12px;font-weight:700;' +
      'color:var(--tomato);box-shadow:0 1px 4px rgba(0,0,0,.25)}' +
    '.dark .cep-mapbox{background:#23201e}' +
    // the OSM map's credit line, and the close button of the map's note
    '.cep-map-credit{position:absolute;right:4px;bottom:1px;font-size:8px;color:var(--muted);opacity:.85;pointer-events:none}' +
    '.cep-map-note button{float:right;margin:-3px -4px 0 8px;width:22px;height:22px;padding:0;border:0;border-radius:6px;font:inherit;font-size:14px;' +
      'line-height:1;cursor:pointer;background:var(--line);color:var(--ink)}' +
    '.cep-vstop{width:18px;height:18px;border-radius:50%;border:2.5px solid #fff;color:#fff;font:800 10px/18px sans-serif;text-align:center;' +
      'box-shadow:0 1px 3px rgba(0,0,0,.35)}.cep-vstop.next{width:24px;height:24px;line-height:24px;font-size:12px}' +
    // the north dial: tap it for the map's timings
    '.cep-map-n{position:absolute;left:8px;top:8px;width:30px;height:30px;padding:0;border:0;border-radius:50%;cursor:pointer;' +
      'background:rgba(255,255,255,.88);box-shadow:0 1px 3px rgba(0,0,0,.3)}.dark .cep-map-n{background:rgba(0,0,0,.6)}' +
    '.cep-map-nd{position:absolute;inset:0;display:block;font:800 10px/30px sans-serif;text-align:center;color:#25201d}.dark .cep-map-nd{color:#fff}' +
    '.cep-map-nd:before{content:"";position:absolute;left:11px;top:0;border:4px solid transparent;border-bottom:7px solid #e4572e;border-top:0}' +
    '.cep-map-gear{position:absolute;left:8px;top:44px;width:30px;height:30px;padding:0;border:0;border-radius:50%;cursor:pointer;font-size:15px;line-height:30px;' +
      'background:rgba(255,255,255,.88);color:#25201d;box-shadow:0 1px 3px rgba(0,0,0,.3)}.dark .cep-map-gear{background:rgba(0,0,0,.6);color:#fff}.cep-map-gear.on{box-shadow:0 0 0 2px var(--tomato)}' +
    '.cep-map-whole{top:80px}.cep-map-whole svg,.cep-map-go svg{width:15px;height:15px;vertical-align:-2px}' +
    '.cep-map-go{top:80px}.cep-map-go.low{top:116px}.cep-map-set-g.cep-map-gos{grid-template-columns:1fr 1fr}.cep-map-set .cep-map-gos button{color:var(--ink);font-weight:700}.cep-map-set .cep-map-gos button:disabled{color:var(--muted)}' +
    '.cep-map-gomsg{margin-top:7px;font-size:12px;color:var(--muted)}.cep-map-gomsg.bad{color:var(--tomato)}' +
    '.cep-map-set{position:absolute;left:8px;right:8px;top:8px;padding:8px 10px 10px;border-radius:12px;background:var(--card);color:var(--ink);box-shadow:0 2px 8px rgba(0,0,0,.35);z-index:3}' +
      '.cep-map-set-h{display:flex;align-items:center;justify-content:space-between;margin-bottom:6px}.cep-map-set-h b{font-size:13px}' +
      '.cep-map-set-h button{width:26px;height:26px;padding:0;border:0;border-radius:8px;font:inherit;cursor:pointer;background:var(--line);color:var(--ink)}' +
      '.cep-map-set-g{display:grid;grid-template-columns:1fr 1fr;gap:5px}.cep-map-set-g button{min-height:30px;padding:4px 8px;border:1px solid var(--line);border-radius:9px;' +
        'font:inherit;font-size:11px;font-weight:700;text-align:left;cursor:pointer;background:transparent;color:var(--muted)}' +
      '.cep-map-set-g button:disabled{opacity:.45;cursor:default}.cep-map-set-g button.on{background:#e7f3ea;border-color:#8cc59a;color:#1f5c31}.dark .cep-map-set-g button.on{background:#1d3a26;border-color:#3d7a4e;color:#bfe6c8}' +
      '.cep-map-set-g button:before{content:"○ ";}.cep-map-set-g button.on:before{content:"● "}.cep-map-set-p button:before{content:none}.cep-map-set-p button.on:before{content:none}' +
      '.cep-map-set-p{grid-template-columns:1fr 1fr 1fr}.cep-map-set-p i{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:0}' +
      '.cep-map-set-p button:not(.on) i{opacity:.35}.cep-map-set-l{margin:8px 0 4px;font-size:11px;font-weight:700;color:var(--muted)}' +
    '.cep-map-stats{position:absolute;left:8px;right:56px;top:60px;padding:8px 10px;border-radius:10px;background:var(--card);font-size:11px;line-height:1.45;' +
      'color:var(--ink);box-shadow:0 1px 4px rgba(0,0,0,.3);z-index:2}.cep-map-stats b{font-weight:800}' +
    '.cep-map-stats button{margin-top:6px;padding:5px 9px;border:0;border-radius:8px;font:inherit;font-weight:700;cursor:pointer;background:var(--line);color:var(--ink)}' +
    // directions: the next turn on top, the speed and the way left at the bottom
    '.cep-map-dir{display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:10px;' +
      'background:#1f6f4a;color:#fff;box-shadow:0 1px 4px rgba(0,0,0,.3)}' +
    '.cep-map-dir svg{flex:none;width:30px;height:30px}.cep-map-dir b{display:block;font-size:17px;font-weight:800;line-height:1.1}' +
    '.cep-map-dir span{display:block;font-size:11px;opacity:.9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.cep-map-dir div{min-width:0}' +
    '.cep-map-lanes{display:flex;gap:2px;padding:4px 6px;border-radius:9px;background:#185a3c;box-shadow:0 1px 4px rgba(0,0,0,.3)}' +
      '.cep-map-lanes svg{width:22px;height:22px;opacity:.35}.cep-map-lanes svg.ok{opacity:1}' +
    '.cep-map-speed{position:absolute;left:8px;bottom:8px;width:46px;height:46px;padding:0;border:0;font:inherit;cursor:pointer;border-radius:50%;background:var(--card);color:var(--ink);text-align:center;' +
      'box-shadow:0 1px 4px rgba(0,0,0,.3)}.cep-map-speed.over{background:#fde3de;box-shadow:0 0 0 3px var(--tomato)}.dark .cep-map-speed.over{background:#4a1f18}' +
      '.cep-map-speed i{position:absolute;right:-3px;top:-3px;width:16px;height:16px;border-radius:50%;background:var(--card);box-shadow:0 1px 2px rgba(0,0,0,.3)}' +
      '.cep-map-speed i svg{width:16px;height:16px;display:block}.cep-map-speed b{display:block;font-size:17px;font-weight:800;line-height:1;margin-top:3px}' +
    '.cep-map-speed small{font-size:9px;color:var(--muted)}.cep-map-speed.over b{color:var(--tomato)}' +
    '.cep-map-speed.slight{background:#fff3d6;box-shadow:0 0 0 3px var(--warn)}.cep-map-speed.slight b{color:#9a6400}.dark .cep-map-speed.slight{background:#3d2e10}.dark .cep-map-speed.slight b{color:#f0b54a}' +
    '.cep-map-limit{position:absolute;left:14px;bottom:60px;box-shadow:0 1px 4px rgba(0,0,0,.3)}.cep-map-limit.solo{bottom:14px}' +
    '.cep-map-left{position:absolute;left:60px;bottom:14px;padding:5px 9px;border-radius:9px;background:var(--card);font-size:12px;font-weight:700;' +
      'color:var(--ink);box-shadow:0 1px 4px rgba(0,0,0,.3)}.cep-map-left small{font-weight:600;color:var(--muted)}' +
    '.cep-map-hasleft .cep-map-note{left:60px;bottom:48px}' +
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

  var HOME_CSS =
    '.cehm-grid{flex:1;min-height:0;overflow:auto;display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));align-content:start;gap:12px}' +
    '.cehm-room{display:flex;flex-direction:column;gap:7px;padding:14px 16px;border:3px solid #7fb7d1;border-radius:6px;' +
    'background-image:linear-gradient(#1a2733 1px,transparent 1px),linear-gradient(90deg,#1a2733 1px,transparent 1px);background-size:22px 22px}' +
    '.cehm-room.free{border-style:dashed;border-color:#3a4d5c}.cehm-room.garage{grid-column:1/-1;background:#232a31}' +
    '.cehm-cars{display:flex;flex-wrap:wrap;gap:6px}.cehm-cars .cehq-car{width:30px;height:54px}.cehm-cars .cehq-car.empty{opacity:.2}' +
    '.cehm-steps{display:flex;flex-wrap:wrap;gap:6px}.cehm-steps span{font-size:12px;padding:4px 8px;border-radius:6px;background:#22313d;color:#9fb2bf}' +
    '.cehm-steps span.on{background:#7fd19b;color:#15202a;font-weight:700}' +
    '.cehm-pick{display:flex;flex-direction:column;gap:6px}.cehm-pick .cehq-btn{text-align:left}' +
    '.cehm-row{display:flex;flex-wrap:wrap;gap:8px}' +
    '@media (max-width:620px){.cehq-panel{width:100vw;height:100vh;max-height:none;border-radius:0;padding:14px 16px}.cehq-head{flex-direction:column}.cehq-head-right{max-width:none;justify-content:flex-start}}'

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
    '.cehq .cep-pills>span{background:rgba(255,255,255,.1);color:#dbe6ee;font-size:12px}' +
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
  // any km value from the game: one decimal (whole km from 100 up), so a raw road length never spills out of a pill
  function km(v) {
    if (v === null || v === undefined || v === '') return '–'
    var n = Number(v)
    if (!isFinite(n)) return '–'
    n = n >= 100 ? Math.round(n) : Math.round(n * 10) / 10
    return String(n).replace('.', ',') + ' km'
  }

  return {
    template:
      '<div style="width:100%;height:100%"><style>' + CSS + DASH_CSS + MENU_CSS + DARK_CSS + HQ_CSS + HOME_CSS + '</style>' +
      '<div class="cehq" ng-show="homeOpen" role="dialog" aria-label="Home garage">' +
      '<div class="cehq-panel" ng-if="homeOpen">' +
        '<div class="cehq-head">' +
          '<div><div class="cehq-kicker">Home garage · {{ places.homeInfo.levelName || "Not set" }}</div>' +
            '<div class="cehq-title">{{ places.homeInfo.name || "No home yet" }}</div>' +
            '<div class="cep-pills" ng-if="places.homeInfo"><span ng-if="places.homeInfo.town && places.homeInfo.name.indexOf(places.homeInfo.town) < 0">{{ places.homeInfo.town }}</span>' +
              '<span>{{ places.homeInfo.here ? "You are home" : fmt.num(places.homeKm) + " km away" }}</span>' +
              '<span ng-if="places.homeInfo.rested">Rested: +10 % pay, {{ places.homeInfo.rested }} min left</span>' +
              '<span ng-if="places.homeInfo.resting">Resting: {{ places.homeInfo.resting }} min to Rested</span></div></div>' +
          '<div class="cehq-head-right">' +
            '<div class="cehq-money" ng-if="places.homeInfo">{{ fmt.money(places.money) }}</div>' +
            '<button class="cehq-btn ghost" ng-if="places.home && !places.atHome" ng-disabled="places.busy || places.shift" ng-click="pdo(\'homeGps\')">Route home</button>' +
            '<button class="cehq-btn" ng-click="closeHome()">Close</button></div></div>' +
        '<div class="cehq-msg" ng-if="!places">Loading your home…</div>' +
        '<div class="cehq-msg" ng-if="places.msg">{{ fmt.text(places.msg) }}</div>' +
        '<div class="cehq-empty" ng-if="places && !places.homeInfo">' +
          '<div class="cehq-title">Make a home where you park</div>' +
          '<p>A home is never needed, but your own trailers park there. It also gives you room for more cars and cheaper repairs, servicing and fuel when you are there.</p>' +
          '<button class="cehq-btn build" ng-disabled="!places.started || places.busy || places.shift" ng-click="claimHome()">Make this spot my home</button></div>' +
        '<div class="cehm-grid" ng-if="places.homeInfo">' +
          '<div class="cehm-room garage"><div class="cehq-label">Garage · {{ places.used }} of {{ places.capacity || places.homeInfo.cars }} cars</div>' +
            '<div class="cehm-cars"><svg class="cehq-car" ng-repeat="on in carSpots() track by $index" ng-class="{empty: !on}" viewBox="0 0 60 110" aria-hidden="true">' +
              '<rect x="8" y="4" width="44" height="102" rx="14"/><path class="glass" d="M14 30h32l-4 16H18zM18 78h24l4 12H14z"/></svg></div>' +
            '<div class="cehm-steps"><span ng-repeat="st in homeSteps track by $index" ng-class="{on: $index < places.homeInfo.level}">{{ st }}</span></div>' +
            '<div class="cehq-note">Trailer spots: {{ places.homeInfo.trailersHere }} of {{ places.homeInfo.trailerSpots }} used (Garage → Trailers).</div>' +
            '<div class="cehq-note" ng-if="places.homeInfo.next">Next: {{ places.homeInfo.next.name }}, room for {{ places.homeInfo.next.cars }} cars, {{ places.homeInfo.next.trailers }} trailers and {{ places.homeInfo.next.rooms }} rooms.</div>' +
            '<div class="cehq-note" ng-if="!places.homeInfo.next">Your home is fully built.</div>' +
            '<div class="cehm-row"><button class="cehq-btn build" ng-if="places.homeInfo.next" ng-disabled="!places.homeInfo.next.can" ng-click="pdo(\'upgradeHome\')">Upgrade · {{ fmt.money(places.homeInfo.next.cost) }}</button>' +
              '<button class="cehq-btn ghost" ng-disabled="places.busy || places.shift" ng-click="claimHome()">{{ homeAsk ? "Press again: move home here" : "Move home here" }}</button></div>' +
            '<div class="cehq-note">Moving keeps the rooms you built. Your cars move with the home.</div></div>' +
          '<div class="cehm-room" ng-repeat="r in places.homeInfo.rooms track by r.id" ng-if="r.built"><div class="cehq-label">{{ r.name }}</div>' +
            '<div class="cehq-note">{{ r.text }}.</div></div>' +
          '<div class="cehm-room free" ng-repeat="n in range(places.homeInfo.slots - places.homeInfo.used) track by $index" ng-if="!allRoomsBuilt()"><div class="cehq-label small">Free room</div>' +
            '<div class="cehm-pick"><div ng-repeat="r in places.homeInfo.rooms track by r.id" ng-if="!r.built">' +
              '<button class="cehq-btn small build" ng-disabled="!r.can" ng-click="pdo(\'buildRoom\', r.id)">Build {{ r.name }} · {{ fmt.money(r.cost) }}</button>' +
              '<div class="cehq-note">{{ r.text }}.</div></div></div></div>' +
          '<div class="cehm-room free" ng-if="places.homeInfo.used >= places.homeInfo.slots && !allRoomsBuilt()"><div class="cehq-label small">No free room</div>' +
            '<div class="cehq-note">Upgrade your home to build another room.</div></div>' +
        '</div></div></div>' +
      '<div class="cehq" ng-show="hqOpen" role="dialog" aria-label="Headquarters">' +
      '<div class="cehq-panel" ng-if="hqOpen">' +
        '<div class="cehq-head">' +
          '<div><div class="cehq-kicker">Headquarters</div>' +
            '<div class="cehq-title">{{ hq.name || "Your firm" }}</div>' +
            '<div class="cehq-sub" ng-if="hq.hq">{{ hq.hq.name }}</div><div class="cep-pills" ng-if="hq.hq"><span ng-if="hq.hq.town">{{ hq.hq.town }}</span><span>{{ hq.hq.here ? "You are here" : fmt.num(hq.hq.km) + " km away" }}</span></div>' +
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
            '<div class="cehq-label small" ng-if="hq.drivers.can">Looking for work (new faces in {{ hq.drivers.nextMin }} min)</div>' +
            '<div class="cehq-app" ng-repeat="a in hq.drivers.applicants track by a.id" ng-if="hq.drivers.can" ng-class="{picked: pick.id === a.id}" ' +
              'ng-click="pick.id = (pick.id === a.id ? null : a.id)">' +
              '<b>{{ a.name }}</b><div class="cep-pills"><span>Speed {{ pct(a.speed) }}</span><span>Care {{ pct(a.care) }}</span><span>{{ fmt.money(a.wage) }} a shift</span></div>' +
              '<div class="cep-pills"><span ng-repeat="l in a.licenceNames track by $index">{{ l }} licence</span><span ng-if="a.knowsName">Best with {{ a.knowsName }}</span></div></div>' +
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
            '<button class="cehq-btn" ng-if="hq.repair.cost > 0" ng-disabled="!hq.hq.here || hq.company" ng-click="hdo(\'repair\')">Repair your car · {{ fmt.money(hq.repair.cost * hq.repair.factor - (hq.repair.insured || 0)) }}{{ hq.repair.insured ? " (insurance pays " + fmt.money(hq.repair.insured) + ")" : "" }}</button>' +
            '<div class="cehq-note" ng-if="hq.repair.cost > 0 && !hq.hq.here">Bring the car here to use the workshop.</div></div>' +
          '<div class="cehq-room stores"><div class="cehq-label">Parts storage</div>' +
            '<div class="cehq-stat">{{ hq.parts.count }}<small>spare {{ hq.parts.count === 1 ? "part" : "parts" }}</small></div>' +
            '<div class="cehq-shelf"><span ng-repeat="p in hq.parts.items track by $index">{{ p.name }}<b ng-if="p.count > 1"> × {{ p.count }}</b></span>' +
              '<span ng-if="hq.parts.kinds > hq.parts.items.length">and {{ hq.parts.kinds - hq.parts.items.length }} more</span></div>' +
            '<div class="cehq-note" ng-if="!hq.parts.count">Parts you take off a car are kept here.</div></div>' +
          '<div class="cehq-yard"><div class="cehq-yard-head"><div class="cehq-label">Yard: {{ hq.bays.length }} of {{ hq.capacity }} bays taken</div>' +
        '<button class="cehq-btn small build" ng-if="up(\'bays\').cost" ng-disabled="!up(\'bays\').can" ng-click="hdo(\'upgrade\', \'bays\')" title="{{ up(\'bays\').next }}">Build more bays · {{ fmt.money(up(\'bays\').cost) }}</button></div>' +
            '<div class="cehq-bays">' +
              '<div class="cehq-bay" ng-repeat="b in hq.bays track by $index" ng-class="{current: b.current, out: b.driver}">' +
                '<svg class="cehq-car" viewBox="0 0 60 110" aria-hidden="true"><rect x="8" y="4" width="44" height="102" rx="14"/><path class="glass" d="M14 30h32l-4 16H18zM18 78h24l4 12H14z"/><path class="glass" d="M10 50v24M50 50v24"/></svg>' +
                '<div class="cehq-bay-name">{{ b.name }}</div>' +
                '<div class="cep-pills"><span>{{ fmt.int(b.km) }} km</span><span>{{ b.current ? "You drive it" : (b.driver ? "On the road" : "Parked") }}</span></div>' +
                '<div class="cehq-driver" ng-if="b.driver">{{ b.driver.name }}</div>' +
                '<div class="cep-pills" ng-if="b.driver && !b.driver.waiting"><span>{{ fmt.money(b.driver.net) }} a shift</span><span>Earned {{ fmt.money(b.driver.earned) }}</span></div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'repair\'">Waiting for a repair</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'trailer\'">Needs a free trailer</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'licence\'">No licence for this vehicle</div>' +
                '<div class="cehq-note warn" ng-if="b.driver.waiting === \'boxes\'">Needs cargo boxes fitted</div>' +
                '<div class="cehq-wear" ng-if="b.upkeep"><div ng-repeat="it in b.upkeep.items track by it.id" ng-class="{soon: it.soon, due: it.due}" ' +
                  'title="{{ it.name }}: {{ it.due ? \'overdue\' : it.kmLeft + \' km left\' }}"><span>{{ it.id }}</span><em><i ng-style="{width: Math.min(100, it.share * 100) + \'%\'}"></i></em></div></div>' +
                '<button class="cehq-btn small" ng-if="b.upkeep.due > 0" ng-disabled="hq.company || (b.current && !hq.hq.here) || hq.money < b.upkeep.dueCost" ' +
                  'ng-click="hdo(\'service\', b.current ? \'current\' : b.id)" title="{{ b.current && !hq.hq.here ? \'Bring the car here\' : \'\' }}">Service · {{ fmt.money(b.upkeep.dueCost) }}</button>' +
                '<button class="cehq-btn small build" ng-if="b.repairCost > 0" ng-disabled="hq.company || hq.money < b.repairCost" ng-click="hdo(\'repairParked\', b.id)">Repair · {{ fmt.money(b.repairCost) }}{{ b.insured ? " (insured)" : "" }}</button>' +
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
            '<div class="cehq-section"><div class="cehq-label">Trailers: {{ hq.trailers.length }} of {{ hq.trailerYard }} spots in the yard</div>' +
              '<div class="cehq-note">Your trailers, shared with your hired drivers: a tractor driver takes one parked here or at home. ' +
                'Buy, take out and park them in Garage → Trailers.</div>' +
              '<div class="cehq-shop">' +
                '<div class="cehq-item" ng-repeat="t in hq.trailers track by t.id"><b>{{ t.name }}</b>' +
                  '<div class="cep-pills"><span>{{ fmt.int(t.condition * 100) }} %</span><span ng-if="t.repair > 0">Needs repairs</span></div></div>' +
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
        '<i class="cep-dot-live"></i><span><strong>{{ liveTitle() }}</strong><small>{{ liveDetail() }}</small></span>' +
        '<em class="cep-live-left" ng-if="liveLeft()"><strong>{{ liveLeft().dist }}</strong><small ng-if="liveLeft().time">{{ liveLeft().time }}</small></em>' +
        '<b aria-hidden="true">&rsaquo;</b></button>' +
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
            '<div class="cep-sub" ng-if="firm.hq">Headquarters: {{ firm.hq.name }}</div><div class="cep-pills" ng-if="firm.hq.town"><span>{{ firm.hq.town }}</span></div>' +
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
            '<div class="cep-keyval"><span>Fines</span><strong>{{ career.fines.count }} for {{ fmt.money(career.fines.paid) }}</strong></div></div>' +
          '<div class="cep-card"><div class="cep-label">Delivery rank</div>' +
            '<div class="cep-big">{{ career.rank }}</div>' +
            '<div ng-if="career.nextRank">' +
              '<div class="cep-sub">Next rank: {{ career.nextRank }}</div>' +
              '<div class="cep-time" role="progressbar" aria-label="Progress toward next rank" aria-valuemin="0" ' +
                'ng-attr-aria-valuemax="{{ career.nextAt }}" ng-attr-aria-valuenow="{{ career.completed }}">' +
                '<i ng-style="{width: (career.completed / career.nextAt * 100) + \'%\'}"></i></div>' +
              '<div class="cep-sub">{{ fmt.int(career.completed) }} of {{ fmt.int(career.nextAt) }} deliveries</div></div>' +
            '<div class="cep-sub" ng-if="!career.nextRank">Highest rank reached</div>' +
            '<div class="cep-sub" ng-repeat="r in career.ranks track by r.name" ng-if="r.perk">{{ r.name }} ({{ r.at }} deliveries): {{ fmt.text(r.perk) }}</div></div>' +
          '<div class="cep-card cep-stats"><div>{{ fmt.int(career.completed) }}<span>delivered</span></div>' +
            '<div>{{ fmt.int(career.ruined) }}<span>ruined</span></div>' +
            '<div>{{ fmt.int(career.drivenKm || 0) }} km<span>driven</span></div></div>' +
          // every kind of work: what to do, what it needs, whether you have it and what it earns (issue #123)
          '<div class="cep-label" ng-if="career.work">Work types</div>' +
          '<div class="cep-card" ng-repeat="w in career.work track by w.id">' +
            '<div class="cep-keyval"><strong>{{ w.name }}</strong>' +
              '<span class="cep-sub" ng-if="w.ready" style="color:var(--ok)">Available</span><span class="cep-sub" ng-if="!w.ready">Locked</span></div>' +
            '<div class="cep-sub">{{ fmt.text(w.what) }}</div>' +
            '<div class="cep-sub"><b>Needs:</b> {{ fmt.text(w.needs) }}</div>' +
            '<div class="cep-sub" ng-if="!w.ready && w.missing" style="color:var(--tomato)">{{ fmt.text(w.missing) }}</div>' +
            '<div class="cep-sub" ng-if="w.perHour">About {{ fmt.money(w.perHour) }} an hour</div>' +
            '<div class="cep-sub" ng-if="w.exp">Experience: {{ w.exp.jobs }} jobs, +{{ fmt.pct(w.exp.rate) }} pay (up to +{{ fmt.pct(w.exp.max) }} after {{ w.exp.full }})</div></div>' +
          '<div class="cep-label">Cargo milestones</div>' +
          '<div class="cep-card" ng-repeat="goal in career.cargo track by goal.id">' +
            '<div class="cep-keyval"><strong>{{ goal.name }}</strong>' +
              '<span class="cep-sub" ng-if="goal.complete" style="color:var(--ok)">Completed</span></div>' +
            '<div class="cep-sub">{{ fmt.text(goal.detail) }}</div></div>' +
          '<div class="cep-card" ng-if="career.trucking"><div class="cep-label">Freight</div>' +
            '<div class="cep-name">{{ career.trucking.label }}</div>' +
            '<div class="cep-sub" ng-if="career.trucking.van < career.trucking.vanGoal">Van hauls {{ career.trucking.van }} / {{ career.trucking.vanGoal }} to unlock rigid trucks</div>' +
            '<div class="cep-pills" ng-if="career.trucking.van >= career.trucking.vanGoal"><span>{{ career.trucking.van }} van hauls</span><span>Box trucks unlocked</span></div>' +
            '<div class="cep-sub" ng-if="career.trucking.rigid < career.trucking.rigidGoal">Rigid hauls {{ career.trucking.rigid }} / {{ career.trucking.rigidGoal }} to unlock semis</div>' +
            '<div class="cep-pills" ng-if="career.trucking.rigid >= career.trucking.rigidGoal"><span>{{ career.trucking.rigid }} box truck hauls</span><span>Semis unlocked</span></div>' +
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
              '<div class="cep-keyval" ng-repeat="src in career.debtInfo.sources track by src.kind"><span>{{ src.label }}<span class="cep-pills" ng-if="src.count > 1"><span>{{ src.count }} charges</span></span></span><strong class="cep-debit" style="white-space:nowrap;margin-left:12px">{{ fmt.money(src.amount) }}</strong></div>' +
              '<button class="cep-sm ghost" ng-click="toggleDebtCharges()">{{ debtCharges ? "Hide the charges" : "Show each charge" }}</button>' +
              '<div ng-if="debtCharges"><div class="cep-keyval" ng-repeat="ch in career.debtInfo.open track by $index"><span>{{ fmt.text(ch.what) }}<span class="cep-pills" ng-if="ch.at"><span>{{ ch.at }}</span></span></span><strong class="cep-debit" style="white-space:nowrap;margin-left:12px">{{ fmt.money(ch.left) }}</strong></div></div>' +
              '<div class="cep-row" style="margin-top:6px"><button class="cep-sm" ng-if="!s.company" ng-disabled="!(s.money > 0)" ng-click="payDebt()">Pay what I can</button>' +
                '<button class="cep-sm ghost" ng-click="setTab(\'garage\')">Garage</button></div></div>' +
            '<div ng-if="career.debtInfo.log.length"><div class="cep-label" style="margin-top:8px">Debt history</div>' +
              '<div class="cep-keyval" ng-repeat="e in career.debtInfo.log track by $index"><span>{{ fmt.text(e.what) || (e.amount > 0 ? "Added" : "Paid") }}<span class="cep-pills"><span>{{ e.at }}</span><span>Owed after {{ fmt.money(e.left) }}</span></span></span>' +
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
            '<div class="cep-pills"><span>Last {{ mapData.count }} drop-offs</span><span>North is up</span><span>About {{ fmt.num(mapData.spanKm) }} km across</span></div></div>' +
          '<div class="cep-label">Personal records</div>' +
          '<div class="cep-card">' +
            '<div class="cep-keyval"><span class="cep-sub">Five-star run</span><strong>{{ mapData.records.streak }} now, best {{ mapData.records.bestStreak }}</strong></div>' +
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
            '<div class="cep-name" style="white-space:normal">{{ places.home.name }}</div><div class="cep-sub" ng-if="places.home.town && places.home.name.indexOf(places.home.town) < 0">{{ places.home.town }}</div>' +
            '<div class="cep-sub">{{ places.used }} / {{ places.capacity || places.home.capacity }} owned vehicles. {{ places.atHome ? "You are home." : fmt.num(places.homeKm) + " km away." }}</div>' +
            '<div class="cep-sub" ng-if="places.homeInfo">{{ places.homeInfo.levelName }}<span ng-if="places.homeInfo.rested"> · Rested, {{ places.homeInfo.rested }} min left</span></div>' +
            '<button class="cep-btn go" ng-click="openHome()">Open home</button>' +
          '</div>' +
          '<div class="cep-label">{{ places.home ? "Move your home garage" : "Choose your home garage" }}</div>' +
          '<div class="cep-sub">Park your career car where you want your garage, then set it here. A home is never needed: it gives room for more cars and cheaper repairs, servicing and fuel there.</div>' +
          '<div class="cep-sub" ng-if="!places.started">Start a career on the phone first.</div>' +
          '</div>' +
          '<div ng-if="panel === \'companies\'" style="display:flex;flex-direction:column;gap:8px">' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'loading\' || places.discovery.state === \'searching\'">Finding workplaces around you…</div>' +
          '<div class="cep-sub" ng-if="places.discovery.state === \'off\'">Start the Cargo Earth helper to find workplaces here.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.supportsDepots === false">Update the helper to 0.3.0 for workplace discovery.</div>' +
          '<div class="cep-sub" ng-if="places.discovery.msg">{{ fmt.text(places.discovery.msg) }}</div>' +
          '<div class="cep-sub">The company lends you a van, or a truck once you unlock it, and pays its costs. You get 80 % of the delivery pay when the work ends; damaged loads pay less, ruined ones nothing.</div>' +
          '<div class="cep-card" ng-if="places.shift"><div class="cep-name" style="white-space:normal">{{ places.shift.company }}</div>' +
            '<div class="cep-label" ng-if="places.shift.ownerOperator">Your own {{ places.shift.vehicle || "van" }}</div>' +
            '<div class="cep-pills"><span>{{ places.shift.completed }} of {{ places.shift.total }} deliveries</span><span>{{ fmt.money(places.shift.held) }} held</span></div>' +
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
            '<div class="cep-sub" ng-if="!places.canContract">Start your career in Garage first.</div>' +
            '<div class="cep-empty cep-sub" ng-if="!places.companies.length">No contracts nearby yet. Try again in a moment or somewhere else.</div>' +
            '<div class="cep-card" ng-repeat="company in places.companies track by company.id">' +
              '<div class="cep-name" style="white-space:normal">{{ company.name }}</div>' +
              '<div class="cep-pills"><span>{{ company.vehicle }}</span><span>Yard {{ fmt.num(company.km) }} km</span><span>2 deliveries</span><span>About {{ company.minutes }} min</span></div>' +
              '<div class="cep-keyval"><span class="cep-sub">Wages</span><strong>about {{ fmt.money(company.wages) }}</strong></div>' +
              '<div class="cep-sub">Reputation {{ company.reputation }} / 100</div>' +
              '<button class="cep-sm ghost" ng-disabled="places.busy" ng-click="pdo(\'companyGps\', company.id)">Route to yard</button>' +
              '<button class="cep-btn go" ng-disabled="places.busy || !places.canContract || !company.atYard" ng-click="pdo(\'startCompany\', company.id)">' +
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
        '<div class="cep-actionbar" aria-label="Home garage actions" ng-if="panel === \'home\' && places.started && !places.blocked">' +
          '<button class="cep-btn go" ng-disabled="places.busy || places.shift" ng-click="claimHome()">' +
            '{{ homeAsk ? "Press again: move home here" : (places.home ? "Move home here" : "Make this spot my home") }}</button>' +
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
          '<button ng-class="{on: gview === \'cars\'}" ng-click="openCars()">Used cars</button>' +
          '<button ng-class="{on: gview === \'trailers\'}" ng-click="openTrailers()">Trailers</button></div>' +
        '<div ng-if="g && !g.started" class="cep-center">' +
          '<div class="cep-label">Your career</div><div class="cep-big">Start with an old {{ g.starter }}</div>' +
          '<div class="cep-sub">You get the cheapest {{ g.starter }} and {{ fmt.money(g.startMoney) }}. Free play money, ratings and stats do not carry over. ' +
          'Orders then only come while you drive this car. Buy parts and better cars from what you earn.</div>' +
          '<div class="cep-sub" ng-if="g.busy" style="color:var(--tomato)">Your current order will be cancelled (no fee).</div>' +
        '</div><button class="cep-btn go" ng-if="g && !g.started" ng-click="gdo(\'start\')">Start my career</button>' +
        '<div ng-if="g && g.started && gview === \'home\' && g.preview && !g.parts" class="cep-scroll">' +
          '<div class="cep-card"><div class="cep-label">For sale, you are sitting in it</div>' +
            '<div class="cep-name" style="font-size:17px;white-space:normal">{{ g.preview.name }}</div>' +
            '<div class="cep-pills"><span>{{ fmt.int(g.preview.km) }} km</span><span>Condition {{ fmt.cond(g.preview.condition) }}</span></div>' +
            '<div class="cep-time" style="height:4px;margin-top:6px" ng-class="{warn: g.preview.condition < 0.6, late: g.preview.condition < 0.35}">' +
              '<i ng-style="{width: (g.preview.condition * 100) + \'%\'}"></i></div></div>' +
          '<div class="cep-label">Missing parts</div>' +
          '<div class="cep-sub" ng-if="g.preview.error">{{ g.preview.error }}</div>' +
          '<div class="cep-sub" ng-if="!g.preview.ready && !g.preview.error">Checking the car…</div>' +
          '<div class="cep-sub" ng-if="g.preview.ready && !g.preview.missing.length">Nothing missing.</div>' +
          '<div class="cep-sub" ng-if="g.preview.missing.length" style="color:var(--ink)">{{ g.preview.missing.join(", ") }}</div>' +
          '<div class="cep-pills" ng-if="g.preview.paint"><span>Paint: {{ g.preview.paint }}</span></div>' +
          '<div class="cep-label" ng-if="g.preview.faults.length">Worn components</div>' +
          '<div class="cep-li" ng-repeat="f in g.preview.faults track by f.id"><div><div class="cep-name">{{ f.name }}</div>' +
            '<small>{{ f.text }} Fixing it: about {{ fmt.money(f.cost) }}.</small></div></div>' +
          '<div class="cep-sub">Price {{ fmt.money(g.preview.price) }}<span ng-if="g.preview.tradeIn > 0">, your car is taken in for ' +
            '{{ fmt.money(g.preview.tradeIn) }}: you pay {{ fmt.money(g.preview.price - g.preview.tradeIn) }}</span>.</div>' +
          '<div class="cep-sub" ng-if="g.preview.keepCar">Your current car will be parked in My cars.</div>' +
        '</div>' +

        '<div ng-if="g && g.started && gview === \'home\' && !g.preview && !g.parts" class="cep-scroll">' +
          '<div class="cep-card" ng-if="g.car"><div class="cep-label">Your car</div><div class="cep-name" style="font-size:17px;white-space:normal">{{ g.car }}</div>' +
            '<div class="cep-pills"><span>{{ fmt.int(g.km) }} km</span><span ng-if="g.own">Condition {{ fmt.cond(g.condition) }}</span><span ng-if="g.own">Worth about {{ fmt.money(g.value) }}</span></div>' +
            '<div class="cep-sub" ng-if="!g.own" style="color:var(--tomato)">You are not in it. Orders only come in your own car.</div></div>' +
          '<div class="cep-card" ng-if="g.own && s.storage.capacity">' +
            '<div class="cep-label">Cargo space</div>' +
            '<div class="cep-pills" ng-if="s.storage.boxes"><span>{{ s.storage.boxes }} cargo box{{ s.storage.boxes > 1 ? "es" : "" }}</span>' +
              '<span>{{ s.storage.capacity }} slots</span><span>{{ fmt.num(s.storage.kg) }} kg loaded</span></div>' +
            '<div class="cep-sub" ng-if="!s.storage.boxes">Starter bag with 1 slot. Fit a parcel box in the Parts shop to carry more.</div></div>' +
          '<div class="cep-card" ng-if="g.fuel"><div class="cep-keyval"><span class="cep-label">{{ g.fuel.unit === "kWh" ? "Battery" : "Fuel" }}</span>' +
              '<strong ng-if="!g.fuel.reading">{{ fmt.num(g.fuel.have) }} / {{ fmt.num(g.fuel.cap) }} {{ g.fuel.unit }}</strong></div>' +
            '<div class="cep-sub" ng-if="g.fuel.reading">Reading the fuel gauge…</div>' +
            '<div ng-if="!g.fuel.reading">' +
              '<div class="cep-time" role="progressbar" aria-label="Fuel level" aria-valuemin="0" aria-valuemax="100" ng-attr-aria-valuenow="{{ fmt.int(g.fuel.share * 100) }}" ' +
                'ng-class="{warn: g.fuel.low && !g.fuel.empty, late: g.fuel.empty}"><i ng-style="{width: (g.fuel.share * 100) + \'%\'}"></i></div>' +
              '<div class="cep-pills"><span>About {{ g.fuel.rangeKm }} km left</span>' +
                '<span>{{ g.fuel.per100 ? fmt.num(g.fuel.per100) + " " + g.fuel.unit + "/100 km" : "Average use after 5 km" }}</span></div>' +
              '<div class="cep-sub" ng-if="g.fuel.per100">Running cost about {{ fmt.price(g.fuel.costPerKm) }} per km.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.free">Company fuel card: free fuel.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.empty" style="color:var(--tomato)">The tank is empty.</div>' +
              '<div class="cep-sub" ng-if="g.fuel.locked">This tank cannot be filled from here; use a pump.</div>' +
              '<div ng-if="g.fuel.station"><div class="cep-name" style="white-space:normal;margin-top:6px">{{ g.fuel.station.name }}</div>' +
                '<div class="cep-pills"><span>{{ g.fuel.station.at ? "You are at the pumps" : fmt.num(g.fuel.station.km) + " km away" }}</span>' +
                  '<span>{{ fmt.price(g.fuel.station.price) }} per {{ g.fuel.unit }}</span></div></div>' +
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
          // insurance (cargoEarth/insurance): your own cars only; a claim pays the repair minus the deductible.
          // One line on what it does, the full rules folded under "How it works" (Jan: quick to read).
          '<div class="cep-card" ng-if="g.insurance.car && g.own"><div class="cep-label">Insurance</div>' +
            '<div class="cep-name" style="font-size:15px">{{ g.insurance.car.insured ? "🛡 Insured" : "Not insured" }}</div>' +
            '<div class="cep-pills"><span>{{ fmt.money(g.insurance.car.week) }} a week</span><span>Rate {{ g.insurance.rate }} %</span><span ng-if="g.insurance.surcharge" title="A recent claim: back to {{ g.insurance.baseRate }} % after {{ g.insurance.surchargeHours }} hours of play">Claim surcharge</span>' +
              '<span ng-if="g.insurance.car.cover > 0">Covered now {{ fmt.money(g.insurance.car.cover) }}</span></div>' +
            '<div class="cep-sub">Pays {{ 100 - g.insurance.deductible * 100 | number:0 }} % of your crash repairs and tows a wrecked car home for free.</div>' +
            '<div class="cep-row" style="margin-top:6px">' +
              '<button class="cep-sm go" ng-if="!g.insurance.car.insured" ng-disabled="g.insurance.car.why || g.money < g.insurance.car.day" ng-click="gdo(\'insure\')">Insure · {{ fmt.money(g.insurance.car.day) }} now</button>' +
              '<button class="cep-sm" ng-if="g.insurance.car.wreck && g.insurance.home" ng-click="gdo(\'tow\', \'home\')">Free tow home</button>' +
              '<button class="cep-sm" ng-if="g.insurance.car.wreck && g.insurance.hq" ng-click="gdo(\'tow\', \'hq\')">Free tow to HQ</button>' +
              '<button class="cep-sm ghost" ng-if="g.insurance.car.insured" ng-click="gdo(\'uninsure\')">End insurance</button></div>' +
            '<small ng-if="!g.insurance.car.insured && g.insurance.car.why">{{ g.insurance.car.why }}</small>' +
            '<div class="cep-li" ng-repeat="pc in g.insurance.parked track by pc.id"><div><div class="cep-name">{{ pc.name }}</div><div class="cep-pills"><span>Parked, insured</span><span>{{ fmt.money(pc.week) }} a week</span></div></div>' +
              '<button class="cep-sm ghost" ng-click="gdo(\'uninsure\', pc.id)">End</button></div>' +
            '<div class="cep-pills" ng-if="g.insurance.claims > 0"><span>Claims {{ g.insurance.claims }}</span><span>Insurance paid {{ fmt.money(g.insurance.received) }}</span><span>Premiums {{ fmt.money(g.insurance.paid) }}</span></div>' +
            '<button class="cep-sm ghost" style="width:100%;margin-top:6px;min-height:26px;padding:4px" ng-click="cf.insHelp = !cf.insHelp">{{ cf.insHelp ? "Hide how it works ▴" : "How it works ▾" }}</button>' +
            '<div class="cep-ins-help" ng-if="cf.insHelp">' +
              '<div><b>Price.</b> {{ g.insurance.rate }} % of the car\'s value per week ({{ g.insurance.weekHours }} hours of play), charged hourly, also while the car is parked.</div>' +
              '<div><b>Buying.</b> In your own car, stopped, with no job running. It covers you at once.</div>' +
              '<div><b>Claims.</b> Repairing pays the real repair bill minus {{ g.insurance.deductible * 100 | number:0 }} %. "Pay it all yourself" makes no claim.</div>' +
              '<div><b>Your rate.</b> Each claim adds {{ g.insurance.claimUp }} % for {{ g.insurance.surchargeHours }} hours of play. Each week without a claim takes {{ g.insurance.cleanDown }} % off ({{ g.insurance.rateMin }}–{{ g.insurance.rateMax }} %).</div>' +
              '<div><b>Speeding.</b> The insurer is lenient: up to {{ g.insurance.leniency }} km/h over the limit is fine. Crashes at higher speeds are cut or refused.</div>' +
              '<div><b>Write-off.</b> A free tow home or to your headquarters.</div>' +
              '<div><b>Not covered.</b> Wear, servicing, faults the car came with, breakdowns, fuel. Company and hired drivers\' vehicles have their own cover.</div>' +
            '</div>' +
          '</div>' +
          '<div class="cep-card" ng-if="g.breakdown" role="alert" style="box-shadow:inset 0 0 0 1.5px var(--tomato)"><div class="cep-label" style="color:var(--tomato)">Breakdown</div>' +
            '<div class="cep-sub">{{ fmt.text(g.breakdown.text) }}</div>' +
          '</div>' +
          '<div class="cep-li" ng-if="g.upkeep && g.own"><div><div class="cep-name">Service</div>' +
            '<div class="cep-pills"><span ng-repeat="it in g.upkeep.items track by it.id" ng-class="{late: it.due}">{{ it.name }}: {{ it.due ? "overdue" : fmt.int(it.kmLeft) + " km" }}</span></div>' +
            '<div><small ng-if="g.upkeep.due > 0 && !g.upkeep.where">Service at a fuel station or your headquarters. Overdue parts can break down.</small></div></div>' +
            '<button class="cep-sm go" ng-if="g.upkeep.due > 0" ng-disabled="!g.upkeep.where || g.money < g.upkeep.dueCost" ng-click="gdo(\'service\')">Service {{ fmt.money(g.upkeep.dueCost) }}</button></div>' +
          '<div class="cep-li" ng-repeat="f in g.faults track by f.id" ng-if="g.own"><div><div class="cep-name">{{ f.name }}</div>' +
            '<small>{{ f.text }}</small>' +
            '<div><small ng-if="!f.service && !g.upkeep.where">Repair it at a fuel station, your home workshop or your headquarters.</small></div></div>' +
            '<button class="cep-sm go" ng-if="!f.service" ng-disabled="!g.upkeep.where || g.money < f.cost" ng-click="gdo(\'fixFault\', f.id)">Repair {{ fmt.money(f.cost) }}</button></div>' +
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
          '<div class="cep-sub" ng-if="g.parts.owed">The car owes {{ fmt.money(g.parts.owed) }} of repairs. Parts you swap come new; the damage on every other part stays, and so does its share of the bill.</div>' +
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
            '<div class="cep-pills"><span>Active car</span><span>{{ fmt.int(g.km) }} km</span></div></div>' +
          '<div class="cep-card"><div class="cep-label">Drivers</div>' +
            '<div class="cep-sub" ng-if="!g.fleet.unlocked">Only a firm with a headquarters can hire drivers (Menu → Firm).</div>' +
            '<div class="cep-sub" ng-if="g.fleet.unlocked">Hire them in the headquarters, where you pick who drives what.</div>' +
            '<div class="cep-sub" ng-if="g.fleet.earned > 0">Drivers have earned {{ fmt.money(g.fleet.earned) }}</div></div>' +
          '<div class="cep-sub" ng-if="!g.fleet.cars.length">No other cars yet. Tick "Keep my current car" when buying one.</div>' +
          '<div class="cep-sub" ng-if="g.busy && g.fleet.cars.length">Finish your orders before switching cars.</div>' +
          '<div class="cep-card" ng-repeat="v in g.fleet.cars track by v.id">' +
            '<div class="cep-name" style="white-space:normal">{{ v.name }}</div>' +
            '<div class="cep-pills"><span>{{ fmt.int(v.km) }} km</span><span>{{ v.driver ? "With a driver" : "Parked" }}</span><span ng-if="v.storageSlots">{{ v.boxCount ? v.boxCount + " fitted boxes" : "Starter bag" }}</span><span ng-if="v.storageSlots">{{ v.storageSlots }} slots</span></div>' +
                                    '<div class="cep-sub" ng-if="v.repair > 0">Needs {{ fmt.money(v.repair) }} of repairs.</div>' +
            '<div class="cep-pills" ng-if="v.driver"><span>{{ v.driver.name }}</span><span>Earned {{ fmt.money(v.driver.earned) }}</span><span ng-class="{warn: v.driver.waiting}">{{ v.driver.waiting === "repair" ? "Waiting for a repair" : (v.driver.waiting === "trailer" ? "Needs a trailer" : (v.driver.waiting === "licence" ? "No licence for it" : (v.driver.waiting === "boxes" ? "Needs cargo boxes" : "Next shift in " + v.driver.nextMin + " min"))) }}</span></div>' +
            '<div class="cep-sub" ng-if="v.upkeep && v.upkeep.due > 0" style="color:var(--tomato)">Service due: {{ fmt.money(v.upkeep.dueCost) }} at the headquarters</div>' +
            '<div class="cep-row" style="margin-top:6px">' +
              '<button class="cep-sm go" ng-if="!v.driver" ng-disabled="g.busy" ng-click="gdo(\'switchCar\', v.id)">Drive</button>' +
              '<button class="cep-sm" ng-if="g.fleet.unlocked && !v.driver && !v.loaner" ng-click="openHq()">Hire a driver</button>' +
              '<button class="cep-sm ghost" ng-if="v.driver" ng-click="gdo(\'releaseDriver\', v.id)">Release driver</button></div>' +
          '</div></div>' +
        // your trailers (the pool you share with hired drivers): spots at home, take out / park, the shops
        '<div ng-if="g && g.started && gview === \'trailers\' && !g.parts" class="cep-scroll">' +
          '<div class="cep-sub" ng-if="!tp">Loading your trailers.</div>' +
          '<div class="cep-msg" ng-if="tp.msg">{{ fmt.text(tp.msg) }}</div>' +
          '<div class="cep-card" ng-if="tp && !tp.none"><div class="cep-label">Trailer spots</div>' +
            '<div class="cep-sub" ng-if="!tp.home">Trailers need a home garage: set one in Menu → Home first. The basic home has room for one.</div>' +
            '<div class="cep-pills" ng-if="tp.home"><span>Home: {{ tp.homeSpots }}</span><span ng-if="tp.hqSpots">Headquarters: {{ tp.hqSpots }}</span><span>Owned: {{ tp.owned }}</span>' +
              '<span ng-if="tp.at">You are {{ tp.at === "home" ? "at home" : "at the headquarters" }}</span></div>' +
            '<div class="cep-sub" ng-if="tp.home && !tp.room">Every spot is taken. A bigger home or a Trailer yard room gives more.</div></div>' +
          '<div class="cep-card" ng-repeat="t in tp.list track by t.id">' +
            '<div class="cep-name" style="white-space:normal">{{ t.name }}</div>' +
            '<div class="cep-pills"><span>{{ t.place === "home" ? "At home" : t.place === "hq" ? "At the headquarters" : t.place === "out" ? (t.hitched ? "On your hitch" : "Out, not hitched") : t.place === "driver" ? "With a driver" : (t.at || "Left somewhere") }}</span>' +
              '<span>{{ fmt.int(t.km) }} km</span><span>{{ fmt.int(t.condition * 100) }} %</span><span ng-if="t.bulk">Bulk boxes</span>' +
              '<span ng-if="t.km_away !== undefined && !t.near">{{ t.km_away }} km away</span></div>' +
            '<div class="cep-sub" ng-if="t.carries">{{ t.carries }}</div>' +
            '<div class="cep-sub" ng-if="t.loaded">Loaded: {{ t.loaded }}</div>' +
            '<div class="cep-sub" ng-if="t.needs">{{ t.needs }}</div>' +
            '<div class="cep-sub" ng-if="t.repair > 0" style="color:var(--tomato)">Damage: {{ fmt.money(t.repair) }} of repairs</div>' +
            '<div class="cep-sub" ng-if="t.upkeep && t.upkeep.due > 0" style="color:var(--tomato)">Service due ({{ fmt.money(t.serviceCost || t.upkeep.dueCost) }})</div>' +
            '<div class="cep-row" style="margin-top:6px;flex-wrap:wrap">' +
              '<button class="cep-sm go" ng-if="t.place !== \'out\'" ng-disabled="!t.canTake" ng-click="tdo(\'takeOut\', t.id)">Take out</button>' +
              '<button class="cep-sm" ng-if="t.place !== \'out\' && t.canBulk" ng-disabled="!t.canTake" title="With 16 aggregate boxes for gravel, sand and grain" ng-click="tdo(\'takeOut\', t.id, \'bulk\')">Take out for bulk</button>' +
              '<button class="cep-sm go" ng-if="t.place === \'out\'" ng-disabled="!t.canPark" title="At home or at the headquarters" ng-click="tdo(\'park\', t.id)">Park it here</button>' +
              '<button class="cep-sm" ng-if="t.place === \'out\' && !t.hitched" ng-click="tdo(\'hitch\', t.id)">Hitch</button>' +
              '<button class="cep-sm" ng-if="t.place === \'left\' && t.fetch" ng-click="tdo(\'fetch\', t.id)">Bring it home · {{ fmt.money(t.fetch) }}</button>' +
              '<button class="cep-sm" ng-if="t.canService" ng-click="tdo(\'service\', t.id)">Service · {{ fmt.money(t.serviceCost) }}</button>' +
              '<button class="cep-sm" ng-if="t.repair > 0 && t.repairCost" ng-click="tdo(\'repair\', t.id)">Repair · {{ fmt.money(t.repairCost) }}</button>' +
              '<button class="cep-sm ghost" ng-if="t.place === \'home\' || t.place === \'hq\'" ng-click="tdo(\'sell\', t.id)">Sell · {{ fmt.money(t.sellFor) }}</button></div>' +
          '</div>' +
          '<div class="cep-label" ng-if="tp.used.length">Used trailers</div>' +
          '<div class="cep-card" ng-repeat="u in tp.used track by u.id">' +
            '<div class="cep-keyval"><strong style="white-space:normal">{{ u.name }}</strong><strong style="white-space:nowrap">{{ fmt.money(u.price) }}</strong></div>' +
            '<div class="cep-pills"><span>{{ fmt.int(u.km) }} km</span><span>{{ fmt.int(u.condition * 100) }} %</span><span ng-if="u.faults.tyres">Worn tyres</span><span ng-if="u.faults.brakes">Worn brakes</span>' +
              '<span ng-if="u.body > 0">Body damage {{ fmt.money(u.body) }}</span></div>' +
            '<div class="cep-sub">At {{ u.seller }}<span ng-if="u.away !== undefined"> · {{ u.away }} km</span> · listed for {{ u.minutesLeft }} more min</div>' +
            '<button class="cep-sm go" style="margin-top:6px" ng-disabled="!u.can" ng-click="tdo(\'buyUsed\', u.id)">Buy</button></div>' +
          '<div class="cep-label" ng-if="tp.shop.length">New trailers</div>' +
          '<div class="cep-card" ng-repeat="n in tp.shop track by n.id">' +
            '<div class="cep-keyval"><strong style="white-space:normal">{{ n.name }}</strong><strong style="white-space:nowrap">{{ fmt.money(n.price) }}</strong></div>' +
            '<div class="cep-pills"><span>{{ n.pulls === "semi" ? "Tractor" : "Tow hitch" }}</span><span ng-if="n.boxes">{{ n.boxes }} cargo boxes</span>' +
              '<span ng-if="n.payload">{{ fmt.kg(n.payload) }}</span></div>' +
            '<div class="cep-sub" ng-if="n.carries">{{ n.carries }}</div>' +
            '<button class="cep-sm go" style="margin-top:6px" ng-disabled="!n.can" ng-click="tdo(\'buyNew\', n.id)">Buy new</button></div>' +
        '</div>' +
        '<div ng-if="g && g.started && gview === \'cars\' && !g.parts" class="cep-scroll cep-market-list">' +
          // the car being looked at stays on top of the list, so the next one is a tap away
          '<div class="cep-card" ng-if="g.preview"><div class="cep-label">Looking at</div>' +
            '<div class="cep-keyval"><strong style="white-space:normal">{{ g.preview.name }}</strong><strong style="white-space:nowrap">{{ fmt.money(g.preview.price - (g.preview.tradeIn || 0)) }}</strong></div>' +
            '<div class="cep-sub" ng-if="g.preview.keepCar">Your current car will be parked in My cars.</div>' +
            '<div class="cep-sub" ng-if="!g.preview.keepCar && g.preview.tradeIn > 0">Trade-in credit: {{ fmt.money(g.preview.tradeIn) }}</div>' +
            '<div class="cep-sub" ng-if="!g.preview.ready && !g.preview.error">Checking the car…</div>' +
            '<div class="cep-sub" ng-if="g.preview.error">{{ g.preview.error }}</div>' +
          '</div>' +

          '<div class="cep-row"><button class="cep-sm ghost" ng-click="goHome()">‹ Back</button>' +
            '<input class="cep-input" placeholder="Find a car" aria-label="Find a car" ng-model="cf.text">' +
            '<button class="cep-sm" ng-click="loadCars()">Search</button></div>' +
          '<label class="cep-sub" ng-if="market.tradeIn > 0 && !g.preview"><input type="checkbox" ng-model="purchase.keep"> Keep my current car</label>' +
          '<div class="cep-sub" ng-if="market.tradeIn > 0 && !purchase.keep && !g.preview"><span ng-if="market.repair">Before repairs {{ fmt.money(market.tradeGross) }}, repair bill {{ fmt.money(market.repair) }}<br></span>Trade-in credit: {{ fmt.money(market.tradeIn) }}</div>' +
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
            '<div class="cep-pills"><span>{{ fmt.int(c.km) }} km</span><span>Condition {{ fmt.cond(c.condition) }}</span>' +
              '<span ng-if="c.missing !== undefined && c.missing !== null" ng-class="{warn: c.missing > 0}">{{ c.missing }} parts missing</span>' +
              '<span ng-repeat="f in c.faults track by f.id" class="warn" title="{{ f.text }} Fixing it: about {{ fmt.money(f.cost) }}.">{{ f.name }}</span></div>' +
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
            '<button class="cep-btn go" ng-disabled="!(g.repair > 0)" ng-click="gdo(\'repair\')">{{ g.repair > 0 ? (g.repairInsured ? "Repair with insurance: " + fmt.money(g.repairCost - g.repairInsured) : "Repair: " + fmt.money(g.repair)) : "No damage" }}</button></div>' +
          '<button class="cep-sm ghost" ng-if="g.own && g.repairInsured" style="width:100%;margin-top:6px" title="No claim: your insurance rate stays as it is" ng-click="gdo(\'repairOwn\')">Pay it all yourself · {{ fmt.money(g.repairCost) }}</button>' +
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
        "<button class=\"cep-sm ghost\" ng-if=\"jobsSettingsOpen\" ng-click=\"closeJobsSettings()\">Back to Settings</button>" +
        "<div class=\"cep-scroll\" ng-if=\"!st.reviewingParts\">" +
        "<div ng-if=\"jobsSettingsOpen\" aria-label=\"Jobs settings\">" +
        "<div class=\"cep-sub\" ng-if=\"st.paused\">Load a career to edit its job settings.</div><div ng-if=\"!st.paused\">" +
        "<div class=\"cep-modes\" ng-keydown=\"$event.keyCode === 27 && (modePicker.jobs = false)\"><span>Job type to configure</span>" +
        "<button class=\"cep-mode-select cep-job-select\" aria-label=\"Job type to configure\" aria-haspopup=\"menu\" aria-expanded=\"{{ modePicker.jobs }}\" ng-click=\"modePicker.jobs = !modePicker.jobs\">{{ jobTypeName() }}<b aria-hidden=\"true\">▾</b></button>" +
        "<div class=\"cep-mode-menu\" role=\"menu\" aria-label=\"Job settings categories\" ng-if=\"modePicker.jobs\">" +
        "<button ng-repeat=\"m in st.jobTypes\" role=\"menuitemradio\" aria-checked=\"{{ st.jobType === m.id }}\" ng-class=\"{on: st.jobType === m.id}\" ng-click=\"chooseJobSettings(m.id)\">{{ m.name }}</button></div></div>" +
        "<div class=\"cep-sub\">{{ st.jobHint }}</div>" +
        "<div ng-repeat=\"it in st.items\"><div class=\"cep-card cep-km\" ng-if=\"it.unit === 'km'\"><div class=\"cep-keyval\"><span class=\"cep-label\">{{ it.label }}</span>" +
        "<small>{{ fmt.num(it.min) }}–{{ fmt.num(it.max) }} km</small></div><div class=\"cep-km-row\">" +
        "<button class=\"cep-sm ghost\" aria-label=\"Less\" ng-click=\"nudgeDraft(it, -1)\">−</button>" +
        "<input class=\"cep-input cep-job-input\" type=\"number\" step=\"any\" min=\"{{ it.min }}\" max=\"{{ it.max }}\" aria-label=\"{{ it.label }} in kilometres\" ng-model=\"jobDraft()[it.key]\"><span>km</span>" +
        "<button class=\"cep-sm ghost\" aria-label=\"More\" ng-click=\"nudgeDraft(it, 1)\">+</button></div></div>" +
        "<div class=\"cep-li\" ng-if=\"it.unit !== 'km'\" style=\"cursor:default\"><div class=\"cep-name\">{{ it.label }}</div><div class=\"cep-step2\">" +
        "<button class=\"cep-sm ghost\" ng-click=\"sdo('step', it.key, -1)\">−</button><b>{{ it.value }}</b><button class=\"cep-sm ghost\" ng-click=\"sdo('step', it.key, 1)\">+</button></div></div></div>" +
        "<div class=\"cep-li\" ng-if=\"st.jobType === 'courier'\" ng-click=\"sdo('autoReach', !st.autoReach)\"><div><div class=\"cep-name\">Look further in the countryside</div><small>Automatically widen the search where restaurants are few</small></div><b>{{ st.autoReach ? \"On\" : \"Off\" }}</b></div>" +
        "<div class=\"cep-sub\" role=\"status\" ng-if=\"st.rangeError\">{{ st.rangeError }}</div><div class=\"cep-sub\" role=\"status\" ng-if=\"st.rangeSaved\">Distances saved for this job type.</div>" +
        "</div></div>" +
        "<div ng-if=\"!jobsSettingsOpen\"><button class=\"cep-btn ghost\" ng-click=\"openJobsSettings()\">Jobs settings</button>" +
        "<div class=\"cep-sub\" ng-if=\"st.paused\">Load a career to edit job settings, cameras and career progress.</div><div ng-if=\"!st.paused\">" +
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
        '<div class="cep-li" ng-if="st.dash.on" style="cursor:default"><div class="cep-name">Default position</div><div class="cep-row">' +
          '<button class="cep-sm" ng-class="{ghost: st.dash.where !== \'wheel\'}" ng-click="sdo(\'dash\', \'wheel\')">Behind wheel</button>' +
          '<button class="cep-sm" ng-class="{ghost: st.dash.where === \'wheel\'}" ng-click="sdo(\'dash\', \'middle\')">Center console</button></div></div>' +
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
        "</div></div>" +
        "<div class=\"cep-actionbar\" aria-label=\"Job settings actions\" ng-if=\"jobsSettingsOpen && !st.paused && !st.reviewingParts && st.jobType !== 'bus'\">" +
        "<button class=\"cep-btn go\" ng-disabled=\"!jobRangeValid()\" ng-click=\"saveJobRange()\">Apply distances</button>" +
        "<button class=\"cep-sm ghost\" ng-click=\"resetJobRange()\">Reset this job type</button></div>" +
        "</div>" +
      '</div></div></div>' +
      '<div class="cep-pill" ng-if="ready && min && !menuOnly" ng-click="fold(false)"><span>Cargo<b>Earth</b><span ng-if="radio.status === \'playing\'" style="font-weight:500"> ♪ {{ radio.station.name | limitTo: 18 }}</span></span>' +
        '<span><span class="cep-limit" ng-if="s.limit" ng-class="{over: s.limit.over}">{{ s.limit.sign }}</span>' +
        '{{ s.online ? "● online" : "" }} {{ fmt.money(s.money) }} ▴</span></div>' +
      '<div class="cep" ng-class="{dark: dark}" ng-if="ready && !min && !menuOnly"><div class="cep-screen">' +
      // one slim status row for everything around the content: clock and the job's settings on the left,
      // the speed limit, the balance and online on the right (the tabs at the bottom say whether this is Work or Radio)
      '<div class="cep-bar"><span class="cep-bar-l">{{ s.clock }}' +
        '<button class="cep-settings-link" title="{{ s.mode === \'courier\' ? \'Food delivery\' : \'Freight\' }} settings" ' +
          'aria-label="Job settings" ng-click="openJobsSettings()">⚙</button>' +
        // Unstuck: a free repair in place when Earth's roads wreck or trap the car (cargoEarth/garage M.unstuck)
        '<button class="cep-unstuck" ng-if="s.unstuck" ng-class="{wait: !s.unstuck.can}" ' +
          'title="{{ s.unstuck.why || \'Stuck or damaged by the road? Fix the car here for free\' }}" ng-click="act(\'unstuck\')">' +
          'Unstuck<small ng-if="s.unstuck.left > 0"> {{ unstuckMin() }}m</small></button></span>' +
        '<span class="cep-bar-r"><span class="cep-limit" ng-if="s.limit && !(tab === \'map\' && !panel && mapPrefs().speedo)" ng-class="{over: s.limit.over}" title="Speed limit here">{{ s.limit.sign }}' +
          '<small ng-if="s.limit.unit === \'mph\'">mph</small></span>' +
        '<strong class="cep-bal">{{ fmt.money(s.money) }}</strong>' +
        '<i class="cep-on" ng-if="s.online" title="Online"></i>' +
        '<button class="cep-min" title="Fold the phone" ng-if="!dash" ng-click="fold(true)">–</button></span></div>' +
      '<button class="cep-live" ng-if="showLiveShortcut()" ng-click="openLiveWork()">' +
        '<i class="cep-dot-live"></i><span><strong>{{ liveTitle() }}</strong><small>{{ liveDetail() }}</small></span>' +
        '<em class="cep-live-left" ng-if="liveLeft()"><strong>{{ liveLeft().dist }}</strong><small ng-if="liveLeft().time">{{ liveLeft().time }}</small></em>' +
        '<b aria-hidden="true">&rsaquo;</b></button>' +

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
      '<div class="cep-modes" role="radiogroup" aria-label="Job type"><div class="cep-subtabs cep-work-modes">' +
        '<button ng-repeat="m in workModes" role="radio" aria-checked="{{ s.mode === m.id }}" aria-label="{{ m.name }}" ng-class="{on: s.mode === m.id}" ' +
          'ng-disabled="!s.canSwitch && s.mode !== m.id" ng-attr-title="{{ m.tip }}" ng-click="chooseWorkMode(\'work\', m.id)">{{ m.short }}</button></div>' +
        '<small ng-if="!s.canSwitch">Finish or cancel the current job to switch.</small></div>' +
      // city bus lines: the lines near you (the bus is lent at a depot near the first stop), or the shift you are on
      '<div class="cep-scroll" ng-if="s.bus">' +
        '<div class="cep-card" ng-if="s.bus.shift"><div class="cep-label">{{ s.bus.shift.name }}</div>' +
          '<div class="cep-big" style="font-size:15px" ng-if="s.bus.shift.handover">Taking you back to {{ s.bus.shift.depot }}</div>' +
          '<div class="cep-sub" ng-if="s.bus.shift.handover">The bus is handed over. Your car is waiting at the depot.</div>' +
          '<div class="cep-big" style="font-size:15px" ng-if="!s.bus.shift.handover">Your bus is getting ready</div>' +
          '<div class="cep-sub" ng-if="s.bus.shift.error" style="color:var(--tomato)">{{ s.bus.shift.error }}</div>' +
        '</div>' +
        // city lines or intercity coaches (cargoEarth/coach): the same lent bus, doors and comfort
        '<div class="cep-subtabs" role="radiogroup" aria-label="Bus work" ng-if="!s.bus.shift && !s.bus.line">' +
          '<button role="radio" aria-checked="{{ s.bus.kind !== \'coach\' }}" ng-class="{on: s.bus.kind !== \'coach\'}" ng-disabled="s.bus.selected" ' +
            'ng-click="act(\'busKind\', \'lines\')">City lines</button>' +
          '<button role="radio" aria-checked="{{ s.bus.kind === \'coach\' }}" ng-class="{on: s.bus.kind === \'coach\'}" ng-disabled="s.bus.selected" ' +
            'ng-click="act(\'busKind\', \'coach\')">Coaches</button></div>' +
        '<div class="cep-label" ng-if="!s.bus.shift && s.bus.kind !== \'coach\'">Bus lines nearby</div>' +
        '<div class="cep-card" ng-if="s.bus.selected"><strong>{{ s.bus.selected.name }}</strong>' +
          '<div class="cep-sub">Park inside the marker at {{ s.bus.selected.depot }} for {{ s.bus.selected.leftS }} s. Your car will be stored, then replaced by the bus.</div>' +
          '<div class="cep-sub" ng-if="s.bus.selected.error" style="color:var(--tomato)">{{ s.bus.selected.error }}</div>' +
        '</div>' +
        '<div class="cep-sub" role="status" ng-if="!s.bus.shift && s.bus.kind !== \'coach\'">{{ busStatus(s.bus) }}</div>' +
        '<div class="cep-pills" ng-if="!s.bus.shift && s.bus.kind !== \'coach\' && s.bus.progress"><span>{{ s.bus.progress.ready }} of {{ s.bus.progress.total }} areas checked</span>' +
          '<span ng-if="s.bus.progress.queued">{{ s.bus.progress.queued }} queued</span>' +
          '<span ng-if="s.bus.progress.failed">{{ s.bus.progress.failed }} failed</span>' +
          '<span ng-if="s.bus.progress.loading">{{ s.bus.progress.elapsed }} s elapsed</span>' +
          '<span ng-if="s.bus.progress.server && s.bus.progress.loading">{{ s.bus.progress.server }} (server {{ s.bus.progress.attempt }})</span>' +
          '<span ng-if="s.bus.progress.failed && s.bus.progress.retryAfter">Automatic retry in {{ s.bus.progress.retryAfter }} s</span></div>' +
        '<div class="cep-sub" ng-if="!s.bus.shift && s.bus.kind !== \'coach\' && s.bus.error" style="color:var(--tomato);overflow-wrap:anywhere">{{ s.bus.error }}</div>' +
        '<div class="cep-sub" ng-if="s.bus.message" style="color:var(--tomato)">{{ s.bus.message }}</div>' +
        '<div class="cep-card" ng-repeat="l in s.bus.lines track by l.id">' +
          '<div class="cep-keyval"><strong style="white-space:normal"><span class="cep-busref" ng-style="badge(l.colour, l.textColour)">{{ l.ref || "Bus" }}</span> to {{ l.to }}</strong>' +
            '<strong style="white-space:nowrap">{{ fmt.money(l.pay) }}</strong></div>' +
          '<div class="cep-sub">From {{ l.from }}</div><div class="cep-pills"><span>{{ l.stops }} stops</span><span>{{ fmt.km(l.km) }}</span><span>About {{ l.minutes }} min</span><span ng-if="l.fares">+{{ fmt.money(l.fares) }} fares</span></div>' +
          '<div class="cep-sub" ng-if="l.singleDirection">Only this direction found in local map data.</div>' +
          '<div class="cep-sub" ng-if="l.limited">This shift serves the first {{ l.stops }} mapped stops.</div>' +
          '<div class="cep-sub">Bus at {{ l.depot }}</div><div class="cep-pills" ng-if="l.depotM !== undefined"><span>{{ fmt.dist(l.depotM).v }} {{ fmt.dist(l.depotM).u }} away</span></div>' +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm ghost" ng-click="act(\'busGps\', l.id)">Route</button>' +
            '<button class="cep-sm go" ng-click="act(\'busStart\', l.id)">Choose line</button></div></div>' +
        '<div class="cep-sub" ng-if="!s.bus.shift && s.bus.lines.length">Choose a line, then park your own car in its depot marker to collect the bus.</div>' +
        // intercity coaches: from the coach station near you to far towns
        '<div ng-if="s.bus.coach">' +
          '<div class="cep-label">Coach rides from {{ s.bus.coach.from ? s.bus.coach.from.n : "a station near you" }}</div>' +
          '<div class="cep-sub" role="status">{{ coachStatus(s.bus.coach) }}</div>' +
          '<div class="cep-card" ng-repeat="r in s.bus.coach.rides track by r.id">' +
            '<strong style="white-space:normal"><span class="cep-busref">Coach</span> to {{ r.town }}</strong>' +
            '<div class="cep-sub">{{ r.to }}{{ r.rail ? " (railway station)" : "" }}</div>' +
            '<div class="cep-pills" ng-if="r.depotM !== undefined"><span>Coach at {{ r.depot }}, {{ fmt.dist(r.depotM).v }} {{ fmt.dist(r.depotM).u }}</span></div>' +
            // one way and the return trip, each with its own figures and button
            '<div class="cep-coachtrip">' +
              '<div class="cep-keyval"><span class="cep-name">One way</span><strong style="white-space:nowrap">{{ fmt.money(r.pay) }}</strong></div>' +
              '<div class="cep-pills"><span>{{ fmt.km(r.km) }}</span><span>About {{ r.minutes }} min</span><span ng-if="r.fares">+{{ fmt.money(r.fares) }} fares</span></div>' +
              '<button class="cep-sm go" ng-click="act(\'busStart\', r.id)">Choose one way</button></div>' +
            '<div class="cep-coachtrip" ng-if="r.back">' +
              '<div class="cep-keyval"><span class="cep-name">Return trip</span><strong style="white-space:nowrap">{{ fmt.money(r.back.pay) }}</strong></div>' +
              '<div class="cep-pills"><span>{{ fmt.km(r.back.km) }}</span><span>About {{ r.back.minutes }} min</span><span ng-if="r.back.fares">+{{ fmt.money(r.back.fares) }} fares</span></div>' +
              '<button class="cep-sm go" ng-click="act(\'busStart\', r.back.id)">Choose return trip</button></div>' +
            '<button class="cep-sm ghost" style="margin-top:6px" ng-click="act(\'busGps\', r.id)">Route to the coach</button></div>' +
          '<div class="cep-sub" ng-if="s.bus.coach.rides.length">Choose a ride, then park your own car in the marker at the station to collect the coach. ' +
            'One way: everyone gets off at the far station and you are taken back to your car. Return trip: new passengers board there and you drive them back.</div>' +
        '</div>' +
      '</div>' +
      '<div class="cep-center" ng-if="!s.bus" ng-class="{\'cep-freight-summary\': s.trucking}">' +
        '<div class="cep-big">{{ s.trucking && !s.trucking.carrier ? "No work vehicle of your own" : "You are offline" }}</div>' +
        '<div class="cep-sub" ng-if="!s.taxi && (!s.trucking || !s.trucking.hint)">Go online to get orders from nearby {{ s.mode === "courier" ? "restaurants and shops" : "depots" }}.</div>' +
        '<div class="cep-sub" ng-if="s.taxi">{{ s.taxi.hint }}</div>' +
        '<div class="cep-sub" role="status" ng-if="s.taxi.eligible">{{ s.taxi.search }}</div>' +
        '<div class="cep-sub" ng-if="s.trucking.carrier">{{ s.trucking.carrier }}</div>' +
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
          '<div class="cep-pills"><span>{{ c.vehicle }}</span><span>Yard {{ fmt.km(c.km) }}</span><span>2 deliveries</span><span>About {{ c.minutes }} min</span></div>' +
          '<div class="cep-row" style="margin-top:6px"><button class="cep-sm ghost" ng-click="act(\'contractGps\', c.id)">Route</button>' +
            '<button class="cep-sm go" ng-disabled="!c.atYard" ng-click="act(\'contractStart\', c.id)">Start</button></div></div>' +
      '</div>' +
      '<button class="cep-sm ghost" ng-if="s.bus.shift && !s.bus.shift.handover" ng-click="act(\'busEnd\')">End shift</button>' +
      '<div class="cep-row" ng-if="s.bus && !s.bus.shift"><button class="cep-sm ghost" ng-if="s.bus.kind !== \'coach\'" ng-disabled="s.bus.state === \'loading\' && !(s.bus.progress && s.bus.progress.failed)" ng-click="act(\'busRetry\')">Retry bus search</button>' +
        '<button class="cep-sm ghost" ng-if="s.bus.kind === \'coach\' && !s.bus.selected" ng-click="act(\'coachRetry\')">Retry coach search</button>' +
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
        // why nothing comes: the helper is down or still loading, nothing within reach, or the distance settings (core.offerWhy)
        '<div class="cep-sub cep-why" role="status" ng-if="s.why">{{ s.why }}</div>' +
        '<div class="cep-sub" ng-if="!s.why && !s.trucking && !s.taxi && (!s.helper || s.helper.state === \'ready\')">The next order will ring here.</div>' +
        '<div class="cep-sub" ng-if="!s.why && !s.trucking && !s.taxi && s.helper && !s.helper.outdated && (s.helper.state === \'loading\' || s.helper.state === \'searching\')">' +
          '{{ s.helper.restaurants ? "Loading nearby pickup locations…" : "Loading nearby grocery stores…" }}</div>' +
        '<div class="cep-sub" ng-if="!s.why && !s.trucking && !s.taxi && s.helper && s.helper.state === \'off\'">' +
          '{{ s.helper.restaurants ? "Start the Cargo Earth helper to load nearby pickup locations." : "Start the Cargo Earth helper to get local grocery runs." }}' +
          '<span ng-if="s.helper.msg"> ({{ s.helper.msg }})</span></div>' +
        // the helper answers, but could not build this area (no Python libraries, no internet...): not "start it"
        '<div class="cep-sub" ng-if="!s.why && !s.trucking && !s.taxi && s.helper && s.helper.state === \'error\'">' +
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
            '(s.incoming.batch ? "Add to your route" : (s.incoming.kind === "food" ? "New food order" : (s.incoming.tow ? "Tow job" : (s.incoming.taxi ? "Taxi ride: " + (s.incoming.taxi.modeName || "Comfort") : "New freight job"))))) }}</div>' +
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
              '<div class="cep-pills"><span>{{ fmt.km(s.incoming.taxi.pickupRoadKm || s.incoming.pickupKm) }} away<span ng-if="s.incoming.taxi.pickupRoadKm !== undefined">{{ s.incoming.taxi.pickupEstimated ? " est. by road" : " by road" }}</span></span>' +
                '<span ng-if="s.incoming.from.town">{{ s.incoming.from.town }}</span></div></div>' +
            '<span><span class="cep-line"></span></span><span></span>' +
            '<span class="cep-dot to"></span><div><div class="cep-label">{{ s.incoming.route ? s.incoming.route.count + " drop-offs, nearest first" : "Drop-off" }}</div>' +
              '<div class="cep-name">{{ s.incoming.route ? s.incoming.route.stops[0].name + " and " + (s.incoming.route.count - 1) + " more" : s.incoming.to.name }}</div>' +
              '<div class="cep-meta">{{ s.incoming.route ? s.incoming.route.left + " parcels in your containers" : (s.incoming.to.town || s.incoming.to.label) }}</div></div>' +
          '</div></div>' +
          '<div class="cep-card" ng-if="s.incoming.items.length"><div class="cep-label">{{ s.incoming.orderType === "grocery" ? s.incoming.cargo : "In this order" }}' +
            '</div><div class="cep-pills" ng-if="s.incoming.slots"><span>{{ s.incoming.slots }} slot{{ s.incoming.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.incoming.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-pills" ng-if="!s.incoming.items.length"><span>{{ s.incoming.cargo }}</span><span ng-if="s.incoming.trailer">{{ s.incoming.trailer }}</span></div>' +
          '<div class="cep-sub" ng-if="s.incoming.freight">{{ fmt.freight(s.incoming.freight) }}</div>' +
          '<div class="cep-pills"><span>{{ fmt.km(s.incoming.km) }} trip</span><span>{{ s.incoming.minutes }} min to deliver</span>' +
            '<span ng-if="s.incoming.farPickup > 0 && !s.incoming.batch">+{{ fmt.money(s.incoming.farPickup) }} far pickup</span></div>' +
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
          '<div class="cep-row cep-load" ng-if="s.incoming.load" aria-label="How much to load">' +
            '<button class="cep-sm" ng-disabled="s.incoming.load.n <= 1" ng-click="act(\'loadSteps\', s.incoming.load.n - 1)" aria-label="Load less">−</button>' +
            '<span class="cep-sub" style="flex:1;text-align:center">{{ fmt.load(s.incoming.load) }}</span>' +
            '<button class="cep-sm" ng-disabled="s.incoming.load.n >= s.incoming.load.max" ng-click="act(\'loadSteps\', s.incoming.load.n + 1)" aria-label="Load more">+</button>' +
            '<button class="cep-sm ghost" ng-disabled="s.incoming.load.n >= s.incoming.load.max" ng-click="act(\'loadSteps\', s.incoming.load.max)">Full</button></div>' +
          '<div class="cep-sub" ng-if="s.incoming.resupplyBonus">+{{ fmt.money(s.incoming.resupplyBonus) }} from the station for {{ s.incoming.litres }} L</div>' +
          '<div class="cep-sub" ng-if="s.incoming.special"><b>{{ s.incoming.special.name }}:</b> +{{ fmt.money(s.incoming.special.bonus) }}. ' +
            '{{ s.incoming.special.note }}</div>' +
          '<div class="cep-sub" ng-if="s.incoming.fuelAllowance">+{{ fmt.money(s.incoming.fuelAllowance) }} toward your fuel</div>' +
          '<div class="cep-sub" ng-if="s.incoming.carBonus">+{{ fmt.money(s.incoming.carBonus) }} for a nicer car ({{ fmt.pct(s.incoming.carRate) }})</div>' +
          '<div class="cep-sub" ng-if="s.incoming.loadBonus < 0">Load {{ fmt.pct(s.incoming.loadFill) }} full: {{ fmt.money(s.incoming.loadBonus) }} (a fuller vehicle earns the full rate)</div>' +
          '<div class="cep-sub" ng-if="s.incoming.expBonus">+{{ fmt.money(s.incoming.expBonus) }} for your experience ({{ fmt.pct(s.incoming.expRate) }})</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay > 1">+{{ fmt.pct(s.incoming.reputationPay - 1) }} for your reputation</div>' +
          '<div class="cep-sub" ng-if="s.incoming.reputationPay < 1">−{{ fmt.pct(1 - s.incoming.reputationPay) }} for your reputation</div>' +
          '<div class="cep-pills" ng-if="s.incoming.handling"><span>{{ s.incoming.handling }} cargo</span><span ng-if="s.incoming.handling === \'Fragile\'">Avoid hard jolts</span></div>' +
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
              '{{ s.bus.line ? (s.bus.line.coach ? "Coach station" : "Bus stop") : (s.active.here ? "Trailer" : (s.active.phase === "toPickup" ? (s.active.kind === "food" ? "Pick up" : (s.active.tow ? "Load the car" : (s.active.taxi ? "Pick up" : "Load freight"))) : "Drop off")) }}</span>' +
              '<strong>{{ fmt.money(s.active.pay) }}</strong></div>' +
            '<div><div class="cep-name">{{ here().name }}</div>' +
              '<div class="cep-pills"><span ng-if="here().label">{{ here().label }}</span><span ng-if="here().town">{{ here().town }}</span></div>' +
              '<div class="cep-pills" ng-if="s.active.taxi"><span>{{ s.active.taxi.people }} passenger{{ s.active.taxi.people === 1 ? "" : "s" }}</span><span>{{ s.active.taxi.mode === "rush" ? "Rush: only speed counts" : "Comfort: drive smoothly" }}</span></div>' +
              '<div class="cep-sub" role="status" ng-if="s.active.taxi && s.active.phase === \'toPickup\' && (!s.taxi.eligible || s.taxi.seats < s.active.taxi.people)">' +
                '{{ !s.taxi.eligible ? s.taxi.hint : "Not enough passenger seats for this group." }}</div>' +
              '<div class="cep-sub" role="status" ng-if="s.active.taxi.boardingError">Passengers could not be seated. Stay at the pickup to retry.</div></div>' +
            '<div class="cep-drive">' +
              '<div class="cep-dist">{{ fmt.dist(s.active.distM).v }}<small>{{ fmt.dist(s.active.distM).u }}</small></div>' +
              '<div class="cep-pills cep-pills-mid" ng-if="!s.active.stop.inZone"><span>{{ s.active.distRoad ? "By road" : ' +
                '(s.active.kind === "food" && s.active.phase === "toPickup" ? "To the roadside ring" : "Straight line") }}</span>' +
                '<span ng-if="s.active.etaS && s.active.distRoad">About {{ fmt.mins(s.active.etaS) }}</span></div>' +
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
            '<span ng-if="s.dropped.left > 0">, {{ fmt.kg(s.dropped.left) }} still on board</span></div>' +
          '<div class="cep-impact-note" ng-if="s.failure">{{ s.failure.count }} order{{ s.failure.count > 1 ? "s" : "" }} ruined' +
            '<span ng-if="s.failure.g"> ({{ fmt.num(s.failure.g) }} g impact)</span></div>' +
          '<div class="cep-batch-list" ng-if="s.active.count > 1">' +
            '<div class="cep-label">Other stops ({{ s.active.carrying }} on board)</div>' +
            '<div class="cep-li cep-order-line" ng-repeat="o in s.active.orders | filter:{current:false}:true track by o.id">' +
              '<div><small>{{ o.pickup ? "Awaiting pickup" : "On board" }}</small>' +
                '<div class="cep-name">{{ o.name }}</div><div class="cep-pills"><span>{{ o.cargo }}</span>' +
                  '<span ng-if="o.pickupLeftS !== undefined && o.pickupLeftS !== null" ng-class="{late: o.pickupLeftS < 0}">Pick up {{ fmt.clock(o.pickupLeftS) }}</span>' +
                  '<span ng-class="{late: o.leftS < 0}">Deliver {{ fmt.clock(o.leftS) }}</span>' +
                  '<span ng-if="!o.pickup && o.cargoCondition < 100">{{ o.cargoCondition }}% intact</span></div></div>' +
              '<button class="cep-sm ghost" ng-if="o.selectable" ng-click="act(\'selectDelivery\', o.id)">Deliver next</button></div>' +
          '</div>' +
          '<div class="cep-receipt-note cep-pills" ng-if="s.done"><span>Last drop-off +{{ fmt.money(s.done.net) }}</span>' +
            '<span ng-if="s.done.tip > 0">{{ fmt.money(s.done.tip) }} tip</span>' +
            '<span ng-if="s.done.stars">{{ s.done.stars }} of 5 stars</span>' +
            '<span ng-if="s.done.rankUp">New rank {{ s.done.rankUp }}</span></div>' +
          '<div class="cep-card" ng-if="s.active.items.length"><div class="cep-label">{{ s.active.orderType ? s.active.cargo : "In this order" }}' +
            '</div><div class="cep-pills" ng-if="s.active.slots"><span>{{ s.active.slots }} slot{{ s.active.slots > 1 ? "s" : "" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="item in s.active.items"><b>{{ item.qty }}×</b>{{ item.name }}</li></ul></div>' +
          '<div class="cep-sub" ng-if="!s.active.items.length && s.active.count === 1">{{ s.active.cargo }}</div>' +
          '<div class="cep-card" ng-if="s.active.route"><div class="cep-label">{{ s.active.route.fill ? "Stops on the way" : "Parcel route" }}</div>' +
            '<div class="cep-pills"><span>Stop {{ s.active.route.at }} of {{ s.active.route.count }}</span><span>{{ s.active.route.fill ? fmt.kg(s.active.route.kg) + " on board" : s.active.route.left + " parcels on board" }}</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="st in s.active.route.stops track by $index" ng-style="{opacity: st.done ? 0.45 : 1, fontWeight: st.current ? 700 : 400}">' +
              '<b>{{ st.done ? "✓" : (s.active.route.fill ? "" : st.slots + "×") }}</b>{{ st.name }}<small class="cep-badge" ng-if="!st.done">{{ fmt.kg(st.kg) }}</small></li></ul></div>' +
          '<div class="cep-sub" ng-if="s.active.freight && !s.active.route">{{ fmt.freight(s.active.freight) }}</div>' +
          '<div class="cep-sub" ng-if="s.active.freightStatus">{{ s.active.freightStatus }}</div>' +
          '<div class="cep-row cep-load" ng-if="s.active.load" aria-label="How much to load">' +
            '<button class="cep-sm" ng-disabled="s.active.load.n <= 1" ng-click="act(\'loadSteps\', s.active.load.n - 1)" aria-label="Load less">−</button>' +
            '<span class="cep-sub" style="flex:1;text-align:center">{{ fmt.load(s.active.load) }}</span>' +
            '<button class="cep-sm" ng-disabled="s.active.load.n >= s.active.load.max" ng-click="act(\'loadSteps\', s.active.load.n + 1)" aria-label="Load more">+</button>' +
            '<button class="cep-sm ghost" ng-disabled="s.active.load.n >= s.active.load.max" ng-click="act(\'loadSteps\', s.active.load.max)">Full</button></div>' +
          '<div class="cep-card" ng-if="s.active.fill"><div class="cep-label">Fill up the rest</div>' +
            '<div class="cep-row" ng-repeat="f in s.active.fill track by $index" style="align-items:center">' +
              '<span class="cep-sub" style="flex:1;white-space:normal">{{ f.slots / 100 }} boxes to {{ f.to.n }} · +{{ f.detourKm }} km</span>' +
              '<button class="cep-sm go" ng-click="act(\'fillUp\', $index + 1)">+{{ fmt.money(f.pay) }}</button></div></div>' +
          '<div class="cep-card" ng-if="s.bus && s.bus.line"><div class="cep-label"><span class="cep-busref" ng-style="badge(s.bus.line.colour, s.bus.line.textColour)">{{ s.bus.line.ref || (s.bus.line.coach ? "Coach" : "Bus") }}</span> ' +
            '</div><div class="cep-pills"><span>Stop {{ s.bus.line.at }} of {{ s.bus.line.count }}</span><span>{{ s.bus.line.onBoard }} of {{ s.bus.line.capacity }} on board</span></div>' +
            '<ul class="cep-order-items"><li ng-repeat="st in s.bus.line.next track by $index" ng-style="{fontWeight: st.current ? 700 : 400}">' +
              '<b>{{ st.current ? "›" : "" }}</b>{{ st.n }}</li></ul>' +
            '<div class="cep-pills" ng-if="s.bus.line.doors"><span>Doors open</span><span>{{ s.bus.line.doors.off }} off</span><span>{{ s.bus.line.doors.on }} on</span><span>{{ s.bus.line.doors.left }} s</span></div>' +
            '<div class="cep-sub" ng-if="!s.bus.line.doors && s.bus.stop">{{ s.bus.stop.inZone ? s.bus.stop.title : ("Drive to the " + (s.bus.line.coach ? "station" : "stop") + ": " + fmt.dist(s.bus.stop.distM).v + " " + fmt.dist(s.bus.stop.distM).u + " away") }}</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.skipped">{{ s.bus.line.skipped }} skipped (not paid)</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.comfort < 100" ng-style="s.bus.line.comfort < 70 ? {color: \'var(--tomato)\'} : {}">Passenger comfort {{ s.bus.line.comfort }} % (brake, accelerate and corner gently)</div>' +
            '<div class="cep-sub" ng-if="s.bus.line.late">{{ s.bus.line.late }} min behind the timetable so far (lowers the pay)</div>' +
            '<div class="cep-sub">{{ s.bus.line.coach ? "" : "Skip a stop you cannot reach. " }}Ending early costs {{ fmt.money(s.bus.collectFee) }}.</div></div>' +
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
          '<div class="cep-row"><button class="cep-sm ghost" ng-if="!s.bus.line.coach" ng-disabled="s.bus.line.doors" ng-click="act(\'busSkip\')">Skip stop</button>' +
            '<button class="cep-sm ghost" ng-click="act(\'busEnd\')">End shift</button></div></div>' +
        '<div ng-if="!s.bus.line" class="cep-actionbar">' +
        '<button class="cep-btn go" ng-if="s.active.towHitch" ng-click="act(\'towHitch\')">Hitch trailer again</button>' +
        '<button class="cep-btn go" ng-if="s.active.towWaiting" ng-click="act(\'towLoad\')">Load {{ s.active.tow.cars > 1 ? "cars" : "car" }} on trailer</button>' +
        '<button class="cep-btn go" ng-if="s.active.canRestoreTrailer && !s.active.towWaiting && !s.active.towHitch" ng-click="act(\'restoreTrailer\')">' +
          '{{ s.active.tow ? (s.active.reloadFee ? "Reload cars: " + fmt.money(s.active.reloadFee) : "Restore tow load (free)") : "Restore assigned trailer" }}</button>' +
        '<button class="cep-btn go" ng-if="s.active.canHandover" title="No gate you can reach? The site staff come out to you." ' +
          'ng-click="act(\'handover\')">{{ s.active.handoverPickup ? "Load here" : "Hand over here" }}: {{ fmt.money(s.active.handoverPay) }}</button>' +
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
        '<div class="cep-label">{{ s.done.held ? "Delivered, pay held" : "Delivered" }}</div><div class="cep-pay">{{ s.done.held ? "" : "+" }}{{ fmt.money(s.done.net) }}</div>' +
        '<div class="cep-sub" ng-if="s.done.held">Paid when the contract ends: {{ s.done.ownerOperator ? "all of it with your own " + (s.done.vehicle || "van") : "80 % with the company " + (s.done.vehicle || "vehicle") }}.</div>' +
        '<div class="cep-sub">{{ s.done.to }}</div>' +
        '<div class="cep-sub" ng-if="s.dropped">Dropped {{ fmt.kg(s.dropped.kg) }}<span ng-if="s.dropped.left > 0">, {{ fmt.kg(s.dropped.left) }} still on board</span></div>' +
        '<div ng-if="s.done.stars"><div class="cep-stars big" role="img" ng-attr-aria-label="{{ s.done.stars }} of 5 stars">{{ fmt.stars(s.done.stars) }}<i>{{ fmt.noStars(s.done.stars) }}</i></div>' +
          '<div class="cep-sub">“{{ s.done.note }}”</div></div>' +
        '<div class="cep-step" ng-if="s.done.records" style="background:var(--ok)">New personal record</div>' +
        '<div class="cep-step to" ng-if="s.done.rankUp">New rank: {{ s.done.rankUp }}</div>' +
        '<div class="cep-step to" ng-if="s.done.truckUnlock">{{ s.done.truckUnlock }} unlocked</div>' +
        '<div class="cep-card" style="width:100%;text-align:left">' +
          '<div class="cep-keyval"><span class="cep-sub">Delivery pay</span><strong>{{ fmt.money(s.done.pay) }}</strong></div>' +
          '<div class="cep-keyval"><span class="cep-sub">Customer tip<span ng-if="s.done.tipWhy"> ({{ tipWhy(s.done.tipWhy) }})</span></span>' +
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
          '<div class="cep-pills" ng-if="radio.station && stationMeta(radio.station).length"><span ng-repeat="m in stationMeta(radio.station) track by $index">{{ m }}</span></div>' +
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
          '<div><div class="cep-name">{{ st.name }}</div><div class="cep-pills" ng-if="stationMeta(st).length"><span ng-repeat="m in stationMeta(st) track by $index">{{ m }}</span></div></div>' +
          '<button class="cep-fav" title="Remove from saved" ng-click="radioFav(st, $event)">★</button></div>' +
        '<div class="cep-sub" ng-if="!rs || rs.state === \'loading\'">Finding stations{{ rs && rs.countryName ? " in " + rs.countryName : "" }}…</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'off\' || rs.state === \'disabled\'">Start the Cargo Earth helper to find stations.</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'old\'">Update the Cargo Earth helper to get the radio.</div>' +
        '<div class="cep-msg" ng-if="rs.state === \'failed\'">Cannot reach the station list. Trying again soon.</div>' +
        '<div class="cep-sub" ng-if="rs.state === \'nowhere\'">No country here, so no local stations.</div>' +
        '<div class="cep-sub" ng-if="rs.state === \'noworld\'">Load a BeamNG.Earth map to find local stations.</div>' +
        '<div class="cep-label" ng-if="rs.near.length">Near you</div>' +
        '<div class="cep-li" ng-repeat="st in rs.near track by st.id" ng-class="{on: radio.station.id === st.id}" ng-click="radioPlay(st, rs.near)">' +
          '<div><div class="cep-name">{{ st.name }}</div><div class="cep-pills"><span>{{ st.km }} km</span><span ng-repeat="m in stationMeta(st) track by $index">{{ m }}</span></div></div>' +
          '<button class="cep-fav" title="Save station" ng-click="radioFav(st, $event)">{{ isSaved(st) ? "★" : "☆" }}</button></div>' +
        '<div class="cep-label" ng-if="rs.top.length">Popular in {{ rs.countryName }}</div>' +
        '<div class="cep-li" ng-repeat="st in rs.top | limitTo: radio.show track by st.id" ng-class="{on: radio.station.id === st.id}" ng-click="radioPlay(st, rs.top)">' +
          '<div><div class="cep-name">{{ st.name }}</div><div class="cep-pills" ng-if="stationMeta(st).length"><span ng-repeat="m in stationMeta(st) track by $index">{{ m }}</span></div></div>' +
          '<button class="cep-fav" title="Save station" ng-click="radioFav(st, $event)">{{ isSaved(st) ? "★" : "☆" }}</button></div>' +
        '<button class="cep-sm ghost" ng-if="rs.top.length > radio.show" ng-click="radioMore()">More stations</button>' +
        '<div class="cep-sub" ng-if="rs.state === \'ready\' && !rs.top.length">No working stations listed for {{ rs.countryName }}.</div>' +
        '<div class="cep-sub" style="font-size:11px">Stations: radio-browser.info</div>' +
      '</div></div>' +

      // live map: roads from BeamNG.Earth's road graph, the GPS route and the job's stops, the car pointing up
      '<div class="cep-body cep-mapbody" ng-if="tab === \'map\'"><div class="cep-mapbox" ng-class="{\'cep-map-hasleft\': lm.left}">' +
        '<canvas class="cep-livemap" role="img" aria-label="Map of the roads around your car, your route and your stops"></canvas>' +
        '<div class="cep-map-credit" ng-if="lm.osm">© OpenFreeMap © OpenMapTiles © OpenStreetMap contributors</div>' +
        '<div class="cep-map-head">' +
        '<div class="cep-map-dir" ng-if="lm.turn && !lm.behind" ng-class="{joined: mapJob()}" role="status">' +
          '<svg viewBox="-15 -15 30 30" aria-hidden="true"><path ng-attr-d="{{ lm.turn.icon }}" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/></svg>' +
          '<div><b>{{ lm.turn.dist }}</b><span>{{ lm.turn.text }}</span></div></div>' +
        '<button class="cep-map-job" ng-if="mapJob()" ng-class="{offer: mapJob().offer}" ng-click="openLiveWork()" title="Open the job on the Work tab">' +
          '<span><b>{{ mapJob().what }}</b> {{ mapJob().where }}</span><i aria-hidden="true">&rsaquo;</i></button>' +
        '<div class="cep-map-turn" ng-if="lm.behind && !(lm.note && lm.note !== lm.noteHidden)">The route is behind you. Turn around, or keep going and the GPS finds another way.</div>' +
        '<div class="cep-map-lanes" ng-if="lm.turn.lanes && !lm.behind && mapPrefs().lanes" aria-label="Lanes: the bright ones lead your way">' +
          '<svg ng-repeat="lane in lm.turn.lanes track by $index" ng-class="{ok: lane.ok}" viewBox="-15 -15 30 30" aria-hidden="true">' +
          '<path ng-attr-d="{{ lane.icon }}" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/></svg></div>' +
        '</div>' +
        '<button class="cep-map-n" title="North. Tap for the map\'s timings" aria-label="North. Tap for the map\'s timings" ng-click="mapStats()"><span class="cep-map-nd">N</span></button>' +
        '<button class="cep-map-gear" title="Map settings" aria-label="Map settings" ng-class="{on: lm.set}" ng-click="mapSet()">⚙</button>' +
        '<button class="cep-map-gear cep-map-whole" ng-if="lm.hasRoute" ng-class="{on: lm.overview}" ng-click="mapWhole()" ' +
          'title="{{ lm.overview ? \'Back to following the car\' : \'See the whole route\' }}" aria-label="{{ lm.overview ? \'Back to following the car\' : \'See the whole route\' }}">' +
          '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 6V2h4M10 2h4v4M14 10v4h-4M6 14H2v-4" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></button>' +
        '<button class="cep-map-gear cep-map-go" ng-if="lm.go" ng-class="{on: lm.goOpen, low: lm.hasRoute}" ng-click="mapGoOpen()" title="Route to home, headquarters or fuel" aria-label="Route to home, headquarters or fuel">' +
          '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 15C5 11 3.5 8.6 3.5 6.2a4.5 4.5 0 0 1 9 0C12.5 8.6 11 11 8 15z" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/><circle cx="8" cy="6.2" r="1.6" fill="currentColor"/></svg></button>' +
        '<div class="cep-map-set" ng-if="lm.goOpen && lm.go" role="dialog" aria-label="Route to">' +
          '<div class="cep-map-set-h"><b>Route to</b><button title="Close" aria-label="Close" ng-click="mapGoOpen()">✕</button></div>' +
          '<div class="cep-map-set-g cep-map-set-p cep-map-gos">' +
            '<button ng-click="mapGo(\'home\')" ng-disabled="!lm.go.home" title="{{ lm.go.home ? \'Route home\' : \'You have no home yet\' }}">Home</button>' +
            '<button ng-click="mapGo(\'hq\')" ng-disabled="!lm.go.hq" title="{{ lm.go.hq ? \'Route to your headquarters\' : \'Your firm has no headquarters yet\' }}">Headquarters</button>' +
            '<button ng-click="mapGo(\'fuel\')" title="Route to the nearest station for your car">Nearest fuel</button>' +
            '<button ng-click="mapGo(\'clear\')" ng-disabled="!lm.hasRoute" title="Clear the GPS route">Clear route</button></div>' +
          '<div class="cep-map-gomsg" ng-if="lm.goMsg" ng-class="{bad: !lm.goOk}">{{ lm.goMsg }}</div></div>' +
        '<div class="cep-map-set" ng-if="lm.set" role="dialog" aria-label="Map settings">' +
          '<div class="cep-map-set-h"><b>Map</b><button title="Close" aria-label="Close" ng-click="mapSet()">✕</button></div>' +
          '<div class="cep-map-set-g">' +
            '<button ng-repeat="o in MAP_SWITCHES track by o.k" ng-class="{on: o.k === \'sound\' ? !s.quiet : mapPrefs()[o.k]}" ng-click="mapPref(o.k)" ' +
              'aria-pressed="{{ o.k === \'sound\' ? !s.quiet : !!mapPrefs()[o.k] }}">{{ o.t }}</button></div>' +
          '<div class="cep-map-set-l">Places</div><div class="cep-map-set-g cep-map-set-p">' +
            '<button ng-repeat="o in MAP_PLACES track by o.k" ng-class="{on: mapPrefs()[o.k]}" ng-click="mapPref(o.k)" aria-pressed="{{ !!mapPrefs()[o.k] }}">' +
              '<i ng-style="{background: o.c}"></i>{{ o.t }}</button></div></div>' +
        '<div class="cep-map-stats" ng-if="lm.stats"><div ng-repeat="line in lm.statLines track by $index">{{ line }}</div>' +
          '<button ng-click="mapEngine()">{{ lm.engine === \'osm\' ? \'Use the simple map\' : \'Use the OSM map\' }}</button> ' +
          '<button ng-click="mapStats()">Close</button></div>' +
        '<span class="cep-limit cep-map-limit" ng-if="s.limit && mapPrefs().speedo" ng-class="{solo: !lm.speed}" title="Speed limit here">{{ s.limit.sign }}' +
          '<small ng-if="s.limit.unit === \'mph\'">mph</small></span>' +
        '<button class="cep-map-speed" ng-if="lm.speed && mapPrefs().speedo" ng-class="{slight: lm.speed.over === \'slight\', over: lm.speed.over === \'well\'}" ng-click="mapQuiet()" ' +
          'title="{{ s.quiet ? \'Your speed. The chime over the limit is off: tap to turn it on\' : \'Your speed. Tap to turn off the chime over the limit\' }}">' +
          '<b>{{ lm.speed.v }}</b><small>{{ lm.speed.unit }}</small>' +
          '<i ng-if="s.quiet"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 6h2l3-2.5v9L5 10H3z" fill="#7b726a"/><path d="M10 6l4 4M14 6l-4 4" stroke="#e8452c" stroke-width="1.6" stroke-linecap="round"/></svg></i></button>' +
        '<div class="cep-map-left" ng-if="lm.left" title="Left to the next stop, and the time you get there">{{ lm.left.dist }} <small ng-if="lm.left.time">· {{ lm.left.time }}</small><small ng-if="lm.left.at"> · {{ lm.left.at }}</small></div>' +
        '<div class="cep-map-note" ng-if="lm.note && lm.note !== lm.noteHidden" role="status">' +
          '<button title="Close" aria-label="Close" ng-click="mapNoteClose()">✕</button>{{ lm.note }}</div>' +
        '<div class="cep-map-zoom"><button class="cep-map-btn" title="Zoom in" ng-disabled="lm.zoom === 0" ng-click="mapZoom(-1)">+</button>' +
          '<button class="cep-map-btn" title="Zoom out" ng-disabled="lm.zoom === 2" ng-click="mapZoom(1)">−</button></div>' +
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
      // an insured car wrecked: the insurer's free tow (cargoEarth/core M.insuranceTow)
      '<div class="cep-pump cep-wreck" role="alertdialog" aria-label="Car written off" ng-if="s.wreck">' +
        '<div class="cep-pump-head"><span>Your {{ s.wreck.car || "car" }} is a write-off</span></div>' +
        '<div class="cep-pump-msg">Repair {{ fmt.money(s.wreck.bill) }}: insurance pays {{ fmt.money(s.wreck.payout) }}, you pay {{ fmt.money(s.wreck.own) }}. Repair it here, or have it towed for free.</div>' +
        '<div class="cep-pump-msg" ng-if="s.wreck.msg">{{ s.wreck.msg }}</div>' +
        '<div class="cep-pump-msg" ng-if="!s.wreck.home && !s.wreck.hq">You have no home garage or headquarters to tow it to.</div>' +
        '<div class="cep-pump-row">' +
          '<button class="cep-sm" ng-if="s.wreck.home" ng-click="act(\'towHome\')">Tow home</button>' +
          '<button class="cep-sm" ng-if="s.wreck.hq" ng-click="act(\'towHq\')">Tow to HQ</button>' +
          '<button class="cep-sm" ng-click="act(\'wreckRepair\')">Repair here<small>{{ fmt.money(s.wreck.own) }}</small></button>' +
          '<button class="cep-sm ghost" ng-click="act(\'wreckClose\')">Later</button></div></div>' +
      '<div class="cep-notices" aria-label="Job notifications">' +
      '<div class="cep-msg" role="alert" ng-if="s.insNote">{{ s.insNote }}</div>' +
      '<div class="cep-msg" role="alert" ng-if="s.saveError">{{ s.saveError }}</div>' +
      '<div class="cep-msg" role="alert" ng-if="s.flash">Speed camera: {{ s.flash.speed }} km/h, limit {{ s.flash.limit }}. Fine {{ fmt.money(s.flash.fine) }}' +
        '<span ng-if="s.flash.owed > 0"> ({{ fmt.money(s.flash.owed) }} added to your debt)</span>' +
        '<span ng-if="s.flash.stars > 0">. One star off the order on board</span>.</div>' +
      '<div class="cep-impact-note" ng-if="s.camera && !s.flash">Speed camera in {{ s.camera.m }} m, limit {{ s.camera.limit }} km/h</div>' +
      '<div class="cep-impact-note" ng-if="s.companyDamage > 0">{{ s.companyOwnerOperator ? "Your" : "Company" }} {{ s.companyVehicle || "vehicle" }} damage noted. It costs company reputation.</div>' +
      '</div>' +
      // one quiet line under the content: cargo space (Work only), fuel and damage. Debt is in the Menu.
      '<div class="cep-foot cep-pills" ng-if="s.screen !== \'resume\'">' +
        '<span ng-if="tab === \'orders\' && s.storage.checking">Checking cargo space…</span>' +
        '<span ng-if="tab === \'orders\' && s.storage.capacity" ng-class="{\'cep-foot-warn\': s.storage.overflow}">' +
          '{{ s.storage.boxes ? "Boxes" : "Bag" }} {{ s.storage.free }}/{{ s.storage.capacity }} free</span>' +
        '<span ng-if="s.fuel" ng-style="{color: s.fuel.empty ? \'var(--tomato)\' : (s.fuel.low ? \'var(--warn)\' : \'\')}">{{ s.fuel.empty ? "Out of fuel" : "Fuel " + s.fuel.pct + " %" }}</span>' +
        '<span ng-if="s.fuel && s.fuel.rangeKm && !s.fuel.empty">{{ s.fuel.rangeKm }} km</span>' +
        '<span ng-if="s.insured" title="Your car is insured">🛡 Insured</span>' +
        '<span ng-if="s.repair > 0" style="color:var(--warn)">Damage {{ fmt.money(s.repair) }}</span></div>' +
      '<nav class="cep-tabs" aria-label="Phone sections">' +
        '<button ng-class="{on: tab === \'orders\' && !panel}" ng-attr-aria-current="{{ tab === \'orders\' && !panel ? \'page\' : undefined }}" ng-click="setTab(\'orders\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="6" width="18" height="15" rx="2"/><path d="M8 6V3h8v3M3 11h18M10 11v3h4v-3"/></svg>Work</button>' +
        '<button ng-class="{on: tab === \'map\' && !panel}" ng-attr-aria-current="{{ tab === \'map\' && !panel ? \'page\' : undefined }}" ng-click="setTab(\'map\')">' +
          '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 21s-6-5.6-6-11a6 6 0 0 1 12 0c0 5.4-6 11-6 11z"/><circle cx="12" cy="10" r="2.3"/></svg>Map</button>' +
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
      // ---- speeding: a short chime when the car goes over the limit (the phone's sign turns red at the same moment).
      // Once per time over; again after 3 s back under. One phone chimes: the floating one, or the dash one while the
      // floating one is hidden. Tap the map's speedometer to turn it off or on (kept by the game for both phones).
      var chimed = false, underAt = 0, chimeCtx = null
      function chime() {
        try {
          var AC = typeof window !== 'undefined' && (window.AudioContext || window.webkitAudioContext)
          if (!AC) return
          chimeCtx = chimeCtx || new AC()
          if (chimeCtx.state === 'suspended' && chimeCtx.resume) chimeCtx.resume()
          var t = chimeCtx.currentTime
          ;[0, 0.17].forEach(function (d) {
            var o = chimeCtx.createOscillator(), g = chimeCtx.createGain()
            o.type = 'sine'
            o.frequency.value = d ? 1175 : 880
            g.gain.setValueAtTime(0.0001, t + d)
            g.gain.exponentialRampToValueAtTime(0.22, t + d + 0.02)
            g.gain.exponentialRampToValueAtTime(0.0001, t + d + 0.15)
            o.connect(g)
            g.connect(chimeCtx.destination)
            o.start(t + d)
            o.stop(t + d + 0.16)
          })
        } catch (e) {}
      }
      scope.chimes = 0
      function speedWatch(r) {
        var over = !!(r && r.limit && r.limit.over)
        var now = Date.now()
        if (!over) {
          if (chimed && !underAt) underAt = now
          if (underAt && now - underAt >= 3000) { chimed = false; underAt = 0 }
          return
        }
        underAt = 0
        if (chimed) return
        // every phone marks the time over, also the one that stays quiet: hiding the floating phone while still over
        // the limit must not make the dash phone chime again
        chimed = true
        if (r.quiet || scope.menuOnly) return
        if (scope.dash ? !r.hidden : r.hidden) return
        scope.chimes++
        chime()
      }
      // the map's ⚙ panel: what it shows, kept in the player's ui.json by the game (setMapPref)
      var MAP_DEFAULTS = {streets: true, water: true, food: true, shop: true, fuel: true, health: true, other: false,
        buildings: true, north: false, autoZoom: false, lanes: true, speedo: true, latin: false, numbers: true, oneway: true, cams: true}
      scope.MAP_SWITCHES = [{k: 'sound', t: 'Speed chime'}, {k: 'streets', t: 'Street names'}, {k: 'water', t: 'River names'},
        {k: 'latin', t: 'Latin names'}, {k: 'numbers', t: 'House nos.'}, {k: 'oneway', t: 'One-way'}, {k: 'cams', t: 'Speed cameras'},
        {k: 'buildings', t: 'Buildings'}, {k: 'north', t: 'North up'}, {k: 'autoZoom', t: 'Auto zoom'}, {k: 'lanes', t: 'Lane arrows'},
        {k: 'speedo', t: 'Speedometer'}]
      scope.MAP_PLACES = [{k: 'food', t: 'Food', c: '#e8833a'}, {k: 'shop', t: 'Shops', c: '#9b6ad6'}, {k: 'fuel', t: 'Fuel', c: '#2a9d8f'},
        {k: 'health', t: 'Health', c: '#d9534f'}, {k: 'other', t: 'Other', c: '#8a8580'}]
      scope.mapPrefs = function () { return (scope.s && scope.s.mapPrefs) || MAP_DEFAULTS }
      scope.mapSet = function () { lm.set = !lm.set; if (lm.set) lm.goOpen = false }
      // one-tap routes (home, headquarters, the nearest fuel) while no job steers the GPS
      scope.mapGoOpen = function () { lm.goOpen = !lm.goOpen; lm.goMsg = ''; if (lm.goOpen) lm.set = false }
      scope.mapGo = function (where) {
        lm.goMsg = 'Asking the GPS…'
        lm.goOk = true
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.mapGo(' + bngApi.serializeToLua(where) + ') or nil', function (r) {
          scope.$evalAsync(function () {
            lm.goOk = !!(r && r.ok)
            lm.goMsg = r && r.msg ? r.msg : 'The game did not answer.'
            if (!lm.goOk) return
            lastSketch = ''
            var said = lm.goMsg
            setTimeout(function () { scope.$evalAsync(function () { if (lm.goMsg === said) { lm.goOpen = false; lm.goMsg = '' } }) }, 2500)
          })
        })
      }
      scope.mapPref = function (k) {
        if (k === 'sound') { scope.mapQuiet(); return }
        if (!(k in MAP_DEFAULTS)) return
        var p = {}, cur = scope.mapPrefs()
        for (var pk in MAP_DEFAULTS) p[pk] = pk in cur ? cur[pk] : MAP_DEFAULTS[pk]
        p[k] = !p[k]
        if (scope.s) scope.s.mapPrefs = p
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.setMapPref(' + bngApi.serializeToLua(k) + ', ' + (p[k] ? 'true' : 'false') + ')', function () {})
      }
      scope.mapQuiet = function () {
        var quiet = !(scope.s && scope.s.quiet)
        if (scope.s) scope.s.quiet = quiet || undefined
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.setQuiet(' + (quiet ? 'true' : 'false') + ')', function () {})
      }
      function apply(r) {
        if (destroyed) return
        speedWatch(r)
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
          if (r && (r.tab === 'orders' || r.tab === 'radio' || r.tab === 'map') && r.tab !== scope.tab && !scope.menuOnly &&
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
        if (scope.panel === 'garage' && scope.gview === 'trailers' && (!scope.min || scope.menuOnly) && now - trailerPollAt >= 2000) scope.loadTrailers()
        if (now - lastPoll < pollGap()) return
        lastPoll = now
        busy = true
        bngApi.engineLua(STATE, function (r) { busy = false; apply(r) })
      }
      scope.badge = cargoEarthBadge
      scope.coachStatus = function (c) {
        if (!c) return ''
        var st = c.status || {}
        if (st.old) return 'Update the Cargo Earth helper to get coach rides.'
        if (c.helper === 'off') return 'Cannot reach the Cargo Earth helper. Check that it is running.'
        if (c.rides && c.rides.length) return c.rides.length + ' rides to far towns. More appear as towns load.'
        if (st.origin === 'loading') return 'Looking for coach stations near you…'
        if (st.origin === 'failed') return 'Could not load coach stations near you. Retry in a moment.'
        if (!c.from) return 'No bus or railway station within ' + (c.range ? c.range.nearKm : 15) + ' km. Drive to a town, or widen it in job settings.'
        if (!st.towns) return 'No town of 30,000 people within ' + c.range.minKm + '–' + c.range.maxKm + ' km. Change the ride distances in job settings.'
        return 'Looking for stations in far towns… ' + st.ready + ' of ' + st.towns + ' ready.'
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
      scope.unstuckMin = function () { return Math.ceil(((scope.s && scope.s.unstuck && scope.s.unstuck.left) || 0) / 60) }
      scope.act = function (name, value) {
        scope.cancelAsk = false
        var arg = value === undefined ? '' : ', ' + bngApi.serializeToLua(value)
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneAction("' + name + '"' + arg + ') or nil', apply)
      }
      // One row of buttons, no pop-up: native select pop-ups never reach the dashboard texture, and a list that scrolls on
      // its own cannot be scrolled with the holder's buttons in VR.
      // tip: what the work is (the same words as cargoEarth/progress M.WORK, shown on the Progress page)
      scope.workModes = [
        {id: 'courier', name: 'Food delivery', short: 'Food', tip: 'Bring meals and groceries from restaurants and shops to customers, in any car you own.'},
        {id: 'trucking', name: 'Freight', short: 'Freight', tip: 'Goods between companies, parcel routes, parts runs and tow jobs, by the vehicle you drive. No van or truck of your own: take a company contract.'},
        {id: 'taxi', name: 'Taxi', short: 'Taxi', tip: 'Take passengers to stations, airports, hotels and sights. Needs a free passenger seat. A nicer car earns more.'},
        {id: 'bus', name: 'Bus', short: 'Bus', tip: 'Drive a real city bus line in a lent bus. Nothing to buy.'}]
      scope.modePicker = {work: false, settings: false, jobs: false}
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
      scope.homeAsk = false
      scope.panel = null // the menu window's section, or null while it is closed
      scope.careerView = 'progress'
      scope.endCompanyAsk = false
      scope.g = null; scope.gview = 'home'; scope.cars = []; scope.st = null
      scope.jobsSettingsOpen = false
      scope.rangeDrafts = {}
      scope.settingsEpoch = 0
      scope.openJobsSettings = function () {
        if (scope.panel === 'settings') { scope.jobsSettingsOpen = true; loadSettings() }
        else scope.openPanel('settings', 'jobs')
      }
      scope.closeJobsSettings = function () { scope.jobsSettingsOpen = false; scope.modePicker.jobs = false }
      scope.jobTypeName = function () {
        var state = scope.st || {}
        var types = state.jobTypes || []
        for (var i = 0; i < types.length; i++) if (types[i].id === state.jobType) return types[i].name
        return 'Choose a job type'
      }
      scope.chooseJobSettings = function (id) { scope.modePicker.jobs = false; scope.sdo('jobType', id) }
      // Drafts belong to one loaded career; an untouched draft follows the saved values (they can change elsewhere,
      // e.g. in the old jobs window), while a half-typed one survives polling.
      scope.rangeBase = {}
      scope.rangeDraftsCareer = null
      function sameRange(a, b) {
        var keys = Object.keys(a || {}).concat(Object.keys(b || {}))
        return keys.every(function (k) { return (a || {})[k] === (b || {})[k] })
      }
      scope.jobDraft = function () {
        var state = scope.st || {}, id = state.jobType
        if (!id) return {}
        if (state.careerEpoch !== scope.rangeDraftsCareer) {
          scope.rangeDrafts = {}
          scope.rangeBase = {}
          scope.rangeDraftsCareer = state.careerEpoch
        }
        var saved = {}
        ;(state.items || []).forEach(function (it) { if (it.unit === 'km') saved[it.key] = it.value })
        var draft = scope.rangeDrafts[id]
        if (!draft || (sameRange(draft, scope.rangeBase[id]) && !sameRange(saved, scope.rangeBase[id]))) {
          scope.rangeDrafts[id] = JSON.parse(JSON.stringify(saved))
          scope.rangeBase[id] = saved
        }
        return scope.rangeDrafts[id]
      }
      // −/+ beside each distance, so it can be set without a keyboard (the dash phone and VR can't type)
      scope.nudgeDraft = function (it, dir) {
        var draft = scope.jobDraft(), v = Number(draft[it.key])
        if (!isFinite(v)) v = it.value
        var at = dir < 0 ? v - 0.01 : v   // going down from 100 steps by 5, from 10 by 0.5
        var step = at < 10 ? 0.5 : (at < 100 ? 5 : 25)
        v = Math.round((v + dir * step) / step) * step
        draft[it.key] = Math.max(it.min, Math.min(it.max, Math.round(v * 10) / 10))
      }
      scope.jobRangeValid = function () {
        var state = scope.st || {}, draft = scope.jobDraft()
        var fields = (state.items || []).filter(function (it) { return it.unit === 'km' })
        return fields.length === 3 && fields.every(function (it) {
          var n = draft[it.key]
          return typeof n === 'number' && isFinite(n) && n >= it.min && n <= it.max
        }) && draft.minKm <= draft.maxKm
      }
      scope.saveJobRange = function () {
        if (scope.jobRangeValid()) scope.sdo('jobRange', scope.st.jobType, scope.jobDraft())
      }
      scope.resetJobRange = function () { if (scope.st) scope.sdo('resetJobRange', scope.st.jobType) }
      function settingsResult(r) {
        scope.st = r
        if (r && (r.rangeSaved || r.rangeReset)) { delete scope.rangeDrafts[r.rangeChanged]; delete scope.rangeBase[r.rangeChanged] }
      }

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
        if (load.kind === 'load') return (load.what || 'Load') + ', ' + scope.fmt.kg(load.kg)
        return scope.fmt.int(load.amount) + (load.kind === 'parcel' ? ' slots' : ' L') + ', ' + scope.fmt.int(load.kg) + ' kg'
      }
      // the load picker: "8 of 16 boxes", "10 of 34 × 1,000 L"
      scope.fmt.load = function (l) {
        if (!l) return ''
        if (l.kind === 'load') return (l.what || 'Load ' + l.n) + (l.kg ? ', ' + scope.fmt.kg(l.kg) : '') + ' (' + l.n + ' of ' + l.max + ')'
        if (l.kind === 'parcel') return l.n + ' of ' + l.max + ' boxes'
        if (l.kind === 'dryBulk') return l.n + ' of ' + l.max + ' bulk boxes'
        return scope.fmt.int(l.n * 1000) + ' of ' + scope.fmt.int(l.max * 1000) + ' L'
      }
      var CATS = {trailer: 'Trailers', delivery: 'Delivery', company_wages: 'Company wages', drivers: 'Drivers', garage: 'Garage', parts: 'Parts',
        cancel_fee: 'Cancel fee', adjustment: 'Other', fuel: 'Fuel', fine: 'Speeding fine', insurance: 'Insurance', firm: 'Firm', home: 'Home', upkeep: 'Upkeep'}
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
        var request = {at: Date.now(), settingsEpoch: scope.settingsEpoch}
        loadingPage[fn] = request
        lua(fn, [], function (r) {
          if (loadingPage[fn] !== request) return
          delete loadingPage[fn]
          if (field === 'st' && request.settingsEpoch !== scope.settingsEpoch) return
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
        if (t !== 'orders' && t !== 'radio' && t !== 'map') return
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
        if (p === 'settings') { scope.jobsSettingsOpen = view === 'jobs'; scope.modePicker.jobs = false }
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
        if (scope.panel === 'settings' && scope.jobsSettingsOpen) return 'Jobs settings'
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
        // the Map tab has its own slim line under the turn banner (mapJob)
        if (scope.tab === 'map' && !scope.panel) return false
        if (s.active || s.screen === 'incoming') return scope.tab !== 'orders' || !!scope.panel
        return !!s.company && scope.tab !== 'orders' && scope.panel !== 'companies'
      }
      // the job on the Map tab: one slim line under the turn banner (tap: the Work tab)
      var mapJobKey = '', mapJobLook = null
      scope.mapJob = function () {
        var s = scope.s
        if (!s || s.screen === 'resume') return null
        var look = null
        if (s.screen === 'incoming') look = {what: 'New offer', where: 'Tap to see it', offer: true}
        else if (s.active) look = {what: s.active.phase === 'toPickup' ? 'Pick up' : 'Deliver', where: scope.here().name || ''}
        else if (s.company) look = {what: 'Contract', where: s.company}
        var key = look ? look.what + '|' + look.where : ''
        if (key !== mapJobKey) { mapJobKey = key; mapJobLook = look }
        return mapJobLook
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
      // the way left to the next stop (the GPS's), beside the work bar's title: on every tab, not only on the map
      var liveLeftKey = '', liveLeftLook = null
      scope.liveLeft = function () {
        var s = scope.s || {}, r = s.active && s.routeLeft
        if (!r || typeof r.m !== 'number') return null
        var key = r.m + '|' + r.s + '|' + r.imperial
        if (key !== liveLeftKey) { liveLeftKey = key; liveLeftLook = {dist: lengthText(r.m, r.imperial), time: r.s ? timeText(r.s) : ''} }
        return liveLeftLook
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
        if (i.brand) rows.push(['Make', i.brand + (i.country ? ', ' + i.country : '')])
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
      // Garage → Trailers: your own trailers
      var trailerPollAt = 0
      scope.loadTrailers = function () { trailerPollAt = Date.now(); page('trailerState', 'tp') }
      scope.openTrailers = function () { scope.gview = 'trailers'; scope.loadTrailers() }
      scope.tdo = function (name, a, b) {
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        lua('trailerDo', args, function (r) { if (r && !r._phoneError) scope.tp = r; poll() })
      }
      scope.pdo = function (name, value) {
        var args = [name]
        if (value !== undefined) args.push(value)
        lua('placesDo', args, function (r) { scope.places = r; poll() })
      }
      // the full-screen home view (Menu > Home garage > Open home)
      scope.homeOpen = false
      scope.homeSteps = ['Small garage', 'Medium garage', 'Large garage', 'Extra large garage']
      scope.openHome = function () { scope.homeOpen = true; scope.homeAsk = false; loadPlaces() }
      scope.closeHome = function () { scope.homeOpen = false }
      scope.carSpots = function () {
        var p = scope.places || {}, cap = Math.min(12, p.capacity || (p.homeInfo && p.homeInfo.cars) || 0), out = []
        for (var i = 0; i < cap; i++) out.push(i < (p.used || 0))
        return out
      }
      scope.allRoomsBuilt = function () {
        var rooms = (scope.places && scope.places.homeInfo && scope.places.homeInfo.rooms) || []
        for (var i = 0; i < rooms.length; i++) if (!rooms[i].built) return false
        return true
      }
      // one press sets a first home; moving an existing one asks for a second press
      scope.claimHome = function () {
        if (!(scope.places && scope.places.home) || scope.homeAsk) { scope.homeAsk = false; scope.pdo('claimHome'); return }
        scope.homeAsk = true
        setTimeout(function () { scope.$evalAsync(function () { scope.homeAsk = false }) }, 5000)
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
        var epoch = ++scope.settingsEpoch
        var args = [name]
        if (a !== undefined) args.push(a)
        if (b !== undefined) args.push(b)
        lua('settingsDo', args, function (r) {
          if (epoch !== scope.settingsEpoch) return
          settingsResult(r)
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
      // the station's facts as a list, shown as pills (ng-repeat compares the items, so a new list each time is fine)
      scope.stationMeta = function (st) {
        var bits = []
        if (st.region) bits.push(st.region)
        if (st.codec) bits.push(st.codec + (st.kbps ? ' ' + st.kbps + ' kbps' : ''))
        if (!st.region && st.tags) bits.push(st.tags)
        return bits
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
      // ---- live map (Map tab). The game sends the car, the GPS route and the stops 4 times a second, the roads round
      // the car only when they changed (another tile, another road graph). The phone draws them on a canvas, the car
      // pointing up, gliding between answers. Nothing runs while another tab shows or the phone is folded or hidden.
      var MAP_VIEW = [250, 500, 1000]   // metres from the top of the map to its bottom, per zoom step
      var MAP_COLORS = {
        light: {bg: '#ece6dd', fill: ['#e2dad0', '#ffffff', '#ffe7a3', '#ffc98a'], edge: ['#e2dad0', '#cfc5b8', '#d6b35a', '#cf8a3e'], route: '#2f7bf6', casing: '#ffffff', tag: '#ffffff', tagText: '#25201d'},
        dark: {bg: '#23201e', fill: ['#36312d', '#4d4741', '#7a6838', '#8c5a2c'], edge: ['#36312d', '#1b1917', '#1b1917', '#1b1917'], route: '#4a95ff', casing: '#10213d', tag: '#2b2724', tagText: '#f3ede6'}
      }
      var ROAD_M = [3, 6, 9, 13], ROAD_PX = [1, 2, 3, 4]   // road width in metres, and never thinner than this in pixels
      var STOP_LOOK = {next: ['#e4572e', ''], pickup: ['#e4572e', 'P'], drop: ['#2e9e5b', 'D'], stop: ['#7a5cc7', ''], home: ['#2f7bf6', 'H'], hq: ['#4b5563', 'W']}
      var lm = scope.lm = {overview: false, hasRoute: false, set: false, note: '', noteHidden: '', zoom: 1, behind: false, engine: 'osm', osm: false, stats: false, statLines: [], turn: null, speed: null, left: null,
        go: null, goOpen: false, goMsg: '', goOk: true}
      try { var z = localStorage.getItem('cargoEarthMapZoom'); if (z === '0' || z === '1' || z === '2') lm.zoom = Number(z) } catch (e) {}
      try { if (localStorage.getItem('cargoEarthMapEngine') === 'sketch') lm.engine = 'sketch' } catch (e) {}
      var mapData = {roadsKey: null, roads: [], route: null, routeGps: false, stops: [], car: null, from: null, at: 0, routeLL: null}
      // the timing readout's numbers (kept only while it shows)
      var perf = {asks: [], draws: [], frames: 0, framesAt: Date.now(), fps: 0, game: null, bytes: 0, roadsSent: 0}
      function perfPush(list, v) { list.push(v); if (list.length > 40) list.shift() }
      function perfAvg(list) { var t = 0; for (var i = 0; i < list.length; i++) t += list[i]; return list.length ? t / list.length : 0 }
      function perfMax(list) { var m = 0; for (var i = 0; i < list.length; i++) if (list[i] > m) m = list[i]; return m }
      function ms(v) { return (Math.round(v * 100) / 100).toFixed(2) + ' ms' }
      scope.mapStats = function () { lm.stats = !lm.stats; perf.asks = []; perf.draws = []; perf.game = null; mapStatsLines() }
      scope.mapEngine = function () {
        lm.engine = lm.engine === 'osm' ? 'sketch' : 'osm'
        if (lm.engine === 'osm') osmMap.reset()
        mapData.roadsKey = null
        perf.asks = []; perf.draws = []
        try { localStorage.setItem('cargoEarthMapEngine', lm.engine) } catch (e) {}
        mapStatsLines()
      }
      function mapStatsLines() {
        if (!lm.stats) return
        var L = [], g = perf.game
        L.push(lm.engine === 'osm' ? 'OSM map (OpenFreeMap tiles through the helper)' : 'Simple map (roads drawn by the phone)')
        if (lm.engine === 'osm' && osmMap.failed) L.push('OSM map off: ' + osmMap.failed)
        if (g) {
          L.push('Game: ' + ms(g.luaAvg) + ' per answer (max ' + ms(g.luaMax) + '), ' + ms(g.luaAvg * 4) + ' a second')
          if (lm.engine !== 'osm') {
            L.push('Road index: ' + ms(g.buildMs) + ' in ' + g.slices + ' slices (largest ' + ms(g.sliceMaxMs) + ')' + (g.building ? ', sorting now' : ''))
            L.push('Roads: ' + g.edges + ' in the index, ' + perf.roadsSent + ' sent last (' + ms(g.roadsMs) + ')')
          }
        } else L.push('Game: waiting for an answer')
        L.push('Answer size: ' + (perf.bytes / 1024).toFixed(1) + ' KB, round trip ' + ms(perfAvg(perf.asks)))
        L.push('Phone: drawing ' + ms(perfAvg(perf.draws)) + ' (max ' + ms(perfMax(perf.draws)) + '), ' + perf.fps + ' frames a second')
        if (lm.engine === 'osm') {
          L.push('Tiles: ' + osmMap.ok + ' loaded, ' + osmMap.loading + ' loading, ' + osmMap.errors + ' failed' + (osmMap.lastError ? ' (' + osmMap.lastError + ')' : ''))
          L.push('Last map piece drawn in ' + ms(osmMap.renderMs))
        }
        scope.$evalAsync(function () { lm.statLines = L })
      }
      // ---- directions: the next turn, the speed and the way left, in the game's units
      var TURN_ICON = {
        straight: 'M0 12 V-11 M-6 -5 L0 -11 L6 -5',
        left: 'M4 12 V0 Q4 -6 -2 -6 H-10 M-5 -11 L-10 -6 L-5 -1',
        right: 'M-4 12 V0 Q-4 -6 2 -6 H10 M5 -11 L10 -6 L5 -1',
        'slight left': 'M3 12 V2 L-6 -8 M-6 -1 V-8 H1',
        'slight right': 'M-3 12 V2 L6 -8 M6 -1 V-8 H-1',
        'sharp left': 'M5 -11 V4 L-7 10 M-7 3 V10 H0',
        'sharp right': 'M-5 -11 V4 L7 10 M7 3 V10 H0',
        uturn: 'M4 12 V-3 A5 5 0 0 0 -6 -3 V6 M-11 1 L-6 6 L-1 1',
        roundabout: 'M0 12 V5 M0 -11 V-5 M-5 -9 L0 -14 L5 -9 M0 -5 A5 5 0 1 1 0 5 A5 5 0 1 1 0 -5',
        arrive: 'M0 11 C-6 4 -8 0 -8 -4 A8 8 0 0 1 8 -4 C8 0 6 4 0 11 Z M0 -7 A3 3 0 1 0 0.01 -7'
      }
      var TURN_WORD = {left: 'Turn left', right: 'Turn right', 'slight left': 'Keep left', 'slight right': 'Keep right',
        'sharp left': 'Turn sharp left', 'sharp right': 'Turn sharp right', uturn: 'Make a U-turn', straight: 'Go straight'}
      function lengthText(m, imperial) {
        if (imperial) {
          var ft = m * 3.28084
          if (ft < 1000) return (ft < 100 ? Math.round(ft / 10) * 10 : Math.round(ft / 50) * 50) + ' ft'
          var mi = m / 1609.344
          return (mi < 10 ? mi.toFixed(1) : Math.round(mi)) + ' mi'
        }
        if (m < 1000) return (m < 100 ? Math.round(m / 10) * 10 : Math.round(m / 50) * 50) + ' m'
        var km = m / 1000
        return (km < 10 ? km.toFixed(1) : Math.round(km)) + ' km'
      }
      function timeText(s) {
        if (!(s > 0)) return ''
        var min = Math.round(s / 60)
        return min < 60 ? Math.max(1, min) + ' min' : Math.floor(min / 60) + ' h ' + (min % 60) + ' min'
      }
      // the clock time you get there (the phone's clock: the computer's own time)
      function arriveText(s, now) {
        if (!(s > 0)) return ''
        var d = new Date((now === undefined ? Date.now() : now) + s * 1000)
        var hh = d.getHours(), mm = d.getMinutes()
        return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm
      }
      scope.mapArriveText = arriveText    // (tests)
      function turnLook(t, imperial) {
        if (!t) return null
        var mod = t.modifier || 'straight', icon, text, onto = t.name ? ' onto ' + t.name : ''
        if (t.type === 'arrive') { icon = TURN_ICON.arrive; text = 'You arrive' }
        else if (t.type === 'roundabout' || t.type === 'rotary' || t.type === 'exit roundabout' || t.type === 'roundabout turn') {
          icon = TURN_ICON.roundabout
          text = t.exit ? 'At the roundabout take exit ' + t.exit + onto : 'Go through the roundabout' + onto
        } else if (t.type === 'merge') { icon = TURN_ICON[mod] || TURN_ICON.straight; text = 'Merge' + onto }
        else if (t.type === 'on ramp' || t.type === 'off ramp') {
          icon = TURN_ICON[mod] || TURN_ICON.straight
          text = (t.type === 'on ramp' ? 'Take the ramp' : 'Take the exit') + (mod.indexOf('left') !== -1 ? ' on the left' : mod.indexOf('right') !== -1 ? ' on the right' : '') + onto
        } else if (t.type === 'fork') { icon = TURN_ICON[mod] || TURN_ICON.straight; text = (mod.indexOf('left') !== -1 ? 'Keep left' : mod.indexOf('right') !== -1 ? 'Keep right' : 'Keep straight') + onto }
        else { icon = TURN_ICON[mod] || TURN_ICON.straight; text = (TURN_WORD[mod] || 'Go on') + onto }
        var lanes = null
        // the lanes, once the turn is near (1 km): bright where the route goes on
        if (t.lanes && t.lanes.length > 1 && t.m <= 1000) {
          lanes = t.lanes.map(function (l) { return {ok: !!l.ok, icon: TURN_ICON[l.dir] || TURN_ICON.straight} })
        }
        return {icon: icon, text: text, dist: lengthText(t.m, imperial), lanes: lanes}
      }
      function sameLook(a, b) { return a === b || (a && b && a.icon === b.icon && a.text === b.text && a.dist === b.dist && JSON.stringify(a.lanes) === JSON.stringify(b.lanes)) }
      function directions(r) {
        var turn = r.routeGps ? turnLook(r.turn, r.imperial) : null
        var sp = r.car ? {v: r.imperial ? Math.round(r.car.kmh / 1.609344) : r.car.kmh, unit: r.imperial ? 'mph' : 'km/h'} : null
        var limit = scope.s && scope.s.limit
        // like the nav apps: amber just over the limit, red well over (the limit's sign stays beside it)
        if (sp && limit && limit.over) sp.over = limit.well ? 'well' : 'slight'
        var left = typeof r.leftM === 'number' ? {dist: lengthText(r.leftM, r.imperial), time: timeText(r.leftS), at: arriveText(r.leftS)} : null
        if (sameLook(turn, lm.turn) && sameLook2(sp, lm.speed) && sameLook2(left, lm.left)) return
        scope.$evalAsync(function () { lm.turn = turn; lm.speed = sp; lm.left = left })
      }
      function sameLook2(a, b) { return JSON.stringify(a) === JSON.stringify(b) }
      // ---- the OSM map (see cargoEarthOsm): tiles through the helper, drawn under our route
      var osmMap = scope.osmMap = new cargoEarthOsm.TileMap({xhr: tileFromGame})
      // BeamNG's UI browser cancels the page's own requests to the helper, so a tile comes through the game: ask it
      // (cargoEarth_core.osmTile) every 200 ms until the helper answered. done(status, ArrayBuffer) like an XHR.
      function tileFromGame(url, done) {
        var m = /[?&]z=(\d+)&x=(\d+)&y=(\d+)/.exec(url)
        if (!m) { done(400, null); return }
        var t0 = Date.now()
        function poll() {
          if (destroyed) return
          bngApi.engineLua('cargoEarth_core and cargoEarth_core.osmTile(' + m[1] + ', ' + m[2] + ', ' + m[3] + ') or nil', function (r) {
            if (destroyed) return
            if (r && r.state === 'ok') {
              var bytes
              try { bytes = cargoEarthOsm.fromBase64(r.b64 || '') } catch (e) { done(200, null); return }
              done(200, bytes.buffer)
            } else if (r && r.state === 'error') {
              var why = String(r.err || 'no answer')
              var code = /^HTTP (\d+)/.exec(why)
              done(code ? +code[1] : why === 'a broken answer' ? 502 : 0,          // no HTTP answer: the helper is not there
                cargoEarthOsm.utf8Bytes(JSON.stringify({error: why.replace(/^HTTP \d+: /, '')})).buffer)
            } else if (!r) done(0, null)                                   // the mod is not running
            else if (Date.now() - t0 > 160000) done(0, null)              // never answered (tiles wait in one queue: up to 6 x 20 s)
            else setTimeout(poll, 200)
          })
        }
        poll()
      }
      scope.mapNoteClose = function () { lm.noteHidden = lm.note }
      function osmOn() { return lm.engine === 'osm' && !osmMap.failed }
      var mapBusy = false, mapAskedAt = -Infinity
      scope.mapZoom = function (d) {
        lm.zoom = Math.max(0, Math.min(MAP_VIEW.length - 1, lm.zoom + d))
        try { localStorage.setItem('cargoEarthMapZoom', String(lm.zoom)) } catch (e) {}
      }
      function mapOn() { return scope.tab === 'map' && !scope.panel && !scope.min && !scope.menuOnly && !(scope.s && scope.s.hidden) && !destroyed }
      function mapNote(text) {
        if (lm.note === text) return
        scope.$evalAsync(function () { lm.note = text })
      }
      // where the car is drawn now: between the last two answers, so it glides instead of jumping
      function carNow(now) {
        var a = mapData.from, b = mapData.car
        if (!b) return null
        if (!a) return b
        var t = Math.max(0, Math.min(1, (now - mapData.at) / 250))
        var dh = ((b.h - a.h + 540) % 360) - 180
        var c = {x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, h: a.h + dh * t}
        if (a.lat !== undefined && b.lat !== undefined) { c.lat = a.lat + (b.lat - a.lat) * t; c.lon = a.lon + (b.lon - a.lon) * t }
        else if (b.lat !== undefined) { c.lat = b.lat; c.lon = b.lon }
        return c
      }
      function mapAsk() {
        if (!mapOn() || mapBusy) return
        var now = Date.now()
        if (now - mapAskedAt < 250) return
        mapAskedAt = now
        mapBusy = true
        var geo = osmOn()
        var sent = Date.now()
        bngApi.engineLua('cargoEarth_core and cargoEarth_core.phoneMap(' + bngApi.serializeToLua(geo ? null : mapData.roadsKey) + ', ' +
          (lm.stats ? 'true' : 'false') + ', ' + (geo ? 'true' : 'false') + ', ' + (lm.overview ? 'true' : 'false') + ') or nil', function (r) {
          mapBusy = false
          if (destroyed) return
          if (lm.stats && r) {
            perfPush(perf.asks, Date.now() - sent)
            try { perf.bytes = JSON.stringify(r).length } catch (e) {}
            if (r.roads) perf.roadsSent = r.roads.length / 5
            if (r.perf) {
              var g = perf.game || {lua: []}
              perfPush(g.lua, r.perf.luaMs || 0)
              g.luaAvg = perfAvg(g.lua); g.luaMax = perfMax(g.lua)
              g.buildMs = r.perf.buildMs || 0; g.slices = r.perf.slices || 0; g.sliceMaxMs = r.perf.sliceMaxMs || 0
              g.edges = r.perf.edges || 0; g.roadsMs = r.perf.roadsMs || 0; g.building = !!r.perf.building
              perf.game = g
            }
          }
          if (!r || r.status !== 'ok' || !r.car) {
            mapData.car = mapData.from = null
            mapNote(r && r.status && r.status !== 'ok' ? r.status + '.' : 'The map shows once BeamNG.Earth has loaded the world.')
            return
          }
          if (r.roadsKey !== undefined) {
            if (r.roads) mapData.roads = r.roads
            mapData.roadsKey = r.roadsKey
          }
          mapData.from = carNow(Date.now())
          mapData.car = r.car
          mapData.at = Date.now()
          mapData.route = r.route || null
          mapData.routeGps = !!r.routeGps
          mapData.stops = r.stops || []
          mapData.offM = r.offM || 0
          mapData.routeLL = r.routeLL || null
          mapData.whole = r.whole || null
          mapData.cams = r.cams || null
          mapData.imperial = !!r.imperial
          var hasRoute = !!(r.route && r.route.length >= 4)
          if (hasRoute !== lm.hasRoute || (!hasRoute && lm.overview)) scope.$evalAsync(function () { lm.hasRoute = hasRoute; if (!hasRoute) lm.overview = false })
          if (!!r.behind !== lm.behind) scope.$evalAsync(function () { lm.behind = !!r.behind })
          var go = r.go ? {home: !!r.go.home, hq: !!r.go.hq} : null
          if (JSON.stringify(go) !== JSON.stringify(lm.go)) scope.$evalAsync(function () { lm.go = go; if (!go) lm.goOpen = false })
          directions(r)
          if (geo) {
            if (r.tiles) osmMap.setBase(r.tiles)
            else osmMap.failed = 'it needs the Cargo Earth helper'
            mapNote(osmMap.failed || osmMap.ok ? '' : 'Loading the map…')
          } else if (osmMap.failed && lm.engine === 'osm') mapNote('Simple map: the OSM map is off, ' + osmMap.failed + '.')
          else mapNote(mapData.roads.length ? '' : 'No roads here yet. They appear as BeamNG.Earth builds the world around you.')
        })
      }
      function mapCanvas() {
        var root = element && element[0]
        return root && root.querySelector ? root.querySelector('.cep-livemap') : null
      }
      function mapDraw() {
        var cv = mapCanvas()
        if (!cv || !cv.getContext) return
        var w = cv.clientWidth, h = cv.clientHeight
        if (!w || !h) return
        var ratio = (typeof window !== 'undefined' && window.devicePixelRatio) || 1
        if (cv.width !== Math.round(w * ratio) || cv.height !== Math.round(h * ratio)) { cv.width = Math.round(w * ratio); cv.height = Math.round(h * ratio) }
        var ctx = cv.getContext('2d')
        var col = MAP_COLORS[scope.dark ? 'dark' : 'light']
        ctx.setTransform(ratio, 0, 0, ratio, 0, 0)
        ctx.fillStyle = col.bg
        ctx.fillRect(0, 0, w, h)
        var car = carNow(Date.now())
        if (!car) return false
        var mp = scope.mapPrefs()
        // the whole-route view: north up, the whole way ahead and the car fitted in; else the car's own view
        var ov = lm.overview ? overviewOf(car, w, h) : null
        var scale = ov ? ov.scale : h / MAP_VIEW[mapZoomNow(mp)], ox = w / 2, oy = ov ? ov.oy : mp.north ? h * 0.5 : h * 0.68
        var hd = ov || mp.north ? 0 : car.h       // north up, or the car's heading up
        var rad = hd * Math.PI / 180, cs = Math.cos(rad), sn = Math.sin(rad)
        var vx = ov ? ov.x : car.x, vy = ov ? ov.y : car.y      // the game point in the view's centre
        // game metres (x east, y north) to the screen, the car's heading up
        var sx = function (x, y) { return ox + ((x - vx) * cs - (y - vy) * sn) * scale }
        var sy = function (x, y) { return oy - ((x - vx) * sn + (y - vy) * cs) * scale }
        // the OSM map: its tiles under everything, and the route and stops by lat / lon
        var view = {w: w, h: h, ox: ox, oy: oy, scale: scale, ratio: ratio, lat: ov && ov.lat !== undefined ? ov.lat : car.lat,
          lon: ov && ov.lon !== undefined ? ov.lon : car.lon, heading: hd, opts: mp, z: ov ? ov.z : undefined}
        var osm = osmOn() && car.lat !== undefined && osmMap.base ? osmMap.draw(ctx, view, !!scope.dark, Date.now()) : null
        if (!!osm !== lm.osm) scope.$evalAsync(function () { lm.osm = !!osm })
        if (osm) {
          sx = function (la, lo) { return osm.proj(la, lo)[0] }
          sy = function (la, lo) { return osm.proj(la, lo)[1] }
        }
        // where the car is on the screen (the view's centre, except in the whole-route view)
        var carSX = ox, carSY = oy
        if (ov) {
          carSX = osm ? sx(car.lat, car.lon) : sx(car.x, car.y)
          carSY = osm ? sy(car.lat, car.lon) : sy(car.x, car.y)
          view.carX = carSX
          view.carY = carSY
        }
        var pad = 40
        function off(ax, ay, bx, by) {
          return (ax < -pad && bx < -pad) || (ax > w + pad && bx > w + pad) || (ay < -pad && by < -pad) || (ay > h + pad && by > h + pad)
        }
        ctx.lineCap = 'round'
        ctx.lineJoin = 'round'
        // roads: by kind, small ones first; a darker edge under each, then its fill
        var roads = osm ? [] : mapData.roads, k, i
        var pts = []
        for (i = 0; i + 4 < roads.length; i += 5) {
          var ax = sx(roads[i], roads[i + 1]), ay = sy(roads[i], roads[i + 1])
          var bx = sx(roads[i + 2], roads[i + 3]), by = sy(roads[i + 2], roads[i + 3])
          if (!off(ax, ay, bx, by)) pts.push(ax, ay, bx, by, roads[i + 4])
        }
        for (var pass = 0; pass < 2; pass++) {
          for (k = 0; k < 4; k++) {
            var px = Math.max(ROAD_PX[k], ROAD_M[k] * scale)
            if (pass === 0 && k === 0) continue
            ctx.strokeStyle = pass === 0 ? col.edge[k] : col.fill[k]
            ctx.lineWidth = pass === 0 ? px + 2 : px
            ctx.beginPath()
            for (i = 0; i < pts.length; i += 5) {
              if (pts[i + 4] !== k) continue
              ctx.moveTo(pts[i], pts[i + 1])
              ctx.lineTo(pts[i + 2], pts[i + 3])
            }
            ctx.stroke()
          }
        }
        // the route: the GPS's own line, or a dashed straight line to the next stop when the GPS has none
        var whole = ov && mapData.whole
        var route = whole ? (osm ? whole.ll : whole.xy) : osm ? mapData.routeLL : mapData.route
        if (route && route.length >= 4) {
          var line = function () {
            ctx.beginPath()
            var pen = false
            for (var j = 0; j + 1 < route.length; j += 2) {
              if (route[j] === false) { pen = false; j -= 1; continue }
              var x = sx(route[j], route[j + 1]), y = sy(route[j], route[j + 1])
              if (pen) ctx.lineTo(x, y); else ctx.moveTo(x, y)
              pen = true
            }
            ctx.stroke()
          }
          var rw = Math.max(4, 5 * scale)
          // off the line (a side road, a car park): a dashed link from the car to where the route goes on
          if (!ov && mapData.routeGps && mapData.offM > 20 && typeof route[0] === 'number') {
            if (ctx.setLineDash) ctx.setLineDash([6, 6])
            ctx.strokeStyle = col.route
            ctx.lineWidth = 3
            ctx.beginPath()
            ctx.moveTo(ox, oy)
            ctx.lineTo(sx(route[0], route[1]), sy(route[0], route[1]))
            ctx.stroke()
          }
          if (ctx.setLineDash) ctx.setLineDash(mapData.routeGps ? [] : [rw * 1.5, rw * 1.5])
          ctx.strokeStyle = col.casing
          ctx.lineWidth = rw + 3
          line()
          ctx.strokeStyle = col.route
          ctx.lineWidth = rw
          line()
          if (ctx.setLineDash) ctx.setLineDash([])
        }
        // street names over the route (the street the route takes keeps its name), under the stops and the car
        if (osm) { ctx.save(); osm.labels(); ctx.restore() }
        // speed cameras: a small limit sign where each one stands
        var cams = mp.cams !== false && mapData.cams
        if (cams) {
          ctx.textAlign = 'center'
          ctx.textBaseline = 'middle'
          for (i = 0; i < cams.length; i++) {
            var cm = cams[i], ca1 = osm ? cm.lat : cm.x, cb1 = osm ? cm.lon : cm.y
            if (ca1 === undefined) continue
            var cx1 = sx(ca1, cb1), cy1 = sy(ca1, cb1)
            if (cx1 < 8 || cx1 > w - 8 || cy1 < 8 || cy1 > h - 8) continue
            ctx.beginPath()
            ctx.arc(cx1, cy1, 9, 0, Math.PI * 2)
            ctx.fillStyle = '#ffffff'
            ctx.fill()
            ctx.lineWidth = 2.5
            ctx.strokeStyle = '#d7262b'
            ctx.stroke()
            var lim = cm.limit && (mapData.imperial ? Math.round(cm.limit / 1.609344 / 5) * 5 : cm.limit)
            ctx.fillStyle = '#1b1b1b'
            ctx.font = '800 ' + (lim >= 100 ? 7 : 8) + 'px sans-serif'
            ctx.fillText(lim ? String(lim) : '!', cx1, cy1 + 0.5)
          }
        }
        // stops: a dot with a letter; the next one bigger, and held at the edge with an arrow when it is off the map
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        var stops = mapData.stops || [], nextName = null
        for (i = 0; i < stops.length; i++) {
          var st = stops[i], look = STOP_LOOK[st.k] || STOP_LOOK.stop
          var sa = osm ? st.lat : st.x, sb = osm ? st.lon : st.y
          if (sa === undefined) continue
          var x = sx(sa, sb), y = sy(sa, sb), r = st.k === 'next' ? 11 : 8
          var edge = x < r || x > w - r || y < r || y > h - r
          if (edge && st.k !== 'next') continue
          if (edge) {
            var dx = x - ox, dy = y - oy, f = Math.min(Math.abs((w / 2 - 18) / (dx || 1e-6)), Math.abs((oy - 18) / (dy < 0 ? -dy : 1e-6)), Math.abs((h - oy - 18) / (dy > 0 ? dy : 1e-6)))
            x = ox + dx * f
            y = oy + dy * f
            var ang = Math.atan2(dy, dx)
            ctx.fillStyle = look[0]
            ctx.beginPath()
            ctx.moveTo(x + Math.cos(ang) * 18, y + Math.sin(ang) * 18)
            ctx.lineTo(x + Math.cos(ang + 2.5) * 9, y + Math.sin(ang + 2.5) * 9)
            ctx.lineTo(x + Math.cos(ang - 2.5) * 9, y + Math.sin(ang - 2.5) * 9)
            ctx.fill()
          }
          ctx.beginPath()
          ctx.arc(x, y, r, 0, Math.PI * 2)
          ctx.fillStyle = look[0]
          ctx.fill()
          ctx.lineWidth = 2.5
          ctx.strokeStyle = '#ffffff'
          ctx.stroke()
          var label = st.k === 'stop' ? st.n : (st.k === 'next' ? (st.pickup ? 'P' : 'D') : look[1])
          if (label) {
            ctx.fillStyle = '#ffffff'
            ctx.font = '800 ' + (r + 1) + 'px sans-serif'
            ctx.fillText(String(label).slice(0, 2), x, y + 0.5)
          }
          if (st.k === 'next' && !edge && st.n) nextName = {x: x, y: y, r: r, n: String(st.n), c: look[0]}
        }
        // the next stop's name (the drop-off's street and number, the pickup's name) on a tag beside its pin
        if (nextName) stopTag(ctx, nextName, w, col)
        // the car: an arrow pointing up (north up: pointing where the car heads)
        var ca = (car.h - hd) * Math.PI / 180, cc = Math.cos(ca), cn = Math.sin(ca)
        var arrow = function (x, y) { return [carSX + x * cc - y * cn, carSY + x * cn + y * cc] }
        var a1 = arrow(0, -13), a2 = arrow(9, 9), a3 = arrow(0, 4), a4 = arrow(-9, 9)
        ctx.beginPath()
        ctx.moveTo(a1[0], a1[1])
        ctx.lineTo(a2[0], a2[1])
        ctx.lineTo(a3[0], a3[1])
        ctx.lineTo(a4[0], a4[1])
        ctx.closePath()
        ctx.fillStyle = col.route
        ctx.fill()
        ctx.lineWidth = 2.5
        ctx.strokeStyle = '#ffffff'
        ctx.stroke()
        return osm ? osm.missing : false
      }
      var STOP_TAG_MAX = 30
      function stopTag(ctx, t, w, col) {
        var text = t.n.length > STOP_TAG_MAX ? t.n.slice(0, STOP_TAG_MAX - 1) + '…' : t.n
        ctx.font = '700 11px sans-serif'
        var tw = ctx.measureText(text).width, bw = tw + 12, bh = 18
        // right of the pin, or left of it when the zoom buttons or the edge are in the way
        var bx = t.x + t.r + 5
        if (bx + bw > w - 54) bx = t.x - t.r - 5 - bw
        bx = Math.max(4, bx)
        var by = t.y - bh / 2
        ctx.beginPath()
        if (ctx.roundRect) ctx.roundRect(bx, by, bw, bh, 6)
        else ctx.rect(bx, by, bw, bh)
        ctx.fillStyle = col.tag || '#ffffff'
        ctx.fill()
        ctx.lineWidth = 1.5
        ctx.strokeStyle = t.c
        ctx.stroke()
        ctx.fillStyle = col.tagText || '#25201d'
        ctx.textAlign = 'left'
        ctx.textBaseline = 'middle'
        ctx.fillText(text, bx + 6, by + bh / 2 + 0.5)
      }
      scope.mapStopTag = stopTag    // (tests)
      // The whole-route view: the way ahead (a few hundred points from the game) and the car fitted between the
      // banner and the bottom, north up. Coarser map tiles the farther it reaches. Null without a route.
      var OVERVIEW_MIN_Z = 3
      function overviewOf(car, w, h) {
        var wh = mapData.whole
        if (!wh || !wh.xy || wh.xy.length < 4) return null
        var x0 = car.x, x1 = car.x, y0 = car.y, y1 = car.y, j
        for (j = 0; j + 1 < wh.xy.length; j += 2) {
          x0 = Math.min(x0, wh.xy[j]); x1 = Math.max(x1, wh.xy[j]); y0 = Math.min(y0, wh.xy[j + 1]); y1 = Math.max(y1, wh.xy[j + 1])
        }
        var top = 110, bottom = 76, side = 28
        var scale = Math.min((w - 2 * side) / Math.max(x1 - x0, 60), (h - top - bottom) / Math.max(y1 - y0, 60), h / MAP_VIEW[0])
        var o = {x: (x0 + x1) / 2, y: (y0 + y1) / 2, scale: scale, oy: (top + h - bottom) / 2}
        if (wh.ll && wh.ll.length >= 4 && car.lat !== undefined) {
          var a0 = car.lat, a1 = car.lat, b0 = car.lon, b1 = car.lon
          for (j = 0; j + 1 < wh.ll.length; j += 2) {
            a0 = Math.min(a0, wh.ll[j]); a1 = Math.max(a1, wh.ll[j]); b0 = Math.min(b0, wh.ll[j + 1]); b1 = Math.max(b1, wh.ll[j + 1])
          }
          o.lat = (a0 + a1) / 2
          o.lon = (b0 + b1) / 2
        }
        // about two tiles from top to bottom (z14 up to 2.5 km, one zoom out for each doubling), and never more tiles
        // in view than half of what the tile cache keeps (a long haul: coarse tiles that stay, not a loop of reloads)
        var z = Math.min(14, 14 - Math.ceil(Math.log(h / scale / 2500) / Math.LN2))
        var lat = o.lat !== undefined ? o.lat : 50
        while (z > OVERVIEW_MIN_Z) {
          var reach = Math.sqrt(w * w + h * h) / 2 / scale / cargoEarthOsm.tileMetres(lat, z)
          if (Math.pow(2 * reach + 2, 2) <= cargoEarthOsm.TileMap.MAX_TILES / 2) break
          z--
        }
        o.z = Math.max(OVERVIEW_MIN_Z, z)
        return o
      }
      scope.mapWhole = function () { lm.overview = !lm.overview; lastSketch = '' }
      scope.mapOverviewOf = overviewOf    // (tests)
      // auto zoom: one step farther out while driving fast (on from 70 km/h, back under 50, so it does not flicker)
      var zoomedOut = false
      function mapZoomNow(mp) {
        var kmh = mapData.car && mapData.car.kmh || 0
        zoomedOut = !!mp.autoZoom && (zoomedOut ? kmh > 50 : kmh >= 70)
        return Math.min(MAP_VIEW.length - 1, lm.zoom + (zoomedOut ? 1 : 0))
      }
      // the north dial turns with the map (the car's heading is up)
      var dialAt = null
      function mapDial(car) {
        var root = element && element[0]
        var d = root && root.querySelector ? root.querySelector('.cep-map-nd') : null
        if (!d || !car) return
        var deg = scope.mapPrefs().north ? 0 : Math.round(-car.h)
        if (dialAt === deg && d.style.transform) return
        dialAt = deg
        d.style.transform = 'rotate(' + deg + 'deg)'
      }
      var lastSketch = ''
      var statsTick = 0
      var mapTimer = setInterval(function () {
        if (!mapOn()) return
        mapAsk()
        var t0 = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now()
        var car = carNow(Date.now())
        var drew = true
        // the same picture as last time (the car stands, nothing new, no map piece still to come): not drawn again
        var key = car ? [car.x.toFixed(1), car.y.toFixed(1), car.h.toFixed(1), mapZoomNow(scope.mapPrefs()), !!scope.dark, mapData.at, lm.engine, osmMap.version,
          JSON.stringify(scope.mapPrefs()), lm.overview].join(',') : ''
        if (key && key === lastSketch) drew = false
        else {
          var missing = mapDraw()
          lastSketch = missing ? '' : key
          if (lm.stats) perf.frames++
        }
        mapDial(car)
        if (lm.stats) {
          var t1 = (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now()
          if (drew) perfPush(perf.draws, t1 - t0)
          var now = Date.now()
          if (now - perf.framesAt >= 1000) { perf.fps = Math.round(perf.frames * 1000 / (now - perf.framesAt)); perf.frames = 0; perf.framesAt = now }
          if (statsTick++ % 10 === 0) mapStatsLines()
        }
      }, 50)
      scope.$on('$destroy', function () { clearInterval(mapTimer) })

      var slowTicks = 0
      var slow = setInterval(function () {
        if (scope.hqOpen) loadHq()
        if (scope.homeOpen && scope.panel !== 'home') loadPlaces()
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

