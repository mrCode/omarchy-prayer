require 'tomlrb'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Config
    class MissingError < StandardError; end
    class InvalidError < StandardError; end

    KNOWN_METHODS = %w[
      auto MWL ISNA Egypt Makkah Karachi Tehran Jafari Kuwait Qatar
      Singapore Turkey Gulf Moonsighting Dubai France
    ].freeze

    DEFAULTS = {
      'method'        => { 'name' => 'auto' },
      'offsets'       => { 'fajr' => 0, 'dhuhr' => 0, 'asr' => 0, 'maghrib' => 0, 'isha' => 0 },
      'notifications' => { 'enabled' => true, 'pre_notify_minutes' => 10, 'respect_silencing' => true },
      'audio'         => { 'enabled' => true, 'player' => 'mpv',
                           'adhan' => '~/.config/omarchy-prayer/adhan.mp3',
                           'adhan_fajr' => '~/.config/omarchy-prayer/adhan-fajr.mp3',
                           'volume' => 80 },
      'waybar'        => { 'format' => '{prayer} {countdown}', 'soon_threshold_minutes' => 10 }
    }.freeze

    attr_reader :raw

    def self.load(path = Paths.config_file)
      raise MissingError, "config.toml not found at #{path} — run `omarchy-prayer` to bootstrap" unless File.exist?(path)
      new(Tomlrb.load_file(path, symbolize_keys: false))
    end

    def initialize(raw)
      @raw = merge_defaults(raw)
      validate!
    end

    def latitude;  @raw['location']['latitude'];  end
    def longitude; @raw['location']['longitude']; end
    def city;      @raw['location']['city'];      end
    def country;   @raw['location']['country'];   end

    def method_name; @raw['method']['name']; end

    def offsets
      @raw['offsets'].transform_keys(&:to_sym).transform_values(&:to_i)
    end

    def notifications_enabled;   @raw['notifications']['enabled'];            end
    def pre_notify_minutes;      @raw['notifications']['pre_notify_minutes']; end
    def respect_silencing;       @raw['notifications']['respect_silencing']; end

    def audio_enabled; @raw['audio']['enabled']; end
    def audio_player;  @raw['audio']['player'];  end
    def volume;        @raw['audio']['volume'];  end
    def adhan_path;      Paths.expand(@raw['audio']['adhan']);      end
    def adhan_fajr_path; Paths.expand(@raw['audio']['adhan_fajr']); end

    def waybar_format;          @raw['waybar']['format'];                 end
    def soon_threshold_minutes; @raw['waybar']['soon_threshold_minutes']; end

    private

    def merge_defaults(raw)
      result = DEFAULTS.each_with_object({}) { |(k, v), h| h[k] = v.dup }
      raw.each do |k, v|
        result[k] = v.is_a?(Hash) && result[k].is_a?(Hash) ? result[k].merge(v) : v
      end
      result
    end

    def validate!
      loc = @raw['location']
      raise InvalidError, '[location] section required' unless loc.is_a?(Hash)
      %w[latitude longitude].each do |k|
        raise InvalidError, "[location].#{k} must be a number" unless loc[k].is_a?(Numeric)
      end
      raise InvalidError, '[location].latitude out of range (-90..90)'   unless (-90..90).cover?(loc['latitude'])
      raise InvalidError, '[location].longitude out of range (-180..180)' unless (-180..180).cover?(loc['longitude'])

      unless KNOWN_METHODS.include?(@raw['method']['name'])
        raise InvalidError, "[method].name #{@raw['method']['name'].inspect} unknown (try: #{KNOWN_METHODS.join(', ')})"
      end

      vol = @raw['audio']['volume']
      raise InvalidError, '[audio].volume must be 0..100' unless vol.is_a?(Integer) && (0..100).cover?(vol)

      pm = @raw['notifications']['pre_notify_minutes']
      raise InvalidError, '[notifications].pre_notify_minutes must be 0..120' unless pm.is_a?(Integer) && (0..120).cover?(pm)
    end
  end
end
