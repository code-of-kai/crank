# Suppressions

Crank's enforcement system has three suppression mechanisms — one per layer. They look different on purpose. The reasons are mechanical (each layer observes violations differently), and trying to force one mechanism would either miss layers or build a fake-unified system that breaks under real diagnostics.

This guide documents all three side-by-side, explains when each fires, and shows what trying to use the wrong mechanism produces.

## The three layers at a glance

| Layer | Where violations originate | Suppression mechanism | Codes |
|---|---|---|---|
| **A** | AST walk (Credo, `@before_compile`) | Source-adjacent `# crank-allow:` comment | `CRANK_PURITY_001..006`, `CRANK_TYPE_001..003`, `CRANK_META_001..004` |
| **B** | Boundary post-compile graph check | Boundary config `:exceptions` entry | `CRANK_DEP_001..003` |
| **C** | Runtime trace (`Crank.PurityTrace`) | Programmatic `:allow` opt | `CRANK_PURITY_007`, `CRANK_RUNTIME_001..002`, `CRANK_TRACE_001..002` |

Setup codes (`CRANK_SETUP_001..002`) are not suppressible — they are the boot-time guards that ensure Crank is wired correctly.

## Layer A: source-adjacent comments

For violations that have a single source line — a Credo issue, a `@before_compile` AST match — the suppression goes immediately above that line.

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp; never reached in production paths
@debug_now DateTime.utc_now()
```

### Rules

- The `# reason:` comment is **required** on the next line. Missing it raises `CRANK_META_001`.
- The suppression applies to the **next non-comment code line** within 3 lines. Beyond that, raises `CRANK_META_003` (orphaned).
- The referenced code must be in the catalog. Unknown codes raise `CRANK_META_002`.
- The referenced code must be suppressible by Layer A. Topology codes (`CRANK_DEP_*`) and runtime codes (`CRANK_PURITY_007`, `CRANK_RUNTIME_*`, `CRANK_TRACE_*`) raise `CRANK_META_004` with a pointer to the right mechanism.
- Multiple codes can be listed on one annotation: `# crank-allow: CRANK_PURITY_004, CRANK_PURITY_005`.
- Each suppression emits a `[:crank, :suppression]` telemetry event with `layer: :a` so projects can audit how often each suppression fires.

### Implementation

`Crank.Suppressions.parse/1` walks the source comments alongside the AST, builds a line-keyed suppression map, and `Crank.Suppressions.suppressed?/2` is consulted before any check raises. The Credo check (`Crank.Check.TurnPurity`) and the `@before_compile` hook (`Crank.Check.CompileTime`) both use the same parser, so the syntax is identical between them.

### Worked example

```elixir
defmodule MyApp.OrderMachine do
  use Crank

  # crank-allow: CRANK_PURITY_004
  # reason: dev-only debug timestamp; this clause is gated by Mix.env() == :dev
  @compile_time_now DateTime.utc_now()

  def turn({:debug, _}, %Idle{}, memory) do
    {:stay, %{memory | last_debug_at: @compile_time_now}}
  end

  ...
end
```

The annotation silences the static check for the `DateTime.utc_now/0` call on line 6. The reason explains that the call is dev-only — anyone reviewing this can verify whether the gate is real and whether the suppression should still exist.

## Layer B: Boundary configuration

For topology violations — domain referencing infrastructure, unmarked first-party helpers, unclassified third-party apps — the suppression goes into the Boundary config. There is no single source line that "owns" the violation; it's a fact about the dependency graph between two modules.

```elixir
# config/boundary.exs
config :my_app, Boundary,
  ...,
  exceptions: [
    {MyApp.LegacyOrderImporter, MyApp.Repo,
      reason: "legacy import path; will be removed in v2.0"}
  ]
```

### Rules

- The `:reason` field is **required**. Boundary's wrapper validates this at config-load time.
- Each entry is a `{from_module, to_module, opts}` tuple. The exception applies only to references between exactly those two modules.
- Each suppression emits a `[:crank, :suppression]` telemetry event with `layer: :b` when Boundary runs.
- Source comments cannot suppress topology violations. Attempting (`# crank-allow: CRANK_DEP_001`) raises `CRANK_META_004` with a pointer to this mechanism.

### Why config-level

Topology violations don't have a source-line anchor. The violation is "module A depends on module B"; the `alias`, `import`, or call could be anywhere — or nowhere, if the dependency comes from a `__using__` macro. A comment-based mechanism wouldn't have a line to attach to.

Boundary's existing users already use this config-level mechanism. Crank's wrapper preserves it rather than reinventing.

## Layer C: programmatic `:allow` opt

