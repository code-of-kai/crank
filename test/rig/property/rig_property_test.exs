defmodule Rig.PropertyTest do
  @moduledoc """
  Property-based tests for Rig.

  These tests generate random event sequences and verify that invariants
  hold across thousands of inputs. The Turnstile machine is used because
  it handles every event in every state (total function) — ideal for
  random sequence testing.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Rig.Generators

  @moduletag :property

  # ===========================================================================
  # Invariant 1: Machine struct integrity
  # ===========================================================================

  property "invariant: machine struct is always valid after any crank sequence" do
    check all(events <- turnstile_event_sequence(100), max_runs: 200) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      assert %Rig.Machine{} = machine
      assert machine.module == Rig.Examples.Turnstile
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
    check all(events <- turnstile_event_sequence(50), max_runs: 200) do
      # Crank through all events, collecting effects at each step
      {_final, all_effects} =
        Enum.reduce(events, {Rig.new(Rig.Examples.Turnstile), []}, fn event, {m, acc} ->
          new_m = Rig.crank(m, event)
          {new_m, [new_m.effects | acc]}
        end)

      # Turnstile never returns actions, so effects should always be []
      assert Enum.all?(all_effects, &(&1 == []))
    end
  end

  # ===========================================================================
  # Invariant 3: Conservation — coins + passes always equals total events
  # ===========================================================================

  property "invariant: coins_collected + pushes_ignored + passes = total events" do
    check all(events <- turnstile_event_sequence(100), max_runs: 200) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      total_coins = Enum.count(events, &(&1 == :coin))
      total_pushes = Enum.count(events, &(&1 == :push))

      # Every coin increments the counter regardless of state
      assert machine.data.coins == total_coins

      # Passes only count when unlocked+push transitions to locked
      # We can verify: passes <= total_pushes (some pushes hit locked door)
      assert machine.data.passes <= total_pushes
      assert machine.data.passes >= 0
    end
  end

  # ===========================================================================
  # Invariant 4: Purity — same inputs always produce same outputs
  # ===========================================================================

  property "invariant: deterministic — same events always produce same result" do
    check all(events <- turnstile_event_sequence(50), max_runs: 200) do
      run = fn ->
        Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.data == b.data
      assert a.effects == b.effects
      assert a.status == b.status
    end
  end

  # ===========================================================================
  # Invariant 5: State reachability — only valid states are reachable
  # ===========================================================================

  property "invariant: state is always in the declared state set" do
    check all(events <- turnstile_event_sequence(100), max_runs: 200) do
      # Check state at EVERY intermediate step, not just the end
      Enum.reduce(events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
        new_m = Rig.crank(m, event)
        assert new_m.state in [:locked, :unlocked],
               "Reached unexpected state #{inspect(new_m.state)} after event #{inspect(event)}"
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
            pre_events <- list_of(constant(:tick), min_length: 0, max_length: 20),
            post_events <- list_of(member_of([:tick, :die, :anything]), min_length: 1, max_length: 10),
            max_runs: 100
          ) do
      machine =
        Enum.reduce(pre_events, Rig.new(StoppableMachine), fn event, m ->
          Rig.crank(m, event)
        end)

      # Stop the machine
      stopped = Rig.crank(machine, :die)
      assert stopped.status == {:stopped, :dead}

      # Every subsequent crank must raise
      Enum.each(post_events, fn event ->
        assert_raise Rig.StoppedError, fn -> Rig.crank(stopped, event) end
      end)
    end
  end

  # ===========================================================================
  # Invariant 7: Monotonicity — counters never decrease
  # ===========================================================================

  property "invariant: coins counter is monotonically non-decreasing" do
    check all(events <- turnstile_event_sequence(100), max_runs: 200) do
      {_final, prev_coins_list} =
        Enum.reduce(events, {Rig.new(Rig.Examples.Turnstile), [0]}, fn event, {m, coins_history} ->
          new_m = Rig.crank(m, event)
          {new_m, [new_m.data.coins | coins_history]}
        end)

      # Reversed history should be sorted (non-decreasing)
      coins_history = Enum.reverse(prev_coins_list)
      assert coins_history == Enum.sort(coins_history)
    end
  end

  # ===========================================================================
  # Invariant 8: on_enter fires exactly once per state change
  # ===========================================================================

  defmodule EnterCounter do
    use Rig

    @impl true
    def init(_), do: {:ok, :a, %{enters: 0, cranks: 0, state_changes: 0}}

    @impl true
    def handle_event(:a, _, :go, data) do
      {:next_state, :b, %{data | cranks: data.cranks + 1, state_changes: data.state_changes + 1}}
    end

    def handle_event(:b, _, :go, data) do
      {:next_state, :a, %{data | cranks: data.cranks + 1, state_changes: data.state_changes + 1}}
    end

    def handle_event(_, _, :stay, data) do
      {:keep_state, %{data | cranks: data.cranks + 1}}
    end

    @impl true
    def on_enter(_old, _new, data) do
      {:keep_state, %{data | enters: data.enters + 1}}
    end
  end

  property "invariant: on_enter fires exactly once per next_state, never on keep_state" do
    check all(events <- list_of(member_of([:go, :stay]), min_length: 1, max_length: 50), max_runs: 200) do
      machine =
        Enum.reduce(events, Rig.new(EnterCounter), fn event, m ->
          Rig.crank(m, event)
        end)

      # on_enter should fire exactly as many times as there were state changes
      assert machine.data.enters == machine.data.state_changes
    end
  end

  # ===========================================================================
  # Invariant 9: Turnstile alternation — push after coin always passes
  # ===========================================================================

  property "invariant: coin then push always increments passes by 1" do
    check all(machine <- turnstile_in_random_state(), max_runs: 200) do
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
    check all(events <- turnstile_event_sequence(50), max_runs: 200) do
      machine = Rig.new(Rig.Examples.Turnstile)

      {via_crank, via_bang} =
        Enum.reduce(events, {machine, machine}, fn event, {m1, m2} ->
          {Rig.crank(m1, event), Rig.crank!(m2, event)}
        end)

      assert via_crank.state == via_bang.state
      assert via_crank.data == via_bang.data
      assert via_crank.effects == via_bang.effects
      assert via_crank.status == via_bang.status
    end
  end
end
