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
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"
  readonly property color okColor: "#93c01f"

  signal exit()

  property alias cardItem: session.cardItem

  // "loading" | "ready" | "info" | "quiz" | "starting" | "batch" | "summary" | "error"
  property string phase: "loading"
  property bool dryRun: true
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

  // the learn pages for a subject, mirroring wanikani.com's lesson walk
  function pagesFor(kind) {
    if (kind === "radical") return ["meaning"]
    if (kind === "kanji") return ["composition", "meaning", "reading"]
    return ["meaning", "reading", "context"]   // vocabulary
  }
  readonly property var currentPages: pagesFor(infoKind)
  readonly property string soloSection: (phase === "info" && pageIndex < currentPages.length)
    ? currentPages[pageIndex] : "meaning"

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
      // returning from a continue goes straight into the learn walk
      phase = doneIds.length > 0 ? "info" : "ready"
      if (phase === "info")
        Qt.callLater(function () { if (infoPage.visible) infoPage.focusPage() })
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
      pageIndex = pagesFor(String((service.subjectDetail(ids[infoIndex]) || {}).object || "")).length - 1
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
    function onDetailReady(ids) { flow.checkReady() }
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
      if (e.text === "l" || e.key === Qt.Key_Right || e.key === Qt.Key_Return
          || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { infoNext(); e.accepted = true }
      else if (e.text === "h" || e.key === Qt.Key_Left) { infoPrev(); e.accepted = true }
      else if (e.key === Qt.Key_Escape) { flow.exit(); e.accepted = true }
      else if (e.text === "j" || e.text === "k" || e.text === "p" || e.text === "g" || e.text === "G") {
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
      anchors.topMargin: Style.space(38)
      subject: flow.infoSubject
      service: flow.service
      soloSection: flow.soloSection
      pageBg: flow.pageBg
      fg: flow.fg
      fontFamily: flow.fontFamily
      jpFamily: flow.jpFamily
      radicalColor: flow.radicalColor
      kanjiColor: flow.kanjiColor
      vocabColor: flow.vocabColor
      onNavigate: function (id) { /* linked chips are inert during a lesson */ }
    }

    // top strip: per-subject progress dots + a "which item" counter
    Rectangle {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(38)
      color: flow.pageBg
      z: 10

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        text: "Lesson " + (flow.infoIndex + 1) + " / " + flow.ids.length
        color: Qt.darker(flow.fg, 1.4)
        font.family: flow.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // page dots for the current subject
      Row {
        anchors.centerIn: parent
        spacing: Style.space(6)
        Repeater {
          model: flow.currentPages.length
          delegate: Rectangle {
            width: index === flow.pageIndex ? Style.space(16) : Style.space(6)
            height: Style.space(6)
            radius: height / 2
            color: index === flow.pageIndex ? flow.fg
              : Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.25)
            Behavior on width { NumberAnimation { duration: 120 } }
          }
        }
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        readonly property bool lastPage: flow.pageIndex + 1 >= flow.currentPages.length
        readonly property bool lastItem: flow.infoIndex + 1 >= flow.ids.length
        text: "‹ ›  move   ·   " + ((lastPage && lastItem) ? "→  start quiz" : "→  next")
        color: Qt.darker(flow.fg, 1.6)
        font.family: flow.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ‹ / › page buttons, bottom-centre
    Row {
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(20)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(16)
      z: 10
      Repeater {
        model: [{ g: "‹", act: "prev" }, { g: "›", act: "next" }]
        delegate: Rectangle {
          width: Style.space(46); height: Style.space(36); radius: Style.space(6)
          readonly property bool disabled: modelData.act === "prev"
            && flow.infoIndex === 0 && flow.pageIndex === 0
          color: nHover.containsMouse && !disabled
            ? Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.16)
            : Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.08)
          border.width: 1
          border.color: Qt.rgba(flow.fg.r, flow.fg.g, flow.fg.b, 0.2)
          opacity: disabled ? 0.35 : 1
          Text {
            anchors.centerIn: parent
            text: modelData.g
            color: flow.fg
            font.family: flow.fontFamily
            font.pixelSize: Style.font.heading
          }
          MouseArea {
            id: nHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: !parent.disabled
            cursorShape: Qt.PointingHandCursor
            onClicked: modelData.act === "prev" ? flow.infoPrev() : flow.infoNext()
          }
        }
      }
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
