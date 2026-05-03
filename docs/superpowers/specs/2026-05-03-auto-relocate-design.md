# Auto-relocate on schedule + network-up; friendlier TUI dates

## Motivation

`omarchy-prayer` geolocates via IP only on first run (`lib/omarchy_prayer/first_run.rb:48` returns early if `config.toml` exists) or when the user explicitly invokes `omarchy-prayer relocate`. Travel between cities or countries leaves the schedule computing prayer times for the previous location until the user notices and runs `relocate` manually.

The existing schedule timer already runs at startup (`OnStartupSec=30s`), daily at 00:01, on resume from suspend (`omarchy-prayer-resume.service`), and on `omarchy-prayer refresh`. Wiring auto-detection into that script covers most travel scenarios. A NetworkManager dispatcher hook adds instant updates when the user joins a new network mid-session.

## Design

### `OmarchyPrayer::AutoRelocate` (`lib/omarchy_prayer/auto_relocate.rb`)

One public entry point:

```ruby
AutoRelocate.maybe_update(cfg, threshold_km: 50, geolocate: Geolocate, io: $stderr) → loc | nil
```

Logic:

1. `geolocate.detect` — on `Geolocate::Error`, `SocketError`, `Errno::*` (any network failure): log a warning to `io` and return `nil`. **Must never raise** — the schedule run depends on it.
2. Compare detected vs `cfg`:
   - If `country` differs → update.
   - Else compute great-circle distance (haversine, inline helper) between `(cfg.latitude, cfg.longitude)` and detected coords. If `> threshold_km` → update.
   - Else → return `nil` (no-op).
   - City strings are not compared — ip-api.com sometimes returns variants ("Riyadh" vs "Ar Riyadh") that would thrash the config without a real location change. The city field is updated when an update fires for another reason; it stays informational.
3. On update: delegate to `Relocate.update_config!(loc)` and `Relocate.clear_month_caches` (existing helpers in `lib/omarchy_prayer/relocate.rb`). No duplication.
4. Log: `omarchy-prayer: auto-relocated Riyadh, SA → Makkah, SA (Δ 870 km)`.
5. Return the new `loc` hash so the caller knows config changed.

Threshold default `50 km`: catches inter-city travel (Riyadh → Makkah ≈ 870 km, Riyadh → Dammam ≈ 400 km), tolerates ISP-hub jitter within metro areas (Riyadh metro is ~80 km wide but the ISP hub is stable, so detection is consistent within a metro).

### Opt-out: `auto_update` config flag

Add to the `[location]` block in `config.toml`:

```toml
[location]
latitude   = 24.7136
longitude  = 46.6753
city       = "Riyadh"
country    = "SA"
auto_update = true   # default; set false to pin location
```

`Config` exposes `cfg.auto_update?`, defaulting to `true` when the key is missing (back-compat for existing configs — they get auto-update opt-in transparently). `FirstRun::TEMPLATE` writes `auto_update = true` so new configs include the comment for discoverability.

Validation in `Config#validate!`: if present, must be boolean.

### Daily safety net: wire into `bin/omarchy-prayer-schedule`

Between `FirstRun.ensure_config!` and the existing `Config.load`:

```ruby
OmarchyPrayer::FirstRun.ensure_config!
cfg = OmarchyPrayer::Config.load
if cfg.auto_update? && OmarchyPrayer::AutoRelocate.maybe_update(cfg)
  cfg = OmarchyPrayer::Config.load   # reload after rewrite
end
```

This gives four trigger points already: 00:01 daily timer, session-startup (`OnStartupSec=30s`), resume-from-suspend, and `omarchy-prayer refresh`.

### Network-up trigger: NetworkManager dispatcher

New file `share/networkmanager/90-omarchy-prayer`:

```bash
#!/bin/bash
# NetworkManager dispatcher: trigger omarchy-prayer schedule rebuild on connection up.
[ "$2" = "up" ] || exit 0
USER_NAME=$(loginctl list-sessions --no-legend | awk '/seat0/{print $3; exit}')
[ -n "$USER_NAME" ] || exit 0
USER_UID=$(id -u "$USER_NAME") || exit 0
runuser -l "$USER_NAME" -c \
  "XDG_RUNTIME_DIR=/run/user/$USER_UID systemctl --user start omarchy-prayer-schedule.service" \
  >/dev/null 2>&1 || true
```

Triggers `omarchy-prayer-schedule.service` for the active graphical user on every connection up event; that service runs the same schedule script which now performs auto-relocate. Fire-and-forget, swallows errors so it never breaks NM.

