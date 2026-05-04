defmodule Crank.Turns do
  @moduledoc """
  A descriptor for advancing multiple `Crank` machines as one unit of work.

  `%Crank.Turns{}` accumulates named steps as data — each step is a turn
  against a named machine. The descriptor is built, optionally composed with
  other descriptors, then executed at one boundary (`apply/1` for pure mode,
  `Crank.Server.Turns.apply/1` for process mode — same descriptor, two
  executors).

  This is the analogue of `Ecto.Multi` for state machines. One caller intent
  fans out into multiple state advances; `Turns` is the reified unit of that
  intent.

  ## Execution semantics: best-effort sequential

  Steps run in the order they were added. Each step sees prior successful
  results by name; its machine and/or event can be computed from them.

  On `{:stop, reason, memory}` from any step, execution aborts. No compensation,
  no rollback, no atomicity. The caller receives:

  - `{:ok, results}` where `results` is a map of `name => %Crank{}` if every
    step succeeded.
  - `{:error, name, reason, advanced_so_far}` where `name` identifies the
    failing step, `reason` is its stop reason (or `{:stopped_input, reason}`
    if the step's input machine was already stopped), and `advanced_so_far`
    is a map containing every machine that had a turn applied — including
    the stopped one in the common case.

  The mental model is the implementation. Reading top-to-bottom tells you
  exactly what physically happened.

  ## Example

      order    = Crank.new(MyApp.Order)
      payment  = Crank.new(MyApp.Payment)
      shipping = Crank.new(MyApp.Shipping)

      Crank.Turns.new()
      |> Crank.Turns.turn(:order, order, :submit)
      |> Crank.Turns.turn(:payment, payment,
           fn %{order: o} -> {:charge, o.memory.total} end)
      |> Crank.Turns.turn(:shipping, shipping,
           fn %{payment: p} -> {:queue, p.memory.txn_id} end)
      |> Crank.Turns.apply()
      #=> {:ok, %{order: %Crank{...}, payment: %Crank{...}, shipping: %Crank{...}}}

  ## Dependencies

  Either the machine OR the event argument may be a function of arity 1
  taking the prior results map and returning the resolved value. Literal
  `%Crank{}` structs and literal event terms are used as-is.

      Crank.Turns.new()
      |> Crank.Turns.turn(:charged, payment, :charge)
      |> Crank.Turns.turn(:notified,
           fn %{charged: c} -> notifier_machine(c.memory.user) end,
           fn %{charged: c} -> {:send_receipt, c.memory.txn_id} end)

  Any term passed as the `event` argument that is NOT an arity-1 function is
  treated as a literal event. If you need to pass a literal function as an
  event, wrap it (e.g., `{:call, &handler/1}`).

  ## Names must be unique

  Each step's `name` must be unique within the descriptor. Adding a duplicate
  name via `turn/4` raises `ArgumentError` at build time.

  ## Not a saga

  `Turns` is synchronous and bounded. It is the unit of a *command* — one
  caller intent that advances multiple machines now. A *saga* (a workflow
  unfolding over real time with compensation) is a different tool; in Crank,
  sagas are their own machine modules.
  """

  alias Crank.Turns

  @typedoc "A step's unique identifier within the descriptor."
  @type name :: term()

  @typedoc "The prior results available to dependency functions."
  @type results :: %{optional(name()) => Crank.t()}

  @typedoc "A machine to advance, or a function producing one from prior results."
  @type machine_resolver :: Crank.t() | (results() -> Crank.t())

  @typedoc "An event to apply, or a function producing one from prior results."
  @type event_resolver :: term() | (results() -> term())

  @typedoc "One ordered step. Opaque in intent; exposed for `to_list/1`."
  @type step :: {name(), machine_resolver(), event_resolver()}

  @typedoc "The descriptor struct."
  @type t :: %__MODULE__{steps: [step()]}

  @typedoc "What `apply/1` returns."
  @type apply_result ::
          {:ok, results()}
          | {:error, name(), reason :: term(), results()}

  defstruct steps: []

  # ──────────────────────────────────────────────────────────────────────────
  # Builder
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Returns an empty descriptor.

      iex> Crank.Turns.new()
      %Crank.Turns{steps: []}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends a step to the descriptor.

  `machine` is what an executor will turn. The value's shape depends on
  which executor interprets the descriptor:

  - `Crank.Turns.apply/1` (pure mode) expects a `%Crank{}` struct.
  - `Crank.Server.Turns.apply/1` (process mode) expects a pid, registered
    name, or `{name, node}` tuple of a running `Crank.Server`.

  In either mode, if `machine` is a function of arity 1, it is called at
  apply time with the prior-results map; the return value is the machine.
  Otherwise `machine` is used as a literal.

  `event` is either a literal term or an arity-1 function resolving to one.
  If you need to pass a *literal* function as an event (rather than have it
  interpreted as a resolver), wrap it — e.g., `{:call, &handler/1}` — and
  have the machine's `c:Crank.turn/3` match the wrapped shape.

  Build-time validation rejects functions whose arity is not 1. Literal
  values of the wrong shape (e.g., a non-`%Crank{}` map in pure mode) are
  caught at apply time by the executor.

  Raises `ArgumentError` if `name` is already present in the descriptor,
  or if `machine` is a function with arity other than 1.

      iex> machine = Crank.new(Crank.Examples.Door)
      iex> turns = Crank.Turns.new() |> Crank.Turns.turn(:front, machine, :unlock)
      iex> length(turns.steps)
      1
  """
  @spec turn(t(), name(), machine_resolver(), event_resolver()) :: t()
  def turn(%__MODULE__{} = turns, name, machine, event) do
    validate_unique_name!(turns, name)
    validate_machine!(machine)
    %__MODULE__{steps: turns.steps ++ [{name, machine, event}]}
  end

  @doc """
  Concatenates two descriptors in order. Raises `ArgumentError` if the two
  share any step names.

      iex> a = Crank.Turns.new() |> Crank.Turns.turn(:a, Crank.new(Crank.Examples.Door), :unlock)
      iex> b = Crank.Turns.new() |> Crank.Turns.turn(:b, Crank.new(Crank.Examples.Door), :unlock)
      iex> length(Crank.Turns.append(a, b).steps)
      2
  """
  @spec append(t(), t()) :: t()
  def append(%__MODULE__{} = first, %__MODULE__{} = second) do
    first_names = names(first)
    second_names = names(second)
    overlap = for n <- first_names, n in second_names, do: n

    if overlap != [] do
      raise ArgumentError,
            "Crank.Turns.append/2: step names appear in both descriptors: " <>
              "#{inspect(overlap)}"
    end

    %__MODULE__{steps: first.steps ++ second.steps}
  end

  @doc """
  Returns the descriptor's steps as a list in execution order.

      iex> machine = Crank.new(Crank.Examples.Door)
      iex> Crank.Turns.new()
      ...> |> Crank.Turns.turn(:a, machine, :unlock)
      ...> |> Crank.Turns.to_list()
      ...> |> length()
      1
  """
  @spec to_list(t()) :: [step()]
  def to_list(%__MODULE__{steps: steps}), do: steps

  @doc """
  Returns the list of step names in execution order.

      iex> machine = Crank.new(Crank.Examples.Door)
      iex> Crank.Turns.new()
      ...> |> Crank.Turns.turn(:a, machine, :unlock)
      ...> |> Crank.Turns.turn(:b, machine, :unlock)
      ...> |> Crank.Turns.names()
      [:a, :b]
  """
  @spec names(t()) :: [name()]
  def names(%__MODULE__{steps: steps}) do
    Enum.map(steps, fn {name, _m, _e} -> name end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pure executor
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Executes the descriptor against `%Crank{}` structs.

  Steps run in order. Each step sees prior successful results in a map keyed
  by name. Returns `{:ok, results}` on full success, or
  `{:error, name, reason, advanced_so_far}` on the first stop.

  When a step stops a machine, the stopped `%Crank{}` (with `engine: {:off, reason}`)
  IS included in `advanced_so_far` under its name — the turn physically
  happened. When a step's input machine was already stopped, no turn runs;
  the reason is wrapped as `{:stopped_input, original_reason}` and
  `advanced_so_far` contains only the prior successes.

  User-raised exceptions from `c:Crank.turn/3` or from dependency functions
  propagate; they are not caught. Only `Crank.StoppedError` from a
  pre-stopped input machine is caught and reported.

  ## Example

      order   = Crank.new(MyApp.Order)
      payment = Crank.new(MyApp.Payment)

      {:ok, %{order: advanced_order, payment: advanced_payment}} =
        Crank.Turns.new()
        |> Crank.Turns.turn(:order, order, :submit)
        |> Crank.Turns.turn(:payment, payment,
             fn %{order: o} -> {:charge, o.memory.total} end)
        |> Crank.Turns.apply()
  """
  @spec apply(t()) :: apply_result()
  def apply(%__MODULE__{steps: steps}) do
    apply_steps(steps, %{})
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────────────────────

  defp apply_steps([], results), do: {:ok, results}

  defp apply_steps([{name, machine_res, event_res} | rest], results) do
    machine = resolve(machine_res, results)
    validate_resolved_machine!(machine, name)
    event = resolve(event_res, results)

    try do
      case Crank.turn(machine, event) do
        %Crank{engine: {:off, reason}} = stopped ->
          {:error, name, reason, Map.put(results, name, stopped)}

        %Crank{} = advanced ->
          apply_steps(rest, Map.put(results, name, advanced))
      end
    rescue
      e in Crank.StoppedError ->
        {:error, name, {:stopped_input, e.reason}, results}
    end
  end

  # Arity-1 function → call with results; anything else → literal value.
  defp resolve(fun, results) when is_function(fun, 1), do: fun.(results)
  defp resolve(value, _results), do: value

  # Apply-time check: catches both non-%Crank{} literals and function resolvers
  # that returned non-%Crank{}. The descriptor accepts any value at build time
  # (to allow pids / names for the process-mode executor), so pure-mode
  # validation lives here.
  defp validate_resolved_machine!(%Crank{}, _name), do: :ok

  defp validate_resolved_machine!(other, name) do
    raise ArgumentError,
          "Crank.Turns.apply/1: step #{inspect(name)} resolved to " <>
            "#{inspect(other)} — expected %Crank{}"
  end

  defp validate_unique_name!(%Turns{} = turns, name) do
    if name in names(turns) do
      raise ArgumentError,
            "Crank.Turns.turn/4: duplicate step name #{inspect(name)}"
    end
  end

  # Build-time: only rejects functions with wrong arity. Anything else (including
  # non-%Crank{} literals and pids) is accepted because different executors
  # interpret the descriptor differently. Value-shape validation lives in the
  # executor's apply/1.
  defp validate_machine!(fun) when is_function(fun, 1), do: :ok

  defp validate_machine!(fun) when is_function(fun) do
    {:arity, arity} = :erlang.fun_info(fun, :arity)

    raise ArgumentError,
          "Crank.Turns.turn/4: machine function must have arity 1, got arity #{arity}"
  end

  defp validate_machine!(_other), do: :ok
end
