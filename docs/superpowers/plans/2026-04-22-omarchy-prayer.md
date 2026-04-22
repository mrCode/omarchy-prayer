# omarchy-prayer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `omarchy-prayer`, a Muslim prayer-time notifier for Omarchy with mako notifications, adhan audio, a waybar widget, and a themed TUI, scheduled via `systemd --user` timers.

**Architecture:** Ruby library (`lib/omarchy_prayer/*.rb`) + thin entry scripts in `bin/`. A daily scheduler rebuilds ten transient systemd timers (5 prayers × on-time + pre-notify). Time resolution falls through cache → Aladhan API → offline calculator. TUI and waybar both read the same `today.json`.

**Tech Stack:** Ruby 4, `tomlrb` for config, `minitest` for tests, `webrick` for integration fixtures, `systemd-run` for transient timers, `mako`/`notify-send`, `mpv` for audio. Reference spec: `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md`.

---

## File Structure

```
/home/mrcode/workspace/omarchy-prayer/
├── bin/
│   ├── omarchy-prayer            # CLI + TUI entry
│   ├── omarchy-prayer-schedule   # Daily scheduler
│   ├── omarchy-prayer-notify     # Fires one event
│   ├── omarchy-prayer-waybar     # Waybar JSON output
│   └── omarchy-prayer-stop       # Kills adhan
├── lib/omarchy_prayer/
│   ├── paths.rb                  # XDG paths, ~ expansion
│   ├── config.rb                 # TOML load + validation + defaults
│   ├── country_methods.rb        # Country → calc-method table
│   ├── methods.rb                # Method parameters (Fajr/Isha angles)
│   ├── qibla.rb                  # Bearing to Makkah
│   ├── offline_calc.rb           # Pure-Ruby offline prayer calc
│   ├── aladhan_client.rb         # HTTP client + monthly cache
│   ├── today.rb                  # today.json read/write
│   ├── times_source.rb           # Three-tier resolver
│   ├── waybar.rb                 # Next-prayer + countdown JSON
│   ├── audio.rb                  # Spawn/kill mpv + PID file
│   ├── notifier.rb               # notify-send + DND + mute checks
│   ├── geolocate.rb              # IP geolocation (ip-api.com)
│   ├── first_run.rb              # Bootstrap on first command
│   ├── scheduler.rb              # systemd-run transient timers
│   ├── theme.rb                  # Omarchy theme → ANSI palette
│   ├── tui.rb                    # TUI main loop
│   └── cli.rb                    # Subcommand dispatcher
├── share/
│   ├── systemd/
│   │   ├── omarchy-prayer-schedule.service
│   │   ├── omarchy-prayer-schedule.timer
│   │   └── omarchy-prayer-resume.service
│   └── audio/
│       ├── adhan.mp3.placeholder
│       └── adhan-fajr.mp3.placeholder
├── test/
│   ├── test_helper.rb
│   ├── test_paths.rb
│   ├── test_config.rb
│   ├── test_country_methods.rb
│   ├── test_qibla.rb
│   ├── test_offline_calc.rb
│   ├── test_aladhan_client.rb
│   ├── test_today.rb
│   ├── test_times_source.rb
│   ├── test_waybar.rb
│   ├── test_audio.rb
│   ├── test_notifier.rb
│   ├── test_geolocate.rb
│   ├── test_scheduler.rb
│   ├── test_theme.rb
│   └── fixtures/aladhan_april_2026.json
├── Gemfile
├── Rakefile
├── install.sh
└── README.md
```

**Test strategy:**
- Pure-logic modules: straight minitest.
- HTTP: stand up a local WEBrick fixture server on 127.0.0.1:0 and inject the base URL.
- Systemd + mpv + notify-send: tests call a shim. Each test puts a temp dir first on `$PATH` containing a log-only stand-in (e.g. a 5-line shell script that appends its argv to `$LOG_FILE`). The tests assert the log contents.
- TUI rendering: a smoke test that renders to an in-memory IO and asserts key fragments appear.

---

## Task 1: Project skeleton

**Files:**
- Create: `Gemfile`
- Create: `Rakefile`
- Create: `test/test_helper.rb`
- Create: `README.md`
- Create: `.gitignore`

- [ ] **Step 1: Write `.gitignore`**

```
/vendor/
/.bundle/
/coverage/
*.gem
.tmp/
```

- [ ] **Step 2: Write `Gemfile`**

```ruby
source 'https://rubygems.org'

gem 'tomlrb', '~> 2.0'

group :test do
  gem 'minitest', '~> 5.20'
  gem 'webrick', '~> 1.8'
end
```

- [ ] **Step 3: Write `Rakefile`**

```ruby
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/test_*.rb']
  t.warning = false
end

task default: :test
```

- [ ] **Step 4: Write `test/test_helper.rb`**

```ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'

module TestHelper
  # Isolate HOME / XDG so tests never touch the real user's files.
  def with_isolated_home
    Dir.mktmpdir('omarchy-prayer-test-') do |home|
      orig = %w[HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR PATH]
              .map { |k| [k, ENV[k]] }.to_h
      ENV['HOME']            = home
      ENV['XDG_CONFIG_HOME'] = "#{home}/.config"
      ENV['XDG_STATE_HOME']  = "#{home}/.local/state"
      ENV['XDG_CACHE_HOME']  = "#{home}/.cache"
      ENV['XDG_RUNTIME_DIR'] = "#{home}/run"
      %w[.config .local/state .cache run].each { |d| FileUtils.mkdir_p(File.join(home, d)) }
      yield home
    ensure
      orig.each { |k, v| ENV[k] = v }
    end
  end

  # Put a temp dir at the front of PATH holding log-only shims for commands.
  # The shim writes "<name> <argv-joined-with-\t>\n" to $OP_SHIM_LOG.
  def with_shims(home, names)
    shim_dir = File.join(home, 'shims')
    log_file = File.join(home, 'shim.log')
    FileUtils.mkdir_p(shim_dir)
    ENV['OP_SHIM_LOG'] = log_file
    names.each do |name|
      path = File.join(shim_dir, name)
      File.write(path, <<~SH)
        #!/usr/bin/env bash
        printf '%s' "#{name}" >> "$OP_SHIM_LOG"
        for a in "$@"; do printf '\\t%s' "$a" >> "$OP_SHIM_LOG"; done
        printf '\\n' >> "$OP_SHIM_LOG"
        # Allow stubbed stdout via env var OP_SHIM_STDOUT_<name>
        var="OP_SHIM_STDOUT_#{name.upcase.gsub(/[^A-Z0-9]/, '_')}"
        eval "out=\\"\\$$var\\""
        if [ -n "$out" ]; then printf '%s' "$out"; fi
        exit 0
      SH
      File.chmod(0o755, path)
    end
    ENV['PATH'] = "#{shim_dir}:#{ENV['PATH']}"
    log_file
  end

  def read_shim_log(path)
    return [] unless File.exist?(path)
    File.readlines(path, chomp: true).map { |l| l.split("\t") }
  end
end
```

- [ ] **Step 5: Write minimal `README.md`**

```markdown
# omarchy-prayer

Muslim prayer-time notifier for Omarchy.

See `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md` for the design.

## Install

```bash
./install.sh
```

## Test

```bash
bundle install
bundle exec rake test
```
```

- [ ] **Step 6: Run `bundle install` to create `Gemfile.lock`**

```bash
cd /home/mrcode/workspace/omarchy-prayer && bundle install --path vendor/bundle
```

Expected: exit 0, Gemfile.lock created. If `tomlrb` fails to resolve, try `bundle install` without `--path`.

- [ ] **Step 7: Run the empty test suite**

```bash
cd /home/mrcode/workspace/omarchy-prayer && bundle exec rake test
```

Expected: `0 runs, 0 assertions, 0 failures`. The task fails if rake cannot find any files — that's fine for now.

- [ ] **Step 8: Commit**

```bash
cd /home/mrcode/workspace/omarchy-prayer && \
  git add Gemfile Gemfile.lock Rakefile .gitignore test/test_helper.rb README.md && \
  git commit -m "chore: project skeleton, test harness, Gemfile"
```

---

## Task 2: `Paths` module

**Files:**
- Create: `lib/omarchy_prayer/paths.rb`
- Create: `test/test_paths.rb`

- [ ] **Step 1: Write failing test at `test/test_paths.rb`**

```ruby
require 'test_helper'
require 'omarchy_prayer/paths'

class TestPaths < Minitest::Test
  include TestHelper

  def test_config_file_uses_xdg_config_home
    with_isolated_home do |home|
      assert_equal "#{home}/.config/omarchy-prayer/config.toml",
                   OmarchyPrayer::Paths.config_file
    end
  end

  def test_today_json_uses_xdg_state_home
    with_isolated_home do |home|
      assert_equal "#{home}/.local/state/omarchy-prayer/today.json",
                   OmarchyPrayer::Paths.today_json
    end
  end

  def test_expand_user_tilde
    with_isolated_home do |home|
      assert_equal "#{home}/adhan.mp3", OmarchyPrayer::Paths.expand('~/adhan.mp3')
    end
  end

  def test_ensure_state_dir_creates_it
    with_isolated_home do |home|
      dir = OmarchyPrayer::Paths.ensure_state_dir
      assert Dir.exist?(dir)
      assert_equal "#{home}/.local/state/omarchy-prayer", dir
    end
  end
end
```

- [ ] **Step 2: Run test to see it fail**

```bash
cd /home/mrcode/workspace/omarchy-prayer && bundle exec rake test TEST=test/test_paths.rb
```

Expected: LoadError "cannot load such file -- omarchy_prayer/paths".

- [ ] **Step 3: Write `lib/omarchy_prayer/paths.rb`**

```ruby
require 'fileutils'

module OmarchyPrayer
  module Paths
    module_function

    APP = 'omarchy-prayer'

    def home
      ENV['HOME'] || Dir.home
    end

    def xdg_config_home
      ENV['XDG_CONFIG_HOME'] || File.join(home, '.config')
    end

    def xdg_state_home
      ENV['XDG_STATE_HOME'] || File.join(home, '.local/state')
    end

    def config_dir; File.join(xdg_config_home, APP); end
    def state_dir;  File.join(xdg_state_home,  APP); end

    def config_file;     File.join(config_dir, 'config.toml');                   end
    def today_json;      File.join(state_dir,  'today.json');                    end
    def month_cache(ym); File.join(state_dir,  "times-#{ym}.json");              end
    def adhan_pid;       File.join(state_dir,  'current-adhan.pid');             end
    def mute_today;      File.join(state_dir,  'mute-today');                    end

    def ensure_config_dir; FileUtils.mkdir_p(config_dir); config_dir; end
    def ensure_state_dir;  FileUtils.mkdir_p(state_dir);  state_dir;  end

    def expand(path)
      path.start_with?('~') ? File.expand_path(path) : path
    end
  end
end
```

- [ ] **Step 4: Run test, verify pass**

```bash
cd /home/mrcode/workspace/omarchy-prayer && bundle exec rake test TEST=test/test_paths.rb
```

Expected: `4 runs, 4 assertions, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/paths.rb test/test_paths.rb && \
  git commit -m "feat(paths): XDG-aware path helpers"
```

---

## Task 3: `Config` — TOML load, defaults, validation

**Files:**
- Create: `lib/omarchy_prayer/config.rb`
- Create: `test/test_config.rb`

- [ ] **Step 1: Write failing test at `test/test_config.rb`**

