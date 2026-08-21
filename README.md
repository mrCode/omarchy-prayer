# omarchy-prayer

Muslim prayer-time notifier for Omarchy (Hyprland). Ships a native bar widget for
the **Omarchy 4 Quickshell shell**, and keeps the waybar module for Omarchy 3 and
other Hyprland setups.

- Fires desktop notifications + plays the adhan at the five daily prayers.
- 10-minute pre-notifications (configurable).
- Bar widget with live next-prayer countdown, on Omarchy 4's shell or on waybar.
- Themed full-screen TUI with qibla direction.
- Scheduled via `systemd --user` timers; rebuilt daily at 00:01 and on resume from suspend.
- Time source: Aladhan API (cached monthly) with offline fall-through calculator.

## Install

### Arch / Omarchy — from AUR (recommended)

```bash
yay -S omarchy-prayer        # or: paru -S omarchy-prayer
omarchy-prayer               # first-run: geolocates, downloads Makkah+Madinah,
                             # installs the bar widget, enables systemd timers
```

The first `omarchy-prayer` invocation runs `setup` automatically: it downloads the default **Makkah** adhan (and **Madinah** for Fajr), installs the bar widget for whichever bar you run, and enables the `--user` schedule timer + resume hook. Re-run `omarchy-prayer setup` any time to re-apply.

Setup detects your bar at runtime:

- **Omarchy 4** — copies the `io.github.mrcode.prayer-times` Quickshell plugin into `~/.config/omarchy/plugins/` and places it on your bar (backing up `shell.json` first).
- **Omarchy 3 / other Hyprland** — injects the `custom/prayer` module into `~/.config/waybar/config.jsonc` (your original is backed up to `config.jsonc.bak.omarchy-prayer-<ts>`).
- **Neither** — says so, and changes nothing.

The widget is placed on your bar **once**. If you later remove it, re-running setup keeps the plugin files current but will not put it back.

### Arch — manually (without an AUR helper)

```bash
git clone https://aur.archlinux.org/omarchy-prayer.git
cd omarchy-prayer
makepkg -si
omarchy-prayer
```

### From source (any distro with Hyprland)

```bash
git clone https://github.com/mrCode/omarchy-prayer.git
cd omarchy-prayer
./install.sh
```

`install.sh` verifies dependencies, installs scripts to `~/.local/bin/`, registers `systemd --user` units, runs the initial schedule, and runs `omarchy-prayer setup` to download the default adhans and install the bar widget.

### Omarchy 4 bar widget

`omarchy-prayer setup` installs and places it automatically. To do it by hand:

```bash
omarchy-shell shell enablePlugin io.github.mrcode.prayer-times '{"section":"right","index":0}'
```

| Click  | Action |
|--------|--------|
| Left   | Open the prayer times panel |
| Right  | Stop a playing adhan |
| Middle | Open the TUI in a floating terminal |

### Pill designs

Pick a design from the panel, or from the CLI:

| Preset | Pill reads |
|---------|-----------|
| `full` | `Riyadh · Isha 1h 26m` |
| `minimal` | `Isha 1h 26m` |
| `icon` | Omarchy 4 widget only: the mosque glyph alone, times in the tooltip and panel. On the waybar module (no glyph of its own) this renders as an **empty module** — avoid it there, or undo with `bar preset full` |

```bash
omarchy-prayer bar preset list
omarchy-prayer bar preset minimal
omarchy-prayer bar names arabic     # العشاء instead of Isha, in the pill and panel
omarchy-prayer bar compact on       # "1:26" instead of "1h 26m"
omarchy-prayer bar quiet 60         # glyph only until the prayer is within 60 minutes
omarchy-prayer bar status
```

A design is just a `format` string under `[bar]`, so hand-written formats keep
working — they show as `custom`. Quiet-until-near applies to the Omarchy 4
widget only; the waybar module has no glyph to collapse to.

The panel lists the five prayers with the next one highlighted, plus qibla
direction, calculation method, and time source, with **Mute today**,
**Adhan on/off**, and **Stop adhan** buttons.

