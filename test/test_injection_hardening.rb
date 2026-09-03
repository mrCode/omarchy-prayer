require 'test_helper'
require 'stringio'
require 'rbconfig'
require 'tomlrb'
require 'omarchy_prayer/tui'
require 'omarchy_prayer/relocate'
require 'omarchy_prayer/first_run'
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/notifier'
require 'omarchy_prayer/status'

# Regression tests for the three findings of the v0.3.3 security scan.
#
# Shared threat model: [location].city and .country originate in an HTTP
# response from a third-party geolocation service, so an attacker on the
# network path (or the service itself) chooses their bytes. Those bytes then
# reach a raw-mode terminal, the bar, and the config file.
class TestInjectionHardening < Minitest::Test
  include TestHelper

  ESC = 27.chr.freeze
  BEL = 7.chr.freeze

  # The six LITERAL characters an attacker puts in the JSON response. Tomlrb
  # decodes them inside a basic string into a real ESC byte, which is what
  # makes the payload below live rather than theoretical. Built by
  # concatenation so no raw control character appears in this file.
  TOML_ESC = ('\\' + 'u001b').freeze

  # OSC 52 writes its base64 payload to the system clipboard. Omarchy's
  # shipped Alacritty config sets osc52 = "CopyPaste", so this is live.
  OSC52 = "Riyadh#{TOML_ESC}]52;c;cGF5bG9hZA==#{('\\' + 'u0007')}".freeze

  TIMES = {
    'fajr' => '04:30', 'dhuhr' => '11:50', 'asr' => '15:20',
    'maghrib' => '18:35', 'isha' => '20:05'
  }.freeze

  def seed(city: OSC52, hijri: nil)
    with_isolated_home do |home|
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "#{city}"
        country   = "SA"

        [method]
        name = "auto"
      TOML
      OmarchyPrayer::Today.new(
        date: Date.today.strftime('%Y-%m-%d'), tz_offset: 3 * 3600,
        city: OmarchyPrayer::Config.load.city, country: 'SA',
        method: 'Makkah', source: 'aladhan', times: TIMES, hijri: hijri
      ).write
      yield home
    end
  end

  def render_header(width: 80)
    out = StringIO.new
    tui = OmarchyPrayer::TUI.new(out: out, input: StringIO.new(''))
    tui.instance_variable_set(:@cfg, OmarchyPrayer::Config.load)
    tui.instance_variable_set(:@today, OmarchyPrayer::Today.read)
    tui.instance_variable_set(:@width, width)
    tui.send(:render_header)
    # Strip the TUI's own SGR colour codes; anything left is the attacker's.
    out.string.gsub(/\e\[[0-9;]*m/, '')
  end

  # ---- Vuln 1: cleartext geolocation as the trust root -------------------

  def test_geolocate_refuses_a_cleartext_endpoint
    e = assert_raises(OmarchyPrayer::Geolocate::Error) do
      OmarchyPrayer::Geolocate.detect_ip(url: 'http://ip-api.com/json/')
    end
    assert_match(/non-HTTPS/, e.message)
  end

  def test_default_geolocation_endpoint_is_https
    assert_match(%r{\Ahttps://}, OmarchyPrayer::Geolocate::DEFAULT_URL)
  end

  # ---- Vuln 2: terminal escape injection at the display sinks -----------

  # If this ever stops holding, the sink tests below stop testing anything.
  def test_the_fixture_really_carries_a_decoded_esc
    seed { assert_includes OmarchyPrayer::Config.load.city, ESC }
  end

  def test_tui_header_emits_no_control_characters
    seed do
      body = render_header
      refute_includes body, ESC, 'OSC 52 escape reached the terminal'
      refute_includes body, BEL
      assert_includes body, 'Riyadh'
    end
  end

  def test_tui_header_sanitises_hijri
    seed(city: 'Riyadh', hijri: "15 Dhu#{TOML_ESC}]52;c;eA== 1447") do
      refute_includes render_header, ESC
    end
  end

  def test_status_line_emits_no_control_characters
    seed do
      bin = File.expand_path('../bin/omarchy-prayer', __dir__)
      out = IO.popen([RbConfig.ruby, bin, 'status'], err: File::NULL, &:read)
      refute_includes out, ESC, 'OSC 52 escape reached the terminal'
      refute_includes out, BEL
      assert_includes out, 'Riyadh'
    end
  end

  # ---- Vuln 3: TOML injection through city / country --------------------

  INJECTION = %(Paris"\nauto_update = false\ndummy = "x).freeze

  def test_relocate_cannot_inject_toml
    seed(city: 'Riyadh') do
      OmarchyPrayer::Relocate.update_config!(
        latitude: 48.8566, longitude: 2.3522, city: INJECTION, country: 'FR'
      )
      loc = Tomlrb.parse(File.read(OmarchyPrayer::Paths.config_file))['location']
      assert_nil loc['auto_update'], 'injected key must not appear'
      assert_nil loc['dummy']
      assert_includes loc['city'], 'auto_update', 'payload stays inside the value'
    end
  end

  def test_first_run_cannot_inject_toml
    with_isolated_home do
      geo = Class.new do
        def self.detect
          { latitude: 48.8566, longitude: 2.3522,
            city: %(Paris"\nenabled = true\ndummy = "x), country: 'FR' }
        end
      end
      # Setup.run does network and systemd work; first-run bootstrap is not
      # what this asserts, so stand it down for the duration.
      sc = OmarchyPrayer::Setup.singleton_class
      sc.send(:alias_method, :run_orig, :run)
      sc.send(:define_method, :run) { |**_| [] }
      begin
        OmarchyPrayer::FirstRun.ensure_config!(geolocate: geo, out: StringIO.new)
      ensure
        sc.send(:alias_method, :run, :run_orig)
        sc.send(:remove_method, :run_orig)
      end
      parsed = Tomlrb.parse(File.read(OmarchyPrayer::Paths.config_file))
      assert_equal true, parsed['location']['auto_update'], 'real value must survive'
      assert_equal false, parsed['audio']['enabled'], 'adhan stays muted by default'
      assert_nil parsed['location']['dummy']
      assert_includes parsed['location']['city'], 'enabled = true'
    end
  end

  # ---- Sinks beyond the terminal ---------------------------------------

  def test_notification_body_carries_no_control_characters
    hostile = "Riyadh#{ESC}]52;c;cGF5bG9hZA==#{BEL}"
    today = OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: hostile, country: 'SA',
      method: 'Makkah', source: 'api', times: TIMES
    )
    notifier = OmarchyPrayer::Notifier.new(
      today: today, respect_silencing: false, audio_enabled: false,
      audio_player: 'mpv', volume: 80, adhan: nil, adhan_fajr: nil,
      pre_notify_minutes: 10
    )
    _title, body, = notifier.send(:compose, :dhuhr, 'pre')
    refute_includes body, ESC, 'escape reached the notification daemon'
    refute_includes body, BEL
    assert_includes body, 'Riyadh'
  end

  def test_status_json_sanitises_hijri
    seed(city: 'Riyadh', hijri: "15 Dhu#{ESC}]52;c;eA==#{BEL} 1447") do
      json = OmarchyPrayer::Status.build(
        today: OmarchyPrayer::Today.read, config: OmarchyPrayer::Config.load
      )
      refute_includes json['hijri'], ESC
      refute_includes json['hijri'], BEL
      assert_includes json['hijri'], '1447'
    end
  end

  # ---- Aladhan timings (found by the v0.4.0 security review) -------------

  # `hijri` was sanitised from this response; `timings` from the SAME response
  # was not, and split(' ', 2).first only requires "no whitespace" — which an
  # OSC 52 payload satisfies. It reached the TUI's prayer list raw.
  def test_aladhan_timings_reject_a_malformed_value_outright
    require 'omarchy_prayer/aladhan_client'
    payload = { 'Fajr' => "#{ESC}]52;c;cGF5bG9hZA==#{BEL}", 'Dhuhr' => '12:00 (EDT)' }
    assert_raises(OmarchyPrayer::AladhanClient::Error) do
      OmarchyPrayer::AladhanClient.new.send(:strip_timings, payload)
    end
  end

  # Rejecting the month is deliberate: TimesSource#safe swallows it and the day
  # falls through to the offline calculator. Neutralising in place would give
  # the user a confident 00:00 and a midnight timer.
  def test_wellformed_timings_pass_through_byte_identical
    require 'omarchy_prayer/aladhan_client'
    out = OmarchyPrayer::AladhanClient.new.send(
      :strip_timings, 'Fajr' => '05:07 (EDT)', 'Dhuhr' => '12:00', 'Asr' => '5:07'
    )
    assert_equal({ 'fajr' => '05:07', 'dhuhr' => '12:00', 'asr' => '5:07' }, out)
  end

  def test_tui_prayer_list_sanitises_times
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "Riyadh"
        country   = "SA"
      TOML
      hostile = TIMES.merge('fajr' => "#{ESC}]52;c;eA==#{BEL}")
      OmarchyPrayer::Today.new(
        date: Date.today.strftime('%Y-%m-%d'), tz_offset: 3 * 3600,
        city: 'Riyadh', country: 'SA', method: 'Makkah', source: 'api',
        times: hostile, hijri: nil
      ).write
      tui = OmarchyPrayer::TUI.new(out: StringIO.new, input: StringIO.new(''))
      tui.instance_variable_set(:@cfg, OmarchyPrayer::Config.load)
      tui.instance_variable_set(:@today, OmarchyPrayer::Today.read)
      tui.instance_variable_set(:@width, 80)
      # list_row RETURNS the row; it does not print. Asserting on the output
      # stream here passed vacuously and survived deleting the fix.
      row = tui.send(:list_row, :fajr, :dhuhr, Time.now).gsub(/\e\[[0-9;]*m/, '')
      refute_includes row, ESC, 'escape reached the terminal from timings'
      refute_includes row, BEL
      assert_includes row, 'Fajr'
    end
  end

  # Isolates tui.rb's own guard. The pipeline test above passes if EITHER
  # defence is present, so on its own it cannot tell you that `safe()` at
  # list_row is doing anything. This stand-in skips Today's cleaning entirely.
  def test_tui_list_row_sanitises_even_unclean_times
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "Riyadh"
        country   = "SA"
      TOML
      raw = Class.new do
        def initialize(times) = @times = times
        attr_reader :times
        def time_for(prayer)
          h, m = @times.fetch(prayer).to_s.split(':').map(&:to_i)
          Time.new(2026, 5, 3, h.to_i, m.to_i, 0, 3 * 3600)
        end
      end.new(TIMES.transform_keys(&:to_sym).merge(fajr: "#{ESC}]52;c;eA==#{BEL}"))

      tui = OmarchyPrayer::TUI.new(out: StringIO.new, input: StringIO.new(''))
      tui.instance_variable_set(:@cfg, OmarchyPrayer::Config.load)
      tui.instance_variable_set(:@today, raw)
      tui.instance_variable_set(:@width, 80)
      row = tui.send(:list_row, :fajr, :dhuhr, Time.now).gsub(/\e\[[0-9;]*m/, '')
      refute_includes row, ESC, 'list_row must sanitise regardless of Today'
      refute_includes row, BEL
    end
  end

  # A field the app never reads must not be able to fail the whole month —
  # that would wire a kill switch to Aladhan's schema, and the offline fallback
  # it lands in cannot compute above ~60 degrees latitude.
  def test_unused_aladhan_field_of_odd_shape_does_not_fail_the_month
    require 'omarchy_prayer/aladhan_client'
    out = OmarchyPrayer::AladhanClient.new.send(:strip_timings,
      'Fajr' => '05:07 (EDT)', 'Sunrise' => '06:25', 'Dhuhr' => '12:55',
      'Asr' => '16:35', 'Maghrib' => '19:25', 'Isha' => '20:43',
      'Midnight' => '2026-09-04T00:55:00-04:00', 'Iso8601' => 'whatever')
    assert_equal '05:07', out['fajr']
    refute out.key?('midnight'), 'odd-shaped unused field should be dropped'
    refute out.key?('iso8601')
  end

  # Pins REQUIRED to exactly what is displayed. sunrise is fetched but never
  # shown, so it must not be able to take the month down.
  def test_required_fields_are_exactly_the_displayed_prayers
    require 'omarchy_prayer/aladhan_client'
    assert_equal OmarchyPrayer::Today::ORDER.map(&:to_s).sort,
                 OmarchyPrayer::AladhanClient::REQUIRED.sort
  end

  def test_a_malformed_sunrise_does_not_fail_the_month
    require 'omarchy_prayer/aladhan_client'
    out = OmarchyPrayer::AladhanClient.new.send(:strip_timings,
      'Fajr' => '05:07', 'Sunrise' => '-----', 'Dhuhr' => '12:55',
      'Asr' => '16:35', 'Maghrib' => '19:25', 'Isha' => '20:43')
    assert_equal '05:07', out['fajr']
    refute out.key?('sunrise')
  end

  def test_a_required_field_of_odd_shape_still_fails_the_month
    require 'omarchy_prayer/aladhan_client'
    assert_raises(OmarchyPrayer::AladhanClient::Error) do
      OmarchyPrayer::AladhanClient.new.send(:strip_timings,
        'Fajr' => '-----', 'Dhuhr' => '12:55')
    end
  end

  # nil must stay nil: "" reaches time_for as midnight, and Scheduler would then
  # arm a real adhan timer at 00:00 instead of skipping the prayer.
  def test_a_null_timing_is_preserved_not_coerced_to_midnight
    t = OmarchyPrayer::Today.new(
      date: '2026-05-03', tz_offset: 3 * 3600, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api', times: TIMES.merge('fajr' => nil), hijri: nil
    )
    assert_nil t.times[:fajr], 'nil became a schedulable midnight'
    assert_equal '11:50', t.times[:dhuhr]
  end

  # The egress half. A payload written by an older version survives in the month
  # cache and today.json, and TimesSource PREFERS the cache — so ingress
  # validation alone would keep serving it all month.
  def test_poisoned_today_json_is_cleaned_on_read
    with_isolated_home do
      OmarchyPrayer::Paths.ensure_state_dir
      File.write(OmarchyPrayer::Paths.today_json, JSON.pretty_generate(
        'date' => Date.today.strftime('%Y-%m-%d'), 'tz_offset' => 10800,
        'city' => 'Riyadh', 'country' => 'SA', 'method' => 'Makkah', 'source' => 'cache',
        'times' => TIMES.merge('fajr' => "#{ESC}]52;c;eA==#{BEL}<span>x</span>"),
        'hijri' => nil
      ))
      t = OmarchyPrayer::Today.read
      refute_includes t.times[:fajr], ESC, 'cached payload survived into Today'
      refute_includes t.times[:fajr], BEL
      refute_includes t.times[:fajr], '<'
      assert_equal '11:50', t.times[:dhuhr], 'well-formed times must be untouched'
    end
  end

  def test_cmd_today_prints_no_control_characters
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude  = 24.7136
        longitude = 46.6753
        city      = "Riyadh"
        country   = "SA"
      TOML
      OmarchyPrayer::Paths.ensure_state_dir
      File.write(OmarchyPrayer::Paths.today_json, JSON.pretty_generate(
        'date' => Date.today.strftime('%Y-%m-%d'), 'tz_offset' => 10800,
        'city' => 'Riyadh', 'country' => 'SA', 'method' => 'Makkah', 'source' => 'cache',
        'times' => TIMES.merge('maghrib' => "#{ESC}]52;c;eA==#{BEL}"), 'hijri' => nil
      ))
      bin = File.expand_path('../bin/omarchy-prayer', __dir__)
      out = IO.popen([RbConfig.ruby, bin, 'today'], err: File::NULL, &:read)
      refute_includes out, ESC, 'omarchy-prayer today leaked an escape'
      refute_includes out, BEL
    end
  end
end
