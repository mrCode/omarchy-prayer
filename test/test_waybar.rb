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
    assert_equal "Asr \u200E2h 14m", data['text']
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
    assert_equal "London · Asr \u200E2h 14m", data['text']
  end

  def test_city_omitted_when_not_in_format
    now = Time.new(2026,4,22, 13,4,0, 10800)
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'London',
      format: '{prayer} {countdown}', soon_minutes: 10)
    data = JSON.parse(json)
    assert_equal "Asr \u200E2h 14m", data['text']
  end

  def status_with(pill)
    {
      'city'    => 'Riyadh',
      'prayers' => [{ 'pretty' => 'Asr', 'time' => '15:18' }],
      'next'    => { 'pretty' => 'Asr', 'time' => '15:18',
                     'epoch' => Time.new(2026, 4, 22, 15, 18, 0, 10800).to_i },
      'pill'    => { 'soon_threshold_minutes' => 10 }.merge(pill)
    }
  end

  def test_compact_countdown_uses_colon_form
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)   # 2h 14m before Asr
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => true), now: now
    )
    assert_equal "\u200E2:14", JSON.parse(json)['text']
  end

  def test_compact_countdown_under_an_hour_stays_minutes
    now = Time.new(2026, 4, 22, 14, 52, 0, 10800)  # 26m before Asr
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => true), now: now
    )
    assert_equal "\u200E26m", JSON.parse(json)['text']
  end

  def test_non_compact_countdown_unchanged
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{countdown}', 'compact_countdown' => false), now: now
    )
    assert_equal "\u200E2h 14m", JSON.parse(json)['text']
  end

  def test_icon_preset_renders_empty_text
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => ''), now: now
    )
    data = JSON.parse(json)
    assert_equal '', data['text']
    refute_empty data['tooltip'], 'times must stay reachable in the tooltip'
  end

  def test_quiet_until_minutes_ignored_by_waybar
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)
    json = OmarchyPrayer::Waybar.render_from_status(
      status_with('format' => '{prayer} {countdown}', 'quiet_until_minutes' => 60), now: now
    )
    assert_equal "Asr \u200E2h 14m", JSON.parse(json)['text'],
                 'waybar has no glyph to collapse to, so quiet must not apply'
  end

  # `[bar] names = "arabic"` makes {prayer} an RTL string (e.g. "العشاء").
  # Without an anchor, the bidi algorithm can pull the countdown's leading
  # LTR digits across the RTL run and visually reorder the text (see
  # share/omarchy-shell-plugin/Model.js#renderPill for the widget-side fix
  # this mirrors). Assert on the actual codepoints: the LRM (U+200E) must
  # sit immediately before the countdown digits.
  def test_arabic_prayer_name_anchors_countdown_with_lrm
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)   # 2h 14m before Isha
    status = status_with('format' => '{prayer} {countdown}')
    status['next']['pretty'] = 'العشاء'
    json = OmarchyPrayer::Waybar.render_from_status(status, now: now)
    text = JSON.parse(json)['text']
    assert_equal "العشاء \u200E2h 14m", text
    assert_includes text, "\u200E2h 14m"
  end

  # Latin prayer names are unaffected in substance: the anchor is applied
  # unconditionally (mirroring Model.js, which does not special-case RTL
  # either), so the LRM is present here too. It is a zero-width, non-
  # rendering character, so the on-screen text is unchanged from before
  # this fix; only the underlying bytes gained the anchor.
  def test_latin_prayer_name_still_renders_with_anchor
    now = Time.new(2026, 4, 22, 13, 4, 0, 10800)   # 2h 14m before Asr
    json = OmarchyPrayer::Waybar.render(today, now: now, city: 'Riyadh',
      format: '{prayer} {countdown}', soon_minutes: 10)
    assert_equal "Asr \u200E2h 14m", JSON.parse(json)['text']
  end
end
