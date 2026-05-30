# TZ-aware relocate, muted-by-default adhan, TUI relocate hotkey, waybar `{city}`

## Motivation

`omarchy-prayer` currently geolocates exclusively via `ip-api.com`. When a user is in London but tethered through STC roaming (or any VPN / foreign-IP scenario), the IP resolves to Saudi Arabia and the daily auto-relocate run silently rewrites the config back to Riyadh — even after a manual `omarchy-prayer relocate --lat … --lon … --city London`. The user-visible symptom is "I relocated yesterday, today it's wrong again."

The IP itself is genuinely Saudi, so multi-provider voting wouldn't help. The strongest local signal that is *not* affected by network routing is the system timezone (`/etc/localtime` → `Europe/London`). Every Linux user has it set correctly because their clock would otherwise be wrong. Combined with `/usr/share/zoneinfo/zone1970.tab` (ships with `tzdata`, a core dependency), it yields country + representative lat/lon offline, with zero new runtime deps.

Three additional changes are bundled because they shape the same user-facing flow:

1. **Muted-by-default adhan.** Audio is loud; notifications are quiet. New users should hear the mako prayer popup, not a full adhan, until they opt in. Existing users get a one-time migration with a clear stderr message explaining the change.
2. **TUI relocate hotkey.** The TUI is the discovery surface for non-CLI users. A single keypress should re-detect location (via the new TZ-aware flow) without dropping to the shell.
3. **Waybar `{city}` placeholder.** The user wants the current city visible on the bar so they can spot a wrong location immediately, without opening the TUI or grepping config.

## Design

### `OmarchyPrayer::TzLocation` (`lib/omarchy_prayer/tz_location.rb`)

New module. One public entry point:

```ruby
TzLocation.detect → { latitude:, longitude:, city:, country:, countries:, zone: } | nil
```

`nil` whenever the timezone can't be resolved to a `zone1970.tab` row (missing file, `Etc/UTC`, legacy `posix/` zones, parse failure). Never raises — callers degrade to IP-only.

**Zone-name resolution**, in order:

1. `ENV['TZ']` if set and non-empty.
2. `File.realpath('/etc/localtime')` stripped of `/usr/share/zoneinfo/` prefix.
3. `timedatectl show -p Timezone --value` (last resort; only path that spawns).

**`zone1970.tab` parsing:**

Format (tab-separated, comment lines start with `#`):

```
GB,GG,IM,JE    +513030-0000731    Europe/London
SA,AQ,KW,YE    +2438+04643        Asia/Riyadh    Syowa
```

Parse on first call, cache the result in a module-level `@table` hash keyed by zone name. Value: `{ countries: ["GB","GG","IM","JE"], lat: 51.5083, lon: -0.1253 }`.

**ISO 6709 coord parsing** handles both forms:

- `±DDMM±DDDMM` (e.g. `+2438+04643`): 4-digit lat, 5-digit lon.
- `±DDMMSS±DDDMMSS` (e.g. `+513030-0000731`): 6-digit lat, 7-digit lon.

Distinguish on length, not regex alternation, since the two forms are unambiguous. Convert DMS → decimal degrees rounded to 4 places (matches existing `Relocate#sub_numeric` format).

**City derivation:** Last `/`-separated segment of zone name, `_` → space. `America/New_York` → `New York`. `Europe/London` → `London`. `America/Indiana/Indianapolis` → `Indianapolis`. Acceptable granularity for prayer calculations — sub-minute time difference vs. the actual user position within a zone.

**Country selection:** First entry in the comma-separated country list. `zone1970.tab` lists the zone's primary country first by convention.

### Detection orchestration in `OmarchyPrayer::Geolocate` (`lib/omarchy_prayer/geolocate.rb`)

Existing `Geolocate.detect` (pure ip-api.com call) becomes `Geolocate.detect_ip` (preserves the same return shape and error class — `Geolocate::Error`).

New `Geolocate.detect` orchestrates:

