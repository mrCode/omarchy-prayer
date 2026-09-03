require 'test_helper'
require 'omarchy_prayer/paths'
require 'tomlrb'
require 'rbconfig'

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

  CUSTOM_CONFIG = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"

    [bar]
    # hand-edited — matches no built-in preset
    format = "{prayer} at {time}"
  TOML

  # Pre-0.2.0 shape: only [waybar] exists, [bar] has never been written.
  # soon_threshold_minutes is a non-default value so a silent revert to the
  # DEFAULTS constant is distinguishable from a genuine migration.
  UNMIGRATED_CONFIG = <<~TOML.freeze
    [location]
    latitude  = 24.7136
    longitude = 46.6753
    city      = "Riyadh"
    country   = "SA"

    [waybar]
    # how the pill reads
    format                 = "{city} · {prayer} {countdown}"
    soon_threshold_minutes = 37
  TOML

  # The `omarchy-shell` on this machine's real PATH pings "ok" (quickshell),
  # so BarDetect tests must run with a PATH that excludes it entirely to
  # simulate a waybar-only machine. Only ruby's own bindir is kept, since
  # run_bar spawns a real subprocess via `#!/usr/bin/env ruby`.
  RUBY_BINDIR = File.dirname(RbConfig.ruby).freeze

  def seed
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, CONFIG)
  end

  def seed_custom
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, CUSTOM_CONFIG)
  end

  def seed_unmigrated
    FileUtils.mkdir_p(OmarchyPrayer::Paths.config_dir)
    File.write(OmarchyPrayer::Paths.config_file, UNMIGRATED_CONFIG)
  end

  def force_waybar_detection(home)
    FileUtils.mkdir_p(File.join(home, '.config', 'waybar'))
    File.write(File.join(home, '.config', 'waybar', 'config.jsonc'), '{}')
    ENV['PATH'] = RUBY_BINDIR
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

  # Regression: when the stored format matches no built-in preset,
  # Config#bar_preset reports 'custom' — the list must mark that row active
  # (and only that row), since `bar preset list` is the discovery UI and must
  # always answer "which am I on?".
  def test_preset_list_marks_custom_active_when_format_matches_no_preset
    with_isolated_home do
      seed_custom
      out, status = run_bar('preset', 'list')
      assert_equal 0, status
      assert_match(/^\* custom$/, out)
      assert_match(/^  full$/, out)
      assert_match(/^  minimal$/, out)
      assert_match(/^  icon$/, out)
      refute_match(/^\* full$/, out)
      refute_match(/^\* minimal$/, out)
      refute_match(/^\* icon$/, out)

      status_out, = run_bar('status')
      assert_match(/\Apreset\s+custom/, status_out)
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

  # ---- time12 / colored, ported from PR #4 by @ch-arslanahmad ------------

  def test_time12_on_writes_the_bar_key
    with_isolated_home do
      seed
      out, status = run_bar('time12', 'on')
      assert_equal 0, status
      assert_match(/12-hour time: on/, out)
      assert_equal true, Tomlrb.parse(text)['bar']['time_12h']
    end
  end

  def test_time12_off_writes_the_bar_key
    with_isolated_home do
      seed
      run_bar('time12', 'on')
      out, status = run_bar('time12', 'off')
      assert_equal 0, status
      assert_match(/12-hour time: off/, out)
      assert_equal false, Tomlrb.parse(text)['bar']['time_12h']
    end
  end

  def test_colored_on_writes_the_bar_key
    with_isolated_home do
      seed
      out, status = run_bar('colored', 'on')
      assert_equal 0, status
      assert_match(/coloured prayer names: on/, out)
      assert_equal true, Tomlrb.parse(text)['bar']['colored']
    end
  end

  def test_time12_rejects_a_bad_value_and_leaves_config_alone
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('time12', 'maybe')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar time12/, out)
      assert_equal before, text
    end
  end

  def test_colored_rejects_a_bad_value_and_leaves_config_alone
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('colored', 'maybe')
      assert_equal 1, status
      assert_match(/usage: omarchy-prayer bar colored/, out)
      assert_equal before, text
    end
  end

  def test_status_reports_the_new_options
    with_isolated_home do
      seed
      run_bar('time12', 'on')
      out, status = run_bar('status')
      assert_equal 0, status
      assert_match(/12-hour time\s+on/, out)
      assert_match(/coloured names\s+off/, out)
    end
  end

  def test_unknown_subcommand_prints_usage_and_exits_1
    with_isolated_home do
      seed
      before = text
      out, status = run_bar('flarp')
      assert_equal 1, status
      assert_match(%r{usage: omarchy-prayer bar \[preset\|names\|compact\|time12\|colored\|quiet\|status\]}, out)
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

  # Regression: `bar` used to be the one entry point that never migrated an
  # unmigrated config first. BarSetting only knows the literal [bar] header,
  # so it appended a NEW [bar] section alongside a surviving [waybar]; the
  # later [waybar]->[bar] rename then produced two [bar] tables, which
  # Tomlrb refuses to parse — corrupting the config for every entry point.
  def test_bar_command_migrates_an_unmigrated_waybar_config_first
    with_isolated_home do
      seed_unmigrated
      out, status = run_bar('preset', 'minimal')
      assert_equal 0, status
      # stderr (migration notice) and stdout are merged by run_bar; the
      # migration notice is expected here, on top of the normal confirmation.
      assert_match(/renamed \[waybar\] to \[bar\]/, out)
      assert_match(/bar preset: minimal\n\z/, out)

      raw = text
      assert_equal 1, raw.scan(/^\[bar\]/).length, 'must never produce two [bar] tables'
      assert_includes raw, '[bar]'
      refute_includes raw, '[waybar]'

      parsed = Tomlrb.load_file(OmarchyPrayer::Paths.config_file)
      assert_equal '{prayer} {countdown}', parsed['bar']['format']
      assert_equal 37, parsed['bar']['soon_threshold_minutes'],
                   "the user's pre-existing soon_threshold_minutes must survive, not revert to the default"
      refute parsed.key?('waybar')

      # A second bar command afterward must still parse cleanly — no double
      # [bar] section is ever created on a re-run.
      out2, status2 = run_bar('status')
      assert_equal 0, status2
      assert_match(/\Apreset\s+minimal/, out2)
      Tomlrb.load_file(OmarchyPrayer::Paths.config_file) # raises on a corrupt file
    end
  end

  # Regression: `icon` is an empty format. The Quickshell widget collapses to
  # its own mosque glyph, but waybar's module has no glyph of its own — with
  # no `format` override it falls back to the default `{text}`, so an empty
  # format renders nothing at all: no icon, no tooltip, module effectively
  # gone from the bar. The setting is still honoured (the user asked for it);
  # only a warning is added.
  def test_bar_preset_icon_warns_when_the_detected_bar_is_waybar
    with_isolated_home do |home|
      seed
      force_waybar_detection(home)

      out, status = run_bar('preset', 'icon')
      assert_equal 0, status
      assert_match(/bar preset: icon/, out)
      assert_match(/waybar module has no glyph/, out)
      assert_match(/bar preset full/, out, 'the warning must say how to undo it')
      assert_match(/format\s*=\s*""/, text)
    end
  end

  # The same preset on a quickshell-detected machine must apply silently —
  # the warning is specific to waybar's missing glyph.
  def test_bar_preset_icon_is_silent_when_not_on_waybar
    with_isolated_home do
      seed
      out, status = run_bar('preset', 'icon')
      assert_equal 0, status
      assert_equal "bar preset: icon\n", out
    end
  end
end
