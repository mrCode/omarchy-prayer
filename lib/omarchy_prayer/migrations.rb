require 'fileutils'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  module Migrations
    MARKER_FILENAME     = '.migrated-mute-default-v1'.freeze
    BAR_MARKER_FILENAME = '.migrated-bar-section-v1'.freeze

    module_function

    def marker_path
      File.join(Paths.state_dir, MARKER_FILENAME)
    end

    def bar_marker_path
      File.join(Paths.state_dir, BAR_MARKER_FILENAME)
    end

    # Each migration carries its own marker so adding one never re-runs, or
    # skips, the others.
    def run(io: $stderr)
      unless File.exist?(marker_path)
        mute_audio_default(io)
        Paths.ensure_state_dir
        FileUtils.touch(marker_path)
      end

      unless File.exist?(bar_marker_path)
        rename_bar_section(io)
        Paths.ensure_state_dir
        FileUtils.touch(bar_marker_path)
      end
    rescue StandardError => e
      io.puts "omarchy-prayer: migration warning (#{e.class}: #{e.message})"
    end

    # [waybar] became [bar] in 0.2.0 — the section now drives both the waybar
    # module and the Omarchy 4 Quickshell widget.
    def rename_bar_section(io)
      path = Paths.config_file
      return unless File.exist?(path)
      text = File.read(path)
      new_text = text.sub(/^[ \t]*\[waybar\][ \t]*$/, '[bar]')
      return if new_text == text
      File.write(path, new_text)
      io.puts 'omarchy-prayer: renamed [waybar] to [bar] in config.toml ' \
              '(it now configures both the waybar module and the Omarchy 4 widget).'
    end

    def mute_audio_default(io)
      path = Paths.config_file
      return unless File.exist?(path)
      text = File.read(path)
      new_text = flip_audio_enabled_section(text)
      return if new_text == text
      File.write(path, new_text)
      io.puts 'omarchy-prayer: adhan audio is now muted by default. ' \
              'Re-enable by setting `enabled = true` under [audio] in ' \
              '~/.config/omarchy-prayer/config.toml.'
    end

    # Walk the TOML line by line, tracking the active section header.
    # Rewrite ONLY the `enabled = true` line that sits under [audio].
    def flip_audio_enabled_section(text)
      section = nil
      text.each_line.map do |line|
        if (m = line.match(/\A\s*\[([^\]]+)\]\s*\z/))
          section = m[1].strip
          line
        elsif section == 'audio' && line =~ /\A(\s*enabled\s*=\s*)true\s*\z/
          "#{Regexp.last_match(1)}false\n"
        else
          line
        end
      end.join
    end
  end
end
