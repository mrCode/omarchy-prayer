# Bar Pill Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose the bar pill's design from the panel or the CLI, with Arabic prayer names, a compact countdown, and a quiet-until-near mode.

**Architecture:** A preset is a named format string; the active name is derived by matching the stored `format` against the catalogue, never persisted. Ruby resolves policy into the `pill` object of `status --json`; QML substitutes placeholders and applies compact/collapse rules per tick, as it already does for the countdown.

**Tech Stack:** Ruby 3.x + minitest + tomlrb; QML / Quickshell (Qt 6); Arch PKGBUILD.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-17-bar-presets-design.md`. Read it before starting.
- **Presets shipped: `full`, `minimal`, `icon` only.** No `clock` preset, no standalone glyph toggle — both were considered and dropped.
- **There is no `preset` config key.** The active preset is always derived from `format`.
- **Arabic localises prayer names only** — pill and panel. Row tags, buttons, footer, notifications and the TUI stay English.
- **Waybar ignores `quiet_until_minutes`** (it has no glyph to collapse to) but honours preset and `compact_countdown`.
- **Adhan audio ships muted by default.** Never change `[audio].enabled` defaults.
- **No `.stub` in tests** — `minitest/mock` is unavailable when the AUR `check()` runs outside bundler. Inject dependencies instead.
- Any test mutating `ENV` or module constants restores it (`with_isolated_home` handles env).
- **Verify CLI-backed widget behaviour through `PATH`** (`bash -lc "omarchy-prayer …"`), never `ruby -Ilib` — the widget runs the installed binary.
- Run both: `bundle exec rake test` **and** `ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'`.
- Target version: **0.3.0**.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `lib/omarchy_prayer/bar_preset.rb` | Preset catalogue; format ↔ name mapping |
| `lib/omarchy_prayer/prayer_names.rb` | Latin/Arabic prayer-name table |
| `lib/omarchy_prayer/bar_setting.rb` | Section-aware writes of `[bar]` keys in config.toml |
| `test/test_bar_preset.rb`, `test/test_prayer_names.rb`, `test/test_bar_setting.rb` | Tests |

**Modify:** `lib/omarchy_prayer/config.rb`, `status.rb`, `waybar.rb`, `bin/omarchy-prayer`, `share/omarchy-shell-plugin/{Model.js,BarWidget.qml,Panel.qml,manifest.json}`, `lib/omarchy_prayer/version.rb`, `README.md`, and the AUR `PKGBUILD`.

---

### Task 1: Preset catalogue

**Files:**
- Create: `lib/omarchy_prayer/bar_preset.rb`, `test/test_bar_preset.rb`

**Interfaces:**
- Produces: `BarPreset::PRESETS → Hash[String, String]`, `BarPreset.names → Array[String]`, `BarPreset.format_for(name) → String | nil`, `BarPreset.name_for(format) → String`

- [ ] **Step 1: Write the failing test**

Create `test/test_bar_preset.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/bar_preset'

class TestBarPreset < Minitest::Test
  def test_ships_exactly_three_presets
    assert_equal %w[full minimal icon], OmarchyPrayer::BarPreset.names
  end

  def test_format_for_each_preset
    assert_equal '{city} · {prayer} {countdown}',
                 OmarchyPrayer::BarPreset.format_for('full')
    assert_equal '{prayer} {countdown}',
                 OmarchyPrayer::BarPreset.format_for('minimal')
    assert_equal '', OmarchyPrayer::BarPreset.format_for('icon')
  end

  def test_format_for_unknown_name_is_nil
    assert_nil OmarchyPrayer::BarPreset.format_for('nope')
  end

  def test_name_for_round_trips_every_preset
    OmarchyPrayer::BarPreset.names.each do |name|
      format = OmarchyPrayer::BarPreset.format_for(name)
      assert_equal name, OmarchyPrayer::BarPreset.name_for(format),
                   "#{name} did not round-trip"
    end
  end

  def test_name_for_unmatched_format_is_custom
    assert_equal 'custom', OmarchyPrayer::BarPreset.name_for('{prayer} at {time}')
  end

  def test_name_for_nil_is_custom
    assert_equal 'custom', OmarchyPrayer::BarPreset.name_for(nil)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_preset.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/bar_preset`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/bar_preset.rb`:

```ruby
module OmarchyPrayer
  # Named pill designs. A preset is just a format string; the active preset is
  # recovered by matching the stored format back against this catalogue rather
  # than being persisted, so hand-editing `format` can never leave the picker
  # highlighting a design the bar is not using.
  module BarPreset
    PRESETS = {
      'full'    => '{city} · {prayer} {countdown}',
      'minimal' => '{prayer} {countdown}',
      'icon'    => ''
    }.freeze

    CUSTOM = 'custom'.freeze

    module_function

    def names
      PRESETS.keys
    end

    def format_for(name)
      PRESETS[name.to_s]
    end

    def name_for(format)
      return CUSTOM if format.nil?
      PRESETS.key(format.to_s) || CUSTOM
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_preset.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/bar_preset.rb test/test_bar_preset.rb
git commit -m "feat(bar): preset catalogue with derived active name"
```

---

### Task 2: Prayer name table

**Files:**
- Create: `lib/omarchy_prayer/prayer_names.rb`, `test/test_prayer_names.rb`

**Interfaces:**
- Produces: `PrayerNames.pretty(key, script:) → String`, `PrayerNames::SCRIPTS → Array[String]`

- [ ] **Step 1: Write the failing test**

Create `test/test_prayer_names.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/prayer_names'

