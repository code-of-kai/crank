defmodule Crank do
  @moduledoc """
  ## What this is

  Crank lets you build a state machine as ordinary data. The machine is a
  struct, `%Crank.Machine{}`, which holds the current state, whatever data
  you've accumulated, and any side effects the last transition declared. To
  advance the machine, you call `Crank.crank(machine, event)`. You get back
  a new struct. That's the whole interface.

  There's no process involved, no message passing, no supervision tree.
  It's a pure function -- same input, same output, no side effects.
  You can call it in a test, in a LiveView, in an Oban worker, in a script.
  Anywhere you can call a function.

  ## What you write

  A Crank module is a set of functions. Crank calls them at the right
  moments — Elixir calls this pattern "callbacks." Define the function;
  the library calls it back when something happens. The functions are
  never called directly.

  There are three callbacks:

  **`init/1`** — Crank calls this once when the machine is created. It
  returns the starting state and any initial data:

      def init(opts) do
        {:ok, :idle, %{price: opts[:price] || 100, balance: 0}}
      end

  **`handle/3`** — Crank calls this every time an event arrives, passing
  the event, the current state, and the accumulated data. It returns the
  next state:

      def handle({:coin, amount}, :idle, data) do
        {:next_state, :accepting, %{data | balance: amount}}
      end

      def handle({:coin, amount}, :accepting, data) do
        {:next_state, :accepting, %{data | balance: data.balance + amount}}
      end

  Each function clause is one transition. Read it like a sentence: "When a
  coin arrives and we're idle, move to accepting and record the amount."
  The set of all clauses is the complete specification of the state machine.
  There's nothing else to configure, no tables to fill in, no DSL to learn.

  **`on_enter/3`** — Optional. Crank calls this after a state change,
  passing the old state, the new state, and the data. Useful for recording
  that a transition happened — a timestamp, a counter, a log entry —
  without cluttering the transition logic itself.

  That's every concept. The variety comes from writing more clauses for
  different events and states.

  ## The struct

  After each `crank/2` call, you get back a `%Crank.Machine{}` with five
  fields:

    * `module` — the callback module (so the struct knows which functions to call)
    * `state` — the current state (an atom, a struct, a tuple — any Elixir term)
    * `data` — whatever your `init/1` and `handle/3` have accumulated
    * `effects` — side effects from the last transition, stored as data (never executed)
    * `status` — `:running` or `{:stopped, reason}`

  The `effects` field is important. When `handle/3` returns actions like
  timeouts or replies, the pure core doesn't execute them. It stores them
  as a list in `effects`. They can be inspected, asserted on in tests, or
  ignored. They're just data until something decides to act on them.

  Each `crank/2` call replaces `effects` — they don't pile up from previous
  transitions.

  ## Running it as a process

  Everything above works without a process. But sometimes you need one.
  Maybe you want a timeout that fires after 30 seconds of inactivity. Maybe
  you want the machine to live in a supervision tree so it restarts on
  failure. Maybe another process needs to send it a message and get a reply.

  `Crank.Server` handles this. It takes the same module — the exact same
  one, unchanged — and runs the functions inside `gen_statem`
  (Erlang/Elixir's built-in state machine process):

      {:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, price: 75)
      Crank.Server.cast(pid, {:coin, 25})

  The logic is the same. What changes is the plumbing around it: who calls
  the functions, and what happens to the effects afterward. In pure mode,
  effects are stored as data. In process mode, `gen_statem` executes them —
  timeouts fire, replies get sent, telemetry events are emitted.

  There isn't one module for pure and another for process. There is one
  module. It works in both contexts because it's just functions.

  ## When you need `handle_event/4`

  `handle/3` is enough for most logic. But when a machine runs as a
  process, events arrive in different ways. A cast is asynchronous — fire
  and forget. A call is synchronous — the caller is waiting for a reply.
  A timeout fires because time passed. A raw message arrives from another
  process.

  Sometimes the function needs to know which of these happened. That's
  what `handle_event/4` is for. It's `handle/3` with one extra argument —
  the event type — prepended:

      def handle_event({:call, from}, :status, state, data) do
        {:keep_state, data, [{:reply, from, state}]}
      end

  The event types are:

    * `:internal` — programmatic events (this is what pure `crank/2` always uses)
    * `:cast` — someone called `Crank.Server.cast(pid, event)`
    * `{:call, from}` — someone called `Crank.Server.call(pid, event)` and is waiting
    * `:info` — a raw Erlang message from another process
    * `:timeout`, `:state_timeout`, `{:timeout, name}` — a timer fired

  If a module defines `handle_event/4`, Crank uses it instead of
  `handle/3`. If a module needs both — `handle/3` for business logic
  and `handle_event/4` for replies — the specific clauses go in
  `handle_event/4`, and a catch-all delegates everything else:

      def handle_event({:call, from}, :status, state, data) do
        {:keep_state, data, [{:reply, from, state}]}
      end

      # Everything that isn't a call goes to handle/3
      def handle_event(_event_type, event, state, data) do
        handle(event, state, data)
      end

  ## What you return

  Every `handle/3` (or `handle_event/4`) clause returns a tuple that tells
  Crank what should happen next. The most common ones:

    * `{:next_state, new_state, new_data}` — move to a different state
    * `{:next_state, new_state, new_data, actions}` — move and declare side effects
    * `{:keep_state, new_data}` — stay in the same state, update the data
    * `{:stop, reason, new_data}` — shut down the machine

  There are a few more (`{:keep_state, new_data, actions}`,
  `:keep_state_and_data`, `{:keep_state_and_data, actions}`). These match
  `:gen_statem`'s return values exactly. `{:next_state, ...}` and
  `{:keep_state, ...}` cover nearly everything.

  The `actions` list is where side effects are declared: timeouts, replies,
  internal events. In pure mode these get stored in `machine.effects`. In
  process mode `gen_statem` executes them.

  ## Example

  A door with three states — locked, unlocked, opened — and four transitions:

      defmodule MyApp.Door do
        use Crank

        @impl true
        def init(_opts), do: {:ok, :locked, %{}}

        @impl true
        def handle(:unlock, :locked, data), do: {:next_state, :unlocked, data}
        def handle(:lock, :unlocked, data), do: {:next_state, :locked, data}
        def handle(:open, :unlocked, data), do: {:next_state, :opened, data}
        def handle(:close, :opened, data), do: {:next_state, :unlocked, data}
      end

  Use it:

      machine =
        MyApp.Door
        |> Crank.new()
        |> Crank.crank(:unlock)
        |> Crank.crank(:open)

      machine.state
      #=> :opened

  Four clauses. Four transitions. That's the whole machine. If an event
  arrives that no clause matches — say, `:open` when the door is `:locked`
  — Elixir raises a `FunctionClauseError`. That's deliberate. A state
  machine that silently ignores unexpected events is hiding bugs.
  """

  alias Crank.Machine

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @typedoc """
  How an event was delivered. This is the first argument to `handle_event/4`.

  In pure mode (`crank/2`), the event type is always `:internal`. The other
  types only appear when the machine runs as a process via `Crank.Server`.
  """
  @type event_type ::
          :internal
          | :cast
          | {:call, from :: GenServer.from()}
          | :info
          | :timeout
          | :state_timeout
          | {:timeout, name :: term()}

  @typedoc "What `init/1` returns — either `{:ok, state, data}` to start, or `{:stop, reason}` to refuse."
  @type init_result ::
          {:ok, state :: term(), data :: term()}
          | {:stop, reason :: term()}

  @typedoc """
  What `handle/3` or `handle_event/4` returns. The tuple tells Crank what
  to do next — move to a new state, stay in the current one, or stop.
  Matches `:gen_statem` return values exactly.
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

  @typedoc "What `on_enter/3` returns. Can only keep the current state (optionally updating data)."
  @type on_enter_result ::
          {:keep_state, new_data :: term()}
          | {:keep_state, new_data :: term(), actions :: [Machine.action()]}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Crank calls this once when the machine is created. It returns the
  starting state and any data the machine should carry.

      def init(opts) do
        {:ok, :idle, %{price: opts[:price] || 100, balance: 0}}
      end

  Returns `{:ok, state, data}` to start the machine, or `{:stop, reason}`
  to refuse.
  """
  @callback init(args :: term()) :: init_result()

  @doc """
  Crank calls this every time an event arrives. This is the full
  signature — it includes the event type as the first argument, which
  tells the function *how* the event was delivered.

  Most of the time the delivery method doesn't matter. `handle/3` drops
  the event type and is simpler. `handle_event/4` is for when the function
  needs to reply to a synchronous call, distinguish timeouts from casts,
  or handle raw process messages:

      # Reply to a synchronous caller
      def handle_event({:call, from}, :status, state, data) do
        {:keep_state, data, [{:reply, from, state}]}
      end

  The event types:

    * `:internal` — pure cranks via `Crank.crank/2` (always this in pure mode)
    * `:cast` — async, via `Crank.Server.cast/2`
    * `{:call, from}` — sync, via `Crank.Server.call/3` (caller is waiting)
    * `:info` — raw Erlang message from another process
    * `:timeout` / `:state_timeout` / `{:timeout, name}` — a timer fired

  If a module defines both `handle_event/4` and `handle/3`, Crank uses
  `handle_event/4`.
  """
  @callback handle_event(
              event_type :: event_type(),
              event_content :: term(),
              state :: term(),
              data :: term()
            ) :: handle_event_result()

  @doc """
  Crank calls this every time an event arrives. This is the simplified
  signature — just the event, the current state, and the data. No event
  type.

  This is the callback for business logic. Each clause is one transition:

      def handle({:coin, amount}, :accepting, data) do
        {:next_state, :accepting, %{data | balance: data.balance + amount}}
      end

  Read it as: "When a coin event arrives and the machine is in the
  accepting state, stay in accepting and add the amount to the balance."

  If a module also defines `handle_event/4`, Crank uses that instead.
  This allows process-specific concerns (replies, timeouts) to live in
  `handle_event/4` while everything else delegates:

      def handle_event({:call, from}, :status, state, data) do
        {:keep_state, data, [{:reply, from, state}]}
      end

      def handle_event(_, event, state, data), do: handle(event, state, data)
  """
  @callback handle(
              event :: term(),
              state :: term(),
              data :: term()
            ) :: handle_event_result()

  @doc """
  Crank calls this after the machine enters a new state. Optional.

  Receives the state the machine just left, the state it just entered, and
  the current data. Only fires on actual state changes — when `handle/3`
  returns `{:next_state, ...}` with a different state.

  Useful for recording that a transition happened without cluttering the
  transition logic:

      def on_enter(_old_state, _new_state, data) do
        {:keep_state, Map.put(data, :entered_at, System.monotonic_time())}
      end
  """
  @callback on_enter(
              old_state :: term(),
              new_state :: term(),
              data :: term()
            ) :: on_enter_result()

  @optional_callbacks [handle: 3, handle_event: 4, on_enter: 3]

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
  Create a new machine.

  Takes a callback module and any arguments for `init/1`. Calls `init/1`,
  gets the starting state and data, and returns a `%Crank.Machine{}` struct
  ready to receive events.

  Raises if the module doesn't define the required callbacks, or if
  `init/1` returns `{:stop, reason}`.

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
  Send an event to the machine. Returns a new machine with the updated state.

  This is the core operation. Calls `handle/3` (or `handle_event/4`) with
  the event, the current state, and the data. Whatever the function returns
  becomes the new machine.

  If the function returns `{:stop, reason, data}`, the machine's status
  changes to `{:stopped, reason}`. After that, any further `crank/2` calls
  raise `Crank.StoppedError` — a stopped machine can't process events.

  If the function returns actions (timeouts, replies), they're stored in
  `machine.effects` as inert data. Each `crank/2` replaces effects from
  the previous call — they don't accumulate.

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
    result = dispatch_event(machine.module, event, machine.state, machine.data)
    apply_result(machine, result)
  end

  @doc """
  Same as `crank/2`, but raises if the transition stops the machine.

  In tests and scripts, a stop usually means something went wrong. This
  lets you write a pipeline without checking for stops at each step — if
  any transition returns `{:stop, reason, data}`, you get a
  `Crank.StoppedError` immediately.

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
  # Public API — Persistence
  # ---------------------------------------------------------------------------

  @typedoc """
  A serializable snapshot of a machine: just the module, state, and data.

  Enough to rebuild the machine with `from_snapshot/1` or `resume/3`.
  """
  @type snapshot :: %{
          module: module(),
          state: term(),
          data: term()
        }

  @doc """
  Capture the machine's module, state, and data as a plain map.

  The returned map is a snapshot -- enough to rebuild the machine later
  with `from_snapshot/1`. Effects and status are not included. Effects
  are transient (each `crank/2` replaces them), and a stopped machine
  shouldn't be resumed.

  ## Examples

      iex> machine = Crank.new(Crank.Examples.Door) |> Crank.crank(:unlock)
      iex> snap = Crank.snapshot(machine)
      iex> snap.module
      Crank.Examples.Door
      iex> snap.state
      :unlocked

  """
  @spec snapshot(Machine.t()) :: snapshot()
  def snapshot(%Machine{module: module, state: state, data: data}) do
    %{module: module, state: state, data: data}
  end

  @doc """
  Rebuild a machine from a snapshot. Does not call `init/1`.

  Takes a map with `:module`, `:state`, and `:data` keys and returns a
  `%Crank.Machine{}` in the running state with no effects. Emits a
  `[:crank, :resume]` telemetry event.

  `on_enter/3` does not fire -- the machine is resuming, not entering
  a state for the first time.

  Raises `ArgumentError` if the module doesn't implement the `Crank`
  behaviour, or if the map is missing required keys.

  ## Examples

      iex> original = Crank.new(Crank.Examples.Door) |> Crank.crank(:unlock)
      iex> snap = Crank.snapshot(original)
      iex> resumed = Crank.from_snapshot(snap)
      iex> resumed.state
      :unlocked
      iex> resumed.effects
      []

  """
  @spec from_snapshot(snapshot()) :: Machine.t()
  def from_snapshot(%{module: module, state: state, data: data}) do
    resume(module, state, data)
  end

  def from_snapshot(other) do
    raise ArgumentError,
          "from_snapshot/1 expected a map with :module, :state, and :data keys, got: #{inspect(other)}"
  end

  @doc """
  Rebuild a machine from its three components. Does not call `init/1`.

  Equivalent to `from_snapshot/1` for callers that already have the
  module, state, and data as separate values. Emits a `[:crank, :resume]`
  telemetry event. `on_enter/3` does not fire.

  Raises `ArgumentError` if the module doesn't implement the `Crank`
  behaviour.

  ## Examples

      iex> machine = Crank.resume(Crank.Examples.Door, :unlocked, %{})
      iex> machine.state
      :unlocked
      iex> Crank.crank(machine, :lock).state
      :locked

  """
  @spec resume(module(), term(), term()) :: Machine.t()
  def resume(module, state, data) do
    validate_module!(module)

    :telemetry.execute(
      [:crank, :resume],
      %{system_time: System.system_time()},
      %{module: module, state: state, data: data}
    )

    %Machine{module: module, state: state, data: data, effects: [], status: :running}
  end

  # ---------------------------------------------------------------------------
  # Dispatch — prefer handle_event/4, fall back to handle/3
  # ---------------------------------------------------------------------------

  defp dispatch_event(module, event, state, data) do
    if function_exported?(module, :handle_event, 4) do
      module.handle_event(:internal, event, state, data)
    else
      module.handle(event, state, data)
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
    callback =
      if function_exported?(module, :handle_event, 4),
        do: "handle_event/4",
        else: "handle/3"

    raise ArgumentError,
          "#{inspect(module)}.#{callback} in state #{inspect(state)} " <>
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

    unless function_exported?(module, :handle_event, 4) or
             function_exported?(module, :handle, 3) do
      raise ArgumentError,
            "#{inspect(module)} does not implement the Crank behaviour " <>
              "(missing handle_event/4 or handle/3)"
    end

    :ok
  end
end
