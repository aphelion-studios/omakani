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

  // "loading" | "ready" | "info" | "quiz" | "starting" | "summary" | "error"
  property string phase: "loading"
  property bool dryRun: true
  property string errorText: ""
  property int infoIndex: 0
  property int startedCount: 0
  property var quizStats: ({ total: 0, correct: 0, answers: 0 })

  readonly property var ids: (subjectIds || [])
    .map(function (x) { return parseInt(String(x), 10) })
    .filter(function (x) { return isFinite(x) })
  readonly property var infoSubject: (phase === "info" && service && infoIndex < ids.length)
    ? service.subjectDetail(ids[infoIndex]) : null

  // never pull focus while off-screen (background build on another page)
  function _grabFocus() { if (flow.visible) flow.forceActiveFocus() }

  // re-entering the view before begin() has run again: clear a terminal
  // screen so its window-wide Enter/Esc -> exit() shortcut can't fire on
  // the keypress meant to start the next batch
  function rearm() {
    if (phase === "summary" || phase === "error") { errorText = ""; phase = "loading" }
  }

  function begin() {
    phase = ids.length === 0 ? "error" : "loading"
    errorText = ids.length === 0 ? "No lessons are waiting right now." : ""
    infoIndex = 0
    startedCount = 0
    if (service && ids.length > 0) {
      service.loadDetail(ids)
      service.preloadAudio(ids)   // warm the audio cache for the batch
    }
    checkReady()
  }

  function checkReady() {
    if (phase !== "loading" || !service || ids.length === 0) return
    if (ids.every(function (x) { return !!service.subjectDetail(x) }))
      phase = "ready"
  }

  function startInfo() {
    phase = "info"
    infoIndex = 0
    Qt.callLater(function () { if (infoPage.visible) infoPage.focusPage() })
  }

  function infoNext() {
    if (phase !== "info") return
    if (infoIndex + 1 < ids.length) infoIndex += 1
    else { phase = "quiz"; Qt.callLater(function () { session.start() }) }
  }
  function infoPrev() { if (phase === "info" && infoIndex > 0) infoIndex -= 1 }

  function afterQuiz(total, correct, answers, missed) {
    if (phase !== "quiz") return
    quizStats = { total: total, correct: correct, answers: answers }
    phase = "starting"
    startedCount = 0
    for (var i = 0; i < ids.length; i++)
      service.startLesson(ids[i], flow.dryRun)
  }

  Connections {
    target: flow.service
    enabled: flow.service !== null
    function onDetailReady(ids) { flow.checkReady() }
    function onLessonStarted(result) {
      if (flow.phase !== "starting") return
      flow.startedCount += 1
      if (flow.startedCount >= flow.ids.length) {
        flow.phase = "summary"
        Qt.callLater(flow._grabFocus)
      }
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
      || flow.phase === "summary" || flow.phase === "error")
    onActivated: flow.phase === "ready" ? flow.startInfo() : flow.exit()
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
        + (flow.totalWaiting > flow.ids.length ? "   (" + flow.totalWaiting + " waiting)" : "")
      color: flow.fg
      font.family: flow.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true
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

  // ---- info cards ----
  Item {
    anchors.fill: parent
    visible: flow.phase === "info"

    SubjectPage {
      id: infoPage
      anchors.fill: parent
      anchors.topMargin: Style.space(34)
      subject: flow.infoSubject
      service: flow.service
      pageBg: flow.pageBg
      fg: flow.fg
      fontFamily: flow.fontFamily
      jpFamily: flow.jpFamily
      radicalColor: flow.radicalColor
      kanjiColor: flow.kanjiColor
      vocabColor: flow.vocabColor
    }

    // top strip: counter + hint
    Rectangle {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(34)
      color: flow.pageBg
      Row {
        anchors.centerIn: parent
        spacing: Style.space(16)
        Text {
          text: (flow.infoIndex + 1) + " / " + flow.ids.length
          color: flow.fg
          font.family: flow.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          text: "h / l  move   ·   " + (flow.infoIndex + 1 < flow.ids.length ? "l" : "Enter") + "  "
            + (flow.infoIndex + 1 < flow.ids.length ? "next" : "start quiz")
          color: Qt.darker(flow.fg, 1.6)
          font.family: flow.fontFamily
          font.pixelSize: Style.font.caption
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
