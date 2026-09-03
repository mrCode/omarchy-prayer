require 'json'
require 'date'
require 'time'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/sanitize'

module OmarchyPrayer
  class Today
    ORDER = %i[fajr dhuhr asr maghrib isha].freeze

    # A clock time and nothing else. Times originate in the Aladhan response and
    # are printed to raw-mode terminals (`omarchy-prayer today`, the TUI) and
    # into a Pango-parsed waybar label, so they are attacker-influenced data on
    # a display path.
    #
    # Sanitising at ingress in AladhanClient is NOT sufficient: the month cache
    # and today.json are both re-read verbatim, and TimesSource PREFERS the
    # cache over the API — so a payload written by an older version keeps being
    # served for the rest of the month. This is the same reasoning Status
    # already applies to `city`, which may hold a poisoned value from before its
    # guard existed. Enforce it here, where every consumer inherits it.
    TIME_TOKEN = /\A\d{1,2}:\d{2}\z/.freeze

    attr_reader :date, :tz_offset, :city, :country, :method, :source, :times, :hijri

    def initialize(date:, tz_offset:, city:, country:, method:, source:, times:, hijri: nil)
      @date = date; @tz_offset = tz_offset
      @city = city; @country = country
      @method = method; @source = source
      @times = clean_times(symbolize(times))
      @hijri = hijri
    end

    # Well-formed times pass through byte-identical, so nothing about a normal
    # install changes.
    #
    # nil is preserved rather than coerced. `""` would reach `time_for` as
    # midnight, so Scheduler's `next unless hhmm` guard would stop skipping the
    # prayer and would instead arm a real timer at 00:00 — the same "confident
    # 00:00" this project rejects at ingress. A missing prayer must stay missing.
    def clean_times(times)
      times.transform_values do |v|
        next v   if v.is_a?(String) && v.match?(TIME_TOKEN)
        next nil if v.nil?
        Sanitize.display(v.to_s)
      end
    end
    private :clean_times

    def self.read(path = Paths.today_json)
      data = JSON.parse(File.read(path))
      new(
        date: data['date'], tz_offset: data['tz_offset'],
        city: data['city'], country: data['country'],
        method: data['method'], source: data['source'],
        times: data['times'], hijri: data['hijri']
      )
    end

    def write(path = Paths.today_json)
      Paths.ensure_state_dir
      File.write(path, JSON.pretty_generate(
        date: @date, tz_offset: @tz_offset, city: @city, country: @country,
        method: @method, source: @source,
        times: @times.transform_keys(&:to_s), hijri: @hijri
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
