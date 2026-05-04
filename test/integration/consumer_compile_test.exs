defmodule Crank.Integration.ConsumerCompileTest do
  @moduledoc """
  Regression test for the Credo-as-optional-dep guard.

  Spins up a fresh mix project under `System.tmp_dir!()`, depends on
  `:crank` via path, and asserts `mix compile` succeeds. Without the
  `if Code.ensure_loaded?(Credo.Check)` guard around `Crank.Check.TurnPurity`,
  this test fails because Credo is `only: [:dev, :test]` in Crank's
  `mix.exs` and isn't pulled in for consumers — the module fails to
  compile with `module Credo.Check is not loaded and could not be found`.

  This is the bug that surfaced during Track A (Boundary integration) work
  and would have caught the regression before any user did.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  test "fresh project depending on :crank by path compiles without Credo" do
    crank_root = Path.expand(Path.join(__DIR__, "../.."))
    project_dir = stage_consumer_project!(crank_root)

    on_exit(fn -> archive_dir(project_dir) end)

    {get_output, get_exit} =
      System.cmd("mix", ["deps.get"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert get_exit == 0, "mix deps.get failed: #{get_output}"

    {compile_output, compile_exit} =
      System.cmd("mix", ["compile", "--force"],
        cd: project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    refute compile_output =~ "Credo.Check is not loaded",
           "Credo gate regression: consumer compile failed because Credo is not loaded:\n#{compile_output}"

    assert compile_exit == 0,
           "consumer compile failed (exit #{compile_exit}):\n#{compile_output}"

    refute compile_output =~ "** (CompileError)",
           "consumer compile produced a CompileError:\n#{compile_output}"
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp stage_consumer_project!(crank_root) do
    dir = Path.join(System.tmp_dir!(), "crank_consumer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule CrankConsumer.MixProject do
      use Mix.Project

      def project do
        [
          app: :crank_consumer,
          version: "0.1.0",
          elixir: "~> 1.15",
          deps: [
            {:crank, path: #{inspect(crank_root)}}
          ]
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end
    end
    """)

    File.write!(Path.join([dir, "lib", "consumer.ex"]), """
    defmodule Consumer do
      @moduledoc false
    end
    """)

    dir
  end

  # Move the staged project to a sibling-archive path rather than deleting
  # it; matches the standing-rule preference for reversible cleanup over
  # destructive rm. CI runners reset tmp directories on each run.
  defp archive_dir(dir) do
    archive_root = Path.join(System.tmp_dir!(), "crank_consumer_archive")
    File.mkdir_p!(archive_root)
    target = Path.join(archive_root, Path.basename(dir))
    _ = File.rename(dir, target)
    :ok
  end
end
