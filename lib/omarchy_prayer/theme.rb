require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Theme
    FALLBACK = {
      background: '#1a1b26', foreground: '#c0caf5',
      accent:     '#7aa2f7', primary:    '#bb9af7',
      secondary:  '#7dcfff', warning:    '#e0af68',
      muted:      '#565f89'
    }.freeze

    HEX = /\A#([0-9a-fA-F]{6})\z/

    def self.load(force_truecolor: false)
      new(parse_theme_file, force_truecolor)
    end

    def initialize(colors, force_truecolor)
      @colors = FALLBACK.merge(colors)
      @truecolor = force_truecolor || truecolor_supported?
      @no_color = ENV['NO_COLOR'] && !ENV['NO_COLOR'].empty?
    end

    FALLBACK.each_key do |k|
      define_method(k) { @colors[k] }
    end

    def ansi_fg(key)
      return '' if @no_color
      rgb = parse_hex(@colors[key])
      if @truecolor
        "\e[38;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
      else
        "\e[38;5;#{nearest_256(rgb)}m"
      end
    end

    def ansi_bg(key)
      return '' if @no_color
      rgb = parse_hex(@colors[key])
      if @truecolor
        "\e[48;2;#{rgb[0]};#{rgb[1]};#{rgb[2]}m"
      else
        "\e[48;5;#{nearest_256(rgb)}m"
      end
    end

    def bold;  @no_color ? '' : "\e[1m"; end
    def dim;   @no_color ? '' : "\e[2m"; end
    def reset; @no_color ? '' : "\e[0m"; end

    def self.parse_theme_file
      path = File.join(Paths.xdg_config_home, 'omarchy', 'current', 'alacritty.toml')
      return {} unless File.exist?(path)
      txt = File.read(path)
      out = {}
      out[:background] = txt[/background\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:foreground] = txt[/foreground\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:accent]     = txt[/blue\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:primary]    = txt[/magenta\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:secondary]  = txt[/cyan\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:warning]    = txt[/yellow\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out[:muted]      = txt[/black\s*=\s*"(#[0-9a-fA-F]{6})"/, 1]
      out.compact
    end

    private

    def truecolor_supported?
      ct = ENV['COLORTERM'].to_s
      ct.include?('truecolor') || ct.include?('24bit')
    end

    def parse_hex(hex)
      m = hex.match(HEX) or return [200, 200, 200]
      s = m[1]
      [s[0,2].to_i(16), s[2,2].to_i(16), s[4,2].to_i(16)]
    end

    def nearest_256(rgb)
      r, g, b = rgb.map { |c| (c / 51.0).round }
      16 + 36*r + 6*g + b
    end
  end
end
