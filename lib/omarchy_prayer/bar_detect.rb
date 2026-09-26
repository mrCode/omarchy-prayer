require 'omarchy_prayer/paths'

module OmarchyPrayer
  # Which status bar is this machine actually running?
  #
  # Omarchy 4 replaced waybar with a Quickshell shell. Machines upgraded from
  # Omarchy 3 keep the waybar binary and config as leftovers, so Quickshell is
  # checked first — the live bar is the correct integration target.
  module BarDetect
    SHELL_PACKAGE_DIR = '/usr/share/omarchy/shell'.freeze

    module_function

    def detect(package_dir: SHELL_PACKAGE_DIR)
      return :quickshell if quickshell?(package_dir: package_dir)
      return :waybar     if waybar_config_path
      :none
    end

    # Deliberately does NOT test for ~/.config/omarchy/shell.json: that file is
    # optional, since the shell falls back to packaged defaults when the user
    # has never customised their bar. Keying on it would misdetect a stock
    # Omarchy 4 install as having no bar at all.
    # `package_dir` is injectable so a test can prove the PING path works on its
    # own. With it hardcoded, any machine that has the shell package installed
    # returns true from the fallback and a broken ping goes unnoticed — which is
    # exactly what happened.
    def quickshell?(package_dir: SHELL_PACKAGE_DIR)
      return false unless which('omarchy-shell')
      return true if `omarchy-shell shell ping 2>/dev/null`.strip == 'ok'

      # Shell installed but not running — e.g. setup invoked over SSH or from
      # a package hook.
      Dir.exist?(package_dir)
    rescue StandardError
      false
    end

    def waybar_config_path
      %w[config.jsonc config]
        .map { |name| File.join(Paths.xdg_config_home, 'waybar', name) }
        .find { |path| File.exist?(path) }
    end

    def which(cmd)
      ENV['PATH'].to_s.split(File::PATH_SEPARATOR)
                 .any? { |dir| File.executable?(File.join(dir, cmd)) }
    end
  end
end
