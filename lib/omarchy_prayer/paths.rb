require 'fileutils'

module OmarchyPrayer
  module Paths
    module_function

    APP = 'omarchy-prayer'

    def home
      ENV['HOME'] || Dir.home
    end

    def xdg_config_home
      ENV['XDG_CONFIG_HOME'] || File.join(home, '.config')
    end

    def xdg_state_home
      ENV['XDG_STATE_HOME'] || File.join(home, '.local/state')
    end

    def config_dir; File.join(xdg_config_home, APP); end
    def state_dir;  File.join(xdg_state_home,  APP); end

    def config_file;     File.join(config_dir, 'config.toml');                   end
    def today_json;      File.join(state_dir,  'today.json');                    end
    def month_cache(ym); File.join(state_dir,  "times-#{ym}.json");              end
    def adhan_pid;       File.join(state_dir,  'current-adhan.pid');             end
    def mute_today;      File.join(state_dir,  'mute-today');                    end

    def ensure_config_dir; FileUtils.mkdir_p(config_dir); config_dir; end
    def ensure_state_dir;  FileUtils.mkdir_p(state_dir);  state_dir;  end

    def expand(path)
      path.start_with?('~') ? File.expand_path(path) : path
    end
  end
end
