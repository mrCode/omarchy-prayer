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

    def render(today, now: Time.now, format:, soon_minutes:)
      name, at = today.next_prayer(now: now)
      pretty = PRETTY.fetch(name)
      time_s = at.strftime('%H:%M')
      secs = (at - now).to_i
      countdown = format_countdown(secs)
      text = format.gsub('{prayer}', pretty).gsub('{time}', time_s).gsub('{countdown}', countdown)
      cls  = secs / 60 < soon_minutes ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(today))
    end

    def format_countdown(secs)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def build_tooltip(today)
      Today::ORDER.map { |p| format('%-7s %s', PRETTY[p], today.times[p]) }.join("\n")
    end
  end
end
