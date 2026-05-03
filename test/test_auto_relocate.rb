require 'test_helper'
require 'omarchy_prayer/auto_relocate'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'

class TestAutoRelocate < Minitest::Test
  include TestHelper

  RIYADH = { latitude: 24.7136, longitude: 46.6753, city: 'Riyadh', country: 'SA' }.freeze
  MAKKAH = { latitude: 21.4225, longitude: 39.8262, city: 'Makkah', country: 'SA' }.freeze
  DUBAI  = { latitude: 25.2048, longitude: 55.2708, city: 'Dubai',  country: 'AE' }.freeze

  def stub_geo(loc)
    Class.new do
      define_singleton_method(:detect) { loc }
    end
  end

  def raising_geo(error_class, message = 'boom')
    Class.new do
      define_singleton_method(:detect) { raise error_class, message }
    end
  end

  def seed_config(loc = RIYADH)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      # comment must survive
      latitude  = #{format('%.4f', loc[:latitude])}
      longitude = #{format('%.4f', loc[:longitude])}
      city      = "#{loc[:city]}"
      country   = "#{loc[:country]}"

      [method]
      name = "auto"
    TOML
  end

  def seed_caches
    FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
    %w[times-2026-04-old.json times-2026-05-old.json].each do |f|
      File.write(File.join(OmarchyPrayer::Paths.state_dir, f), '{}')
    end
  end

  def test_no_op_when_within_threshold
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      nearby = RIYADH.merge(latitude: 24.75, longitude: 46.70) # ~5 km away
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(nearby), io: io)
      assert_nil result
      assert_match(/Riyadh/, File.read(OmarchyPrayer::Paths.config_file))
      refute_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
    end
  end

  def test_updates_when_country_differs
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(DUBAI), io: io)
      refute_nil result
      assert_equal 'AE', result[:country]
      cfg_text = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/country\s*=\s*"AE"/, cfg_text)
      assert_match(/city\s*=\s*"Dubai"/, cfg_text)
      assert_match(/# comment must survive/, cfg_text)
      assert_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
      assert_match(/auto-relocated/, io.string)
    end
  end

  def test_updates_when_distance_exceeds_threshold
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      # Riyadh -> Makkah is ~870 km; same country, so the distance branch fires.
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(MAKKAH), io: io)
      refute_nil result
      cfg_text = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/city\s*=\s*"Makkah"/, cfg_text)
      assert_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
    end
  end

  def test_no_update_on_city_string_variation
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      variant = RIYADH.merge(city: 'Ar Riyadh', latitude: 24.72, longitude: 46.68) # ~1 km
      result = OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: stub_geo(variant), io: io)
      assert_nil result
      assert_match(/city\s*=\s*"Riyadh"/, File.read(OmarchyPrayer::Paths.config_file))
    end
  end

  def test_tolerates_geolocate_error
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(
        cfg, geolocate: raising_geo(OmarchyPrayer::Geolocate::Error, 'http 503'), io: io
      )
      assert_nil result
      assert_match(/auto-relocate skipped/, io.string)
      assert_match(/Riyadh/, File.read(OmarchyPrayer::Paths.config_file))
    end
  end

  def test_tolerates_network_error
    with_isolated_home do
      seed_config(RIYADH); seed_caches
      cfg = OmarchyPrayer::Config.load
      io = StringIO.new
      result = OmarchyPrayer::AutoRelocate.maybe_update(
        cfg, geolocate: raising_geo(SocketError, 'getaddrinfo: name or service not known'), io: io
      )
      assert_nil result
      assert_match(/auto-relocate skipped/, io.string)
    end
  end

  def test_schedule_script_calls_auto_relocate
    src = File.read(File.expand_path('../bin/omarchy-prayer-schedule', __dir__))
    assert_match(%r{require 'omarchy_prayer/auto_relocate'}, src)
    assert_match(/AutoRelocate\.maybe_update\(cfg\)/, src)
  end

  def test_dispatcher_script_present_and_executable
    path = File.expand_path('../share/networkmanager/90-omarchy-prayer', __dir__)
    assert File.exist?(path), 'dispatcher script missing'
    assert File.executable?(path), 'dispatcher script not executable'
    body = File.read(path)
    assert_match(%r{omarchy-prayer-schedule\.service}, body)
    assert_match(/loginctl list-sessions/, body)
  end
end
