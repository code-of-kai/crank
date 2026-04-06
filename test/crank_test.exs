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
end
