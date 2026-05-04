defmodule Crank.MachineInvariantsTest do
  @moduledoc """
  Property-based tests for Crank. ~60M random turns across the suite.
  Fixtures are local; global examples live in `test/support/examples.ex`.

  This module name avoids collision with `Crank.PropertyTest` — the public
  helper module (Phase 2.3) that bridges `Crank.PurityTrace` with StreamData
  for user-facing purity property tests.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crank.Generators

  @moduletag :property

  @runs 10_000
  @seq 1000

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 1: Machine struct integrity
  # ──────────────────────────────────────────────────────────────────────────

  property "machine struct is always valid after any turn sequence" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
          Crank.turn(m, event)
        end)

      assert %Crank{} = machine
      assert machine.state in [:locked, :unlocked]
      assert is_map(machine.memory)
      assert is_list(machine.wants)
      assert machine.engine == :running
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 2: Turnstile declares no wants — struct.wants is always []
  # ──────────────────────────────────────────────────────────────────────────

  property "Turnstile wants is always empty (no wants/2 defined)" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
        new_m = Crank.turn(m, event)
        assert new_m.wants == []
        new_m
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 3: Conservation — coins always equals total coin events
  # ──────────────────────────────────────────────────────────────────────────

  property "coin count equals total coin events" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
          Crank.turn(m, event)
        end)

      assert machine.memory.coins == Enum.count(events, &(&1 == :coin))
      assert machine.memory.passes <= Enum.count(events, &(&1 == :push))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 4: Purity — same inputs always produce same outputs
  # ──────────────────────────────────────────────────────────────────────────

  property "deterministic — same events always produce same result" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      run = fn ->
        Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
          Crank.turn(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.memory == b.memory
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 5: State reachability — only valid states at every step
  # ──────────────────────────────────────────────────────────────────────────

  property "state is always in the declared state set" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
        new_m = Crank.turn(m, event)
        assert new_m.state in [:locked, :unlocked]
        new_m
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 6: Stopped is terminal
  # ──────────────────────────────────────────────────────────────────────────

  defmodule StoppableMachine do
    use Crank

    @impl true
    def start(_), do: {:ok, :alive, %{ticks: 0}}

    @impl true
    def turn(:tick, :alive, m), do: {:stay, %{m | ticks: m.ticks + 1}}
    def turn(:die, :alive, m), do: {:stop, :dead, m}
  end

  property "once stopped, every subsequent turn raises StoppedError" do
    check all(
            pre_events <- list_of(constant(:tick), min_length: 0, max_length: 100),
            post_events <- list_of(member_of([:tick, :die, :anything]), min_length: 1, max_length: 20),
            max_runs: @runs
          ) do
      machine =
        Enum.reduce(pre_events, Crank.new(StoppableMachine), fn event, m ->
          Crank.turn(m, event)
        end)

      stopped = Crank.turn(machine, :die)
      assert stopped.engine == {:off, :dead}

      Enum.each(post_events, fn event ->
        assert_raise Crank.StoppedError, fn -> Crank.turn(stopped, event) end
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 7: Monotonicity — counters never decrease
  # ──────────────────────────────────────────────────────────────────────────

  property "coins counter is monotonically non-decreasing" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      {_final, coins_history} =
        Enum.reduce(events, {Crank.new(Crank.Examples.Turnstile), [0]}, fn event, {m, history} ->
          new_m = Crank.turn(m, event)
          {new_m, [new_m.memory.coins | history]}
        end)

      sorted = Enum.reverse(coins_history)
      assert sorted == Enum.sort(sorted)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 8: Turnstile — coin then push always passes
  # ──────────────────────────────────────────────────────────────────────────

  property "coin then push always increments passes by 1" do
    check all(machine <- turnstile_in_random_state(), max_runs: @runs) do
      after_coin = Crank.turn(machine, :coin)
      assert after_coin.state == :unlocked

      passes_before = after_coin.memory.passes
      after_push = Crank.turn(after_coin, :push)
      assert after_push.state == :locked
      assert after_push.memory.passes == passes_before + 1
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 9: turn! and turn agree on non-stop results
  # ──────────────────────────────────────────────────────────────────────────

  property "turn! returns same machine as turn when not stopping" do
    check all(events <- turnstile_event_sequence(@seq), max_runs: @runs) do
      machine = Crank.new(Crank.Examples.Turnstile)

      {via_turn, via_bang} =
        Enum.reduce(events, {machine, machine}, fn event, {m1, m2} ->
          {Crank.turn(m1, event), Crank.turn!(m2, event)}
        end)

      assert via_turn.state == via_bang.state
      assert via_turn.memory == via_bang.memory
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 10: Pure/process equivalence
  # ──────────────────────────────────────────────────────────────────────────

  property "pure turn and Server produce identical state and memory" do
    check all(events <- turnstile_event_sequence(100), max_runs: @runs) do
      pure =
        Enum.reduce(events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
          Crank.turn(m, event)
        end)

      {:ok, pid} = Crank.Server.start_link(Crank.Examples.Turnstile, [])
      Enum.each(events, &Crank.Server.cast(pid, &1))

      # :sys.get_state synchronizes — mailbox is drained before it returns.
      {process_state, %Crank.Server.Adapter{memory: process_memory}} = :sys.get_state(pid)
      Crank.Server.stop(pid)

      assert pure.state == process_state
      assert pure.memory == process_memory
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 11: Multi-sender conservation
  # ──────────────────────────────────────────────────────────────────────────

  property "conservation holds regardless of sender interleaving" do
    check all(
            sender_count <- integer(2..8),
            events_per_sender <- integer(5..30),
            max_runs: @runs
          ) do
      {:ok, pid} = Crank.Server.start_link(Crank.Examples.Turnstile, [])

      senders =
        for _ <- 1..sender_count do
          events = for _ <- 1..events_per_sender, do: Enum.random([:coin, :push])

          Task.async(fn ->
            Enum.each(events, fn event -> Crank.Server.cast(pid, event) end)
            events
          end)
        end

      all_events = Task.await_many(senders) |> List.flatten()

      {_state, %Crank.Server.Adapter{memory: memory}} = :sys.get_state(pid)
      Crank.Server.stop(pid)

      total_coins = Enum.count(all_events, &(&1 == :coin))
      assert memory.coins == total_coins

      total_pushes = Enum.count(all_events, &(&1 == :push))
      assert memory.passes <= total_pushes
      assert memory.passes >= 0
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Invariant 12: Restart equivalence
  # ──────────────────────────────────────────────────────────────────────────

  property "restarted server is indistinguishable from a fresh one" do
    check all(
            pre_events <- turnstile_event_sequence(50),
            post_events <- turnstile_event_sequence(50),
            max_runs: @runs
          ) do
      {:ok, pid} = Crank.Server.start_link(Crank.Examples.Turnstile, [])
      Enum.each(pre_events, &Crank.Server.cast(pid, &1))
      :sys.get_state(pid)
      Crank.Server.stop(pid)

      {:ok, fresh_pid} = Crank.Server.start_link(Crank.Examples.Turnstile, [])
      Enum.each(post_events, &Crank.Server.cast(fresh_pid, &1))

      {fresh_state, %Crank.Server.Adapter{memory: fresh_memory}} = :sys.get_state(fresh_pid)
      Crank.Server.stop(fresh_pid)

      pure =
        Enum.reduce(post_events, Crank.new(Crank.Examples.Turnstile), fn event, m ->
          Crank.turn(m, event)
        end)

      assert pure.state == fresh_state
      assert pure.memory == fresh_memory
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Order machine properties
  # ──────────────────────────────────────────────────────────────────────────

  property "Order state is always in the declared state set" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Crank.new(Crank.Examples.Order), fn event, m ->
        new_m = Crank.turn(m, event)
        assert new_m.state in Crank.Examples.Order.states()
        new_m
      end)
    end
  end

  property "Order wants matches the state it's in" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Crank.new(Crank.Examples.Order), fn event, m ->
          Crank.turn(m, event)
        end)

      # Moore invariant: when wants is populated, it equals what the state declares.
      case machine.wants do
        [] ->
          :ok

        wants ->
          assert wants == Crank.Examples.Order.wants(machine.state, machine.memory)
      end
    end
  end

  property "Order cancelled is absorbing — no escape once cancelled" do
    check all(
            pre <- order_event_sequence(100),
            post <- order_event_sequence(100),
            max_runs: @runs
          ) do
      machine =
        Enum.reduce(pre ++ [:cancel], Crank.new(Crank.Examples.Order), fn event, m ->
          Crank.turn(m, event)
        end)

      if machine.state == :cancelled do
        final = Enum.reduce(post, machine, fn event, m -> Crank.turn(m, event) end)
        assert final.state == :cancelled
      end
    end
  end

  property "Order pure/process equivalence" do
    check all(events <- order_event_sequence(100), max_runs: @runs) do
      pure =
        Enum.reduce(events, Crank.new(Crank.Examples.Order), fn event, m ->
          Crank.turn(m, event)
        end)

      {:ok, pid} = Crank.Server.start_link(Crank.Examples.Order, [])
      Enum.each(events, &Crank.Server.cast(pid, &1))

      {process_state, %Crank.Server.Adapter{memory: process_memory}} = :sys.get_state(pid)
      Crank.Server.stop(pid)

      assert pure.state == process_state
      assert pure.memory.order_id == process_memory.order_id
      assert pure.memory.total == process_memory.total
      assert pure.memory.transitions == process_memory.transitions
      assert pure.memory.notes == process_memory.notes
    end
  end

  property "Order determinism across complex event sequences" do
    check all(events <- order_event_sequence(@seq), max_runs: @runs) do
      run = fn ->
        Enum.reduce(events, Crank.new(Crank.Examples.Order), fn event, m ->
          Crank.turn(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.memory == b.memory
      assert a.wants == b.wants
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Submission machine properties (struct-per-state)
  # ──────────────────────────────────────────────────────────────────────────

  alias Crank.Examples.Submission.{Validating, Quoted, Bound, Declined}

  @submission_structs [Validating, Quoted, Bound, Declined]

  property "Submission state is always one of the 4 struct types" do
    check all(events <- submission_event_sequence(@seq), max_runs: @runs) do
      Enum.reduce(events, Crank.new(Crank.Examples.Submission), fn event, m ->
        new_m = Crank.turn(m, event)
        assert new_m.state.__struct__ in @submission_structs
        new_m
      end)
    end
  end

  property "Submission illegal states are unrepresentable" do
    check all(events <- submission_event_sequence(@seq), max_runs: @runs) do
      machine =
        Enum.reduce(events, Crank.new(Crank.Examples.Submission), fn event, m ->
          Crank.turn(m, event)
        end)

      state = machine.state

      case state do
        %Validating{} ->
          refute Map.has_key?(state, :quotes)
          refute Map.has_key?(state, :quote)
          refute Map.has_key?(state, :reason)

        %Quoted{} ->
          refute Map.has_key?(state, :violations)
          refute Map.has_key?(state, :quote)
          refute Map.has_key?(state, :reason)

        %Bound{} ->
          refute Map.has_key?(state, :violations)
          refute Map.has_key?(state, :quotes)
          refute Map.has_key?(state, :reason)

        %Declined{} ->
          refute Map.has_key?(state, :violations)
          refute Map.has_key?(state, :quotes)
          refute Map.has_key?(state, :quote)
      end
    end
  end

  property "Submission Declined is absorbing — no escape once declined" do
    check all(
            pre <- submission_event_sequence(100),
            post <- submission_event_sequence(100),
            max_runs: @runs
          ) do
      machine =
        Enum.reduce(pre ++ [:decline], Crank.new(Crank.Examples.Submission), fn event, m ->
          Crank.turn(m, event)
        end)

      if match?(%Declined{}, machine.state) do
        final = Enum.reduce(post, machine, fn event, m -> Crank.turn(m, event) end)
        assert %Declined{} = final.state
      end
    end
  end

  property "Submission Bound is absorbing — no escape once bound" do
    check all(events <- submission_event_sequence(@seq), max_runs: @runs) do
      {_final, saw_bound_escape} =
        Enum.reduce(events, {Crank.new(Crank.Examples.Submission), false}, fn event, {m, escaped} ->
          was_bound = match?(%Bound{}, m.state)
          new_m = Crank.turn(m, event)
          now_not_bound = not match?(%Bound{}, new_m.state)
          {new_m, escaped or (was_bound and now_not_bound)}
        end)

      refute saw_bound_escape
    end
  end

  property "Submission determinism across complex event sequences" do
    check all(events <- submission_event_sequence(@seq), max_runs: @runs) do
      run = fn ->
        Enum.reduce(events, Crank.new(Crank.Examples.Submission), fn event, m ->
          Crank.turn(m, event)
        end)
      end

      a = run.()
      b = run.()

      assert a.state == b.state
      assert a.memory == b.memory
    end
  end

  property "Submission pure/process equivalence with struct states" do
    check all(events <- submission_event_sequence(100), max_runs: @runs) do
      pure =
        Enum.reduce(events, Crank.new(Crank.Examples.Submission), fn event, m ->
          Crank.turn(m, event)
        end)

      {:ok, pid} = Crank.Server.start_link(Crank.Examples.Submission, [])
      Enum.each(events, &Crank.Server.cast(pid, &1))

      {process_state, %Crank.Server.Adapter{memory: process_memory}} = :sys.get_state(pid)
      Crank.Server.stop(pid)

      assert pure.state == process_state
      assert pure.memory.parameters == process_memory.parameters
    end
  end
end
