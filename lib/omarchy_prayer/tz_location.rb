module OmarchyPrayer
  module TzLocation
    DEFAULT_TAB = '/usr/share/zoneinfo/zone1970.tab'.freeze
    ZONEINFO_PREFIX = '/usr/share/zoneinfo/'.freeze

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
  end
end
