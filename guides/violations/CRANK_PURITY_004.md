# CRANK_PURITY_004 — Time or randomness inside turn/3

## What triggers this

Any call to a non-deterministic stdlib function from inside `turn/3`. The blacklist covers `DateTime.utc_now`, `Date.utc_today`, `Time.utc_now`, `NaiveDateTime.utc_now`, `:rand.*`, `:random.*`, `System.os_time`, `System.system_time`, `System.monotonic_time`, `:erlang.system_time`, `:erlang.monotonic_time`, `:erlang.unique_integer`, `make_ref/0`, `self/0`, `node/0`.

```elixir
def turn(:place, %Pending{}, memory) do
  now = DateTime.utc_now()                          # CRANK_PURITY_004
  {:next, %Confirmed{at: now}, memory}
end
```

## Why it's wrong

The whole point of a pure `turn/3` is that the same `(event, state, memory)` always returns the same `(state', memory')`. Time and randomness break that property: two replays of the same event sequence produce different results. Snapshot/resume becomes lossy. Property tests that find a failure can't reliably reproduce it. Event sourcing loses determinism in the fold.

Sample the value at the boundary and pass it in. The application service is allowed to read the clock; it then puts the timestamp into the event payload. Inside `turn/3` you only ever see the value, not the source.

## How to fix

### Wrong

```elixir
def turn(:place, %Pending{}, memory) do
  now = DateTime.utc_now()
  {:next, %Confirmed{at: now}, memory}
end
```

### Right

```elixir
# Application service samples the clock at the boundary:
def place_order(machine) do
  Crank.turn(machine, {:place, at: DateTime.utc_now()})
end

# turn/3 receives the value:
def turn({:place, at: now}, %Pending{}, memory) do
  {:next, %Confirmed{at: now}, memory}
end
```

Same applies to randomness (`{:place, token: :rand.bytes(16)}`) and to identifiers (`{:place, id: Ecto.UUID.generate()}`). Source the entropy at the edge; carry the value through the event.

## How to suppress at this layer

Layer A — source-adjacent comment.

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp; never reached in production paths
@debug_now DateTime.utc_now()
```

## See also

- [Transitions and guards](../transitions-and-guards.md).
- [Property testing](../property-testing.md) — why determinism matters for shrinking.
- [Suppressions](../suppressions.md).
