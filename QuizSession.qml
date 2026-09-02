import QtQuick
import qs.Commons

// Runs a batch of subjects through QuizCard, meaning + reading per subject
// (radicals: name only). A wrong answer requeues that question further back;
// the batch is done when every question has been answered correctly once.
// Used for Extra Study now (no server sync); the lesson flow and review
// engine will wrap it with their own start / POST calls.
FocusScope {
  id: session

  property var subjectIds: []
  property var service: null
  property string title: "Extra Study"

  property color pageBg: Color.background
  property color fg: Color.foreground
  property string fontFamily: Style.font.family
  property string jpFamily: "Noto Sans CJK JP"
  property color radicalColor: "#01a9fd"
  property color kanjiColor: "#fc02a9"
  property color vocabColor: "#a802fd"

  signal exit()

  property alias cardItem: card    // for the app's test IPC

  // queue entries: { id, type: "meaning"|"reading", tries }
  property var queue: []
  property int pos: 0
  property int totalQuestions: 0
  property int clearedQuestions: 0
  property int totalAnswers: 0
  property int correctAnswers: 0
  property var missedIds: ({})       // subjectId -> true, for the summary
  property bool built: false
  property string phase: "loading"   // "loading" | "quiz" | "summary" | "empty"

  readonly property var current: (pos >= 0 && pos < queue.length) ? queue[pos] : null
  readonly property var currentSubject: (current && service)
    ? service.subjectDetail(current.id) : null
  readonly property real progress: totalQuestions > 0
    ? clearedQuestions / totalQuestions : 0

  // never pull focus while off-screen (background build on another page)
  function _grabFocus() { if (session.visible) session.forceActiveFocus() }

  // re-entering the view before start() has run again: clear a terminal
  // screen so its window-wide Enter/Esc -> exit() shortcut can't fire on
  // the keypress meant to start the next session
  function rearm() {
    if (phase === "summary" || phase === "empty") phase = "loading"
  }

  // "<id>:meaning" / "<id>:reading" -> true, once cleared this session. Drives
  // the f-info anti-cheat fold the same way the review engine's per-item
  // mOK/rOK does.
  property var _cleared: ({})

  // Last Answers log -- one card per subject the moment its first answer
  // lands, every typed guess appended, and a plain current-stage chip (no
  // ↑ / ↓ -- Extra Study never moves SRS) once the subject is done. Same
  // shape the review engine feeds QuizCard; cleared by start().
  property var answerLog: []
  function _srsName(stage) {
    if (stage <= 0) return "Lesson"
    if (stage <= 4) return "Apprentice"
    if (stage <= 6) return "Guru"
    if (stage === 7) return "Master"
    if (stage === 8) return "Enlightened"
    return "Burned"
  }
  function _needsReading(id) {
    var s = service && service.subjectDetail(id)
    var kind = s ? String(s.object || "") : ""
    return kind === "kanji" || kind === "vocabulary"
  }
  function _subjectDone(id) {
    return _cleared[id + ":meaning"] === true
      && (!_needsReading(id) || _cleared[id + ":reading"] === true)
  }
  function _logTouch(id, type, guess) {
    var log = answerLog.slice()
    var e = null
    for (var i = 0; i < log.length; i++)
      if (log[i].id === id) { e = log.splice(i, 1)[0]; break }
    if (!e)
      e = { id: id, needsR: _needsReading(id), mGuesses: [], rGuesses: [],
            done: false, pass: true, up: null, stageName: "" }
    if (type === "meaning") e.mGuesses = e.mGuesses.concat([guess])
    else e.rGuesses = e.rGuesses.concat([guess])
    log.unshift(e)
    answerLog = log
  }
  function _logFinish(id) {
    var s = service && service.subjectDetail(id)
    var stage = (s && s.assignment && isFinite(s.assignment.srs_stage))
      ? s.assignment.srs_stage : 0
    var log = answerLog.slice()
    for (var i = 0; i < log.length; i++)
      if (log[i].id === id) {
        log[i].done = true
        log[i].pass = true
        log[i].up = null                 // Extra Study leaves SRS where it is
        log[i].stageName = _srsName(stage)
        break
      }
    answerLog = log
  }

  function start() {
    queue = []
    pos = 0
    totalQuestions = 0
    clearedQuestions = 0
    totalAnswers = 0
    correctAnswers = 0
    missedIds = ({})
    _cleared = ({})
    answerLog = []
    built = false
    _finished = false
    var ids = (subjectIds || []).map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
    if (ids.length === 0) { phase = "empty"; return }
    phase = "loading"
    if (service) service.loadDetail(ids)
    tryBuild()
  }

  function tryBuild() {
    // onDetailReady fires this on every detail fetch app-wide; only act while
    // we're loading our own batch
    if (built || !service || phase !== "loading") return
    var ids = (subjectIds || []).map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
    if (ids.length === 0) return
    var ready = ids.every(function (x) { return !!service.subjectDetail(x) })
    if (!ready) return

    var q = []
    ids.forEach(function (id) {
      var s = service.subjectDetail(id)
      var kind = s ? String(s.object || "") : ""
      q.push({ id: id, type: "meaning", tries: 0 })
      if (kind === "kanji" || kind === "vocabulary")
        q.push({ id: id, type: "reading", tries: 0 })
    })
    // shuffle
    for (var i = q.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var t = q[i]; q[i] = q[j]; q[j] = t
    }
    queue = q
    totalQuestions = q.length
    built = true
    phase = q.length > 0 ? "quiz" : "empty"
    Qt.callLater(function () { if (card.visible) card.forceActiveFocus() })
  }

  Connections {
    target: session.service
    enabled: session.service !== null
    function onDetailReady(ids) { session.tryBuild() }
  }

  function onAnswered(correct, text) {
    totalAnswers += 1
    if (current)
      _logTouch(current.id, current.type,
                { text: String(text || ""), ok: correct === true })
    if (correct) {
      correctAnswers += 1
      clearedQuestions += 1
      if (current) {
        var m = _cleared
        m[current.id + ":" + current.type] = true
        _cleared = m
        if (_subjectDone(current.id)) _logFinish(current.id)
      }
    } else {
      missedIds[current.id] = true
      // requeue this question ~4 slots back
      var again = { id: current.id, type: current.type, tries: current.tries + 1 }
      var at = Math.min(queue.length, pos + 4)
      var next = queue.slice()
      next.splice(at, 0, again)
      queue = next
    }
  }

  // set by a wrapper (LessonFlow) that wants to show its own end screen
  property bool suppressSummary: false
  // Last Answers ( , ) -- on for Extra Study, off inside the lesson quiz
  // (brand-new items, no session history worth flipping back to)
  property bool lastAnswers: !suppressSummary
  property bool _finished: false
  signal completed(int total, int correct, int answers, var missed)

  function onAdvance() {
    if (_finished) return
    if (pos + 1 >= queue.length) {
      _finished = true
      session.completed(totalQuestions, correctAnswers, totalAnswers,
                        Object.keys(missedIds))
      if (!suppressSummary) {
        phase = "summary"
        Qt.callLater(session._grabFocus)
      }
    } else {
      pos += 1
    }
  }

  // a focused item still gets key events while hidden -- don't eat keys when
  // this isn't the visible view (that's how the home menu's Enter/Esc went dead
  // after wrapping a session)
  Keys.enabled: session.visible

  Keys.onPressed: function (e) {
    if (phase === "summary" && (e.key === Qt.Key_Return || e.key === Qt.Key_Enter
        || e.key === Qt.Key_Escape)) {
      session.exit()
      e.accepted = true
    } else if (phase === "empty" && (e.key === Qt.Key_Escape || e.key === Qt.Key_Return)) {
      session.exit()
      e.accepted = true
    }
  }

  // Shortcuts fire window-wide, so Enter / Esc finish the summary even when the
  // nested focus chain hasn't settled on this FocusScope (that's why "Enter to
  // finish" did nothing on the Recent Mistakes done screen).
  Shortcut {
    sequences: ["Return", "Enter", "Esc"]
    enabled: session.visible && (session.phase === "summary" || session.phase === "empty")
    onActivated: session.exit()
  }

  Rectangle { anchors.fill: parent; color: session.pageBg }

  // ---- loading / empty ----
  Text {
    anchors.centerIn: parent
    visible: session.phase === "loading" || session.phase === "empty"
    text: session.phase === "empty"
      ? "Nothing to study here right now.\n\nEsc to go back"
      : "Loading " + session.title + "…"
    horizontalAlignment: Text.AlignHCenter
    color: Qt.darker(session.fg, 1.4)
    font.family: session.fontFamily
    font.pixelSize: Style.font.body
  }

  // ---- the quiz ----
  QuizCard {
    id: card
    anchors.fill: parent
    visible: session.phase === "quiz" && session.currentSubject !== null
    service: session.service
    subject: session.currentSubject
    studyMaterial: subject && subject.study_material ? subject.study_material : null
    questionType: session.current ? session.current.type : "meaning"
    progress: session.progress
    // f-info hides the half you're being tested on, like a real review
    restrictInfo: true
    showLastAnswers: session.lastAnswers
    answerLog: session.answerLog
    meaningDone: session.current
      ? session._cleared[session.current.id + ":meaning"] === true : false
    readingDone: session.current
      ? session._cleared[session.current.id + ":reading"] === true : false
    pageBg: session.pageBg
    fg: session.fg
    fontFamily: session.fontFamily
    jpFamily: session.jpFamily
    radicalColor: session.radicalColor
    kanjiColor: session.kanjiColor
    vocabColor: session.vocabColor
    onAnswered: function (correct, text) { session.onAnswered(correct, text) }
    onAdvance: session.onAdvance()
    onWrapUp: { session.phase = "summary"; Qt.callLater(session._grabFocus) }
    onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
  }

  // ---- summary ----
  Column {
    anchors.centerIn: parent
    visible: session.phase === "summary"
    spacing: Style.space(12)
    width: Math.min(parent.width - Style.space(80), Style.space(420))

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: session.title + " — done"
      color: session.fg
      font.family: session.fontFamily
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: {
        var acc = session.totalAnswers > 0
          ? Math.round(100 * session.correctAnswers / session.totalAnswers) : 100
        return session.totalQuestions + " items  ·  " + acc + "% accuracy"
      }
      color: Qt.darker(session.fg, 1.35)
      font.family: session.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: Object.keys(session.missedIds).length > 0
      text: Object.keys(session.missedIds).length + " tripped you up"
      color: Qt.darker(session.fg, 1.5)
      font.family: session.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Enter to finish"
      color: Qt.darker(session.fg, 1.9)
      font.family: session.fontFamily
      font.pixelSize: Style.font.caption
      topPadding: Style.space(8)
    }
  }
}
