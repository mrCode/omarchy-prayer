require 'test_helper'
require 'omarchy_prayer/times_source'

class TestTimesSource < Minitest::Test
  include TestHelper

  # StubClient records calls and returns configured values.
  class StubClient
    attr_reader :calls
    def initialize(behavior); @behavior = behavior; @calls = []; end
    def read_cache(year:, month:)
      @calls << [:read_cache, year, month]
      @behavior[:cache]
    end
    def fetch_month(year:, month:, lat:, lon:, method_name:)
      @calls << [:fetch_month, year, month, method_name]
      raise @behavior[:fetch_error] if @behavior[:fetch_error]
      @behavior[:fetched]
    end
  end

  FAKE_DAY = { 'fajr' => '04:15', 'sunrise' => '05:35', 'dhuhr' => '11:48',
               'asr' => '15:18', 'maghrib' => '18:01', 'isha' => '19:21' }

  def base_args
    { year: 2026, month: 4, day: '2026-04-22', lat: 24.7136, lon: 46.6753,
      method_name: 'MWL', tz_offset: 10800, offline_fallback: ->(*) { FAKE_DAY } }
  end

  def test_cache_hit_skips_fetch
    client = StubClient.new(cache: { '2026-04-22' => FAKE_DAY })
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'cache',   src
    assert_equal '04:15',   times['fajr']
    refute(client.calls.any? { |c| c[0] == :fetch_month })
  end

  def test_cache_miss_fetches
    client = StubClient.new(cache: nil, fetched: { '2026-04-22' => FAKE_DAY })
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'api',     src
    assert_equal '04:15',   times['fajr']
  end

  def test_fetch_failure_falls_to_offline
    client = StubClient.new(cache: nil, fetch_error: StandardError.new('network down'))
    src, times = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'offline', src
    assert_equal '04:15',   times['fajr']
  end

  def test_cache_present_but_missing_day_falls_through
    other = { '2026-04-01' => FAKE_DAY }
    client = StubClient.new(cache: other, fetched: { '2026-04-22' => FAKE_DAY })
    src, _ = OmarchyPrayer::TimesSource.new(client: client).resolve(**base_args)
    assert_equal 'api', src
  end
end
