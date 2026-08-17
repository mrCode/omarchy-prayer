require 'omarchy_prayer/paths'

module OmarchyPrayer
  # Reads and writes `[audio].enabled` in config.toml.
  #
  # Text-level rewrite rather than a TOML round-trip: config.toml is
  # hand-edited and full of comments and alignment we must not clobber. The
  # section is tracked line by line so only the `enabled` key under [audio] is
  # touched — [notifications] has an `enabled` key too.
  module AudioSetting
    module_function

    def enabled?(path = Paths.config_file)
      return false unless File.exist?(path)
      value_in_audio_section(File.read(path)) == 'true'
    end

    # Returns the new state, or nil when there is no config to write.
    def set(enabled, path = Paths.config_file)
      return nil unless File.exist?(path)
      text = File.read(path)
      rewritten = rewrite(text, enabled)
      File.write(path, rewritten) unless rewritten == text
      enabled
    end

    def toggle(path = Paths.config_file)
      set(!enabled?(path), path)
    end

    def value_in_audio_section(text)
      each_audio_enabled_line(text) { |_line, value| return value }
      nil
    end

    def rewrite(text, enabled)
      target = enabled ? 'true' : 'false'
      out = []
      each_line_with_section(text) do |line, section|
        if section == 'audio' && (m = line.match(/\A(\s*enabled\s*=\s*)(true|false)(\s*)\z/m))
          out << "#{m[1]}#{target}#{m[3]}"
        else
          out << line
        end
      end
      out.join
    end

    def each_audio_enabled_line(text)
      each_line_with_section(text) do |line, section|
        next unless section == 'audio'
        m = line.match(/\A\s*enabled\s*=\s*(true|false)\s*\z/m)
        yield(line, m[1]) if m
      end
    end

    def each_line_with_section(text)
      section = nil
      text.each_line do |line|
        if (m = line.match(/\A\s*\[([^\]]+)\]\s*\z/))
          section = m[1].strip
        end
        yield(line, section)
      end
    end
  end
end
