require 'json'
require 'omarchy_prayer/today'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/prayer_names'
require 'omarchy_prayer/sanitize'

module OmarchyPrayer
  # The single structured view of "what are today's prayer times, right now".
  #
  # Both the waybar renderer and the Omarchy 4 Quickshell widget consume this,
  # so every calculation stays here in Ruby rather than being duplicated in
  # QML. The widget only substitutes placeholders and subtracts timestamps.
  module Status
    module_function

    def build(today:, config:, now: Time.now)
      next_name, next_at = today.next_prayer(now: now)
      degrees = Qibla.bearing(config.latitude, config.longitude)
      script  = config.names_script

      {
        # Sanitised on the way out as well as on the way in: an existing
        # config may already hold a poisoned city from before the ingress
        # guard existed. See Sanitize for why this matters.
        'city'    => Sanitize.display(config.city),
        'country' => Sanitize.display(config.country),
        'date'    => today.date,
        # Aladhan's response, not ours — same trust class as city.
        'hijri'   => Sanitize.display(today.hijri),
        'prayers' => Today::ORDER.map { |p| prayer_entry(today, p, now, script) },
        'next'    => {
          'name'   => next_name.to_s,
          'pretty' => PrayerNames.pretty(next_name, script: script),
          'time'   => next_at.strftime('%H:%M'),
          'epoch'  => next_at.to_i
        },
        'qibla'   => { 'degrees' => degrees, 'compass' => Qibla.cardinal(degrees) },
        'method'  => today.method,
        'source'  => today.source,
        # Two distinct things: `muted` is the today-only suppression marker,
        # `audio_enabled` is the standing [audio].enabled setting.
        'muted'         => File.exist?(Paths.mute_today),
        'audio_enabled' => config.audio_enabled,
        'pill'    => {
          'format'                 => config.bar_format,
          'soon_threshold_minutes' => config.soon_threshold_minutes,
          'preset'                 => config.bar_preset,
          'compact_countdown'      => config.compact_countdown?,
          'quiet_until_minutes'    => config.quiet_until_minutes
        }
      }
    end

    def to_json(today:, config:, now: Time.now)
      JSON.generate(build(today: today, config: config, now: now))
    end

    def prayer_entry(today, prayer, now, script = PrayerNames::DEFAULT_SCRIPT)
      at = today.time_for(prayer)
      {
        'name'   => prayer.to_s,
        'pretty' => PrayerNames.pretty(prayer, script: script),
        'time'   => today.times[prayer],
        'epoch'  => at.to_i,
        'passed' => at <= now
      }
    end
  end
end
