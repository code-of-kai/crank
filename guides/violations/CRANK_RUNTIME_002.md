# CRANK_RUNTIME_002 — Turn exceeded timeout

## What triggers this

A traced or supervised `turn/3` ran longer than the configured timeout.

- In `Crank.PurityTrace` (test/dev): the worker exceeds `:timeout` (default 1000ms) and `Process.monitor/1` reports a timeout.
- In `Crank.Server` Mode B (`turn_timeout` configured): `Task.yield(task, turn_timeout)` returns `nil`, `Task.shutdown(task, :brutal_kill)` fires, the gen_statem reports `CRANK_RUNTIME_002` and crashes.

The Mode B path is the one that justifies the out-of-process worker design: a same-process timer can't preempt a non-yielding callback, so the worker must be killable from outside.

```elixir
def turn(:compute, %Working{}, memory) do
  spin = fn -> spin.() end                # tight loop, never yields
  spin.()                                 # CRANK_RUNTIME_002 after turn_timeout
end
```

## Why it's wrong

A pure `turn/3` should be fast — milliseconds, not seconds. If a turn is taking too long, one of three things is true: the algorithm has runaway recursion, the work belongs in an adapter (so the gen_statem stays responsive), or the input is pathologically large and should be paginated.

`Crank.Server` Mode B's resource-limits design is opt-in *and* defensive — it exists to protect the rest of the supervision tree from a single bad turn, not to set a quality budget. If you're hitting timeouts under load, raising `turn_timeout` may be the right local move, but it's worth asking whether the work should leave `turn/3` entirely.

## How to fix

### Wrong

```elixir
def turn(:warm_cache, %Idle{}, memory) do
  warmed = Enum.map(1..1_000_000, &expensive_lookup/1)
  {:next, %Warm{data: warmed}, memory}
end
```

### Right

```elixir
# turn/3 stays cheap; warming runs as an adapter:
def turn(:warm_cache, %Idle{}, memory) do
  {:next, %Warming{}, memory}
end

def wants(%Warming{}, _memory) do
  [{:telemetry, [:cache, :warm_requested], %{}, %{}}]
end

# Adapter:
:telemetry.attach("warm-cache", [:cache, :warm_requested], fn _, _, _, _ ->
  Task.Supervisor.start_child(MyApp.TaskSupervisor, &warm_now/0)
end, nil)
```

If the work genuinely belongs in `turn/3` (small, deterministic, but heavy enough to need the cap raised):

```elixir
Crank.Server.start_link(MyMachine, init_args,
  resource_limits: [turn_timeout: 30_000]
)
```

## How to suppress at this layer

Layer C — programmatic option on test helpers. Source comments cannot suppress this code; attempting raises `CRANK_META_004`.

```elixir
test "long-running but bounded compute" do
  Crank.PropertyTest.assert_pure_turn(machine, events, timeout: 10_000)
end
```

## See also

- [`CRANK_RUNTIME_001`](CRANK_RUNTIME_001.md) — heap exhaustion.
- [Property testing](../property-testing.md).
- [Suppressions](../suppressions.md).
