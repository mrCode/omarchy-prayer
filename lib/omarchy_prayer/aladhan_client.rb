require 'net/http'
require 'uri'
require 'json'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class AladhanClient
    # Aladhan method IDs — https://aladhan.com/calculation-methods
    METHOD_IDS = {
      'MWL' => 3, 'ISNA' => 2, 'Egypt' => 5, 'Makkah' => 4, 'Karachi' => 1,
      'Tehran' => 7, 'Jafari' => 0, 'Kuwait' => 9, 'Qatar' => 10,
      'Singapore' => 11, 'Turkey' => 13, 'Gulf' => 8, 'Moonsighting' => 15,
      'Dubai' => 16, 'France' => 12
    }.freeze

    DEFAULT_BASE = 'https://api.aladhan.com'.freeze

    class Error < StandardError; end

    def initialize(base_url: DEFAULT_BASE, timeout: 10)
      @base = base_url
      @timeout = timeout
    end

    def fetch_month(year:, month:, lat:, lon:, method_name:)
      method_id = METHOD_IDS.fetch(method_name) do
        raise Error, "no Aladhan method id for #{method_name.inspect}"
      end
      uri = URI("#{@base}/v1/calendar/#{year}/#{month}")
      uri.query = URI.encode_www_form(
        latitude: lat, longitude: lon, method: method_id, school: 0
      )
      resp = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: @timeout, read_timeout: @timeout) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "Aladhan HTTP #{resp.code}" unless resp.code == '200'
      parsed = JSON.parse(resp.body)
      raise Error, "Aladhan payload status #{parsed['code']}" unless parsed['code'] == 200

      days = {}
      parsed['data'].each do |entry|
        date_key = reformat_date(entry.dig('date', 'gregorian', 'date'))
        days[date_key] = strip_timings(entry['timings'])
        if (h = entry.dig('date', 'hijri'))
          m = h.dig('month', 'en')
          if h['day'] && m && h['year']
            days[date_key]['hijri'] = "#{h['day']} #{m} #{h['year']}"
          end
        end
      end
      write_cache(year: year, month: month, lat: lat, lon: lon, method_name: method_name, days: days)
      days
    end

    def read_cache(year:, month:, lat:, lon:, method_name:)
      path = Paths.month_cache(cache_key(year, month, lat, lon, method_name))
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    private

    def write_cache(year:, month:, lat:, lon:, method_name:, days:)
      Paths.ensure_state_dir
      File.write(Paths.month_cache(cache_key(year, month, lat, lon, method_name)),
                 JSON.pretty_generate(days))
    end

    # Cache key includes location + method so a config change naturally lands
    # in a different file rather than returning stale times for the old city.
    def cache_key(year, month, lat, lon, method_name)
      format('%04d-%02d-lat%.4f-lon%.4f-%s',
             year, month, lat, lon,
             method_name.gsub(/[^A-Za-z0-9]/, ''))
    end

    def reformat_date(ddmmyyyy)
      d, m, y = ddmmyyyy.split('-')
      "#{y}-#{m}-#{d}"
    end

    # Aladhan returns "05:07 (EDT)"; keep the clock part only.
    #
    # The response is third-party data — this file already treats it that way
    # for `hijri`, which goes through Sanitize. `timings` did not, and
    # `split(' ', 2).first` constrains the survivor only to "contains no
    # whitespace", which an OSC 52 clipboard-write payload satisfies. From
    # there it reaches a raw-mode terminal via the TUI's prayer list. Same
    # class as the v0.3.3 finding, different trust root.
    #
    TIME_TOKEN = /\A\d{1,2}:\d{2}\z/.freeze

    # Only these are ever read — they are exactly `Today::ORDER`. Aladhan also
    # returns sunrise, imsak, midnight, firstthird and lastthird, and has added
    # fields before. `sunrise` is displayed nowhere (Today::ORDER excludes it and
    # test_status pins that), so a malformed sunrise must not cost the user their
    # month either.
    REQUIRED = %w[fajr dhuhr asr maghrib isha].freeze

    # A well-formed time passes through byte-identical, so no real response
    # changes.
    #
    # A malformed value in a REQUIRED field rejects the whole month:
    # TimesSource#safe swallows the error and the day falls through to the
    # offline calculator, which is what happened before this guard existed
    # (`nil.split` raised NoMethodError). Neutralising it in place instead would
    # hand the user a confident 00:00 and a midnight timer — silently wrong
    # times are worse than a documented fallback.
    #
    # A malformed value in any OTHER field is dropped, not raised on. Failing
    # the month over a field we never read would wire a global kill switch to a
    # third party's schema: one new key of an unexpected shape would take prayer
    # times away from every user at once, and the offline fallback it lands in
    # cannot compute above ~60 degrees latitude.
    def strip_timings(t)
      t.transform_keys(&:downcase).each_with_object({}) do |(key, value), out|
        token = value.to_s.split(' ', 2).first.to_s
        if token.match?(TIME_TOKEN)
          out[key] = token
        elsif REQUIRED.include?(key)
          raise Error, "malformed timing for #{key}: #{value.inspect}"
        end
      end
    end
  end
end
