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
    assert_raises(OmarchyPrayer::Config::InvalidError) do
      write_config(bad) { }
    end
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