class TestPrayerNames < Minitest::Test
  KEYS = %i[fajr sunrise dhuhr asr maghrib isha fajr_tomorrow].freeze

  def test_latin_names
    assert_equal 'Fajr',    OmarchyPrayer::PrayerNames.pretty(:fajr, script: 'latin')
    assert_equal 'Maghrib', OmarchyPrayer::PrayerNames.pretty(:maghrib, script: 'latin')
    assert_equal 'Fajr',    OmarchyPrayer::PrayerNames.pretty(:fajr_tomorrow, script: 'latin')
  end

  def test_arabic_names
    assert_equal 'الفجر',  OmarchyPrayer::PrayerNames.pretty(:fajr, script: 'arabic')
    assert_equal 'العشاء', OmarchyPrayer::PrayerNames.pretty(:isha, script: 'arabic')
    assert_equal 'الفجر',  OmarchyPrayer::PrayerNames.pretty(:fajr_tomorrow, script: 'arabic')
  end

  def test_every_key_has_both_scripts
    KEYS.each do |key|
      %w[latin arabic].each do |script|
        value = OmarchyPrayer::PrayerNames.pretty(key, script: script)
        refute_nil value, "#{key}/#{script} missing"
        refute_empty value, "#{key}/#{script} empty"
      end
    end
  end

  def test_unknown_script_falls_back_to_latin
    assert_equal 'Isha', OmarchyPrayer::PrayerNames.pretty(:isha, script: 'klingon')
    assert_equal 'Isha', OmarchyPrayer::PrayerNames.pretty(:isha, script: nil)
  end

  def test_scripts_listed
    assert_equal %w[latin arabic], OmarchyPrayer::PrayerNames::SCRIPTS
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_prayer_names.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/prayer_names`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/prayer_names.rb`:

```ruby
module OmarchyPrayer
  # Prayer names per script. Applied in Status so every consumer — pill, panel,
  # waybar tooltip — receives an already-localised name and needs no knowledge
  # of scripts. Only names localise; the rest of the UI stays English.
  module PrayerNames
    SCRIPTS = %w[latin arabic].freeze
    DEFAULT_SCRIPT = 'latin'.freeze

    NAMES = {
      'latin' => {
        fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr', asr: 'Asr',
        maghrib: 'Maghrib', isha: 'Isha', fajr_tomorrow: 'Fajr'
      }.freeze,
      'arabic' => {
        fajr: 'الفجر', sunrise: 'الشروق', dhuhr: 'الظهر', asr: 'العصر',
        maghrib: 'المغرب', isha: 'العشاء', fajr_tomorrow: 'الفجر'
      }.freeze
    }.freeze

    module_function

    def pretty(key, script: DEFAULT_SCRIPT)
      table = NAMES[script.to_s] || NAMES[DEFAULT_SCRIPT]
      table.fetch(key.to_sym) { NAMES[DEFAULT_SCRIPT].fetch(key.to_sym) }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_prayer_names.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/prayer_names.rb test/test_prayer_names.rb
git commit -m "feat(bar): Latin and Arabic prayer-name table"
```

---

### Task 3: Config keys

**Files:**
- Modify: `lib/omarchy_prayer/config.rb:22,62-67`
- Test: `test/test_config.rb`

**Interfaces:**
- Consumes: `BarPreset.name_for` (Task 1), `PrayerNames::SCRIPTS` (Task 2)
- Produces: `Config#names_script → String`, `Config#compact_countdown? → Boolean`, `Config#quiet_until_minutes → Integer`, `Config#bar_preset → String`

- [ ] **Step 1: Write the failing test**

Add to `test/test_config.rb`:

