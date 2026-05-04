defmodule Mix.Tasks.Crank.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Crank.Check

  describe "check_setup/1" do
    test "fails with CRANK_SETUP_001 when :crank not in :compilers" do
      Mix.Project.push(__MODULE__.NoCompilerProject, "fake/mix.exs")

      try do
        capture_io(fn -> assert {:error, 1, "CRANK_SETUP_001"} = Check.check_setup([]) end)
      after
        Mix.Project.pop()
      end
    end

    test "fails with CRANK_SETUP_002 when synthetic OTP < minimum" do
      Mix.Project.push(__MODULE__.WiredProject, "fake/mix.exs")

      try do
        capture_io(fn ->
          assert {:error, 1, "CRANK_SETUP_002"} = Check.check_setup(otp_release: 25)
        end)
      after
        Mix.Project.pop()
      end
    end

    test "passes when :crank is wired and OTP >= minimum" do
      Mix.Project.push(__MODULE__.WiredProject, "fake/mix.exs")

      try do
        assert :ok = Check.check_setup(otp_release: 26)
      after
        Mix.Project.pop()
      end
    end
  end

  defmodule WiredProject do
    def project do
      [
        app: :wired,
        version: "0.1.0",
        compilers: [:crank | Mix.compilers()]
      ]
    end
  end

  defmodule NoCompilerProject do
    def project do
      [
        app: :unwired,
        version: "0.1.0"
      ]
    end
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
