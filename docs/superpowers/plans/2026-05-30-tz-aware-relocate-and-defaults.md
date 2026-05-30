# TZ-aware Relocate + Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `omarchy-prayer` location detection robust to roaming/VPN by cross-checking IP geolocation against system timezone; mute the adhan audio by default (notifications still fire) with a one-time migration for existing users; add a `[l]` relocate hotkey to the TUI; add a `{city}` placeholder to the waybar widget.

**Architecture:**
- New `OmarchyPrayer::TzLocation` reads `/etc/localtime` (or `$TZ` / `timedatectl`) and parses `/usr/share/zoneinfo/zone1970.tab` to derive `{countries, lat, lon, city}` offline. No new runtime deps.
- `OmarchyPrayer::Geolocate.detect` becomes an orchestrator: existing HTTP code moves to `Geolocate.detect_ip`; the orchestrator returns IP if the IP-country lies inside the TZ-zone's country set, otherwise TZ-derived. All three current callers (`FirstRun`, `AutoRelocate`, `Relocate`) call `.detect` and pick up the cross-check transparently.
- New `OmarchyPrayer::Migrations` runs a one-shot, marker-gated migration that flips `audio.enabled = true` → `false` for existing users under the `[audio]` section only. Invoked from `bin/omarchy-prayer` and `bin/omarchy-prayer-schedule`.
- `Config::DEFAULTS` and `FirstRun::TEMPLATE` updated so fresh installs write `audio.enabled = false` and `waybar.format = '{city} · {prayer} {countdown}'`.
- `Waybar.render` gains a `city:` kwarg and substitutes `{city}`; `bin/omarchy-prayer-waybar` passes `cfg.city`.
- `TUI` gets `[l] relocate` that invokes `Relocate.run([])` (now TZ-aware), refreshes the schedule, and shows a brief toast in the hotkey row. `[t]` shows an "audio disabled" toast when `cfg.audio_enabled == false`.

**Tech Stack:** Ruby (no new deps), Minitest (existing), `tzdata` (system package, already required by Linux), TOML via `tomlrb` (existing).

---

## File Structure

- Create:
  - `lib/omarchy_prayer/tz_location.rb` — zone resolution + `zone1970.tab` parser + ISO 6709 coord parse.
  - `lib/omarchy_prayer/migrations.rb` — one-shot `mute-default-v1` migration with marker file.
  - `test/test_tz_location.rb` — unit tests, uses fixture `zone1970.tab`.
  - `test/test_migrations.rb` — unit tests for migration logic.
  - `test/fixtures/zone1970.tab` — small fixture (5 representative rows).
- Modify:
  - `lib/omarchy_prayer/geolocate.rb` — rename `detect` → `detect_ip`; add orchestrator `detect`.
  - `lib/omarchy_prayer/config.rb` — DEFAULTS: `audio.enabled = false`, `waybar.format = '{city} · {prayer} {countdown}'`.
  - `lib/omarchy_prayer/first_run.rb` — TEMPLATE: `audio.enabled = false` with explanatory comment, `waybar.format` includes `{city}`.
  - `lib/omarchy_prayer/waybar.rb` — `render` accepts `city:` kwarg, substitutes `{city}` placeholder.
  - `lib/omarchy_prayer/tui.rb` — `[l]` hotkey, `relocate_here`, toast helper, `t` audio-disabled toast, updated hotkey row.
  - `bin/omarchy-prayer` — `require 'omarchy_prayer/migrations'`, call `Migrations.run` after `FirstRun.ensure_config!`.
  - `bin/omarchy-prayer-schedule` — same.
  - `bin/omarchy-prayer-waybar` — pass `city: cfg.city` to `Waybar.render`.
  - `test/test_geolocate.rb` — adjust to test `detect_ip` (existing HTTP behavior) + new orchestrator tests.
  - `test/test_waybar.rb` — pass `city:` kwarg; add `{city}` substitution test.
  - `test/test_tui.rb` — add `relocate_here` dispatch test.
  - `README.md` — document `{city}` placeholder, muted-by-default behavior, `[l]` hotkey.

---

### Task 1: `TzLocation` test fixture

**Files:**
- Create: `test/fixtures/zone1970.tab`

- [ ] **Step 1: Create the fixture**

Create `test/fixtures/zone1970.tab` with content:

```
# Test fixture — subset of real zone1970.tab. DO NOT add comments mid-row.
# Format: country-codes<TAB>coordinates<TAB>TZ<TAB>comments
GB,GG,IM,JE	+513030-0000731	Europe/London
SA,AQ,KW,YE	+2438+04643	Asia/Riyadh	Syowa
US	+404251-0740023	America/New_York	Eastern (most areas)
US	+394606-0860929	America/Indiana/Indianapolis	Eastern - IN (most areas)
FR	+4852+00220	Europe/Paris
JP	+353916+1394441	Asia/Tokyo
```

NOTE: real columns are tab-separated. When you create the file, use literal tab characters between the country list, coords, zone name, and comment.

- [ ] **Step 2: Verify tabs are tabs, not spaces**

Run: `cat -A test/fixtures/zone1970.tab | head -3`

Expected: each row shows `^I` between fields (the tab marker).

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/zone1970.tab
git commit -m "test(tz): add zone1970.tab fixture for TzLocation tests"
```

---

### Task 2: `TzLocation` — zone-name resolution

**Files:**
- Create: `lib/omarchy_prayer/tz_location.rb`
- Test: `test/test_tz_location.rb`

- [ ] **Step 1: Write the failing test**

Create `test/test_tz_location.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/tz_location'

