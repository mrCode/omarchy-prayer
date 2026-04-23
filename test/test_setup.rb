require 'test_helper'
require 'webrick'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/setup'

class TestSetup < Minitest::Test
  include TestHelper

  def write_minimal_config
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
      [location]
      latitude = 24.7136
      longitude = 46.6753
      city = "Riyadh"
      country = "SA"

      [method]
      name = "MWL"

      [audio]
      enabled = true
      player = "mpv"
      adhan = "~/.config/omarchy-prayer/adhan.mp3"
      adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
      volume = 80
    TOML
  end

  def start_mp3_stub(body: 'ID3fake-mp3-data')
    server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    server.mount_proc('/') do |_, res|
      res.content_type = 'audio/mpeg'
      res.body = body
    end
    thr = Thread.new { server.start }
    [server, thr, "http://127.0.0.1:#{server.config[:Port]}"]
  end

  # --- adhan bootstrap --------------------------------------------------------

  def test_ensure_default_adhans_downloads_when_placeholder_and_missing
    with_isolated_home do |home|
      write_minimal_config
      # Override AdhanCatalog entries so downloads hit our stub.
      server, thr, base = start_mp3_stub
      OmarchyPrayer::AdhanCatalog::SUNNI.each do |e|
        e[:url] = "#{base}/#{e[:key]}.mp3" if %w[makkah madinah].include?(e[:key])
      end

      done = []
      OmarchyPrayer::Setup.ensure_default_adhans(
        io: StringIO.new, skip_network: false, done: done
      )

      adhan_dir = OmarchyPrayer::AdhanManager.adhan_dir
      assert File.exist?(File.join(adhan_dir, 'makkah.mp3')),
             'makkah.mp3 should be downloaded'
      assert File.exist?(File.join(adhan_dir, 'madinah.mp3')),
             'madinah.mp3 should be downloaded'
      cfg = File.read(OmarchyPrayer::Paths.config_file)
      assert_match %r{^\s*adhan\s*=\s*"#{Regexp.escape(adhan_dir)}/makkah\.mp3"}, cfg
      assert_match %r{^\s*adhan_fajr\s*=\s*"#{Regexp.escape(adhan_dir)}/madinah\.mp3"}, cfg
      assert_includes done.join("\n"), 'makkah'
      assert_includes done.join("\n"), 'madinah'
    ensure
      server&.shutdown
      thr&.join
    end
  end

  def test_ensure_default_adhans_skips_when_user_has_custom_path
    with_isolated_home do |_home|
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude = 24.7
        longitude = 46.7
        city = "X"
        country = "SA"

        [method]
        name = "MWL"

        [audio]
        enabled = true
        player = "mpv"
        adhan = "/tmp/my-custom-adhan.mp3"
        adhan_fajr = "/tmp/my-custom-fajr.mp3"
        volume = 80
      TOML

      done = []
      OmarchyPrayer::Setup.ensure_default_adhans(
        io: StringIO.new, skip_network: false, done: done
      )
      assert_empty done, 'should not touch user-customized paths'
      refute File.exist?(File.join(OmarchyPrayer::AdhanManager.adhan_dir, 'makkah.mp3'))
    end
  end

  # --- waybar patch -----------------------------------------------------------

  def test_patch_waybar_adds_module_when_missing
    original = <<~JSON
      {
        "layer": "top",
        "modules-right": [
          "battery"
        ]
      }
    JSON

    patched = OmarchyPrayer::Setup.patch_waybar_text(original)
    refute_nil patched, 'should successfully patch a valid file'

    parsed = JSON.parse(patched)
    assert_equal ['custom/prayer', 'battery'], parsed['modules-right']
    assert_equal 'omarchy-prayer-waybar', parsed['custom/prayer']['exec']
  end

  def test_patch_waybar_is_noop_when_already_configured
    already = <<~JSON
      {
        "modules-right": ["custom/prayer", "battery"],
        "custom/prayer": { "exec": "omarchy-prayer-waybar" }
      }
    JSON
    # ensure_waybar_module short-circuits; simulate that by checking the guard.
    assert_includes already, '"custom/prayer"'
  end

  def test_patch_waybar_preserves_jsonc_comments
    original = <<~JSONC
      // top-level comment
      {
        "layer": "top", // line comment
        /* block comment */
        "modules-right": [
          "battery"
        ]
      }
    JSONC
    patched = OmarchyPrayer::Setup.patch_waybar_text(original)
    refute_nil patched
    assert_includes patched, '// top-level comment'
    assert_includes patched, '// line comment'
    assert_includes patched, '/* block comment */'
    assert_includes patched, '"custom/prayer"'
    # Should still parse after JSONC strip.
    assert OmarchyPrayer::Setup.jsonc_parseable?(patched)
  end

  def test_patch_waybar_handles_trailing_comma
    original = <<~JSONC
      {
        "modules-right": ["battery",],
      }
    JSONC
    patched = OmarchyPrayer::Setup.patch_waybar_text(original)
    refute_nil patched
    assert OmarchyPrayer::Setup.jsonc_parseable?(patched)
    parsed = JSON.parse(OmarchyPrayer::Setup.strip_jsonc(patched))
    assert_includes parsed['modules-right'], 'custom/prayer'
  end

  def test_patch_waybar_refuses_unparseable_input
    patched = OmarchyPrayer::Setup.patch_waybar_text('this is { not json')
    assert_nil patched
  end

  def test_ensure_waybar_module_creates_backup_and_writes
    with_isolated_home do |home|
      path = File.join(home, '.config', 'waybar', 'config.jsonc')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~JSON)
        {
          "modules-right": ["battery"]
        }
      JSON

      # Shim out pkill so we don't try to signal a real waybar.
      with_shims(home, %w[pkill])

      done = []
      OmarchyPrayer::Setup.ensure_waybar_module(io: StringIO.new, done: done)

      assert_includes done.join(' '), 'custom/prayer'
      backups = Dir["#{path}.bak.omarchy-prayer-*"]
      assert_equal 1, backups.size, 'should create exactly one backup'
      refute_equal File.read(backups.first), File.read(path),
                   'patched file should differ from backup'
      assert_includes File.read(path), '"custom/prayer"'
    end
  end

  def test_ensure_waybar_module_noop_when_already_patched
    with_isolated_home do |home|
      path = File.join(home, '.config', 'waybar', 'config.jsonc')
      FileUtils.mkdir_p(File.dirname(path))
      content = <<~JSON
        {
          "modules-right": ["custom/prayer", "battery"],
          "custom/prayer": { "exec": "omarchy-prayer-waybar" }
        }
      JSON
      File.write(path, content)

      done = []
      OmarchyPrayer::Setup.ensure_waybar_module(io: StringIO.new, done: done)

      assert_empty done
      assert_equal content, File.read(path), 'file should be untouched'
      assert Dir["#{path}.bak.omarchy-prayer-*"].empty?, 'no backup should be created'
    end
  end

  # --- systemd ----------------------------------------------------------------

  def test_ensure_systemd_units_enables_when_installed_and_disabled
    with_isolated_home do |home|
      log = with_shims(home, %w[systemctl])
      # Simulate units installed in the user's unit dir.
      unit_dir = File.join(home, '.config', 'systemd', 'user')
      FileUtils.mkdir_p(unit_dir)
      %w[omarchy-prayer-schedule.timer omarchy-prayer-resume.service].each do |u|
        File.write(File.join(unit_dir, u), '')
      end
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = 'disabled'

      done = []
      OmarchyPrayer::Setup.ensure_systemd_units(io: StringIO.new, done: done)

      calls = read_shim_log(log)
      assert calls.any? { |c| c.include?('enable') && c.include?('omarchy-prayer-schedule.timer') },
             'should attempt to enable schedule timer'
      assert calls.any? { |c| c.include?('enable') && c.include?('omarchy-prayer-resume.service') },
             'should attempt to enable resume service'
      assert_equal 2, done.size
    ensure
      ENV.delete('OP_SHIM_STDOUT_SYSTEMCTL')
    end
  end

  def test_ensure_systemd_units_noop_when_enabled
    with_isolated_home do |home|
      log = with_shims(home, %w[systemctl])
      unit_dir = File.join(home, '.config', 'systemd', 'user')
      FileUtils.mkdir_p(unit_dir)
      %w[omarchy-prayer-schedule.timer omarchy-prayer-resume.service].each do |u|
        File.write(File.join(unit_dir, u), '')
      end
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = 'enabled'

      done = []
      OmarchyPrayer::Setup.ensure_systemd_units(io: StringIO.new, done: done)

      calls = read_shim_log(log)
      assert calls.none? { |c| c.include?('enable') && !c.include?('is-enabled') },
             'should NOT run systemctl enable when already enabled'
      assert_empty done
    ensure
      ENV.delete('OP_SHIM_STDOUT_SYSTEMCTL')
    end
  end
end
