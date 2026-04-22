# omarchy-prayer — Design

**Date:** 2026-04-22
**Status:** Approved for planning

## Summary

`omarchy-prayer` is a Muslim prayer-time notifier for Omarchy (Hyprland / mako / waybar). It fires desktop notifications and plays the adhan at each of the five daily prayers, shows the next prayer in waybar with a live countdown, and exposes a themed full-screen TUI for viewing today's times, qibla direction, and settings. It is written in Ruby, scheduled via `systemd --user` timers, and respects Omarchy's existing notification silencing.

## Goals

- Fire on-time and 10-minute-early notifications for each of the five prayers, every day, without user intervention after first-run setup.
- Play an adhan audio clip at each prayer time (Fajr uses the traditional Fajr variant).
- Show the next prayer and a countdown in waybar, styled with the active Omarchy theme.
- Provide a colorful full-screen TUI (in the spirit of `monitor-tui`) to view today's times, qibla direction, and edit settings.
- Match Omarchy's conventions: scripts in `~/.local/bin/` named `omarchy-prayer-*`, config in `~/.config/omarchy-prayer/`, systemd user units, minimal dependencies.

## Non-goals

- Multiple users / multiple locations at once. One machine, one user, one location.
- Monthly / yearly calendar export, iCal feeds, sharing with other apps.
- Mobile-style "Qibla finder" compass with live sensor data. TUI shows a static bearing only.
- Supporting non-Omarchy distros as a primary target. It should work on generic Hyprland+mako but Omarchy is the reference environment.

## User-confirmed decisions

Captured from brainstorming:

| Decision | Choice |
|---|---|
| Time source | Cache Aladhan API monthly; fall back to cache if offline; fall back to an always-available offline calculator if cache is also stale. |
| Location | Auto-detected on first run via IP geolocation; fully overridable in `config.toml`. |
| Calc method | Auto-picked from detected country; overridable in config. |
| Notifications | mako popup + adhan audio + 10-minute pre-notification. Respect mako silencing. |
| Waybar | Yes — next prayer + live countdown; clickable → opens TUI. |
| Language | Ruby. |
| Scheduling | `systemd --user` transient timers, rebuilt daily at 00:01. |
| UX | Full-screen colorful TUI (like `monitor-tui`). |
| Adhan audio | Fajr-specific variant (`adhan-fajr.mp3`), standard variant for the other four. |
| Extras | Qibla direction in TUI, stop-adhan shortcut, respect mako silencing, 10-min pre-notification. |

## Architecture

### Approach: per-day transient systemd timers

A daily scheduler service runs at 00:01 and rebuilds today's timers:

1. Resolve today's five prayer times (fall-through: API cache → fetch API → offline calc).
2. Cancel any lingering transient timers from a previous run.
3. For each of the five prayers, create two transient timers via `systemd-run --user --on-calendar=...`:
   - One at prayer time → fires on-time notification.
   - One at prayer time minus `pre_notify_minutes` → fires pre-notification.
4. Write `today.json` for waybar and TUI consumers.

Rationale over alternatives:

- **Long-running daemon:** rejected — one more thing to supervise, suspend/resume surface area, and a socket to serve TUI/waybar doesn't buy enough to offset the complexity.
- **Cron-style every-minute poll:** rejected — 1440 wake-ups/day, minute-level imprecision, noisy journal.

Transient timers give clean observability (`systemctl --user list-timers`), survive reboot, and keep the codebase stateless between events.

### Components

```
~/.local/bin/
  omarchy-prayer              # CLI + TUI entry (Ruby)
  omarchy-prayer-schedule     # Daily scheduler (Ruby)
  omarchy-prayer-notify       # Fires one event (Ruby)
  omarchy-prayer-waybar       # Short JSON for waybar custom module
  omarchy-prayer-stop         # Kills any playing adhan

~/.config/omarchy-prayer/
  config.toml                 # User config (TOML)
  adhan.mp3                   # Default audio, user-replaceable
  adhan-fajr.mp3              # Fajr variant

~/.config/systemd/user/
  omarchy-prayer-schedule.service
  omarchy-prayer-schedule.timer   # OnCalendar=*-*-* 00:01:00
  omarchy-prayer-resume.service   # Re-runs scheduler after sleep.target

~/.local/state/omarchy-prayer/
  times-YYYY-MM.json          # Monthly cache from Aladhan
  today.json                  # Today's resolved times + source provenance
  current-adhan.pid           # PID of the currently playing adhan
  mute-today                  # Zero-byte flag: present → skip today (cleared 00:01)
```

