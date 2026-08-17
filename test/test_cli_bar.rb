require 'test_helper'
require 'omarchy_prayer/paths'

# Exercises `omarchy-prayer bar` as a real subprocess (not by calling Ruby
# methods directly) so argument parsing, exit codes, and stdout/stderr
# routing are covered end to end, the same way a shell-based caller (the
# panel's design picker) will invoke it.
class TestCliBar < Minitest::Test
  include TestHelper

  PROJECT = File.expand_path('..', __dir__)

  CONFIG = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"

    [bar]
    # how the pill reads
    format                 = "{city} · {prayer} {countdown}"
    soon_threshold_minutes = 10
  TOML

  def seed
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, CONFIG)
  end

  def text
    File.read(OmarchyPrayer::Paths.config_file)
  end

  # Spawns the real binary via IO.popen, merging stderr into stdout, and
  # returns [output, exit_status]. Runs with the caller's already-isolated
  # HOME/XDG env (see with_isolated_home) plus RUBYLIB pointed at lib/.
  def run_bar(*args)
    env = { 'RUBYLIB' => "#{PROJECT}/lib" }
    cmd = [File.join(PROJECT, 'bin', 'omarchy-prayer'), 'bar', *args]
    out = IO.popen(env, cmd, err: [:child, :out], &:read)
    [out, $?.exitstatus]
  end

  def test_status_reports_defaults_over_a_full_preset_config
    with_isolated_home do
      seed
      out, status = run_bar('status')
      assert_equal 0, status
      assert_match(/\Apreset\s+full/, out)
      assert_match(/format\s+"\{city\} · \{prayer\} \{countdown\}"/, out)
      assert_match(/names\s+latin/, out)
      assert_match(/compact countdown\s+off/, out)
      assert_match(/quiet until\s+off/, out)
    end
  end

  def test_status_with_no_argument_defaults_to_status
    with_isolated_home do
      seed
      out, status = run_bar
      assert_equal 0, status
      assert_match(/\Apreset\s+full/, out)
    end
  end

  def test_preset_list_marks_the_active_preset
    with_isolated_home do
      seed
      out, status = run_bar('preset', 'list')
      assert_equal 0, status
      assert_match(/^\* full$/, out)
      assert_match(/^  minimal$/, out)
      assert_match(/^  icon$/, out)
    end
  end

  def test_preset_minimal_writes_format_preserving_alignment_and_comments
    with_isolated_home do
      seed
      out, status = run_bar('preset', 'minimal')
      assert_equal 0, status
      assert_equal "bar preset: minimal\n", out
      assert_match(/format                 = "\{prayer\} \{countdown\}"/, text)
      assert_includes text, '# how the pill reads'
      assert_includes text, 'soon_threshold_minutes = 10'
    end
  end

  def test_preset_round_trips_back_to_full
    with_isolated_home do
      seed
      run_bar('preset', 'minimal')
      out, status = run_bar('preset', 'full')
      assert_equal 0, status
      assert_equal "bar preset: full\n", out
      assert_match(/format                 = "\{city\} · \{prayer\} \{countdown\}"/, text)

      status_out, = run_bar('status')
      assert_match(/\Apreset\s+full/, status_out)
    end
  end

  # No `preset` config key exists — only `format` is ever written.
  def test_preset_never_writes_a_preset_key
    with_isolated_home do
      seed
      run_bar('preset', 'minimal')
      refute_match(/^\s*preset\s*=/, text)
    end
  end

  def test_preset_bogus_is_rejected_without_writing_config
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('preset', 'bogus')
      assert_equal 1, status
      assert_match(/unknown preset "bogus"/, out)
      assert_match(/valid: full, minimal, icon/, out)
      assert_equal before, text, 'config.toml must be untouched on invalid input'
    end
  end

  def test_names_arabic_writes_names_key
    with_isolated_home do
      seed
      out, status = run_bar('names', 'arabic')
      assert_equal 0, status
      assert_equal "bar names: arabic\n", out
      assert_match(/names\s*=\s*"arabic"/, text)
    end
  end

  def test_names_invalid_is_rejected_without_writing_config
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('names', 'klingon')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar names <latin\|arabic>/, out)
      assert_equal before, text
    end
  end

  def test_compact_on_writes_boolean_unquoted
    with_isolated_home do
      seed
      out, status = run_bar('compact', 'on')
      assert_equal 0, status
      assert_equal "bar compact countdown: on\n", out
      assert_match(/compact_countdown\s*=\s*true/, text)
    end
  end

  def test_compact_off_writes_boolean_unquoted
    with_isolated_home do
      seed
      run_bar('compact', 'on')
      out, status = run_bar('compact', 'off')
      assert_equal 0, status
      assert_equal "bar compact countdown: off\n", out
      assert_match(/compact_countdown\s*=\s*false/, text)
    end
  end

  def test_compact_invalid_is_rejected_without_writing_config
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('compact', 'sideways')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar compact <on\|off>/, out)
      assert_equal before, text
    end
  end

  def test_quiet_15_writes_minutes
    with_isolated_home do
      seed
      out, status = run_bar('quiet', '15')
      assert_equal 0, status
      assert_equal "bar quiet: collapses beyond 15m\n", out
      assert_match(/quiet_until_minutes\s*=\s*15/, text)
    end
  end

  def test_quiet_0_disables
    with_isolated_home do
      seed
      run_bar('quiet', '15')
      out, status = run_bar('quiet', '0')
      assert_equal 0, status
      assert_equal "bar quiet: off\n", out
      assert_match(/quiet_until_minutes\s*=\s*0/, text)
    end
  end

  def test_quiet_negative_is_rejected_without_writing_config
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('quiet', '-5')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar quiet <minutes>   \(0 disables\)/, out)
      assert_equal before, text
    end
  end

  def test_quiet_non_numeric_is_rejected_without_writing_config
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('quiet', 'soon')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar quiet/, out)
      assert_equal before, text
    end
  end

  def test_unknown_subcommand_prints_usage_and_exits_1
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('flarp')
      assert_equal 1, status
      assert_match(%r{usage: omarchy-prayer bar \[preset\|names\|compact\|quiet\|status\]}, out)
      assert_equal before, text
    end
  end

  def test_status_aborts_cleanly_when_config_is_missing
    with_isolated_home do
      out, status = run_bar('status')
      refute_equal 0, status
      assert_match(/config\.toml not found/, out)
    end
  end
end