```ruby
  def test_new_bar_keys_have_defaults
    cfg = OmarchyPrayer::Config.new('location' => base_location)
    assert_equal 'latin', cfg.names_script
    assert_equal false,   cfg.compact_countdown?
    assert_equal 0,       cfg.quiet_until_minutes
  end

  def test_bar_preset_is_derived_from_format
    cfg = OmarchyPrayer::Config.new(
      'location' => base_location, 'bar' => { 'format' => '{prayer} {countdown}' }
    )
    assert_equal 'minimal', cfg.bar_preset
  end

  def test_bar_preset_custom_for_handwritten_format
    cfg = OmarchyPrayer::Config.new(
      'location' => base_location, 'bar' => { 'format' => '{prayer} at {time}' }
    )
    assert_equal 'custom', cfg.bar_preset
  end

  def test_icon_preset_is_empty_format
    cfg = OmarchyPrayer::Config.new(
      'location' => base_location, 'bar' => { 'format' => '' }
    )
    assert_equal 'icon', cfg.bar_preset
    assert_equal '', cfg.bar_format
  end

  def test_names_script_accepts_arabic
    cfg = OmarchyPrayer::Config.new(
      'location' => base_location, 'bar' => { 'names' => 'arabic' }
    )
    assert_equal 'arabic', cfg.names_script
  end

  def test_unknown_names_script_falls_back_to_latin
    cfg = OmarchyPrayer::Config.new(
      'location' => base_location, 'bar' => { 'names' => 'klingon' }
    )
    assert_equal 'latin', cfg.names_script
  end

  def test_quiet_until_minutes_coerced
    loc = base_location
    assert_equal 60, OmarchyPrayer::Config.new(
      'location' => loc, 'bar' => { 'quiet_until_minutes' => 60 }
    ).quiet_until_minutes
    assert_equal 0, OmarchyPrayer::Config.new(
      'location' => loc, 'bar' => { 'quiet_until_minutes' => -5 }
    ).quiet_until_minutes, 'negative disables'
    assert_equal 0, OmarchyPrayer::Config.new(
      'location' => loc, 'bar' => { 'quiet_until_minutes' => 'soon' }
    ).quiet_until_minutes, 'non-numeric disables'
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_config.rb -n "/new_bar_keys|bar_preset|names_script|quiet_until/"`
Expected: FAIL with `NoMethodError: undefined method 'names_script'`

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/config.rb`, add requires at the top:

```ruby
require 'omarchy_prayer/bar_preset'
require 'omarchy_prayer/prayer_names'
```

Extend the `'bar'` defaults entry:

```ruby
      'bar'           => { 'format' => '{city} · {prayer} {countdown}',
                           'soon_threshold_minutes' => 10,
                           'names' => 'latin',
                           'compact_countdown' => false,
                           'quiet_until_minutes' => 0 }
```

Add readers next to `bar_format`:

```ruby
    # Derived, never stored — see BarPreset.
    def bar_preset; BarPreset.name_for(bar_format); end

    def names_script
      value = @raw['bar']['names'].to_s
      PrayerNames::SCRIPTS.include?(value) ? value : PrayerNames::DEFAULT_SCRIPT
    end

    def compact_countdown?
      @raw['bar']['compact_countdown'] == true
    end

    # 0 disables. Anything negative or non-numeric is treated as disabled
    # rather than raising — a typo here must never break the bar.
    def quiet_until_minutes
      value = @raw['bar']['quiet_until_minutes']
      return 0 unless value.is_a?(Numeric)
      value.to_i.negative? ? 0 : value.to_i
    end
```

- [ ] **Step 4: Run the config suite**

Run: `bundle exec ruby -Ilib -Itest test/test_config.rb`
Expected: PASS, including all pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/config.rb test/test_config.rb
git commit -m "feat(config): bar names, compact countdown, quiet threshold"
```

---

### Task 4: Status exposes presets and localised names

**Files:**
- Modify: `lib/omarchy_prayer/status.rb:13-19,32,58`
- Test: `test/test_status.rb`

**Interfaces:**
- Consumes: `Config#bar_preset`, `#names_script`, `#compact_countdown?`, `#quiet_until_minutes` (Task 3); `PrayerNames.pretty` (Task 2)
- Produces: `status['pill']['preset' | 'compact_countdown' | 'quiet_until_minutes']`; every `pretty` localised

- [ ] **Step 1: Write the failing test**

Add to `test/test_status.rb`:

```ruby
  def test_pill_carries_preset_and_display_options
    s = build
    assert_equal 'full', s['pill']['preset']
    assert_equal false,  s['pill']['compact_countdown']
    assert_equal 0,      s['pill']['quiet_until_minutes']
  end

  def test_pill_preset_tracks_format
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '' }
    )
    s = OmarchyPrayer::Status.build(today: today, config: cfg, now: afternoon)
    assert_equal 'icon', s['pill']['preset']
  end

  def test_names_localised_to_arabic
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'names' => 'arabic' }
    )
    s = OmarchyPrayer::Status.build(today: today, config: cfg, now: afternoon)
    assert_equal 'المغرب', s['next']['pretty']
    assert_equal 'الفجر',  s['prayers'].first['pretty']
    assert_equal 'fajr',   s['prayers'].first['name'], 'keys stay machine-readable'
  end

  def test_names_default_to_latin
    s = build
    assert_equal 'Maghrib', s['next']['pretty']
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_status.rb -n "/pill_carries|pill_preset_tracks|names_localised/"`
Expected: FAIL — `s['pill']['preset']` is nil.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/status.rb`, add `require 'omarchy_prayer/prayer_names'` at the top and delete the `PRETTY` constant. Replace its uses:

```ruby
    def build(today:, config:, now: Time.now)
      next_name, next_at = today.next_prayer(now: now)
      degrees = Qibla.bearing(config.latitude, config.longitude)
      script  = config.names_script

      {
        'city'    => config.city,
        'country' => config.country,
        'date'    => today.date,
        'hijri'   => today.hijri,
        'prayers' => Today::ORDER.map { |p| prayer_entry(today, p, now, script) },
        'next'    => {
          'name'   => next_name.to_s,
          'pretty' => PrayerNames.pretty(next_name, script: script),
          'time'   => next_at.strftime('%H:%M'),
          'epoch'  => next_at.to_i
        },
        'qibla'   => { 'degrees' => degrees, 'compass' => Qibla.cardinal(degrees) },
        'method'  => today.method,
        'source'  => today.source,
        'muted'         => File.exist?(Paths.mute_today),
        'audio_enabled' => config.audio_enabled,
        'pill'    => {
          'format'                 => config.bar_format,
          'soon_threshold_minutes' => config.soon_threshold_minutes,
          'preset'                 => config.bar_preset,
          'compact_countdown'      => config.compact_countdown?,
          'quiet_until_minutes'    => config.quiet_until_minutes
        }
      }
    end
