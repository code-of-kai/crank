defmodule Rig.AdversarialTest do
  @moduledoc """
  Adversarial and edge-case tests for Rig.

  These tests probe failure modes, weird inputs, concurrency,
  and invariants that normal usage wouldn't exercise.
  """
  use ExUnit.Case, async: true

  # ===========================================================================
  # PART 1: Pure Core Adversarial Tests
  # ===========================================================================

  # ---------------------------------------------------------------------------
  # Fixture: a machine that exercises every return type in one module
  # ---------------------------------------------------------------------------

  defmodule KitchenSink do
    use Rig

    @impl true
    def init(opts) do
      case opts[:fail] do
        true -> {:stop, :init_failed}
        _ -> {:ok, :idle, %{log: [], counter: 0}}
      end
    end

    @impl true
    # Normal transitions
    def handle_event(:idle, _, :start, data) do
      {:next_state, :running, %{data | log: [:started | data.log]}}
    end

    def handle_event(:running, _, :pause, data) do
      {:next_state, :paused, data}
    end

    def handle_event(:paused, _, :resume, data) do
      {:next_state, :running, data}
    end

    # Self-transition (same state)
    def handle_event(:running, _, :tick, data) do
      {:next_state, :running, %{data | counter: data.counter + 1}}
    end

    # Keep state variants
    def handle_event(:running, _, :increment, data) do
      {:keep_state, %{data | counter: data.counter + 1}}
    end

    def handle_event(:running, _, :increment_with_timeout, data) do
      {:keep_state, %{data | counter: data.counter + 1},
       [{:state_timeout, 5000, :heartbeat}]}
    end

    def handle_event(:running, _, :noop, _data), do: :keep_state_and_data

    def handle_event(:running, _, :noop_with_timeout, _data) do
      {:keep_state_and_data, [{:state_timeout, 1000, :ping}]}
    end

    # Stop
    def handle_event(:running, _, :crash, data) do
      {:stop, :intentional_crash, %{data | log: [:crashed | data.log]}}
    end

    # Bogus return (for testing invalid return detection)
    def handle_event(:idle, _, :bad_return, _data), do: :oops

    # Return with multiple actions
    def handle_event(:running, _, :multi_action, data) do
      {:next_state, :waiting, data, [
        {:state_timeout, 10_000, :deadline},
        {:next_event, :internal, :self_ping}
      ]}
    end

    def handle_event(:waiting, _, :self_ping, data) do
      {:keep_state, %{data | log: [:self_pinged | data.log]}}
    end

    # Call/reply (Server-only but should not crash pure core if event shape matches)
    def handle_event(state, {:call, from}, :status, data) do
      {:keep_state, data, [{:reply, from, {state, data.counter}}]}
    end

    # Timeout handler
    def handle_event(:waiting, :state_timeout, :deadline, data) do
      {:next_state, :timed_out, %{data | log: [:timed_out | data.log]}}
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture: machine with on_enter that modifies data AND returns actions
  # ---------------------------------------------------------------------------

  defmodule EnterHeavy do
    use Rig

    @impl true
    def init(_), do: {:ok, :a, %{enters: 0, log: []}}

    @impl true
    def handle_event(:a, _, :go_b, data), do: {:next_state, :b, data}
    def handle_event(:b, _, :go_c, data), do: {:next_state, :c, data, [{:state_timeout, 100, :c_timeout}]}
    def handle_event(:c, _, :go_a, data), do: {:next_state, :a, data}

    @impl true
    def on_enter(old, new, data) do
      new_data = %{data |
        enters: data.enters + 1,
        log: [{:enter, old, new} | data.log]
      }

      case new do
        :b -> {:keep_state, new_data, [{:state_timeout, 200, :b_timeout}]}
        _ -> {:keep_state, new_data}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fixture: machine with on_enter that returns invalid result
  # ---------------------------------------------------------------------------

  defmodule BadEnter do
    use Rig

    @impl true
    def init(_), do: {:ok, :a, %{}}

    @impl true
    def handle_event(:a, _, :go, _data), do: {:next_state, :b, %{}}

    @impl true
    def on_enter(_old, :b, _data), do: {:error, :bad_enter}
    def on_enter(_old, _new, data), do: {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Pure core: basic invariants
  # ---------------------------------------------------------------------------

  describe "pure core invariants" do
    test "new machine is always :running with empty effects" do
      machine = Rig.new(KitchenSink)
      assert machine.status == :running
      assert machine.effects == []
      assert machine.state == :idle
    end

    test "module field is always the original module" do
      machine = Rig.new(KitchenSink) |> Rig.crank(:start) |> Rig.crank(:tick)
      assert machine.module == KitchenSink
    end

    test "data is never nil after any operation" do
      machine = Rig.new(KitchenSink)
      assert machine.data != nil

      machine = Rig.crank(machine, :start)
      assert machine.data != nil

      machine = Rig.crank(machine, :increment)
      assert machine.data != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: self-transitions (same state → same state)
  # ---------------------------------------------------------------------------

  describe "self-transitions" do
    test "machine can transition to the same state" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:tick)
        |> Rig.crank(:tick)
        |> Rig.crank(:tick)

      assert machine.state == :running
      assert machine.data.counter == 3
    end

    test "on_enter fires on self-transitions" do
      machine =
        EnterHeavy
        |> Rig.new()
        |> Rig.crank(:go_b)
        |> Rig.crank(:go_c)
        |> Rig.crank(:go_a)

      # Three transitions: a→b, b→c, c→a — three enter calls
      assert machine.data.enters == 3
      assert length(machine.data.log) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: long pipelines
  # ---------------------------------------------------------------------------

  describe "long pipelines" do
    test "100 transitions in a pipeline" do
      machine = Rig.new(KitchenSink) |> Rig.crank(:start)

      machine =
        Enum.reduce(1..100, machine, fn _, m ->
          Rig.crank(m, :tick)
        end)

      assert machine.state == :running
      assert machine.data.counter == 100
    end

    test "circular transitions don't corrupt state" do
      machine = Rig.new(EnterHeavy)

      machine =
        Enum.reduce(1..50, machine, fn _, m ->
          m
          |> Rig.crank(:go_b)
          |> Rig.crank(:go_c)
          |> Rig.crank(:go_a)
        end)

      assert machine.state == :a
      assert machine.data.enters == 150
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: effects handling
  # ---------------------------------------------------------------------------

  describe "effects edge cases" do
    test "effects from different return types" do
      # {:next_state, _, _, actions}
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:multi_action)

      assert length(machine.effects) == 2
      assert {:state_timeout, 10_000, :deadline} in machine.effects
      assert {:next_event, :internal, :self_ping} in machine.effects

      # {:keep_state, _, actions}
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:increment_with_timeout)

      assert machine.effects == [{:state_timeout, 5000, :heartbeat}]

      # {:keep_state_and_data, actions}
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:noop_with_timeout)

      assert machine.effects == [{:state_timeout, 1000, :ping}]
    end

    test "effects are always replaced, never accumulated across cranks" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:increment_with_timeout)

      assert length(machine.effects) == 1

      # Next crank clears effects
      machine = Rig.crank(machine, :noop)
      assert machine.effects == []

      # And a new crank with effects replaces fresh
      machine = Rig.crank(machine, :noop_with_timeout)
      assert machine.effects == [{:state_timeout, 1000, :ping}]
    end

    test "on_enter effects append to handle_event effects" do
      machine =
        EnterHeavy
        |> Rig.new()
        |> Rig.crank(:go_b)

      # handle_event returned no actions, on_enter returned [{:state_timeout, 200, :b_timeout}]
      assert machine.effects == [{:state_timeout, 200, :b_timeout}]
    end

    test "handle_event effects + on_enter effects both present" do
      machine =
        EnterHeavy
        |> Rig.new()
        |> Rig.crank(:go_b)
        |> Rig.crank(:go_c)

      # handle_event returned [{:state_timeout, 100, :c_timeout}]
      # on_enter returned no actions (not :b)
      assert machine.effects == [{:state_timeout, 100, :c_timeout}]
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: stopped machine behaviour
  # ---------------------------------------------------------------------------

  describe "stopped machine" do
    test "status is {:stopped, reason} after stop" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:crash)

      assert machine.status == {:stopped, :intentional_crash}
    end

    test "data is preserved after stop" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:tick)
        |> Rig.crank(:crash)

      assert machine.data.counter == 1
      assert :crashed in machine.data.log
    end

    test "state is preserved (last state before stop)" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:crash)

      assert machine.state == :running
    end

    test "effects are cleared on stop" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:increment_with_timeout)

      assert machine.effects != []

      machine = Rig.crank(machine, :crash)
      assert machine.effects == []
    end

    test "crank raises StoppedError on stopped machine" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:crash)

      error = assert_raise Rig.StoppedError, fn -> Rig.crank(machine, :start) end
      assert error.module == KitchenSink
      assert error.state == :running
      assert error.event == :start
      assert error.reason == :intentional_crash
    end

    test "crank! raises on the stopping transition itself" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank!(:start)

      assert_raise Rig.StoppedError, fn -> Rig.crank!(machine, :crash) end
    end

    test "crank (non-bang) does NOT raise on stop — returns stopped machine" do
      machine =
        KitchenSink
        |> Rig.new()
        |> Rig.crank(:start)
        |> Rig.crank(:crash)

      # Non-bang returns the stopped machine, doesn't raise
      assert machine.status == {:stopped, :intentional_crash}
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: invalid callback returns
  # ---------------------------------------------------------------------------

  describe "invalid callback returns" do
    test "handle_event returning invalid result raises ArgumentError" do
      machine = Rig.new(KitchenSink)

      error = assert_raise ArgumentError, fn -> Rig.crank(machine, :bad_return) end
      assert error.message =~ "returned invalid result"
      assert error.message =~ "KitchenSink"
      assert error.message =~ ":idle"
      assert error.message =~ ":oops"
    end

    test "on_enter returning invalid result raises ArgumentError" do
      machine = Rig.new(BadEnter)

      error = assert_raise ArgumentError, fn -> Rig.crank(machine, :go) end
      assert error.message =~ "on_enter"
      assert error.message =~ "returned invalid result"
      assert error.message =~ ":a"
      assert error.message =~ ":b"
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: module validation
  # ---------------------------------------------------------------------------

  describe "module validation" do
    test "Rig.new with non-Rig module raises ArgumentError" do
      assert_raise ArgumentError, ~r/does not implement the Rig behaviour/, fn ->
        Rig.new(String)
      end
    end

    test "Rig.new with atom that isn't a module raises" do
      assert_raise ArgumentError, fn ->
        Rig.new(:not_a_module)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Pure core: event type correctness
  # ---------------------------------------------------------------------------

  describe "event type in pure context" do
    defmodule EventTypeRecorder do
      use Rig

      @impl true
      def init(_), do: {:ok, :idle, %{types: []}}

      @impl true
      def handle_event(state, event_type, event, data) do
        new_data = %{data | types: [{state, event_type, event} | data.types]}

        case event do
          :go -> {:next_state, :running, new_data}
          :stay -> {:keep_state, new_data}
          :stop -> {:stop, :done, new_data}
          _ -> {:keep_state, new_data}
        end
      end
    end

    test "every pure crank uses :internal event type" do
      machine =
        EventTypeRecorder
        |> Rig.new()
        |> Rig.crank(:go)
        |> Rig.crank(:stay)
        |> Rig.crank(:stay)

      types = Enum.map(machine.data.types, fn {_state, type, _event} -> type end)
      assert Enum.all?(types, &(&1 == :internal))
    end
  end

  # ===========================================================================
  # PART 2: Server Adversarial Tests
  # ===========================================================================

  describe "server: crash recovery" do
    @describetag :capture_log
    defmodule CrashOnSecond do
      use Rig

      @impl true
      def init(_), do: {:ok, :alive, %{count: 0}}

      @impl true
      def handle_event(:alive, _, :tick, %{count: 2} = _data) do
        raise "boom"
      end

      def handle_event(:alive, _, :tick, data) do
        {:keep_state, %{data | count: data.count + 1}}
      end

      def handle_event(:alive, {:call, from}, :count, data) do
        {:keep_state, data, [{:reply, from, data.count}]}
      end
    end

    test "unhandled exception kills the server process" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Rig.Server.start_link(CrashOnSecond, [])

      Rig.Server.cast(pid, :tick)
      Rig.Server.cast(pid, :tick)
      # Third tick will raise
      Rig.Server.cast(pid, :tick)

      assert_receive {:EXIT, ^pid, _reason}, 500
    end
  end

  describe "server: concurrent casts" do
    defmodule Counter do
      use Rig

      @impl true
      def init(_), do: {:ok, :counting, %{n: 0}}

      @impl true
      def handle_event(:counting, _, :inc, data) do
        {:keep_state, %{data | n: data.n + 1}}
      end

      def handle_event(:counting, {:call, from}, :get, data) do
        {:keep_state, data, [{:reply, from, data.n}]}
      end
    end

    test "100 concurrent casts are all processed" do
      {:ok, pid} = Rig.Server.start_link(Counter, [])

      # Fire 100 casts from separate processes
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> Rig.Server.cast(pid, :inc) end)
        end

      Task.await_many(tasks)

      # Give time for all casts to process
      Process.sleep(100)

      assert Rig.Server.call(pid, :get) == 100
      GenServer.stop(pid)
    end
  end

  describe "server: call timeout" do
    defmodule SlowMachine do
      use Rig

      @impl true
      def init(_), do: {:ok, :idle, %{}}

      @impl true
      def handle_event(:idle, {:call, _from}, :slow, _data) do
        Process.sleep(500)
        # Never replies — simulates a stuck handler
        :keep_state_and_data
      end

      def handle_event(:idle, {:call, from}, :fast, data) do
        {:keep_state, data, [{:reply, from, :ok}]}
      end
    end

    test "call with short timeout exits" do
      {:ok, pid} = Rig.Server.start_link(SlowMachine, [])

      assert catch_exit(Rig.Server.call(pid, :slow, 50))

      GenServer.stop(pid)
    end
  end

  describe "server: multiple state transitions from single cast" do
    defmodule AutoAdvance do
      use Rig

      @impl true
      def init(_), do: {:ok, :a, %{visited: [:a]}}

      @impl true
      def handle_event(:a, _, :go, data) do
        {:next_state, :b, data, [{:next_event, :internal, :auto}]}
      end

      def handle_event(:b, :internal, :auto, data) do
        {:next_state, :c, %{data | visited: [:c | data.visited]}}
      end

      def handle_event(:c, {:call, from}, :visited, data) do
        {:keep_state, data, [{:reply, from, data.visited}]}
      end

      @impl true
      def on_enter(_old, new, data) do
        {:keep_state, %{data | visited: [new | data.visited]}}
      end
    end

    test "next_event causes chained transitions in one cast" do
      {:ok, pid} = Rig.Server.start_link(AutoAdvance, [])
      Rig.Server.cast(pid, :go)
      Process.sleep(50)

      visited = Rig.Server.call(pid, :visited)
      # Should have visited a (init), then a→b (on_enter :b), then b→c (auto + on_enter :c)
      assert :b in visited
      assert :c in visited

      GenServer.stop(pid)
    end
  end

  describe "server: info messages" do
    defmodule InfoHandler do
      use Rig

      @impl true
      def init(_), do: {:ok, :idle, %{received: []}}

      @impl true
      def handle_event(:idle, :info, msg, data) do
        {:keep_state, %{data | received: [msg | data.received]}}
      end

      def handle_event(:idle, {:call, from}, :received, data) do
        {:keep_state, data, [{:reply, from, data.received}]}
      end
    end

    test "raw messages arrive as :info event type" do
      {:ok, pid} = Rig.Server.start_link(InfoHandler, [])

      send(pid, :hello)
      send(pid, {:data, 42})
      Process.sleep(50)

      received = Rig.Server.call(pid, :received)
      assert :hello in received
      assert {:data, 42} in received

      GenServer.stop(pid)
    end
  end

  describe "server: named timeouts" do
    defmodule NamedTimeouts do
      use Rig

      @impl true
      def init(_), do: {:ok, :idle, %{fired: []}}

      @impl true
      def handle_event(:idle, _, :start_timers, data) do
        {:keep_state, data, [
          {{:timeout, :fast}, 30, :fast_payload},
          {{:timeout, :slow}, 100, :slow_payload}
        ]}
      end

      def handle_event(:idle, {:timeout, :fast}, :fast_payload, data) do
        {:keep_state, %{data | fired: [:fast | data.fired]}}
      end

      def handle_event(:idle, {:timeout, :slow}, :slow_payload, data) do
        {:keep_state, %{data | fired: [:slow | data.fired]}}
      end

      def handle_event(:idle, {:call, from}, :fired, data) do
        {:keep_state, data, [{:reply, from, data.fired}]}
      end
    end

    test "named timeouts fire with correct names and payloads" do
      {:ok, pid} = Rig.Server.start_link(NamedTimeouts, [])

      Rig.Server.cast(pid, :start_timers)
      Process.sleep(200)

      fired = Rig.Server.call(pid, :fired)
      assert :fast in fired
      assert :slow in fired

      GenServer.stop(pid)
    end
  end
end
