require 'test_helper'
require 'webrick'
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
    result = OmarchyPrayer::Geolocate.detect(url: url, timeout: 2)
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
      OmarchyPrayer::Geolocate.detect(url: "http://127.0.0.1:#{server.config[:Port]}/", timeout: 2)
    end
    assert_match(/geolocation failed/, err.message)
  ensure
    server&.shutdown
    thr&.join
  end
end
