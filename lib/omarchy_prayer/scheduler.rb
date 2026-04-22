require 'omarchy_prayer/today'

module OmarchyPrayer
  class Scheduler
    UNIT_PREFIX = 'op-'

    def rebuild(today, pre_minutes:)
      stop_existing
      Today::ORDER.each do |prayer|
        hhmm = today.times[prayer]
        next unless hhmm
        at = parse_time(today.date, hhmm, today.tz_offset)
        create_transient(today.date, prayer, 'on-time', at)

        if pre_minutes.positive?
          create_transient(today.date, prayer, 'pre', at - pre_minutes * 60)
        end
      end
    end

    def stop_existing
      out = `systemctl --user list-timers --all --no-legend 2>/dev/null`
      out.each_line do |line|
        unit = line.strip.split(/\s+/).find { |tok| tok.start_with?(UNIT_PREFIX) && tok.end_with?('.timer') }
        next unless unit
        system('systemctl', '--user', 'stop', unit)
      end
    end

    private

    def parse_time(date, hhmm, tz_offset)
      y, m, d = date.split('-').map(&:to_i)
      h, mi   = hhmm.split(':').map(&:to_i)
      Time.new(y, m, d, h, mi, 0, tz_offset)
    end

    def create_transient(date, prayer, event, at)
      unit = "#{UNIT_PREFIX}#{prayer}-#{event}-#{date}"
      on_calendar = at.strftime('%Y-%m-%d %H:%M:%S')
      system('systemd-run', '--user',
             "--unit=#{unit}",
             "--on-calendar=#{on_calendar}",
             '--timer-property=AccuracySec=1s',
             'omarchy-prayer-notify', prayer.to_s, event)
    end
  end
end
