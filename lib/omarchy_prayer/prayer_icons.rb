module OmarchyPrayer
  # One emoji per prayer, keyed to the time of day it falls in.
  #
  # Contributed by @ch-arslanahmad in PR #4. The glyphs and the time-of-day
  # colours below are theirs; only the plumbing changed when this was ported
  # onto the shared Status renderer.
  #
  # Exposed through the `{icon}` format placeholder rather than an on-by-default
  # switch, so an upgrade never silently rewrites what an existing bar shows.
  module PrayerIcons
    ICONS = {
      fajr:           "\u{1F31B}",          # first quarter moon — pre-dawn
      sunrise:        "\u{1F307}",          # sunrise over buildings
      dhuhr:          "\u{2600}\u{FE0F}",   # sun — midday
      asr:            "\u{26C5}",           # sun behind cloud — afternoon
      maghrib:        "\u{1F307}",          # sunset
      isha:           "\u{1F319}",          # crescent moon — night
      fajr_tomorrow:  "\u{1F31B}"
    }.freeze

    # Pango span colours, used only by the waybar renderer: the Quickshell
    # widget renders Text.PlainText by design and never interprets markup.
    COLORS = {
      fajr:          '#b8a9ff',  # dawn purple
      sunrise:       '#f5cba7',
      dhuhr:         '#ffda7a',  # noon gold
      asr:           '#ffb347',  # afternoon orange
      maghrib:       '#ff6b6b',  # sunset coral
      isha:          '#74b9ff',  # night blue
      fajr_tomorrow: '#b8a9ff'
    }.freeze

    module_function

    def for(prayer)
      ICONS[prayer.to_s.to_sym]
    end

    def color_for(prayer)
      COLORS[prayer.to_s.to_sym]
    end
  end
end
