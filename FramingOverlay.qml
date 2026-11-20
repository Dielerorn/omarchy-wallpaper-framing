import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The framing mode on one monitor: the wallpaper as it will sit there, drawn
// above every window, to be dragged and zoomed into place. The desktop's own
// background draws the same working copy underneath, so closing this only
// lets the windows back in.
PanelWindow {
  id: win

  required property var modelData
  property var service: null

  readonly property string monitorName: String(modelData.name || "")
  readonly property bool active: !!service && service.activeMonitor === monitorName
  readonly property string imagePath: service ? service.imageFor(monitorName) : ""
  readonly property bool ownImage: !!service && service.hasOwnImage(monitorName)
  readonly property real pixelRatio: modelData.devicePixelRatio || 1

  // Held back until the surface has its full size and the wallpaper has
  // decoded, so the desktop is never swapped for a half-drawn frame.
  readonly property bool sized: backingWindowVisible && width === modelData.width && height === modelData.height
  property bool settled: false
  readonly property bool revealed: !!service && service.framingShown && settled

  function requestSize() {
    if (service) service.requestNativeSize(imagePath, frame.version)
  }

  function settleWhenDrawn() {
    if (!settled && sized && (frame.ready || frame.failed || imagePath === "")) settled = true
  }

  onSizedChanged: settleWhenDrawn()
  onImagePathChanged: {
    requestSize()
    settleWhenDrawn()
  }

  // The offer's button sits where these controls come up, so a second click
  // meant for it would land on one of them. They take the pointer a moment
  // after they appear.
  property bool armed: false
  Timer {
    interval: 350
    running: win.revealed && !win.armed
    onTriggered: win.armed = true
  }

  // A slow decode must not hold a keyboard-grabbing surface invisible.
  Timer {
    interval: 450
    running: win.sized && !win.settled
    onTriggered: win.settled = true
  }

  screen: modelData
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  // The background's own namespace: it is the background, raised. Omarchy's
  // Hyprland rules already keep compositor animations off it, so the fade
  // below is the only one.
  WlrLayershell.namespace: "omarchy-background"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: service && service.framingShown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  Item {
    id: stage
    anchors.fill: parent
    opacity: win.revealed ? 1 : 0
    focus: true
    LayoutMirroring.enabled: Commons.I18n.rightToLeft
    LayoutMirroring.childrenInherit: true

    Behavior on opacity {
      id: fade
      NumberAnimation {
        duration: Style.duration(fade.targetValue > 0 ? 180 : 120)
        easing.type: Easing.OutCubic
      }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (win.service && win.revealed) win.service.handleKey(event)
    }
    Component.onCompleted: forceActiveFocus()

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.background
    }

    Frame {
      id: frame
      anchors.fill: parent
      path: win.imagePath
      version: !win.service || win.ownImage ? 0 : win.service.reloadVersion
      nativeSize: win.service ? win.service.nativeSizeOf(frame.path, frame.version) : undefined
      onVersionChanged: win.requestSize()
      Component.onCompleted: win.requestSize()
      framing: win.service ? win.service.framingOf(win.monitorName) : ({})
      pixelRatio: win.pixelRatio
      maxPixels: 3 * Math.ceil(win.width * win.pixelRatio) * Math.ceil(win.height * win.pixelRatio)
      backdrop: win.service ? win.service.settings.backdrop : "color"
      backdropColor: Commons.Color.background
      // The image follows the pointer exactly while dragged, and eases for
      // everything else: a wheel notch, a mode switch, a reset.
      settleDecode: true
      animated: win.revealed && !pan.pressed
      fadeIn: win.settled
      onReadyChanged: win.settleWhenDrawn()
      onFailedChanged: win.settleWhenDrawn()
    }

    // Thirds, while the image is held.
    Item {
      anchors.fill: parent
      opacity: pan.pressed ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
      }

      Repeater {
        model: 2
        Rectangle {
          required property int index
          x: Math.round(parent.width * (index + 1) / 3)
          width: 1
          height: parent.height
          color: Qt.rgba(1, 1, 1, 0.32)
        }
      }
      Repeater {
        model: 2
        Rectangle {
          required property int index
          y: Math.round(parent.height * (index + 1) / 3)
          width: parent.width
          height: 1
          color: Qt.rgba(1, 1, 1, 0.32)
        }
      }
    }

    // The monitor the pointer is on when the mode opens is the active one,
    // before the pointer has moved at all.
    HoverHandler {
      onHoveredChanged: if (hovered && win.service) win.service.activeMonitor = win.monitorName
    }

    MouseArea {
      id: pan
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: !frame.geometry ? Qt.ArrowCursor : pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

      property real pressX: 0
      property real pressY: 0
      property real originX: 0
      property real originY: 0
      property bool held: false

      // Where the image was when the pointer took hold of it.
      function grab(x, y) {
        var geometry = win.service.geometryOf(win.monitorName)
        held = !!geometry
        if (!geometry) return
        pressX = x
        pressY = y
        originX = geometry.x
        originY = geometry.y
      }

      onEntered: win.service.activeMonitor = win.monitorName
      onPressed: function(mouse) {
        win.service.activeMonitor = win.monitorName
        if (win.revealed) grab(mouse.x, mouse.y)
      }
      onReleased: held = false
      onPositionChanged: function(mouse) {
        if (win.service.activeMonitor !== win.monitorName) win.service.activeMonitor = win.monitorName
        if (pressed && held) win.service.panTo(win.monitorName, originX + mouse.x - pressX, originY + mouse.y - pressY)
      }
      onDoubleClicked: {
        if (!win.revealed) return
        var mode = win.service.framingOf(win.monitorName).mode
        win.service.setMode(win.monitorName, mode === "fill" ? "fit" : "fill")
      }
      onWheel: function(wheel) {
        if (!win.revealed) return
        win.service.activeMonitor = win.monitorName
        // A mouse notch is 120; a touchpad sends pixels.
        var notches = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y / 120 : wheel.pixelDelta.y / 60
        if (notches === 0) return
        win.service.zoomBy(win.monitorName, Math.exp(notches * 0.1), wheel.x, wheel.y)
        // The image changed size under a held pointer: take hold again here.
        if (pressed) grab(wheel.x, wheel.y)
        wheel.accepted = true
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: win.imagePath === ""
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(520))
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: win.service ? win.service.strings.t("overlay.video") : ""
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
    }

    FramingHud {
      service: win.service
      monitorName: win.monitorName
      screenWidth: win.modelData.width * win.pixelRatio
      screenHeight: win.modelData.height * win.pixelRatio
      imagePath: win.imagePath
      ownImage: win.ownImage
      active: win.active
      enabled: win.armed
      maxWidth: stage.width - Style.space(48)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(40)
    }
  }
}
