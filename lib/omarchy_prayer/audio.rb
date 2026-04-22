require 'fileutils'
require 'omarchy_prayer/paths'

module OmarchyPrayer
  class Audio
    def initialize(player: 'mpv', volume: 80)
      @player = player
      @volume = volume
    end

    def play(file)
      Paths.ensure_state_dir
      pid = Process.spawn(@player, '--no-video', '--really-quiet',
                          "--volume=#{@volume}", file,
                          pgroup: true,
                          %i[out err] => '/dev/null',
                          :in => '/dev/null')
      Process.detach(pid)
      write_pid_atomic(pid)
      pid
    end

    def stop
      path = Paths.adhan_pid
      return unless File.exist?(path)
      pid = File.read(path).strip.to_i
      FileUtils.rm_f(path)
      return if pid.zero?
      begin
        Process.kill('TERM', pid)
        # Attempt a non-blocking reap so the process doesn't linger as a zombie
        # when it happens to be a direct child (e.g. in tests).  Try a few times
        # to give the signal time to be delivered.  Silently ignore ECHILD when
        # the process is not our child (normal production case).
        5.times do
          break if Process.waitpid(pid, Process::WNOHANG)
          sleep 0.02
        end
      rescue Errno::ESRCH
        # Already gone — fine.
      rescue Errno::ECHILD
        # Not our child (detached mpv); nothing to reap.
      end
    end

    private

    def write_pid_atomic(pid)
      tmp = "#{Paths.adhan_pid}.tmp.#{Process.pid}"
      File.write(tmp, pid.to_s)
      File.rename(tmp, Paths.adhan_pid)
    end
  end
end
