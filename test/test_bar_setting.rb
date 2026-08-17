require 'test_helper'
require 'omarchy_prayer/bar_setting'
require 'omarchy_prayer/paths'
require 'tomlrb'

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

  # Regression: [bar] as the last section with no trailing newline used to
  # glue the appended key onto the previous line, corrupting both — the
  # written file must still parse with a real TOML parser afterward.
  def test_appends_when_bar_is_last_section_with_no_trailing_newline
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      no_trailing_newline = <<~TOML.chomp
        [location]
        latitude = 24.7136

        [bar]
        format = "{prayer} {countdown}"
      TOML
      refute no_trailing_newline.end_with?("\n"),
             'fixture must have no trailing newline to exercise the bug'
      File.write(OmarchyPrayer::Paths.config_file, no_trailing_newline)

      OmarchyPrayer::BarSetting.set('names', 'arabic')

      parsed = Tomlrb.load_file(OmarchyPrayer::Paths.config_file)
      assert_equal '{prayer} {countdown}', parsed['bar']['format'],
                   'pre-existing key must keep its original value'
      assert_equal 'arabic', parsed['bar']['names']
    end
  end

  # Regression: a raw string interpolation quoted embedded double quotes
  # without escaping them, writing an unparseable line.
  def test_set_with_embedded_quote_round_trips_through_real_parser
    with_isolated_home do
      seed
      value = 'he said "hi"'
      OmarchyPrayer::BarSetting.set('format', value)
      parsed = Tomlrb.load_file(OmarchyPrayer::Paths.config_file)
      assert_equal value, parsed['bar']['format']
    end
  end

  # Regression: a backslash must survive un-mangled through a real TOML
  # parser too, not just this module's own lenient reader.
  def test_set_with_backslash_round_trips_through_real_parser
    with_isolated_home do
      seed
      value = 'C:\\prayer\\path'
      OmarchyPrayer::BarSetting.set('format', value)
      parsed = Tomlrb.load_file(OmarchyPrayer::Paths.config_file)
      assert_equal value, parsed['bar']['format']
    end
  end

  # Guard against over-escaping: booleans/integers must stay unquoted so the
  # real parser returns TrueClass/Integer, not strings.
  def test_booleans_and_integers_stay_unquoted_per_real_parser
    with_isolated_home do
      seed
      OmarchyPrayer::BarSetting.set('compact_countdown', true)
      OmarchyPrayer::BarSetting.set('quiet_until_minutes', 60)
      parsed = Tomlrb.load_file(OmarchyPrayer::Paths.config_file)
      assert_equal true, parsed['bar']['compact_countdown']
      assert_equal 60, parsed['bar']['quiet_until_minutes']
    end
  end
end
