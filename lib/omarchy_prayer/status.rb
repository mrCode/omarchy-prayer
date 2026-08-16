require 'json'
require 'omarchy_prayer/today'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  # The single structured view of "what are today's prayer times, right now".
  #
  # Both the waybar renderer and the Omarchy 4 Quickshell widget consume this,
  # so every calculation stays here in Ruby rather than being duplicated in
  # QML. The widget only substitutes placeholders and subtracts timestamps.
  module Status
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr', asr: 'Asr',
      maghrib: 'Maghrib', isha: 'Isha', fajr_tomorrow: 'Fajr'
    }.freeze

    module_function

    def build(today:, config:, now: Time.now)
      next_name, next_at = today.next_prayer(now: now)
      degrees = Qibla.bearing(config.latitude, config.longitude)

      {
        'city'    => config.city,
        'country' => config.country,
        'date'    => today.date,
        'hijri'   => today.hijri,
        'prayers' => Today::ORDER.map { |p| prayer_entry(today, p, now) },
        'next'    => {
          'name'   => next_name.to_s,
          'pretty' => PRETTY.fetch(next_name),
          'time'   => next_at.strftime('%H:%M'),
          'epoch'  => next_at.to_i
        },
        'qibla'   => { 'degrees' => degrees, 'compass' => Qibla.cardinal(degrees) },
        'method'  => today.method,
        'source'  => today.source,
        'muted'   => File.exist?(Paths.mute_today),
        'pill'    => {
          'format'                 => config.bar_format,
          'soon_threshold_minutes' => config.soon_threshold_minutes
        }
      }
    end

    def to_json(today:, config:, now: Time.now)
      JSON.generate(build(today: today, config: config, now: now))
    end

    def prayer_entry(today, prayer, now)
      at = today.time_for(prayer)
      {
        'name'   => prayer.to_s,
        'pretty' => PRETTY.fetch(prayer),
        'time'   => today.times[prayer],
        'epoch'  => at.to_i,
        'passed' => at <= now
      }
    end
  end
end
