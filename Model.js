// Pure helpers for the OmaWaniKani plugin: parsing the helper's JSON and turning
// counts and timestamps into the strings the bar and the dashboard render. Kept
// out of the QML so the formatting rules live in one place.

// The helper always prints one JSON object, but a crashed interpreter or a
// missing python3 leaves noise -- treat anything unparseable as a failed
// refresh rather than letting the panel bind to undefined.
function parsePayload(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "The WaniKani helper returned nothing" }
  try {
    var payload = JSON.parse(text)
    if (!payload || typeof payload !== "object") throw new Error("not an object")
    return payload
  } catch (e) {
    return { ok: false, error: "Could not read the WaniKani helper output" }
  }
}

function parseStamp(value) {
  var text = String(value || "").trim()
  if (text === "") return null
  var millis = Date.parse(text)
  return isNaN(millis) ? null : new Date(millis)
}

// "now", "in 47m", "in 3h 20m", "in 2 days", "" when unknown.
function relativeTime(stamp, now) {
  var when = parseStamp(stamp)
  if (!when || !now) return ""
  var seconds = Math.round((when.getTime() - now.getTime()) / 1000)
  if (seconds <= 30) return "now"
  if (seconds < 3600) return "in " + Math.max(1, Math.round(seconds / 60)) + "m"
  if (seconds < 86400) {
    var hours = Math.floor(seconds / 3600)
    var minutes = Math.round((seconds % 3600) / 60)
    return "in " + hours + "h" + (minutes > 0 ? " " + minutes + "m" : "")
  }
  return "in " + Math.round(seconds / 86400) + " days"
}

function plural(n, one, many) {
  n = Math.max(0, Math.round(Number(n) || 0))
  return n + " " + (n === 1 ? one : many)
}

// The bar tooltip.
function barTooltip(view, now) {
  if (!view || view.ok === false)
    return "WaniKani\n\n" + String((view && view.error) || "Not connected")
  if (!view.configured)
    return "WaniKani\n\nClick to connect your API token"

  var lines = []
  lines.push(plural(view.lessonsNow, "lesson", "lessons")
             + "  ·  " + plural(view.reviewsNow, "review", "reviews"))

  if ((Number(view.reviewsNow) || 0) === 0) {
    var rel = relativeTime(view.nextReviewsAt, now)
    lines.push(rel === "" ? "No reviews scheduled" : "Next review " + rel)
  }

  var who = []
  if (view.level) who.push("Level " + view.level)
  if (view.username) who.push(String(view.username))
  if (who.length) lines.push(who.join("  ·  "))
  if (view.vacation) lines.push("Vacation mode")

  return lines.join("\n")
}

// One-line status under the hero. Errors win over notes.
function statusLine(view) {
  if (!view) return ""
  if (view.ok === false) return String(view.error || "Something went wrong")
  if (view.error) return String(view.error)
  if (view.note) return String(view.note)
  if (!view.configured) return "Paste a WaniKani API token to connect."
  return ""
}
