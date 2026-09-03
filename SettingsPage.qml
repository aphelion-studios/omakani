import QtQuick
import qs.Commons
import "Model.js" as Model

// The floating app's Settings screen -- the same schema (Model.SETTINGS) the
// dashboard drop-down renders, laid out with room for the descriptions.
// j / k move the row ring, h / l (or Enter on a toggle / enum) change the
// value, Esc closes.
FocusScope {
  id: page

  property var service: null
  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  readonly property color accent: Color.accent

  signal closeRequested()

  readonly property var rows: Model.SETTINGS
  property int cursor: 0

  function value(row) {
    var v = service ? service.setting(row.key, row.fallback) : row.fallback
    if (row.kind === "bool") return v === true || v === "true" || v === 1
    if (row.kind === "enum") return String(v)
    var n = parseInt(String(v), 10)
    return isFinite(n) ? n : row.fallback
  }
  function change(row, dir) {
    if (!service) return
    if (row.kind === "bool") service.setSetting(row.key, !value(row))
    else if (row.kind === "enum")
      service.setSetting(row.key, Model.cycleEnum(row, value(row), dir || 1))
    else {
      var step = row.step || 1
      var n = Math.max(row.from, Math.min(row.to, value(row) + (dir || 1) * step))
      service.setSetting(row.key, n)
    }
  }
  function focusPage() { keyScope.forceActiveFocus() }

  FocusScope {
    id: keyScope
    anchors.fill: parent
    focus: true
    Keys.enabled: page.visible
    Keys.onPressed: function (e) {
      var r = page.rows[page.cursor]
      if (e.text === "?") { keyHints.toggle(); e.accepted = true }
      else if (e.key === Qt.Key_Escape && keyHints.open) { keyHints.close(); e.accepted = true }
      else if (e.key === Qt.Key_Escape) { page.closeRequested(); e.accepted = true }
      else if (e.text === "s" && !keyHints.open) { page.closeRequested(); e.accepted = true }
      else if (e.text === "j" || e.key === Qt.Key_Down) {
        page.cursor = Math.min(page.rows.length - 1, page.cursor + 1)
        Qt.callLater(ensureVisible); e.accepted = true
      }
      else if (e.text === "k" || e.key === Qt.Key_Up) {
        page.cursor = Math.max(0, page.cursor - 1)
        Qt.callLater(ensureVisible); e.accepted = true
      }
      else if (e.text === "l" || e.key === Qt.Key_Right) { page.change(r, 1); e.accepted = true }
      else if (e.text === "h" || e.key === Qt.Key_Left) { page.change(r, -1); e.accepted = true }
      else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) {
        page.change(r, 1); e.accepted = true
      }
    }
    function ensureVisible() {
      if (page.cursor === 0) { flick.contentY = 0; return }   // show the header
      var it = rowRepeater.itemAt(page.cursor)
      if (!it) return
      var top = it.mapToItem(col, 0, 0).y
      var bot = top + it.height
      var pad = Style.space(24)
      if (top - pad < flick.contentY) flick.contentY = Math.max(0, top - pad)
      else if (bot + pad > flick.contentY + flick.height)
        flick.contentY = bot + pad - flick.height
    }

    Rectangle { anchors.fill: parent; color: page.pageBg }

    Flickable {
      id: flick
      anchors.fill: parent
      anchors.leftMargin: Style.space(40)
      anchors.rightMargin: Style.space(40)
      anchors.topMargin: Style.space(24)
      anchors.bottomMargin: Style.space(24)
      contentWidth: width
      contentHeight: col.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: Math.min(flick.width, Style.space(560))
        x: Math.max(0, (flick.width - width) / 2)
        spacing: Style.space(4)

        Text {
          text: "Settings"
          color: page.fg
          font.family: page.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
          bottomPadding: Style.space(12)
        }

        Repeater {
          id: rowRepeater
          model: page.rows
          delegate: Column {
            width: col.width
            spacing: Style.space(3)
            readonly property bool firstOfGroup: index === 0
              || page.rows[index - 1].group !== modelData.group

            Text {
              visible: parent.firstOfGroup
              text: String(modelData.group || "").toUpperCase()
              color: Qt.darker(page.fg, 1.7)
              font.family: page.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.5
              topPadding: index === 0 ? 0 : Style.space(22)
              bottomPadding: Style.space(6)
            }

            Rectangle {
              width: parent.width
              implicitHeight: rowCol.implicitHeight + Style.space(20)
              radius: Style.space(6)
              color: page.cursor === index
                ? Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.08)
                : Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.03)
              border.width: page.cursor === index ? 1 : 0
              border.color: Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.25)

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { page.cursor = index; page.change(modelData, 1) }
              }

              Row {
                id: rowCol
                x: Style.space(14)
                y: Style.space(10)
                width: parent.width - Style.space(28)
                spacing: Style.space(14)

                Column {
                  width: parent.width - ctrl.width - parent.spacing
                  spacing: Style.space(3)
                  Text {
                    width: parent.width
                    text: modelData.label
                    color: page.fg
                    font.family: page.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    width: parent.width
                    visible: !!modelData.help
                    text: modelData.help || ""
                    color: Qt.darker(page.fg, 1.5)
                    font.family: page.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    lineHeight: 1.25
                  }
                }

                // ---- the control ----
                Item {
                  id: ctrl
                  anchors.verticalCenter: parent.verticalCenter
                  width: modelData.kind === "enum" ? Style.space(150)
                    : modelData.kind === "int" ? Style.space(96)
                    : Style.space(44)
                  height: Style.space(28)

                  // bool: a pill toggle
                  Rectangle {
                    visible: modelData.kind === "bool"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(40)
                    height: Style.space(22)
                    radius: height / 2
                    readonly property bool on: page.value(modelData) === true
                    color: on ? page.accent
                      : Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.15)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Rectangle {
                      width: Style.space(16); height: width; radius: width / 2
                      color: "#fcfdfd"
                      anchors.verticalCenter: parent.verticalCenter
                      x: parent.on ? parent.width - width - Style.space(3) : Style.space(3)
                      Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }
                  }

                  // int / enum: ‹ value ›
                  Row {
                    visible: modelData.kind === "int" || modelData.kind === "enum"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)
                    Rectangle {
                      width: Style.space(24); height: Style.space(24); radius: Style.space(4)
                      color: Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.1)
                      Text {
                        anchors.centerIn: parent; text: "‹"; color: page.fg
                        font.family: page.fontFamily; font.pixelSize: Style.font.body
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { page.cursor = index; page.change(modelData, -1) } }
                    }
                    Text {
                      width: modelData.kind === "enum" ? Style.space(94) : Style.space(40)
                      horizontalAlignment: Text.AlignHCenter
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      readonly property var v: page.value(modelData)
                      text: modelData.kind === "enum" ? Model.enumLabel(modelData, v)
                        : (v === 0 ? "Off" : String(v))
                      color: page.fg
                      font.family: page.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    Rectangle {
                      width: Style.space(24); height: Style.space(24); radius: Style.space(4)
                      color: Qt.rgba(page.fg.r, page.fg.g, page.fg.b, 0.1)
                      Text {
                        anchors.centerIn: parent; text: "›"; color: page.fg
                        font.family: page.fontFamily; font.pixelSize: Style.font.body
                      }
                      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { page.cursor = index; page.change(modelData, 1) } }
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          topPadding: Style.space(20)
          width: col.width
          text: "j / k  move   ·   h / l  change   ·   Esc  back"
          color: Qt.darker(page.fg, 1.9)
          font.family: page.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    HotkeysOverlay {
      id: keyHints
      anchors.fill: parent
      fg: page.fg
      pageBg: page.pageBg
      fontFamily: page.fontFamily
      title: "Keys"
      rows: [
        { k: "j k", d: "Move between settings" },
        { k: "h l", d: "Change the value" },
        { k: "↵", d: "Toggle / cycle" },
        { k: "s", d: "Close settings" },
        { k: "Esc", d: "Back" },
        { k: "?", d: "Toggle this menu" }
      ]
    }
  }
}
