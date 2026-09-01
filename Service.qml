import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The `service` kind: one instance for the whole shell. Owns every piece of
// WaniKani state, does the background polling (summary on the short interval,
// dashboard on a longer one), and fires desktop notifications. The bar widget
// reads it via `shell.serviceFor(...)` and pushes its settings in.
//
// Two worker processes: one for the periodic refresh, one for user actions
// (connect / forget), so a slow refresh never blocks the token form.
Item {
  id: root

  // Injected by the shell for a service-kind plugin.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Pushed in by the bar widget (all bar-widget instances share one shell.json
  // entry, so whichever writes last writes the same thing).
  property var settings: ({})

  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir).replace(/\/$/, "") : ""
  readonly property string helperPath: sourceDir !== ""
    ? sourceDir + "/wanikani.py"
    : String(Qt.resolvedUrl("wanikani.py")).replace(/^file:\/\//, "")

  // `view` is the cheap /summary snapshot (counts, countdown); `dash` is the
  // heavier /dashboard payload (caches synced, everything derived).
  property var view: ({ ok: true, configured: false })
  property var dash: ({})
  property bool configured: false
  property string lastError: ""
  property string note: ""
  property string fetchedAt: ""
  property bool everLoaded: false

  readonly property bool ready: helperPath !== ""
  readonly property bool refreshing: statusProcess.running || dashProcess.running
  readonly property bool actionBusy: tokenProcess.running
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 30, 3600)
  // The dashboard changes slowly (distributions, level progress) and its sync
  // is heavier, so it polls on its own, longer cadence.
  readonly property int dashboardIntervalSec: Math.max(120, refreshIntervalSec * 5)

  readonly property int reviewsNow: Number(view.reviewsNow) || 0
  readonly property int lessonsNow: Number(view.lessonsNow) || 0
  readonly property string nextReviewsAt: String(view.nextReviewsAt || "")
  readonly property int level: Number(view.level) || 0
  readonly property string username: String(view.username || "")
  readonly property bool vacation: view.vacation === true

  // ---- dashboard ----
  readonly property bool dashboardLoaded: dash.ok === true && dash.configured === true
  readonly property bool dashboardBusy: dashProcess.running
  readonly property bool coldStart: dash.coldStart === true
  readonly property var itemSpread: dash.itemSpread || ({})
  readonly property var levelProgress: dash.levelProgress || ({})
  readonly property string projectedLevelUp: String(dash.projectedLevelUp || "")
  readonly property var upcoming: dash.upcoming || []
  readonly property int upcomingTotal: Number(dash.upcomingTotal) || 0
  readonly property var recentlyUnlocked: dash.recentlyUnlocked || []
  readonly property var recentlyBurned: dash.recentlyBurned || []
  readonly property var criticalCondition: dash.criticalCondition || []
  readonly property var extraStudy: dash.extraStudy || ({})

  // ---- full app: subject browser + detail pages ----
  // These are only ever driven by App.qml; the bar widget never touches them.
  // `browseData` is the last level query; `detailCache` accumulates full
  // subject resources across lookups so revisiting a page is instant.
  property var browseData: ({})
  property var detailCache: ({})
  readonly property bool browseBusy: browseProcess.running
  readonly property bool detailBusy: detailProcess.running
  property string browseError: ""
  property string detailError: ""

  // Pronunciation audio: the helper caches the clip and hands back a path,
  // the helper feeds it to a persistent idle mpv (device stays warm, so the
  // clip start isn't clipped). `audioError` surfaces "no audio for this one".
  // `audioPlaying` is a short pulse for the speaker icon -- the daemon plays
  // out of process so we can't watch it directly.
  readonly property bool audioBusy: audioProcess.running
  property bool audioPlaying: false
  property string audioError: ""
  property string lastVoiceActor: ""

  // Review engine: the due-queue and the submit backlog. Submits are
  // serialised (each is a POST) and a failure stops the drain so nothing
  // is double-sent -- the engine re-checks and can resume.
  readonly property bool reviewQueueBusy: reviewQueueProcess.running
  property string reviewQueueError: ""
  property var reviewSubmitQueue: []
  // subject ids already sent this session -- a POST /reviews for an item
  // that's already been reviewed makes its assignment un-available again and
  // WK 422s the retry with "created_at must be in the acceptable time range"
  property var reviewSubmittedIds: ({})
  function resetReviewSubmits() { reviewSubmittedIds = ({}); reviewSubmitQueue = [] }
  readonly property bool reviewSubmitBusy: reviewSubmitProcess.running
  property string reviewSubmitError: ""

  // Lesson flow -- same serialised-submit shape as reviews.
  readonly property bool lessonQueueBusy: lessonQueueProcess.running
  property string lessonQueueError: ""
  property var lessonStartQueue: []
  readonly property bool lessonStartBusy: lessonStartProcess.running
  property string lessonStartError: ""

  signal browseReady(int level)
  signal detailReady(var ids)
  signal audioPlayed(string voiceActor)
  signal reviewsReady(var ids)
  signal reviewSubmitted(var result)
  signal reviewSubmitFailed(int subjectId, string message)
  signal lessonsReady(var ids, int total)
  signal lessonStarted(var result)
  signal lessonStartFailed(int subjectId, string message)

  signal tokenRejected(string message)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var parsed = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(parsed)) parsed = fallback
    return Math.max(min, Math.min(max, parsed))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true" || value === 1
  }

  // ---------------------------------------------------------------- commands

  // The notification flags the helper's summary / dashboard commands take,
  // derived from the bar widget's settings. The helper stays silent until its
  // first snapshot and while on vacation, so passing these always is safe.
  function summaryArgs() {
    var out = ["summary", "--notify-reviews",
               String(intSetting("notifyReviewsThreshold", 25, 0, 500))]
    if (boolSetting("notifyLessons", true)) out.push("--notify-lessons")
    if (boolSetting("notifyLevelUp", true)) out.push("--notify-levelup")
    return out
  }
  function dashboardArgs() {
    var out = ["dashboard"]
    if (boolSetting("notifyBurns", true)) out.push("--notify-burns")
    return out
  }

  function refresh() {
    if (!ready || statusProcess.running) return
    statusProcess.command = ["python3", helperPath].concat(summaryArgs())
    statusProcess.running = true
  }

  function refreshDashboard() {
    if (!ready || dashProcess.running) return
    dashProcess.command = ["python3", helperPath].concat(dashboardArgs())
    dashProcess.running = true
  }

  // Called when the panel opens: freshen both, but skip the dashboard sync if
  // it ran in the last minute (opening and closing the panel repeatedly should
  // not hammer the API).
  function refreshAll() {
    refresh()
    if (!dashboardLoaded || Date.now() - lastDashboardAt > 60000) refreshDashboard()
  }

  property double lastDashboardAt: 0

  function saveToken(token) {
    var trimmed = String(token || "").trim()
    if (!ready || trimmed === "" || tokenProcess.running) return
    note = "Checking the token with WaniKani…"
    noteChanged()
    tokenProcess.mode = "set"
    tokenProcess.secret = trimmed
    tokenProcess.command = ["python3", helperPath, "set-token"]
    tokenProcess.running = true
  }

  function clearToken() {
    if (!ready || tokenProcess.running) return
    tokenProcess.mode = "clear"
    tokenProcess.secret = ""
    tokenProcess.command = ["python3", helperPath, "clear-token"]
    tokenProcess.running = true
  }

  // Level browser: the slim subjects for one level, from the dashboard's
  // subjects cache (no API call unless the cache is cold). Stepping levels
  // faster than the helper returns must NOT drop the request -- remember the
  // level we want and fire it when the running job finishes, otherwise the
  // browser is stuck showing "Nothing on level N yet."
  property int browseWantedLevel: 0
  property int browseLaunchedLevel: 0
  function loadBrowse(level) {
    var n = parseInt(String(level), 10)
    if (!ready || !isFinite(n)) return
    browseWantedLevel = n
    if (browseProcess.running) return   // picked up in browseProcess.onExited
    _startBrowse(n)
  }
  function _startBrowse(n) {
    browseError = ""
    browseLaunchedLevel = n
    browseProcess.command = ["python3", helperPath, "browse", String(n)]
    browseProcess.running = true
  }

  // Detail pages: full resources for one or more subject ids. The helper
  // serves cached subject records and only fetches ids it's never seen.
  // A request that arrives while one's in flight is buffered, not dropped
  // (that's how a subject page / Recent Lessons could hang on "Loading").
  property var detailPendingIds: []
  function loadDetail(ids) {
    if (!ready) return
    var list = (Array.isArray(ids) ? ids : [ids])
      .map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
    if (list.length === 0) return
    if (detailProcess.running) {
      var merged = detailPendingIds.slice()
      for (var i = 0; i < list.length; i++)
        if (merged.indexOf(list[i]) < 0) merged.push(list[i])
      detailPendingIds = merged
      return
    }
    _startDetail(list)
  }
  function _startDetail(list) {
    detailError = ""
    detailProcess.pending = list
    detailProcess.command = ["python3", helperPath, "detail"].concat(
      list.map(function (x) { return String(x) }))
    detailProcess.running = true
  }

  function subjectDetail(id) {
    var key = String(parseInt(String(id), 10))
    return detailCache[key] || null
  }

  // Play a subject's pronunciation. `voice` is "kyoko" | "kenichi" | "random"
  // | "" (any); `reading` (optional kana) pins a multi-reading word to the
  // reading that was just answered. The helper caches the clip; mpv plays it.
  function playAudio(id, voice, reading) {
    var n = parseInt(String(id), 10)
    if (!ready || audioProcess.running || !isFinite(n)) return
    audioError = ""
    var cmd = ["python3", helperPath, "audio", String(n)]
    if (voice && voice !== "") cmd.push("--voice", String(voice))
    if (reading && String(reading) !== "") cmd.push("--reading", String(reading))
    audioProcess.command = cmd
    audioProcess.running = true
  }

  // Warm the audio cache for a whole review / lesson batch so the first p
  // in the session is instant. Fire-and-forget -- we don't care about output.
  function preloadAudio(ids) {
    if (!ready) return
    var list = (Array.isArray(ids) ? ids : [ids])
      .map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
      .map(function (x) { return String(x) })
    if (list.length === 0) return
    Quickshell.execDetached(["python3", helperPath, "preload-audio"].concat(list))
  }

  function applyAudio(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok !== true || !payload.path) {
      audioError = String(payload.error || "No audio for that subject")
      return
    }
    lastVoiceActor = String(payload.voiceActor || "")
    // the helper already handed the clip to the persistent mpv; just pulse
    // the icon for roughly a clip's length
    audioPlaying = true
    audioPulse.restart()
    audioPlayed(lastVoiceActor)
  }

  Timer {
    id: audioPulse
    interval: 1500
    onTriggered: root.audioPlaying = false
  }

  function applyBrowse(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok === false) {
      browseError = String(payload.error || "Could not load that level")
      return
    }
    browseData = payload
    browseReady(Number(payload.level) || 0)
  }

  // ---- review engine ----

  function loadReviews() {
    if (!ready || reviewQueueProcess.running) return
    reviewQueueError = ""
    reviewQueueProcess.command = ["python3", helperPath, "reviews"]
    reviewQueueProcess.running = true
  }

  function applyReviews(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok !== true) {
      reviewQueueError = String(payload.error || "Could not load the review queue")
      return
    }
    reviewsReady(payload.subjectIds || [])
  }

  // Queue one finished review. `dryRun` true = no POST, the helper just echoes
  // what it would send. Submits drain one at a time.
  function submitReview(id, incorrectMeaning, incorrectReading, dryRun) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    var key = String(n)
    // never send the same subject twice in one session, dry or live
    if (reviewSubmittedIds[key] || reviewSubmitQueue.some(function (j) { return j.id === n })) {
      console.warn("omakani: ignoring duplicate submitReview for", n)
      return
    }
    var next = reviewSubmitQueue.slice()
    next.push({ id: n,
                im: Math.max(0, parseInt(String(incorrectMeaning), 10) || 0),
                ir: Math.max(0, parseInt(String(incorrectReading), 10) || 0),
                dry: dryRun === true })
    reviewSubmitQueue = next
    drainReviewSubmits()
  }

  function drainReviewSubmits() {
    if (!ready || reviewSubmitProcess.running || reviewSubmitQueue.length === 0) return
    var job = reviewSubmitQueue[0]
    var cmd = ["python3", helperPath, "submit-review", String(job.id),
               "--incorrect-meaning", String(job.im),
               "--incorrect-reading", String(job.ir)]
    if (job.dry) cmd.push("--dry-run")
    reviewSubmitProcess.pendingId = job.id
    reviewSubmitProcess.command = cmd
    reviewSubmitProcess.running = true
  }

  function applyReviewSubmit(raw) {
    var payload = Model.parsePayload(raw)
    var job = reviewSubmitQueue.length > 0 ? reviewSubmitQueue[0] : null
    if (payload.ok !== true) {
      // stop the drain -- do not move on, the engine re-checks and resumes
      reviewSubmitError = String(payload.error || "Review submit failed")
      reviewSubmitFailed(job ? job.id : 0, reviewSubmitError)
      return
    }
    reviewSubmitError = ""
    if (job) {
      var m = reviewSubmittedIds
      m[String(job.id)] = true
      reviewSubmittedIds = m
    }
    reviewSubmitQueue = reviewSubmitQueue.slice(1)
    reviewSubmitted(payload)
    drainReviewSubmits()
  }

  // ---- lesson flow (same shape as the review engine) ----

  function loadLessons(batch) {
    if (!ready || lessonQueueProcess.running) return
    lessonQueueError = ""
    var cmd = ["python3", helperPath, "lessons"]
    var n = parseInt(String(batch), 10)
    if (isFinite(n) && n > 0) cmd.push("--batch", String(n))
    lessonQueueProcess.command = cmd
    lessonQueueProcess.running = true
  }

  function applyLessons(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok !== true) {
      lessonQueueError = String(payload.error || "Could not load the lesson queue")
      return
    }
    lessonsReady(payload.subjectIds || [], Number(payload.total) || 0)
  }

  function startLesson(id, dryRun) {
    var n = parseInt(String(id), 10)
    if (!isFinite(n)) return
    var next = lessonStartQueue.slice()
    next.push({ id: n, dry: dryRun === true })
    lessonStartQueue = next
    drainLessonStarts()
  }

  function drainLessonStarts() {
    if (!ready || lessonStartProcess.running || lessonStartQueue.length === 0) return
    var job = lessonStartQueue[0]
    var cmd = ["python3", helperPath, "start-lesson", String(job.id)]
    if (job.dry) cmd.push("--dry-run")
    lessonStartProcess.pendingId = job.id
    lessonStartProcess.command = cmd
    lessonStartProcess.running = true
  }

  function applyLessonStart(raw) {
    var payload = Model.parsePayload(raw)
    var job = lessonStartQueue.length > 0 ? lessonStartQueue[0] : null
    if (payload.ok !== true) {
      lessonStartError = String(payload.error || "Starting the lesson failed")
      lessonStartFailed(job ? job.id : 0, lessonStartError)
      return
    }
    lessonStartError = ""
    lessonStartQueue = lessonStartQueue.slice(1)
    lessonStarted(payload)
    drainLessonStarts()
  }

  function applyDetail(raw, requestedIds) {
    var payload = Model.parsePayload(raw)
    if (payload.ok === false) {
      detailError = String(payload.error || "Could not load that subject")
      return
    }
    var subjects = payload.subjects || {}
    var merged = {}
    var k
    for (k in detailCache) merged[k] = detailCache[k]
    for (k in subjects) merged[String(k)] = subjects[k]
    detailCache = merged
    detailReady(requestedIds || [])
  }

  // ---------------------------------------------------------------- payloads

  // Fire each event the helper flagged as a desktop notification. notify-send
  // routes through the shell's notification server, so Do Not Disturb is
  // honoured for free.
  function fireNotifications(list) {
    if (!Array.isArray(list)) return
    for (var i = 0; i < list.length; i++) {
      var text = String(list[i] && list[i].text || "").trim()
      if (text === "") continue
      Quickshell.execDetached(["notify-send", "-a", "OmaKani",
                               "-h", "string:x-canonical-private-synchronous:omakani-" + String(list[i].id || i),
                               text])
    }
  }

  function apply(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok === false) {
      lastError = String(payload.error || "WaniKani request failed")
      note = ""
      return payload
    }
    view = payload
    configured = payload.configured === true
    lastError = String(payload.error || "")
    note = String(payload.note || "")
    fetchedAt = String(payload.fetchedAt || "")
    everLoaded = true
    if (note !== "") noteTimer.restart()
    fireNotifications(payload.notifications)
    // First time we learn we're connected, pull the dashboard too.
    if (configured && !dashboardLoaded && !dashProcess.running) refreshDashboard()
    return payload
  }

  function applyDashboard(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok === false) {
      lastError = String(payload.error || "WaniKani dashboard request failed")
      return
    }
    dash = payload
    lastDashboardAt = Date.now()
    if (payload.error) lastError = String(payload.error)
    fireNotifications(payload.notifications)
  }

  function helperFailure(text, code) {
    var trimmed = String(text || "").replace(/\s+/g, " ").trim()
    if (trimmed === "") return "wanikani.py exited with code " + code
    return trimmed.length > 160 ? trimmed.substring(0, 157) + "…" : trimmed
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.ready
    onTriggered: root.refresh()
  }

  // A bar exists per monitor, so this service exists per monitor; spread the
  // first refresh so a multi-monitor start does not fire every copy at once.
  Timer {
    id: firstRefresh
    interval: 200 + Math.floor(Math.random() * 2000)
    repeat: false
    running: root.ready
    onTriggered: root.refresh()
  }

  Timer {
    id: noteTimer
    interval: 3200
    repeat: false
    onTriggered: root.note = ""
  }

  Timer {
    id: dashboardTimer
    interval: root.dashboardIntervalSec * 1000
    repeat: true
    running: root.ready && root.configured
    onTriggered: root.refreshDashboard()
  }

  Process {
    id: dashProcess
    running: false
    command: []
    stdout: StdioCollector { id: dashOut; waitForEnd: true }
    stderr: StdioCollector { id: dashErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.helperFailure(dashErr.text, exitCode)
        return
      }
      root.applyDashboard(dashOut.text)
    }
  }

  Process {
    id: browseProcess
    running: false
    command: []
    stdout: StdioCollector { id: browseOut; waitForEnd: true }
    stderr: StdioCollector { id: browseErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.browseError = root.helperFailure(browseErr.text, exitCode)
      else
        root.applyBrowse(browseOut.text)
      // a newer level was asked for while this one ran -- go get it
      if (root.browseWantedLevel > 0 && root.browseWantedLevel !== root.browseLaunchedLevel)
        Qt.callLater(function () { root._startBrowse(root.browseWantedLevel) })
    }
  }

  Process {
    id: detailProcess
    property var pending: []
    running: false
    command: []
    stdout: StdioCollector { id: detailOut; waitForEnd: true }
    stderr: StdioCollector { id: detailErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.detailError = root.helperFailure(detailErr.text, exitCode)
      else
        root.applyDetail(detailOut.text, detailProcess.pending)
      // drain anything that queued up while this ran
      if (root.detailPendingIds.length > 0) {
        var next = root.detailPendingIds
        root.detailPendingIds = []
        Qt.callLater(function () { root._startDetail(next) })
      }
    }
  }

  Process {
    id: audioProcess
    running: false
    command: []
    stdout: StdioCollector { id: audioOut; waitForEnd: true }
    stderr: StdioCollector { id: audioErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.audioError = root.helperFailure(audioErr.text, exitCode)
        return
      }
      root.applyAudio(audioOut.text)
    }
  }

  Process {
    id: reviewQueueProcess
    running: false
    command: []
    stdout: StdioCollector { id: rqOut; waitForEnd: true }
    stderr: StdioCollector { id: rqErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.reviewQueueError = root.helperFailure(rqErr.text, exitCode)
        return
      }
      root.applyReviews(rqOut.text)
    }
  }

  Process {
    id: reviewSubmitProcess
    property int pendingId: 0
    running: false
    command: []
    stdout: StdioCollector { id: rsOut; waitForEnd: true }
    stderr: StdioCollector { id: rsErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.reviewSubmitError = root.helperFailure(rsErr.text, exitCode)
        root.reviewSubmitFailed(reviewSubmitProcess.pendingId, root.reviewSubmitError)
        return
      }
      root.applyReviewSubmit(rsOut.text)
    }
  }

  Process {
    id: lessonQueueProcess
    running: false
    command: []
    stdout: StdioCollector { id: lqOut; waitForEnd: true }
    stderr: StdioCollector { id: lqErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lessonQueueError = root.helperFailure(lqErr.text, exitCode)
        return
      }
      root.applyLessons(lqOut.text)
    }
  }

  Process {
    id: lessonStartProcess
    property int pendingId: 0
    running: false
    command: []
    stdout: StdioCollector { id: lsOut; waitForEnd: true }
    stderr: StdioCollector { id: lsErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lessonStartError = root.helperFailure(lsErr.text, exitCode)
        root.lessonStartFailed(lessonStartProcess.pendingId, root.lessonStartError)
        return
      }
      root.applyLessonStart(lsOut.text)
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.helperFailure(statusErr.text, exitCode)
        return
      }
      root.apply(statusOut.text)
    }
  }

  // The token goes in over stdin so it never appears in this process's argv,
  // which any user on the machine can read out of /proc.
  Process {
    id: tokenProcess
    property string mode: ""
    property string secret: ""
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    stderr: StdioCollector { id: tokenErr; waitForEnd: true }
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = root.helperFailure(tokenErr.text, exitCode)
        if (mode === "set") root.tokenRejected(root.lastError)
        return
      }
      var payload = root.apply(tokenOut.text)
      if (mode === "set" && (payload.ok === false || payload.configured !== true))
        root.tokenRejected(String(payload.error || "WaniKani rejected the API token"))
    }
  }
}
