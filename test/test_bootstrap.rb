require 'test_helper'
require 'webrick'
require 'date'
require 'omarchy_prayer/paths'

class TestBootstrap < Minitest::Test
  include TestHelper

  FIXTURE_DIR = File.expand_path('fixtures', __dir__)
  PROJECT     = File.expand_path('..', __dir__)

  def setup
    @body = File.read(File.join(FIXTURE_DIR, 'aladhan_april_2026.json'))
  end

  def start_aladhan_stub
    server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    server.mount_proc('/') { |_, res| res.content_type = 'application/json'; res.body = @body }
    thr = Thread.new { server.start }
    [server, thr, "http://127.0.0.1:#{server.config[:Port]}"]
  end

  def write_config
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      latitude = 24.7136
      longitude = 46.6753
      city = "Riyadh"
      country = "SA"

      [method]
      name = "MWL"
    TOML
  end

  def run_today
    `RUBYLIB=#{PROJECT}/lib #{PROJECT}/bin/omarchy-prayer today 2>&1`
  end

  def test_today_bootstraps_when_cache_missing
    server, thr, base = start_aladhan_stub
    with_isolated_home do |home|
      with_shims(home, %w[systemd-run systemctl notify-send mpv makoctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      ENV['OMARCHY_PRAYER_ALADHAN_BASE'] = base
      write_config

      refute File.exist?(OmarchyPrayer::Paths.today_json),
             'precondition: today.json should not exist'

      out = run_today
      assert_equal 0, $?.exitstatus,
                   "omarchy-prayer today exited #{$?.exitstatus}. output:\n#{out}"
      assert_match(/fajr\s+\d\d:\d\d/, out,
                   "expected a 'fajr HH:MM' line, got:\n#{out}")
      assert File.exist?(OmarchyPrayer::Paths.today_json),
             'today.json should be created by bootstrap'
    ensure
      ENV.delete('OMARCHY_PRAYER_ALADHAN_BASE')
    end
  ensure
    server&.shutdown
    thr&.join
  end

  def test_today_uses_cache_when_fresh
    with_isolated_home do |home|
      with_shims(home, %w[systemd-run systemctl notify-send mpv makoctl])
      write_config

      OmarchyPrayer::Paths.ensure_state_dir
      File.write(OmarchyPrayer::Paths.today_json, JSON.pretty_generate(
        date: Date.today.strftime('%Y-%m-%d'),
        tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'MWL', source: 'cache',
        times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
                 asr: '15:18', maghrib: '18:01', isha: '19:21' }
      ))

      # No Aladhan base + no fixture server: if bootstrap ran, it would still
      # likely succeed via offline_calc, but we assert the cached values are
      # used by checking the marker time we wrote above.
      out = run_today
      assert_equal 0, $?.exitstatus, out
      assert_match(/fajr\s+04:15/, out)
    end
  end

  def test_today_rebootstraps_when_cache_stale
    server, thr, base = start_aladhan_stub
    with_isolated_home do |home|
      with_shims(home, %w[systemd-run systemctl notify-send mpv makoctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      ENV['OMARCHY_PRAYER_ALADHAN_BASE'] = base
      write_config

      yesterday = (Date.today - 1).strftime('%Y-%m-%d')
      OmarchyPrayer::Paths.ensure_state_dir
      File.write(OmarchyPrayer::Paths.today_json, JSON.pretty_generate(
        date: yesterday,
        tz_offset: 10800, city: 'Riyadh', country: 'SA',
        method: 'MWL', source: 'cache',
        times: { fajr: '03:00', sunrise: '04:00', dhuhr: '12:00',
                 asr: '15:00', maghrib: '18:00', isha: '19:00' }
      ))

      out = run_today
      assert_equal 0, $?.exitstatus, out
      data = JSON.parse(File.read(OmarchyPrayer::Paths.today_json))
      assert_equal Date.today.strftime('%Y-%m-%d'), data['date'],
                   'stale cache should have been replaced with today'
    ensure
      ENV.delete('OMARCHY_PRAYER_ALADHAN_BASE')
    end
  ensure
    server&.shutdown
    thr&.join
  end
end
