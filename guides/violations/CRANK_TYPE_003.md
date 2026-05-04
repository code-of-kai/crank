# CRANK_TYPE_003 — Unknown state returned from turn/3

## What triggers this

A `turn/3` clause returns a state value that is not in the declared state union (the `:states` option to `use Crank, ...`). Caught by `@before_compile` AST analysis when the macro form is used.

```elixir
use Crank,
  states: [Idle, Accepting, Dispensing],
  memory: MyApp.VendingMemory

def turn(:reject, %Accepting{}, memory) do
  {:next, %Refunding{}, memory}    # CRANK_TYPE_003 — :Refunding not in declared union
end
```

*(Track A implementation: ships with the macro form in 1.7. Severity is `:warning`, not `:error` — the static analysis is best-effort because state values can be computed at runtime.)*

## Why it's wrong

The declared state union is a closure of "what counts as a state for this machine." If `turn/3` can return a state outside that closure, two things break: the type-checker (Dialyzer / set-theoretic types) cannot reason about the machine's full behaviour, and snapshot consumers (event sourcers, persistence adapters) may receive shapes they don't know how to deserialise.

This is the cousin of the future "compile-time exhaustiveness" goal in `DESIGN.md`: when Elixir's set-theoretic types fully cover this case, unhandled returns will be a hard compile error. Until then, Crank's macro form provides best-effort detection at the warning level — enough to catch typos and copy-paste mistakes, not enough to prove totality.

## How to fix

### Wrong

```elixir
use Crank,
  states: [Idle, Accepting, Dispensing]

def turn(:reject, %Accepting{}, memory) do
  {:next, %Refunding{}, memory}
end
```

### Right

```elixir
# Add the state to the declared union:
use Crank,
  states: [Idle, Accepting, Dispensing, Refunding]

def turn(:reject, %Accepting{}, memory) do
  {:next, %Refunding{}, memory}
end

defmodule Refunding do
  defstruct [:amount]
end
```

Or, if the return was wrong in the first place, change it to one of the declared states.

## How to suppress at this layer

Layer A — source-adjacent comment. The signal is usually right; suppression should be rare.

```elixir
# crank-allow: CRANK_TYPE_003
# reason: experimental state still being designed; merged before 1.0 cut
{:next, %ProvisionalState{}, memory}
```

## See also

- [Typing state and memory](../typing-state-and-memory.md) — declaring the state union.
- [DESIGN.md](../../DESIGN.md) — "Compiler-checked exhaustiveness (future)".
- [`CRANK_TYPE_001`](CRANK_TYPE_001.md), [`CRANK_TYPE_002`](CRANK_TYPE_002.md).
- [Suppressions](../suppressions.md).
