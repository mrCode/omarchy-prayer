# Omarchy 4 Quickshell Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port omarchy-prayer's bar integration from waybar to a native Omarchy 4 Quickshell plugin, backed by a structured JSON status producer, and fix four compatibility breakages found in an end-to-end audit.

**Architecture:** Ruby remains the single source of truth for all prayer calculation. A new `Status` module emits structured JSON consumed by both the new QML bar widget and the existing waybar renderer. Setup detects which bar is present at runtime and installs the matching integration. The QML widget holds no domain logic — it substitutes placeholders and subtracts timestamps.

**Tech Stack:** Ruby 3.x + minitest + tomlrb; QML / Quickshell (Qt 6); systemd user units; Arch PKGBUILD.

## Global Constraints

- **Adhan audio ships muted by default.** `[audio].enabled` is `false`. Never introduce a default that plays audio.
- **Test isolation is mandatory.** Any test mutating `ENV`, module-level constants, or global state MUST restore it in `teardown` or via `with_isolated_home`. Failure to do this broke the v0.1.5 AUR `check()`.
- **`OmarchyPrayer::Waybar.render` output must remain byte-identical** to v0.1.7 for existing waybar users.
- **Never edit `/usr/share/omarchy/`.** Read it freely; write only to `~/.config/` and package-owned paths.
- Plugin ID is exactly `prayer.times`. Bar placement is exactly `{"section":"right","index":0}`.
- Target version: **0.2.0**.
- Run the full suite with `bundle exec rake test`.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `lib/omarchy_prayer/version.rb` | `OmarchyPrayer::VERSION` constant |
| `lib/omarchy_prayer/status.rb` | Structured status Hash — the one data source |
| `lib/omarchy_prayer/bar_detect.rb` | Runtime bar detection |
| `lib/omarchy_prayer/shell_plugin.rb` | Quickshell plugin install + enable |
| `share/omarchy-shell-plugin/manifest.json` | Plugin manifest |
| `share/omarchy-shell-plugin/BarWidget.qml` | Bar pill, process, timers, IPC |
| `share/omarchy-shell-plugin/Panel.qml` | Popup panel (layout B) |
| `share/omarchy-shell-plugin/Model.js` | Pure formatting helpers |
| `test/test_status.rb`, `test/test_bar_detect.rb`, `test/test_shell_plugin.rb` | Tests |

**Modify:** `lib/omarchy_prayer/theme.rb`, `notifier.rb`, `config.rb`, `migrations.rb`, `waybar.rb`, `setup.rb`, `bin/omarchy-prayer`, `bin/omarchy-prayer-schedule`, `install.sh`, `README.md`, and the AUR `PKGBUILD`.

---

### Task 1: Theme resolution for Omarchy 4

Omarchy 4 moved the current theme from `~/.config/omarchy/current/alacritty.toml` to `~/.local/state/omarchy/current/theme/alacritty.toml`. A path fix alone is **not sufficient**: `parse_theme_file` regexes the first `black =` in the file, which in the v4 theme is `[colors.normal].black = "#2d353b"` — identical to the background, so all muted text would render invisible. Replace the regex scan with a section-aware `Tomlrb` parse and take `muted` from `[colors.bright].black`.

**Files:**
- Modify: `lib/omarchy_prayer/theme.rb:52-66`
- Test: `test/test_theme.rb`

**Interfaces:**
- Produces: `Theme.theme_file_candidates → Array[String]`, `Theme.parse_theme_file → Hash[Symbol, String]`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_theme.rb`:

```ruby
  V4_ALACRITTY = <<~TOML
    [colors.primary]
    background = "#2d353b"
    foreground = "#d3c6aa"

    [colors.normal]
    black   = "#2d353b"
    red     = "#e67e80"
    green   = "#a7c080"
    yellow  = "#dbbc7f"
    blue    = "#7fbbb3"
    magenta = "#d699b6"
    cyan    = "#83c092"

    [colors.bright]
    black = "#475258"
  TOML

  def test_reads_omarchy4_state_path
    with_isolated_home do |home|
      dir = "#{home}/.local/state/omarchy/current/theme"
      FileUtils.mkdir_p(dir)
      File.write("#{dir}/alacritty.toml", V4_ALACRITTY)
      colors = OmarchyPrayer::Theme.parse_theme_file
      assert_equal '#2d353b', colors[:background]
      assert_equal '#7fbbb3', colors[:accent]
      assert_equal '#dbbc7f', colors[:warning]
    end
  end

  def test_muted_prefers_bright_black_over_normal_black
    with_isolated_home do |home|
      dir = "#{home}/.local/state/omarchy/current/theme"
      FileUtils.mkdir_p(dir)
      File.write("#{dir}/alacritty.toml", V4_ALACRITTY)
      colors = OmarchyPrayer::Theme.parse_theme_file
      assert_equal '#475258', colors[:muted],
                   'muted must not collapse to the background colour'
      refute_equal colors[:background], colors[:muted]
    end
  end

  def test_v4_state_path_wins_over_v3_config_path
    with_isolated_home do |home|
      v3 = "#{home}/.config/omarchy/current"
      FileUtils.mkdir_p(v3)
      File.write("#{v3}/alacritty.toml", MINI_ALACRITTY)
      v4 = "#{home}/.local/state/omarchy/current/theme"
      FileUtils.mkdir_p(v4)
      File.write("#{v4}/alacritty.toml", V4_ALACRITTY)
      assert_equal '#2d353b', OmarchyPrayer::Theme.parse_theme_file[:background]
    end
  end

  def test_returns_empty_when_no_theme_file_anywhere
    with_isolated_home do |_home|
      assert_empty OmarchyPrayer::Theme.parse_theme_file
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_theme.rb -n "/omarchy4|bright_black|v4_state|no_theme_file/"`
Expected: FAIL — v4 path not found, `colors[:background]` is nil.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/theme.rb`, add `require 'tomlrb'` at the top, then replace `self.parse_theme_file` (lines 52-66) with:

```ruby
    # Omarchy 4 moved the current theme under XDG state; Omarchy 3 kept it in
    # XDG config. Newest layout wins.
    def self.theme_file_candidates
      [
        File.join(Paths.xdg_state_home,  'omarchy', 'current', 'theme', 'alacritty.toml'),
        File.join(Paths.xdg_config_home, 'omarchy', 'current', 'alacritty.toml')
      ]
    end

    # Section-aware parse. A regex scan would match [colors.normal].black,
    # which in Omarchy 4 themes equals the background — rendering muted text
    # invisible. Bright black is the intended dim grey.
    def self.parse_theme_file
      path = theme_file_candidates.find { |p| File.exist?(p) }
      return {} unless path

      colors  = Tomlrb.load_file(path, symbolize_keys: false)['colors'] || {}
      primary = colors['primary'] || {}
      normal  = colors['normal']  || {}
      bright  = colors['bright']  || {}

      {
        background: primary['background'],
        foreground: primary['foreground'],
        accent:     normal['blue'],
        primary:    normal['magenta'],
        secondary:  normal['cyan'],
        warning:    normal['yellow'],
        muted:      bright['black'] || normal['black']
      }.select { |_, v| v.is_a?(String) && v.match?(HEX) }
    rescue StandardError
      {}
    end
```

- [ ] **Step 4: Run the full theme suite**

Run: `bundle exec ruby -Ilib -Itest test/test_theme.rb`
Expected: PASS, including the pre-existing v3 tests (`MINI_ALACRITTY` has no `[colors.bright]`, so `muted` falls back to `normal.black` = `#565f89`).

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/theme.rb test/test_theme.rb
git commit -m "fix(theme): resolve Omarchy 4 theme path and parse by section

