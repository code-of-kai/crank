defmodule Crank.Integration.Dep001Test do
  @moduledoc """
  End-to-end test for the topology layer (Phase 1.4 of `purity-enforcement.md`).

  Stages a consumer mix project under `System.tmp_dir!()` that depends on
  `:crank` by path and adds `:crank` to `:compilers`. Asserts that:

    * a domain module (`use Crank`) calling an infrastructure module
      (`use Boundary`) produces `CRANK_DEP_001` in the compile output
    * a domain module calling a `use Crank.Domain.Pure` helper compiles
      cleanly with no `CRANK_DEP_*` diagnostic

  This is the canonical Stage 5 spike validation: the full pipeline runs
  through `Mix.Tasks.Compile.Crank`, Boundary's checker, and
  `Crank.BoundaryIntegration.translate_error/2`. If any seam breaks the
  test fails.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  test "domain module aliasing infrastructure emits CRANK_DEP_001 and clean helper compiles silent" do
    crank_root = Path.expand(Path.join(__DIR__, "../.."))
    project_dir = stage_project!(crank_root)

    on_exit(fn -> archive_dir(project_dir) end)

    {get_output, get_exit} =
      System.cmd("mix", ["deps.get"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert get_exit == 0, "mix deps.get failed: #{get_output}"

    {compile_output, _exit_code} =
      System.cmd("mix", ["compile", "--force"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    # Violating domain → infra reference produces CRANK_DEP_001
    assert compile_output =~ "[CRANK_DEP_001]",
           "expected CRANK_DEP_001 in compile output, got:\n#{compile_output}"

    assert compile_output =~ "ViolatingDomain",
           "expected ViolatingDomain to be named in the diagnostic, got:\n#{compile_output}"

    assert compile_output =~ "Infra",
           "expected Infra boundary to be named, got:\n#{compile_output}"

    # The clean fixture (CleanDomain calls CleanHelper which is a Crank.Domain.Pure)
    # should NOT trigger any CRANK_DEP_* diagnostic
    refute compile_output =~ "CleanDomain references",
           "did not expect CleanDomain to fire CRANK_DEP_*, got:\n#{compile_output}"
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp stage_project!(crank_root) do
    dir = Path.join(System.tmp_dir!(), "crank_dep_001_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule TestApp.MixProject do
      use Mix.Project

      def project do
        [
          app: :test_app_dep_001,
          version: "0.1.0",
          elixir: "~> 1.15",
          compilers: [:crank] ++ Mix.compilers(),
          deps: [{:crank, path: #{inspect(crank_root)}}]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """)

    File.write!(Path.join([dir, "lib", "infra.ex"]), """
    defmodule TestApp.Infra do
      use Boundary, deps: [], exports: [Repo]
    end

    defmodule TestApp.Infra.Repo do
      def insert!(record), do: record
    end
    """)

    File.write!(Path.join([dir, "lib", "violating_domain.ex"]), """
    defmodule ViolatingDomain do
      use Crank
      alias TestApp.Infra.Repo

      @impl true
      def start(_), do: {:ok, :idle, %{last: nil}}

      @impl true
      def turn(:save, :idle, memory) do
        # crank-allow: CRANK_PURITY_001
        # reason: e2e topology test fixture for CRANK_DEP_001
        saved = Repo.insert!(:something)
        {:next, :saved, %{memory | last: saved}}
      end
    end
    """)

    File.write!(Path.join([dir, "lib", "clean_helper.ex"]), """
    defmodule CleanHelper do
      use Crank.Domain.Pure

      def add(a, b), do: a + b
    end
    """)

    File.write!(Path.join([dir, "lib", "clean_domain.ex"]), """
    defmodule CleanDomain do
      use Crank, boundary_deps: [CleanHelper]

      @impl true
      def start(_), do: {:ok, :idle, %{value: 0}}

      @impl true
      def turn({:add, x, y}, :idle, memory) do
        {:stay, %{memory | value: CleanHelper.add(x, y)}}
      end
    end
    """)

    dir
  end

  defp archive_dir(dir) do
    archive_root = Path.join(System.tmp_dir!(), "crank_integration_archive")
    File.mkdir_p!(archive_root)
    target = Path.join(archive_root, Path.basename(dir))
    _ = File.rename(dir, target)
    :ok
  end
end
