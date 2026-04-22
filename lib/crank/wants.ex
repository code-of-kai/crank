defmodule Crank.Wants do
  @moduledoc """
  Composable builder over `c:Crank.wants/2` effect declarations.

  Wants are plain tuples (see `t:Crank.want/0`). This module produces lists
  of those tuples through a pipe-friendly API. The wire format does not
  change — builder output and literal tuples are interchangeable, and both
  are interpreted by `Crank.Server` the same way.

  ## Why use a builder?

  Hand-written wants look like this:

      def wants(:accepting, memory) do
        base = [
          {:after, 60_000, :refund_timeout},
          {:telemetry, [:vending, :accepting], %{balance: memory.balance}, %{}}
        ]

        if memory.balance > 1000 do
          base ++ [{:send, :fraud_monitor, {:big_balance, memory.balance}}]
        else
          base
        end
      end

  With the builder:

      def wants(:accepting, memory) do
        Crank.Wants.new()
        |> Crank.Wants.timeout(60_000, :refund_timeout)
        |> Crank.Wants.telemetry([:vending, :accepting], %{balance: memory.balance}, %{})
        |> Crank.Wants.only_if(memory.balance > 1000,
             &Crank.Wants.send(&1, :fraud_monitor, {:big_balance, memory.balance}))
      end

  More importantly, shared policies become composable:

      # In a shared module:
      def standard_entry_telemetry(state, memory) do
        Crank.Wants.new()
        |> Crank.Wants.telemetry([:my_app, state], %{}, %{memory: memory})
      end

      # In every machine's wants/2:
      def wants(state, memory) do
        MyApp.Telemetry.standard_entry_telemetry(state, memory)
        |> Crank.Wants.timeout(5_000, :health_check)
      end

  ## Purity

  All functions in this module are pure. They build lists of tuples. Effects
  happen only when `Crank.Server` interprets the list — never at build time.
  `c:Crank.wants/2` itself must remain total and pure; raising in that
  callback crashes the process.

  ## Example

      iex> alias Crank.Wants
      iex> Wants.new()
      ...> |> Wants.timeout(60_000, :refund)
      ...> |> Wants.telemetry([:vending, :accepting], %{balance: 50}, %{})
      [{:after, 60_000, :refund}, {:telemetry, [:vending, :accepting], %{balance: 50}, %{}}]
  """

  @typedoc "A list of wants. Identical shape to `c:Crank.wants/2`'s return value."
  @type t :: [Crank.want()]

  @doc """
  Returns an empty wants list.

      iex> Crank.Wants.new()
      []
  """
  @spec new() :: t()
  def new, do: []

  @doc """
  Appends an anonymous state timeout. Fires `event` after `ms` milliseconds
  if the state has not changed. Only one anonymous state timeout per state;
  setting a new one replaces any pending timer. Auto-cancelled when the state
  value changes.

      iex> Crank.Wants.new() |> Crank.Wants.timeout(100, :tick)
      [{:after, 100, :tick}]
  """
  @spec timeout(t(), non_neg_integer(), term()) :: t()
  def timeout(wants, ms, event)
      when is_list(wants) and is_integer(ms) and ms >= 0 do
    wants ++ [{:after, ms, event}]
  end

  @doc """
  Appends a named generic timeout. Multiple named timeouts may run
  concurrently. Not auto-cancelled on state change; cancel explicitly with
  `cancel/2`.

      iex> Crank.Wants.new() |> Crank.Wants.timeout(:heartbeat, 5_000, :ping)
      [{:after, :heartbeat, 5_000, :ping}]
  """
  @spec timeout(t(), name :: term(), non_neg_integer(), term()) :: t()
  def timeout(wants, name, ms, event)
      when is_list(wants) and is_integer(ms) and ms >= 0 do
    wants ++ [{:after, name, ms, event}]
  end

  @doc """
  Appends a named-timeout cancellation. No-op if no such timer is active.

      iex> Crank.Wants.new() |> Crank.Wants.cancel(:heartbeat)
      [{:cancel, :heartbeat}]
  """
  @spec cancel(t(), name :: term()) :: t()
  def cancel(wants, name) when is_list(wants) do
    wants ++ [{:cancel, name}]
  end

  @doc """
  Appends a message-send want. `dest` is a pid, a registered name, or a
  `{name, node}` tuple. Fire-and-forget; no delivery verification.

      iex> Crank.Wants.new() |> Crank.Wants.send(:logger, {:info, "entering"})
      [{:send, :logger, {:info, "entering"}}]

  Prefer registered names over raw pids in machine definitions — they survive
  process restarts and are easier to stub in tests.
  """
  @spec send(t(), pid() | atom() | {atom(), node()}, term()) :: t()
  def send(wants, dest, message) when is_list(wants) do
    wants ++ [{:send, dest, message}]
  end

  @doc """
  Appends a telemetry event. `event_name` must be a list of atoms;
  `measurements` and `metadata` must be maps.

      iex> Crank.Wants.new()
      ...> |> Crank.Wants.telemetry([:app, :state, :entered], %{count: 1}, %{state: :idle})
      [{:telemetry, [:app, :state, :entered], %{count: 1}, %{state: :idle}}]
  """
  @spec telemetry(t(), [atom()], map(), map()) :: t()
  def telemetry(wants, event_name, measurements, metadata)
      when is_list(wants) and is_list(event_name) and is_map(measurements) and
             is_map(metadata) do
    wants ++ [{:telemetry, event_name, measurements, metadata}]
  end

  @doc """
  Appends an internal-event injection. The event is processed before any
  queued external event, after the current transition completes.

      iex> Crank.Wants.new() |> Crank.Wants.next(:auto_advance)
      [{:next, :auto_advance}]

  Use sparingly. An internal event decomposes one logical transition into
  two steps. For multi-step workflow orchestration across machines, write a
  saga (another Crank module) rather than chaining `:next` wants.
  """
  @spec next(t(), term()) :: t()
  def next(wants, event) when is_list(wants) do
    wants ++ [{:next, event}]
  end

  @doc """
  Conditionally extends the wants list. If `condition` is truthy, returns
  `fun.(wants)`; otherwise returns `wants` unchanged.

      iex> Crank.Wants.new()
      ...> |> Crank.Wants.only_if(true, &Crank.Wants.next(&1, :applied))
      [{:next, :applied}]

      iex> Crank.Wants.new()
      ...> |> Crank.Wants.only_if(false, &Crank.Wants.next(&1, :skipped))
      []

  `fun` must return a wants list — compose it from the other builder
  functions.
  """
  @spec only_if(t(), term(), (t() -> t())) :: t()
  def only_if(wants, condition, fun)
      when is_list(wants) and is_function(fun, 1) do
    if condition, do: fun.(wants), else: wants
  end

  @doc """
  Concatenates two wants lists. Useful for composing wants from multiple
  shared sources.

      iex> a = Crank.Wants.new() |> Crank.Wants.next(:one)
      iex> b = Crank.Wants.new() |> Crank.Wants.next(:two)
      iex> Crank.Wants.merge(a, b)
      [{:next, :one}, {:next, :two}]
  """
  @spec merge(t(), t()) :: t()
  def merge(a, b) when is_list(a) and is_list(b), do: a ++ b
end
