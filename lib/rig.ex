defmodule Rig do
  @moduledoc """
  A behaviour for finite state machines as pure, testable data structures.

  Rig separates state machine logic from process concerns. You implement
  a single callback module with `handle_event/4` (and optionally `on_enter/3`),
  then use it in two ways:

    1. **Pure** — `Rig.new/2` and `Rig.step/2` operate on a `%Rig.Machine{}`
       struct with no processes, no side effects, no telemetry. Perfect for
       tests, LiveView reducers, Oban workers, scripts.

    2. **Process** — `Rig.Server` wraps the same module in a `:gen_statem`
       process, executing effects, emitting telemetry, and integrating with
       supervision trees.

  ## Callback Signature

  `handle_event/4` takes four arguments: state, event type, event content, and data.
  The event type follows `:gen_statem` exactly:

    * `:internal` — programmatic events (pure steps, `{:next_event, :internal, _}`)
    * `:cast` — async events via `Rig.Server.cast/2`
    * `{:call, from}` — sync events via `Rig.Server.call/3` (reply with `{:reply, from, reply}`)
    * `:info` — raw messages from linked processes
    * `:timeout` / `:state_timeout` / `{:timeout, name}` — timer events

  In pure code, the event type is always `:internal`. Match on `_` if you don't
  need to distinguish.

  ## Example

      defmodule MyApp.Door do
        use Rig

        @impl true
        def init(_opts), do: {:ok, :locked, %{}}

        @impl true
        def handle_event(:locked, _, :unlock, data) do
          {:next_state, :unlocked, data}
        end

        def handle_event(:unlocked, _, :lock, data) do
          {:next_state, :locked, data}
        end

        def handle_event(:unlocked, _, :open, data) do
          {:next_state, :opened, data}
        end

        def handle_event(:opened, _, :close, data) do
          {:next_state, :unlocked, data}
        end

        # Runner-only: reply to synchronous calls
        def handle_event(state, {:call, from}, :status, data) do
          {:keep_state, data, [{:reply, from, state}]}
        end
      end

      # Pure usage — no process needed
      machine =
        MyApp.Door
        |> Rig.new()
        |> Rig.step(:unlock)
        |> Rig.step(:open)

      machine.state
      #=> :opened

  """

  alias Rig.Machine

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type event_type ::
          :internal
          | :cast
          | {:call, GenServer.from()}
          | :info
          | :timeout
          | :state_timeout
          | {:timeout, term()}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Initialise the machine. Return the starting state and data.
  """
  @callback init(args :: term()) ::
              {:ok, state :: term(), data :: term()}
              | {:stop, reason :: term()}

  @doc """
  Handle an event in the current state.

  Arguments mirror `:gen_statem` exactly:

    1. `state` — the current state (primary pattern match discriminator)
    2. `event_type` — `:internal`, `:cast`, `{:call, from}`, `:info`, `:timeout`,
       `:state_timeout`, or `{:timeout, name}`
    3. `event_content` — the event payload
    4. `data` — the machine's accumulated data

  In pure usage (`Rig.step/2`), event_type is always `:internal`.
  Use `_` to ignore it when the clause works in both pure and process contexts.
  """
  @callback handle_event(
              state :: term(),
              event_type :: event_type(),
              event_content :: term(),
              data :: term()
            ) ::
              {:next_state, new_state :: term(), new_data :: term()}
              | {:next_state, new_state :: term(), new_data :: term(),
                 actions :: [Machine.action()]}
              | {:keep_state, new_data :: term()}
              | {:keep_state, new_data :: term(), actions :: [Machine.action()]}
              | :keep_state_and_data
              | {:keep_state_and_data, actions :: [Machine.action()]}
              | {:stop, reason :: term(), new_data :: term()}

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
            ) ::
              {:keep_state, new_data :: term()}
              | {:keep_state, new_data :: term(), actions :: [Machine.action()]}

  @optional_callbacks [on_enter: 3]

  # ---------------------------------------------------------------------------
  # __using__ macro
  # ---------------------------------------------------------------------------

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour Rig

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Rig.Server, :start_link, [__MODULE__, args, []]},
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

  Calls `module.init(args)` and returns a `%Rig.Machine{}` struct.
  Raises on `{:stop, reason}` from init, or if the module doesn't
  implement the `Rig` behaviour.

  ## Examples

      machine = Rig.new(MyApp.Door)
      machine = Rig.new(MyApp.Order, order_id: 123)

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
  Step the machine forward by applying a domain event.

  The event type is `:internal` — this is a pure, programmatic step.
  Returns the updated `%Rig.Machine{}`. If the callback returns
  `{:stop, reason, data}`, the machine's status becomes `{:stopped, reason}`.

  Each call replaces `effects` with the effects from this step
  only — effects do not accumulate across pipeline stages.

  Raises `Rig.StoppedError` if the machine has already stopped.

  ## Examples

      machine = Rig.step(machine, :payment_received)
      machine = Rig.step(machine, {:approve, user})

  """
  @spec step(Machine.t(), term()) :: Machine.t()
  def step(%Machine{status: {:stopped, reason}} = machine, event) do
    raise Rig.StoppedError,
          module: machine.module,
          state: machine.state,
          event: event,
          reason: reason
  end

  def step(%Machine{} = machine, event) do
    result = machine.module.handle_event(machine.state, :internal, event, machine.data)
    apply_result(machine, result)
  end

  @doc """
  Like `step/2`, but raises on `{:stop, ...}` results.

  Useful in tests and scripts where a stop is unexpected.
  """
  @spec step!(Machine.t(), term()) :: Machine.t()
  def step!(%Machine{} = machine, event) do
    case step(machine, event) do
      %Machine{status: {:stopped, reason}} = stopped ->
        raise Rig.StoppedError,
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

  defp move_to(machine, new_state, new_data, actions) do
    %{machine | state: new_state, data: new_data, effects: List.wrap(actions)}
  end

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

  defp validate_module!(module) do
    unless function_exported?(module, :handle_event, 4) do
      raise ArgumentError,
            "#{inspect(module)} does not implement the Rig behaviour " <>
              "(missing handle_event/4)"
    end
  end
end
