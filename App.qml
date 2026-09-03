import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The full OmaKani app: subject browser, lessons and reviews done in-shell.
// A `panel`-kind plugin, mounted by the shell and summoned with
//   omarchy-shell -q shell toggle io.github.aphelion-studios.omakani
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
    ? String(manifest.id) : "io.github.aphelion-studios.omakani"

  readonly property color bg: Color.background
  readonly property color fg: Color.foreground
  readonly property color accent: Color.accent
  readonly property bool lightUi: Model.lightBg(Color.background)
  readonly property string fontFamily: Style.font.family
  // WaniKani's web app sets subject characters in "Noto Sans JP" (the Google
  // webfont). Use it when the user has installed it; otherwise fall back to
  // "Noto Sans CJK JP", the same Source Han Sans design shipped with the OS.
  readonly property string jpFamily: Qt.fontFamilies().indexOf("Noto Sans JP") >= 0
    ? "Noto Sans JP" : "Noto Sans CJK JP"

  readonly property bool startLessons: !!service && service.configured
    && !service.vacation && service.lessonsNow > 0
  readonly property bool startReviews: !!service && service.configured
    && !service.vacation && service.reviewsNow > 0

  // ---- home screen keyboard nav --------------------------------------
  // laid out in rows: [Lessons | Reviews], then [Level Progress], then one
  // Extra Study row each. j/k step rows (h/l step columns); a disabled item
  // (zero count) can't be focused or activated, and j/k skips its whole row
  // if nothing in it is reachable. `count` -1 means "no pill".
  property int homeIndex: 0
  readonly property var homeActions: {
    var out = []
    if (!service || !service.configured) return out
    var ok = !service.vacation
    var ln = service.lessonsNow, rn = service.reviewsNow
    out.push({ text: "Lessons", act: "lesson", kind: "primary", row: 0, col: 0,
               count: ln, enabled: ok && ln > 0 })
    out.push({ text: "Reviews", act: "review", kind: "primary", row: 0, col: 1,
               count: rn, enabled: ok && rn > 0 })
    out.push({ text: "Level Progress", act: "browse", kind: "wide", row: 1, col: 0,
               count: -1, enabled: true })
    var es = service.extraStudy || ({})
    var rl = Number(es.recentLessons) || 0
    var rm = Number(es.recentMistakes) || 0
    var bi = Number(es.burnedItems) || 0
    out.push({ text: "Recent Lessons",  act: "es:recent-lessons", kind: "extra",
               row: 2, col: 0, glyph: "󰌵", count: rl, enabled: rl > 0 })
    out.push({ text: "Recent Mistakes", act: "es:mistakes", kind: "extra",
               row: 3, col: 0, glyph: "󰀦", count: rm, enabled: rm > 0 })
    out.push({ text: "Burned Items",    act: "es:burned", kind: "extra",
               row: 4, col: 0, glyph: "󰈸", count: bi, enabled: bi > 0 })
    return out
  }
  readonly property var homePrimary: homeActions.filter(function (a) { return a.kind === "primary" })
  readonly property var homeWide: homeActions.filter(function (a) { return a.kind === "wide" })
  readonly property var homeExtra: homeActions.filter(function (a) { return a.kind === "extra" })
  readonly property int _homeRows: {
    var m = 0
    for (var i = 0; i < homeActions.length; i++) m = Math.max(m, homeActions[i].row)
    return homeActions.length > 0 ? m + 1 : 0
  }
  function _homeAt(row, col) {
    for (var i = 0; i < homeActions.length; i++)
      if (homeActions[i].row === row && homeActions[i].col === col) return i
    return -1
  }
  // flat index of a reachable action in `row`, preferring column `want`
  function _homeRowPick(row, want) {
    var p = _homeAt(row, want)
    if (p >= 0 && homeActions[p].enabled !== false) return p
    for (var c = 0; c < 4; c++) {
      var i = _homeAt(row, c)
      if (i >= 0 && homeActions[i].enabled !== false) return i
    }
    return -1
  }
  function homeMoveV(dir) {
    if (homeActions.length === 0) return
    var cur = Math.max(0, Math.min(homeIndex, homeActions.length - 1))
    var r = homeActions[cur].row, c = homeActions[cur].col
    for (var step = 0; step < _homeRows; step++) {
      r = (r + dir + _homeRows) % _homeRows
      var t = _homeRowPick(r, r === 0 ? 1 : c)   // reviews-first on the top row
      if (t >= 0) { homeIndex = t; return }
    }
  }
  function homeMoveH(dir) {
    if (homeActions.length === 0) return
    var cur = Math.max(0, Math.min(homeIndex, homeActions.length - 1))
    var r = homeActions[cur].row, c = homeActions[cur].col + dir
    while (true) {
      var i = _homeAt(r, c)
      if (i < 0) return
      if (homeActions[i].enabled !== false) { homeIndex = i; return }
      c += dir
    }
  }
  function homeEnsureValid() {
    var n = homeActions.length
    if (n === 0) { homeIndex = 0; return }
    if (homeIndex < n && homeActions[homeIndex] && homeActions[homeIndex].enabled !== false) return
    for (var i = 0; i < n; i++)
      if (homeActions[i] && homeActions[i].enabled !== false) { homeIndex = i; return }
    homeIndex = 0
  }
  // land on Reviews whenever any are due -- the WaniKani habit is to clear
  // reviews before touching lessons. Otherwise the first actionable thing.
  function homeDefault() {
    for (var i = 0; i < homeActions.length; i++)
      if (homeActions[i].act === "review" && homeActions[i].enabled !== false) {
        homeIndex = i; return
      }
    homeEnsureValid()
  }
  onHomeActionsChanged: Qt.callLater(homeEnsureValid)
  function homeActivate() {
    var a = homeActions[Math.max(0, Math.min(homeIndex, homeActions.length - 1))]
    if (!a || a.enabled === false) return
    if (a.act === "lesson") goLesson()
    else if (a.act === "review") goReview()
    else if (a.act === "browse") goBrowse(service ? (service.level || 1) : 1)
    else if (a.act.indexOf("es:") === 0) openSessionMode(a.act.substring(3))
  }

  // Website type colours (vivid variants, tuned against the dark app ground).
  readonly property color radicalColor: "#0098e6"
  readonly property color kanjiColor: "#fc02a9"
  readonly property color vocabColor: "#a802fd"

  // ---- navigation stack -------------------------------------------------
  // Each entry: { view: "home" | "browse" | "subject", level, id }
  property var navStack: [{ view: "home" }]
  readonly property var currentPage: navStack.length > 0
    ? navStack[navStack.length - 1] : ({ view: "home" })
  readonly property string view: String(currentPage.view || "home")

  // Route keyboard focus to whichever view is showing (each owns its keys).
  onViewChanged: Qt.callLater(applyFocus)
  function applyFocus() {
    if (!opened) return
    if (view === "home") homeDefault()
    if (view === "browse") levelBrowser.focusGrid()
    else if (view === "subject") subjectPage.focusPage()
    else if (view === "settings") settingsPage.focusPage()
    else if (view === "quiz") quizCard.forceActiveFocus()
    else if (view === "session") quizSession.forceActiveFocus()
    else if (view === "review") reviewEngine.forceActiveFocus()
    else if (view === "lesson") lessonFlow.forceActiveFocus()
    else {
      // home -- a just-hidden child view can still be holding focus for a few
      // frames; homeScope is a real sibling FocusScope so forcing focus onto
      // it actually moves the shell's sub-focus pointer, and homePoke keeps
      // re-grabbing until it sticks
      homeScope.forceActiveFocus()
      homePoke.kick()
    }
  }

  function pushPage(page) {
    var next = navStack.slice()
    next.push(page)
    navStack = next
  }

  function popPage() {
    if (navStack.length <= 1) return
    navStack = navStack.slice(0, navStack.length - 1)
  }

  // leave the current view: step back if there's somewhere to step back to,
  // otherwise land on the home menu. A flow summoned straight from the
  // dashboard has no page under it -- finishing or wrapping it out should
  // drop to the menu (where you can re-enter the remaining reviews), not
  // slam the window shut. Esc from the menu itself still closes the app.
  function leave() {
    if (navStack.length > 1) popPage()
    else navStack = [{ view: "home" }]
  }

  function resetNav() {
    navStack = [{ view: "home" }]
  }

  // the level the browser is showing -- held here (not derived from the nav
  // stack) so it doesn't snap to 1 while you're on a subject page, which would
  // reset the browser's chip cursor
  property int browseLevel: 1
  function goSettings() { pushPage({ view: "settings" }) }

  function goBrowse(level) {
    var n = Math.max(1, Math.min(60, parseInt(String(level), 10) || 1))
    root.browseLevel = n
    pushPage({ view: "browse", level: n })
    levelBrowser.enterFresh()   // top of the level, even when re-entering it
    if (root.service) {
      root.service.clearSearch()   // a fresh entry starts on the level view
      root.service.loadBrowse(n)
    }
  }

  function goSubject(id) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    pushPage({ view: "subject", id: n })
    if (root.service) root.service.loadDetail([n])
  }

  // best-effort type name for the "Loading …" line -- from whatever's cached
  // (a resolved detail record) or the last-loaded level's rows
  function subjectKindLabel(id) {
    var n = Number(id)
    var obj = ""
    if (service) {
      var d = service.subjectDetail(n)
      if (d && d.object) obj = String(d.object)
      else {
        var rows = (service.browseData && service.browseData.subjects) || []
        for (var i = 0; i < rows.length; i++)
          if (Number(rows[i].id) === n) { obj = String(rows[i].object || ""); break }
      }
    }
    if (obj === "radical") return "radical"
    if (obj === "kanji") return "kanji"
    if (obj === "vocabulary" || obj === "kana_vocabulary") return "vocabulary"
    return "subject"
  }

  // primary meaning for the breadcrumb ("OmaKani | Stamp"). Detail record
  // first, then the last-loaded level's slim rows, then a plain fallback.
  function subjectName(id) {
    var n = Number(id)
    if (service) {
      var d = service.subjectDetail(n)
      var ms = d && d.data ? (d.data.meanings || []) : []
      for (var i = 0; i < ms.length; i++)
        if (ms[i].primary) return ms[i].meaning
      if (ms.length) return ms[0].meaning
      var rows = (service.browseData && service.browseData.subjects) || []
      for (var j = 0; j < rows.length; j++)
        if (Number(rows[j].id) === n && rows[j].meaning) return String(rows[j].meaning)
    }
    return "Subject"
  }

  // [ / ] on a subject page: walk the level's items in order. Replaces the
  // current nav entry (rather than pushing) so Back still lands on the level,
  // not on every item you stepped through. No-op if this subject isn't in the
  // last-loaded level (e.g. you drilled here via a chip from another level).
  function stepSubjectInLevel(dir) {
    if (root.view !== "subject" || !service) return
    var rows = (service.browseData && service.browseData.subjects) || []
    if (!rows.length) return
    var curId = Number(root.currentPage.id)
    var idx = -1
    for (var i = 0; i < rows.length; i++)
      if (Number(rows[i].id) === curId) { idx = i; break }
    if (idx < 0) return
    var ni = idx + (dir > 0 ? 1 : -1)
    if (ni < 0 || ni >= rows.length) return
    var nextId = Number(rows[ni].id)
    var stack = navStack.slice()
    stack[stack.length - 1] = { view: "subject", id: nextId }
    navStack = stack
    service.loadDetail([nextId])
  }

  // A single-prompt quiz for one subject -- the primitive the lesson flow
  // and review engine drive. `type` is "meaning" | "reading".
  function goQuiz(id, type) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    pushPage({ view: "quiz", id: n, quizType: type === "reading" ? "reading" : "meaning" })
    if (root.service) root.service.loadDetail([n])
  }

  // An Extra Study session over a batch of subjects (no server sync).
  property var sessionIds: []
  property string sessionTitle: "Extra Study"
  function goSession(ids, title) {
    root.sessionIds = (Array.isArray(ids) ? ids : []).slice(0, 100)
    root.sessionTitle = title || "Extra Study"
    quizSession.rearm()   // drop any stale summary/empty screen from a past run
    pushPage({ view: "session" })
    Qt.callLater(function () { quizSession.start() })
  }

  // The review session -- POSTs to /reviews (guarded by the dry-run start
  // screen). Pulls the due queue from the helper first.
  property var reviewIds: []
  function goReview() {
    reviewEngine.rearm()   // drop a stale summary/error screen until begin() rebuilds
    pushPage({ view: "review" })
    if (service) service.loadReviews()
  }

  // The lesson batch -- POSTs /assignments/{id}/start (dry-run guarded).
  property var lessonIds: []
  property int lessonTotal: 0
  function goLesson() {
    lessonFlow.rearm()   // drop a stale summary/error screen until begin() rebuilds
    pushPage({ view: "lesson" })
    if (service) service.loadLessons(lessonBatchSize())
  }
  function lessonBatchSize() {
    var n = parseInt(String(setting("lessonBatchSize", 5)), 10)
    return (isFinite(n) && n > 0) ? Math.min(n, 20) : 5
  }
  function setting(name, fallback) {
    var v = root.service ? root.service.setting(name, fallback) : fallback
    return v === undefined || v === null ? fallback : v
  }

  Connections {
    target: root.service
    enabled: root.service !== null
    function onReviewsReady(ids) {
      if (root.view !== "review") return
      // a late second reviewsReady (a background refresh, a re-summon) must not
      // rebuild a session that's already past its start screen
      if (reviewEngine.phase !== "loading") return
      root.reviewIds = ids || []
      Qt.callLater(function () { reviewEngine.begin() })
    }
    function onLessonsReady(ids, total) {
      if (root.view !== "lesson") return
      if (lessonFlow.phase !== "loading") return
      if (lessonFlow.doneIds.length > 0) {
        // continuing an in-progress sitting: feed the next batch, minus
        // whatever's already been learned this session
        var done = lessonFlow.doneIds
        var fresh = (ids || []).filter(function (x) { return done.indexOf(Number(x)) < 0 })
        var next = fresh.slice(0, lessonFlow.batchSize())
        Qt.callLater(function () {
          if (next.length === 0) lessonFlow.phase = "summary"
          else lessonFlow.continueBatch(next)
        })
        return
      }
      root.lessonIds = ids || []
      root.lessonTotal = total || 0
      Qt.callLater(function () { lessonFlow.begin() })
    }
  }

  // (linked-subject hydration lives in SubjectPage now -- it self-fetches
  // component / amalgamation detail so the chips resolve everywhere)

  function open(payloadJson) {
    closingFromHost = false
    opened = true
    resetNav()
    if (service) service.refreshAll()

    // a summon payload routes straight to a view (the dashboard's Start
    // Reviews / Lessons / Extra Study / a chip). A home page stays under it
    // so Esc from that flow backs out to the menu; a second Esc closes.
    var payload = null
    try { payload = payloadJson ? JSON.parse(payloadJson) : null } catch (e) { payload = null }
    if (payload && (payload.session || payload.review || payload.lesson
        || payload.subject || payload.browse)) {
      Qt.callLater(function () {
        root.navStack = [{ view: "home" }]
        if (payload.subject) root.goSubject(Number(payload.subject))
        else if (payload.browse) {
          levelBrowser.pendingSection = payload.focus ? String(payload.focus) : ""
          root.goBrowse(Number(payload.browse))
        }
        else if (payload.session) root.openSessionMode(String(payload.session))
        else if (payload.review) root.goReview()
        else root.goLesson()
      })
    } else {
      Qt.callLater(applyFocus)
    }
  }

  function openSessionMode(which) {
    var dash = service ? service.extraStudy : ({})
    if (which === "burned") goSession(dash.burnedItemIds || [], "Burned Items")
    else if (which === "mistakes") goSession(dash.recentMistakeIds || [], "Recent Mistakes")
    else goSession(dash.recentLessonIds || [], "Recent Lessons")
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

  // Lets keybinds (and debugging) drive the app straight to a view:
  //   omarchy-shell -q io.github.aphelion-studios.omakani.app browse 7
  //   omarchy-shell -q io.github.aphelion-studios.omakani.app subject 440
  IpcHandler {
    target: "io.github.aphelion-studios.omakani.app"

    function home(): void { root.open(""); root.resetNav() }
    function settings(): void { root.open(""); root.resetNav(); root.goSettings() }
    function browse(level: string): void {
      root.open("")
      root.resetNav()
      root.goBrowse(parseInt(level, 10) || (root.service ? root.service.level : 1))
    }
    // Level Progress for the current level, optionally landing on a section's
    // first chip: focus = "radical" | "kanji" | "vocabulary" (or "").
    function levelprogress(focus: string): void {
      root.open("")
      root.resetNav()
      levelBrowser.pendingSection = (focus && focus !== "") ? focus : ""
      root.goBrowse(root.service ? root.service.level : 1)
    }
    function subject(id: string): void {
      root.open("")
      root.resetNav()
      root.goSubject(parseInt(id, 10))
    }
    // testing: open a subject the way a chip click does -- keep the current
    // stack (home -> browse -> subject) instead of resetting
    function pick(id: string): void { root.goSubject(parseInt(id, 10)) }
    function quiz(id: string, type: string): void {
      root.open("")
      root.resetNav()
      root.goQuiz(parseInt(id, 10), type)
    }
    function qanswer(text: string): string {
      var c = root.view === "quiz" ? quizCard
        : root.view === "session" ? quizSession.cardItem
        : root.view === "review" ? reviewEngine.cardItem
        : root.view === "lesson" ? lessonFlow.cardItem : null
      if (!c) return "not in a quiz"
      c.typeAndSubmit(text)
      var tail = ""
      if (root.view === "session")
        tail = "  [" + quizSession.phase + " " + quizSession.clearedQuestions
          + "/" + quizSession.totalQuestions + "]"
      else if (root.view === "review")
        tail = "  [" + reviewEngine.phase + " submitted " + reviewEngine.submittedCount
          + "/" + reviewEngine.totalSubjects + (reviewEngine.dryRun ? " DRY" : " LIVE") + "]"
      return c.phase + (c.nudge ? " (" + c.nudge + ")" : "") + tail
    }
    function rstart(): string {
      if (root.view !== "review") return "not in review"
      reviewEngine.startRun()
      return reviewEngine.phase
    }
    // testing the wrap-out / re-enter path
    function rwrap(): string {
      if (root.view !== "review") return "not in review"
      reviewEngine.phase = "summary"
      return reviewEngine.phase
    }
    function rphase(): string { return reviewEngine.phase }
    // simulate the home-screen Enter on the focused action
    function henter(): string {
      if (root.view !== "home") return "not home"
      root.homeActivate()
      return "view=" + root.view + " depth=" + root.navStack.length
    }
    function hidx(n: string): string { root.homeIndex = parseInt(n, 10) || 0; return String(root.homeIndex) }
    function goreview2(): string { root.goReview(); return "view=" + root.view + " depth=" + root.navStack.length + " phase=" + reviewEngine.phase }
    function eexit(): string { reviewEngine.exit(); return "depth=" + root.navStack.length + " opened=" + root.opened }
    function rtool(what: string): string {
      var c = root.view === "review" ? reviewEngine.cardItem : null
      if (!c) return "not in review"
      var ip = c.infoPageItem
      if (what === "drill") {
        var comp = (ip && ip.subject && ip.subject.data
          && (ip.subject.data.component_subject_ids || [])[0]) || 0
        if (ip && comp) ip.navigate(comp)
        return "drilled to " + comp
      }
      else if (what === "back") { if (ip) ip.closeRequested() }
      else if (what === "down") { if (ip) ip.moveFocus(1) }
      else if (what === "up") { if (ip) ip.moveFocus(-1) }
      else if (what === "chipnext") { if (ip) ip.moveChip(1) }
      else if (what === "chipprev") { if (ip) ip.moveChip(-1) }
      else if (what === "enter") { if (ip) ip.activateFocused() }
      return "phase=" + c.phase + " chipIndex=" + (ip ? ip.chipIndex : "?")
        + " focusedKey=" + (ip ? ip.focusedKey : "?")
        + " subj=" + (ip && ip.subject ? ip.subject.id : "?")
    }
    function rinfo(): string {
      var c = root.view === "review" ? reviewEngine.cardItem
        : root.view === "lesson" ? lessonFlow.cardItem : null
      if (!c) return "no card"
      c.infoOpen = !c.infoOpen
      var ip = c.infoPageItem
      return "type=" + c.effectiveType + " restrict=" + c.restrictInfo
        + " mDone=" + c.meaningDone + " rDone=" + c.readingDone
        + " infoOpen=" + c.infoOpen + " phase=" + c.phase
        + (ip ? " focusSection=" + ip.focusSection + " focusIndex=" + ip.focusIndex
            + " focusedKey=" + ip.focusedKey
            + " nav=" + ip.visibleNav().map(function (x) { return x.navKey }).join(",")
          : "")
    }
    // testing: toggle the ✓ Last Answers / ひ Kana Chart overlays
    function rover(what: string): string {
      var c = root.view === "review" ? reviewEngine.cardItem
        : root.view === "session" ? quizSession.cardItem
        : root.view === "lesson" ? lessonFlow.cardItem : null
      if (!c) return "no card"
      if (what === "last") c.lastOpen ? c.closeOverlays() : c.openLast()
      else if (what === "kana") c.kanaOpen ? c.closeOverlays() : c.openKana()
      else c.closeOverlays()
      return "lastOpen=" + c.lastOpen + " kanaOpen=" + c.kanaOpen
        + " log=" + (c.answerLog ? c.answerLog.length : 0)
    }
    // testing: a Kana Chart keypress ("<>" for backspace)
    function kkey(s: string): string {
      var c = root.view === "review" ? reviewEngine.cardItem
        : root.view === "session" ? quizSession.cardItem
        : root.view === "lesson" ? lessonFlow.cardItem : null
      if (!c) return "no card"
      if (s === "<>") c.kanaBackspace()
      else c.insertKana(s)
      return c.fieldText
    }
    function lstep(what: string): string {
      if (root.view !== "lesson") return "not in lesson"
      if (what === "begin") lessonFlow.startInfo()
      else if (what === "next") lessonFlow.infoNext()
      else if (what === "prev") lessonFlow.infoPrev()
      return lessonFlow.phase + " info=" + lessonFlow.infoIndex + "/" + lessonFlow.ids.length
        + " started=" + lessonFlow.startedCount
    }
    function rcur(): string {
      var c = root.view === "review" ? reviewEngine.cardItem
        : root.view === "lesson" ? lessonFlow.cardItem
        : root.view === "session" ? quizSession.cardItem
        : root.view === "quiz" ? quizCard : null
      var s = c ? c.subject : null
      if (!s) return "none"
      var d = s.data || ({})
      return JSON.stringify({
        id: s.id,
        type: c.questionType,
        chars: d.characters || "",
        meanings: (d.meanings || []).map(function (m) { return m.meaning }),
        readings: (d.readings || []).filter(function (r) { return r.accepted_answer !== false })
          .map(function (r) { return r.reading })
      })
    }
    // extra-study session over the dashboard's recent-lessons / burned batch
    function session(which: string): void {
      root.open("")
      root.resetNav()
      root.openSessionMode(String(which || "recent-lessons"))
    }
    function review(): void {
      root.open("")
      root.resetNav()
      root.goReview()
    }
    function lesson(): void {
      root.open("")
      root.resetNav()
      root.goLesson()
    }
    // testing: run the lesson flow over an explicit id list (0 real lessons)
    function lessonTest(idsCsv: string): void {
      root.open("")
      root.resetNav()
      var ids = String(idsCsv || "").split(",")
        .map(function (x) { return parseInt(x.trim(), 10) })
        .filter(function (x) { return isFinite(x) })
      root.lessonIds = ids
      root.lessonTotal = ids.length
      root.pushPage({ view: "lesson" })
      Qt.callLater(function () { lessonFlow.begin() })
    }
    function state(): string {
      return JSON.stringify({
        opened: root.opened,
        view: root.view,
        stackDepth: root.navStack.length,
        page: root.currentPage,
        detailError: root.service ? root.service.detailError : "",
        browseError: root.service ? root.service.browseError : "",
        browseCursor: levelBrowser.cursor,
        browseRows: levelBrowser.rows.length,
        browseKeyFocus: levelBrowser.hasKeyFocus,
        subjectHasSubject: !!subjectPage.subject,
        subjectKeyFocus: subjectPage.hasKeyFocus,
        subjectFocusIndex: subjectPage.focusIndex,
        enginePhase: reviewEngine.phase,
        homeIndex: root.homeIndex,
        homeActions: root.homeActions.map(function (a) { return a.act })
      })
    }
  }


  FloatingWindow {
    id: window
    visible: root.opened
    title: "OmaKani"
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
      Keys.onEscapePressed: {
        if (root.navStack.length > 1) root.popPage()
        else root.requestClose()
      }
      Keys.onPressed: function (e) {
        // fallback for the home screen only (homeScope owns it normally)
        if (root.view !== "home") return
        if (e.key === Qt.Key_Down || e.text === "j") { root.homeMoveV(1); e.accepted = true }
        else if (e.key === Qt.Key_Up || e.text === "k") { root.homeMoveV(-1); e.accepted = true }
        else if (e.key === Qt.Key_Right || e.text === "l") { root.homeMoveH(1); e.accepted = true }
        else if (e.key === Qt.Key_Left || e.text === "h") { root.homeMoveH(-1); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          root.homeActivate(); e.accepted = true
        }
      }

      // ---- top strip: back + breadcrumb ----
      Item {
        id: topStrip
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(44)
        z: 2

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          visible: root.navStack.length > 1
          text: "‹ Back"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            cursorShape: Qt.PointingHandCursor
            onClicked: root.popPage()
          }
        }

        // breadcrumb -- centred in the strip in every view
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (root.view === "browse") return "OmaKani  |  Level " + root.currentPage.level
            if (root.view === "subject") return "OmaKani  |  " + root.subjectName(root.currentPage.id)
            if (root.view === "review") return "OmaKani  |  Reviews"
            if (root.view === "lesson") return "OmaKani  |  Lessons"
            if (root.view === "session") return "OmaKani  |  " + root.sessionTitle
            if (root.view === "settings") return "OmaKani  |  Settings"
            return "OmaKani"
          }
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          text: "Esc to " + (root.navStack.length > 1 ? "go back" : "close")
          color: Qt.darker(root.fg, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- page area ----
      Item {
        id: pageArea
        anchors.top: topStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        // -------------------------------------------------- HOME
        // its own FocusScope, a sibling of every other view, so applyFocus()
        // can pull the shell's sub-focus pointer off a view that just went
        // invisible (a plain focusScope.forceActiveFocus() re-delegated right
        // back into the hidden view, leaving the menu's Enter/Esc dead)
        FocusScope {
          id: homeScope
          anchors.fill: parent
          visible: root.view === "home"
          Keys.enabled: root.view === "home"
          Keys.onPressed: function (e) {
            if (e.key === Qt.Key_Down || e.text === "j") {
              root.homeMoveV(1); e.accepted = true
            } else if (e.key === Qt.Key_Up || e.text === "k") {
              root.homeMoveV(-1); e.accepted = true
            } else if (e.key === Qt.Key_Right || e.text === "l") {
              root.homeMoveH(1); e.accepted = true
            } else if (e.key === Qt.Key_Left || e.text === "h") {
              root.homeMoveH(-1); e.accepted = true
            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
              root.homeActivate(); e.accepted = true
            } else if (e.text === "," || e.text === "s") {
              root.goSettings(); e.accepted = true
            } else if (e.text === "?") {
              homeHotkeys.toggle(); e.accepted = true
            }
          }
          Keys.onEscapePressed: {
            if (homeHotkeys.open) { homeHotkeys.close(); return }
            if (root.navStack.length > 1) root.popPage()
            else root.requestClose()
          }

          // keep re-grabbing until it takes -- a view that just went invisible
          // can hold focus for a few frames while its teardown settles
          Timer {
            id: homePoke
            interval: 16
            repeat: true
            property int ticks: 0
            function kick() { ticks = 0; restart() }
            onTriggered: {
              ticks += 1
              if (root.view === "home") homeScope.forceActiveFocus()
              if (ticks >= 12 || root.view !== "home" || homeScope.activeFocus) {
                stop(); ticks = 0
              }
            }
          }

        Column {
          id: homeCol
          visible: root.view === "home"
          anchors.centerIn: parent
          spacing: Style.space(14)
          // one column width drives the button pair, Level Progress and the
          // Extra Study rows so their edges line up
          readonly property real colW: Math.min(parent.width - Style.space(80), Style.space(360))
          readonly property real gap: Style.space(10)
          width: colW

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: Qt.resolvedUrl("wordmark.svg")
            height: Style.space(58)
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 1893
            smooth: true
            mipmap: true
            width: Math.min(implicitWidth, parent.width)
          }

          // greeting -- ようこそ、<name>！  /  Level N
          Column {
            width: parent.width
            spacing: Style.space(2)
            bottomPadding: Style.space(6)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: Qt.darker(root.fg, 1.4)
              font.family: root.jpFamily
              font.pixelSize: Style.font.body
              text: {
                if (!root.service) return "Connecting to the service…"
                if (!root.service.configured) return "Add your API token from the bar widget first."
                return "ようこそ、" + root.service.username + "！"
              }
            }
            Text {
              visible: !!root.service && root.service.configured
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              color: Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: root.service ? ("Level " + root.service.level) : ""
            }
          }

          // ---- Lessons / Reviews (side by side) ----
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: homeCol.gap
            visible: !!root.service && root.service.configured

            Repeater {
              model: root.homePrimary
              delegate: Rectangle {
                id: homeBtn
                readonly property int gIndex: index
                readonly property bool on: modelData.enabled !== false
                readonly property bool current: gIndex === root.homeIndex && on
                readonly property bool lit: current || (homeHover.containsMouse && on)
                // dark theme: the accent. light theme: WK's kanji-pink for
                // Lessons, radical-blue for Reviews.
                readonly property color fillColor: root.lightUi
                  ? (modelData.act === "lesson" ? "#fc02a9" : "#0098e6")
                  : root.accent
                readonly property color btnInk: root.lightUi ? "#fcfdfd" : root.bg
                width: (homeCol.colW - homeCol.gap) / 2
                height: Style.space(44)
                radius: Style.space(6)
                clip: true
                opacity: on ? 1.0 : 0.4
                color: lit ? Qt.lighter(fillColor, 1.3) : fillColor
                border.width: lit ? 3 : 0
                border.color: root.lightUi ? Qt.rgba(0, 0, 0, 0.3) : "#fcfdfd"
                Behavior on color { ColorAnimation { duration: 110 } }

                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: Qt.lighter(homeBtn.fillColor, 1.35)
                  visible: homeBtn.on && !homeBtn.lit
                  opacity: 0
                  SequentialAnimation on opacity {
                    running: homeBtn.on && homeBtn.visible && !homeBtn.lit
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.0; to: 0.35; duration: 950; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.35; to: 0.0; duration: 950; easing.type: Easing.InOutSine }
                  }
                }

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.text
                    color: homeBtn.btnInk
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  // count pill (white, like the website)
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(height, cnt.implicitWidth + Style.space(12))
                    height: Style.space(20)
                    radius: height / 2
                    color: "#fcfdfd"
                    // hairline so the white pill keeps an edge on a light card
                    border.width: 1
                    border.color: Qt.rgba(0, 0, 0, 0.12)
                    Text {
                      id: cnt
                      anchors.centerIn: parent
                      text: modelData.count
                      color: root.lightUi ? homeBtn.fillColor : root.bg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
                MouseArea {
                  id: homeHover
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: homeBtn.on
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.homeIndex = homeBtn.gIndex
                  onClicked: { root.homeIndex = homeBtn.gIndex; root.homeActivate() }
                }
              }
            }
          }

          // ---- Level Progress (full column width) ----
          Repeater {
            model: root.homeWide
            delegate: Rectangle {
              id: wideBtn
              anchors.horizontalCenter: parent.horizontalCenter
              readonly property int gIndex: root.homePrimary.length + index
              readonly property bool lit: gIndex === root.homeIndex || wideHover.containsMouse
              width: homeCol.colW
              height: Style.space(40)
              radius: Style.space(6)
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, lit ? 0.16 : 0.08)
              border.width: lit ? 2 : 1
              border.color: lit ? root.fg
                : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)
              Behavior on color { ColorAnimation { duration: 110 } }
              Text {
                anchors.centerIn: parent
                text: modelData.text
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                id: wideHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.homeIndex = wideBtn.gIndex
                onClicked: { root.homeIndex = wideBtn.gIndex; root.homeActivate() }
              }
            }
          }

          // ---- Extra Study ----
          Column {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            spacing: Style.space(6)
            topPadding: Style.space(8)
            visible: !!root.service && root.service.configured

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "EXTRA STUDY"
              color: Qt.darker(root.fg, 1.9)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.homeExtra
              delegate: Rectangle {
                id: esRow
                anchors.horizontalCenter: parent.horizontalCenter
                readonly property int gIndex: root.homePrimary.length + root.homeWide.length + index
                readonly property bool on: modelData.enabled !== false
                readonly property bool lit: (gIndex === root.homeIndex || esHover.containsMouse) && on
                width: homeCol.colW
                height: Style.space(38)
                radius: Style.space(6)
                opacity: on ? 1.0 : 0.4
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, lit ? 0.14 : 0.06)
                border.width: lit ? 2 : 1
                border.color: lit ? root.fg
                  : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
                Behavior on color { ColorAnimation { duration: 110 } }

                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(13)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(9)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.glyph
                    color: Qt.darker(root.fg, 1.25)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.text
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                // count pill (outline, like the website)
                Rectangle {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(height, esCnt.implicitWidth + Style.space(12))
                  height: Style.space(19)
                  radius: height / 2
                  color: "transparent"
                  border.width: 1
                  border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
                  Text {
                    id: esCnt
                    anchors.centerIn: parent
                    text: modelData.count
                    color: Qt.darker(root.fg, 1.15)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
                MouseArea {
                  id: esHover
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: esRow.on
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.homeIndex = esRow.gIndex
                  onClicked: { root.homeIndex = esRow.gIndex; root.homeActivate() }
                }
              }
            }
          }

        }

        // ? hotkeys + settings gear, bottom-right of the home screen
        HotkeysOverlay {
          id: homeHotkeys
          anchors.fill: parent
          fg: root.fg
          pageBg: root.bg
          fontFamily: root.fontFamily
          title: "Keys"
          extraButton: ({ glyph: "󰒓" })
          onExtraClicked: root.goSettings()
          rows: [
            { k: "j k", d: "Move between rows" },
            { k: "h l", d: "Lessons / Reviews" },
            { k: "↵", d: "Open" },
            { k: "s", d: "Settings" },
            { k: "Esc", d: "Close the window" },
            { k: "?", d: "Toggle this menu" }
          ]
        }
        }   // homeScope

        // -------------------------------------------------- BROWSE
        LevelBrowser {
          id: levelBrowser
          visible: root.view === "browse"
          anchors.fill: parent
          service: root.service
          level: root.browseLevel
          fg: root.fg
          pageBg: root.bg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onOpenSubject: function (subjectId) { root.goSubject(subjectId) }
          onChangeLevel: function (newLevel) {
            root.browseLevel = newLevel
            var next = root.navStack.slice()
            next[next.length - 1] = { view: "browse", level: newLevel }
            root.navStack = next
            if (root.service) root.service.loadBrowse(newLevel)
          }
          onVisibleChanged: if (visible) Qt.callLater(function () { if (levelBrowser.visible) levelBrowser.focusGrid() })
        }

        // -------------------------------------------------- SETTINGS
        SettingsPage {
          id: settingsPage
          visible: root.view === "settings"
          anchors.fill: parent
          service: root.service
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          onCloseRequested: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (settingsPage.visible) settingsPage.focusPage() })
        }

        // -------------------------------------------------- SUBJECT
        SubjectPage {
          id: subjectPage
          visible: root.view === "subject"
          anchors.fill: parent
          service: root.service
          subject: (root.view === "subject" && root.service)
            ? root.service.subjectDetail(root.currentPage.id) : null
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          keyNav: true          // j/k sections, h/l chips, Enter, Esc
          onNavigate: function (subjectId) { root.goSubject(subjectId) }
          onStepSubject: function (dir) { root.stepSubjectInLevel(dir) }
          onCloseRequested: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (subjectPage.visible) subjectPage.focusPage() })
        }

        // loading / empty state for the subject page
        Text {
          anchors.centerIn: parent
          visible: root.view === "subject" && !subjectPage.subject
          text: (root.service && root.service.detailError)
            ? root.service.detailError
            : "Loading " + root.subjectKindLabel(root.currentPage.id) + "…"
          color: Qt.rgba(1, 1, 1, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // -------------------------------------------------- QUIZ (primitive)
        QuizCard {
          id: quizCard
          visible: root.view === "quiz"
          anchors.fill: parent
          service: root.service
          subject: (root.view === "quiz" && root.service)
            ? root.service.subjectDetail(root.currentPage.id) : null
          studyMaterial: subject && subject.study_material ? subject.study_material : null
          questionType: root.view === "quiz" ? root.currentPage.quizType : "meaning"
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onAdvance: root.popPage()
          onWrapUp: root.popPage()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (quizCard.visible) quizCard.forceActiveFocus() })
        }

        Text {
          anchors.centerIn: parent
          visible: root.view === "quiz" && !quizCard.subject
          text: (root.service && root.service.detailError)
            ? root.service.detailError : "Loading…"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // -------------------------------------------------- SESSION (extra study)
        QuizSession {
          id: quizSession
          visible: root.view === "session"
          anchors.fill: parent
          service: root.service
          subjectIds: root.sessionIds
          title: root.sessionTitle
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onExit: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (quizSession.visible) quizSession.forceActiveFocus() })
        }

        // -------------------------------------------------- REVIEW (POSTs)
        ReviewEngine {
          id: reviewEngine
          visible: root.view === "review"
          anchors.fill: parent
          service: root.service
          subjectIds: root.reviewIds
          // "ask" shows the dry-run start screen; "dry-run" / "live" skip it
          mode: String(root.setting("reviewMode", "ask"))
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onExit: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (reviewEngine.visible) reviewEngine.forceActiveFocus() })
        }

        // -------------------------------------------------- LESSON (POSTs)
        LessonFlow {
          id: lessonFlow
          visible: root.view === "lesson"
          anchors.fill: parent
          service: root.service
          subjectIds: root.lessonIds
          totalWaiting: root.lessonTotal
          pageBg: root.bg
          fg: root.fg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onExit: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (lessonFlow.visible) lessonFlow.forceActiveFocus() })
        }
      }
    }
  }
}
