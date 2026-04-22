module OmarchyPrayer
  module Qibla
    MAKKAH_LAT = 21.4225
    MAKKAH_LON = 39.8262

    CARDINALS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze

    module_function

    # Initial great-circle bearing from (lat, lon) to Makkah, degrees [0, 360).
    def bearing(lat, lon)
      phi1 = to_rad(lat)
      phi2 = to_rad(MAKKAH_LAT)
      dlon = to_rad(MAKKAH_LON - lon)
      y = Math.sin(dlon) * Math.cos(phi2)
      x = Math.cos(phi1) * Math.sin(phi2) -
          Math.sin(phi1) * Math.cos(phi2) * Math.cos(dlon)
      deg = to_deg(Math.atan2(y, x))
      (deg % 360).round
    end

    def cardinal(deg)
      idx = ((deg % 360) / 22.5 + 0.5).floor % 16
      CARDINALS[idx]
    end

    def to_rad(d); d * Math::PI / 180.0; end
    def to_deg(r); r * 180.0 / Math::PI; end
  end
end
