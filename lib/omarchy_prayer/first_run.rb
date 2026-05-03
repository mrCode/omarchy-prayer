require 'fileutils'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/setup'

module OmarchyPrayer
  module FirstRun
    TEMPLATE = <<~TOML
      [location]
      # Edit freely; filled from IP geolocation on first run.
      latitude    = %<lat>.4f
      longitude   = %<lon>.4f
      city        = "%<city>s"
      country     = "%<country>s"
      # Re-detect on every schedule run (daily, on resume, on network up).
      # Set to false to pin location and only update via `omarchy-prayer relocate`.
      auto_update = true

      [method]
      # "auto" picks from country; see README for full list.
      name = "auto"

      [offsets]
      fajr = 0
      dhuhr = 0
      asr = 0
      maghrib = 0
      isha = 0

      [notifications]
      enabled            = true
      pre_notify_minutes = 10
      respect_silencing  = true

      [audio]
      enabled    = true
      player     = "mpv"
      adhan      = "~/.config/omarchy-prayer/adhan.mp3"
      adhan_fajr = "~/.config/omarchy-prayer/adhan-fajr.mp3"
      volume     = 80

      [waybar]
      format                 = "{prayer} {countdown}"
      soon_threshold_minutes = 10
    TOML

    module_function

    # Returns true if config was just created; false if it already existed.
    def ensure_config!(geolocate: Geolocate, out: $stdout)
      return false if File.exist?(Paths.config_file)
      out.puts 'omarchy-prayer: first-run — detecting location via ip-api.com…'
      loc = geolocate.detect
      Paths.ensure_config_dir
      File.write(Paths.config_file,
                 format(TEMPLATE,
                        lat: loc[:latitude], lon: loc[:longitude],
                        city: loc[:city], country: loc[:country]))
      out.puts "omarchy-prayer: wrote config for #{loc[:city]}, #{loc[:country]} (edit #{Paths.config_file} to override)"
      Setup.run(io: out)
      true
    rescue Geolocate::Error => e
      raise "first-run failed: #{e.message}\n" \
            "edit #{Paths.config_file} manually — see README for the template"
    end
  end
end
