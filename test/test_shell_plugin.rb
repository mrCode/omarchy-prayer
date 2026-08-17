require 'test_helper'
require 'stringio'
require 'omarchy_prayer/shell_plugin'

class TestShellPlugin < Minitest::Test
  include TestHelper

  # Stands in for the packaged /usr/share/omarchy-prayer/shell-plugin.
  def fake_source(home)
    dir = File.join(home, 'pkg', 'shell-plugin')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.json'), '{"id":"io.github.mrcode.prayer-times"}')
    File.write(File.join(dir, 'BarWidget.qml'), '// widget')
    dir
  end

  def install(version: '0.2.0', done: [], src:)
    OmarchyPrayer::ShellPlugin.install!(
      io: StringIO.new, done: done, version: version, source: src
    )
    done
  end

  def enable_calls(log)
    read_shim_log(log).select { |e| e[0] == 'omarchy-shell' && e.include?('enablePlugin') }
  end

  def test_installs_plugin_into_user_config
    with_isolated_home do |home|
      log  = with_shims(home, %w[omarchy-shell])
      done = install(src: fake_source(home))

      target = File.join(home, '.config', 'omarchy', 'plugins', 'io.github.mrcode.prayer-times')
      assert File.exist?(File.join(target, 'manifest.json'))
      assert File.exist?(File.join(target, 'BarWidget.qml'))
      assert_equal '0.2.0', File.read(File.join(target, '.version')).strip
      assert_equal 1, enable_calls(log).length
      assert done.any? { |d| d.include?('io.github.mrcode.prayer-times') }, done.inspect
    end
  end

  def test_placement_is_right_section_index_zero
    with_isolated_home do |home|
      log = with_shims(home, %w[omarchy-shell])
      install(src: fake_source(home))
      call = enable_calls(log).first
      assert_includes call, '{"section":"right","index":0}'
    end
  end

  def test_second_run_does_not_recopy_or_reenable
    with_isolated_home do |home|
      src = fake_source(home)
      log = with_shims(home, %w[omarchy-shell])
      install(src: src)
      done2 = install(src: src)
      assert_equal 1, enable_calls(log).length, 'must enable exactly once'
      assert_empty done2, 'an idempotent run should report no changes'
    end
  end

  def test_version_change_recopies_but_does_not_reenable
    with_isolated_home do |home|
      src = fake_source(home)
      log = with_shims(home, %w[omarchy-shell])
      install(src: src)
      done = install(src: src, version: '0.3.0')

      assert_equal '0.3.0',
                   File.read(File.join(OmarchyPrayer::ShellPlugin.target_dir, '.version')).strip
      assert done.any? { |d| d.include?('0.3.0') }, done.inspect
      assert_equal 1, enable_calls(log).length
    end
  end

  # If the user takes the widget off their bar, setup must respect that.
  def test_user_removal_is_respected
    with_isolated_home do |home|
      src = fake_source(home)
      log = with_shims(home, %w[omarchy-shell])
      install(src: src)
      install(src: src)
      install(src: src)
      assert_equal 1, enable_calls(log).length,
                   'setup must never force the widget back onto the bar'
    end
  end

  def test_backs_up_existing_shell_json
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      FileUtils.mkdir_p(File.join(home, '.config', 'omarchy'))
      shell_json = File.join(home, '.config', 'omarchy', 'shell.json')
      File.write(shell_json, '{"bar":{}}')

      done = install(src: fake_source(home))

      backups = Dir[File.join(home, '.config', 'omarchy', 'shell.json.bak.omarchy-prayer-*')]
      assert_equal 1, backups.length
      assert_equal '{"bar":{}}', File.read(backups.first)
      assert done.any? { |d| d.include?('backed up') }, done.inspect
    end
  end

  # --- legacy id migration (prayer.times -> io.github.mrcode.prayer-times) ---

  def legacy_dir(home)
    File.join(home, '.config', 'omarchy', 'plugins', 'prayer.times')
  end

  def seed_legacy_install(home, on_bar: true)
    FileUtils.mkdir_p(legacy_dir(home))
    File.write(File.join(legacy_dir(home), 'manifest.json'), '{"id":"prayer.times"}')
    FileUtils.mkdir_p(File.join(home, '.config', 'omarchy'))
    layout = on_bar ? '{"id":"prayer.times"},{"id":"omarchy.tray"}' : '{"id":"omarchy.tray"}'
    File.write(OmarchyPrayer::ShellPlugin.shell_json_path,
               "{\"bar\":{\"layout\":{\"right\":[#{layout}]}}}")
  end

  def test_legacy_plugin_directory_is_removed
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      seed_legacy_install(home)
      install(src: fake_source(home))
      refute Dir.exist?(legacy_dir(home)), 'stale plugin dir must not linger'
    end
  end

  def test_legacy_bar_entry_is_renamed_in_place
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      seed_legacy_install(home)
      install(src: fake_source(home))

      shell_json = File.read(OmarchyPrayer::ShellPlugin.shell_json_path)
      refute_includes shell_json, '"prayer.times"'
      assert_includes shell_json, '"io.github.mrcode.prayer-times"'
      assert_operator shell_json.index('io.github.mrcode.prayer-times'),
                      :<, shell_json.index('omarchy.tray'),
                      'renaming must preserve the widget position on the bar'
    end
  end

  def test_legacy_migration_backs_up_shell_json
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      seed_legacy_install(home)
      done = install(src: fake_source(home))
      backups = Dir[File.join(home, '.config', 'omarchy', 'shell.json.bak.omarchy-prayer-*')]
      refute_empty backups
      assert done.any? { |d| d.match?(/renamed|migrat/i) }, done.inspect
    end
  end

  # A user who removed the old widget should not get the new one forced back.
  def test_legacy_removal_is_respected
    with_isolated_home do |home|
      log = with_shims(home, %w[omarchy-shell])
      seed_legacy_install(home, on_bar: false)
      FileUtils.mkdir_p(OmarchyPrayer::Paths.state_dir)
      FileUtils.touch(OmarchyPrayer::ShellPlugin.enabled_marker)
      install(src: fake_source(home))
      shell_json = File.read(OmarchyPrayer::ShellPlugin.shell_json_path)
      refute_includes shell_json, 'io.github.mrcode.prayer-times',
                      'must not add the widget back to a bar it was removed from'
      assert_empty enable_calls(log)
    end
  end

  def test_fresh_install_without_legacy_is_unaffected
    with_isolated_home do |home|
      with_shims(home, %w[omarchy-shell])
      done = install(src: fake_source(home))
      refute done.any? { |d| d.match?(/renamed|migrat/i) }, done.inspect
    end
  end

  def test_no_source_dir_is_a_noop
    with_isolated_home do |_home|
      done = install(src: nil)
      assert_empty done
    end
  end
end
