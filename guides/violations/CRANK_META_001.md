# CRANK_META_001 — Suppression missing reason

## What triggers this

A `# crank-allow:` annotation has no `# reason:` comment immediately after it. The reason field is required.

```elixir
# crank-allow: CRANK_PURITY_004           # no `# reason:` line — CRANK_META_001
@debug_now DateTime.utc_now()
```

The parser in [`Crank.Suppressions`](../suppressions.md) raises this when it consumes the annotation but does not find a reason on the next line.

## Why it's wrong

Suppressions are deliberate exceptions to a rule. The reason field forces the author to articulate *why*, in plain language, this exception is justified. A bare `# crank-allow:` is the suppression equivalent of `# TODO`: it admits the rule but commits to nothing. Six months later, when someone reads the file, the reason is the only thing that says whether the suppression is still load-bearing or whether the workaround it was for has been gone for years.

The check is mechanical — it does not validate that the reason is *good*. But the existence of any reason at all is a strong signal in code review. The author had to think about the explanation; the reviewer has something concrete to push back on.

## How to fix

### Wrong

```elixir
# crank-allow: CRANK_PURITY_004
@debug_now DateTime.utc_now()
```

### Right

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp; never reached in production paths
@debug_now DateTime.utc_now()
```

## How to suppress at this layer

`CRANK_META_001` itself cannot be suppressed. It is the rule that protects suppression hygiene. Add the missing reason instead.

## See also

- [Suppressions](../suppressions.md).
- [`CRANK_META_002`](CRANK_META_002.md), [`CRANK_META_003`](CRANK_META_003.md), [`CRANK_META_004`](CRANK_META_004.md).
