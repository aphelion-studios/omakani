import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// The full OmaWaniKani app: subject browser, lessons and reviews done in-shell.
// A `panel`-kind plugin, mounted by the shell and summoned with
//   omarchy-shell -q shell toggle io.github.aphelion-studios.omawanikani
// It reads the shared Service the bar widget also uses.
//
// Host contract (same as the Spotify full player): the shell sets `opened`
// through open()/close(); the window closing itself routes back through
// requestClose() -> shell.hide().
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""

  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.aphelion-studios.omawanikani"

  readonly property color bg: Color.background
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: Style.font.family
  readonly property string jpFamily: "Noto Sans CJK JP"

  function open(payloadJson) {
    closingFromHost = false
    opened = true
    Qt.callLater(function () { focusScope.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    opened = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "OmaWaniKani"
    color: root.bg
    implicitWidth: 1120
    implicitHeight: 780
    minimumSize: Qt.size(720, 560)

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    Rectangle {
      anchors.fill: parent
      color: root.bg
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.requestClose()

      // ---- placeholder home screen (fleshed out in the next commits) ----

      Column {
        anchors.centerIn: parent
        spacing: Style.space(16)
        width: Math.min(parent.width - Style.space(80), Style.space(520))

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "OmaWaniKani"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          font.bold: true
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          text: {
            if (!root.service) return "Connecting to the service…"
            if (!root.service.configured) return "Add your API token from the bar widget first."
            var s = root.service
            return s.username + "  ·  Level " + s.level + "\n"
              + s.reviewsNow + " reviews  ·  " + s.lessonsNow + " lessons ready\n\n"
              + "The subject browser, lessons and reviews land here next."
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Esc to close"
          color: Qt.darker(root.fg, 1.8)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
