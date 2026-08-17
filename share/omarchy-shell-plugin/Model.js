.pragma library

// Pure helpers for the prayer widget. No Qt types and no I/O, so the logic
// here stays trivially checkable. Every prayer-time calculation lives in Ruby
// (`omarchy-prayer status --json`); this file only formats what it is handed.

// Seconds -> "1h 57m" / "8m", or compact "1:57" / "8m". Never negative.
function formatCountdown(secs, compact) {
  if (!isFinite(secs) || secs < 0) secs = 0
  var h = Math.floor(secs / 3600)
  var m = Math.floor((secs % 3600) / 60)
  if (h <= 0) return m + "m"
  if (!compact) return h + "h " + m + "m"
  return h + ":" + (m < 10 ? "0" + m : m)
}

// Quiet-until-near: stay collapsed to the glyph while the next prayer is
// further away than the threshold. 0 disables.
function shouldCollapse(secs, quietMinutes) {
  if (!quietMinutes || quietMinutes <= 0) return false
  return secs > quietMinutes * 60
}

// Substitute the pill placeholders. Runs on every countdown tick, so it stays
// allocation-light and side-effect free.
//
// The countdown substitution is prefixed with U+200E (LEFT-TO-RIGHT MARK).
// When {prayer} is an RTL string (e.g. Arabic "العشاء"), the bidi algorithm
// can pull leading LTR digits of the adjacent countdown across the RTL run,
// visually reordering "1h 26m" around the prayer name. The LRM anchors the
// countdown's direction without adding a visible character or touching the
// format string itself (which would break the Latin case).
function renderPill(format, city, prayer, time, countdown) {
  return String(format === undefined || format === null ? "" : format)
    .replace(/\{city\}/g, city || "")
    .replace(/\{prayer\}/g, prayer || "")
    .replace(/\{time\}/g, time || "")
    .replace(/\{countdown\}/g, countdown ? "‎" + countdown : "")
}

function secondsUntil(epochSeconds, nowMs) {
  return Math.floor(epochSeconds - (nowMs / 1000))
}

function isSoon(secs, thresholdMinutes) {
  var threshold = (thresholdMinutes === undefined || thresholdMinutes === null)
    ? 10 : thresholdMinutes
  return Math.floor(secs / 60) < threshold
}

// Row label in the panel: the live countdown for the next prayer, "passed"
// for ones already gone, blank for prayers still ahead today.
function rowTag(prayer, nextName, countdown) {
  if (!prayer) return ""
  if (prayer.name === nextName) return countdown
  return prayer.passed ? "passed" : ""
}

// "Qibla 244° WSW"
function qiblaLabel(qibla) {
  if (!qibla) return ""
  return "Qibla " + qibla.degrees + "° " + qibla.compass
}

// "Method Makkah · cache"
//
// The "Method" label is load-bearing: this sits on the same row as the qibla
// bearing, and several calculation methods are named after cities — "Makkah",
// "Karachi", "Tehran". Unlabelled, "Makkah" next to a bearing reads as the
// qibla target rather than the method. The TUI labels these for the same
// reason.
function sourceLabel(method, source) {
  var parts = []
  if (method) parts.push("Method " + method)
  if (source) parts.push(source)
  return parts.join(" · ")
}
