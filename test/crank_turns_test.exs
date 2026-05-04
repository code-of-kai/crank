defmodule Crank.TurnsTest do
  use ExUnit.Case, async: true
  doctest Crank.Turns

  alias Crank.Examples.Door
  alias Crank.Turns

  # ──────────────────────────────────────────────────────────────────────────
  # Test fixtures — machines that exercise non-default turn results
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Stoppable do
    @moduledoc false
    use Crank

    @impl true
    def start(_), do: {:ok, :live, %{value: 0}}

    @impl true
    def turn(:go, :live, memory), do: {:next, :running, memory}
    def turn(:bump, _state, memory), do: {:stay, %{memory | value: memory.value + 1}}
    def turn({:stop, reason}, state, memory) when state in [:live, :running] do
      {:stop, reason, memory}
    end
  end

  defmodule Raiser do
    @moduledoc false
    use Crank

    @impl true
    def start(_), do: {:ok, :idle, %{}}

    @impl true
    def turn(:boom, :idle, _memory), do: raise "user bug in turn/3"
    def turn(_event, _state, memory), do: {:stay, memory}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Builder
  # ──────────────────────────────────────────────────────────────────────────

  describe "new/0" do
    test "returns an empty descriptor" do
      assert Turns.new() == %Turns{steps: []}
    end
  end

  describe "turn/4" do
    test "appends one step" do
      machine = Crank.new(Door)
      turns = Turns.new() |> Turns.turn(:front, machine, :unlock)

      assert turns.steps == [{:front, machine, :unlock}]
    end

    test "preserves insertion order" do
      m = Crank.new(Door)

      turns =
        Turns.new()
        |> Turns.turn(:a, m, :unlock)
        |> Turns.turn(:b, m, :unlock)
        |> Turns.turn(:c, m, :unlock)

      assert Turns.names(turns) == [:a, :b, :c]
    end

    test "accepts a function machine resolver" do
      machine = Crank.new(Door)
      resolver = fn _results -> machine end

      turns = Turns.new() |> Turns.turn(:a, resolver, :unlock)

      assert turns.steps == [{:a, resolver, :unlock}]
    end

    test "accepts a function event resolver" do
      machine = Crank.new(Door)
      resolver = fn _results -> :unlock end

      turns = Turns.new() |> Turns.turn(:a, machine, resolver)

      assert turns.steps == [{:a, machine, resolver}]
    end

    test "accepts any term for event (literal)" do
      machine = Crank.new(Door)
      turns = Turns.new() |> Turns.turn(:a, machine, {:coin, 25})

      assert turns.steps == [{:a, machine, {:coin, 25}}]
    end

    test "raises on duplicate name" do
      m = Crank.new(Door)
      turns = Turns.new() |> Turns.turn(:same, m, :unlock)

      assert_raise ArgumentError, ~r/duplicate step name :same/, fn ->
        Turns.turn(turns, :same, m, :unlock)
      end
    end

    test "accepts a non-%Crank{} non-function machine at build time" do
      # The descriptor is shared between pure and process executors. The
      # process executor expects pids or names, not %Crank{}, so the builder
      # accepts any value. Pure-mode validation is deferred to apply time.
      turns = Turns.turn(Turns.new(), :later, :some_registered_name, :event)

      assert turns.steps == [{:later, :some_registered_name, :event}]
    end

    test "raises on function machine with wrong arity (zero)" do
      assert_raise ArgumentError,
                   ~r/machine function must have arity 1, got arity 0/,
                   fn ->
                     Turns.turn(Turns.new(), :bad, fn -> :wrong end, :event)
                   end
    end

    test "raises on function machine with wrong arity (two)" do
      assert_raise ArgumentError,
                   ~r/machine function must have arity 1, got arity 2/,
                   fn ->
                     Turns.turn(Turns.new(), :bad, fn _a, _b -> :wrong end, :event)
                   end
    end
  end

  describe "append/2" do
    test "concatenates steps in order" do
      m = Crank.new(Door)
      a = Turns.new() |> Turns.turn(:x, m, :unlock)
      b = Turns.new() |> Turns.turn(:y, m, :unlock) |> Turns.turn(:z, m, :unlock)

      merged = Turns.append(a, b)

      assert Turns.names(merged) == [:x, :y, :z]
    end

    test "handles empty left" do
      m = Crank.new(Door)
      a = Turns.new()
      b = Turns.new() |> Turns.turn(:y, m, :unlock)

      assert Turns.append(a, b) == b
    end

    test "handles empty right" do
      m = Crank.new(Door)
      a = Turns.new() |> Turns.turn(:x, m, :unlock)

      assert Turns.append(a, Turns.new()) == a
    end

    test "raises on overlapping names" do
      m = Crank.new(Door)
      a = Turns.new() |> Turns.turn(:shared, m, :unlock)
      b = Turns.new() |> Turns.turn(:shared, m, :unlock)

      assert_raise ArgumentError, ~r/appear in both descriptors.*:shared/, fn ->
        Turns.append(a, b)
      end
    end
  end

  describe "to_list/1 and names/1" do
    test "to_list returns steps in order" do
      m = Crank.new(Door)
      turns = Turns.new() |> Turns.turn(:a, m, :unlock)

      assert Turns.to_list(turns) == [{:a, m, :unlock}]
    end

    test "names returns step names in order" do
      m = Crank.new(Door)

      turns =
        Turns.new()
        |> Turns.turn(:first, m, :unlock)
        |> Turns.turn(:second, m, :unlock)

      assert Turns.names(turns) == [:first, :second]
    end

    test "names on empty descriptor is empty" do
      assert Turns.names(Turns.new()) == []
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pure executor
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply/1 — success" do
    test "empty descriptor returns {:ok, empty map}" do
      assert Turns.apply(Turns.new()) == {:ok, %{}}
    end

    test "single step succeeds and returns the advanced machine" do
      machine = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:door, machine, :unlock)
        |> Turns.apply()

      assert %{door: advanced} = results
      assert advanced.state == :unlocked
    end

    test "multiple independent steps succeed" do
      m1 = Crank.new(Door)
      m2 = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:a, m1, :unlock)
        |> Turns.turn(:b, m2, :unlock)
        |> Turns.apply()

      assert results.a.state == :unlocked
      assert results.b.state == :unlocked
    end

    test "each result is keyed by its step's name" do
      m = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:door_a, m, :unlock)
        |> Turns.turn(:door_b, m, :unlock)
        |> Turns.apply()

      assert Map.keys(results) |> Enum.sort() == [:door_a, :door_b]
    end

    test "literal event is passed through unchanged" do
      m = Crank.new(Crank.Examples.VendingMachine, price: 100)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:vm, m, {:coin, 25})
        |> Turns.apply()

      assert results.vm.state == :accepting
      assert results.vm.memory.balance == 25
    end
  end

  describe "apply/1 — dependencies" do
    test "event can be a function of prior results" do
      stoppable = Crank.new(Stoppable)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:first, stoppable, :go)
        |> Turns.turn(:second, stoppable, fn %{first: f} ->
          # Use the first result's state to pick an event
          if f.state == :running, do: :bump, else: :go
        end)
        |> Turns.apply()

      assert results.first.state == :running
      assert results.second.state == :live
      assert results.second.memory.value == 1
    end

    test "machine can be a function of prior results" do
      stoppable = Crank.new(Stoppable)
      door = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:first, stoppable, :go)
        |> Turns.turn(:second, fn %{first: _} -> door end, :unlock)
        |> Turns.apply()

      assert results.second.state == :unlocked
    end

    test "both machine and event can be functions" do
      vm = Crank.new(Crank.Examples.VendingMachine, price: 100)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:start, vm, {:coin, 50})
        |> Turns.turn(
          :continue,
          fn %{start: s} -> s end,
          fn %{start: s} -> {:coin, 100 - s.memory.balance} end
        )
        |> Turns.apply()

      assert results.continue.state == :accepting
      assert results.continue.memory.balance == 100
    end

    test "dep function receives prior successful results only" do
      m = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:a, m, :unlock)
        |> Turns.turn(:b, fn prior ->
          # At this point prior contains :a only, not :b
          assert Map.keys(prior) == [:a]
          m
        end, :unlock)
        |> Turns.apply()

      assert results.a.state == :unlocked
      assert results.b.state == :unlocked
    end
  end

  describe "apply/1 — stop mid-sequence" do
    test "reports {:error, name, reason, results} when a turn stops the machine" do
      stoppable = Crank.new(Stoppable)
      door = Crank.new(Door)

      result =
        Turns.new()
        |> Turns.turn(:first, door, :unlock)
        |> Turns.turn(:second, stoppable, {:stop, :business_reason})
        |> Turns.turn(:third, door, :unlock)
        |> Turns.apply()

      assert {:error, :second, :business_reason, advanced_so_far} = result

      # Prior step succeeded
      assert advanced_so_far.first.state == :unlocked

      # Failing step's stopped machine IS in the map
      assert advanced_so_far.second.engine == {:off, :business_reason}

      # Later step did not run
      refute Map.has_key?(advanced_so_far, :third)
    end

    test "stops on first step when first step stops" do
      stoppable = Crank.new(Stoppable)

      result =
        Turns.new()
        |> Turns.turn(:first, stoppable, {:stop, :immediate})
        |> Turns.turn(:never, Crank.new(Door), :unlock)
        |> Turns.apply()

      assert {:error, :first, :immediate, advanced} = result
      assert advanced.first.engine == {:off, :immediate}
      refute Map.has_key?(advanced, :never)
    end

    test "reports {:stopped_input, reason} when input machine was already stopped" do
      stoppable = Crank.new(Stoppable)
      stopped = Crank.turn(stoppable, {:stop, :was_stopped})
      assert stopped.engine == {:off, :was_stopped}

      door = Crank.new(Door)

      result =
        Turns.new()
        |> Turns.turn(:first, door, :unlock)
        |> Turns.turn(:second, stopped, :go)
        |> Turns.apply()

      assert {:error, :second, {:stopped_input, :was_stopped}, advanced_so_far} = result

      # Prior step succeeded
      assert advanced_so_far.first.state == :unlocked

      # Failing step's machine is NOT in the map (no turn happened)
      refute Map.has_key?(advanced_so_far, :second)
    end
  end

  describe "apply/1 — exceptions propagate" do
    test "exception from user turn/3 propagates, not caught as :error" do
      raiser = Crank.new(Raiser)

      assert_raise RuntimeError, "user bug in turn/3", fn ->
        Turns.new()
        |> Turns.turn(:kaboom, raiser, :boom)
        |> Turns.apply()
      end
    end

    test "exception from dep function propagates" do
      m = Crank.new(Door)

      assert_raise KeyError, fn ->
        Turns.new()
        |> Turns.turn(:a, m, :unlock)
        |> Turns.turn(:b, m, fn results -> results.nonexistent.something end)
        |> Turns.apply()
      end
    end

    test "FunctionClauseError from turn/3 (unhandled event) propagates" do
      m = Crank.new(Door)

      assert_raise FunctionClauseError, fn ->
        Turns.new()
        |> Turns.turn(:a, m, :not_a_real_event)
        |> Turns.apply()
      end
    end

    test "apply raises clear error when a machine resolver returns non-%Crank{}" do
      assert_raise ArgumentError,
                   ~r/step :bad resolved to :not_a_crank — expected %Crank{}/,
                   fn ->
                     Turns.new()
                     |> Turns.turn(:bad, fn _results -> :not_a_crank end, :event)
                     |> Turns.apply()
                   end
    end

    test "apply raises clear error when a literal non-%Crank{} machine reaches pure executor" do
      # The builder now accepts this (process-mode-compatible), so it must be
      # caught at apply-time in pure mode.
      assert_raise ArgumentError,
                   ~r/step :bad resolved to :not_a_crank — expected %Crank{}/,
                   fn ->
                     Turns.new()
                     |> Turns.turn(:bad, :not_a_crank, :event)
                     |> Turns.apply()
                   end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Integration — realistic multi-machine command
  # ──────────────────────────────────────────────────────────────────────────

  describe "integration" do
    test "three machines advance together as one unit of work" do
      order_m = Crank.new(Crank.Examples.Order, order_id: 42, total: 150)
      vending = Crank.new(Crank.Examples.VendingMachine, price: 100)
      door = Crank.new(Door)

      {:ok, results} =
        Turns.new()
        |> Turns.turn(:order, order_m, :pay)
        |> Turns.turn(:vend, vending, {:coin, 150})
        |> Turns.turn(:door, door, :unlock)
        |> Turns.apply()

      assert results.order.state == :paid
      assert results.order.memory.order_id == 42
      assert results.vend.state == :accepting
      assert results.vend.memory.balance == 150
      assert results.door.state == :unlocked
    end

    test "descriptor can be inspected before applying" do
      m = Crank.new(Door)

      turns =
        Turns.new()
        |> Turns.turn(:a, m, :unlock)
        |> Turns.turn(:b, m, :unlock)

      # We can inspect names, count steps, extract the list — all without
      # executing anything.
      assert Turns.names(turns) == [:a, :b]
      assert length(Turns.to_list(turns)) == 2

      # And then decide to apply.
      assert {:ok, _results} = Turns.apply(turns)
    end

    test "two descriptors can be composed" do
      m = Crank.new(Door)
      payment_phase = Turns.new() |> Turns.turn(:door_a, m, :unlock)
      fulfill_phase = Turns.new() |> Turns.turn(:door_b, m, :unlock)

      {:ok, results} =
        payment_phase
        |> Turns.append(fulfill_phase)
        |> Turns.apply()

      assert results.door_a.state == :unlocked
      assert results.door_b.state == :unlocked
    end
  end
end
