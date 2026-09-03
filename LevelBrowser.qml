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
//
// Each chip carries a thin SRS strip; on your current level a band above the
// grid lists the kanji still blocking the level-up gate.
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
  // the host (dashboard "Radicals 19/20" etc.) can ask us to land on a
  // section's first chip; applied once that level's rows arrive, then cleared
  property string pendingSection: ""
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
  // kanji on this level not yet Guru'd -- the items blocking the level-up gate
  readonly property var blockingKanji: (ready && !searching)
    ? rows.filter(function (r) { return r.object === "kanji" && r.passed !== true })
    : []
  function progOf(pkey) {
    var p = prog[pkey] || ({})
    return { passed: p.passed || 0, unlocked: p.unlocked || 0, total: p.total || 0 }
  }
  // flat index of the first chip in a section
  function firstIndexOf(kind) {
    if (kind === "kanji") return sectionRows("radical").length
    if (kind === "vocabulary" || kind === "vocab")
      return sectionRows("radical").length + sectionRows("kanji").length
    return 0   // radical
  }
  // section Column items, keyed by kind -- so a pending-section request can
  // scroll that heading into view
  property var _sections: ({})
  // true while we're driving the view to a pending section: suppresses the
  // grid's own auto-scrolls (topPin, the first-chip scroll-to-top) so they
  // don't fight sectionPin
  property bool _seeking: false

  // a fresh entry into Level Progress -- top of the level, nothing ringed.
  // A pending-section request (from the dashboard's "Kanji 31/37" etc.) drives
  // the view instead, so don't reset when one is queued.
  function enterFresh() {
    onLevelBar = false
    // a pending-section request drives the view -- and it may have been
    // consumed synchronously already (cached level), so also bail while a
    // seek is still settling
    if (pendingSection !== "" || _seeking) return
    cursor = 0
    scrollTop()
  }
  function _applyPendingSection() {
    if (pendingSection === "" || rows.length === 0) return
    var kind = pendingSection === "vocab" ? "vocabulary" : pendingSection
    // the section must actually be in `rows` before we can land on it -- rows
    // arrives whole, but a stale level's rows can be showing for a frame. Keep
    // pendingSection queued and retry on the next rows / ready change.
    var srows = sectionRows(kind)
    if (srows.length === 0) return
    var idx = firstIndexOf(kind)
    if (idx >= rows.length) return
    pendingSection = ""
    onLevelBar = false
    cursor = idx
    if (idx === 0) { _seeking = false; scrollTop(); return }
    // pin the section heading near the top for a few frames -- the grid
    // reflows as chips resolve and a one-shot scroll gets undone
    sectionPin.kind = kind
    sectionPin.ticks = 0
    sectionPin.restart()
  }
  // give up on an unresolvable pending section so _seeking can't wedge the view
  Timer {
    id: seekWatchdog
    interval: 2500
    onTriggered: if (browser.pendingSection !== "" || browser._seeking) {
      browser.pendingSection = ""
      browser._seeking = false
    }
  }
  Timer {
    id: sectionPin
    interval: 16
    repeat: true
    property string kind: ""
    property int ticks: 0
    onTriggered: {
      ticks += 1
      var t = browser._sections[kind]
      if (t) {
        var y = t.mapToItem(flick.contentItem, 0, 0).y
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        flick.contentY = Math.max(0, Math.min(maxY, y - Style.space(4)))
      }
      if (ticks >= 20 || !browser.visible) {
        stop(); ticks = 0; kind = ""; browser._seeking = false
      }
    }
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
  function scrollTop() {
    if (_seeking) return   // a pending section owns the scroll right now
    flick.contentY = 0
    topPin.restart()
  }
  Timer {
    id: topPin
    interval: 16
    repeat: true
    property int ticks: 0
    onTriggered: {
      if (browser._seeking) { stop(); ticks = 0; return }
      flick.contentY = 0
      ticks += 1
      if (ticks >= 14 || !browser.visible || browser.cursor !== 0) { stop(); ticks = 0 }
    }
  }
  onLevelChanged: { if (!_seeking) cursor = 0; if (pendingSection === "" && !_seeking) scrollTop() }
  onRowsChanged: {
    if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)
    _applyPendingSection()
    if (cursor === 0 && pendingSection === "") scrollTop()   // show first heading
  }
  onVisibleChanged: if (visible) {
    onLevelBar = false
    Qt.callLater(_applyPendingSection)
    if (cursor === 0 && pendingSection === "") scrollTop()
  }
  onPendingSectionChanged: if (pendingSection !== "") {
    _seeking = true
    seekWatchdog.restart()
    Qt.callLater(_applyPendingSection)
  }
  onReadyChanged: if (ready && pendingSection !== "") Qt.callLater(_applyPendingSection)

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

    // ---- level-up gate: which kanji still block the next level (current level
    // only, mirroring the website's "Guru N more kanji" line) ----
    Item {
      id: levelUpBand
      anchors.top: levelBar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(24)
      anchors.rightMargin: Style.space(24)
      anchors.topMargin: visible ? Style.space(10) : 0

      readonly property int userLevel: browser.service ? Number(browser.service.level) || 0 : 0
      // 90% of this level's kanji must be Guru'd to level up. Everything here
      // reads off the same browse counts so the text, the bar and the section
      // header can't disagree.
      readonly property var kp: browser.progOf("kanji")
      readonly property int threshold: kp.total > 0 ? Math.ceil(kp.total * 0.9) : 1
      readonly property int gate: Math.max(0, threshold - kp.passed)
      visible: !browser.searching && browser.ready
        && browser.level === userLevel && browser.blockingKanji.length > 0
      implicitHeight: visible ? bandCol.implicitHeight : 0

      Column {
        id: bandCol
        width: parent.width
        spacing: Style.space(8)

        // "Guru <b>3 more kanji</b> to level up." -- WK bolds the count phrase
        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: levelUpBand.gate > 0
            ? "Guru <b>" + levelUpBand.gate + " more kanji</b> to level up."
            : "<b>Kanji gate cleared</b> — level " + (browser.level + 1) + " is unlocked."
          color: levelUpBand.gate > 0 ? browser.ink : browser.passedColor
          font.family: browser.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // segmented gate bar: one slot per kanji needed for the threshold,
        // green for the ones already Guru'd. Rounded outer ends, square
        // middles, generous gaps -- the website's look. The wrapper adds a
        // little breathing room below the bar before the blocking chips.
        Item {
          width: parent.width
          implicitHeight: gateBar.implicitHeight + Style.space(6)
          Row {
            id: gateBar
            width: parent.width
            anchors.top: parent.top
            spacing: Style.space(3)
            readonly property int slots: Math.max(1, levelUpBand.threshold)
            readonly property int filled: Math.min(slots, levelUpBand.kp.passed)
            readonly property real segW: (bandCol.width - (slots - 1) * Style.space(3)) / slots
            Repeater {
              model: gateBar.slots
              delegate: Rectangle {
                width: gateBar.segW
                height: Style.space(10)
                readonly property real endR: Style.space(4)
                topLeftRadius: index === 0 ? endR : 0
                bottomLeftRadius: index === 0 ? endR : 0
                topRightRadius: index === gateBar.slots - 1 ? endR : 0
                bottomRightRadius: index === gateBar.slots - 1 ? endR : 0
                color: index < gateBar.filled
                  ? browser.passedColor
                  : Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.14)
              }
            }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: browser.blockingKanji.slice(0, 14)
            delegate: SubjectChip {
              subjectId: modelData.id
              object: "kanji"
              characters: modelData.characters || ""
              meaning: modelData.meaning || ""
              locked: modelData.unlocked === false
              fontFamily: browser.fontFamily
              jpFamily: browser.jpFamily
              fg: browser.ink
              radicalColor: browser.radicalColor
              kanjiColor: browser.kanjiColor
              vocabColor: browser.vocabColor
              onActivated: browser.openSubject(modelData.id)
            }
          }
          Text {
            visible: browser.blockingKanji.length > 14
            anchors.verticalCenter: parent.verticalCenter
            text: "+" + (browser.blockingKanji.length - 14)
            color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.5)
            font.family: browser.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }

    // ---- scrolling section list ----
    Flickable {
      id: flick
      anchors.top: levelUpBand.bottom
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
            Component.onCompleted: browser._sections[modelData.kind] = section
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
                text: "(" + section.p.passed + "/" + section.p.total + " Guru'd)"
                color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.7)
                font.family: browser.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // chip grid -- each cell is the chip plus a thin SRS-progress
            // strip, the way the website annotates its level page
            Grid {
              id: grid
              width: parent.width
              columns: browser.columns
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(10)

              Repeater {
                model: section.srows
                delegate: Column {
                  id: cell
                  width: (grid.width - (browser.columns - 1) * Style.space(8)) / browser.columns
                  spacing: Style.space(3)
                  readonly property int flatIndex: section.baseIndex + index
                  readonly property bool cLocked: modelData.unlocked === false
                  // unlocked but not learned yet -> in the lesson queue
                  readonly property bool cInLessons: modelData.unlocked === true
                    && modelData.started !== true
                  readonly property int cStage: Number(modelData.srsStage) || 0

                  SubjectChip {
                    id: chipItem
                    width: parent.width
                    subjectId: modelData.id
                    object: modelData.object
                    characters: modelData.characters || ""
                    meaning: modelData.meaning || ""
                    locked: cell.cLocked
                    inLessons: cell.cInLessons
                    cursored: browser.cursor === cell.flatIndex && browser.visible && !browser.onLevelBar
                    fontFamily: browser.fontFamily
                    jpFamily: browser.jpFamily
                    fg: browser.ink
                    radicalColor: browser.radicalColor
                    kanjiColor: browser.kanjiColor
                    vocabColor: browser.vocabColor
                    onActivated: {
                      browser.cursor = cell.flatIndex
                      browser.openSubject(modelData.id)
                    }
                    onCursoredChanged: if (cursored) Qt.callLater(function () {
                      if (browser._seeking) return   // sectionPin owns the scroll
                      if (cell.flatIndex === 0) browser.scrollTop()
                      else browser.ensureVisible(cell)
                    })
                  }

                  // annotation band under the chip -- a fixed-height slot so
                  // the SRS strip and the "Lessons" / "Locked" caption sit on
                  // the same line across a grid row. Started items get the
                  // strip; lessons / locked items get the word.
                  Item {
                    width: parent.width
                    height: Style.space(15)

                    SrsStrip {
                      visible: !cell.cLocked && !cell.cInLessons
                      width: parent.width - Style.space(8)
                      anchors.centerIn: parent
                      stage: cell.cStage
                      locked: cell.cLocked
                      fg: browser.ink
                      passedColor: browser.passedColor
                    }

                    Text {
                      visible: cell.cLocked || cell.cInLessons
                      anchors.centerIn: parent
                      text: cell.cLocked ? "Locked" : "Lessons"
                      color: Qt.rgba(browser.ink.r, browser.ink.g, browser.ink.b, 0.5)
                      font.family: browser.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
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