```ruby
def detect
  ip = safe(:detect_ip)
  tz = TzLocation.detect

  if ip && tz
    return ip if tz[:countries].include?(ip[:country].to_s.upcase)
    log_override(ip, tz)
    return tz_to_loc(tz)
  end

  return ip if ip   # TZ unresolved → IP alone
  return tz_to_loc(tz) if tz   # IP failed → TZ alone
  raise Error, "no location signal available (IP failed, timezone unresolved)"
end
```

`safe(:detect_ip)` catches the network-failure family already used in `AutoRelocate` (`Geolocate::Error`, `SocketError`, `Errno::ECONNREFUSED`, `Errno::ENETUNREACH`, `Errno::EHOSTUNREACH`, `Timeout::Error`), returns `nil` on failure.

`log_override` writes to `$stderr`:

```
omarchy-prayer: IP→Riyadh, SA but timezone is Europe/London — using London, GB
```

`tz_to_loc(tz)` returns `{ latitude: tz[:lat], longitude: tz[:lon], city: tz[:city], country: tz[:country] }`.

**Decision rule, in one line:** Use IP if it lies inside the TZ's country set (IP is more precise within the right country). Otherwise, use TZ. Either-or-fail.

All three current callers (`FirstRun#ensure_config!`, `AutoRelocate#maybe_update`, `Relocate#resolve_location`) call `Geolocate.detect` and get the cross-check for free. No call-site changes required beyond the existing injection points.

### Default-mute adhan + one-time migration

**`Config::DEFAULTS` change** (`lib/omarchy_prayer/config.rb`):

```ruby
'audio' => { 'enabled' => false, 'player' => 'mpv',
             'adhan' => '~/.config/omarchy-prayer/adhan.mp3',
             'adhan_fajr' => '~/.config/omarchy-prayer/adhan-fajr.mp3',
             'volume' => 80 },
```

`notifications.enabled` stays `true` — user still sees mako popups.

**`FirstRun::TEMPLATE`** updated to write `enabled = false` with a comment: `# set to true to play the adhan audio at each prayer`.

**Migration module** — new `OmarchyPrayer::Migrations` (`lib/omarchy_prayer/migrations.rb`):

```ruby
module Migrations
  STATE_MARKER = File.join(Paths.state_dir, '.migrated-mute-default-v1')

  def self.run(io: $stderr)
    return if File.exist?(STATE_MARKER)
    mute_audio_default(io)
    Paths.ensure_state_dir
    FileUtils.touch(STATE_MARKER)
  rescue StandardError => e
    io.puts "omarchy-prayer: migration warning (#{e.class}: #{e.message})"
  end

  def self.mute_audio_default(io)
    path = Paths.config_file
    return unless File.exist?(path)
    text = File.read(path)
    return unless text =~ /^\s*enabled\s*=\s*true\s*$/  # inside [audio] — see below
    new_text = rewrite_audio_enabled(text, false)
    return if new_text == text
    File.write(path, new_text)
    io.puts 'omarchy-prayer: adhan audio is now muted by default. ' \
            'Re-enable by setting `enabled = true` under [audio] in ~/.config/omarchy-prayer/config.toml.'
  end
end
```

`rewrite_audio_enabled` walks the TOML line-by-line tracking the current section header (`[audio]`, `[notifications]`, etc.) and rewrites *only* the `enabled = …` line that appears under `[audio]`. This avoids accidentally flipping `notifications.enabled`.

**Call sites:** `bin/omarchy-prayer` and `bin/omarchy-prayer-schedule` invoke `Migrations.run` immediately after `FirstRun.ensure_config!` and before `Config.load`. Idempotent and bounded — single file read + at most one file write.

**Why a marker file, not a config key:** keeps the user's `config.toml` clean. The marker also gives us a versioned namespace (`-v1`, `-v2`, …) for future one-shots without re-running this one.

**Uninstall:** `uninstall.sh` already removes `~/.local/state/omarchy-prayer/` recursively, which sweeps the marker. No extra change.

### TUI relocate hotkey

**Key:** `l` (mnemonic: location).

**Dispatch** in `TUI#run` loop:

```ruby
when 'l' then relocate_here
```

**`relocate_here` implementation:**

