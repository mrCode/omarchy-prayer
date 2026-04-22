require 'net/http'
require 'uri'
require 'json'

module OmarchyPrayer
  module Geolocate
    class Error < StandardError; end

    DEFAULT_URL = 'http://ip-api.com/json/'

    module_function

    def detect(url: DEFAULT_URL, timeout: 5)
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
