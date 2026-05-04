# CRANK_DEP_002 — Unmarked domain helper

## What triggers this

In Boundary's strict mode, a domain module references a first-party helper module that is not classified as `:domain` (via `use Crank.Domain.Pure`) and not classified as `:infrastructure`. The helper is in your own application — it isn't a third-party dependency — but its purity status is undeclared.

```elixir
defmodule MyApp.OrderMachine do
  use Crank
  def turn(:place, %Pending{}, memory) do
    total = MyApp.OrderMath.total(memory.lines)    # CRANK_DEP_002 — OrderMath unmarked
    {:next, %Confirmed{total: total}, memory}
  end
end

defmodule MyApp.OrderMath do
  # No `use Crank.Domain.Pure`; Boundary doesn't know which side this lives on.
  def total(lines), do: Enum.sum(Enum.map(lines, & &1.amount))
end
```

*(Track A implementation: ships with `Crank.BoundaryIntegration`.)*

## Why it's wrong

Strict mode treats unclassified first-party modules as a topology hole. Without a marker, Boundary cannot decide whether the helper belongs to the domain (and therefore must itself be pure) or to infrastructure (and therefore should not be called from a domain module). The architectural cut runs through your code; every first-party module either belongs on one side or the other.

The fix is one line of code at the helper. `use Crank.Domain.Pure` does two things: it tags the helper as part of the domain so Boundary lets the call through, *and* it subjects the helper's bodies to the same call-site blacklist (`CRANK_PURITY_001..006`) that `turn/3` answers to. The helper becomes a first-class domain citizen, not an unclassified gap.

## How to fix

### Wrong

```elixir
defmodule MyApp.OrderMath do
  def total(lines), do: Enum.sum(Enum.map(lines, & &1.amount))
end
```

### Right

```elixir
defmodule MyApp.OrderMath do
  use Crank.Domain.Pure

  def total(lines), do: Enum.sum(Enum.map(lines, & &1.amount))
end
```

If the helper genuinely *is* infrastructure (it talks to a database, hits a network), don't mark it pure — move the call into an adapter on the telemetry boundary. See `CRANK_DEP_001` for that case.

## How to suppress at this layer

Layer B — Boundary configuration. The clean fix is to mark the helper. Suppression should be reserved for transitional cases.

```elixir
# In your Boundary config:
boundary [
  ...,
  exceptions: [
    {MyApp.OrderMachine, MyApp.OrderMath,
      reason: "in-flight migration; OrderMath gets the marker in PR #4421"}
  ]
]
```

## See also

- [Boundary setup](../boundary-setup.md) — strict mode and the `:domain` cut.
- [`CRANK_DEP_001`](CRANK_DEP_001.md) — domain → infrastructure references.
- [Suppressions](../suppressions.md).
