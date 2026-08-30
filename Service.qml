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
  // then we hand that to mpv. `audioError` surfaces "no audio for this one".
  readonly property bool audioBusy: audioProcess.running
  property string audioError: ""
  property string lastVoiceActor: ""

  signal browseReady(int level)
  signal detailReady(var ids)
  signal audioPlayed(string voiceActor)

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
  // subjects cache (no API call unless the cache is cold).
  function loadBrowse(level) {
    var n = parseInt(String(level), 10)
    if (!ready || browseProcess.running || !isFinite(n)) return
    browseError = ""
    browseProcess.command = ["python3", helperPath, "browse", String(n)]
    browseProcess.running = true
  }

  // Detail pages: full resources for one or more subject ids. The helper
  // fetches /subjects?ids=... fresh and folds in study materials.
  function loadDetail(ids) {
    if (!ready || detailProcess.running) return
    var list = (Array.isArray(ids) ? ids : [ids])
      .map(function (x) { return parseInt(String(x), 10) })
      .filter(function (x) { return isFinite(x) })
    if (list.length === 0) return
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
  // | "" (any). The helper downloads + caches the clip; we play it with mpv.
  function playAudio(id, voice) {
    var n = parseInt(String(id), 10)
    if (!ready || audioProcess.running || !isFinite(n)) return
    audioError = ""
    var cmd = ["python3", helperPath, "audio", String(n)]
    if (voice && voice !== "") cmd.push("--voice", String(voice))
    audioProcess.command = cmd
    audioProcess.running = true
  }

  function applyAudio(raw) {
    var payload = Model.parsePayload(raw)
    if (payload.ok !== true || !payload.path) {
      audioError = String(payload.error || "No audio for that subject")
      return
    }
    lastVoiceActor = String(payload.voiceActor || "")
    Quickshell.execDetached(["mpv", "--no-video", "--no-terminal",
                             "--really-quiet", String(payload.path)])
    audioPlayed(lastVoiceActor)
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
      if (exitCode !== 0) {
        root.browseError = root.helperFailure(browseErr.text, exitCode)
        return
      }
      root.applyBrowse(browseOut.text)
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
      if (exitCode !== 0) {
        root.detailError = root.helperFailure(detailErr.text, exitCode)
        return
      }
      root.applyDetail(detailOut.text, detailProcess.pending)
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
