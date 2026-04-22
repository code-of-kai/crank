defmodule Crank.WantsTest do
  use ExUnit.Case, async: true
  doctest Crank.Wants

  alias Crank.Wants

  describe "new/0" do
    test "returns an empty list" do
      assert Wants.new() == []
    end
  end

  describe "timeout/3 (anonymous)" do
    test "appends an anonymous after tuple" do
      assert Wants.new() |> Wants.timeout(100, :tick) == [{:after, 100, :tick}]
    end

    test "accepts zero milliseconds" do
      assert Wants.new() |> Wants.timeout(0, :now) == [{:after, 0, :now}]
    end

    test "accepts any term as event" do
      assert Wants.new() |> Wants.timeout(100, {:retry, :http, 3}) ==
               [{:after, 100, {:retry, :http, 3}}]
    end

    test "raises on negative milliseconds" do
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :timeout, [Wants.new(), -1, :bad])
      end
    end

    test "raises on non-integer milliseconds" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :timeout, [Wants.new(), "soon", :bad])
      end
    end

    test "raises on float milliseconds" do
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :timeout, [Wants.new(), 1.5, :bad])
      end
    end

    test "preserves existing wants and appends at end" do
      result =
        Wants.new()
        |> Wants.next(:ping)
        |> Wants.timeout(100, :later)

      assert result == [{:next, :ping}, {:after, 100, :later}]
    end
  end

  describe "timeout/4 (named)" do
    test "appends a named after tuple" do
      assert Wants.new() |> Wants.timeout(:hb, 5_000, :heartbeat) ==
               [{:after, :hb, 5_000, :heartbeat}]
    end

    test "accepts any term as name" do
      assert Wants.new() |> Wants.timeout({:user, 42}, 100, :poll) ==
               [{:after, {:user, 42}, 100, :poll}]
    end

    test "accepts zero milliseconds" do
      assert Wants.new() |> Wants.timeout(:now, 0, :go) ==
               [{:after, :now, 0, :go}]
    end

    test "raises on negative milliseconds" do
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :timeout, [Wants.new(), :x, -1, :bad])
      end
    end

    test "raises on non-integer milliseconds" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :timeout, [Wants.new(), :x, :soon, :bad])
      end
    end
  end

  describe "cancel/2" do
    test "appends a cancel tuple" do
      assert Wants.new() |> Wants.cancel(:heartbeat) == [{:cancel, :heartbeat}]
    end

    test "accepts any term as name" do
      assert Wants.new() |> Wants.cancel({:user, 42}) == [{:cancel, {:user, 42}}]
    end

    test "pairs with timeout/4 for a typical lifecycle" do
      result =
        Wants.new()
        |> Wants.timeout(:poll, 1_000, :check)
        |> Wants.cancel(:poll)

      assert result == [{:after, :poll, 1_000, :check}, {:cancel, :poll}]
    end
  end

  describe "send/3" do
    test "appends a send tuple with a pid" do
      pid = self()
      assert Wants.new() |> Wants.send(pid, :ping) == [{:send, pid, :ping}]
    end

    test "appends a send tuple with a registered name" do
      assert Wants.new() |> Wants.send(:logger, {:log, "hi"}) ==
               [{:send, :logger, {:log, "hi"}}]
    end

    test "accepts a remote reference" do
      assert Wants.new() |> Wants.send({:registered, :some@node}, :msg) ==
               [{:send, {:registered, :some@node}, :msg}]
    end

    test "accepts any term as message" do
      assert Wants.new() |> Wants.send(:dest, %{deeply: [nested: :data]}) ==
               [{:send, :dest, %{deeply: [nested: :data]}}]
    end
  end

  describe "telemetry/4" do
    test "appends a telemetry tuple" do
      assert Wants.new() |> Wants.telemetry([:a, :b], %{count: 1}, %{id: 42}) ==
               [{:telemetry, [:a, :b], %{count: 1}, %{id: 42}}]
    end

    test "accepts empty measurements and metadata maps" do
      assert Wants.new() |> Wants.telemetry([:a], %{}, %{}) ==
               [{:telemetry, [:a], %{}, %{}}]
    end

    test "raises on non-list event name" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :telemetry, [Wants.new(), :not_list, %{}, %{}])
      end
    end

    test "raises on non-map measurements" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :telemetry, [Wants.new(), [:a], [count: 1], %{}])
      end
    end

    test "raises on non-map metadata" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :telemetry, [Wants.new(), [:a], %{}, [id: 1]])
      end
    end
  end

  describe "next/2" do
    test "appends a next tuple" do
      assert Wants.new() |> Wants.next(:auto_advance) == [{:next, :auto_advance}]
    end

    test "accepts any term as event" do
      assert Wants.new() |> Wants.next({:retry, 3}) == [{:next, {:retry, 3}}]
    end
  end

  describe "only_if/3" do
    test "applies fun when condition is true" do
      result = Wants.new() |> Wants.only_if(true, &Wants.next(&1, :yes))
      assert result == [{:next, :yes}]
    end

    test "skips fun when condition is false" do
      result = Wants.new() |> Wants.only_if(false, &Wants.next(&1, :no))
      assert result == []
    end

    test "skips fun when condition is nil" do
      result = Wants.new() |> Wants.only_if(nil, &Wants.next(&1, :no))
      assert result == []
    end

    test "applies fun for any truthy value" do
      result = Wants.new() |> Wants.only_if(:yes, &Wants.next(&1, :went))
      assert result == [{:next, :went}]
    end

    test "applies fun for a non-empty list" do
      result = Wants.new() |> Wants.only_if([1], &Wants.next(&1, :went))
      assert result == [{:next, :went}]
    end

    test "applies fun for 0 (truthy in Elixir)" do
      result = Wants.new() |> Wants.only_if(0, &Wants.next(&1, :went))
      assert result == [{:next, :went}]
    end

    test "preserves existing wants when condition is false" do
      result =
        Wants.new()
        |> Wants.next(:first)
        |> Wants.only_if(false, &Wants.next(&1, :skipped))

      assert result == [{:next, :first}]
    end

    test "composes with existing wants when condition is true" do
      result =
        Wants.new()
        |> Wants.next(:first)
        |> Wants.only_if(true, &Wants.next(&1, :second))

      assert result == [{:next, :first}, {:next, :second}]
    end

    test "fun can append multiple wants" do
      result =
        Wants.new()
        |> Wants.only_if(true, fn w ->
          w
          |> Wants.next(:a)
          |> Wants.next(:b)
        end)

      assert result == [{:next, :a}, {:next, :b}]
    end

    test "raises when fun has the wrong arity" do
      # apply/3 bypasses compile-time type checking so the runtime guard is exercised.
      assert_raise FunctionClauseError, fn ->
        apply(Wants, :only_if, [Wants.new(), true, fn -> :bad end])
      end
    end
  end

  describe "merge/2" do
    test "concatenates two lists in order" do
      a = Wants.new() |> Wants.next(:one)
      b = Wants.new() |> Wants.next(:two)

      assert Wants.merge(a, b) == [{:next, :one}, {:next, :two}]
    end

    test "handles empty lists on the left" do
      wants = Wants.new() |> Wants.next(:solo)
      assert Wants.merge([], wants) == [{:next, :solo}]
    end

    test "handles empty lists on the right" do
      wants = Wants.new() |> Wants.next(:solo)
      assert Wants.merge(wants, []) == [{:next, :solo}]
    end

    test "handles two empty lists" do
      assert Wants.merge([], []) == []
    end
  end

  describe "integration — output matches Crank.want type" do
    test "all builder outputs produce valid want tuples" do
      wants =
        Wants.new()
        |> Wants.timeout(100, :a)
        |> Wants.timeout(:named, 200, :b)
        |> Wants.cancel(:named)
        |> Wants.send(:logger, :log)
        |> Wants.telemetry([:x], %{}, %{})
        |> Wants.next(:auto)

      assert wants == [
               {:after, 100, :a},
               {:after, :named, 200, :b},
               {:cancel, :named},
               {:send, :logger, :log},
               {:telemetry, [:x], %{}, %{}},
               {:next, :auto}
             ]
    end

    test "builder output is usable as c:Crank.wants/2 return value" do
      defmodule WantsIntegrationMachine do
        @moduledoc false
        use Crank
        alias Crank.Wants

        @impl true
        def start(_), do: {:ok, :idle, %{count: 0}}

        @impl true
        def turn(:tick, :idle, memory), do: {:next, :running, memory}
        def turn(_, state, memory) when state != :idle, do: {:stay, memory}

        @impl true
        def wants(:running, memory) do
          Wants.new()
          |> Wants.timeout(100, :heartbeat)
          |> Wants.telemetry([:integration, :running], %{count: memory.count}, %{})
        end

        def wants(_, _), do: []
      end

      machine = Crank.new(WantsIntegrationMachine) |> Crank.turn(:tick)

      assert machine.state == :running

      assert machine.wants == [
               {:after, 100, :heartbeat},
               {:telemetry, [:integration, :running], %{count: 0}, %{}}
             ]
    end

    test "shared helper composes into per-machine wants" do
      defmodule SharedTelemetry do
        @moduledoc false
        alias Crank.Wants

        def entry(state, memory) do
          Wants.new()
          |> Wants.telemetry([:shared, :entry], %{}, %{state: state, memory: memory})
        end
      end

      defmodule WantsComposeMachine do
        @moduledoc false
        use Crank
        alias Crank.Wants

        @impl true
        def start(_), do: {:ok, :idle, %{}}

        @impl true
        def turn(:go, :idle, memory), do: {:next, :active, memory}

        @impl true
        def wants(state, memory) do
          SharedTelemetry.entry(state, memory)
          |> Wants.timeout(1_000, :refresh)
        end
      end

      machine = Crank.new(WantsComposeMachine) |> Crank.turn(:go)

      assert machine.wants == [
               {:telemetry, [:shared, :entry], %{}, %{state: :active, memory: %{}}},
               {:after, 1_000, :refresh}
             ]
    end
  end
end
