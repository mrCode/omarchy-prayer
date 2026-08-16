require 'fileutils'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/version'

module OmarchyPrayer
  # Installs the Omarchy 4 Quickshell bar widget.
  #
  # The shell only scans ~/.config/omarchy/plugins/, so a pacman package cannot
  # own the live plugin files — we copy them out of the package at setup time.
  module ShellPlugin
    PLUGIN_ID      = 'prayer.times'.freeze
    PLACEMENT      = '{"section":"right","index":0}'.freeze
    ENABLED_MARKER = '.shell-plugin-enabled-v1'.freeze

    PACKAGED_SOURCE = '/usr/share/omarchy-prayer/shell-plugin'.freeze
    REPO_SOURCE     = File.expand_path('../../share/omarchy-shell-plugin', __dir__)

    module_function

    # Packaged copy wins, so a pacman install is never shadowed by a stale
    # source checkout.
    def source_dir
      [PACKAGED_SOURCE,
       File.join(Paths.home, '.local/share/omarchy-prayer/shell-plugin'),
       REPO_SOURCE].find { |dir| Dir.exist?(dir) }
    end

    def target_dir
      File.join(Paths.xdg_config_home, 'omarchy', 'plugins', PLUGIN_ID)
    end

    def version_file;    File.join(target_dir, '.version');          end
    def enabled_marker;  File.join(Paths.state_dir, ENABLED_MARKER); end

    def shell_json_path
      File.join(Paths.xdg_config_home, 'omarchy', 'shell.json')
    end

    def installed_version
      File.exist?(version_file) ? File.read(version_file).strip : nil
    end

    # `source` is injectable so tests can point at a fixture directory without
    # monkeypatching — minitest/mock is not available when the AUR PKGBUILD's
    # check() runs the suite outside bundler.
    def install!(io:, done:, version: VERSION, source: source_dir)
      src = source
      unless src
        io.puts 'warning: shell plugin source not found — skipping bar widget'
        return
      end

      copy!(src, version, done) if installed_version != version
      enable!(io: io, done: done)
    rescue StandardError => e
      io.puts "warning: could not install shell plugin (#{e.message})"
    end

    def copy!(src, version, done)
      FileUtils.mkdir_p(File.dirname(target_dir))
      FileUtils.rm_rf(target_dir)
      FileUtils.cp_r(src, target_dir)
      File.write(version_file, version)
      done << "installed #{PLUGIN_ID} shell plugin (#{version})"
    end

    # Placement happens exactly once. If the user later takes the widget off
    # their bar, re-running setup keeps the plugin files current but respects
    # that decision rather than forcing it back.
    def enable!(io:, done:)
      return if File.exist?(enabled_marker)

      backup_shell_json(done)
      ok = system('omarchy-shell', 'shell', 'enablePlugin', PLUGIN_ID, PLACEMENT,
                  out: File::NULL, err: File::NULL)
      Paths.ensure_state_dir
      FileUtils.touch(enabled_marker)

      done << if ok
                "added #{PLUGIN_ID} to your bar"
              else
                "could not place #{PLUGIN_ID} automatically — add it with " \
                "`omarchy-shell shell enablePlugin #{PLUGIN_ID} '#{PLACEMENT}'`"
              end
    end

    def backup_shell_json(done)
      path = shell_json_path
      return unless File.exist?(path)
      backup = "#{path}.bak.omarchy-prayer-#{Time.now.to_i}"
      FileUtils.cp(path, backup)
      done << "backed up shell.json → #{backup}"
    end
  end
end