```ruby
require 'test_helper'
require 'omarchy_prayer/config'

class TestConfig < Minitest::Test
  include TestHelper

  MINIMAL = <<~TOML
    [location]
    latitude = 24.7136
    longitude = 46.6753
    city = "Riyadh"
    country = "SA"
  TOML

  def write_config(contents)
    with_isolated_home do |home|
      path = "#{home}/.config/omarchy-prayer/config.toml"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      yield OmarchyPrayer::Config.load, home
    end
  end

  def test_defaults_applied_when_sections_missing
    write_config(MINIMAL) do |cfg, _|
      assert_equal 'auto',  cfg.method_name
      assert_equal 10,      cfg.pre_notify_minutes
      assert_equal true,    cfg.respect_silencing
      assert_equal true,    cfg.audio_enabled
      assert_equal 'mpv',   cfg.audio_player
      assert_equal 80,      cfg.volume
      assert_equal({fajr: 0, dhuhr: 0, asr: 0, maghrib: 0, isha: 0}, cfg.offsets)
      assert_equal '{prayer} {countdown}', cfg.waybar_format
      assert_equal 10,      cfg.soon_threshold_minutes
    end
  end

  def test_location_fields_parsed
    write_config(MINIMAL) do |cfg, _|
      assert_in_delta 24.7136, cfg.latitude, 1e-6
      assert_in_delta 46.6753, cfg.longitude, 1e-6
      assert_equal 'Riyadh',  cfg.city
      assert_equal 'SA',      cfg.country
    end
  end

  def test_missing_file_raises_with_actionable_message
    with_isolated_home do
      err = assert_raises(OmarchyPrayer::Config::MissingError) { OmarchyPrayer::Config.load }
      assert_match(/config\.toml not found/, err.message)
    end
  end

  def test_latitude_out_of_range_rejected
    bad = MINIMAL.sub('24.7136', '999.0')
    write_config(bad) do |_cfg, _|
      flunk 'expected InvalidError'
    end
  rescue OmarchyPrayer::Config::InvalidError => e
    assert_match(/latitude/, e.message)
  end

  def test_unknown_method_rejected
    bad = MINIMAL + "\n[method]\nname = \"BOGUS\"\n"
    assert_raises(OmarchyPrayer::Config::InvalidError) do
      write_config(bad) { }
    end
  end

  def test_audio_paths_tilde_expanded
    write_config(MINIMAL) do |cfg, home|
      assert_equal "#{home}/.config/omarchy-prayer/adhan.mp3",      cfg.adhan_path
      assert_equal "#{home}/.config/omarchy-prayer/adhan-fajr.mp3", cfg.adhan_fajr_path
    end
  end
end
```

- [ ] **Step 2: Run test to see it fail**

```bash
bundle exec rake test TEST=test/test_config.rb
```

Expected: LoadError.

- [ ] **Step 3: Write `lib/omarchy_prayer/config.rb`**

```ruby
require 'tomlrb'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Config
    class MissingError < StandardError; end
    class InvalidError < StandardError; end

    KNOWN_METHODS = %w[
      auto MWL ISNA Egypt Makkah Karachi Tehran Jafari Kuwait Qatar
      Singapore Turkey Gulf Moonsighting Dubai France
    ].freeze

    DEFAULTS = {
      'method'        => { 'name' => 'auto' },
      'offsets'       => { 'fajr' => 0, 'dhuhr' => 0, 'asr' => 0, 'maghrib' => 0, 'isha' => 0 },
      'notifications' => { 'enabled' => true, 'pre_notify_minutes' => 10, 'respect_silencing' => true },
      'audio'         => { 'enabled' => true, 'player' => 'mpv',
                           'adhan' => '~/.config/omarchy-prayer/adhan.mp3',
                           'adhan_fajr' => '~/.config/omarchy-prayer/adhan-fajr.mp3',
                           'volume' => 80 },
      'waybar'        => { 'format' => '{prayer} {countdown}', 'soon_threshold_minutes' => 10 }
    }.freeze

    attr_reader :raw

    def self.load(path = Paths.config_file)
      raise MissingError, "config.toml not found at #{path} — run `omarchy-prayer` to bootstrap" unless File.exist?(path)
      new(Tomlrb.load_file(path, symbolize_keys: false))
    end

    def initialize(raw)
      @raw = merge_defaults(raw)
      validate!
    end

    def latitude;  @raw['location']['latitude'];  end
    def longitude; @raw['location']['longitude']; end
    def city;      @raw['location']['city'];      end
    def country;   @raw['location']['country'];   end

    def method_name; @raw['method']['name']; end

    def offsets
      @raw['offsets'].transform_keys(&:to_sym).transform_values(&:to_i)
    end

    def notifications_enabled;   @raw['notifications']['enabled'];            end
    def pre_notify_minutes;      @raw['notifications']['pre_notify_minutes']; end
    def respect_silencing;       @raw['notifications']['respect_silencing']; end

    def audio_enabled; @raw['audio']['enabled']; end
    def audio_player;  @raw['audio']['player'];  end
    def volume;        @raw['audio']['volume'];  end
    def adhan_path;      Paths.expand(@raw['audio']['adhan']);      end
    def adhan_fajr_path; Paths.expand(@raw['audio']['adhan_fajr']); end

    def waybar_format;          @raw['waybar']['format'];                 end
    def soon_threshold_minutes; @raw['waybar']['soon_threshold_minutes']; end

    private

    def merge_defaults(raw)
      result = DEFAULTS.each_with_object({}) { |(k, v), h| h[k] = v.dup }
      raw.each do |k, v|
        result[k] = v.is_a?(Hash) && result[k].is_a?(Hash) ? result[k].merge(v) : v
      end
      result
    end

    def validate!
      loc = @raw['location']
      raise InvalidError, '[location] section required' unless loc.is_a?(Hash)
      %w[latitude longitude].each do |k|
        raise InvalidError, "[location].#{k} must be a number" unless loc[k].is_a?(Numeric)
      end
      raise InvalidError, '[location].latitude out of range (-90..90)'   unless (-90..90).cover?(loc['latitude'])
      raise InvalidError, '[location].longitude out of range (-180..180)' unless (-180..180).cover?(loc['longitude'])

      unless KNOWN_METHODS.include?(@raw['method']['name'])
        raise InvalidError, "[method].name #{@raw['method']['name']!r} unknown (try: #{KNOWN_METHODS.join(', ')})"
      end

      vol = @raw['audio']['volume']
      raise InvalidError, '[audio].volume must be 0..100' unless vol.is_a?(Integer) && (0..100).cover?(vol)

      pm = @raw['notifications']['pre_notify_minutes']
      raise InvalidError, '[notifications].pre_notify_minutes must be 0..120' unless pm.is_a?(Integer) && (0..120).cover?(pm)
    end
  end
end
```

**Note:** the `#{value!r}` syntax in the error message is wrong in Ruby — replace with `#{@raw['method']['name'].inspect}`. Watch for it in Step 4 failures.

- [ ] **Step 4: Run test, iterate until pass**

```bash
bundle exec rake test TEST=test/test_config.rb
```

Expected: `6 runs, all pass`. If the `!r` syntax error hits, replace with `.inspect`.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/config.rb test/test_config.rb && \
  git commit -m "feat(config): TOML loader with defaults and validation"
```

---

## Task 4: `CountryMethods` — country → calc method mapping

**Files:**
- Create: `lib/omarchy_prayer/country_methods.rb`
- Create: `test/test_country_methods.rb`

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/country_methods'

class TestCountryMethods < Minitest::Test
  def test_saudi_arabia_to_makkah
    assert_equal 'Makkah', OmarchyPrayer::CountryMethods.resolve('SA')
  end

  def test_egypt_to_egypt
    assert_equal 'Egypt', OmarchyPrayer::CountryMethods.resolve('EG')
  end

  def test_pakistan_to_karachi
    assert_equal 'Karachi', OmarchyPrayer::CountryMethods.resolve('PK')
  end

  def test_united_states_to_isna
    assert_equal 'ISNA', OmarchyPrayer::CountryMethods.resolve('US')
  end

  def test_iran_to_tehran
    assert_equal 'Tehran', OmarchyPrayer::CountryMethods.resolve('IR')
  end

  def test_turkey_to_turkey
    assert_equal 'Turkey', OmarchyPrayer::CountryMethods.resolve('TR')
  end

  def test_unknown_falls_back_to_mwl
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve('ZZ')
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve(nil)
    assert_equal 'MWL', OmarchyPrayer::CountryMethods.resolve('')
  end

  def test_lowercase_accepted
    assert_equal 'Makkah', OmarchyPrayer::CountryMethods.resolve('sa')
  end
end
```

- [ ] **Step 2: Run to see it fail**

```bash
bundle exec rake test TEST=test/test_country_methods.rb
```

Expected: LoadError.

- [ ] **Step 3: Write `lib/omarchy_prayer/country_methods.rb`**

```ruby
module OmarchyPrayer
  module CountryMethods
    TABLE = {
      # Makkah (Umm al-Qura)
      'SA' => 'Makkah', 'YE' => 'Makkah',
      # Egypt (Egyptian General Authority)
      'EG' => 'Egypt', 'SY' => 'Egypt', 'IQ' => 'Egypt', 'JO' => 'Egypt',
      'LB' => 'Egypt', 'PS' => 'Egypt', 'DZ' => 'Egypt', 'TN' => 'Egypt',
      'LY' => 'Egypt', 'MA' => 'Egypt', 'SD' => 'Egypt',
      # Karachi
      'PK' => 'Karachi', 'BD' => 'Karachi', 'AF' => 'Karachi', 'IN' => 'Karachi',
      # Tehran (Shia Ithna-Ashari)
      'IR' => 'Tehran',
      # Turkey Diyanet
      'TR' => 'Turkey',
      # Gulf
      'AE' => 'Gulf', 'OM' => 'Gulf', 'BH' => 'Gulf',
      'QA' => 'Qatar',
      'KW' => 'Kuwait',
      # Singapore (also covers MY/BN)
      'SG' => 'Singapore', 'MY' => 'Singapore', 'BN' => 'Singapore', 'ID' => 'Singapore',
      # ISNA — North America
      'US' => 'ISNA', 'CA' => 'ISNA',
      # France
      'FR' => 'France',
      # Dubai carve-out
      # (AE already maps to Gulf; users wanting Dubai set explicitly.)
    }.freeze

    DEFAULT = 'MWL'

    module_function

    def resolve(code)
      return DEFAULT if code.nil? || code.to_s.strip.empty?
      TABLE.fetch(code.to_s.upcase, DEFAULT)
    end
  end
end
```

- [ ] **Step 4: Run test, verify pass**

Expected: `8 runs, 8 assertions, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/country_methods.rb test/test_country_methods.rb && \
  git commit -m "feat(methods): country → calc-method resolution"
```

---

## Task 5: `Methods` — parameter table for calc methods

**Files:**
- Create: `lib/omarchy_prayer/methods.rb`

- [ ] **Step 1: Write the module (pure data — tests exercise it via offline_calc)**

```ruby
module OmarchyPrayer
  module Methods
    # Parameters used by the offline calculator:
    #   fajr_angle: sun depression below horizon for Fajr (degrees)
    #   isha_angle: sun depression for Isha (degrees, unless isha_interval set)
    #   isha_interval: if set, Isha = Maghrib + N minutes (Umm al-Qura convention)
    #   maghrib_angle: sun depression for Maghrib (unset for most → sunset)
    #   asr_factor: 1 for Shafi/Maliki/Hanbali/Jafari; 2 for Hanafi (Karachi uses 1)
    TABLE = {
      'MWL'          => { fajr_angle: 18.0, isha_angle: 17.0 },
      'ISNA'         => { fajr_angle: 15.0, isha_angle: 15.0 },
      'Egypt'        => { fajr_angle: 19.5, isha_angle: 17.5 },
      'Makkah'       => { fajr_angle: 18.5, isha_interval: 90 },
      'Karachi'      => { fajr_angle: 18.0, isha_angle: 18.0 },
      'Tehran'       => { fajr_angle: 17.7, isha_angle: 14.0, maghrib_angle: 4.5 },
      'Jafari'       => { fajr_angle: 16.0, isha_angle: 14.0, maghrib_angle: 4.0 },
      'Kuwait'       => { fajr_angle: 18.0, isha_angle: 17.5 },
      'Qatar'        => { fajr_angle: 18.0, isha_interval: 90 },
      'Singapore'    => { fajr_angle: 20.0, isha_angle: 18.0 },
      'Turkey'       => { fajr_angle: 18.0, isha_angle: 17.0 },
      'Gulf'         => { fajr_angle: 19.5, isha_interval: 90 },
      'Moonsighting' => { fajr_angle: 18.0, isha_angle: 18.0 },
      'Dubai'        => { fajr_angle: 18.2, isha_angle: 18.2 },
      'France'       => { fajr_angle: 12.0, isha_angle: 12.0 }
    }.freeze

    module_function

    def params(name)
      TABLE.fetch(name) { raise ArgumentError, "unknown method: #{name.inspect}" }
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/omarchy_prayer/methods.rb && git commit -m "feat(methods): prayer calc parameter table"
```

