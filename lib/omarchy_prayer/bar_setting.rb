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
      else "\"#{escape(value.to_s)}\""
      end
    end

    # Escape backslashes first, then quotes — otherwise a quote's escaping
    # backslash would itself get re-escaped by the next pass.
    def escape(str)
      str.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }
    end

    def unescape(str)
      str.gsub('\\"') { '"' }.gsub('\\\\') { '\\' }
    end

    def unquote(raw)
      raw =~ /\A"(.*)"\z/m ? unescape(Regexp.last_match(1)) : raw
    end

    # Returns nil when the key is not present, so the caller can append.
    def replace_key(text, key, value)
      found = false
      out = []
      each_line_with_section(text) do |line, section|
        if section == SECTION &&
           (m = line.match(/\A(\s*#{Regexp.escape(key)}\s*=\s*)(.*)\z/m))
          found = true
          _old_value, trailing = split_value_and_trailing(m[2])
          out << "#{m[1]}#{literal(value)}#{trailing}"
        else
          out << line
        end
      end
      found ? out.join : nil
    end

    # Splits the text after `key = ` into the old value token and everything
    # that follows it (inter-token spacing, an optional trailing `# comment`,
    # and the line terminator), so a rewrite can carry that tail over
    # untouched instead of swallowing a comment into the old value's lazy
    # match. A quoted string is scanned for its real closing quote (honouring
    # `\"` escapes) so a `#` inside the value itself is never mistaken for a
    # comment marker.
    def split_value_and_trailing(rest)
      if rest.start_with?('"')
        i = 1
        escaped = false
        while i < rest.length
          c = rest[i]
          if escaped
            escaped = false
          elsif c == '\\'
            escaped = true
          elsif c == '"'
            break
          end
          i += 1
        end
        [rest[0..i], rest[(i + 1)..] || '']
      else
        m = rest.match(/\A(\S*)(.*)\z/m)
        [m[1], m[2]]
      end
    end

    def append_key(text, key, value)
      # Normalise first so every element of `text.lines` is newline-terminated.
      # Without this, a [bar] section at end-of-file with no trailing newline
      # leaves its last line unterminated; concatenating the new key line
      # straight onto it would glue the two into one unparseable TOML line.
      normalized = ensure_trailing_newline(text)
      out = []
      inserted = false
      lines = normalized.lines
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
      return out.join if inserted

      separator = normalized.empty? ? '' : "\n"
      "#{normalized}#{separator}[#{SECTION}]\n#{key} = #{literal(value)}\n"
    end

    def ensure_trailing_newline(text)
      return text if text.empty? || text.end_with?("\n")
      "#{text}\n"
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
