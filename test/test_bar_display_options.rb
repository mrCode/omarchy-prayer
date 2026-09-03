require 'test_helper'
require 'json'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/status'
require 'omarchy_prayer/waybar'
require 'omarchy_prayer/prayer_icons'

# Display options ported from PR #4 by @ch-arslanahmad: per-prayer icons,
# 12-hour times, and time-of-day colours.
#
# Three deliberate differences from that PR, each with a reason:
#
#   - Icons are a `{icon}` FORMAT PLACEHOLDER, not an `icons = true` boolean
#     defaulting to on. The original would have added emoji to every existing
#     waybar user's bar on upgrade; a placeholder composes with the preset
#     system and changes nothing until asked for.
#   - 12-hour time lives in Status, so the Quickshell panel honours it too,
#     not just waybar.
#   - No `markup` key is emitted at all. The original set `markup: true`
#     unconditionally; a security review of v0.4.0 established that waybar has
#     no such key (its contract is {text, tooltip, class, percentage}) and
#     parses Pango markup on these labels REGARDLESS. So the key was inert and
#     the reasoning behind making it conditional was wrong — Sanitize is
#     load-bearing for every user either way.
class TestBarDisplayOptions < Minitest::Test
  TIMES = { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
            asr: '15:18', maghrib: '18:01', isha: '19:21' }.freeze

  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api', times: TIMES
    )
  end

  def now
    Time.new(2026, 4, 22, 13, 4, 0, 10800) # 2h 14m before Asr 15:18
  end

  def config(bar = {})
    OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '{prayer} {countdown}',
                      'soon_threshold_minutes' => 10 }.merge(bar)
    )
  end

  def render(bar = {})
    status = OmarchyPrayer::Status.build(today: today, config: config(bar), now: now)
    JSON.parse(OmarchyPrayer::Waybar.render_from_status(status, now: now))
  end

  # ---- {icon} placeholder ------------------------------------------------

  def test_icon_placeholder_substitutes_the_prayer_icon
    data = render('format' => '{icon} {prayer} {countdown}')
    assert_equal "#{OmarchyPrayer::PrayerIcons.for(:asr)} Asr 2h 14m", data['text']
  end

  def test_every_prayer_has_an_icon
    OmarchyPrayer::Today::ORDER.each do |prayer|
      refute_nil OmarchyPrayer::PrayerIcons.for(prayer), "no icon for #{prayer}"
      refute_empty OmarchyPrayer::PrayerIcons.for(prayer)
    end
  end

  def test_status_exposes_an_icon_per_prayer_and_for_next
    status = OmarchyPrayer::Status.build(today: today, config: config, now: now)
    assert_equal OmarchyPrayer::PrayerIcons.for(:asr), status['next']['icon']
    status['prayers'].each { |p| refute_nil p['icon'], "no icon on #{p['name']}" }
  end

  # The whole point of choosing a placeholder over a default-on boolean.
  def test_default_format_is_unchanged_for_existing_users
    data = render('format' => '{city} · {prayer} {countdown}')
    assert_equal 'Riyadh · Asr 2h 14m', data['text']
    refute_includes data['text'], OmarchyPrayer::PrayerIcons.for(:asr)
  end

  # ---- 12-hour time ------------------------------------------------------

  def test_time_placeholder_is_24h_by_default
    assert_equal '15:18', render('format' => '{time}')['text']
  end

  def test_time_12h_switches_the_time_placeholder
    assert_equal '3:18 PM', render('format' => '{time}', 'time_12h' => true)['text']
  end

  def test_time_12h_strips_the_leading_zero
    early = OmarchyPrayer::Status.build(
      today: today, config: config('time_12h' => true),
      now: Time.new(2026, 4, 22, 3, 0, 0, 10800) # before Fajr 04:15
    )
    assert_equal '4:15 AM', early['next']['time']
  end

  def test_time_12h_reaches_the_tooltip
    data = render('format' => '{prayer}', 'time_12h' => true)
    assert_includes data['tooltip'], '3:18 PM'
    assert_includes data['tooltip'], '11:48 AM'
    refute_includes data['tooltip'], '15:18'
  end

  # Status is shared with the Quickshell widget, so the panel honours it too.
  def test_time_12h_applies_to_every_prayer_in_status
    status = OmarchyPrayer::Status.build(today: today, config: config('time_12h' => true), now: now)
    assert_equal ['4:15 AM', '11:48 AM', '3:18 PM', '6:01 PM', '7:21 PM'],
                 status['prayers'].map { |p| p['time'] }
  end

  # ---- colours -----------------------------------------------------------

  def test_colours_wrap_the_prayer_name_in_a_pango_span
    data = render('colored' => true)
    assert_match(%r{<span color='#[0-9a-fA-F]{6}'>Asr</span>}, data['text'])
  end

  def test_no_span_when_colours_are_off
    refute_includes render['text'], '<span'
  end

  # waybar has no `markup` key — its contract is {text, tooltip, class,
  # percentage} — and parses Pango markup on these labels regardless. Emitting
  # one would encode a false belief about when Sanitize matters.
  def test_no_inert_markup_key_is_emitted
    refute render.key?('markup')
    refute render('colored' => true).key?('markup')
  end

  # ---- Pango escaping ----------------------------------------------------

  # An unescaped `&` fails gtk_label_set_markup outright and the module renders
  # BLANK — and waybar parses markup whether or not colours are on, so this bit
  # every user with an ampersand in their city, not just those opting in.
  def test_ampersand_in_city_is_escaped_so_the_label_still_parses
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Tom & Jerry' },
      'bar'      => { 'format' => '{city} · {prayer}', 'soon_threshold_minutes' => 10 }
    )
    text = JSON.parse(OmarchyPrayer::Waybar.render_from_status(
      OmarchyPrayer::Status.build(today: today, config: cfg, now: now), now: now
    ))['text']
    assert_includes text, 'Tom &amp; Jerry'
    refute_match(/&(?!amp;)/, text, 'a bare & would blank the whole module')
  end

  def test_ampersand_is_escaped_in_the_tooltip_too
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => 'Riyadh' },
      'bar'      => { 'format' => '{prayer}', 'soon_threshold_minutes' => 10, 'names' => 'arabic' }
    )
    # The fixture must actually contain an `&`, or this asserts nothing.
    poisoned = OmarchyPrayer::Status.build(today: today, config: cfg, now: now)
    poisoned['prayers'].first['pretty'] = 'Fajr & Dawn'
    tip = JSON.parse(OmarchyPrayer::Waybar.render_from_status(poisoned, now: now))['tooltip']
    assert_includes tip, 'Fajr &amp; Dawn'
    refute_match(/&(?!amp;)/, tip)
  end

  # ---- substitution is one pass, block form ------------------------------

  def test_a_substituted_value_is_not_expanded_again
    data = render('format' => '{city} {prayer}')
    # city is literally "{prayer}" — it must NOT become a second prayer name
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => '{prayer}' },
      'bar'      => { 'format' => '{city} {prayer}', 'soon_threshold_minutes' => 10 }
    )
    text = JSON.parse(OmarchyPrayer::Waybar.render_from_status(
      OmarchyPrayer::Status.build(today: today, config: cfg, now: now), now: now
    ))['text']
    assert_equal '{prayer} Asr', text
    refute_nil data
  end

  # The string form of gsub expands \0 and \& in the REPLACEMENT as
  # backreferences; Relocate.sub_string documents the same trap.
  def test_backreference_sequences_in_a_value_are_literal
    cfg = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224, 'city' => "x\\0y" },
      'bar'      => { 'format' => '{city}', 'soon_threshold_minutes' => 10 }
    )
    text = JSON.parse(OmarchyPrayer::Waybar.render_from_status(
      OmarchyPrayer::Status.build(today: today, config: cfg, now: now), now: now
    ))['text']
    refute_includes text, '{city}', 'a backreference expanded into the match'
  end

  # Only the NAME is wrapped. An emoji carries its own colour and ignores a
  # Pango foreground, so wrapping it too would add a span that changes nothing.
  def test_colouring_wraps_the_name_only_and_emits_one_span
    data = render('format' => '{icon} {prayer}', 'colored' => true)
    assert_includes data['text'], "<span color='"
    assert_equal 1, data['text'].scan('<span').length, 'one span, not one per part'
    assert data['text'].start_with?(OmarchyPrayer::PrayerIcons.for(:asr)),
           "icon should sit outside the span: #{data['text'].inspect}"
  end

  # City is attacker-influenced. Even with markup on, it must not be able to
  # introduce Pango tags of its own.
  def test_city_cannot_inject_pango_markup_when_colours_are_on
    hostile = OmarchyPrayer::Config.new(
      'location' => { 'latitude' => 24.6869, 'longitude' => 46.7224,
                      'city' => "Riyadh<span foreground='red'>x</span>" },
      'bar'      => { 'format' => '{city} {prayer}', 'soon_threshold_minutes' => 10,
                      'colored' => true }
    )
    status = OmarchyPrayer::Status.build(today: today, config: hostile, now: now)
    text = JSON.parse(OmarchyPrayer::Waybar.render_from_status(status, now: now))['text']
    assert_equal 1, text.scan('<span').length, "city injected a span: #{text.inspect}"
    assert_includes text, 'Riyadh'
  end

  # ---- config ------------------------------------------------------------

  def test_options_default_off
    cfg = config
    refute cfg.time_12h?
    refute cfg.bar_colored?
  end

  def test_options_read_from_the_bar_section
    cfg = config('time_12h' => true, 'colored' => true)
    assert cfg.time_12h?
    assert cfg.bar_colored?
  end

  def test_status_pill_carries_the_options
    pill = OmarchyPrayer::Status.build(
      today: today, config: config('time_12h' => true, 'colored' => true), now: now
    )['pill']
    assert_equal true, pill['time_12h']
    assert_equal true, pill['colored']
  end
end
