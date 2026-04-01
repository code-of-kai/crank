defmodule Rig.PropertyTest do
  @moduledoc """
  Property-based tests for Rig.

  13 invariants. 10 pure (10,000 runs × up to 1,000 events each),
  3 process (1,000–10,000 runs). ~12 seconds, ~50M random cranks.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Rig.Generators

  @moduletag :property

  @runs 10_000
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

  # ===========================================================================
  # Invariant 12: Multi-sender conservation (Joe Armstrong #1)
  # ===========================================================================

  property "invariant: conservation holds regardless of sender interleaving" do
    check all(
            # Generate events split across N senders
            sender_count <- integer(2..8),
            events_per_sender <- integer(5..30),
            max_runs: 1_000
          ) do
      {:ok, pid} = Rig.Server.start_link(Rig.Examples.Turnstile, [])

      # Each sender gets a random event list and fires concurrently
      senders =
        for _ <- 1..sender_count do
          events = for _ <- 1..events_per_sender, do: Enum.random([:coin, :push])

          Task.async(fn ->
            Enum.each(events, fn event ->
              Rig.Server.cast(pid, event)
            end)

            events
          end)
        end

      all_events = Task.await_many(senders) |> List.flatten()

      # Drain the mailbox
      {_state, %Rig.Server.Adapter{data: data}} = :sys.get_state(pid)
      GenServer.stop(pid)

      # Conservation: total coins == total coin events regardless of interleaving
      total_coins = Enum.count(all_events, &(&1 == :coin))
      assert data.coins == total_coins

      # Passes bounded by total pushes
      total_pushes = Enum.count(all_events, &(&1 == :push))
      assert data.passes <= total_pushes
      assert data.passes >= 0
    end
  end

  # ===========================================================================
  # Invariant 13: Restart equivalence (Joe Armstrong #2)
  # ===========================================================================

  property "invariant: restarted server is indistinguishable from a fresh one" do
    check all(
            pre_events <- turnstile_event_sequence(50),
            post_events <- turnstile_event_sequence(50),
            max_runs: 1_000
          ) do
      # Start, crank some events, then kill the process
      {:ok, pid} = Rig.Server.start_link(Rig.Examples.Turnstile, [])
      Enum.each(pre_events, &Rig.Server.cast(pid, &1))
      :sys.get_state(pid)
      GenServer.stop(pid)

      # Start fresh, send only the post_events
      {:ok, fresh_pid} = Rig.Server.start_link(Rig.Examples.Turnstile, [])
      Enum.each(post_events, &Rig.Server.cast(fresh_pid, &1))

      {fresh_state, %Rig.Server.Adapter{data: fresh_data}} = :sys.get_state(fresh_pid)
      GenServer.stop(fresh_pid)

      # Compare with pure path (fresh machine + post_events only)
      pure =
        Enum.reduce(post_events, Rig.new(Rig.Examples.Turnstile), fn event, m ->
          Rig.crank(m, event)
        end)

      # Restarted server must match a fresh machine — no leaked state
      assert pure.state == fresh_state
      assert pure.data == fresh_data
    end
  end

  # ===========================================================================
  # Order machine properties (complex, 5 states, 8 events, effects, on_enter)
  # ===========================================================================

  property "invariant: Order state is always in the declared state set" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Rig.new(Rig.Examples.Order), fn event, m ->
        new_m = Rig.crank(m, event)
        assert new_m.state in Rig.Examples.Order.states()
        new_m
      end)
    end
  end

  property "invariant: Order transitions counter equals actual state changes" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Order), fn event, m ->
          Rig.crank(m, event)
        end)

      # on_enter logs every transition — its length must equal transitions count
      assert length(machine.data.enter_log) == machine.data.transitions
    end
  end

  property "invariant: Order on_enter log records correct from→to pairs" do
    check all(events <- order_event_sequence(200), max_runs: @runs) do
      machine =
        Enum.reduce(events, Rig.new(Rig.Examples.Order), fn event, m ->
          Rig.crank(m, event)
        end)

      # Every entry in enter_log should have valid states
      valid = Rig.Examples.Order.states()

      Enum.each(machine.data.enter_log, fn {from, to} ->
        assert from in valid, "on_enter from #{inspect(from)} not in valid states"
        assert to in valid, "on_enter to #{inspect(to)} not in valid states"
      end)
    end
  end

  property "invariant: Order cancelled is absorbing — no escape once cancelled" do
    check all(
            pre <- order_event_sequence(100),
            post <- order_event_sequence(100),
            max_runs: @runs
          ) do
      # Crank until we hit cancelled (force it with a :cancel at the end)
      machine =
        Enum.reduce(pre ++ [:cancel], Rig.new(Rig.Examples.Order), fn event, m ->
          Rig.crank(m, event)
        end)

      if machine.state == :cancelled do
        # Every subsequent crank should stay cancelled
        final =
          Enum.reduce(post, machine, fn event, m ->
            Rig.crank(m, event)
          end)

        assert final.state == :cancelled
      end
    end
  end

  property "invariant: Order pure/process equivalence (complex machine)" do
    check all(events <- order_event_sequence(100), max_runs: 1_000) do
      pure =
        Enum.reduce(events, Rig.new(Rig.Examples.Order), fn event, m ->
          Rig.crank(m, event)
        end)

      {:ok, pid} = Rig.Server.start_link(Rig.Examples.Order, [])
      Enum.each(events, &Rig.Server.cast(pid, &1))

      {process_state, %Rig.Server.Adapter{data: process_data}} = :sys.get_state(pid)
      GenServer.stop(pid)

      assert pure.state == process_state
      assert pure.data.order_id == process_data.order_id
      assert pure.data.total == process_data.total
      assert pure.data.transitions == process_data.transitions
      assert pure.data.notes == process_data.notes
    end
  end

  property "invariant: Order determinism across complex event sequences" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      run = fn ->
        Enum.reduce(events, Rig.new(Rig.Examples.Order), fn event, m ->
          Rig.crank(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.data == b.data
      assert a.effects == b.effects
    end
  end
end
