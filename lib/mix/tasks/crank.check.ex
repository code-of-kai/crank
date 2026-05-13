defmodule Mix.Tasks.Crank.Check do
  @shortdoc "Runs the full Crank purity-enforcement gate"

  @moduledoc """
  Canonical CI gate. Wraps the underlying tools that comprise the
  Crank purity-enforcement discipline:

    1. **Setup verification** — `:crank` is in `:compilers`, OTP >= 26.
       Failures surface as `CRANK_SETUP_001` / `CRANK_SETUP_002`.
    2. **`mix compile --warnings-as-errors`** — runs Boundary's topology
       check (via the `:crank` Mix compiler) and the `@before_compile`
       call-site check. Topology violations carry `CRANK_DEP_*` codes;
       call-site violations carry `CRANK_PURITY_*` codes.
    3. **`mix credo --strict`** — runs `Crank.Check.TurnPurity` and the
       host project's normal Credo configuration.
    4. **`mix dialyzer`** — runs Dialyzer if the dependency is present
       and a PLT is available. Skipped with a warning if not.
    5. **`mix test`** — runs the host project's test suite.

  ## Options

    * `--skip-dialyzer` — skip the Dialyzer step. Useful in CI lanes
      where Dialyzer runs separately.
    * `--skip-test` — skip the test step. Useful for fast pre-commit
      gating on compile + credo only.
    * `--otp-release N` — synthetic override for the OTP-release check
      used by integration tests on hosts that already run OTP 27+.

  ## Exit code

  Returns 0 on success. On failure, exits with the first non-zero exit
  code from the underlying tools, after running every preceding step
  whose precondition the failing step depends on.

  ## Not applicable to the Crank source repo itself (design record)

  This section is a design record, not a discoverability surface — a
  contributor confused by `CRANK_SETUP_001` against the Crank source
  is more likely to land on the explanatory comment in this repo's
  `mix.exs` (next to the deliberately-omitted `:compilers` entry),
  which points back here for the full reasoning.

  The gate is designed for **consumer projects** — codebases that
  declare FSM modules with `use Crank` and helper modules with
  `use Crank.Domain.Pure`. Running `mix crank.check` against the
  Crank source repo fails immediately at `check_setup/1` with
  `CRANK_SETUP_001`, because `:crank` is intentionally not in the
  Crank library's own `:compilers` list. This is deliberate, not an
  oversight.

  The discipline does not literally apply to the library that defines
  it:

    * The Crank source has zero `use Crank` modules — the library
      defines the `__using__` macro; it does not invoke it on its own
      modules.
    * The Crank source has zero `use Crank.Domain.Pure` modules for
      the same reason.
    * The `__crank_domain__` persisted attribute (set exclusively by
      those two `use` macros) is the prerequisite for every
      `CRANK_PURITY_*` and `CRANK_DEP_002` check. Without it, those
      checks have no surface to fire on.
    * Marking library internals like `Crank.Turns` or `Crank.Typing`
      with `use Crank.Domain.Pure` would tag them as "FSM domain
      helpers" — which they aren't; they're library implementation.
      The category mismatch would exercise the gate's plumbing but
      not its semantic value.

  The library dogfoods via integration tests instead. `test/integration/`
  stages real path-dep consumer projects and exercises the full
  compile-Boundary-diagnostic pipeline against them:

    * `consumer_compile_test.exs` — fresh consumer compiles cleanly
      without Credo loaded.
    * `dep_001_test.exs` — domain-to-infrastructure reference fires
      `CRANK_DEP_001` in a staged consumer.
    * `dep_002_test.exs` — unmarked first-party helper fires
      `CRANK_DEP_002` in a staged consumer.
    * `purity_e2e_test.exs` — full call-site purity pipeline.

  And `test/mix/tasks/crank.check_test.exs` covers `check_setup/1`'s
  compiler-position logic against fake `Mix.Project` fixtures
  (`WiredProject`, `AppendedAfterElixirProject`, etc.).

  Between those two test paths the discipline is verified against the
  shape it's *for* (consumer FSM modules), which is more faithful than
  artificially tagging the library's internals would be. The Crank
  source's own CI lane verifies each underlying component (`mix compile
  --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix test`) individually, since the all-in-one gate cannot run
  against this repo by design.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: [
          skip_dialyzer: :boolean,
          skip_test: :boolean,
          otp_release: :integer
        ]
      )

    Mix.shell().info(IO.ANSI.bright() <> "Crank check" <> IO.ANSI.reset())
    Mix.shell().info("")

    [
      {"setup", &check_setup(&1)},
      {"compile (--warnings-as-errors)", &check_compile(&1)},
      {"credo --strict", &check_credo(&1)},
      {"dialyzer", &check_dialyzer(&1)},
      {"test", &check_test(&1)}
    ]
    |> Enum.reduce_while([], fn {name, fun}, results ->
      case fun.(opts) do
        :skip ->
          Mix.shell().info("  [skip] #{name}")
          {:cont, [{name, :skip} | results]}

        :ok ->
          Mix.shell().info("  [ ok ] #{name}")
          {:cont, [{name, :ok} | results]}

        {:error, code, reason} ->
          Mix.shell().info("  [fail] #{name}  (#{reason})")
          {:halt, [{name, {:error, code}} | results]}
      end
    end)
    |> finalize()
  end

  # ── steps ──────────────────────────────────────────────────────────────────

  @doc false
  def check_setup(opts) do
    case validate_compiler_position() do
      :ok ->
        check_otp_version(opts)

      {:error, reason, context} ->
        violation =
          Crank.Errors.build("CRANK_SETUP_001",
            location: %{file: "mix.exs", line: nil},
            context: context,
            metadata: %{reason: reason}
          )

        Mix.shell().info("")
        Mix.shell().info(Crank.Errors.format_pretty(violation))
        {:error, 1, "CRANK_SETUP_001"}
    end
  end

  defp check_otp_version(opts) do
    otp = Keyword.get(opts, :otp_release, Crank.Application.otp_release())
    minimum = Crank.Application.minimum_otp_release()

    if otp < minimum do
      violation =
        Crank.Errors.build("CRANK_SETUP_002",
          location: %{file: nil, line: nil},
          context: "Runtime OTP #{otp} is below the minimum supported release (#{minimum}).",
          metadata: %{actual_otp: otp, minimum_otp: minimum}
        )

      Mix.shell().info("")
      Mix.shell().info(Crank.Errors.format_pretty(violation))
      {:error, 1, "CRANK_SETUP_002"}
    else
      :ok
    end
  end

  @doc false
  def check_compile(_opts), do: shell_step(["compile", "--warnings-as-errors", "--force"])

  @doc false
  def check_credo(_opts) do
    if dep_loaded?(:credo) do
      shell_step(["credo", "--strict"])
    else
      :skip
    end
  end

  @doc false
  def check_dialyzer(opts) do
    cond do
      Keyword.get(opts, :skip_dialyzer, false) ->
        :skip

      dep_loaded?(:dialyxir) ->
        shell_step(["dialyzer"])

      true ->
        :skip
    end
  end

  @doc false
  def check_test(opts) do
    if Keyword.get(opts, :skip_test, false), do: :skip, else: shell_step(["test"])
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Validates that `:crank` is in the `:compilers` list AND positioned
  # before `:elixir` and `:app`. The `Mix.Tasks.Compile.Crank.run/1`
  # body registers `after_compiler(:elixir, ...)` and
  # `after_compiler(:app, ...)` hooks; if `:crank` runs after either
  # of them, the hooks register too late for the current compile pass
  # and topology enforcement is silently inert.
  #
  # Codex review #25 (2026-05-08) flagged that the previous check
  # only validated membership — projects with the docs-recommended
  # but-now-known-wrong `Mix.compilers() ++ [:crank]` ordering would
  # pass `mix crank.check` while topology checks didn't fire.
  defp validate_compiler_position do
    compilers = Mix.Project.config() |> Keyword.get(:compilers, [])

    cond do
      :crank not in compilers ->
        {:error, :missing,
         "`:crank` is not present in the project's `:compilers` list. Run `mix crank.gen.config` to wire it."}

      crank_runs_after_elixir_or_app?(compilers) ->
        {:error, :wrong_order,
         "`:crank` is positioned AFTER `:elixir` or `:app` in `:compilers`. " <>
           "The Crank compiler registers post-compile hooks; if it runs after those compilers, " <>
           "the hooks register too late and topology enforcement is silently inert. " <>
           "Use `[:crank | Mix.compilers()]` (prepend), not `Mix.compilers() ++ [:crank]` (append). " <>
           "Current compilers: #{inspect(compilers)}"}

      true ->
        :ok
    end
  end

  defp crank_runs_after_elixir_or_app?(compilers) do
    crank_idx = Enum.find_index(compilers, &(&1 == :crank))
    elixir_idx = Enum.find_index(compilers, &(&1 == :elixir))
    app_idx = Enum.find_index(compilers, &(&1 == :app))

    (elixir_idx != nil and crank_idx > elixir_idx) or
      (app_idx != nil and crank_idx > app_idx)
  end

  defp dep_loaded?(app) do
    Mix.Project.config()[:deps]
    |> List.wrap()
    |> Enum.any?(fn
      {^app, _} -> true
      {^app, _, _} -> true
      _ -> false
    end)
  end

  defp shell_step(args) do
    case System.cmd("mix", args, stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} -> :ok
      {_, code} -> {:error, code, "exit #{code}"}
    end
  end

  defp finalize(results) do
    Mix.shell().info("")

    failures =
      Enum.filter(results, fn
        {_, {:error, _}} -> true
        _ -> false
      end)

    case failures do
      [] ->
        Mix.shell().info(IO.ANSI.green() <> "Crank check passed." <> IO.ANSI.reset())
        :ok

      _ ->
        Mix.shell().info(IO.ANSI.red() <> "Crank check failed." <> IO.ANSI.reset())
        [{_, {:error, code}} | _] = failures
        exit({:shutdown, code})
    end
  end
end