```

And the entry builder:

```ruby
    def prayer_entry(today, prayer, now, script = PrayerNames::DEFAULT_SCRIPT)
      at = today.time_for(prayer)
      {
        'name'   => prayer.to_s,
        'pretty' => PrayerNames.pretty(prayer, script: script),
        'time'   => today.times[prayer],
        'epoch'  => at.to_i,
        'passed' => at <= now
      }
    end
```

- [ ] **Step 4: Run the status suite**

Run: `bundle exec ruby -Ilib -Itest test/test_status.rb`
Expected: PASS, including pre-existing tests.

- [ ] **Step 5: Check nothing else referenced Status::PRETTY**

Run: `grep -rn "Status::PRETTY" lib/ bin/ test/`
Expected: no output. If there is any, point it at `PrayerNames.pretty`.

- [ ] **Step 6: Commit**

```bash
git add lib/omarchy_prayer/status.rb test/test_status.rb
git commit -m "feat(status): expose preset and display options, localise names"
```

---

### Task 5: Waybar honours preset and compact countdown

**Files:**
- Modify: `lib/omarchy_prayer/waybar.rb`
- Test: `test/test_waybar.rb`

**Interfaces:**
- Consumes: `status['pill']['compact_countdown']` (Task 4)
- Produces: `Waybar.format_countdown(secs, compact = false) → String`

- [ ] **Step 1: Write the failing test**

Add to `test/test_waybar.rb`:

```ruby
  def status_with(pill)
    {
      'city'    => 'Riyadh',
      'prayers' => [{ 'pretty' => 'Asr', 'time' => '15:18' }],
      'next'    => { 'pretty' => 'Asr', 'time' => '15:18',
                     'epoch' => Time.new(2026, 4, 22, 15, 18, 0, 10800).to_i },
      'pill'    => { 'soon_threshold_minutes' => 10 }.merge(pill)
    }
  end

  def test_compact_countdown_uses_colon_form
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)   # 2h 14m before Asr
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => true), now: now
    )
    assert_equal '2:14', JSON.parse(json)['text']
  end

  def test_compact_countdown_under_an_hour_stays_minutes
    now = Time.new(2026, 4, 22, 14, 52, 0, 10800)  # 26m before Asr
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => true), now: now
    )
    assert_equal '26m', JSON.parse(json)['text']
  end

  def test_non_compact_countdown_unchanged
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => false), now: now
    )
    assert_equal '2h 14m', JSON.parse(json)['text']
  end

  def test_icon_preset_renders_empty_text
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => ''), now: now
    )
    data = JSON.parse(json)
    assert_equal '', data['text']
    refute_empty data['tooltip'], 'times must stay reachable in the tooltip'
  end

  def test_quiet_until_minutes_ignored_by_waybar
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{prayer} {countdown}', 'quiet_until_minutes' => 60), now: now
    )
    assert_equal 'Asr 2h 14m', JSON.parse(json)['text'],
                 'waybar has no glyph to collapse to, so quiet must not apply'
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_waybar.rb -n "/compact_countdown/"`
Expected: FAIL — `2h 14m` returned where `2:14` expected.

- [ ] **Step 3: Implement**

In `lib/omarchy_prayer/waybar.rb`, give `format_countdown` a compact mode and pass the flag through:

```ruby
    def format_countdown(secs, compact = false)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      return "#{m}m" unless h.positive?
      compact ? format('%d:%02d', h, m) : "#{h}h #{m}m"
    end
```

In `render_from_status`, use the flag. Note `quiet_until_minutes` is deliberately not read here:

```ruby
      text = pill['format']
        .gsub('{city}',      status['city'].to_s)
        .gsub('{prayer}',    nx['pretty'])
        .gsub('{time}',      nx['time'])
        .gsub('{countdown}', format_countdown(secs, pill['compact_countdown'] == true))
```

- [ ] **Step 4: Run the waybar suite**

Run: `bundle exec ruby -Ilib -Itest test/test_waybar.rb`
Expected: PASS. The byte-identity guard from 0.2.0 still passes, since `compact_countdown` defaults to falsey.

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/waybar.rb test/test_waybar.rb
git commit -m "feat(waybar): compact countdown; icon preset renders empty text"
```

---

### Task 6: `[bar]` config writer

**Files:**
- Create: `lib/omarchy_prayer/bar_setting.rb`, `test/test_bar_setting.rb`

**Interfaces:**
- Produces: `BarSetting.set(key, value, path = Paths.config_file) → value | nil`, `BarSetting.get(key, path = Paths.config_file) → String | nil`

- [ ] **Step 1: Write the failing test**

Create `test/test_bar_setting.rb`:

