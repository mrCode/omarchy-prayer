require 'test_helper'
require 'stringio'
require 'omarchy_prayer/tui'
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
end
