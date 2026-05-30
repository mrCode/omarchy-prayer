module OmarchyPrayer
  module TzLocation
    DEFAULT_TAB = '/usr/share/zoneinfo/zone1970.tab'.freeze
    ZONEINFO_PREFIX = '/usr/share/zoneinfo/'.freeze

    # ISO 6709 ±DDMM±DDDMM (11 chars) or ±DDMMSS±DDDMMSS (15 chars).
    SHORT_RE = /\A([+-]\d{2})(\d{2})([+-]\d{3})(\d{2})\z/
    LONG_RE  = /\A([+-]\d{2})(\d{2})(\d{2})([+-]\d{3})(\d{2})(\d{2})\z/

    module_function

    def zone_name
      env = ENV['TZ']
      return env if env && !env.empty?

      begin
        real = File.realpath('/etc/localtime')
        return real.sub(ZONEINFO_PREFIX, '') if real.start_with?(ZONEINFO_PREFIX)
      rescue Errno::ENOENT, Errno::EINVAL
        # /etc/localtime missing or not a symlink — fall through
      end

      out = `timedatectl show -p Timezone --value 2>/dev/null`.strip
      return out unless out.empty?

      nil
    rescue StandardError
      nil
    end

    def parse_iso6709(s)
      return nil if s.nil? || s.empty?
      if (m = LONG_RE.match(s))
        return [dms_to_deg(m[1], m[2], m[3]), dms_to_deg(m[4], m[5], m[6])]
      end
      if (m = SHORT_RE.match(s))
        return [dms_to_deg(m[1], m[2], '00'), dms_to_deg(m[3], m[4], '00')]
      end
      nil
    end

    def dms_to_deg(deg_signed, min_str, sec_str)
      sign = deg_signed.start_with?('-') ? -1 : 1
      deg = deg_signed.to_i.abs
      sign * (deg + min_str.to_i / 60.0 + sec_str.to_i / 3600.0)
    end
  end
end
