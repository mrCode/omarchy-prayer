require 'fileutils'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  module Migrations
    MARKER_FILENAME = '.migrated-mute-default-v1'.freeze

    module_function

    def marker_path
      File.join(Paths.state_dir, MARKER_FILENAME)
    end

    def run(io: $stderr)
      return if File.exist?(marker_path)
      mute_audio_default(io)
      Paths.ensure_state_dir
      FileUtils.touch(marker_path)
    rescue StandardError => e
      io.puts "omarchy-prayer: migration warning (#{e.class}: #{e.message})"
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
