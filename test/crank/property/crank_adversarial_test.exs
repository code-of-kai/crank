defmodule Crank.AdversarialTest do
  @moduledoc """
  Foul-mood tests. Written to expose divergences between pure and process
  modes, subtle gen_statem corners, and places the ergonomic property tests
  don't touch.

  Mix of unit and property tests. Unit tests target specific suspected bugs;
  properties generalize the invariants to random sequences.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :adversarial

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 1: same-state re-entry with empty wants should cancel pending timers
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Disarmable do
    @moduledoc false
    # Re-enters :armed with memory.armed toggled. wants/2 returns [] when
    # disarmed. If the Server fails to cancel the pending state timeout on
    # same-state re-entry, the timer fires and transitions to :went_off.
    use Crank

    def start(_), do: {:ok, :armed, %{armed: true}}

    def turn(:disarm, :armed, m), do: {:next, :armed, %{m | armed: false}}
    def turn(:arm, :armed, m), do: {:next, :armed, %{m | armed: true}}
    def turn(:timer_fired, :armed, m), do: {:next, :went_off, m}
    def turn(_, _, m), do: {:stay, m}

    def wants(:armed, %{armed: true}), do: [{:after, 30, :timer_fired}]
    def wants(:armed, _), do: []
    def wants(_, _), do: []
  end

  describe "same-state re-entry with empty wants" do
    test "pure: machine.wants is recomputed on {:next, same_state, new_memory}" do
      m = Crank.new(Disarmable)
      assert m.wants == [{:after, 30, :timer_fired}]

      m = Crank.turn(m, :disarm)
      assert m.state == :armed
      assert m.memory.armed == false
      assert m.wants == []
    end

    test "server: disarming cancels the pending state timeout" do
      {:ok, pid} = Crank.Server.start_link(Disarmable, [])
      Crank.Server.turn(pid, :disarm)

      # Wait past the original 30ms timer. If it was cancelled, we stay :armed.
      # If the Server didn't cancel it, the timer fires and transitions to :went_off.
      Process.sleep(80)

      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :armed,
             "same-state re-entry with empty wants did NOT cancel the pending timer; " <>
               "got state #{inspect(reading)}"
    end

    test "server: re-arming after disarming restarts the timer" do
      {:ok, pid} = Crank.Server.start_link(Disarmable, [])
      Crank.Server.turn(pid, :disarm)
      Process.sleep(80)
      # Confirm we're still :armed (timer was cancelled).
      assert Crank.Server.reading(pid) == :armed

      # Re-arm — timer should fire 30ms later.
      Crank.Server.turn(pid, :arm)
      Process.sleep(80)

      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :went_off,
             "re-arming did not restart the timer; got state #{inspect(reading)}"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 2: same-state re-entry with different wants should replace the timer
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Reconfigurable do
    @moduledoc false
    # Shortens the pending timeout by re-entering :armed with a new delay.
    use Crank

    def start(_), do: {:ok, :armed, %{delay: 500}}
    def turn({:configure, ms}, :armed, m), do: {:next, :armed, %{m | delay: ms}}
    def turn(:timer_fired, :armed, m), do: {:next, :went_off, m}
    def turn(_, _, m), do: {:stay, m}

    def wants(:armed, m), do: [{:after, m.delay, :timer_fired}]
    def wants(_, _), do: []
  end

  describe "same-state re-entry with different wants" do
    test "server: shortening the delay replaces the pending timer" do
      {:ok, pid} = Crank.Server.start_link(Reconfigurable, [])
      # Initial timer: 500ms. Reconfigure to 20ms — if the old timer isn't
      # replaced, we'll see :armed for 500ms.
      Crank.Server.turn(pid, {:configure, 20})
      Process.sleep(80)

      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :went_off,
             "reconfiguring the timer did not fire the new short timeout; " <>
               "got state #{inspect(reading)}"
    end

    test "server: lengthening the delay cancels the short timer" do
      defmodule Lengthenable do
        use Crank
        def start(_), do: {:ok, :armed, %{delay: 20}}
        def turn({:configure, ms}, :armed, m), do: {:next, :armed, %{m | delay: ms}}
        def turn(:timer_fired, :armed, m), do: {:next, :went_off, m}
        def turn(_, _, m), do: {:stay, m}
        def wants(:armed, m), do: [{:after, m.delay, :timer_fired}]
        def wants(_, _), do: []
      end

      {:ok, pid} = Crank.Server.start_link(Lengthenable, [])
      # Initial timer: 20ms. Reconfigure to 500ms before it fires.
      # If old timer isn't cancelled, we'll transition to :went_off.
      Crank.Server.turn(pid, {:configure, 500})
      Process.sleep(80)

      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :armed,
             "lengthening the timer did not cancel the old short timeout; " <>
               "got state #{inspect(reading)}"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 3: chained {:next, event} wants
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Chain do
    @moduledoc false
    use Crank

    def start(_), do: {:ok, :a, %{path: []}}

    def turn(event, state, m) do
      new_state = advance(state, event)
      {:next, new_state, %{m | path: [state | m.path]}}
    end

    defp advance(:a, :go), do: :b
    defp advance(:b, :continue), do: :c
    defp advance(:c, :continue), do: :d
    defp advance(:d, :continue), do: :e
    defp advance(s, _), do: s

    def wants(s, _) when s in [:b, :c, :d], do: [{:next, :continue}]
    def wants(_, _), do: []
  end

  describe "chained :next wants" do
    test "server: a → b → c → d → e via single :go event" do
      {:ok, pid} = Crank.Server.start_link(Chain, [])
      Crank.Server.turn(pid, :go)

      # Chain fully unrolls via :next wants before any new external event.
      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :e,
             "chain did not fully unroll; stopped at #{inspect(reading)}"
    end

    test "pure: single turn stops at :b (wants are inert data)" do
      m = Crank.new(Chain) |> Crank.turn(:go)
      assert m.state == :b
      assert m.wants == [{:next, :continue}]
    end

    test "pure: manually draining :next wants matches process behavior" do
      m = Crank.new(Chain) |> Crank.turn(:go) |> drain_next()
      assert m.state == :e
    end

    defp drain_next(%Crank{wants: wants} = m) do
      case Enum.find(wants, &match?({:next, _}, &1)) do
        {:next, event} -> m |> Crank.turn(event) |> drain_next()
        nil -> m
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 4: wants/2 is called with NEW state and memory, not old
  # ──────────────────────────────────────────────────────────────────────────

  describe "wants/2 arguments" do
    test "wants receives the NEW state and memory after {:next, ...}" do
      defmodule WantsRecorder do
        use Crank
        def start(_), do: {:ok, :a, %{seen: []}}
        def turn(:go, :a, m), do: {:next, :b, %{m | seen: [:in_turn | m.seen]}}
        def turn(_, _, m), do: {:stay, m}

        def wants(:b, m) do
          # If wants sees the NEW memory (with :in_turn prepended), this list
          # will contain :in_turn. If it sees the OLD memory, it won't.
          send(self(), {:wants_saw, m.seen})
          []
        end

        def wants(_, _), do: []
      end

      m = Crank.new(WantsRecorder) |> Crank.turn(:go)
      assert_received {:wants_saw, [:in_turn]}
      assert m.state == :b
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 5: reading/1 does not advance, does not call turn/3
  # ──────────────────────────────────────────────────────────────────────────

  describe "reading is truly read-only" do
    defmodule NoisyTurn do
      use Crank
      def start(_), do: {:ok, :idle, %{turns: 0}}
      def turn(_event, _state, m), do: {:next, :idle, %{m | turns: m.turns + 1}}
      def reading(_state, m), do: m.turns
    end

    property "reading/1 never increments the turn counter" do
      check all(n <- integer(1..50), max_runs: 200) do
        {:ok, pid} = Crank.Server.start_link(NoisyTurn, [])

        # Call reading n times
        readings = for _ <- 1..n, do: Crank.Server.reading(pid)

        # All readings should be 0 — no turn/3 was called.
        assert Enum.all?(readings, &(&1 == 0))

        Crank.Server.stop(pid)
      end
    end

    property "pure: Crank.reading/1 does not mutate the struct" do
      check all(n <- integer(1..100), max_runs: 200) do
        m = Crank.new(NoisyTurn)
        original = m.memory

        for _ <- 1..n do
          _ = Crank.reading(m)
        end

        assert m.memory == original
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 6: pure machine.wants always equals module.wants(state, memory)
  # ──────────────────────────────────────────────────────────────────────────

  describe "pure core invariant" do
    property "machine.wants always equals module.wants(state, memory)" do
      events = one_of([:arm, :disarm, :noop])

      check all(sequence <- list_of(events, min_length: 0, max_length: 100), max_runs: 2_000) do
        machine =
          Enum.reduce(sequence, Crank.new(Disarmable), fn event, m ->
            Crank.turn(m, event)
          end)

        # The struct field is a materialised cache of the pure callback.
        # Never drifts. Always in sync.
        assert machine.wants == Disarmable.wants(machine.state, machine.memory)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 7: pure and process memory diverge after same-state re-entry runs
  # ──────────────────────────────────────────────────────────────────────────

  describe "pure/process equivalence under same-state re-entry" do
    property "random arm/disarm sequences end with same state and memory" do
      events = one_of([:arm, :disarm])

      check all(sequence <- list_of(events, min_length: 1, max_length: 50), max_runs: 500) do
        pure =
          Enum.reduce(sequence, Crank.new(Disarmable), fn event, m ->
            Crank.turn(m, event)
          end)

        {:ok, pid} = Crank.Server.start_link(Disarmable, [])
        Enum.each(sequence, &Crank.Server.cast(pid, &1))

        # Drain the mailbox — :sys.get_state is synchronous.
        {process_state, %Crank.Server.Adapter{memory: process_memory}} = :sys.get_state(pid)
        Crank.Server.stop(pid)

        assert pure.state == process_state
        assert pure.memory == process_memory
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 8: stopped engine is absorbing — every further turn raises
  # ──────────────────────────────────────────────────────────────────────────

  describe "stopped engine" do
    defmodule OneShot do
      use Crank
      def start(_), do: {:ok, :live, %{}}
      def turn(:die, :live, m), do: {:stop, :normal, m}
      def turn(_, _, m), do: {:stay, m}
    end

    property "after {:stop, ...}, every subsequent turn raises StoppedError" do
      # Narrow generator: atom events only. `term()` generates huge nested
      # terms that starve the property within its 60-second budget.
      event_gen = one_of([atom(:alphanumeric), integer(), {:"$tag", integer()}])

      check all(events <- list_of(event_gen, min_length: 1, max_length: 20), max_runs: 500) do
        stopped = Crank.new(OneShot) |> Crank.turn(:die)
        assert match?({:off, _}, stopped.engine)

        Enum.each(events, fn event ->
          assert_raise Crank.StoppedError, fn -> Crank.turn(stopped, event) end
        end)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 9: {:send, dest, msg} wants deliver the message
  # ──────────────────────────────────────────────────────────────────────────

  describe "send wants" do
    defmodule Broadcaster do
      use Crank
      def start(opts), do: {:ok, :idle, %{sub: opts[:sub]}}
      def turn(:announce, :idle, m), do: {:next, :announcing, m}
      def turn(_, _, m), do: {:stay, m}
      def wants(:announcing, m), do: [{:send, m.sub, :announcement}]
      def wants(_, _), do: []
    end

    test "server: send wants deliver the message to the target process" do
      parent = self()
      {:ok, pid} = Crank.Server.start_link(Broadcaster, sub: parent)

      Crank.Server.turn(pid, :announce)
      assert_receive :announcement, 200

      Crank.Server.stop(pid)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 10: crash inside turn/3 terminates the gen_statem cleanly
  # ──────────────────────────────────────────────────────────────────────────

  describe "turn/3 crash" do
    defmodule Crasher do
      use Crank
      def start(_), do: {:ok, :idle, %{}}
      def turn(:boom, :idle, _m), do: raise("kaboom")
      def turn(_, _, m), do: {:stay, m}
    end

    test "raised exception inside turn/3 terminates the server" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Crank.Server.start_link(Crasher, [])
      ref = Process.monitor(pid)

      # Fire-and-forget crash
      Crank.Server.cast(pid, :boom)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 11: wants interpreter rejects unknown shapes
  # ──────────────────────────────────────────────────────────────────────────

  describe "unknown want shapes" do
    defmodule BadWants do
      use Crank
      def start(_), do: {:ok, :idle, %{}}
      def turn(_, _, m), do: {:stay, m}
      # Malformed want: unknown tag.
      def wants(:idle, _), do: [{:totally_made_up, 1, 2, 3}]
      def wants(_, _), do: []
    end

    test "server: unknown want raises ArgumentError during init" do
      Process.flag(:trap_exit, true)

      # init/1 calls wants_actions; an unknown want should crash the process.
      result =
        try do
          Crank.Server.start_link(BadWants, [])
        catch
          :exit, reason -> {:exit, reason}
        end

      case result do
        {:error, _} -> :ok
        {:exit, _} -> :ok
        {:ok, pid} -> flunk("expected startup to fail; got running pid #{inspect(pid)}")
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 12: can_turn?/2 must not silence nested FunctionClauseError
  # ──────────────────────────────────────────────────────────────────────────

  describe "can_turn? FCE origin check" do
    defmodule NestedFCE do
      use Crank

      def start(_), do: {:ok, :idle, %{}}

      # :go is handled, but the handler calls a helper that raises a FCE
      # for a bad argument. can_turn? must NOT swallow that helper's FCE
      # and falsely report the event unhandled.
      def turn(:go, :idle, m) do
        _ = buggy_helper(:not_one)
        {:stay, m}
      end

      defp buggy_helper(:one), do: :ok
    end

    test "reraises FCE from helpers called inside turn/3" do
      machine = Crank.new(NestedFCE)

      assert_raise FunctionClauseError, fn ->
        Crank.can_turn?(machine, :go)
      end
    end

    test "returns false only when the FCE is raised from module.turn/3 itself" do
      machine = Crank.new(NestedFCE)
      refute Crank.can_turn?(machine, :never_handled)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 13: [:crank, :exception] telemetry fires when turn/3 raises
  # ──────────────────────────────────────────────────────────────────────────

  describe "[:crank, :exception] telemetry" do
    defmodule RaisesOnBoom do
      use Crank
      def start(_), do: {:ok, :idle, %{}}
      def turn(:boom, :idle, _m), do: raise("kaboom")
      def turn(_, _, m), do: {:stay, m}
    end

    test "emits :crank, :exception before the process dies" do
      Process.flag(:trap_exit, true)
      ref = make_ref()
      parent = self()
      handler_id = "test-exception-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:crank, :exception],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      {:ok, pid} = Crank.Server.start_link(RaisesOnBoom, [])
      mon = Process.monitor(pid)

      Crank.Server.cast(pid, :boom)

      assert_receive {^ref, [:crank, :exception], %{system_time: _},
                      %{module: RaisesOnBoom, state: :idle, event: :boom, kind: :error,
                        reason: %RuntimeError{message: "kaboom"}}}, 500

      assert_receive {:DOWN, ^mon, :process, ^pid, _}, 500

      :telemetry.detach(handler_id)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Suspect 14: named timeouts fire independently
  # ──────────────────────────────────────────────────────────────────────────

  describe "named timeouts" do
    defmodule TwoTimers do
      use Crank

      def start(_), do: {:ok, :armed, %{}}

      def turn(:short_fired, :armed, m), do: {:next, :short_went, m}
      def turn(:long_fired, :armed, m), do: {:next, :long_went, m}
      def turn(_, _, m), do: {:stay, m}

      def wants(:armed, _m) do
        [
          {:after, :short, 30, :short_fired},
          {:after, :long, 200, :long_fired}
        ]
      end

      def wants(_s, _m), do: []
    end

    test "two named timers on the same state fire independently (short wins)" do
      {:ok, pid} = Crank.Server.start_link(TwoTimers, [])

      # Short fires at 30ms → transitions to :short_went. The :long timer
      # is not auto-cancelled by gen_statem (named timeouts persist across
      # state changes), but it has nothing to fire on from :short_went.
      Process.sleep(80)
      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :short_went,
             "short named timer did not fire first; got #{inspect(reading)}"
    end
  end

  describe "cancel named timeout" do
    defmodule CancelableTimer do
      use Crank

      def start(_), do: {:ok, :armed, %{armed: true}}

      def turn(:disarm, :armed, m), do: {:next, :armed, %{m | armed: false}}
      def turn(:fired, :armed, m), do: {:next, :went_off, m}
      def turn(_, _, m), do: {:stay, m}

      def wants(:armed, %{armed: true}), do: [{:after, :shot, 30, :fired}]
      def wants(:armed, %{armed: false}), do: [{:cancel, :shot}]
      def wants(_, _), do: []
    end

    test "{:cancel, name} cancels a named timer before it fires" do
      {:ok, pid} = Crank.Server.start_link(CancelableTimer, [])
      Crank.Server.turn(pid, :disarm)
      Process.sleep(80)

      reading = Crank.Server.reading(pid)
      Crank.Server.stop(pid)

      assert reading == :armed,
             "named timer was not cancelled; got #{inspect(reading)}"
    end
  end
end