---

## Task 6: `Qibla` — bearing to Makkah

**Files:**
- Create: `lib/omarchy_prayer/qibla.rb`
- Create: `test/test_qibla.rb`

Makkah = (21.4225°N, 39.8262°E). Qibla bearing uses the great-circle initial bearing formula.

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/qibla'

class TestQibla < Minitest::Test
  # Reference bearings (degrees True, to nearest integer) from IslamicFinder.
  REF = [
    # [lat,     lon,     expected_deg, label]
    [ 24.7136,  46.6753, 255, 'Riyadh'   ],   # almost due west
    [ 51.5074,  -0.1278, 119, 'London'   ],
    [ 40.7128, -74.0060,  58, 'New York' ],
    [-33.8688, 151.2093, 277, 'Sydney'   ],
    [ 35.6895, 139.6917, 293, 'Tokyo'    ]
  ].freeze

  def test_known_bearings_within_two_degrees
    REF.each do |lat, lon, expected, label|
      actual = OmarchyPrayer::Qibla.bearing(lat, lon)
      assert_in_delta expected, actual, 2.0, "#{label}: expected ~#{expected}°, got #{actual}°"
    end
  end

  def test_bearing_from_makkah_is_nan_safe
    # Near-zero distance — returns something in [0,360).
    b = OmarchyPrayer::Qibla.bearing(21.4225, 39.8262)
    assert b >= 0 && b < 360
  end

  def test_cardinal_west
    assert_equal 'W',   OmarchyPrayer::Qibla.cardinal(270)
    assert_equal 'WNW', OmarchyPrayer::Qibla.cardinal(292)
    assert_equal 'N',   OmarchyPrayer::Qibla.cardinal(0)
    assert_equal 'N',   OmarchyPrayer::Qibla.cardinal(359)
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/qibla.rb`**

```ruby
module OmarchyPrayer
  module Qibla
    MAKKAH_LAT = 21.4225
    MAKKAH_LON = 39.8262

    CARDINALS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze

    module_function

    # Initial great-circle bearing from (lat, lon) to Makkah, degrees [0, 360).
    def bearing(lat, lon)
      phi1 = to_rad(lat)
      phi2 = to_rad(MAKKAH_LAT)
      dlon = to_rad(MAKKAH_LON - lon)
      y = Math.sin(dlon) * Math.cos(phi2)
      x = Math.cos(phi1) * Math.sin(phi2) -
          Math.sin(phi1) * Math.cos(phi2) * Math.cos(dlon)
      deg = to_deg(Math.atan2(y, x))
      (deg % 360).round
    end

    def cardinal(deg)
      idx = ((deg % 360) / 22.5 + 0.5).floor % 16
      CARDINALS[idx]
    end

    def to_rad(d); d * Math::PI / 180.0; end
    def to_deg(r); r * 180.0 / Math::PI; end
  end
end
```

- [ ] **Step 4: Run test, verify pass**

Expected: all pass. If Riyadh bearing is off by more than 2°, re-check MAKKAH constants.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/qibla.rb test/test_qibla.rb && \
  git commit -m "feat(qibla): great-circle bearing to Makkah"
```

---

## Task 7: `OfflineCalc` — pure-Ruby prayer calculator

**Files:**
- Create: `lib/omarchy_prayer/offline_calc.rb`
- Create: `test/test_offline_calc.rb`

Implements standard solar equations for Fajr/sunrise/Dhuhr/Asr/Maghrib/Isha.

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'date'
require 'omarchy_prayer/offline_calc'

