// node tests/model.test.js
const assert = require("node:assert/strict")
const test = require("node:test")
const M = require("../Model.js")

const near = (a, b, eps = 1e-6) => assert.ok(Math.abs(a - b) <= eps, `${a} !~ ${b}`)

test("fill covers the screen and centers by default", () => {
  const g = M.layout(3840, 2160, 2560, 720, M.defaultFraming(), 1)
  near(g.width, 2560)
  near(g.height, 1440)
  near(g.x, 0)
  near(g.y, -360)
  assert.equal(g.covers, true)
})

test("anchors pick the edge kept in a crop", () => {
  const top = M.layout(3840, 2160, 2560, 720, { mode: "fill", ay: 0 }, 1)
  near(top.y, 0)
  const bottom = M.layout(3840, 2160, 2560, 720, { mode: "fill", ay: 1 }, 1)
  near(bottom.y, -720)
})

test("fit leaves bars and reports it does not cover", () => {
  const g = M.layout(1000, 1000, 2000, 1000, { mode: "fit" }, 1)
  near(g.width, 1000)
  near(g.x, 500)
  assert.equal(g.covers, false)
})

test("stretch fills both axes whatever the rotation", () => {
  const g = M.layout(1000, 500, 1920, 1080, { mode: "stretch", rotation: 90 }, 1)
  near(g.width, 1920)
  near(g.height, 1080)
  assert.equal(g.rotated, true)
})

test("actual size is one image pixel per device pixel", () => {
  const g = M.layout(1000, 500, 1920, 1080, { mode: "actual" }, 2)
  near(g.width, 500)
  near(g.height, 250)
})

test("rotation swaps the sides used to cover", () => {
  const g = M.layout(4000, 2000, 1000, 2000, { mode: "fill", rotation: 90 }, 1)
  near(g.width, 1000)
  near(g.height, 2000)
})

test("zoom is held to the mode's range", () => {
  assert.equal(M.normalizeFraming({ mode: "fill", zoom: 0.2 }).zoom, 1)
  assert.equal(M.normalizeFraming({ mode: "fit", zoom: 0.2 }).zoom, 0.2)
  assert.equal(M.normalizeFraming({ mode: "fill", zoom: 99 }).zoom, M.ZOOM_MAX)
})

test("junk framings fall back to the default", () => {
  assert.deepEqual(M.normalizeFraming({ mode: "<img>", zoom: "2", ax: NaN, ay: 7, rotation: 45 }),
    { mode: "fill", zoom: 1, ax: 0.5, ay: 1, rotation: 0 })
  assert.deepEqual(M.normalizeFraming(null), M.defaultFraming())
})

test("panTo follows the pointer and stops at the edges", () => {
  const f = M.defaultFraming()
  const g = M.layout(3840, 2160, 2560, 720, f, 1)
  near(M.panTo(f, g, 2560, 720, 0, -100).ay, 100 / 720, 1e-4)
  assert.equal(M.panTo(f, g, 2560, 720, 0, 500).ay, 0)
  assert.equal(M.panTo(f, g, 2560, 720, 0, -5000).ay, 1)
  // No horizontal slack: that anchor is left alone.
  assert.equal(M.panTo(f, g, 2560, 720, -300, -100).ax, 0.5)
})

test("zoomAt keeps the point under the cursor", () => {
  const f = { mode: "fill", zoom: 1, ax: 0.5, ay: 0.5, rotation: 0 }
  const W = 2560, H = 1440, px = 700, py = 300
  const before = M.layout(2560, 1440, W, H, f, 1)
  const zoomed = M.zoomAt(2560, 1440, W, H, f, 1, 2, px, py)
  const after = M.layout(2560, 1440, W, H, zoomed, 1)
  near((px - before.x) / before.width, (px - after.x) / after.width, 1e-3)
  near((py - before.y) / before.height, (py - after.y) / after.height, 1e-3)
})

test("decodeSize covers the drawn size and never exceeds the file", () => {
  const g = M.layout(7680, 4320, 2560, 1440, M.defaultFraming(), 1)
  assert.deepEqual(M.decodeSize(7680, 4320, g, 1), { width: 2560, height: 1440 })
  const small = M.layout(1280, 720, 2560, 1440, M.defaultFraming(), 1)
  assert.deepEqual(M.decodeSize(1280, 720, small, 1), { width: 1280, height: 720 })
  const rotated = M.layout(4000, 2000, 1000, 2000, { rotation: 90 }, 1)
  assert.deepEqual(M.decodeSize(4000, 2000, rotated, 1), { width: 2000, height: 1000 })
})

