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
  @typedoc """
  Optional resource limits applied to the running machine. See
  `Crank.Server` module docs for the Mode A / Mode B distinction.

    * `:max_heap_size` — bytes; passed to `Process.flag(:max_heap_size, _)`.
      In Mode A (no `:turn_timeout`) the cap applies to the gen_statem process
      itself. In Mode B the cap applies to the worker task that runs `turn/3`.
    * `:turn_timeout` — milliseconds; if set, every `turn/3` call runs in a
      `Task.Supervisor.async_nolink/3` worker that is killed on timeout.
      Without this, no worker is spawned and behaviour is unchanged from
      pre-resource-limits Crank.Server (Mode A).
  """
  @type resource_limits :: [
          max_heap_size: pos_integer(),
          turn_timeout: pos_integer()
        ]

  @spec start_link(module(), term(), keyword()) :: on_start()
  def start_link(module, args \\ [], opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    {resource_limits, gen_opts} = Keyword.pop(opts, :resource_limits, [])
    do_start({:start, module, args, resource_limits}, name, gen_opts)
  end

  @doc """
  Starts a supervised process from a snapshot. Skips `c:Crank.start/1`,
  re-arms the resumed state's wants, emits `[:crank, :resume]` telemetry.
  """
  @spec resume(Crank.snapshot(), keyword()) :: on_start()
  def resume(%{module: _, state: _, memory: _} = snapshot, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    {resource_limits, gen_opts} = Keyword.pop(opts, :resource_limits, [])
    do_start({:resume, snapshot, resource_limits}, name, gen_opts)
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
          memory: term(),
          resource_limits: keyword()
        }

  @enforce_keys [:module, :memory]
  defstruct [:module, :memory, resource_limits: []]

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  # ──────────────────────────────────────────────────────────────────────────
  # Init — fire [:crank, :start] or [:crank, :resume], then arm initial wants
  # ──────────────────────────────────────────────────────────────────────────

  @impl :gen_statem
  def init({:start, module, args, resource_limits}) do
    apply_mode_a_heap_cap!(resource_limits)
    Code.ensure_loaded(module)

    if function_exported?(module, :turn, 3) do
      case module.start(args) do
        {:ok, state, memory} ->
          emit(:start, %{module: module, state: state, memory: memory})
          actions = wants_actions(module, state, memory)

          data = %__MODULE__{
            module: module,
            memory: memory,
            resource_limits: resource_limits
          }

          {:ok, state, data, actions}

        {:stop, reason} ->
          {:stop, reason}

        other ->
          {:stop, {:bad_start_result, other}}
      end
    else
      {:stop, {:bad_module, module}}
    end
  end

  # Backwards-compatible 3-element shape (no resource_limits).
  def init({:start, module, args}), do: init({:start, module, args, []})

  def init({:resume, %{module: module, state: state, memory: memory}, resource_limits}) do
    apply_mode_a_heap_cap!(resource_limits)
    Code.ensure_loaded(module)

    if function_exported?(module, :turn, 3) do
      emit(:resume, %{module: module, state: state, memory: memory})
      actions = wants_actions(module, state, memory)

      data = %__MODULE__{
        module: module,
        memory: memory,
        resource_limits: resource_limits
      }

      {:ok, state, data, actions}
    else
      {:stop, {:bad_module, module}}
    end
  end

  # Backwards-compatible 2-element shape (no resource_limits).
  def init({:resume, snapshot}), do: init({:resume, snapshot, []})

  # Mode A only: heap cap applies to gen_statem itself when `turn_timeout`
  # is not set. In Mode B the cap is applied to the worker task at spawn
  # time; setting it on the gen_statem would enforce on the wrong process.
  defp apply_mode_a_heap_cap!(resource_limits) do
    cond do
      Keyword.has_key?(resource_limits, :turn_timeout) ->
        :ok

      heap = Keyword.get(resource_limits, :max_heap_size) ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        :ok

      true ->
        :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Synchronous turn — auto-reply with reading
  # ──────────────────────────────────────────────────────────────────────────

  @impl :gen_statem
  def handle_event({:call, from}, {:"$crank_turn", event}, state, data) do
    case call_turn_with_limits(data, event, state) do
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
    case call_turn_with_limits(data, event, state) do
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

  # Dispatches to Mode A (in-process) or Mode B (worker-task with timeout)
  # based on resource_limits. Mode A is the default behaviour preserved
  # for backwards compatibility; Mode B engages only when `turn_timeout`
  # is explicitly configured on `start_link`.
  defp call_turn_with_limits(data, event, state) do
    case Keyword.get(data.resource_limits, :turn_timeout) do
      nil ->
        # Mode A: direct in-process call. Heap cap (if any) was applied
        # in init/1 and is enforced by the BEAM on the gen_statem itself.
        call_turn(data.module, event, state, data.memory)

      timeout when is_integer(timeout) and timeout > 0 ->
        # Mode B: spawn a worker under Crank.TaskSupervisor that runs
        # turn/3, set the worker's heap cap before invoking, then await
        # with Task.yield/2 + Task.shutdown(:brutal_kill) on timeout.
        call_turn_in_worker(data, event, state, timeout)
    end
  end

  defp call_turn_in_worker(data, event, state, timeout) do
    %{module: module, memory: memory, resource_limits: limits} = data
    parent = self()

    fun = fn ->
      # Apply heap cap on the worker process (where the actual work
      # happens). The BEAM kills the process if it allocates beyond.
      case Keyword.get(limits, :max_heap_size) do
        nil ->
          :ok

        size when is_integer(size) ->
          Process.flag(:max_heap_size, %{size: size, kill: true, error_logger: false})
      end

      # We catch and forward exceptions so the gen_statem can re-raise
      # them with the correct context, instead of seeing them as `:exit`.
      try do
        {:ok, module.turn(event, state, memory)}
      rescue
        e -> {:raised, :error, e, __STACKTRACE__}
      catch
        kind, reason when kind in [:exit, :throw] ->
          {:raised, kind, reason, __STACKTRACE__}
      end
    end

    case start_worker_task(fun) do
      {:ok, task} ->
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, result}} ->
            result

          {:ok, {:raised, :error, exception, stacktrace}} ->
            emit(:exception, %{
              module: module,
              state: state,
              event: event,
              memory: memory,
              kind: :error,
              reason: exception,
              stacktrace: stacktrace
            })

            reraise exception, stacktrace

          {:ok, {:raised, kind, reason, stacktrace}} when kind in [:exit, :throw] ->
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

          {:exit, {:killed, _stack}} ->
            # Worker was killed by Process.flag(:max_heap_size, kill: true).
            handle_resource_violation(parent, data, event, state, "CRANK_RUNTIME_001",
              :max_heap_exceeded
            )

          {:exit, :killed} ->
            handle_resource_violation(parent, data, event, state, "CRANK_RUNTIME_001",
              :max_heap_exceeded
            )

          {:exit, reason} ->
            # Other exit (e.g., supervisor ancestor died). Surface as exception
            # telemetry and propagate.
            emit(:exception, %{
              module: module,
              state: state,
              event: event,
              memory: memory,
              kind: :exit,
              reason: reason,
              stacktrace: []
            })

            exit(reason)

          nil ->
            # Task.yield returned nil → timeout fired → Task.shutdown
            # killed the worker. Mode B's defining signal.
            handle_resource_violation(parent, data, event, state, "CRANK_RUNTIME_002",
              {:turn_timeout, timeout}
            )
        end

      :saturated ->
        # Crank.TaskSupervisor has reached max_children. This is a
        # system-health failure, not a purity violation. Stop the
        # gen_statem with a distinct reason so supervision restarts it.
        exit({:crank_supervisor_saturated, data.module})

      :supervisor_down ->
        exit({:crank_supervisor_unavailable, data.module})
    end
  end

  # Defensive wrapper around Task.Supervisor.async_nolink. The historical
  # OTP contract for supervisor saturation has varied; we handle both the
  # tagged-tuple return and the :exit signal modes so the code works on
  # any OTP 26+ release.
  defp start_worker_task(fun) do
    try do
      case Task.Supervisor.async_nolink(Crank.TaskSupervisor, fun) do
        %Task{} = task -> {:ok, task}
        {:error, :max_children_reached} -> :saturated
        {:error, _other} -> :saturated
      end
    catch
      :exit, {:noproc, _} -> :supervisor_down
      :exit, reason -> if saturation_exit?(reason), do: :saturated, else: :erlang.raise(:exit, reason, __STACKTRACE__)
    end
  end

  defp saturation_exit?(reason) do
    case reason do
      {:max_children, _} -> true
      :max_children -> true
      _ -> false
    end
  end

  defp handle_resource_violation(_parent, data, event, state, code, reason) do
    emit(:exception, %{
      module: data.module,
      state: state,
      event: event,
      memory: data.memory,
      kind: :error,
      reason: {code, reason},
      stacktrace: []
    })

    # Re-raise so the gen_statem callback path observes the failure and
    # the supervisor restarts. `code` is the catalog code; the message
    # is human-readable for debug logs.
    raise RuntimeError, "[#{code}] Crank turn resource limit exceeded: #{inspect(reason)}"
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
