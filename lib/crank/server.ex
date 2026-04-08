defmodule Crank.Server do
  @moduledoc """
  Runs a `Crank` callback module as a supervised `gen_statem` process.

  The Server calls the same `handle/3` or `handle_event/4` functions
  that `Crank.crank/2` calls. It adds what pure functions can't do:
  execute timeouts, send replies, emit telemetry on every transition,
  and integrate with OTP supervision.

  ## Two ways to use it

  **Separate logic and server modules:**

      defmodule MyApp.DoorServer do
        use Crank.Server, logic: MyApp.Door
      end

      {:ok, pid} = Crank.Server.start_link(MyApp.DoorServer, [])
      Crank.Server.cast(pid, :unlock)

  **Inline -- the logic module is the server module:**

      defmodule MyApp.Door do
        use Crank
        use Crank.Server

        @impl Crank
        def init(_opts), do: {:ok, :locked, %{}}

        @impl Crank
        def handle_event(_, :unlock, :locked, data), do: {:next_state, :unlocked, data}
        def handle_event(_, :lock, :unlocked, data), do: {:next_state, :locked, data}
      end

  Both produce a supervised process. The callback module doesn't change.
  """

  @typedoc "A pid, registered name, or `{name, node}` tuple identifying a running server."
  @type server :: GenServer.server()

  @typedoc "Return value of `start_link/3`."
  @type on_start :: {:ok, pid()} | :ignore | {:error, term()}

  @doc false
  defmacro __using__(opts) do
    logic_module = Keyword.get(opts, :logic)

    quote location: :keep do
      @logic_module unquote(logic_module) || __MODULE__

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Crank.Server, :start_link, [@logic_module, args, [name: __MODULE__]]},
          restart: :permanent,
          shutdown: 5000
        }
      end

      defoverridable child_spec: 1
    end
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a `Crank.Server` process linked to the calling process.

  Crank calls `module.init(args)` to get the starting state and data.
  Pass `:name` in `opts` to register the process. All other options
  are forwarded to `:gen_statem.start_link/3` (`:debug`, `:spawn_opt`, etc.).
  """
  @spec start_link(module(), args :: term(), keyword()) :: on_start()
  def start_link(module, args, opts \\ []) do
    {name, gen_opts} = Keyword.pop(opts, :name)

    if name do
      :gen_statem.start_link({:local, name}, Crank.Server.Adapter, {module, args}, gen_opts)
    else
      :gen_statem.start_link(Crank.Server.Adapter, {module, args}, gen_opts)
    end
  end

  @doc """
  Sends an asynchronous event to the server. Returns `:ok` immediately.
  """
  @spec cast(server(), event :: term()) :: :ok
  def cast(server, event) do
    :gen_statem.cast(server, event)
  end

  @doc """
  Sends a synchronous event and waits for the server to reply.

  The callback module replies using `{:reply, from, response}` in its
  effects list. Times out after `timeout` milliseconds (default 5000).
  """
  @spec call(server(), event :: term(), timeout()) :: term()
  def call(server, event, timeout \\ 5000) do
    :gen_statem.call(server, event, timeout)
  end

  @doc """
  Starts a supervised process from a snapshot. Does not call `module.init/1`.

  Takes a snapshot map (produced by `Crank.snapshot/1`) and starts a
  `gen_statem` process with the snapshotted state and data. `on_enter/3`
  does not fire on startup -- the machine is resuming.

  Pass `:name` in `opts` to register the process. All other options are
  forwarded to `:gen_statem.start_link/3`.

  ## Examples

      machine = Crank.new(MyApp.Order) |> Crank.crank(:pay)
      snapshot = Crank.snapshot(machine)
      {:ok, pid} = Crank.Server.start_from_snapshot(snapshot)

  """
  @spec start_from_snapshot(Crank.snapshot(), keyword()) :: on_start()
  def start_from_snapshot(%{module: module, state: state, data: data}, opts) do
    start_from_snapshot(module, state, data, opts)
  end

  def start_from_snapshot(snapshot) when is_map(snapshot) do
    start_from_snapshot(snapshot, [])
  end

  @doc """
  Starts a supervised process from a module, state, and data.

  Same as `start_from_snapshot/2` but takes the three values as positional
  arguments instead of a map.
  """
  @spec start_from_snapshot(module(), term(), term(), keyword()) :: on_start()
  def start_from_snapshot(module, state, data, opts \\ []) when is_atom(module) do
    {name, gen_opts} = Keyword.pop(opts, :name)
    init_arg = {:resume, module, state, data}

    if name do
      :gen_statem.start_link({:local, name}, Crank.Server.Adapter, init_arg, gen_opts)
    else
      :gen_statem.start_link(Crank.Server.Adapter, init_arg, gen_opts)
    end
  end
end

defmodule Crank.Server.Adapter do
  @moduledoc false
  @behaviour :gen_statem

  @type t :: %__MODULE__{
          module: module(),
          data: term(),
          suppress_next_enter: boolean()
        }

  @enforce_keys [:module, :data]
  defstruct [:module, :data, suppress_next_enter: false]

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  @spec init({module(), term()} | {:resume, module(), term(), term()}) ::
          {:ok, term(), t()} | {:stop, term()}
  def init({:resume, module, state, data}) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :handle_event, 4) or
             function_exported?(module, :handle, 3) do
      {:stop, {:bad_module, module}}
    else
      :telemetry.execute(
        [:crank, :resume],
        %{system_time: System.system_time()},
        %{module: module, state: state, data: data}
      )

      {:ok, state, %__MODULE__{module: module, data: data, suppress_next_enter: true}}
    end
  end

  def init({module, args}) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :handle_event, 4) or
             function_exported?(module, :handle, 3) do
      {:stop, {:bad_module, module}}
    else
      case module.init(args) do
        {:ok, state, data} ->
          {:ok, state, %__MODULE__{module: module, data: data}}

        {:stop, reason} ->
          {:stop, reason}
      end
    end
  end

  @impl :gen_statem
  # Resume path — skip the initial :enter callback, clear the flag
  def handle_event(:enter, _old_state, _new_state, %__MODULE__{suppress_next_enter: true} = internal) do
    {:keep_state, %{internal | suppress_next_enter: false}}
  end

  # State enter events — delegate to on_enter/3 if defined
  def handle_event(:enter, old_state, new_state, %__MODULE__{module: module, data: data} = internal) do
    if function_exported?(module, :on_enter, 3) do
      case module.on_enter(old_state, new_state, data) do
        {:keep_state, new_data} ->
          report(module, old_state, new_state, nil, new_data)
          {:keep_state, %{internal | data: new_data}}

        {:keep_state, new_data, actions} ->
          report(module, old_state, new_state, nil, new_data)
          {:keep_state, %{internal | data: new_data}, actions}
      end
    else
      report(module, old_state, new_state, nil, data)
      :keep_state_and_data
    end
  end

  # All other events — pass event_type through to the callback directly
  def handle_event(event_type, event_content, state, %__MODULE__{} = internal) do
    dispatch_event(internal.module, event_type, event_content, state, internal.data)
    |> translate_result(internal, event_content)
  end

  defp dispatch_event(module, event_type, event_content, state, data) do
    if function_exported?(module, :handle_event, 4) do
      module.handle_event(event_type, event_content, state, data)
    else
      module.handle(event_content, state, data)
    end
  end

  # ---------------------------------------------------------------------------
  # Result translation — callback returns → gen_statem returns
  # ---------------------------------------------------------------------------

  @spec translate_result(Crank.handle_event_result(), t(), term()) :: term()
  defp translate_result({:next_state, new_state, new_data}, internal, event) do
    report(internal.module, nil, new_state, event, new_data)
    {:next_state, new_state, %{internal | data: new_data}}
  end

  defp translate_result({:next_state, new_state, new_data, actions}, internal, event) do
    report(internal.module, nil, new_state, event, new_data)
    {:next_state, new_state, %{internal | data: new_data}, actions}
  end

  defp translate_result({:keep_state, new_data}, internal, _event) do
    {:keep_state, %{internal | data: new_data}}
  end

  defp translate_result({:keep_state, new_data, actions}, internal, _event) do
    {:keep_state, %{internal | data: new_data}, actions}
  end

  defp translate_result(:keep_state_and_data, _internal, _event) do
    :keep_state_and_data
  end

  defp translate_result({:keep_state_and_data, actions}, _internal, _event) do
    {:keep_state_and_data, actions}
  end

  defp translate_result({:stop, reason, new_data}, internal, _event) do
    {:stop, reason, %{internal | data: new_data}}
  end

  @spec report(module(), term(), term(), term(), term()) :: :ok
  defp report(module, from, to, event, data) do
    :telemetry.execute(
      [:crank, :transition],
      %{system_time: System.system_time()},
      %{module: module, from: from, to: to, event: event, data: data}
    )
  end
end
