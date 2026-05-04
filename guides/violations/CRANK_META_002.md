# CRANK_META_002 — Suppression references unknown code

## What triggers this

A `# crank-allow:` annotation names a code that is not in the frozen catalog (`Crank.Errors.Catalog`).

```elixir
# crank-allow: CRANK_PURITY_999            # CRANK_META_002 — not in catalog
# reason: ...
some_call()
```

The parser checks every code against `Catalog.codes/0`; misspellings, retired codes, and codes from a future major version all trigger this rule.

## Why it's wrong

The catalog is the closed set of identifiers Crank guarantees stable across major versions. A misspelled code silently silences nothing — the violation will keep firing because no real code matches — but it looks like a working suppression. Teams discover the issue only when the underlying violation appears in CI long after the original suppression was written.

The rule fires loudly so authors know immediately that the suppression is dead.

## How to fix

Look up the correct code. The catalog is documented at [the violations index](index.md). Each error message in CI / Credo also includes the canonical code in `[CRANK_X_NNN]` brackets — copy it directly from there.

### Wrong

```elixir
# crank-allow: CRANK_PURITTY_001
# reason: legacy import path
MyApp.Repo.all(...)
```

### Right

```elixir
# crank-allow: CRANK_PURITY_001
# reason: legacy import path; will be removed in v2.0
MyApp.Repo.all(...)
```

## How to suppress at this layer

`CRANK_META_002` cannot be suppressed. Spell the code correctly.

## See also

- [Violations index](index.md) — every catalog code with one-line descriptions.
- [Suppressions](../suppressions.md).
- [`CRANK_META_001`](CRANK_META_001.md), [`CRANK_META_003`](CRANK_META_003.md), [`CRANK_META_004`](CRANK_META_004.md).