Two different controls, easy to confuse:

| Control | Scope |
|---------|-------|
| **Mute today** | Suppresses notification + adhan until midnight, then auto-clears |
| **Adhan on/off** | Standing `[audio].enabled` setting — whether the adhan ever plays |

When the adhan is off, a muted-speaker glyph appears next to the mosque icon on
the pill. The same setting from the CLI:

```bash
omarchy-prayer audio status     # on | off
omarchy-prayer audio on
omarchy-prayer audio off
omarchy-prayer audio toggle
```

### Waybar widget (Omarchy 3 and other Hyprland setups)

`omarchy-prayer setup` patches your waybar config automatically. If you want to do it manually, add this module to `~/.config/waybar/config.jsonc` and put `"custom/prayer"` in your `modules-right`:

```jsonc
"custom/prayer": {
  "exec": "omarchy-prayer-waybar",
  "interval": 30,
  "return-type": "json",
  "on-click": "alacritty -e omarchy-prayer",
  "on-click-right": "omarchy-prayer-stop",
  "tooltip": true
}
```

Both widgets support four placeholders in `bar.format`:

| Placeholder    | Renders as                    |
|----------------|-------------------------------|
| `{city}`       | current city (e.g. `London`)  |
| `{prayer}`     | next prayer name (e.g. `Maghrib`) |
| `{time}`       | next prayer time (e.g. `18:01`) |
| `{countdown}`  | remaining time (e.g. `1h 12m`) |

Default format is `{city} · {prayer} {countdown}`. Omit `{city}` from the format to hide it.

Optional CSS for the "prayer time soon" amber tint:

```css
#custom-prayer.prayer-soon { color: @warning; }
```

### Optional Hyprland keybind for stopping the adhan

Append to `~/.config/hypr/bindings.conf`:

```
bind = SUPER CTRL, M, exec, omarchy-prayer-stop
```

## Commands

| Command                         | What it does                                   |
|--------------------------------|-----------------------------------------------|
| `omarchy-prayer`               | open the TUI                                   |
| `omarchy-prayer today`         | print today's times                            |
| `omarchy-prayer next`          | print next prayer name + time                  |
| `omarchy-prayer status`        | print source/method/city line                  |
| `omarchy-prayer refresh`       | re-run the scheduler                           |
| `omarchy-prayer relocate`      | re-detect location (IP) or set manually        |
| `omarchy-prayer mute-today`    | toggle today-only mute flag                    |
| `omarchy-prayer audio`         | adhan audio on / off / toggle / status         |
| `omarchy-prayer bar`           | pill design: preset / names / compact / quiet   |
| `omarchy-prayer-stop`          | kill any playing adhan                         |
| `omarchy-prayer adhans`        | list / download / set curated Sunni adhans     |
| `omarchy-prayer setup`         | re-run setup (default adhans + bar widget + timers)|

In the TUI, press `[l]` to trigger relocate interactively without leaving the screen.

## Configuration

Edit `~/.config/omarchy-prayer/config.toml` — the installer seeds it on first run via IP geolocation. See `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md` for all options.

### `[waybar]` is now `[bar]`

Since 0.2.0 the widget section is named `[bar]`, because it configures both the
Omarchy 4 Quickshell widget and the waybar module:

```toml
[bar]
format                 = "{city} · {prayer} {countdown}"
soon_threshold_minutes = 10
```

Existing configs are renamed automatically on the next run, and an unmigrated
`[waybar]` section keeps working either way.

### Updating location

Location auto-updates on every schedule rebuild — daily at 00:01, on session start, on resume from suspend, on `omarchy-prayer refresh`, and (if the NetworkManager dispatcher was installed) on every network connection-up. Each rebuild re-detects via ipwho.is (HTTPS) and rewrites `[location]` in `config.toml` if the **country** changed or detected **coordinates drift more than 50 km** from the configured ones.

The 50 km threshold is large enough to absorb the provider's regional-hub jitter (e.g. an IP in Makkah commonly resolves to Jeddah — same metro, no rewrite) while still catching real travel between cities.

