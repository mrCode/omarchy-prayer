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
  moduleName: "prayer.times"

  // Parsed status JSON, or null when unavailable.
  property var prayerData: null
  property string errorText: ""
  property int secsRemaining: 0

  readonly property bool ready: prayerData !== null && prayerData.next !== undefined
  readonly property string countdown: Model.formatCountdown(secsRemaining)

  readonly property string pillText: ready
    ? Model.renderPill(prayerData.pill.format, prayerData.city, prayerData.next.pretty,
                       prayerData.next.time, countdown)
    : "—"

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
    if (!statusProc.running) statusProc.running = true
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
    target: "prayer.times"

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
      if (exitCode !== 0) {
        root.prayerData = null
        root.errorText = "omarchy-prayer exited " + exitCode
          + " — run `omarchy-prayer` once to set it up"
      }
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

  Timer {
    id: muteRefreshTimer
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var lead = root.glyph + (root.audioStateKnown && !root.audioEnabled ? " \uf026" : "")
      return root.vertical ? lead : (lead + "  " + root.pillText)
    }
    fontSize: Style.font.body
    horizontalMargin: 8.75
    verticalPadding: 8.75
    dimmed: root.muted
    active: root.soon
    useActiveColor: true
    tooltipText: root.errorText !== "" ? root.errorText : "Prayer times"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.stopAdhan()
      else if (b === Qt.MiddleButton) root.openTui()
      else root.togglePanel()
    }
  }
}
