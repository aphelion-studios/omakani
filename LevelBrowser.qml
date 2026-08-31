import QtQuick
import qs.Commons

// The level browser: every subject on one level, grouped Radicals / Kanji /
// Vocabulary like the website, each group headed with an "(n/m unlocked)"
// count and a green progress bar for how many are passed. Locked items show
// hollow with a dashed border.
//
// Keys: h/j/k/l (or arrows) move the grid cursor; k from the top row scrolls
// the section headings in, then a further k lands on the < Level N > bar
// where h/l step levels and j drops back to the grid; [ / ] step levels from
// anywhere; Enter opens the subject; g / G jump to the ends.
Item {
  id: browser

  property var service: null
  property int level: 1
  property color fg: Color.foreground
  property color pageBg: Color.background
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"
  readonly property color passedColor: "#93c01f"
  readonly property color ink: "#fcfdfd"

  signal openSubject(int subjectId)
  signal changeLevel(int newLevel)

  readonly property bool ready: service && service.browseData
    && Number(service.browseData.level) === level
  readonly property var rows: ready ? (service.browseData.subjects || []) : []
  readonly property var prog: ready ? (service.browseData.progress || ({})) : ({})
  readonly property bool loading: service ? service.browseBusy : false

  // Flat cursor over `rows` (already ordered radical -> kanji -> vocab).
  property int cursor: 0
  // when true the < Level N > bar has the ring; h/l step levels, j returns
  property bool onLevelBar: false
  readonly property int columns: Math.max(1,
    Math.floor((flick.width - Style.space(2)) / Style.space(196)))

  function sectionRows(kind) {
    return rows.filter(function (r) {
      return kind === "vocabulary"
        ? (r.object === "vocabulary" || r.object === "kana_vocabulary")
        : r.object === kind
    })
  }
  function progOf(pkey) {
    var p = prog[pkey] || ({})
    return { passed: p.passed || 0, unlocked: p.unlocked || 0, total: p.total || 0 }
  }

  function focusGrid() { keyScope.forceActiveFocus() }
  readonly property bool hasKeyFocus: keyScope.activeFocus

  function stepLevel(d) {
    var n = level + d
    if (n >= 1 && n <= 60) browser.changeLevel(n)
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = Math.max(0, Math.min(rows.length - 1, cursor + delta))
    if (next === cursor) {
      // couldn't move -- going up past the first row: first scroll the
      // section headings in, then hand off to the level bar
      if (delta < 0) {
        if (flick.contentY > 1) flick.contentY = 0
        else onLevelBar = true
      } else {
        flick.contentY = Math.max(0, flick.contentHeight - flick.height)
      }
      return
    }
    cursor = next
  }
  function openCursor() {
    if (cursor >= 0 && cursor < rows.length) browser.openSubject(rows[cursor].id)
  }
  function ensureVisible(item) {
    if (!item) return
    var top = item.mapToItem(flick.contentItem, 0, 0).y
    var m = Style.space(20)
    if (top - m < flick.contentY)
      flick.contentY = Math.max(0, top - m)
    else if (top + item.height + m > flick.contentY + flick.height)
      flick.contentY = top + item.height + m - flick.height
  }

  function scrollTop() { flick.contentY = 0; Qt.callLater(function () { flick.contentY = 0 }) }
  onLevelChanged: { cursor = 0; scrollTop() }
  onRowsChanged: {
    if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)
    if (cursor === 0) scrollTop()   // fresh level -- show the first heading
  }
  onVisibleChanged: if (visible) { onLevelBar = false; if (cursor === 0) scrollTop() }

  FocusScope {
    id: keyScope
    anchors.fill: parent
    // a focused item still gets key events while hidden -- stop eating keys
    // when the browser isn't the visible view
    Keys.enabled: browser.visible

    Keys.onPressed: function (e) {
      if (e.text === "[") { browser.stepLevel(-1); e.accepted = true; return }
      if (e.text === "]") { browser.stepLevel(1); e.accepted = true; return }

      if (browser.onLevelBar) {
        if (e.text === "h" || e.key === Qt.Key_Left) { browser.stepLevel(-1); e.accepted = true }
        else if (e.text === "l" || e.key === Qt.Key_Right) { browser.stepLevel(1); e.accepted = true }
        else if (e.text === "j" || e.key === Qt.Key_Down || e.key === Qt.Key_Return
                 || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape) {
          browser.onLevelBar = false; e.accepted = true
        }
        return
      }

      if (e.text === "h" || e.key === Qt.Key_Left) { browser.moveCursor(-1); e.accepted = true }
      else if (e.text === "l" || e.key === Qt.Key_Right) { browser.moveCursor(1); e.accepted = true }
      else if (e.text === "j" || e.key === Qt.Key_Down) { browser.moveCursor(browser.columns); e.accepted = true }
      else if (e.text === "k" || e.key === Qt.Key_Up) { browser.moveCursor(-browser.columns); e.accepted = true }
      else if (e.text === "g") { browser.cursor = 0; flick.contentY = 0; e.accepted = true }
      else if (e.text === "G") { browser.cursor = Math.max(0, browser.rows.length - 1); e.accepted = true }
      else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { browser.openCursor(); e.accepted = true }
    }

    // ---- level bar (fixed at the top) ----
    Rectangle {
      id: levelBar
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(24)
      anchors.bottomMargin: 0
      height: levelRow.implicitHeight + Style.space(12)
      color: "transparent"
      radius: Style.space(6)
      border.width: browser.onLevelBar ? 2 : 0
      border.color: browser.ink

      Row {
        id: levelRow
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(14)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "‹"
          color: browser.level > 1 ? browser.ink : Qt.darker(browser.ink, 2)
          font.family: browser.fontFamily
          font.pixelSize: Style.font.heading
          MouseArea {
            anchors.fill: parent; anchors.margins: -Style.space(6)
            cursorShape: Qt.PointingHandCursor
            onClicked: browser.stepLevel(-1)
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Level " + browser.level
          color: browser.ink
          font.family: browser.fontFamily
          font.pixelSize: Style.font.heading
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "›"
          color: browser.level < 60 ? browser.ink : Qt.darker(browser.ink, 2)
          font.family: browser.fontFamily
          font.pixelSize: Style.font.heading
          MouseArea {
            anchors.fill: parent; anchors.margins: -Style.space(6)
            cursorShape: Qt.PointingHandCursor
            onClicked: browser.stepLevel(1)
          }
        }
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        text: browser.onLevelBar
          ? "h / l  level   ·   j  grid"
          : "h / j / k / l  navigate   ·   [ / ]  level   ·   Enter  open"
        color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.55)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ---- scrolling section list ----
    Flickable {
      id: flick
      anchors.top: levelBar.bottom
      anchors.topMargin: Style.space(14)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(24)
      anchors.rightMargin: Style.space(24)
      anchors.bottomMargin: Style.space(24)
      clip: true
      contentWidth: width
      contentHeight: sections.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: sections
        width: flick.width
        spacing: Style.space(22)

        Repeater {
          model: [
            { kind: "radical", label: "Radicals", pkey: "radicals", tint: browser.radicalColor },
            { kind: "kanji", label: "Kanji", pkey: "kanji", tint: browser.kanjiColor },
            { kind: "vocabulary", label: "Vocabulary", pkey: "vocabulary", tint: browser.vocabColor }
          ]

          delegate: Column {
            id: section
            width: sections.width
            spacing: Style.space(8)
            readonly property var srows: browser.sectionRows(modelData.kind)
            readonly property var p: browser.progOf(modelData.pkey)
            readonly property int baseIndex: {
              if (modelData.kind === "kanji")
                return browser.sectionRows("radical").length
              if (modelData.kind === "vocabulary")
                return browser.sectionRows("radical").length
                  + browser.sectionRows("kanji").length
              return 0
            }
            visible: srows.length > 0

            // section header
            Row {
              spacing: Style.space(10)
              Text {
                text: modelData.label
                color: browser.ink
                font.family: browser.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "(" + section.p.unlocked + "/" + section.p.total + " unlocked)"
                color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.7)
                font.family: browser.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // passed-progress bar
            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.12)
              Rectangle {
                height: parent.height
                radius: parent.radius
                width: parent.width * (section.p.total > 0
                  ? section.p.passed / section.p.total : 0)
                color: browser.passedColor
              }
            }

            // chip grid
            Grid {
              id: grid
              width: parent.width
              columns: browser.columns
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)

              Repeater {
                model: section.srows
                delegate: SubjectChip {
                  id: chipItem
                  width: (grid.width - (browser.columns - 1) * Style.space(8)) / browser.columns
                  readonly property int flatIndex: section.baseIndex + index
                  subjectId: modelData.id
                  object: modelData.object
                  characters: modelData.characters || ""
                  meaning: modelData.meaning || ""
                  locked: modelData.unlocked === false
                  cursored: browser.cursor === flatIndex && browser.visible && !browser.onLevelBar
                  fontFamily: browser.fontFamily
                  jpFamily: browser.jpFamily
                  fg: browser.ink
                  radicalColor: browser.radicalColor
                  kanjiColor: browser.kanjiColor
                  vocabColor: browser.vocabColor
                  onActivated: {
                    browser.cursor = flatIndex
                    browser.openSubject(modelData.id)
                  }
                  onCursoredChanged: if (cursored) Qt.callLater(function () {
                    browser.ensureVisible(chipItem)
                  })
                }
              }
            }
          }
        }
      }
    }

    // loading / empty state -- a sibling of the Flickable so it centres in
    // the viewport, not in the (possibly zero-height) scroll content
    Text {
      anchors.centerIn: flick
      visible: browser.rows.length === 0
      text: browser.loading ? "Loading level " + browser.level + "…"
        : "Nothing on level " + browser.level + " yet."
      color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.6)
      font.family: browser.fontFamily
      font.pixelSize: Style.font.body
    }
  }
}
