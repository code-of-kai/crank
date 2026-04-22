defmodule Crank.Server do
  @moduledoc """
  Runs a Crank module inside `:gen_statem`. Same callbacks as pure mode;
  the Server is the one place where declared wants become real side effects.

  `turn/2` replies with `c:Crank.reading/2` after the transition. `reading/1`
  queries without advancing. `cast/2` is async fire-and-forget. `resume/2`
  starts from a snapshot without calling `c:Crank.start/1`.

  ## Inbound messages

  Raw messages delivered via `send/2` arrive as `:info` events and are routed
  straight to `c:Crank.turn/3`. Monitor references (`:DOWN`), exit signals
  (`:EXIT`, when the machine traps exits), and stray sends from unrelated
  processes all reach `turn/3`. If your machine establishes monitors or traps
  exits, add explicit `turn/3` clauses for those message shapes, or a
  catch-all `def turn(_msg, state, memory), do: :stay` to tolerate unknown
  inputs. Without a clause, unhandled messages raise `FunctionClauseError`
  and terminate the process; the supervisor restarts from `c:Crank.start/1`.

  ## Telemetry

  - `[:crank, :start]` — on `start_link/3` boot; `%{module, state, memory}`.
  - `[:crank, :resume]` — on `resume/2`; `%{module, state, memory}`.
  - `[:crank, :transition]` — on every state change; `%{module, from, to, event, memory}`.
  - `[:crank, :exception]` — when `c:Crank.turn/3` raises, throws, or exits;
    `%{module, state, event, memory, kind, reason, stacktrace}`. Emitted before
    the exception is re-raised and the process terminates.

  ## `resume/2` and at-least-once effects

  `resume/2` re-fires the resumed state's `c:Crank.wants/2`. Timers are
  re-armed; `{:send, dest, msg}` wants re-deliver their messages. If a state's
  wants include sends with real-world effects (charging a card, dispatching a
  shipment), recovery from a crash may trigger them a second time. Design
  those side-effect recipients to be idempotent, or move the effect out of
  `wants/2` into a saga/process-manager that persists delivery state.
  """

  @typedoc "A pid, registered name, or `{name, node}` tuple."
  @type server :: GenServer.server()

  @typedoc "Return value of `start_link/3` and `resume/2`."
  @type on_start :: {:ok, pid()} | :ignore | {:error, term()}

  @doc """
  Starts a supervised `Crank` process linked to the caller.

  Pass `:name` in `opts` to register the process. All other options are
  forwarded to `:gen_statem.start_link/3` (`:debug`, `:spawn_opt`, etc.).
  """
  @spec start_link(module(), term(), keyword()) :: on_start()
  def start_link(module, args \\ [], opts \\ []) do
    {name, gen_opts} = Keyword.pop(opts, :name)
    do_start({:start, module, args}, name, gen_opts)
  end

  @doc """
  Starts a supervised process from a snapshot. Skips `c:Crank.start/1`,
  re-arms the resumed state's wants, emits `[:crank, :resume]` telemetry.
  """
  @spec resume(Crank.snapshot(), keyword()) :: on_start()
  def resume(%{module: _, state: _, memory: _} = snapshot, opts \\ []) do
    {name, gen_opts} = Keyword.pop(opts, :name)
    do_start({:resume, snapshot}, name, gen_opts)
  end

  @doc """
  Advances the machine by one event. Synchronous. Returns the new reading.

  The reply is always `c:Crank.reading/2` applied to the state and memory
  after the transition. User code cannot declare replies — they are a
  property of arrival at the new state, not the edge that produced it.
  """
  @spec turn(server(), term(), timeout()) :: term()
  def turn(server, event, timeout \\ 5_000) do
    :gen_statem.call(server, {:"$crank_turn", event}, timeout)
  end

  @doc "Fire-and-forget variant. Returns `:ok` immediately. The caller never sees the reading."
  @spec cast(server(), term()) :: :ok
  def cast(server, event) do
    :gen_statem.cast(server, event)
  end

  @doc "Returns the current reading without advancing the machine. No `c:Crank.turn/3` call."
  @spec reading(server(), timeout()) :: term()
  def reading(server, timeout \\ 5_000) do
    :gen_statem.call(server, :"$crank_reading", timeout)
  end

  @doc "Stops the server. Reason defaults to `:normal`, timeout to `:infinity`."
  @spec stop(server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ :infinity) do
    :gen_statem.stop(server, reason, timeout)
  end

  defp do_start(init_arg, nil, gen_opts) do
    :gen_statem.start_link(Crank.Server.Adapter, init_arg, gen_opts)
  end

  defp do_start(init_arg, name, gen_opts) do
    :gen_statem.start_link({:local, name}, Crank.Server.Adapter, init_arg, gen_opts)
  end