```ruby
require 'test_helper'
require 'omarchy_prayer/bar_setting'
require 'omarchy_prayer/paths'

class TestBarSetting < Minitest::Test
  include TestHelper

  CONFIG = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753

    [notifications]
    enabled = true

    [bar]
    # how the pill reads
    format                 = "{city} · {prayer} {countdown}"
    soon_threshold_minutes = 10
  TOML

  def seed
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, CONFIG)
  end

  def text
    File.read(OmarchyPrayer::Paths.config_file)
  end

  def test_rewrites_existing_key_preserving_alignment
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('format', '{prayer} {countdown}')
      assert_includes text, 'format                 = "{prayer} {countdown}"'
    end
  end

  def test_appends_key_that_is_absent
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('names', 'arabic')
      assert_match(/\[bar\][^\[]*names\s*=\s*"arabic"/m, text)
    end
  end

  def test_writes_booleans_and_integers_unquoted
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('compact_countdown', true)
      OmarchyPrayer::BarSetting.set('quiet_until_minutes', 60)
      assert_match(/compact_countdown\s*=\s*true/, text)
      assert_match(/quiet_until_minutes\s*=\s*60/, text)
      refute_match(/"true"/, text)
    end
  end

  def test_writes_empty_string_for_icon_preset
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('format', '')
      assert_match(/format\s+= ""/, text)
    end
  end

  def test_never_touches_other_sections
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('format', '')
      assert_match(/\[notifications\]\nenabled = true/, text)
      assert_includes text, '# how the pill reads'
    end
  end

  def test_get_reads_current_value
    with_isolated_home do
      seed
      assert_equal '{city} · {prayer} {countdown}', OmarchyPrayer::BarSetting.get('format')
      assert_nil OmarchyPrayer::BarSetting.get('names')
    end
  end

  def test_missing_config_is_safe
    with_isolated_home do
      assert_nil OmarchyPrayer::BarSetting.set('names', 'arabic')
      assert_nil OmarchyPrayer::BarSetting.get('names')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_setting.rb`
Expected: FAIL with `cannot load such file -- omarchy_prayer/bar_setting`

- [ ] **Step 3: Implement**

Create `lib/omarchy_prayer/bar_setting.rb`:

