# CRANK_PURITY_003 — Logger call inside turn/3

## What triggers this

Any call to `Logger.*` from inside a `turn/3` clause body. `Logger.info`, `Logger.warning`, `Logger.error` — every level is rejected.

```elixir
def turn({:coin, amount}, %Idle{}, memory) do
  Logger.info("coin inserted: #{amount}")    # CRANK_PURITY_003
  {:next, %Accepting{balance: amount}, memory}
end
```

## Why it's wrong

`Logger` is an effect: it writes to a backend, which under the hood may format JSON, ship to a remote sink, or trigger `:logger` filter callbacks. Calling it from `turn/3` makes the domain model depend on the logger backend's configuration, which is exactly the kind of implicit infrastructure coupling Crank is designed to keep out of the core.

The replacement is *telemetry-as-want*. Instead of calling Logger, declare a telemetry event the state arrival should emit. A logging adapter attached to that event decides what severity, what backend, and what filter it lives behind. The domain model says only "this happened"; the operator decides what to do with it.

## How to fix

### Wrong

```elixir
def turn({:coin, amount}, %Idle{}, memory) do
  Logger.info("coin inserted: #{amount}")
  {:next, %Accepting{balance: amount}, memory}
end
```

### Right

```elixir
def turn({:coin, amount}, %Idle{}, memory) do
  {:next, %Accepting{balance: amount}, memory}
end

def wants(%Accepting{balance: bal}, _memory) do
  [{:telemetry, [:vending, :coin_inserted], %{amount: bal}, %{}}]
end

# Attached at app boot:
:telemetry.attach("vending-log", [:vending, :coin_inserted], fn _, m, meta, _ ->
  Logger.info("coin inserted: #{m.amount}")
end, nil)
```

Same observable behaviour. The domain stayed pure; the logging concern moved to where it belongs.

## How to suppress at this layer

Layer A — source-adjacent comment.

```elixir
# crank-allow: CRANK_PURITY_003
# reason: dev-only diagnostics; this clause is never reached in :prod via guard
Logger.debug(inspect(memory))
```

## See also

- [Hexagonal Architecture](../hexagonal-architecture.md) — telemetry-as-want pattern.
- [`CRANK_PURITY_001`](CRANK_PURITY_001.md) — direct impure calls.
- [Suppressions](../suppressions.md).
