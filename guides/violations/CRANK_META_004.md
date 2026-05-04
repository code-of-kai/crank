# CRANK_META_004 — Suppression at the wrong layer

## What triggers this

A `# crank-allow:` annotation references a code that the source-comment layer cannot suppress. Layer A handles `:static_call_site`, `:type`, and `:meta` codes only; topology codes (`CRANK_DEP_*`) and runtime codes (`CRANK_PURITY_007`, `CRANK_RUNTIME_*`, `CRANK_TRACE_*`) belong to other mechanisms.

```elixir
# crank-allow: CRANK_DEP_001               # CRANK_META_004 — DEP_001 is Layer B
# reason: ...
alias MyApp.Repo
```

The parser consults `Crank.Errors.Catalog.suppressible_by(:layer_a)` and rejects any code whose layer doesn't appear there.

## Why it's wrong

The three layers exist for a reason: they observe violations at fundamentally different phases.

- **Layer A** (source-adjacent comments) operates at the AST level. It can silence violations that have a direct source-line anchor.
- **Layer B** (Boundary configuration) operates at the dependency graph. Topology violations don't have a single line — they're a fact about a module pair.
- **Layer C** (programmatic `:allow` opt) operates at the trace level. Runtime observations may originate in a transitive helper whose source line is far from the test asserting purity.

Letting one layer's mechanism silence another layer's violations would create the illusion of suppression while leaving the real check unaffected. `CRANK_META_004` makes the mismatch loud and points at the correct mechanism.

## How to fix

Use the right mechanism for the code's layer.

### Wrong (DEP_001 silenced via comment — does nothing)

```elixir
# crank-allow: CRANK_DEP_001
# reason: legacy adapter
defmodule MyApp.OrderMachine do
  use Crank
  alias MyApp.Repo
end
```

### Right (DEP_001 silenced via Boundary config)

```elixir
# In your Boundary config:
boundary [
  ...,
  exceptions: [
    {MyApp.OrderMachine, MyApp.Repo,
      reason: "legacy import; removed when adapter pattern lands in PR #4423"}
  ]
]
```

For runtime codes (`CRANK_PURITY_007`, `CRANK_RUNTIME_*`, `CRANK_TRACE_*`), use the `:allow` opt:

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  allow: [
    {Decimal, :_, :_, reason: "trusted pure dependency"}
  ]
)
```

## How to suppress at this layer

`CRANK_META_004` cannot be suppressed; it is the rule that makes layer mismatches visible. Fix the mismatch.

## See also

- [Suppressions](../suppressions.md) — full treatment of the three mechanisms.
- [Boundary setup](../boundary-setup.md).
- [`CRANK_META_001`](CRANK_META_001.md), [`CRANK_META_002`](CRANK_META_002.md), [`CRANK_META_003`](CRANK_META_003.md).
