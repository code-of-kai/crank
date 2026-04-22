defmodule Crank.PureTest do
  use ExUnit.Case, async: true
  doctest Crank

  # ──────────────────────────────────────────────────────────────────────────
  # Fixtures — one module per concern
  # ──────────────────────────────────────────────────────────────────────────

  defmodule Door do
    use Crank

    @impl true
    def start(_opts), do: {:ok, :locked, %{}}

    @impl true
    def turn(:unlock, :locked, m), do: {:next, :unlocked, m}
    def turn(:lock, :unlocked, m), do: {:next, :locked, m}
    def turn(:open, :unlocked, m), do: {:next, :opened, m}
    def turn(:close, :opened, m), do: {:next, :unlocked, m}
  end

  defmodule Order do
    use Crank

    @impl true
    def start(opts), do: {:ok, :pending, %{order_id: opts[:order_id], amount: opts[:amount]}}

    @impl true
    def turn(:pay, :pending, m), do: {:next, :paid, Map.put(m, :paid_at, :now)}
    def turn(:ship, :paid, m), do: {:next, :shipped, m}
    def turn(:cancel, :paid, m), do: {:stop, :cancelled, Map.put(m, :cancelled_at, :now)}
    def turn(:note, _s, m), do: {:stay, Map.update(m, :notes, 1, &(&1 + 1))}
    def turn(:noop, _s, _m), do: :stay

    @impl true
    def wants(:shipped, _m), do: [{:after, 86_400_000, :delivery_timeout}]
    def wants(_s, _m), do: []
  end

  defmodule Counter do
    @moduledoc false
    use Crank

    @impl true
    def start(_opts), do: {:ok, :idle, %{count: 0}}

    @impl true
    def turn(:tick, :idle, m), do: {:stay, %{m | count: m.count + 1}}
    def turn(:double, :idle, m), do: {:stay, %{m | count: m.count * 2}}

    @impl true
    def reading(state, m), do: %{state: state, count: m.count}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # turn/2 — return shapes
  # ──────────────────────────────────────────────────────────────────────────

  describe "turn/2 — return shapes" do
    test "{:next, state, memory}" do
      m = Door |> Crank.new() |> Crank.turn(:unlock)
      assert m.state == :unlocked
      assert m.memory == %{}
      assert m.wants == []
    end

    test "{:stay, memory}" do
      m = Order |> Crank.new(order_id: 1, amount: 50) |> Crank.turn(:note)
      assert m.state == :pending
      assert m.memory.notes == 1
      assert m.wants == []
    end

    test ":stay" do
      m = Order |> Crank.new(order_id: 1, amount: 50) |> Crank.turn(:noop)
      assert m.state == :pending
      assert m.wants == []
    end

    test "{:stop, reason, memory}" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:cancel)

      assert m.engine == {:off, :cancelled}
      assert m.memory.cancelled_at == :now
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # wants/2 — always reflects module.wants(state, memory)
  # ──────────────────────────────────────────────────────────────────────────

  describe "wants/2" do
    test "machine.wants equals module.wants(state, memory) after {:next, ...}" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:ship)

      assert m.state == :shipped
      assert m.wants == Order.wants(:shipped, m.memory)
      assert m.wants == [{:after, 86_400_000, :delivery_timeout}]
    end

    test "machine.wants equals module.wants(state, memory) after {:stay, memory}" do
      # Order has wants(:shipped, _) declared. :note on :shipped returns
      # {:stay, new_memory} — wants should still reflect :shipped's declaration.
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:ship)
        |> Crank.turn(:note)

      assert m.state == :shipped
      assert m.wants == Order.wants(:shipped, m.memory)
      assert m.wants == [{:after, 86_400_000, :delivery_timeout}]
    end

    test "machine.wants equals module.wants(state, memory) after :stay" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:ship)
        |> Crank.turn(:noop)

      assert m.state == :shipped
      assert m.wants == Order.wants(:shipped, m.memory)
    end

    test "initial new/2 populates wants for the starting state" do
      defmodule InitialWants do
        use Crank
        def start(_), do: {:ok, :armed, %{}}
        def turn(_, _, m), do: {:stay, m}
        def wants(:armed, _), do: [{:after, 1_000, :check}]
        def wants(_, _), do: []
      end

      m = Crank.new(InitialWants)
      assert m.wants == [{:after, 1_000, :check}]
    end

    test "defaults to empty list when the callback is not defined" do
      m = Door |> Crank.new() |> Crank.turn(:unlock)
      assert m.wants == []
    end

    test "preserved on {:stop, ...} — still matches module.wants(state, memory)" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:cancel)

      # {:stop, reason, memory} preserves state (domain position at time of stop).
      assert m.state == :paid
      assert m.engine == {:off, :cancelled}
      # Whether the engine can act is answered by `engine`; `wants` still
      # reflects what the current (state, memory) would declare.
      assert m.wants == Order.wants(m.state, m.memory)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # reading/1 — projection for observers
  # ──────────────────────────────────────────────────────────────────────────

  describe "reading/1" do
    test "uses reading/2 callback when defined" do
      m = Counter |> Crank.new() |> Crank.turn(:tick) |> Crank.turn(:tick) |> Crank.turn(:tick)
      assert Crank.reading(m) == %{state: :idle, count: 3}
    end

    test "falls back to the raw state when reading/2 is not defined" do
      m = Door |> Crank.new() |> Crank.turn(:unlock)
      assert Crank.reading(m) == :unlocked
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # can_turn?/2 and can_turn!/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "can_turn?/2" do
    test "true when the event would be handled" do
      assert Crank.can_turn?(Crank.new(Door), :unlock)
    end

    test "false when no clause matches" do
      refute Crank.can_turn?(Crank.new(Door), :open)
    end

    test "reflects the current state" do
      m = Crank.turn(Crank.new(Door), :unlock)
      assert Crank.can_turn?(m, :open)
      refute Crank.can_turn?(m, :unlock)
    end

    test "false for a stopped machine" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:cancel)

      assert match?({:off, _}, m.engine)
      refute Crank.can_turn?(m, :ship)
    end

    test "does not mutate the machine" do
      m = Crank.new(Door)
      _ = Crank.can_turn?(m, :unlock)
      assert m.state == :locked
    end
  end

  describe "can_turn!/2" do
    test "returns :ok when the event would be handled" do
      assert :ok == Crank.can_turn!(Crank.new(Door), :unlock)
    end

    test "raises FunctionClauseError when not" do
      assert_raise FunctionClauseError, fn ->
        Crank.can_turn!(Crank.new(Door), :open)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # turn!/2 — bang variant
  # ──────────────────────────────────────────────────────────────────────────

  describe "turn!/2" do
    test "returns the machine on successful transition" do
      m = Crank.turn!(Crank.new(Door), :unlock)
      assert m.state == :unlocked
    end

    test "raises StoppedError if the transition stops the machine" do
      m = Crank.turn!(Crank.new(Order, order_id: 1, amount: 50), :pay)

      assert_raise Crank.StoppedError, fn -> Crank.turn!(m, :cancel) end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Error paths
  # ──────────────────────────────────────────────────────────────────────────

  describe "error paths" do
    test "start returning {:stop, reason} raises ArgumentError" do
      defmodule FailStart do
        use Crank
        def start(_), do: {:stop, :bad_config}
        def turn(_, _, m), do: {:stay, m}
      end

      assert_raise ArgumentError, ~r/bad_config/, fn -> Crank.new(FailStart) end
    end

    test "non-Crank module raises ArgumentError" do
      assert_raise ArgumentError, ~r/does not implement the Crank behaviour/, fn ->
        Crank.new(String)
      end
    end

    test "invalid turn/3 return raises ArgumentError" do
      defmodule BadReturn do
        use Crank
        def start(_), do: {:ok, :idle, %{}}
        def turn(:go, :idle, _m), do: :oops
      end

      assert_raise ArgumentError, ~r/returned invalid result/, fn ->
        Crank.turn(Crank.new(BadReturn), :go)
      end
    end

    test "unhandled event raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Crank.turn(Crank.new(Door), :nonexistent)
      end
    end

    test "turn on a stopped machine raises StoppedError" do
      m =
        Order
        |> Crank.new(order_id: 1, amount: 50)
        |> Crank.turn(:pay)
        |> Crank.turn(:cancel)

      assert_raise Crank.StoppedError, ~r/engine is off/, fn ->
        Crank.turn(m, :ship)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Persistence — snapshot/1 and resume/1
  # ──────────────────────────────────────────────────────────────────────────

  describe "snapshot/1" do
    test "returns a map of module, state, memory" do
      m = Door |> Crank.new() |> Crank.turn(:unlock)
      assert Crank.snapshot(m) == %{module: Door, state: :unlocked, memory: %{}}
    end

    test "captures memory accumulated across turns" do
      m = Order |> Crank.new(order_id: 42, amount: 100) |> Crank.turn(:pay)
      snap = Crank.snapshot(m)

      assert snap.state == :paid
      assert snap.memory.order_id == 42
      assert snap.memory.paid_at == :now
    end

    test "excludes wants and engine" do
      m = Order |> Crank.new(order_id: 1, amount: 50) |> Crank.turn(:pay) |> Crank.turn(:ship)
      assert m.wants != []

      snap = Crank.snapshot(m)
      refute Map.has_key?(snap, :wants)
      refute Map.has_key?(snap, :engine)
    end
  end

  describe "resume/1" do
    test "round-trips through snapshot and back" do
      original = Door |> Crank.new() |> Crank.turn(:unlock)
      resumed = original |> Crank.snapshot() |> Crank.resume()

      assert resumed.module == original.module
      assert resumed.state == original.state
      assert resumed.memory == original.memory
    end

    test "resumed machine accepts further events" do
      m =
        Door
        |> Crank.new()
        |> Crank.turn(:unlock)
        |> Crank.snapshot()
        |> Crank.resume()
        |> Crank.turn(:lock)

      assert m.state == :locked
    end

    test "populates wants cache to match module.wants(state, memory)" do
      # Pure resume populates the cache for consistency with the
      # "wants is always module.wants(state, memory)" invariant. It does NOT
      # execute anything — pure mode never executes wants. Server resume is
      # the mode that actually re-arms timers and re-delivers sends.
      snap = %{module: Order, state: :shipped, memory: %{notes: 0}}
      resumed = Crank.resume(snap)

      assert resumed.wants == Order.wants(:shipped, %{notes: 0})
      assert resumed.wants == [{:after, 86_400_000, :delivery_timeout}]
    end

    test "starts with engine: :running" do
      snap = Crank.snapshot(Crank.new(Door))
      assert Crank.resume(snap).engine == :running
    end

    test "emits [:crank, :resume] telemetry" do
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

      snap = Door |> Crank.new() |> Crank.turn(:unlock) |> Crank.snapshot()
      Crank.resume(snap)

      assert_received {^ref, [:crank, :resume], %{system_time: _},
                       %{module: Door, state: :unlocked, memory: %{}}}

      :telemetry.detach(handler_id)
    end

    test "raises ArgumentError when module is not a Crank module" do
      assert_raise ArgumentError, ~r/does not implement the Crank behaviour/, fn ->
        Crank.resume(%{module: String, state: :foo, memory: %{}})
      end
    end

    test "raises ArgumentError when snapshot is not a valid map" do
      assert_raise ArgumentError, ~r/expected a snapshot map/, fn ->
        Crank.resume(:not_a_map)
      end
    end
  end
end
