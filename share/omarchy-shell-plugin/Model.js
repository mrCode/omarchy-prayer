.pragma library

// Pure helpers for the prayer widget. No Qt types and no I/O, so the logic
// here stays trivially checkable. Every prayer-time calculation lives in Ruby
// (`omarchy-prayer status --json`); this file only formats what it is handed.

// Seconds -> "1h 57m" / "8m". Never negative.
function formatCountdown(secs) {
  if (!isFinite(secs) || secs < 0) secs = 0
  var h = Math.floor(secs / 3600)
  var m = Math.floor((secs % 3600) / 60)
  return h > 0 ? (h + "h " + m + "m") : (m + "m")
}

// Substitute the pill placeholders. Runs on every countdown tick, so it stays
// allocation-light and side-effect free.
function renderPill(format, city, prayer, time, countdown) {
  return String(format === undefined || format === null ? "" : format)
    .replace(/\{city\}/g, city || "")
    .replace(/\{prayer\}/g, prayer || "")
    .replace(/\{time\}/g, time || "")
    .replace(/\{countdown\}/g, countdown || "")
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

// "Makkah · cache"
function sourceLabel(method, source) {
  return [method, source].filter(function(v) { return !!v }).join(" · ")
}
