require 'io/console'
require 'fileutils'
require 'date'
require 'stringio'
require 'omarchy_prayer/theme'
require 'omarchy_prayer/today'
require 'omarchy_prayer/config'
require 'omarchy_prayer/qibla'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/relocate'
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/sanitize'

module OmarchyPrayer
  class TUI
    PRETTY = { fajr: 'Fajr', dhuhr: 'Dhuhr', asr: 'Asr', maghrib: 'Maghrib', isha: 'Isha' }.freeze

    CARD_INNER = 26
    LIST_INNER = 34

    def initialize(out: $stdout, input: $stdin)
      @out = out; @input = input
      @theme = Theme.load
    end

    def run
      return show_error('no config — run `omarchy-prayer refresh` first') unless File.exist?(Paths.config_file)
      return show_error('no today.json — run `omarchy-prayer refresh` first') unless File.exist?(Paths.today_json)

      @cfg = Config.load
      @today = Today.read
      @input.raw do
        hide_cursor
        loop do
          render
          key = @input.getc
          case key
          when 'q', "\x03" then break
          when 'r' then refresh_schedule
          when 'l' then relocate_here
          when 'm' then toggle_mute
          when 't' then test_audio
          end
        end
      end
    ensure
      show_cursor
      clear_screen
    end

    private

    def render
      @width = terminal_width
      clear_screen
      now = Time.now
      next_name, next_at = @today.next_prayer(now: now)

      blank
      render_header
      blank 2
      render_next_card(next_name, next_at, now)
      blank
      render_today_list(next_name, now)
      blank
      render_meta
      blank 2
      render_hotkeys
      blank
    end

    def render_header
      center bold + fg(:accent) + 'OMARCHY  PRAYER' + rst
      # Sanitised at the sink: city/country come from a geolocation HTTP
      # response and are printed into a RAW-mode terminal, where a decoded
      # escape sequence (e.g. OSC 52 clipboard write) would execute.
      center fg(:muted) + "#{safe(@cfg.city)}, #{safe(@cfg.country)}" + rst
      center fg(:muted) + format_date_line + rst
    end

    def format_date_line
      gregorian = format_gregorian(@today.date)
      @today.hijri ? "#{gregorian}     #{dot}     #{safe(@today.hijri)}" : gregorian
    end

    def format_gregorian(iso_date)
      Date.parse(iso_date).strftime('%a, %-d %b %Y')
    end

    def render_next_card(name, at, now)
      label   = (PRETTY[name] || 'Fajr').upcase
      time_s  = at.strftime('%H:%M')
      remaining = [(at - now).to_i, 0].max
      countdown = format_countdown(remaining)
      soon = remaining / 60 < @cfg.soon_threshold_minutes
      count_c = soon ? :warning : :secondary

      center fg(:muted) + 'N  E  X  T     P  R  A  Y  E  R' + rst
      blank
      center box_border(:top, CARD_INNER, :primary)
      center box_content('', CARD_INNER)
      center box_content(label, CARD_INNER, color: :primary, style: bold)
      center box_content(time_s, CARD_INNER, color: :primary, style: bold)
      center box_content('', CARD_INNER)
      center box_content("in  #{countdown}", CARD_INNER, color: count_c, style: bold)
      center box_content('', CARD_INNER)
      center box_border(:bottom, CARD_INNER, :primary)
    end

    def render_today_list(next_name, now)
      center box_border(:top, LIST_INNER, :muted)
      Today::ORDER.each do |p|
        center list_row(p, next_name, now)
      end
      center box_border(:bottom, LIST_INNER, :muted)
    end

    def list_row(prayer, next_name, now)
      pretty = PRETTY[prayer]
      # Validated at ingress too (AladhanClient::TIME_TOKEN); belt and braces,
      # because this line is the one the comment on `safe` used to overlook.
      time_s = safe(@today.times[prayer] || '--:--')
      at = @today.time_for(prayer)
      is_next = next_name == prayer
      is_past = at < now

      marker = is_next ? '▸' : (is_past ? '·' : '◌')
      state  = is_next ? 'next' : (is_past ? 'passed' : '')

      # 2+1+2+8+2+5+2+10+2 = 34 → matches LIST_INNER
      inner = format('  %s  %-8s  %-5s  %-10s  ', marker, pretty, time_s, state)
      color = is_next ? :primary : (is_past ? :muted : :foreground)
      style = is_next ? bold : (is_past ? dim : '')

      fg(:muted) + '│' + rst +
        style + fg(color) + inner + rst +
        fg(:muted) + '│' + rst
    end

    def render_meta
      deg = Qibla.bearing(@cfg.latitude, @cfg.longitude)
      parts = []
      parts << "Qibla  #{deg}° #{Qibla.cardinal(deg)}"
      parts << "Method  #{@today.method}"
      parts << "Source  #{@today.source}"
      parts << bold + fg(:warning) + 'MUTED TODAY' + rst + fg(:muted) if File.exist?(Paths.mute_today)
      center fg(:muted) + parts.join("     #{dot}     ") + rst
    end

    def render_hotkeys
      hk = ->(k, l) { fg(:accent) + "[#{k}]" + fg(:muted) + " #{l}" + rst }
      line = [hk.call('q', 'quit'), hk.call('r', 'refresh'), hk.call('l', 'relocate'),
              hk.call('m', 'mute today'), hk.call('t', 'test adhan')].join('     ')
      center line
    end

    # ---- Box helpers ----

    def box_border(which, inner, color)
      l, mid, r = (which == :top ? %w[╭ ─ ╮] : %w[╰ ─ ╯])
      fg(color) + l + (mid * inner) + r + rst
    end

    def box_content(text, inner, color: :foreground, style: '')
      plain = text.to_s
      pad_l = (inner - plain.length) / 2
      pad_r = inner - plain.length - pad_l
      fg(:primary) + '│' + rst +
        ' ' * pad_l + style + fg(color) + plain + rst + ' ' * pad_r +
        fg(:primary) + '│' + rst
    end

    # ---- Centering ----

    def center(text = '')
      vlen = visible_len(text)
      pad  = [(@width - vlen) / 2, 0].max
      @out.print ' ' * pad + text + "\r\n"
    end

    def blank(n = 1)
      n.times { @out.print "\r\n" }
    end

    # Everything that reaches the terminal goes through this.
    def safe(value)
      Sanitize.display(value.to_s)
    end

    def visible_len(s)
      s.gsub(/\e\[[0-9;]*m/, '').length
    end

    # ---- Actions ----

    def relocate_here
      show_toast('locating…', color: :muted)
      captured = StringIO.new
      Relocate.run([], io: captured)
      refresh_schedule
      @cfg = Config.load
      show_toast("→ #{safe(@cfg.city)}, #{safe(@cfg.country)}", color: :primary, dwell: 1.0)
    rescue Geolocate::Error, SocketError,
           Errno::ECONNREFUSED, Errno::ENETUNREACH, Errno::EHOSTUNREACH,
           Timeout::Error, SystemExit => e
      show_toast("relocate failed: #{e.message}", color: :warning, dwell: 1.5)
    end

    def show_toast(msg, color:, dwell: 0)
      # Re-render hotkey row replaced with the toast text.
      @out.print "\e[#{terminal_height};1H\e[2K"  # move to last row, clear
      pad = [(@width - visible_len(msg)) / 2, 0].max
      @out.print ' ' * pad + fg(color) + msg + rst
      sleep dwell if dwell.positive?
    end

    def terminal_height
      IO.console&.winsize&.first || 24
    end

    def refresh_schedule
      system('systemctl', '--user', 'start', 'omarchy-prayer-schedule.service')
      sleep 0.3
      @today = Today.read
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
      unless @cfg.audio_enabled
        show_toast('audio disabled — set audio.enabled = true to enable',
                   color: :warning, dwell: 1.5)
        return
      end
      file = @cfg.adhan_path
      return unless File.exist?(file)
      pid = Process.spawn(@cfg.audio_player, '--no-video', '--really-quiet',
                          "--volume=#{@cfg.volume}", file,
                          %i[out err] => '/dev/null')
      sleep 3
      begin; Process.kill('TERM', pid); rescue Errno::ESRCH; end
    end

    # ---- Theming shortcuts ----

    def fg(key); @theme.ansi_fg(key); end
    def rst;    @theme.reset;        end
    def bold;   @theme.bold;         end
    def dim;    @theme.dim;          end
    def dot;    '·';                 end

    # ---- Misc ----

    def format_countdown(secs)
      h = secs / 3600
      m = (secs % 3600) / 60
      h.positive? ? "#{h}h #{m}m" : "#{m}m"
    end

    def terminal_width
      IO.console&.winsize&.last || 80
    end

    def show_error(msg)
      @out.puts "\e[31momarchy-prayer:\e[0m #{msg}"
      exit 1
    end

    def clear_screen; @out.print "\e[2J\e[H"; end
    def hide_cursor;  @out.print "\e[?25l"; end
    def show_cursor;  @out.print "\e[?25h"; end
  end
end
