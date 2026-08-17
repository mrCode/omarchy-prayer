require 'omarchy_prayer/paths'

module OmarchyPrayer
  # Reads and writes single keys inside the [bar] section of config.toml.
  #
  # Text-level rewrite rather than a TOML round-trip, for the same reason as
  # AudioSetting: config.toml is hand-edited and full of comments and column
  # alignment that a re-serialise would destroy. Section tracking matters —
  # [notifications] has an `enabled` key too.
  module BarSetting
    SECTION = 'bar'.freeze

    module_function

    def get(key, path = Paths.config_file)
      return nil unless File.exist?(path)
      each_line_with_section(File.read(path)) do |line, section|
        next unless section == SECTION
        m = line.match(/\A\s*#{Regexp.escape(key)}\s*=\s*(.*?)\s*\z/m)
        return unquote(m[1]) if m
      end
      nil
    end

    # Returns the written value, or nil when there is no config to write.
    def set(key, value, path = Paths.config_file)
      return nil unless File.exist?(path)
      text = File.read(path)
      rewritten = replace_key(text, key, value) || append_key(text, key, value)
      File.write(path, rewritten) unless rewritten == text
      value
    end

    def literal(value)
      case value
      when true, false, Integer then value.to_s
      else "\"#{value}\""
      end
    end

    def unquote(raw)
      raw =~ /\A"(.*)"\z/m ? Regexp.last_match(1) : raw
    end

    # Returns nil when the key is not present, so the caller can append.
    def replace_key(text, key, value)
      found = false
      out = []
      each_line_with_section(text) do |line, section|
        if section == SECTION &&
           (m = line.match(/\A(\s*#{Regexp.escape(key)}\s*=\s*)(.*?)(\s*)\z/m))
          found = true
          out << "#{m[1]}#{literal(value)}#{m[3]}"
        else
          out << line
        end
      end
      found ? out.join : nil
    end

    def append_key(text, key, value)
      out = []
      inserted = false
      lines = text.lines
      lines.each_with_index do |line, i|
        out << line
        next unless !inserted && line.match(/\A\s*\[#{SECTION}\]\s*\z/)
        # Insert after the last line of the section so appended keys group
        # together rather than splitting the section header from its body.
        j = i + 1
        j += 1 while lines[j] && !lines[j].match(/\A\s*\[[^\]]+\]\s*\z/)
        out.concat(lines[(i + 1)...j])
        out << "#{key} = #{literal(value)}\n"
        out.concat(lines[j..] || [])
        inserted = true
        break
      end
      inserted ? out.join : "#{text}\n[#{SECTION}]\n#{key} = #{literal(value)}\n"
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