class TestTzLocation < Minitest::Test
  include TestHelper

  FIXTURE = File.expand_path('fixtures/zone1970.tab', __dir__)

  def test_zone_name_from_env
    orig = ENV['TZ']
    ENV['TZ'] = 'Europe/London'
    assert_equal 'Europe/London', OmarchyPrayer::TzLocation.zone_name
  ensure
    ENV['TZ'] = orig
  end

  def test_zone_name_blank_env_falls_through
    orig = ENV['TZ']
    ENV['TZ'] = ''
    # Without /etc/localtime guarantees, just assert it returns either nil or a string.
    result = OmarchyPrayer::TzLocation.zone_name
    assert(result.nil? || result.is_a?(String))
  ensure
    ENV['TZ'] = orig
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: FAIL — `cannot load such file -- omarchy_prayer/tz_location`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/omarchy_prayer/tz_location.rb`:

```ruby
module OmarchyPrayer
  module TzLocation
    DEFAULT_TAB = '/usr/share/zoneinfo/zone1970.tab'.freeze
    ZONEINFO_PREFIX = '/usr/share/zoneinfo/'.freeze

    module_function

    def zone_name
      env = ENV['TZ']
      return env if env && !env.empty?

      begin
        real = File.realpath('/etc/localtime')
        return real.sub(ZONEINFO_PREFIX, '') if real.start_with?(ZONEINFO_PREFIX)
      rescue Errno::ENOENT, Errno::EINVAL
        # /etc/localtime missing or not a symlink — fall through
      end

      out = `timedatectl show -p Timezone --value 2>/dev/null`.strip
      return out unless out.empty?

      nil
    rescue StandardError
      nil
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tz_location.rb test/test_tz_location.rb
git commit -m "feat(tz): TzLocation.zone_name resolves via env/symlink/timedatectl"
```

---

### Task 3: `TzLocation` — ISO 6709 coord parsing

**Files:**
- Modify: `lib/omarchy_prayer/tz_location.rb`
- Test: `test/test_tz_location.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tz_location.rb` (before the final `end`):

```ruby
  def test_parse_coord_short_form
    lat, lon = OmarchyPrayer::TzLocation.parse_iso6709('+2438+04643')
    assert_in_delta 24.6333, lat, 1e-4
    assert_in_delta 46.7166, lon, 1e-4
  end

  def test_parse_coord_long_form
    lat, lon = OmarchyPrayer::TzLocation.parse_iso6709('+513030-0000731')
    assert_in_delta 51.5083, lat, 1e-4
    assert_in_delta(-0.1253, lon, 1e-4)
  end

  def test_parse_coord_returns_nil_on_garbage
    assert_nil OmarchyPrayer::TzLocation.parse_iso6709('not-a-coord')
    assert_nil OmarchyPrayer::TzLocation.parse_iso6709('')
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: FAIL — `undefined method 'parse_iso6709' for OmarchyPrayer::TzLocation`.

- [ ] **Step 3: Implement**

Add to `lib/omarchy_prayer/tz_location.rb` (inside the module, after `zone_name`):

```ruby
    # ISO 6709 ±DDMM±DDDMM (11 chars) or ±DDMMSS±DDDMMSS (15 chars).
    SHORT_RE = /\A([+-]\d{2})(\d{2})([+-]\d{3})(\d{2})\z/
    LONG_RE  = /\A([+-]\d{2})(\d{2})(\d{2})([+-]\d{3})(\d{2})(\d{2})\z/

    def parse_iso6709(s)
      return nil if s.nil? || s.empty?
      if (m = LONG_RE.match(s))
        lat = m[1].to_i + m[2].to_i / 60.0 + m[3].to_i / 3600.0
        lon = m[4].to_i + m[5].to_i / 60.0 + m[6].to_i / 3600.0
        return [lat.round(4), lon.round(4)]
      end
      if (m = SHORT_RE.match(s))
        lat = m[1].to_i + m[2].to_i / 60.0
        lon = m[3].to_i + m[4].to_i / 60.0
        return [lat.round(4), lon.round(4)]
      end
      nil
    end
```

NOTE: The sign on degrees applies to the whole value when we add the unsigned minutes/seconds. For negative values (e.g. `-0000731`), `m[4].to_i` is `-0` which evaluates to `0`, so we need a sign-aware version. Fix:

```ruby
    def parse_iso6709(s)
      return nil if s.nil? || s.empty?
      if (m = LONG_RE.match(s))
        return [dms_to_deg(m[1], m[2], m[3]), dms_to_deg(m[4], m[5], m[6])]
      end
      if (m = SHORT_RE.match(s))
        return [dms_to_deg(m[1], m[2], '00'), dms_to_deg(m[3], m[4], '00')]
      end
      nil
    end

    def dms_to_deg(deg_signed, min_str, sec_str)
      sign = deg_signed.start_with?('-') ? -1 : 1
      deg = deg_signed.to_i.abs
      (sign * (deg + min_str.to_i / 60.0 + sec_str.to_i / 3600.0)).round(4)
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tz_location.rb test/test_tz_location.rb
git commit -m "feat(tz): parse ISO 6709 coords (both DMS forms)"
```

---

### Task 4: `TzLocation` — `zone1970.tab` parser

**Files:**
- Modify: `lib/omarchy_prayer/tz_location.rb`
- Test: `test/test_tz_location.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tz_location.rb`:

