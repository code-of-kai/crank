# CRANK_PURITY_007 — Transitive impurity observed at runtime

## What triggers this

`Crank.PurityTrace` ran a turn and observed an impure call somewhere in the call graph — not directly in `turn/3`'s body, but in a helper module the body called. The static call-site checks (`CRANK_PURITY_001..006`) only see what's lexically in the `turn/3` clause. Anything deeper requires the runtime trace.

```elixir
defmodule MyApp.OrderMachine do
  use Crank
  def turn(:place, %Pending{}, memory) do
    {:next, %Confirmed{id: MyApp.IdGen.next()}, memory}    # looks pure here
  end
end

defmodule MyApp.IdGen do
  def next, do: :erlang.unique_integer()                    # caught at runtime
end
```

The trace fires `CRANK_PURITY_007` naming `:erlang.unique_integer/0` and the path through `MyApp.IdGen.next/0`. *(Track B implementation: `Crank.PurityTrace` ships in the Stage 7 work.)*

## Why it's wrong

The transitive case is the one most likely to slip past code review. `MyApp.IdGen.next/0` looks pure at the call site; only by stepping into the helper does the impurity become visible. That's exactly what `Crank.PurityTrace` mechanises — it observes every call from inside the worker and reports any blacklist match anywhere in the dynamic call graph.

The fix has the same shape as the static-layer fixes: lift the impurity out of the helper, or mark the helper with `use Crank.Domain.Pure` and fix the impurity inside it (so the static layer catches it at compile time too). What you cannot do is leave the helper impure and route around `turn/3`'s purity guarantee — the trace will keep failing.

## How to fix

### Wrong

```elixir
defmodule MyApp.IdGen do
  def next, do: :erlang.unique_integer()
end
```

### Right

```elixir
# Option A: sample at the boundary, pass through the event.
defmodule MyApp.OrderMachine do
  def turn({:place, id}, %Pending{}, memory) do
    {:next, %Confirmed{id: id}, memory}
  end
end

# Option B: mark the helper, then make it pure.
defmodule MyApp.IdGen do
  use Crank.Domain.Pure
  def next(seed), do: :erlang.phash2(seed)   # deterministic, takes input
end
```

If the helper is third-party code you can't modify, and the call really is benign for your purposes, classify the app as `:third_party_pure` in Boundary config (see [boundary-setup](../boundary-setup.md)) and use a Layer C `:allow` opt to silence the trace.

## How to suppress at this layer

Layer C — programmatic `:allow` opt on the property test or trace call. Source comments cannot suppress this code; attempting raises `CRANK_META_004`.

```elixir
test "order machine is pure" do
  Crank.PropertyTest.assert_pure_turn(machine, events,
    allow: [
      {Decimal, :_, :_, reason: "trusted pure dependency"}
    ]
  )
end
```

## See also

- [Property testing](../property-testing.md) — how the trace integrates with StreamData.
- [Boundary setup](../boundary-setup.md) — classifying third-party apps.
- [Suppressions](../suppressions.md) — Layer C details.
