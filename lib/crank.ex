defmodule Crank do
  @moduledoc """
  A behaviour for finite state machines as pure, testable data structures.

  ## What got lost

  In early Erlang, a state machine was mutually recursive functions. The state
  was which function the process was executing. The data available in each state
  was whatever that function received — nothing more. The call stack scoped your data.

  OTP formalized this with `gen_fsm`, then replaced it with `gen_statem`. Elixir
  adopted GenServer as its primary OTP abstraction, and GenServer has no concept
  of states — just one blob of data with a status atom. The function-per-state
  model didn't carry over. Two things got lost: data scoping (every handler can
  see every field) and the ability to use state machine logic without a process.

  ## What Crank recovers

  Crank separates the two concerns that OTP fused together: state machine logic
  and process lifecycle. You implement a single callback module with
  `handle_event/4` (and optionally `on_enter/3`), then use it in two ways:

    1. **Pure** — `Crank.new/2` and `Crank.crank/2` operate on a `%Crank.Machine{}`
       struct with no processes, no side effects, no telemetry. Perfect for
       tests, LiveView reducers, Oban workers, scripts.

    2. **Process** — `Crank.Server` wraps the same module in a `:gen_statem`
       process, executing effects, emitting telemetry, and integrating with
       supervision trees.

  For data scoping, Crank supports struct-per-state — each state is its own struct
  with exactly the fields that exist in that state. See `Crank.Examples.Submission`
  for the full pattern.

  ## Callback Signature

  `handle_event/4` takes four arguments matching `:gen_statem`'s
  `handle_event_function` callback mode exactly: event type, event content,
  state, and data.

    * `:internal` — programmatic events (pure cranks, `{:next_event, :internal, _}`)
    * `:cast` — async events via `Crank.Server.cast/2`
    * `{:call, from}` — sync events via `Crank.Server.call/3` (reply with `{:reply, from, reply}`)
    * `:info` — raw messages from linked processes
    * `:timeout` / `:state_timeout` / `{:timeout, name}` — timer events

  In pure code, the event type is always `:internal`. Match on `_` if you don't
  need to distinguish.

  ## Example

      defmodule MyApp.Door do
        use Crank

        @impl true
        def init(_opts), do: {:ok, :locked, %{}}

        @impl true
        def handle_event(_, :unlock, :locked, data) do
          {:next_state, :unlocked, data}
        end

        def handle_event(_, :lock, :unlocked, data) do
          {:next_state, :locked, data}
        end

        def handle_event(_, :open, :unlocked, data) do
          {:next_state, :opened, data}
        end

        def handle_event(_, :close, :opened, data) do
          {:next_state, :unlocked, data}
        end

        # Server-only: reply to synchronous calls
        def handle_event({:call, from}, :status, state, data) do
          {:keep_state, data, [{:reply, from, state}]}
        end
      end

      # Pure usage — no process needed
      machine =
        MyApp.Door
        |> Crank.new()
        |> Crank.crank(:unlock)
        |> Crank.crank(:open)

      machine.state
      #=> :opened

  """

  alias Crank.Machine

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc """
  The type of event being delivered as the first argument to `handle_event/4`.

  Matches `:gen_statem` event types exactly. In pure code (via `crank/2`),
  the event type is always `:internal`.
  """
  @type event_type ::
          :internal
          | :cast
          | {:call, from :: GenServer.from()}
          | :info
          | :timeout
          | :state_timeout
          | {:timeout, name :: term()}

  @typedoc "Result of `init/1`."
  @type init_result ::
          {:ok, state :: term(), data :: term()}
          | {:stop, reason :: term()}

  @typedoc """
  Result of `handle_event/4`.

  Named type so it can be referenced in specs and documentation.
  Mirrors `:gen_statem` return values exactly.
  """
  @type handle_event_result ::
          {:next_state, new_state :: term(), new_data :: term()}
          | {:next_state, new_state :: term(), new_data :: term(),
             actions :: [Machine.action()]}
          | {:keep_state, new_data :: term()}
          | {:keep_state, new_data :: term(), actions :: [Machine.action()]}
          | :keep_state_and_data
          | {:keep_state_and_data, actions :: [Machine.action()]}
          | {:stop, reason :: term(), new_data :: term()}

  @typedoc "Result of `on_enter/3`."
  @type on_enter_result ::
          {:keep_state, new_data :: term()}
          | {:keep_state, new_data :: term(), actions :: [Machine.action()]}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Initialise the machine. Return the starting state and data.
  """
  @callback init(args :: term()) :: init_result()

  @doc """
  Handle an event in the current state.

  Arguments mirror `:gen_statem` exactly:

    1. `event_type` — `:internal`, `:cast`, `{:call, from}`, `:info`, `:timeout`,
       `:state_timeout`, or `{:timeout, name}`
    2. `event_content` — the event payload
    3. `state` — the current state
    4. `data` ��� the machine's accumulated data

  In pure usage (`Crank.crank/2`), event_type is always `:internal`.
  Use `_` to ignore it when the clause works in both pure and process contexts.
  """
  @callback handle_event(
              event_type :: event_type(),
              event_content :: term(),
              state :: term(),
              data :: term()
            ) :: handle_event_result()

  @doc """
  Called after entering a new state. Optional.

  Receives the previous state, the new state, and the current data.
  Only invoked on actual state changes (when `handle_event/4` returns
  `{:next_state, ...}`).
  """
  @callback on_enter(
              old_state :: term(),
              new_state :: term(),
              data :: term()
            ) :: on_enter_result()

  @optional_callbacks [on_enter: 3]

  # ---------------------------------------------------------------------------
  # __using__ macro
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour Crank

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Crank.Server, :start_link, [__MODULE__, args, []]},
          restart: unquote(Keyword.get(opts, :restart, :permanent)),
          shutdown: unquote(Keyword.get(opts, :shutdown, 5000))
        }
      end

      defoverridable child_spec: 1
    end
  end

  # ---------------------------------------------------------------------------
  # Public API — Pure Core
  # ---------------------------------------------------------------------------

  @doc """
  Create a new machine from a callback module.

  Calls `module.init(args)` and returns a `%Crank.Machine{}` struct.
  Raises on `{:stop, reason}` from init, or if the module doesn't
  implement the `Crank` behaviour.

  ## Examples

      iex> machine = Crank.new(Crank.Examples.Door)
      iex> machine.state
      :locked
      iex> machine.effects
      []
      iex> machine.status
      :running

      iex> machine = Crank.new(Crank.Examples.Turnstile)
      iex> machine.data
      %{coins: 0, passes: 0}

  """
  @spec new(module(), term()) :: Machine.t()
  def new(module, args \\ []) do
    validate_module!(module)

    case module.init(args) do
      {:ok, state, data} ->
        %Machine{module: module, state: state, data: data}

      {:stop, reason} ->
        raise ArgumentError,
              "#{inspect(module)}.init/1 returned {:stop, #{inspect(reason)}}"
    end
  end

  @doc """
  Crank the machine with a domain event, producing a new machine.

  The event type is `:internal` — this is a pure, programmatic crank.
  Returns the updated `%Crank.Machine{}`. If the callback returns
  `{:stop, reason, data}`, the machine's status becomes `{:stopped, reason}`.

  Each call replaces `effects` with the effects from this crank
  only — effects do not accumulate across pipeline stages.

  Raises `Crank.StoppedError` if the machine has already stopped.

  ## Examples

      iex> machine = Crank.new(Crank.Examples.Door) |> Crank.crank(:unlock)
      iex> machine.state
      :unlocked

      iex> machine = Crank.new(Crank.Examples.Turnstile) |> Crank.crank(:coin) |> Crank.crank(:push)
      iex> machine.state
      :locked
      iex> machine.data
      %{coins: 1, passes: 1}

  Pipeline style:

      iex> machine =
      ...>   Crank.Examples.Door
      ...>   |> Crank.new()
      ...>   |> Crank.crank(:unlock)
      ...>   |> Crank.crank(:open)
      iex> machine.state
      :opened

  """
  @spec crank(Machine.t(), event_content :: term()) :: Machine.t()
  def crank(%Machine{status: {:stopped, reason}} = machine, event) do
    raise Crank.StoppedError,
          module: machine.module,
          state: machine.state,
          event: event,
          reason: reason
  end

  def crank(%Machine{} = machine, event) do
    result = machine.module.handle_event(:internal, event, machine.state, machine.data)
    apply_result(machine, result)
  end

  @doc """
  Like `crank/2`, but raises on `{:stop, ...}` results.

  Useful in tests and scripts where a stop is unexpected.

  ## Examples

      iex> Crank.new(Crank.Examples.Door) |> Crank.crank!(:unlock) |> Map.get(:state)
      :unlocked

  """
  @spec crank!(Machine.t(), event_content :: term()) :: Machine.t()
  def crank!(%Machine{} = machine, event) do
    case crank(machine, event) do
      %Machine{status: {:stopped, reason}} = stopped ->
        raise Crank.StoppedError,
              module: stopped.module,
              state: stopped.state,
              event: event,
              reason: reason

      machine ->
        machine
    end
  end

  # ---------------------------------------------------------------------------
  # Result application (pure)
  # ---------------------------------------------------------------------------

  @spec apply_result(Machine.t(), handle_event_result() | term()) :: Machine.t()
  defp apply_result(machine, {:next_state, new_state, new_data}) do
    machine
    |> move_to(new_state, new_data, [])
    |> check_enter_hook(machine.state)
  end

  defp apply_result(machine, {:next_state, new_state, new_data, actions}) do
    machine
    |> move_to(new_state, new_data, actions)
    |> check_enter_hook(machine.state)
  end

  defp apply_result(machine, {:keep_state, new_data}) do
    %{machine | data: new_data, effects: []}
  end

  defp apply_result(machine, {:keep_state, new_data, actions}) do
    %{machine | data: new_data, effects: List.wrap(actions)}
  end

  defp apply_result(machine, :keep_state_and_data) do
    %{machine | effects: []}
  end

  defp apply_result(machine, {:keep_state_and_data, actions}) do
    %{machine | effects: List.wrap(actions)}
  end

  defp apply_result(machine, {:stop, reason, new_data}) do
    %{machine | data: new_data, status: {:stopped, reason}, effects: []}
  end

  defp apply_result(%Machine{module: module, state: state}, invalid) do
    raise ArgumentError,
          "#{inspect(module)}.handle_event/4 in state #{inspect(state)} " <>
            "returned invalid result: #{inspect(invalid)}"
  end

  @spec move_to(Machine.t(), term(), term(), [Machine.action()]) :: Machine.t()
  defp move_to(machine, new_state, new_data, actions) do
    %{machine | state: new_state, data: new_data, effects: List.wrap(actions)}
  end

  @spec check_enter_hook(Machine.t(), old_state :: term()) :: Machine.t()
  defp check_enter_hook(
         %Machine{module: module, state: new_state, data: data} = machine,
         old_state
       ) do
    if function_exported?(module, :on_enter, 3) do
      case module.on_enter(old_state, new_state, data) do
        {:keep_state, new_data} ->
          %{machine | data: new_data}

        {:keep_state, new_data, enter_actions} ->
          %{machine |
            data: new_data,
            effects: machine.effects ++ List.wrap(enter_actions)}

        invalid ->
          raise ArgumentError,
                "#{inspect(module)}.on_enter/3 (#{inspect(old_state)} → #{inspect(new_state)}) " <>
                  "returned invalid result: #{inspect(invalid)}"
      end
    else
      machine
    end
  end

  @spec validate_module!(module()) :: :ok
  defp validate_module!(module) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :handle_event, 4) do
      raise ArgumentError,
            "#{inspect(module)} does not implement the Crank behaviour " <>
              "(missing handle_event/4)"
    end

    :ok
  end
end