```ruby
  def test_table_loads_fixture
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    london = table['Europe/London']
    assert_equal %w[GB GG IM JE], london[:countries]
    assert_in_delta 51.5083, london[:lat], 1e-4
    assert_in_delta(-0.1253, london[:lon], 1e-4)
  end

  def test_table_handles_short_coord_form
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    riyadh = table['Asia/Riyadh']
    assert_equal %w[SA AQ KW YE], riyadh[:countries]
    assert_in_delta 24.6333, riyadh[:lat], 1e-4
    assert_in_delta 46.7166, riyadh[:lon], 1e-4
  end

  def test_table_skips_comment_and_blank_lines
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    refute_includes table.keys, '#'
    assert_equal 6, table.size
  end

  def test_table_missing_file_returns_empty
    assert_empty OmarchyPrayer::TzLocation.load_table('/nonexistent/zone1970.tab')
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: FAIL — `undefined method 'load_table'`.

- [ ] **Step 3: Implement**

Add to `lib/omarchy_prayer/tz_location.rb` (inside the module):

```ruby
    def load_table(path = DEFAULT_TAB)
      return {} unless File.exist?(path)
      table = {}
      File.foreach(path) do |line|
        line = line.chomp
        next if line.empty? || line.start_with?('#')
        cols = line.split("\t")
        next if cols.size < 3
        countries = cols[0].split(',')
        coord = parse_iso6709(cols[1])
        zone = cols[2]
        next unless coord && zone
        table[zone] = { countries: countries, lat: coord[0], lon: coord[1] }
      end
      table
    rescue StandardError
      {}
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tz_location.rb test/test_tz_location.rb
git commit -m "feat(tz): parse zone1970.tab into a {zone -> {countries, lat, lon}} table"
```

---

### Task 5: `TzLocation.detect` — public entry point

**Files:**
- Modify: `lib/omarchy_prayer/tz_location.rb`
- Test: `test/test_tz_location.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_tz_location.rb`:

```ruby
  def test_detect_returns_full_loc_for_known_zone
    orig = ENV['TZ']
    ENV['TZ'] = 'Europe/London'
    loc = OmarchyPrayer::TzLocation.detect(table_path: FIXTURE)
    assert_equal 'London', loc[:city]
    assert_equal 'GB', loc[:country]
    assert_equal %w[GB GG IM JE], loc[:countries]
    assert_in_delta 51.5083, loc[:latitude], 1e-4
    assert_in_delta(-0.1253, loc[:longitude], 1e-4)
    assert_equal 'Europe/London', loc[:zone]
  ensure
    ENV['TZ'] = orig
  end

  def test_detect_city_underscore_becomes_space
    orig = ENV['TZ']
    ENV['TZ'] = 'America/New_York'
    loc = OmarchyPrayer::TzLocation.detect(table_path: FIXTURE)
    assert_equal 'New York', loc[:city]
    assert_equal 'US', loc[:country]
  ensure
    ENV['TZ'] = orig
  end

  def test_detect_nested_zone_uses_last_segment
    orig = ENV['TZ']
    ENV['TZ'] = 'America/Indiana/Indianapolis'
    loc = OmarchyPrayer::TzLocation.detect(table_path: FIXTURE)
    assert_equal 'Indianapolis', loc[:city]
  ensure
    ENV['TZ'] = orig
  end

  def test_detect_returns_nil_when_zone_unresolved
    orig = ENV['TZ']
    ENV['TZ'] = 'Etc/Unknown-Zone'
    assert_nil OmarchyPrayer::TzLocation.detect(table_path: FIXTURE)
  ensure
    ENV['TZ'] = orig
  end

  def test_detect_returns_nil_when_zone_name_unavailable
    orig = ENV['TZ']
    ENV['TZ'] = ''
    # Force zone_name to nil by also pretending /etc/localtime is missing.
    # We just trust zone_name's fall-through; this test is best-effort.
    skip 'zone_name fallback depends on system' if OmarchyPrayer::TzLocation.zone_name
    assert_nil OmarchyPrayer::TzLocation.detect(table_path: FIXTURE)
  ensure
    ENV['TZ'] = orig
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: FAIL — `undefined method 'detect'`.

- [ ] **Step 3: Implement**

Add to `lib/omarchy_prayer/tz_location.rb`:

```ruby
    def detect(table_path: DEFAULT_TAB)
      zone = zone_name
      return nil if zone.nil? || zone.empty?
      row = load_table(table_path)[zone]
      return nil unless row
      city = zone.split('/').last.to_s.tr('_', ' ')
      country = row[:countries].first
      {
        latitude:  row[:lat],
        longitude: row[:lon],
        city:      city,
        country:   country,
        countries: row[:countries],
        zone:      zone
      }
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_tz_location.rb`
Expected: PASS (14 tests, possibly 1 skipped).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tz_location.rb test/test_tz_location.rb
git commit -m "feat(tz): TzLocation.detect returns full loc hash from system timezone"
```

---

### Task 6: Rename `Geolocate.detect` → `Geolocate.detect_ip`

**Files:**
- Modify: `lib/omarchy_prayer/geolocate.rb`
- Modify: `test/test_geolocate.rb`

- [ ] **Step 1: Rename in `lib/omarchy_prayer/geolocate.rb`**

Replace the file contents with:

```ruby
require 'net/http'
require 'uri'
require 'json'
require 'omarchy_prayer/tz_location'

module OmarchyPrayer
  module Geolocate
    class Error < StandardError; end

    DEFAULT_URL = 'http://ip-api.com/json/'.freeze

    NETWORK_ERRORS = [
      Error, SocketError,
      Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH,
      Timeout::Error
    ].freeze

    module_function

    def detect_ip(url: DEFAULT_URL, timeout: 5)
      uri = URI(url)
      resp = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "geolocation HTTP #{resp.code}" unless resp.code == '200'
      data = JSON.parse(resp.body)
      raise Error, "geolocation failed: #{data.inspect}" unless data['status'] == 'success'
      {
        latitude:  data.fetch('lat'),
        longitude: data.fetch('lon'),
        city:      data.fetch('city'),
        country:   data.fetch('countryCode')
      }
    end
  end
