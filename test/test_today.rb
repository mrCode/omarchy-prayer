require 'test_helper'
require 'omarchy_prayer/today'

class TestToday < Minitest::Test
  include TestHelper

  def test_write_and_read_roundtrip
    with_isolated_home do
      today = OmarchyPrayer::Today.new(
        date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'Makkah', source: 'api-cache',
        times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
                 asr: '15:18', maghrib: '18:01', isha: '19:21' }
      )
      today.write
      loaded = OmarchyPrayer::Today.read
      assert_equal '2026-04-22', loaded.date
      assert_equal 'Riyadh',     loaded.city
      assert_equal '04:15',      loaded.times[:fajr]
      assert_equal 'api-cache',  loaded.source
    end
  end

  def test_hijri_roundtrips
    with_isolated_home do
      today = OmarchyPrayer::Today.new(
        date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'Makkah', source: 'api',
        times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
                 asr: '15:18', maghrib: '18:01', isha: '19:21' },
        hijri: '5 Dhū al-Qaʿdah 1447'
      )
      today.write
      loaded = OmarchyPrayer::Today.read
      assert_equal '5 Dhū al-Qaʿdah 1447', loaded.hijri
    end
  end

  def test_hijri_nil_when_absent
    with_isolated_home do
      today = OmarchyPrayer::Today.new(
        date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'Makkah', source: 'offline',
        times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
                 asr: '15:18', maghrib: '18:01', isha: '19:21' }
      )
      today.write
      loaded = OmarchyPrayer::Today.read
      assert_nil loaded.hijri
    end
  end

  def test_next_prayer_selects_first_future
    times = { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
              asr: '15:18', maghrib: '18:01', isha: '19:21' }
    today = OmarchyPrayer::Today.new(date: '2026-04-22', tz_offset: 10800,
      city: 'Riyadh', country: 'SA', method: 'Makkah', source: 'api', times: times)
    now = Time.new(2026, 4, 22, 12, 30, 0, 10800)
    name, at = today.next_prayer(now: now)
    assert_equal :asr, name
    assert_equal Time.new(2026,4,22,15,18,0,10800), at
  end

  def test_next_prayer_after_isha_returns_tomorrow_fajr
    times = { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
              asr: '15:18', maghrib: '18:01', isha: '19:21' }
    today = OmarchyPrayer::Today.new(date: '2026-04-22', tz_offset: 10800,
      city: 'Riyadh', country: 'SA', method: 'Makkah', source: 'api', times: times)
    now = Time.new(2026, 4, 22, 22, 0, 0, 10800)
    name, at = today.next_prayer(now: now)
    assert_equal :fajr_tomorrow, name
    assert_equal Time.new(2026,4,23,4,15,0,10800), at
  end
end
