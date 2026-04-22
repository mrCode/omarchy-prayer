require 'json'
require 'date'
require 'time'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Today
    ORDER = %i[fajr dhuhr asr maghrib isha].freeze

    attr_reader :date, :tz_offset, :city, :country, :method, :source, :times

    def initialize(date:, tz_offset:, city:, country:, method:, source:, times:)
      @date = date; @tz_offset = tz_offset
      @city = city; @country = country
      @method = method; @source = source
      @times = symbolize(times)
    end

    def self.read(path = Paths.today_json)
      data = JSON.parse(File.read(path))
      new(
        date: data['date'], tz_offset: data['tz_offset'],
        city: data['city'], country: data['country'],
        method: data['method'], source: data['source'],
        times: data['times']
      )
    end

    def write(path = Paths.today_json)
      Paths.ensure_state_dir
      File.write(path, JSON.pretty_generate(
        date: @date, tz_offset: @tz_offset, city: @city, country: @country,
        method: @method, source: @source,
        times: @times.transform_keys(&:to_s)
      ))
    end

    def time_for(prayer)
      h, m = @times.fetch(prayer).split(':').map(&:to_i)
      y, mo, d = @date.split('-').map(&:to_i)
      Time.new(y, mo, d, h, m, 0, @tz_offset)
    end

    def next_prayer(now: Time.now)
      ORDER.each do |p|
        t = time_for(p)
        return [p, t] if t > now
      end
      # All five passed — tomorrow's fajr.
      tomorrow = Date.parse(@date).next
      h, m = @times.fetch(:fajr).split(':').map(&:to_i)
      [:fajr_tomorrow, Time.new(tomorrow.year, tomorrow.month, tomorrow.day, h, m, 0, @tz_offset)]
    end

    private

    def symbolize(h)
      h.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