end
```

(The orchestrator `detect` is added in Task 7 — this commit is just the rename.)

- [ ] **Step 2: Update existing test to use `detect_ip`**

In `test/test_geolocate.rb`, replace both occurrences of `OmarchyPrayer::Geolocate.detect(` with `OmarchyPrayer::Geolocate.detect_ip(`.

- [ ] **Step 3: Run geolocate tests**

Run: `ruby -Ilib -Itest test/test_geolocate.rb`
Expected: PASS (2 tests).

- [ ] **Step 4: Run the full suite to find any remaining callers**

Run: `bundle exec rake test 2>&1 | tail -40`
Expected: All tests still pass. `auto_relocate`, `relocate`, `first_run` tests use injected stubs and don't actually call `Geolocate.detect` on the real module — they inject `stub_geo` / `STUB_GEO` modules with their own `.detect` method, so they're unaffected by the rename.

If anything fails, the failure will point at the offending file — fix it.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/geolocate.rb test/test_geolocate.rb
git commit -m "refactor(geolocate): rename detect → detect_ip (prep for tz cross-check)"
```

---

### Task 7: `Geolocate.detect` — TZ cross-check orchestrator

**Files:**
- Modify: `lib/omarchy_prayer/geolocate.rb`
- Test: `test/test_geolocate.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_geolocate.rb` (before final `end`):

```ruby
  IP_RIYADH  = { latitude: 24.7136, longitude: 46.6753, city: 'Riyadh', country: 'SA' }.freeze
  IP_LONDON  = { latitude: 51.5074, longitude: -0.1278, city: 'London', country: 'GB' }.freeze
  TZ_LONDON  = { latitude: 51.5083, longitude: -0.1253, city: 'London',
                 country: 'GB', countries: %w[GB GG IM JE], zone: 'Europe/London' }.freeze
  TZ_RIYADH  = { latitude: 24.6333, longitude: 46.7166, city: 'Riyadh',
                 country: 'SA', countries: %w[SA AQ KW YE], zone: 'Asia/Riyadh' }.freeze

  def test_detect_uses_ip_when_tz_country_agrees
    ip = ->(*) { IP_LONDON.dup }
    tz = -> { TZ_LONDON.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'London', loc[:city]
    assert_in_delta 51.5074, loc[:latitude], 1e-4  # IP coords, not TZ
  end

  def test_detect_falls_back_to_tz_when_country_disagrees
    ip = ->(*) { IP_RIYADH.dup }
    tz = -> { TZ_LONDON.dup }
    io = StringIO.new
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: io)
    assert_equal 'London', loc[:city]
    assert_equal 'GB', loc[:country]
    assert_in_delta 51.5083, loc[:latitude], 1e-4  # TZ coords
    assert_match(/IP.*Riyadh.*timezone is Europe\/London/, io.string)
  end

  def test_detect_uses_ip_when_tz_unavailable
    ip = ->(*) { IP_RIYADH.dup }
    tz = -> { nil }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'Riyadh', loc[:city]
  end

  def test_detect_falls_back_to_tz_when_ip_fails
    ip = ->(*) { raise OmarchyPrayer::Geolocate::Error, 'boom' }
    tz = -> { TZ_LONDON.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'London', loc[:city]
  end

  def test_detect_raises_when_both_fail
    ip = ->(*) { raise OmarchyPrayer::Geolocate::Error, 'boom' }
    tz = -> { nil }
    assert_raises(OmarchyPrayer::Geolocate::Error) do
      OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    end
  end

  def test_detect_ip_country_in_zone_country_set_uses_ip
    # Kuwait user (TZ=Asia/Riyadh), IP routed through SA. Both in {SA,AQ,KW,YE} → use IP.
    ip_sa = IP_RIYADH.dup
    tz = -> { TZ_RIYADH.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ->(*) { ip_sa }, tz_detect: tz, io: StringIO.new)
    assert_equal 'Riyadh', loc[:city]
    assert_equal 'SA', loc[:country]
  end
```

Also add `require 'stringio'` at the top of `test/test_geolocate.rb` if not already present.

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_geolocate.rb`
Expected: FAIL — `wrong number of arguments` or `unknown keyword: :ip_detect`.

- [ ] **Step 3: Implement the orchestrator**

Add to `lib/omarchy_prayer/geolocate.rb` inside the `module Geolocate` block (after `detect_ip`):

```ruby
    DEFAULT_IP_DETECT = ->(*args, **kw) { Geolocate.detect_ip(*args, **kw) }
    DEFAULT_TZ_DETECT = -> { TzLocation.detect }

    def detect(ip_detect: DEFAULT_IP_DETECT, tz_detect: DEFAULT_TZ_DETECT, io: $stderr)
      ip = safe_ip(ip_detect)
      tz = safe_tz(tz_detect)

      if ip && tz
        return ip if tz[:countries].include?(ip[:country].to_s.upcase)
        io.puts format('omarchy-prayer: IP→%s, %s but timezone is %s — using %s, %s',
                       ip[:city], ip[:country], tz[:zone], tz[:city], tz[:country])
        return tz_to_loc(tz)
      end

      return ip if ip
      return tz_to_loc(tz) if tz
      raise Error, 'no location signal available (IP failed, timezone unresolved)'
    end

    def safe_ip(callable)
      callable.call
    rescue *NETWORK_ERRORS
      nil
    end

    def safe_tz(callable)
      callable.call
    rescue StandardError
      nil
    end

    def tz_to_loc(tz)
      { latitude: tz[:latitude], longitude: tz[:longitude],
        city: tz[:city], country: tz[:country] }
    end
```

NOTE: the `→` and `—` are escape sequences for `→` and `—`. Use plain Ruby string syntax — replace with literal Unicode characters in the source:

```ruby
        io.puts format('omarchy-prayer: IP→%s, %s but timezone is %s — using %s, %s',
                       ip[:city], ip[:country], tz[:zone], tz[:city], tz[:country])
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_geolocate.rb`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Run full suite to confirm no regressions**

Run: `bundle exec rake test 2>&1 | tail -20`
Expected: All green. `auto_relocate`/`first_run`/`relocate` tests inject their own `geolocate` stubs that still respond to `.detect` — those continue to work because the stubs match the public interface.

- [ ] **Step 6: Commit**

```bash
git add lib/omarchy_prayer/geolocate.rb test/test_geolocate.rb
git commit -m "feat(geolocate): cross-check IP vs system timezone, prefer TZ on conflict"
```

---

### Task 8: `Migrations` module — marker + audio flip logic

**Files:**
- Create: `lib/omarchy_prayer/migrations.rb`
- Create: `test/test_migrations.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/test_migrations.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/migrations'
require 'omarchy_prayer/paths'

class TestMigrations < Minitest::Test
  include TestHelper

  CONFIG_AUDIO_ON = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"

    [notifications]
    enabled = true
    pre_notify_minutes = 10

    [audio]
    enabled = true
    player  = "mpv"
    volume  = 80
  TOML

  CONFIG_AUDIO_OFF = CONFIG_AUDIO_ON.sub(/(?<=\[audio\]\n)enabled = true/, 'enabled = false').freeze

  def seed_config(text)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, text)
  end

  def marker_path
    File.join(OmarchyPrayer::Paths.state_dir, '.migrated-mute-default-v1')
  end

  def test_flips_audio_enabled_when_marker_absent
    with_isolated_home do
      seed_config(CONFIG_AUDIO_ON)
      io = StringIO.new
      OmarchyPrayer::Migrations.run(io: io)
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/\[audio\]\nenabled = false/, cfg)
      assert_match(/\[notifications\]\nenabled = true/, cfg)  # NOT flipped
      assert File.exist?(marker_path)
      assert_match(/adhan audio is now muted/, io.string)
    end
  end

  def test_noop_when_marker_present
    with_isolated_home do
      seed_config(CONFIG_AUDIO_ON)
      FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
      FileUtils.touch(marker_path)
      io = StringIO.new
      OmarchyPrayer::Migrations.run(io: io)
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/\[audio\]\nenabled = true/, cfg)  # untouched
      assert_empty io.string
    end
  end

  def test_creates_marker_without_rewrite_when_audio_already_off
    with_isolated_home do
      seed_config(CONFIG_AUDIO_OFF)
      io = StringIO.new
      OmarchyPrayer::Migrations.run(io: io)
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/\[audio\]\nenabled = false/, cfg)
      assert File.exist?(marker_path)
      assert_empty io.string  # no message — nothing changed
    end
  end

  def test_creates_marker_when_config_missing
    with_isolated_home do
      io = StringIO.new
      OmarchyPrayer::Migrations.run(io: io)
      assert File.exist?(marker_path)
    end
  end

  def test_does_not_flip_notifications_enabled
    with_isolated_home do
      # Config where [notifications] comes AFTER [audio] — order shouldn't matter
      text = <<~TOML
        [location]
        latitude = 0.0
        longitude = 0.0
        city = "X"
        country = "XX"

        [audio]
        enabled = true

        [notifications]
        enabled = true
      TOML
      seed_config(text)
      OmarchyPrayer::Migrations.run(io: StringIO.new)
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/\[audio\]\nenabled = false/, cfg)
      assert_match(/\[notifications\]\nenabled = true/, cfg)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_migrations.rb`
Expected: FAIL — `cannot load such file -- omarchy_prayer/migrations`.

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/migrations.rb`:

