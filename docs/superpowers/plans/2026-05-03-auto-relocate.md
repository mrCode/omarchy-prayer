# Auto-relocate + friendlier TUI dates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-detect location via IP on the existing schedule rebuild triggers (and a new NetworkManager dispatcher), and render the TUI header dates in a friendlier format.

**Architecture:**
- New `OmarchyPrayer::AutoRelocate` module that geolocates, compares against `cfg`, and delegates to existing `Relocate.update_config!` / `Relocate.clear_month_caches` when country changes or coords drift > 50 km.
- `bin/omarchy-prayer-schedule` calls `AutoRelocate.maybe_update(cfg)` between `FirstRun.ensure_config!` and the rest of the run; reloads cfg if it returns truthy.
- New `share/networkmanager/90-omarchy-prayer` dispatcher script triggers the user-mode `omarchy-prayer-schedule.service` on connection-up; `install.sh` installs it via `sudo`.
- `[location].auto_update` (default `true`) opt-out, parsed by `Config`.
- TUI header: render Gregorian as `Sun, 3 May 2026` and combine with Hijri on one line.

**Tech Stack:** Ruby (no new deps), `Net::HTTP` (already used by `Geolocate`), systemd user units, NetworkManager dispatcher (bash).

---

## File Structure

- Create:
  - `lib/omarchy_prayer/auto_relocate.rb` — core auto-relocate logic.
  - `share/networkmanager/90-omarchy-prayer` — NM dispatcher script.
  - `test/test_auto_relocate.rb` — unit tests for the module.
  - `test/test_tui.rb` — header-rendering tests.
- Modify:
  - `lib/omarchy_prayer/config.rb` — add `auto_update?` reader + validation.
  - `lib/omarchy_prayer/first_run.rb` — add `auto_update = true` to `TEMPLATE`.
  - `lib/omarchy_prayer/relocate.rb` — make `clear_month_caches` and `update_config!` callable from `AutoRelocate` (already module-level; just confirm).
  - `lib/omarchy_prayer/tui.rb` — `render_header` formatting.
  - `bin/omarchy-prayer-schedule` — call `AutoRelocate.maybe_update`.
  - `install.sh` — install the NM dispatcher via sudo.
  - `test/test_config.rb` — `auto_update?` parsing tests.
  - `README.md` — update the "Updating location" section.

---

### Task 1: `Config#auto_update?` with default `true`

**Files:**
- Modify: `lib/omarchy_prayer/config.rb`
- Test: `test/test_config.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_config.rb` (before the final `end`):

```ruby
  def test_auto_update_defaults_to_true_when_missing
    write_config(MINIMAL) do |cfg, _|
      assert_equal true, cfg.auto_update?
    end
  end

  def test_auto_update_explicit_false_parsed
    cfg_text = MINIMAL.sub("country = \"SA\"\n", "country = \"SA\"\nauto_update = false\n")
    write_config(cfg_text) do |cfg, _|
      assert_equal false, cfg.auto_update?
    end
  end

  def test_auto_update_explicit_true_parsed
    cfg_text = MINIMAL.sub("country = \"SA\"\n", "country = \"SA\"\nauto_update = true\n")
    write_config(cfg_text) do |cfg, _|
      assert_equal true, cfg.auto_update?
    end
  end

  def test_auto_update_non_boolean_rejected
    cfg_text = MINIMAL.sub("country = \"SA\"\n", "country = \"SA\"\nauto_update = \"yes\"\n")
    assert_raises(OmarchyPrayer::Config::InvalidError) do
      write_config(cfg_text) { }
    end
  end
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `bundle exec rake test TEST=test/test_config.rb`
Expected: FAIL — `NoMethodError: undefined method 'auto_update?'` (or InvalidError tests fail).

- [ ] **Step 3: Add the reader and validation**

Edit `lib/omarchy_prayer/config.rb`. After line 40 (`def country; ... end`), add:

```ruby
    def auto_update?
      v = @raw['location'].fetch('auto_update', true)
      v
    end
