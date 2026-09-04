import QtQuick
import qs.Commons

// A WaniKani lesson batch: walk the info cards, quiz on all of them (both
// meaning and reading correct), then start each subject -- which moves it
// from the lesson queue into reviews. `POST /assignments/{id}/start` mutates
// SRS, so it opens on a dry-run toggle like the review engine.
FocusScope {
  id: flow

  property var service: null
  property var subjectIds: []
  property int totalWaiting: 0

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#0098e6"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"
  readonly property color okColor: "#34a553"

  signal exit()

  property alias cardItem: session.cardItem

  // "loading" | "ready" | "info" | "quiz" | "starting" | "batch" | "summary" | "error"
  property string phase: "loading"
  property bool dryRun: true
  // "ask" -> show the start screen; "dry-run" / "live" -> straight into it,
  // same as the review engine
  property string mode: "ask"
  property string errorText: ""
  property int infoIndex: 0        // subject within the current batch
  property int pageIndex: 0        // learn page within that subject
  property int startedCount: 0
  property var quizStats: ({ total: 0, correct: 0, answers: 0 })

  // how many lessons in the whole daily allowance, and the ones already
  // learned + started this sitting -- drives the "N more" on the continue screen
  property int batchTotal: totalWaiting
  property var doneIds: []

  readonly property var ids: (subjectIds || [])
    .map(function (x) { return parseInt(String(x), 10) })
    .filter(function (x) { return isFinite(x) })
  readonly property var infoSubject: (phase === "info" && service && infoIndex < ids.length)
    ? service.subjectDetail(ids[infoIndex]) : null
  readonly property string infoKind: infoSubject ? String(infoSubject.object || "") : ""

  // the learn pages for a subject, mirroring wanikani.com's lesson walk --
  // only the sections that subject actually has content for
  function pagesFor(subjectId) {
    var s = service ? service.subjectDetail(subjectId) : null
    if (!s) return ["meaning"]
    var kind = String(s.object || "")
    var d = s.data || ({})
    var hasComp = (d.component_subject_ids || []).length > 0
    var hasContext = (d.context_sentences || []).length > 0
    if (kind === "radical") return ["meaning"]
    if (kind === "kanji")
      return (hasComp ? ["composition"] : []).concat(["meaning", "reading"])
    // vocabulary / kana_vocabulary
    var p = hasComp ? ["composition"] : []
    p = p.concat(["meaning", "reading"])
    if (hasContext) p.push("context")
    return p
  }
  readonly property var currentPages: (phase === "info" && infoIndex < ids.length)
    ? pagesFor(ids[infoIndex]) : ["meaning"]
  readonly property string soloSection: (pageIndex < currentPages.length)
    ? currentPages[pageIndex] : "meaning"

  // drilling into a component chip from the Composition page during the learn
  // walk -- a small back stack, the same shape as the review Item Info. h /
  // Left / Esc pops one.
  property var _drillStack: []
  property int _drillPending: 0
  readonly property bool drilled: _drillStack.length > 0
  readonly property var infoSubjectShown: drilled
    ? _drillStack[_drillStack.length - 1] : infoSubject
  // on the Composition page the SubjectPage drives its own chip ring (j/k/h/l/
  // Enter), exactly like reviews; every other learn page uses h/l for paging
  readonly property bool infoChipNav: phase === "info" && soloSection === "composition"
  function _drill(id) {
    if (!service) return
    var res = service.subjectDetail(id)
    if (res) { _drillStack = _drillStack.concat([res]); return }
    _drillPending = parseInt(String(id), 10)
    service.loadDetail([id])
  }
  function _drillBack() {
    if (_drillStack.length > 0) _drillStack = _drillStack.slice(0, -1)
  }
  onPageIndexChanged: _drillStack = []
  onInfoIndexChanged: _drillStack = []

  readonly property int moreWaiting: Math.max(0, batchTotal - doneIds.length)

  // autoplay a vocab's reading when the learn walk reaches its reading page
  onSoloSectionChanged: {
    if (phase === "info" && soloSection === "reading" && infoSubject
        && (infoKind === "vocabulary" || infoKind === "kana_vocabulary")
        && service && service.boolSetting("autoplayLessons", false))
      Qt.callLater(function () { service.playAudio(infoSubject.id) })
  }

  // never pull focus while off-screen (background build on another page)
  function _grabFocus() { if (flow.visible) flow.forceActiveFocus() }

  function rearm() {
    if (phase === "summary" || phase === "error") { errorText = ""; phase = "loading" }
  }

  function begin() {
    phase = ids.length === 0 ? "error" : "loading"
    errorText = ids.length === 0 ? "No lessons are waiting right now." : ""
    infoIndex = 0
    pageIndex = 0
    startedCount = 0
    doneIds = []
    batchTotal = totalWaiting
    if (service && ids.length > 0) {
      service.loadDetail(ids)
      service.preloadAudio(ids)
    }
    checkReady()
  }

  // the host hands us the next batch's ids (already minus what's done); keep
  // the learn walk going without leaving the lesson view. batchTotal is the
  // day's allowance and doesn't move.
  function continueBatch(nextIds) {
    subjectIds = nextIds || []
    infoIndex = 0
    pageIndex = 0
    startedCount = 0
    if (service && ids.length > 0) {
      service.loadDetail(ids)
      service.preloadAudio(ids)
      phase = "loading"
      checkReady()
    } else {
      phase = "summary"
    }
  }

  function checkReady() {
    if (phase !== "loading" || !service || ids.length === 0) return
    if (ids.every(function (x) { return !!service.subjectDetail(x) })) {
      // the Kanji Composition page needs the component subjects too
      var comp = []
      for (var i = 0; i < ids.length; i++) {
        var d = (service.subjectDetail(ids[i]) || {}).data || {}
        var c = d.component_subject_ids || []
        for (var j = 0; j < c.length; j++)
          if (comp.indexOf(c[j]) < 0 && !service.subjectDetail(c[j])) comp.push(c[j])
      }
      if (comp.length > 0) service.loadDetail(comp)
      // returning from a continue goes straight into the learn walk
      phase = doneIds.length > 0 ? "info" : "ready"
      if (phase === "info")
        Qt.callLater(function () { if (infoPage.visible) infoPage.focusPage() })
      // skip the start screen when the mode is pinned in settings
      else if (mode === "dry-run" || mode === "live") {
        dryRun = (mode === "dry-run")
        Qt.callLater(startInfo)
      }
    }
  }

  function startInfo() {
    phase = "info"
    infoIndex = 0
    pageIndex = 0
    Qt.callLater(function () { if (infoPage.visible) infoPage.focusPage() })
  }

  function infoNext() {
    if (phase !== "info") return
    if (pageIndex + 1 < currentPages.length) { pageIndex += 1; return }
    if (infoIndex + 1 < ids.length) { infoIndex += 1; pageIndex = 0; return }
    phase = "quiz"
    Qt.callLater(function () { session.start() })
  }
  function infoPrev() {
    if (phase !== "info") return
    if (pageIndex > 0) { pageIndex -= 1; return }
    if (infoIndex > 0) {
      infoIndex -= 1
      pageIndex = Math.max(0, pagesFor(ids[infoIndex]).length - 1)
    }
  }

  function afterQuiz(total, correct, answers, missed) {
    if (phase !== "quiz") return
    quizStats = { total: total, correct: correct, answers: answers }
    phase = "starting"
    startedCount = 0
    for (var i = 0; i < ids.length; i++)
      service.startLesson(ids[i], flow.dryRun)
  }

  function _batchStarted() {
    // record this batch as done, then continue or finish
    var d = doneIds.slice()
    for (var i = 0; i < ids.length; i++)
      if (d.indexOf(ids[i]) < 0) d.push(ids[i])
    doneIds = d
    if (moreWaiting > 0) {
      phase = "batch"
      Qt.callLater(flow._grabFocus)
    } else {
      phase = "summary"
      Qt.callLater(flow._grabFocus)
    }
  }

  // the continue screen's "keep going" -- ask the host for the whole daily
  // list; App filters out what's done and hands back the next batch
  function requestContinue() {
    if (!service) { phase = "summary"; return }
    phase = "loading"
    service.loadLessons(0)
  }
  function batchSize() {
    var n = parseInt(String(service ? service.setting("lessonBatchSize", 5) : 5), 10)
    return (isFinite(n) && n > 0) ? Math.min(n, 20) : 5
  }

  Connections {
    target: flow.service
    enabled: flow.service !== null
    function onDetailReady(ids) {
      flow.checkReady()
      if (flow._drillPending > 0 && flow.service) {
        var res = flow.service.subjectDetail(flow._drillPending)
        if (res) {
          flow._drillStack = flow._drillStack.concat([res])
          flow._drillPending = 0
        }
      }
    }
    function onLessonStarted(result) {
      if (flow.phase !== "starting") return
      flow.startedCount += 1
      if (flow.startedCount >= flow.ids.length) flow._batchStarted()
    }
    function onLessonStartFailed(subjectId, message) {
      flow.errorText = "Starting a lesson failed: " + message
        + "\n\nSome may have gone through -- check the site."
      flow.phase = "error"
    }
  }

  Shortcut {
    sequences: ["d"]
    enabled: flow.visible && flow.phase === "ready"
    onActivated: flow.dryRun = !flow.dryRun
  }
  Shortcut {
    sequences: ["Return", "Enter"]
    enabled: flow.visible && (flow.phase === "ready"
      || flow.phase === "batch" || flow.phase === "summary" || flow.phase === "error")
    onActivated: flow.phase === "ready" ? flow.startInfo()
      : flow.phase === "batch" ? flow.requestContinue() : flow.exit()
  }

  // a focused item still gets key events while hidden -- don't eat keys once
  // this isn't the visible view (keeps the home menu's Enter/Esc alive after
  // wrapping out of a lesson)
  Keys.enabled: flow.visible

  Keys.onPressed: function (e) {
    if (phase === "ready") {
      if (e.text === "d") { dryRun = !dryRun; e.accepted = true }
      else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { startInfo(); e.accepted = true }
      else if (e.key === Qt.Key_Escape) { flow.exit(); e.accepted = true }
    } else if (phase === "info") {
      // The SubjectPage handles j/k itself (scroll, or -- on the Composition
      // page -- arming its component ring). Anything it doesn't accept bubbles
      // here: h/l page the learn walk, unless the ring is armed and eats them.
      if (e.text === "?") { learnHotkeys.toggle(); e.accepted = true }
      else if (e.key === Qt.Key_Escape && learnHotkeys.open) { learnHotkeys.close(); e.accepted = true }
      else if (drilled && (e.key === Qt.Key_Escape || e.key === Qt.Key_Left)) {
        _drillBack(); e.accepted = true
      }
      else if (drilled) {
        // the drilled page owns j/k/h/l/Enter; Left / Esc (above) pops it
      }
      else if (e.text === "l" || e.key === Qt.Key_Right || e.key === Qt.Key_Return
          || e.key === Qt.Key_Enter) { infoNext(); e.accepted = true }
      else if (e.text === "h" || e.key === Qt.Key_Left) { infoPrev(); e.accepted = true }
      else if (e.key === Qt.Key_Escape) { flow.exit(); e.accepted = true }
      else if (e.text === "j" || e.text === "k" || e.text === "d" || e.text === "u"
               || e.text === "g" || e.text === "G" || e.key === Qt.Key_Space) {
        // let the info page handle scroll / audio
      }
    } else if (phase === "batch") {
      if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter
          || e.text === "l" || e.key === Qt.Key_Right) { requestContinue(); e.accepted = true }
      else if (e.key === Qt.Key_Escape || e.text === "f") { phase = "summary"; e.accepted = true }
    } else if ((phase === "summary" || phase === "error")
        && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape)) {
      flow.exit(); e.accepted = true
    }
  }

  Rectangle { anchors.fill: parent; color: flow.pageBg }

  Text {
    anchors.centerIn: parent
    visible: flow.phase === "loading"
    text: "Loading lessons…"
    color: Qt.darker(flow.fg, 1.4)
    font.family: flow.fontFamily
    font.pixelSize: Style.font.body
  }

  // ---- start screen ----
  Column {
    anchors.centerIn: parent
    visible: flow.phase === "ready"
    spacing: Style.space(16)
    width: Math.min(parent.width - Style.space(80), Style.space(440))

    Image {
      anchors.horizontalCenter: parent.horizontalCenter
      source: Qt.resolvedUrl("wordmark.svg")
      height: Style.space(48)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: 1893
      smooth: true
      mipmap: true
      width: Math.min(implicitWidth, parent.width)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: flow.ids.length + (flow.ids.length === 1 ? " lesson" : " lessons")
      color: flow.fg
      font.family: flow.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: flow.totalWaiting > flow.ids.length
      text: "this batch  ·  " + flow.totalWaiting + " for today"
      color: Qt.darker(flow.fg, 1.5)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: dryRow.implicitWidth + Style.space(28)
      height: Style.space(40)
      radius: Style.space(6)
      color: flow.dryRun
        ? Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.1)
        : Qt.rgba(flow.okColor.r, flow.okColor.g, flow.okColor.b, 0.22)
      border.width: 1
      border.color: flow.dryRun
        ? Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.28) : flow.okColor
      Row {
        id: dryRow
        anchors.centerIn: parent
        spacing: Style.space(8)
        Text {
          text: flow.dryRun ? "Dry run — nothing is sent" : "LIVE — lessons will be started"
          color: flow.fg
          font.family: flow.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          text: "(d to toggle)"
          color: Qt.darker(flow.fg, 1.6)
          font.family: flow.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: flow.dryRun = !flow.dryRun
      }
    }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: startLbl.implicitWidth + Style.space(44)
      height: Style.space(44)
      radius: Style.space(6)
      color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, startHover.containsMouse ? 0.2 : 0.12)
      border.width: 1
      border.color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.3)
      Text {
        id: startLbl
        anchors.centerIn: parent
        text: "Begin  ›"
        color: flow.fg
        font.family: flow.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      MouseArea {
        id: startHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: flow.startInfo()
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Enter to start   ·   Esc to go back"
      color: Qt.darker(flow.fg, 1.9)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- info cards (the page-by-page learn walk) ----
  Item {
    anchors.fill: parent
    visible: flow.phase === "info"

    SubjectPage {
      id: infoPage
      anchors.fill: parent
      anchors.bottomMargin: flow.drilled ? 0 : Style.space(98)   // chips + nav
      subject: flow.infoSubjectShown
      service: flow.service
      // a drilled component shows the whole page; the learn walk shows one card
      soloSection: flow.drilled ? "" : flow.soloSection
      lessonMode: true
      // a drilled component always shows its ring; the Composition page only
      // once the user presses j (SubjectPage tracks that itself)
      forceKeyNav: flow.drilled
      pageBg: flow.pageBg
      fg: flow.fg
      fontFamily: flow.fontFamily
      jpFamily: flow.jpFamily
      radicalColor: flow.radicalColor
      kanjiColor: flow.kanjiColor
      vocabColor: flow.vocabColor
      onNavigate: function (id) { flow._drill(id) }
      onCloseRequested: flow.drilled ? flow._drillBack() : flow.exit()
    }

    // lesson chips stacked above the ‹ › page nav, bottom-centre (the website's
    // shape). Chips: one per subject in the batch, current filled, rest dimmed.
    Column {
      visible: !flow.drilled
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(16)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)
      z: 10

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)
        Repeater {
          model: flow.ids
          delegate: Rectangle {
            readonly property var s: flow.service ? flow.service.subjectDetail(modelData) : null
            readonly property string obj: s ? String(s.object || "") : ""
            readonly property string ch: (s && s.data)
              ? String(s.data.characters || "") : ""
            readonly property bool cur: index === flow.infoIndex
            readonly property color tint: obj === "radical" ? flow.radicalColor
              : obj === "kanji" ? flow.kanjiColor : flow.vocabColor
            width: chipLbl.implicitWidth + Style.space(16)
            height: Style.space(28)
            radius: Style.space(5)
            color: cur ? tint : Qt.rgba(tint.r, tint.g, tint.b, 0.16)
            opacity: cur ? 1 : 0.6
            Behavior on opacity { NumberAnimation { duration: 120 } }
            Text {
              id: chipLbl
              anchors.centerIn: parent
              text: ch !== "" ? ch
                : ((s && s.data && s.data.meanings && s.data.meanings[0])
                   ? s.data.meanings[0].meaning : "…")
              color: cur ? "#fcfdfd" : tint
              font.family: ch !== "" ? flow.jpFamily : flow.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: { flow.infoIndex = index; flow.pageIndex = 0 }
            }
          }
        }
      }

      // ‹ / › page nav, centred under the chips
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(16)
        Repeater {
          model: [{ g: "‹", prev: true }, { g: "›", prev: false }]
          delegate: Rectangle {
            width: Style.space(48); height: Style.space(36); radius: Style.space(8)
            readonly property bool off: modelData.prev
              && flow.infoIndex === 0 && flow.pageIndex === 0
            color: navHover.containsMouse && !off
              ? Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.14)
              : Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.14)
            opacity: off ? 0.3 : 1
            Text {
              anchors.centerIn: parent
              text: modelData.g
              color: flow.fg
              font.family: flow.fontFamily
              font.pixelSize: Style.font.title
            }
            MouseArea {
              id: navHover
              anchors.fill: parent
              hoverEnabled: true
              enabled: !parent.off
              cursorShape: Qt.PointingHandCursor
              onClicked: modelData.prev ? flow.infoPrev() : flow.infoNext()
            }
          }
        }
      }
    }

    HotkeysOverlay {
      id: learnHotkeys
      anchors.fill: parent
      fg: flow.fg
      pageBg: flow.pageBg
      fontFamily: flow.fontFamily
      title: "Lesson keys"
      rows: flow.drilled ? [
        { k: "h l", d: "Move between components" },
        { k: "↵", d: "Open the ringed component" },
        { k: "Esc", d: "Back to the lesson" },
        { k: "?", d: "Toggle this menu" }
      ] : (flow.infoChipNav && infoPage.lessonChipFocused) ? [
        { k: "h l", d: "Move between components" },
        { k: "↵", d: "Open a component's page" },
        { k: "k", d: "Unfocus (back to paging)" },
        { k: "Esc", d: "Back to lesson menu" },
        { k: "?", d: "Toggle this menu" }
      ] : flow.infoChipNav ? [
        { k: "h l", d: "Previous / next page" },
        { k: "j", d: "Focus the components" },
        { k: "j k", d: "Scroll the page" },
        { k: "Esc", d: "Back to lesson menu" },
        { k: "?", d: "Toggle this menu" }
      ] : [
        { k: "l", d: "Next page / item" },
        { k: "h", d: "Previous page / item" },
        { k: "j", d: "Play audio" },
        { k: "j k", d: "Scroll the page" },
        { k: "Esc", d: "Back to lesson menu" },
        { k: "?", d: "Toggle this menu" }
      ]
    }
  }

  // ---- quiz ----
  QuizSession {
    id: session
    anchors.fill: parent
    visible: flow.phase === "quiz"
    service: flow.service
    subjectIds: flow.subjectIds
    title: "Lesson quiz"
    suppressSummary: true
    isLesson: true
    pageBg: flow.pageBg
    fg: flow.fg
    fontFamily: flow.fontFamily
    jpFamily: flow.jpFamily
    radicalColor: flow.radicalColor
    kanjiColor: flow.kanjiColor
    vocabColor: flow.vocabColor
    onCompleted: function (total, correct, answers, missed) {
      flow.afterQuiz(total, correct, answers, missed)
    }
    onExit: flow.exit()
    onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
  }

  Text {
    anchors.centerIn: parent
    visible: flow.phase === "starting"
    text: (flow.dryRun ? "Wrapping up (dry run)…" : "Starting your lessons…")
      + "\n" + flow.startedCount + " / " + flow.ids.length
    horizontalAlignment: Text.AlignHCenter
    color: Qt.darker(flow.fg, 1.4)
    font.family: flow.fontFamily
    font.pixelSize: Style.font.body
  }

  // ---- between batches ----
  Column {
    anchors.centerIn: parent
    visible: flow.phase === "batch"
    spacing: Style.space(14)
    width: Math.min(parent.width - Style.space(80), Style.space(420))

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Batch complete"
      color: flow.fg
      font.family: flow.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: {
        var acc = flow.quizStats.answers > 0
          ? Math.round(100 * flow.quizStats.correct / flow.quizStats.answers) : 100
        return flow.ids.length + (flow.dryRun ? " walked (dry run)" : " started")
          + "  ·  " + acc + "% on the quiz"
      }
      color: Qt.darker(flow.fg, 1.35)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: contLbl.implicitWidth + Style.space(40)
      height: Style.space(44)
      radius: Style.space(6)
      color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, contHover.containsMouse ? 0.2 : 0.12)
      border.width: 1
      border.color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.3)
      Text {
        id: contLbl
        anchors.centerIn: parent
        text: "Continue  (" + flow.moreWaiting + " more)  ›"
        color: flow.fg
        font.family: flow.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      MouseArea {
        id: contHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: flow.requestContinue()
      }
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Enter to continue   ·   Esc to finish"
      color: Qt.darker(flow.fg, 1.9)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- summary / error ----
  Column {
    anchors.centerIn: parent
    visible: flow.phase === "summary" || flow.phase === "error"
    spacing: Style.space(12)
    width: Math.min(parent.width - Style.space(80), Style.space(460))

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: flow.phase === "error" ? "Stopped" : "Lessons done"
      color: flow.fg
      font.family: flow.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: {
        if (flow.phase === "error") return flow.errorText
        var acc = flow.quizStats.answers > 0
          ? Math.round(100 * flow.quizStats.correct / flow.quizStats.answers) : 100
        return flow.startedCount + " / " + flow.ids.length + " started"
          + (flow.dryRun ? " (dry run — nothing was sent)" : "")
          + "\nquiz: " + acc + "% over " + flow.quizStats.answers + " answers"
      }
      color: Qt.darker(flow.fg, 1.35)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Enter to finish"
      color: Qt.darker(flow.fg, 1.9)
      font.family: flow.fontFamily
      font.pixelSize: Style.font.caption
      topPadding: Style.space(6)
    }
  }
}
