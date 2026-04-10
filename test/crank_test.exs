defmodule Crank.PureTest do
  use ExUnit.Case, async: true
  doctest Crank

  # ---------------------------------------------------------------------------
  # Fixtures — one machine per return type family
  # ---------------------------------------------------------------------------

  defmodule Door do
    use Crank

    @impl true
    def init(_opts), do: {:ok, :locked, %{}}

    @impl true
    def handle_event(_, :unlock, :locked, data), do: {:next_state, :unlocked, data}
    def handle_event(_, :lock, :unlocked, data), do: {:next_state, :locked, data}
    def handle_event(_, :open, :unlocked, data), do: {:next_state, :opened, data}
    def handle_event(_, :close, :opened, data), do: {:next_state, :unlocked, data}
  end

  defmodule Order do
    use Crank

    @impl true
    def init(opts) do
      {:ok, :pending, %{order_id: opts[:order_id], amount: opts[:amount]}}
    end

    @impl true
    def handle_event(_, :pay, :pending, data) do
      {:next_state, :paid, Map.put(data, :paid_at, :now)}
    end

    def handle_event(_, :ship, :paid, data) do
      {:next_state, :shipped, data, [{:state_timeout, 86_400_000, :delivery_timeout}]}
    end

    def handle_event(_, :cancel, :paid, data) do
      {:stop, :cancelled, Map.put(data, :cancelled_at, :now)}
    end

    def handle_event(_, :keep, _state, data), do: {:keep_state, data}

    def handle_event(_, :keep_with_actions, _state, data) do
      {:keep_state, data, [{:state_timeout, 1000, :nudge}]}
    end

    def handle_event(_, :noop, _state, _data), do: :keep_state_and_data

    def handle_event(_, :noop_with_actions, _state, _data) do
      {:keep_state_and_data, [{:state_timeout, 2000, :nag}]}
    end
  end

  defmodule WithEnter do
    use Crank

    @impl true
    def init(_opts), do: {:ok, :a, %{}}

    @impl true
    def handle_event(_, :go, :a, data), do: {:next_state, :b, data}

    @impl true
    def on_enter(old, new, data) do
      {:keep_state, Map.put(data, :entered, {old, new})}
    end
  end

  defmodule WithEnterActions do
    use Crank

    @impl true
    def init(_opts), do: {:ok, :a, %{}}

    @impl true
    def handle_event(_, :go, :a, data) do
      {:next_state, :b, data, [{:state_timeout, 5000, :from_handle}]}
    end

    @impl true
    def on_enter(_old, :b, data) do
      {:keep_state, data, [{:state_timeout, 3000, :from_enter}]}
    end

    def on_enter(_old, _new, data), do: {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # handle/3 — simplified callback (vending machine)
  # ---------------------------------------------------------------------------

  defmodule VendingMachine do
    use Crank

    @impl true
    def init(_opts), do: {:ok, :idle, %{balance: 0}}

    @impl true
    def handle(:insert, :idle, data) do
      {:next_state, :ready, %{data | balance: data.balance + 100}}
    end

    def handle(:select, :ready, data) do
      {:next_state, :vending, data, [{:state_timeout, 5000, :vend_timeout}]}
    end

    def handle(:dispense, :vending, data) do
      {:next_state, :idle, %{data | balance: 0}}
    end

    def handle(:refund, :ready, data) do
      {:stop, :refunded, %{data | balance: 0}}
    end

    def handle(:check, _state, data), do: {:keep_state, data}
    def handle(:noop, _state, _data), do: :keep_state_and_data

    def handle(:check_with_actions, _state, data) do
      {:keep_state, data, [{:state_timeout, 1000, :nudge}]}
    end

    def handle(:noop_with_actions, _state, _data) do
      {:keep_state_and_data, [{:state_timeout, 2000, :nag}]}
    end
  end

  defmodule VendingWithEnter do
    use Crank

    @impl true
    def init(_opts), do: {:ok, :idle, %{entered: nil}}

    @impl true
    def handle(:insert, :idle, data), do: {:next_state, :ready, data}

    @impl true
    def on_enter(old, new, data) do
      {:keep_state, %{data | entered: {old, new}}}
    end
  end

  describe "handle/3" do
    test "basic transitions" do
      m =
        VendingMachine
        |> Crank.new()
        |> Crank.crank(:insert)
        |> Crank.crank(:select)

      assert m.state == :vending
      assert m.data.balance == 100
    end

    test "{:next_state, state, data}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:insert)
      assert m.state == :ready
      assert m.effects == []
    end

    test "{:next_state, state, data, actions}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:insert) |> Crank.crank(:select)
      assert m.state == :vending
      assert m.effects == [{:state_timeout, 5000, :vend_timeout}]
    end

    test "{:keep_state, data}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:check)
      assert m.state == :idle
    end

    test "{:keep_state, data, actions}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:check_with_actions)
      assert m.effects == [{:state_timeout, 1000, :nudge}]
    end

    test ":keep_state_and_data" do
      m = Crank.new(VendingMachine) |> Crank.crank(:noop)
      assert m.state == :idle
    end

    test "{:keep_state_and_data, actions}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:noop_with_actions)
      assert m.effects == [{:state_timeout, 2000, :nag}]
    end

    test "{:stop, reason, data}" do
      m = Crank.new(VendingMachine) |> Crank.crank(:insert) |> Crank.crank(:refund)
      assert m.status == {:stopped, :refunded}
      assert m.data.balance == 0
    end

    test "composes with on_enter/3" do
      m = Crank.new(VendingWithEnter) |> Crank.crank(:insert)
      assert m.data.entered == {:idle, :ready}
    end

    test "handle_event/4 takes precedence when both exist" do
      defmodule BothCallbacks do
        use Crank

        @impl true
        def init(_), do: {:ok, :a, %{}}

        @impl true
        def handle_event(_, :go, :a, data), do: {:next_state, :b_from_event, data}

        @impl true
        def handle(:go, :a, data), do: {:next_state, :b_from_handle, data}
      end

      m = Crank.new(BothCallbacks) |> Crank.crank(:go)
      assert m.state == :b_from_event
    end

    test "module with neither callback raises" do
      defmodule NoCallbacks do
        def init(_), do: {:ok, :a, %{}}
      end

      assert_raise ArgumentError, ~r/handle_event\/4 or handle\/3/, fn ->
        Crank.new(NoCallbacks)
      end
    end

    test "invalid return references handle/3 in error" do
      defmodule BadHandleReturn do
        use Crank

        @impl true
        def init(_), do: {:ok, :idle, %{}}

        @impl true
        def handle(:go, :idle, _data), do: :oops
      end

      assert_raise ArgumentError, ~r/handle\/3.*returned invalid result/, fn ->
        Crank.new(BadHandleReturn) |> Crank.crank(:go)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Return types — one test per variant (exhaustive)
  # ---------------------------------------------------------------------------

  describe "return types" do
    test "{:next_state, state, data}" do
      m = Crank.new(Door) |> Crank.crank(:unlock)
      assert m.state == :unlocked
      assert m.effects == []
    end

    test "{:next_state, state, data, actions}" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:pay) |> Crank.crank(:ship)
      assert m.state == :shipped
      assert m.effects == [{:state_timeout, 86_400_000, :delivery_timeout}]
    end

    test "{:keep_state, data}" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:keep)
      assert m.state == :pending
    end

    test "{:keep_state, data, actions}" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:keep_with_actions)
      assert m.effects == [{:state_timeout, 1000, :nudge}]
    end

    test ":keep_state_and_data" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:noop)
      assert m.state == :pending
    end

    test "{:keep_state_and_data, actions}" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:noop_with_actions)
      assert m.effects == [{:state_timeout, 2000, :nag}]
    end

    test "{:stop, reason, data}" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:pay) |> Crank.crank(:cancel)
      assert m.status == {:stopped, :cancelled}
    end
  end

  # ---------------------------------------------------------------------------
  # on_enter — behaviour tests that properties can't express
  # ---------------------------------------------------------------------------

  describe "on_enter/3" do
    test "receives old_state and new_state" do
      m = Crank.new(WithEnter) |> Crank.crank(:go)
      assert m.data.entered == {:a, :b}
    end

    test "effects from handle_event and on_enter combine in order" do
      m = Crank.new(WithEnterActions) |> Crank.crank(:go)
      assert m.effects == [{:state_timeout, 5000, :from_handle}, {:state_timeout, 3000, :from_enter}]
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths — things that must crash with good messages
  # ---------------------------------------------------------------------------

  describe "error paths" do
    test "init {:stop, reason} raises ArgumentError" do
      defmodule FailInit do
        use Crank
        @impl true
        def init(_), do: {:stop, :bad_config}
        @impl true
        def handle_event(_, _, _, _data), do: :keep_state_and_data
      end

      assert_raise ArgumentError, ~r/bad_config/, fn -> Crank.new(FailInit) end
    end

    test "non-Crank module raises ArgumentError" do
      assert_raise ArgumentError, ~r/does not implement the Crank behaviour/, fn ->
        Crank.new(String)
      end
    end

    test "invalid callback return raises ArgumentError" do
      defmodule BadReturn do
        use Crank
        @impl true
        def init(_), do: {:ok, :idle, %{}}
        @impl true
        def handle_event(_, :go, :idle, _data), do: :oops
      end

      assert_raise ArgumentError, ~r/returned invalid result.*:oops/, fn ->
        Crank.new(BadReturn) |> Crank.crank(:go)
      end
    end

    test "unhandled event crashes with FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Crank.new(Door) |> Crank.crank(:nonexistent)
      end
    end

    test "crank on stopped machine raises StoppedError" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:pay) |> Crank.crank(:cancel)

      assert_raise Crank.StoppedError, ~r/machine is stopped/, fn ->
        Crank.crank(m, :ship)
      end
    end

    test "crank! raises on stop result" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank!(:pay)

      assert_raise Crank.StoppedError, fn -> Crank.crank!(m, :cancel) end
    end
  end

  # ---------------------------------------------------------------------------
  # can_crank?/2
  # ---------------------------------------------------------------------------

  describe "can_crank?/2" do
    test "returns true when the event would be handled" do
      machine = Crank.new(Door)
      assert Crank.can_crank?(machine, :unlock)
    end

    test "returns false when no clause matches" do
      machine = Crank.new(Door)
      refute Crank.can_crank?(machine, :open)
    end

    test "reflects the current state" do
      machine = Crank.new(Door) |> Crank.crank(:unlock)
      assert Crank.can_crank?(machine, :open)
      refute Crank.can_crank?(machine, :unlock)
    end

    test "returns false for a stopped machine" do
      machine =
        Crank.new(Order, order_id: "1", amount: 100)
        |> Crank.crank(:pay)
        |> Crank.crank(:cancel)

      assert machine.status == {:stopped, :cancelled}
      refute Crank.can_crank?(machine, :ship)
    end

    test "does not mutate the machine" do
      machine = Crank.new(Door)
      Crank.can_crank?(machine, :unlock)
      assert machine.state == :locked
    end

    test "respects current state" do
      machine = Crank.new(Order, order_id: "1", amount: 100) |> Crank.crank(:pay)
      assert Crank.can_crank?(machine, :ship)
      refute Crank.can_crank?(machine, :nonsense)
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence — snapshot, from_snapshot, resume
  # ---------------------------------------------------------------------------

  describe "snapshot/1" do
    test "returns a map with module, state, and data" do
      m = Crank.new(Door) |> Crank.crank(:unlock)
      snap = Crank.snapshot(m)

      assert snap == %{module: Door, state: :unlocked, data: %{}}
    end

    test "captures data accumulated across multiple cranks" do
      m =
        Crank.new(Order, order_id: 42, amount: 100)
        |> Crank.crank(:pay)

      snap = Crank.snapshot(m)
      assert snap.state == :paid
      assert snap.data.order_id == 42
      assert snap.data.paid_at == :now
    end

    test "does not include effects or status" do
      m = Crank.new(Order, order_id: 1, amount: 50) |> Crank.crank(:pay) |> Crank.crank(:ship)
      assert m.effects == [{:state_timeout, 86_400_000, :delivery_timeout}]

      snap = Crank.snapshot(m)
      refute Map.has_key?(snap, :effects)
      refute Map.has_key?(snap, :status)
    end
  end

  describe "from_snapshot/1" do
    test "round-trips through snapshot and back" do
      original = Crank.new(Door) |> Crank.crank(:unlock)
      resumed = original |> Crank.snapshot() |> Crank.from_snapshot()

      assert resumed.module == original.module
      assert resumed.state == original.state
      assert resumed.data == original.data
    end

    test "resumed machine accepts further events" do
      snap =
        Crank.new(Door)
        |> Crank.crank(:unlock)
        |> Crank.snapshot()

      resumed = Crank.from_snapshot(snap) |> Crank.crank(:lock)
      assert resumed.state == :locked
    end

    test "clears effects on resume" do
      m =
        Crank.new(Order, order_id: 1, amount: 50)
        |> Crank.crank(:pay)
        |> Crank.crank(:ship)

      assert m.effects != []

      resumed = m |> Crank.snapshot() |> Crank.from_snapshot()
      assert resumed.effects == []
    end

    test "starts in :running status" do
      snap = Crank.new(Door) |> Crank.snapshot()
      resumed = Crank.from_snapshot(snap)
      assert resumed.status == :running
    end

    test "emits [:crank, :resume] telemetry" do
      ref = make_ref()
      parent = self()

      handler_id = "test-from-snapshot-telemetry-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:crank, :resume],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      snap = Crank.new(Door) |> Crank.crank(:unlock) |> Crank.snapshot()
      Crank.from_snapshot(snap)

      assert_received {^ref, [:crank, :resume], %{system_time: _},
                       %{module: Door, state: :unlocked, data: %{}}}

      :telemetry.detach(handler_id)
    end

    test "does not call on_enter/3" do
      # WithEnter has on_enter/3 that writes to data.entered.
      # If we resume, on_enter should NOT fire, so data.entered stays at nil.
      snap = %{module: WithEnter, state: :b, data: %{some: :data}}
      resumed = Crank.from_snapshot(snap)

      refute Map.has_key?(resumed.data, :entered)
    end

    test "raises ArgumentError when module is not a Crank module" do
      assert_raise ArgumentError, ~r/does not implement the Crank behaviour/, fn ->
        Crank.from_snapshot(%{module: String, state: :foo, data: %{}})
      end
    end

    test "raises ArgumentError when snapshot is missing keys" do
      assert_raise ArgumentError, ~r/expected a map with :module, :state, and :data/, fn ->
        Crank.from_snapshot(%{module: Door, state: :locked})
      end
    end

    test "raises ArgumentError when passed a non-map" do
      assert_raise ArgumentError, ~r/expected a map/, fn ->
        Crank.from_snapshot(:not_a_map)
      end
    end
  end

  describe "resume/3" do
    test "produces the same machine as from_snapshot/1" do
      via_positional = Crank.resume(Door, :unlocked, %{})
      via_map = Crank.from_snapshot(%{module: Door, state: :unlocked, data: %{}})

      assert via_positional.module == via_map.module
      assert via_positional.state == via_map.state
      assert via_positional.data == via_map.data
      assert via_positional.effects == via_map.effects
      assert via_positional.status == via_map.status
    end

    test "resumed machine can be cranked further" do
      m = Crank.resume(Door, :unlocked, %{}) |> Crank.crank(:open)
      assert m.state == :opened
    end

    test "raises ArgumentError when module is not a Crank module" do
      assert_raise ArgumentError, ~r/does not implement the Crank behaviour/, fn ->
        Crank.resume(String, :foo, %{})
      end
    end
  end
end