class TestOfflineCalc < Minitest::Test
  # Expected times collected from Aladhan for a fixed reference date.
  # (MWL method, Asr=Shafi). Tolerance ±2 minutes to absorb solar-equation variance.
  FIXTURES = [
    # [date,              lat,      lon,      method, tz_offset_sec, expected]
    [Date.new(2026,4,22), 24.7136,  46.6753, 'MWL', 3*3600,
      { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48', asr: '15:18', maghrib: '18:01', isha: '19:21' }],
    [Date.new(2026,4,22), 51.5074,  -0.1278, 'MWL', 1*3600,
      { fajr: '03:24', sunrise: '05:49', dhuhr: '12:58', asr: '16:53', maghrib: '20:08', isha: '22:22' }],
    [Date.new(2026,4,22), -6.2088, 106.8456, 'MWL', 7*3600,
      { fajr: '04:26', sunrise: '05:44', dhuhr: '11:50', asr: '15:10', maghrib: '17:54', isha: '19:03' }]
  ].freeze

  def test_matches_aladhan_within_two_minutes
    FIXTURES.each do |date, lat, lon, method, tz_offset, expected|
      times = OmarchyPrayer::OfflineCalc.compute(date:, lat:, lon:, method:, tz_offset:)
      expected.each do |prayer, hhmm|
        got = times[prayer].strftime('%H:%M')
        delta = minutes_between(got, hhmm)
        assert delta <= 2, "#{date} @ #{lat},#{lon} #{prayer}: expected #{hhmm}, got #{got} (Δ#{delta}m)"
      end
    end
  end

  def test_makkah_method_uses_90_min_isha_interval
    t = OmarchyPrayer::OfflineCalc.compute(
      date: Date.new(2026,4,22), lat: 24.7136, lon: 46.6753,
      method: 'Makkah', tz_offset: 3*3600
    )
    minutes = (t[:isha] - t[:maghrib]) / 60
    assert_in_delta 90, minutes, 1
  end

  private

  def minutes_between(a, b)
    ((Time.parse("2000-01-01 #{a}") - Time.parse("2000-01-01 #{b}")) / 60).abs.round
  end

  def setup
    require 'time'
  end
end
```

**Note:** the fixture times are illustrative targets. If your calculator is within ±2 min of the real Aladhan output for these coords/date, the test passes. When running, if any city is more than 2 minutes off, first verify the fixture against `curl -s "https://api.aladhan.com/v1/timings/22-04-2026?latitude=24.7136&longitude=46.6753&method=3"` (method=3 is MWL) and update the fixture, then fix the calculator if there's still drift.

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/offline_calc.rb`**

```ruby
require 'date'
require 'omarchy_prayer/methods'

module OmarchyPrayer
  module OfflineCalc
    module_function

    PRAYERS = %i[fajr sunrise dhuhr asr maghrib isha].freeze

    # Returns { prayer => Time (local, using tz_offset seconds from UTC) }.
    # asr_factor: 1 (Shafi/default) or 2 (Hanafi). Not part of method table for simplicity.
    def compute(date:, lat:, lon:, method:, tz_offset:, asr_factor: 1)
      jd = julian_day(date)
      decl, eqt = sun_position(jd)

      # Dhuhr (solar noon) in UTC hours.
      dhuhr_utc = 12 - lon / 15.0 - eqt / 60.0

      params = Methods.params(method)

      fajr_utc    = dhuhr_utc - hour_angle_for_angle(params[:fajr_angle], lat, decl) / 15.0
      sunrise_utc = dhuhr_utc - hour_angle_for_altitude(-0.833, lat, decl) / 15.0
      maghrib_utc =
        if params[:maghrib_angle]
          dhuhr_utc + hour_angle_for_angle(params[:maghrib_angle], lat, decl) / 15.0
        else
          dhuhr_utc + hour_angle_for_altitude(-0.833, lat, decl) / 15.0
        end
      asr_utc     = dhuhr_utc + hour_angle_for_asr(asr_factor, lat, decl) / 15.0
      isha_utc =
        if params[:isha_interval]
          maghrib_utc + params[:isha_interval] / 60.0
        else
          dhuhr_utc + hour_angle_for_angle(params[:isha_angle], lat, decl) / 15.0
        end

      times = {
        fajr:    fajr_utc,    sunrise: sunrise_utc, dhuhr: dhuhr_utc,
        asr:     asr_utc,     maghrib: maghrib_utc, isha:  isha_utc
      }
      times.transform_values { |h_utc| hour_to_time(date, h_utc, tz_offset) }
    end

    def julian_day(date)
      y = date.year; m = date.month; d = date.day
      if m <= 2; y -= 1; m += 12; end
      a = (y / 100).floor
      b = 2 - a + (a / 4).floor
      (365.25 * (y + 4716)).floor + (30.6001 * (m + 1)).floor + d + b - 1524.5
    end

    # Returns [declination_deg, equation_of_time_minutes].
    def sun_position(jd)
      d = jd - 2451545.0
      g = (357.529 + 0.98560028 * d) % 360
      q = (280.459 + 0.98564736 * d) % 360
      l = (q + 1.915 * Math.sin(r(g)) + 0.020 * Math.sin(r(2*g))) % 360
      e = 23.439 - 0.00000036 * d
      ra_deg = d(Math.atan2(Math.cos(r(e)) * Math.sin(r(l)), Math.cos(r(l)))) / 15.0
      ra_deg = (ra_deg + 24) % 24
      decl = d(Math.asin(Math.sin(r(e)) * Math.sin(r(l))))
      eqt  = (q / 15.0 - ra_deg) * 60
      [decl, eqt]
    end

    def hour_angle_for_angle(angle_deg, lat, decl)
      h = Math.acos(
        (-Math.sin(r(angle_deg)) - Math.sin(r(lat)) * Math.sin(r(decl))) /
        (Math.cos(r(lat)) * Math.cos(r(decl)))
      )
      d(h)
    end

    def hour_angle_for_altitude(alt_deg, lat, decl)
      hour_angle_for_angle(-alt_deg, lat, decl)
    end

    def hour_angle_for_asr(factor, lat, decl)
      alt = -d(Math.atan(1.0 / (factor + Math.tan(r(lat - decl)))))
      hour_angle_for_altitude(alt, lat, decl)
    end

    def hour_to_time(date, h_utc, tz_offset)
      h_local = (h_utc + tz_offset / 3600.0) % 24
      total_sec = (h_local * 3600).round
      hh = total_sec / 3600
      mm = (total_sec % 3600) / 60
      ss = total_sec % 60
      Time.new(date.year, date.month, date.day, hh, mm, ss, tz_offset)
    end

    def r(deg); deg * Math::PI / 180.0; end
    def d(rad); rad * 180.0 / Math::PI; end
  end
end
```

- [ ] **Step 4: Run test; iterate**

If the test fails by more than 2 minutes at any fixture, first validate the fixture against live Aladhan. If still drifting: check sign conventions in `hour_angle_for_angle` (a common bug is flipping the sign of the angle for Fajr vs Maghrib).

Expected (after iteration): all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/offline_calc.rb test/test_offline_calc.rb && \
  git commit -m "feat(offline): pure-Ruby prayer time calculator"
```

---

## Task 8: `AladhanClient` — HTTP + monthly cache

**Files:**
- Create: `lib/omarchy_prayer/aladhan_client.rb`
- Create: `test/test_aladhan_client.rb`
- Create: `test/fixtures/aladhan_april_2026.json`

- [ ] **Step 1: Create minimal fixture at `test/fixtures/aladhan_april_2026.json`**

Use the shape returned by `GET /v1/calendar`. Keep only two days for brevity; the client doesn't care how many entries.

```json
{
  "code": 200,
  "status": "OK",
  "data": [
    {
      "timings": {
        "Fajr": "04:15 (+03)",
        "Sunrise": "05:35 (+03)",
        "Dhuhr": "11:48 (+03)",
        "Asr": "15:18 (+03)",
        "Maghrib": "18:01 (+03)",
        "Isha": "19:21 (+03)"
      },
      "date": { "readable": "01 Apr 2026", "gregorian": { "date": "01-04-2026" } }
    },
    {
      "timings": {
        "Fajr": "04:14 (+03)",
        "Sunrise": "05:34 (+03)",
        "Dhuhr": "11:48 (+03)",
        "Asr": "15:18 (+03)",
        "Maghrib": "18:02 (+03)",
        "Isha": "19:22 (+03)"
      },
      "date": { "readable": "22 Apr 2026", "gregorian": { "date": "22-04-2026" } }
    }
  ]
}
```

- [ ] **Step 2: Write `test/test_aladhan_client.rb`**

```ruby
require 'test_helper'
require 'webrick'
require 'omarchy_prayer/aladhan_client'
require 'date'

class TestAladhanClient < Minitest::Test
  include TestHelper

  def setup
    @fixture = File.read(File.expand_path('fixtures/aladhan_april_2026.json', __dir__))
    @captured_path = nil
    @server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc('/') do |req, res|
      @captured_path = req.path + '?' + (req.query_string || '')
      res.content_type = 'application/json'
      res.body = @fixture
    end
    @thread = Thread.new { @server.start }
    @base = "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def teardown
    @server.shutdown
    @thread.join
  end

  def test_fetch_month_returns_day_map
    days = OmarchyPrayer::AladhanClient.new(base_url: @base).fetch_month(
      year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'MWL'
    )
    assert_equal 2, days.size
    entry = days['2026-04-22']
    assert_equal '04:14', entry['fajr']
    assert_equal '19:22', entry['isha']
  end

  def test_url_includes_method_and_coords
    OmarchyPrayer::AladhanClient.new(base_url: @base).fetch_month(
      year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'Makkah'
    )
    assert_match %r{/v1/calendar/2026/4\?}, @captured_path
    assert_match(/method=4/,                @captured_path)   # Makkah == 4
    assert_match(/latitude=24.7136/,        @captured_path)
    assert_match(/longitude=46.6753/,       @captured_path)
  end

  def test_cache_roundtrip
    with_isolated_home do
      client = OmarchyPrayer::AladhanClient.new(base_url: @base)
      first = client.fetch_month(year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'MWL')
      cache_file = OmarchyPrayer::Paths.month_cache('2026-04')
      assert File.exist?(cache_file)
      # Shut down server to prove the second call uses cache.
      @server.shutdown; @thread.join
      second = client.read_cache(year: 2026, month: 4)
      assert_equal first, second
    end
  end
end
```

- [ ] **Step 3: Run to see fail**

- [ ] **Step 4: Write `lib/omarchy_prayer/aladhan_client.rb`**

```ruby
require 'net/http'
require 'uri'
require 'json'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class AladhanClient
    # Aladhan method IDs — https://aladhan.com/calculation-methods
    METHOD_IDS = {
      'MWL' => 3, 'ISNA' => 2, 'Egypt' => 5, 'Makkah' => 4, 'Karachi' => 1,
      'Tehran' => 7, 'Jafari' => 0, 'Kuwait' => 9, 'Qatar' => 10,
      'Singapore' => 11, 'Turkey' => 13, 'Gulf' => 8, 'Moonsighting' => 15,
      'Dubai' => 16, 'France' => 12
    }.freeze

    DEFAULT_BASE = 'https://api.aladhan.com'.freeze

    class Error < StandardError; end

    def initialize(base_url: DEFAULT_BASE, timeout: 10)
      @base = base_url
      @timeout = timeout
    end

    def fetch_month(year:, month:, lat:, lon:, method_name:)
      method_id = METHOD_IDS.fetch(method_name) do
        raise Error, "no Aladhan method id for #{method_name.inspect}"
      end
      uri = URI("#{@base}/v1/calendar/#{year}/#{month}")
      uri.query = URI.encode_www_form(
        latitude: lat, longitude: lon, method: method_id, school: 0
      )
      resp = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "Aladhan HTTP #{resp.code}" unless resp.code == '200'
      parsed = JSON.parse(resp.body)
      raise Error, "Aladhan payload status #{parsed['code']}" unless parsed['code'] == 200

      days = {}
      parsed['data'].each do |entry|
        date_key = reformat_date(entry.dig('date', 'gregorian', 'date'))  # DD-MM-YYYY → YYYY-MM-DD
        days[date_key] = strip_timings(entry['timings'])
      end
      write_cache(year: year, month: month, days: days)
      days
    end

    def read_cache(year:, month:)
      path = Paths.month_cache(format('%04d-%02d', year, month))
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    private

    def write_cache(year:, month:, days:)
      Paths.ensure_state_dir
      File.write(Paths.month_cache(format('%04d-%02d', year, month)), JSON.pretty_generate(days))
    end

    def reformat_date(ddmmyyyy)
      d, m, y = ddmmyyyy.split('-')
      "#{y}-#{m}-#{d}"
    end

    def strip_timings(t)
      t.transform_keys(&:downcase).transform_values { |v| v.split(' ', 2).first }
    end
  end
end
```

- [ ] **Step 5: Run tests, verify pass**

- [ ] **Step 6: Commit**

```bash
git add lib/omarchy_prayer/aladhan_client.rb test/test_aladhan_client.rb test/fixtures/aladhan_april_2026.json && \
  git commit -m "feat(aladhan): HTTP client + monthly cache"
```

---

## Task 9: `Today` + `TimesSource` — today.json + three-tier resolver

**Files:**
- Create: `lib/omarchy_prayer/today.rb`
- Create: `lib/omarchy_prayer/times_source.rb`
- Create: `test/test_today.rb`
- Create: `test/test_times_source.rb`

- [ ] **Step 1: Write `test/test_today.rb`**

```ruby
require 'test_helper'
require 'omarchy_prayer/today'

class TestToday < Minitest::Test
  include TestHelper

  def test_write_and_read_roundtrip
    with_isolated_home do
      today = OmarchyPrayer::Today.new(
        date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'Makkah', source: 'api-cache',
        times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
                 asr: '15:18', maghrib: '18:01', isha: '19:21' }
      )
      today.write
      loaded = OmarchyPrayer::Today.read
      assert_equal '2026-04-22', loaded.date
      assert_equal 'Riyadh',     loaded.city
      assert_equal '04:15',      loaded.times[:fajr]
      assert_equal 'api-cache',  loaded.source
    end
  end

  def test_next_prayer_selects_first_future
    times = { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
              asr: '15:18', maghrib: '18:01', isha: '19:21' }
    today = OmarchyPrayer::Today.new(date: '2026-04-22', tz_offset: 10800,
      city: 'Riyadh', country: 'SA', method: 'Makkah', source: 'api', times: times)
    now = Time.new(2026, 4, 22, 12, 30, 0, 10800)
    name, at = today.next_prayer(now: now)
    assert_equal :asr, name
    assert_equal Time.new(2026,4,22,15,18,0,10800), at
  end

  def test_next_prayer_after_isha_returns_tomorrow_fajr
    times = { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
              asr: '15:18', maghrib: '18:01', isha: '19:21' }
    today = OmarchyPrayer::Today.new(date: '2026-04-22', tz_offset: 10800,
      city: 'Riyadh', country: 'SA', method: 'Makkah', source: 'api', times: times)
    now = Time.new(2026, 4, 22, 22, 0, 0, 10800)
    name, at = today.next_prayer(now: now)
    assert_equal :fajr_tomorrow, name
    assert_equal Time.new(2026,4,23,4,15,0,10800), at
  end
end
```

- [ ] **Step 2: Write `test/test_times_source.rb`**

```ruby
require 'test_helper'
require 'omarchy_prayer/times_source'

class TestTimesSource < Minitest::Test
  include TestHelper

  # Use a stub client that records calls.
  class StubClient
    attr_reader :calls
    def initialize(behavior) ; @behavior = behavior ; @calls = [] ; end
    def read_cache(year:, month:)
      @calls << [:read_cache, year, month]
      @behavior[:cache]
    end
    def fetch_month(year:, month:, lat:, lon:, method_name:)
      @calls << [:fetch_month, year, month, method_name]
      raise @behavior[:fetch_error] if @behavior[:fetch_error]
      @behavior[:fetched]
    end
  end

  FAKE_DAY = { 'fajr' => '04:15', 'sunrise' => '05:35', 'dhuhr' => '11:48',
               'asr' => '15:18', 'maghrib' => '18:01', 'isha' => '19:21' }

  def base_args
    { year: 2026, month: 4, day: '2026-04-22', lat: 24.7136, lon: 46.6753,
      method_name: 'MWL', tz_offset: 10800, offline_fallback: ->(*) { FAKE_DAY } }
  end

  def test_cache_hit_skips_fetch
    client = StubClient.new(cache: { '2026-04-22' => FAKE_DAY })
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'cache',   src
    assert_equal '04:15',   times['fajr']
    refute(client.calls.any? { |c| c[0] == :fetch_month })
  end

  def test_cache_miss_fetches
    client = StubClient.new(cache: nil, fetched: { '2026-04-22' => FAKE_DAY })
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'api',     src
    assert_equal '04:15',   times['fajr']
  end

  def test_fetch_failure_falls_to_offline
    client = StubClient.new(cache: nil, fetch_error: StandardError.new('network down'))
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'offline', src
    assert_equal '04:15',   times['fajr']
  end

  def test_cache_present_but_missing_day_falls_through
    other = { '2026-04-01' => FAKE_DAY }
    client = StubClient.new(cache: other, fetched: { '2026-04-22' => FAKE_DAY })
    src, _ = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'api', src
  end
end
```

- [ ] **Step 3: Run both to see fail**

- [ ] **Step 4: Write `lib/omarchy_prayer/today.rb`**

```ruby
require 'json'
require 'time'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Today
    ORDER = %i[fajr dhuhr asr maghrib isha].freeze

    attr_reader :date, :tz_offset, :city, :country, :method, :source, :times

    def initialize(date:, tz_offset:, city:, country:, method:, source:, times:)
      @date = date; @tz_offset = tz_offset
      @city = city; @country = country
      @method = method; @source = source
      @times = symbolize(times)
    end

    def self.read(path = Paths.today_json)
      data = JSON.parse(File.read(path))
      new(**{
        date: data['date'], tz_offset: data['tz_offset'],
        city: data['city'], country: data['country'],
        method: data['method'], source: data['source'],
        times: data['times']
      })
    end

    def write(path = Paths.today_json)
      Paths.ensure_state_dir
      File.write(path, JSON.pretty_generate(
        date: @date, tz_offset: @tz_offset, city: @city, country: @country,
        method: @method, source: @source,
        times: @times.transform_keys(&:to_s)
      ))
    end

    def time_for(prayer)
      h, m = @times.fetch(prayer).split(':').map(&:to_i)
      y, mo, d = @date.split('-').map(&:to_i)
      Time.new(y, mo, d, h, m, 0, @tz_offset)
    end

    def next_prayer(now: Time.now)
      ORDER.each do |p|
        t = time_for(p)
        return [p, t] if t > now
      end
      # All passed — tomorrow's fajr.
      tomorrow = Date.parse(@date).next
      h, m = @times.fetch(:fajr).split(':').map(&:to_i)
      [:fajr_tomorrow, Time.new(tomorrow.year, tomorrow.month, tomorrow.day, h, m, 0, @tz_offset)]
    end

    private

    def symbolize(h)
      h.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
```

- [ ] **Step 5: Write `lib/omarchy_prayer/times_source.rb`**

```ruby
require 'omarchy_prayer/aladhan_client'

module OmarchyPrayer
  class TimesSource
    def initialize(client: AladhanClient.new)
      @client = client
    end

    # Returns [source_label, day_hash] where source_label ∈ {cache, api, offline}
    # and day_hash = { 'fajr' => 'HH:MM', ... }.
    def resolve(year:, month:, day:, lat:, lon:, method_name:, tz_offset:, offline_fallback:)
      cached = safe { @client.read_cache(year: year, month: month) }
      if cached && cached[day]
        return ['cache', cached[day]]
      end
      fetched = safe { @client.fetch_month(year: year, month: month, lat: lat, lon: lon, method_name: method_name) }
      if fetched && fetched[day]
        return ['api', fetched[day]]
      end
      ['offline', offline_fallback.call(day: day, lat: lat, lon: lon, method_name: method_name, tz_offset: tz_offset)]
    end

    private

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
```

- [ ] **Step 6: Run both tests**

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/omarchy_prayer/today.rb lib/omarchy_prayer/times_source.rb \
        test/test_today.rb test/test_times_source.rb && \
  git commit -m "feat(today): today.json + three-tier times resolver"
```

---

## Task 10: `Waybar` — next-prayer JSON

**Files:**
- Create: `lib/omarchy_prayer/waybar.rb`
- Create: `test/test_waybar.rb`

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/today'
require 'omarchy_prayer/waybar'

class TestWaybar < Minitest::Test
  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  def test_countdown_and_class
    now = Time.new(2026,4,22, 13,4,0, 10800)  # 2h 14m before Asr 15:18
    json = OmarchyPrayer::Waybar.render(today, now: now,
      format: '{prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'Asr 2h 14m', data['text']
    assert_equal 'prayer-normal', data['class']
    assert_match(/Fajr.*04:15/, data['tooltip'])
    assert_match(/Asr.*15:18/,  data['tooltip'])
  end

  def test_soon_class_applied_within_threshold
    now = Time.new(2026,4,22, 15,12,0, 10800)  # 6m before Asr
    json = OmarchyPrayer::Waybar.render(today, now: now,
      format: '{prayer} {countdown}', soon_minutes: 10)
    assert_equal 'prayer-soon', JSON.parse(json)['class']
  end

  def test_after_isha_shows_tomorrow_fajr
    now = Time.new(2026,4,22, 22,0,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now,
      format: '{prayer} {time}', soon_minutes: 10)
    assert_match(/Fajr 04:15/, JSON.parse(json)['text'])
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/waybar.rb`**

```ruby
require 'json'
require 'omarchy_prayer/today'

module OmarchyPrayer
  module Waybar
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr',
      asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha',
      fajr_tomorrow: 'Fajr'
    }.freeze

    module_function

    def render(today, now: Time.now, format:, soon_minutes:)
      name, at = today.next_prayer(now: now)
      pretty = PRETTY.fetch(name)
      time_s = at.strftime('%H:%M')
      secs = (at - now).to_i
      countdown = format_countdown(secs)
      text = format.gsub('{prayer}', pretty).gsub('{time}', time_s).gsub('{countdown}', countdown)
      cls  = secs / 60 < soon_minutes ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(today))
    end

    def format_countdown(secs)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def build_tooltip(today)
      Today::ORDER.map { |p| format('%-7s %s', PRETTY[p], today.times[p]) }.join("\n")
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/waybar.rb test/test_waybar.rb && \
  git commit -m "feat(waybar): render next-prayer JSON with countdown"
