require 'omarchy_prayer/aladhan_client'

module OmarchyPrayer
  class TimesSource
    def initialize(client: AladhanClient.new)
      @client = client
    end

    # Returns [source_label, day_hash] where source_label ∈ {cache, api, offline}.
    def resolve(year:, month:, day:, lat:, lon:, method_name:, tz_offset:, offline_fallback:)
      cached = safe { @client.read_cache(year: year, month: month) }
      if cached && cached[day]
        return ['cache', cached[day]]
      end
      fetched = safe { @client.fetch_month(year: year, month: month, lat: lat, lon: lon, method_name: method_name) }
      if fetched && fetched[day]
        return ['api', fetched[day]]
      end
      ['offline', offline_fallback.call(day: day, lat: lat, lon: lon, method_name: method_name, tz_offset: tz_offset)]
    end

    private

    def safe
      yield
    rescue StandardError
      nil
    end
  end
end
