require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/relocate'
require 'omarchy_prayer/sanitize'
require 'omarchy_prayer/tz_location'
require 'omarchy_prayer/paths'
require 'date'

module OmarchyPrayer
  module AutoRelocate
    DEFAULT_THRESHOLD_KM = 50

    module_function

    # Returns the new loc Hash on update, or nil on no-op / detection failure.
    # Never raises — schedule runs depend on this completing.
    def maybe_update(cfg, threshold_km: DEFAULT_THRESHOLD_KM, geolocate: Geolocate, io: $stderr)
      detected = geolocate.detect
      return nil unless update_needed?(cfg, detected, threshold_km)

      # Printed to stderr, which on a schedule run is the user's terminal.
      previous = format('%s, %s', Sanitize.display(cfg.city.to_s),
                        Sanitize.display(cfg.country.to_s))
      delta_km = haversine_km(cfg.latitude, cfg.longitude,
                              detected[:latitude], detected[:longitude])
      Relocate.update_config!(detected)
      Relocate.clear_month_caches
      io.puts format('omarchy-prayer: auto-relocated %s → %s, %s (Δ %d km)',
                     previous, Sanitize.display(detected[:city].to_s),
                     Sanitize.display(detected[:country].to_s), delta_km.round)
      detected
    rescue Geolocate::Error, SocketError, Errno::ECONNREFUSED, Errno::ENETUNREACH,
           Errno::EHOSTUNREACH, Timeout::Error => e
      io.puts "omarchy-prayer: auto-relocate skipped (#{e.class}: #{e.message})"
      nil
    end

    # A pin stops the app following the IP — that is what it is for. But it must
    # not go silent when the user clearly moves: a pinned config sat on the wrong
    # city for eleven days, scheduling the wrong prayers daily, saying nothing.
    #
    # The signal is the SYSTEM TIMEZONE, not IP geolocation. The timezone is set
    # by the user or their OS, so a country-level disagreement with the pinned
    # country is near-certain evidence of travel — unlike an IP result, which was
    # 694 km wrong on the very connection that prompted the pin in the first
    # place. Country granularity only: within one country the timezone says
    # nothing useful, and a false alarm on a pin the user deliberately set would
    # train them to ignore it.
    #
    # It WARNS. It does not unpin. Silently overriding the user's explicit choice
    # is the v0.4.2 bug from the other direction.
    #
    # Returns the message on warning, nil otherwise. Never raises — the schedule
    # run must complete regardless.
    def warn_stale_pin(cfg, tz_detect: TzLocation, io: $stderr, notify: NOTIFY_SEND)
      return nil if cfg.auto_update?
      return nil unless cfg.warn_timezone_mismatch?

      tz = tz_detect.detect
      return nil unless tz && tz[:countries]

      pinned = cfg.country.to_s.upcase
      return nil if pinned.empty?
      return nil if tz[:countries].map { |c| c.to_s.upcase }.include?(pinned)

      # Sanitised: city/country are geolocation-derived and this lands in a
      # notification body, which mako renders as Pango markup.
      # `pinned` itself is interpolated below, so it needs the same treatment as
      # city — the raw value is kept for comparison and the marker stamp only.
      city   = Sanitize.display(cfg.city.to_s)
      zone   = Sanitize.display(tz[:zone].to_s)
      shown  = Sanitize.display(pinned)
      title = 'Prayer times: pinned location may be stale'
      body  = "Pinned to #{city}, #{shown}, but this system's timezone is " \
              "#{zone}. Prayer times are being calculated for #{city}. " \
              'Run `omarchy-prayer relocate --auto` to follow your location ' \
              'again, or re-pin with `omarchy-prayer relocate --lat N --lon N ' \
              '--city CITY --country CC` (all four are required). ' \
              'Silence this with `warn_timezone_mismatch = false` under ' \
              '[location].'

      io.puts "omarchy-prayer: pinned to #{city}, #{shown} but timezone is #{zone} — times may be wrong"
      notify.call(title, body) if should_notify?(pinned, zone)
      body
    rescue StandardError => e
      # Never take the schedule run down over an advisory.
      begin
        io.puts "omarchy-prayer: stale-pin check skipped (#{e.class})"
      rescue StandardError
        nil
      end
      nil
    end

    # `critical` rather than `normal`: a normal toast auto-expires (8s on the
    # Omarchy 4 shell) and is filed into history. This whole feature exists
    # because a wrong location went unnoticed for eleven days, and the 00:01
    # scheduler run — which usually consumes the day's one notification —
    # happens while nobody is watching. Critical notifications do not expire.
    NOTIFY_SEND = lambda do |title, body|
      system('notify-send', '-a', 'omarchy-prayer', '-u', 'critical', title, body)
    end

    # One notification per (day, mismatch). The scheduler runs at 00:01, on
    # resume, and on every network-up, so notifying per run would be a stream;
    # never re-notifying would let a single missed popup hide a wrong location
    # for the whole trip. A changed mismatch is new information and notifies at
    # once.
    def should_notify?(pinned, zone)
      marker = Paths.pin_mismatch_marker
      stamp  = "#{Date.today}|#{pinned}|#{zone}"
      return false if File.file?(marker) && File.read(marker).strip == stamp
      Paths.ensure_state_dir
      File.write(marker, stamp)
      true
    rescue Errno::EISDIR, Errno::EACCES, Errno::EROFS, Errno::ENOSPC
      # The marker is unusable (a directory, or an unwritable state dir). Erring
      # toward warning would fire on EVERY scheduler run — 00:01, resume, each
      # network-up — which is worse than the problem. Stay quiet; the run that
      # writes today.json will surface the real fault.
      false
    rescue StandardError
      true # can't remember for some other reason? a duplicate beats silence
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
