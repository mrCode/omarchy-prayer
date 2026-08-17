require 'json'
require 'fileutils'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/version'

module OmarchyPrayer
  # Installs the Omarchy 4 Quickshell bar widget.
  #
  # The shell only scans ~/.config/omarchy/plugins/, so a pacman package cannot
  # own the live plugin files — we copy them out of the package at setup time.
  module ShellPlugin
    # Marketplace plugin IDs are permanent and globally unique, so this is
    # namespaced. `prayer.times` shipped in 0.2.0/0.2.1 and is migrated below.
    PLUGIN_ID        = 'io.github.mrcode.prayer-times'.freeze
    LEGACY_PLUGIN_ID = 'prayer.times'.freeze
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

    def legacy_target_dir
      File.join(Paths.xdg_config_home, 'omarchy', 'plugins', LEGACY_PLUGIN_ID)
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

      migrate_legacy_id!(done: done)
      copy!(src, version, done) if installed_version != version
      enable!(io: io, done: done)
    rescue StandardError => e
      io.puts "warning: could not install shell plugin (#{e.message})"
    end

    # 0.2.2 renamed the plugin id. Rewrite the id in shell.json rather than
    # remove-and-re-add, so the widget keeps its position on the user's bar,
    # and drop the stale plugin directory. A user who had already taken the
    # widget off their bar has nothing to rename, and stays that way.
    def migrate_legacy_id!(done:)
      FileUtils.rm_rf(legacy_target_dir) if Dir.exist?(legacy_target_dir)

      path = shell_json_path
      return unless File.exist?(path)
      text = File.read(path)
      needle = "\"#{LEGACY_PLUGIN_ID}\""
      return unless text.include?(needle)

      backup_shell_json(done)
      File.write(path, text.gsub(needle, "\"#{PLUGIN_ID}\""))
      done << "renamed #{LEGACY_PLUGIN_ID} to #{PLUGIN_ID} on your bar"
    end

    def copy!(src, version, done)
      FileUtils.mkdir_p(File.dirname(target_dir))
      FileUtils.rm_rf(target_dir)
      FileUtils.cp_r(src, target_dir)
      File.write(version_file, version)
      done << "installed #{PLUGIN_ID} shell plugin (#{version})"
      warn_on_id_mismatch(done)
    end

    # The shell keys plugins on the manifest id, not the directory name. If a
    # stale package is the copy source its manifest can declare a different id
    # than the bar entry we just wrote, and the widget silently fails to
    # render — say so instead of leaving an empty slot.
    def warn_on_id_mismatch(done)
      manifest = File.join(target_dir, 'manifest.json')
      return unless File.exist?(manifest)
      id = JSON.parse(File.read(manifest))['id']
      return if id == PLUGIN_ID
      done << "warning: installed manifest declares id #{id.inspect}, expected " \
              "#{PLUGIN_ID.inspect} — the packaged plugin is out of date; " \
              'reinstall omarchy-prayer'
    rescue StandardError
      nil
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
