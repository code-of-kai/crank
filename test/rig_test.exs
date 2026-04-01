defmodule Rig.PureTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Test fixtures
  # ---------------------------------------------------------------------------

  defmodule Door do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :locked, %{}}

    @impl true
    def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
    def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
    def handle_event(:unlocked, _, :open, data), do: {:next_state, :opened, data}
    def handle_event(:opened, _, :close, data), do: {:next_state, :unlocked, data}
  end

  defmodule Order do
    use Rig

    @impl true
    def init(opts) do
      {:ok, :pending, %{order_id: opts[:order_id], amount: opts[:amount]}}
    end

    @impl true
    def handle_event(:pending, _, :pay, data) do
      {:next_state, :paid, Map.put(data, :paid_at, :now)}
    end

    def handle_event(:paid, _, :ship, data) do
      {:next_state, :shipped, data, [{:state_timeout, 86_400_000, :delivery_timeout}]}
    end

    def handle_event(:shipped, _, {:timeout, :delivery_timeout}, data) do
      {:next_state, :delayed, data}
    end

    def handle_event(:paid, _, :cancel, data) do
      {:stop, :cancelled, Map.put(data, :cancelled_at, :now)}
    end

    def handle_event(_state, _, :keep, data) do
      {:keep_state, data}
    end

    def handle_event(_state, _, :keep_with_actions, data) do
      {:keep_state, data, [{:state_timeout, 1000, :nudge}]}
    end

    def handle_event(_state, _, :noop, _data) do
      :keep_state_and_data
    end

    def handle_event(_state, _, :noop_with_actions, _data) do
      {:keep_state_and_data, [{:state_timeout, 2000, :nag}]}
    end
  end

  defmodule WithEnter do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :idle, %{entered: []}}

    @impl true
    def handle_event(:idle, _, :go, data), do: {:next_state, :running, data}
    def handle_event(:running, _, :stop, data), do: {:next_state, :idle, data}

    def handle_event(:running, _, :go_with_actions, data) do
      {:next_state, :finishing, data, [{:state_timeout, 5000, :wrap_up}]}
    end

    @impl true
    def on_enter(old_state, new_state, data) do
      {:keep_state, Map.update!(data, :entered, &[{old_state, new_state} | &1])}
    end
  end

  defmodule WithEnterActions do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :a, %{}}

    @impl true
    def handle_event(:a, _, :go, data), do: {:next_state, :b, data}

    @impl true
    def on_enter(_old, :b, data) do
      {:keep_state, data, [{:state_timeout, 3000, :b_timeout}]}
    end

    def on_enter(_old, _new, data), do: {:keep_state, data}
  end

  defmodule FailInit do
    use Rig

    @impl true
    def init(_opts), do: {:stop, :bad_config}

    @impl true
    def handle_event(_, _, _, _), do: :keep_state_and_data
  end

  # ---------------------------------------------------------------------------
  # Tests — Rig.new/2
  # ---------------------------------------------------------------------------

  describe "Rig.new/2" do
    test "creates a machine with initial state and data" do
      machine = Rig.new(Door)

      assert %Rig.Machine{} = machine
      assert machine.module == Door
      assert machine.state == :locked
      assert machine.data == %{}
      assert machine.effects == []
      assert machine.status == :running
    end

    test "passes args to init/1" do
      machine = Rig.new(Order, order_id: 42, amount: 100)

      assert machine.state == :pending
      assert machine.data.order_id == 42
      assert machine.data.amount == 100
    end

    test "raises on {:stop, reason} from init" do
      assert_raise ArgumentError, ~r/bad_config/, fn ->
        Rig.new(FailInit)
      end
    end

    test "raises on module that doesn't implement Rig behaviour" do
      assert_raise ArgumentError, ~r/does not implement the Rig behaviour/, fn ->
        Rig.new(String)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Rig.crank/2
  # ---------------------------------------------------------------------------

  describe "Rig.crank/2" do
    test "cranks to a new state" do
      machine =
        Door
        |> Rig.new()
        |> Rig.crank(:unlock)

      assert machine.state == :unlocked
    end

    test "pipeline through multiple states" do
      machine =
        Door
        |> Rig.new()
        |> Rig.crank(:unlock)
        |> Rig.crank(:open)

      assert machine.state == :opened
    end

    test "stores effects from {:next_state, _, _, actions}" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:pay)
        |> Rig.crank(:ship)

      assert machine.state == :shipped
      assert machine.effects == [{:state_timeout, 86_400_000, :delivery_timeout}]
    end

    test "each crank replaces effects (no accumulation)" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:pay)

      assert machine.effects == []

      machine = Rig.crank(machine, :ship)
      assert machine.effects == [{:state_timeout, 86_400_000, :delivery_timeout}]

      machine = Rig.crank(machine, :keep)
      assert machine.effects == []
    end

    test "handles {:keep_state, new_data}" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:keep)

      assert machine.state == :pending
      assert machine.effects == []
    end

    test "handles {:keep_state, new_data, actions}" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:keep_with_actions)

      assert machine.state == :pending
      assert machine.effects == [{:state_timeout, 1000, :nudge}]
    end

    test "handles :keep_state_and_data" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:noop)

      assert machine.state == :pending
      assert machine.effects == []
    end

    test "handles {:keep_state_and_data, actions}" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:noop_with_actions)

      assert machine.state == :pending
      assert machine.effects == [{:state_timeout, 2000, :nag}]
    end

    test "handles {:stop, reason, data}" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:pay)
        |> Rig.crank(:cancel)

      assert machine.status == {:stopped, :cancelled}
      assert machine.state == :paid
      assert machine.data.cancelled_at == :now
      assert machine.effects == []
    end

    test "raises StoppedError when crankping a stopped machine" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank(:pay)
        |> Rig.crank(:cancel)

      assert_raise Rig.StoppedError, ~r/machine is stopped/, fn ->
        Rig.crank(machine, :ship)
      end
    end

    test "unhandled event raises FunctionClauseError (let it crash)" do
      machine = Rig.new(Door)

      assert_raise FunctionClauseError, fn ->
        Rig.crank(machine, :nonexistent_event)
      end
    end

    test "event_type is :internal in pure cranks" do
      defmodule EventTypeProbe do
        use Rig

        @impl true
        def init(_), do: {:ok, :idle, %{}}

        @impl true
        def handle_event(:idle, event_type, :go, data) do
          {:next_state, :done, Map.put(data, :event_type, event_type)}
        end
      end

      machine =
        EventTypeProbe
        |> Rig.new()
        |> Rig.crank(:go)

      assert machine.data.event_type == :internal
    end

    test "raises ArgumentError on invalid callback return" do
      defmodule BadReturn do
        use Rig

        @impl true
        def init(_), do: {:ok, :idle, %{}}

        @impl true
        def handle_event(:idle, _, :go, _data), do: {:error, :oops}
      end

      machine = Rig.new(BadReturn)

      assert_raise ArgumentError, ~r/returned invalid result/, fn ->
        Rig.crank(machine, :go)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Rig.crank!/2
  # ---------------------------------------------------------------------------

  describe "Rig.crank!/2" do
    test "returns machine on success" do
      machine =
        Door
        |> Rig.new()
        |> Rig.crank!(:unlock)

      assert machine.state == :unlocked
    end

    test "raises on stop result" do
      machine =
        Order
        |> Rig.new(order_id: 1, amount: 50)
        |> Rig.crank!(:pay)

      assert_raise Rig.StoppedError, fn ->
        Rig.crank!(machine, :cancel)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — on_enter/3
  # ---------------------------------------------------------------------------

  describe "on_enter/3" do
    test "called on state transitions with old and new state" do
      machine =
        WithEnter
        |> Rig.new()
        |> Rig.crank(:go)

      assert machine.state == :running
      assert machine.data.entered == [{:idle, :running}]
    end

    test "called on each crank in a pipeline" do
      machine =
        WithEnter
        |> Rig.new()
        |> Rig.crank(:go)
        |> Rig.crank(:stop)

      assert machine.data.entered == [{:running, :idle}, {:idle, :running}]
    end

    test "on_enter effects are appended to handle_event effects" do
      machine =
        WithEnterActions
        |> Rig.new()
        |> Rig.crank(:go)

      assert machine.state == :b
      assert machine.effects == [{:state_timeout, 3000, :b_timeout}]
    end

    test "handle_event effects + on_enter effects combine" do
      machine =
        WithEnter
        |> Rig.new()
        |> Rig.crank(:go)
        |> Rig.crank(:go_with_actions)

      assert machine.state == :finishing
      assert machine.effects == [{:state_timeout, 5000, :wrap_up}]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Machine struct
  # ---------------------------------------------------------------------------

  describe "Rig.Machine struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Rig.Machine, [])
      end
    end
  end
end
