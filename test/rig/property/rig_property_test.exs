defmodule Rig.PropertyTest do
  @moduledoc """
  Property-based tests for Rig.

  10 invariants × 8,000 runs × sequences up to 1,000 events.
  ~40,000,000 random cranks in ~10 seconds. Pure functions are cheap.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Rig.Generators

  @moduletag :property

  @runs 8_000
  @seq 1000

  # ===========================================================================
  # Invariant 1: Machine struct integrity
  # ===========================================================================

  property "invariant: machine struct is always valid after any crank sequence" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      assert %Rig.Machine{} = machine
      assert machine.state in [:locked, :unlocked]
      assert is_map(machine.data)
      assert is_list(machine.effects)
      assert machine.status == :running
    end
  end

  # ===========================================================================
  # Invariant 2: Effects replace (never accumulate)
  # ===========================================================================

  property "invariant: effects from crank N never leak into crank N+1" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
        new_m = Rig.crank(m, event)
        assert new_m.effects == []
        new_m
      end)
    end
  end

  # ===========================================================================
  # Invariant 3: Conservation — coins always equals total coin events
  # ===========================================================================

  property "invariant: coin count equals total coin events" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      assert machine.data.coins == Enum.count(events, &(&1 == :coin))
      assert machine.data.passes <= Enum.count(events, &(&1 == :push))
    end
  end

  # ===========================================================================
  # Invariant 4: Purity — same inputs always produce same outputs
  # ===========================================================================

  property "invariant: deterministic — same events always produce same result" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      run = fn ->
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.data == b.data
    end
  end

  # ===========================================================================
  # Invariant 5: State reachability — only valid states at every step
  # ===========================================================================

  property "invariant: state is always in the declared state set" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
        new_m = Rig.crank(m, event)
        assert new_m.state in [:locked, :unlocked]
        new_m
      end)
    end
  end

  # ===========================================================================
  # Invariant 6: Stopped is terminal
  # ===========================================================================

  defmodule StoppableMachine do
    use Rig

    @impl true
    def init(_), do: {:ok, :alive, %{ticks: 0}}

    @impl true
    def handle_event(:alive, _, :tick, data) do
      {:keep_state, %{data | ticks: data.ticks + 1}}
    end

    def handle_event(:alive, _, :die, data) do
      {:stop, :dead, data}
    end
  end

  property "invariant: once stopped, every subsequent crank raises StoppedError" do
    check all(
            pre_events <- list_of(constant(:tick), min_length: 0, max_length: 100),
            post_events <- list_of(member_of([:tick, :die, :anything]), min_length: 1, max_length: 20),
            max_runs: @runs
          ) do
      machine =
        Enum.reduce(pre_events, Rig.new(StoppableMachine), fn event, m ->
          Rig.crank(m, event)
        end)

      stopped = Rig.crank(machine, :die)
      assert stopped.status == {:stopped, :dead}

      Enum.each(post_events, fn event ->
        assert_raise Rig.StoppedError, fn -> Rig.crank(stopped, event) end
      end)
    end
  end

  # ===========================================================================
  # Invariant 7: Monotonicity — counters never decrease
  # ===========================================================================

  property "invariant: coins counter is monotonically non-decreasing" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      {_final, coins_history} =
        Enum.reduce(events, {Rig.new(Rig.Examples.Turnstile), [0]}, fn event, {m, history} ->
          new_m = Rig.crank(m, event)
          {new_m, [new_m.data.coins | history]}
        end)

      sorted = coins_history |> Enum.reverse()
      assert sorted == Enum.sort(sorted)
    end
  end

  # ===========================================================================
  # Invariant 8: on_enter fires exactly once per state change
  # ===========================================================================

  defmodule EnterCounter do
    use Rig

    @impl true
    def init(_), do: {:ok, :a, %{enters: 0, state_changes: 0}}

    @impl true
    def handle_event(:a, _, :go, data) do
      {:next_state, :b, %{data | state_changes: data.state_changes + 1}}
    end

    def handle_event(:b, _, :go, data) do
      {:next_state, :a, %{data | state_changes: data.state_changes + 1}}
    end

    def handle_event(_, _, :stay, _data), do: :keep_state_and_data

    @impl true
    def on_enter(_old, _new, data) do
      {:keep_state, %{data | enters: data.enters + 1}}
    end
  end

  property "invariant: on_enter fires exactly once per next_state, never on keep_state" do
    check all(events <- list_of(member_of([:go, :stay]), min_length: 1, max_length: @seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Rig.new(EnterCounter), fn event, m ->
          Rig.crank(m, event)
        end)

      assert machine.data.enters == machine.data.state_changes
    end
  end

  # ===========================================================================
  # Invariant 9: Turnstile — coin then push always passes
  # ===========================================================================

  property "invariant: coin then push always increments passes by 1" do
    check all(machine <- turnstile_in_random_state(), max_runs: @runs) do
      after_coin = Rig.crank(machine, :coin)
      assert after_coin.state == :unlocked

      passes_before = after_coin.data.passes
      after_push = Rig.crank(after_coin, :push)
      assert after_push.state == :locked
      assert after_push.data.passes == passes_before + 1
    end
  end

  # ===========================================================================
  # Invariant 10: crank! and crank agree on non-stop results
  # ===========================================================================

  property "invariant: crank! returns same machine as crank when not stopping" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine = Rig.new(Rig.Examples.Turnstile)

      {via_crank, via_bang} =
        Enum.reduce(events, {machine, machine}, fn event, {m1, m2} ->
          {Rig.crank(m1, event), Rig.crank!(m2, event)}
        end)

      assert via_crank.state == via_bang.state
      assert via_crank.data == via_bang.data
    end
  end

  # ===========================================================================
  # Invariant 11: Pure/process equivalence
  # ===========================================================================

  property "invariant: pure crank and Server produce identical state and data" do
    check all(events <- turnstile_event_sequence(100), max_runs: @runs) do
      # Pure path
      pure =
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      # Process path — send all events, then read final state via :sys
      {:ok, pid} = Rig.Server.start_link(Rig.Examples.Turnstile, [])
      Enum.each(events, &Rig.Server.cast(pid, &1))

      # Synchronize: :sys.get_state blocks until the mailbox is drained
      {process_state, %Rig.Server.Adapter{data: process_data}} = :sys.get_state(pid)
      GenServer.stop(pid)

      assert pure.state == process_state
      assert pure.data == process_data
    end
  end
end
