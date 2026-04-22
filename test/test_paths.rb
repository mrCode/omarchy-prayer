require 'test_helper'
require 'omarchy_prayer/paths'

class TestPaths < Minitest::Test
  include TestHelper

  def test_config_file_uses_xdg_config_home
    with_isolated_home do |home|
      assert_equal "#{home}/.config/omarchy-prayer/config.toml",
                   OmarchyPrayer::Paths.config_file
    end
  end

  def test_today_json_uses_xdg_state_home
    with_isolated_home do |home|
      assert_equal "#{home}/.local/state/omarchy-prayer/today.json",
                   OmarchyPrayer::Paths.today_json
    end
  end

  def test_expand_user_tilde
    with_isolated_home do |home|
      assert_equal "#{home}/adhan.mp3", OmarchyPrayer::Paths.expand('~/adhan.mp3')
    end
  end

  def test_ensure_state_dir_creates_it
    with_isolated_home do |home|
      dir = OmarchyPrayer::Paths.ensure_state_dir
      assert Dir.exist?(dir)
      assert_equal "#{home}/.local/state/omarchy-prayer", dir
    end
  end
end
