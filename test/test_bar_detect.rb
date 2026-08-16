require 'test_helper'
require 'omarchy_prayer/bar_detect'

class TestBarDetect < Minitest::Test
  include TestHelper

  # Strip system PATH so the real /usr/bin/omarchy-shell on this machine can't
  # leak into tests that are meant to simulate its absence.
  def isolate_path(home)
    with_shims(home, [])
    ENV['PATH'] = File.join(home, 'shims')
  end

  def shim_shell(home, ping_output)
    with_shims(home, %w[omarchy-shell])
    ENV['PATH'] = File.join(home, 'shims')
    ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = ping_output
  end

  def write_waybar_config(home)
    FileUtils.mkdir_p("#{home}/.config/waybar")
    File.write("#{home}/.config/waybar/config.jsonc", '{}')
  end

  def test_none_when_no_bar_present
    with_isolated_home do |home|
      isolate_path(home)
      assert_equal :none, OmarchyPrayer::BarDetect.detect
    end
  end

  def test_waybar_when_config_present_and_no_shell
    with_isolated_home do |home|
      isolate_path(home)
      write_waybar_config(home)
      assert_equal :waybar, OmarchyPrayer::BarDetect.detect
    end
  end

  def test_quickshell_when_shell_pings_ok
    with_isolated_home do |home|
      shim_shell(home, 'ok')
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_quickshell_wins_over_waybar_on_upgraded_machine
    with_isolated_home do |home|
      shim_shell(home, 'ok')
      write_waybar_config(home)
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect,
                   'the live bar is the correct target, not the leftover'
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_detection_does_not_depend_on_shell_json
    with_isolated_home do |home|
      shim_shell(home, 'ok')
      refute File.exist?("#{home}/.config/omarchy/shell.json"),
             'a stock Omarchy 4 install may never have written shell.json'
      assert_equal :quickshell, OmarchyPrayer::BarDetect.detect
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_waybar_config_path_finds_both_names
    with_isolated_home do |home|
      isolate_path(home)
      FileUtils.mkdir_p("#{home}/.config/waybar")
      File.write("#{home}/.config/waybar/config", '{}')
      assert_equal "#{home}/.config/waybar/config",
                   OmarchyPrayer::BarDetect.waybar_config_path
    end
  end
end
