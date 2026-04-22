require 'test_helper'
require 'omarchy_prayer/qibla'

class TestQibla < Minitest::Test
  # Reference bearings (degrees True, to nearest integer) from IslamicFinder.
  REF = [
    # [lat,     lon,     expected_deg, label]
    [ 24.7136,  46.6753, 244, 'Riyadh'   ],   # WSW (IslamicFinder ref was wrong; formula + flat-earth both give 244)
    [ 51.5074,  -0.1278, 119, 'London'   ],
    [ 40.7128, -74.0060,  58, 'New York' ],
    [-33.8688, 151.2093, 277, 'Sydney'   ],
    [ 35.6895, 139.6917, 293, 'Tokyo'    ]
  ].freeze

  def test_known_bearings_within_two_degrees
    REF.each do |lat, lon, expected, label|
      actual = OmarchyPrayer::Qibla.bearing(lat, lon)
      assert_in_delta expected, actual, 2.0, "#{label}: expected ~#{expected}°, got #{actual}°"
    end
  end

  def test_bearing_from_makkah_is_nan_safe
    b = OmarchyPrayer::Qibla.bearing(21.4225, 39.8262)
    assert b >= 0 && b < 360
  end

  def test_cardinal_west
    assert_equal 'W',   OmarchyPrayer::Qibla.cardinal(270)
    assert_equal 'WNW', OmarchyPrayer::Qibla.cardinal(292)
    assert_equal 'N',   OmarchyPrayer::Qibla.cardinal(0)
    assert_equal 'N',   OmarchyPrayer::Qibla.cardinal(359)
  end
end