Omarchy 4 moved the current theme to ~/.local/state/omarchy/current/theme/.
Also replaces the regex colour scan with a section-aware Tomlrb parse: the
old scan matched [colors.normal].black, which equals the background in v4
themes and would have rendered all muted text invisible."
```

---

### Task 2: Do-not-disturb probe via omarchy-shell

`makoctl mode` fails on Omarchy 4 (`No such object path '/fr/emersion/Mako'`), so `respect_silencing = true` silently became a no-op. Probe `omarchy-shell notifications isDnd` first, fall back to `makoctl`, and fire when neither answers — a probe failure must never silently suppress a prayer.

**Files:**
- Modify: `lib/omarchy_prayer/notifier.rb:46-49`
- Test: `test/test_notifier.rb`

**Interfaces:**
- Produces: `Notifier#dnd? → Boolean` (private, unchanged signature)

- [ ] **Step 1: Write the failing tests**

Add to `test/test_notifier.rb`:

```ruby
  def test_dnd_respected_via_omarchy_shell
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'on'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert_empty read_shim_log(log).select { |e| e[0] == 'notify-send' }
      assert_empty read_shim_log(log).select { |e| e[0] == 'mpv' }
    end
  end

  def test_fires_when_omarchy_shell_reports_dnd_off
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'off'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert read_shim_log(log).any? { |e| e[0] == 'notify-send' && e.include?('Dhuhr') }
    end
  end

  def test_omarchy_shell_takes_precedence_over_makoctl
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell makoctl mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'off'
      ENV['OP_SHIM_STDOUT_MAKOCTL']       = 'do-not-disturb'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert read_shim_log(log).any? { |e| e[0] == 'notify-send' },
             'live shell DND state must win over a stale mako'
    end
  end
```

