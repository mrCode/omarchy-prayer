require 'test_helper'
require 'webrick'
require 'omarchy_prayer/paths'

class TestSmoke < Minitest::Test
  include TestHelper

  FIXTURE_DIR = File.expand_path('fixtures', __dir__)

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

  def test_schedule_end_to_end
    server, thr, base = start_aladhan_stub
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl notify-send mpv makoctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''

      # Pre-write config (skip first-run geolocation).
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

      ENV['OMARCHY_PRAYER_ALADHAN_BASE'] = base
      project = File.expand_path('..', __dir__)
      ok = system({'RUBYLIB' => "#{project}/lib"},
                  "#{project}/bin/omarchy-prayer-schedule")
      assert ok, 'omarchy-prayer-schedule exited non-zero'

      today_path = OmarchyPrayer::Paths.today_json
      assert File.exist?(today_path), "today.json not written at #{today_path}"
      content = File.read(today_path)
      # Source may be cache, api, or offline depending on whether today's date
      # matches the fixture (which has entries for 2026-04-01 and 2026-04-22).
      assert_match(/"source":\s*"(cache|api|offline)"/, content)

      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      assert calls.size >= 5, "expected at least 5 systemd-run calls, got #{calls.size}"
    ensure
      ENV.delete('OMARCHY_PRAYER_ALADHAN_BASE')
    end
  ensure
    server&.shutdown
    thr&.join
  end
end