To disable auto-update — for example, if you want the schedule pinned to a city you don't currently live in — set `auto_update = false` in the `[location]` block of `config.toml`. Manual override is still available:

```bash
omarchy-prayer relocate                                            # one-shot re-detect via IP
omarchy-prayer relocate --lat 21.4225 --lon 39.8262 --city Makkah --country SA   # manual override
```

`relocate` rewrites the `[location]` block in `config.toml` (preserving comments and other settings), invalidates cached month data so prayer times for the new location are fetched fresh, and runs the scheduler so today's times take effect immediately.

Location detection cross-checks IP geolocation against your system timezone (`/etc/localtime`). If you're roaming through a foreign carrier or behind a VPN that places your IP in a different country, the system timezone takes precedence — so `omarchy-prayer` won't auto-relocate you to the carrier's country. To override manually:

```bash
omarchy-prayer relocate --lat 51.5074 --lon -0.1278 --city London --country GB
```

The NetworkManager dispatcher is installed by `install.sh` via sudo. If you skipped sudo or installed without it, install it manually:

```bash
sudo install -m 0755 -o root -g root \
  share/networkmanager/90-omarchy-prayer \
  /etc/NetworkManager/dispatcher.d/90-omarchy-prayer
```

### Adhan audio (default: muted)

The adhan audio is **muted by default** — you'll see the prayer notification but won't hear the call. To enable, edit `~/.config/omarchy-prayer/config.toml`:

```toml
[audio]
enabled = true
```

Existing users upgrading from earlier versions are migrated to muted on first run; a stderr line announces the change with re-enable instructions.

## Adhan library

A curated catalog of 17 Sunni adhans (Makkah, Madinah, Al-Aqsa, Egypt, Halab, plus classical reciters) is bundled via praytimes.org.

```bash
omarchy-prayer adhans list                # show catalog + which are downloaded
omarchy-prayer adhans download makkah     # fetch the Makkah adhan
omarchy-prayer adhans set makkah          # use Makkah as the standard adhan
omarchy-prayer adhans set madinah --fajr  # use Madinah for Fajr specifically
omarchy-prayer adhans current             # show currently configured paths
```

Downloaded files live at `~/.local/share/omarchy-prayer/adhans/<key>.mp3`. `set` rewrites only the matching `adhan = "..."` / `adhan_fajr = "..."` line in your config, leaving everything else untouched.

## Manual verification checklist

After install:

- [ ] `omarchy-prayer today` lists five prayers with HH:MM times.
- [ ] `systemctl --user list-timers | grep op-` shows 10 transient units.
- [ ] `omarchy-prayer-notify fajr on-time` produces a desktop notification and plays the Fajr adhan.
- [ ] `omarchy-prayer-stop` silences the adhan within 1 second.
- [ ] `omarchy-toggle-notification-silencing` on → repeat step 3 → no popup, no audio.
- [ ] The bar shows "<next prayer> <countdown>" and counts down live.
- [ ] `omarchy-prayer` (TUI) renders with the active Omarchy theme colors.
- [ ] After midnight, `systemctl --user list-timers | grep op-` shows the new day's units.
- [ ] Airplane mode: `omarchy-prayer refresh` still produces a `today.json` (source=offline).

## Uninstall

```bash
systemctl --user disable --now omarchy-prayer-schedule.timer omarchy-prayer-resume.service
rm -f ~/.local/bin/omarchy-prayer{,-schedule,-notify,-waybar,-stop}
rm -f ~/.config/systemd/user/omarchy-prayer-*.{service,timer}
rm -rf ~/.local/share/omarchy-prayer
# config and audio left in place:
# rm -rf ~/.config/omarchy-prayer ~/.local/state/omarchy-prayer
```

## Development

```bash
bundle install
bundle exec rake test
```

- Spec: `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md`
- Plan: `docs/superpowers/plans/2026-04-22-omarchy-prayer.md`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Basem Aljedai.

Prayer times via the [Aladhan API](https://aladhan.com/). Bundled adhan catalog sourced from [praytimes.org](https://praytimes.org/docs/adhan).