test("decodeSize honors the pixel budget", () => {
  const g = M.layout(10000, 4000, 2560, 720, { zoom: 3 }, 1)
  const d = M.decodeSize(10000, 4000, g, 1, 3 * 2560 * 720)
  assert.ok(d.width * d.height <= 3 * 2560 * 720 * 1.01)
  near(d.width / d.height, 2.5, 0.01)
})

test("cropLoss measures what a plain fill hides", () => {
  near(M.cropLoss(1920, 1080, 1920, 1080), 0)
  near(M.cropLoss(3840, 2160, 2560, 720), 0.5)
})

test("keyFor names staged theme wallpapers by theme", () => {
  const home = "/home/u", staged = "/home/u/.local/state/omarchy/current/theme/backgrounds"
  assert.equal(M.keyFor(staged + "/1.jpg", home, staged, "nord"), "theme:nord/1.jpg")
  assert.equal(M.keyFor("/home/u/Pictures/a.png", home, staged, "nord"), "~/Pictures/a.png")
  assert.equal(M.keyFor("/srv/a.png", home, staged, "nord"), "/srv/a.png")
  assert.equal(M.keyFor("", home, staged, "nord"), "")
})

test("normalizeConfig drops what it cannot trust", () => {
  const c = M.normalizeConfig({
    settings: { afterPick: "explode", askSeconds: 9999, backdrop: "blur" },
    defaults: { "DP-1": { ay: 0 }, "DP-2": {} },
    frames: { "k": { "DP-1": { zoom: 2 } }, "empty": {}, "bad": "x" }
  })
  assert.deepEqual(c.settings, { afterPick: "ask", askSeconds: 60, backdrop: "blur" })
  assert.deepEqual(Object.keys(c.defaults), ["DP-1"])
  assert.deepEqual(Object.keys(c.frames), ["k"])
  assert.deepEqual(M.normalizeConfig("nope"), M.emptyConfig())
})

test("framingFor falls back to the monitor default, then the built-in one", () => {
  const c = M.normalizeConfig({ defaults: { "DP-2": { ay: 0 } }, frames: { k: { "DP-1": { zoom: 2 } } } })
  assert.equal(M.framingFor(c, "k", "DP-1").zoom, 2)
  assert.equal(M.framingFor(c, "k", "DP-2").ay, 0)
  assert.deepEqual(M.framingFor(c, "other", "DP-1"), M.defaultFraming())
})

test("withFraming does not mutate and prunes default entries", () => {
  const a = M.emptyConfig()
  const b = M.withFraming(a, "k", "DP-1", { zoom: 2 })
  assert.deepEqual(a.frames, {})
  assert.equal(b.frames.k["DP-1"].zoom, 2)
  const c = M.withFraming(b, "k", "DP-1", M.defaultFraming())
  assert.deepEqual(c.frames, {})
})

test("withDefault keeps the current wallpaper's look", () => {
  const a = M.withFraming(M.emptyConfig(), "k", "DP-2", { ay: 0 })
  const b = M.withDefault(a, "DP-2", { ay: 0 }, "k")
  assert.deepEqual(b.frames, {})
  assert.equal(M.framingFor(b, "k", "DP-2").ay, 0)
  assert.equal(M.framingFor(b, "other", "DP-2").ay, 0)
  const cleared = M.withDefault(b, "DP-2", M.defaultFraming(), "k")
  assert.deepEqual(cleared.defaults, {})
})

test("a framing keeps an image of its own only when it is an absolute path", () => {
  assert.equal(M.normalizeFraming({ image: "/a.jpg" }).image, "/a.jpg")
  assert.equal("image" in M.normalizeFraming({ image: "a.jpg" }), false)
  assert.equal("image" in M.normalizeFraming({ image: 7 }), false)
  assert.equal(M.sameFraming({ image: "/a.jpg" }, {}), false)
})

test("withImage starts the framing over and withoutImage returns to the default", () => {
  const a = M.withFraming(M.emptyConfig(), "k", "DP-1", { zoom: 2, ay: 0 })
  const b = M.withImage(a, "k", "DP-1", "/wide.jpg")
  assert.deepEqual(b.frames.k["DP-1"], { mode: "fill", zoom: 1, ax: 0.5, ay: 0.5, rotation: 0, image: "/wide.jpg" })
  assert.deepEqual(M.withoutImage(b, "k", "DP-1").frames, {})
})

test("a wallpaper can opt out of a monitor's default image", () => {
  const a = M.withDefault(M.emptyConfig(), "DP-1", { image: "/always.jpg" }, "")
  assert.equal(M.framingFor(a, "k", "DP-1").image, "/always.jpg")
  const b = M.withoutImage(a, "k", "DP-1")
  assert.equal("image" in M.framingFor(b, "k", "DP-1"), false)
  assert.equal(M.framingFor(b, "other", "DP-1").image, "/always.jpg")
})

