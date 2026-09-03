// Pure helpers for the OmaKani plugin: parsing the helper's JSON and turning
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

// The client-side settings, mirrored from wanikani.py's _PREF_DEFAULTS. The
// dashboard drop-down and the floating app both render from this one schema so
// they can't drift. `group` orders them into sections; `kind` picks the
// control.
var SETTINGS = [
  { key: "lessonBatchSize", kind: "int", group: "Lessons",
    label: "Preferred lesson batch size", from: 1, to: 20, step: 1, fallback: 5,
    help: "New lessons to learn before each lesson quiz. The last batch may run a little over to avoid a tiny leftover batch." },
  { key: "lessonDailyMax", kind: "int", group: "Lessons",
    label: "Maximum daily lessons", from: 0, to: 100, step: 5, fallback: 15,
    help: "Cap on new lessons per day (0 = no cap). More lessons means more reviews later." },
  { key: "lessonInterleave", kind: "bool", group: "Lessons",
    label: "Interleave lesson item types", fallback: true,
    help: "On: mix radicals / kanji / vocabulary. Off: group by type, then level." },

  { key: "reviewSrsIndicator", kind: "bool", group: "Reviews",
    label: "SRS change indicator during reviews", fallback: true,
    help: "Show the “you moved to Guru” chip as each item finishes." },
  { key: "reviewOrdering", kind: "enum", group: "Reviews",
    label: "Review ordering", fallback: "shuffled",
    options: [
      { value: "shuffled", label: "Shuffled" },
      { value: "apprentice", label: "Apprentice first" },
      { value: "lowsrs", label: "Lower SRS stages first" },
      { value: "lowlevel", label: "Lower levels first" } ],
    help: "Shuffled is best for a queue you clear regularly. The others prioritise what you're likeliest to forget or a backlog." },

  { key: "audioVoice", kind: "enum", group: "Audio",
    label: "Pronunciation voice", fallback: "random",
    options: [
      { value: "random", label: "Random" },
      { value: "kyoko", label: "Kyoko" },
      { value: "kenichi", label: "Kenichi" } ],
    help: "Default voice for vocabulary audio in lessons and reviews." },
  { key: "autoplayLessons", kind: "bool", group: "Audio",
    label: "Autoplay audio in lessons", fallback: false },
  { key: "autoplayReviews", kind: "bool", group: "Audio",
    label: "Autoplay audio in reviews", fallback: false },
  { key: "autoplayExtraStudy", kind: "bool", group: "Audio",
    label: "Autoplay audio in extra study", fallback: false },
];

function settingGroups() {
  var seen = [], out = [];
  for (var i = 0; i < SETTINGS.length; i++)
    if (seen.indexOf(SETTINGS[i].group) < 0) { seen.push(SETTINGS[i].group); out.push(SETTINGS[i].group); }
  return out;
}
function settingsInGroup(group) {
  return SETTINGS.filter(function (s) { return s.group === group; });
}
function enumLabel(row, value) {
  var opts = row.options || [];
  for (var i = 0; i < opts.length; i++) if (opts[i].value === value) return opts[i].label;
  return String(value);
}
function cycleEnum(row, value, dir) {
  var opts = row.options || [];
  var idx = 0;
  for (var i = 0; i < opts.length; i++) if (opts[i].value === value) { idx = i; break; }
  idx = (idx + dir + opts.length) % opts.length;
  return opts[idx].value;
}

// Is the theme background a light one? A plain perceived-luminance test on
// Color.background -- the 5 light Omarchy themes land at ~0.94-1.0, the 17 dark
// ones at ~0.03-0.14, so any threshold in between is safe. This is only a
// background classifier feeding one `lightUi` bool per screen; it is NOT a
// per-element ink picker.
function lightBg(c) {
  if (!c) return false
  return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.5
}

// Colour "chroma" -- how far from grey a colour is (max channel minus min).
// Near-zero for the White theme's near-neutral accent, so callers can swap in
// a saturated hue where a tinted-accent state would otherwise read as grey.
function chroma(c) {
  if (!c) return 0
  return Math.max(c.r, c.g, c.b) - Math.min(c.r, c.g, c.b)
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