Note: `with_shims` derives the stdout variable by uppercasing the command and replacing non-alphanumerics with `_`, so `omarchy-shell` reads `OP_SHIM_STDOUT_OMARCHY_SHELL`. `with_isolated_home` already restores `PATH` and `OP_SHIM_LOG`; add `OP_SHIM_STDOUT_OMARCHY_SHELL` cleanup by setting it only inside the block (ENV is restored by the helper's `ensure` for the listed keys — explicitly `ENV.delete` it at the end of each new test to avoid leaking into later tests).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_notifier.rb -n "/omarchy_shell/"`
Expected: FAIL — `test_dnd_respected_via_omarchy_shell` fires the notification because `isDnd` is never consulted.

- [ ] **Step 3: Implement**

Replace `dnd?` in `lib/omarchy_prayer/notifier.rb`:

```ruby
    # Omarchy 4 runs notifications inside omarchy-shell; Omarchy 3 used mako.
    # If neither answers we fire: a broken probe must never silently swallow
    # a prayer notification.
    def dnd?
      state = `omarchy-shell notifications isDnd 2>/dev/null`.strip
      return state == 'on' if %w[on off].include?(state)

      `makoctl mode 2>/dev/null`.strip.include?('do-not-disturb')
    rescue StandardError
      false
    end
```

- [ ] **Step 4: Run the full notifier suite**

Run: `bundle exec ruby -Ilib -Itest test/test_notifier.rb`
Expected: PASS. The pre-existing mako tests still pass — they shim only `makoctl`, so `omarchy-shell` is absent, the backtick yields `""`, and the mako branch runs.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/notifier.rb test/test_notifier.rb
git commit -m "fix(notifier): probe DND via omarchy-shell, fall back to makoctl

makoctl fails on Omarchy 4, which silently disabled respect_silencing."
```

---

### Task 3: Version constant

**Files:**
- Create: `lib/omarchy_prayer/version.rb`
- Test: `test/test_smoke.rb`

**Interfaces:**
- Produces: `OmarchyPrayer::VERSION → String` (used by Task 6 for the plugin `.version` marker)

- [ ] **Step 1: Write the failing test**

Add to `test/test_smoke.rb`:

```ruby
  def test_version_is_semver
    require 'omarchy_prayer/version'
    assert_match(/\A\d+\.\d+\.\d+\z/, OmarchyPrayer::VERSION)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_smoke.rb -n test_version_is_semver`
Expected: FAIL with `cannot load such file -- omarchy_prayer/version`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/version.rb`:

```ruby
module OmarchyPrayer
  VERSION = '0.2.0'.freeze
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_smoke.rb -n test_version_is_semver`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/version.rb test/test_smoke.rb
git commit -m "chore: add VERSION constant"
```

---

### Task 4: Config `[waybar]` → `[bar]` rename with migration

The section now drives both bar integrations, so it is renamed. Reading must tolerate unmigrated configs, and the migration rewrites the header in place.

**Files:**
- Modify: `lib/omarchy_prayer/config.rb:26,63-64`, `lib/omarchy_prayer/migrations.rb`
- Test: `test/test_config.rb`, `test/test_migrations.rb`

**Interfaces:**
- Produces: `Config#bar_format → String`, `Config#soon_threshold_minutes → Integer`, `Config#waybar_format → String` (deprecated alias for `bar_format`)
- Produces: `Migrations.rename_bar_section(io) → void`, marker `.migrated-bar-section-v1`

- [ ] **Step 1: Write the failing tests**

Add to `test/test_config.rb`:

```ruby
  def test_reads_bar_section
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.7, 'longitude' => 46.7 },
      'bar'      => { 'format' => '{prayer} {time}', 'soon_threshold_minutes' => 5 }
    )
    assert_equal '{prayer} {time}', cfg.bar_format
    assert_equal 5, cfg.soon_threshold_minutes
  end

  def test_falls_back_to_legacy_waybar_section
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.7, 'longitude' => 46.7 },
      'waybar'   => { 'format' => '{city} legacy', 'soon_threshold_minutes' => 7 }
    )
    assert_equal '{city} legacy', cfg.bar_format
    assert_equal 7, cfg.soon_threshold_minutes
  end

  def test_bar_section_wins_over_legacy_waybar_section
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.7, 'longitude' => 46.7 },
      'bar'      => { 'format' => 'new' },
      'waybar'   => { 'format' => 'old' }
    )
    assert_equal 'new', cfg.bar_format
  end

  def test_waybar_format_alias_still_works
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.7, 'longitude' => 46.7 },
      'bar'      => { 'format' => 'aliased' }
    )
    assert_equal 'aliased', cfg.waybar_format
  end
```

Add to `test/test_migrations.rb`:

```ruby
  def test_renames_waybar_section_to_bar
    with_isolated_home do |_home|
      OmarchyPrayer::Paths.ensure_config_dir
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude = 24.7
        longitude = 46.7

        [waybar]
        format = "{city} · {prayer} {countdown}"
        soon_threshold_minutes = 10
      TOML
      OmarchyPrayer::Migrations.run(io: StringIO.new)
      text = File.read(OmarchyPrayer::Paths.config_file)
      assert_includes text, '[bar]'
      refute_includes text, '[waybar]'
      assert_includes text, 'soon_threshold_minutes = 10'
    end
  end

  def test_bar_rename_is_idempotent
    with_isolated_home do |_home|
      OmarchyPrayer::Paths.ensure_config_dir
      File.write(OmarchyPrayer::Paths.config_file, "[bar]\nformat = \"x\"\n")
      2.times { OmarchyPrayer::Migrations.run(io: StringIO.new) }
      assert_equal "[bar]\nformat = \"x\"\n", File.read(OmarchyPrayer::Paths.config_file)
    end
  end
```

Add `require 'stringio'` at the top of `test/test_migrations.rb` if absent.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec ruby -Ilib -Itest test/test_config.rb -n "/bar_section|bar_format|waybar_format_alias/"`
Expected: FAIL with `NoMethodError: undefined method 'bar_format'`

- [ ] **Step 3: Implement the config side**

In `lib/omarchy_prayer/config.rb`, change the `DEFAULTS` key `'waybar'` to `'bar'`:

```ruby
      'bar'           => { 'format' => '{city} · {prayer} {countdown}', 'soon_threshold_minutes' => 10 }
```

Change `initialize` to normalize the legacy section before defaults are merged:

```ruby
    def initialize(raw)
      @raw = merge_defaults(normalize_bar_section(raw))
      validate!
    end
```

Replace the `waybar_format` / `soon_threshold_minutes` readers with:

```ruby
    def bar_format;             @raw['bar']['format'];                 end
    def soon_threshold_minutes; @raw['bar']['soon_threshold_minutes']; end

    # Retained so external callers and older bin scripts keep working.
    def waybar_format; bar_format; end
```

Add to the `private` section:

```ruby
    # An unmigrated config still has [waybar]. Promote it to [bar] before
    # defaults merge, so the user's values win rather than the defaults.
    def normalize_bar_section(raw)
      return raw unless raw.is_a?(Hash)
      return raw if raw.key?('bar') || !raw.key?('waybar')
      copy = raw.dup
      copy['bar'] = copy.delete('waybar')
      copy
    end
```

- [ ] **Step 4: Implement the migration**

In `lib/omarchy_prayer/migrations.rb`, replace the single-marker `run` with per-migration markers:

```ruby
    MARKER_FILENAME     = '.migrated-mute-default-v1'.freeze
    BAR_MARKER_FILENAME = '.migrated-bar-section-v1'.freeze

    module_function

    def marker_path
      File.join(Paths.state_dir, MARKER_FILENAME)
    end

    def bar_marker_path
      File.join(Paths.state_dir, BAR_MARKER_FILENAME)
    end

    def run(io: $stderr)
      unless File.exist?(marker_path)
        mute_audio_default(io)
        Paths.ensure_state_dir
        FileUtils.touch(marker_path)
      end

      unless File.exist?(bar_marker_path)
        rename_bar_section(io)
        Paths.ensure_state_dir
        FileUtils.touch(bar_marker_path)
      end
    rescue StandardError => e
      io.puts "omarchy-prayer: migration warning (#{e.class}: #{e.message})"
    end

    # [waybar] became [bar] in 0.2.0 — the section now drives both the waybar
    # module and the Omarchy 4 Quickshell widget.
    def rename_bar_section(io)
      path = Paths.config_file
      return unless File.exist?(path)
      text = File.read(path)
      new_text = text.sub(/^\s*\[waybar\]\s*$/, '[bar]')
      return if new_text == text
      File.write(path, new_text)
      io.puts 'omarchy-prayer: renamed [waybar] to [bar] in config.toml ' \
              '(it now configures both the waybar module and the Omarchy 4 widget).'
    end
```

- [ ] **Step 5: Run the tests**

Run: `bundle exec ruby -Ilib -Itest test/test_config.rb && bundle exec ruby -Ilib -Itest test/test_migrations.rb`
Expected: PASS, including all pre-existing tests.

- [ ] **Step 6: Update the first-run template**

In `lib/omarchy_prayer/first_run.rb`, change the `[waybar]` header in `TEMPLATE` to `[bar]`. Run `bundle exec ruby -Ilib -Itest test/test_bootstrap.rb` — expected PASS. Update any assertion there that greps for `[waybar]`.

- [ ] **Step 7: Commit**

```bash
git add lib/omarchy_prayer/config.rb lib/omarchy_prayer/migrations.rb lib/omarchy_prayer/first_run.rb test/
git commit -m "feat(config): rename [waybar] to [bar] with migration

The section now configures both the waybar module and the Omarchy 4
Quickshell widget. Reading falls back to [waybar] so unmigrated configs
never break."
```

---

### Task 5: `Status` module and `status --json`

The single structured data source for both bars.

**Files:**
- Create: `lib/omarchy_prayer/status.rb`, `test/test_status.rb`
- Modify: `bin/omarchy-prayer:48-54`

**Interfaces:**
- Produces: `Status.build(today:, config:, now: Time.now) → Hash` with string keys
- Produces: `Status.to_json(today:, config:, now: Time.now) → String`
- Consumes: `Today#time_for`, `Today#next_prayer`, `Qibla.bearing`, `Qibla.cardinal`, `Config#bar_format`

- [ ] **Step 1: Write the failing test**

Create `test/test_status.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/status'

class TestStatus < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-08-16', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'cache', hijri: '3 Rabīʿ al-awwal 1448',
      times: { fajr: '04:05', sunrise: '05:30', dhuhr: '11:57',
               asr: '15:26', maghrib: '18:27', isha: '19:57' }
    )
  end

  def config
    OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224,
                      'city' => 'Riyadh', 'country' => 'SA' },
      'bar'      => { 'format' => '{city} · {prayer} {countdown}',
                      'soon_threshold_minutes' => 10 }
    )
  end

  def test_shape_and_next_prayer
    now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
    s = OmarchyPrayer::Status.build(today: today, config: config, now: now)

    assert_equal 'Riyadh', s['city']
    assert_equal '2026-08-16', s['date']
    assert_equal '3 Rabīʿ al-awwal 1448', s['hijri']
    assert_equal 5, s['prayers'].length
    assert_equal %w[fajr dhuhr asr maghrib isha], s['prayers'].map { |p| p['name'] }
    assert_equal 'maghrib', s['next']['name']
    assert_equal 'Maghrib', s['next']['pretty']
    assert_equal '18:27', s['next']['time']
    assert_equal 'Makkah', s['method']
    assert_equal 'cache', s['source']
    assert_equal '{city} · {prayer} {countdown}', s['pill']['format']
    assert_equal 10, s['pill']['soon_threshold_minutes']
  end

  def test_passed_flags_track_now
    now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
    s = OmarchyPrayer::Status.build(today: today, config: config, now: now)
    by_name = s['prayers'].to_h { |p| [p['name'], p['passed']] }
    assert by_name['asr'],        'Asr at 15:26 has passed by 16:30'
    refute by_name['maghrib'],    'Maghrib at 18:27 has not passed'
  end

  def test_epoch_matches_wall_clock
    now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
    s = OmarchyPrayer::Status.build(today: today, config: config, now: now)
    maghrib = s['prayers'].find { |p| p['name'] == 'maghrib' }
    assert_equal Time.new(2026, 8, 16, 18, 27, 0, 10800).to_i, maghrib['epoch']
    assert_equal maghrib['epoch'], s['next']['epoch']
  end

  def test_after_isha_next_is_tomorrow_fajr
    now = Time.new(2026, 8, 16, 22, 0, 0, 10800)
    s = OmarchyPrayer::Status.build(today: today, config: config, now: now)
    assert_equal 'fajr_tomorrow', s['next']['name']
    assert_equal 'Fajr', s['next']['pretty']
    assert_equal Time.new(2026, 8, 17, 4, 5, 0, 10800).to_i, s['next']['epoch']
  end

  def test_qibla_included
    now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
    s = OmarchyPrayer::Status.build(today: today, config: config, now: now)
    assert_kind_of Integer, s['qibla']['degrees']
    assert_includes OmarchyPrayer::Qibla::CARDINALS, s['qibla']['compass']
  end

  def test_muted_reflects_marker
    with_isolated_home do |_home|
      now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
      refute OmarchyPrayer::Status.build(today: today, config: config, now: now)['muted']
      OmarchyPrayer::Paths.ensure_state_dir
      FileUtils.touch(OmarchyPrayer::Paths.mute_today)
      assert OmarchyPrayer::Status.build(today: today, config: config, now: now)['muted']
    end
  end

  def test_to_json_round_trips
    now = Time.new(2026, 8, 16, 16, 30, 0, 10800)
    parsed = JSON.parse(OmarchyPrayer::Status.to_json(today: today, config: config, now: now))
    assert_equal 'maghrib', parsed['next']['name']
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_status.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/status`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/status.rb`:

```ruby
require 'json'
require 'omarchy_prayer/today'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  # The single structured view of "what are today's prayer times, right now".
  # Both the waybar renderer and the Omarchy 4 Quickshell widget consume this,
  # so all calculation stays here in Ruby and never leaks into QML.
  module Status
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr', asr: 'Asr',
      maghrib: 'Maghrib', isha: 'Isha', fajr_tomorrow: 'Fajr'
    }.freeze

    module_function

    def build(today:, config:, now: Time.now)
      next_name, next_at = today.next_prayer(now: now)
      degrees = Qibla.bearing(config.latitude, config.longitude)

      {
        'city'    => config.city,
        'country' => config.country,
        'date'    => today.date,
        'hijri'   => today.hijri,
        'prayers' => Today::ORDER.map { |p| prayer_entry(today, p, now) },
        'next'    => {
          'name'   => next_name.to_s,
          'pretty' => PRETTY.fetch(next_name),
          'time'   => next_at.strftime('%H:%M'),
          'epoch'  => next_at.to_i
        },
        'qibla'   => { 'degrees' => degrees, 'compass' => Qibla.cardinal(degrees) },
        'method'  => today.method,
        'source'  => today.source,
        'muted'   => File.exist?(Paths.mute_today),
        'pill'    => {
          'format'                 => config.bar_format,
          'soon_threshold_minutes' => config.soon_threshold_minutes
        }
      }
    end

    def to_json(today:, config:, now: Time.now)
      JSON.generate(build(today: today, config: config, now: now))
    end

    def prayer_entry(today, prayer, now)
      at = today.time_for(prayer)
      {
        'name'   => prayer.to_s,
        'pretty' => PRETTY.fetch(prayer),
        'time'   => today.times[prayer],
        'epoch'  => at.to_i,
        'passed' => at <= now
      }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_status.rb`
Expected: PASS (8 runs, 0 failures)

- [ ] **Step 5: Wire up `status --json`**

In `bin/omarchy-prayer`, replace `cmd_status` (lines 48-54):

```ruby
def cmd_status(argv = [])
  ensure_today!
  t = OmarchyPrayer::Today.read

  if argv.include?('--json')
    require 'omarchy_prayer/config'
    require 'omarchy_prayer/status'
    puts OmarchyPrayer::Status.to_json(today: t, config: OmarchyPrayer::Config.load)
    return
  end

  line = "date #{t.date}  source #{t.source}  method #{t.method}  city #{t.city}"
  line += "  hijri #{t.hijri}" if t.hijri
  puts line
