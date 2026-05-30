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
end