```ruby
require 'omarchy_prayer/paths'

module OmarchyPrayer
  # Reads and writes single keys inside the [bar] section of config.toml.
  #
  # Text-level rewrite rather than a TOML round-trip, for the same reason as
  # AudioSetting: config.toml is hand-edited and full of comments and column
  # alignment that a re-serialise would destroy. Section tracking matters —
  # [notifications] has an `enabled` key too.
  module BarSetting
    SECTION = 'bar'.freeze

    module_function

    def get(key, path = Paths.config_file)
      return nil unless File.exist?(path)
      each_line_with_section(File.read(path)) do |line, section|
        next unless section == SECTION
        m = line.match(/\A\s*#{Regexp.escape(key)}\s*=\s*(.*?)\s*\z/m)
        return unquote(m[1]) if m
      end
      nil
    end

    # Returns the written value, or nil when there is no config to write.
    def set(key, value, path = Paths.config_file)
      return nil unless File.exist?(path)
      text = File.read(path)
      rewritten = replace_key(text, key, value) || append_key(text, key, value)
      File.write(path, rewritten) unless rewritten == text
      value
    end

    def literal(value)
      case value
      when true, false, Integer then value.to_s
      else "\"#{value}\""
      end
    end

    def unquote(raw)
      raw =~ /\A"(.*)"\z/m ? Regexp.last_match(1) : raw
    end

    # Returns nil when the key is not present, so the caller can append.
    def replace_key(text, key, value)
      found = false
      out = []
      each_line_with_section(text) do |line, section|
        if section == SECTION &&
           (m = line.match(/\A(\s*#{Regexp.escape(key)}\s*=\s*)(.*?)(\s*)\z/m))
          found = true
          out << "#{m[1]}#{literal(value)}#{m[3]}"
        else
          out << line
        end
      end
      found ? out.join : nil
    end

    def append_key(text, key, value)
      out = []
      inserted = false
      lines = text.lines
      lines.each_with_index do |line, i|
        out << line
        next unless !inserted && line.match(/\A\s*\[#{SECTION}\]\s*\z/)
        # Insert after the last line of the section so appended keys group
        # together rather than splitting the section header from its body.
        j = i + 1
        j += 1 while lines[j] && !lines[j].match(/\A\s*\[[^\]]+\]\s*\z/)
        out.concat(lines[(i + 1)...j])
        out << "#{key} = #{literal(value)}\n"
        out.concat(lines[j..] || [])
        inserted = true
        break
      end
      inserted ? out.join : "#{text}\n[#{SECTION}]\n#{key} = #{literal(value)}\n"
    end

    def each_line_with_section(text)
      section = nil
      text.each_line do |line|
        if (m = line.match(/\A\s*\[([^\]]+)\]\s*\z/))
          section = m[1].strip
        end
        yield(line, section)
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Ilib -Itest test/test_bar_setting.rb`
Expected: PASS (7 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/omarchy_prayer/bar_setting.rb test/test_bar_setting.rb
git commit -m "feat(config): section-aware writer for [bar] keys"
```

---

### Task 7: `omarchy-prayer bar` CLI

**Files:**
- Modify: `bin/omarchy-prayer` (add `cmd_bar`, dispatch, help)

**Interfaces:**
- Consumes: `BarPreset` (Task 1), `PrayerNames::SCRIPTS` (Task 2), `BarSetting` (Task 6), `Config` (Task 3)

- [ ] **Step 1: Implement**

In `bin/omarchy-prayer`, add before `def cmd_refresh`:

```ruby
def cmd_bar(argv)
  require 'omarchy_prayer/bar_preset'
  require 'omarchy_prayer/bar_setting'
  require 'omarchy_prayer/prayer_names'
  require 'omarchy_prayer/config'

  sub = (argv[0] || 'status').downcase
  arg = argv[1]

  case sub
  when 'preset'      then bar_preset(arg)
  when 'names'       then bar_names(arg)
  when 'compact'     then bar_compact(arg)
  when 'quiet'       then bar_quiet(arg)
  when 'status'      then bar_status
  else
    warn 'usage: omarchy-prayer bar [preset|names|compact|quiet|status]'
    exit 1
  end
end

def bar_config_or_abort
  OmarchyPrayer::Config.load
rescue OmarchyPrayer::Config::MissingError => e
  abort "omarchy-prayer: #{e.message}"
end

def bar_preset(name)
  presets = OmarchyPrayer::BarPreset.names
  if name.nil? || name == 'list'
    active = bar_config_or_abort.bar_preset
    presets.each { |p| puts "#{p == active ? '*' : ' '} #{p}" }
    puts '  custom' if active == 'custom'
    return
  end
  unless presets.include?(name)
    warn "unknown preset #{name.inspect} (valid: #{presets.join(', ')})"
    exit 1
  end
  OmarchyPrayer::BarSetting.set('format', OmarchyPrayer::BarPreset.format_for(name))
  puts "bar preset: #{name}"
end

def bar_names(script)
  scripts = OmarchyPrayer::PrayerNames::SCRIPTS
  unless scripts.include?(script)
    warn "usage: omarchy-prayer bar names <#{scripts.join('|')}>"
    exit 1
  end
  OmarchyPrayer::BarSetting.set('names', script)
  puts "bar names: #{script}"
end

def bar_compact(value)
  case value
  when 'on', 'true'   then state = true
  when 'off', 'false' then state = false
  else
    warn 'usage: omarchy-prayer bar compact <on|off>'
    exit 1
  end
  OmarchyPrayer::BarSetting.set('compact_countdown', state)
  puts "bar compact countdown: #{state ? 'on' : 'off'}"
end

def bar_quiet(value)
  unless value.to_s.match?(/\A\d+\z/)
    warn 'usage: omarchy-prayer bar quiet <minutes>   (0 disables)'
    exit 1
  end
  minutes = value.to_i
  OmarchyPrayer::BarSetting.set('quiet_until_minutes', minutes)
  puts minutes.zero? ? 'bar quiet: off' : "bar quiet: collapses beyond #{minutes}m"
end

def bar_status
  cfg = bar_config_or_abort
  puts "preset            #{cfg.bar_preset}"
  puts "format            #{cfg.bar_format.inspect}"
  puts "names             #{cfg.names_script}"
  puts "compact countdown #{cfg.compact_countdown? ? 'on' : 'off'}"
  puts "quiet until       #{cfg.quiet_until_minutes.zero? ? 'off' : "#{cfg.quiet_until_minutes}m"}"
end
```

Add the dispatch line after `when 'audio'`:

```ruby
when 'bar'        then cmd_bar(ARGV[1..] || [])
```

And the help line after the `audio` entry:

```
      bar           pill design: preset|names|compact|quiet|status
```

- [ ] **Step 2: Verify the round trip against a real config**

```bash
ruby -Ilib bin/omarchy-prayer bar status
ruby -Ilib bin/omarchy-prayer bar preset list
ruby -Ilib bin/omarchy-prayer bar preset minimal
ruby -Ilib bin/omarchy-prayer bar status
ruby -Ilib bin/omarchy-prayer bar preset full
```

Expected: `preset` flips to `minimal` then back to `full`; `format` in `~/.config/omarchy-prayer/config.toml` changes to match; comments and alignment are untouched.

- [ ] **Step 3: Verify invalid input is rejected**

```bash
ruby -Ilib bin/omarchy-prayer bar preset bogus; echo "exit=$?"
ruby -Ilib bin/omarchy-prayer bar quiet -5;     echo "exit=$?"
```

Expected: both print the valid values and `exit=1`, and `config.toml` is unchanged.

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rake test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/omarchy-prayer
git commit -m "feat(cli): omarchy-prayer bar preset/names/compact/quiet"
```

---

### Task 8: Widget renders presets

**Files:**
- Modify: `share/omarchy-shell-plugin/Model.js`, `share/omarchy-shell-plugin/BarWidget.qml`

**Interfaces:**
- Consumes: `status['pill']` fields (Task 4)
- Produces: `Model.formatCountdown(secs, compact)`, `Model.shouldCollapse(secs, quietMinutes)`; `root.collapsed`, `root.tooltipLine` on the widget

- [ ] **Step 1: Extend Model.js**

Replace `formatCountdown` and add `shouldCollapse`:

```javascript
// Seconds -> "1h 57m" / "8m", or compact "1:57" / "8m". Never negative.
function formatCountdown(secs, compact) {
  if (!isFinite(secs) || secs < 0) secs = 0
  var h = Math.floor(secs / 3600)
  var m = Math.floor((secs % 3600) / 60)
  if (h <= 0) return m + "m"
  if (!compact) return h + "h " + m + "m"
  return h + ":" + (m < 10 ? "0" + m : m)
}

// Quiet-until-near: stay collapsed to the glyph while the next prayer is
// further away than the threshold. 0 disables.
function shouldCollapse(secs, quietMinutes) {
  if (!quietMinutes || quietMinutes <= 0) return false
  return secs > quietMinutes * 60
}
```

- [ ] **Step 2: Apply them in BarWidget.qml**

Add these properties next to `pillText`, replacing the existing `pillText` definition:

```qml
  readonly property bool compactCountdown: ready && prayerData.pill.compact_countdown === true
  readonly property int quietMinutes: ready ? (prayerData.pill.quiet_until_minutes || 0) : 0

  readonly property string countdown: Model.formatCountdown(secsRemaining, compactCountdown)

  // Collapsed when the preset has no text at all (icon), or while quiet-until-near
  // applies. Either way only the glyph is painted.
  readonly property bool collapsed: ready
    && (String(prayerData.pill.format || "") === ""
        || Model.shouldCollapse(secsRemaining, quietMinutes))

  readonly property string pillText: ready
    ? Model.renderPill(prayerData.pill.format, prayerData.city, prayerData.next.pretty,
                       prayerData.next.time, countdown)
    : "—"

  // In a collapsed state the pill shows no text, so the times have to stay
  // reachable without a click.
  readonly property string tooltipLine: ready
    ? (prayerData.next.pretty + " " + countdown)
    : ""
```

Delete the old `readonly property string countdown: Model.formatCountdown(secsRemaining)` line, which the new one replaces.

Update the button so a collapsed pill paints only the glyph and tooltips the times:

```qml
    text: {
      // The second glyph is U+F026 (muted speaker). Keep the escape rather
      // than retyping the character — it is invisible in most editors.
      var lead = root.glyph + (root.audioStateKnown && !root.audioEnabled ? " \uf026" : "")
      if (root.vertical || root.collapsed) return lead
      return lead + "  " + root.pillText
    }
    tooltipText: root.errorText !== "" ? root.errorText
               : (root.collapsed && root.tooltipLine !== "" ? root.tooltipLine : "Prayer times")
```

- [ ] **Step 3: Install and verify each preset on the real bar**

```bash
cp share/omarchy-shell-plugin/* ~/.config/omarchy/plugins/io.github.mrcode.prayer-times/
omarchy restart shell
```

Then step through, checking the pill after each:

```bash
bash -lc "omarchy-prayer bar preset full"      # Riyadh · Isha 1h 26m
bash -lc "omarchy-prayer bar preset minimal"   # Isha 1h 26m
bash -lc "omarchy-prayer bar preset icon"      # glyph only; hover shows "Isha 1h 26m"
bash -lc "omarchy-prayer bar preset minimal"
bash -lc "omarchy-prayer bar compact on"       # Isha 1:26
bash -lc "omarchy-prayer bar compact off"
bash -lc "omarchy-prayer bar quiet 60"         # collapses when >60m away, expands within
bash -lc "omarchy-prayer bar quiet 0"
```

The widget polls every 5 minutes, so nudge it after each change:
`omarchy-shell -q io.github.mrcode.prayer-times refresh`

Check for errors after the sequence:
`journalctl --user --since "2 minutes ago" | grep -i prayer | grep -iE "warn|error"`

- [ ] **Step 4: Verify Arabic rendering — the bidi risk**

```bash
bash -lc "omarchy-prayer bar names arabic"
omarchy-shell -q io.github.mrcode.prayer-times refresh
```

Look at the pill. Expected: `󱠧 العشاء 1h 26m`. **If the countdown appears on the wrong side of the name**, bidi reordering is at fault: prefix the countdown with U+200E (LEFT-TO-RIGHT MARK) inside `Model.renderPill`'s `{countdown}` substitution, reinstall, and re-check. Do not reorder the format string — that would break Latin rendering.

Also open the panel and confirm the rows read Arabic while tags still read `passed`.

Restore with `bash -lc "omarchy-prayer bar names latin"` when done.

- [ ] **Step 5: Commit**

```bash
git add share/omarchy-shell-plugin/Model.js share/omarchy-shell-plugin/BarWidget.qml
git commit -m "feat(shell): render presets, compact countdown, quiet-until-near"
```

---

### Task 9: Panel design picker

**Files:**
- Modify: `share/omarchy-shell-plugin/Panel.qml`

**Interfaces:**
- Consumes: `hostWidget.prayerData.pill.preset` (Task 4), `omarchy-prayer bar preset <name>` (Task 7)

- [ ] **Step 1: Add a setPreset function to BarWidget.qml**

Next to `toggleAudio()`:

```qml
  function setPreset(name) {
    runCommand("omarchy-prayer bar preset " + name)
    // Give the CLI a moment to rewrite config.toml before re-reading it.
    muteRefreshTimer.restart()
  }
```

- [ ] **Step 2: Add the chip row to Panel.qml**

Insert directly above the `// ---- Actions.` Row, so the picker sits above the buttons:

```qml
        // ---- Design picker. Hidden on a pre-0.3.0 CLI that does not report
        //      pill.preset, rather than showing a control that cannot work.
        Column {
          visible: root.ready && root.prayerData.pill
                   && root.prayerData.pill.preset !== undefined
          width: parent.width
          spacing: Style.space(5)

          Text {
            text: "DESIGN"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: ["full", "minimal", "icon"]

              Button {
                required property var modelData
                readonly property bool active:
                  root.ready && root.prayerData.pill.preset === modelData

                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                bordered: true
                selected: active
                fontSize: Style.font.caption
                onClicked: {
                  if (root.hostWidget) root.hostWidget.setPreset(modelData)
                }
              }
            }
          }
        }
```

- [ ] **Step 3: Install and verify**

```bash
cp share/omarchy-shell-plugin/* ~/.config/omarchy/plugins/io.github.mrcode.prayer-times/
omarchy restart shell
omarchy-shell io.github.mrcode.prayer-times show
```

Verify: three chips appear above the buttons, the active one is highlighted, clicking each switches the pill within about a second, and the highlight follows. Then set a custom format by hand
(`bash -lc "omarchy-prayer bar preset full"` then edit `format` in config.toml to `"{prayer} at {time}"`),
refresh, and confirm no chip is highlighted but clicking one still works.

Check for QML errors:
`journalctl --user --since "1 minute ago" | grep -i prayer | grep -iE "warn|error"`

- [ ] **Step 4: Commit**

```bash
git add share/omarchy-shell-plugin/BarWidget.qml share/omarchy-shell-plugin/Panel.qml
git commit -m "feat(shell): design picker chips in the panel"
```

---

### Task 10: Version, docs, and release

**Files:**
- Modify: `lib/omarchy_prayer/version.rb`, `share/omarchy-shell-plugin/manifest.json`, `README.md`, AUR `PKGBUILD`

- [ ] **Step 1: Bump the version**

```bash
sed -i "s/VERSION = '0.2.2'.freeze/VERSION = '0.3.0'.freeze/" lib/omarchy_prayer/version.rb
sed -i 's/"version": "0.2.2"/"version": "0.3.0"/' share/omarchy-shell-plugin/manifest.json
```

- [ ] **Step 2: Document it in README.md**

Add to the Omarchy 4 bar widget section, after the click table:

```markdown
### Pill designs

Pick a design from the panel, or from the CLI:

| Preset | Pill reads |
|---------|-----------|
| `full` | `Riyadh · Isha 1h 26m` |
| `minimal` | `Isha 1h 26m` |
| `icon` | the mosque glyph alone; times in the tooltip and panel |

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
```

Add a row to the Commands table:

```markdown
| `omarchy-prayer bar`           | pill design: preset / names / compact / quiet   |
```

- [ ] **Step 3: Run everything**

```bash
bundle exec rake test
ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'
omarchy plugin validate share/omarchy-shell-plugin
```

Expected: both suites PASS; validate exits 0.

- [ ] **Step 4: Sync the marketplace plugin repo**

```bash
./script/sync-plugin-repo
git -C ../omarchy-prayer-plugin push origin master
```

- [ ] **Step 5: Commit, tag, push**

```bash
git add -A
git commit -m "feat(bar): pill design presets, Arabic names, display options"
git tag -a v0.3.0 -m "v0.3.0 — pill design presets

full/minimal/icon designs selectable from the panel or 'omarchy-prayer bar',
plus Arabic prayer names, compact countdown, and quiet-until-near."
git push origin master && git push origin v0.3.0
```

- [ ] **Step 6: Release to AUR**

```bash
cd ~/.cache/yay/omarchy-prayer
sed -i 's/^pkgver=0.2.2/pkgver=0.3.0/' PKGBUILD
rm -f omarchy-prayer-0.*.tar.gz
updpkgsums && makepkg --printsrcinfo > .SRCINFO
rm -rf src pkg && makepkg -f --nodeps      # MUST pass check() before pushing
```

Only when the build succeeds:

```bash
git add PKGBUILD .SRCINFO
git commit -m "upgpkg: omarchy-prayer 0.3.0-1"
git push origin master
sudo pacman -U --noconfirm omarchy-prayer-0.3.0-1-any.pkg.tar.zst
```

- [ ] **Step 7: Verify the released package through PATH**

```bash
bash -lc "omarchy-prayer bar status"
bash -lc "omarchy-prayer status --json" | python3 -c "import json,sys; print(json.load(sys.stdin)['pill'])"
```

Expected: `bar status` prints all five values; the `pill` object contains `preset`, `compact_countdown` and `quiet_until_minutes`.

- [ ] **Step 8: Update PROGRESS.md**

Record v0.3.0, the preset catalogue, the derived-preset decision, and whether the Arabic bidi workaround was needed.

---

## Verification before release

- [ ] Both test invocations green
- [ ] Each of the three presets renders correctly on the real bar
- [ ] Icon preset's tooltip shows prayer and countdown
- [ ] Compact countdown shows `1:26` above an hour and `26m` below
- [ ] Quiet-until-near collapses and expands at the threshold
- [ ] Arabic names render correctly in pill and panel (bidi checked)
- [ ] Picker chips highlight the active preset and switch on click
- [ ] A hand-written format shows as `custom` with no chip highlighted
- [ ] `omarchy-prayer-waybar` output unchanged when the new keys are absent
- [ ] `makepkg` passes `check()` before the AUR push