end

defmodule Crank.Server.Adapter do
  @moduledoc false
  # The gen_statem implementation. Users interact via `Crank.Server`.
  #
  # callback_mode is plain :handle_event_function — not :state_enter. All
  # wants-derived actions (state timeouts, internal events, sends, telemetry)
  # fire from the transition return tuple. :state_enter is avoided because
  # it forbids :next_event actions, which {:next, event} wants need.
  #
  # Telemetry:
  #   [:crank, :start]      — emitted in init on fresh start
  #   [:crank, :resume]     — emitted in init on resume
  #   [:crank, :transition] — emitted from turn handlers on every state change

  @behaviour :gen_statem

  @type t :: %__MODULE__{
          module: module(),
          memory: term()
        }

  @enforce_keys [:module, :memory]
  defstruct [:module, :memory]

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  # ──────────────────────────────────────────────────────────────────────────
  # Init — fire [:crank, :start] or [:crank, :resume], then arm initial wants
  # ──────────────────────────────────────────────────────────────────────────

  @impl :gen_statem
  def init({:start, module, args}) do
    Code.ensure_loaded(module)

    if function_exported?(module, :turn, 3) do
      case module.start(args) do
        {:ok, state, memory} ->
          emit(:start, %{module: module, state: state, memory: memory})
          actions = wants_actions(module, state, memory)
          {:ok, state, %__MODULE__{module: module, memory: memory}, actions}

        {:stop, reason} ->
          {:stop, reason}

        other ->
          {:stop, {:bad_start_result, other}}
      end
    else
      {:stop, {:bad_module, module}}
    end
  end

  def init({:resume, %{module: module, state: state, memory: memory}}) do
    Code.ensure_loaded(module)

    if function_exported?(module, :turn, 3) do
      emit(:resume, %{module: module, state: state, memory: memory})
      actions = wants_actions(module, state, memory)
      {:ok, state, %__MODULE__{module: module, memory: memory}, actions}
    else
      {:stop, {:bad_module, module}}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Synchronous turn — auto-reply with reading
  # ──────────────────────────────────────────────────────────────────────────

  @impl :gen_statem
  def handle_event({:call, from}, {:"$crank_turn", event}, state, data) do
    case call_turn(data.module, event, state, data.memory) do
      {:next, new_state, new_memory} ->
        emit_transition(data.module, state, new_state, event, new_memory)
        reply = reading_of(data.module, new_state, new_memory)

        actions =
          [{:reply, from, reply}] ++
            cancel_stale_timeout(state, new_state) ++
            wants_actions(data.module, new_state, new_memory)

        {:next_state, new_state, %{data | memory: new_memory}, actions}

      {:stay, new_memory} ->
        reply = reading_of(data.module, state, new_memory)
        {:keep_state, %{data | memory: new_memory}, [{:reply, from, reply}]}

      :stay ->
        reply = reading_of(data.module, state, data.memory)
        {:keep_state_and_data, [{:reply, from, reply}]}

      {:stop, reason, new_memory} ->
        reply = reading_of(data.module, state, new_memory)
        {:stop_and_reply, reason, [{:reply, from, reply}], %{data | memory: new_memory}}

      other ->
        raise_bad_turn(data.module, state, other)
    end
  end

  # Read-only projection — no turn/3, no state change, no telemetry
  def handle_event({:call, from}, :"$crank_reading", state, data) do
    reply = reading_of(data.module, state, data.memory)
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Cast, info, timeout, internal — route to turn/3, arm wants on transition
  # ──────────────────────────────────────────────────────────────────────────

  def handle_event(:cast, event, state, data), do: route_turn(event, state, data)
  def handle_event(:info, msg, state, data), do: route_turn(msg, state, data)
  def handle_event(:state_timeout, event, state, data), do: route_turn(event, state, data)
  def handle_event(:internal, event, state, data), do: route_turn(event, state, data)

  # Named generic timeout fired by `{:after, name, ms, event}` want.
  def handle_event({:timeout, _name}, event, state, data), do: route_turn(event, state, data)

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp route_turn(event, state, data) do
    case call_turn(data.module, event, state, data.memory) do
      {:next, new_state, new_memory} ->
        emit_transition(data.module, state, new_state, event, new_memory)

        actions =
          cancel_stale_timeout(state, new_state) ++
            wants_actions(data.module, new_state, new_memory)

        {:next_state, new_state, %{data | memory: new_memory}, actions}

      {:stay, new_memory} ->
        {:keep_state, %{data | memory: new_memory}}

      :stay ->
        :keep_state_and_data

      {:stop, reason, new_memory} ->
        {:stop, reason, %{data | memory: new_memory}}

      other ->
        raise_bad_turn(data.module, state, other)
    end
  end

  # Wraps `module.turn/3` with exception telemetry. A raised exception becomes a
  # `[:crank, :exception]` event and is then re-raised so gen_statem terminates
  # cleanly and the supervisor restarts. Matches Ecto/Phoenix observability idiom.
  defp call_turn(module, event, state, memory) do
    module.turn(event, state, memory)
  rescue
    e ->
      stacktrace = __STACKTRACE__
      emit(:exception, %{
        module: module,
        state: state,
        event: event,
        memory: memory,
        kind: :error,
        reason: e,
        stacktrace: stacktrace
      })

      reraise e, stacktrace
  catch
    kind, reason when kind in [:exit, :throw] ->
      stacktrace = __STACKTRACE__
      emit(:exception, %{
        module: module,
        state: state,
        event: event,
        memory: memory,
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      })

      :erlang.raise(kind, reason, stacktrace)
  end

  # On same-state `{:next, ...}` re-entry, gen_statem does NOT auto-cancel the
  # pending state timeout (auto-cancel only fires on state-value changes). We
  # inject an explicit cancel so old timers don't survive into a state whose
  # wants no longer declares them. The subsequent wants_actions entries may
  # re-arm with a new timeout, which replaces the cancel.
  defp cancel_stale_timeout(old_state, new_state) do
    if old_state == new_state do
      [{:state_timeout, :cancel}]
    else
      []
    end
  end

  defp wants_actions(module, state, memory) do
    if function_exported?(module, :wants, 2) do
      module.wants(state, memory) |> Enum.flat_map(&interpret_want/1)
    else
      []
    end
  end

  # Anonymous state timeout — auto-cancels on state-value change; only one per state.
  defp interpret_want({:after, ms, event}) when is_integer(ms) and ms >= 0 do
    [{:state_timeout, ms, event}]
  end

  # Named generic timeout — multiple can run concurrently; cancelled explicitly.
  defp interpret_want({:after, name, ms, event}) when is_integer(ms) and ms >= 0 do
    [{{:timeout, name}, ms, event}]
  end

  # Explicit cancellation of a named timeout. No-op if no such timer is active.
  defp interpret_want({:cancel, name}) do
    [{{:timeout, name}, :cancel}]
  end

  defp interpret_want({:next, event}) do
    [{:next_event, :internal, event}]
  end

  defp interpret_want({:send, dest, msg}) do
    send(dest, msg)
    []
  end

  defp interpret_want({:telemetry, name, measurements, metadata})
       when is_list(name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(name, measurements, metadata)
    []
  end

  defp interpret_want(other) do
    raise ArgumentError, "unknown want: #{inspect(other)}"
  end

  defp reading_of(module, state, memory) do
    if function_exported?(module, :reading, 2) do
      module.reading(state, memory)
    else
      state
    end
  end

  defp emit_transition(module, from, to, event, memory) do
    emit(:transition, %{module: module, from: from, to: to, event: event, memory: memory})
  end

  defp emit(name, metadata) do
    :telemetry.execute(
      [:crank, name],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp raise_bad_turn(module, state, result) do
    raise ArgumentError,
          "#{inspect(module)}.turn/3 in state #{inspect(state)} " <>
            "returned invalid result: #{inspect(result)}"
  end
end