test("edits keep the image", () => {
  const f = { image: "/a.jpg" }
  const g = M.layout(4000, 2000, 1000, 1000, f, 1)
  assert.equal(M.panTo(f, g, 1000, 1000, -100, 0).image, "/a.jpg")
  assert.equal(M.zoomAt(4000, 2000, 1000, 1000, f, 1, 2, 500, 500).image, "/a.jpg")
})

test("changesBetween lists only the entries that changed", () => {
  const base = M.normalizeConfig({
    defaults: { "DP-1": { ay: 0 } },
    frames: { a: { "DP-1": { zoom: 2 }, "DP-2": { ax: 0 } }, b: { "DP-1": { ay: 1 } } }
  })
  let next = M.withFraming(base, "a", "DP-1", { zoom: 3, ay: 0 })
  next = M.withFraming(next, "b", "DP-1", M.defaultFor(next, "DP-1"))
  next = M.withDefault(next, "DP-2", { mode: "fit" }, "")
  const changes = M.changesBetween(base, next)
  assert.deepEqual(changes.map(c => [c.kind, c.key || "", c.monitor, c.value && c.value.zoom]), [
    ["frame", "a", "DP-1", 3],
    ["frame", "b", "DP-1", null],
    ["default", "", "DP-2", 1]
  ])
  assert.deepEqual(M.changesBetween(base, M.copyConfig(base)), [])
})

test("mergeChanges keeps the latest change to each entry", () => {
  const older = [{ kind: "frame", key: "a", monitor: "DP-1", value: { zoom: 2 } }, { kind: "default", monitor: "DP-1", value: null }]
  const newer = [{ kind: "frame", key: "a", monitor: "DP-1", value: null }, { kind: "frame", key: "b", monitor: "DP-1", value: { zoom: 4 } }]
  const merged = M.mergeChanges(older, newer)
  assert.equal(merged.length, 3)
  assert.equal(merged[0].value, null)
  assert.equal(merged[2].key, "b")
})

test("a save writes its changes into the file as it is now, not as it was", () => {
  // The file when the framing mode opened, then an edit made to it meanwhile.
  const opened = { version: 1, frames: { a: { "DP-1": { zoom: 2 } } } }
  const onDisk = {
    version: 1, note: "kept", settings: { afterPick: "off" },
    defaults: { "HDMI-A-1": { ay: 1 } },
    frames: { a: { "DP-1": { zoom: 2 } }, c: { "DP-2": { zoom: 5, future: true } }, junk: "left alone" }
  }
  const before = M.normalizeConfig(opened)
  const draft = M.withFraming(before, "b", "DP-1", { zoom: 3 })
  const written = M.applyChanges(onDisk, M.changesBetween(before, draft))
  assert.equal(written.note, "kept")
  assert.equal(written.settings.afterPick, "off")
  assert.deepEqual(written.defaults, onDisk.defaults)
  assert.deepEqual(written.frames.a, onDisk.frames.a)
  assert.deepEqual(written.frames.c, onDisk.frames.c)
  assert.equal(written.frames.junk, "left alone")
  assert.equal(written.frames.b["DP-1"].zoom, 3)
  // The file itself is not modified in place.
  assert.equal(onDisk.frames.b, undefined)
})

test("removing a framing removes only that entry", () => {
  const onDisk = { frames: { a: { "DP-1": { zoom: 2 }, "DP-2": { zoom: 3 } }, b: { "DP-1": { zoom: 4 } } } }
  const one = M.applyChanges(onDisk, [{ kind: "frame", key: "a", monitor: "DP-1", value: null }])
  assert.deepEqual(Object.keys(one.frames.a), ["DP-2"])
  const both = M.applyChanges(one, [{ kind: "frame", key: "a", monitor: "DP-2", value: null }])
  assert.equal(both.frames.a, undefined)
  assert.equal(both.frames.b["DP-1"].zoom, 4)
})

test("with no file yet, changes start from the defaults", () => {
  const written = M.applyChanges(null, [{ kind: "default", monitor: "DP-1", value: { ay: 0 } }])
  assert.equal(written.version, 1)
  assert.equal(written.settings.afterPick, "ask")
  assert.equal(written.defaults["DP-1"].ay, 0)
})

test("parseSettings refuses anything it could not write back faithfully", () => {
  assert.equal(M.parseSettings('{"frames": {}').state, "error")
  assert.equal(M.parseSettings("[1, 2]").state, "error")
  assert.equal(M.parseSettings('"text"').state, "error")
  assert.equal(M.parseSettings("null").state, "error")
  assert.equal(M.parseSettings("").state, "missing")
  assert.equal(M.parseSettings("  \n").state, "missing")
  const ok = M.parseSettings('{"version": 1}')
  assert.equal(ok.state, "ok")
  assert.equal(ok.raw.version, 1)
})
