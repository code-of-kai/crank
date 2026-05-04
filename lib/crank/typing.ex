defmodule Crank.Typing do
  @moduledoc """
  Generators and compile-time checks for the `use Crank, states: ..., memory: ...`
  macro form (Phase 1.7 of `purity-enforcement.md`).

  Two pieces of work happen here:

    * AST generators that produce `@type state/0` (closed union of the listed
      state structs) and `@type memory/0` (alias for the named memory
      struct's `t/0`) typespecs from the `:states` and `:memory` options
      passed to `use Crank`. Generation is opt-in — without these options,
      no typespecs are injected and the existing manual-typespec path
      continues to work unchanged.

    * A `@before_compile` callback that walks `turn/3` clause bodies and
      verifies every literal `{:next, %SomeState{}, _}` return shape uses
      a state struct from the declared union. Non-literal returns (a
      variable, a helper-function result) are skipped — at macro time we
      can't see through them, and runtime tracing is the right enforcement
      mechanism for those cases.

  The `Crank.Check.CompileTime` `@before_compile` already handles the
  call-site purity walk; this module's `@before_compile` is registered
  separately so the two concerns stay decoupled.

  Typespec verification in tests uses the public `Code.Typespec.fetch_types/1`
  API (and *not* `Module.spec_to_callback/2`, which is not the right API
  for this purpose).
  """

  @doc """
  Builds the AST for `@type state :: ...` from a list of state struct
  modules. Returns `nil` if `states` is empty or nil — caller threads it
  through `quote do unquote(...) end` so a `nil` collapses to a no-op.
  """
  @spec build_state_type([module()] | nil) :: Macro.t() | nil
  def build_state_type(nil), do: nil
  def build_state_type([]), do: nil

  def build_state_type([_ | _] = states) do
    type_union =
      states
      |> Enum.map(fn state ->
        quote do
          unquote(state).t()
        end
      end)
      |> Enum.reduce(fn left, right ->
        quote do
          unquote(right) | unquote(left)
        end
      end)

    quote do
      @type state :: unquote(type_union)
    end
  end

  @doc """
  Builds the AST for `@type memory :: SomeMemoryStruct.t()` from a memory
  struct module. Returns `nil` if `memory` is nil.
  """
  @spec build_memory_type(module() | nil) :: Macro.t() | nil
  def build_memory_type(nil), do: nil

  def build_memory_type(memory) when is_atom(memory) do
    quote do
      @type memory :: unquote(memory).t()
    end
  end

  @doc """
  Builds the AST that registers the state-union for the `@before_compile`
  hook to consult later. Stored as a module attribute keyed at compile
  time — a list of state struct modules.
  """
  @spec build_state_union_attribute([module()] | nil) :: Macro.t() | nil
  def build_state_union_attribute(nil), do: nil
  def build_state_union_attribute([]), do: nil

  def build_state_union_attribute(states) when is_list(states) do
    quote do
      Module.put_attribute(__MODULE__, :__crank_state_union__, unquote(states))
    end
  end

  @doc """
  Builds the AST that registers the memory module for the `@after_compile`
  CRANK_TYPE_002 validator (forbidden `function/0` or `module/0` types).
  """
  @spec build_memory_module_attribute(module() | nil) :: Macro.t() | nil
  def build_memory_module_attribute(nil), do: nil

  def build_memory_module_attribute(memory) when is_atom(memory) do
    quote do
      Module.put_attribute(__MODULE__, :__crank_memory_module__, unquote(memory))
      @after_compile {Crank.Typing, :__after_compile_memory_check__}
    end
  end

  @doc """
  `@after_compile` callback that validates the configured memory module's
  typespec for forbidden `function/0` and `module/0` types (CRANK_TYPE_002).

  Best-effort: if the memory module's typespec can't be fetched (typically
  because it lives in the same project and BEAM bytecode isn't yet on disk
  when this hook fires), the check is skipped silently — the same check
  runs again later via `mix crank.check`. If the typespec IS available and
  contains a forbidden type, this raises a `CompileError`.
  """
  def __after_compile_memory_check__(env, _bytecode) do
    case read_memory_module_attr(env.module) do
      nil -> :ok
      memory_module -> check_memory_module(memory_module, env)
    end
  end

  defp check_memory_module(memory_module, env) do
    case fetch_memory_types(memory_module) do
      {:ok, types} -> raise_if_forbidden(memory_module, types, env)
      # Memory module typespec not yet available (compilation order); the
      # check runs again later via `mix crank.check`. Forbidden function/
      # module types can't slip past the second-pass check.
      :error -> :ok
    end
  end

  defp raise_if_forbidden(memory_module, types, env) do
    case find_forbidden_types(types) do
      [] ->
        :ok

      [_ | _] = forbidden ->
        raise Crank.Errors.to_compile_error(build_forbidden_violation(memory_module, forbidden, env))
    end
  end

  defp build_forbidden_violation(memory_module, forbidden, env) do
    Crank.Errors.build("CRANK_TYPE_002",
      location: %{file: env.file, line: 0},
      context:
        "memory struct #{inspect(memory_module)} declares forbidden type(s) #{inspect(forbidden)} in its typespec — function/0 and module/0 are not allowed in memory because they make memory unserializable and break replayability.",
      metadata: %{memory_module: memory_module, forbidden_types: forbidden}
    )
  end

  defp fetch_memory_types(memory_module) do
    case Code.Typespec.fetch_types(memory_module) do
      {:ok, types} -> {:ok, types}
      :error -> :error
    end
  end

  # Read the `:__crank_memory_module__` module attribute, falling back to
  # the persisted-attribute lookup when the module is already closed
  # (the @after_compile callback path expects the module still being
  # compiled, but defensively the test path may invoke it post-compile).
  defp read_memory_module_attr(module) do
    Module.get_attribute(module, :__crank_memory_module__)
  rescue
    ArgumentError -> nil
  end

  # Walks a list of typespec entries returned by `Code.Typespec.fetch_types/1`
  # looking for occurrences of the `function/0` or `module/0` predefined types.
  # Returns a list of `:function | :module` atoms found (deduplicated).
  defp find_forbidden_types(types) do
    types
    |> Enum.flat_map(fn {_kind, type_spec} -> collect_forbidden(type_spec) end)
    |> Enum.uniq()
  end

  defp collect_forbidden({_name, type_ast, _args}), do: collect_forbidden_from_ast(type_ast)

  defp collect_forbidden_from_ast({:type, _, :fun, _}), do: [:function]
  defp collect_forbidden_from_ast({:type, _, :module, []}), do: [:module]

  defp collect_forbidden_from_ast({:type, _, _name, args}) when is_list(args) do
    Enum.flat_map(args, &collect_forbidden_from_ast/1)
  end

  defp collect_forbidden_from_ast({:remote_type, _, [_mod, _name, args]}) do
    Enum.flat_map(args, &collect_forbidden_from_ast/1)
  end

  defp collect_forbidden_from_ast({:user_type, _, _name, args}) do
    Enum.flat_map(args, &collect_forbidden_from_ast/1)
  end

  defp collect_forbidden_from_ast({:ann_type, _, [_var, type]}), do: collect_forbidden_from_ast(type)

  defp collect_forbidden_from_ast(_), do: []

  @doc """
  `@before_compile` callback that validates `turn/3` returns against the
  declared state union.

  Walks every captured `turn/3` clause body looking for return tuples of
  the form `{:next, %SomeState{...}, _}` and `{:stop, _, _}` etc. For
  `{:next, ...}`, asserts the state is in the declared union; if not,
  raises a CompileError carrying `CRANK_TYPE_003`.
  """
  defmacro __before_compile__(env) do
    state_union = Module.get_attribute(env.module, :__crank_state_union__)

    if is_list(state_union) and state_union != [] do
      turn_bodies = Module.get_attribute(env.module, :__crank_turn_bodies__) || []

      violations = check_turn_returns(turn_bodies, state_union, env)

      case violations do
        [] ->
          :ok

        [first | _] ->
          raise Crank.Errors.to_compile_error(first)
      end
    end

    quote do: :ok
  end

  defp check_turn_returns(bodies, state_union, env) do
    bodies
    |> Enum.flat_map(fn body -> walk_returns(body, state_union, env) end)
  end

  # Walk an AST looking for `{:next, %Module{...}, _}` return shapes.
  # Returns a list of violations.
  defp walk_returns(ast, state_union, env) do
    {_, violations} =
      Macro.prewalk(ast, [], &check_node(&1, &2, state_union, env))

    Enum.reverse(violations)
  end

  defp check_node(node, acc, state_union, env) do
    case extract_next_state(node) do
      {:literal_struct, module, line} ->
        validate_state(node, acc, module, line, state_union, env)

      _ ->
        {node, acc}
    end
  end

  defp validate_state(node, acc, module, line, state_union, env) do
    if module in state_union do
      {node, acc}
    else
      {node, [build_unknown_state_violation(module, line, state_union, env) | acc]}
    end
  end

  defp build_unknown_state_violation(module, line, state_union, env) do
    Crank.Errors.build("CRANK_TYPE_003",
      location: %{file: env.file, line: line},
      context:
        "turn/3 returns state #{inspect(module)}, which is not in the declared :states union (#{inspect(state_union)})",
      metadata: %{returned_state: module, declared_states: state_union}
    )
  end

  # Pattern: {:next, %Module{...}, memory}
  defp extract_next_state({:{}, meta, [:next, struct_ast, _memory]}) do
    case struct_ast do
      {:%, _, [{:__aliases__, _, parts}, {:%{}, _, _}]} ->
        {:literal_struct, Module.concat(parts), Keyword.get(meta, :line, 0)}

      {:%, _, [aliased, {:%{}, _, _}]} when is_atom(aliased) ->
        {:literal_struct, aliased, Keyword.get(meta, :line, 0)}

      _ ->
        :unknown
    end
  end

  # 3-tuple syntactic sugar: {:next, state, memory} as plain {:next, ...}
  # Elixir parses this as {{:next, _, _}} with no :{} wrapper for fixed-size tuples
  defp extract_next_state({:next, struct_ast, _memory}) do
    case struct_ast do
      {:%, _, [{:__aliases__, _, parts}, {:%{}, _, _}]} ->
        {:literal_struct, Module.concat(parts), 0}

      {:%, _, [aliased, {:%{}, _, _}]} when is_atom(aliased) ->
        {:literal_struct, aliased, 0}

      _ ->
        :unknown
    end
  end

  # Three-element tuples are wrapped in {:{}, _, list}; two-element are bare.
  # We're after three-element tuples starting with :next.
  defp extract_next_state(_), do: :unknown
end