### Component responsibilities

**`omarchy-prayer` (CLI / TUI entry)**
- Subcommands: `tui` (default), `today`, `next`, `status`, `test-adhan`, `mute-today`, `refresh`.
- `today` / `next` / `status` print to stdout for quick scripting.
- `tui` launches the full-screen themed interface (see TUI section).
- `refresh` re-invokes `omarchy-prayer-schedule` via `systemctl --user start omarchy-prayer-schedule.service`.

**`omarchy-prayer-schedule`**
- Loads config.
- Resolves today's times with the three-tier fall-through (cache → API → offline calc).
- Writes `today.json` including which source succeeded.
- Purges stale transient timers from a previous day (match by unit name prefix).
- Creates one transient timer per event for today using `systemd-run --user --on-calendar=…`.
- Idempotent — safe to run multiple times per day.

**`omarchy-prayer-notify <prayer> <event>`**
- `event` ∈ `on-time | pre`.
- Reads `today.json` to get the prayer time and location display.
- If `mute-today` exists → exit 0 silently.
- If `respect_silencing` and `makoctl mode` reports DND → exit 0 silently.
- Emits `notify-send` with title/body; on-time notifications include a "Stop adhan" action.
- For on-time events: launches audio via configured player (`mpv --no-video --really-quiet --volume=<n> <file>`) in the background, records PID to `current-adhan.pid`. Writes nothing to PID file for `pre` events.

**`omarchy-prayer-waybar`**
- Reads `today.json`, computes next prayer + countdown in memory.
- Outputs waybar JSON: `{"text": "Asr 2h 14m", "tooltip": "...full schedule...", "class": "prayer-soon|prayer-normal"}`.
- Invoked by waybar's custom module with `interval=30`.

**`omarchy-prayer-stop`**
- Reads `current-adhan.pid` → `kill <pid>` → remove the PID file. No-op if file missing or process already gone.
- Always wired to the "Stop adhan" notification action (automatic). A suggested `SUPER+CTRL+M` Hyprland keybind is printed by the installer for the user to paste into `~/.config/hypr/bindings.conf` — the installer does not edit Hyprland config automatically to avoid collisions with existing binds.

### Data flow

```
00:01 daily ─► omarchy-prayer-schedule
                ├─ read config.toml
                ├─ resolve times (cache → API → offline-calc)
                ├─ write today.json
                └─ create 10 transient timers

prayer-time T-10 ─► omarchy-prayer-notify <prayer> pre
prayer-time T    ─► omarchy-prayer-notify <prayer> on-time
                      ├─ notify-send
                      └─ mpv (on-time only) → current-adhan.pid

every 30s ─► omarchy-prayer-waybar → stdout (JSON)

on-resume ─► omarchy-prayer-resume.service → re-run schedule
```

### First-run bootstrap

Any command, if `config.toml` is absent:

1. Query `http://ip-api.com/json/` for `lat`, `lon`, `countryCode`.
2. Map country → calc method via an internal table (`SA`→Makkah, `EG`→Egypt, `PK`→Karachi, `IR`→Tehran, `TR`→Turkey, `US`→ISNA, default→MWL, etc.).
3. Write a complete `config.toml` with every key filled in (so the user can edit meaningfully without guessing).
4. Copy bundled `adhan.mp3` / `adhan-fajr.mp3` into `~/.config/omarchy-prayer/` if missing.
5. Enable+start `omarchy-prayer-schedule.timer` and `omarchy-prayer-resume.service` (the resume service is `WantedBy=sleep.target`, so enabling is enough — it fires on wake).
6. Immediately run the scheduler once to populate today's times.

If offline at first run: print a friendly error pointing at a documented manual-config snippet and exit non-zero. Never silently continue with a broken config.

## Config file

TOML, at `~/.config/omarchy-prayer/config.toml`:

