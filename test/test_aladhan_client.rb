require 'test_helper'
require 'webrick'
require 'omarchy_prayer/aladhan_client'

class TestAladhanClient < Minitest::Test
  include TestHelper

  def setup
    @fixture = File.read(File.expand_path('fixtures/aladhan_april_2026.json', __dir__))
    @captured_path = nil
    @server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc('/') do |req, res|
      @captured_path = req.path + '?' + (req.query_string || '')
      res.content_type = 'application/json'
      res.body = @fixture
    end
    @thread = Thread.new { @server.start }
    @base = "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def teardown
    @server&.shutdown
    @thread&.join
  end

  def test_fetch_month_returns_day_map
    with_isolated_home do
      days = OmarchyPrayer::AladhanClient.new(base_url: @base).fetch_month(
        year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'MWL'
      )
      assert_equal 2, days.size
      entry = days['2026-04-22']
      assert_equal '04:14', entry['fajr']
      assert_equal '19:22', entry['isha']
      assert_equal '5 Dhū al-Qaʿdah 1447', entry['hijri']
    end
  end

  def test_url_includes_method_and_coords
    with_isolated_home do
      OmarchyPrayer::AladhanClient.new(base_url: @base).fetch_month(
        year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'Makkah'
      )
    end
    assert_match %r{/v1/calendar/2026/4\?}, @captured_path
    assert_match(/method=4/,                @captured_path)   # Makkah == 4 per Aladhan
    assert_match(/latitude=24.7136/,        @captured_path)
    assert_match(/longitude=46.6753/,       @captured_path)
  end

  def test_cache_roundtrip
    with_isolated_home do
      client = OmarchyPrayer::AladhanClient.new(base_url: @base)
      first = client.fetch_month(year: 2026, month: 4, lat: 24.7136, lon: 46.6753, method_name: 'MWL')
      cache_file = OmarchyPrayer::Paths.month_cache('2026-04')
      assert File.exist?(cache_file)
      # Prove second call works without server.
      @server.shutdown; @thread.join; @server = nil
      second = client.read_cache(year: 2026, month: 4)
      assert_equal first, second
    end
  end
end
