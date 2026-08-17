require 'test_helper'
require 'omarchy_prayer/audio_setting'
require 'omarchy_prayer/paths'

class TestAudioSetting < Minitest::Test
  include TestHelper

  CONFIG = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"

    [notifications]
    # keep this comment
    enabled = true

    [audio]
    # adhan audio is opt-in
    enabled    = false
    player     = "mpv"
    volume     = 80
  TOML

  def seed
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, CONFIG)
  end

  def config_text
    File.read(OmarchyPrayer::Paths.config_file)
  end

  def test_enables_audio
    with_isolated_home do
      seed
      assert_equal true, OmarchyPrayer::AudioSetting.set(true)
      assert_match(/\[audio\][^\[]*enabled\s+= true/m, config_text)
    end
  end

  def test_disables_audio
    with_isolated_home do
      seed
      OmarchyPrayer::AudioSetting.set(true)
      assert_equal false, OmarchyPrayer::AudioSetting.set(false)
      assert_match(/\[audio\][^\[]*enabled\s+= false/m, config_text)
    end
  end

  def test_toggle_flips_current_value
    with_isolated_home do
      seed
      assert_equal true,  OmarchyPrayer::AudioSetting.toggle
      assert_equal false, OmarchyPrayer::AudioSetting.toggle
      assert_equal true,  OmarchyPrayer::AudioSetting.toggle
    end
  end

  def test_never_touches_notifications_enabled
    with_isolated_home do
      seed
      OmarchyPrayer::AudioSetting.set(true)
      assert_match(/\[notifications\]\n# keep this comment\nenabled = true/, config_text,
                   'must only rewrite the enabled key under [audio]')
    end
  end

  def test_preserves_comments_and_other_keys
    with_isolated_home do
      seed
      OmarchyPrayer::AudioSetting.set(true)
      assert_includes config_text, '# adhan audio is opt-in'
      assert_includes config_text, 'player     = "mpv"'
      assert_includes config_text, 'volume     = 80'
    end
  end

  def test_preserves_alignment_padding
    with_isolated_home do
      seed
      OmarchyPrayer::AudioSetting.set(true)
      assert_includes config_text, 'enabled    = true',
                      'should keep the original spacing around ='
    end
  end

  def test_enabled_reads_current_state
    with_isolated_home do
      seed
      refute OmarchyPrayer::AudioSetting.enabled?
      OmarchyPrayer::AudioSetting.set(true)
      assert OmarchyPrayer::AudioSetting.enabled?
    end
  end

  def test_missing_config_is_safe
    with_isolated_home do
      refute OmarchyPrayer::AudioSetting.enabled?
      assert_nil OmarchyPrayer::AudioSetting.set(true)
    end
  end
end
