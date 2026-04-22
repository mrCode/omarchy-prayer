# omarchy-prayer

Muslim prayer-time notifier for Omarchy (Hyprland + mako + waybar).

- Fires mako notifications + plays the adhan at the five daily prayers.
- 10-minute pre-notifications (configurable).
- Waybar widget with live next-prayer countdown.
- Themed full-screen TUI with qibla direction.
- Scheduled via `systemd --user` timers; rebuilt daily at 00:01 and on resume from suspend.
- Time source: Aladhan API (cached monthly) with offline fall-through calculator.

## Install

```bash
./install.sh
```

The installer verifies dependencies, installs the scripts, registers systemd units, and runs the initial schedule. Follow the "next steps" it prints to wire up the waybar widget and optional Hyprland keybind.

## Commands

| Command                         | What it does                                   |
|--------------------------------|-----------------------------------------------|
| `omarchy-prayer`               | open the TUI                                   |
| `omarchy-prayer today`         | print today's times                            |
| `omarchy-prayer next`          | print next prayer name + time                  |
| `omarchy-prayer status`        | print source/method/city line                  |
| `omarchy-prayer refresh`       | re-run the scheduler                           |
| `omarchy-prayer mute-today`    | toggle today-only mute flag                    |
| `omarchy-prayer-stop`          | kill any playing adhan                         |
| `omarchy-prayer adhans`        | list / download / set curated Sunni adhans     |

## Configuration

Edit `~/.config/omarchy-prayer/config.toml` — the installer seeds it on first run via IP geolocation. See `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md` for all options.

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

## License

TBD — will be added before the first public release.