```ruby
def relocate_here
  show_toast('locating…', color: :muted)
  begin
    captured = StringIO.new
    Relocate.run([], io: captured)
    refresh_schedule   # reloads @today and triggers timer
    @cfg = Config.load
    show_toast("→ #{@cfg.city}, #{@cfg.country}", color: :primary, dwell: 1.0)
  rescue Geolocate::Error, SocketError, Errno::ECONNREFUSED, Errno::ENETUNREACH,
         Errno::EHOSTUNREACH, Timeout::Error, SystemExit => e
    show_toast("relocate failed: #{e.message}", color: :warning, dwell: 1.5)
  end
end
```

`show_toast(msg, color:, dwell: 0)` renders the message in place of the hotkey row, then sleeps for `dwell` seconds. A `dwell` of 0 returns immediately (used for the "locating…" indicator that is *replaced* by the next render).

**Hotkey row** (`render_hotkeys`) gains `[l] relocate`:

```
[q] quit  [r] refresh  [l] relocate  [m] mute today  [t] test adhan
```

**Why blocking, not threaded:** the relocate call is ~2 s (one HTTP request + small file writes). Blocking the TUI with a status indicator is simpler than juggling a worker thread and avoiding stale renders. The user can `Ctrl+C` if it hangs.

**`test_audio` change:** when `@cfg.audio_enabled` is false, skip the spawn and toast `audio disabled — set audio.enabled = true to enable`. Discovery path for users who hit `t` post-migration.

### Waybar `{city}` placeholder

**`Config::DEFAULTS` change:**

```ruby
'waybar' => { 'format' => '{city} · {prayer} {countdown}', 'soon_threshold_minutes' => 10 },
```

Fresh installs render `London · Maghrib 1h 12m`. Existing users keep their current `waybar.format` from disk untouched — no migration. They can add `{city}` by editing the config.

**`Waybar.render` signature** gains `city:`:

```ruby
def render(today, now: Time.now, format:, soon_minutes:, city:)
  …
  text = format
    .gsub('{city}',     city.to_s)
    .gsub('{prayer}',   pretty)
    .gsub('{time}',     time_s)
    .gsub('{countdown}', countdown)
  …
end
```

