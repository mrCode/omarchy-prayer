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

    def strip_timings(t)
      t.transform_keys(&:downcase).transform_values { |v| v.split(' ', 2).first }
    end
  end
end
