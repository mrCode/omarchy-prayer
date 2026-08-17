require 'json'
require 'omarchy_prayer/today'

module OmarchyPrayer
  module Waybar
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr',
      asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha',
      fajr_tomorrow: 'Fajr'
    }.freeze

    module_function

    # The one renderer. Consumes the same Status structure the Omarchy 4
    # widget does, so the two bars can never drift apart.
    def render_from_status(status, now: Time.now)
      nx   = status['next']
      pill = status['pill']
      secs = nx['epoch'] - now.to_i

      text = pill['format']
        .gsub('{city}',      status['city'].to_s)
        .gsub('{prayer}',    nx['pretty'])
        .gsub('{time}',      nx['time'])
        .gsub('{countdown}', format_countdown(secs, pill['compact_countdown'] == true))

      cls = secs / 60 < pill['soon_threshold_minutes'] ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(status))
    end

    # Historical signature, kept so callers passing loose args keep working.
    # Builds the minimal Status shape and delegates.
    def render(today, now: Time.now, format:, soon_minutes:, city:)
      name, at = today.next_prayer(now: now)
      status = {
        'city'    => city,
        'prayers' => Today::ORDER.map { |p| { 'pretty' => PRETTY[p], 'time' => today.times[p] } },
        'next'    => { 'pretty' => PRETTY.fetch(name),
                       'time'   => at.strftime('%H:%M'),
                       'epoch'  => at.to_i },
        'pill'    => { 'format' => format, 'soon_threshold_minutes' => soon_minutes }
      }
      render_from_status(status, now: now)
    end

    def format_countdown(secs, compact = false)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      return "#{m}m" unless h.positive?
      compact ? format('%d:%02d', h, m) : "#{h}h #{m}m"
    end

    def build_tooltip(status)
      status['prayers'].map { |p| format('%-7s %s', p['pretty'], p['time']) }.join("\n")
    end
  end
end
