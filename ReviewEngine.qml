import QtQuick
import qs.Commons

// A WaniKani review session. Each subject needs BOTH its meaning and reading
// answered correctly before it's submitted; wrong answers tally per component
// and requeue that question. On completion the item goes to the helper's
// `submit-review` -- which POSTs to /reviews and moves real SRS state, so the
// session starts in dry-run (nothing sent) and you opt into a live run on the
// start screen.
FocusScope {
  id: engine

  property var service: null
  property var subjectIds: []

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"
  readonly property color okColor: "#93c01f"

  signal exit()

  property alias cardItem: card

  // "loading" | "ready" | "review" | "summary" | "error"
  property string phase: "loading"
  property bool dryRun: true
  property string errorText: ""
  // "ask" -> show the start screen; "dry-run" / "live" -> straight into it
  property string mode: "ask"

  // per-subject: { mOK, rOK, mWrong, rWrong, needsR, sent }
  property var items: ({})
  // completed items in finish order, for the ✓ "Last Answers" panel:
  // [{ id, mWrong, rWrong, needsR, stageName, up, pass }]
  property var answerLog: []
  property var queue: []                // [{ id, type }]
  property int pos: 0
  property int totalSubjects: 0
  property int submittedCount: 0
  property int answerCount: 0
  property int correctCount: 0
  property bool built: false

  readonly property var current: (pos >= 0 && pos < queue.length) ? queue[pos] : null
  readonly property var currentSubject: (current && service)
    ? service.subjectDetail(current.id) : null
  readonly property real progress: totalSubjects > 0
    ? submittedCount / totalSubjects : 0

  // never pull keyboard focus while off-screen -- onPhaseChanged fires as
  // the engine builds in the background (e.g. a queue prefetched while you're
  // on another page) and an invisible FocusScope that grabs focus leaves the
  // visible page's keys dead
  function _grabFocus() { if (engine.visible) engine.forceActiveFocus() }

  // re-entering the view before begin() has run again: clear a terminal
  // screen so its window-wide Enter/Esc -> exit() shortcut can't fire on
  // the keypress that's meant to start the next session
  function rearm() {
    if (phase === "summary" || phase === "error") {
      built = false
      errorText = ""
      phase = "loading"
    }
  }

  function begin() {
    // don't tear down a run that's already going / finished
    if (phase === "review" || phase === "summary") return
    items = ({})
    answerLog = []
    queue = []
    pos = 0
    totalSubjects = 0
    submittedCount = 0
    answerCount = 0
    correctCount = 0
    built = false
    errorText = ""
    if (service) service.resetReviewSubmits()
    var ids = (subjectIds || []).map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
    if (ids.length === 0) { phase = "error"; errorText = "No reviews are due right now."; return }
    totalSubjects = ids.length
    phase = "loading"
    if (service) {
      service.loadDetail(ids.slice(0, 100))
      service.preloadAudio(ids)   // warm the audio cache for the whole batch
    }
    tryBuild()
  }

  function tryBuild() {
    // only while we're actually loading a batch -- onDetailReady fires this
    // on every detail fetch anywhere in the app, and an empty id list would
    // otherwise "succeed" and flip an idle engine to ready
    if (built || !service || phase !== "loading") return
    var ids = (subjectIds || []).map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) }).slice(0, 100)
    if (ids.length === 0) return
    if (!ids.every(function (x) { return !!service.subjectDetail(x) })) return

    var it = ({})
    var q = []
    ids.forEach(function (id) {
      var s = service.subjectDetail(id)
      var kind = s ? String(s.object || "") : ""
      var needsR = (kind === "kanji" || kind === "vocabulary")
      it[id] = { mOK: false, rOK: false, mWrong: 0, rWrong: 0, needsR: needsR, sent: false }
      q.push({ id: id, type: "meaning" })
      if (needsR) q.push({ id: id, type: "reading" })
    })
    for (var i = q.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var t = q[i]; q[i] = q[j]; q[j] = t
    }
    items = it
    queue = q
    totalSubjects = ids.length
    built = true
    phase = "ready"
    // skip the start screen when the mode is pinned in settings
    if (mode === "dry-run" || mode === "live") {
      dryRun = (mode === "dry-run")
      Qt.callLater(startRun)
    }
  }

  function subjectComplete(rec) {
    return rec && rec.mOK && (!rec.needsR || rec.rOK)
  }

  // the "→ Guru" / "↓ Apprentice" chip shown as a subject finishes. In a dry
  // run WaniKani isn't consulted, so the new stage is computed the same way
  // it does: pass -> +1, miss -> current - ceil(misses/2) * (2 at Guru+, else 1)
  property var pill: null
  function srsName(stage) {
    if (stage <= 0) return "Lesson"
    if (stage <= 4) return "Apprentice"
    if (stage <= 6) return "Guru"
    if (stage === 7) return "Master"
    if (stage === 8) return "Enlightened"
    return "Burned"
  }
  function nextStage(cur, misses) {
    if (misses <= 0) return Math.min(9, cur + 1)
    var adj = Math.ceil(misses / 2)
    var penalty = cur >= 5 ? 2 : 1
    return Math.max(1, cur - adj * penalty)
  }

  function finishIfComplete(rec, id) {
    if (!subjectComplete(rec) || rec.sent) return
    rec.sent = true
    submittedCount += 1
    var s = engine.currentSubject
    var cur = (s && s.assignment && isFinite(s.assignment.srs_stage))
      ? s.assignment.srs_stage : 0
    var misses = (rec.mWrong || 0) + (rec.rWrong || 0)
    var ns = engine.nextStage(cur, misses)
    engine.pill = { text: engine.srsName(ns), pass: misses === 0, up: ns > cur }
    engine.answerLog = engine.answerLog.concat([{
      id: id, mWrong: rec.mWrong || 0, rWrong: rec.rWrong || 0,
      needsR: rec.needsR === true, stageName: engine.srsName(ns),
      up: ns > cur, pass: misses === 0
    }])
    if (service)
      service.submitReview(id, rec.mWrong, rec.rWrong, engine.dryRun)
  }

  function onAnswered(correct) {
    if (!current) return
    var id = current.id
    var type = current.type
    var it = items
    var rec = it[id]
    answerCount += 1
    if (correct) {
      correctCount += 1
      if (type === "meaning") rec.mOK = true
      else rec.rOK = true
      finishIfComplete(rec, id)
    } else {
      if (type === "meaning") rec.mWrong += 1
      else rec.rWrong += 1
      var again = { id: id, type: type }
      var at = Math.min(queue.length, pos + 4)
      var nq = queue.slice()
      nq.splice(at, 0, again)
      queue = nq
    }
    items = it
  }

  function onAdvance() {
    engine.pill = null
    // skip any queued questions for a subject that's already complete
    var next = pos + 1
    while (next < queue.length && subjectComplete(items[queue[next].id])) next += 1
    if (next >= queue.length) {
      phase = "summary"
      Qt.callLater(engine._grabFocus)
    } else {
      pos = next
    }
  }

  Connections {
    target: engine.service
    enabled: engine.service !== null
    function onDetailReady(ids) { engine.tryBuild() }
    function onReviewSubmitFailed(subjectId, message) {
      engine.errorText = "Submit failed for a review: " + message
        + "\n\nWaniKani may or may not have recorded it -- check the site."
      engine.phase = "error"
    }
  }

  // keep keyboard focus on the engine whenever the quiz card isn't the thing
  // being driven, so the start / summary / error screens catch keys directly
  onPhaseChanged: {
    if (phase === "ready" || phase === "loading"
        || phase === "summary" || phase === "error")
      Qt.callLater(engine._grabFocus)
    if (phase === "ready") readyIndex = 1
  }

  // start screen: 0 = the dry-run toggle, 1 = the Start button
  property int readyIndex: 1

  // a focused item still gets key events while hidden -- don't eat Enter/Esc
  // (or the "ready" screen's catch-all) once this isn't the visible view, or
  // the home menu you land on after wrapping out goes keyboard-dead
  Keys.enabled: engine.visible

  Keys.onPressed: function (e) {
    if ((phase === "summary" || phase === "error")
        && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Escape)) {
      engine.exit()
      e.accepted = true
    } else if (phase === "ready") {
      if (e.text === "d" || e.text === "D") { engine.dryRun = !engine.dryRun; e.accepted = true }
      else if (e.key === Qt.Key_Up || e.key === Qt.Key_Left || e.text === "k" || e.text === "h") {
        engine.readyIndex = 0; e.accepted = true
      } else if (e.key === Qt.Key_Down || e.key === Qt.Key_Right || e.text === "j" || e.text === "l") {
        engine.readyIndex = 1; e.accepted = true
      } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
        if (engine.readyIndex === 0) engine.dryRun = !engine.dryRun
        else engine.startRun()
        e.accepted = true
      } else if (e.key === Qt.Key_Escape) { engine.exit(); e.accepted = true }
      else e.accepted = true   // don't let stray keys leak into the quiz card
    }
  }

  function startRun() {
    if (queue.length === 0) { phase = "error"; errorText = "Nothing to review."; return }
    phase = "review"
    Qt.callLater(function () { if (card.visible) card.forceActiveFocus() })
  }

  // Shortcuts fire window-wide, so d / Enter work on the start screen even
  // when the nested focus chain hasn't settled on this FocusScope.
  Shortcut {
    sequences: ["d"]
    enabled: engine.visible && engine.phase === "ready"
    onActivated: engine.dryRun = !engine.dryRun
  }
  Shortcut {
    sequences: ["Return", "Enter"]
    enabled: engine.visible && (engine.phase === "ready"
      || engine.phase === "summary" || engine.phase === "error")
    onActivated: {
      if (engine.phase !== "ready") { engine.exit(); return }
      if (engine.readyIndex === 0) engine.dryRun = !engine.dryRun
      else engine.startRun()
    }
  }

  Rectangle { anchors.fill: parent; color: engine.pageBg }

  // ---- loading ----
  Text {
    anchors.centerIn: parent
    visible: engine.phase === "loading"
    text: "Loading reviews…"
    color: Qt.darker(engine.fg, 1.4)
    font.family: engine.fontFamily
    font.pixelSize: Style.font.body
  }

  // ---- start screen ----
  Column {
    anchors.centerIn: parent
    visible: engine.phase === "ready"
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
      text: engine.totalSubjects + " reviews"
      color: engine.fg
      font.family: engine.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true
    }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: dryRow.implicitWidth + Style.space(28)
      height: Style.space(40)
      radius: Style.space(6)
      color: engine.dryRun
        ? Qt.rgba(engine.fg.r, engine.fg.g, engine.fg.b, 0.1)
        : Qt.rgba(engine.okColor.r, engine.okColor.g, engine.okColor.b, 0.22)
      border.width: engine.readyIndex === 0 ? 2 : 1
      border.color: engine.readyIndex === 0 ? engine.fg
        : engine.dryRun
          ? Qt.rgba(engine.fg.r, engine.fg.g, engine.fg.b, 0.28)
          : engine.okColor

      Row {
        id: dryRow
        anchors.centerIn: parent
        spacing: Style.space(8)
        Text {
          text: engine.dryRun ? "Dry run — nothing is sent" : "LIVE — reviews will be submitted"
          color: engine.fg
          font.family: engine.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          text: "(d to toggle)"
          color: Qt.darker(engine.fg, 1.6)
          font.family: engine.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: engine.dryRun = !engine.dryRun
      }
    }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: startLbl.implicitWidth + Style.space(44)
      height: Style.space(44)
      radius: Style.space(6)
      color: Qt.rgba(engine.fg.r, engine.fg.g, engine.fg.b,
        (startHover.containsMouse || engine.readyIndex === 1) ? 0.2 : 0.12)
      border.width: engine.readyIndex === 1 ? 2 : 1
      border.color: engine.readyIndex === 1
        ? engine.fg : Qt.rgba(engine.fg.r, engine.fg.g, engine.fg.b, 0.3)
      Text {
        id: startLbl
        anchors.centerIn: parent
        text: engine.dryRun ? "Start dry run  ›" : "Start reviews  ›"
        color: engine.fg
        font.family: engine.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      MouseArea {
        id: startHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: engine.startRun()
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: "j / k  move   ·   Enter  select   ·   Esc  go back"
      color: Qt.darker(engine.fg, 1.9)
      font.family: engine.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- the quiz ----
  QuizCard {
    id: card
    anchors.fill: parent
    visible: engine.phase === "review" && engine.currentSubject !== null
    // never let the (hidden) quiz field hold focus on the start screen --
    // that's how stray "d" presses ended up typed into the first review
    enabled: engine.phase === "review"
    service: engine.service
    subject: engine.currentSubject
    studyMaterial: subject && subject.study_material ? subject.study_material : null
    questionType: engine.current ? engine.current.type : "meaning"
    progress: engine.progress
    // a review must not let f peek the half you haven't answered yet
    restrictInfo: true
    meaningDone: engine.current && engine.items[engine.current.id]
      ? engine.items[engine.current.id].mOK === true : false
    readingDone: engine.current && engine.items[engine.current.id]
      ? engine.items[engine.current.id].rOK === true : false
    srsPill: engine.pill
    reviewMode: true
    answerLog: engine.answerLog
    pageBg: engine.pageBg
    fg: engine.fg
    fontFamily: engine.fontFamily
    jpFamily: engine.jpFamily
    radicalColor: engine.radicalColor
    kanjiColor: engine.kanjiColor
    vocabColor: engine.vocabColor
    onAnswered: function (correct) { engine.onAnswered(correct) }
    onAdvance: engine.onAdvance()
    onWrapUp: { engine.phase = "summary"; Qt.callLater(engine._grabFocus) }
    onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
  }

  // dry-run badge over the quiz (top-left, out of the way of the counts)
  Rectangle {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.topMargin: Style.space(10)
    anchors.leftMargin: Style.space(12)
    visible: engine.phase === "review" && engine.dryRun && !card.anyOverlay
    width: dryBadge.implicitWidth + Style.space(16)
    height: Style.space(22)
    radius: Style.space(4)
    color: Qt.rgba(0, 0, 0, 0.5)
    z: 6
    Text {
      id: dryBadge
      anchors.centerIn: parent
      text: "DRY RUN"
      color: "#fcfdfd"
      font.family: engine.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // session counts, top-right -- icon + value, like the website: accuracy,
  // items completed, items remaining
  Row {
    id: countRow
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(12)
    anchors.rightMargin: Style.space(16)
    // stays visible over the item-info overlay (matches the mockup)
    visible: engine.phase === "review"
    spacing: Style.space(12)
    z: 26

    readonly property int pctAcc: engine.answerCount > 0
      ? Math.round(100 * engine.correctCount / engine.answerCount) : 100
    readonly property int remain: Math.max(0, engine.totalSubjects - engine.submittedCount)

    Repeater {
      model: [
        { g: "󰔓", v: countRow.pctAcc + "%" },
        { g: "󰄬", v: String(engine.submittedCount) },
        { g: "󰂺", v: String(countRow.remain) }
      ]
      delegate: Row {
        spacing: Style.space(4)
        Text {
          text: modelData.g
          color: Qt.rgba(1, 1, 1, 0.92)
          font.family: engine.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: modelData.v
          color: "#fcfdfd"
          font.family: engine.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  // ---- summary / error ----
  Column {
    anchors.centerIn: parent
    visible: engine.phase === "summary" || engine.phase === "error"
    spacing: Style.space(12)
    width: Math.min(parent.width - Style.space(80), Style.space(460))

    Image {
      anchors.horizontalCenter: parent.horizontalCenter
      source: Qt.resolvedUrl("wordmark.svg")
      height: Style.space(44)
      fillMode: Image.PreserveAspectFit
      sourceSize.width: 1893
      smooth: true
      mipmap: true
      width: Math.min(implicitWidth, parent.width)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: engine.phase === "error" ? "Stopped" : "Reviews done"
      color: engine.fg
      font.family: engine.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      visible: text !== ""
      text: {
        if (engine.phase === "error") return engine.errorText
        var acc = engine.answerCount > 0
          ? Math.round(100 * engine.correctCount / engine.answerCount) : 100
        return engine.submittedCount + " / " + engine.totalSubjects + " submitted"
          + (engine.dryRun ? " (dry run — nothing was sent)" : "")
          + "\n" + acc + "% accuracy over " + engine.answerCount + " answers"
      }
      color: Qt.darker(engine.fg, 1.35)
      font.family: engine.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Enter to finish"
      color: Qt.darker(engine.fg, 1.9)
      font.family: engine.fontFamily
      font.pixelSize: Style.font.caption
      topPadding: Style.space(6)
    }
  }
}
