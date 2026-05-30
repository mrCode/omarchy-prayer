require 'net/http'
require 'uri'
require 'json'
require 'omarchy_prayer/tz_location'

module OmarchyPrayer
  module Geolocate
    class Error < StandardError; end

    DEFAULT_URL = 'http://ip-api.com/json/'.freeze

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
      resp = Net::HTTP.start(uri.host, uri.port,
                             use_ssl: uri.scheme == 'https',
                             open_timeout: timeout, read_timeout: timeout) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "geolocation HTTP #{resp.code}" unless resp.code == '200'
      data = JSON.parse(resp.body)
      raise Error, "geolocation failed: #{data.inspect}" unless data['status'] == 'success'
      {
        latitude:  data.fetch('lat'),
        longitude: data.fetch('lon'),
        city:      data.fetch('city'),
        country:   data.fetch('countryCode')
      }
    end
  end
end
