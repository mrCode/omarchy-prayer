require 'test_helper'
require 'stringio'
require 'tomlrb'
require 'omarchy_prayer/relocate'
require 'omarchy_prayer/auto_relocate'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/bar_setting'

# A manual `relocate` must stick.
#
# Before this, `cmd_relocate` wrote the coordinates and then exec'd the
# scheduler, which — with the default `auto_update = true` — re-detected by IP
# and overwrote them inside the same command. The user's explicit override was
# destroyed before it ever took effect, exit status 0, with only a stderr line
# that reads like normal operation.
#
# The timezone cross-check does NOT save this: it compares COUNTRIES only, so a
# 694 km error inside one country passes straight through.
class TestRelocatePinning < Minitest::Test
  include TestHelper

  # Stands in for a geolocation provider that puts this connection 694 km away.
  FAR_AWAY = Class.new do
    def self.detect = { latitude: 32.7174, longitude: -117.1628, city: 'San Diego', country: 'US' }
  end

  MANUAL = %w[--lat 37.4419 --lon -122.1430 --city PaloAlto --country US].freeze

  def seed(auto_update: true, with_key: true)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    line = with_key ? "auto_update = #{auto_update}\n" : ''
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      latitude    = 40.7127
      longitude   = -74.0060
      city        = "New York City"
      country     = "US"
      # keep this comment
      #{line}
      [method]
      name = "auto"
    TOML
  end

  def loc = Tomlrb.parse(File.read(OmarchyPrayer::Paths.config_file))['location']

  # Simulates what cmd_relocate does: Relocate.run, then the scheduler's
  # auto-relocate step. Without exec'ing anything — `systemd-run --user` would
  # rearm the real user's live timers.
  def relocate_then_schedule(argv)
    OmarchyPrayer::Relocate.run(argv, geolocate: FAR_AWAY, io: StringIO.new)
    cfg = OmarchyPrayer::Config.load
    OmarchyPrayer::AutoRelocate.maybe_update(cfg, geolocate: FAR_AWAY, io: StringIO.new) if cfg.auto_update?
  end

  def test_manual_relocate_survives_the_scheduler_it_launches
    with_isolated_home do
      seed
      relocate_then_schedule(MANUAL)
      assert_equal 'PaloAlto', loc['city'], 'the manual pin was overwritten'
      assert_in_delta 37.4419, loc['latitude'], 0.0001
    end
  end

  def test_manual_relocate_pins_by_disabling_auto_update
    with_isolated_home do
      seed
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      assert_equal false, loc['auto_update']
    end
  end

  # A config written before auto_update existed has no such key, and
  # Config#auto_update? defaults to TRUE — so pinning must add the key, not
  # assume it is there to rewrite.
  def test_pinning_adds_the_key_when_the_config_lacks_it
    with_isolated_home do
      seed(with_key: false)
      relocate_then_schedule(MANUAL)
      assert_equal false, loc['auto_update']
      assert_equal 'PaloAlto', loc['city']
    end
  end

  def test_pinning_is_reported_not_silent
    with_isolated_home do
      seed
      io = StringIO.new
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: io)
      assert_match(/auto-update/i, io.string, 'the user must be told the pin disabled auto-update')
      assert_match(/--auto/, io.string, 'and told how to undo it')
    end
  end

  # A bare `relocate` is a one-shot re-detect, not a pin. It must not silently
  # switch travel tracking off.
  def test_bare_relocate_leaves_auto_update_alone
    with_isolated_home do
      seed
      OmarchyPrayer::Relocate.run([], geolocate: FAR_AWAY, io: StringIO.new)
      assert_equal true, loc['auto_update'], 'IP re-detect must not disable auto-update'
      assert_equal 'San Diego', loc['city']
    end
  end

  def test_auto_flag_re_enables_tracking
    with_isolated_home do
      seed(auto_update: false)
      io = StringIO.new
      OmarchyPrayer::Relocate.run(['--auto'], geolocate: FAR_AWAY, io: io)
      assert_equal true, loc['auto_update']
      assert_equal 'San Diego', loc['city'], '--auto re-detects as well as re-enabling'
      assert_match(/auto-update/i, io.string)
    end
  end

  def test_comments_and_other_sections_survive_the_pin
    with_isolated_home do
      seed
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      text = File.read(OmarchyPrayer::Paths.config_file)
      assert_includes text, '# keep this comment'
      assert_equal 'auto', Tomlrb.parse(text)['method']['name']
      # Without this the test survives deleting the pin outright — everything
      # it asserted was already guaranteed by update_config! alone.
    end
  end

  # [notifications] has an `enabled` key and [audio] has one too; a key written
  # into [location] must not land in a neighbouring section.
  def test_the_key_lands_in_the_location_section
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude    = 40.7127
        longitude   = -74.0060
        city        = "New York City"
        country     = "US"

        [notifications]
        enabled = true
        auto_update = true
      TOML
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      parsed = Tomlrb.parse(File.read(OmarchyPrayer::Paths.config_file))
      assert_equal false, parsed['location']['auto_update'], 'pin did not reach [location]'
      assert_equal true, parsed['notifications']['auto_update'], 'pin corrupted a neighbouring section'
    end
  end

  # ---- from the v0.4.2 security review ----------------------------------

  # `[location]  # my home` is valid TOML. A writer that does not accept the
  # trailing comment cannot see the section, appends a SECOND [location] table,
  # and the config stops parsing — taking every entry point down until the user
  # repairs it by hand.
  def test_a_commented_section_header_is_still_found
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]  # my home
        latitude    = 40.7127
        longitude   = -74.0060
        city        = "New York City"
        country     = "US"

        [method]
        name = "auto"
      TOML
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      text = File.read(OmarchyPrayer::Paths.config_file)
      assert_equal 1, text.scan(/^\s*\[location\]/).size, 'a duplicate [location] table was appended'
      parsed = Tomlrb.parse(text) # must not raise
      assert_equal false, parsed['location']['auto_update']
      assert_equal 'PaloAlto', parsed['location']['city']
    end
  end

  # The REPLACE path, which the append test above does not reach: append_key has
  # its own header matcher, so with the key already present only the section
  # TRACKER is consulted. Reverting the reader regex alone left the other test
  # green — this is the one that catches it.
  def test_a_commented_section_header_is_found_when_the_key_already_exists
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]  # my home
        latitude    = 40.7127
        longitude   = -74.0060
        city        = "New York City"
        country     = "US"
        auto_update = true

        [method]
        name = "auto"
      TOML
      OmarchyPrayer::Relocate.run(MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      text = File.read(OmarchyPrayer::Paths.config_file)
      assert_equal 1, text.scan(/^\s*auto_update/).size, 'the existing key was not rewritten'
      assert_equal false, Tomlrb.parse(text)['location']['auto_update']
    end
  end

  # Opposite intents. Sequential guards fired both, writing manual coordinates
  # with auto_update = true — the original bug — while printing "pinned".
  def test_auto_cannot_be_combined_with_a_manual_override
    with_isolated_home do
      seed
      before = File.read(OmarchyPrayer::Paths.config_file)
      err = assert_raises(SystemExit) do
        OmarchyPrayer::Relocate.run(['--auto'] + MANUAL, geolocate: FAR_AWAY, io: StringIO.new)
      end
      refute_equal 0, err.status
      assert_equal before, File.read(OmarchyPrayer::Paths.config_file), 'config was touched before aborting'
    end
  end

  # A section name is interpolated raw when a new header has to be written.
  def test_a_section_name_carrying_toml_syntax_is_refused
    with_isolated_home do
      seed
      assert_raises(ArgumentError) do
        OmarchyPrayer::BarSetting.set('k', true, OmarchyPrayer::Paths.config_file,
                                      section: "x]\nowned = 1\n[y")
      end
    end
  end

  # BarSetting.get gained the same section: parameter; nothing covered it, so a
  # mutation that ignored it left the whole suite green.
  def test_get_reads_from_the_named_section
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        shared = "locval"

        [bar]
        shared = "barval"
      TOML
      path = OmarchyPrayer::Paths.config_file
      assert_equal 'barval', OmarchyPrayer::BarSetting.get('shared', path)
      assert_equal 'locval', OmarchyPrayer::BarSetting.get('shared', path, section: 'location')
    end
  end
end