#### Install via `install.sh`

New step after the systemd-units step:

```bash
NM_DISPATCHER=/etc/NetworkManager/dispatcher.d
if [ -d "$NM_DISPATCHER" ]; then
  msg "installing NetworkManager dispatcher (requires sudo)"
  sudo install -m 0755 -o root -g root \
    "$PROJECT_DIR/share/networkmanager/90-omarchy-prayer" \
    "$NM_DISPATCHER/90-omarchy-prayer" \
    || warn "could not install NM dispatcher — auto-relocate falls back to daily timer only"
else
  warn "NetworkManager dispatcher dir not found — auto-relocate falls back to daily timer only"
fi
```

User declines sudo / no NetworkManager → install continues, daily safety net still works. Non-fatal.

### Tests

New `test/test_auto_relocate.rb`:

- `test_no_op_when_within_threshold` — detected coords < 50 km from cfg, same city/country → returns nil, config unchanged, no caches cleared.
- `test_updates_when_country_differs` — `cfg.country = "SA"`, detected `"AE"` → returns loc, config rewritten, caches cleared.
- `test_updates_when_distance_exceeds_threshold` — same country, coords > 50 km apart → updates.
- `test_no_update_on_city_string_variation` — same country, coords < 50 km apart, different city string ("Riyadh" vs "Ar Riyadh") → no-op (regression guard against city-string thrashing).
- `test_tolerates_geolocate_error` — stub raises `Geolocate::Error` → returns nil, logs warning, config unchanged.
- `test_tolerates_network_error` — stub raises `SocketError` → returns nil, logs warning.
- `test_respects_disabled_flag` — caller checks `cfg.auto_update?` itself; this test asserts `Config#auto_update?` defaults to `true` and parses `false` correctly.

Existing `test/test_relocate.rb`: untouched — manual `relocate` behavior is unchanged. `test/test_config.rb`: add cases for `auto_update` parsing (default true, explicit true/false, validates non-bool).

`test/test_bootstrap.rb` (smoke test that loads schedule script): no changes expected — `AutoRelocate.maybe_update` is tolerant of network errors so isolated test runs (no network) just log a warning.

### README updates

Replace the "Updating location" section content (currently directs users to `omarchy-prayer relocate` after travel):

- Lead: auto-update is on by default. The schedule rebuild (daily, on startup, on resume, on connection up) re-detects via IP and rewrites `[location]` if the country changed or coords moved more than 50 km.
- Note ISP-hub jitter (e.g. Makkah IPs resolve to Jeddah) and that the 50 km threshold is large enough to tolerate it within a metro.
- Disable: set `auto_update = false` in `[location]`.
- Manual override still available via `omarchy-prayer relocate --lat ... --lon ... --city ... --country ...`.
- NM dispatcher: installed by `install.sh` for instant updates on network change; if absent, falls back to the daily/startup/resume triggers.

### TUI header: friendlier date display

The current TUI header (`lib/omarchy_prayer/tui.rb:66-70`) renders:

```
                    OMARCHY  PRAYER
                Riyadh, SA     ·     2026-05-03
                  15 Dhu al-Qi'dah 1447
```

Update `render_header` to:

1. Format Gregorian as `Sun, 3 May 2026` (`%a, %-d %b %Y`) instead of ISO `2026-05-03`.
2. Render both dates on a single line when Hijri is available: `Sun, 3 May 2026  ·  15 Dhu al-Qi'dah 1447`.
3. Hijri-missing fallback: just the Gregorian line (current offline path goes through `OfflineCalc` which doesn't supply Hijri — keep that behavior unchanged).
4. Location line stays as `City, CC`.

New TUI test assertions in `test/test_tui.rb` (or whichever covers `render_header`): seed a `Today` with both dates and assert the rendered header contains `Sun, 3 May 2026  ·  15 Dhu al-Qi'dah 1447`; seed without `hijri` and assert only the Gregorian portion appears.

If no `test_tui.rb` exists, this gets a small new test file that exercises `render_header` against an in-memory `StringIO` writer.

## Out of scope

- GeoIP databases for offline detection (current ip-api.com call requires network anyway).
- DNS-based or cellular-modem location sources.
- Notifying the user when auto-relocate fires (a log line is enough; the user sees the new city in `omarchy-prayer status`).
- Rate limiting beyond the natural cadence of the trigger points (worst case: NM dispatcher fires several times during a flaky reconnect — each call is a single ip-api.com request, well within free-tier limits).
