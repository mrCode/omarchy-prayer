$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'

module TestHelper
  # Isolate HOME / XDG so tests never touch the real user's files.
  def with_isolated_home
    Dir.mktmpdir('omarchy-prayer-test-') do |home|
      orig = %w[HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR PATH OP_SHIM_LOG]
              .map { |k| [k, ENV[k]] }.to_h
      ENV['HOME']            = home
      ENV['XDG_CONFIG_HOME'] = "#{home}/.config"
      ENV['XDG_STATE_HOME']  = "#{home}/.local/state"
      ENV['XDG_CACHE_HOME']  = "#{home}/.cache"
      ENV['XDG_RUNTIME_DIR'] = "#{home}/run"
      %w[.config .local/state .cache run].each { |d| FileUtils.mkdir_p(File.join(home, d)) }
      yield home
    ensure
      orig.each { |k, v| ENV[k] = v }
    end
  end

  # Must be called inside with_isolated_home; PATH + OP_SHIM_LOG are restored there.
  # Put a temp dir at the front of PATH holding log-only shims for commands.
  # The shim writes "<name>\t<argv joined by \t>\n" to $OP_SHIM_LOG.
  def with_shims(home, names)
    shim_dir = File.join(home, 'shims')
    log_file = File.join(home, 'shim.log')
    FileUtils.mkdir_p(shim_dir)
    ENV['OP_SHIM_LOG'] = log_file
    names.each do |name|
      path = File.join(shim_dir, name)
      File.write(path, <<~SH)
        #!/usr/bin/env bash
        printf '%s' "#{name}" >> "$OP_SHIM_LOG"
        for a in "$@"; do printf '\t%s' "$a" >> "$OP_SHIM_LOG"; done
        printf '\n' >> "$OP_SHIM_LOG"
        var="OP_SHIM_STDOUT_#{name.upcase.gsub(/[^A-Z0-9]/, '_')}"
        eval "out=\\"\\$$var\\""
        if [ -n "$out" ]; then printf '%s' "$out"; fi
        exit 0
      SH
      File.chmod(0o755, path)
    end
    ENV['PATH'] = "#{shim_dir}:#{ENV['PATH']}"
    log_file
  end

  def read_shim_log(path)
    return [] unless File.exist?(path)
    File.readlines(path, chomp: true).map { |l| l.split("\t") }
  end
end