end
```

Change the dispatch line to `when 'status' then cmd_status(ARGV[1..] || [])`, and add `status [--json]` to the help text.

- [ ] **Step 6: Verify manually**

Run: `ruby -Ilib bin/omarchy-prayer status --json | ruby -rjson -e 'p JSON.parse(STDIN.read)["next"]'`
Expected: a Hash with `name`, `pretty`, `time`, `epoch`.

- [ ] **Step 7: Commit**

```bash
git add lib/omarchy_prayer/status.rb test/test_status.rb bin/omarchy-prayer
git commit -m "feat(status): structured JSON producer for bar integrations"
```

---

### Task 6: Render waybar output from `Status`

Collapse to one rendering path while keeping v0.1.7 output byte-identical.

**Files:**
- Modify: `lib/omarchy_prayer/waybar.rb`, `bin/omarchy-prayer-waybar`
- Test: `test/test_waybar.rb`

**Interfaces:**
- Produces: `Waybar.render_from_status(status, now: Time.now) → String` (JSON)
- Retains: `Waybar.render(today, now:, format:, soon_minutes:, city:) → String` — unchanged signature and output

- [ ] **Step 1: Write the failing test**

Add to `test/test_waybar.rb`:

```ruby
  def test_render_from_status_matches_render
    require 'omarchy_prayer/config'
    require 'omarchy_prayer/status'
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '{prayer} {countdown}', 'soon_threshold_minutes' => 10 }
    )
    status = OmarchyPrayer::Status.build(today: today, config: cfg, now: now)

    legacy = OmarchyPrayer::Waybar.render(today, now: now, city: 'Riyadh',
                                          format: '{prayer} {countdown}', soon_minutes: 10)
    assert_equal legacy, OmarchyPrayer::Waybar.render_from_status(status, now: now)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_waybar.rb -n test_render_from_status_matches_render`
Expected: FAIL with `NoMethodError: undefined method 'render_from_status'`

- [ ] **Step 3: Implement**

Rewrite the body of `lib/omarchy_prayer/waybar.rb` (keep the existing `PRETTY`, `format_countdown`):

```ruby
    # The one renderer. `render` builds the same minimal shape from loose args
    # so the historical signature keeps working and its output stays identical.
    def render_from_status(status, now: Time.now)
      nx   = status['next']
      secs = nx['epoch'] - now.to_i
      pill = status['pill']

      text = pill['format']
        .gsub('{city}',      status['city'].to_s)
        .gsub('{prayer}',    nx['pretty'])
        .gsub('{time}',      nx['time'])
        .gsub('{countdown}', format_countdown(secs))

      cls = secs / 60 < pill['soon_threshold_minutes'] ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(status))
    end

    def render(today, now: Time.now, format:, soon_minutes:, city:)
      name, at = today.next_prayer(now: now)
      status = {
        'city'    => city,
        'prayers' => Today::ORDER.map { |p| { 'pretty' => PRETTY[p], 'time' => today.times[p] } },
        'next'    => { 'pretty' => PRETTY.fetch(name), 'time' => at.strftime('%H:%M'), 'epoch' => at.to_i },
        'pill'    => { 'format' => format, 'soon_threshold_minutes' => soon_minutes }
      }
      render_from_status(status, now: now)
    end

    def build_tooltip(status)
      status['prayers'].map { |p| format('%-7s %s', p['pretty'], p['time']) }.join("\n")
    end
```

Delete the old `build_tooltip(today)` implementation. `format_countdown` is unchanged.

- [ ] **Step 4: Run the full waybar suite**

Run: `bundle exec ruby -Ilib -Itest test/test_waybar.rb`
Expected: PASS — every pre-existing assertion still holds, proving output is byte-identical.

- [ ] **Step 5: Point the binary at `Status`**

Rewrite `bin/omarchy-prayer-waybar`:

```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'omarchy_prayer/config'
require 'omarchy_prayer/today'
require 'omarchy_prayer/status'
require 'omarchy_prayer/waybar'

begin
  status = OmarchyPrayer::Status.build(
    today: OmarchyPrayer::Today.read, config: OmarchyPrayer::Config.load
  )
  puts OmarchyPrayer::Waybar.render_from_status(status)
rescue StandardError => e
  require 'json'
  puts JSON.generate(text: '', tooltip: "omarchy-prayer: #{e.message}", class: 'prayer-error')
