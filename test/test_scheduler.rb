require 'test_helper'
require 'omarchy_prayer/scheduler'
require 'omarchy_prayer/today'

class TestScheduler < Minitest::Test
  include TestHelper

  def today
    OmarchyPrayer::Today.new(
      date: '2026-04-22', tz_offset: 10800, city: 'Riyadh', country: 'SA',
      method: 'Makkah', source: 'api',
      times: { fajr: '04:15', sunrise: '05:35', dhuhr: '11:48',
               asr: '15:18', maghrib: '18:01', isha: '19:21' }
    )
  end

  def test_issues_ten_units_with_correct_on_calendar
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 10)
      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      assert_equal 10, calls.size
      assert calls.all? { |c| c.include?('--user') }
      assert calls.all? { |c| c.any? { |a| a.start_with?('--on-calendar=') } }
      assert calls.any? { |c|
        c.include?('--on-calendar=2026-04-22 04:15:00') &&
        c.any? { |a| a.start_with?('--unit=op-fajr-on-time') }
      }, "missing Fajr on-time unit: #{calls.inspect}"
      assert calls.any? { |c|
        c.include?('--on-calendar=2026-04-22 04:05:00') &&
        c.any? { |a| a.start_with?('--unit=op-fajr-pre') }
      }, "missing Fajr pre unit: #{calls.inspect}"
    end
  end

  def test_pre_minutes_zero_disables_pre_timers
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = ''
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 0)
      calls = read_shim_log(log).select { |e| e[0] == 'systemd-run' }
      assert_equal 5, calls.size
      assert calls.none? { |c| c.any? { |a| a.include?('-pre') } }
    end
  end

  def test_stops_prior_units_before_creating_new
    with_isolated_home do |home|
      log = with_shims(home, %w[systemd-run systemctl])
      ENV['OP_SHIM_STDOUT_SYSTEMCTL'] = "op-old.timer loaded active\n"
      OmarchyPrayer::Scheduler.new.rebuild(today, pre_minutes: 10)
      calls = read_shim_log(log).select { |e| e[0] == 'systemctl' }
      assert calls.any? { |c| c.include?('stop') && c.include?('op-old.timer') },
             "systemctl stop op-old.timer not invoked: #{calls.inspect}"
    end
  end
end
