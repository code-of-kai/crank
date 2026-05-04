# Violations index

Every Crank purity-enforcement violation has a stable code, a frozen rule name, and a doc page. The catalog is part of Crank's public API: codes do not rename across major versions, and additions are non-breaking. The full list lives below; the source of truth is `Crank.Errors.Catalog`.

For the discipline behind these rules, start with [Hexagonal Architecture](../hexagonal-architecture.md). For the suppression mechanisms (one per layer), see [Suppressions](../suppressions.md).

## Call-site purity (Layer A — source-comment suppressible)

These fire at compile time via the `@before_compile` hook (hard `CompileError`) and at editor time via the Credo check (warning). Both share the blacklist via `Crank.Check.Blacklist`.

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_PURITY_001](CRANK_PURITY_001.md) | turn-purity-direct | Direct impure call inside `turn/3` body. |
| [CRANK_PURITY_002](CRANK_PURITY_002.md) | turn-purity-discarded | Discarded return value (`_ = some_call()`) inside `turn/3`. |
| [CRANK_PURITY_003](CRANK_PURITY_003.md) | turn-purity-logger | `Logger.*` call inside `turn/3`. |
| [CRANK_PURITY_004](CRANK_PURITY_004.md) | turn-purity-nondeterminism | Time, randomness, or identity call inside `turn/3`. |
| [CRANK_PURITY_005](CRANK_PURITY_005.md) | turn-purity-process-comm | `send/2`, `Task`, `spawn`, `GenServer` inside `turn/3`. |
| [CRANK_PURITY_006](CRANK_PURITY_006.md) | turn-purity-ambient-state | ETS, persistent_term, process dict, config, file IO. |

## Topology (Layer B — Boundary config suppressible)

Post-compile graph check delegated to Boundary. Wired automatically by `mix crank.gen.config`; if missing, fires `CRANK_SETUP_001` from `mix crank.check`.

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_DEP_001](CRANK_DEP_001.md) | dependency-direction | Domain module references infrastructure module. |
| [CRANK_DEP_002](CRANK_DEP_002.md) | unmarked-domain-helper | Domain module calls unmarked first-party helper (strict mode). |
| [CRANK_DEP_003](CRANK_DEP_003.md) | unclassified-external-dep | Domain module calls a third-party app not classified in Boundary config. |

## Type-level (Layer A — source-comment suppressible)

Caught natively by Elixir's struct semantics, the `@before_compile` hook, and the macro form (`use Crank, states: [...], memory: ...`).

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_TYPE_001](CRANK_TYPE_001.md) | memory-field-unknown | Struct-update or struct-literal references a field not declared in the memory struct. |
| [CRANK_TYPE_002](CRANK_TYPE_002.md) | function-in-memory | Function or module value declared in memory or state typespec. |
| [CRANK_TYPE_003](CRANK_TYPE_003.md) | unknown-state-returned | `turn/3` returns a state not in the declared state union. |

## Runtime trace (Layer C — `:allow` opt suppressible)

Observed by `Crank.PurityTrace` during property tests and traced runs. Source comments cannot suppress runtime codes — attempts raise `CRANK_META_004`.

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_PURITY_007](CRANK_PURITY_007.md) | turn-purity-transitive | Trace observed an impure call via a helper. |
| [CRANK_RUNTIME_001](CRANK_RUNTIME_001.md) | resource-heap | Heap exhaustion observed during traced turn. |
| [CRANK_RUNTIME_002](CRANK_RUNTIME_002.md) | resource-timeout | Turn exceeded timeout. |
| [CRANK_TRACE_001](CRANK_TRACE_001.md) | atom-table-mutation | New atom created during turn. |
| [CRANK_TRACE_002](CRANK_TRACE_002.md) | process-dict-mutation | Process dictionary modified during turn. |

## Suppression hygiene (meta — not suppressible)

The rules that protect the suppression system itself. None of these are suppressible — they are the guard rails.

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_META_001](CRANK_META_001.md) | suppression-missing-reason | `# crank-allow:` annotation without `# reason:` follow-up. |
| [CRANK_META_002](CRANK_META_002.md) | suppression-unknown-code | `# crank-allow:` references a code not in the catalog. |
| [CRANK_META_003](CRANK_META_003.md) | suppression-orphaned | `# crank-allow:` annotation with no following code line within 3 lines. |
| [CRANK_META_004](CRANK_META_004.md) | suppression-wrong-layer | `# crank-allow:` references a code that this layer cannot suppress. |

## Setup (not suppressible)

Boot-time and CI-time guards. Failing these means the project hasn't completed Crank's setup.

| Code | Rule | What it catches |
|---|---|---|
| [CRANK_SETUP_001](CRANK_SETUP_001.md) | boundary-not-wired | Project lacks `:crank` in `:compilers`. |
| [CRANK_SETUP_002](CRANK_SETUP_002.md) | otp-version-too-old | Runtime OTP < 26. |

## Reading order

If you've never touched the enforcement system before:

1. [Hexagonal Architecture](../hexagonal-architecture.md) — why the boundary exists.
2. [Suppressions](../suppressions.md) — the three layers and when each fires.
3. [Boundary setup](../boundary-setup.md) — wiring the topology layer.
4. [Property testing](../property-testing.md) — what runtime tracing buys.
5. [Typing state and memory](../typing-state-and-memory.md) — how tight typing makes the type layer load-bearing.
