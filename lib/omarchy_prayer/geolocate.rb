require 'net/http'
require 'uri'
require 'json'
require 'omarchy_prayer/tz_location'
require 'omarchy_prayer/sanitize'

module OmarchyPrayer
  module Geolocate
    class Error < StandardError; end

    # HTTPS is mandatory. This response is a trust root: its coordinates are
    # written into config.toml by auto-relocate and drive every prayer time and
    # systemd timer thereafter, and auto-relocate runs on every network
    # connection-up via the NetworkManager dispatcher. Over cleartext, anyone
    # on-path on a hostile network could permanently move a user's prayer
    # times. ip-api.com's free tier is HTTP-only, hence this provider.
    DEFAULT_URL = 'https://ipwho.is/'.freeze

    # Loopback is exempt from the HTTPS requirement: the test suite serves a
    # stub over http://127.0.0.1 and nobody can sit on-path inside loopback.
    LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

    NETWORK_ERRORS = [
      Error, SocketError,
      Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH,
      Timeout::Error
    ].freeze

    module_function

    DEFAULT_IP_DETECT = ->(*args, **kw) { Geolocate.detect_ip(*args, **kw) }
    DEFAULT_TZ_DETECT = -> { TzLocation.detect }

    def detect(ip_detect: DEFAULT_IP_DETECT, tz_detect: DEFAULT_TZ_DETECT, io: $stderr)
      ip = safe_ip(ip_detect)
      tz = safe_tz(tz_detect)

      if ip && tz
        return ip if tz[:countries].include?(ip[:country].to_s.upcase)
        io.puts format('omarchy-prayer: IP→%s, %s but timezone is %s — using %s, %s',
                       ip[:city], ip[:country], tz[:zone], tz[:city], tz[:country])
        return tz_to_loc(tz)
      end

      return ip if ip
      return tz_to_loc(tz) if tz
      raise Error, 'no location signal available (IP failed, timezone unresolved)'
    end

    def safe_ip(callable)
      callable.call
    rescue *NETWORK_ERRORS
      nil
    end

    def safe_tz(callable)
      callable.call
    rescue StandardError
      nil
    end

    def tz_to_loc(tz)
      { latitude: tz[:latitude], longitude: tz[:longitude],
        city: tz[:city], country: tz[:country] }
    end

    def detect_ip(url: DEFAULT_URL, timeout: 5)
      uri = URI(url)
      require_secure_transport!(uri)

      resp = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "geolocation HTTP #{resp.code}" unless resp.code == '200'

      parse_payload(JSON.parse(resp.body))
    end

    # Refuse to downgrade rather than silently sending this over cleartext.
    def require_secure_transport!(uri)
      return if uri.scheme == 'https'
      return if LOOPBACK_HOSTS.include?(uri.host)
      raise Error, "refusing non-HTTPS geolocation endpoint: #{uri}"
    end

    # Accepts both the ipwho.is shape (success/latitude/longitude/country_code)
    # and the older ip-api shape (status/lat/lon/countryCode), so a pinned
    # endpoint or an existing stub keeps working. Every field is validated:
    # this data is attacker-influenced and ends up on disk.
    def parse_payload(data)
      ok = data['success'] == true || data['status'] == 'success'
      raise Error, "geolocation failed: #{data.inspect}" unless ok

      lat = numeric!(data['latitude']  || data['lat'],  'latitude',  -90..90)
      lon = numeric!(data['longitude'] || data['lon'], 'longitude', -180..180)

      {
        latitude:  lat,
        longitude: lon,
        city:      Sanitize.display(data['city'].to_s),
        country:   country_code!(data['country_code'] || data['countryCode'])
      }
    end

    def numeric!(value, name, range)
      raise Error, "geolocation #{name} not numeric: #{value.inspect}" unless value.is_a?(Numeric)
      raise Error, "geolocation #{name} out of range: #{value}" unless range.cover?(value)
      value
    end

    def country_code!(value)
      code = Sanitize.display(value.to_s)
      raise Error, "geolocation country code invalid: #{value.inspect}" unless code.match?(/\A[A-Za-z]{2}\z/)
      code.upcase
    end
  end
end
