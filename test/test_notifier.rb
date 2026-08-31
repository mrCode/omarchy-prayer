require 'test_helper'
require 'omarchy_prayer/notifier'
require 'omarchy_prayer/today'
require 'omarchy_prayer/paths'

class TestNotifier < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  def adhan_files(home)
    adhan = "#{home}/adhan.mp3"; File.write(adhan, 'stub')
    fajr  = "#{home}/adhan-fajr.mp3"; File.write(fajr, 'stub')
    [adhan, fajr]
  end

  def notifier_for(today_obj, adhan, fajr)
    OmarchyPrayer::Notifier.new(
      today: today_obj, respect_silencing: true,
      audio_enabled: true, audio_player: 'mpv', volume: 80,
      adhan: adhan, adhan_fajr: fajr, pre_notify_minutes: 10
    )
  end

  def test_on_time_notification_emits_notify_send_and_plays_audio
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      wait_for_shim(log, 'mpv')
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'notify-send' && e.include?('Dhuhr') },
             "no notify-send with Dhuhr: #{entries.inspect}"
      assert entries.any? { |e| e[0] == 'mpv' && e.include?(adhan) },
             "no mpv invocation: #{entries.inspect}"
    end
  end

  # The property that matters: a blocking notify-send must not delay the adhan.
  # `notify-send --action=` waits for the user to click (or for the daemon to
  # time out), so if audio were started after it, the adhan would arrive minutes
  # late.
  #
  # This does NOT compare shim log ORDER. mpv is spawned detached, so under CPU
  # load the kernel can schedule it after the foreground notify-send has already
  # appended its line — the log inverts while the spawn order is still correct.
  # That made the old assertion fail about 1 run in 45 on a loaded machine, which
  # matters because this suite runs in the AUR PKGBUILD's check() on every user
  # who builds the package.
  #
  # Instead: make notify-send block for BLOCK_SECS and require the adhan to be
  # audible well before it returns. Normal spawn latency is single-digit
  # milliseconds, so the window below is a ~40x margin; a regression that moved
  # audio after notify-send could not produce mpv until BLOCK_SECS had elapsed.
  BLOCK_SECS  = 3
  DETECT_SECS = 2.0

  def test_audio_starts_during_the_blocking_notify_send
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv],
                       delays: { 'notify-send' => BLOCK_SECS })
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      adhan, fajr = adhan_files(home)

      fired = Thread.new { notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time') }
      started = Time.now
      heard = wait_for_shim(log, 'mpv', timeout: DETECT_SECS)
      elapsed = Time.now - started

      assert heard,
             "adhan did not start within #{DETECT_SECS}s while notify-send was blocking " \
             "for #{BLOCK_SECS}s — audio is being delayed by the notification. " \
             "log: #{read_shim_log(log).inspect}"
      assert fired.alive?,
             'notify-send should still have been blocking when the adhan started; ' \
             'the shim did not block, so this test proved nothing'
      fired.join

      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'mpv' && e.include?(adhan) },
             "wrong audio file: #{entries.inspect}"
      assert entries.any? { |e| e[0] == 'notify-send' && e.any? { |a| a.start_with?('--action=') } },
             "no notify-send --action=: #{entries.inspect}"
      assert_operator elapsed, :<, BLOCK_SECS,
                      'adhan must start before notify-send returns, not after'
    end
  end

  def test_fajr_uses_fajr_variant
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :fajr, event: 'on-time')
      wait_for_shim(log, 'mpv')
      assert read_shim_log(log).any? { |e| e[0] == 'mpv' && e.include?(fajr) },
             "fajr variant not played"
    end
  end

  def test_pre_event_skips_audio
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :asr, event: 'pre')
      sleep 0.1
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'notify-send' && e.include?('10 min to Asr') },
             "no pre-notification: #{entries.inspect}"
      refute entries.any? { |e| e[0] == 'mpv' }, "mpv was spawned for pre event"
    end
  end

  def test_dnd_respected
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'do-not-disturb'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert_empty read_shim_log(log).select { |e| e[0] == 'notify-send' }
      assert_empty read_shim_log(log).select { |e| e[0] == 'mpv' }
    end
  end

  def test_mute_today_suppresses
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      FileUtils.mkdir_p(File.dirname(OmarchyPrayer::Paths.mute_today))
      FileUtils.touch(OmarchyPrayer::Paths.mute_today)
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      assert_empty read_shim_log(log).select { |e| %w[notify-send mpv].include?(e[0]) }
    end
  end

  # --- Omarchy 4 DND (omarchy-shell notifications isDnd) --------------------

  # with_isolated_home restores HOME/XDG/PATH/OP_SHIM_LOG but not the per-shim
  # stdout vars, so each test below clears its own.
  def test_dnd_respected_via_omarchy_shell
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'on'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert_empty read_shim_log(log).select { |e| e[0] == 'notify-send' }
      assert_empty read_shim_log(log).select { |e| e[0] == 'mpv' }
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_fires_when_omarchy_shell_reports_dnd_off
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'off'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert read_shim_log(log).any? { |e| e[0] == 'notify-send' && e.include?('Dhuhr') },
             "expected a Dhuhr notification: #{read_shim_log(log).inspect}"
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
    end
  end

  def test_omarchy_shell_takes_precedence_over_makoctl
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send omarchy-shell makoctl mpv])
      ENV['OP_SHIM_STDOUT_OMARCHY_SHELL'] = 'off'
      ENV['OP_SHIM_STDOUT_MAKOCTL']       = 'do-not-disturb'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert read_shim_log(log).any? { |e| e[0] == 'notify-send' },
             'live shell DND state must win over a stale mako'
    ensure
      ENV.delete('OP_SHIM_STDOUT_OMARCHY_SHELL')
      ENV.delete('OP_SHIM_STDOUT_MAKOCTL')
    end
  end

  def test_fires_when_neither_dnd_probe_answers
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send mpv])
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :dhuhr, event: 'on-time')
      sleep 0.1
      assert read_shim_log(log).any? { |e| e[0] == 'notify-send' },
             'a broken probe must never silently swallow a prayer notification'
    end
  end
end
