defmodule Rig.ServerTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Test fixtures
  # ---------------------------------------------------------------------------

  defmodule Door do
    use Rig

    @impl true
    def init(opts), do: {:ok, :locked, %{key: opts[:key] || "default"}}

    @impl true
    def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
    def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
    def handle_event(:unlocked, _, :open, data), do: {:next_state, :opened, data}
    def handle_event(:opened, _, :close, data), do: {:next_state, :unlocked, data}

    def handle_event(state, {:call, from}, :status, data) do
      {:keep_state, data, [{:reply, from, state}]}
    end

    def handle_event(:opened, _, :auto_close, data) do
      {:keep_state, data, [{:state_timeout, 50, :close_timeout}]}
    end

    def handle_event(:opened, :state_timeout, :close_timeout, data) do
      {:next_state, :unlocked, data}
    end
  end

  defmodule DoorWithEnter do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :locked, %{enter_log: []}}

    @impl true
    def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
    def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}

    def handle_event(_state, {:call, from}, :enter_log, data) do
      {:keep_state, data, [{:reply, from, data.enter_log}]}
    end

    @impl true
    def on_enter(old_state, new_state, data) do
      {:keep_state, Map.update!(data, :enter_log, &[{old_state, new_state} | &1])}
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Server lifecycle
  # ---------------------------------------------------------------------------

  describe "start_link/3" do
    test "starts a gen_statem process" do
      {:ok, pid} = Rig.Server.start_link(Door, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "passes args to init" do
      {:ok, pid} = Rig.Server.start_link(Door, key: "secret")
      assert Rig.Server.call(pid, :status) == :locked
      GenServer.stop(pid)
    end

    test "supports :name option" do
      {:ok, pid} = Rig.Server.start_link(Door, [], name: :test_door)
      assert Process.whereis(:test_door) == pid
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — cast/2 and call/3
  # ---------------------------------------------------------------------------

  describe "cast/2" do
    test "sends an async event that transitions state" do
      {:ok, pid} = Rig.Server.start_link(Door, [])
      :ok = Rig.Server.cast(pid, :unlock)
      assert eventually(fn -> Rig.Server.call(pid, :status) == :unlocked end)
      GenServer.stop(pid)
    end
  end

  describe "call/3" do
    test "sends a sync event and returns the reply" do
      {:ok, pid} = Rig.Server.start_link(Door, [])
      assert Rig.Server.call(pid, :status) == :locked

      Rig.Server.cast(pid, :unlock)
      assert eventually(fn -> Rig.Server.call(pid, :status) == :unlocked end)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — event_type passthrough
  # ---------------------------------------------------------------------------

  describe "event_type passthrough" do
    test "cast events arrive with :cast event_type" do
      defmodule CastProbe do
        use Rig

        @impl true
        def init(_), do: {:ok, :idle, %{}}

        @impl true
        def handle_event(:idle, :cast, :ping, data) do
          {:keep_state, Map.put(data, :got_cast, true)}
        end

        def handle_event(_state, {:call, from}, :check, data) do
          {:keep_state, data, [{:reply, from, data[:got_cast]}]}
        end
      end

      {:ok, pid} = Rig.Server.start_link(CastProbe, [])
      Rig.Server.cast(pid, :ping)
      assert eventually(fn -> Rig.Server.call(pid, :check) == true end)
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — state timeouts
  # ---------------------------------------------------------------------------

  describe "state timeouts" do
    test "state_timeout fires and triggers transition" do
      {:ok, pid} = Rig.Server.start_link(Door, [])

      Rig.Server.cast(pid, :unlock)
      Rig.Server.cast(pid, :open)
      Rig.Server.cast(pid, :auto_close)

      assert eventually(fn -> Rig.Server.call(pid, :status) == :unlocked end, 200)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — on_enter/3 via Server
  # ---------------------------------------------------------------------------

  describe "on_enter/3 via Server" do
    test "on_enter is called on state transitions" do
      {:ok, pid} = Rig.Server.start_link(DoorWithEnter, [])

      Rig.Server.cast(pid, :unlock)
      Process.sleep(20)

      log = Rig.Server.call(pid, :enter_log)
      assert {:locked, :unlocked} in log

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — telemetry
  # ---------------------------------------------------------------------------

  describe "telemetry" do
    test "emits [:rig, :transition] on state changes" do
      ref = make_ref()
      parent = self()

      handler = fn event, measurements, metadata, _config ->
        send(parent, {ref, event, measurements, metadata})
      end

      :telemetry.attach("test-rig-transition", [:rig, :transition], handler, nil)

      {:ok, pid} = Rig.Server.start_link(Door, [])
      Rig.Server.cast(pid, :unlock)
      Process.sleep(50)

      assert_received {^ref, [:rig, :transition], %{system_time: _},
                       %{module: Door, data: _data}}

      :telemetry.detach("test-rig-transition")
      GenServer.stop(pid)
    end

    test "telemetry metadata includes machine data" do
      ref = make_ref()
      parent = self()

      handler = fn _event, _measurements, metadata, _config ->
        send(parent, {ref, metadata})
      end

      :telemetry.attach("test-rig-data", [:rig, :transition], handler, nil)

      {:ok, pid} = Rig.Server.start_link(Door, key: "secret")
      Rig.Server.cast(pid, :unlock)
      Process.sleep(50)

      # Flush until we get a transition with to: :unlocked
      assert_received {^ref, %{to: :unlocked, data: data}}
      assert data.key == "secret"

      :telemetry.detach("test-rig-data")
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp eventually(fun, timeout \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end
end
