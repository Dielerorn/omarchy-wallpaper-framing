import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Omarchy's desktop background, with a framing per wallpaper and monitor.
//
// This is the stock background service (shell/plugins/background) with its
// images drawn through Frame.qml. Everything the stock one answers is kept:
// the `background` IPC target, the slanted reveal, the theme handoff, OWE's
// video suspension, and the double-click that opens the native picker. On top
// of that it remembers how each wallpaper sits on each monitor, offers to
// adjust it after a pick from the native picker, and lets the wallpaper be
// dragged into place.
Item {
  id: root

  property var shell: null
  property bool suspended: false
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  readonly property string currentThemeBackgrounds: stateHome + "/omarchy/current/theme/backgrounds"
  // WALLPAPER_FRAMING_CONFIG points a test instance at settings of its own.
  readonly property string configPath: Quickshell.env("WALLPAPER_FRAMING_CONFIG") || home + "/.config/omarchy/wallpaper-framing.json"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  // A theme switch names its next background before it has staged the rest of
  // the theme, so the incoming frame can decode while that work runs.
  property string preparedBackground: ""
  // The prepare and transition calls travel as separate IPC clients, so a
  // prepare can land after its transition. The path it names then must not be
  // decoded again.
  property string lastTransitionPath: ""
  // Native pixel size per wallpaper, read from the file header before the
  // image loads, so nothing is ever decoded at the file's size first. The
  // layout is worked out from it too, so it is kept per path and reload
  // version: a theme switch can put another picture behind the same path
  // while the old one is still on screen.
  property var nativeSizes: ({})
  property var sizeQueue: []
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int reloadVersion: 0
  // The reload version the displayed background was taken at. It moves with
  // displayedBackground, never ahead of it: the base frame must keep the
  // outgoing image until the reveal has covered it.
  property int displayedVersion: 0
  property int oldVersion: 0
  property int incomingVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1
  readonly property bool ready: {
    if (isVideo(displayedBackground)) return true
    if (backgrounds.instances.length === 0) return false
    for (var panel of backgrounds.instances) {
      if (!panel.backgroundReady) return false
    }
    return true
  }

  // ---------------------------------------------------------------- framing

  // A framing is looked up by wallpaper and monitor. The wallpaper's name is
  // taken when it becomes current, not from its path later: a theme switch
  // reveals from one snapshot file to another, and both stand for wallpapers
  // with names of their own.
  property string currentKey: ""
  property string displayedKey: ""
  property string incomingKey: ""
  property string oldKey: ""
  property string themeName: ""

  property var config: Model.emptyConfig()
  // The settings file is the framing library, and a save writes only the
  // entries changed here into whatever the file holds at that moment. So an
  // edit made to the file meanwhile stays, and a file that cannot be read is
  // never written over. `diskRaw` is the file as last read or written, parsed
  // (null: no file yet); `pending` holds changes not in the file yet. They
  // wait while the file cannot be read and go in once it can.
  property var diskRaw: null
  property var pending: []
  // "", "unreadable" or "unwritable".
  property string settingsProblem: ""
  property bool settingsProblemNoticed: false
  property string probeState: ""
  property bool writeFailed: false
  // A working copy while the framing mode is open. Everything on screen draws
  // from `view`, so the desktop under the overlay already matches on close.
  // Saving applies only what changed since `draftBase`, the copy it began as.
  property var draft: null
  property var draftBase: null
  readonly property var view: draft || config
  readonly property var settings: view.settings
  // Images of a monitor's own that failed to load. Such a monitor follows the
  // shared wallpaper instead.
  property var failedImages: ({})

  property bool framingOpen: false
  // The overlay steps aside while the native picker chooses a monitor's image.
  readonly property bool framingShown: framingOpen && !imagePickProc.running
  property bool framingMapped: false
  property string activeMonitor: ""
  property string imagePickMonitor: ""

  property bool promptOpen: false
  // Counts the offers made, so one made while another is up restarts its time.
  property int promptSerial: 0
  // Stays set through the offer's fade-out, so it is not unloaded mid-fade.
  property bool promptLoaded: false
  property bool pickPending: false
  property bool pickerOpen: false
  property double pickerClosedAt: 0

  readonly property var strings: catalog

  Commons.Translations {
    id: catalog
    directory: Qt.resolvedUrl("i18n")
  }

  onFramingShownChanged: {
    if (framingShown) {
      unmapTimer.stop()
      framingMapped = true
    } else {
      unmapTimer.restart()
    }
  }

  // Long enough for the overlay's own fade to finish before it unmaps.
  Timer {
    id: unmapTimer
    interval: 170
    onTriggered: root.framingMapped = false
  }

  function isVideo(path) {
    return Util.isVideoPath(path)
  }

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function readThemeName() {
    themeNameFile.reload()
    themeNameFile.waitForJob()
    themeName = String(themeNameFile.text() || "").trim()
  }

  function keyFor(path) {
    return Model.keyFor(path, home, currentThemeBackgrounds, themeName)
  }

  function framingFor(key, monitor) {
    return Model.framingFor(view, key, monitor)
  }

  // The image a monitor shows for a wallpaper in place of the wallpaper
  // itself, or "" when it follows it.
  function ownImage(key, monitor) {
    var image = framingFor(key, monitor).image || ""
    return image && !failedImages[image] ? image : ""
  }

  function noteImageFailed(path) {
    if (!path || failedImages[path]) return
    var next = Object.assign({}, failedImages)
    next[path] = true
    failedImages = next
    console.warn("wallpaper-framing: image did not load, following the wallpaper instead: " + path)
  }

  // The still this monitor shows, or "" when it shows the video wallpaper.
  function imageFor(monitor) {
    var own = ownImage(currentKey, monitor)
    if (own) return own
    return isVideo(currentBackground) ? "" : currentBackground
  }

  function hasOwnImage(monitor) {
    return ownImage(currentKey, monitor) !== ""
  }

  function framingOf(monitor) {
    return framingFor(currentKey, monitor)
  }

  function screenNamed(monitor) {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (String(Quickshell.screens[i].name) === monitor) return Quickshell.screens[i]
    }
    return null
  }

  function focusedMonitorName() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    if (name && screenNamed(name)) return name
    return Quickshell.screens.length > 0 ? String(Quickshell.screens[0].name) : ""
  }

  // Everything needed to lay a monitor's image out, or null when it has none
  // or its size is not known yet.
  function canvasOf(monitor) {
    var screen = screenNamed(monitor)
    var path = imageFor(monitor)
    var native = nativeSizeOf(path, hasOwnImage(monitor) ? 0 : reloadVersion)
    if (!screen || !native || !(native.width > 0) || !(native.height > 0)) return null
    return {
      width: screen.width, height: screen.height, ratio: screen.devicePixelRatio || 1,
      imageWidth: native.width, imageHeight: native.height
    }
  }

  function geometryOf(monitor) {
    var c = canvasOf(monitor)
    return c ? Model.layout(c.imageWidth, c.imageHeight, c.width, c.height, framingOf(monitor), c.ratio) : null
  }

  // Edits go to the draft while the framing mode is open, and straight to the
  // saved settings when they come from IPC with it closed.
  function mutate(next) {
    if (draft) draft = next
    else commit(Model.changesBetween(config, next))
  }

  function applyFraming(monitor, framing) {
    if (!currentKey) return
    mutate(Model.withFraming(view, currentKey, monitor, framing))
  }

  function panTo(monitor, x, y) {
    var c = canvasOf(monitor)
    if (!c) return
    var framing = framingOf(monitor)
    var geometry = Model.layout(c.imageWidth, c.imageHeight, c.width, c.height, framing, c.ratio)
    applyFraming(monitor, Model.panTo(framing, geometry, c.width, c.height, x, y))
  }

  function nudge(monitor, dx, dy) {
    var geometry = geometryOf(monitor)
    if (geometry) panTo(monitor, geometry.x + dx, geometry.y + dy)
  }

  // Zooms about (px, py), or the middle of the screen when none is given.
  function zoomBy(monitor, factor, px, py) {
    var c = canvasOf(monitor)
    if (!c) return
    var framing = framingOf(monitor)
    var zoom = Model.clamp(framing.zoom * factor, Model.zoomMin(framing.mode), Model.ZOOM_MAX)
    // A notch that lands within a hair of 100% is meant as 100%.
    if (Math.abs(zoom - 1) < 0.02) zoom = 1
    applyFraming(monitor, Model.zoomAt(c.imageWidth, c.imageHeight, c.width, c.height, framing, c.ratio, zoom,
      px === undefined ? c.width / 2 : px, py === undefined ? c.height / 2 : py))
  }

  function setMode(monitor, mode) {
    var framing = framingOf(monitor)
    if (framing.mode === mode && framing.zoom === 1) return
    applyFraming(monitor, Object.assign({}, framing, { mode: mode, zoom: 1 }))
  }

  function rotate(monitor, degrees) {
    var framing = framingOf(monitor)
    framing.rotation = (framing.rotation + degrees + 360) % 360
    applyFraming(monitor, framing)
  }

  // Back to the monitor's default framing. The image stays: reset is about
  // where the picture sits, not which picture it is.
  function resetFraming(monitor) {
    var framing = Model.defaultFor(view, monitor)
    var own = framingOf(monitor).image
    if (own) framing.image = own
    else delete framing.image
    applyFraming(monitor, framing)
  }

  // Whether this monitor's current look is its default for every wallpaper.
  function isMonitorDefault(monitor) {
    return !!view.defaults[monitor] && Model.sameFraming(framingOf(monitor), view.defaults[monitor])
  }

  function toggleMonitorDefault(monitor) {
    var key = currentKey
    var framing = framingOf(monitor)
    if (isMonitorDefault(monitor)) {
      // The wallpaper keeps its look; it just stops being the default.
      mutate(Model.withFraming(Model.withDefault(view, monitor, Model.defaultFraming(), ""), key, monitor, framing))
    } else {
      mutate(Model.withDefault(view, monitor, framing, key))
    }
  }

  // Gives the monitor an image of its own for the current wallpaper, or with
  // no path has it follow the wallpaper again.
  function setImage(monitor, path) {
    path = String(path || "").trim()
    if (!currentKey || (path && (path.charAt(0) !== "/" || isVideo(path)))) return
    if (path && failedImages[path]) {
      var cleared = Object.assign({}, failedImages)
      delete cleared[path]
      failedImages = cleared
    }
    if (path) requestNativeSize(path, 0)
    mutate(path ? Model.withImage(view, currentKey, monitor, path) : Model.withoutImage(view, currentKey, monitor))
  }

  function pickImage(monitor) {
    if (imagePickProc.running || !screenNamed(monitor)) return
    imagePickMonitor = monitor
    imagePickProc.command = ["bash", "-c", imagePickProc.script, "pick-image", imageFor(monitor), currentThemeBackgrounds,
      home + "/.config/omarchy/backgrounds", home + "/.config/omarchy/themes"]
    imagePickProc.running = true
  }

  function cycleMonitor(step) {
    var names = []
    for (var i = 0; i < Quickshell.screens.length; i++) names.push(String(Quickshell.screens[i].name))
    if (names.length === 0) return
    var index = names.indexOf(activeMonitor)
    activeMonitor = names[(index + step + names.length) % names.length]
  }

  function openFraming(monitor) {
    if (framingOpen) return
    promptOpen = false
    pickPending = false
    draft = Model.copyConfig(config)
    draftBase = Model.copyConfig(config)
    activeMonitor = monitor && screenNamed(monitor) ? monitor : focusedMonitorName()
    framingOpen = true
    // The controls belong on the monitor the pointer is on. A surface mapped
    // under a pointer at rest hears nothing from it until it moves, so ask.
    if (!monitor && !cursorProc.running) cursorProc.running = true
  }

  function monitorAt(x, y) {
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var screen = Quickshell.screens[i]
      if (x >= screen.x && x < screen.x + screen.width && y >= screen.y && y < screen.y + screen.height)
        return String(screen.name)
    }
    return ""
  }

  function closeFraming(save) {
    if (!framingOpen) return
    if (save && draft) commit(Model.changesBetween(draftBase, draft))
    draft = null
    draftBase = null
    framingOpen = false
  }

  function handleKey(event) {
    var monitor = activeMonitor
    var shift = event.modifiers & Qt.ShiftModifier
    var step = shift ? 1 : (event.modifiers & Qt.ControlModifier) ? 120 : 24
    var handled = true
    switch (event.key) {
    case Qt.Key_Escape: closeFraming(false); break
    case Qt.Key_Return:
    case Qt.Key_Enter: closeFraming(true); break
    case Qt.Key_Left: nudge(monitor, -step, 0); break
    case Qt.Key_Right: nudge(monitor, step, 0); break
    case Qt.Key_Up: nudge(monitor, 0, -step); break
    case Qt.Key_Down: nudge(monitor, 0, step); break
    case Qt.Key_Plus:
    case Qt.Key_Equal: zoomBy(monitor, 1.1); break
    case Qt.Key_Minus:
    case Qt.Key_Underscore: zoomBy(monitor, 1 / 1.1); break
    case Qt.Key_0: setMode(monitor, framingOf(monitor).mode); break
    case Qt.Key_1: setMode(monitor, "fill"); break
    case Qt.Key_2: setMode(monitor, "fit"); break
    case Qt.Key_3: setMode(monitor, "stretch"); break
    case Qt.Key_4: setMode(monitor, "actual"); break
    case Qt.Key_R: rotate(monitor, shift ? -90 : 90); break
    case Qt.Key_Backspace:
    case Qt.Key_Delete: resetFraming(monitor); break
    case Qt.Key_Tab: cycleMonitor(1); break
    case Qt.Key_Backtab: cycleMonitor(-1); break
    default: handled = false
    }
    if (handled) event.accepted = true
  }

  // A pick from the native picker, as opposed to a theme switch or a script
  // cycling backgrounds: the picker's layer is up, or has just come down.
  function fromPicker() {
    // A pick closes the picker within a moment of setting the background. If
    // the close never comes, the open was a missed event, not a picker.
    if (pickerOpen) pickerStale.restart()
    return bgSwitchProc.running || pickerOpen || Date.now() - pickerClosedAt < 2000
  }

  Timer {
    id: pickerStale
    interval: 3000
    onTriggered: root.pickerOpen = false
  }

  function notePick(path) {
    if (framingOpen || settings.afterPick === "off" || isVideo(path)) return
    pickPending = true
    // The reveal plays first; its end brings the offer up. A pick of the
    // wallpaper already showing has no reveal to wait for.
    pickTimer.interval = incomingBackground !== "" ? 2500 : 160
    pickTimer.restart()
  }

  function offerFraming() {
    pickTimer.stop()
    if (!pickPending) return
    pickPending = false
    if (framingOpen || isVideo(currentBackground)) return
    if (settings.afterPick === "open") openFraming("")
    else if (settings.afterPick === "ask") showPrompt()
  }

  function showPrompt() {
    promptSerial += 1
    promptOpen = true
  }

  function acceptPrompt() {
    promptOpen = false
    openFraming("")
  }

  Timer {
    id: pickTimer
    onTriggered: root.offerFraming()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.data !== "omarchy-image-selector") return
      if (event.name === "openlayer") {
        root.pickerOpen = true
      } else if (event.name === "closelayer") {
        pickerStale.stop()
        root.pickerOpen = false
        root.pickerClosedAt = Date.now()
      }
    }
  }

  // The settings file's text as it is on disk right now, read past any change
  // not yet heard from the watcher: null when there is no file, undefined when
  // it cannot be read.
  function readSettingsText() {
    probeState = ""
    configProbe.reload()
    configProbe.waitForJob()
    if (probeState === "loaded") return configProbe.text()
    return probeState === "missing" ? null : undefined
  }

  function readSettingsFile() {
    var text = readSettingsText()
    if (text === undefined) return { state: "error" }
    return text === null ? { state: "missing" } : Model.parseSettings(text)
  }

  // Takes in what the file holds, with the changes not yet in it on top. A
  // file that cannot be read changes nothing: the last settings read stay.
  function takeDisk(result) {
    if (result.state === "error") {
      reportProblem("unreadable")
      return false
    }
    diskRaw = result.state === "ok" ? result.raw : null
    if (settingsProblem === "unreadable") clearProblem()
    config = Model.normalizeConfig(Model.applyChanges(diskRaw, pending))
    return true
  }

  function commit(changes) {
    if (changes.length === 0) return
    pending = Model.mergeChanges(pending, changes)
    config = Model.normalizeConfig(Model.applyChanges(diskRaw, pending))
    writePending()
  }

  function writePending() {
    retryWrite.stop()
    if (pending.length === 0 || !takeDisk(readSettingsFile())) return
    var next = Model.applyChanges(diskRaw, pending)
    var text = JSON.stringify(next, null, 2) + "\n"
    writeFailed = false
    configFile.setText(text)
    // Quickshell reports a failed atomic commit as saved, so the changes are
    // let go only once the file read back from disk holds what was written.
    if (writeFailed || readSettingsText() !== text) {
      reportProblem("unwritable")
      return
    }
    diskRaw = next
    pending = []
    config = Model.normalizeConfig(next)
    clearProblem()
  }

  // A change heard from the watcher. Changes that waited on the file go in a
  // moment later, so an editor that writes in steps has finished.
  function fileLoaded(result) {
    if (takeDisk(result) && pending.length > 0) retryWrite.restart()
  }

  function reportProblem(kind) {
    if (settingsProblem !== kind) {
      settingsProblem = kind
      settingsProblemNoticed = false
      console.warn("wallpaper-framing: " + (kind === "unreadable"
        ? "the settings file cannot be read; it is left as it is and changes wait until it can be"
        : "the settings file cannot be written; changes wait for the next save"))
    }
    if (!settingsProblemNoticed) problemNotice.restart()
  }

  function clearProblem() {
    if (!settingsProblem) return
    settingsProblem = ""
    settingsProblemNoticed = false
    problemNotice.stop()
  }

  Timer {
    id: retryWrite
    interval: 500
    onTriggered: root.writePending()
  }

  // Waits out an editor's half-written file before saying anything, and the
  // notification service at startup.
  Timer {
    id: problemNotice
    interval: 3000
    onTriggered: {
      if (!root.settingsProblem || root.settingsProblemNoticed) return
      root.settingsProblemNoticed = true
      var where = root.configPath.indexOf(root.home + "/") === 0 ? "~" + root.configPath.slice(root.home.length) : root.configPath
      var kind = root.settingsProblem
      noticeProc.command = ["omarchy-notification-send", "-g", "\uf071",
        root.strings.t("notice." + kind + ".title"), root.strings.t("notice." + kind + ".body").arg(where)]
      noticeProc.running = true
    }
  }

  Process {
    id: noticeProc
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(text || "").split(",")
        var monitor = parts.length === 2 ? root.monitorAt(parseInt(parts[0], 10), parseInt(parts[1], 10)) : ""
        if (monitor && root.framingOpen) root.activeMonitor = monitor
      }
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    blockLoading: true
    // Writes finish before setText returns, so they can be checked at once.
    blockWrites: true
    onFileChanged: reload()
    onLoaded: root.fileLoaded(Model.parseSettings(text()))
    onLoadFailed: error => root.fileLoaded({ state: error === FileViewError.FileNotFound ? "missing" : "error" })
    onSaveFailed: root.writeFailed = true
  }

  // Reads the settings file on demand, just before a write.
  FileView {
    id: configProbe
    path: root.configPath
    printErrors: false
    blockLoading: true
    onLoaded: root.probeState = "loaded"
    onLoadFailed: error => root.probeState = error === FileViewError.FileNotFound ? "missing" : "error"
  }

  FileView {
    id: themeNameFile
    path: root.stateHome + "/omarchy/current/theme.name"
    printErrors: false
    blockLoading: true
  }

  // The native picker, choosing an image for one monitor. A wallpaper picked
  // from the staged theme is named by where the theme keeps it, since the
  // staged copy is replaced at the next theme switch.
  Process {
    id: imagePickProc
    readonly property string script: [
      'selected=$1 staged=$2 user_backgrounds=$3 user_themes=$4',
      'theme=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null)',
      'picked=$(omarchy-menu-images --selected "$selected" "$staged" "$user_backgrounds/$theme") || exit 0',
      '[[ -n $picked ]] || exit 0',
      'if [[ $picked == "$staged"/* ]]; then',
      '  name=${picked#"$staged"/}',
      '  for base in "$user_themes/$theme/backgrounds" "$OMARCHY_PATH/themes/$theme/backgrounds"; do',
      '    if [[ -f $base/$name ]]; then picked="$base/$name"; break; fi',
      '  done',
      'fi',
      'printf "%s\\n" "$picked"'
    ].join("\n")
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path && root.framingOpen) root.setImage(root.imagePickMonitor, path)
      }
    }
  }

  // ------------------------------------------------- the stock background

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  // The desktop must never be left without a wallpaper. A path that stops
  // loading, say one that ran through a theme since replaced, is resolved
  // again from the background link, which a theme switch always repoints.
  // Only a different path is taken, so a file that is there but unreadable
  // cannot loop.
  property string failedBackground: ""
  property int recoverVersion: -1

  function recoverBackground(failedPath) {
    if (!failedPath || failedPath !== displayedBackground) return
    failedBackground = failedPath
    if (recoverProc.running) return
    recoverVersion = backgroundVersion
    recoverProc.running = true
  }

  function finishRecovery(path) {
    path = String(path || "").trim()
    var failedPath = failedBackground
    failedBackground = ""
    if (recoverVersion !== backgroundVersion) {
      recoverBackground(failedPath)
      return
    }
    if (!path || path === failedPath) return
    setBackground(path, true)
  }

  function setBackground(path, instant) {
    if (instant) reloadVersion += 1
    transitionBackground("", path, path, instant, instant)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path || (!force && finalPath === currentBackground)) return
    if (path !== preparedBackground) preparedBackground = ""
    preparedBackgroundTimer.stop()
    lastTransitionPath = path
    // The incoming frame gates the reveal, so its size is read first.
    var startsOnFinal = path === finalPath
    requestNativeSize(path, startsOnFinal ? reloadVersion : 0)
    requestNativeSize(fromPath || displayedBackground, fromPath ? 0 : displayedVersion)
    requestNativeSize(finalPath, reloadVersion)
    var previousKey = currentKey
    readThemeName()
    currentBackground = finalPath
    currentKey = keyFor(finalPath)
    backgroundVersion += 1
    failedBackground = ""
    revealStartedVersion = -1

    // OWE draws a video background and fades the last still into it. That
    // still stays on screen until OWE has the first frame and suspends this
    // layer, so the desktop does not show an empty background meanwhile. A
    // running reveal finishes on its incoming still, which OWE fades from.
    if (!instant && !root.suspended && displayedBackground && isVideo(path) && !isVideo(displayedBackground)) return

    revealAnimation.stop()
    finishingTransition = false
    finishTimer.stop()
    revealGate.stop()
    revealGate.elapsed = false

    // Video frames are not fed through the image-only reveal stack. Switching
    // instantly also avoids decoding two full videos during a transition.
    if (instant || !displayedBackground || isVideo(path) || isVideo(displayedBackground)) {
      oldBackground = ""
      incomingBackground = ""
      preparedBackground = ""
      displayedBackground = finalPath
      displayedVersion = reloadVersion
      displayedKey = currentKey
      revealProgress = 1
      return
    }

    // A snapshot handed in stands for the wallpaper that was current; without
    // one the reveal starts from whatever the base frame shows.
    oldKey = fromPath ? previousKey : displayedKey
    oldVersion = fromPath ? 0 : displayedVersion
    oldBackground = fromPath || displayedBackground
    incomingKey = currentKey
    incomingVersion = startsOnFinal ? reloadVersion : 0
    incomingBackground = path
    revealProgress = 0
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    // Background polling can advance backgroundVersion while a theme switch is
    // pending; the latest theme payload should still apply.
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Commons.Color.loadColors(pendingColorsRaw)
    // Commons.Color.loadShell also refreshes Style so the type scale flips with the
    // background reveal instead of waiting for a separate reload path.
    Commons.Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    // Two themes can stage different pictures at one path. Marking the
    // switch makes the final image load fresh instead of matching the old
    // theme's bitmap in the image cache.
    reloadVersion += 1
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  // The wipe starts on every monitor together. The first incoming frame to
  // decode holds it a moment for the rest; one that still is not ready then
  // joins the wipe where it has got to, rather than cutting in at the end.
  function considerReveal() {
    Qt.callLater(root.startRevealWhenReady)
  }

  function startRevealWhenReady() {
    if (!incomingBackground || revealProgress !== 0 || revealStartedVersion === backgroundVersion) return
    var ready = 0
    var waiting = 0
    for (var panel of backgrounds.instances) {
      if (panel.incomingReady()) ready += 1
      else if (!panel.incomingFailed()) waiting += 1
    }
    if (ready === 0) {
      // Nothing decoded and nothing still trying: there is no frame to wipe
      // to, so the base frame takes the new path and its own recovery.
      if (waiting === 0 && backgrounds.instances.length > 0) settleWithoutReveal()
      return
    }
    if (waiting > 0 && !revealGate.elapsed) {
      if (!revealGate.running) revealGate.start()
      return
    }
    revealGate.stop()
    for (var joining of backgrounds.instances) {
      if (joining.incomingReady()) joining.maskReady = true
    }
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function settleWithoutReveal() {
    revealGate.stop()
    oldBackground = ""
    incomingBackground = ""
    preparedBackground = ""
    displayedBackground = currentBackground
    displayedVersion = reloadVersion
    displayedKey = currentKey
    revealProgress = 1
    applyPendingTheme()
  }

  Timer {
    id: revealGate
    property bool elapsed: false
    interval: 400
    onTriggered: {
      elapsed = true
      root.startRevealWhenReady()
    }
  }

  // The reveal ends on the incoming frame. It is let go once every monitor's
  // base frame has loaded the final image underneath it. Asked a turn later:
  // a frame reports ready before bindings that read it have caught up.
  function maybeFinishTransition() {
    if (finishingTransition) Qt.callLater(root.finishWhenSettled)
  }

  function finishWhenSettled() {
    if (!finishingTransition) return
    for (var panel of backgrounds.instances) {
      if (!panel.baseSettled()) return
    }
    finishTransition()
  }

  function finishTransition() {
    finishTimer.stop()
    if (!finishingTransition) return
    incomingBackground = ""
    oldBackground = ""
    preparedBackground = ""
    finishingTransition = false
    pruneNativeSizes()
  }

  function prepareBackground(path) {
    path = String(path || "").trim()
    // Only a still that is not already on screen is worth decoding ahead.
    if (!path || isVideo(path) || path === lastTransitionPath || path === displayedBackground) return
    requestNativeSize(path, 0)
    preparedBackground = path
    preparedBackgroundTimer.restart()
  }

  function sizeKey(path, version) {
    return version ? path + "?v=" + version : path
  }

  function nativeSizeOf(path, version) {
    return path ? nativeSizes[sizeKey(path, version)] : undefined
  }

  function requestNativeSize(path, version) {
    if (!path || isVideo(path)) return
    var key = sizeKey(path, version || 0)
    if (nativeSizes[key] !== undefined) return
    for (var i = 0; i < sizeQueue.length; i++) {
      if (sizeQueue[i].key === key) return
    }
    sizeQueue = sizeQueue.concat([{ key: key, path: path }])
    probeNextSize()
  }

  function probeNextSize() {
    if (sizeProbe.running || sizeQueue.length === 0) return
    sizeProbe.key = sizeQueue[0].key
    sizeProbe.path = sizeQueue[0].path
    sizeProbe.command = ["magick", "identify", "-ping", "-format", "%w %h", sizeProbe.path + "[0]"]
    sizeProbe.running = true
  }

  // Each theme switch names fresh snapshot paths, so keep only the sizes of
  // the wallpapers still in play, and of the images monitors have of their own.
  function pruneNativeSizes() {
    var keep = {}
    function hold(path, version) {
      if (!path) return
      keep[sizeKey(path, version)] = true
      keep[path] = true
    }
    hold(displayedBackground, displayedVersion)
    hold(incomingBackground, incomingVersion)
    hold(oldBackground, oldVersion)
    hold(preparedBackground, 0)
    hold(currentBackground, reloadVersion)
    for (var monitor in view.defaults) hold(view.defaults[monitor].image, 0)
    for (var key in view.frames) {
      for (var name in view.frames[key]) hold(view.frames[key][name].image, 0)
    }
    var kept = {}
    for (var known in nativeSizes) {
      if (keep[known]) kept[known] = nativeSizes[known]
    }
    nativeSizes = kept
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    var payload = JSON.stringify({ source: "themes" })

    // A cloned background may not summon the picker in-process, so it takes
    // the IPC route instead.
    if (!root.shell || !root.shell.summon("omarchy.image-picker", payload))
      Util.execArgv(["omarchy-shell", "shell", "summon", "omarchy.image-picker", payload])
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: sizeProbe
    property string key: ""
    property string path: ""
    stdout: StdioCollector { id: sizeProbeOut }
    onExited: function(exitCode) {
      var parts = String(sizeProbeOut.text || "").trim().split(/\s+/)
      var width = exitCode === 0 ? parseInt(parts[0], 10) : 0
      var height = exitCode === 0 ? parseInt(parts[1], 10) : 0
      var known = Object.assign({}, root.nativeSizes)
      // An unreadable header records 0x0, which is drawn as a plain fill.
      var size = { width: width > 0 ? width : 0, height: height > 0 ? height : 0 }
      known[key] = size
      // The shell's theme cover asks by plain path for what is displayed.
      known[path] = size
      root.nativeSizes = known
      root.sizeQueue = root.sizeQueue.filter(function(queued) { return queued.key !== sizeProbe.key })
      root.probeNextSize()
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // The link's target when it exists, or else the theme's first background,
  // so a link left dangling still finds a wallpaper.
  Process {
    id: recoverProc
    command: [
      "bash", "-c",
      'target=$(readlink -f "$1"); if [[ -e $target ]]; then echo "$target"; else ' +
      'find "$2" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) | sort | head -n 1; fi',
      "resolve", root.currentBackgroundLink, root.currentThemeBackgrounds
    ]
    stdout: StdioCollector {
      onStreamFinished: root.finishRecovery(text)
    }
  }

  ShellIpc {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      var picked = root.fromPicker()
      root.setBackground(path, false)
      if (picked) root.notePick(String(path || "").trim())
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function setSuspended(value: string): void {
      root.suspended = value === "true"
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }

    function prepare(path: string): void {
      root.prepareBackground(path)
    }
  }

  ShellIpc {
    target: "wallpaper-framing"

    function open(): string {
      root.openFraming("")
      return "ok"
    }

    function save(): string {
      root.closeFraming(true)
      return "ok"
    }

    function cancel(): string {
      root.closeFraming(false)
      return "ok"
    }

    function toggle(): string {
      if (root.framingOpen) root.closeFraming(false)
      else root.openFraming("")
      return "ok"
    }

    // Offers the adjustment the way a pick from the native picker does.
    function ask(): string {
      root.pickPending = false
      if (root.framingOpen || root.isVideo(root.currentBackground)) return "unavailable"
      root.showPrompt()
      return "ok"
    }

    function frame(monitor: string, framingJson: string): string {
      if (!root.screenNamed(monitor)) return "unknown monitor"
      try {
        root.applyFraming(monitor, JSON.parse(framingJson))
      } catch (e) {
        return "invalid framing"
      }
      return "ok"
    }

    function reset(monitor: string): string {
      if (!root.screenNamed(monitor)) return "unknown monitor"
      root.resetFraming(monitor)
      return "ok"
    }

    // An image of the monitor's own for the current wallpaper.
    function image(monitor: string, path: string): string {
      if (!root.screenNamed(monitor)) return "unknown monitor"
      if (path.charAt(0) !== "/" || root.isVideo(path)) return "an absolute path to a still image is required"
      root.setImage(monitor, path)
      return "ok"
    }

    function follow(monitor: string): string {
      if (!root.screenNamed(monitor)) return "unknown monitor"
      root.setImage(monitor, "")
      return "ok"
    }

    function state(): string {
      var monitors = {}
      for (var i = 0; i < Quickshell.screens.length; i++) {
        var name = String(Quickshell.screens[i].name)
        monitors[name] = {
          image: root.imageFor(name), ownImage: root.hasOwnImage(name),
          framing: root.framingOf(name), geometry: root.geometryOf(name)
        }
      }
      return JSON.stringify({
        open: root.framingOpen, asking: root.promptOpen, active: root.activeMonitor,
        wallpaper: root.currentBackground, key: root.currentKey,
        settings: root.settings, settingsProblem: root.settingsProblem, unsaved: root.pending.length,
        monitors: monitors
      })
    }
  }

  // A prepared frame that no transition claims, say from a theme switch that
  // failed after naming it, must not hold its decoded texture indefinitely.
  Timer {
    id: preparedBackgroundTimer
    interval: 5000
    repeat: false
    onTriggered: root.preparedBackground = ""
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  // A base frame that never reports back must not hold the reveal's frames.
  Timer {
    id: finishTimer
    interval: 3000
    onTriggered: root.finishTransition()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: Style.duration(840)
    easing.type: Easing.OutCubic
    onFinished: {
      if (root.incomingBackground) {
        // After a video was chosen during the reveal, the incoming still
        // stays until OWE takes the background.
        var settlesOnCurrent = root.currentBackground && !root.isVideo(root.currentBackground)
        root.displayedBackground = settlesOnCurrent ? root.currentBackground : root.incomingBackground
        root.displayedVersion = root.reloadVersion
        root.displayedKey = settlesOnCurrent ? root.currentKey : root.incomingKey
        root.finishingTransition = true
        finishTimer.restart()
      }
      root.revealProgress = 1
      if (root.pickPending) {
        pickTimer.interval = 90
        pickTimer.restart()
      }
    }
  }

  Component.onCompleted: {
    takeDisk(readSettingsFile())
    readThemeName()
    refreshBackground()
  }

  Variants {
    id: backgrounds
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      readonly property string monitorName: String(modelData.name || "")
      // While OWE plays the current video the displayed still is a stale one,
      // so a monitor's own image is looked up for the wallpaper that is current.
      readonly property string baseKey: root.suspended ? root.currentKey : root.displayedKey
      readonly property string baseOwn: root.ownImage(baseKey, monitorName)
      readonly property string oldOwn: root.ownImage(root.oldKey, monitorName)
      readonly property string incomingOwn: root.incomingBackground !== "" ? root.ownImage(root.incomingKey, monitorName) : ""
      readonly property real pixelRatio: modelData.devicePixelRatio || 1
      // Three screens' worth of pixels: room to crop a much wider or taller
      // image, or to zoom well in, before the decode is held back.
      readonly property real pixelBudget: 3 * Math.ceil(width * pixelRatio) * Math.ceil(height * pixelRatio)

      screen: modelData
      // A monitor with an image of its own keeps it while OWE plays a video
      // on the others.
      visible: !remapGuard.remapping && (!root.suspended || baseOwn !== "")
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. A still
      // wallpaper costs nothing to keep enabled. OWE manages video layers.
      updatesEnabled: true

      property bool maskReady: false
      property int readyFrames: 0
      readonly property bool backgroundReady: base.ready && readyFrames >= 2

      function baseSettled() {
        return base.ready || base.failed || base.path === ""
      }

      function incomingReady() {
        return incomingFrame.ready
      }

      function incomingFailed() {
        return incomingFrame.failed
      }

      FrameAnimation {
        running: base.ready && panel.readyFrames < 2
        onTriggered: panel.readyFrames += 1
      }

      function maybeStartReveal() {
        if (!root.incomingBackground || maskReady) return
        if (root.revealStartedVersion === root.backgroundVersion) {
          // The wipe is already under way: join it where it is.
          if (incomingFrame.ready && root.revealProgress < 1) maskReady = true
          return
        }
        if (incomingFrame.ready || incomingFrame.failed) root.considerReveal()
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // OWE owns video backgrounds. This layer draws stills, and stays empty
      // behind a video so OWE's own layer shows through.
      Frame {
        id: base
        anchors.fill: parent
        path: panel.baseOwn || (root.isVideo(root.displayedBackground) ? "" : root.displayedBackground)
        version: panel.baseOwn ? 0 : root.displayedVersion
        nativeSize: root.nativeSizeOf(base.path, base.version)
        framing: root.framingFor(panel.baseKey, panel.monitorName)
        settleDecode: root.framingOpen
        pixelRatio: panel.pixelRatio
        maxPixels: panel.pixelBudget
        backdrop: root.settings.backdrop
        backdropColor: Commons.Color.background
        onPathChanged: root.requestNativeSize(path, version)
        onVersionChanged: root.requestNativeSize(path, version)
        Component.onCompleted: root.requestNativeSize(path, version)
        onFailedChanged: {
          if (!failed) return
          if (panel.baseOwn && path === panel.baseOwn) root.noteImageFailed(path)
          else root.recoverBackground(path)
          root.maybeFinishTransition()
        }
        onReadyChanged: {
          panel.readyFrames = 0
          if (ready) root.maybeFinishTransition()
        }
      }

      Frame {
        id: oldFrame
        anchors.fill: parent
        path: root.oldBackground === "" ? "" : (panel.oldOwn || root.oldBackground)
        version: panel.oldOwn ? 0 : root.oldVersion
        nativeSize: root.nativeSizeOf(oldFrame.path, oldFrame.version)
        framing: root.framingFor(root.oldKey, panel.monitorName)
        pixelRatio: panel.pixelRatio
        maxPixels: panel.pixelBudget
        backdrop: root.settings.backdrop
        backdropColor: Commons.Color.background
        // A snapshot is a one-off file; a monitor's own image is not.
        cached: panel.oldOwn !== ""
        visible: path !== "" && root.revealProgress < 1
        onPathChanged: root.requestNativeSize(path, version)
        onVersionChanged: root.requestNativeSize(path, version)
        Component.onCompleted: root.requestNativeSize(path, version)
        onFailedChanged: if (failed && path === panel.oldOwn) root.noteImageFailed(path)
        onReadyChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        visible: root.incomingBackground !== "" && incomingFrame.ready && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Frame {
          id: incomingFrame
          anchors.fill: parent
          // The same URL and size as a prepared frame keeps its decoded
          // image, so a transition to it can reveal at once.
          path: root.incomingBackground !== "" ? (panel.incomingOwn || root.incomingBackground) : root.preparedBackground
          version: panel.incomingOwn || root.incomingBackground === "" ? 0 : root.incomingVersion
          nativeSize: root.nativeSizeOf(incomingFrame.path, incomingFrame.version)
          framing: root.framingFor(root.incomingBackground !== "" ? root.incomingKey : "", panel.monitorName)
          pixelRatio: panel.pixelRatio
          maxPixels: panel.pixelBudget
          backdrop: root.settings.backdrop
          backdropColor: Commons.Color.background
          cached: panel.incomingOwn !== ""
          onPathChanged: root.requestNativeSize(path, version)
          onVersionChanged: root.requestNativeSize(path, version)
          Component.onCompleted: root.requestNativeSize(path, version)
          onFailedChanged: {
            if (!failed) return
            if (path === panel.incomingOwn) root.noteImageFailed(path)
            else panel.maybeStartReveal()
          }
          onReadyChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
        // The incoming path is set before the reveal is reset, so a frame
        // that was ready beforehand (a prepared one, or a monitor's own
        // image from the cache) is checked again here. It has no load of its
        // own left to announce it.
        function onRevealProgressChanged() {
          if (root.revealProgress === 0) panel.maybeStartReveal()
        }
      }

      // Left opens the native wallpaper picker and right the theme picker, as
      // stock. Middle opens the framing mode on this monitor.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else if (mouse.button === Qt.MiddleButton) root.openFraming(panel.monitorName)
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }

  // ------------------------------------------------------- framing surfaces

  Variants {
    model: root.framingMapped ? Quickshell.screens : []

    FramingOverlay {
      service: root
    }
  }

  Loader {
    active: root.promptLoaded
    sourceComponent: Prompt {
      service: root
    }
  }

  onPromptOpenChanged: {
    if (promptOpen) {
      promptLinger.stop()
      promptLoaded = true
    } else {
      promptLinger.restart()
    }
  }

  Timer {
    id: promptLinger
    interval: 400
    onTriggered: root.promptLoaded = false
  }
}