```ruby
require 'fileutils'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  module Migrations
    MARKER_FILENAME = '.migrated-mute-default-v1'.freeze

    module_function

    def marker_path
      File.join(Paths.state_dir, MARKER_FILENAME)
    end

    def run(io: $stderr)
      return if File.exist?(marker_path)
      mute_audio_default(io)
      Paths.ensure_state_dir
      FileUtils.touch(marker_path)
    rescue StandardError => e
      io.puts "omarchy-prayer: migration warning (#{e.class}: #{e.message})"
    end

    def mute_audio_default(io)
      path = Paths.config_file
      return unless File.exist?(path)
      text = File.read(path)
      new_text = flip_audio_enabled_section(text)
      return if new_text == text
      File.write(path, new_text)
      io.puts 'omarchy-prayer: adhan audio is now muted by default. ' \
              'Re-enable by setting `enabled = true` under [audio] in ' \
              '~/.config/omarchy-prayer/config.toml.'
    end

    # Walk the TOML line by line, tracking the active section header.
    # Rewrite ONLY the `enabled = true` line that sits under [audio].
    def flip_audio_enabled_section(text)
      section = nil
      text.each_line.map do |line|
        if (m = line.match(/\A\s*\[([^\]]+)\]\s*\z/))
          section = m[1].strip
          line
        elsif section == 'audio' && line =~ /\A(\s*enabled\s*=\s*)true\s*\z/
          "#{Regexp.last_match(1)}false\n"
        else
          line
        end
      end.join
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_migrations.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/migrations.rb test/test_migrations.rb
git commit -m "feat(migrations): one-shot mute-default-v1 flips audio.enabled under [audio]"
```

---

### Task 9: Wire `Migrations.run` into entry points

**Files:**
- Modify: `bin/omarchy-prayer`
- Modify: `bin/omarchy-prayer-schedule`
- Test: `test/test_migrations.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/test_migrations.rb`:

```ruby
  def test_omarchy_prayer_bin_requires_and_calls_migrations
    src = File.read(File.expand_path('../bin/omarchy-prayer', __dir__))
    assert_match(%r{require 'omarchy_prayer/migrations'}, src)
    assert_match(/Migrations\.run/, src)
  end

  def test_omarchy_prayer_schedule_bin_requires_and_calls_migrations
    src = File.read(File.expand_path('../bin/omarchy-prayer-schedule', __dir__))
    assert_match(%r{require 'omarchy_prayer/migrations'}, src)
    assert_match(/Migrations\.run/, src)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_migrations.rb`
Expected: 5 PASS + 2 FAIL (the new ones).

- [ ] **Step 3: Modify `bin/omarchy-prayer`**

Add `require 'omarchy_prayer/migrations'` after the existing `require 'omarchy_prayer/first_run'` line near the top. Then in `cmd_tui` and `cmd_setup`, after `FirstRun.ensure_config!`, add `OmarchyPrayer::Migrations.run`.

Specifically:

In `cmd_tui` (currently at `bin/omarchy-prayer:78-84`), change:

```ruby
def cmd_tui
  require 'omarchy_prayer/tui'
  OmarchyPrayer::FirstRun.ensure_config!
  OmarchyPrayer::Setup.run(io: $stderr)
  OmarchyPrayer::TUI.new.run
end
```

to:

```ruby
def cmd_tui
  require 'omarchy_prayer/tui'
  OmarchyPrayer::FirstRun.ensure_config!
  OmarchyPrayer::Migrations.run
  OmarchyPrayer::Setup.run(io: $stderr)
  OmarchyPrayer::TUI.new.run
end
```

In `cmd_setup` (currently at `bin/omarchy-prayer:86-94`), change:

```ruby
def cmd_setup
  OmarchyPrayer::FirstRun.ensure_config!
  changes = OmarchyPrayer::Setup.run
```

to:

```ruby
def cmd_setup
  OmarchyPrayer::FirstRun.ensure_config!
  OmarchyPrayer::Migrations.run
  changes = OmarchyPrayer::Setup.run
```

Add the require near the top of the file:

Find:
```ruby
require 'omarchy_prayer/first_run'
```

Add immediately after:
```ruby
require 'omarchy_prayer/migrations'
```

- [ ] **Step 4: Modify `bin/omarchy-prayer-schedule`**

Add `require 'omarchy_prayer/migrations'` after `require 'omarchy_prayer/first_run'`.

Change:
```ruby
OmarchyPrayer::FirstRun.ensure_config!
cfg = OmarchyPrayer::Config.load
```

to:
```ruby
OmarchyPrayer::FirstRun.ensure_config!
OmarchyPrayer::Migrations.run
cfg = OmarchyPrayer::Config.load
```

- [ ] **Step 5: Run tests**

Run: `ruby -Ilib -Itest test/test_migrations.rb`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add bin/omarchy-prayer bin/omarchy-prayer-schedule test/test_migrations.rb
git commit -m "feat(migrations): wire mute-default migration into omarchy-prayer entry points"
```

---

### Task 10: `Config::DEFAULTS` — `audio.enabled = false`

**Files:**
- Modify: `lib/omarchy_prayer/config.rb`
- Modify: `test/test_config.rb`

- [ ] **Step 1: Update the existing assertion + add a new one**

In `test/test_config.rb`, inside `test_defaults_applied_when_sections_missing`, change:

```ruby
      assert_equal true,    cfg.audio_enabled