end
```

- [ ] **Step 6: Verify manually**

Run: `ruby -Ilib bin/omarchy-prayer-waybar`
Expected: same JSON shape as before — `text`, `class`, `tooltip`.

- [ ] **Step 7: Commit**

```bash
git add lib/omarchy_prayer/waybar.rb bin/omarchy-prayer-waybar test/test_waybar.rb
git commit -m "refactor(waybar): render from Status so both bars share one path"
```

---

### Task 7: Bar detection

**Files:**
- Create: `lib/omarchy_prayer/bar_detect.rb`, `test/test_bar_detect.rb`

**Interfaces:**
- Produces: `BarDetect.detect → :quickshell | :waybar | :none`
- Produces: `BarDetect.waybar_config_path → String | nil`

- [ ] **Step 1: Write the failing test**

Create `test/test_bar_detect.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/bar_detect'

class TestBarDetect < Minitest::Test
  include TestHelper

  def test_none_when_no_bar_present
    with_isolated_home do |home|
      with_shims(home, [])                       # PATH now has only the empty shim dir prefix
      ENV['PATH'] = File.join(home, 'shims')     # drop system PATH so omarchy-shell is absent
      assert_equal :none, OmarchyPrayer::BarDetect.detect
    end
  end

  def test_waybar_when_config_present_and_no_shell
    with_isolated_home do |home|
      with_shims(home, [])
      ENV['PATH'] = File.join(home, 'shims')
      FileUtils.mkdir_p("#{home}/.config/waybar")
      File.write("#{home}/.config/waybar/config.jsonc", '{}')
      assert_equal :waybar, OmarchyPrayer::BarDetect.detect
    end
  end

  def test_quickshell_when_shell_pings_ok
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      ENV['PATH'] = "#{File.join(home, 'shims')}:#{ENV['PATH']}"
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'ok'
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_quickshell_wins_over_waybar_on_upgraded_machine
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      ENV['PATH'] = "#{File.join(home, 'shims')}:#{ENV['PATH']}"
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'ok'
      FileUtils.mkdir_p("#{home}/.config/waybar")
      File.write("#{home}/.config/waybar/config.jsonc", '{}')
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_detection_does_not_depend_on_shell_json
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      ENV['PATH'] = "#{File.join(home, 'shims')}:#{ENV['PATH']}"
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'ok'
      refute File.exist?("#{home}/.config/omarchy/shell.json"),
             'a stock Omarchy 4 install may have no shell.json'
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_detect.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/bar_detect`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/bar_detect.rb`:

```ruby
require 'omarchy_prayer/paths'

module OmarchyPrayer
  # Which status bar is this machine actually running?
  #
  # Omarchy 4 replaced waybar with a Quickshell shell. Machines upgraded from
  # Omarchy 3 keep the waybar binary and config as leftovers, so Quickshell is
  # checked first — the live bar is the correct integration target.
  module BarDetect
    SHELL_PACKAGE_DIR = '/usr/share/omarchy/shell'.freeze

    module_function

    def detect
      return :quickshell if quickshell?
      return :waybar     if waybar_config_path
      :none
    end

    # Deliberately does NOT test for ~/.config/omarchy/shell.json: that file is
    # optional, since the shell falls back to packaged defaults when the user
    # has never customised their bar.
    def quickshell?
      return false unless which('omarchy-shell')
      return true if `omarchy-shell shell ping 2>/dev/null`.strip == 'ok'

      # Shell installed but not running — e.g. setup invoked over SSH.
      Dir.exist?(SHELL_PACKAGE_DIR)
    rescue StandardError
      false
    end

    def waybar_config_path
      %w[config.jsonc config]
        .map { |name| File.join(Paths.xdg_config_home, 'waybar', name) }
        .find { |path| File.exist?(path) }
    end

    def which(cmd)
      ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
                 .any? { |dir| File.executable?(File.join(dir, cmd)) }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_detect.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/bar_detect.rb test/test_bar_detect.rb
git commit -m "feat(bar): detect Quickshell vs waybar at runtime"
```

---

### Task 8: Shell plugin install and enable

**Files:**
- Create: `lib/omarchy_prayer/shell_plugin.rb`, `test/test_shell_plugin.rb`

**Interfaces:**
- Consumes: `OmarchyPrayer::VERSION` (Task 3)
- Produces: `ShellPlugin::PLUGIN_ID = 'prayer.times'`
- Produces: `ShellPlugin.install!(io:, done:, version: VERSION) → void`
- Produces: `ShellPlugin.target_dir → String`, `ShellPlugin.installed_version → String | nil`

- [ ] **Step 1: Write the failing test**

Create `test/test_shell_plugin.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/shell_plugin'

class TestShellPlugin < Minitest::Test
  include TestHelper

  # Stand in for the packaged /usr/share/omarchy-prayer/shell-plugin directory.
  def fake_source(home)
    dir = File.join(home, 'pkg', 'shell-plugin')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.json'), '{"id":"prayer.times"}')
    File.write(File.join(dir, 'BarWidget.qml'), '// widget')
    dir
  end

  def test_installs_plugin_into_user_config
    with_isolated_home do |home|
      log = with_shims(home, %w[omarchy-shell])
      done = []
      OmarchyPrayer::ShellPlugin.stub(:source_dir, fake_source(home)) do
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done, version: '0.2.0')
      end

      target = File.join(home, '.config', 'omarchy', 'plugins', 'prayer.times')
      assert File.exist?(File.join(target, 'manifest.json'))
      assert File.exist?(File.join(target, 'BarWidget.qml'))
      assert_equal '0.2.0', File.read(File.join(target, '.version')).strip
      assert read_shim_log(log).any? { |e| e[0] == 'omarchy-shell' && e.include?('enablePlugin') }
    end
  end

  def test_second_run_does_not_recopy_or_reenable
    with_isolated_home do |home|
      src = fake_source(home)
      done1 = []
      done2 = []
      OmarchyPrayer::ShellPlugin.stub(:source_dir, src) do
        log = with_shims(home, %w[omarchy-shell])
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done1, version: '0.2.0')
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done2, version: '0.2.0')
        enables = read_shim_log(log).select { |e| e.include?('enablePlugin') }
        assert_equal 1, enables.length, 'must enable exactly once'
      end
      assert_empty done2, 'idempotent run should report no changes'
    end
  end

  def test_version_change_recopies_but_does_not_reenable
    with_isolated_home do |home|
      src = fake_source(home)
      OmarchyPrayer::ShellPlugin.stub(:source_dir, src) do
        log = with_shims(home, %w[omarchy-shell])
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: [], version: '0.2.0')
        done = []
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done, version: '0.3.0')
        assert_equal '0.3.0',
                     File.read(File.join(OmarchyPrayer::ShellPlugin.target_dir, '.version')).strip
        assert done.any? { |d| d.include?('0.3.0') }
        assert_equal 1, read_shim_log(log).count { |e| e.include?('enablePlugin') }
      end
    end
  end

  def test_user_removal_is_respected
    with_isolated_home do |home|
      src = fake_source(home)
      OmarchyPrayer::ShellPlugin.stub(:source_dir, src) do
        log = with_shims(home, %w[omarchy-shell])
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: [], version: '0.2.0')
        # User takes the widget off their bar; setup runs again.
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: [], version: '0.2.0')
        assert_equal 1, read_shim_log(log).count { |e| e.include?('enablePlugin') },
                     'setup must not force the widget back onto the bar'
      end
    end
  end

  def test_backs_up_existing_shell_json
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      FileUtils.mkdir_p(File.join(home, '.config', 'omarchy'))
      shell_json = File.join(home, '.config', 'omarchy', 'shell.json')
      File.write(shell_json, '{"bar":{}}')
      done = []
      OmarchyPrayer::ShellPlugin.stub(:source_dir, fake_source(home)) do
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done, version: '0.2.0')
      end
      backups = Dir[File.join(home, '.config', 'omarchy', 'shell.json.bak.omarchy-prayer-*')]
      assert_equal 1, backups.length
      assert_equal '{"bar":{}}', File.read(backups.first)
      assert done.any? { |d| d.include?('backed up') }
    end
  end

  def test_no_source_dir_is_a_noop
    with_isolated_home do |_home|
      done = []
      OmarchyPrayer::ShellPlugin.stub(:source_dir, nil) do
        OmarchyPrayer::ShellPlugin.install!(io: StringIO.new, done: done, version: '0.2.0')
      end
      assert_empty done
    end
  end
end
```

