require 'test_helper'
require 'webrick'
require 'omarchy_prayer/adhan_manager'
require 'omarchy_prayer/paths'

class TestAdhanManager < Minitest::Test
  include TestHelper

  MP3_BYTES = 'ID3\x03\x00\x00\x00'.b + ('A' * 1024)

  def serve_bytes(bytes)
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, res| res.body = bytes; res.content_type = 'audio/mpeg' }
    thr = Thread.new { server.start }
    ["http://127.0.0.1:#{server.config[:Port]}/", server, thr]
  end

  def test_list_includes_downloaded_flag
    with_isolated_home do
      entries = OmarchyPrayer::AdhanManager.list
      assert_equal 17, entries.size
      assert entries.all? { |e| e.key?(:downloaded) && e[:downloaded] == false }
    end
  end

  def test_download_writes_file
    url, server, thr = serve_bytes(MP3_BYTES)
    with_isolated_home do
      path = OmarchyPrayer::AdhanManager.download('makkah', url_override: url, io: StringIO.new)
      assert File.exist?(path)
      assert_equal MP3_BYTES, File.binread(path)
      # After download, list shows downloaded=true for that key
      entry = OmarchyPrayer::AdhanManager.list.find { |e| e[:key] == 'makkah' }
      assert entry[:downloaded]
    end
  ensure
    server&.shutdown
    thr&.join
  end

  def test_download_unknown_key_raises
    with_isolated_home do
      assert_raises(OmarchyPrayer::AdhanManager::Error) do
        OmarchyPrayer::AdhanManager.download('bogus', io: StringIO.new)
      end
    end
  end

  def test_set_rewrites_adhan_line
    with_isolated_home do
      # Seed config + pre-downloaded file (skip_download: true).
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude = 24.7136
        longitude = 46.6753
        city = "Riyadh"
        country = "SA"

        [audio]
        enabled    = true
        player     = "mpv"
        adhan      = "~/.config/omarchy-prayer/adhan.mp3"
        adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
        volume     = 80
      TOML
      # Pre-create the adhan file to avoid network.
      FileUtils.mkdir_p(OmarchyPrayer::AdhanManager.adhan_dir)
      File.write(OmarchyPrayer::AdhanManager.local_path('makkah'), MP3_BYTES)

      OmarchyPrayer::AdhanManager.set('makkah', skip_download: true, io: StringIO.new)

      text = File.read(OmarchyPrayer::Paths.config_file)
      expected = OmarchyPrayer::AdhanManager.local_path('makkah')
      assert_match(/^\s*adhan\s*=\s*"#{Regexp.escape(expected)}"/m, text)
      # adhan_fajr untouched
      assert_match(%r{adhan_fajr\s*=\s*"~/\.config/omarchy-prayer/adhan-fajr\.mp3"}, text)
    end
  end

  def test_set_fajr_only_rewrites_fajr_line
    with_isolated_home do
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [location]
        latitude = 24.7136
        longitude = 46.6753
        city = "Riyadh"
        country = "SA"

        [audio]
        adhan      = "~/.config/omarchy-prayer/adhan.mp3"
        adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
      TOML
      FileUtils.mkdir_p(OmarchyPrayer::AdhanManager.adhan_dir)
      File.write(OmarchyPrayer::AdhanManager.local_path('al-aqsa'), MP3_BYTES)

      OmarchyPrayer::AdhanManager.set('al-aqsa', fajr: true, skip_download: true, io: StringIO.new)

      text = File.read(OmarchyPrayer::Paths.config_file)
      expected = OmarchyPrayer::AdhanManager.local_path('al-aqsa')
      assert_match(/^\s*adhan_fajr\s*=\s*"#{Regexp.escape(expected)}"/m, text)
      # adhan untouched
      assert_match(%r{^\s*adhan\s*=\s*"~/\.config/omarchy-prayer/adhan\.mp3"}, text)
    end
  end

  def test_current_returns_expanded_paths
    with_isolated_home do |home|
      FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
      File.write(OmarchyPrayer::Paths.config_file, <<~TOML)
        [audio]
        adhan      = "~/some/path.mp3"
        adhan_fajr = "/abs/fajr.mp3"
      TOML
      cur = OmarchyPrayer::AdhanManager.current
      assert_equal "#{home}/some/path.mp3", cur[:adhan]
      assert_equal '/abs/fajr.mp3', cur[:adhan_fajr]
    end
  end
end
