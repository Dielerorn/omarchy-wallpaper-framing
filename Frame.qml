import QtQuick
import QtQuick.Effects
import qs.Commons
import "Model.js" as Model

// One wallpaper drawn with a framing: where the image sits on the screen and
// how large. The image is decoded at about the size it is drawn, never at the
// file's own size first, and moving it only moves the item, so a drag never
// decodes anything.
Item {
  id: frame

  property string path: ""
  // Cache-bust for a file replaced behind an unchanged path.
  property int version: 0
  // { width, height } of the file, read from its header by the service.
  // Undefined until then, and the image waits for it.
  property var nativeSize
  property var framing: Model.defaultFraming()
  property real pixelRatio: 1
  property bool cached: true
  // Ease geometry changes (a mode switch, a wheel notch) instead of jumping.
  // Off while the pointer drags the image, which must track 1:1.
  property bool animated: false
  property bool fadeIn: false
  property string backdrop: "blur"
  property color backdropColor: "black"
  // The most pixels this frame may decode; 0 means no limit beyond the file.
  property real maxPixels: 0

  readonly property bool known: nativeSize !== undefined && nativeSize !== null
  // An unreadable header is recorded as 0x0. Such a file is drawn as a plain
  // centered fill, the way the stock background would.
  readonly property bool measured: known && nativeSize.width > 0 && nativeSize.height > 0
  readonly property bool sized: width > 0 && height > 0
  readonly property var geometry: measured && sized
    ? Model.layout(nativeSize.width, nativeSize.height, width, height, framing, pixelRatio) : null
  readonly property bool covers: !geometry || geometry.covers
  readonly property string url: path !== "" ? Util.fileUrl(path) + (version ? "?v=" + version : "") : ""
  readonly property bool ready: image.status === Image.Ready && loadedUrl === url && url !== ""
  readonly property bool failed: image.status === Image.Error

  // The size to decode at for the geometry as it stands.
  readonly property size wanted: {
    if (!sized || !known || path === "") return Qt.size(0, 0)
    if (!geometry) return Qt.size(Math.ceil(width * pixelRatio), Math.ceil(height * pixelRatio))
    var d = Model.decodeSize(nativeSize.width, nativeSize.height, geometry, pixelRatio, maxPixels)
    return Qt.size(d.width, d.height)
  }
  // While the image is being zoomed by hand a new decode waits until the
  // zoom has settled, and the old bitmap stays up while the sharper one loads.
  property bool settleDecode: false
  // The size the image is decoded at, and the file that size was worked out
  // for. They are taken together, once the properties that set them have all
  // changed: a wallpaper change moves the path, the framing and the version
  // one after another, and the image must load once, not once for each.
  property size decode: Qt.size(0, 0)
  property string decodeUrl: ""
  property string loadedUrl: ""

  function applyDecode() {
    settle.stop()
    decodeUrl = url
    decode = wanted
  }

  function scheduleDecode() {
    if (settleDecode && decodeUrl === url && decode.width > 0 && wanted.width > 0) settle.restart()
    else Qt.callLater(frame.applyDecode)
  }

  function noteLoaded() {
    if (image.status === Image.Ready && String(image.source) !== "") loadedUrl = decodeUrl
  }

  onWantedChanged: scheduleDecode()
  onUrlChanged: scheduleDecode()
  Component.onCompleted: scheduleDecode()

  Timer {
    id: settle
    interval: 180
    onTriggered: frame.applyDecode()
  }

  clip: true

  Rectangle {
    anchors.fill: parent
    visible: !frame.covers
    color: frame.backdropColor
  }

  // Behind an image that leaves bars: the same picture, blurred and dimmed.
  // It is rendered at an eighth of the screen and scaled up, so it costs a
  // few hundred kilobytes rather than a second screen-sized texture.
  Loader {
    active: !frame.covers && frame.backdrop === "blur" && frame.url !== ""
    sourceComponent: Item {
      id: blurred
      readonly property int reduce: 8
      width: Math.max(1, Math.ceil(frame.width / reduce))
      height: Math.max(1, Math.ceil(frame.height / reduce))
      transform: Scale {
        xScale: frame.width / blurred.width
        yScale: frame.height / blurred.height
      }

      Image {
        id: wash
        anchors.fill: parent
        source: frame.url
        sourceSize: Qt.size(blurred.width, blurred.height)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: frame.cached
        smooth: true
        visible: false
      }

      MultiEffect {
        anchors.fill: parent
        source: wash
        visible: wash.status === Image.Ready
        blurEnabled: true
        blur: 1
        blurMax: 48
        brightness: -0.28
        saturation: -0.15
      }
    }
  }

  Image {
    id: image

    readonly property var g: frame.geometry

    // The item keeps the file's orientation and turns about its center, so
    // it is placed by the center of the rectangle the layout drew.
    width: g ? (g.rotated ? g.height : g.width) : frame.width
    height: g ? (g.rotated ? g.width : g.height) : frame.height
    x: g ? g.x + (g.width - width) / 2 : 0
    y: g ? g.y + (g.height - height) / 2 : 0
    rotation: g ? g.rotation : 0

    source: frame.decode.width > 0 && frame.decodeUrl === frame.url ? frame.url : ""
    sourceSize.width: frame.decode.width
    sourceSize.height: frame.decode.height
    fillMode: g ? Image.Stretch : Image.PreserveAspectCrop
    asynchronous: true
    cache: frame.cached
    smooth: true
    retainWhileLoading: true
    // A bitmap kept from the previous file would be drawn with this file's
    // geometry, so it stays hidden until the new one has loaded.
    visible: frame.loadedUrl === frame.url && frame.url !== ""
    opacity: !frame.fadeIn || visible ? 1 : 0

    // A file already in the image cache can go from ready to ready without a
    // status change, so the source is checked again once it has been applied.
    onStatusChanged: frame.noteLoaded()
    onSourceChanged: Qt.callLater(frame.noteLoaded)

    Behavior on opacity {
      enabled: frame.fadeIn
      NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
    }
    Behavior on x { enabled: frame.animated; NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on y { enabled: frame.animated; NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on width { enabled: frame.animated; NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on height { enabled: frame.animated; NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on rotation {
      enabled: frame.animated
      RotationAnimation { duration: Style.duration(180); direction: RotationAnimation.Shortest; easing.type: Easing.OutCubic }
    }
  }
}
