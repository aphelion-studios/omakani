import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

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
  property int homeIndex: 0
  readonly property var homeActions: {
    var out = []
    if (!service || !service.configured) return out
    if (startLessons) out.push({ text: "Start Lessons", act: "lesson", loud: true })
    if (startReviews) out.push({ text: "Start Reviews", act: "review", loud: true })
    out.push({ text: "Browse Subjects", act: "browse", loud: false })
    return out
  }
  function homeMove(d) {
    if (homeActions.length === 0) return
    homeIndex = (homeIndex + d + homeActions.length) % homeActions.length
  }
  onHomeActionsChanged: if (homeIndex >= homeActions.length)
    homeIndex = Math.max(0, homeActions.length - 1)
  function homeActivate() {
    var a = homeActions[Math.max(0, Math.min(homeIndex, homeActions.length - 1))]
    if (!a) return
    if (a.act === "lesson") goLesson()
    else if (a.act === "review") goReview()
    else goBrowse(service ? (service.level || 1) : 1)
  }

  // Website type colours (vivid variants, tuned against the dark app ground).
  readonly property color radicalColor: "#01a9fd"
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
    if (view === "browse") levelBrowser.focusGrid()
    else if (view === "subject") subjectPage.focusPage()
    else if (view === "quiz") quizCard.forceActiveFocus()
    else if (view === "session") quizSession.forceActiveFocus()
    else if (view === "review") reviewEngine.forceActiveFocus()
    else if (view === "lesson") lessonFlow.forceActiveFocus()
    else {
      // home -- a just-hidden child FocusScope can still be holding it, so
      // reclaim on the next tick too
      focusScope.forceActiveFocus()
      Qt.callLater(function () { if (root.view === "home") focusScope.forceActiveFocus() })
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
  // otherwise close the app (a flow summoned from the dashboard is the root)
  function leave() {
    if (navStack.length > 1) popPage()
    else requestClose()
  }

  function resetNav() {
    navStack = [{ view: "home" }]
  }

  function goBrowse(level) {
    var n = Math.max(1, Math.min(60, parseInt(String(level), 10) || 1))
    pushPage({ view: "browse", level: n })
    if (root.service) root.service.loadBrowse(n)
  }

  function goSubject(id) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    pushPage({ view: "subject", id: n })
    if (root.service) root.service.loadDetail([n])
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
    pushPage({ view: "session" })
    Qt.callLater(function () { quizSession.start() })
  }

  // The review session -- POSTs to /reviews (guarded by the dry-run start
  // screen). Pulls the due queue from the helper first.
  property var reviewIds: []
  function goReview() {
    pushPage({ view: "review" })
    if (service) service.loadReviews()
  }

  // The lesson batch -- POSTs /assignments/{id}/start (dry-run guarded).
  property var lessonIds: []
  property int lessonTotal: 0
  function goLesson() {
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
      root.reviewIds = ids || []
      Qt.callLater(function () { reviewEngine.begin() })
    }
    function onLessonsReady(ids, total) {
      if (root.view !== "lesson") return
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
    // Reviews / Start Lessons / Extra Study). It clears the stack first so
    // Esc / Back from that view closes the app rather than landing on a
    // home screen the user never opened.
    var payload = null
    try { payload = payloadJson ? JSON.parse(payloadJson) : null } catch (e) { payload = null }
    if (payload && (payload.session || payload.review || payload.lesson)) {
      Qt.callLater(function () {
        root.navStack = []
        if (payload.session) root.openSessionMode(String(payload.session))
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
    function browse(level: string): void {
      root.open("")
      root.resetNav()
      root.goBrowse(parseInt(level, 10) || (root.service ? root.service.level : 1))
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
        subjectFocusIndex: subjectPage.focusIndex
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
        // On the home screen only; the browser and subject page own their keys.
        if (root.view !== "home") return
        if (e.key === Qt.Key_Down || e.key === Qt.Key_Right || e.text === "j" || e.text === "l") {
          root.homeMove(1); e.accepted = true
        } else if (e.key === Qt.Key_Up || e.key === Qt.Key_Left || e.text === "k" || e.text === "h") {
          root.homeMove(-1); e.accepted = true
        } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
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

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Text {
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

          Text {
            text: {
              if (root.view === "browse") return "OmaKani  /  Level " + root.currentPage.level
              if (root.view === "subject") return "OmaKani  /  Subject"
              return "OmaKani"
            }
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
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
        Column {
          visible: root.view === "home"
          anchors.centerIn: parent
          spacing: Style.space(18)
          width: Math.min(parent.width - Style.space(80), Style.space(520))

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: Qt.resolvedUrl("wordmark.svg")
            height: Style.space(64)
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 1893
            smooth: true
            mipmap: true
            width: Math.min(implicitWidth, parent.width)
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
              return s.username + "   ·   Level " + s.level + "\n"
                + s.reviewsNow + " reviews   ·   " + s.lessonsNow + " lessons ready"
            }
          }

          // Start Lessons / Start Reviews (when waiting) + Browse subjects.
          // j/k/h/l or arrows move the cursor, Enter activates. The "loud"
          // ones are styled like the dashboard's Start buttons -- accent
          // fill, focus ring, breathing pulse.
          Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(10)
            visible: !!root.service && root.service.configured

            Repeater {
              model: root.homeActions
              delegate: Rectangle {
                id: homeBtn
                anchors.horizontalCenter: parent.horizontalCenter
                readonly property bool current: index === root.homeIndex
                readonly property bool lit: current || homeHover.containsMouse
                readonly property bool loud: modelData.loud
                width: homeLabel.implicitWidth + Style.space(52)
                height: Style.space(42)
                radius: Style.space(6)
                clip: true
                color: loud
                  ? (lit ? Qt.lighter(root.accent, 1.3) : root.accent)
                  : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, lit ? 0.16 : 0.08)
                border.width: lit ? 3 : (loud ? 0 : 1)
                border.color: lit ? (loud ? "#fcfdfd" : root.fg)
                  : (loud ? "transparent"
                          : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22))
                Behavior on color { ColorAnimation { duration: 110 } }

                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: Qt.lighter(root.accent, 1.35)
                  visible: homeBtn.loud && !homeBtn.lit
                  opacity: 0
                  SequentialAnimation on opacity {
                    running: homeBtn.loud && homeBtn.visible && !homeBtn.lit
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.0; to: 0.4; duration: 950; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.4; to: 0.0; duration: 950; easing.type: Easing.InOutSine }
                  }
                }

                Text {
                  id: homeLabel
                  anchors.centerIn: parent
                  text: modelData.text + (homeBtn.loud ? "  ›" : "")
                  color: homeBtn.loud ? root.bg : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: homeBtn.loud
                }
                MouseArea {
                  id: homeHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.homeIndex = index
                  onClicked: { root.homeIndex = index; root.homeActivate() }
                }
              }
            }
          }

        }

        // -------------------------------------------------- BROWSE
        LevelBrowser {
          id: levelBrowser
          visible: root.view === "browse"
          anchors.fill: parent
          service: root.service
          level: root.view === "browse" ? root.currentPage.level : 1
          fg: root.fg
          pageBg: root.bg
          fontFamily: root.fontFamily
          jpFamily: root.jpFamily
          radicalColor: root.radicalColor
          kanjiColor: root.kanjiColor
          vocabColor: root.vocabColor
          onOpenSubject: function (subjectId) { root.goSubject(subjectId) }
          onChangeLevel: function (newLevel) {
            var next = root.navStack.slice()
            next[next.length - 1] = { view: "browse", level: newLevel }
            root.navStack = next
            if (root.service) root.service.loadBrowse(newLevel)
          }
          onVisibleChanged: if (visible) Qt.callLater(function () { if (levelBrowser.visible) levelBrowser.focusGrid() })
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
          onCloseRequested: root.leave()
          onVisibleChanged: if (visible) Qt.callLater(function () { if (subjectPage.visible) subjectPage.focusPage() })
        }

        // loading / empty state for the subject page
        Text {
          anchors.centerIn: parent
          visible: root.view === "subject" && !subjectPage.subject
          text: (root.service && root.service.detailError)
            ? root.service.detailError : "Loading subject…"
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
