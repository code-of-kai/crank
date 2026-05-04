# CRANK_PURITY_002 — Discarded return value in turn/3

## What triggers this

A call inside `turn/3` whose return value is bound to `_` and discarded. The pattern `_ = some_call()` (or just `some_call()` as a side-effecting statement) is a tell that the author wanted the *effect* of the call, not its value.

```elixir
def turn(:notify, %Sending{} = state, memory) do
  _ = MyApp.Mailer.deliver(memory.email)   # CRANK_PURITY_002
  {:next, %Sent{}, memory}
end
```

## Why it's wrong

In a pure function, you do not call functions for their effects — you call them for their values. A discarded return is therefore either dead code (delete it) or a smuggled effect (move it). The catch-all `_ = expr` pattern hides which one it is, which is exactly what the check pushes back on.

This is a structural cousin of `CRANK_PURITY_001`: both move work that should live in adapters into the pure core. `CRANK_PURITY_002` is the version that even a syntactic blacklist would miss without the discard pattern, because the call's *target* may not look impure on the surface.

## How to fix

### Wrong

```elixir
def turn(:notify, %Sending{} = state, memory) do
  _ = MyApp.Mailer.deliver(memory.email)
  {:next, %Sent{}, memory}
end
```

### Right

```elixir
def turn(:notify, %Sending{} = state, memory) do
  {:next, %Sent{}, memory}
end

# wants/2 declares the effect; an adapter performs it.
def wants(%Sent{}, memory) do
  [{:telemetry, [:order, :sent], %{}, %{email: memory.email}}]
end
```

If the call really did produce a value the next state needs, capture it through the event payload at the boundary, not inline.

## How to suppress at this layer

Layer A — source-adjacent comment.

```elixir
# crank-allow: CRANK_PURITY_002
# reason: probe call required for legacy auditor; removed once v3 ships
_ = MyApp.LegacyAuditor.probe(memory.id)
```

## See also

- [`CRANK_PURITY_001`](CRANK_PURITY_001.md) — direct impure call (the more common cousin).
- [Hexagonal Architecture](../hexagonal-architecture.md).
- [Suppressions](../suppressions.md).
