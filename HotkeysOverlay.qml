import QtQuick
import qs.Commons

// A keyboard-glyph button pinned bottom-right that toggles a hotkeys reference
// card (like wanikani.com's). Optionally a second button to its left -- used
// on the app home for the settings gear. The host catches "?" and calls
// toggle(); every screen that wants the card just drops one of these in.
Item {
  id: ov
  anchors.fill: parent

  property var rows: []            // [{ k: "F", d: "Item Info" }, ...]
  property string title: "Hotkeys"
  property color fg: Color.foreground
  property color pageBg: Color.background
  property string fontFamily: Style.font.family
  property bool open: false

  // optional extra button (a gear, say): { glyph, tip } or null
  property var extraButton: null
  signal extraClicked()

  function toggle() { open = !open }
  function close() { open = false }

  Row {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(14)
    spacing: Style.space(8)
    z: 60

    Rectangle {
      visible: !!ov.extraButton
      width: Style.space(34); height: Style.space(30); radius: Style.space(4)
      color: exHover.containsMouse
        ? Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.18)
        : Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.08)
      border.width: 1
      border.color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.1)
      Text {
        anchors.centerIn: parent
        text: ov.extraButton ? String(ov.extraButton.glyph || "") : ""
        color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, exHover.containsMouse ? 0.9 : 0.45)
        font.family: ov.fontFamily
        font.pixelSize: Style.font.body
      }
      MouseArea {
        id: exHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ov.extraClicked()
      }
    }

    Rectangle {
      id: btn
      width: Style.space(34); height: Style.space(30); radius: Style.space(4)
      color: (hkHover.containsMouse || ov.open)
        ? Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.18)
        : Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.08)
      border.width: 1
      border.color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, ov.open ? 0.22 : 0.1)
      Text {
        anchors.centerIn: parent
        text: "󰌌"
        color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, ov.open ? 0.9 : 0.45)
        font.family: ov.fontFamily
        font.pixelSize: Style.font.body
      }
      MouseArea {
        id: hkHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: ov.toggle()
      }
    }
  }

  Rectangle {
    id: card
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: Style.space(14)
    anchors.bottomMargin: Style.space(50)
    visible: ov.open
    z: 60
    width: hkCol.implicitWidth + Style.space(28)
    height: hkCol.implicitHeight + Style.space(24)
    radius: Style.space(6)
    color: Qt.darker(ov.pageBg, 1.15)
    border.width: 1
    border.color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.16)

    Column {
      id: hkCol
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        text: ov.title
        color: Qt.darker(ov.fg, 1.5)
        font.family: ov.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        bottomPadding: Style.space(3)
      }

      Repeater {
        model: ov.rows
        delegate: Row {
          spacing: Style.space(8)
          Repeater {
            model: String(modelData.k).split(" ")
            delegate: Rectangle {
              width: Math.max(Style.space(20), kLabel.implicitWidth + Style.space(9))
              height: Style.space(18)
              radius: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
              color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.1)
              border.width: 1
              border.color: Qt.rgba(ov.fg.r, ov.fg.g, ov.fg.b, 0.16)
              Text {
                id: kLabel
                anchors.centerIn: parent
                text: modelData
                color: ov.fg
                font.family: ov.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.d
            color: Qt.darker(ov.fg, 1.2)
            font.family: ov.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
