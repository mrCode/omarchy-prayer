require 'test_helper'
require 'omarchy_prayer/theme'

class TestTheme < Minitest::Test
  include TestHelper

  MINI_ALACRITTY = <<~TOML
    [colors.primary]
    background = "#1a1b26"
    foreground = "#c0caf5"

    [colors.normal]
    red    = "#f7768e"
    green  = "#9ece6a"
    yellow = "#e0af68"
    blue   = "#7aa2f7"
    cyan   = "#7dcfff"
    magenta = "#bb9af7"
    black  = "#565f89"
  TOML

  # Omarchy 4 layout: note [colors.normal].black equals the background, which
  # is why `muted` must come from [colors.bright].
  V4_ALACRITTY = <<~TOML
    [colors.primary]
    background = "#2d353b"
    foreground = "#d3c6aa"

    [colors.normal]
    black   = "#2d353b"
    red     = "#e67e80"
    green   = "#a7c080"
    yellow  = "#dbbc7f"
    blue    = "#7fbbb3"
    magenta = "#d699b6"
    cyan    = "#83c092"

    [colors.bright]
    black = "#475258"
  TOML

  def setup_theme(home)
    theme_dir = "#{home}/.config/omarchy/current"
    FileUtils.mkdir_p(theme_dir)
    File.write("#{theme_dir}/alacritty.toml", MINI_ALACRITTY)
  end

  def setup_v4_theme(home)
    theme_dir = "#{home}/.local/state/omarchy/current/theme"
    FileUtils.mkdir_p(theme_dir)
    File.write("#{theme_dir}/alacritty.toml", V4_ALACRITTY)
  end

  def test_reads_omarchy4_state_path
    with_isolated_home do |home|
      setup_v4_theme(home)
      colors = OmarchyPrayer::Theme.parse_theme_file
      assert_equal '#2d353b', colors[:background]
      assert_equal '#d3c6aa', colors[:foreground]
      assert_equal '#7fbbb3', colors[:accent]
      assert_equal '#dbbc7f', colors[:warning]
    end
  end

  def test_muted_prefers_bright_black_over_normal_black
    with_isolated_home do |home|
      setup_v4_theme(home)
      colors = OmarchyPrayer::Theme.parse_theme_file
      assert_equal '#475258', colors[:muted],
                   'muted must not collapse to the background colour'
      refute_equal colors[:background], colors[:muted]
    end
  end

  def test_v4_state_path_wins_over_v3_config_path
    with_isolated_home do |home|
      setup_theme(home)
      setup_v4_theme(home)
      assert_equal '#2d353b', OmarchyPrayer::Theme.parse_theme_file[:background]
    end
  end

  def test_v3_config_path_still_read_when_no_v4_theme
    with_isolated_home do |home|
      setup_theme(home)
      colors = OmarchyPrayer::Theme.parse_theme_file
      assert_equal '#1a1b26', colors[:background]
      assert_equal '#565f89', colors[:muted]  # falls back to normal.black
    end
  end

  def test_returns_empty_when_no_theme_file_anywhere
    with_isolated_home do |_home|
      assert_empty OmarchyPrayer::Theme.parse_theme_file
    end
  end

  def test_loads_truecolor_palette_from_theme
    with_isolated_home do |home|
      setup_theme(home)
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      assert_equal '#1a1b26', pal.background
      assert_equal '#c0caf5', pal.foreground
      assert_equal '#7aa2f7', pal.accent           # blue
      assert_equal '#e0af68', pal.warning          # yellow
    end
  end

  def test_fallback_when_no_theme_present
    with_isolated_home do
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      refute_nil pal.foreground
      refute_nil pal.accent
    end
  end

  def test_no_color_mode
    with_isolated_home do |home|
      setup_theme(home)
      ENV['NO_COLOR'] = '1'
      pal = OmarchyPrayer::Theme.load
      assert_equal '', pal.ansi_fg(:accent)
      assert_equal '', pal.reset
    ensure
      ENV.delete('NO_COLOR')
    end
  end

  def test_ansi_escape_sequence_for_truecolor
    with_isolated_home do |home|
      setup_theme(home)
      pal = OmarchyPrayer::Theme.load(force_truecolor: true)
      assert_equal "\e[38;2;122;162;247m", pal.ansi_fg(:accent)
      assert_equal "\e[0m", pal.reset
    end
  end
end
