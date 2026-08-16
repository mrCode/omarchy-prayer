# Omarchy 4 support: Quickshell bar widget, structured status producer, compat fixes

## Motivation

Omarchy 4.0.0 ("Quarto") replaces waybar with a Quickshell-based shell (`omarchy-shell`) and mako with an in-shell notification daemon. An end-to-end audit of v0.1.7 on Omarchy 4.0.0 found the scheduler, prayer-time calculation, notification delivery and TUI all healthy, but five integration points broken or silently degraded:

1. **No bar widget.** `~/.config/waybar/` does not exist. `omarchy-prayer-waybar` still emits correct JSON that nothing consumes. The headline feature — a live next-prayer countdown on the bar — is simply absent.
2. **Theme detection silently falls back.** `Theme.parse_theme_file` reads `~/.config/omarchy/current/alacritty.toml`; on Omarchy 4 the current theme lives at `~/.local/state/omarchy/current/theme/alacritty.toml`. The file check fails, `{}` is returned, and the TUI renders its built-in palette while appearing to work.
3. **Do-not-disturb is ignored.** `Notifier#dnd?` shells `makoctl mode`, which now fails with `No such object path '/fr/emersion/Mako'`. `respect_silencing = true` became a no-op, so the adhan plays during DND.
4. **`setup` reports work it did not do.** `ensure_waybar_module` returns early when no waybar config exists, contributing nothing to `done`, so `cmd_setup` prints `already set up (adhan audio, waybar widget, systemd timer)` — claiming a widget that does not exist.
5. **Packaging pulls dead dependencies.** `depends=(… mako waybar …)` installs two packages Omarchy 4 does not use.

Fixes 2–5 are small and independent. The bar widget is the substantial work and drives the shape of this design.

## Constraints discovered

- `PluginRegistry.qml:11` hardcodes `pluginsDir: home + "/.config/omarchy/plugins"`. There is no system-wide third-party plugin directory, so **a pacman package cannot own the live plugin files** — something must copy them into `$HOME`.
- Third-party plugin IDs are not validated (`Util.canonicalWidgetId` is identity). `__isFirstParty` is stamped by source directory, so a plugin under `~/.config/omarchy/plugins/` is automatically third-party and user-disableable.
- Omarchy ships **no generic command-output widget**. There is no waybar-`custom/`-equivalent; a bar widget must be QML.
- Plugin code and `shell.json` hot-reload on save; `omarchy-shell shell rescanPlugins` forces a reload.
- `omarchy-shell notifications isDnd` returns `on`/`off` and is the DND replacement for `makoctl mode`.
- Subprocess cost of the Ruby producer is ~43 ms per invocation.

## Design

### Data producer: `omarchy-prayer status --json`

Ruby remains the single source of truth for every calculation. A new `OmarchyPrayer::Status` module builds one structured Hash, serialized by a `--json` flag on the existing `status` subcommand:

```json
{
  "city": "Riyadh",
  "country": "SA",
  "date": "2026-08-16",
  "hijri": "3 Rabīʿ al-awwal 1448",
  "prayers": [
    {"name": "fajr",    "pretty": "Fajr",    "time": "04:05", "epoch": 1786842300, "passed": true},
    {"name": "dhuhr",   "pretty": "Dhuhr",   "time": "11:57", "epoch": 1786870620, "passed": true},
    {"name": "asr",     "pretty": "Asr",     "time": "15:26", "epoch": 1786883160, "passed": true},
    {"name": "maghrib", "pretty": "Maghrib", "time": "18:27", "epoch": 1786894020, "passed": false},
    {"name": "isha",    "pretty": "Isha",    "time": "19:57", "epoch": 1786899420, "passed": false}
  ],
  "next": {"name": "maghrib", "pretty": "Maghrib", "time": "18:27", "epoch": 1786894020},
  "qibla": {"degrees": 244, "compass": "WSW"},
  "method": "Makkah",
  "source": "cache",
  "muted": false,
  "pill": {"format": "{city} · {prayer} {countdown}", "soon_threshold_minutes": 10}
}
```

`next` may reference tomorrow's Fajr, matching `Today#next_prayer` semantics. `pill.format` is passed through from config so the QML performs substitution only — no formatting policy in QML.

