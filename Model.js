// Pure layout and settings helpers for Wallpaper Framing. No QML types, so the
// same file runs under node for tests/model.test.js.

var MODES = ["fill", "fit", "stretch", "actual"]
var ROTATIONS = [0, 90, 180, 270]
var ZOOM_MAX = 8
var AFTER_PICK = ["ask", "open", "off"]
var BACKDROPS = ["blur", "color"]
var MAX_FRAMES = 4000
var MAX_KEY = 4096

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value))
}

function finite(value) {
  return typeof value === "number" && isFinite(value)
}

function round4(value) {
  return Math.round(value * 10000) / 10000
}

function plain(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

// Fill and stretch always cover the screen, so they never zoom out past 1.
// Fit and actual size already leave room around the image and may shrink.
function zoomMin(mode) {
  return mode === "fit" || mode === "actual" ? 0.1 : 1
}

function defaultFraming() {
  return { mode: "fill", zoom: 1, ax: 0.5, ay: 0.5, rotation: 0 }
}

// A framing may name an image of its own: the monitor then shows that still
// instead of the shared wallpaper.
function validImage(path) {
  return typeof path === "string" && path.charAt(0) === "/" && path.length <= MAX_KEY
}

function normalizeFraming(value) {
  var src = plain(value) ? value : {}
  var mode = MODES.indexOf(src.mode) >= 0 ? src.mode : "fill"
  var rotation = ROTATIONS.indexOf(src.rotation) >= 0 ? src.rotation : 0
  var zoom = finite(src.zoom) ? clamp(src.zoom, zoomMin(mode), ZOOM_MAX) : 1
  function anchor(n) { return finite(n) ? clamp(n, 0, 1) : 0.5 }
  var out = { mode: mode, zoom: round4(zoom), ax: round4(anchor(src.ax)), ay: round4(anchor(src.ay)), rotation: rotation }
  if (validImage(src.image)) out.image = src.image
  return out
}

function sameFraming(a, b) {
  var x = normalizeFraming(a), y = normalizeFraming(b)
  return x.mode === y.mode && x.zoom === y.zoom && x.ax === y.ax && x.ay === y.ay && x.rotation === y.rotation
    && (x.image || "") === (y.image || "")
}

// Where the image lands on a screen of W x H logical pixels. The rectangle is
// the image as drawn, after rotation; `rotated` says its sides are swapped
// against the file. The anchors place it: 0 holds the image's left or top
// edge to the screen's, 1 its right or bottom, whether the image is larger
// than the screen (a crop) or smaller (bars).
function layout(imageWidth, imageHeight, W, H, framing, pixelRatio) {
  if (![imageWidth, imageHeight, W, H].every(function(n) { return finite(n) && n > 0 })) return null
  var f = normalizeFraming(framing)
  var dpr = finite(pixelRatio) && pixelRatio > 0 ? pixelRatio : 1
  var rotated = f.rotation === 90 || f.rotation === 270
  var rw = rotated ? imageHeight : imageWidth
  var rh = rotated ? imageWidth : imageHeight
  var sx, sy
  if (f.mode === "stretch") {
    sx = W / rw
    sy = H / rh
  } else if (f.mode === "fit") {
    sx = sy = Math.min(W / rw, H / rh)
  } else if (f.mode === "actual") {
    sx = sy = 1 / dpr
  } else {
    sx = sy = Math.max(W / rw, H / rh)
  }
  var w = rw * sx * f.zoom
  var h = rh * sy * f.zoom
  var x = (W - w) * f.ax
  var y = (H - h) * f.ay
  return {
    x: x, y: y, width: w, height: h, rotated: rotated, rotation: f.rotation,
    covers: x <= 0.5 && y <= 0.5 && x + w >= W - 0.5 && y + h >= H - 0.5
  }
}

// The bitmap to decode for a layout, in the file's own orientation. Never
// larger than the file, and never more than maxPixels when that is given, so
// a deep zoom into a large image softens instead of filling video memory.
function decodeSize(imageWidth, imageHeight, geometry, pixelRatio, maxPixels) {
  if (!geometry || !(imageWidth > 0) || !(imageHeight > 0)) return { width: 0, height: 0 }
  var dpr = finite(pixelRatio) && pixelRatio > 0 ? pixelRatio : 1
  var drawnWidth = geometry.rotated ? geometry.height : geometry.width
  var drawnHeight = geometry.rotated ? geometry.width : geometry.height
  var scale = Math.min(1, Math.max(drawnWidth * dpr / imageWidth, drawnHeight * dpr / imageHeight))
  var w = imageWidth * scale
  var h = imageHeight * scale
  if (finite(maxPixels) && maxPixels > 0 && w * h > maxPixels) {
    var shrink = Math.sqrt(maxPixels / (w * h))
    w *= shrink
    h *= shrink
  }
  return { width: Math.max(1, Math.ceil(w)), height: Math.max(1, Math.ceil(h)) }
}

// The framing that puts the drawn image's top-left corner at (x, y), held to
// the range the anchors allow. An axis with no slack keeps its anchor.
function panTo(framing, geometry, W, H, x, y) {
  var f = normalizeFraming(framing)
  if (!geometry) return f
  var slackX = W - geometry.width
  var slackY = H - geometry.height
  if (Math.abs(slackX) > 0.5) f.ax = round4(clamp(x / slackX, 0, 1))
  if (Math.abs(slackY) > 0.5) f.ay = round4(clamp(y / slackY, 0, 1))
  return f
}

// Zoom to `zoom` while the image point under (px, py) stays under it, as far
// as the anchors allow.
function zoomAt(imageWidth, imageHeight, W, H, framing, pixelRatio, zoom, px, py) {
  var f = normalizeFraming(framing)
  var before = layout(imageWidth, imageHeight, W, H, f, pixelRatio)
  if (!before) return f
  var next = normalizeFraming(Object.assign({}, f, { zoom: zoom }))
  var after = layout(imageWidth, imageHeight, W, H, next, pixelRatio)
  var u = (px - before.x) / before.width
  var v = (py - before.y) / before.height
  return panTo(next, after, W, H, px - u * after.width, py - v * after.height)
}

// How much of the image a plain centered fill hides on a W x H screen, 0..1.
function cropLoss(imageWidth, imageHeight, W, H) {
  if (![imageWidth, imageHeight, W, H].every(function(n) { return finite(n) && n > 0 })) return 0
  var image = imageWidth / imageHeight
  var screen = W / H
  return 1 - Math.min(image / screen, screen / image)
}

// A stable name for a wallpaper. Omarchy stages the active theme under one
// fixed directory, so two themes that both ship 1.jpg share a path; those are
// named by theme instead. Everything else is its path, with home shortened.
function keyFor(path, home, stagedDir, themeName) {
  path = String(path || "")
  if (!path) return ""
  if (stagedDir && themeName && path.indexOf(stagedDir + "/") === 0)
    return "theme:" + themeName + "/" + path.slice(stagedDir.length + 1)
  if (home && path.indexOf(home + "/") === 0) return "~" + path.slice(home.length)
  return path
}

function emptyConfig() {
  return { version: 1, settings: normalizeSettings(null), defaults: {}, frames: {} }
}

function normalizeSettings(value) {
  var src = plain(value) ? value : {}
  var seconds = finite(src.askSeconds) ? clamp(Math.round(src.askSeconds), 2, 60) : 6
  return {
    afterPick: AFTER_PICK.indexOf(src.afterPick) >= 0 ? src.afterPick : "ask",
    askSeconds: seconds,
    backdrop: BACKDROPS.indexOf(src.backdrop) >= 0 ? src.backdrop : "blur"
  }
}

function validName(name) {
  return typeof name === "string" && name.length > 0 && name.length <= 128
}

function normalizeConfig(value) {
  var src = plain(value) ? value : {}
  var out = emptyConfig()
  out.settings = normalizeSettings(src.settings)

  if (plain(src.defaults)) {
    Object.keys(src.defaults).forEach(function(monitor) {
      if (!validName(monitor)) return
      var framing = normalizeFraming(src.defaults[monitor])
      if (!sameFraming(framing, defaultFraming())) out.defaults[monitor] = framing
    })
  }

  if (plain(src.frames)) {
    var kept = 0
    Object.keys(src.frames).forEach(function(key) {
      var perMonitor = src.frames[key]
      if (kept >= MAX_FRAMES || !key || key.length > MAX_KEY || !plain(perMonitor)) return
      var entry = {}
      Object.keys(perMonitor).forEach(function(monitor) {
        if (validName(monitor)) entry[monitor] = normalizeFraming(perMonitor[monitor])
      })
      if (Object.keys(entry).length > 0) {
        out.frames[key] = entry
        kept += 1
      }
    })
  }

  return out
}

// What a monitor falls back on for a wallpaper it has no framing for.
function defaultFor(config, monitor) {
  var defaults = config && config.defaults
  return defaults && defaults[monitor] ? normalizeFraming(defaults[monitor]) : defaultFraming()
}

function hasFraming(config, key, monitor) {
  var frames = config && config.frames
  return !!(frames && key && frames[key] && frames[key][monitor])
}

function framingFor(config, key, monitor) {
  if (hasFraming(config, key, monitor)) return normalizeFraming(config.frames[key][monitor])
  return defaultFor(config, monitor)
}

function copyConfig(config) {
  var src = config || emptyConfig()
  var frames = {}
  Object.keys(src.frames || {}).forEach(function(key) { frames[key] = Object.assign({}, src.frames[key]) })
  return {
    version: 1,
    settings: Object.assign({}, src.settings),
    defaults: Object.assign({}, src.defaults),
    frames: frames
  }
}

// A framing that only repeats the monitor's default is not stored, so a later
// change to that default still reaches the wallpaper.
function withFraming(config, key, monitor, framing) {
  var next = copyConfig(config)
  if (!key || !validName(monitor)) return next
  var value = normalizeFraming(framing)
  var entry = Object.assign({}, next.frames[key])
  if (sameFraming(value, defaultFor(next, monitor))) delete entry[monitor]
  else entry[monitor] = value
  if (Object.keys(entry).length > 0) next.frames[key] = entry
  else delete next.frames[key]
  return next
}

// Makes `framing` the monitor's default. The wallpaper `keepKey` keeps the
// look it has now: its own entry goes, since the default now says the same.
function withDefault(config, monitor, framing, keepKey) {
  var next = copyConfig(config)
  if (!validName(monitor)) return next
  var value = normalizeFraming(framing)
  if (sameFraming(value, defaultFraming())) delete next.defaults[monitor]
  else next.defaults[monitor] = value
  if (keepKey && next.frames[keepKey]) {
    var entry = Object.assign({}, next.frames[keepKey])
    delete entry[monitor]
    if (Object.keys(entry).length > 0) next.frames[keepKey] = entry
    else delete next.frames[keepKey]
  }
  return next
}

// Gives a monitor an image of its own for one wallpaper. The framing starts
// over: where the last picture sat says nothing about this one.
function withImage(config, key, monitor, path) {
  var framing = defaultFraming()
  if (validImage(path)) framing.image = path
  return withFraming(config, key, monitor, framing)
}

// Back to the shared wallpaper. A monitor whose default names an image needs
// an entry that says so; otherwise the default's framing takes over.
function withoutImage(config, key, monitor) {
  var fallback = defaultFor(config, monitor)
  return withFraming(config, key, monitor, fallback.image ? defaultFraming() : fallback)
}

function fileName(path) {
  var text = String(path || "")
  return text.slice(text.lastIndexOf("/") + 1)
}

if (typeof module !== "undefined") module.exports = {
  MODES: MODES, ZOOM_MAX: ZOOM_MAX, zoomMin: zoomMin, defaultFraming: defaultFraming,
  normalizeFraming: normalizeFraming, sameFraming: sameFraming, layout: layout, decodeSize: decodeSize,
  panTo: panTo, zoomAt: zoomAt, cropLoss: cropLoss, keyFor: keyFor, emptyConfig: emptyConfig,
  normalizeSettings: normalizeSettings, normalizeConfig: normalizeConfig, defaultFor: defaultFor,
  hasFraming: hasFraming, framingFor: framingFor, copyConfig: copyConfig, withFraming: withFraming,
  withDefault: withDefault, withImage: withImage, withoutImage: withoutImage, fileName: fileName
}
