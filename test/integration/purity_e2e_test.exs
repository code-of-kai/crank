defmodule Crank.Integration.PurityE2ETest do
  @moduledoc """
  End-to-end test for the call-site purity layer (Phase 1.3).

  Stages a consumer project that contains both a pure and an impure
  `use Crank` module. Asserts:

    * the pure module compiles cleanly
    * the impure module's compile fails with the expected catalog code
    * a properly-suppressed impure module compiles cleanly

  This catches integration regressions where the `@before_compile`
  hook works in Crank's own test suite but breaks when consumed via a
  path dependency (Hex package shape, missing assets, etc.).
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  test "impure consumer turn/3 fails compile with the expected code; suppressed copy compiles" do
    crank_root = Path.expand(Path.join(__DIR__, "../.."))
    project_dir = stage_impure_project!(crank_root)

    on_exit(fn -> archive_dir(project_dir) end)

    {get_output, get_exit} =
      System.cmd("mix", ["deps.get"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert get_exit == 0, "mix deps.get failed: #{get_output}"

    {compile_output, exit_code} =
      System.cmd("mix", ["compile", "--force"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute exit_code == 0,
           "expected compile to fail on impure module; got success with output:\n#{compile_output}"

    assert compile_output =~ "CRANK_PURITY_001",
           "expected CRANK_PURITY_001 in compile output, got:\n#{compile_output}"
  end

  test "pure consumer with proper suppression compiles cleanly" do
    crank_root = Path.expand(Path.join(__DIR__, "../.."))
    project_dir = stage_suppressed_project!(crank_root)

    on_exit(fn -> archive_dir(project_dir) end)

    {get_output, get_exit} =
      System.cmd("mix", ["deps.get"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert get_exit == 0, "mix deps.get failed: #{get_output}"

    {compile_output, exit_code} =
      System.cmd("mix", ["compile", "--force"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "expected suppressed module to compile cleanly; got failure:\n#{compile_output}"
  end

  # ── stagers ────────────────────────────────────────────────────────────────

  defp stage_impure_project!(crank_root) do
    dir = unique_dir("crank_purity_e2e_impure")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), basic_mix_exs(:test_app_purity_e2e_impure, crank_root))

    File.write!(Path.join([dir, "lib", "pure.ex"]), """
    defmodule PureMachine do
      use Crank

      @impl true
      def start(_), do: {:ok, :idle, %{}}

      @impl true
      def turn(_event, :idle, memory), do: {:next, :active, memory}

      @impl true
      def turn(_event, :active, memory), do: {:stay, memory}
    end
    """)

    File.write!(Path.join([dir, "lib", "impure.ex"]), """
    defmodule ImpureMachine do
      use Crank

      @impl true
      def start(_), do: {:ok, :idle, %{}}

      @impl true
      def turn(:save, :idle, memory) do
        _ = Repo.insert!(memory)
        {:next, :saved, memory}
      end
    end
    """)

    dir
  end

  defp stage_suppressed_project!(crank_root) do
    dir = unique_dir("crank_purity_e2e_suppressed")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), basic_mix_exs(:test_app_purity_e2e_suppressed, crank_root))

    File.write!(Path.join([dir, "lib", "suppressed.ex"]), """
    defmodule SuppressedMachine do
      use Crank

      @impl true
      def start(_), do: {:ok, :idle, %{}}

      @impl true
      def turn(:save, :idle, memory) do
        # crank-allow: CRANK_PURITY_001
        # reason: e2e fixture asserting suppression silences the error
        _ = Repo.insert!(memory)
        {:next, :saved, memory}
      end
    end
    """)

    dir
  end

  defp basic_mix_exs(app_name, crank_root) do
    """
    defmodule TestApp.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(app_name)},
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: [{:crank, path: #{inspect(crank_root)}}]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """
  end

  defp unique_dir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp archive_dir(dir) do
    archive_root = Path.join(System.tmp_dir!(), "crank_integration_archive")
    File.mkdir_p!(archive_root)
    target = Path.join(archive_root, Path.basename(dir))
    _ = File.rename(dir, target)
    :ok
  end
end