Add `require 'stringio'` to `test/test_helper.rb` if not already present.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_shell_plugin.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/shell_plugin`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/shell_plugin.rb`:

```ruby
require 'fileutils'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/version'

module OmarchyPrayer
  # Installs the Omarchy 4 Quickshell bar widget.
  #
  # The shell only scans ~/.config/omarchy/plugins/, so a pacman package cannot
  # own the live plugin files — we copy them out of the package at setup time.
  module ShellPlugin
    PLUGIN_ID   = 'prayer.times'.freeze
    PLACEMENT   = '{"section":"right","index":0}'.freeze
    ENABLED_MARKER = '.shell-plugin-enabled-v1'.freeze

    PACKAGED_SOURCE = '/usr/share/omarchy-prayer/shell-plugin'.freeze
    REPO_SOURCE     = File.expand_path('../../share/omarchy-shell-plugin', __dir__)

    module_function

    def source_dir
      [PACKAGED_SOURCE, REPO_SOURCE].find { |d| Dir.exist?(d) }
    end

    def target_dir
      File.join(Paths.xdg_config_home, 'omarchy', 'plugins', PLUGIN_ID)
    end

    def version_file;    File.join(target_dir, '.version');              end
    def enabled_marker;  File.join(Paths.state_dir, ENABLED_MARKER);     end
    def shell_json_path; File.join(Paths.xdg_config_home, 'omarchy', 'shell.json'); end

    def installed_version
      File.exist?(version_file) ? File.read(version_file).strip : nil
    end

    def install!(io:, done:, version: VERSION)
      src = source_dir
      unless src
        io.puts 'warning: shell plugin source not found — skipping bar widget'
        return
      end

      copy!(src, version, done) if installed_version != version
      enable!(io: io, done: done)
    rescue StandardError => e
      io.puts "warning: could not install shell plugin (#{e.message})"
    end

    def copy!(src, version, done)
      FileUtils.mkdir_p(File.dirname(target_dir))
      FileUtils.rm_rf(target_dir)
      FileUtils.cp_r(src, target_dir)
      File.write(version_file, version)
      done << "installed #{PLUGIN_ID} shell plugin (#{version})"
    end

    # Placement happens exactly once. If the user later takes the widget off
    # their bar, re-running setup keeps the files current but respects that.
    def enable!(io:, done:)
      return if File.exist?(enabled_marker)

      backup_shell_json(done)
      ok = system('omarchy-shell', 'shell', 'enablePlugin', PLUGIN_ID, PLACEMENT,
                  out: File::NULL, err: File::NULL)
      Paths.ensure_state_dir
      FileUtils.touch(enabled_marker)

      done << if ok
                "added #{PLUGIN_ID} to your bar"
              else
                "could not place #{PLUGIN_ID} automatically — add it with " \
                "`omarchy-shell shell enablePlugin #{PLUGIN_ID} '#{PLACEMENT}'`"
              end
    end

    def backup_shell_json(done)
      path = shell_json_path
      return unless File.exist?(path)
      backup = "#{path}.bak.omarchy-prayer-#{Time.now.to_i}"
      FileUtils.cp(path, backup)
      done << "backed up shell.json → #{backup}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_shell_plugin.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/shell_plugin.rb test/test_shell_plugin.rb
git commit -m "feat(shell): install and place the Quickshell bar widget

Enable happens once only, so removing the widget from the bar sticks."
```

---

### Task 9: Setup dispatches on the detected bar

Also fixes the dishonest "already set up" message, which claimed a waybar widget on machines that have no waybar.

**Files:**
- Modify: `lib/omarchy_prayer/setup.rb:40-45,86-104`, `bin/omarchy-prayer` (`cmd_setup`)
- Test: `test/test_setup.rb`

**Interfaces:**
- Consumes: `BarDetect.detect`, `ShellPlugin.install!`
- Produces: `Setup.ensure_bar_integration(io:, done:) → void`

- [ ] **Step 1: Write the failing test**

Add to `test/test_setup.rb`:

```ruby
  def test_bar_integration_installs_shell_plugin_on_quickshell
    with_isolated_home do |home|
      log = with_shims(home, %w[omarchy-shell])
      ENV['PATH'] = "#{File.join(home, 'shims')}:#{ENV['PATH']}"
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'ok'
      done = []
      OmarchyPrayer::Setup.ensure_bar_integration(io: StringIO.new, done: done)
      assert done.any? { |d| d.include?('prayer.times') },
             "expected shell plugin work, got: #{done.inspect}"
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_bar_integration_reports_when_no_bar_present
    with_isolated_home do |home|
      with_shims(home, [])
      ENV['PATH'] = File.join(home, 'shims')
      done = []
      OmarchyPrayer::Setup.ensure_bar_integration(io: StringIO.new, done: done)
      assert done.any? { |d| d.match?(/no supported bar/i) },
             "setup must say so rather than claim a widget: #{done.inspect}"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_setup.rb -n "/bar_integration/"`
Expected: FAIL with `NoMethodError: undefined method 'ensure_bar_integration'`

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/setup.rb`, add requires at the top:

```ruby
require 'omarchy_prayer/bar_detect'
require 'omarchy_prayer/shell_plugin'
```

Replace the `ensure_waybar_module` call in `run` with `ensure_bar_integration`:

```ruby
    def run(io: $stdout, skip_network: false)
      done = []
      ensure_default_adhans(io: io, skip_network: skip_network, done: done)
      ensure_bar_integration(io: io, done: done)
      ensure_systemd_units(io: io, done: done)
      done
    end
```

Add above `ensure_waybar_module` (which stays exactly as-is for waybar users):

```ruby
    # --- bar integration ----------------------------------------------------

    # Omarchy 4 runs a Quickshell bar; Omarchy 3 and other Hyprland setups run
    # waybar. Install whichever is actually present, and say so honestly when
    # neither is.
    def ensure_bar_integration(io:, done:)
      case BarDetect.detect
      when :quickshell then ShellPlugin.install!(io: io, done: done)
      when :waybar     then ensure_waybar_module(io: io, done: done)
      else
        done << 'no supported bar detected (neither Omarchy shell nor waybar) — skipped bar widget'
      end
    end
```

- [ ] **Step 4: Fix the setup summary message**

In `bin/omarchy-prayer`, find `cmd_setup` and replace the hardcoded summary. It currently prints `already set up (adhan audio, waybar widget, systemd timer)` regardless of what happened. Replace with:

```ruby
def cmd_setup
  require 'omarchy_prayer/setup'
  done = OmarchyPrayer::Setup.run
  if done.empty?
    puts 'omarchy-prayer: already set up — nothing to do.'
  else
    done.each { |d| puts "omarchy-prayer: #{d}" }
  end
end
```

- [ ] **Step 5: Run the setup suite**

