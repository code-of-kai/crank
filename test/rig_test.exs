defmodule Rig.PureTest do
  use ExUnit.Case, async: true
  doctest Rig

  # ---------------------------------------------------------------------------
  # Fixtures — one machine per return type family
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

    def handle_event(:paid, _, :cancel, data) do
      {:stop, :cancelled, Map.put(data, :cancelled_at, :now)}
    end

    def handle_event(_state, _, :keep, data), do: {:keep_state, data}

    def handle_event(_state, _, :keep_with_actions, data) do
      {:keep_state, data, [{:state_timeout, 1000, :nudge}]}
    end

    def handle_event(_state, _, :noop, _data), do: :keep_state_and_data

    def handle_event(_state, _, :noop_with_actions, _data) do
      {:keep_state_and_data, [{:state_timeout, 2000, :nag}]}
    end
  end

  defmodule WithEnter do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :a, %{}}

    @impl true
    def handle_event(:a, _, :go, data), do: {:next_state, :b, data}

    @impl true
    def on_enter(old, new, data) do
      {:keep_state, Map.put(data, :entered, {old, new})}
    end
  end

  defmodule WithEnterActions do
    use Rig

    @impl true
    def init(_opts), do: {:ok, :a, %{}}

    @impl true
    def handle_event(:a, _, :go, data) do
      {:next_state, :b, data, [{:state_timeout, 5000, :from_handle}]}
    end

    @impl true
    def on_enter(_old, :b, data) do
      {:keep_state, data, [{:state_timeout, 3000, :from_enter}]}
    end

    def on_enter(_old, _new, data), do: {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Return types — one test per variant (exhaustive)
  # ---------------------------------------------------------------------------

  describe "return types" do
    test "{:next_state, state, data}" do
      m = Rig.new(Door) |> Rig.crank(:unlock)
      assert m.state == :unlocked
      assert m.effects == []
    end

    test "{:next_state, state, data, actions}" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:pay) |> Rig.crank(:ship)
      assert m.state == :shipped
      assert m.effects == [{:state_timeout, 86_400_000, :delivery_timeout}]
    end

    test "{:keep_state, data}" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:keep)
      assert m.state == :pending
    end

    test "{:keep_state, data, actions}" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:keep_with_actions)
      assert m.effects == [{:state_timeout, 1000, :nudge}]
    end

    test ":keep_state_and_data" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:noop)
      assert m.state == :pending
    end

    test "{:keep_state_and_data, actions}" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:noop_with_actions)
      assert m.effects == [{:state_timeout, 2000, :nag}]
    end

    test "{:stop, reason, data}" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:pay) |> Rig.crank(:cancel)
      assert m.status == {:stopped, :cancelled}
    end
  end

  # ---------------------------------------------------------------------------
  # on_enter — behaviour tests that properties can't express
  # ---------------------------------------------------------------------------

  describe "on_enter/3" do
    test "receives old_state and new_state" do
      m = Rig.new(WithEnter) |> Rig.crank(:go)
      assert m.data.entered == {:a, :b}
    end

    test "effects from handle_event and on_enter combine in order" do
      m = Rig.new(WithEnterActions) |> Rig.crank(:go)
      assert m.effects == [{:state_timeout, 5000, :from_handle}, {:state_timeout, 3000, :from_enter}]
    end
  end

  # ---------------------------------------------------------------------------
  # Error paths — things that must crash with good messages
  # ---------------------------------------------------------------------------

  describe "error paths" do
    test "init {:stop, reason} raises ArgumentError" do
      defmodule FailInit do
        use Rig
        @impl true
        def init(_), do: {:stop, :bad_config}
        @impl true
        def handle_event(_, _, _, _), do: :keep_state_and_data
      end

      assert_raise ArgumentError, ~r/bad_config/, fn -> Rig.new(FailInit) end
    end

    test "non-Rig module raises ArgumentError" do
      assert_raise ArgumentError, ~r/does not implement the Rig behaviour/, fn ->
        Rig.new(String)
      end
    end

    test "invalid callback return raises ArgumentError" do
      defmodule BadReturn do
        use Rig
        @impl true
        def init(_), do: {:ok, :idle, %{}}
        @impl true
        def handle_event(:idle, _, :go, _data), do: :oops
      end

      assert_raise ArgumentError, ~r/returned invalid result.*:oops/, fn ->
        Rig.new(BadReturn) |> Rig.crank(:go)
      end
    end

    test "unhandled event crashes with FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Rig.new(Door) |> Rig.crank(:nonexistent)
      end
    end

    test "crank on stopped machine raises StoppedError" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank(:pay) |> Rig.crank(:cancel)

      assert_raise Rig.StoppedError, ~r/machine is stopped/, fn ->
        Rig.crank(m, :ship)
      end
    end

    test "crank! raises on stop result" do
      m = Rig.new(Order, order_id: 1, amount: 50) |> Rig.crank!(:pay)

      assert_raise Rig.StoppedError, fn -> Rig.crank!(m, :cancel) end
    end
  end
end