```

In `validate!`, after the longitude range check (around line 78), add:

```ruby
      if loc.key?('auto_update') && ![true, false].include?(loc['auto_update'])
        raise InvalidError, '[location].auto_update must be a boolean'
      end
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `bundle exec rake test TEST=test/test_config.rb`
Expected: PASS, including the four new tests.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/config.rb test/test_config.rb
git commit -m "$(cat <<'EOF'
feat(config): add [location].auto_update flag (default true)

Reader Config#auto_update? returns true when the key is missing so
existing configs opt into auto-relocate transparently. Validates that
the value, when present, is a boolean.

EOF
)"
```

---

### Task 2: `AutoRelocate` module — happy path + thresholds

**Files:**
- Create: `lib/omarchy_prayer/auto_relocate.rb`
- Test: `test/test_auto_relocate.rb`

- [ ] **Step 1: Write the failing test file**

Create `test/test_auto_relocate.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/auto_relocate'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'

class TestAutoRelocate < Minitest::Test
  include TestHelper

  RIYADH = { latitude: 24.7136, longitude: 46.6753, city: 'Riyadh', country: 'SA' }.freeze
  MAKKAH = { latitude: 21.4225, longitude: 39.8262, city: 'Makkah', country: 'SA' }.freeze
  DUBAI  = { latitude: 25.2048, longitude: 55.2708, city: 'Dubai',  country: 'AE' }.freeze

  def stub_geo(loc)
    Class.new do
      define_singleton_method(:detect) { loc }
    end
  end

  def raising_geo(error_class, message = 'boom')
    Class.new do
      define_singleton_method(:detect) { raise error_class, message }
    end
  end

  def seed_config(loc = RIYADH)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      # comment must survive
      latitude  = #{format('%.4f', loc[:latitude])}
      longitude = #{format('%.4f', loc[:longitude])}
      city      = "#{loc[:city]}"
      country   = "#{loc[:country]}"

      [method]
      name = "auto"
    TOML
  end

  def seed_caches
    FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
    %w[times-2026-04-old.json times-2026-05-old.json].each do |f|
      File.write(File.join(OmarchyPrayer::Paths.state_dir, f), '{}')
    end
  end

  def test_no_op_when_within_threshold
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      nearby = RIYADH.merge(latitude: 24.75, longitude: 46.70) # ~5 km away
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(nearby), io: io)
      assert_nil result
      assert_match(/Riyadh/, File.read(OmarchyPrayer::Paths.config_file))
      refute_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
    end
  end

  def test_updates_when_country_differs
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(DUBAI), io: io)
      refute_nil result
      assert_equal 'AE', result[:country]
      cfg_text = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/country\s*=\s*"AE"/, cfg_text)
      assert_match(/city\s*=\s*"Dubai"/, cfg_text)
      assert_match(/# comment must survive/, cfg_text)
      assert_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
      assert_match(/auto-relocated/, io.string)
    end
  end

  def test_updates_when_distance_exceeds_threshold
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      # Riyadh → Makkah is ~870 km; same country, so the distance branch fires.
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(MAKKAH), io: io)
      refute_nil result
      cfg_text = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/city\s*=\s*"Makkah"/, cfg_text)
      assert_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
    end
  end

  def test_no_update_on_city_string_variation
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      variant = RIYADH.merge(city: 'Ar Riyadh', latitude: 24.72, longitude: 46.68) # ~1 km
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(variant), io: io)
      assert_nil result
      assert_match(/city\s*=\s*"Riyadh"/, File.read(OmarchyPrayer::Paths.config_file))
    end
  end

  def test_tolerates_geolocate_error
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(
        cfg, geolocate: raising_geo(OmarchyPrayer::Geolocate::Error, 'http 503'), io: io
      )
      assert_nil result
      assert_match(/auto-relocate skipped/, io.string)
      assert_match(/Riyadh/, File.read(OmarchyPrayer::Paths.config_file))
    end
  end

  def test_tolerates_network_error
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(
        cfg, geolocate: raising_geo(SocketError, 'getaddrinfo: name or service not known'), io: io
      )
      assert_nil result
      assert_match(/auto-relocate skipped/, io.string)
    end
  end
