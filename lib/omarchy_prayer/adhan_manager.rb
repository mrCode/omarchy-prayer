require 'fileutils'
require 'net/http'
require 'uri'
require 'omarchy_prayer/adhan_catalog'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class AdhanManager
    class Error < StandardError; end

    def self.adhan_dir
      File.join(Paths.xdg_config_home.sub(%r{/\.config$}, '/.local/share'), 'omarchy-prayer', 'adhans')
    end

    def self.local_path(key)
      File.join(adhan_dir, "#{key}.mp3")
    end

    # Lists all catalog entries with a :downloaded flag.
    def self.list
      AdhanCatalog.all.map do |e|
        e.merge(downloaded: File.exist?(local_path(e[:key])))
      end
    end

    # Downloads an entry to adhan_dir/<key>.mp3. Returns the local path.
    # `url_override` lets tests point at a local WEBrick instance.
    def self.download(key, url_override: nil, io: $stdout)
      entry = AdhanCatalog.find(key) or raise Error, "unknown adhan: #{key.inspect}"
      url = url_override || entry[:url]
      FileUtils.mkdir_p(adhan_dir)
      dst = local_path(key)
      io.puts "downloading #{entry[:label]} from #{url}…"
      uri = URI(url)
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                             open_timeout: 20, read_timeout: 60) do |http|
        http.get(uri.request_uri)
      end
      raise Error, "HTTP #{resp.code}" unless resp.code == '200'
      File.binwrite(dst, resp.body)
      io.puts "saved #{dst} (#{resp.body.bytesize} bytes)"
      dst
    end

    # Rewrites config.toml to point audio.adhan (or audio.adhan_fajr) at the
    # local file for `key`. The file is downloaded first if missing (unless
    # caller passes skip_download: true).
    def self.set(key, fajr: false, skip_download: false, io: $stdout)
      entry = AdhanCatalog.find(key) or raise Error, "unknown adhan: #{key.inspect}"
      dst = local_path(key)
      download(key, io: io) unless skip_download || File.exist?(dst)

      cfg_path = Paths.config_file
      raise Error, "config.toml missing at #{cfg_path}" unless File.exist?(cfg_path)
      text = File.read(cfg_path)
      field = fajr ? 'adhan_fajr' : 'adhan'
      pattern = /^(\s*#{Regexp.escape(field)}\s*=\s*)"[^"]*"/m
      if text =~ pattern
        text = text.sub(pattern, "\\1\"#{dst}\"")
      else
        raise Error, "no `#{field} = \"...\"` line in #{cfg_path}"
      end
      File.write(cfg_path, text)
      io.puts "set #{field} = \"#{dst}\" in #{cfg_path}"
      dst
    end

    # Returns { adhan: path-or-nil, adhan_fajr: path-or-nil } as currently set.
    def self.current
      text = File.exist?(Paths.config_file) ? File.read(Paths.config_file) : ''
      extract = ->(field) {
        m = text.match(/^\s*#{field}\s*=\s*"([^"]*)"/m)
        m && Paths.expand(m[1])
      }
      { adhan: extract.call('adhan'), adhan_fajr: extract.call('adhan_fajr') }
    end
  end
end