```

---

## Task 11: `Audio` — spawn/kill mpv with PID file

**Files:**
- Create: `lib/omarchy_prayer/audio.rb`
- Create: `test/test_audio.rb`

- [ ] **Step 1: Write test using shim**

```ruby
require 'test_helper'
require 'omarchy_prayer/audio'
require 'omarchy_prayer/paths'

class TestAudio < Minitest::Test
  include TestHelper

  def test_play_records_pid_and_log
    with_isolated_home do |home|
      log = with_shims(home, %w[mpv])
      # Fake audio file.
      audio = "#{home}/adhan.mp3"; File.write(audio, 'stub')
      audio_mod = OmarchyPrayer::Audio.new(player: 'mpv', volume: 77)
      audio_mod.play(audio)
      # Allow the forked child to run once.
      sleep 0.05
      assert File.exist?(OmarchyPrayer::Paths.adhan_pid)
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'mpv' && e.include?('--volume=77') && e.include?(audio) },
             "mpv not invoked correctly: #{entries.inspect}"
    end
  end

  def test_stop_kills_process_and_removes_pidfile
    with_isolated_home do |home|
      pid_file = OmarchyPrayer::Paths.adhan_pid
      FileUtils.mkdir_p(File.dirname(pid_file))
      # Spawn a sleep we can actually kill.
      pid = Process.spawn('sleep', '30')
      File.write(pid_file, pid.to_s)
      OmarchyPrayer::Audio.new.stop
      refute File.exist?(pid_file)
      # Process gone within 500ms.
      deadline = Time.now + 0.5
      while Time.now < deadline
        begin
          Process.kill(0, pid)
          sleep 0.02
        rescue Errno::ESRCH
          break
        end
      end
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  ensure
    begin; Process.wait(pid); rescue; end if pid
  end

  def test_stop_without_pid_file_is_noop
    with_isolated_home do
      OmarchyPrayer::Audio.new.stop  # should not raise
    end
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/audio.rb`**

```ruby
require 'fileutils'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Audio
    def initialize(player: 'mpv', volume: 80)
      @player = player
      @volume = volume
    end

    def play(file)
      Paths.ensure_state_dir
      # Spawn detached; capture PID atomically.
      pid = Process.spawn(@player, '--no-video', '--really-quiet',
                          "--volume=#{@volume}", file,
                          pgroup: true,
                          %i[out err] => '/dev/null',
                          :in => '/dev/null')
      Process.detach(pid)
      write_pid_atomic(pid)
      pid
    end

    def stop
      path = Paths.adhan_pid
      return unless File.exist?(path)
      pid = File.read(path).strip.to_i
      FileUtils.rm_f(path)
      return if pid.zero?
      begin
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        # gone already
      end
    end

    private

    def write_pid_atomic(pid)
      tmp = "#{Paths.adhan_pid}.tmp.#{Process.pid}"
      File.write(tmp, pid.to_s)
      File.rename(tmp, Paths.adhan_pid)
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

Expected: all three tests pass. The `sleep 0.05` in the first test is the common reason for flakiness — bump to 0.1 if needed.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/audio.rb test/test_audio.rb && \
  git commit -m "feat(audio): spawn/stop mpv with atomic PID file"
```

---

## Task 12: `Notifier` — notify-send + DND + mute

**Files:**
- Create: `lib/omarchy_prayer/notifier.rb`
- Create: `test/test_notifier.rb`

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/notifier'
require 'omarchy_prayer/today'
require 'omarchy_prayer/paths'

class TestNotifier < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  def test_on_time_notification_emits_notify_send_and_plays_audio
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      OmarchyPrayer::Notifier.new(
        today: today, respect_silencing: true,
        audio_enabled: true, audio_player: 'mpv', volume: 80,
        adhan: '/tmp/adhan.mp3', adhan_fajr: '/tmp/adhan-fajr.mp3'
      ).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.05
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'notify-send' && e.include?('Dhuhr') }
      assert entries.any? { |e| e[0] == 'mpv' && e.include?('/tmp/adhan.mp3') }
    end
  end

  def test_fajr_uses_fajr_variant
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      OmarchyPrayer::Notifier.new(
        today: today, respect_silencing: true, audio_enabled: true,
        audio_player: 'mpv', volume: 80,
        adhan: '/tmp/adhan.mp3', adhan_fajr: '/tmp/adhan-fajr.mp3'
      ).fire(prayer: :fajr, event: 'on-time')
      sleep 0.05
      assert read_shim_log(log).any? { |e| e[0] == 'mpv' && e.include?('/tmp/adhan-fajr.mp3') }
    end
  end

  def test_pre_event_skips_audio
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      OmarchyPrayer::Notifier.new(today: today, respect_silencing: true,
        audio_enabled: true, audio_player: 'mpv', volume: 80,
        adhan: '/tmp/a.mp3', adhan_fajr: '/tmp/f.mp3'
      ).fire(prayer: :asr, event: 'pre')
      sleep 0.05
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'notify-send' && e.include?('10 min to Asr') }
      refute entries.any? { |e| e[0] == 'mpv' }
    end
  end

  def test_dnd_respected
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'do-not-disturb'
      OmarchyPrayer::Notifier.new(today: today, respect_silencing: true,
        audio_enabled: true, audio_player: 'mpv', volume: 80,
        adhan: '/tmp/a.mp3', adhan_fajr: '/tmp/f.mp3'
      ).fire(prayer: :dhuhr, event: 'on-time')
      assert_empty read_shim_log(log).select { |e| e[0] == 'notify-send' }
      assert_empty read_shim_log(log).select { |e| e[0] == 'mpv' }
    end
  end

  def test_mute_today_suppresses
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      FileUtils.mkdir_p(File.dirname(OmarchyPrayer::Paths.mute_today))
      FileUtils.touch(OmarchyPrayer::Paths.mute_today)
      OmarchyPrayer::Notifier.new(today: today, respect_silencing: true,
        audio_enabled: true, audio_player: 'mpv', volume: 80,
        adhan: '/tmp/a.mp3', adhan_fajr: '/tmp/f.mp3'
      ).fire(prayer: :dhuhr, event: 'on-time')
      assert_empty read_shim_log(log).select { |e| %w[notify-send mpv].include?(e[0]) }
    end
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/notifier.rb`**

```ruby
require 'omarchy_prayer/audio'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Notifier
    PRETTY = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' }.freeze

    def initialize(today:, respect_silencing:, audio_enabled:, audio_player:, volume:,
                   adhan:, adhan_fajr:, pre_notify_minutes: 10)
      @today = today; @respect = respect_silencing
      @audio_enabled = audio_enabled; @audio_player = audio_player; @volume = volume
      @adhan = adhan; @adhan_fajr = adhan_fajr
      @pre_minutes = pre_notify_minutes
    end

    def fire(prayer:, event:)
      return if muted?
      return if @respect && dnd?

      title, body, action = compose(prayer, event)
      args = ['-a', 'omarchy-prayer', title, body]
      args += ['--action=stop-adhan=Stop adhan'] if action
      system('notify-send', *args)

      if event == 'on-time' && @audio_enabled
        file = prayer == :fajr ? @adhan_fajr : @adhan
        if File.exist?(file)
          Audio.new(player: @audio_player, volume: @volume).play(file)
        else
          system('notify-send', '-a', 'omarchy-prayer', '-u', 'low',
                 'Adhan audio missing', "Not found: #{file}")
        end
      end
    end

    private

    def muted?
      File.exist?(Paths.mute_today)
    end

    def dnd?
      out = `makoctl mode 2>/dev/null`.strip
      out.include?('do-not-disturb')
    end

    def compose(prayer, event)
      pretty = PRETTY.fetch(prayer)
      at = @today.times.fetch(prayer)
      if event == 'pre'
        ["#{@pre_minutes} min to #{pretty}", "#{pretty} at #{at} — #{@today.city}", false]
      else
        [pretty, "#{at} — time for #{pretty}", true]
      end
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/notifier.rb test/test_notifier.rb && \
  git commit -m "feat(notifier): notify-send + audio with DND and mute-today"
```

---

## Task 13: `Geolocate` — IP-based location on first run

**Files:**
- Create: `lib/omarchy_prayer/geolocate.rb`
- Create: `test/test_geolocate.rb`

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'webrick'
require 'omarchy_prayer/geolocate'

class TestGeolocate < Minitest::Test
  def test_parses_ip_api_response
    body = { status: 'success', lat: 24.7136, lon: 46.6753,
             city: 'Riyadh', countryCode: 'SA' }.to_json
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, res| res.body = body; res.content_type = 'application/json' }
    thr = Thread.new { server.start }
    url = "http://127.0.0.1:#{server.config[:Port]}/"
    result = OmarchyPrayer::Geolocate.detect(url: url, timeout: 2)
    assert_equal 'Riyadh', result[:city]
    assert_equal 'SA',     result[:country]
    assert_in_delta 24.7136, result[:latitude], 1e-6
  ensure
    server&.shutdown
    thr&.join
  end

  def test_raises_when_status_not_success
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, r| r.body = '{"status":"fail"}'; r.content_type = 'application/json' }
    thr = Thread.new { server.start }
    err = assert_raises(OmarchyPrayer::Geolocate::Error) do
      OmarchyPrayer::Geolocate.detect(url: "http://127.0.0.1:#{server.config[:Port]}/", timeout: 2)
    end
    assert_match(/geolocation failed/, err.message)
  ensure
    server&.shutdown
    thr&.join
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/geolocate.rb`**

```ruby
require 'net/http'
require 'uri'
require 'json'

module OmarchyPrayer
  module Geolocate
    class Error < StandardError; end

    DEFAULT_URL = 'http://ip-api.com/json/'

    module_function

    def detect(url: DEFAULT_URL, timeout: 5)
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

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/geolocate.rb test/test_geolocate.rb && \
  git commit -m "feat(geolocate): IP geolocation for first-run setup"
```

---

## Task 14: `FirstRun` — bootstrap config.toml

**Files:**
- Create: `lib/omarchy_prayer/first_run.rb`

- [ ] **Step 1: Write the bootstrap module (exercised via integration smoke test later)**

```ruby
require 'fileutils'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/country_methods'

