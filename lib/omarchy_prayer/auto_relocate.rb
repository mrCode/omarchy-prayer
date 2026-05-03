require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/relocate'

module OmarchyPrayer
  module AutoRelocate
    DEFAULT_THRESHOLD_KM = 50

    module_function

    # Returns the new loc Hash on update, or nil on no-op / detection failure.
    # Never raises — schedule runs depend on this completing.
    def maybe_update(cfg, threshold_km: DEFAULT_THRESHOLD_KM, geolocate: Geolocate, io: $stderr)
      detected = geolocate.detect
      return nil unless update_needed?(cfg, detected, threshold_km)

      previous = format('%s, %s', cfg.city, cfg.country)
      delta_km = haversine_km(cfg.latitude, cfg.longitude,
                              detected[:latitude], detected[:longitude])
      Relocate.update_config!(detected)
      Relocate.clear_month_caches
      io.puts format('omarchy-prayer: auto-relocated %s → %s, %s (Δ %d km)',
                     previous, detected[:city], detected[:country], delta_km.round)
      detected
    rescue Geolocate::Error, SocketError, Errno::ECONNREFUSED, Errno::ENETUNREACH,
           Errno::EHOSTUNREACH, Timeout::Error => e
      io.puts "omarchy-prayer: auto-relocate skipped (#{e.class}: #{e.message})"
      nil
    end

    def update_needed?(cfg, detected, threshold_km)
      return true if cfg.country.to_s.upcase != detected[:country].to_s.upcase
      haversine_km(cfg.latitude, cfg.longitude,
                   detected[:latitude], detected[:longitude]) > threshold_km
    end

    # Great-circle distance in kilometres.
    def haversine_km(lat1, lon1, lat2, lon2)
      r = 6371.0
      to_rad = ->(d) { d * Math::PI / 180.0 }
      dlat = to_rad.call(lat2 - lat1)
      dlon = to_rad.call(lon2 - lon1)
      a = Math.sin(dlat / 2)**2 +
          Math.cos(to_rad.call(lat1)) * Math.cos(to_rad.call(lat2)) *
          Math.sin(dlon / 2)**2
      2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    end
  end
end
