import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget and dashboard for OmaKani. One entry point, like the
// first-party dropbox plugin: a quiet alligator-head mark that takes the accent
// colour while reviews (or lessons) are waiting, and a drop-down with the counts
// and the Upcoming Reviews forecast (day list -> hour breakdown, mirroring the
// website). The rest of the dashboard sections land here across phase 2.
Panel {
  id: root
  moduleName: "io.github.aphelion-studios.omakani"
  ipcTarget: "io.github.aphelion-studios.omakani"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color background: Color.popups.background
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // WaniKani's subject-type colours, held a touch off their vivid web values so
  // they read on a dark bar without shouting. Used for Level Progress and the
  // Item Spread pills, where the colour carries meaning.
  readonly property color radicalColor: "#1f93e6"
  readonly property color kanjiColor: "#e42e9c"
  readonly property color vocabColor: "#9457e8"

  // WaniKani's review-forecast green, for the Upcoming Reviews bars and deltas.
  readonly property color forecastColor: "#93c01f"

  function typeColor(type) {
    if (type === "radical" || type === "radicals") return radicalColor
    if (type === "kanji") return kanjiColor
    return vocabColor
  }

  // Japanese characters (item chips) need CJK coverage the bar's monospace
  // font lacks. Match WaniKani's web app ("Noto Sans JP") when that Google
  // webfont is installed; otherwise "Noto Sans CJK JP", the same Source Han
  // Sans design that ships with the OS. A machine without either falls back
  // to whatever it offers.
  readonly property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  readonly property bool showLessons: setting("showLessons", true) === true
  readonly property bool hideWhenZero: setting("hideWhenZero", false) === true

  readonly property bool anythingDue: wk.reviewsNow > 0 || (showLessons && wk.lessonsNow > 0)
  readonly property bool markActive: wk.configured && anythingDue && !wk.vacation

  // The two count cards (Lessons / Reviews), mirroring the website. The
  // Lessons card is dropped when the showLessons setting is off. `active`
  // means that queue has something waiting now (drives the loud button
  // style). Both run in the shell now, via a summon payload.
  readonly property var startActions: {
    var out = []
    if (showLessons)
      out.push({ kind: "lessons", label: "Lessons", text: "Start Lessons",
                 payload: { lesson: true },
                 count: wk.lessonsNow,
                 active: wk.lessonsNow > 0 && !wk.vacation })
    out.push({ kind: "reviews", label: "Reviews", text: "Start Reviews",
               payload: { review: true },
               count: wk.reviewsNow,
               active: wk.reviewsNow > 0 && !wk.vacation })
    return out
  }
  function openStart(index) {
    var a = startActions[index]
    if (!a) return
    if (a.payload) {
      Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon",
        "io.github.aphelion-studios.omakani", JSON.stringify(a.payload)])
      root.close()   // get the dropdown out of the app's way
    } else if (a.url) {
      Quickshell.execDetached(["xdg-open", String(a.url)])
    }
  }

  // The mark always shows while unconnected (so the panel stays reachable to
  // paste a token) and while something is due; hideWhenZero only hides a
  // connected, caught-up widget.
  visible: !wk.configured || !hideWhenZero || anythingDue
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string statusText: Model.statusLine(wk.view)
  readonly property bool statusIsError: wk.lastError !== ""

  // ---- keyboard navigation ----------------------------------------------
  //
  // One cursor over a flat sequence of sections. j/k step through it (moving
  // within a vertical section, then crossing to the next); h/l move within a
  // horizontal section (chip rows, footer), and on a vertical row l acts /
  // h goes back. Enter or Space acts. g / G jump to the ends. Mouse hover
  // drives the same cursor, so there is exactly one highlight.

  property bool navActive: false
  property string navSection: ""
  property int navIndex: 0
  property Item cursorItem: null

  readonly property int chipCap: 15
  function chipCount(list) { return Math.min(list ? list.length : 0, chipCap) }

  // Only the sections that exist right now, in visual order. { n: name,
  // o: orientation "v"|"h", c: item count }.
  readonly property var navSections: {
    if (settingsOpen) return [{ n: "settings", o: "v", c: settingRows.length },
                              { n: "settingsdone", o: "h", c: 1 }]
    if (!wk.configured) return [{ n: "token", o: "v", c: 1 }, { n: "footer", o: "h", c: 4 }]
    if (upcomingDrill >= 0) return [{ n: "drillback", o: "h", c: 1 }]
    var out = []
    if (startActions.length > 0)
      out.push({ n: "start", o: "h", c: startActions.length })
    if (wk.dashboardLoaded && wk.upcoming.length > 0)
      out.push({ n: "upcoming", o: "v", c: wk.upcoming.length })
    if (wk.dashboardLoaded)
      out.push({ n: "extra", o: "v", c: 3 })
    if (chipCount(wk.recentlyUnlocked) > 0)
      out.push({ n: "unlocked", o: "h", c: chipCount(wk.recentlyUnlocked) })
    if (chipCount(wk.criticalCondition) > 0)
      out.push({ n: "critical", o: "h", c: chipCount(wk.criticalCondition) })
    if (chipCount(wk.recentlyBurned) > 0)
      out.push({ n: "burned", o: "h", c: chipCount(wk.recentlyBurned) })
    out.push({ n: "footer", o: "h", c: 4 })
    return out
  }

  function navSecAt(name) {
    var s = navSections
    for (var i = 0; i < s.length; i++) if (s[i].n === name) return i
    return -1
  }
  readonly property var navCur: {
    var i = navSecAt(navSection)
    return i >= 0 ? navSections[i] : null
  }

  function hasCursor(section, index) {
    return navActive && navSection === section && navIndex === index
  }
  function setCursor(section, index) {
    navActive = true
    navSection = section
    navIndex = index
  }
  function setCursorItem(item) {
    cursorItem = item
    scrollTimer.restart()
  }

  function navReset() {
    navActive = false
    navSection = navSections.length > 0 ? navSections[0].n : ""
    navIndex = 0
  }

  function navMove(dx, dy) {
    var secs = navSections
    if (secs.length === 0) return
    if (!navActive) {
      navActive = true
      if (navSecAt(navSection) < 0) { navSection = secs[0].n; navIndex = 0 }
      scrollTimer.restart()
      return
    }
    var si = navSecAt(navSection)
    if (si < 0) { navSection = secs[0].n; navIndex = 0; scrollTimer.restart(); return }
    var cur = secs[si]

    if (dy !== 0) {
      var down = dy > 0
      if (cur.o === "v" && ((down && navIndex < cur.c - 1) || (!down && navIndex > 0))) {
        navIndex += down ? 1 : -1
      } else {
        var ni = si + (down ? 1 : -1)
        if (ni >= 0 && ni < secs.length) {
          navSection = secs[ni].n
          navIndex = down ? 0 : secs[ni].c - 1
        }
      }
    } else if (dx !== 0) {
      var right = dx > 0
      if (cur.n === "drillback") {
        if (!right) upcomingDrill = -1
      } else if (cur.n === "settingsdone") {
        if (!right) settingsOpen = false
      } else if (cur.n === "settings") {
        settingsAdjust(navIndex, right ? 1 : -1)
      } else if (cur.o === "h") {
        navIndex = Math.max(0, Math.min(cur.c - 1, navIndex + (right ? 1 : -1)))
      } else if (right) {
        navActivate()
        return
      }
    }
    scrollTimer.restart()
  }

  function navEnd(toBottom) {
    var secs = navSections
    if (secs.length === 0) return
    navActive = true
    var s = toBottom ? secs[secs.length - 1] : secs[0]
    navSection = s.n
    navIndex = toBottom ? s.c - 1 : 0
    scrollTimer.restart()
  }

  function navActivate() {
    if (!navActive) { navActive = true; return }
    var s = navSection, i = navIndex
    if (s === "token") tokenField.forceActiveFocus()
    else if (s === "drillback") upcomingDrill = -1
    else if (s === "settingsdone") settingsOpen = false
    else if (s === "settings") settingsActivate(i)
    else if (s === "upcoming") {
      if (i < wk.upcoming.length && Number(wk.upcoming[i].count) > 0) upcomingDrill = i
    }
    else if (s === "start") openStart(i)
    else if (s === "extra") openExtraStudy(i)
    else if (s === "unlocked") openItem(wk.recentlyUnlocked[i])
    else if (s === "critical") openItem(wk.criticalCondition[i])
    else if (s === "burned") openItem(wk.recentlyBurned[i])
    else if (s === "footer") {
      if (i === 0) wk.refreshAll()
      else if (i === 1) openDashboard()
      else if (i === 2) settingsOpen = !settingsOpen
      else wk.clearToken()
    }
  }

  function openItem(item) {
    if (item && item.url) Quickshell.execDetached(["xdg-open", String(item.url)])
  }
  function openDashboard() {
    Quickshell.execDetached(["xdg-open", "https://www.wanikani.com/dashboard"])
  }
  function openExtraStudy(index) {
    var es = wk.extraStudy
    var modes = ["recent-lessons", "mistakes", "burned"]
    var counts = [Number(es.recentLessons), Number(es.recentMistakes), Number(es.burnedItems)]
    if (index < 0 || index > 2 || !(counts[index] > 0)) return
    // run it in the full app (no server sync -- WaniKani doesn't track Extra
    // Study). summon carries a payload so it works whether the app is open.
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon",
      "io.github.aphelion-studios.omakani",
      JSON.stringify({ session: modes[index] })])
  }

  Timer {
    id: scrollTimer
    interval: 1
    onTriggered: root.scrollToCursor()
  }
  function scrollToCursor() {
    var it = cursorItem
    if (!it || !it.visible || !panelFlick) return
    // At the very first target, show the whole header above it.
    if (navSecAt(navSection) === 0 && navIndex === 0) {
      panelFlick.contentY = 0
      return
    }
    var y = it.mapToItem(panelFlick.contentItem, 0, 0).y
    // A fatter top margin on the first row of a section pulls its heading in too.
    var topM = navIndex === 0 ? Style.space(38) : Style.space(16)
    var botM = Style.space(16)
    var viewH = panelFlick.height
    var maxY = Math.max(0, panelFlick.contentHeight - viewH)
    if (y - topM < panelFlick.contentY)
      panelFlick.contentY = Math.max(0, y - topM)
    else if (y + it.height + botM > panelFlick.contentY + viewH)
      panelFlick.contentY = Math.min(maxY, y + it.height + botM - viewH)
  }

  function commitToken() {
    var token = tokenField.text
    if (String(token).trim() === "") return
    tokenField.text = ""
    tokenField.focus = false
    wk.saveToken(token)
  }

  onOpenedChanged: if (opened) {
    upcomingDrill = -1
    settingsOpen = false
    navReset()
    if (panelFlick) panelFlick.contentY = 0
    wk.refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Drilling in / out of a day rebuilds the section list; land the cursor
  // somewhere valid. Deferred, because `navSections` is not yet re-evaluated
  // while this change signal is being delivered.
  onUpcomingDrillChanged: Qt.callLater(function() {
    root.navSection = root.navSections.length > 0 ? root.navSections[0].n : ""
    root.navIndex = 0
    scrollTimer.restart()
  })

  // Which day the Upcoming Reviews section is drilled into; -1 is the day list.
  property int upcomingDrill: -1

  // ---- settings ---------------------------------------------------------

  property bool settingsOpen: false
  onSettingsOpenChanged: {
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() {
      root.navSection = root.navSections.length > 0 ? root.navSections[0].n : ""
      root.navIndex = 0
      scrollTimer.restart()
    })
  }

  // Ordered { key, kind } for the settings sheet. bool rows flip on Enter;
  // the number row takes h/l.
  readonly property var settingRows: [
    { key: "showLessons",           kind: "bool", label: "Light the mark for lessons",
      fallback: true },
    { key: "hideWhenZero",          kind: "bool", label: "Hide the mark when caught up",
      fallback: false },
    { key: "notifyReviewsThreshold", kind: "int", label: "Notify at N reviews",
      fallback: 25, from: 0, to: 500, step: 5 },
    { key: "notifyLessons",         kind: "bool", label: "Notify on new lessons",
      fallback: true },
    { key: "notifyLevelUp",         kind: "bool", label: "Notify on level-up",
      fallback: true },
    { key: "notifyBurns",           kind: "bool", label: "Notify when items burn",
      fallback: true },
  ]

  function settingValue(row) {
    var v = setting(row.key, row.fallback)
    if (row.kind === "bool") return v === true || v === "true" || v === 1
    var n = parseInt(String(v), 10)
    return isFinite(n) ? n : row.fallback
  }

  // Merge new values into this widget's shell.json layout entry and persist.
  // The local `settings` update redraws immediately; the Binding pushes it to
  // the shared service.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var k in values) entry[k] = values[k]
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function settingsActivate(index) {
    var row = settingRows[index]
    if (!row || row.kind !== "bool") return
    var next = {}
    next[row.key] = !settingValue(row)
    persistSettings(next)
  }

  function settingsAdjust(index, dir) {
    var row = settingRows[index]
    if (!row || row.kind !== "int") return
    var step = row.step || 1
    var v = Math.max(row.from, Math.min(row.to, settingValue(row) + dir * step))
    var next = {}
    next[row.key] = v
    persistSettings(next)
  }

  // The shared service instance. Null for a beat at startup before the shell
  // mounts it, so every read below is guarded.
  readonly property var svc: (bar && bar.shell && bar.shell.serviceFor)
    ? bar.shell.serviceFor("io.github.aphelion-studios.omakani")
    : null

  // Push this bar-widget entry's settings into the shared service.
  Binding {
    target: root.svc
    property: "settings"
    value: root.settings
    when: root.svc !== null
  }

  Connections {
    target: root.svc
    function onTokenRejected(message) {
      Qt.callLater(function() { tokenField.forceActiveFocus() })
    }
  }

  // Null-safe view of the service so the bindings below stay terse.
  QtObject {
    id: wk
    readonly property var view: root.svc ? root.svc.view : ({ ok: true, configured: false })
    readonly property var dash: root.svc ? root.svc.dash : ({})
    readonly property bool configured: root.svc ? root.svc.configured : false
    readonly property string lastError: root.svc ? root.svc.lastError : ""
    readonly property string note: root.svc ? root.svc.note : ""
    readonly property bool ready: root.svc ? root.svc.ready : false
    readonly property bool refreshing: root.svc ? root.svc.refreshing : false
    readonly property bool actionBusy: root.svc ? root.svc.actionBusy : false
    readonly property int reviewsNow: root.svc ? root.svc.reviewsNow : 0
    readonly property int lessonsNow: root.svc ? root.svc.lessonsNow : 0
    readonly property string nextReviewsAt: root.svc ? root.svc.nextReviewsAt : ""
    readonly property int level: root.svc ? root.svc.level : 0
    readonly property string username: root.svc ? root.svc.username : ""
    readonly property bool vacation: root.svc ? root.svc.vacation : false
    readonly property bool dashboardLoaded: root.svc ? root.svc.dashboardLoaded : false
    readonly property bool dashboardBusy: root.svc ? root.svc.dashboardBusy : false
    readonly property bool coldStart: root.svc ? root.svc.coldStart : false
    readonly property var itemSpread: root.svc ? root.svc.itemSpread : ({})
    readonly property var levelProgress: root.svc ? root.svc.levelProgress : ({})
    readonly property string projectedLevelUp: root.svc ? root.svc.projectedLevelUp : ""
    readonly property var upcoming: root.svc ? root.svc.upcoming : []
    readonly property int upcomingTotal: root.svc ? root.svc.upcomingTotal : 0
    readonly property var recentlyUnlocked: root.svc ? root.svc.recentlyUnlocked : []
    readonly property var recentlyBurned: root.svc ? root.svc.recentlyBurned : []
    readonly property var criticalCondition: root.svc ? root.svc.criticalCondition : []
    readonly property var extraStudy: root.svc ? root.svc.extraStudy : ({})

    function refresh() { if (root.svc) root.svc.refresh() }
    function refreshAll() { if (root.svc) root.svc.refreshAll() }
    function refreshDashboard() { if (root.svc) root.svc.refreshDashboard() }
    function saveToken(token) { if (root.svc) root.svc.saveToken(token) }
    function clearToken() { if (root.svc) root.svc.clearToken() }
  }

  // Seconds only matter while the popup is open and counting down to the next
  // review; nothing else needs them.
  SystemClock {
    id: clock
    precision: root.opened ? SystemClock.Seconds : SystemClock.Minutes
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function settings(): void { root.open(); root.settingsOpen = true }
    function refresh(): string { wk.refreshAll(); return "ok" }
    function status(): string {
      if (!wk.configured) return "not connected"
      return wk.lessonsNow + " lessons, " + wk.reviewsNow + " reviews"
    }
    function debug(): string {
      return JSON.stringify({
        configured: wk.configured,
        dashboardLoaded: wk.dashboardLoaded,
        dashboardBusy: wk.dashboardBusy,
        lastError: wk.lastError,
        reviewsNow: wk.reviewsNow,
        lessonsNow: wk.lessonsNow,
        counts: wk.dash.counts,
        nav: root.navActive ? (root.navSection + "[" + root.navIndex + "]") : "off",
        fetchedAt: wk.dash.fetchedAt
      })
    }
  }

  // ---- the recolourable mark -------------------------------------------------

  // The Crabigator badge is round and fills its viewBox, so it runs a touch
  // smaller than a nominal bar glyph (which leaves ink room inside its em) to
  // weigh the same as the Nerd Font icons around it.
  readonly property int barMarkHeight: Math.round(Style.bar.iconFont * 1.02)

  component Mark: Item {
    id: markRoot
    // `size` is the mark's height; the Crabigator head is much taller than
    // it is wide (243 x 399 in the source).
    property real size: root.barMarkHeight
    readonly property real aspect: 243 / 399
    property color tint: root.foreground
    implicitWidth: Math.round(size * aspect)
    implicitHeight: size

    Image {
      id: markSource
      anchors.fill: parent
      source: Qt.resolvedUrl("icon.svg")
      sourceSize.width: Math.round(markRoot.size * 4)
      sourceSize.height: Math.round(markRoot.size * 4)
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: false
    }
    MultiEffect {
      anchors.fill: parent
      source: markSource
      colorization: 1.0
      colorizationColor: markRoot.tint
      Behavior on colorizationColor { ColorAnimation { duration: 160 } }
    }
  }

  // The "WANI KANI" lockup for the top of the dashboard -- the plugin
  // author's artwork (wordmark.svg), pink text + blue Crabigator on a
  // transparent ground so it sits on any theme. `h` is the render height.
  // QtSvg's auto-sizing on this file is unreliable, so pin the raster to
  // the artwork's native width and let it downscale -- always crisp.
  component Wordmark: Image {
    property real h: Style.space(44)
    height: h
    fillMode: Image.PreserveAspectFit
    source: Qt.resolvedUrl("wordmark.svg")
    sourceSize.width: 1893
    smooth: true
    mipmap: true
  }

  // ---- bar button ---------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // `text` feeds the pill sizing fallback and nothing else; the visible mark
    // is the child below, and labelVisible is off.
    text: "wanikani"
    labelVisible: false
    fixedWidth: Math.round(root.barMarkHeight * (243 / 399)) + Style.space(10)
    tooltipText: Model.barTooltip(wk.view, clock.date)
    onPressed: function(pressedButton) {
      if (pressedButton === Qt.MiddleButton) wk.refresh()
      else root.toggle()
    }

    Mark {
      anchors.centerIn: parent
      tint: root.markActive ? root.accent
        : (!wk.configured
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.7)
           : root.foreground)
    }
  }

  // ---- dashboard --------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: tokenField.activeFocus
      onMoveRequested: function(dx, dy) { root.navMove(dx, dy) }
      onActivateRequested: root.navActivate()
      onCloseRequested: {
        if (root.settingsOpen) root.settingsOpen = false
        else if (root.upcomingDrill >= 0) root.upcomingDrill = -1
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") wk.refreshAll()
        else if (text === "g") root.navEnd(false)
        else if (text === "G") root.navEnd(true)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Column {
            width: parent.width
            spacing: Style.space(4)
            topPadding: Style.space(2)

            Wordmark {
              anchors.horizontalCenter: parent.horizontalCenter
              h: Style.space(60)
              // never let a large-font theme push it past the card
              width: Math.min(implicitWidth, parent.width - Style.space(8))
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: text !== ""
              text: {
                if (!wk.configured) return "paste a read-only API token below"
                if (wk.vacation) return "vacation mode"
                if (root.anythingDue) return ""
                var rel = Model.relativeTime(wk.nextReviewsAt, clock.date)
                return rel === "" ? "all caught up" : "next review " + rel
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.statusText !== ""
            width: parent.width
            text: root.statusText
            color: root.statusIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ----------------------------------------------------- connect

          Column {
            visible: !wk.configured
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "API TOKEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: tokenField
                Layout.fillWidth: true
                password: true
                placeholderText: "Paste a WaniKani API token"
                foreground: root.foreground
                font.family: root.fontFamily
                enabled: !wk.actionBusy
                hasCursor: !activeFocus && root.hasCursor("token", 0)
                onHoveredChanged: if (hovered) root.setCursor("token", 0)
                onHasCursorChanged: if (hasCursor) root.setCursorItem(tokenField)
                onAccepted: root.commitToken()
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { focus = false; event.accepted = true }
                }
              }

              Button {
                text: "Connect"
                iconText: "󰌆"
                bordered: true
                enabled: !wk.actionBusy && tokenField.text !== ""
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.commitToken()
              }
            }

            Text {
              width: parent.width
              text: "wanikani.com → Settings → API Tokens → Generate a new token. "
                + "Read-only is enough for the dashboard. Stored in "
                + "~/.config/omarchy/wanikani.json with 0600 permissions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------------------------------------------------- counts

          RowLayout {
            visible: wk.configured
            width: parent.width
            spacing: Style.space(12)

            Repeater {
              model: root.startActions
              delegate: CountCard {
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                index: model.index
                kind: modelData.kind
                label: modelData.label
                count: modelData.count
                active: modelData.active
                startText: modelData.text
              }
            }
          }

          PanelSeparator {
            visible: wk.configured
            foreground: root.foreground
          }

          // ------------------------------------------ upcoming reviews

          Column {
            id: upcomingBlock
            visible: wk.configured
            width: parent.width
            spacing: Style.space(8)

            readonly property var drillDay: root.upcomingDrill >= 0
              && root.upcomingDrill < wk.upcoming.length
              ? wk.upcoming[root.upcomingDrill] : null

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelActionButton {
                id: drillBackBtn
                visible: upcomingBlock.drillDay !== null
                iconText: "󰅁"
                tooltipText: "Back to the week"
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursor("drillback", 0)
                onHovered: function(h) { if (h) root.setCursor("drillback", 0) }
                onHasCursorChanged: if (hasCursor) root.setCursorItem(drillBackBtn)
                onClicked: root.upcomingDrill = -1
              }

              PanelSectionHeader {
                text: upcomingBlock.drillDay
                  ? String(upcomingBlock.drillDay.labelLong || upcomingBlock.drillDay.label).toUpperCase()
                  : "UPCOMING REVIEWS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }

              Text {
                visible: wk.dashboardLoaded
                text: {
                  var d = upcomingBlock.drillDay
                  var added = d ? d.count : wk.upcomingTotal
                  return added > 0 ? "+" + added : "—"
                }
                color: root.forecastColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            UpcomingRows {
              width: parent.width
              day: upcomingBlock.drillDay
              onDrillInto: function (index) { root.upcomingDrill = index }
            }

            Text {
              visible: wk.dashboardLoaded && upcomingBlock.drillDay === null
                && wk.upcomingTotal === 0
              width: parent.width
              text: {
                var rel = Model.relativeTime(wk.nextReviewsAt, clock.date)
                return "Nothing due in the next 5 days"
                  + (rel === "" || rel === "now" ? "." : " — next review " + rel + ".")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !wk.dashboardLoaded
              width: parent.width
              text: wk.coldStart || wk.dashboardBusy
                ? "Building your dashboard… this first sync can take a few seconds."
                : "Loading…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: wk.configured
            foreground: root.foreground
          }

          // ------------------------------------------- extra study

          Column {
            visible: wk.configured && wk.dashboardLoaded
            width: parent.width
            spacing: Style.space(5)

            readonly property var es: wk.extraStudy

            PanelSectionHeader {
              text: "EXTRA STUDY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ExtraStudyRow {
              width: parent.width
              idx: 0
              label: "Recent Lessons"
              count: Number(parent.es.recentLessons)
              queue: "recent_lessons"
            }
            ExtraStudyRow {
              width: parent.width
              idx: 1
              label: "Recent Mistakes"
              count: Number(parent.es.recentMistakes)
              queue: "recent_mistakes"
            }
            ExtraStudyRow {
              width: parent.width
              idx: 2
              label: "Burned Items"
              count: Number(parent.es.burnedItems)
              queue: "burned"
            }
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // ----------------------------------------- level progress

          Column {
            visible: wk.configured && wk.dashboardLoaded
            width: parent.width
            spacing: Style.space(8)

            readonly property var lp: wk.levelProgress
            readonly property int gate: Number(lp.kanjiToLevelUp) || 0

            PanelSectionHeader {
              text: "LEVEL " + wk.level + " PROGRESS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ProgressRow {
              width: parent.width
              label: "Radicals"
              tint: root.radicalColor
              passed: Number(parent.lp.radicals ? parent.lp.radicals.passed : 0)
              total: Number(parent.lp.radicals ? parent.lp.radicals.total : 0)
            }
            ProgressRow {
              width: parent.width
              label: "Kanji"
              tint: root.kanjiColor
              passed: Number(parent.lp.kanji ? parent.lp.kanji.passed : 0)
              total: Number(parent.lp.kanji ? parent.lp.kanji.total : 0)
            }
            ProgressRow {
              width: parent.width
              label: "Vocabulary"
              tint: root.vocabColor
              passed: Number(parent.lp.vocabulary ? parent.lp.vocabulary.passed : 0)
              total: Number(parent.lp.vocabulary ? parent.lp.vocabulary.total : 0)
            }

            Text {
              width: parent.width
              topPadding: Style.space(2)
              text: parent.gate > 0
                ? "Guru " + parent.gate + " more kanji to reach level " + (wk.level + 1)
                : "Kanji gate cleared — level " + (wk.level + 1) + " is unlocked."
              color: parent.gate > 0 ? root.foreground : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // -------------------------------------------- item spread

          Column {
            visible: wk.configured && wk.dashboardLoaded
            width: parent.width
            spacing: Style.space(6)

            RowLayout {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "ITEM SPREAD"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }
              Repeater {
                model: [
                  { t: "Rad", c: root.radicalColor },
                  { t: "Kan", c: root.kanjiColor },
                  { t: "Voc", c: root.vocabColor },
                ]
                delegate: Row {
                  spacing: Style.space(3)
                  Rectangle {
                    width: Style.space(6); height: Style.space(6); radius: width / 2
                    color: modelData.c
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.t
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            SpreadRow { width: parent.width; label: "Apprentice";   bucket: wk.itemSpread.apprentice }
            SpreadRow { width: parent.width; label: "Guru";         bucket: wk.itemSpread.guru }
            SpreadRow { width: parent.width; label: "Master";       bucket: wk.itemSpread.master }
            SpreadRow { width: parent.width; label: "Enlightened";  bucket: wk.itemSpread.enlightened }
            SpreadRow { width: parent.width; label: "Burned";       bucket: wk.itemSpread.burned }
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // -------------------------------------------- item lists

          ItemList {
            width: parent.width
            section: "unlocked"
            title: "RECENTLY UNLOCKED"
            note: "30 days"
            items: wk.recentlyUnlocked
            emptyText: "Nothing unlocked in the last 30 days."
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          ItemList {
            width: parent.width
            section: "critical"
            title: "CRITICAL CONDITION"
            note: "< 75%"
            items: wk.criticalCondition
            emptyText: "Your items are in good health."
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          ItemList {
            width: parent.width
            section: "burned"
            title: "RECENTLY BURNED"
            note: "30 days"
            items: wk.recentlyBurned
            emptyText: "Nothing burned in the last 30 days."
          }

          PanelSeparator {
            visible: wk.configured && wk.dashboardLoaded
            foreground: root.foreground
          }

          // ---------------------------------------------------- footer

          RowLayout {
            visible: wk.configured
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: {
                var parts = []
                if (wk.level) parts.push("󰃀  Level " + wk.level)
                if (wk.username) parts.push(wk.username)
                if (wk.vacation) parts.push("vacation")
                return parts.join("   ·   ")
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            PanelActionButton {
              id: footerRefresh
              iconText: "󰑐"
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !wk.refreshing
              hasCursor: root.hasCursor("footer", 0)
              onHovered: function(h) { if (h) root.setCursor("footer", 0) }
              onHasCursorChanged: if (hasCursor) root.setCursorItem(footerRefresh)
              Layout.alignment: Qt.AlignVCenter
              onClicked: wk.refreshAll()
            }

            PanelActionButton {
              id: footerOpen
              iconText: "󰏌"
              tooltipText: "Open wanikani.com"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("footer", 1)
              onHovered: function(h) { if (h) root.setCursor("footer", 1) }
              onHasCursorChanged: if (hasCursor) root.setCursorItem(footerOpen)
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.openDashboard()
            }

            PanelActionButton {
              id: footerSettings
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("footer", 2)
              onHovered: function(h) { if (h) root.setCursor("footer", 2) }
              onHasCursorChanged: if (hasCursor) root.setCursorItem(footerSettings)
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.settingsOpen = !root.settingsOpen
            }

            PanelActionButton {
              id: footerForget
              iconText: "󰌆"
              tooltipText: "Forget the stored API token"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !wk.actionBusy
              hoverColor: root.urgent
              hasCursor: root.hasCursor("footer", 3)
              onHovered: function(h) { if (h) root.setCursor("footer", 3) }
              onHasCursorChanged: if (hasCursor) root.setCursorItem(footerForget)
              Layout.alignment: Qt.AlignVCenter
              onClicked: wk.clearToken()
            }
          }
        }
      }

      // Standalone so it can sit in the card's right padding rather than over
      // the content; wired to the flickable by hand.
      ScrollBar {
        id: vScroll
        orientation: Qt.Vertical
        anchors.top: panelFlick.top
        anchors.bottom: panelFlick.bottom
        anchors.right: panelFlick.right
        anchors.rightMargin: -Style.space(11)
        policy: ScrollBar.AsNeeded
        size: panelFlick.visibleArea.heightRatio
        position: panelFlick.visibleArea.yPosition
        active: panelFlick.movingVertically || hovered || pressed
        onPositionChanged: if (pressed) panelFlick.contentY = position * panelFlick.contentHeight
      }

      // ---- settings sheet ----

      Rectangle {
        anchors.fill: parent
        visible: root.settingsOpen
        color: Color.popups.background

        Column {
          width: parent.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width
            spacing: Style.space(6)
            PanelActionButton {
              id: settingsBack
              iconText: "󰅁"
              tooltipText: "Done"
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("settingsdone", 0)
              onHovered: function(h) { if (h) root.setCursor("settingsdone", 0) }
              onHasCursorChanged: if (hasCursor) root.setCursorItem(settingsBack)
              onClicked: root.settingsOpen = false
            }
            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.fillWidth: true
            }
          }

          Repeater {
            model: root.settingRows
            delegate: SettingRow {
              width: parent.width
              row: modelData
              idx: index
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(4)
            text: "Notifications follow Do Not Disturb and stay quiet on vacation."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---- small components ------------------------------------------------

  // One of the two dashboard count cards, mirroring the website: the queue
  // name with its count (or "Done!" for a cleared lesson queue) to the
  // right, and that queue's Start button below. When the queue has items
  // (`active`) the button switches to a loud accent style with a soft
  // pulse; otherwise it's the quiet outline style. `index` is the slot in
  // root.startActions.
  component CountCard: Column {
    id: cc
    property int index: 0
    property string kind: ""
    property string label: ""
    property int count: 0
    property bool active: false
    property string startText: ""

    readonly property bool showDone: kind === "lessons" && count === 0
    readonly property bool cursored: root.hasCursor("start", index)

    spacing: Style.space(8)
    onCursoredChanged: if (cursored) root.setCursorItem(cc)

    // ---- queue name + count badge
    Row {
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: cc.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: badgeText.implicitWidth + Style.space(14)
        implicitHeight: Style.space(19)
        radius: height / 2
        color: cc.active
          ? root.accent
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

        Text {
          id: badgeText
          anchors.centerIn: parent
          text: cc.showDone ? "Done!" : String(cc.count)
          color: cc.active ? root.background : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    // ---- start button
    Rectangle {
      id: startBtn
      width: parent.width
      implicitHeight: Style.space(34)
      radius: Style.space(5)
      clip: true

      readonly property bool lit: cc.cursored || startHover.containsMouse

      color: cc.active
        ? (lit ? Qt.lighter(root.accent, 1.12) : root.accent)
        : (lit
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08))
      border.width: cc.cursored ? 2 : 1
      border.color: cc.cursored
        ? root.foreground
        : (cc.active
            ? "transparent"
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22))

      // "hey, look here!" breathing highlight while the queue is available
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: Qt.lighter(root.accent, 1.35)
        visible: cc.active
        opacity: 0
        SequentialAnimation on opacity {
          running: cc.active && startBtn.visible
          loops: Animation.Infinite
          NumberAnimation { from: 0.0; to: 0.4; duration: 950; easing.type: Easing.InOutSine }
          NumberAnimation { from: 0.4; to: 0.0; duration: 950; easing.type: Easing.InOutSine }
        }
      }

      Row {
        anchors.centerIn: parent
        spacing: Style.space(5)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: cc.startText
          color: cc.active ? root.background : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "›"
          color: cc.active ? root.background : root.foreground
          opacity: cc.active ? 0.9 : 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      MouseArea {
        id: startHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: if (containsMouse) root.setCursor("start", cc.index)
        onClicked: root.openStart(cc.index)
      }
    }
  }

  // One row in the settings sheet: a label plus a switch (bool) or a
  // minus / value / plus stepper (int). The row owns the click.
  component SettingRow: Item {
    id: sr
    property var row: ({})
    property int idx: 0
    readonly property bool cursored: root.hasCursor("settings", idx)
    readonly property bool isBool: row.kind === "bool"
    readonly property var currentValue: root.settingValue(row)
    implicitHeight: Style.space(28)
    onCursoredChanged: if (cursored) root.setCursorItem(sr)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: sr.isBool ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor("settings", sr.idx)
      onClicked: if (sr.isBool) root.settingsActivate(sr.idx)
    }

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      radius: Style.cornerRadius
      color: sr.cursored
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
      Behavior on color { ColorAnimation { duration: 60 } }
    }

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        text: String(sr.row.label || "")
        color: root.foreground
        opacity: 0.92
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
        elide: Text.ElideRight
      }

      ToggleSwitch {
        visible: sr.isBool
        checked: sr.currentValue === true
        interactive: false
        hasCursor: sr.cursored
        Layout.alignment: Qt.AlignVCenter
      }

      Row {
        visible: !sr.isBool
        spacing: Style.space(6)
        Layout.alignment: Qt.AlignVCenter

        PanelActionButton {
          iconText: "󰍵"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.settingsAdjust(sr.idx, -1)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          horizontalAlignment: Text.AlignHCenter
          text: sr.currentValue === 0 ? "off" : String(sr.currentValue)
          color: sr.currentValue === 0 ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        PanelActionButton {
          iconText: "󰐕"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.settingsAdjust(sr.idx, 1)
        }
      }
    }
  }

  // One Extra Study mode: name, a count badge, a chevron. Opens WaniKani's
  // extra-study session for that queue; a phase-5 change points it in-shell.
  component ExtraStudyRow: Item {
    id: esr
    property string label: ""
    property int count: 0
    property string queue: ""
    property int idx: 0
    readonly property bool available: count > 0
    readonly property bool cursored: root.hasCursor("extra", idx)
    implicitHeight: Style.space(20)
    opacity: available ? 1 : 0.45
    onCursoredChanged: if (cursored) root.setCursorItem(esr)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      radius: Style.cornerRadius
      color: esr.cursored
        ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        : "transparent"
      Behavior on color { ColorAnimation { duration: 60 } }
    }

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        text: esr.label
        color: root.foreground
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }

      Rectangle {
        implicitWidth: Math.max(Style.space(18), esrCount.implicitWidth + Style.space(8))
        implicitHeight: Style.space(15)
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                       esr.available ? 0.12 : 0.07)
        Layout.alignment: Qt.AlignVCenter
        Text {
          id: esrCount
          anchors.centerIn: parent
          text: String(esr.count)
          color: esr.available ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        text: "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: esr.available ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor("extra", esr.idx)
      onClicked: if (esr.available) root.openExtraStudy(esr.idx)
    }
  }

  // One Level Progress line: "Radicals  19 / 20" over a tinted fill bar.
  component ProgressRow: Column {
    id: pr
    property string label: ""
    property color tint: root.accent
    property int passed: 0
    property int total: 0
    readonly property real frac: total > 0 ? Math.max(0, Math.min(1, passed / total)) : 0
    spacing: Style.space(3)

    RowLayout {
      width: parent.width
      Text {
        text: pr.label
        color: root.foreground
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }
      Text {
        text: pr.passed + " / " + pr.total
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: 2
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
      Rectangle {
        width: Math.round(parent.width * pr.frac)
        height: parent.height
        radius: parent.radius
        color: pr.tint
      }
    }
  }

  // A coloured number chip in the Item Spread table.
  component Pill: Rectangle {
    property int value: 0
    property color tint: root.accent
    readonly property bool filled: value > 0
    implicitHeight: Style.space(16)
    Layout.fillWidth: true
    Layout.minimumWidth: Style.space(24)
    radius: Style.space(4)
    color: filled ? tint
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
    Text {
      anchors.centerIn: parent
      text: String(parent.value)
      color: parent.filled ? "#ffffff" : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // One Item Spread row: stage name, a chip per subject type, the stage total.
  component SpreadRow: RowLayout {
    id: sr
    property string label: ""
    property var bucket: ({})
    readonly property int rad: Number(bucket && bucket.radicals) || 0
    readonly property int kan: Number(bucket && bucket.kanji) || 0
    readonly property int voc: Number(bucket && bucket.vocabulary) || 0
    readonly property int total: rad + kan + voc
    spacing: Style.space(5)

    Text {
      text: sr.label
      color: root.foreground
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.preferredWidth: Style.space(72)
    }

    Pill { value: sr.rad; tint: root.radicalColor }
    Pill { value: sr.kan; tint: root.kanjiColor }
    Pill { value: sr.voc; tint: root.vocabColor }

    Text {
      text: String(sr.total)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: Style.space(28)
    }
  }

  // A subject as a coloured chip: its characters (or, for character-less
  // radicals, its meaning). Click opens the item's page on wanikani.com.
  component ItemChip: Rectangle {
    id: chip
    property var item: ({})
    property string section: ""
    property int idx: 0
    readonly property string glyph: (item && item.characters && String(item.characters).length)
      ? String(item.characters)
      : String((item && item.meaning) || "•")
    readonly property bool cursored: root.hasCursor(section, idx)
    implicitHeight: Style.space(19)
    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    radius: Style.space(4)
    color: root.typeColor(item ? item.type : "")
    opacity: chipMouse.containsMouse ? 0.82 : 1
    border.width: cursored ? Math.max(1, Style.space(2)) : 0
    border.color: root.foreground
    onCursoredChanged: if (cursored) root.setCursorItem(chip)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: parent.glyph
      color: "#ffffff"
      font.family: root.jpFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor(chip.section, chip.idx)
      onClicked: root.openItem(chip.item)
    }
  }

  // A titled section that flows a list of subjects as chips, with an empty
  // state and a "+N more" chip that opens the dashboard.
  component ItemList: Column {
    id: il
    property string title: ""
    property string note: ""
    property string section: ""
    property var items: []
    property string emptyText: ""
    property int cap: root.chipCap
    spacing: Style.space(6)
    visible: wk.configured && wk.dashboardLoaded

    RowLayout {
      width: parent.width
      PanelSectionHeader {
        text: il.title
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.fillWidth: true
      }
      Text {
        text: {
          var count = il.items ? il.items.length : 0
          if (count === 0) return il.note
          return il.note === "" ? String(count) : il.note + "  ·  " + count
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(4)
      visible: il.items && il.items.length > 0

      Repeater {
        model: il.items ? il.items.slice(0, il.cap) : []
        delegate: ItemChip { item: modelData; section: il.section; idx: index }
      }

      Rectangle {
        visible: il.items && il.items.length > il.cap
        implicitHeight: Style.space(19)
        implicitWidth: moreLabel.implicitWidth + Style.space(12)
        radius: Style.space(4)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
        Text {
          id: moreLabel
          anchors.centerIn: parent
          text: "+" + ((il.items ? il.items.length : 0) - il.cap) + " more"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: Quickshell.execDetached(["xdg-open", "https://www.wanikani.com/dashboard"])
        }
      }
    }

    Text {
      visible: !il.items || il.items.length === 0
      width: parent.width
      text: il.emptyText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  // Upcoming Reviews, the website's forecast widget: a day list, or one day's
  // hour-by-hour breakdown when `day` is set. Each row is
  // label | bar | +delta | cumulative | (chevron on the day list).
  component UpcomingRows: Column {
    id: rows
    property var day: null
    signal drillInto(int index)

    readonly property bool isWeek: day === null || day === undefined
    readonly property var model: isWeek ? wk.upcoming : (day.hours || [])
    readonly property real peak: {
      var maximum = 1
      for (var i = 0; i < model.length; i++)
        if (Number(model[i].count) > maximum) maximum = Number(model[i].count)
      return maximum
    }

    spacing: Style.space(3)
    visible: wk.dashboardLoaded && model.length > 0

    Repeater {
      model: rows.model
      delegate: Item {
        id: rowItem
        width: rows.width
        height: Style.space(19)
        readonly property int count: Number(modelData.count) || 0
        readonly property bool clickable: rows.isWeek && count > 0
        readonly property bool cursored: rows.isWeek && root.hasCursor("upcoming", index)
        onCursoredChanged: if (cursored) root.setCursorItem(rowItem)

        Rectangle {
          anchors.fill: parent
          anchors.leftMargin: -Style.space(4)
          anchors.rightMargin: -Style.space(4)
          radius: Style.cornerRadius
          color: rowItem.cursored
            ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
            : (hover.containsMouse && rowItem.clickable
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              : "transparent")
          Behavior on color { ColorAnimation { duration: 60 } }
        }

        RowLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          Text {
            text: String(modelData.label || "")
            color: root.foreground
            opacity: 0.85
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.preferredWidth: Style.space(rows.isWeek ? 30 : 42)
          }

          Item {
            Layout.fillWidth: true
            implicitHeight: Style.space(10)
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              radius: 2
              width: rowItem.count > 0
                ? Math.max(3, parent.width * (rowItem.count / rows.peak))
                : 0
              color: root.forecastColor
              opacity: 0.95
            }
          }

          Text {
            text: rowItem.count > 0 ? "+" + rowItem.count : ""
            color: root.forecastColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: Style.space(32)
          }

          Text {
            text: String(modelData.cumulative)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: Style.space(34)
          }

          Text {
            visible: rows.isWeek
            text: "󰅂"
            color: rowItem.clickable
              ? root.dim
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: rowItem.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
          onContainsMouseChanged: if (containsMouse && rows.isWeek) root.setCursor("upcoming", index)
          onClicked: if (rowItem.clickable) rows.drillInto(index)
        }
      }
    }
  }
}
