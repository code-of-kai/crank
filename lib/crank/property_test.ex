defmodule Crank.PropertyTest do
  @moduledoc """
  Helpers for testing Crank machines under runtime purity tracing.

  Bridges `Crank.PurityTrace` (Phase 2.1) with the StreamData /
  ExUnitProperties workflow. Given a machine and a list of events, every
  `Crank.turn/2` call runs inside an isolated trace session; any forbidden
  call observed during the turn fails the property.

  Combined with `StreamData` event generators, this turns a property test
  into a purity test for free: shrinking produces a minimal failing event
  sequence, and the failure message names the offending MFA.

  ## Example

      defmodule MyMachineTest do
        use ExUnit.Case
        use ExUnitProperties
        import Crank.PropertyTest

        property "MyMachine.turn/3 is pure across any event sequence" do
          check all events <- list_of(my_event_generator(), max_length: 50) do
            machine = Crank.new(MyMachine)
            assert_pure_turn(machine, events)
          end
        end
      end

  ## Layer-C suppression

  Both `turn_traced/3` and `assert_pure_turn/3` accept an `:allow` keyword
  that delegates to `Crank.PurityTrace`. Each entry must include a
  `:reason`; `[:crank, :suppression]` telemetry fires with `layer: :c`.

      assert_pure_turn(machine, events,
        allow: [
          {Decimal, :_, :_, reason: "trusted pure dependency"}
        ]
      )

  Source-comment suppressions (`# crank-allow:`) cannot silence a
  `CRANK_PURITY_007` violation observed at runtime — there is no source line
  to anchor against. Attempting it raises `CRANK_META_004`. Use the
  `:allow` opt instead.
  """

  alias Crank.PurityTrace

  @typedoc """
  Result of `turn_traced/3`. The `:ok` tuple carries the per-step machine
  list (in event order). Failure shapes carry the partial machine list, the
  partial trace, and the failing event so callers can format actionable
  errors and so StreamData has a meaningful counterexample to shrink.
  """
  @type traced_result ::
          {:ok, [Crank.t()]}
          | {:impurity, [Crank.Errors.Violation.t()], [Crank.t()], [PurityTrace.trace_event()],
             event :: term()}
          | {:resource_exhausted, :heap | :timeout, [Crank.t()],
             [PurityTrace.trace_event()], event :: term()}

  @doc """
  Runs `events` through `machine`, tracing each `Crank.turn/2` call.

  Returns `{:ok, machines}` if every turn was pure, where `machines` is the
  list `[initial | after_event_1, after_event_2, ...]` in event order. On
  the first impure or resource-exhausted turn, returns the corresponding
  failure tuple along with the partial machine list, the partial trace,
  and the offending event — exactly the information StreamData needs to
  produce a minimal failing input.

  Options are forwarded to `Crank.PurityTrace.trace_pure/2`. See its
  moduledoc for the full list (`:timeout`, `:max_heap_size`,
  `:forbidden_modules`, `:allow`, `:atom_table_check`).
  """
  @spec turn_traced(Crank.t(), [term()], keyword()) :: traced_result()
  def turn_traced(%Crank{} = machine, events, opts \\ []) when is_list(events) do
    do_turn_traced(events, [machine], opts)
  end

  defp do_turn_traced([], acc, _opts), do: {:ok, Enum.reverse(acc)}

  defp do_turn_traced([event | rest], [last | _] = acc, opts) do
    case PurityTrace.trace_pure(fn -> Crank.turn(last, event) end, opts) do
      {:ok, %Crank{} = next, _trace} ->
        do_turn_traced(rest, [next | acc], opts)

      {:ok, other, _trace} ->
        # `Crank.turn/2` is supposed to return a `%Crank{}`; if it didn't,
        # surface that as a property failure rather than swallowing.
        machines = Enum.reverse(acc)

        violation =
          Crank.Errors.build("CRANK_TYPE_003",
            context: "Crank.turn/2 returned non-%Crank{} value: #{inspect(other)}",
            metadata: %{layer: :runtime, returned: other}
          )

        {:impurity, [violation], machines, [], event}

      {:impurity, violations, trace} ->
        {:impurity, violations, Enum.reverse(acc), trace, event}

      {:resource_exhausted, kind, trace} ->
        {:resource_exhausted, kind, Enum.reverse(acc), trace, event}
    end
  end

  @doc """
  Asserts that running `event_or_events` through `machine` produces no
  impure calls or resource exhaustion.

  Returns the final `%Crank{}` on success. Raises `ExUnit.AssertionError`
  on failure with a message that names the offending event, the offending
  MFA(s), the partial event sequence consumed so far, and the canonical fix
  suggestion from each violation.

  Accepts a single event or a list. A bare event is treated as `[event]`.
  Options are forwarded to `Crank.PurityTrace.trace_pure/2`.
  """
  @spec assert_pure_turn(Crank.t(), term() | [term()], keyword()) :: Crank.t()
  def assert_pure_turn(machine, event_or_events, opts \\ [])

  def assert_pure_turn(%Crank{} = machine, events, opts) when is_list(events) do
    case turn_traced(machine, events, opts) do
      {:ok, machines} ->
        List.last(machines)

      {:impurity, violations, machines, _trace, event} ->
        raise ExUnit.AssertionError,
          message: format_impurity(violations, event, events, machines)

      {:resource_exhausted, kind, machines, _trace, event} ->
        raise ExUnit.AssertionError,
          message: format_exhausted(kind, event, events, machines)
    end
  end

  def assert_pure_turn(%Crank{} = machine, event, opts) do
    assert_pure_turn(machine, [event], opts)
  end

  # ── Failure formatting ────────────────────────────────────────────────────

  defp format_impurity(violations, event, all_events, machines_so_far) do
    """
    Crank turn observed impure call(s) during traced run.

    Failing event:    #{inspect(event)}
    Event index:      #{length(machines_so_far) - 1}
    Event sequence:   #{inspect(all_events)}
    Machine before:   #{inspect(state_summary(List.last(machines_so_far)))}

    Violations:
    #{Enum.map_join(violations, "\n\n", &Crank.Errors.format_pretty/1)}
    """
  end

  defp format_exhausted(kind, event, all_events, machines_so_far) do
    code =
      case kind do
        :heap -> "CRANK_RUNTIME_001"
        :timeout -> "CRANK_RUNTIME_002"
      end

    """
    Crank turn exceeded resource limit during traced run.

    Failing event:    #{inspect(event)}
    Event index:      #{length(machines_so_far) - 1}
    Event sequence:   #{inspect(all_events)}
    Machine before:   #{inspect(state_summary(List.last(machines_so_far)))}
    Limit kind:       #{kind}
    Catalog code:     #{code}
    """
  end

  defp state_summary(%Crank{module: m, state: s, memory: mem}),
    do: %{module: m, state: s, memory: mem}

  defp state_summary(other), do: other
end
