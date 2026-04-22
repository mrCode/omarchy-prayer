require 'test_helper'
require 'omarchy_prayer/audio'
require 'omarchy_prayer/paths'

class TestAudio < Minitest::Test
  include TestHelper

  def test_play_records_pid_and_log
    with_isolated_home do |home|
      log = with_shims(home, %w[mpv])
      audio_file = "#{home}/adhan.mp3"
      File.write(audio_file, 'stub')
      OmarchyPrayer::Audio.new(player: 'mpv', volume: 77).play(audio_file)
      # Give the detached shim time to run and flush its log.
      sleep 0.1
      assert File.exist?(OmarchyPrayer::Paths.adhan_pid)
      entries = read_shim_log(log)
      assert entries.any? { |e|
        e[0] == 'mpv' &&
        e.include?('--volume=77') &&
        e.include?(audio_file)
      }, "mpv not invoked correctly: #{entries.inspect}"
    end
  end

  def test_stop_kills_process_and_removes_pidfile
    with_isolated_home do
      pid_file = OmarchyPrayer::Paths.adhan_pid
      FileUtils.mkdir_p(File.dirname(pid_file))
      pid = Process.spawn('sleep', '30')
      File.write(pid_file, pid.to_s)
      OmarchyPrayer::Audio.new.stop
      refute File.exist?(pid_file)
      # Give the signal a moment to take effect.
      deadline = Time.now + 0.5
      gone = false
      while Time.now < deadline
        begin
          Process.kill(0, pid)
          sleep 0.02
        rescue Errno::ESRCH
          gone = true
          break
        end
      end
      assert gone, "process #{pid} still alive after stop"
      begin; Process.wait(pid); rescue; end
    end
  end

  def test_stop_without_pid_file_is_noop
    with_isolated_home do
      OmarchyPrayer::Audio.new.stop  # should not raise
    end
  end
end
