defmodule Decidable do
  @moduledoc """
  A behaviour for finite state machines as pure, testable data structures.

  Decidable separates state machine logic from process concerns. You implement
  a single callback module with `handle_event/4` (and optionally `on_enter/3`),
  then use it in two ways:

    1. **Pure** — `Decidable.new/2` and `Decidable.transition/2` operate on a
       `%Decidable.Machine{}` struct with no processes, no side effects, no telemetry.
       Perfect for tests, LiveView reducers, Oban workers, scripts.

    2. **Process** — `Decidable.Server` wraps the same module in a `:gen_statem`
       process, executing pending actions, emitting telemetry, and integrating
       with supervision trees.

  ## Callback Signature

  `handle_event/4` takes four arguments: state, event type, event content, and data.
  The event type follows `:gen_statem` exactly:

    * `:internal` — programmatic events (pure transitions, `{:next_event, :internal, _}`)
    * `:cast` — async events via `Decidable.Server.cast/2`
    * `{:call, from}` — sync events via `Decidable.Server.call/3` (reply with `{:reply, from, reply}`)
    * `:info` — raw messages from linked processes
    * `:timeout` / `:state_timeout` / `{:timeout, name}` — timer events

  In pure code, the event type is always `:internal`. Match on `_` if you don't
  need to distinguish.

  ## Example

      defmodule MyApp.Door do
        use Decidable

        @impl true
        def init(_opts), do: {:ok, :locked, %{}}

        @impl true
        # Pure domain events — ignore event type with _
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

        # Server-only: reply to synchronous calls
        def handle_event(state, {:call, from}, :status, data) do
          {:keep_state, data, [{:reply, from, state}]}
        end
      end

      # Pure usage — no process needed
      machine =
        MyApp.Door
        |> Decidable.new()
        |> Decidable.transition(:unlock)
        |> Decidable.transition(:open)

      machine.state
      #=> :opened

  """

  alias Decidable.Machine

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

  In pure usage (`Decidable.transition/2`), event_type is always `:internal`.
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
      @behaviour Decidable

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Decidable.Server, :start_link, [__MODULE__, args, []]},
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

  Calls `module.init(args)` and returns a `%Decidable.Machine{}` struct.
  Raises on `{:stop, reason}` from init.

  ## Examples

      machine = Decidable.new(MyApp.Door)
      machine = Decidable.new(MyApp.Order, order_id: 123)

  """
  @spec new(module(), term()) :: Machine.t()
  def new(module, args \\ []) do
    case module.init(args) do
      {:ok, state, data} ->
        %Machine{module: module, state: state, data: data}

      {:stop, reason} ->
        raise ArgumentError,
              "#{inspect(module)}.init/1 returned {:stop, #{inspect(reason)}}"
    end
  end

  @doc """
  Apply a domain event to the machine, producing a new machine.

  The event type is `:internal` — this is a pure, programmatic transition.
  Returns the updated `%Decidable.Machine{}`. If the callback returns
  `{:stop, reason, data}`, the machine's status becomes `{:stopped, reason}`.

  Each call replaces `pending_actions` with the actions from this transition
  only — actions do not accumulate across pipeline stages.

  Raises `Decidable.StoppedError` if the machine has already stopped.

  ## Examples

      machine = Decidable.transition(machine, :payment_received)
      machine = Decidable.transition(machine, {:approve, user})

  """
  @spec transition(Machine.t(), term()) :: Machine.t()
  def transition(%Machine{status: {:stopped, reason}} = machine, event) do
    raise Decidable.StoppedError,
          module: machine.module,
          state: machine.state,
          event: event,
          reason: reason
  end

  def transition(%Machine{} = machine, event) do
    result = machine.module.handle_event(machine.state, :internal, event, machine.data)
    apply_result(machine, result)
  end

  @doc """
  Like `transition/2`, but raises on `{:stop, ...}` results.

  Useful in tests and scripts where a stop is unexpected.
  """
  @spec transition!(Machine.t(), term()) :: Machine.t()
  def transition!(%Machine{} = machine, event) do
    case transition(machine, event) do
      %Machine{status: {:stopped, reason}} = stopped ->
        raise Decidable.StoppedError,
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
    |> put_transition(new_state, new_data, [])
    |> maybe_on_enter(machine.state)
  end

  defp apply_result(machine, {:next_state, new_state, new_data, actions}) do
    machine
    |> put_transition(new_state, new_data, actions)
    |> maybe_on_enter(machine.state)
  end

  defp apply_result(machine, {:keep_state, new_data}) do
    %{machine | data: new_data, pending_actions: []}
  end

  defp apply_result(machine, {:keep_state, new_data, actions}) do
    %{machine | data: new_data, pending_actions: List.wrap(actions)}
  end

  defp apply_result(machine, :keep_state_and_data) do
    %{machine | pending_actions: []}
  end

  defp apply_result(machine, {:keep_state_and_data, actions}) do
    %{machine | pending_actions: List.wrap(actions)}
  end

  defp apply_result(machine, {:stop, reason, new_data}) do
    %{machine | data: new_data, status: {:stopped, reason}, pending_actions: []}
  end

  defp put_transition(machine, new_state, new_data, actions) do
    %{machine | state: new_state, data: new_data, pending_actions: List.wrap(actions)}
  end

  defp maybe_on_enter(
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
            pending_actions: machine.pending_actions ++ List.wrap(enter_actions)}
      end
    else
      machine
    end
  end
end
