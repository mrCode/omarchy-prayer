# omarchy-prayer

Muslim prayer-time notifier for Omarchy (Hyprland + mako + waybar).

- Fires mako notifications + plays the adhan at the five daily prayers.
- 10-minute pre-notifications (configurable).
- Waybar widget with live next-prayer countdown.
- Themed full-screen TUI with qibla direction.
- Scheduled via `systemd --user` timers; rebuilt daily at 00:01 and on resume from suspend.
- Time source: Aladhan API (cached monthly) with offline fall-through calculator.

## Install

### Arch / Omarchy — from AUR (recommended)

```bash
yay -S omarchy-prayer        # or: paru -S omarchy-prayer
omarchy-prayer               # first-run: geolocates, downloads Makkah+Madinah,
                             # patches waybar config, enables systemd timers
```

The first `omarchy-prayer` invocation runs `setup` automatically: it downloads the default **Makkah** adhan (and **Madinah** for Fajr), injects the `custom/prayer` widget into `~/.config/waybar/config.jsonc` (your original is backed up to `config.jsonc.bak.omarchy-prayer-<ts>`), and enables the `--user` schedule timer + resume hook. Re-run `omarchy-prayer setup` any time to re-apply.

### Arch — manually (without an AUR helper)

```bash
git clone https://aur.archlinux.org/omarchy-prayer.git
cd omarchy-prayer
makepkg -si
omarchy-prayer
```

### From source (any distro with Hyprland + mako + waybar)

```bash
git clone https://github.com/mrCode/omarchy-prayer.git
cd omarchy-prayer
./install.sh
```

`install.sh` verifies dependencies, installs scripts to `~/.local/bin/`, registers `systemd --user` units, runs the initial schedule, and runs `omarchy-prayer setup` to download the default adhans and patch your waybar config.

### Waybar widget

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
| `omarchy-prayer-stop`          | kill any playing adhan                         |
| `omarchy-prayer adhans`        | list / download / set curated Sunni adhans     |
| `omarchy-prayer setup`         | re-run setup (default adhans + waybar + timers)|

## Configuration

Edit `~/.config/omarchy-prayer/config.toml` — the installer seeds it on first run via IP geolocation. See `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md` for all options.

### Updating location

IP geolocation resolves to your ISP's regional hub city, not necessarily the city you're physically in (e.g. an IP in Makkah commonly resolves to Jeddah). After first-run, verify `omarchy-prayer status` shows the right city. If it doesn't — or when you travel — use `relocate`:

```bash
omarchy-prayer relocate                                            # re-detect via IP
omarchy-prayer relocate --lat 21.4225 --lon 39.8262 --city Makkah --country SA   # manual override
```

`relocate` rewrites the `[location]` block in `config.toml` (preserving comments and other settings), invalidates cached month data so prayer times for the new location are fetched fresh, and runs the scheduler so today's times take effect immediately.

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
- [ ] `omarchy-prayer-notify fajr on-time` produces a mako popup and plays the Fajr adhan.
- [ ] `omarchy-prayer-stop` silences the adhan within 1 second.
- [ ] `omarchy-toggle-notification-silencing` on → repeat step 3 → no popup, no audio.
- [ ] Waybar shows "<next prayer> <countdown>" and updates within 30 s.
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
