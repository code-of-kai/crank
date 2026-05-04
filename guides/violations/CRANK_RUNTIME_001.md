# CRANK_RUNTIME_001 — Heap exhaustion during turn

## What triggers this

A traced or supervised `turn/3` allocated past the configured `:max_heap_size` cap. The BEAM kills the process; Crank reports the violation.

- In `Crank.PurityTrace` (test/dev): the worker process the trace runs in hits its heap limit.
- In `Crank.Server` (Mode B, `turn_timeout` configured): the worker spawned by `Crank.TaskSupervisor` hits its heap limit and exits, the gen_statem reports `CRANK_RUNTIME_001` and crashes.

```elixir
def turn(:expand, %Building{}, memory) do
  giant = Enum.reduce(1..1_000_000_000, [], &[&1 | &2])    # blows past max_heap_size
  {:next, %Built{data: giant}, memory}
end
```

## Why it's wrong

A pure `turn/3` should not produce unbounded allocations. Either the algorithm has a bug (an off-by-one creating a runaway accumulator), or the data shape is wrong (you're materialising a stream that should stay lazy), or the work genuinely doesn't belong in `turn/3` (move it to an adapter).

The cap is a backstop, not a budget. If you're hitting it during normal operation, the right fix is to bound the allocation in the algorithm — not to raise the cap. Raising the cap on a leaky algorithm just delays the same crash.

## How to fix

### Wrong

```elixir
def turn(:expand, %Building{} = state, memory) do
  full = Enum.to_list(memory.stream)
  {:next, %Built{data: full}, memory}
end
```

### Right

```elixir
# Keep the stream lazy; consume at the boundary, not in turn/3.
def turn(:expand, %Building{}, memory) do
  {:next, %Built{}, memory}
end

# Adapter on [:crank, :transition] reads memory.stream lazily and writes incrementally.
```

If raising the cap really *is* the right answer (a domain that genuinely needs more memory), do it explicitly at `Crank.Server.start_link/3`:

```elixir
Crank.Server.start_link(MyMachine, init_args,
  resource_limits: [max_heap_size: 200_000_000]
)
```

## How to suppress at this layer

Layer C — programmatic `:allow` opt on test helpers. Source comments cannot suppress this code (the violation has no static source line); attempting raises `CRANK_META_004`.

```elixir
test "computation that needs the larger heap" do
  Crank.PropertyTest.assert_pure_turn(machine, events,
    max_heap_size: 200_000_000,
    allow: []
  )
end
```

## See also

- [Property testing](../property-testing.md).
- [`CRANK_RUNTIME_002`](CRANK_RUNTIME_002.md) — turn timeout.
- [Suppressions](../suppressions.md) — Layer C details.
