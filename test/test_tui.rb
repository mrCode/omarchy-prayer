require 'test_helper'
require 'stringio'
require 'omarchy_prayer/tui'
require 'omarchy_prayer/relocate'
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
    out.string.gsub(/\e\[[0-9;]*m/, '')
  end

  def test_header_combines_dates_when_hijri_present
    with_seed(hijri: '15 Dhu al-Qi\'dah 1447') do
      out = render_header_to_string
      assert_match(/Riyadh, SA/, out)
      assert_match(/Sun, 3 May 2026/, out)
      assert_match(/15 Dhu al-Qi'dah 1447/, out)
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
end
