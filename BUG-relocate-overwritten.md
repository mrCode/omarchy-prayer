# Bug: `relocate` manual override is silently reverted by the scheduler it launches

**Severity:** High — the documented way to set location by hand does not work, and the
command reports success while discarding the user's input.

**Version:** omarchy-prayer 0.4.1-1 (Arch package)

## Summary

`omarchy-prayer relocate --lat … --lon … --city … --country …` writes the manual
coordinates to `config.toml`, then immediately `exec`s the scheduler, which — when
`auto_update = true` (the default) — re-detects location by IP and **overwrites the
values just written**. The user's explicit override is destroyed within the same
command invocation. Exit status is 0 and the failure is easy to miss.

The config comment advertises exactly the workflow that is broken:

```toml
# Re-detect on every schedule run (daily, on resume, on network up).
# Set to false to pin location and only update via `omarchy-prayer relocate`.
auto_update = true
```

That sentence implies `relocate` is authoritative. It is not: with the default
setting, `relocate` cannot pin anything.

## Reproduction

Requires an IP-geolocated position more than `AutoRelocate::DEFAULT_THRESHOLD_KM`
(50 km) from the coordinates being set.

```bash
grep auto_update ~/.config/omarchy-prayer/config.toml     # auto_update = true
omarchy-prayer relocate --lat 37.4419 --lon -122.1430 --city "Palo Alto" --country US
grep -E 'latitude|city' ~/.config/omarchy-prayer/config.toml
```

**Expected:** `city = "Palo Alto"`, `latitude = 37.4419`.

**Actual:** `city = "San Diego"`, `latitude = 32.7174` — the IP-detected location.
Observed on 2026-09-06; `ipwho.is` resolved this connection (IPv6, AT&T) to San
Diego, 694 km from the real location. Repeating the command never converges.

The one visible clue is on stderr, and it reads like normal operation rather than
an override being discarded:

```
omarchy-prayer: auto-relocated Palo Alto, US → San Diego, US (Δ 694 km)
```

## Root cause

`bin/omarchy-prayer:231-236`

```ruby
def cmd_relocate(argv)
  require 'omarchy_prayer/relocate'
  OmarchyPrayer::Relocate.run(argv)   # 1. writes manual coords to config.toml
  schedule = File.expand_path('omarchy-prayer-schedule', __dir__)
  exec(schedule)                      # 2. hands off to the scheduler
end
```

`bin/omarchy-prayer-schedule:28`

```ruby
if cfg.auto_update? && OmarchyPrayer::AutoRelocate.maybe_update(cfg)
```

`AutoRelocate.maybe_update` (lib/omarchy_prayer/auto_relocate.rb:13-32) geolocates,
finds the distance from the freshly written manual coordinates exceeds the 50 km
threshold, and calls `Relocate.update_config!(detected)` (line 22) — overwriting
step 1.

Nothing distinguishes "config values a user just set deliberately" from "config
values left over from a previous auto-detect", so the scheduler treats the manual
pin as stale data and corrects it.

## Suggested fix

The cleanest fix is to make a manual relocate authoritative for the run it starts.
Options, roughly in order of preference:

1. **Suppress auto-relocate for the scheduler run spawned by `cmd_relocate`** —
   e.g. `exec({'OMARCHY_PRAYER_SKIP_AUTO_RELOCATE' => '1'}, schedule)`, honored at
   `omarchy-prayer-schedule:28`. Narrow, no config semantics change, fixes the
   same-command clobber.

2. **Have a manual `relocate` also set `auto_update = false`**, reporting it
   ("pinned location; auto-update disabled"). Matches what a user asking for
   specific coordinates almost certainly wants, and makes the config comment true.
   Needs a way back — e.g. `relocate --auto` to re-enable.

3. **Record manual pins explicitly** (e.g. `location.source = "manual"`) and have
   `update_needed?` decline to overwrite them. Most precise, biggest change.

Option 1 alone still leaves the *next* scheduled run (daily/resume/network-up)
reverting the pin, so 1+2, or 3, is what actually makes `relocate` stick.

Worth deciding alongside this: whether a 694 km auto-relocate should apply silently
at all, or prompt/notify instead. On this network two providers disagreed wildly —
`ipwho.is` over IPv6 said San Diego while `ipinfo.io` over IPv4 said Santa Clara —
so a large jump is at least as likely to be bad geolocation as real travel, and it
shifts every prayer time (here: dhuhr by 20 min, maghrib by 23 min).

## Second, smaller bug: confirmation message lost when stdout is not a TTY

`Relocate.run` prints its confirmation to stdout, then `cmd_relocate` calls `exec`,
which replaces the process image **without flushing Ruby's stdout buffer**. On a
TTY (line-buffered) the message appears; through a pipe or redirect (block-buffered)
it is silently dropped.

```bash
omarchy-prayer relocate --lat 37.4419 --lon -122.1430 --city "Palo Alto" --country US | cat
#   → no "location set to …" line

script -qec "omarchy-prayer relocate --lat 37.4419 --lon -122.1430 --city 'Palo Alto' --country US" /dev/null
#   → omarchy-prayer: location set to Palo Alto, US (37.4419, -122.1430)
#     cleared 1 cached month(s); next refresh will fetch fresh times
```

This actively hampers diagnosis of bug #1: piping the command to a filter hides the
success line while leaving the contradictory `auto-relocated …` line (stderr,
unbuffered) visible. Fix with `$stdout.flush` (or `$stdout.sync = true`) before
`exec`.

## Workaround

Set `auto_update = false` **before** running `relocate`; order matters, since a
`relocate` run while auto-update is on is reverted before it ever takes effect.
