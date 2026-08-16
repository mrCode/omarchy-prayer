require 'test_helper'
require 'omarchy_prayer/today'
require 'omarchy_prayer/waybar'

class TestWaybar < Minitest::Test
  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  # Guards the refactor onto Status: both entry points must produce identical
  # bytes, so existing waybar users see no change whatsoever.
  def test_render_from_status_matches_render
    require 'omarchy_prayer/config'
    require 'omarchy_prayer/status'
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '{city} · {prayer} {countdown}',
                      'soon_threshold_minutes' => 10 }
    )
    status = OmarchyPrayer::Status.build(today: today, config: cfg, now: now)

    legacy = OmarchyPrayer::Waybar.render(
      today, now: now, city: 'Riyadh',
      format: '{city} · {prayer} {countdown}', soon_minutes: 10
    )
    assert_equal legacy, OmarchyPrayer::Waybar.render_from_status(status, now: now)
  end

  def test_countdown_and_class
    now = Time.new(2026,4,22, 13,4,0, 10800)  # 2h 14m before Asr 15:18
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'Riyadh',
      format: '{prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'Asr 2h 14m', data['text']
    assert_equal 'prayer-normal', data['class']
    assert_match(/Fajr.*04:15/, data['tooltip'])
    assert_match(/Asr.*15:18/,  data['tooltip'])
  end

  def test_soon_class_applied_within_threshold
    now = Time.new(2026,4,22, 15,12,0, 10800)  # 6m before Asr
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'Riyadh',
      format: '{prayer} {countdown}', soon_minutes: 10)
    assert_equal 'prayer-soon', JSON.parse(json)['class']
  end

  def test_after_isha_shows_tomorrow_fajr
    now = Time.new(2026,4,22, 22,0,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'Riyadh',
      format: '{prayer} {time}', soon_minutes: 10)
    assert_match(/Fajr 04:15/, JSON.parse(json)['text'])
  end

  def test_city_placeholder_substitution
    now = Time.new(2026,4,22, 13,4,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'London',
      format: '{city} · {prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'London · Asr 2h 14m', data['text']
  end

  def test_city_omitted_when_not_in_format
    now = Time.new(2026,4,22, 13,4,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'London',
      format: '{prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal 'Asr 2h 14m', data['text']
  end
end
