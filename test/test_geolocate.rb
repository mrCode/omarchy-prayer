require 'test_helper'
require 'webrick'
require 'stringio'
require 'omarchy_prayer/geolocate'

class TestGeolocate < Minitest::Test
  def test_parses_ip_api_response
    body = { status: 'success', lat: 24.7136, lon: 46.6753,
             city: 'Riyadh', countryCode: 'SA' }.to_json
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, res| res.body = body; res.content_type = 'application/json' }
    thr = Thread.new { server.start }
    url = "http://127.0.0.1:#{server.config[:Port]}/"
    result = OmarchyPrayer::Geolocate.detect_ip(url: url, timeout: 2)
    assert_equal 'Riyadh', result[:city]
    assert_equal 'SA',     result[:country]
    assert_in_delta 24.7136, result[:latitude], 1e-6
    assert_in_delta 46.6753, result[:longitude], 1e-6
  ensure
    server&.shutdown
    thr&.join
  end

  def test_raises_when_status_not_success
    server = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                     Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc('/') { |_, r| r.body = '{"status":"fail"}'; r.content_type = 'application/json' }
    thr = Thread.new { server.start }
    err = assert_raises(OmarchyPrayer::Geolocate::Error) do
      OmarchyPrayer::Geolocate.detect_ip(url: "http://127.0.0.1:#{server.config[:Port]}/", timeout: 2)
    end
    assert_match(/geolocation failed/, err.message)
  ensure
    server&.shutdown
    thr&.join
  end

  IP_RIYADH  = { latitude: 24.7136, longitude: 46.6753, city: 'Riyadh', country: 'SA' }.freeze
  IP_LONDON  = { latitude: 51.5074, longitude: -0.1278, city: 'London', country: 'GB' }.freeze
  TZ_LONDON  = { latitude: 51.5083, longitude: -0.1253, city: 'London',
                 country: 'GB', countries: %w[GB GG IM JE], zone: 'Europe/London' }.freeze
  TZ_RIYADH  = { latitude: 24.6333, longitude: 46.7166, city: 'Riyadh',
                 country: 'SA', countries: %w[SA AQ KW YE], zone: 'Asia/Riyadh' }.freeze

  def test_detect_uses_ip_when_tz_country_agrees
    ip = ->(*) { IP_LONDON.dup }
    tz = -> { TZ_LONDON.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'London', loc[:city]
    assert_in_delta 51.5074, loc[:latitude], 1e-4  # IP coords, not TZ
  end

  def test_detect_falls_back_to_tz_when_country_disagrees
    ip = ->(*) { IP_RIYADH.dup }
    tz = -> { TZ_LONDON.dup }
    io = StringIO.new
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: io)
    assert_equal 'London', loc[:city]
    assert_equal 'GB', loc[:country]
    assert_in_delta 51.5083, loc[:latitude], 1e-4  # TZ coords
    assert_match(/IP.*Riyadh.*timezone is Europe\/London/, io.string)
  end

  def test_detect_uses_ip_when_tz_unavailable
    ip = ->(*) { IP_RIYADH.dup }
    tz = -> { nil }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'Riyadh', loc[:city]
  end

  def test_detect_falls_back_to_tz_when_ip_fails
    ip = ->(*) { raise OmarchyPrayer::Geolocate::Error, 'boom' }
    tz = -> { TZ_LONDON.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    assert_equal 'London', loc[:city]
  end

  def test_detect_raises_when_both_fail
    ip = ->(*) { raise OmarchyPrayer::Geolocate::Error, 'boom' }
    tz = -> { nil }
    assert_raises(OmarchyPrayer::Geolocate::Error) do
      OmarchyPrayer::Geolocate.detect(ip_detect: ip, tz_detect: tz, io: StringIO.new)
    end
  end

  def test_detect_ip_country_in_zone_country_set_uses_ip
    # Kuwait user (TZ=Asia/Riyadh), IP routed through SA. Both in {SA,AQ,KW,YE} → use IP.
    ip_sa = IP_RIYADH.dup
    tz = -> { TZ_RIYADH.dup }
    loc = OmarchyPrayer::Geolocate.detect(ip_detect: ->(*) { ip_sa }, tz_detect: tz, io: StringIO.new)
    assert_equal 'Riyadh', loc[:city]
    assert_equal 'SA', loc[:country]
  end
end
