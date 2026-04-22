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

  def setup_theme(home)
    theme_dir = "#{home}/.config/omarchy/current"
    FileUtils.mkdir_p(theme_dir)
    File.write("#{theme_dir}/alacritty.toml", MINI_ALACRITTY)
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
