require 'optparse'
require 'fileutils'
require 'omarchy_prayer/geolocate'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  module Relocate
    USAGE = 'usage: omarchy-prayer relocate [--lat N --lon N --city CITY --country CODE]'.freeze

    module_function

    def run(argv, geolocate: Geolocate, io: $stdout)
      opts = parse(argv)
      loc = resolve_location(opts, geolocate: geolocate, io: io)
      update_config!(loc)
      cleared = clear_month_caches
      io.puts "omarchy-prayer: location set to #{loc[:city]}, #{loc[:country]} " \
              "(#{format('%.4f', loc[:latitude])}, #{format('%.4f', loc[:longitude])})"
      io.puts "  cleared #{cleared} cached month(s); next refresh will fetch fresh times"
      loc
    end

    def parse(argv)
      opts = {}
      OptionParser.new do |o|
        o.banner = USAGE
        o.on('--lat F', Float)    { |v| opts[:latitude]  = v }
        o.on('--lon F', Float)    { |v| opts[:longitude] = v }
        o.on('--city CITY')       { |v| opts[:city]      = v }
        o.on('--country CODE')    { |v| opts[:country]   = v }
      end.parse(argv)
      opts
    end

    def resolve_location(opts, geolocate:, io:)
      manual_keys = %i[latitude longitude city country]
      provided = manual_keys.count { |k| opts[k] }
      if provided.zero?
        io.puts 'omarchy-prayer: re-detecting location via ip-api.com…'
        geolocate.detect
      elsif provided == manual_keys.size
        opts.slice(*manual_keys)
      else
        abort "#{USAGE}\n  --lat, --lon, --city, --country must be passed together for manual override"
      end
    end

    def update_config!(loc)
      cfg_path = Paths.config_file
      unless File.exist?(cfg_path)
        abort "config.toml missing at #{cfg_path} — run `omarchy-prayer` first to bootstrap"
      end
      text = File.read(cfg_path)
      text = sub_numeric(text, 'latitude',  format('%.4f', loc[:latitude]))
      text = sub_numeric(text, 'longitude', format('%.4f', loc[:longitude]))
      text = sub_string(text,  'city',      loc[:city])
      text = sub_string(text,  'country',   loc[:country])
      File.write(cfg_path, text)
    end

    def sub_numeric(text, key, value)
      pattern = /^(\s*#{Regexp.escape(key)}\s*=\s*)[^\s#\n]+/
      raise "no `#{key} = ...` line in config.toml" unless text =~ pattern
      text.sub(pattern, "\\1#{value}")
    end

    def sub_string(text, key, value)
      pattern = /^(\s*#{Regexp.escape(key)}\s*=\s*)"[^"]*"/
      raise "no `#{key} = \"...\"` line in config.toml" unless text =~ pattern
      text.sub(pattern, %(\\1"#{value}"))
    end

    def clear_month_caches
      Dir.glob(File.join(Paths.state_dir, 'times-*.json'))
         .each { |p| File.delete(p) }
         .size
    end
  end
end
