defmodule Crank.ApplicationTest do
  use ExUnit.Case, async: true

  describe "otp_release/0" do
    test "returns an integer at or above the minimum" do
      release = Crank.Application.otp_release()
      assert is_integer(release)
      assert release >= Crank.Application.minimum_otp_release()
    end
  end

  describe "minimum_otp_release/0" do
    test "is 26 (the trace-session API floor)" do
      assert Crank.Application.minimum_otp_release() == 26
    end
  end

  describe "check_otp_version!/0" do
    test "returns :ok on supported OTP" do
      assert :ok = Crank.Application.check_otp_version!()
    end
  end

  describe "Crank.TaskSupervisor lifecycle" do
    test "Crank.TaskSupervisor is registered after application start" do
      pid = Process.whereis(Crank.TaskSupervisor)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "Crank.TaskSupervisor restarts if killed" do
      original_pid = Process.whereis(Crank.TaskSupervisor)
      ref = Process.monitor(original_pid)
      Process.exit(original_pid, :kill)

      # Wait for the down message
      receive do
        {:DOWN, ^ref, :process, ^original_pid, _reason} -> :ok
      after
        1000 -> flunk("Crank.TaskSupervisor did not die")
      end

      # OTP supervision should restart it
      :timer.sleep(50)
      new_pid = Process.whereis(Crank.TaskSupervisor)
      assert is_pid(new_pid)
      assert new_pid != original_pid
    end
  end
end
