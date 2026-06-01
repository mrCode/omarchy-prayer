require 'json'
require 'time'
require 'omarchy_prayer/today'

module OmarchyPrayer
  module Waybar
    PRETTY = {
      fajr: 'Fajr', sunrise: 'Sunrise', dhuhr: 'Dhuhr',
      asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha',
      fajr_tomorrow: 'Fajr'
    }.freeze

    ICONS = {
      fajr: "\u{1F31B} ",  sunrise: "\u{1F307} ",
      dhuhr: "\u{2600}\u{FE0F} ", asr: "\u{26C5} ",
      maghrib: "\u{1F307} ", isha: "\u{1F319} ",
      fajr_tomorrow: "\u{1F31B} "
    }.freeze

    COLORS = {
      fajr: '#b8a9ff', sunrise: '#f5cba7', dhuhr: '#ffda7a',
      asr: '#ffb347', maghrib: '#ff6b6b', isha: '#74b9ff',
      fajr_tomorrow: '#b8a9ff'
    }.freeze

    module_function

    def render(today, now: Time.now, format:, soon_minutes:, city:,
               icons: true, time_12h: false, colored: false)
      name, at = today.next_prayer(now: now)
      pretty = PRETTY.fetch(name)
      time_s = format_time(at, time_12h)
      secs = (at - now).to_i
      countdown = format_countdown(secs)

      prayer_text = pretty
      prayer_text = "#{ICONS[name]}#{pretty}" if icons
      if colored && (color = COLORS[name])
        prayer_text = "<span color='#{color}'>#{prayer_text}</span>"
      end

      text = format
        .gsub('{city}',      city.to_s)
        .gsub('{prayer}',    prayer_text)
        .gsub('{time}',      time_s)
        .gsub('{countdown}', countdown)
      cls  = secs / 60 < soon_minutes ? 'prayer-soon' : 'prayer-normal'
      JSON.generate(text: text, class: cls, tooltip: build_tooltip(today, time_12h))
    end

    def format_time(at, use_12h)
      return at.strftime('%H:%M') unless use_12h
      at.strftime('%I:%M %p').sub(/^0/, '')
    end

    def format_countdown(secs)
      secs = 0 if secs < 0
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def format_tooltip_time(t, use_12h)
      return t unless use_12h
      time = t.is_a?(Time) ? t : Time.parse(t)
      time.strftime('%I:%M %p').sub(/^0/, '')
    rescue ArgumentError
      t
    end

    def build_tooltip(today, use_12h = false)
      Today::ORDER.map { |p|
        format('%-7s %s', PRETTY[p], format_tooltip_time(today.times[p], use_12h))
      }.join("\n")
    end
  end
end
