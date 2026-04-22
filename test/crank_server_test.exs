defmodule Crank.ServerTest do
  use ExUnit.Case, async: true

  # ──────────────────────────────────────────────────────────────────────────
  # Fixtures
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Door do
    use Crank

    @impl true
    def start(opts), do: {:ok, :locked, %{key: opts[:key] || "default"}}

    @impl true
    def turn(:unlock, :locked, m), do: {:next, :unlocked, m}
    def turn(:lock, :unlocked, m), do: {:next, :locked, m}
    def turn(:open, :unlocked, m), do: {:next, :opened, m}
    def turn(:close, :opened, m), do: {:next, :unlocked, m}
    # Internal events produced by wants may route here too.
    def turn(:close_timeout, :opened, m), do: {:next, :unlocked, m}
  end

  defmodule AutoClose do
    @moduledoc false
    # A door that auto-closes after entering :opened via a state timeout.
    use Crank

    @impl true
    def start(_opts), do: {:ok, :locked, %{}}

    @impl true
    def turn(:unlock, :locked, m), do: {:next, :unlocked, m}
    def turn(:open, :unlocked, m), do: {:next, :opened, m}
    def turn(:close_timeout, :opened, m), do: {:next, :unlocked, m}

    @impl true
    def wants(:opened, _m), do: [{:after, 50, :close_timeout}]
    def wants(_s, _m), do: []
  end

  defmodule Counter do
    @moduledoc false
    use Crank

    @impl true
    def start(_opts), do: {:ok, :idle, %{count: 0}}

    @impl true
    def turn(:tick, :idle, m), do: {:stay, %{m | count: m.count + 1}}

    @impl true
    def reading(state, m), do: %{state: state, count: m.count}
  end

  defmodule Chain do
    @moduledoc false
    # Demonstrates the {:next, event} want type chaining transitions.
    use Crank

    @impl true
    def start(_opts), do: {:ok, :a, %{log: []}}

    @impl true
    def turn(:go, :a, m), do: {:next, :b, %{m | log: [:a_to_b | m.log]}}
    def turn(:continue, :b, m), do: {:next, :c, %{m | log: [:b_to_c | m.log]}}
    def turn(_, _, m), do: {:stay, m}

    @impl true
    def wants(:b, _m), do: [{:next, :continue}]
    def wants(_s, _m), do: []
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────────────────

  describe "start_link/3" do
    test "starts a gen_statem process" do
      {:ok, pid} = Crank.Server.start_link(Door, [])
      assert Process.alive?(pid)
      Crank.Server.stop(pid)
    end

    test "passes args to start/1" do
      {:ok, pid} = Crank.Server.start_link(Door, key: "secret")
      assert Crank.Server.reading(pid) == :locked
      Crank.Server.stop(pid)
    end

    test "supports :name option" do
      {:ok, pid} = Crank.Server.start_link(Door, [], name: :test_door)
      assert Process.whereis(:test_door) == pid
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # turn/2 — sync, returns reading
  # ──────────────────────────────────────────────────────────────────────────

  describe "turn/2" do
    test "advances the machine and returns the new reading" do
      {:ok, pid} = Crank.Server.start_link(Door, [])
      assert Crank.Server.turn(pid, :unlock) == :unlocked
      assert Crank.Server.reading(pid) == :unlocked
      Crank.Server.stop(pid)
    end

    test "returns reading/2 projection when defined" do
      {:ok, pid} = Crank.Server.start_link(Counter, [])
      assert Crank.Server.turn(pid, :tick) == %{state: :idle, count: 1}
      assert Crank.Server.turn(pid, :tick) == %{state: :idle, count: 2}
      Crank.Server.stop(pid)
    end

    test "reply reflects post-transition state and memory" do
      {:ok, pid} = Crank.Server.start_link(Door, [])
      assert Crank.Server.turn(pid, :unlock) == :unlocked
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # cast/2 — async
  # ──────────────────────────────────────────────────────────────────────────

  describe "cast/2" do
    test "sends an async event that transitions state" do
      {:ok, pid} = Crank.Server.start_link(Door, [])
      :ok = Crank.Server.cast(pid, :unlock)
      assert eventually(fn -> Crank.Server.reading(pid) == :unlocked end)
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # reading/1 — read-only query, no turn/3
  # ──────────────────────────────────────────────────────────────────────────

  describe "reading/1" do
    test "does not call turn/3" do
      {:ok, pid} = Crank.Server.start_link(Counter, [])
      assert Crank.Server.reading(pid) == %{state: :idle, count: 0}
      assert Crank.Server.reading(pid) == %{state: :idle, count: 0}
      Crank.Server.stop(pid)
    end

    test "falls back to raw state when reading/2 is not defined" do
      {:ok, pid} = Crank.Server.start_link(Door, [])
      assert Crank.Server.reading(pid) == :locked
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # wants/2 — executed as real effects
  # ──────────────────────────────────────────────────────────────────────────

  describe "wants/2 — state timeouts" do
    test "{:after, ms, event} fires as a state timeout" do
      {:ok, pid} = Crank.Server.start_link(AutoClose, [])
      Crank.Server.turn(pid, :unlock)
      Crank.Server.turn(pid, :open)

      assert eventually(fn -> Crank.Server.reading(pid) == :unlocked end, 200)
      Crank.Server.stop(pid)
    end

    test "state timeout is cancelled by a state change" do
      {:ok, pid} = Crank.Server.start_link(AutoClose, [])
      Crank.Server.turn(pid, :unlock)
      Crank.Server.turn(pid, :open)
      # Quickly leave :opened before the 50ms timeout fires.
      Process.sleep(5)
      Crank.Server.cast(pid, :close_timeout)
      Process.sleep(80)
      # If the timer had fired a second :close_timeout, it would have been
      # routed to turn/3 and would crash (FunctionClauseError on :close_timeout in :unlocked).
      assert Process.alive?(pid)
      Crank.Server.stop(pid)
    end
  end

  describe "wants/2 — {:next, event}" do
    test "chains transitions via internal events" do
      {:ok, pid} = Crank.Server.start_link(Chain, [])
      # :go advances to :b, which wants {:next, :continue}, which advances to :c.
      Crank.Server.turn(pid, :go)
      assert eventually(fn -> Crank.Server.reading(pid) == :c end)
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Info messages — routed to turn/3
  # ──────────────────────────────────────────────────────────────────────────

  describe "info messages" do
    test "raw send/2 messages are delivered to turn/3" do
      defmodule InfoProbe do
        use Crank
        def start(_), do: {:ok, :waiting, %{}}
        def turn(:hello, :waiting, m), do: {:next, :got_it, m}
        def turn(_, _, m), do: {:stay, m}
      end

      {:ok, pid} = Crank.Server.start_link(InfoProbe, [])
      send(pid, :hello)

      assert eventually(fn -> Crank.Server.reading(pid) == :got_it end)
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Telemetry
  # ──────────────────────────────────────────────────────────────────────────

  describe "telemetry" do
    test "emits [:crank, :start] on fresh boot" do
      ref = make_ref()
      parent = self()
      handler_id = "test-start-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:crank, :start],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Crank.Server.start_link(Door, key: "alpha")

      assert_received {^ref, [:crank, :start], %{system_time: _},
                       %{module: Door, state: :locked, memory: %{key: "alpha"}}}

      :telemetry.detach(handler_id)
      Crank.Server.stop(pid)
    end

    test "emits [:crank, :transition] on state changes with event metadata" do
      ref = make_ref()
      parent = self()
      handler_id = "test-transition-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:crank, :transition],
        fn _event, _measurements, metadata, _ ->
          send(parent, {ref, metadata})
        end,
        nil
      )

      {:ok, pid} = Crank.Server.start_link(Door, [])
      Crank.Server.turn(pid, :unlock)

      assert_received {^ref, %{module: Door, from: :locked, to: :unlocked, event: :unlock, memory: _}}

      :telemetry.detach(handler_id)
      Crank.Server.stop(pid)
    end

    test "emits [:crank, :resume] on resume/2" do
      ref = make_ref()
      parent = self()
      handler_id = "test-resume-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:crank, :resume],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      snapshot = %{module: Door, state: :unlocked, memory: %{key: "secret"}}
      {:ok, pid} = Crank.Server.resume(snapshot)

      assert_received {^ref, [:crank, :resume], %{system_time: _},
                       %{module: Door, state: :unlocked, memory: %{key: "secret"}}}

      :telemetry.detach(handler_id)
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # resume/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "resume/2" do
    test "starts a process in the snapshotted state" do
      snapshot = %{module: Door, state: :unlocked, memory: %{key: "secret"}}
      {:ok, pid} = Crank.Server.resume(snapshot)
      assert Crank.Server.reading(pid) == :unlocked
      Crank.Server.stop(pid)
    end

    test "does not call start/1" do
      # If start were called, the state would be :locked. Resuming into :opened
      # proves start was skipped.
      snapshot = %{module: Door, state: :opened, memory: %{key: "default"}}
      {:ok, pid} = Crank.Server.resume(snapshot)
      assert Crank.Server.reading(pid) == :opened
      Crank.Server.stop(pid)
    end

    test "supports :name option" do
      snapshot = %{module: Door, state: :locked, memory: %{key: "default"}}
      {:ok, pid} = Crank.Server.resume(snapshot, name: :resumed_door)
      assert Process.whereis(:resumed_door) == pid
      Crank.Server.stop(pid)
    end

    test "resumed machine accepts further events" do
      snapshot = %{module: Door, state: :unlocked, memory: %{key: "default"}}
      {:ok, pid} = Crank.Server.resume(snapshot)
      Crank.Server.turn(pid, :lock)
      assert Crank.Server.reading(pid) == :locked
      Crank.Server.stop(pid)
    end

    test "refires wants/2 on the resumed state (re-arms timers)" do
      # AutoClose's wants(:opened) sets a 50ms timeout. Resume into :opened;
      # the timer should re-arm and fire, transitioning to :unlocked.
      snapshot = %{module: AutoClose, state: :opened, memory: %{}}
      {:ok, pid} = Crank.Server.resume(snapshot)

      assert eventually(fn -> Crank.Server.reading(pid) == :unlocked end, 200)
      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp eventually(fun, timeout \\ 200) do
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
