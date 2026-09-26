require 'test_helper'
require 'stringio'
require 'tomlrb'
require 'omarchy_prayer/auto_relocate'
require 'omarchy_prayer/config'
require 'omarchy_prayer/paths'

# A pinned location must not go silent when the user clearly moves.
#
# `auto_update = false` deliberately stops the app following the IP — that is
# the point of a pin. But the user then flew home and the app stayed on the
# pinned city for ELEVEN DAYS, scheduling the wrong prayers every one of them,
# saying nothing.
#
# The signal used here is the SYSTEM TIMEZONE, not IP geolocation. The timezone
# is set by the user or their OS, so a country-level disagreement between
# /etc/localtime and the pinned country is near-certain evidence of travel —
# unlike an IP result, which was 694 km wrong on the very connection that
# prompted the pin.
#
# It warns. It does NOT unpin: the user chose the pin, and silently overriding
# that would repeat the v0.4.2 bug from the other direction.
class TestStalePinWarning < Minitest::Test
  include TestHelper

  RIYADH_TZ = { latitude: 24.63, longitude: 46.71, city: 'Riyadh',
                country: 'SA', countries: ['SA'], zone: 'Asia/Riyadh' }.freeze
  US_TZ     = { latitude: 34.05, longitude: -118.24, city: 'Los Angeles',
                country: 'US', countries: ['US'], zone: 'America/Los_Angeles' }.freeze

  def seed(country: 'US', city: 'Palo Alto', auto_update: false)
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      latitude    = 37.4419
      longitude   = -122.1430
      city        = "#{city}"
      country     = "#{country}"
      auto_update = #{auto_update}
    TOML
    OmarchyPrayer::Config.load
  end

  def tz_stub(value)
    Class.new do
      define_singleton_method(:detect) { value.is_a?(Proc) ? value.call : value }
    end
  end

  # Collects notifications instead of shelling out to notify-send.
  def recorder = ->(title, body) { (@sent ||= []) << [title, body] }

  def warn(cfg, tz, io = StringIO.new)
    OmarchyPrayer::AutoRelocate.warn_stale_pin(
      cfg, tz_detect: tz_stub(tz), io: io, notify: recorder
    )
  end

  def setup = @sent = []

  # ---- the case that prompted this ---------------------------------------

  def test_warns_when_the_timezone_country_disagrees_with_the_pin
    with_isolated_home do
      cfg = seed(country: 'US', city: 'Palo Alto')
      io = StringIO.new
      assert warn(cfg, RIYADH_TZ, io), 'should report a mismatch'
      assert_equal 1, @sent.length, 'exactly one notification'
      title, body = @sent.first
      assert_match(/location/i, title)
      assert_match(/Palo Alto/, body, 'names what it is pinned to')
      assert_match(/Asia\/Riyadh|Riyadh/, body, 'names where the system thinks it is')
      assert_match(/relocate --auto/, body, 'tells the user how to fix it')
      # The re-pin form must be the one Relocate accepts: all four flags, or it
      # aborts with a usage error. Printing a command that fails, in the one
      # notification this feature exists to deliver, is worse than saying
      # nothing.
      assert_match(/--lat N --lon N --city CITY --country CC/, body,
                   'the re-pin command must be the complete form')
      assert_match(/Palo Alto/, io.string, 'and says so on stderr for the journal')
    end
  end

  def test_silent_when_the_timezone_agrees_with_the_pin
    with_isolated_home do
      cfg = seed(country: 'US')
      io = StringIO.new
      refute warn(cfg, US_TZ, io)
      assert_empty @sent
      assert_empty io.string
    end
  end

  # Auto-update already handles moving; warning there would be noise.
  def test_silent_when_not_pinned
    with_isolated_home do
      cfg = seed(country: 'US', auto_update: true)
      refute warn(cfg, RIYADH_TZ)
      assert_empty @sent
    end
  end

  # ---- must never take the schedule run down -----------------------------

  def test_silent_when_the_timezone_is_unknown
    with_isolated_home do
      cfg = seed(country: 'US')
      io = StringIO.new
      refute warn(cfg, nil, io)
      assert_empty @sent
      # Without this the guard can be deleted and the test still passes: the
      # blanket rescue yields the same nil and the same empty @sent. The
      # difference is this line, which would otherwise print on EVERY scheduler
      # run for anyone whose zone is not in zone1970.tab (Etc/UTC, backward
      # links like US/Pacific, POSIX TZ strings, containers).
      assert_empty io.string, 'an unknown timezone must be silent, not an error line'
    end
  end

  def test_never_raises_when_detection_blows_up
    with_isolated_home do
      cfg = seed(country: 'US')
      boom = tz_stub(-> { raise 'zoneinfo exploded' })
      result = OmarchyPrayer::AutoRelocate.warn_stale_pin(
        cfg, tz_detect: boom, io: StringIO.new, notify: recorder
      )
      assert_nil result
      assert_empty @sent
    end
  end

  def test_never_raises_when_notifying_fails
    with_isolated_home do
      cfg = seed(country: 'US')
      exploding = ->(_t, _b) { raise Errno::ENOENT, 'notify-send' }
      OmarchyPrayer::AutoRelocate.warn_stale_pin(
        cfg, tz_detect: tz_stub(RIYADH_TZ), io: StringIO.new, notify: exploding
      )
    end
  end

  # ---- rate limiting: the scheduler runs many times a day ----------------

  def test_does_not_renotify_for_the_same_mismatch_on_the_same_day
    with_isolated_home do
      cfg = seed(country: 'US')
      3.times { warn(cfg, RIYADH_TZ) }
      assert_equal 1, @sent.length, 'network-up and resume runs must not spam'
    end
  end

  def test_renotifies_on_a_new_day_while_still_mismatched
    with_isolated_home do
      cfg = seed(country: 'US')
      warn(cfg, RIYADH_TZ)
      # simulate tomorrow by ageing the marker
      marker = OmarchyPrayer::Paths.pin_mismatch_marker
      File.write(marker, File.read(marker).sub(Date.today.to_s, (Date.today - 1).to_s))
      warn(cfg, RIYADH_TZ)
      assert_equal 2, @sent.length, 'a daily nudge while travelling is wanted'
    end
  end

  def test_renotifies_immediately_when_the_mismatch_changes
    with_isolated_home do
      cfg = seed(country: 'US')
      warn(cfg, RIYADH_TZ)
      warn(cfg, { countries: ['FR'], zone: 'Europe/Paris', city: 'Paris', country: 'FR' })
      assert_equal 2, @sent.length, 'moving again is new information'
    end
  end

  # An unusable marker must not turn a daily warning into a per-run stream.
  def test_an_unusable_marker_does_not_notify_every_run
    with_isolated_home do
      cfg = seed(country: 'US')
      FileUtils.mkdir_p(OmarchyPrayer::Paths.pin_mismatch_marker) # a directory
      3.times { warn(cfg, RIYADH_TZ) }
      assert_equal 0, @sent.length, 'a broken marker must not fire on every run'
    end
  end

  # Someone deliberately running a non-local timezone would otherwise get a
  # persistent, non-expiring notification every day with no way out.
  def test_can_be_switched_off_in_config
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude    = 37.4419
        longitude   = -122.1430
        city        = "Palo Alto"
        country     = "US"
        auto_update = false
        warn_timezone_mismatch = false
      TOML
      refute warn(OmarchyPrayer::Config.load, RIYADH_TZ)
      assert_empty @sent
    end
  end

  # `country` is interpolated alongside `city`. The CLI validates --country
  # now, but a hand-edited config is not validated anywhere, so the display
  # path must still be safe.
  def test_sanitises_the_pinned_country_too
    with_isolated_home do
      toml_esc = '\\' + 'u001b'
      cfg = seed(country: "U#{toml_esc}]52;c;eA==S", city: 'Palo Alto')
      io = StringIO.new
      warn(cfg, RIYADH_TZ, io)
      refute_includes @sent.first[1], 27.chr, 'escape reached the notification via country'
      refute_includes io.string, 27.chr, 'escape reached the terminal via country'
    end
  end

  def test_the_body_says_how_to_silence_it
    with_isolated_home do
      warn(seed(country: 'US'), RIYADH_TZ)
      assert_match(/warn_timezone_mismatch/, @sent.first[1],
                   'a non-expiring notification must be dismissible for good')
    end
  end

  # ---- it warns; it does not act -----------------------------------------

  def test_does_not_unpin_or_touch_the_config
    with_isolated_home do
      cfg = seed(country: 'US')
      before = File.read(OmarchyPrayer::Paths.config_file)
      warn(cfg, RIYADH_TZ)
      assert_equal before, File.read(OmarchyPrayer::Paths.config_file)
      assert_equal false, Tomlrb.parse(before)['location']['auto_update']
    end
  end

  # city/country are geolocation-derived and land in a notification body, which
  # mako renders as Pango markup.
  #
  # The payload is the LITERAL six characters backslash-u-0-0-1-b: a raw ESC is
  # not valid TOML, so that is what an attacker actually sends, and tomlrb
  # decodes it to a real ESC on load. Built by concatenation so no control
  # character appears in this file.
  def test_sanitises_the_pinned_city_before_it_reaches_the_notification
    with_isolated_home do
      toml_esc = '\\' + 'u001b'
      cfg = seed(country: 'US', city: "Palo#{toml_esc}]52;c;eA== <span>Alto</span>")
      assert_includes cfg.city, 27.chr, 'fixture must carry a decoded ESC, or this tests nothing'
      warn(cfg, RIYADH_TZ)
      body = @sent.first[1]
      refute_includes body, 27.chr, 'terminal escape reached the notification'
      refute_includes body, '<span', 'markup reached the notification'
      assert_includes body, 'Palo', 'the real city name should survive'
    end
  end
end