```

to:

```ruby
      assert_equal false,   cfg.audio_enabled
```

Then append a new test before the final `end` of the class:

```ruby
  def test_audio_enabled_default_is_false
    write_config(MINIMAL) do |cfg, _|
      assert_equal false, cfg.audio_enabled
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: FAIL — `Expected: false, Actual: true`.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/config.rb`, change:

```ruby
      'audio'         => { 'enabled' => true, 'player' => 'mpv',
```

to:

```ruby
      'audio'         => { 'enabled' => false, 'player' => 'mpv',
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_config.rb`
Expected: PASS.

Then run: `bundle exec rake test 2>&1 | tail -30` — check for other tests that assume `audio.enabled = true` as a default. Likely candidates:
- `test_notifier.rb` — if a test exercises the audio path with default config, it will now skip audio. Either explicitly pass `audio_enabled: true` in those tests, or seed configs with `[audio]\nenabled = true`.
- `test_bootstrap.rb` — if it asserts the bootstrapped config contains `enabled = true` for audio, flip it.

Fix each by adding the explicit override at the point where audio is exercised.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/config.rb test/test_config.rb
git commit -m "feat(config): default audio.enabled to false (notifications still fire)"
```

---

### Task 11: `FirstRun::TEMPLATE` — `audio.enabled = false`

**Files:**
- Modify: `lib/omarchy_prayer/first_run.rb`

- [ ] **Step 1: Update the template**

In `lib/omarchy_prayer/first_run.rb`, change the `[audio]` block in `TEMPLATE` from:

```toml
      [audio]
      enabled    = true
      player     = "mpv"
```

to:

```toml
      [audio]
      # set to true to play the adhan audio at each prayer
      enabled    = false
      player     = "mpv"
```

- [ ] **Step 2: Run the bootstrap test**

Run: `ruby -Ilib -Itest test/test_bootstrap.rb`
Expected: PASS. If a test asserts `audio.enabled = true` in the bootstrapped config, flip the assertion.

- [ ] **Step 3: Commit**

```bash
git add lib/omarchy_prayer/first_run.rb
git commit -m "feat(first-run): write audio.enabled = false in new configs"
```

---

### Task 12: `Waybar.render` — `{city}` placeholder

**Files:**
- Modify: `lib/omarchy_prayer/waybar.rb`
- Modify: `test/test_waybar.rb`

- [ ] **Step 1: Write the failing tests**

Replace `test/test_waybar.rb` test bodies to pass `city:` and add a substitution test. Specifically:

Update existing tests to add `city: 'Riyadh',` to every `Waybar.render(...)` call. Then append a new test:

```ruby
  def test_city_placeholder_substitution
    now = Time.new(2026,4,22, 13,4,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'London',
      format: '{city} · {prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'London · Asr 2h 14m', data['text']
  end

  def test_city_omitted_when_not_in_format
    now = Time.new(2026,4,22, 13,4,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'London',
      format: '{prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'Asr 2h 14m', data['text']
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_waybar.rb`
Expected: FAIL — `missing keyword: :city` or `{city}` not substituted.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/waybar.rb`, change the signature and substitution:

```ruby
    def render(today, now: Time.now, format:, soon_minutes:, city:)
      name, at = today.next_prayer(now: now)
      pretty = PRETTY.fetch(name)
      time_s = at.strftime('%H:%M')
      secs = (at - now).to_i
      countdown = format_countdown(secs)
      text = format
        .gsub('{city}',      city.to_s)
        .gsub('{prayer}',    pretty)
        .gsub('{time}',      time_s)
        .gsub('{countdown}', countdown)
      cls  = secs / 60 < soon_minutes ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(today))
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_waybar.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/waybar.rb test/test_waybar.rb
git commit -m "feat(waybar): add {city} placeholder to render format"
```

---

### Task 13: `bin/omarchy-prayer-waybar` — pass `city:`

**Files:**
- Modify: `bin/omarchy-prayer-waybar`

- [ ] **Step 1: Update the call**

In `bin/omarchy-prayer-waybar`, change:

```ruby
  puts OmarchyPrayer::Waybar.render(t, format: cfg.waybar_format,
                                     soon_minutes: cfg.soon_threshold_minutes)
```

to:

```ruby
  puts OmarchyPrayer::Waybar.render(t, format: cfg.waybar_format,
                                     soon_minutes: cfg.soon_threshold_minutes,
                                     city: cfg.city)
```

- [ ] **Step 2: Smoke-test by running the script**

Run: `ruby -Ilib bin/omarchy-prayer-waybar 2>&1 | head -1`
Expected: Either a JSON line, or an error JSON if config is missing — but no Ruby crash about missing kwargs.

- [ ] **Step 3: Run full suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: All green.

- [ ] **Step 4: Commit**

```bash
git add bin/omarchy-prayer-waybar
git commit -m "feat(waybar): pass cfg.city to render"
```

---

### Task 14: `Config::DEFAULTS` + `FirstRun::TEMPLATE` — default format includes `{city}`

**Files:**
- Modify: `lib/omarchy_prayer/config.rb`
- Modify: `lib/omarchy_prayer/first_run.rb`

- [ ] **Step 1: Update DEFAULTS**

In `lib/omarchy_prayer/config.rb`, change:

```ruby
      'waybar'        => { 'format' => '{prayer} {countdown}', 'soon_threshold_minutes' => 10 }
```

to:

```ruby
      'waybar'        => { 'format' => '{city} · {prayer} {countdown}', 'soon_threshold_minutes' => 10 }
```

- [ ] **Step 2: Update TEMPLATE**

In `lib/omarchy_prayer/first_run.rb`, change:

```toml
      [waybar]
      format                 = "{prayer} {countdown}"
```

to:

```toml
      [waybar]
      format                 = "{city} · {prayer} {countdown}"
```

- [ ] **Step 3: Update existing test assertion**

In `test/test_config.rb`, inside `test_defaults_applied_when_sections_missing`, change:

```ruby
      assert_equal '{prayer} {countdown}', cfg.waybar_format
```

to:

```ruby
      assert_equal '{city} · {prayer} {countdown}', cfg.waybar_format
```

- [ ] **Step 4: Run full suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: All green. If `test_bootstrap.rb` asserts the old default format literally, update that assertion too.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/config.rb lib/omarchy_prayer/first_run.rb test/test_config.rb
git commit -m "feat(waybar): default format shows {city} · {prayer} {countdown}"
```

---

### Task 15: TUI `[l] relocate` hotkey

**Files:**
- Modify: `lib/omarchy_prayer/tui.rb`
- Modify: `test/test_tui.rb`

- [ ] **Step 1: Inspect existing test_tui.rb to understand its style**

Run: `cat test/test_tui.rb | head -40`

(Required so the test you write matches existing structure — TUI tests likely render to a StringIO and assert on the output, since the TUI itself wraps `IO.console.raw`.)

- [ ] **Step 2: Write the failing test**

Append to `test/test_tui.rb` (before the final `end`):

```ruby
  def test_relocate_here_runs_relocate_and_reloads_cfg
    with_isolated_home do
      # Seed config so TUI can load it
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "Riyadh"
        country   = "SA"

        [method]
        name = "auto"
      TOML
      FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
      File.write(OmarchyPrayer::Paths.today_json, JSON.generate(
        date: Date.today.strftime('%Y-%m-%d'), tz_offset: 0, city: 'Riyadh',
        country: 'SA', method: 'Makkah', source: 'api',
        times: { fajr: '04:00', sunrise: '05:00', dhuhr: '12:00',
                 asr: '15:00', maghrib: '18:00', isha: '19:00' }
      ))

      # Stub Relocate.run to rewrite the config to London + write a confirmation.
      called = []
      original_run = OmarchyPrayer::Relocate.method(:run)
      OmarchyPrayer::Relocate.define_singleton_method(:run) do |argv, **kwargs|
        called << argv
        File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
          [location]
          latitude  = 51.5074
          longitude = -0.1278
          city      = "London"
          country   = "GB"

          [method]
          name = "auto"
        TOML
        kwargs[:io]&.puts 'omarchy-prayer: location set to London, GB'
      end

      tui = OmarchyPrayer::TUI.new(out: StringIO.new)
      tui.instance_variable_set(:@cfg, OmarchyPrayer::Config.load)
      tui.instance_variable_set(:@today, OmarchyPrayer::Today.read)
      tui.instance_variable_set(:@width, 80)
      tui.instance_variable_set(:@theme, OmarchyPrayer::Theme.load)
      tui.define_singleton_method(:refresh_schedule) {}  # avoid systemctl shell-out

      tui.send(:relocate_here)
      assert_equal [[]], called
      assert_equal 'London', tui.instance_variable_get(:@cfg).city
    ensure
      OmarchyPrayer::Relocate.define_singleton_method(:run, original_run) if original_run
    end
  end
```

NOTE: the `ensure` block restores `Relocate.run` to its original implementation — same discipline as the SUNNI catalog memory ([[feedback-test-isolation]]).

Also ensure `require 'omarchy_prayer/relocate'` and `require 'omarchy_prayer/config'` and `require 'omarchy_prayer/today'` are present at the top of the file.

- [ ] **Step 3: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tui.rb`
Expected: FAIL — `NoMethodError: undefined method 'relocate_here'`.

- [ ] **Step 4: Implement**

In `lib/omarchy_prayer/tui.rb`:

Add `require 'omarchy_prayer/relocate'` and `require 'stringio'` near the top.

In the `run` method's key dispatch, add a case for `'l'`:

```ruby
          case key
          when 'q', "\x03" then break
          when 'r' then refresh_schedule
          when 'l' then relocate_here
          when 'm' then toggle_mute
          when 't' then test_audio
          end
```

In the `render_hotkeys` method, update the row:

```ruby
    def render_hotkeys
      hk = ->(k, l) { fg(:accent) + "[#{k}]" + fg(:muted) + " #{l}" + rst }
      line = [hk.call('q', 'quit'), hk.call('r', 'refresh'), hk.call('l', 'relocate'),
              hk.call('m', 'mute today'), hk.call('t', 'test adhan')].join('     ')
      center line
    end
```

Add a private `relocate_here` and `show_toast` near the other `# ---- Actions ----` section:

```ruby
    def relocate_here
      show_toast('locating…', color: :muted)
      captured = StringIO.new
      Relocate.run([], io: captured)
      refresh_schedule
      @cfg = Config.load
      show_toast("→ #{@cfg.city}, #{@cfg.country}", color: :primary, dwell: 1.0)
    rescue Geolocate::Error, SocketError,
           Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH,
           Timeout::Error, SystemExit => e
      show_toast("relocate failed: #{e.message}", color: :warning, dwell: 1.5)
    end

    def show_toast(msg, color:, dwell: 0)
      # Re-render hotkey row replaced with the toast text.
      @out.print "\e[#{terminal_height};1H\e[2K"  # move to last row, clear
      pad = [(@width - visible_len(msg)) / 2, 0].max
      @out.print ' ' * pad + fg(color) + msg + rst
      sleep dwell if dwell.positive?
    end

    def terminal_height
      IO.console&.winsize&.first || 24
    end
```

Also add `require 'omarchy_prayer/geolocate'` near the top of `tui.rb` (for the rescue clause). Same for the other Errno classes already in scope from Ruby core.

- [ ] **Step 5: Run tests**

Run: `ruby -Ilib -Itest test/test_tui.rb`
Expected: PASS.

- [ ] **Step 6: Run full suite**

Run: `bundle exec rake test 2>&1 | tail -10`
Expected: All green.

- [ ] **Step 7: Commit**

```bash
git add lib/omarchy_prayer/tui.rb test/test_tui.rb
git commit -m "feat(tui): [l] hotkey re-detects location via TZ-aware Geolocate"
```

---

### Task 16: TUI `[t]` audio-disabled toast

**Files:**
- Modify: `lib/omarchy_prayer/tui.rb`
- Test: `test/test_tui.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/test_tui.rb` (before final `end`):

```ruby
  def test_test_audio_shows_disabled_toast_when_audio_off
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "Riyadh"
        country   = "SA"

        [audio]
        enabled = false
      TOML
      cfg = OmarchyPrayer::Config.load
      out = StringIO.new
      tui = OmarchyPrayer::TUI.new(out: out)
      tui.instance_variable_set(:@cfg, cfg)
      tui.instance_variable_set(:@width, 80)
      tui.instance_variable_set(:@theme, OmarchyPrayer::Theme.load)
      toasted = []
      tui.define_singleton_method(:show_toast) { |msg, **_| toasted << msg }

      tui.send(:test_audio)
      assert toasted.any? { |m| m =~ /audio disabled/ }
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/test_tui.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/tui.rb`, change `test_audio`:

```ruby
    def test_audio
      unless @cfg.audio_enabled
        show_toast('audio disabled — set audio.enabled = true to enable',
                   color: :warning, dwell: 1.5)
        return
      end
      file = @cfg.adhan_path
      return unless File.exist?(file)
      pid = Process.spawn(@cfg.audio_player, '--no-video', '--really-quiet',
                          "--volume=#{@cfg.volume}", file,
                          %i[out err] => '/dev/null')
      sleep 3
      begin; Process.kill('TERM', pid); rescue Errno::ESRCH; end
    end
```

- [ ] **Step 4: Run tests**

Run: `ruby -Ilib -Itest test/test_tui.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tui.rb test/test_tui.rb
git commit -m "feat(tui): show 'audio disabled' toast on [t] when audio.enabled = false"
```

---

### Task 17: README updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the README**

Find the "Waybar widget" section. After the existing JSON snippet, add documentation for the placeholders:

```markdown
The widget supports four placeholders in `waybar.format`:

| Placeholder    | Renders as                  |
|----------------|----------------------------|
| `{city}`       | current city (e.g. `London`) |
| `{prayer}`     | next prayer name (e.g. `Maghrib`) |
| `{time}`       | next prayer time (e.g. `18:01`) |
| `{countdown}`  | remaining time (e.g. `1h 12m`) |

Default format is `{city} · {prayer} {countdown}`. Omit `{city}` from the format to hide it.
```

Find the "Commands" table. Add a row for `[l] relocate` if a TUI hotkeys table exists; otherwise, leave the TUI hotkey discovery to the on-screen footer.

Find the section on audio (or add one near "Adhan audio"). Add:

```markdown
### Adhan audio (default: muted)

The adhan audio is **muted by default** — you'll see the mako prayer notification but won't hear the call. To enable, edit `~/.config/omarchy-prayer/config.toml`:

```toml
[audio]
enabled = true
```

Existing users upgrading from earlier versions are migrated to muted on first run; a stderr line announces the change with re-enable instructions.
```

Find the "Updating location" section. Append a note:

```markdown
Location detection cross-checks IP geolocation against your system timezone (`/etc/localtime`). If you're roaming through a foreign carrier or behind a VPN that places your IP in a different country, the system timezone takes precedence — so `omarchy-prayer` won't auto-relocate you to the carrier's country. To override manually:

```bash
omarchy-prayer relocate --lat 51.5074 --lon -0.1278 --city London --country GB
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): document {city} placeholder, muted-by-default, tz cross-check"
```

---

### Task 18: Final integration check

**Files:**
- (no edits — verification only)

- [ ] **Step 1: Run the full test suite**

Run: `bundle exec rake test 2>&1 | tail -30`
Expected: All tests green. Number of tests > baseline (we added ~25 new tests across `test_tz_location.rb`, `test_geolocate.rb`, `test_migrations.rb`, `test_waybar.rb`, `test_tui.rb`).

- [ ] **Step 2: Manual smoke — TZ cross-check on this host**

The user is currently on a Saudi-IP-routed connection but lives in London (per the conversation context). After install, on a real Linux box with `Europe/London` timezone:

```bash
ruby -Ilib -e 'require "omarchy_prayer/geolocate"; pp OmarchyPrayer::Geolocate.detect'
```

Expected: prints a London-based location, with a stderr line `omarchy-prayer: IP→Riyadh, SA but timezone is Europe/London — using London, GB` (assuming IP genuinely geolocates to SA).

If the user's machine has TZ already matching IP, this manual step just confirms no crash and a normal IP-based result.

- [ ] **Step 3: Manual smoke — migration**

```bash
# In a temp HOME
HOME=/tmp/op-mig-test ruby -Ilib bin/omarchy-prayer setup 2>&1 | grep -i 'muted\|adhan' || echo 'no migration needed (fresh install)'
ls /tmp/op-mig-test/.local/state/omarchy-prayer/.migrated-mute-default-v1
```

Expected: marker file exists. On a system with a pre-existing `audio.enabled = true` config, the stderr line "adhan audio is now muted by default" appears.

- [ ] **Step 4: Manual smoke — TUI relocate**

Open the TUI: `omarchy-prayer`. Press `l`. Expect: bottom row shows `locating…`, then `→ <City>, <CC>` for ~1 s, then normal hotkey row returns.

- [ ] **Step 5: Manual smoke — waybar `{city}`**

```bash
ruby -Ilib bin/omarchy-prayer-waybar | jq -r .text
```

Expected: starts with the city name, e.g. `London · Maghrib 1h 12m`.

- [ ] **Step 6: Final commit (only if any fixes were needed in steps 1–5)**

If any of the smoke tests revealed an issue, fix it with a small focused commit. If everything passed, no commit needed.

---

## Self-Review Checklist

- ✅ **Spec coverage:** TZ-aware detection (Tasks 2–7), default-mute + migration (Tasks 8–11), TUI `[l]` (Task 15), TUI `[t]` audio-disabled toast (Task 16), waybar `{city}` (Tasks 12–14), README (Task 17), integration smoke (Task 18). All spec sections mapped.
- ✅ **Placeholder scan:** No TBDs. All code blocks contain complete code.
- ✅ **Type consistency:** `TzLocation.detect` returns `{ latitude:, longitude:, city:, country:, countries:, zone: }` — same shape used in Task 7's `Geolocate.detect` orchestrator (`tz[:countries]`, `tz[:zone]`, `tz[:city]`, `tz[:country]`) and in the test fixture data (`TZ_LONDON`, `TZ_RIYADH`). `Geolocate.detect_ip` keeps the existing `{ latitude:, longitude:, city:, country: }` shape used by callers.
- ✅ **Marker filename consistency:** `.migrated-mute-default-v1` used in `Migrations::MARKER_FILENAME` (lib) and in `marker_path` helper (test). Matches the spec.
- ✅ **TDD discipline:** Every implementation task starts with a failing test, then minimal implementation, then green.
- ✅ **Test isolation discipline:** Task 15 explicitly restores `Relocate.run` in `ensure`, per [[feedback-test-isolation]]. No module-level state mutation without restoration.