end
```

- [ ] **Step 2: Run the tests — verify they fail**

Run: `bundle exec rake test TEST=test/test_auto_relocate.rb`
Expected: FAIL — `cannot load such file -- omarchy_prayer/auto_relocate`.

- [ ] **Step 3: Implement the module**

Create `lib/omarchy_prayer/auto_relocate.rb`:

```ruby
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/relocate'

module OmarchyPrayer
  module AutoRelocate
    DEFAULT_THRESHOLD_KM = 50

    module_function

    # Returns the new loc Hash on update, or nil on no-op / detection failure.
    # Never raises — schedule runs depend on this completing.
    def maybe_update(cfg, threshold_km: DEFAULT_THRESHOLD_KM, geolocate: Geolocate, io: $stderr)
      detected = geolocate.detect
      return nil unless update_needed?(cfg, detected, threshold_km)

      previous = format('%s, %s', cfg.city, cfg.country)
      Relocate.update_config!(detected)
      Relocate.clear_month_caches
      delta_km = haversine_km(cfg.latitude, cfg.longitude, detected[:latitude], detected[:longitude])
      io.puts format('omarchy-prayer: auto-relocated %s → %s, %s (Δ %d km)',
                     previous, detected[:city], detected[:country], delta_km.round)
      detected
    rescue Geolocate::Error, SocketError, Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH, Timeout::Error => e
      io.puts "omarchy-prayer: auto-relocate skipped (#{e.class}: #{e.message})"
      nil
    end

    def update_needed?(cfg, detected, threshold_km)
      return true if cfg.country.to_s.upcase != detected[:country].to_s.upcase
      haversine_km(cfg.latitude, cfg.longitude, detected[:latitude], detected[:longitude]) > threshold_km
    end

    # Great-circle distance in kilometres.
    def haversine_km(lat1, lon1, lat2, lon2)
      r = 6371.0
      to_rad = ->(d) { d * Math::PI / 180.0 }
      dlat = to_rad.call(lat2 - lat1)
      dlon = to_rad.call(lon2 - lon1)
      a = Math.sin(dlat / 2)**2 +
          Math.cos(to_rad.call(lat1)) * Math.cos(to_rad.call(lat2)) *
          Math.sin(dlon / 2)**2
      2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
  end
end
```

- [ ] **Step 4: Run the tests — verify they pass**

Run: `bundle exec rake test TEST=test/test_auto_relocate.rb`
Expected: PASS — all six tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/auto_relocate.rb test/test_auto_relocate.rb
git commit -m "$(cat <<'EOF'
feat(auto-relocate): add AutoRelocate.maybe_update

Geolocates via IP and rewrites [location] when the country changes or
detected coordinates drift > 50 km from config. Delegates the rewrite
+ cache-clear to the existing Relocate helpers. Tolerates network
errors so it can be wired into the schedule run without breaking it.

EOF
)"
```

---

### Task 3: Wire `AutoRelocate.maybe_update` into the schedule script

**Files:**
- Modify: `bin/omarchy-prayer-schedule`
- Modify: `lib/omarchy_prayer/first_run.rb` (TEMPLATE)

- [ ] **Step 1: Add `auto_update = true` to the FirstRun template**

Edit `lib/omarchy_prayer/first_run.rb`. Replace the `[location]` block in `TEMPLATE` (lines 9–14) with:

```ruby
      [location]
      # Edit freely; filled from IP geolocation on first run.
      latitude    = %<lat>.4f
      longitude   = %<lon>.4f
      city        = "%<city>s"
      country     = "%<country>s"
      # Re-detect on every schedule run (daily, on resume, on network up).
      # Set to false to pin location and only update via `omarchy-prayer relocate`.
      auto_update = true
```

- [ ] **Step 2: Wire AutoRelocate into the schedule script**

Edit `bin/omarchy-prayer-schedule`. After the `require` lines (line 12), add:

```ruby
require 'omarchy_prayer/auto_relocate'
```

Replace lines 22–23 (`OmarchyPrayer::FirstRun.ensure_config!` and `cfg = OmarchyPrayer::Config.load`) with:

