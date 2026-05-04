# CRANK_META_003 — Suppression orphaned

## What triggers this

A `# crank-allow:` annotation has no following non-comment code line within 3 lines. The suppression sits over blank space, comments, or the end of the file.

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp


# (large gap, then unrelated code)         # CRANK_META_003
def turn(...)
```

The parser walks forward up to `@max_lookahead` (3) lines from the reason comment looking for a non-blank, non-comment line. If it doesn't find one, the annotation is orphaned.

## Why it's wrong

A suppression's job is to silence one specific line of code. If the line moved, was deleted, or never existed, the annotation no longer suppresses anything — but it stays in the source as a misleading marker. Future readers see `# crank-allow: CRANK_PURITY_004` and assume there's a `DateTime.utc_now()` somewhere nearby that's been deliberately exempted; in reality, there's nothing to exempt.

The 3-line lookahead is a deliberate bound: anything further away than that should be a separate suppression on the actual offending line.

## How to fix

Move the suppression directly above the line it's supposed to silence. If the line was deleted, delete the suppression too.

### Wrong

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp


# (gap)
@debug_now DateTime.utc_now()
```

### Right

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp
@debug_now DateTime.utc_now()
```

## How to suppress at this layer

`CRANK_META_003` cannot be suppressed. Move the annotation to the right line, or delete it.

## See also

- [Suppressions](../suppressions.md) — the 3-line lookahead rule.
- [`CRANK_META_001`](CRANK_META_001.md), [`CRANK_META_002`](CRANK_META_002.md), [`CRANK_META_004`](CRANK_META_004.md).
