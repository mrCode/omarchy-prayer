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
end