```toml
[location]
# Filled in by first-run auto-detect; edit to override.
latitude  = 24.7136
longitude = 46.6753
city      = "Riyadh"   # display only
country   = "SA"       # used only when method.name = "auto"

[method]
# "auto" picks from country; or set explicitly:
# "MWL" | "ISNA" | "Egypt" | "Makkah" | "Karachi" | "Tehran" | "Jafari"
# | "Kuwait" | "Qatar" | "Singapore" | "Turkey" | "Gulf" | "Moonsighting"
# | "Dubai" | "France"
name = "auto"

# Per-prayer minute offsets (e.g. +2 delays Fajr by 2 minutes).
[offsets]
fajr    = 0
dhuhr   = 0
asr     = 0
maghrib = 0
isha    = 0

[notifications]
enabled            = true
pre_notify_minutes = 10      # 0 disables pre-notifications
respect_silencing  = true    # skip popup + audio when mako DND is on

[audio]
enabled    = true
player     = "mpv"
adhan      = "~/.config/omarchy-prayer/adhan.mp3"
adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
volume     = 80              # 0–100, passed to player

[waybar]
format                  = "{prayer} {countdown}"   # tokens: {prayer} {time} {countdown}
soon_threshold_minutes  = 10                        # css class "prayer-soon" when under this
```

## TUI

A full-screen colorful Ruby TUI (no heavy framework; ANSI truecolor + `tty-screen` for dimensions) matching the style of `monitor-tui`. The TUI reads Omarchy theme colors in this priority:

1. `OMARCHY_THEME` env var (palette name).
2. `~/.config/omarchy/current/theme` — the file Omarchy already uses for theme state.
3. Hardcoded fallback palette.

Degrades cleanly when `NO_COLOR=1` is set or `tput colors` < 256.

### Main view

```
 ╔═ ☪ Omarchy Prayer ══════════════════════════════════════════╗
 ║  📍 Riyadh, SA        📅 2026-04-22      🧭 Qibla  297°     ║
 ╟─────────────────────────────────────────────────────────────╢
 ║                                                              ║
 ║   ◦ Fajr       04:32    ✓ passed                             ║
 ║   ◦ Dhuhr      12:06    ✓ passed                             ║
 ║   ▶ Asr        15:42    next · in 2h 14m  ████░░░░░░ 63%    ║
 ║   ◦ Maghrib    18:41                                         ║
 ║   ◦ Isha       20:03                                         ║
 ║                                                              ║
 ╟─────────────────────────────────────────────────────────────╢
 ║   Source  Aladhan · cached 2026-04-01    Method  Umm al-Qura ║
 ╚══════════════════════════════════════════════════════════════╝
  [s] Settings   [t] Test adhan   [m] Mute today   [r] Refresh
```

Color rules:
- Header bar: theme `accent` bg, `background` fg, bold.
- Passed prayers: dim foreground.
- Next prayer: theme `primary` fg, bold, with a gradient progress bar showing day-progress from previous prayer → next.
- Countdown: warm color (amber/orange) when less than `waybar.soon_threshold_minutes`; neutral otherwise. (The same threshold is deliberately shared with the waybar `prayer-soon` class so the bar and TUI switch tone at the same moment.)
- Footer hotkeys: `muted` fg with keys highlighted in `accent`.
- Qibla compass: bearing + cardinal in `secondary`.

### Settings view (`s`)

Form with focused-field highlight line in `accent`. Editable:
- City (display only), latitude, longitude.
- Method (`auto` + 15 named options).
- Per-prayer offsets.
- Notifications: on/off, pre-notify minutes, respect-silencing.
- Audio: on/off, volume, adhan path, adhan_fajr path.

Actions: `Save` (validate + write `config.toml` + auto-refresh), `Cancel`, `Test audio`. Invalid input (e.g. lat out of range, audio file missing) surfaces inline in red next to the field without blocking other edits.

### Other keys

- `t` → plays `adhan.mp3` for 3 seconds (for testing volume / file).
- `m` → creates `~/.local/state/omarchy-prayer/mute-today`; shown as a red banner until cleared at 00:01.
- `r` → `systemctl --user start omarchy-prayer-schedule.service` + reload view.
- `q` → quit.

## Waybar integration

Custom module snippet added to the user's waybar config:

```json
"custom/prayer": {
  "exec": "omarchy-prayer-waybar",
  "interval": 30,
  "return-type": "json",
  "on-click": "omarchy-prayer tui",
  "tooltip": true
}
```

