require 'fileutils'
require 'json'
require 'omarchy_prayer/paths'
require 'omarchy_prayer/adhan_manager'

module OmarchyPrayer
  # Idempotent, package-level bootstrap. Safe to re-run on every launch.
  #
  # Three independent steps, each guarded by a cheap "already done" check:
  #   - ensure_default_adhans: download Makkah/Madinah on first use, set them
  #     in config.toml (if user is still on placeholder paths).
  #   - ensure_waybar_module: patch the user's waybar config to include the
  #     custom/prayer module, backing up the original first.
  #   - ensure_systemd_units: enable the daily-reschedule timer and the
  #     resume hook so prayers rebuild on boot / resume.
  module Setup
    DEFAULT_ADHAN      = 'makkah'
    DEFAULT_ADHAN_FAJR = 'madinah'

    WAYBAR_MODULE = {
      'exec'           => 'omarchy-prayer-waybar',
      'interval'       => 30,
      'return-type'    => 'json',
      'on-click'       => 'alacritty -e omarchy-prayer',
      'on-click-right' => 'omarchy-prayer-stop',
      'tooltip'        => true
    }.freeze

    # Placeholder paths written by FirstRun::TEMPLATE — we treat them as
    # "unset, install the default here" rather than "user chose this".
    PLACEHOLDER_ADHAN      = '~/.config/omarchy-prayer/adhan.mp3'
    PLACEHOLDER_ADHAN_FAJR = '~/.config/omarchy-prayer/adhan-fajr.mp3'

    module_function

    # Run all three steps. Returns an Array of human-readable strings describing
    # what was changed; empty Array means "everything already configured".
    def run(io: $stdout, skip_network: false)
      done = []
      ensure_default_adhans(io: io, skip_network: skip_network, done: done)
      ensure_waybar_module(io: io, done: done)
      ensure_systemd_units(io: io, done: done)
      done
    end

    # --- adhan audio -------------------------------------------------------

    def ensure_default_adhans(io:, skip_network:, done:)
      return unless File.exist?(Paths.config_file)

      text = File.read(Paths.config_file)
      {
        'adhan'      => { key: DEFAULT_ADHAN,      placeholder: PLACEHOLDER_ADHAN,      fajr: false },
        'adhan_fajr' => { key: DEFAULT_ADHAN_FAJR, placeholder: PLACEHOLDER_ADHAN_FAJR, fajr: true }
      }.each do |field, spec|
        match = text.match(/^\s*#{field}\s*=\s*"([^"]*)"/m)
        next unless match
        current = match[1]
        local   = AdhanManager.local_path(spec[:key])

        # Nothing to do if user already points at an existing file (theirs or ours).
        next if File.exist?(Paths.expand(current))
        # Respect custom non-placeholder paths even if file missing — user may
        # be provisioning it themselves.
        next unless current == spec[:placeholder] || current == local

        if skip_network
          io.puts "skipping #{field} download (offline mode) — re-run `omarchy-prayer setup` with network"
          next
        end

        begin
          AdhanManager.download(spec[:key], io: io)
        rescue AdhanManager::Error, SocketError, Errno::ECONNREFUSED, Errno::ENETUNREACH => e
          io.puts "warning: could not download #{spec[:key]}: #{e.message} (skipping — re-run later)"
          next
        end

        AdhanManager.set(spec[:key], fajr: spec[:fajr], skip_download: true, io: io)
        text = File.read(Paths.config_file)
        done << "downloaded #{spec[:key]} and set as #{field}"
      end
    end

    # --- waybar module ------------------------------------------------------

    def ensure_waybar_module(io:, done:)
      path = waybar_config_path
      return unless path

      original = File.read(path)
      return if original.include?('"custom/prayer"')

      patched = patch_waybar_text(original)
      return unless patched

      backup = "#{path}.bak.omarchy-prayer-#{Time.now.to_i}"
      FileUtils.cp(path, backup)
      File.write(path, patched)
      reload_waybar
      done << "added custom/prayer to #{path} (backup: #{backup})"
      io.puts "patched waybar config → #{path}"
    rescue => e
      io.puts "warning: could not patch waybar config (#{e.message}) — add the snippet manually"
    end

    def waybar_config_path
      %w[config.jsonc config].each do |name|
        p = File.join(Paths.xdg_config_home, 'waybar', name)
        return p if File.exist?(p)
      end
      nil
    end

    # Text-level injection so JSONC comments are preserved. Returns nil when we
    # can't safely patch (e.g. no modules-right array, no closing brace).
    def patch_waybar_text(text)
      # Validate parseability first (tolerant of JSONC: // and /* */ comments,
      # trailing commas). If it won't parse, we refuse to touch it.
      return nil unless jsonc_parseable?(text)

      patched = text.dup

      # 1. Add "custom/prayer" as first element of modules-right, preserving
      # the whitespace used after the opening [.
      if patched =~ /"modules-right"\s*:\s*\[(\s*)/
        ws = Regexp.last_match(1)
        patched = patched.sub(/"modules-right"\s*:\s*\[(\s*)/,
                              %("modules-right": ["custom/prayer",#{ws}))
      end

      # 2. Inject the custom/prayer module definition right before the final }.
      idx = patched.rindex('}')
      return nil unless idx

      before = patched[0...idx].rstrip
      after  = patched[idx..]

      # Strip a trailing comma if present (JSONC-permissive files).
      before = before[0...-1].rstrip if before.end_with?(',')

      module_snippet = <<~JSON.rstrip
        ,
          "custom/prayer": {
            "exec": "omarchy-prayer-waybar",
            "interval": 30,
            "return-type": "json",
            "on-click": "alacritty -e omarchy-prayer",
            "on-click-right": "omarchy-prayer-stop",
            "tooltip": true
          }
      JSON

      "#{before}#{module_snippet}\n#{after}".sub(/\n*\z/, "\n")
    end

    def jsonc_parseable?(text)
      JSON.parse(strip_jsonc(text))
      true
    rescue JSON::ParserError
      false
    end

    # Strip // line comments (outside strings), /* ... */ block comments,
    # and trailing commas. Conservative — only used for validation parsing.
    def strip_jsonc(text)
      out = String.new
      i = 0
      in_str = false
      escape = false
      while i < text.length
        c = text[i]
        if in_str
          out << c
          if escape
            escape = false
          elsif c == '\\'
            escape = true
          elsif c == '"'
            in_str = false
          end
          i += 1
        elsif c == '"'
          in_str = true
          out << c
          i += 1
        elsif c == '/' && text[i + 1] == '/'
          i += 2
          i += 1 while i < text.length && text[i] != "\n"
        elsif c == '/' && text[i + 1] == '*'
          i += 2
          i += 1 while i < text.length && !(text[i] == '*' && text[i + 1] == '/')
          i += 2
        else
          out << c
          i += 1
        end
      end
      # strip trailing commas before ] or }
      out.gsub(/,(\s*[\]}])/, '\1')
    end

    def reload_waybar
      # pkill is quiet when no waybar is running, which is fine.
      system('pkill', '-SIGUSR2', 'waybar', out: File::NULL, err: File::NULL)
    end

    # --- systemd units ------------------------------------------------------

    def ensure_systemd_units(io:, done:)
      %w[
        omarchy-prayer-schedule.timer
        omarchy-prayer-resume.service
      ].each do |unit|
        next unless unit_installed?(unit)
        next if unit_enabled?(unit)
        args = ['systemctl', '--user', 'enable']
        args << '--now' if unit.end_with?('.timer')
        args << unit
        if system(*args, out: File::NULL, err: File::NULL)
          done << "enabled #{unit}"
        else
          io.puts "warning: could not enable #{unit}"
        end
      end
    end

    def unit_installed?(unit)
      paths = [
        File.join(Paths.xdg_config_home, 'systemd/user', unit),
        "/usr/lib/systemd/user/#{unit}",
        "/etc/systemd/user/#{unit}"
      ]
      paths.any? { |p| File.exist?(p) }
    end

    def unit_enabled?(unit)
      out = `systemctl --user is-enabled #{unit} 2>/dev/null`.strip
      %w[enabled enabled-runtime static linked linked-runtime].include?(out)
    end
  end
end
