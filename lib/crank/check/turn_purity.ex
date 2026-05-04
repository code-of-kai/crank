defmodule Crank.Check.TurnPurity do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      `turn/3` must be a pure function. Side effects inside `turn/3` break
      the hexagonal architecture boundary: they require infrastructure to run
      tests, and they make the domain model depend on adapters.

      Move side effects to adapters attached via telemetry, or declare them
      as `wants/2` entries for `Crank.Server` to execute.

      See the Hexagonal Architecture guide for the boundary contract, and the
      Transitions and guards guide for what `turn/3` clauses should contain.
      """,
      params: [
        impure_modules: """
        Module name prefixes considered impure. Any call whose receiver starts
        with one of these prefixes inside a `turn/3` body raises an issue.
        Defaults to common infrastructure namespaces; extend in `.credo.exs`.
        """
      ]
    ],
    param_defaults: [
      impure_modules: ~w(
        Repo
        Ecto
        HTTPoison
        Tesla
        Finch
        Req
        Swoosh
        Bamboo
        Mailer
        Oban
      )
    ]

  alias Credo.Code
  alias Credo.IssueMeta

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    impure_prefixes = Params.get(params, :impure_modules, __MODULE__)
    Code.prewalk(source_file, &traverse(&1, &2, impure_prefixes, source_file, params))
  end

  # Only inspect defmodule blocks that use Crank.
  defp traverse({:defmodule, _, [_name, [do: body]]} = ast, issues, prefixes, source_file, params) do
    if uses_crank?(body) do
      new_issues = collect_turn_issues(body, prefixes, source_file, params)
      {ast, issues ++ new_issues}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _prefixes, _source_file, _params), do: {ast, issues}

  # Check whether the module body contains `use Crank`.
  defp uses_crank?({:__block__, _, stmts}), do: Enum.any?(stmts, &uses_crank?/1)
  defp uses_crank?({:use, _, [{:__aliases__, _, [:Crank]} | _]}), do: true
  defp uses_crank?(_), do: false

  # Walk all `def turn(_, _, _)` clauses and scan their bodies.
  defp collect_turn_issues({:__block__, _, stmts}, prefixes, source_file, params) do
    Enum.flat_map(stmts, &collect_turn_issues(&1, prefixes, source_file, params))
  end

  defp collect_turn_issues({:def, _meta, [{:turn, _, args}, [do: body]]}, prefixes, source_file, params)
       when length(args) == 3 do
    find_impure_calls(body, prefixes, source_file, params)
  end

  defp collect_turn_issues(_, _prefixes, _source_file, _params), do: []

  # Recursively scan an AST node for calls to impure modules.
  defp find_impure_calls(ast, prefixes, source_file, params) do
    {_, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case impure_call(node, prefixes) do
          {module, fun, line} ->
            issue =
              format_issue(
                IssueMeta.for(source_file, params),
                message: "Impure call `#{module}.#{fun}` inside `turn/3`. Move side effects to a telemetry adapter or declare them in `wants/2`.",
                line_no: line
              )

            {node, [issue | acc]}

          nil ->
            {node, acc}
        end
      end)

    issues
  end

  # Match a remote call whose receiver module starts with a known-impure prefix.
  defp impure_call({{:., meta, [{:__aliases__, _, mod_parts}, fun]}, _, _args}, prefixes) do
    module = Enum.join(mod_parts, ".")

    if Enum.any?(prefixes, &String.starts_with?(module, &1)) do
      {module, fun, meta[:line]}
    end
  end

  defp impure_call(_ast, _prefixes), do: nil
end
