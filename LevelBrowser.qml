import QtQuick
import QtQuick.Controls
import qs.Commons

// The level browser: every subject on one level, grouped Radicals / Kanji /
// Vocabulary like the website, each group headed with an "(n/m unlocked)"
// count and a green progress bar for how many are passed. Locked items show
// hollow with a dashed border.
//
// A search field up top (/ or click to focus) filters subjects from EVERY
// level by name -- clear it to return to the per-level view.
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
  // search mode is driven by the field, not the service, so the view flips the
  // instant you type (results catch up a beat later)
  readonly property string searchText: searchField.text.trim()
  readonly property bool searching: searchText !== ""
  readonly property bool searchStale: searching && (!service
    || service.searchQuery !== searchText || service.searchBusy)
  readonly property var rows: searching
    ? (service ? (service.searchResults || []) : [])
    : (ready ? (service.browseData.subjects || []) : [])
  readonly property var prog: ready ? (service.browseData.progress || ({})) : ({})
  readonly property bool loading: service
    ? (searching ? service.searchBusy : service.browseBusy) : false

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

  // debounce keystrokes in the search field before hitting the helper
  Timer {
    id: searchDebounce
    interval: 220
    onTriggered: if (browser.service) browser.service.search(searchField.text)
  }
  // the host cleared the search (e.g. a fresh entry to Level Progress) -> wipe
  // the field to match
  Connections {
    target: browser.service
    function onSearchQueryChanged() {
      if (browser.service.searchQuery === "" && browser.service.searchWanted === ""
          && searchField.text !== "")
        searchField.text = ""
    }
  }
  function clearSearch() {
    searchDebounce.stop()
    searchField.text = ""
    if (service) service.clearSearch()
    cursor = 0
    flick.contentY = 0
    _toGrid()
  }
  // hand focus from the search field back to the grid -- a FocusScope keeps
  // delegating to a child that still has foc:true, so drop it explicitly
  function _toGrid() {
    searchField.focus = false
    Qt.callLater(function () { keyScope.forceActiveFocus() })
  }

  function stepLevel(d) {
    var n = level + d
    if (n >= 1 && n <= 60) browser.changeLevel(n)
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = Math.max(0, Math.min(rows.length - 1, cursor + delta))
    if (next === cursor) {
      // couldn't move -- going up past the first row: first scroll the
      // section headings in, then hand off to the level bar (not in search
      // mode, where there's no level bar)
      if (delta < 0) {
        if (flick.contentY > 1) flick.contentY = 0
        else if (!browser.searching) onLevelBar = true
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

  // the grid reflows as chips resolve after the rows land, and a plain
  // contentY=0 gets undone by that pass (the "Radicals (n/m)" heading ends up
  // scrolled under the level bar) -- so pin it to 0 for a few frames
  function scrollTop() { flick.contentY = 0; topPin.restart() }
  Timer {
    id: topPin
    interval: 16
    repeat: true
    property int ticks: 0
    onTriggered: {
      flick.contentY = 0
      ticks += 1
      if (ticks >= 14 || !browser.visible || browser.cursor !== 0) { stop(); ticks = 0 }
    }
  }
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
      // / jumps to the search field from anywhere in the grid
      if (e.key === Qt.Key_Slash) { searchField.forceActiveFocus(); e.accepted = true; return }
      // Esc clears an active search and stays on the grid
      if (e.key === Qt.Key_Escape && browser.searching) {
        browser.clearSearch(); e.accepted = true; return
      }

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

    // ---- search field (fixed at the top) ----
    Rectangle {
      id: searchRow
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.topMargin: Style.space(20)
      anchors.leftMargin: Style.space(24)
      anchors.rightMargin: Style.space(24)
      height: Style.space(38)
      radius: Style.space(6)
      color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b,
        searchField.activeFocus ? 0.12 : 0.05)
      border.width: 1
      border.color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b,
        searchField.activeFocus ? 0.5 : 0.16)

      TextField {
        id: searchField
        anchors.left: parent.left
        anchors.right: hintText.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(8)
        background: null
        leftPadding: 0
        rightPadding: 0
        color: browser.ink
        placeholderText: "Search radicals, kanji, vocabulary — every level"
        placeholderTextColor: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.38)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.bodySmall
        selectByMouse: true
        onTextChanged: searchDebounce.restart()
        Keys.onPressed: function (e) {
          if (e.key === Qt.Key_Escape) { browser.clearSearch(); e.accepted = true }
          else if (e.key === Qt.Key_Down || e.key === Qt.Key_Return
                   || e.key === Qt.Key_Enter) {
            browser._toGrid(); e.accepted = true
          }
        }
      }

      Text {
        id: hintText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: searchField.text !== "" ? "✕"
          : searchField.activeFocus ? "" : "press  /"
        color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b,
          searchField.text !== "" ? 0.6 : 0.32)
        font.family: browser.fontFamily
        font.pixelSize: searchField.text !== "" ? Style.font.bodySmall : Style.font.caption
        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(6)
          enabled: searchField.text !== ""
          cursorShape: Qt.PointingHandCursor
          onClicked: browser.clearSearch()
        }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.IBeamCursor
        onClicked: searchField.forceActiveFocus()
        // let the hint's clear button win
        propagateComposedEvents: true
      }
    }

    // ---- level bar (below the search field) ----
    Rectangle {
      id: levelBar
      visible: !browser.searching
      anchors.top: searchRow.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(24)
      anchors.topMargin: Style.space(10)
      anchors.bottomMargin: 0
      height: browser.searching ? 0 : levelRow.implicitHeight + Style.space(12)
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

        // ---- search results: one flat grid, sorted radical -> kanji -> vocab
        // then by level, each chip tagged with its level ----
        Column {
          width: sections.width
          visible: browser.searching
          spacing: Style.space(12)

          Text {
            text: (browser.searchStale && browser.rows.length === 0)
              ? "Searching…"
              : browser.rows.length + (browser.rows.length === 100 ? "+ " : " ")
                + (browser.rows.length === 1 ? "result" : "results")
                + " for “" + (browser.service ? browser.service.searchQuery : "")
                + "”"
            color: browser.ink
            font.family: browser.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Grid {
            id: resultGrid
            width: parent.width
            columns: browser.columns
            columnSpacing: Style.space(8)
            rowSpacing: Style.space(12)

            Repeater {
              model: browser.searching ? browser.rows : []
              delegate: Column {
                id: rcell
                width: (resultGrid.width - (browser.columns - 1) * Style.space(8))
                  / browser.columns
                spacing: Style.space(3)

                SubjectChip {
                  id: rchip
                  width: parent.width
                  subjectId: modelData.id
                  object: modelData.object
                  characters: modelData.characters || ""
                  meaning: modelData.meaning || ""
                  locked: modelData.unlocked === false
                  cursored: browser.cursor === index && browser.visible
                  fontFamily: browser.fontFamily
                  jpFamily: browser.jpFamily
                  fg: browser.ink
                  radicalColor: browser.radicalColor
                  kanjiColor: browser.kanjiColor
                  vocabColor: browser.vocabColor
                  onActivated: { browser.cursor = index; browser.openSubject(modelData.id) }
                  onCursoredChanged: if (cursored)
                    Qt.callLater(function () { browser.ensureVisible(rcell) })
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Level " + (modelData.level || "?")
                  color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.4)
                  font.family: browser.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            visible: !browser.searchStale && browser.rows.length === 0
            text: "No matches. Try a meaning, a reading, or the characters."
            color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.5)
            font.family: browser.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Repeater {
          model: browser.searching ? [] : [
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
                    // don't scroll the first chip up under the section heading
                    if (chipItem.flatIndex === 0) browser.scrollTop()
                    else browser.ensureVisible(chipItem)
                  })
                }
              }
            }
          }
        }
      }
    }

    // loading / empty state -- a sibling of the Flickable so it centres in
    // the viewport, not in the (possibly zero-height) scroll content. Search
    // has its own empty / "Searching…" messaging inside the Flickable.
    Column {
      anchors.centerIn: flick
      visible: browser.rows.length === 0 && !browser.searching
      spacing: Style.space(10)
      readonly property string err: browser.service ? String(browser.service.browseError) : ""

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: browser.loading ? "Loading level " + browser.level + "…"
          : parent.err !== "" ? "Couldn't load level " + browser.level
          : "Nothing on level " + browser.level + " yet."
        color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.6)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !browser.loading && parent.err !== ""
        text: parent.err + "\n[  ]  try another level"
        horizontalAlignment: Text.AlignHCenter
        color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.4)
        font.family: browser.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
