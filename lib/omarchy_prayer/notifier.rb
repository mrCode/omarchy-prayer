require 'omarchy_prayer/audio'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/sanitize'

module OmarchyPrayer
  class Notifier
    PRETTY = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' }.freeze

    def initialize(today:, respect_silencing:, audio_enabled:, audio_player:, volume:,
                   adhan:, adhan_fajr:, pre_notify_minutes: 10)
      @today = today; @respect = respect_silencing
      @audio_enabled = audio_enabled; @audio_player = audio_player; @volume = volume
      @adhan = adhan; @adhan_fajr = adhan_fajr
      @pre_minutes = pre_notify_minutes
    end

    def fire(prayer:, event:)
      return if muted?
      return if @respect && dnd?

      title, body, action = compose(prayer, event)

      # Spawn audio before notify-send: when --action= is passed, notify-send
      # blocks until the popup times out (mako default 5s) or is dismissed,
      # which would otherwise delay adhan playback past prayer time.
      if event == 'on-time' && @audio_enabled
        file = prayer == :fajr ? @adhan_fajr : @adhan
        if File.exist?(file)
          Audio.new(player: @audio_player, volume: @volume).play(file)
        else
          system('notify-send', '-a', 'omarchy-prayer', '-u', 'low',
                 'Adhan audio missing', "Not found: #{file}")
        end
      end

      args = ['-a', 'omarchy-prayer', title, body]
      args += ['--action=stop-adhan=Stop adhan'] if action
      system('notify-send', *args)
    end

    private

    def muted?
      File.exist?(Paths.mute_today)
    end

    # Omarchy 4 runs notifications inside omarchy-shell; Omarchy 3 used mako.
    # The live shell wins over mako, which lingers as an upgrade leftover.
    # If neither answers we fire: a broken probe must never silently swallow
    # a prayer notification.
    def dnd?
      state = `omarchy-shell notifications isDnd 2>/dev/null`.strip
      return state == 'on' if %w[on off].include?(state)

      `makoctl mode 2>/dev/null`.strip.include?('do-not-disturb')
    rescue StandardError
      false
    end

    def compose(prayer, event)
      pretty = PRETTY.fetch(prayer)
      at = @today.times.fetch(prayer)
      if event == 'pre'
        # The body is rendered by Omarchy's in-shell notification daemon
        # (a QML surface) and by notify-send on waybar systems. city is
        # geolocation-derived, so it is sanitised here too.
        ["#{@pre_minutes} min to #{pretty}", "#{pretty} at #{at} — #{Sanitize.display(@today.city.to_s)}", false]
      else
        [pretty, "#{at} — time for #{pretty}", true]
      end
    end
  end
end