```ruby
OmarchyPrayer::FirstRun.ensure_config!
cfg = OmarchyPrayer::Config.load
if cfg.auto_update? && OmarchyPrayer::AutoRelocate.maybe_update(cfg)
  cfg = OmarchyPrayer::Config.load
end
```

- [ ] **Step 3: Add a smoke test for the schedule wire-up**

Append to `test/test_auto_relocate.rb` (before the final `end`):

```ruby
  def test_schedule_script_calls_auto_relocate
    # Smoke check: the schedule script requires auto_relocate and calls maybe_update.
    src = File.read(File.expand_path('../bin/omarchy-prayer-schedule', __dir__))
    assert_match(%r{require 'omarchy_prayer/auto_relocate'}, src)
    assert_match(/AutoRelocate\.maybe_update\(cfg\)/, src)
  end
```

- [ ] **Step 4: Run the full test suite**

Run: `bundle exec rake test`
Expected: PASS — including the new smoke test and existing schedule/bootstrap tests.

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-prayer-schedule lib/omarchy_prayer/first_run.rb test/test_auto_relocate.rb
git commit -m "$(cat <<'EOF'
feat(schedule): auto-relocate before each rebuild

Wires AutoRelocate.maybe_update into omarchy-prayer-schedule between
FirstRun.ensure_config! and the rest of the run. Adds the auto_update
flag to the FirstRun TEMPLATE so new configs include the comment for
discoverability.

EOF
)"
```

---

### Task 4: NetworkManager dispatcher + install.sh integration

**Files:**
- Create: `share/networkmanager/90-omarchy-prayer`
- Modify: `install.sh`

- [ ] **Step 1: Create the dispatcher script**

Create `share/networkmanager/90-omarchy-prayer`:

```bash
#!/bin/bash
# NetworkManager dispatcher: trigger omarchy-prayer schedule rebuild on
# connection up. The schedule script auto-relocates if cfg.auto_update is set.
# Installed at /etc/NetworkManager/dispatcher.d/90-omarchy-prayer (root).

[ "$2" = "up" ] || exit 0

USER_NAME=$(loginctl list-sessions --no-legend 2>/dev/null \
  | awk '/seat0/ {print $3; exit}')
[ -n "$USER_NAME" ] || exit 0

USER_UID=$(id -u "$USER_NAME" 2>/dev/null) || exit 0

runuser -l "$USER_NAME" -c \
  "XDG_RUNTIME_DIR=/run/user/$USER_UID systemctl --user start omarchy-prayer-schedule.service" \
  >/dev/null 2>&1 || true

exit 0
```

Make it executable:

```bash
chmod +x share/networkmanager/90-omarchy-prayer
```

- [ ] **Step 2: Wire into install.sh**

Edit `install.sh`. After the `systemctl --user enable` block (lines 49–56), insert:

```bash
NM_DISPATCHER=/etc/NetworkManager/dispatcher.d
if [ -d "$NM_DISPATCHER" ]; then
  msg "installing NetworkManager dispatcher (sudo) → $NM_DISPATCHER/90-omarchy-prayer"
  if sudo install -m 0755 -o root -g root \
       "$PROJECT_DIR/share/networkmanager/90-omarchy-prayer" \
       "$NM_DISPATCHER/90-omarchy-prayer"; then
    msg "NM dispatcher installed — auto-relocate will fire on connection-up"
  else
    warn "NM dispatcher install failed — falling back to daily/startup/resume triggers"
  fi
else
  warn "NetworkManager dispatcher dir not found ($NM_DISPATCHER) — auto-relocate falls back to daily/startup/resume triggers"
fi
```

- [ ] **Step 3: Add a smoke test for the dispatcher script**

Append to `test/test_auto_relocate.rb` (before the final `end`):

```ruby
  def test_dispatcher_script_present_and_executable
    path = File.expand_path('../share/networkmanager/90-omarchy-prayer', __dir__)
    assert File.exist?(path), 'dispatcher script missing'
    assert File.executable?(path), 'dispatcher script not executable'
    body = File.read(path)
    assert_match(%r{omarchy-prayer-schedule\.service}, body)
    assert_match(/loginctl list-sessions/, body)
  end
