require 'json'
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
      fajr: '#b8a9ff', dhuhr: '#ffda7a', asr: '#ffb347',
      maghrib: '#ff6b6b', isha: '#74b9ff'
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
      prayer_text = "<span color='#{COLORS[name]}'>#{prayer_text}</span>" if colored

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

    def build_tooltip(today, use_12h = false)
      Today::ORDER.map { |p|
        t = today.times[p]
        t = begin; Time.parse(t).strftime('%I:%M %p').sub(/^0/, ''); rescue; t; end if use_12h
        format('%-7s %s', PRETTY[p], t)
      }.join("\n")
    end
  end
end
