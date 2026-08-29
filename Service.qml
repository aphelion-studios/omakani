import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Owns every piece of WaniKani state the widget and dashboard read, and is the
// only thing here that talks to wanikani.py. Two processes: one for the periodic
// refresh, one for user actions (connect / forget), so a slow refresh never
// blocks the token form.
//
// Instantiated inline by Panel.qml for now; it becomes a real `service` kind
// once the plugin grows a background poller and notifications.
Item {
  id: root

  property var settings: ({})
  property string helperPath: ""

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

  // ---------------------------------------------------------------- commands

  function refresh() {
    if (!ready || statusProcess.running) return
    statusProcess.command = ["python3", helperPath, "summary"]
    statusProcess.running = true
  }

  function refreshDashboard() {
    if (!ready || dashProcess.running) return
    dashProcess.command = ["python3", helperPath, "dashboard"]
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

  // ---------------------------------------------------------------- payloads

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