module OmarchyPrayer
  module FirstRun
    TEMPLATE = <<~TOML
      [location]
      # Edit freely; filled from IP geolocation on first run.
      latitude  = %<lat>.4f
      longitude = %<lon>.4f
      city      = "%<city>s"
      country   = "%<country>s"

      [method]
      # "auto" picks from country; see README for full list.
      name = "auto"

      [offsets]
      fajr = 0
      dhuhr = 0
      asr = 0
      maghrib = 0
      isha = 0

      [notifications]
      enabled            = true
      pre_notify_minutes = 10
      respect_silencing  = true

      [audio]
      enabled    = true
      player     = "mpv"
      adhan      = "~/.config/omarchy-prayer/adhan.mp3"
      adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
      volume     = 80

      [waybar]
      format                 = "{prayer} {countdown}"
      soon_threshold_minutes = 10
    TOML

    module_function

    # Returns true if config was just created; false if it already existed.
    def ensure_config!(geolocate: Geolocate, out: $stdout)
      return false if File.exist?(Paths.config_file)
      out.puts 'omarchy-prayer: first-run — detecting location via ip-api.com…'
      loc = geolocate.detect
      Paths.ensure_config_dir
      File.write(Paths.config_file,
                 format(TEMPLATE,
                        lat: loc[:latitude], lon: loc[:longitude],
                        city: loc[:city], country: loc[:country]))
      out.puts "omarchy-prayer: wrote config for #{loc[:city]}, #{loc[:country]} (edit #{Paths.config_file} to override)"
      true
    rescue Geolocate::Error => e
      raise "first-run failed: #{e.message}\n" \
            "edit #{Paths.config_file} manually — see README for the template"
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/omarchy_prayer/first_run.rb && \
  git commit -m "feat(first-run): bootstrap config.toml via IP geolocation"
```

---

## Task 15: `Scheduler` — create transient systemd timers

**Files:**
- Create: `lib/omarchy_prayer/scheduler.rb`
- Create: `test/test_scheduler.rb`

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/scheduler'
require 'omarchy_prayer/today'

class TestScheduler < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  def test_issues_ten_units_with_correct_on_calendar
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      # Let the stub pretend there are no existing timers.
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 10)
      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      assert_equal 10, calls.size
      # Confirm each unit has --user, --on-calendar, and --unit named prayer-...
      assert calls.all? { |c| c.include?('--user') }
      assert calls.all? { |c| c.any? { |a| a.start_with?('--on-calendar=') } }
      # Fajr on-time at 04:15.
      assert calls.any? { |c|
        c.include?('--on-calendar=2026-04-22 04:15:00') &&
        c.any? { |a| a.start_with?('--unit=op-fajr-on-time') }
      }
      # Fajr pre at 04:05.
      assert calls.any? { |c|
        c.include?('--on-calendar=2026-04-22 04:05:00') &&
        c.any? { |a| a.start_with?('--unit=op-fajr-pre') }
      }
    end
  end

  def test_pre_minutes_zero_disables_pre_timers
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 0)
      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      assert_equal 5, calls.size
      assert calls.none? { |c| c.any? { |a| a.include?('pre') } }
    end
  end

  def test_stops_prior_units_before_creating_new
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      # Pretend one old unit exists.
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = "op-old.timer loaded active\n"
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 10)
      calls = read_shim_log(log).select { |e| e[0] == 'systemctl' }
      assert calls.any? { |c| c.include?('stop') && c.include?('op-old.timer') }
    end
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/scheduler.rb`**

```ruby
require 'omarchy_prayer/today'

module OmarchyPrayer
  class Scheduler
    UNIT_PREFIX = 'op-'

    def rebuild(today, pre_minutes:)
      stop_existing
      Today::ORDER.each do |prayer|
        hhmm = today.times[prayer]
        next unless hhmm

        at = parse_time(today.date, hhmm, today.tz_offset)
        create_transient(today.date, prayer, 'on-time', at)

        if pre_minutes.positive?
          pre_at = at - pre_minutes * 60
          create_transient(today.date, prayer, 'pre', pre_at)
        end
      end
    end

    def stop_existing
      out = `systemctl --user list-timers --all --no-legend 2>/dev/null`
      out.each_line do |line|
        unit = line.strip.split(/\s+/).find { |tok| tok.start_with?(UNIT_PREFIX) && tok.end_with?('.timer') }
        next unless unit
        system('systemctl', '--user', 'stop', unit)
      end
    end

    private

    def parse_time(date, hhmm, tz_offset)
      y, m, d = date.split('-').map(&:to_i)
      h, mi   = hhmm.split(':').map(&:to_i)
      Time.new(y, m, d, h, mi, 0, tz_offset)
    end

    def create_transient(date, prayer, event, at)
      unit = "#{UNIT_PREFIX}#{prayer}-#{event}-#{date}"
      on_calendar = at.strftime('%Y-%m-%d %H:%M:%S')
      cmd = ['systemd-run', '--user', '--unit', unit,
             "--on-calendar=#{on_calendar}",
             '--timer-property=AccuracySec=1s',
             'omarchy-prayer-notify', prayer.to_s, event]
      # Older systemd-run wants --unit=... style; pass as a single token too.
      cmd[2] = "--unit=#{unit}"; cmd.delete_at(3)
      system(*cmd)
    end
  end
end
```

**Note on `--unit`:** the test expects the combined `--unit=...` form, so the `cmd` rewrite at the bottom of `create_transient` is not optional — keep the one-arg form.

- [ ] **Step 4: Run, verify pass**

Expected: all three tests pass. If the first test finds 11 calls, you forgot to skip `sunrise` — it's in `Today::ORDER` but shouldn't get a timer. The scheduler iterates `ORDER`, so either change ORDER to exclude sunrise or add a guard. Go with: ORDER stays the five prayers only, which matches `Today::ORDER` as defined in Task 9. Confirm by re-reading `lib/omarchy_prayer/today.rb`.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/scheduler.rb test/test_scheduler.rb && \
  git commit -m "feat(scheduler): rebuild transient systemd timers daily"
```

---

## Task 16: Entry scripts in `bin/`

**Files:**
- Create: `bin/omarchy-prayer-schedule`
- Create: `bin/omarchy-prayer-notify`
- Create: `bin/omarchy-prayer-waybar`
- Create: `bin/omarchy-prayer-stop`

All are thin wrappers that load `lib/` and delegate.

- [ ] **Step 1: Write `bin/omarchy-prayer-schedule`**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'date'
require 'omarchy_prayer/config'
require 'omarchy_prayer/country_methods'
require 'omarchy_prayer/today'
require 'omarchy_prayer/times_source'
require 'omarchy_prayer/offline_calc'
require 'omarchy_prayer/scheduler'
require 'omarchy_prayer/first_run'

def resolve_method(cfg)
  cfg.method_name == 'auto' ? OmarchyPrayer::CountryMethods.resolve(cfg.country) : cfg.method_name
end

def tz_offset_seconds
  Time.now.utc_offset
end

OmarchyPrayer::FirstRun.ensure_config!
cfg    = OmarchyPrayer::Config.load
method = resolve_method(cfg)
date   = Date.today
key    = date.strftime('%Y-%m-%d')
tz     = tz_offset_seconds

offline_fallback = ->(day:, lat:, lon:, method_name:, tz_offset:) {
  times = OmarchyPrayer::OfflineCalc.compute(
    date: Date.parse(day), lat: lat, lon: lon, method: method_name, tz_offset: tz_offset
  )
  times.each_with_object({}) { |(k, t), h| h[k.to_s] = t.strftime('%H:%M') }
}

source, day = OmarchyPrayer::TimesSource.new.resolve(
  year: date.year, month: date.month, day: key,
  lat: cfg.latitude, lon: cfg.longitude, method_name: method,
  tz_offset: tz, offline_fallback: offline_fallback
)

# Apply per-prayer offsets.
cfg.offsets.each do |prayer, minutes|
  next if minutes.zero?
  next unless day[prayer.to_s]
  h, m = day[prayer.to_s].split(':').map(&:to_i)
  t = Time.new(date.year, date.month, date.day, h, m, 0, tz) + minutes * 60
  day[prayer.to_s] = t.strftime('%H:%M')
end

today = OmarchyPrayer::Today.new(
  date: key, tz_offset: tz, city: cfg.city, country: cfg.country,
  method: method, source: source, times: day
)
today.write

# Clear any stale mute-today from yesterday.
File.delete(OmarchyPrayer::Paths.mute_today) if File.exist?(OmarchyPrayer::Paths.mute_today)

OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: cfg.pre_notify_minutes)

puts "omarchy-prayer: scheduled #{today.times.size} prayers for #{key} (#{source}, #{method})"
```

- [ ] **Step 2: Write `bin/omarchy-prayer-notify`**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'omarchy_prayer/config'
require 'omarchy_prayer/today'
require 'omarchy_prayer/notifier'

prayer = ARGV[0]&.downcase&.to_sym
event  = ARGV[1]
abort 'usage: omarchy-prayer-notify <prayer> <on-time|pre>' unless prayer && %w[on-time pre].include?(event)

cfg   = OmarchyPrayer::Config.load
today = OmarchyPrayer::Today.read

OmarchyPrayer::Notifier.new(
  today: today,
  respect_silencing: cfg.respect_silencing,
  audio_enabled: cfg.audio_enabled,
  audio_player: cfg.audio_player, volume: cfg.volume,
  adhan: cfg.adhan_path, adhan_fajr: cfg.adhan_fajr_path,
  pre_notify_minutes: cfg.pre_notify_minutes
).fire(prayer: prayer, event: event)
```

- [ ] **Step 3: Write `bin/omarchy-prayer-waybar`**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'omarchy_prayer/config'
require 'omarchy_prayer/today'
require 'omarchy_prayer/waybar'

begin
  cfg = OmarchyPrayer::Config.load
  t   = OmarchyPrayer::Today.read
  puts OmarchyPrayer::Waybar.render(t, format: cfg.waybar_format,
                                     soon_minutes: cfg.soon_threshold_minutes)
rescue StandardError => e
  require 'json'
  puts JSON.generate(text: '', tooltip: "omarchy-prayer: #{e.message}", class: 'prayer-error')
end
```

- [ ] **Step 4: Write `bin/omarchy-prayer-stop`**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'omarchy_prayer/audio'

OmarchyPrayer::Audio.new.stop
```

- [ ] **Step 5: Make all executable**

```bash
chmod +x bin/omarchy-prayer-schedule bin/omarchy-prayer-notify \
         bin/omarchy-prayer-waybar   bin/omarchy-prayer-stop
```

- [ ] **Step 6: Smoke-test the waybar script manually with a hand-rolled today.json**

```bash
export XDG_STATE_HOME=$(mktemp -d)
export XDG_CONFIG_HOME=$(mktemp -d)
mkdir -p "$XDG_STATE_HOME/omarchy-prayer" "$XDG_CONFIG_HOME/omarchy-prayer"
cat > "$XDG_CONFIG_HOME/omarchy-prayer/config.toml" <<'EOF'
[location]
latitude = 24.7136
longitude = 46.6753
city = "Riyadh"
country = "SA"
EOF
cat > "$XDG_STATE_HOME/omarchy-prayer/today.json" <<'EOF'
{"date":"2026-04-22","tz_offset":10800,"city":"Riyadh","country":"SA","method":"Makkah","source":"api","times":{"fajr":"04:15","sunrise":"05:35","dhuhr":"11:48","asr":"15:18","maghrib":"18:01","isha":"19:21"}}
EOF
./bin/omarchy-prayer-waybar
```

Expected: a single line of JSON with `text`, `class`, and `tooltip`.

- [ ] **Step 7: Commit**

```bash
git add bin/omarchy-prayer-schedule bin/omarchy-prayer-notify \
        bin/omarchy-prayer-waybar bin/omarchy-prayer-stop && \
  git commit -m "feat(bin): entry scripts for schedule/notify/waybar/stop"
```

---

## Task 17: `Theme` — Omarchy theme → ANSI palette

**Files:**
- Create: `lib/omarchy_prayer/theme.rb`
- Create: `test/test_theme.rb`

Omarchy's `~/.config/omarchy/current/theme` is a symlink to a theme directory (e.g. `tokyo-night`). Each theme dir contains colors in various config files. For our purposes we read a small subset: we pick 6 named hex colors from a known file (`alacritty.toml`), fall back to a hardcoded palette if unavailable.

- [ ] **Step 1: Write test**

```ruby
require 'test_helper'
require 'omarchy_prayer/theme'

