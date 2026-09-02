import QtQuick
import qs.Commons

// The review session's answered items, dropped into the answer area by the ✓
// toolbar button (the character header, prompt bar and toolbar stay put). A
// card appears the moment a subject's first answer lands, then fills in: every
// meaning guess you typed (✓ / ✗), a divider, every reading guess, and once
// the subject is done the SRS transition it earned (green ↑ if you never
// missed, red ↓ if you did). Local only -- the engine logs each typed answer
// as it comes in; cleared when the session ends.
//
// j / k (or the arrows) scroll; Esc / ✓ / f close.
FocusScope {
  id: panel

  // [{ id, needsR, mGuesses:[{text,ok}], rGuesses:[{text,ok}],
  //    done, pass, up, stageName }], newest-touched first
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

  // the padding inside a card -- same on every edge (the user liked the gap
  // to the left of the ✓/✗; this mirrors it on the right)
  readonly property real cardPad: Style.space(11)

  signal closeRequested()
  // f jumps straight to item info (the panels swap, like the website)
  signal infoRequested()

  // one ✓/✗ line inside a card (meaning, then reading). Sizes to its content
  // so the card can measure its widest row.
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
      text: arow.label
      color: Qt.darker(panel.fg, 1.15)
      font.family: arow.jp ? panel.jpFamily : panel.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // the engine already keeps this newest-touched first
  readonly property var rows: log || []

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

  Keys.enabled: panel.visible
  Keys.onPressed: function (e) {
    var step = Style.space(90)
    if (e.key === Qt.Key_Escape) {
      panel.closeRequested(); e.accepted = true
    } else if (e.text === "f") {
      panel.infoRequested(); e.accepted = true
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

  // empty state -- nothing answered yet this session
  Text {
    anchors.centerIn: parent
    visible: panel.rows.length === 0
    horizontalAlignment: Text.AlignHCenter
    text: "No answers yet.\n\nEach item shows up here as soon as you\nanswer it, this session."
    color: Qt.darker(panel.fg, 1.6)
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Flickable {
    id: flick
    anchors.fill: parent
    anchors.topMargin: Style.space(16)
    anchors.bottomMargin: Style.space(16)
    anchors.leftMargin: Style.space(20)
    anchors.rightMargin: Style.space(20)
    visible: panel.rows.length > 0
    contentWidth: width
    contentHeight: flow.implicitHeight + Style.space(8)
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
          readonly property var mGuesses: row.mGuesses || []
          readonly property var rGuesses: row.rGuesses || []
          readonly property string chars: panel.charsOf(row.id)
          readonly property bool showChip: row.done === true
          // Extra Study never moves SRS -- the footer just names the current
          // stage, no ↑ / ↓, no pass / fail colour
          readonly property bool staticChip: row.up === null || row.up === undefined
          readonly property real pad: panel.cardPad
          // width tracks the widest thing in the card -- the header text, the
          // longest guess row, or the SRS footer -- with equal padding on both
          // sides. `measure` / `srsMeasure` (hidden) do the sizing so the
          // visible divider and footer can span the full inner width without a
          // binding loop.
          readonly property real innerW: Math.max(
            headText.implicitWidth, measure.implicitWidth,
            showChip ? srsMeasure.implicitWidth : 0)
          width: innerW + pad * 2
          // header · pad · body · pad · (footer)   -- pad matched top & bottom
          height: cardHead.height + pad + bodyCol.implicitHeight + pad
                  + (showChip ? srsFooter.height : 0)
          radius: Style.space(7)
          color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.05)
          border.width: 1
          border.color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.1)
          clip: true

          // hidden width probe: every guess row
          Column {
            id: measure
            visible: false
            Repeater {
              model: card.mGuesses
              delegate: PanelAnswerRow { ok: modelData.ok; label: modelData.text }
            }
            Repeater {
              model: card.rGuesses
              delegate: PanelAnswerRow { ok: modelData.ok; jp: true; label: modelData.text }
            }
          }

          // hidden width probe: the SRS footer's ↑ / stage-name row, so a long
          // stage ("Enlightened") gets the same left/right padding a guess row
          // would and never clips
          Row {
            id: srsMeasure
            visible: false
            spacing: Style.space(4)
            Text {
              visible: !card.staticChip
              text: "↑"
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              text: card.row.stageName || "Apprentice"
              font.family: panel.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // type-coloured header -- rounded to match the card's top corners
          Rectangle {
            id: cardHead
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(44)
            topLeftRadius: card.radius
            topRightRadius: card.radius
            color: panel.colorFor(card.row.id)
            Text {
              id: headText
              anchors.centerIn: parent
              // centre the glyph's ink, not its advance box -- lone narrow
              // radicals (刂 etc.) have lopsided side bearings
              anchors.horizontalCenterOffset: headMetrics.advanceWidth > 0
                ? (headMetrics.advanceWidth / 2 - headMetrics.tightBoundingRect.x
                   - headMetrics.tightBoundingRect.width / 2)
                : 0
              text: card.chars || panel.meaningOf(card.row.id)
              color: "#fcfdfd"
              font.family: card.chars ? panel.jpFamily : panel.fontFamily
              font.pixelSize: card.chars ? Style.font.title : Style.font.bodySmall
            }
            TextMetrics {
              id: headMetrics
              font: headText.font
              text: headText.text
            }
          }

          Column {
            id: bodyCol
            x: card.pad
            y: cardHead.height + card.pad
            spacing: Style.space(4)

            // every meaning guess, in the order they were typed
            Repeater {
              model: card.mGuesses
              delegate: PanelAnswerRow {
                ok: modelData.ok
                label: modelData.text
              }
            }

            // divider between the meaning and reading guesses -- only when
            // both halves have actually been attempted
            Item {
              width: card.innerW
              height: Style.space(9)
              visible: card.mGuesses.length > 0 && card.rGuesses.length > 0
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 1
                color: Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.25)
              }
            }

            Repeater {
              model: card.rGuesses
              delegate: PanelAnswerRow {
                ok: modelData.ok
                jp: true
                label: modelData.text
              }
            }
          }

          // SRS transition -- its own footer band once the subject is done,
          // mirroring the type-coloured header: green ↑ if you never missed
          // it, red ↓ if you did
          Rectangle {
            id: srsFooter
            visible: card.showChip
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(26)
            bottomLeftRadius: card.radius
            bottomRightRadius: card.radius
            color: card.staticChip
              ? Qt.rgba(panel.fg.r, panel.fg.g, panel.fg.b, 0.16)
              : card.row.pass ? panel.okColor : panel.noColor
            readonly property color ink: card.staticChip
              ? Qt.darker(panel.fg, 1.1) : "#fcfdfd"
            Row {
              anchors.centerIn: parent
              spacing: Style.space(4)
              Text {
                visible: !card.staticChip
                text: card.row.up ? "↑" : "↓"
                color: srsFooter.ink
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                text: card.row.stageName
                color: srsFooter.ink
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
