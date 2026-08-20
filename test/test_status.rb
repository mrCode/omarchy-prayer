require 'test_helper'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/status'

class TestStatus < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-08-16', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'cache', hijri: '3 Rabīʿ al-awwal 1448',
      times: { fajr: '04:05', sunrise: '05:30', dhuhr: '11:57',
               asr: '15:26', maghrib: '18:27', isha: '19:57' }
    )
  end

  def config
    OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224,
                      'city' => 'Riyadh', 'country' => 'SA' },
      'bar'      => { 'format' => '{city} · {prayer} {countdown}',
                      'soon_threshold_minutes' => 10 }
    )
  end

  # 16:30 — after Asr (15:26), before Maghrib (18:27).
  def afternoon
    Time.new(2026, 8, 16, 16, 30, 0, 10800)
  end

  def build(now: afternoon)
    OmarchyPrayer::Status.build(today: today, config: config, now: now)
  end

  def test_shape_and_next_prayer
    s = build
    assert_equal 'Riyadh', s['city']
    assert_equal 'SA', s['country']
    assert_equal '2026-08-16', s['date']
    assert_equal '3 Rabīʿ al-awwal 1448', s['hijri']
    assert_equal 5, s['prayers'].length
    assert_equal %w[fajr dhuhr asr maghrib isha], s['prayers'].map { |p| p['name'] }
    assert_equal 'maghrib', s['next']['name']
    assert_equal 'Maghrib', s['next']['pretty']
    assert_equal '18:27', s['next']['time']
    assert_equal 'Makkah', s['method']
    assert_equal 'cache', s['source']
    assert_equal '{city} · {prayer} {countdown}', s['pill']['format']
    assert_equal 10, s['pill']['soon_threshold_minutes']
  end

  def test_passed_flags_track_now
    by_name = build['prayers'].to_h { |p| [p['name'], p['passed']] }
    assert by_name['fajr'],    'Fajr 04:05 has passed by 16:30'
    assert by_name['asr'],     'Asr 15:26 has passed by 16:30'
    refute by_name['maghrib'], 'Maghrib 18:27 has not passed'
    refute by_name['isha'],    'Isha 19:57 has not passed'
  end

  def test_epoch_matches_wall_clock_and_next
    s = build
    maghrib = s['prayers'].find { |p| p['name'] == 'maghrib' }
    assert_equal Time.new(2026, 8, 16, 18, 27, 0, 10800).to_i, maghrib['epoch']
    assert_equal maghrib['epoch'], s['next']['epoch']
  end

  def test_after_isha_next_is_tomorrow_fajr
    s = build(now: Time.new(2026, 8, 16, 22, 0, 0, 10800))
    assert_equal 'fajr_tomorrow', s['next']['name']
    assert_equal 'Fajr', s['next']['pretty']
    assert_equal Time.new(2026, 8, 17, 4, 5, 0, 10800).to_i, s['next']['epoch']
  end

  def test_sunrise_excluded_from_prayer_list
    refute_includes build['prayers'].map { |p| p['name'] }, 'sunrise'
  end

  def test_qibla_included
    s = build
    assert_kind_of Integer, s['qibla']['degrees']
    assert_includes OmarchyPrayer::Qibla::CARDINALS, s['qibla']['compass']
  end

  def test_audio_enabled_reported
    refute build['audio_enabled'], 'config fixture has audio off'

    loud = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'audio'    => { 'enabled' => true }
    )
    s = OmarchyPrayer::Status.build(today: today, config: loud, now: afternoon)
    assert s['audio_enabled']
  end

  def test_muted_and_audio_enabled_are_independent
    with_isolated_home do
      s = build
      refute s['muted'],         'no mute-today marker'
      refute s['audio_enabled'], 'audio off in config'
      OmarchyPrayer::Paths.ensure_state_dir
      FileUtils.touch(OmarchyPrayer::Paths.mute_today)
      assert build['muted'], 'mute-today is separate from the audio setting'
    end
  end

  def test_muted_reflects_marker
    with_isolated_home do |_home|
      refute build['muted'], 'not muted with no marker'
      OmarchyPrayer::Paths.ensure_state_dir
      FileUtils.touch(OmarchyPrayer::Paths.mute_today)
      assert build['muted'], 'muted once the marker exists'
    end
  end

  def test_to_json_round_trips
    parsed = JSON.parse(
      OmarchyPrayer::Status.to_json(today: today, config: config, now: afternoon)
    )
    assert_equal 'maghrib', parsed['next']['name']
    assert_equal 5, parsed['prayers'].length
  end

  def test_pill_carries_preset_and_display_options
    s = build
    assert_equal 'full', s['pill']['preset']
    assert_equal false,  s['pill']['compact_countdown']
    assert_equal 0,      s['pill']['quiet_until_minutes']
  end

  def test_pill_preset_tracks_format
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '' }
    )
    s = OmarchyPrayer::Status.build(today: today, config: cfg, now: afternoon)
    assert_equal 'icon', s['pill']['preset']
  end

  def test_names_localised_to_arabic
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'names' => 'arabic' }
    )
    s = OmarchyPrayer::Status.build(today: today, config: cfg, now: afternoon)
    assert_equal 'المغرب', s['next']['pretty']
    assert_equal 'الفجر',  s['prayers'].first['pretty']
    assert_equal 'fajr',   s['prayers'].first['name'], 'keys stay machine-readable'
  end

  # Security: city/country come from an ip-api.com HTTP response and are
  # rendered by QML Text, whose AutoText default would treat markup as RICH
  # text and load <img src> targets. See OmarchyPrayer::Sanitize.
  def test_city_and_country_are_stripped_of_markup
    hostile = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224,
                      'city' => '<img src="http://attacker.invalid/x">Riyadh',
                      'country' => '<b>SA</b>' }
    )
    s = OmarchyPrayer::Status.build(today: today, config: hostile, now: afternoon)
    refute_includes s['city'], '<'
    refute_includes s['city'], '>'
    refute_includes s['country'], '<'
    assert_includes s['city'], 'Riyadh', 'the legitimate part of the name survives'
  end

  def test_ordinary_city_names_are_untouched
    assert_equal 'Riyadh', build['city']
    assert_equal 'SA', build['country']
  end

  def test_names_default_to_latin
    s = build
    assert_equal 'Maghrib', s['next']['pretty']
  end
end