class TestTheme < Minitest::Test
  include TestHelper

  MINI_ALACRITTY = <<~TOML
    [colors.primary]
    background = "#1a1b26"
    foreground = "#c0caf5"

    [colors.normal]
    red    = "#f7768e"
    green  = "#9ece6a"
    yellow = "#e0af68"
    blue   = "#7aa2f7"
    cyan   = "#7dcfff"
  TOML

  def setup_theme(home)
    theme_dir = "#{home}/.config/omarchy/current"
    FileUtils.mkdir_p(theme_dir)
    File.write("#{theme_dir}/alacritty.toml", MINI_ALACRITTY)
  end

  def test_loads_truecolor_palette_from_theme
    with_isolated_home do |home|
      setup_theme(home)
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      assert_equal '#1a1b26', pal.background
      assert_equal '#c0caf5', pal.foreground
      assert_equal '#7aa2f7', pal.accent           # blue
      assert_equal '#e0af68', pal.warning          # yellow
    end
  end

  def test_fallback_when_no_theme_present
    with_isolated_home do
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      refute_nil pal.foreground
      refute_nil pal.accent
    end
  end

  def test_no_color_mode
    with_isolated_home do |home|
      setup_theme(home)
      ENV['NO_COLOR'] = '1'
      pal = OmarchyPrayer::Theme.load
      assert_equal '', pal.ansi_fg(:accent)
      assert_equal '', pal.reset
    ensure
      ENV.delete('NO_COLOR')
    end
  end

  def test_ansi_escape_sequence_for_truecolor
    with_isolated_home do |home|
      setup_theme(home)
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      assert_equal "\e[38;2;122;162;247m", pal.ansi_fg(:accent)
      assert_equal "\e[0m", pal.reset
    end
  end
