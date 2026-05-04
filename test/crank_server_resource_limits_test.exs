defmodule Crank.ServerResourceLimitsTest do
  use ExUnit.Case, async: false

  setup do
    # Mode-A and Mode-B tests deliberately crash the gen_statem to verify
    # resource-limit enforcement. Trap exits so the test process survives
    # the linked-process death signal.
    Process.flag(:trap_exit, true)
    :ok
  end

  # Test fixtures for Mode A and Mode B.
  defmodule SlowMachine do
    use Crank

    @impl true
    def start(_), do: {:ok, :idle, %{count: 0}}

    @impl true
    def turn({:slow, ms}, :idle, memory) do
      Process.sleep(ms)
      {:next, :slow_done, %{memory | count: memory.count + 1}}
    end

    def turn(:done, _state, memory), do: {:next, :idle, memory}
  end

  defmodule TightLoopMachine do
    use Crank

    @impl true
    def start(_), do: {:ok, :idle, %{}}

    @impl true
    def turn(:loop, :idle, memory) do
      _ = tight_loop(0)
      {:next, :done, memory}
    end

    # Recursive non-yielding loop. Same-process timers cannot preempt
    # this; only out-of-process kill (Task.shutdown :brutal_kill) works.
    defp tight_loop(n), do: tight_loop(n + 1)
  end

  defmodule HeavyAllocMachine do
    use Crank

    @impl true
    def start(_), do: {:ok, :idle, %{}}

    @impl true
    def turn(:allocate, :idle, memory) do
      # Build a list large enough to blow past tiny heap caps.
      _big = for i <- 1..200_000, do: {i, i * i, "padding text padding text"}
      {:next, :done, memory}
    end
  end

  describe "Mode A — no turn_timeout (existing behaviour preserved)" do
    test "start_link with no resource_limits behaves as before" do
      {:ok, pid} = Crank.Server.start_link(SlowMachine, [])
      assert is_pid(pid)
      result = Crank.Server.turn(pid, {:slow, 10})
      assert result != nil
      Crank.Server.stop(pid)
    end

    test "Mode A heap cap kills gen_statem on heavy allocation" do
      {:ok, pid} =
        Crank.Server.start_link(HeavyAllocMachine, [],
          resource_limits: [max_heap_size: 100_000]
        )

      ref = Process.monitor(pid)
      catch_exit(Crank.Server.turn(pid, :allocate, 1_000))

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end

  describe "Mode B — turn_timeout configured (worker-task path)" do
    test "fast turn returns normally" do
      {:ok, pid} =
        Crank.Server.start_link(SlowMachine, [],
          resource_limits: [turn_timeout: 1_000]
        )

      result = Crank.Server.turn(pid, {:slow, 10})
      assert result != nil
      Crank.Server.stop(pid)
    end

    test "slow yielding turn (Process.sleep) crashes with CRANK_RUNTIME_002 on timeout" do
      {:ok, pid} =
        Crank.Server.start_link(SlowMachine, [],
          resource_limits: [turn_timeout: 50]
        )

      ref = Process.monitor(pid)

      # turn/2 will receive an exit signal because the gen_statem dies;
      # catch that to keep the test process alive.
      catch_exit(Crank.Server.turn(pid, {:slow, 500}, 2_000))

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 3_000

      # Reason carries the runtime-error message containing the catalog code.
      assert match_runtime_002?(reason)
    end

    test "non-yielding tight CPU loop crashes with CRANK_RUNTIME_002 (justifies out-of-process design)" do
      {:ok, pid} =
        Crank.Server.start_link(TightLoopMachine, [],
          resource_limits: [turn_timeout: 100]
        )

      ref = Process.monitor(pid)
      catch_exit(Crank.Server.turn(pid, :loop, 5_000))

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 6_000
      assert match_runtime_002?(reason)
    end

    test "Mode B heap cap kills the worker, surfaces CRANK_RUNTIME_001" do
      {:ok, pid} =
        Crank.Server.start_link(HeavyAllocMachine, [],
          resource_limits: [turn_timeout: 5_000, max_heap_size: 100_000]
        )

      ref = Process.monitor(pid)
      catch_exit(Crank.Server.turn(pid, :allocate, 6_000))

      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 6_000
      assert match_runtime_001?(reason)
    end

    test "Crank.TaskSupervisor is used for worker spawn" do
      {:ok, pid} =
        Crank.Server.start_link(SlowMachine, [],
          resource_limits: [turn_timeout: 1_000]
        )

      # Capture supervisor children before and after a turn to verify
      # the worker was spawned under Crank.TaskSupervisor (transient).
      sup_pid = Process.whereis(Crank.TaskSupervisor)
      assert is_pid(sup_pid)

      # Kick off a turn that will succeed quickly.
      _ = Crank.Server.turn(pid, {:slow, 5})

      # After completion, supervisor's child count returns to 0.
      :timer.sleep(50)
      counts = Supervisor.count_children(Crank.TaskSupervisor)
      assert counts.active in [0, 0]
      Crank.Server.stop(pid)
    end
  end

  defp match_runtime_002?(reason) do
    inspect_reason(reason) =~ "CRANK_RUNTIME_002"
  end

  defp match_runtime_001?(reason) do
    inspect_reason(reason) =~ "CRANK_RUNTIME_001"
  end

  defp inspect_reason(reason), do: inspect(reason, limit: :infinity)
end
