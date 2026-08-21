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
end