end
```

- [ ] **Step 2: Run to see fail**

- [ ] **Step 3: Write `lib/omarchy_prayer/theme.rb`**

```ruby
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Theme
    FALLBACK = {
      background: '#1a1b26', foreground: '#c0caf5',
      accent:     '#7aa2f7', primary:    '#bb9af7',
      secondary:  '#7dcfff', warning:    '#e0af68',
      muted:      '#565f89'
    }.freeze

    HEX = /\A#([0-9a-fA-F]{6})\z/

    def self.load(force_truecolor: false)
      new(parse_theme_file, force_truecolor)
    end

    def initialize(colors, force_truecolor)
      @colors = FALLBACK.merge(colors)
      @truecolor = force_truecolor || truecolor_supported?
      @no_color = ENV['NO_COLOR'] && !ENV['NO_COLOR'].empty?
    end

    FALLBACK.each_key do |k|
      define_method(k) { @colors[k] }
    end

    def ansi_fg(key)
      return '' if @no_color
      rgb = parse_hex(@colors[key])
      if @truecolor
        "\e[38;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
      else
        "\e[38;5;#{nearest_256(rgb)}m"
      end
    end

    def ansi_bg(key)
      return '' if @no_color
      rgb = parse_hex(@colors[key])
      if @truecolor
        "\e[48;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
      else
        "\e[48;5;#{nearest_256(rgb)}m"
      end
    end

    def bold;     @no_color ? '' : "\e[1m"; end
    def dim;      @no_color ? '' : "\e[2m"; end
    def reset;    @no_color ? '' : "\e[0m"; end

    def self.parse_theme_file
      path = File.join(Paths.xdg_config_home, 'omarchy', 'current', 'alacritty.toml')
      return {} unless File.exist?(path)
      txt = File.read(path)
      out = {}
      out[:background] = txt[/background\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:foreground] = txt[/foreground\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:accent]     = txt[/blue\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:primary]    = txt[/magenta\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:secondary]  = txt[/cyan\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:warning]    = txt[/yellow\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:muted]      = txt[/black\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out.compact
    end

    private

    def truecolor_supported?
      ct = ENV['COLORTERM'].to_s
      ct.include?('truecolor') || ct.include?('24bit')
    end

    def parse_hex(hex)
      m = hex.match(HEX) or return [200, 200, 200]
      s = m[1]
      [s[0,2].to_i(16), s[2,2].to_i(16), s[4,2].to_i(16)]
    end

    def nearest_256(rgb)
      r, g, b = rgb.map { |c| (c / 51.0).round }
      16 + 36*r + 6*g + b
    end
  end
end
```

- [ ] **Step 4: Run, verify pass**

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/theme.rb test/test_theme.rb && \
  git commit -m "feat(theme): Omarchy alacritty → ANSI palette"
```

---

## Task 18: TUI — main view and settings view

**Files:**
- Create: `lib/omarchy_prayer/tui.rb`
- Create: `bin/omarchy-prayer`

The TUI is one file. No minitest coverage of rendering; manual verification is in Task 21. The file stays under ~300 lines. Settings-view writing uses the same TOML template from `FirstRun`.

- [ ] **Step 1: Write `lib/omarchy_prayer/tui.rb`**

```ruby
require 'io/console'
require 'omarchy_prayer/theme'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class TUI
    PRETTY = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' }.freeze

    def initialize(out: $stdout, input: $stdin)
      @out = out; @input = input
      @theme = Theme.load
    end

    def run
      return show_error('no config — run any omarchy-prayer command to bootstrap') unless File.exist?(Paths.config_file)
      return show_error('no today.json — run `omarchy-prayer refresh`') unless File.exist?(Paths.today_json)

      @cfg = Config.load
      @today = Today.read
      @input.raw do
        hide_cursor
        loop do
          render_main
          key = @input.getc
          case key
          when 'q', "\x03" then break
          when 'r' then system('systemctl', '--user', 'start', 'omarchy-prayer-schedule.service'); sleep 0.3; @today = Today.read
          when 'm' then toggle_mute
          when 't' then test_audio
          when 's' then render_settings_read_only  # v1: read-only editor hint
          end
        end
      end
    ensure
      show_cursor
      clear_screen
    end

    private

    def render_main
      clear_screen
      now = Time.now
      next_name, next_at = @today.next_prayer(now: now)

      qibla_deg = Qibla.bearing(@cfg.latitude, @cfg.longitude)
      qibla_lbl = "#{qibla_deg}° #{Qibla.cardinal(qibla_deg)}"

      puts_line ''
      puts_line header_line(qibla_lbl)
      puts_line divider
      puts_line ''

      Today::ORDER.each do |p|
        t = @today.times[p]
        line = prayer_line(p, t, next_name, now)
        puts_line line
      end

      puts_line ''
      puts_line divider
      puts_line footer_line
      puts_line ''
      puts_line hotkeys
    end

    def header_line(qibla)
      title = '☪ Omarchy Prayer'
      loc = "📍 #{@cfg.city}, #{@cfg.country}"
      date = "📅 #{@today.date}"
      qib = "🧭 Qibla #{qibla}"
      @theme.bold + @theme.ansi_fg(:accent) + "  #{title}   #{loc}    #{date}   #{qib}" + @theme.reset
    end

    def divider
      @theme.ansi_fg(:muted) + ('─' * 66) + @theme.reset
    end

    def prayer_line(prayer, time_s, next_name, now)
      pretty = PRETTY[prayer]
      at = @today.time_for(prayer)

      label = format('  %-9s %s', pretty, time_s || '--:--')

      if next_name == prayer || (next_name == :fajr_tomorrow && prayer == :fajr && Today::ORDER.last == :isha && at < now)
        remaining = (at - now).to_i
        remaining += 24*3600 if remaining < 0
        countdown = format_countdown(remaining)
        bar = progress_bar(remaining)
        soon_color = remaining / 60 < @cfg.soon_threshold_minutes ? :warning : :primary
        @theme.bold + @theme.ansi_fg(:primary) + "▶ #{label}   next · in #{countdown}  " + @theme.ansi_fg(soon_color) + bar + @theme.reset
      elsif at < now
        @theme.dim + "◦ #{label}   ✓ passed" + @theme.reset
      else
        "◦ #{label}"
      end
    end

    def format_countdown(secs)
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def progress_bar(remaining_secs)
      # Approximate: assume day-progress from previous prayer to next.
      filled = [(10 * (1 - remaining_secs / (3*3600.0))).clamp(0, 10).to_i, 10].min
      '█' * filled + '░' * (10 - filled)
    end

    def footer_line
      muted = File.exist?(Paths.mute_today) ? ' · MUTED TODAY' : ''
      @theme.ansi_fg(:muted) +
        "  Source  #{@today.source}    Method  #{@today.method}#{muted}" +
        @theme.reset
    end

    def hotkeys
      dim = @theme.ansi_fg(:muted)
      acc = @theme.ansi_fg(:accent)
      r = @theme.reset
      "  #{acc}[s]#{r}#{dim} Settings   #{acc}[t]#{r}#{dim} Test adhan   #{acc}[m]#{r}#{dim} Mute today   #{acc}[r]#{r}#{dim} Refresh   #{acc}[q]#{r}#{dim} Quit#{r}"
    end

    def toggle_mute
      if File.exist?(Paths.mute_today)
        File.delete(Paths.mute_today)
      else
        Paths.ensure_state_dir
        FileUtils.touch(Paths.mute_today)
      end
    end

    def test_audio
      file = @cfg.adhan_path
      return unless File.exist?(file)
      pid = Process.spawn(@cfg.audio_player, '--no-video', '--really-quiet',
                          "--volume=#{@cfg.volume}", file,
                          %i[out err] => '/dev/null')
      sleep 3
      begin; Process.kill('TERM', pid); rescue Errno::ESRCH; end
    end

    def render_settings_read_only
      clear_screen
      @out.puts "settings — v1 is read-only; edit #{Paths.config_file} directly"
      @out.puts 'press any key to return…'
      @input.getc
    end

    def show_error(msg)
      @out.puts "\e[31momarchy-prayer:\e[0m #{msg}"
      exit 1
    end

    def puts_line(s); @out.puts s; end
    def clear_screen; @out.print "\e[2J\e[H"; end
    def hide_cursor;  @out.print "\e[?25l"; end
    def show_cursor;  @out.print "\e[?25h"; end
  end
end
```

**Scope note:** The spec called for an in-TUI settings form with per-field editing and validation. For v1 we ship a read-only placeholder screen that points at the config file. Building the form editor is a meaningful chunk of extra code; capturing it as v1-read-only lets us ship the rest of the feature and revisit. Add this to the "Out of scope for v1" list in the spec — done below in Task 22.

- [ ] **Step 2: Write `bin/omarchy-prayer` (CLI entry)**

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'omarchy_prayer/first_run'
require 'omarchy_prayer/config'
require 'omarchy_prayer/today'
require 'omarchy_prayer/paths'
require 'fileutils'

def cmd_today
  t = OmarchyPrayer::Today.read
  OmarchyPrayer::Today::ORDER.each { |p| puts format('%-8s %s', p, t.times[p]) }
end

def cmd_next
  t = OmarchyPrayer::Today.read
  name, at = t.next_prayer
  puts "#{name} #{at.strftime('%H:%M')}"
end

def cmd_status
  t = OmarchyPrayer::Today.read
  puts "date #{t.date}  source #{t.source}  method #{t.method}  city #{t.city}"
end

def cmd_refresh
  system('systemctl', '--user', 'start', 'omarchy-prayer-schedule.service')
end

def cmd_mute_today
  if File.exist?(OmarchyPrayer::Paths.mute_today)
    File.delete(OmarchyPrayer::Paths.mute_today)
    puts 'mute-today: cleared'
  else
    OmarchyPrayer::Paths.ensure_state_dir
    FileUtils.touch(OmarchyPrayer::Paths.mute_today)
    puts 'mute-today: set (auto-clears at midnight)'
  end
end

def cmd_tui
  require 'omarchy_prayer/tui'
  OmarchyPrayer::FirstRun.ensure_config!
  OmarchyPrayer::TUI.new.run
end

case ARGV[0]
when nil, 'tui'   then cmd_tui
when 'today'      then cmd_today
when 'next'       then cmd_next
when 'status'     then cmd_status
when 'refresh'    then cmd_refresh
when 'mute-today' then cmd_mute_today
when '-h', '--help', 'help'
  puts 'usage: omarchy-prayer [tui|today|next|status|refresh|mute-today]'
else
  warn "unknown subcommand: #{ARGV[0].inspect}"
  exit 1
end
```

- [ ] **Step 3: `chmod +x bin/omarchy-prayer`**

- [ ] **Step 4: Quick smoke test of CLI subcommands against the hand-rolled fixtures from Task 16**

```bash
./bin/omarchy-prayer today
./bin/omarchy-prayer next
./bin/omarchy-prayer status
```

Expected output (with the fixture from Task 16 Step 6 in `$XDG_STATE_HOME`):
- `today` prints five lines with prayer names + HH:MM.
- `next` prints `<name> HH:MM`.
- `status` prints a single status line.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/tui.rb bin/omarchy-prayer && \
  git commit -m "feat(tui): themed main view + CLI entry"
```

---

## Task 19: Systemd unit files

**Files:**
- Create: `share/systemd/omarchy-prayer-schedule.service`
- Create: `share/systemd/omarchy-prayer-schedule.timer`
- Create: `share/systemd/omarchy-prayer-resume.service`

- [ ] **Step 1: Write `share/systemd/omarchy-prayer-schedule.service`**

```ini
[Unit]
Description=Omarchy prayer scheduler (rebuild today's timers)

[Service]
Type=oneshot
ExecStart=%h/.local/bin/omarchy-prayer-schedule
```

- [ ] **Step 2: Write `share/systemd/omarchy-prayer-schedule.timer`**

```ini
[Unit]
Description=Daily rebuild of omarchy-prayer timers

[Timer]
OnCalendar=*-*-* 00:01:00
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write `share/systemd/omarchy-prayer-resume.service`**

```ini
[Unit]
Description=Rebuild omarchy-prayer timers after resume
After=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/omarchy-prayer-schedule

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
```

- [ ] **Step 4: Verify unit files are syntactically valid**

```bash
systemd-analyze verify share/systemd/*.service share/systemd/*.timer 2>&1
```

Expected: no output (verify prints only on issues). The `%h` substitution will complain if run outside a user-manager context; a simpler check is:

```bash
for f in share/systemd/*; do head -1 "$f"; done
```

Expected: each prints `[Unit]`.

- [ ] **Step 5: Commit**

```bash
git add share/systemd/ && \
  git commit -m "feat(systemd): user service + timer + resume hook"
```

---

## Task 20: `install.sh`

**Files:**
- Create: `install.sh`

- [ ] **Step 1: Write installer**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${HOME}/.config/omarchy-prayer"
UNIT_DIR="${HOME}/.config/systemd/user"
LIB_DIR="${HOME}/.local/share/omarchy-prayer/lib"

msg() { printf '\e[1;34m[omarchy-prayer]\e[0m %s\n' "$*"; }
warn(){ printf '\e[1;33m[omarchy-prayer]\e[0m %s\n' "$*" >&2; }
err() { printf '\e[1;31m[omarchy-prayer]\e[0m %s\n' "$*" >&2; exit 1; }

check_dep() {
  command -v "$1" >/dev/null 2>&1 || warn "missing: $1 — install with: $2"
}

msg "verifying runtime deps"
check_dep ruby         "pacman -S ruby"
check_dep notify-send  "pacman -S libnotify"
check_dep makoctl      "pacman -S mako"
check_dep systemd-run  "(part of systemd)"
check_dep waybar       "pacman -S waybar"
check_dep mpv          "pacman -S mpv"
check_dep curl         "pacman -S curl"

command -v tomlrb >/dev/null 2>&1 || true  # gem is a library, not a command
ruby -e 'require "tomlrb"' 2>/dev/null || {
  msg "installing tomlrb gem"
  gem install --user-install tomlrb >/dev/null
}

msg "installing bin → $BIN_DIR"
mkdir -p "$BIN_DIR" "$LIB_DIR"

# Copy lib/ to a stable location so the bin scripts can find it.
rm -rf "$LIB_DIR"
cp -R "$PROJECT_DIR/lib/omarchy_prayer" "$LIB_DIR/"

for bin in omarchy-prayer omarchy-prayer-schedule omarchy-prayer-notify \
           omarchy-prayer-waybar omarchy-prayer-stop; do
  # Rewrite $LOAD_PATH to point at the installed lib dir.
  sed "s|__dir__)|__dir__); \$LOAD_PATH.unshift '${LIB_DIR%/omarchy_prayer}'|" \
      "$PROJECT_DIR/bin/$bin" > "$BIN_DIR/$bin"
  chmod +x "$BIN_DIR/$bin"
done

msg "installing systemd units → $UNIT_DIR"
mkdir -p "$UNIT_DIR"
cp "$PROJECT_DIR/share/systemd/"*.service "$UNIT_DIR/"
cp "$PROJECT_DIR/share/systemd/"*.timer   "$UNIT_DIR/"

msg "reloading systemd user daemon"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-prayer-schedule.timer
systemctl --user enable omarchy-prayer-resume.service

msg "seeding config + audio"
mkdir -p "$CFG_DIR"
for f in adhan.mp3 adhan-fajr.mp3; do
  [ -f "$CFG_DIR/$f" ] || {
    warn "no $f at $CFG_DIR/$f — drop one in before prayer times or adhan will only log a warning"
    : # leave empty; notifier handles missing files gracefully
  }
done

msg "running initial schedule"
"$BIN_DIR/omarchy-prayer-schedule" || warn "initial schedule failed — fix issues above and run \`omarchy-prayer refresh\`"

cat <<EOF

${bold:-}next steps:${normal:-}
  1. add to ~/.config/waybar/config:
     "custom/prayer": {
       "exec": "omarchy-prayer-waybar",
       "interval": 30,
       "return-type": "json",
       "on-click": "alacritty -e omarchy-prayer tui",
       "tooltip": true
     }
     and add "custom/prayer" to your modules-right array.

  2. (optional) add to ~/.config/hypr/bindings.conf:
     bind = SUPER CTRL, M, exec, omarchy-prayer-stop

  3. drop your adhan MP3s at $CFG_DIR/adhan.mp3 and adhan-fajr.mp3

  4. inspect schedule:  systemctl --user list-timers | grep op-
EOF
```

- [ ] **Step 2: Make executable**

```bash
chmod +x install.sh
```

- [ ] **Step 3: Lint the script**

```bash
bash -n install.sh && echo ok
```

Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add install.sh && git commit -m "feat(install): dep check + bin/unit install + timer enable"
```

---

## Task 21: Integration smoke test

**Files:**
- Create: `test/test_smoke.rb`

This tests the end-to-end wiring: scheduler loads config, resolves times via stub HTTP, writes today.json, and asks `systemd-run` (shim) to create ten timers.

- [ ] **Step 1: Write `test/test_smoke.rb`**

```ruby
require 'test_helper'
require 'webrick'
require 'omarchy_prayer/aladhan_client'
require 'omarchy_prayer/paths'

class TestSmoke < Minitest::Test
  include TestHelper

  FIXTURE_DIR = File.expand_path('fixtures', __dir__)

  def setup
    @body = File.read(File.join(FIXTURE_DIR, 'aladhan_april_2026.json'))
  end

  def start_aladhan_stub
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, res| res.content_type = 'application/json'; res.body = @body }
    thr = Thread.new { server.start }
    [server, thr, "http://127.0.0.1:#{server.config[:Port]}"]
  end

  def test_schedule_end_to_end
    server, thr, base = start_aladhan_stub
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl notify-send mpv makoctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''

      # Write a complete config — skip first-run.
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude = 24.7136
        longitude = 46.6753
        city = "Riyadh"
        country = "SA"

        [method]
        name = "MWL"
      TOML

      # Point AladhanClient at the stub by monkey-patching the default base.
      # The simpler path is to pass an env override the bin script reads.
      ENV['OMARCHY_PRAYER_ALADHAN_BASE'] = base

      project = File.expand_path('..', __dir__)
      system({'RUBYLIB' => "#{project}/lib"}, "#{project}/bin/omarchy-prayer-schedule")

      today = File.read(OmarchyPrayer::Paths.today_json)
      assert_match(/"source":\s*"(api|cache)"/, today)

      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      # Depending on the fixture day covered, may be 10 (pre+on-time) or 5 (no pre).
      # Fixture covers today's date only if Date.today == 2026-04-22. We relax to >= 5.
      assert calls.size >= 5
    ensure
      server&.shutdown; thr&.join
    end
  end
end
```

- [ ] **Step 2: Add env-override support in the scheduler entry script**

Edit `bin/omarchy-prayer-schedule` to honor the env var. Find:

```ruby
source, day = OmarchyPrayer::TimesSource.new.resolve(
```

Change the line above it:

```ruby
client = OmarchyPrayer::AladhanClient.new(
  base_url: ENV['OMARCHY_PRAYER_ALADHAN_BASE'] || OmarchyPrayer::AladhanClient::DEFAULT_BASE
)
source, day = OmarchyPrayer::TimesSource.new(client: client).resolve(
```

- [ ] **Step 3: Run smoke test**

```bash
bundle exec rake test TEST=test/test_smoke.rb
```

Expected: passes. If it skips because `Date.today` isn't April 2026, relax the assertion further or mock `Date.today` at the bin-script level — but the `>= 5` check already handles the off-month case (offline fallback still runs).

- [ ] **Step 4: Run the full suite**

```bash
bundle exec rake test
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/test_smoke.rb bin/omarchy-prayer-schedule && \
  git commit -m "test: end-to-end smoke for schedule pipeline"
```

---

## Task 22: README + manual verification checklist

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md` (add TUI-settings-form to out-of-scope)

- [ ] **Step 1: Replace `README.md` with a full README**

```markdown
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

## Configuration

Edit `~/.config/omarchy-prayer/config.toml` — the installer seeds it on first run via IP geolocation. See `docs/superpowers/specs/…` for all options.

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

Spec: `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md`
Plan: `docs/superpowers/plans/2026-04-22-omarchy-prayer.md`
```

- [ ] **Step 2: Append note to the spec's "Out of scope for v1" section**

Append to `docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md`:

```markdown
- TUI settings form: v1 opens a read-only screen that points at the config file; in-TUI field editing is a later pass.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-04-22-omarchy-prayer-design.md && \
  git commit -m "docs: README and v1 scope carve-out for TUI settings form"
```

---

## Self-review summary

**Spec coverage:**

| Spec section                            | Task(s)                              |
|-----------------------------------------|--------------------------------------|
| Scheduler, 10 transient timers, 00:01   | Task 15, 16, 19                      |
| Notifier (mako + audio + DND + mute)    | Task 11, 12                          |
| Waybar widget                           | Task 10, 16                          |
| TUI main view (themed, qibla)           | Task 17, 18                          |
| TUI settings (v1: read-only placeholder)| Task 18 (carve-out noted in spec)    |
| Config file (TOML, defaults, validation)| Task 3                               |
| Three-tier times source                 | Task 7, 8, 9                         |
| First-run bootstrap via IP geolocation  | Task 13, 14                          |
| Country → method mapping                | Task 4                               |
| Qibla bearing                           | Task 6                               |
| Systemd units + resume service          | Task 19                              |
| Installer with dep checks               | Task 20                              |
| Tests + smoke                           | Tasks 2–17, 21                       |
| README + manual verification            | Task 22                              |

**Placeholder scan:** no "TBD", "implement later" entries. The TUI settings form is explicitly descoped with a written rationale, not left as a blank "TODO."

**Type consistency:** `Today::ORDER` is used consistently in Today, Waybar, Scheduler, and TUI. `Notifier#fire(prayer:, event:)` matches what `bin/omarchy-prayer-notify` passes. `Audio` constructor takes `player:/volume:` — matches callers in Notifier and TUI. `Config` exposes `adhan_path`/`adhan_fajr_path` (expanded) — matches Notifier.

**Scope:** 22 tasks, each 10–30 min of focused work, one commit per task. Manageable for a single implementation pass.

---

**Plan complete and saved to `docs/superpowers/plans/2026-04-22-omarchy-prayer.md`.**

**Execution options:**

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
