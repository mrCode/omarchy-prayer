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
      if File.exist?(path)
        pid = File.read(path).strip.to_i
        FileUtils.rm_f(path)
        if pid.positive?
          begin
            Process.kill('TERM', pid)
            # Non-blocking reap so direct children (tests) don't leave zombies.
            5.times do
              break if Process.waitpid(pid, Process::WNOHANG)
              sleep 0.02
            end
          rescue Errno::ESRCH, Errno::ECHILD
            # ESRCH: process gone. ECHILD: detached mpv, not our child. Both fine.
          end
        end
      end
      sweep_orphan_players
    end

    private

    # Fallback: find player processes whose argv mentions our adhan paths and
    # kill them. Catches the race where stop runs before notify's PID file was
    # written, plus untracked players (e.g. TUI test). Uses /proc rather than
    # pkill -f because pkill regex match-against-full-argv accidentally matches
    # shells that happen to contain "mpv" in their command line.
    def sweep_orphan_players
      player_name = File.basename(@player)
      Dir.glob('/proc/[0-9]*/cmdline').each do |path|
        argv = begin
          File.read(path).split("\0")
        rescue Errno::ENOENT, Errno::EACCES
          next
        end
        next if argv.empty?
        next unless File.basename(argv[0]) == player_name
        next unless argv.any? { |a| a.include?('omarchy-prayer') }
        pid = File.basename(File.dirname(path)).to_i
        next if pid <= 0
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH, Errno::EPERM
          # ESRCH: gone. EPERM: not ours. Either way, skip.
        end
      end
    end

    def write_pid_atomic(pid)
      tmp = "#{Paths.adhan_pid}.tmp.#{Process.pid}"
      File.write(tmp, pid.to_s)
      File.rename(tmp, Paths.adhan_pid)
    end
  end
end
