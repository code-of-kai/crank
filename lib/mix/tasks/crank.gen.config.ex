defmodule Mix.Tasks.Crank.Gen.Config do
  @shortdoc "Wires Crank into a project's mix.exs, .credo.exs, and Boundary config"

  @moduledoc """
  One-time setup task for adding Crank's purity-enforcement wiring to a
  project. Modifies `mix.exs`, creates or amends `.credo.exs`, and writes a
  starter `boundary.exs`.

  ## What this task does

  1. **`mix.exs`** — adds `:boundary` and `:crank` to `deps/0` if missing,
     adds `:crank` to the project's `:compilers` list, and adds an inline
     `:boundary` keyword carrying empty `:third_party_pure` and
     `:third_party_impure` lists.
  2. **`boundary.exs`** — written at project root with the commented seed
     classifications shipped in `priv/boundary.exs.template`. Informational;
     users move entries from there into `mix.exs`'s inline `:boundary` block.
  3. **`.credo.exs`** — created with `Crank.Check.TurnPurity` wired in if
     absent, or amended (without clobbering existing checks) if present.
  4. **CI / README snippets** — printed to stdout for the user to copy.
     This task does **not** write to README or CI YAML files.

  ## Idempotency

  Re-running on a configured project produces no file changes. Each step
  detects its own marker (a deps entry, a compilers atom, the
  `Crank.Check.TurnPurity` reference) before adding anything.

  ## Verification

  After running, `mix crank.check` runs the full CI gate. Expect to fix at
  least `CRANK_DEP_003` warnings the first time you run it — that surfaces
  third-party deps that need entering into `:third_party_pure` or
  `:third_party_impure`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: [quiet: :boolean])
    quiet? = Keyword.get(opts, :quiet, false)

    actions =
      []
      |> wire_mix_exs()
      |> write_boundary_exs()
      |> wire_credo_exs()

    unless quiet?, do: report(actions)
    :ok
  end

  # ── mix.exs wiring ─────────────────────────────────────────────────────────

  @doc false
  @spec wire_mix_exs([action()]) :: [action()]
  def wire_mix_exs(actions, path \\ "mix.exs") do
    case File.read(path) do
      {:ok, source} ->
        {new_source, applied} = update_mix_exs_source(source)

        if new_source == source do
          [{:noop, path, "already wired"} | actions]
        else
          File.write!(path, new_source)
          [{:updated, path, applied} | actions]
        end

      {:error, _} ->
        [{:missing, path, "expected at project root"} | actions]
    end
  end

  @doc """
  Pure transformation: takes a `mix.exs` source string and returns
  `{new_source, applied_changes}` describing what was added.

  Each step is independently idempotent. Used directly by the test suite
  so we can assert behaviour without touching the filesystem.
  """
  @spec update_mix_exs_source(binary()) :: {binary(), [binary()]}
  def update_mix_exs_source(source) do
    {s1, c1} = ensure_dep(source, ":boundary", ~s|{:boundary, "~> 0.10"}|)
    {s2, c2} = ensure_dep(s1, ":crank", ~s|{:crank, "~> 1.2"}|)
    {s3, c3} = ensure_compilers_entry(s2)
    {s4, c4} = ensure_boundary_keyword(s3)

    {s4, Enum.reject([c1, c2, c3, c4], &is_nil/1)}
  end

  # Add `entry` to the deps list if `marker` (e.g. `":boundary"`) isn't
  # already present in the same `defp deps` block.
  #
  # Supports both forms:
  #   * `defp deps do [ ... ] end`  (block form)
  #   * `defp deps, do: [ ... ]`    (keyword form)
  defp ensure_dep(source, marker, entry) do
    pattern = ~r/(defp\s+deps(?:\s*,\s*do:\s*|\s+do\s*)\[)([^\]]*)(\])/s

    case Regex.run(pattern, source, capture: :all_but_first, return: :index) do
      nil ->
        {source, nil}

      [{_, _}, {body_start, body_len}, _] ->
        body = binary_part(source, body_start, body_len)

        if String.contains?(body, marker) do
          {source, nil}
        else
          new_body = inject_dep(body, entry)

          new_source =
            binary_part(source, 0, body_start) <>
              new_body <> binary_part(source, body_start + body_len, byte_size(source) - body_start - body_len)

          {new_source, "added dep #{entry} to mix.exs"}
        end
    end
  end

  # Insert the entry as the last item in the deps list. Preserves
  # surrounding whitespace and trailing commas.
  defp inject_dep(body, entry) do
    trimmed = String.trim_trailing(body)

    cond do
      trimmed == "" ->
        "\n      " <> entry <> "\n    "

      String.ends_with?(trimmed, ",") ->
        body_no_trailing_ws = String.trim_trailing(body)
        leading = byte_size(body_no_trailing_ws)
        prefix = binary_part(body, 0, leading)
        suffix = binary_part(body, leading, byte_size(body) - leading)
        prefix <> "\n      " <> entry <> suffix

      true ->
        body_no_trailing_ws = String.trim_trailing(body)
        leading = byte_size(body_no_trailing_ws)
        prefix = binary_part(body, 0, leading)
        suffix = binary_part(body, leading, byte_size(body) - leading)
        prefix <> ",\n      " <> entry <> suffix
    end
  end

  # Ensure `compilers: [:crank | Mix.compilers()]` is in the project block.
  # If a `compilers:` key already exists, prepend `:crank` if absent.
  # If not, add it after the `deps: deps()` line.
  defp ensure_compilers_entry(source) do
    cond do
      Regex.match?(~r/compilers:\s*\[\s*:crank\b/s, source) ->
        {source, nil}

      Regex.match?(~r/compilers:\s*\[/s, source) ->
        new_source = Regex.replace(~r/compilers:\s*\[/s, source, "compilers: [:crank, ", global: false)
        {new_source, "added :crank to existing :compilers list in mix.exs"}

      Regex.match?(~r/deps:\s*deps\(\)/, source) ->
        new_source =
          Regex.replace(
            ~r/(deps:\s*deps\(\))(\s*,)?/,
            source,
            "\\1,\n      compilers: [:crank | Mix.compilers()]",
            global: false
          )

        {new_source, "added :compilers entry with :crank to mix.exs project config"}

      true ->
        {source, nil}
    end
  end

  # Ensure `boundary:` keyword is in the project block with starter
  # third-party classifications. Idempotent; skips if `boundary:` already
  # exists.
  defp ensure_boundary_keyword(source) do
    if Regex.match?(~r/^\s*boundary:\s*\[/m, source) do
      {source, nil}
    else
      cond do
        Regex.match?(~r/compilers:\s*\[/, source) ->
          new_source =
            Regex.replace(
              ~r/(compilers:\s*\[[^\]]*\])(\s*,)?/,
              source,
              "\\1,\n      boundary: [third_party_pure: [], third_party_impure: []]",
              global: false
            )

          {new_source, "added :boundary classification keyword to mix.exs"}

        Regex.match?(~r/deps:\s*deps\(\)/, source) ->
          new_source =
            Regex.replace(
              ~r/(deps:\s*deps\(\))(\s*,)?/,
              source,
              "\\1,\n      boundary: [third_party_pure: [], third_party_impure: []]",
              global: false
            )

          {new_source, "added :boundary classification keyword to mix.exs"}

        true ->
          {source, nil}
      end
    end
  end

  # ── boundary.exs ───────────────────────────────────────────────────────────

  @doc false
  @spec write_boundary_exs([action()], binary()) :: [action()]
  def write_boundary_exs(actions, path \\ "boundary.exs") do
    if File.exists?(path) do
      [{:noop, path, "exists"} | actions]
    else
      template = Path.join(:code.priv_dir(:crank) |> to_string(), "boundary.exs.template")

      case File.read(template) do
        {:ok, content} ->
          File.write!(path, content)
          [{:created, path, "starter file written from priv/boundary.exs.template"} | actions]

        {:error, _} ->
          [{:missing, template, "template not found in priv/"} | actions]
      end
    end
  end

  # ── .credo.exs ─────────────────────────────────────────────────────────────

  @doc false
  @spec wire_credo_exs([action()], binary()) :: [action()]
  def wire_credo_exs(actions, path \\ ".credo.exs") do
    if File.exists?(path) do
      source = File.read!(path)
      {new_source, change} = update_credo_source(source)

      if change do
        File.write!(path, new_source)
        [{:updated, path, change} | actions]
      else
        [{:noop, path, "already wired"} | actions]
      end
    else
      File.write!(path, starter_credo_config())
      [{:created, path, "starter .credo.exs with Crank.Check.TurnPurity wired"} | actions]
    end
  end

  @doc """
  Pure transformation for `.credo.exs`. Adds `Crank.Check.TurnPurity` to
  the `enabled:` checks list and wires the `requires:` reference if
  missing. Returns `{new_source, change_description | nil}`.
  """
  @spec update_credo_source(binary()) :: {binary(), binary() | nil}
  def update_credo_source(source) do
    s1 = ensure_credo_requires(source)
    s2 = ensure_credo_check(s1)

    if s2 == source do
      {source, nil}
    else
      {s2, "wired Crank.Check.TurnPurity into .credo.exs"}
    end
  end

  defp ensure_credo_requires(source) do
    cond do
      String.contains?(source, "lib/crank/check/turn_purity.ex") ->
        source

      Regex.match?(~r/requires:\s*\[\s*\]/s, source) ->
        Regex.replace(~r/requires:\s*\[\s*\]/s, source,
          ~s|requires: ["lib/crank/check/turn_purity.ex"]|,
          global: false
        )

      Regex.match?(~r/requires:\s*\[/, source) ->
        Regex.replace(~r/requires:\s*\[/, source,
          ~s|requires: ["lib/crank/check/turn_purity.ex", |,
          global: false
        )

      true ->
        source
    end
  end

  defp ensure_credo_check(source) do
    if String.contains?(source, "Crank.Check.TurnPurity") do
      source
    else
      Regex.replace(
        ~r/(checks:\s*%\{[^}]*?enabled:\s*\[)/s,
        source,
        "\\1\n          {Crank.Check.TurnPurity, []},",
        global: false
      )
    end
  end

  defp starter_credo_config do
    """
    %{
      configs: [
        %{
          name: "default",
          files: %{
            included: ["lib/", "test/"],
            excluded: [~r"/_build/", ~r"/deps/"]
          },
          plugins: [],
          requires: ["lib/crank/check/turn_purity.ex"],
          strict: false,
          parse_timeout: 5000,
          color: true,
          checks: %{
            enabled: [
              {Crank.Check.TurnPurity, []}
            ],
            disabled: []
          }
        }
      ]
    }
    """
  end

  # ── reporting ──────────────────────────────────────────────────────────────

  @typedoc "An action returned by each step in this task."
  @type action :: {:created | :updated | :noop | :missing, binary(), term()}

  defp report(actions) do
    Mix.shell().info("")
    Mix.shell().info(IO.ANSI.bright() <> "Crank wiring report" <> IO.ANSI.reset())
    Mix.shell().info("")

    for action <- Enum.reverse(actions) do
      Mix.shell().info(format_action(action))
    end

    Mix.shell().info("")
    Mix.shell().info(IO.ANSI.bright() <> "Recommended next steps" <> IO.ANSI.reset())
    Mix.shell().info("")
    Mix.shell().info("Add this CI step to your workflow:")
    Mix.shell().info(ci_snippet())
    Mix.shell().info("")
    Mix.shell().info("Add this section to your README:")
    Mix.shell().info(readme_snippet())
    Mix.shell().info("")
  end

  defp format_action({:created, path, info}), do: "  created  #{path}  (#{info})"
  defp format_action({:updated, path, changes}) when is_list(changes) do
    "  updated  #{path}\n    " <> Enum.join(changes, "\n    ")
  end

  defp format_action({:updated, path, info}), do: "  updated  #{path}  (#{info})"
  defp format_action({:noop, path, info}), do: "  unchanged  #{path}  (#{info})"
  defp format_action({:missing, path, info}), do: "  MISSING  #{path}  (#{info})"

  defp ci_snippet do
    """

        - name: Crank check
          run: mix crank.check
    """
  end

  defp readme_snippet do
    """

    ## Purity enforcement

    This project uses Crank's purity-enforcement layer. Domain modules tagged
    `use Crank` or `use Crank.Domain.Pure` are subject to:

      * Compile-time call-site checks (`Crank.Check.CompileTime`).
      * Compile-time topology checks (Boundary, via the `:crank` Mix compiler).
      * Runtime tracing in tests (`Crank.PropertyTest.assert_pure_turn/3`).

    Run `mix crank.check` to gate the full discipline. See the
    `Boundary setup` and `Suppressions` guides for configuration.
    """
  end
end
