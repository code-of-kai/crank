defmodule Rig.Server do
  @moduledoc """
  A thin `:gen_statem` adapter that runs a `Rig` callback module as
  a supervised OTP process.

  The Server delegates all crank logic to the pure callback module,
  then executes any effects (timeouts, replies, postpone, etc.)
  via `:gen_statem`'s action system. It also emits telemetry on every
  successful transition.

  ## Usage

      defmodule MyApp.DoorServer do
        use Rig.Server, logic: MyApp.Door
      end

      {:ok, pid} = Rig.Server.start_link(MyApp.DoorServer, [])
      Rig.Server.cast(pid, :unlock)

  Or inline (the logic module *is* the server module):

      defmodule MyApp.Door do
        use Rig
        use Rig.Server

        @impl Rig
        def init(_opts), do: {:ok, :locked, %{}}

        @impl Rig
        def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
        def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
      end

  """

  @typedoc "Server name for process registration."
  @type server :: GenServer.server()

  @typedoc "Return type for `start_link/3`."
  @type on_start :: {:ok, pid()} | :ignore | {:error, term()}

  @doc false
  defmacro __using__(opts) do
    logic_module = Keyword.get(opts, :logic)

    quote location: :keep do
      @logic_module unquote(logic_module) || __MODULE__

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {Rig.Server, :start_link, [@logic_module, args, [name: __MODULE__]]},
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
  Start a `Rig.Server` process linked to the caller.

  `module` is the callback module implementing the `Rig` behaviour.
  `args` are passed to `module.init/1`.
  `opts` supports `:name` for process registration, plus any
  `:gen_statem` start options (`:debug`, `:spawn_opt`, etc.).
  """
  @spec start_link(module(), args :: term(), keyword()) :: on_start()
  def start_link(module, args, opts \\ []) do
    {name, gen_opts} = Keyword.pop(opts, :name)

    if name do
      :gen_statem.start_link({:local, name}, Rig.Server.Adapter, {module, args}, gen_opts)
    else
      :gen_statem.start_link(Rig.Server.Adapter, {module, args}, gen_opts)
    end
  end

  @doc """
  Send an asynchronous event to the server.
  """
  @spec cast(server(), event :: term()) :: :ok
  def cast(server, event) do
    :gen_statem.cast(server, event)
  end

  @doc """
  Send a synchronous event and wait for a reply.
  """
  @spec call(server(), event :: term(), timeout()) :: term()
  def call(server, event, timeout \\ 5000) do
    :gen_statem.call(server, event, timeout)
  end
end

defmodule Rig.Server.Adapter do
  @moduledoc false
  @behaviour :gen_statem

  @type t :: %__MODULE__{
          module: module(),
          data: term()
        }

  @enforce_keys [:module, :data]
  defstruct [:module, :data]

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  @spec init({module(), term()}) :: {:ok, term(), t()} | {:stop, term()}
  def init({module, args}) do
    Code.ensure_loaded(module)

    unless function_exported?(module, :handle_event, 4) do
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
  # State enter events — delegate to on_enter/3 if defined
  def handle_event(:enter, old_state, new_state, %__MODULE__{module: module, data: data} = internal) do
    if function_exported?(module, :on_enter, 3) do
      case module.on_enter(old_state, new_state, data) do
        {:keep_state, new_data} ->
          report(module, old_state, new_state, nil)
          {:keep_state, %{internal | data: new_data}}

        {:keep_state, new_data, actions} ->
          report(module, old_state, new_state, nil)
          {:keep_state, %{internal | data: new_data}, actions}
      end
    else
      report(module, old_state, new_state, nil)
      :keep_state_and_data
    end
  end

  # All other events — pass event_type through to the callback directly
  def handle_event(event_type, event_content, state, %__MODULE__{} = internal) do
    internal.module.handle_event(state, event_type, event_content, internal.data)
    |> translate_result(internal, event_content)
  end

  # ---------------------------------------------------------------------------
  # Result translation — callback returns → gen_statem returns
  # ---------------------------------------------------------------------------

  @spec translate_result(Rig.handle_event_result(), t(), term()) :: term()
  defp translate_result({:next_state, new_state, new_data}, internal, event) do
    report(internal.module, nil, new_state, event)
    {:next_state, new_state, %{internal | data: new_data}}
  end

  defp translate_result({:next_state, new_state, new_data, actions}, internal, event) do
    report(internal.module, nil, new_state, event)
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

  @spec report(module(), term(), term(), term()) :: :ok
  defp report(module, from, to, event) do
    :telemetry.execute(
      [:rig, :transition],
      %{system_time: System.system_time()},
      %{module: module, from: from, to: to, event: event}
    )
  end
end
