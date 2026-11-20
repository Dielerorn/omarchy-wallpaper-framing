import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The controls of the framing mode, one card per monitor. The monitor under
// the pointer shows them all; the others keep only their caption, so it is
// plain which screen a keypress will change.
BorderSurface {
  id: hud

  property var service: null
  property string monitorName: ""
  property real screenWidth: 0
  property real screenHeight: 0
  property string imagePath: ""
  property bool ownImage: false
  property bool active: false
  property real maxWidth: 0

  readonly property var framing: service ? service.framingOf(monitorName) : ({ mode: "fill", zoom: 1 })
  // A monitor showing the video wallpaper has nothing to frame, but can
  // still be given an image of its own.
  readonly property bool editable: imagePath !== ""
  readonly property int pad: Style.spacing.popupPadding
  readonly property color ink: Commons.Color.popups.text
  readonly property color faint: Util.alpha(Commons.Color.popups.text, 0.62)
  readonly property real room: maxWidth - 2 * pad - borderLeft - borderRight
  readonly property bool oneRow: controls.implicitWidth + actions.implicitWidth + Style.space(28) <= room

  function tr(key) {
    return service ? service.strings.t(key) : ""
  }

  function fileName(path) {
    var text = String(path || "")
    return text.slice(text.lastIndexOf("/") + 1)
  }

  width: borderLeft + pad + body.implicitWidth + pad + borderRight
  height: borderTop + pad + body.implicitHeight + pad + borderBottom
  // A screen too narrow for even the stacked rows gets the card scaled down
  // rather than clipped.
  scale: maxWidth > 0 && width > maxWidth ? maxWidth / width : 1
  transformOrigin: Item.Bottom
  color: Util.alpha(Commons.Color.popups.background, 0.96)
  borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  radius: Style.cornerRadius
  opacity: active ? 1 : 0.8
  Behavior on opacity {
    NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic }
  }

  // Presses and the wheel over the card stay on the card instead of moving
  // the wallpaper behind it.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onWheel: function(wheel) { wheel.accepted = true }
  }

  Column {
    id: body
    x: hud.borderLeft + hud.pad
    y: hud.borderTop + hud.pad
    spacing: Style.spacing.lg

    Row {
      spacing: Style.spacing.lg

      Text {
        textFormat: Text.PlainText
        text: hud.monitorName
        color: hud.ink
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        anchors.baseline: parent.children[0].baseline
        text: {
          var parts = [Math.round(hud.screenWidth) + " × " + Math.round(hud.screenHeight)]
          if (hud.editable) {
            parts.push(hud.fileName(hud.imagePath))
            if (hud.ownImage) parts.push(hud.tr("hud.ownImage"))
            if (!hud.active) {
              parts.push(hud.tr("mode." + hud.framing.mode))
              parts.push(hud.tr("hud.percent").arg(Commons.I18n.formatNumber(Math.round(hud.framing.zoom * 100))))
            }
          } else {
            parts.push(hud.tr("hud.video"))
          }
          return parts.join("  ·  ")
        }
        color: hud.faint
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
        width: Math.min(implicitWidth, Math.max(Style.space(160), hud.room - parent.children[0].width - parent.spacing))
      }
    }

    GridLayout {
      visible: hud.active
      columns: hud.oneRow ? 2 : 1
      columnSpacing: Style.space(28)
      rowSpacing: Style.spacing.lg

      Row {
        id: controls
        spacing: Style.spacing.lg

        Row {
          spacing: Style.spacing.lg
          enabled: hud.editable
          opacity: enabled ? 1 : 0.4
          anchors.verticalCenter: parent.verticalCenter

          ButtonGroup {
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            foreground: hud.ink
            background: "transparent"
            options: [
              { value: "fill", label: hud.tr("mode.fill"), tooltip: hud.tr("tip.fill") },
              { value: "fit", label: hud.tr("mode.fit"), tooltip: hud.tr("tip.fit") },
              { value: "stretch", label: hud.tr("mode.stretch"), tooltip: hud.tr("tip.stretch") },
              { value: "actual", label: hud.tr("mode.actual"), tooltip: hud.tr("tip.actual") }
            ]
            value: hud.framing.mode
            onChanged: function(value) { hud.service.setMode(hud.monitorName, value) }
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "−"
              bordered: true
              foreground: hud.ink
              tooltipText: hud.tr("tip.zoomOut")
              onClicked: hud.service.zoomBy(hud.monitorName, 1 / 1.1)
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: zoomWidest.advanceWidth + Style.spacing.md * 2
              horizontalAlignment: Text.AlignHCenter
              text: hud.tr("hud.percent").arg(Commons.I18n.formatNumber(Math.round(hud.framing.zoom * 100)))
              color: hud.ink
              font: zoomWidest.font

              TextMetrics {
                id: zoomWidest
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                text: hud.tr("hud.percent").arg(Commons.I18n.formatNumber(800))
              }

              // The readout is the reset: back to 100% in the current mode.
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: hud.service.setMode(hud.monitorName, hud.framing.mode)
              }
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "+"
              bordered: true
              foreground: hud.ink
              tooltipText: hud.tr("tip.zoomIn")
              onClicked: hud.service.zoomBy(hud.monitorName, 1.1)
            }
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: hud.tr("hud.rotate")
            bordered: true
            foreground: hud.ink
            tooltipText: hud.tr("tip.rotate")
            onClicked: hud.service.rotate(hud.monitorName, 90)
            onRightClicked: hud.service.rotate(hud.monitorName, -90)
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: hud.tr("hud.everyWallpaper")
            bordered: true
            foreground: hud.ink
            selected: !!hud.service && hud.service.isMonitorDefault(hud.monitorName)
            tooltipText: hud.tr("tip.everyWallpaper")
            onClicked: hud.service.toggleMonitorDefault(hud.monitorName)
          }

          Button {
            anchors.verticalCenter: parent.verticalCenter
            text: hud.tr("hud.reset")
            bordered: true
            foreground: hud.ink
            tooltipText: hud.tr("tip.reset")
            onClicked: hud.service.resetFraming(hud.monitorName)
          }
        }

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: 1
          height: Math.round(Style.spacing.controlHeight * 0.7)
          color: Util.alpha(hud.ink, 0.18)
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          text: hud.ownImage ? hud.tr("hud.followWallpaper") : hud.tr("hud.otherImage")
          bordered: true
          foreground: hud.ink
          tooltipText: hud.ownImage ? hud.tr("tip.followWallpaper") : hud.tr("tip.otherImage")
          onClicked: {
            if (hud.ownImage) hud.service.setImage(hud.monitorName, "")
            else hud.service.pickImage(hud.monitorName)
          }
          // Swapping one image for another does not need a trip through
          // "Follow wallpaper" first.
          onRightClicked: hud.service.pickImage(hud.monitorName)
        }
      }

      Row {
        id: actions
        Layout.alignment: Qt.AlignRight
        spacing: Style.spacing.md

        Button {
          text: hud.tr("hud.cancel")
          bordered: true
          foreground: hud.ink
          tooltipText: "Esc"
          onClicked: hud.service.closeFraming(false)
        }

        Button {
          text: hud.tr("hud.save")
          bordered: true
          selected: true
          foreground: hud.ink
          tooltipText: "Enter"
          onClicked: hud.service.closeFraming(true)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: hud.active
      text: hud.tr("hud.hint")
      color: hud.faint
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
  }
}