For runtime trace observations — a transitive impure call, a heap exhaustion, an atom-table mutation — the suppression goes on the test helper that's running the trace.

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  allow: [
    {Decimal, :_, :_, reason: "trusted pure dependency"},
    {SomeLib, :pure_helper, 2, reason: "verified pure in upstream issue #42"}
  ]
)
```

### Rules

- Each entry is a `{module, function, arity, opts}` tuple. Use `:_` for any function name or any arity.
- The `:reason` opt is **required** on every entry.
- Each suppression emits a `[:crank, :suppression]` telemetry event with `layer: :c` when the trace runs.
- Source comments cannot suppress runtime violations. Attempting raises `CRANK_META_004`.

### Why programmatic

Runtime trace observations don't have a clean source-line anchor. The call may originate two helper modules deep, in code the test never directly mentions. The right place to express "yes I know this fires; here's why I trust it" is the test that's doing the verification — exactly the place that knows the test's intent.

The opt is also test-scoped. Layer C suppressions don't leak into other tests, don't modify global state, and don't persist across runs. If a different test wants to verify the same behaviour without the suppression, it can.

## Cross-layer attempts

Trying to use the wrong mechanism is itself a meta-violation that Crank surfaces loudly:

```elixir
# crank-allow: CRANK_DEP_001                       # CRANK_META_004
# reason: legacy adapter
defmodule MyApp.OrderMachine do
  use Crank
  alias MyApp.Repo
end
```

The Layer A parser (`Crank.Suppressions`) consults `Crank.Errors.Catalog.suppressible_by(:layer_a)` and rejects any code whose layer doesn't appear there. The error message names the right mechanism for that code:

```
[CRANK_META_004] # crank-allow: cannot suppress CRANK_DEP_001 via source comment
  — use Boundary configuration `:exceptions` entry instead
```

Same for runtime codes:

```
[CRANK_META_004] # crank-allow: cannot suppress CRANK_PURITY_007 via source comment
  — use the `:allow` opt on `Crank.PropertyTest.assert_pure_turn/3` instead
```

A Boundary config exception that names a runtime code is not an error (Boundary doesn't see runtime codes anyway), but it is logged as a setup-time warning so misconfigurations show up.

## Telemetry on every suppression

All three layers emit `[:crank, :suppression]` events when they silence a violation:

```elixir
:telemetry.attach(
  "audit-suppressions",
  [:crank, :suppression],
  fn _event, _measurements, metadata, _config ->
    # metadata: %{layer: :a | :b | :c, code: "CRANK_X_NNN", reason: "...", file: ..., line: ...}
    Logger.info("Crank suppression: #{metadata.code} — #{metadata.reason}", metadata)
  end,
  nil
)
```

This is the auditable trail. Suppression frequency per code is a meaningful health metric — a code that fires hundreds of times across the codebase is signalling something different from one that fires twice. Attach a handler in CI or in a dashboard to keep an eye on it.

## When to suppress vs when to fix

Suppressions are bridges, not destinations. Three honest reasons to use one:

1. **Mid-migration.** The clean fix is real but landing in a separate PR.
2. **Bridging a third-party limitation.** A library uses the process dict for OpenTelemetry context propagation; the trace fires, the call really is intended.
3. **Dev-only or test-only paths.** A `Logger.debug` inside a clause that only fires when `Mix.env() == :dev`; the suppression makes the gate explicit.

Three smelly reasons:

1. **"Just to make CI green right now."** This will get extended indefinitely; revisit the underlying issue.
2. **"I don't understand the diagnostic."** Read the violation's doc page first; the explanation usually points at the cleaner approach.
3. **"The suppression is faster."** True, but the suppressed call is still impure; you're trading test pain for production risk.

The reason field exists to make these conversations possible at code-review time. A suppression with `# reason: legacy import; PR #4423 lands the adapter pattern that removes it` is a working agreement to remove the suppression. A suppression with `# reason: needed` is a placeholder that nobody will ever revisit.

## A note on `CRANK_META_*` codes

The four meta codes (`CRANK_META_001..004`) are the rules that protect the suppression system itself. None of them are suppressible — they have no escape hatch.

| Code | Triggers | Fix |
|---|---|---|
| [CRANK_META_001](violations/CRANK_META_001.md) | Suppression annotation without `# reason:` | Add the reason. |
| [CRANK_META_002](violations/CRANK_META_002.md) | Suppression names a code not in the catalog | Spell the code correctly. |
| [CRANK_META_003](violations/CRANK_META_003.md) | Suppression has no following code line within 3 lines | Move the suppression to the right line. |
| [CRANK_META_004](violations/CRANK_META_004.md) | Suppression at the wrong layer | Use the right mechanism. |

If any of these fire, treat it as a real diagnostic — it means a suppression isn't doing what its author thought, and the underlying violation is going unsuppressed.

## See also

- [Boundary setup](boundary-setup.md) — Layer B configuration walkthrough.
- [Property testing](property-testing.md) — Layer C suppression in context.
- [Violations index](violations/index.md) — every code with its layer mapping.
- `Crank.Suppressions` source — the Layer A parser implementation.