Styling hooks (optional, in user's `style.css`):

```css
#custom-prayer.prayer-soon { color: @warning; }
```

The installer appends the `custom/prayer` block to the user's waybar config only if no module with that name exists, and does not modify existing modules. Users opt in by adding `"custom/prayer"` to their `modules-right` array manually — the installer prints the exact line to copy.

## Error handling

| Condition | Behavior |
|---|---|
| Network failure during scheduler run | Log to journalctl, use cache; if no cache, use offline calc; never leave user without times. |
| Audio file missing | Notification still fires; second `notify-send` warns about the missing path; logged. |
| Invalid config (parse error, bad lat, unknown method) | Schedule/notify/waybar scripts print a single friendly error, exit non-zero. TUI shows a red banner on the top line and opens directly in the settings view. |
| First run with no network | Clear message (`cannot auto-detect location; edit ~/.config/omarchy-prayer/config.toml — see README`) and exit 1. |
| Suspend/resume across a prayer time | `omarchy-prayer-resume.service` is wired to `sleep.target`'s `After=` and runs the scheduler on wake. If the wake happens within a 2-minute grace window of a prayer that was missed while suspended, fire its notification once; else skip silently. |
| User replaces adhan file with a non-audio file | Player spawn fails; log + notify; no crash. |
| Multiple `omarchy-prayer-notify` invocations collide | PID file is written atomically (`O_EXCL` rename); second invocation sees the file and does not spawn a second mpv. |

## Testing

- **Unit tests (`minitest`):**
  - Config parsing: valid, missing keys (defaulted), invalid types (rejected with clear message).
  - Country → method mapping table: every entry resolves, default branch works.
  - Next-prayer computation: given a fixed `today.json` and a fake "now", returns the expected prayer + countdown including the "all five passed → first prayer tomorrow" edge case.
  - Offline calculator: matches Aladhan outputs within ±1 minute for a reference day at three reference locations (Riyadh, London, Jakarta).
- **Integration smoke test (`bin/test-smoke`):**
  - Points `$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`, and `$XDG_RUNTIME_DIR` at a tmp dir.
  - Stubs the Aladhan endpoint via a local fixture (tiny WEBrick served on 127.0.0.1).
  - Runs `omarchy-prayer-schedule`, asserts `today.json` written with expected shape, asserts `systemctl --user list-timers` shows the 10 transient units.
- **Manual verification checklist** (included in README):
  1. First-run location detect.
  2. Notification popup fires on `omarchy-prayer-notify fajr on-time` (manual trigger).
  3. Adhan plays; `omarchy-prayer-stop` kills it immediately.
  4. mako DND respected (`omarchy-toggle-notification-silencing` → trigger notify → no popup).
  5. Waybar widget shows the next prayer and updates within 30 seconds.
  6. TUI renders correctly with the active Omarchy theme; switches color on theme change.
  7. `mute-today` suppresses the next scheduled event; auto-clears at 00:01.

## Dependencies

Runtime:
- Ruby ≥ 3.0 (Omarchy ships Ruby).
- `tomlrb` gem (for config parsing).
- `mpv` (already typical on Omarchy; configurable).
- `mako`, `libnotify` (`notify-send`), `waybar`, `systemd --user` — all present in Omarchy by default.
- `curl` (for Aladhan fetch) — present by default.

Development-only:
- `minitest` (stdlib on Ruby 3).
- `webrick` gem for the smoke test fixture server.

The installer verifies each runtime dependency on install and prints a clear remediation line if anything is missing.

## Open questions resolved during brainstorming

- **TOML vs JSON for config?** → TOML (comment-friendly; `tomlrb` gem is small).
- **Per-prayer minute offsets?** → Keep them; useful for people whose masjid differs consistently.
- **Offline calculator as safety net?** → Keep; three-tier fall-through (API → cache → offline calc).
- **mpv vs pw-play?** → mpv (handles MP3 cleanly, silent mode is easy, already common on Omarchy).
- **Location auto-detect?** → Yes on first run; user can fully override in config.

## Out of scope for v1

- Hijri-date display in the TUI (nice-to-have for a later pass).
- Tasbih / dhikr counter.
- Mosque-finder integration.
- Support for multiple saved locations with a quick switcher.
- Packaging as an AUR package — ship as a self-install script for now; AUR can come after the design stabilizes.
- TUI settings form: v1 opens a read-only screen that points at the config file; in-TUI field editing is a later pass.
