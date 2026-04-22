require 'io/console'
require 'fileutils'
require 'omarchy_prayer/theme'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class TUI
    PRETTY = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' }.freeze

    def initialize(out: $stdout, input: $stdin)
      @out = out; @input = input
      @theme = Theme.load
    end

    def run
      return show_error('no config — run any omarchy-prayer command to bootstrap') unless File.exist?(Paths.config_file)
      return show_error('no today.json — run `omarchy-prayer refresh`') unless File.exist?(Paths.today_json)

      @cfg = Config.load
      @today = Today.read
      @input.raw do
        hide_cursor
        loop do
          render_main
          key = @input.getc
          case key
          when 'q', "\x03" then break
          when 'r' then system('systemctl', '--user', 'start', 'omarchy-prayer-schedule.service'); sleep 0.3; @today = Today.read
          when 'm' then toggle_mute
          when 't' then test_audio
          when 's' then render_settings_read_only
          end
        end
      end
    ensure
      show_cursor
      clear_screen
    end

    private

    def render_main
      clear_screen
      now = Time.now
      next_name, next_at = @today.next_prayer(now: now)

      qibla_deg = Qibla.bearing(@cfg.latitude, @cfg.longitude)
      qibla_lbl = "#{qibla_deg}° #{Qibla.cardinal(qibla_deg)}"

      puts_line ''
      puts_line header_line(qibla_lbl)
      puts_line divider
      puts_line ''

      Today::ORDER.each do |p|
        t = @today.times[p]
        line = prayer_line(p, t, next_name, next_at, now)
        puts_line line
      end

      puts_line ''
      puts_line divider
      puts_line footer_line
      puts_line ''
      puts_line hotkeys
    end

    def header_line(qibla)
      title = '☪ Omarchy Prayer'
      loc = "📍 #{@cfg.city}, #{@cfg.country}"
      date = "📅 #{@today.date}"
      qib = "🧭 Qibla #{qibla}"
      @theme.bold + @theme.ansi_fg(:accent) + "  #{title}   #{loc}    #{date}   #{qib}" + @theme.reset
    end

    def divider
      @theme.ansi_fg(:muted) + ('─' * 66) + @theme.reset
    end

    def prayer_line(prayer, time_s, next_name, next_at, now)
      pretty = PRETTY[prayer]
      at = @today.time_for(prayer)
      label = format('  %-9s %s', pretty, time_s || '--:--')

      is_next = (next_name == prayer) || (next_name == :fajr_tomorrow && prayer == :fajr)

      if is_next
        remaining = (next_at - now).to_i
        remaining = 0 if remaining < 0
        countdown = format_countdown(remaining)
        bar = progress_bar(remaining)
        soon_color = remaining / 60 < @cfg.soon_threshold_minutes ? :warning : :primary
        @theme.bold + @theme.ansi_fg(:primary) + "▶ #{label}   next · in #{countdown}  " + @theme.ansi_fg(soon_color) + bar + @theme.reset
      elsif at < now
        @theme.dim + "◦ #{label}   ✓ passed" + @theme.reset
      else
        "◦ #{label}"
      end
    end

    def format_countdown(secs)
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def progress_bar(remaining_secs)
      # Rough day-progress bar: full when just passed, empty when 3h+ away.
      filled = [(10 * (1 - remaining_secs / (3 * 3600.0))).clamp(0, 10).to_i, 10].min
      '█' * filled + '░' * (10 - filled)
    end

    def footer_line
      muted = File.exist?(Paths.mute_today) ? ' · MUTED TODAY' : ''
      @theme.ansi_fg(:muted) +
        "  Source  #{@today.source}    Method  #{@today.method}#{muted}" +
        @theme.reset
    end

    def hotkeys
      dim = @theme.ansi_fg(:muted)
      acc = @theme.ansi_fg(:accent)
      r = @theme.reset
      "  #{acc}[s]#{r}#{dim} Settings   #{acc}[t]#{r}#{dim} Test adhan   #{acc}[m]#{r}#{dim} Mute today   #{acc}[r]#{r}#{dim} Refresh   #{acc}[q]#{r}#{dim} Quit#{r}"
    end

    def toggle_mute
      if File.exist?(Paths.mute_today)
        File.delete(Paths.mute_today)
      else
        Paths.ensure_state_dir
        FileUtils.touch(Paths.mute_today)
      end
    end

    def test_audio
      file = @cfg.adhan_path
      return unless File.exist?(file)
      pid = Process.spawn(@cfg.audio_player, '--no-video', '--really-quiet',
                          "--volume=#{@cfg.volume}", file,
                          %i[out err] => '/dev/null')
      sleep 3
      begin; Process.kill('TERM', pid); rescue Errno::ESRCH; end
    end

    def render_settings_read_only
      clear_screen
      @out.puts "settings — v1 is read-only; edit #{Paths.config_file} directly"
      @out.puts 'press any key to return…'
      @input.getc
    end

    def show_error(msg)
      @out.puts "\e[31momarchy-prayer:\e[0m #{msg}"
      exit 1
    end

    def puts_line(s); @out.puts s; end
    def clear_screen; @out.print "\e[2J\e[H"; end
    def hide_cursor;  @out.print "\e[?25l"; end
    def show_cursor;  @out.print "\e[?25h"; end
  end
end
