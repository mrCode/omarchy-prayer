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
      sleep 0.1
      entries = read_shim_log(log)
      assert entries.any? { |e| e[0] == 'notify-send' && e.include?('Dhuhr') },
             "no notify-send with Dhuhr: #{entries.inspect}"
      assert entries.any? { |e| e[0] == 'mpv' && e.include?(adhan) },
             "no mpv invocation: #{entries.inspect}"
    end
  end

  def test_fajr_uses_fajr_variant
    with_isolated_home do |home|
      log = with_shims(home, %w[notify-send makoctl mpv])
      ENV['OP_SHIM_STDOUT_MAKOCTL'] = 'default'
      adhan, fajr = adhan_files(home)
      notifier_for(today, adhan, fajr).fire(prayer: :fajr, event: 'on-time')
      sleep 0.1
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
end
