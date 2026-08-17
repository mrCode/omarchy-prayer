require 'tomlrb'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/bar_preset'
require 'omarchy_prayer/prayer_names'

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
      'audio'         => { 'enabled' => false, 'player' => 'mpv',
                           'adhan' => '~/.config/omarchy-prayer/adhan.mp3',
                           'adhan_fajr' => '~/.config/omarchy-prayer/adhan-fajr.mp3',
                           'volume' => 80 },
      'bar'           => { 'format' => '{city} · {prayer} {countdown}',
                           'soon_threshold_minutes' => 10,
                           'names' => 'latin',
                           'compact_countdown' => false,
                           'quiet_until_minutes' => 0 }
    }.freeze

    attr_reader :raw

    def self.load(path = Paths.config_file)
      raise MissingError, "config.toml not found at #{path} — run `omarchy-prayer` to bootstrap" unless File.exist?(path)
      new(Tomlrb.load_file(path, symbolize_keys: false))
    end

    def initialize(raw)
      @raw = merge_defaults(normalize_bar_section(raw))
      validate!
    end

    def latitude;  @raw['location']['latitude'];  end
    def longitude; @raw['location']['longitude']; end
    def city;      @raw['location']['city'];      end
    def country;   @raw['location']['country'];   end

    def auto_update?
      @raw['location'].fetch('auto_update', true)
    end

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

    def bar_format;             @raw['bar']['format'];                 end
    def soon_threshold_minutes; @raw['bar']['soon_threshold_minutes']; end

    # Derived, never stored — see BarPreset.
    def bar_preset; BarPreset.name_for(bar_format); end

    def names_script
      value = @raw['bar']['names'].to_s
      PrayerNames::SCRIPTS.include?(value) ? value : PrayerNames::DEFAULT_SCRIPT
    end

    def compact_countdown?
      @raw['bar']['compact_countdown'] == true
    end

    # 0 disables. Anything negative or non-numeric is treated as disabled
    # rather than raising — a typo here must never break the bar.
    def quiet_until_minutes
      value = @raw['bar']['quiet_until_minutes']
      return 0 unless value.is_a?(Numeric)
      value.to_i.negative? ? 0 : value.to_i
    end

    # Retained so existing callers keep working after the [waybar] -> [bar]
    # rename.
    def waybar_format; bar_format; end

    private

    # An unmigrated config still has [waybar]. Promote it before defaults are
    # merged, so the user's values win rather than being masked by defaults.
    def normalize_bar_section(raw)
      return raw unless raw.is_a?(Hash)
      return raw if raw.key?('bar') || !raw.key?('waybar')
      copy = raw.dup
      copy['bar'] = copy.delete('waybar')
      copy
    end

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
      if loc.key?('auto_update') && ![true, false].include?(loc['auto_update'])
        raise InvalidError, '[location].auto_update must be a boolean'
      end

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
