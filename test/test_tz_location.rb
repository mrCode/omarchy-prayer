require 'test_helper'
require 'omarchy_prayer/tz_location'

class TestTzLocation < Minitest::Test
  include TestHelper

  FIXTURE = File.expand_path('fixtures/zone1970.tab', __dir__)

  def test_zone_name_from_env
    orig = ENV['TZ']
    ENV['TZ'] = 'Europe/London'
    assert_equal 'Europe/London', OmarchyPrayer::TzLocation.zone_name
  ensure
    ENV['TZ'] = orig
  end

  def test_zone_name_blank_env_falls_through
    orig = ENV['TZ']
    ENV['TZ'] = ''
    # Without /etc/localtime guarantees, just assert it returns either nil or a string.
    result = OmarchyPrayer::TzLocation.zone_name
    assert(result.nil? || result.is_a?(String))
  ensure
    ENV['TZ'] = orig
  end

  def test_parse_coord_short_form
    lat, lon = OmarchyPrayer::TzLocation.parse_iso6709('+2438+04643')
    assert_in_delta 24.6333, lat, 1e-4
    assert_in_delta 46.7166, lon, 1e-4
  end

  def test_parse_coord_long_form
    lat, lon = OmarchyPrayer::TzLocation.parse_iso6709('+513030-0000731')
    assert_in_delta 51.5083, lat, 1e-4
    assert_in_delta(-0.1253, lon, 1e-4)
  end

  def test_parse_coord_returns_nil_on_garbage
    assert_nil OmarchyPrayer::TzLocation.parse_iso6709('not-a-coord')
    assert_nil OmarchyPrayer::TzLocation.parse_iso6709('')
  end

  def test_table_loads_fixture
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    london = table['Europe/London']
    assert_equal %w[GB GG IM JE], london[:countries]
    assert_in_delta 51.5083, london[:lat], 1e-4
    assert_in_delta(-0.1253, london[:lon], 1e-4)
  end

  def test_table_handles_short_coord_form
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    riyadh = table['Asia/Riyadh']
    assert_equal %w[SA AQ KW YE], riyadh[:countries]
    assert_in_delta 24.6333, riyadh[:lat], 1e-4
    assert_in_delta 46.7166, riyadh[:lon], 1e-4
  end

  def test_table_skips_comment_and_blank_lines
    table = OmarchyPrayer::TzLocation.load_table(FIXTURE)
    refute_includes table.keys, '#'
    assert_equal 6, table.size
  end

  def test_table_missing_file_returns_empty
    assert_empty OmarchyPrayer::TzLocation.load_table('/nonexistent/zone1970.tab')
  end
end
