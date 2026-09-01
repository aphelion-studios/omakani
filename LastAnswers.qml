import QtQuick
import qs.Commons

// The review session's completed items, opened with the ✓ toolbar button --
// one card per finished subject, newest first, with a ✓ / ✗ per tested half
// and the SRS transition it earned. Approximate by design: the engine tracks
// per-half miss counts and the resulting stage, not every typed attempt, so a
// half is simply right (never missed) or wrong (missed at least once).
//
// j / k (or the arrows) scroll; Esc / ✓ / f close.
FocusScope {
  id: panel

  // [{ id, mWrong, rWrong, needsR, stageName, up, pass }], oldest first
  property var log: []
  property var service: null

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"
  readonly property color okColor: "#93c01f"
  readonly property color noColor: "#fc0234"

  signal closeRequested()

  // one ✓/✗ line inside a card (meaning, then reading)
  component PanelAnswerRow: Row {
    id: arow
    property bool ok: true
    property string label: ""
    property bool jp: false
    spacing: Style.space(6)
    Text {
      text: arow.ok ? "✓" : "✗"
      color: arow.ok ? panel.okColor : panel.noColor
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    Text {
      width: arow.width - Style.space(22)
      elide: Text.ElideRight
      text: arow.label
      color: Qt.darker(panel.fg, 1.15)
      font.family: arow.jp ? panel.jpFamily : panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // newest completion first, so the item you just cleared is top-left
  readonly property var rows: (log || []).slice().reverse()

  function kindOf(id) {
    var s = panel.service && panel.service.subjectDetail(id)
    return s ? String(s.object || "") : ""
  }
  function colorFor(id) {
    var k = kindOf(id)
    return k === "radical" ? radicalColor
      : k === "kanji" ? kanjiColor : vocabColor
  }
  function charsOf(id) {
    var s = panel.service && panel.service.subjectDetail(id)
    return s && s.data ? String(s.data.characters || "") : ""
  }
  function meaningOf(id) {
    var s = panel.service && panel.service.subjectDetail(id)
    var ms = (s && s.data && s.data.meanings) || []
    for (var i = 0; i < ms.length; i++) if (ms[i].primary) return ms[i].meaning
    return ms.length ? ms[0].meaning : ""
  }
  function readingOf(id) {
    var s = panel.service && panel.service.subjectDetail(id)
    var rs = ((s && s.data && s.data.readings) || [])
      .filter(function (r) { return r.accepted_answer !== false })
    for (var i = 0; i < rs.length; i++) if (rs[i].primary) return rs[i].reading
    return rs.length ? rs[0].reading : ""
  }

  Keys.enabled: panel.visible
  Keys.onPressed: function (e) {
    var step = Style.space(120)
    if (e.key === Qt.Key_Escape || e.text === "f") {
      panel.closeRequested(); e.accepted = true
    } else if (e.key === Qt.Key_Down || e.text === "j") {
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + step)
      e.accepted = true
    } else if (e.key === Qt.Key_Up || e.text === "k") {
      flick.contentY = Math.max(0, flick.contentY - step); e.accepted = true
    } else if (e.key === Qt.Key_PageDown || e.key === Qt.Key_Space) {
      flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + flick.height * 0.9)
      e.accepted = true
    } else if (e.key === Qt.Key_PageUp) {
      flick.contentY = Math.max(0, flick.contentY - flick.height * 0.9); e.accepted = true
    } else {
      e.accepted = true
    }
  }
  onVisibleChanged: if (visible) { flick.contentY = 0; Qt.callLater(forceActiveFocus) }

  Rectangle { anchors.fill: parent; color: panel.pageBg }

  Text {
    id: titleText
    anchors.top: parent.top
    anchors.topMargin: Style.space(24)
    anchors.horizontalCenter: parent.horizontalCenter
    text: "Last Answers"
    color: panel.fg
    font.family: panel.fontFamily
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  // empty state -- nothing submitted yet this session
  Text {
    anchors.centerIn: parent
    visible: panel.rows.length === 0
    text: "No items finished yet."
    color: Qt.darker(panel.fg, 1.6)
    font.family: panel.fontFamily
    font.pixelSize: Style.font.body
  }

  Flickable {
    id: flick
    anchors.top: titleText.bottom
    anchors.topMargin: Style.space(18)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(92)
    anchors.leftMargin: Style.space(24)
    anchors.rightMargin: Style.space(24)
    visible: panel.rows.length > 0
    contentWidth: width
    contentHeight: flow.implicitHeight + Style.space(24)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Flow {
      id: flow
      width: parent.width
      spacing: Style.space(10)

      Repeater {
        model: panel.rows
        delegate: Rectangle {
          id: card
          readonly property var row: modelData
          readonly property bool mRight: !(row.mWrong > 0)
          readonly property bool rRight: !(row.rWrong > 0)
          readonly property string chars: panel.charsOf(row.id)
          width: Style.space(150)
          height: bodyCol.y + bodyCol.implicitHeight + Style.space(12)
          radius: Style.space(6)
          color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.05)
          border.width: 1
          border.color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.1)
          clip: true

          // type-coloured header with the characters
          Rectangle {
            id: cardHead
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(46)
            color: panel.colorFor(card.row.id)
            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: card.chars || panel.meaningOf(card.row.id)
              color: "#fcfdfd"
              font.family: card.chars ? panel.jpFamily : panel.fontFamily
              font.pixelSize: card.chars ? Style.font.title : Style.font.bodySmall
            }
          }

          Column {
            id: bodyCol
            y: cardHead.height + Style.space(10)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(4)

            PanelAnswerRow {
              width: bodyCol.width
              ok: card.mRight
              label: panel.meaningOf(card.row.id)
            }
            PanelAnswerRow {
              width: bodyCol.width
              visible: card.row.needsR
              ok: card.rRight
              jp: true
              label: panel.readingOf(card.row.id)
            }

            // SRS transition
            Rectangle {
              width: srsRow.implicitWidth + Style.space(14)
              height: Style.space(22)
              radius: Style.space(4)
              color: card.row.pass ? panel.okColor : panel.noColor
              Row {
                id: srsRow
                anchors.centerIn: parent
                spacing: Style.space(4)
                Text {
                  text: card.row.up ? "↑" : "↓"
                  color: "#fcfdfd"
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  text: card.row.stageName
                  color: "#fcfdfd"
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }
        }
      }
    }
  }

  Text {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(58)
    anchors.horizontalCenter: parent.horizontalCenter
    visible: panel.rows.length > 0
    text: "j / k  scroll   ·   Esc  close"
    color: Qt.darker(panel.fg, 1.9)
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
  }
}
