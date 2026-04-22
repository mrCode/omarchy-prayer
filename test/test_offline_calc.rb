require 'test_helper'
require 'date'
require 'time'
require 'omarchy_prayer/offline_calc'

class TestOfflineCalc < Minitest::Test
  # Expected times for a fixed reference date (MWL method, standard Asr).
  # Tolerance ±2 minutes. Update these if verification against live Aladhan
  # shows the hardcoded values below are stale — the TOLERANCE stays at 2.
  FIXTURES = [
    # [date,               lat,      lon,      method, tz_offset_sec, expected]
    # Values verified against live Aladhan API 2026-04-22 (method=3 / MWL).
    [Date.new(2026,4,22),  24.7136,  46.6753, 'MWL', 3*3600,
      { fajr: '04:06', sunrise: '05:25', dhuhr: '11:52', asr: '15:20', maghrib: '18:19', isha: '19:34' }],
    [Date.new(2026,4,22),  51.5074,  -0.1278, 'MWL', 1*3600,
      { fajr: '03:34', sunrise: '05:50', dhuhr: '12:59', asr: '16:53', maghrib: '20:09', isha: '22:16' }],
    [Date.new(2026,4,22),  -6.2088, 106.8456, 'MWL', 7*3600,
      { fajr: '04:43', sunrise: '05:53', dhuhr: '11:51', asr: '15:12', maghrib: '17:49', isha: '18:56' }]
  ].freeze

  def test_matches_aladhan_within_two_minutes
    FIXTURES.each do |date, lat, lon, method, tz_offset, expected|
      times = OmarchyPrayer::OfflineCalc.compute(date: date, lat: lat, lon: lon, method: method, tz_offset: tz_offset)
      expected.each do |prayer, hhmm|
        got = times[prayer].strftime('%H:%M')
        delta = minutes_between(got, hhmm)
        assert delta <= 2, "#{date} @ #{lat},#{lon} #{prayer}: expected #{hhmm}, got #{got} (Δ#{delta}m)"
      end
    end
  end

  def test_makkah_method_uses_90_min_isha_interval
    t = OmarchyPrayer::OfflineCalc.compute(
      date: Date.new(2026,4,22), lat: 24.7136, lon: 46.6753,
      method: 'Makkah', tz_offset: 3*3600
    )
    minutes = (t[:isha] - t[:maghrib]) / 60
    assert_in_delta 90, minutes, 1
  end

  private

  def minutes_between(a, b)
    ((Time.parse("2000-01-01 #{a}") - Time.parse("2000-01-01 #{b}")) / 60).abs.round
  end
end