`OmarchyPrayer::Waybar.render` is refactored to derive its `{text, class, tooltip}` from `Status`, so both bars are fed by one code path. Its output must remain **byte-identical** to v0.1.7 for waybar users.

### Bar detection: `OmarchyPrayer::BarDetect`

```ruby
BarDetect.detect → :quickshell | :waybar | :none
```

- `:quickshell` when `omarchy-shell` is on `PATH` **and** either `omarchy-shell shell ping` returns `ok` (shell running) or `/usr/share/omarchy/shell` exists (shell installed but not running — e.g. `setup` invoked over SSH or during package install)
- `:waybar` when a waybar config exists at `$XDG_CONFIG_HOME/waybar/config.jsonc` or `config`
- `:none` otherwise

Detection deliberately does **not** test for `~/.config/omarchy/shell.json`: that file is optional, since the shell falls back to packaged defaults when the user has never customized their bar. Keying on it would misdetect a stock Omarchy 4 install as `:none`.

Quickshell is checked first: on a machine upgraded from Omarchy 3 both may be present (the audit machine still had `waybar` and `mako` binaries as upgrade leftovers), and the live bar is the correct target. Never raises.

### Shell plugin: `prayer.times`

Source lives in the repo at `share/omarchy-shell-plugin/`, ships to `/usr/share/omarchy-prayer/shell-plugin/`, and is copied at setup to `~/.config/omarchy/plugins/prayer.times/`.

| File | Role |
|---|---|
| `manifest.json` | `schemaVersion: 1`, `id: "prayer.times"`, `kinds: ["bar-widget"]`, `entryPoints.barWidget: "BarWidget.qml"` |
| `BarWidget.qml` | The pill. Owns the `Process`, the timers, the `IpcHandler`, and panel hosting. |
| `Panel.qml` | Popup panel (layout below). |
| `Model.js` | Pure helpers: placeholder substitution, countdown formatting, row assembly. No I/O. |

**Bar pill.** Glyph + `{city} · {prayer} {countdown}`, placed in the bar's **right section at index 0** (immediately before the tray). Four visual states:

| State | Appearance |
|---|---|
| Normal | Default foreground |
| Soon | Amber, when remaining minutes < `soon_threshold_minutes` |
| Muted | Dimmed, when `muted` is true; times still shown |
| Error | Glyph + `—`, with the failure reason in the tooltip |

The widget must handle vertical bars (`vertical` property, as `omarchy.clock` does).

**Popup panel.** Opens on left click:

- Header: city + country, Gregorian and Hijri date
- Five rows, each glyph-dotted, with name, time and a status tag (`passed` / countdown for next / blank for later); the next prayer's row is highlighted
- Footer: `Qibla 244° WSW` · `Makkah · cache`
- Actions: **Mute today** (`omarchy-prayer mute-today`) and **Stop adhan** (`omarchy-prayer-stop`)

Click bindings on the pill:

| Click | Action |
|---|---|
| Left | Toggle the popup panel |
| Right | Stop the adhan (`omarchy-prayer-stop`), preserving the waybar binding |
| Middle | Open the TUI in a floating terminal (`omarchy-launch-floating-terminal-with-presentation omarchy-prayer`) |

The middle-click binding exists because the waybar widget opened the TUI on left click; with the panel now taking that slot, the TUI would otherwise become unreachable from the bar. `omarchy.clock` uses the same left/right/middle escalation.

### Data flow and refresh

Two clocks, deliberately separated.

**Data** — `omarchy-prayer status --json` is spawned on:

- component load
- a 5-minute timer
- panel open
- `next.epoch` elapsing (immediate refetch, so Maghrib → Isha rollover is instant)
- IPC: `omarchy-shell -q prayer.times refresh`

**Countdown** — ticks locally every second as `next.epoch − now`, formatted by `Model.js`. This is arithmetic on a timestamp, not a reimplementation of prayer logic; no domain calculation exists in QML.

`omarchy-prayer-schedule` gains a best-effort `omarchy-shell -q prayer.times refresh` after rebuilding the day's timers, so relocation and midnight rollover reach the bar immediately. `-q` swallows failure when the shell is not running.

**Error handling.** Non-zero exit, unparseable JSON, or missing `config.toml` all collapse the pill to its error state with the reason in the tooltip. The widget never renders a partial or stale countdown; if data is unavailable the countdown stops rather than counting into the past.

### Setup and install

