# Auto-setup + reboot-safe scheduling

## Motivation

1. **Missed-athan bug.** `omarchy-prayer-schedule.timer` runs `OnCalendar=00:01` daily. On laptops the machine is usually off at 00:01, and on reboots mid-day the transient `op-*` prayer timers (created via `systemd-run`) are lost. `Persistent=true` does not back-fill because the scheduler's "last trigger" is the morning's manual run. Result: no athan after a reboot.
2. **Fresh-install friction.** A new user installs the package, runs `omarchy-prayer`, gets the config but:
   - no adhan audio (config points at a placeholder path, no mp3)
   - no waybar widget (must hand-edit `~/.config/waybar/config.jsonc`)
   - must manually enable systemd units
   This was the `ecleel` failure mode.

## Design

### Timer fix

`share/systemd/omarchy-prayer-schedule.timer`: add `OnStartupSec=30s`. User timer will now re-run the scheduler ~30s into every user-manager session (login / boot), rebuilding transient prayer timers.

```
[Timer]
OnStartupSec=30s
OnCalendar=*-*-* 00:01:00
Persistent=true
AccuracySec=30s
```

### Setup module (`lib/omarchy_prayer/setup.rb`)

Idempotent bootstrap with three independent steps:

- **`ensure_default_adhans`** — if `audio.adhan` in `config.toml` is the placeholder `~/.config/omarchy-prayer/adhan.mp3` and no file exists at that path, download **Makkah** via `AdhanCatalog` and rewrite config to point at it. Same for `adhan_fajr` → **Madinah**. User customizations (custom paths) are respected.
- **`ensure_waybar_module`** — find `~/.config/waybar/config.jsonc` (or `config`). If present and does not contain `"custom/prayer"`:
  1. Back up to `<path>.bak.omarchy-prayer-<unix>`
  2. Text-inject `"custom/prayer"` as first element of `modules-right` (regex on `"modules-right"\s*:\s*\[(\s*)`)
  3. Text-inject the `custom/prayer` module body before the final `}` (rindex; strip trailing comma if present)
  4. SIGUSR2 waybar (`pkill -SIGUSR2 waybar` or `systemctl --user reload waybar`) to reload
  - Text injection (not parse-and-serialize) preserves JSONC comments.
  - If parse fails after JSONC strip, print instructions and leave file untouched.
- **`ensure_systemd_units`** — if `omarchy-prayer-schedule.timer` not enabled, `systemctl --user enable --now`. Same for `omarchy-prayer-resume.service` (enable without `--now`). Also runs `omarchy-prayer-schedule.service` once if today's cache is missing.

Each step is guarded by a cheap "already done" check so a no-op invocation is fast (< 50ms).

### Invocation points

- `bin/omarchy-prayer setup` — explicit, prints what it did.
- `bin/omarchy-prayer` (no args → TUI) — runs setup silently before launching TUI.
- `FirstRun.ensure_config!` — runs setup after writing initial config (first-run path).
- `install.sh` — runs setup at end.
- **Not** invoked from: `omarchy-prayer today|next|status|refresh`, `omarchy-prayer-schedule`, `omarchy-prayer-waybar`, `omarchy-prayer-notify`. These are fast-path / systemd-triggered and must not block on network.

### Post-install message (`omarchy-prayer.install`)

Updated to tell users: "Run `omarchy-prayer` once — it will download Makkah adhan, add the waybar widget, and enable systemd timers automatically."

## Version

Bump from `0.1.2` → `0.1.3`.

## Testing

- Unit tests in `test/test_setup.rb`:
  - adhan download skipped when file present
  - adhan download triggered when placeholder + no file (uses WEBrick stub like existing tests)
  - waybar patch injects module only when missing
  - waybar patch is no-op on already-patched file
  - waybar patch creates backup
  - systemd enable is no-op when already enabled (using shim log)
- Manual: user runs `yay -R omarchy-prayer && yay -S omarchy-prayer && omarchy-prayer` → widget appears, adhan plays at next prayer.

## Risk / fallback

- **Waybar patch corrupts config.** Backup lets user restore. Regex is conservative (only touches if `custom/prayer` absent).
- **JSONC with exotic syntax.** We bail out and print instructions rather than mangle the file.
- **Downloads fail offline.** Setup prints a warning and continues; user can re-run later.