Run: `bundle exec ruby -Ilib -Itest test/test_setup.rb`
Expected: PASS, including the pre-existing waybar-patching tests.

- [ ] **Step 6: Commit**

```bash
git add lib/omarchy_prayer/setup.rb bin/omarchy-prayer test/test_setup.rb
git commit -m "feat(setup): dispatch bar integration on detected bar

Also stops claiming a waybar widget on machines that have no waybar."
```

---

### Task 10: The Quickshell plugin

**Read before writing.** These are the reference implementations; follow their structure rather than inventing an API:

- `/usr/share/omarchy/shell/plugins/bar/widgets/SystemUpdate.qml` — `Process` + `Timer` + `IpcHandler` in a bar widget
- `/usr/share/omarchy/shell/plugins/panels/clock/BarWidget.qml` — text pill, `setting()`, `vertical` handling, click routing
- `/usr/share/omarchy/shell/plugins/panels/weather/BarWidget.qml` and `Panel.qml` — hosting a popup panel from a pill (`panelLoader`, `injectPanel`, `opened`/`open`/`close` contract)
- `/usr/share/omarchy/shell/plugins/panels/weather/manifest.json` — manifest shape

**Files:**
- Create: `share/omarchy-shell-plugin/manifest.json`, `Model.js`, `BarWidget.qml`, `Panel.qml`

- [ ] **Step 1: Write the manifest**

Create `share/omarchy-shell-plugin/manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "prayer.times",
  "name": "Prayer times",
  "version": "0.2.0",
  "author": "omarchy-prayer",
  "description": "Next prayer countdown with a times panel",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Prayer times",
    "description": "Next prayer countdown with a times panel",
    "category": "Info",
    "allowMultiple": false
  }
}
```

- [ ] **Step 2: Write the pure helpers**

Create `share/omarchy-shell-plugin/Model.js`. This file holds no Qt types so its logic stays trivially checkable:

```javascript
.pragma library

// Seconds -> "1h 57m" / "8m". Never negative.
function formatCountdown(secs) {
  if (!isFinite(secs) || secs < 0) secs = 0
  var h = Math.floor(secs / 3600)
  var m = Math.floor((secs % 3600) / 60)
  return h > 0 ? (h + "h " + m + "m") : (m + "m")
}

// Substitute the pill placeholders. Countdown is recomputed every tick, so
// this runs often — keep it allocation-light and side-effect free.
function renderPill(format, city, prayer, time, countdown) {
  return String(format || "")
    .replace(/\{city\}/g, city || "")
    .replace(/\{prayer\}/g, prayer || "")
    .replace(/\{time\}/g, time || "")
    .replace(/\{countdown\}/g, countdown || "")
}

function secondsUntil(epochSeconds, nowMs) {
  return Math.floor(epochSeconds - (nowMs / 1000))
}

function isSoon(secs, thresholdMinutes) {
  return Math.floor(secs / 60) < (thresholdMinutes === undefined ? 10 : thresholdMinutes)
}

// Row label for the panel: "passed", the live countdown for the next prayer,
// or blank for prayers still ahead today.
function rowTag(prayer, nextName, countdown) {
  if (prayer.name === nextName) return countdown
  return prayer.passed ? "passed" : ""
}
```

- [ ] **Step 3: Write the bar widget**

Create `share/omarchy-shell-plugin/BarWidget.qml`. Model the panel hosting on `weather/BarWidget.qml` — read it first and mirror its `panelLoader` / `injectPanel` / `opened` / `open` / `close` contract exactly, since the bar's popout routing depends on that shape.

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Next-prayer pill. All prayer calculation lives in Ruby; this widget only
// substitutes placeholders and subtracts timestamps.
BarWidget {
  id: root
  moduleName: "prayer.times"

  property var data: null           // parsed status JSON, or null when unavailable
  property string errorText: ""
  property int secsRemaining: 0

  readonly property bool ready: data !== null && data.next !== undefined
  readonly property string countdown: Model.formatCountdown(secsRemaining)

  readonly property string pillText: ready
    ? Model.renderPill(data.pill.format, data.city, data.next.pretty, data.next.time, countdown)
    : "—"

  readonly property bool soon: ready && Model.isSoon(secsRemaining, data.pill.soon_threshold_minutes)

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function recomputeCountdown() {
    if (!ready) return
    secsRemaining = Model.secondsUntil(data.next.epoch, Date.now())
    // The next prayer has arrived — pull fresh data instead of counting past it.
    if (secsRemaining <= 0) refresh()
  }

  function stopAdhan() { if (root.bar) root.bar.run("omarchy-prayer-stop") }
  function muteToday() { root.bar.run("omarchy-prayer mute-today"); refresh() }
  function openTui()   { root.bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-prayer") }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "prayer.times"
    function refresh(): void { root.refresh() }
  }

  Process {
    id: statusProc
    command: ["omarchy-prayer", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.data = JSON.parse(this.text)
          root.errorText = ""
          root.recomputeCountdown()
        } catch (e) {
          root.data = null
          root.errorText = "omarchy-prayer: unreadable status output"
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.data = null
        root.errorText = "omarchy-prayer exited " + exitCode + " — is it set up?"
      }
    }
  }

  // Data changes only at rollover, relocate or mute; the schedule unit pokes
  // us via IPC for the rest.
  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Countdown ticks locally — no subprocess per second.
  Timer {
    interval: 1000
    running: root.ready
    repeat: true
    onTriggered: root.recomputeCountdown()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.glyph : (root.glyph + "  " + root.pillText)
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.errorText !== "" ? root.errorText : "Prayer times"
    opacity: (root.ready && root.data.muted) ? 0.5 : 1.0
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onPressed: function(mouse) {
      if (mouse.button === Qt.RightButton)       root.stopAdhan()
      else if (mouse.button === Qt.MiddleButton) root.openTui()
      else                                       root.togglePanel()
    }
  }
}
```

Two additions to `root` that the block above depends on. Opening the panel always
pulls fresh data first — a panel showing stale times is worse than a brief flicker:

```qml
  // Nerd Font mosque glyph. Confirm it renders in your bar's font before
  // committing; if it shows as a box, pick another and check the font with:
  //   fc-list | grep -i nerd
  readonly property string glyph: ""

  function togglePanel() {
    root.refresh()
    if (panelLoader.item) panelLoader.item.toggle()
  }
