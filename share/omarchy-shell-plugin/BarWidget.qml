import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Next-prayer pill for the Omarchy 4 bar.
//
// All prayer calculation lives in Ruby behind `omarchy-prayer status --json`.
// This widget substitutes placeholders and subtracts timestamps — nothing
// more — so the two bar integrations can never disagree about prayer times.
//
// Two clocks, deliberately separate: the data refreshes on a slow timer (and
// on demand), while the countdown ticks locally every second. Spawning Ruby
// once a second to re-derive a countdown would be waste.
BarWidget {
  id: root
  moduleName: "io.github.mrcode.prayer-times"

  // Parsed status JSON, or null when unavailable.
  property var prayerData: null
  property string errorText: ""
  property int secsRemaining: 0

  readonly property bool ready: prayerData !== null && prayerData.next !== undefined

  readonly property bool compactCountdown: ready && prayerData.pill.compact_countdown === true
  readonly property int quietMinutes: ready ? (prayerData.pill.quiet_until_minutes || 0) : 0

  readonly property string countdown: Model.formatCountdown(secsRemaining, compactCountdown)

  // Collapsed when the preset has no text at all (icon), or while quiet-until-near
  // applies. Either way only the glyph is painted.
  readonly property bool collapsed: ready
    && (String(prayerData.pill.format || "") === ""
        || Model.shouldCollapse(secsRemaining, quietMinutes))

  readonly property string pillText: ready
    ? Model.renderPill(prayerData.pill.format, prayerData.city, prayerData.next.pretty,
                       prayerData.next.time, countdown, prayerData.next.icon)
    : "—"

  // In a collapsed state the pill shows no text, so the times have to stay
  // reachable without a click.
  //
  // Same bidi anchor as Model.renderPill's {countdown} substitution: with an
  // RTL prayer name (prayerData.next.pretty), the countdown's leading LTR
  // digits can get pulled across the RTL run and reorder visually. The
  // U+200E (LEFT-TO-RIGHT MARK) prefix anchors the countdown without adding
  // a visible character or reordering this concatenation.
  readonly property string tooltipLine: ready
    ? (prayerData.next.pretty + " ‎" + countdown)
    : ""

  readonly property bool soon: ready
    && Model.isSoon(secsRemaining, prayerData.pill.soon_threshold_minutes)

  readonly property bool muted: ready && prayerData.muted === true

  // Standing [audio].enabled setting — distinct from `muted`, which is the
  // today-only suppression marker.
  //
  // `audio_enabled` only exists in 0.2.1+. On an older CLI the field is absent,
  // and reporting that as "off" would state the opposite of the truth — so
  // knownAudioState gates every piece of audio UI.
  readonly property bool audioStateKnown: ready && prayerData.audio_enabled !== undefined
  readonly property bool audioEnabled: audioStateKnown && prayerData.audio_enabled === true

  // Nerd Font mosque glyph.
  readonly property string glyph: "󱠧"

  function refresh() {
    if (statusProc.running) return
    statusProc.running = true
    // Quickshell does NOT emit onExited when the binary is missing — it only
    // logs "Process failed to start". Without this watchdog the widget would
    // sit on an empty pill forever, so treat "no data within 5s" as failure.
    startWatchdog.restart()
  }

  function recomputeCountdown() {
    if (!ready) return
    secsRemaining = Model.secondsUntil(prayerData.next.epoch, Date.now())
    // The next prayer has arrived — pull fresh data rather than counting on
    // past it, so Maghrib -> Isha rollover is immediate.
    if (secsRemaining <= 0) refresh()
  }

  function runCommand(cmd) {
    if (root.bar) root.bar.run(cmd)
  }

  function stopAdhan() { runCommand("omarchy-prayer-stop") }

  function muteToday() {
    runCommand("omarchy-prayer mute-today")
    // Give the CLI a moment to write the marker before re-reading it.
    muteRefreshTimer.restart()
  }

  function toggleAudio() {
    runCommand("omarchy-prayer audio toggle")
    // Give the CLI a moment to rewrite config.toml before re-reading it.
    muteRefreshTimer.restart()
  }

  function setPreset(name) {
    runCommand("omarchy-prayer bar preset " + name)
    // Give the CLI a moment to rewrite config.toml before re-reading it.
    muteRefreshTimer.restart()
  }

  function openTui() {
    runCommand("omarchy-launch-floating-terminal-with-presentation omarchy-prayer")
  }

  // ---- Panel hosting. The bar identifies a panel by the widget mounted in
  //      its slot, so open/close/opened must live here and forward inward.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open()  { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }

  function togglePanel() {
    // A panel showing stale times is worse than a brief refresh.
    root.refresh()
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool popoutSwitchClosing:
    panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.mrcode.prayer-times"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void    { root.open() }
    function close(): void   { root.close() }
    function show(): void    { root.open() }
    function hide(): void    { root.close() }
    function toggle(): void  { root.togglePanel() }
  }

  Process {
    id: statusProc
    command: ["omarchy-prayer", "status", "--json"]

    stdout: StdioCollector {
      onStreamFinished: {
        var text = this.text
        if (!text || text.trim() === "") return
        try {
          root.prayerData = JSON.parse(text)
          root.errorText = ""
          startWatchdog.stop()
          root.recomputeCountdown()
        } catch (e) {
          root.prayerData = null
          // `status --json` landed in 0.2.0. An older CLI ignores the flag and
          // prints its human-readable line, so name that case rather than
          // leaving the user with a generic parse failure.
          root.errorText = text.indexOf("date ") === 0
            ? "omarchy-prayer is older than this widget — update to 0.2.0 or newer"
            : "omarchy-prayer: could not read status output"
        }
      }
    }

    onExited: function(exitCode) {
      startWatchdog.stop()
      if (exitCode === 0) return
      root.prayerData = null
      root.errorText = "omarchy-prayer exited " + exitCode
        + " — run `omarchy-prayer` once to set it up"
    }
  }

  // Data changes only at day rollover, on relocate, or on mute. The schedule
  // unit pokes us over IPC for the rest, so this is just a safety net.
  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Countdown ticks locally — no subprocess per second.
  Timer {
    interval: 1000
    running: root.ready
    repeat: true
    onTriggered: root.recomputeCountdown()
  }

  // Fires only when the status command produced neither data nor an exit —
  // i.e. the binary is missing. Someone who installed this plugin on its own
  // (from the marketplace) has the widget but not the CLI it fronts.
  Timer {
    id: startWatchdog
    interval: 5000
    repeat: false
    onTriggered: {
      if (root.prayerData !== null) return
      root.errorText = "omarchy-prayer is not installed — run: yay -S omarchy-prayer"
    }
  }

  Timer {
    id: muteRefreshTimer
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  // What the pill displays. Built here so it can be measured and rendered by
  // OUR label below rather than by WidgetButton's.
  readonly property string buttonText: {
    // The second glyph is U+F026 (muted speaker). Keep the escape rather
    // than retyping the character \u2014 it is invisible in most editors.
    var lead = root.glyph + (root.audioStateKnown && !root.audioEnabled ? " \uf026" : "")
    if (root.vertical || root.collapsed) return lead
    return lead + "  " + root.pillText
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // WidgetButton's own label is a private Text with Qt's AutoText default,
    // which renders markup-shaped input as RICH text and will load <img src>
    // targets. Its textFormat cannot be set from outside the component, and
    // this pill shows configuration- and geolocation-derived values. So we
    // suppress that label and paint our own with plain text enforced here, in
    // this snapshot, instead of relying on every upstream producer to
    // sanitise. Reported by @ryanrhughes; see also Model.plain().
    labelVisible: false
    text: root.buttonText          // kept for tooltip/measurement semantics
    fixedWidth: root.vertical ? -1 : Math.max(12, pillLabel.implicitWidth + Style.spaceReal(8.75) * 2)

    fontSize: Style.font.body
    horizontalMargin: 8.75
    verticalPadding: 8.75
    dimmed: root.muted
    active: root.soon
    useActiveColor: true
    tooltipText: root.errorText !== "" ? root.errorText
               : (root.collapsed && root.tooltipLine !== "" ? root.tooltipLine : "Prayer times")

    onPressed: function(b) {
      if (b === Qt.RightButton) root.stopAdhan()
      else if (b === Qt.MiddleButton) root.openTui()
      else root.togglePanel()
    }

    Text {
      id: pillLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.buttonText
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }
}
