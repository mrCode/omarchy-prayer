require 'test_helper'
require 'omarchy_prayer/relocate'
require 'omarchy_prayer/paths'

class TestRelocate < Minitest::Test
  include TestHelper

  STUB_GEO = Class.new do
    def self.detect = { latitude: 21.4913, longitude: 39.1841, city: 'Jeddah', country: 'SA' }
  end

  def seed_config(home)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      # comment must survive
      latitude  = 24.7136
      longitude = 46.6753
      city      = "Riyadh"
      country   = "SA"

      [method]
      name = "auto"
    TOML
  end

  def seed_caches(home)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
    %w[times-2026-04-old.json times-2026-05-old.json].each do |f|
      File.write(File.join(OmarchyPrayer::Paths.state_dir, f), '{}')
    end
  end

  def test_manual_override_writes_config_and_clears_cache
    with_isolated_home do |home|
      seed_config(home); seed_caches(home)
      io = StringIO.new
      OmarchyPrayer::Relocate.run(
        %w[--lat 21.4225 --lon 39.8262 --city Makkah --country SA],
        geolocate: STUB_GEO, io: io
      )
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/latitude\s*=\s*21\.4225/, cfg)
      assert_match(/longitude\s*=\s*39\.8262/, cfg)
      assert_match(/city\s*=\s*"Makkah"/, cfg)
      assert_match(/country\s*=\s*"SA"/, cfg)
      assert_match(/# comment must survive/, cfg)
      assert_empty Dir.glob(File.join(OmarchyPrayer::Paths.state_dir, 'times-*.json'))
    end
  end

  def test_no_args_uses_geolocate
    with_isolated_home do |home|
      seed_config(home)
      io = StringIO.new
      OmarchyPrayer::Relocate.run([], geolocate: STUB_GEO, io: io)
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match(/city\s*=\s*"Jeddah"/, cfg)
      assert_match(/latitude\s*=\s*21\.4913/, cfg)
    end
  end

  def test_partial_manual_args_aborts
    with_isolated_home do |home|
      seed_config(home)
      assert_raises(SystemExit) do
        OmarchyPrayer::Relocate.run(%w[--lat 24.0 --lon 46.0], geolocate: STUB_GEO, io: StringIO.new)
      end
    end
  end

  def test_aborts_when_config_missing
    with_isolated_home do
      assert_raises(SystemExit) do
        OmarchyPrayer::Relocate.run([], geolocate: STUB_GEO, io: StringIO.new)
      end
    end
  end
end