`bin/omarchy-prayer-waybar` passes `city: cfg.city`. Empty city is rendered as empty string (defensive — `Config#validate!` already requires lat/lon to be numeric but doesn't enforce non-empty city).

**README:** placeholder table extended to four entries: `{city}`, `{prayer}`, `{time}`, `{countdown}`. Note that omitting `{city}` from `format` hides it.

## Error handling summary

| Failure | Behavior |
|---|---|
| `zone1970.tab` missing | `TzLocation.detect` → `nil`. IP-only path. |
| Zone name not in table (UTC, posix/, unknown) | `nil`. IP-only. |
| `/etc/localtime` not a symlink | Fall through to `timedatectl`; if that fails → `nil`. |
| ISO 6709 coord parse error | Log to stderr, return `nil`. Never crash scheduler. |
| IP geolocation fails, TZ available | Use TZ-derived. |
| IP and TZ both fail | `Geolocate::Error` raised. `AutoRelocate` catches → skip. `FirstRun` aborts (same as today). |
| Migration: marker write fails | Log warning, continue. Next run retries (idempotent on already-flipped config). |
| Migration: config rewrite regex misses | Log nothing (no `enabled = true` to flip), drop marker. |
| TUI relocate network error | Toast in warning color, no config change, return to main loop. |
| TUI `t` with audio disabled | Toast "audio disabled — set audio.enabled = true to enable". |

## Testing

Project uses minitest. New test files:

- **`test/tz_location_test.rb`** — embedded `zone1970.tab` fixture (5–10 representative rows). Tests:
  - Parse comments, skip blanks.
  - Country list extraction (`GB,GG,IM,JE` → array).
  - Coord parse: 4-digit (`+2438+04643`), 6-digit (`+513030-0000731`), negative lon (`-0000731`).
  - City derivation: simple (`Europe/London`), underscored (`America/New_York`), nested (`America/Indiana/Indianapolis`).
  - Zone-name resolution priority: `ENV['TZ']` set → wins; unset → `realpath` path.
  - Missing zone → `nil`.
- **`test/geolocate_cross_check_test.rb`** — mock `IpGeolocate.detect_ip` and `TzLocation.detect`. Cases:
  - IP country ∈ zone countries → returns IP unchanged.
  - IP country ∉ zone countries → returns TZ-derived, log line written.
  - IP fails, TZ succeeds → returns TZ-derived.
  - IP succeeds, TZ nil → returns IP unchanged.
  - Both fail → raises `Geolocate::Error`.
- **`test/migrations_test.rb`** — temp `XDG_STATE_HOME`. Cases:
  - Marker absent + `audio.enabled = true` under `[audio]` → flips to false, marker created, stderr line written.
  - Marker absent + `notifications.enabled = true` (also a hit on `enabled = true`) → does NOT flip notifications. Verifies section-aware rewrite.
  - Marker present → no-op (no read of config).
  - Audio already `enabled = false` → marker created, no rewrite, no stderr.
  - Config file missing → no crash, marker still created.
- **`test/tui_relocate_test.rb`** — minimal: instantiate TUI, stub `Relocate.run` and `refresh_schedule`, verify `relocate_here` updates `@cfg` and emits toast text. (TUI rendering itself isn't unit-tested; keep this focused on the dispatch.)
- **`test/waybar_test.rb`** — extend or add: `{city}` substitution; format without `{city}` produces same output as today; empty city → empty substitution.

**SUNNI catalog discipline** ([[feedback-test-isolation]]): any test that mutates module-level constants (e.g. stubs `IpGeolocate`, monkey-patches `TzLocation::TABLE`) restores in `ensure`. The `AdhanCatalog::SUNNI` incident from v0.1.5 is the precedent.

## Out of scope

- GeoClue2 / WiFi-based location.
- Multi-provider IP voting.
- Geocoding API for TUI city-name entry (user picks from system signals, not free-form input).
- Migrating existing users' `waybar.format` to include `{city}`.
- Changing `notifications.enabled` default.
- Preserving knowledge of "user explicitly set `audio.enabled = true`" — after migration, the marker is the only state; re-enabling sticks.
- Auto-detecting `omarchy-prayer dev` workflows or source-development paths.

## File-by-file change summary

| File | Change |
|---|---|
| `lib/omarchy_prayer/tz_location.rb` | **New.** Zone resolution + `zone1970.tab` parser + ISO 6709 coord parse. |
| `lib/omarchy_prayer/geolocate.rb` | Rename `detect` → `detect_ip`; new `detect` orchestrates IP + TZ cross-check. |
| `lib/omarchy_prayer/migrations.rb` | **New.** One-shot `mute-default-v1` migration with marker file. |
| `lib/omarchy_prayer/config.rb` | `DEFAULTS['audio']['enabled']` → `false`; `DEFAULTS['waybar']['format']` → includes `{city}`. |
| `lib/omarchy_prayer/first_run.rb` | `TEMPLATE` writes `audio.enabled = false` with explanatory comment. |
| `lib/omarchy_prayer/waybar.rb` | `render` gains `city:` kwarg; substitutes `{city}` placeholder. |
| `lib/omarchy_prayer/tui.rb` | `l` hotkey → `relocate_here`; `t` shows "audio disabled" toast when applicable; hotkey row updated. |
| `bin/omarchy-prayer` | Invoke `Migrations.run` after `FirstRun.ensure_config!`. |
| `bin/omarchy-prayer-schedule` | Invoke `Migrations.run` after `FirstRun.ensure_config!`. |
| `bin/omarchy-prayer-waybar` | Pass `city: cfg.city` to `Waybar.render`. |
| `README.md` | Document `{city}` placeholder, muted-by-default behavior with opt-in instructions, TUI `[l] relocate` hotkey. |
| `test/tz_location_test.rb` | **New.** |
| `test/geolocate_cross_check_test.rb` | **New.** |
| `test/migrations_test.rb` | **New.** |
| `test/tui_relocate_test.rb` | **New** (minimal). |
| `test/waybar_test.rb` | **Extend or new.** |
