import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The offer that follows a pick from the native wallpaper picker. It sits
// where the OSD does and is built like it, takes no keyboard focus, and
// leaves by itself.
Item {
  id: prompt

  property var service: null
  readonly property bool opened: !!service && service.promptOpen
  readonly property int pad: Style.space(14)
  readonly property int gap: Style.space(14)
  readonly property int seconds: service ? service.settings.askSeconds : 6
  // What is left of the time the offer stays up, 1 down to 0.
  property real remaining: 1

  function accept() {
    if (service) service.acceptPrompt()
  }

  function dismiss() {
    if (service) service.promptOpen = false
  }

  function restart() {
    remaining = 1
    countdown.restart()
  }

  onOpenedChanged: {
    if (opened) restart()
    else countdown.stop()
  }
  Component.onCompleted: if (opened) restart()

  Connections {
    target: prompt.service
    function onPromptSerialChanged() {
      if (prompt.opened) prompt.restart()
    }
  }

  // Runs for real time whatever the motion setting: it is the timeout, and
  // only the hairline that shows it is decoration.
  NumberAnimation {
    id: countdown
    target: prompt
    property: "remaining"
    from: 1
    to: 0
    duration: prompt.seconds * 1000
    onFinished: prompt.dismiss()
  }

  OverlayWindow {
    id: panel
    shown: prompt.opened || card.shownAmount > 0.01
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "omarchy-osd"
    // Only the card takes the pointer; the rest of the screen stays the
    // desktop's.
    mask: Region { item: prompt.opened ? card : null }

    BorderSurface {
      id: card

      property real shownAmount: prompt.opened && panel.contentRevealed ? 1 : 0
      Behavior on shownAmount {
        id: showing
        NumberAnimation {
          duration: Style.duration(showing.targetValue > 0 ? 180 : 120)
          easing.type: Easing.Bezier
          easing.bezierCurve: Style.easeOut
        }
      }

      width: card.borderLeft + prompt.pad + row.implicitWidth + prompt.pad + card.borderRight
      height: card.borderTop + prompt.pad + row.implicitHeight + prompt.pad + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: shownAmount
      scale: 0.97 + 0.03 * shownAmount
      transformOrigin: Item.Bottom
      transform: Translate { y: (1 - card.shownAmount) * Style.space(8) }

      HoverHandler {
        id: hover
        onHoveredChanged: if (countdown.running) countdown.paused = hovered
      }

      // The whole card accepts, so the target is as large as the offer.
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) prompt.dismiss()
          else prompt.accept()
        }
      }

      Row {
        id: row
        x: card.borderLeft + prompt.pad
        y: card.borderTop + prompt.pad
        spacing: prompt.gap

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          // The glyph the Omarchy menu gives its Background row.
          text: ""
          font.family: Style.font.family
          font.pixelSize: Style.font.iconLarge
          color: Commons.Color.popups.text
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: prompt.service ? prompt.service.strings.tn("prompt.message", Quickshell.screens.length) : ""
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          color: Commons.Color.popups.text
        }

        Button {
          anchors.verticalCenter: parent.verticalCenter
          text: prompt.service ? prompt.service.strings.t("prompt.adjust") : ""
          bordered: true
          foreground: Commons.Color.popups.text
          onClicked: prompt.accept()
          onRightClicked: prompt.dismiss()
        }
      }

      Rectangle {
        visible: !Style.reduceMotion
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: card.borderLeft
        anchors.bottomMargin: card.borderBottom
        width: (card.width - card.borderLeft - card.borderRight) * prompt.remaining
        height: Math.max(1, Style.space(2))
        color: Commons.Color.notifications.countdown
        opacity: 0.85
      }
    }
  }
}
