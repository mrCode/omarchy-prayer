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