```


- [ ] **Step 4: Write the panel**

Create `share/omarchy-shell-plugin/Panel.qml` implementing layout B. Read `/usr/share/omarchy/shell/plugins/panels/weather/Panel.qml` first and reuse its `PanelController` wiring, anchoring and open/close semantics. Contents, top to bottom:

1. Header — `data.city + ", " + data.country`, then `data.date` and `data.hijri` in muted text
2. A `Repeater` over `data.prayers`, each row: status dot, `pretty`, `time`, and `Model.rowTag(prayer, data.next.name, root.countdown)`. Highlight the row where `prayer.name === data.next.name` with the accent colour and a filled dot.
3. Footer — `"Qibla " + data.qibla.degrees + "° " + data.qibla.compass` on the left, `data.method + " · " + data.source` on the right
4. Two `PanelActionButton`s — "Mute today" calling `hostWidget.muteToday()`, "Stop adhan" calling `hostWidget.stopAdhan()`

The panel reads its data through `hostWidget` (injected by `injectPanel()` in the bar widget), so reference `hostWidget.data` and `hostWidget.countdown` — **not** a local `root.data`. The row tag call is therefore `Model.rowTag(prayer, hostWidget.data.next.name, hostWidget.countdown)`.

This step deliberately specifies structure rather than complete QML: `PanelController`'s anchoring and open/close contract must be copied from the weather panel as it exists on this machine, not reproduced from memory. Read that file first.

Take every colour from the shell theme singleton used by the reference panels — never hardcode hex values, or the widget will not follow theme switches.

- [ ] **Step 5: Install and verify visually**

```bash
mkdir -p ~/.config/omarchy/plugins/prayer.times
cp share/omarchy-shell-plugin/* ~/.config/omarchy/plugins/prayer.times/
omarchy-shell shell rescanPlugins
omarchy-shell shell enablePlugin prayer.times '{"section":"right","index":0}'
```

Verify each of these before proceeding:
- Pill shows city, next prayer and a countdown that decrements every second
- Left click opens the panel; the next prayer's row is highlighted; qibla and method appear
- Right click stops a playing adhan; middle click opens the TUI
- `omarchy-shell -q prayer.times refresh` updates the pill
- Pill dims after `omarchy-prayer mute-today`
- Renaming `~/.config/omarchy-prayer/config.toml` aside makes the pill show `—` with the error in its tooltip, and does not spin the CPU
- Switching themes (`omarchy theme set catppuccin`) restyles the widget

- [ ] **Step 6: Commit**

```bash
git add share/omarchy-shell-plugin
git commit -m "feat(shell): Quickshell bar widget with prayer times panel"
```

---

### Task 11: Push refreshes from the scheduler

**Files:**
- Modify: `bin/omarchy-prayer-schedule`

- [ ] **Step 1: Implement**

At the end of the successful scheduling path in `bin/omarchy-prayer-schedule`, immediately after the `scheduled N prayers` message, add:

```ruby
# Best-effort nudge so the Omarchy 4 bar widget picks up new times at once
# rather than waiting out its poll. `-q` makes this a no-op when the shell
# isn't running.
system('omarchy-shell', '-q', 'prayer.times', 'refresh',
       out: File::NULL, err: File::NULL)
```

- [ ] **Step 2: Verify it does not break scheduling**

Run: `bundle exec ruby -Ilib -Itest test/test_scheduler.rb`
Expected: PASS. If the scheduler tests assert on the shim log, add `omarchy-shell` to their shim list.

- [ ] **Step 3: Verify manually**

Run: `ruby -Ilib bin/omarchy-prayer-schedule && echo ok`
Expected: `scheduled 5 prayers …` then `ok`, with no error even when the shell is absent.

- [ ] **Step 4: Commit**

```bash
git add bin/omarchy-prayer-schedule
git commit -m "feat(schedule): poke the shell widget after rebuilding timers"
```

---

### Task 12: Packaging and docs

**Files:**
- Modify: `install.sh:18-26`, `README.md`, and the AUR `PKGBUILD` at `~/.cache/yay/omarchy-prayer/PKGBUILD`

- [ ] **Step 1: Update `install.sh` dependency checks**

Replace the fixed `check_dep waybar` / `check_dep makoctl` lines with bar-aware checks:

```bash
msg "verifying runtime deps"
check_dep ruby        "pacman -S ruby"
check_dep notify-send "pacman -S libnotify"
check_dep systemd-run "(part of systemd)"
check_dep mpv         "pacman -S mpv"
check_dep curl        "pacman -S curl"

if command -v omarchy-shell >/dev/null 2>&1; then
  msg "detected Omarchy shell — the prayer widget installs as a Quickshell plugin"
else
  check_dep waybar  "pacman -S waybar"
  check_dep makoctl "pacman -S mako"
fi
```

- [ ] **Step 2: Install the plugin from `install.sh`**

Add alongside the existing `lib` install, so source installs get the widget too:

```bash
PLUGIN_SRC="$PROJECT_DIR/share/omarchy-shell-plugin"
PLUGIN_DEST="${HOME}/.local/share/omarchy-prayer/shell-plugin"
if [ -d "$PLUGIN_SRC" ]; then
  msg "installing shell plugin → $PLUGIN_DEST"
  rm -rf "$PLUGIN_DEST"
  mkdir -p "$(dirname "$PLUGIN_DEST")"
  cp -r "$PLUGIN_SRC" "$PLUGIN_DEST"
fi
```

Then teach `ShellPlugin.source_dir` about that location, so source installs resolve it. In `lib/omarchy_prayer/shell_plugin.rb`:

```ruby
    def source_dir
      [PACKAGED_SOURCE,
       File.join(Paths.home, '.local/share/omarchy-prayer/shell-plugin'),
       REPO_SOURCE].find { |d| Dir.exist?(d) }
    end
```

The packaged path still wins, so a pacman install is never shadowed by a stale source copy.

- [ ] **Step 3: Update the PKGBUILD**

At `~/.cache/yay/omarchy-prayer/PKGBUILD`:

```bash
pkgver=0.2.0
pkgrel=1
pkgdesc="Muslim prayer-time notifier for Omarchy: adhan + notifications, Quickshell/waybar countdown widget, themed TUI, qibla, hijri, adhan catalog"
depends=('ruby' 'ruby-tomlrb' 'ruby-racc' 'libnotify' 'mpv' 'curl' 'systemd')
optdepends=('waybar: bar widget on Omarchy 3 and other Hyprland setups'
            'mako: notification daemon on Omarchy 3 and other Hyprland setups'
            'hyprland: reference window manager')
```

In `package()`, install the plugin:

```bash
  install -dm755 "${pkgdir}/usr/share/${pkgname}/shell-plugin"
  cp -r share/omarchy-shell-plugin/. "${pkgdir}/usr/share/${pkgname}/shell-plugin/"
```

Regenerate `sha256sums` with `updpkgsums` after the release tarball exists.

- [ ] **Step 4: Update the README**

- Change the tagline from `(Hyprland + mako + waybar)` to note Omarchy 4 Quickshell support with waybar as the fallback
- Add an "Omarchy 4 bar widget" section describing the auto-install, the `prayer.times` plugin ID, and the manual `omarchy-shell shell enablePlugin` fallback
- Document the click bindings: left opens the panel, right stops the adhan, middle opens the TUI
- Rename the `[waybar]` config block to `[bar]` and note that it configures both bars, mentioning the automatic migration
- Keep the existing waybar instructions under an "Omarchy 3 / other Hyprland setups" heading

- [ ] **Step 5: Run the whole suite**

Run: `bundle exec rake test`
Expected: PASS — all pre-existing tests plus roughly 25 new ones, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add install.sh README.md
git commit -m "chore(pkg): make waybar/mako optional, ship the shell plugin

Omarchy 4 uses neither; both stay available for Omarchy 3 and other
Hyprland setups."
```

---

## Verification before release

- [ ] `bundle exec rake test` — full suite green
- [ ] `omarchy-prayer status --json | jq .` — valid, complete structure
- [ ] `omarchy-prayer-waybar` — output unchanged from v0.1.7
- [ ] Fresh-install simulation: move `~/.config/omarchy-prayer` and `~/.config/omarchy/plugins/prayer.times` aside, run `omarchy-prayer`, confirm the widget appears on the bar and the summary text is accurate
- [ ] Remove the widget from the bar, re-run `omarchy-prayer setup`, confirm it is **not** re-added
- [ ] `omarchy-shell notifications setDnd true` then trigger a notification — confirm suppression; set back to false
- [ ] TUI colours match the active theme (they did not before Task 1)
- [ ] Update `docs/superpowers/PROGRESS.md` and release per the standard flow: merge → tag `v0.2.0` → push GitHub → bump PKGBUILD → push AUR → `yay -S omarchy-prayer`