`Setup.run` keeps its three-step shape, with the middle step becoming a dispatcher:

```
ensure_default_adhans     (unchanged)
ensure_bar_integration    (new)
  ├─ :quickshell → ShellPlugin.install! [+ enable on first install]
  ├─ :waybar     → existing patcher (unchanged)
  └─ :none       → append an explicit "no supported bar detected" note
ensure_systemd_units      (unchanged)
```

`OmarchyPrayer::ShellPlugin`:

- **Install.** Copy `/usr/share/omarchy-prayer/shell-plugin/` → `~/.config/omarchy/plugins/prayer.times/` when absent, or when the installed copy's version marker differs from the package version. The marker is a `.version` file written into the installed plugin directory containing the package version string. Idempotent.
- **Enable.** `omarchy-shell shell enablePlugin prayer.times '{"section":"right","index":0}'`, backing up `shell.json` to `shell.json.bak.omarchy-prayer-<ts>` first.
- **Enable once only.** A marker in the state directory records that placement has happened. Subsequent `setup` runs keep plugin files current but never re-add the widget — removing it from the bar is a decision the tool respects. This mirrors the waybar patcher, which checks for an existing `custom/prayer` before touching the config.

`cmd_setup`'s "already set up" message is derived from what actually happened, and names the integration actually present.

### Config rename: `[waybar]` → `[bar]`

The section now drives both integrations, so `[waybar]` is renamed `[bar]` with keys unchanged (`format`, `soon_threshold_minutes`). A migration in `migrations.rb` rewrites existing configs in place and prints a one-line stderr notice. Reading falls back to `[waybar]` when `[bar]` is absent, so an unmigrated config never breaks.

### Compat fixes

| Fix | Change |
|---|---|
| Theme path | Resolution chain: `~/.local/state/omarchy/current/theme/alacritty.toml` (v4) → `~/.config/omarchy/current/alacritty.toml` (v3) → built-in defaults |
| DND probe | `omarchy-shell notifications isDnd` (`on`/`off`) → fall back to `makoctl mode` → if neither answers, return `false` and fire, so a probe failure never silently suppresses a prayer |
| Setup honesty | `done` reflects actual work; `:none` reported explicitly |
| PKGBUILD | `depends`: drop `mako` and `waybar`. `optdepends`: `waybar` and `mako` (Omarchy 3 / non-Omarchy Hyprland), `hyprland`. Install plugin to `/usr/share/omarchy-prayer/shell-plugin/` |
| install.sh | Dependency checks branch on `BarDetect`; no waybar/mako warnings when Quickshell is present |

## Testing

Ruby (minitest, existing harness):

- `Status` — JSON shape, `passed` flags either side of a prayer time, `next` crossing into tomorrow's Fajr, `muted` reflecting the mute-today marker
- `Waybar` — renders byte-identically from `Status`; regression guard on existing v0.1.7 output
- `BarDetect` — all three environments with a faked `HOME`/`XDG_CONFIG_HOME`
- `ShellPlugin` — install idempotency, version-marker re-copy, `shell.json` backup, enable-once-only semantics
- `Theme` — resolution across v4 layout, v3 layout, and neither
- `Notifier#dnd?` — `isDnd` present and returning `on`/`off`; `isDnd` absent with `makoctl` present; both absent
- `Migrations` — `[waybar]` → `[bar]`, and reading an unmigrated config

Any test stubbing env vars or module-level constants restores them in `teardown`; the `BarDetect`, `Theme` and `ShellPlugin` tests are precisely the shape that broke the v0.1.5 AUR `check()`.

QML gets no automated harness — the project has none and four files do not justify introducing one. `Model.js` is kept pure so its substitution and countdown logic can be node-tested later if it earns it. Verification is `omarchy-shell shell rescanPlugins` plus a visual check of all four pill states and the panel.

## Out of scope

- Reimplementing prayer calculation, Hijri conversion or qibla bearing in QML
- A Quickshell settings form for the widget (`settingsForm` in the manifest) — config stays in `config.toml`
- Replacing `notify-send` with `omarchy-notification-send`; the freedesktop path works and keeps non-Omarchy Hyprland users supported
- Vertical-bar–specific panel layout beyond making the pill render correctly

## Version

**0.2.0** — new bar integration plus the `[waybar]` → `[bar]` rename.
