defmodule Decidable.PureTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Test fixtures — minimal state machines (arity-4 handle_event)
  # ---------------------------------------------------------------------------

  defmodule Door do
    use Decidable

    @impl true
    def init(_opts), do: {:ok, :locked, %{}}

    @impl true
    def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
    def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
    def handle_event(:unlocked, _, :open, data), do: {:next_state, :opened, data}
    def handle_event(:opened, _, :close, data), do: {:next_state, :unlocked, data}
  end

  defmodule Order do
    use Decidable

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
    use Decidable

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
    use Decidable

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
    use Decidable

    @impl true
    def init(_opts), do: {:stop, :bad_config}

    @impl true
    def handle_event(_, _, _, _), do: :keep_state_and_data
  end

  # ---------------------------------------------------------------------------
  # Tests — Decidable.new/2
  # ---------------------------------------------------------------------------

  describe "Decidable.new/2" do
    test "creates a machine with initial state and data" do
      machine = Decidable.new(Door)

      assert %Decidable.Machine{} = machine
      assert machine.module == Door
      assert machine.state == :locked
      assert machine.data == %{}
      assert machine.pending_actions == []
      assert machine.status == :running
    end

    test "passes args to init/1" do
      machine = Decidable.new(Order, order_id: 42, amount: 100)

      assert machine.state == :pending
      assert machine.data.order_id == 42
      assert machine.data.amount == 100
    end

    test "raises on {:stop, reason} from init" do
      assert_raise ArgumentError, ~r/bad_config/, fn ->
        Decidable.new(FailInit)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Decidable.transition/2
  # ---------------------------------------------------------------------------

  describe "Decidable.transition/2" do
    test "transitions to a new state" do
      machine =
        Door
        |> Decidable.new()
        |> Decidable.transition(:unlock)

      assert machine.state == :unlocked
    end

    test "pipeline through multiple states" do
      machine =
        Door
        |> Decidable.new()
        |> Decidable.transition(:unlock)
        |> Decidable.transition(:open)

      assert machine.state == :opened
    end

    test "stores pending actions from {:next_state, _, _, actions}" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:pay)
        |> Decidable.transition(:ship)

      assert machine.state == :shipped
      assert machine.pending_actions == [{:state_timeout, 86_400_000, :delivery_timeout}]
    end

    test "each transition replaces pending_actions (no accumulation)" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:pay)

      # :pay returns {:next_state, :paid, data} with no actions
      assert machine.pending_actions == []

      machine = Decidable.transition(machine, :ship)
      assert machine.pending_actions == [{:state_timeout, 86_400_000, :delivery_timeout}]

      # A keep_state transition clears them
      machine = Decidable.transition(machine, :keep)
      assert machine.pending_actions == []
    end

    test "handles {:keep_state, new_data}" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:keep)

      assert machine.state == :pending
      assert machine.pending_actions == []
    end

    test "handles {:keep_state, new_data, actions}" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:keep_with_actions)

      assert machine.state == :pending
      assert machine.pending_actions == [{:state_timeout, 1000, :nudge}]
    end

    test "handles :keep_state_and_data" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:noop)

      assert machine.state == :pending
      assert machine.pending_actions == []
    end

    test "handles {:keep_state_and_data, actions}" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:noop_with_actions)

      assert machine.state == :pending
      assert machine.pending_actions == [{:state_timeout, 2000, :nag}]
    end

    test "handles {:stop, reason, data}" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:pay)
        |> Decidable.transition(:cancel)

      assert machine.status == {:stopped, :cancelled}
      assert machine.state == :paid
      assert machine.data.cancelled_at == :now
      assert machine.pending_actions == []
    end

    test "raises StoppedError when transitioning a stopped machine" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition(:pay)
        |> Decidable.transition(:cancel)

      assert_raise Decidable.StoppedError, ~r/machine is stopped/, fn ->
        Decidable.transition(machine, :ship)
      end
    end

    test "unhandled event raises FunctionClauseError (let it crash)" do
      machine = Decidable.new(Door)

      assert_raise FunctionClauseError, fn ->
        Decidable.transition(machine, :nonexistent_event)
      end
    end

    test "event_type is :internal in pure transitions" do
      # This module distinguishes event types to prove :internal is used
      defmodule EventTypeProbe do
        use Decidable

        @impl true
        def init(_), do: {:ok, :idle, %{}}

        @impl true
        def handle_event(:idle, event_type, :go, data) do
          {:next_state, :done, Map.put(data, :event_type, event_type)}
        end
      end

      machine =
        EventTypeProbe
        |> Decidable.new()
        |> Decidable.transition(:go)

      assert machine.data.event_type == :internal
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Decidable.transition!/2
  # ---------------------------------------------------------------------------

  describe "Decidable.transition!/2" do
    test "returns machine on success" do
      machine =
        Door
        |> Decidable.new()
        |> Decidable.transition!(:unlock)

      assert machine.state == :unlocked
    end

    test "raises on stop result" do
      machine =
        Order
        |> Decidable.new(order_id: 1, amount: 50)
        |> Decidable.transition!(:pay)

      assert_raise Decidable.StoppedError, fn ->
        Decidable.transition!(machine, :cancel)
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
        |> Decidable.new()
        |> Decidable.transition(:go)

      assert machine.state == :running
      assert machine.data.entered == [{:idle, :running}]
    end

    test "called on each transition in a pipeline" do
      machine =
        WithEnter
        |> Decidable.new()
        |> Decidable.transition(:go)
        |> Decidable.transition(:stop)

      # Most recent first (prepended)
      assert machine.data.entered == [{:running, :idle}, {:idle, :running}]
    end

    test "on_enter actions are appended to handle_event actions" do
      machine =
        WithEnterActions
        |> Decidable.new()
        |> Decidable.transition(:go)

      assert machine.state == :b
      # handle_event returned no actions, on_enter added one
      assert machine.pending_actions == [{:state_timeout, 3000, :b_timeout}]
    end

    test "handle_event actions + on_enter actions combine" do
      machine =
        WithEnter
        |> Decidable.new()
        |> Decidable.transition(:go)
        |> Decidable.transition(:go_with_actions)

      assert machine.state == :finishing
      # handle_event's action preserved, on_enter didn't add new actions (just data)
      assert machine.pending_actions == [{:state_timeout, 5000, :wrap_up}]
    end
  end

  # ---------------------------------------------------------------------------
  # Tests — Machine struct
  # ---------------------------------------------------------------------------

  describe "Decidable.Machine struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Decidable.Machine, [])
      end
    end
  end
end