```

- [ ] **Step 4: Run the full test suite**

Run: `bundle exec rake test`
Expected: PASS — includes the new dispatcher smoke test.

- [ ] **Step 5: Commit**

```bash
git add share/networkmanager/90-omarchy-prayer install.sh test/test_auto_relocate.rb
git commit -m "$(cat <<'EOF'
feat(install): install NetworkManager dispatcher for auto-relocate

Drops a dispatcher script at /etc/NetworkManager/dispatcher.d/ that
triggers the user-mode omarchy-prayer-schedule.service on every
connection-up event. install.sh prompts for sudo once during install;
if NM is absent or sudo declined, install continues with the daily +
startup + resume triggers as the safety net.

EOF
)"
```

---

### Task 5: TUI header — friendlier dates

**Files:**
- Modify: `lib/omarchy_prayer/tui.rb`
- Create: `test/test_tui.rb`

- [ ] **Step 1: Write the failing test file**

Create `test/test_tui.rb`:

```ruby
require 'test_helper'
require 'stringio'
require 'omarchy_prayer/tui'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'

class TestTUI < Minitest::Test
  include TestHelper

  CONFIG = <<~TOML
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"
  TOML

  TIMES = {
    'fajr' => '04:30', 'dhuhr' => '11:50', 'asr' => '15:20',
    'maghrib' => '18:35', 'isha' => '20:05'
  }.freeze

  def with_seed(hijri:)
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, CONFIG)
      OmarchyPrayer::Today.new(
        date: '2026-05-03', tz_offset: 3 * 3600,
        city: 'Riyadh', country: 'SA',
        method: 'Makkah', source: 'aladhan',
        times: TIMES, hijri: hijri
      ).write
      yield
    end
  end

  def render_header_to_string(width: 80)
    out = StringIO.new
    tui = OmarchyPrayer::TUI.new(out: out, input: StringIO.new(''))
    tui.instance_variable_set(:@cfg, OmarchyPrayer::Config.load)
    tui.instance_variable_set(:@today, OmarchyPrayer::Today.read)
    tui.instance_variable_set(:@width, width)
    tui.send(:render_header)
    plain = out.string.gsub(/\e\[[0-9;]*m/, '')
    plain
  end

  def test_header_combines_dates_when_hijri_present
    with_seed(hijri: '15 Dhu al-Qi\'dah 1447') do
      out = render_header_to_string
      assert_match(/Riyadh, SA/, out)
      assert_match(/Sun, 3 May 2026/, out)
      assert_match(/15 Dhu al-Qi'dah 1447/, out)
      # Both dates on the same line, joined by the dot separator.
      assert_match(/Sun, 3 May 2026.*·.*15 Dhu al-Qi'dah 1447/, out)
    end
  end

  def test_header_falls_back_to_gregorian_only_when_hijri_missing
    with_seed(hijri: nil) do
      out = render_header_to_string
      assert_match(/Riyadh, SA/, out)
      assert_match(/Sun, 3 May 2026/, out)
      refute_match(/Dhu al-Qi'dah/, out)
    end
  end
end
```

- [ ] **Step 2: Run the tests — verify they fail**

Run: `bundle exec rake test TEST=test/test_tui.rb`
Expected: FAIL — `Sun, 3 May 2026` not found (current TUI prints `2026-05-03`).

- [ ] **Step 3: Update `render_header`**

Edit `lib/omarchy_prayer/tui.rb`. Replace lines 66–70:

```ruby
    def render_header
      center bold + fg(:accent) + 'OMARCHY  PRAYER' + rst
      center fg(:muted) + "#{@cfg.city}, #{@cfg.country}" + rst
      center fg(:muted) + format_date_line + rst
    end

    def format_date_line
      gregorian = format_gregorian(@today.date)
      @today.hijri ? "#{gregorian}     #{dot}     #{@today.hijri}" : gregorian
    end

    def format_gregorian(iso_date)
      Date.parse(iso_date).strftime('%a, %-d %b %Y')
    end
```

Add `require 'date'` at the top of the file (after the existing requires) if not already present.

- [ ] **Step 4: Run the tests — verify they pass**

Run: `bundle exec rake test TEST=test/test_tui.rb`
Expected: PASS — both header tests green.

Then run the full suite: `bundle exec rake test`
Expected: PASS — no regressions in existing tests.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tui.rb test/test_tui.rb
git commit -m "$(cat <<'EOF'
feat(tui): friendlier date formatting in header

Render Gregorian as "Sun, 3 May 2026" instead of the ISO "2026-05-03"
and combine with the Hijri date on a single line when the API supplied
one. Location stays on its own line above the dates.

EOF
)"
```

---

### Task 6: README — replace the "Updating location" section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the current section**

Run: `grep -n "Updating location" README.md`
Expected: line ~91.

- [ ] **Step 2: Replace the section**

Replace the existing `### Updating location` block (currently at README.md:91–100) with:

```markdown
### Updating location

Location auto-updates on every schedule rebuild — daily at 00:01, on session start, on resume from suspend, on `omarchy-prayer refresh`, and (if the NetworkManager dispatcher was installed) on every network connection-up. Each rebuild re-detects via ip-api.com and rewrites `[location]` in `config.toml` if the **country** changed or detected **coordinates drift more than 50 km** from the configured ones.

The 50 km threshold is large enough to absorb ip-api.com's regional-hub jitter (e.g. an IP in Makkah commonly resolves to Jeddah — same metro, no rewrite) while still catching real travel between cities.

To disable auto-update — for example, if you want the schedule pinned to a city you don't currently live in — set `auto_update = false` in the `[location]` block of `config.toml`. Manual override is still available:

```bash
omarchy-prayer relocate                                            # one-shot re-detect via IP
omarchy-prayer relocate --lat 21.4225 --lon 39.8262 --city Makkah --country SA   # manual override
```

`relocate` rewrites the `[location]` block (preserving comments and other settings), invalidates cached month data so prayer times for the new location are fetched fresh, and runs the scheduler so today's times take effect immediately.

The NetworkManager dispatcher is installed by `install.sh` via sudo. If you skipped sudo or installed without it, install it manually:

```bash
sudo install -m 0755 -o root -g root \
  share/networkmanager/90-omarchy-prayer \
  /etc/NetworkManager/dispatcher.d/90-omarchy-prayer
```
```

- [ ] **Step 3: Eyeball the rendered README**

Run: `grep -A 25 "### Updating location" README.md`
Expected: the new content above; no leftover lines from the old paragraph.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): document auto-relocate + opt-out

Replaces the "when you travel — use relocate" paragraph with the
auto-update behaviour (triggers, 50 km threshold, ISP-hub note,
auto_update opt-out, NM dispatcher install instructions).

EOF
)"
```

---

### Task 7: Final verification

- [ ] **Step 1: Run the full test suite**

Run: `bundle exec rake test`
Expected: PASS, no skips, no warnings about new files.

- [ ] **Step 2: Sanity-check the schedule script in isolation**

Run: `ruby -Ilib bin/omarchy-prayer-schedule 2>&1 | head -5`
Expected: either prints `auto-relocated …` then `scheduled …`, or just `scheduled …` (if your config matches your current IP); must NOT raise.

- [ ] **Step 3: Sanity-check the TUI**

Run: `ruby -Ilib bin/omarchy-prayer today` and `ruby -Ilib bin/omarchy-prayer status` to confirm nothing regressed; then briefly launch `ruby -Ilib bin/omarchy-prayer` (TUI mode), inspect the header, press `q` to quit. Header line should read `Sun, 3 May 2026     ·     <hijri>` (or just the Gregorian half if no hijri in `today.json`).

- [ ] **Step 4: Reinstall locally (optional, exercises install.sh)**

Run: `./install.sh`
Expected: prompts once for sudo to install the NM dispatcher; existing functionality unaffected. If you skip sudo, install completes with a warning.
