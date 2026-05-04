# Purity Enforcement Implementation Plan

## Status

**Implementation in progress.** Four of thirteen stages shipped to `main`; remainder in flight across parallel Claude Code Desktop sessions. The plan below remains the canonical specification — every session reads it as the source of truth. Per-session briefs in `plans/sessions/` describe how the work is split.

### Shipped on `main`

| Stage | Commit | What's live |
|---|---|---|
| 1. Foundation | `0df893d` | `Crank.Errors`, `Crank.Errors.Catalog` (22 frozen v1 codes), `Crank.Errors.Violation`, `Crank.Check.Blacklist` (shared between Credo and `@before_compile`), `Crank.Suppressions` (Layer A parser + telemetry) |
| 2. OTP guard | `0df893d` | `Crank.Application` boots with OTP 26+ check (`CRANK_SETUP_002` if older), starts `Crank.TaskSupervisor` for Mode B worker tasks |
| 4. Static checks | `ecc0618` | `Crank.Check.TurnPurity` (Credo) and `Crank.Check.CompileTime` (`@before_compile`) wired into `use Crank`. Hard `CompileError` on impure calls in `turn/3`. `# crank-allow:` suppression honoured. |
| 8. Server resource limits | `62fd91d` | `Crank.Server.start_link/3` accepts `:resource_limits`. Mode A applies `:max_heap_size` to gen_statem; Mode B (`turn_timeout` set) spawns workers under `Crank.TaskSupervisor` with kill-on-timeout. Verified against non-yielding tight loop. |
| 5. Topology | `e8da511` | `Crank.BoundaryIntegration` translates Boundary errors → `CRANK_DEP_001/002/003`. `Crank.Domain.Pure` macro tags helpers as strict `:domain` boundaries. `Mix.Tasks.Compile.Crank` (`:crank` compiler) wraps Boundary's machinery and emits Crank-formatted diagnostics. `priv/boundary.exs.template` ships the third-party-app classification starter config. End-to-end integration test (`test/integration/dep_001_test.exs`) stages a consumer mix project and asserts `CRANK_DEP_001` fires on a domain→infra reference. |
| 6. State/memory typing | `505d1ad` | `Crank.__using__/1` accepts `states: [...]` and `memory: ...`. Generates `@type state/0` (closed union) and `@type memory/0` automatically. `Crank.Typing` provides `@before_compile` for `CRANK_TYPE_003` (literal `{:next, %SomeState{}, _}` returns must be in declared union) and `@after_compile` for `CRANK_TYPE_002` (rejects `function/0` / `module/0` types in memory typespec via `Code.Typespec.fetch_types/1`, with best-effort skip-on-unfetchable for same-pass compilation order). |

**Test status:** 292 tests passing on `main` (was 245; +29 from Stage 5 boundary tests, +18 from Stage 6 typing tests, including 2 new integration tests under `test/integration/`).

### Phase 0 outcome — passed

The Boundary feasibility spike validated the integration design without requiring redesign. Key findings:

1. **`use Boundary` macro composition works.** Both `use Crank` and `use Crank.Domain.Pure` successfully inject `use Boundary, type: :strict, deps: [...], exports: []` via `Crank.Domain.Pure.build_boundary_opts/1`. The `Boundary` persisted module attribute is set correctly on every tagged module; verified via the generic test pattern `Keyword.get(module.__info__(:attributes), Boundary)`.

2. **Diagnostic translation has all required fields.** `Crank.BoundaryIntegration.translate_error/2` produces `Crank.Errors.Violation` structs with code, severity, rule, file, line, function, violating_call, context, and metadata fully populated from Boundary's `{:invalid_reference, %{from_boundary, to_boundary, reference: %{from, to, file, line, from_function}}}` shape.

3. **The starter Boundary config in `priv/boundary.exs.template` is reusable** without modification. Third-party app classification operates at the OTP-application level (per the v6 plan correction), so the template seeds `:third_party_pure` and `:third_party_impure` lists with commented-out suggestions only. No stdlib classification (handled by 1.1 / 1.3 / 2.1 instead).

4. **Implementation gotcha discovered during the spike:** `Crank.__using__/1` must auto-add `Crank` to the user's `boundary_deps` list. Without this, the strict-mode external-dep check fires on the macro-injected references to `Crank.Server`, `Crank.Check.CompileTime`, etc., producing spurious `CRANK_DEP_003` errors on every `use Crank` module. The fix is a single line in `Crank.Domain.Pure.build_boundary_opts/1` — Crank is prepended to `:deps` if not already present. Tested via `boundary_deps: [Crank]` opt being a no-op for users.

5. **Boundary's `after_elixir_compiler` semantics matter.** Boundary's own compiler hook only unloads the tracer, NOT flushes CompilerState. An initial draft of `Mix.Tasks.Compile.Crank` flushed state in `after_elixir`, which wiped the captured references before `after_app` could query them. Fixed; the integration test catches this regression.

The spike's three pass criteria (CRANK_DEP_001 with full fields, config reusable as Stage 5 template, macro mechanism compatible with both `use Crank` and `use Crank.Domain.Pure`) are met. No redesign of Phase 1.4 was required.

### Remaining work, by track

Three independent tracks plus a convergence session. Detailed briefs live in `plans/sessions/`:

- **Track A — Topology** (Stages 3 → 5 → 6, sequential): Phase 0 Boundary spike, then `Crank.BoundaryIntegration` + `Crank.Compiler` + `Crank.Domain.Pure`, then the macro form for state/memory typing. See `plans/sessions/track-a-topology.md`.
- **Track B — Runtime** (Stage 7, independent of A): `Crank.PurityTrace` with OTP 26 trace sessions + concurrency-stress test, then `Crank.PropertyTest` helpers. See `plans/sessions/track-b-runtime.md`.
- **Track C — Documentation** (Stages 10 + 11, independent of A and B; markdown-only): 22 per-violation doc pages, `ROADMAP.md`, four new guides, existing-guide updates. See `plans/sessions/track-c-docs.md`.
- **Convergence** (Stages 9, 12, 13 — runs after A, B, C land on `main`): `mix crank.gen.config` and `mix crank.check` Mix tasks, dogfooding via property tests on `Crank.Examples.*`, final CI-gate verification. See `plans/sessions/convergence.md`.

Each track is sized for a single Claude Code Desktop session. Track A's three sub-stages run sequentially within one session because they're tightly coupled (Phase 0's outcome shapes Stage 5's design).

## Revision history

- **v7 (consensus)** — Final editorial pass after Codex v6 review issued explicit TERMINATION SIGNAL ("ship with revisions, minor refinements only"). Fixed wording drift in 1.4's complexity note: the configuration template includes third-party app classification only, not stdlib classification (which Boundary cannot enforce at the module level). The Codex review trajectory across six passes — 9→6→5→4→3→1 findings, with the final pass producing only an editorial inconsistency — indicates the plan has converged. No remaining blockers or majors.
- **v6** — Revised after Codex v5 review. Replaces the assumed `Task.Supervisor.async_nolink/2` saturation contract (`{:error, :max_children_reached}`) with a defensive try/catch wrapper that handles both tagged-tuple return and `:exit` signal modes, since the historical OTP contract has varied. Corrects the Boundary external-dependency policy: Boundary operates at the **OTP-application** level, not the module level, so it cannot enforce "Map pure but IO impure" — that distinction is handled by the existing call-site checks (1.1 / 1.3) and runtime trace (2.1). Boundary's role is narrowed to first-party topology and third-party app classification only. The verification matrix splits accordingly. Loosens the determinism assertion: trace verdict + violating-call set are asserted equal across 100 runs, not byte-for-byte trace identity (which is scheduler-dependent and noise-prone).
- **v5** — Revised after Codex v4 review. Narrows `CRANK_TYPE_001` to "memory-field-unknown" — the original v4 description claimed Elixir's compile-time struct enforcement caught field-type mismatches, which it does not (typespec-level type matching is Dialyzer-warning territory, not compile-error territory); the corrected scope is field-name validation only. Specifies `Task.Supervisor` lifecycle for Mode B (`turn_timeout` enabled): supervisor is started by `Crank.Application` as `Crank.TaskSupervisor` with `max_children: 10_000`, saturation produces `:crank_supervisor_saturated` stop. Moves `:max_heap_size` enforcement to the worker process when Mode B is active — the v4 spec set it on the gen_statem, but the actual work happens in the worker. Adds an explicit external-dependency classification policy for Boundary's strict mode (`:stdlib_pure`, `:stdlib_impure`, `:third_party_pure`, `:third_party_impure`) so first-run setup doesn't drown users in false positives on `Map.put/3` etc. Adds `CRANK_DEP_003` for unclassified third-party deps.
- **v4** — Revised after Codex v3 review. Replaces the same-process timer pattern in `Crank.Server` resource limits (2.2) with a `Task.Supervisor.async_nolink/2` + `Task.shutdown(:brutal_kill)` pattern — same-process timers cannot preempt non-yielding loops, so the v3 spec was unsound for the threat it claimed to address. Adds a non-yielding-loop verification case to prove the pattern works. Adds a per-code ownership table (3.2) mapping every frozen catalog code to a concrete detection mechanism, owning component, and test fixture path; the catalog test enforces that codes without all three cannot be added. Resolves the open question about `Crank.Compiler` packaging: it lives inside Crank, not as a separate package. Refines flaky CI assertions: snapshot tests normalise unstable fields; concurrency-stress test asserts on inclusion not ordering; compile-time overhead uses 95th percentile across 10 runs per module (not max). Limits `mix crank.gen.config` scope to machine-structured config files only — README/CI snippets are printed to stdout for the user to copy, not auto-edited.
- **v3** — Revised after Codex v2 review. Defines per-layer suppression semantics explicitly. Removes `:erlang.system_monitor/2`-based reduction enforcement (VM-global, incompatible with parallel tests). Adds Phase 0 Boundary feasibility spike. Operationalises OTP 26+ requirement (mix.exs, runtime guard, CI matrix). Fixes Phase 1.2 to amend rather than regenerate `.credo.exs`. Adds `mix crank.gen.config` and `Crank.Compiler` for automatic wiring. Replaces unverified `Module.spec_to_callback/2` with `Code.Typespec.fetch_specs/1`.
- **v2** — Revised after Codex v1 review. Specified trace synchronization protocol and OTP 26+ baseline; split dependency-direction check into local and project-level layers; adopted Boundary; replaced "IO-monad-equivalent" framing with detection matrix; froze error-code taxonomy with `CRANK_META_*` codes; added quantitative verification gates; moved suppression ahead of any hard-error check; trimmed internal refactors out of dogfooding scope; resolved strict-vs-permissive default and `mix crank.check` task as decisions.
- **v1** — Original plan.

## Context

Crank's design centres on a pure core: `turn/3` is meant to be a pure function from `(event, state, memory)` to a closed return type, and `wants/2` declares effects as data for the Server to interpret. That discipline is documented in `DESIGN.md` and the hexagonal-architecture guide, but it is currently **enforced only by convention**. Nothing in Crank or the Elixir compiler stops a developer from writing `Repo.insert!` inside `turn/3`. The hexagonal guide previously claimed enforcement that did not exist; that paragraph has been corrected to be honest.

This plan operationalises the discipline through three layered mechanisms — compile-time topology checks, runtime tracing, and property-test integration — composed under a unified error-reporting system that surfaces violations as teachable moments. The plan does **not** claim soundness equivalence with a sound effect system. It defines a bounded threat model, a precise detection matrix, and explicit non-detectable classes (see "Coverage model" below).

The architectural insight that makes this tractable is that Crank's structure produces leverage generic Elixir code lacks:

- **Closed return types** — `turn_result/0` has exactly four shapes; values flowing out are bounded.
- **Closed state unions** (under struct-per-state) — what counts as a state is enumerable.
- **Marked module boundaries** — `use Crank` is an explicit marker that "this module is domain code." Elixir lacks a general domain/infrastructure split; Crank knows where its boundary is.
- **`wants/2` as the effect channel** — declared, not performed. Anywhere a side effect *would* happen has a first-class declarative alternative.

These leverage points let us move accidental-impurity detection from the function-call level (where it requires effect inference) to the module-topology level (where it is a tractable graph problem) and the call-site level (where it is a bounded AST walk). Combined with runtime tracing scaled by property-based test coverage, the residual gap reduces to: trust in third-party libraries, deliberate sabotage, and untested code paths.

This plan does not invent any of the underlying mechanisms. The topology layer is delegated to **Boundary** (`sasa1977/boundary`) — a mature module-dependency-rules library that already implements the post-compile graph check this plan needs. AST walking for call-site checks is well-trodden via Credo. `:trace.session_create/3` (OTP 26+) is the BEAM primitive for isolated tracing. `Process.flag(:max_heap_size, _)` is a process flag that has existed for a decade. Property testing via StreamData is standard Elixir. The contribution is composing them into a coherent enforcement story tailored to Crank's structure, with error messages that teach the discipline at the moment of violation.

## Goals

1. **Two-axis enforcement.** Compile-time topology checks (universal across all module-level references) plus runtime tracing (universal on tested execution paths). The combination closes the categories static alone cannot reach.
2. **Property-test integration.** Pure-mode `Crank.turn/2` paired with StreamData and isolated tracing turns every property test into a purity test for free.
3. **Error messages that teach.** Stable error codes, structured for agent consumption, prose for humans, doc page per code, suppression syntax that is deliberate and reviewable.
4. **Dogfooding.** Crank's own examples exercise the discipline via property tests with negative fixtures.
5. **Forward-compatible types.** Declare typespecs precisely now so each Elixir release strengthens enforcement automatically without Crank-side changes.
6. **Automatic wiring.** New Crank projects get Boundary integration, the `.credo.exs` config, the OTP version guard, and the `mix crank.check` CI gate without manual setup.

## Non-goals

- **Replicating Haskell's IO monad or Koka's algebraic effects at the language level.** Both require type-system features Elixir lacks. Detection here is bounded, not sound.
- **Universal coverage.** The plan defines a precise detection matrix; classes outside the matrix are explicit and documented.
- **Defending against deliberate sabotage.** Threat model is *accidental* impurity. `unsafePerformIO`-equivalents exist in every static system.
- **Production-mode tracing.** Tracing has 5-50% overhead. Dev/test/staging only.
- **Effect-typed callbacks that propagate purity transitively across user code via the type system.** That is an effect system, and we are not building one.
- **Reduction-budget enforcement in `Crank.PurityTrace` v1.** The only mechanism that fits — `:erlang.system_monitor/2` — is VM-global and breaks under parallel test execution. v1 ships timeout-based bounds only. A per-process polling variant is documented as a follow-up.

## Coverage model

### Detection matrix

The plan does not claim universal coverage. It claims specific detection for specific categories at specific layers.

| Impurity category | Static call-site (1.1, 1.3) | Static topology (1.4 + Boundary) | Runtime tracing (2.1) | Type system (1.6, 1.7) |
|---|---|---|---|---|
| Direct call to known impure module in `turn/3` body | AST blacklist match | n/a | trace pattern fires | n/a |
| Direct call to known impure module elsewhere in domain module | n/a | Boundary cross-boundary call rule | trace pattern fires | n/a |
| Indirect call through user helper (helper marked pure) | n/a | Boundary topology check verifies helper is pure | trace shows transitive call | n/a |
| Indirect call through user helper (helper unmarked, strict mode) | n/a | Boundary rejects unmarked call | trace shows transitive call | n/a |
| Dynamic dispatch (`apply(state.handler, ...)`) | n/a | Boundary cannot see runtime values | trace shows resolved call | `state.handler` field rejected if state struct disallows function/module values |
| Stdlib non-determinism (`DateTime.utc_now/0`, `:rand.*`) | AST blacklist match | n/a | trace pattern fires | n/a |
| Process communication (`send/2`, `Task.start/1`) | AST blacklist match | n/a | trace pattern fires | n/a |
| Ambient state read (`:ets.lookup`, `Process.get`) | AST blacklist match | n/a | trace pattern fires | n/a |
| Atom-table mutation (`String.to_atom/1`) | AST blacklist match | n/a | trace + atom-count snapshot | n/a |
| Process dictionary mutation | n/a | n/a | before/after snapshot diff | n/a |
| Type-mismatched return into typed memory struct | n/a | n/a | n/a | struct field rejection (today) + set-theoretic types (progressively) |
| Module/function value stored in memory | n/a | n/a | n/a | typespec rejects function/module types in memory |
| Non-termination of `turn/3` | n/a | n/a | timeout limit | n/a |
| Resource exhaustion in `turn/3` | n/a | n/a | `max_heap_size` kill | n/a |

### Non-detectable classes (acknowledged)

These survive all layers and are documented as known gaps:

- **Trust in third-party library purity.** A domain helper calls `Decimal.add/2`; we trust Decimal. Universal floor across all static-purity disciplines.
- **Deliberate sabotage of markers.** Anyone can write `use Crank.Domain.Pure` on an impure module. Mitigation is code review on additions of the marker.
- **Untested code paths for runtime-only categories.** Tracing covers what runs.
- **Compile-time configuration leakage.** `Application.compile_env` resolves at compile and bakes a value into the module; the static check rejects the call but cannot see whether the *value* is impure.
- **Halting / non-termination at the type level.** Caught at runtime via timeout, not provable statically.
- **Reduction-budget enforcement in tracing.** Not implemented in v1 (see non-goals); timeout substitutes.

The `ROADMAP.md` discusses what could be added to shrink each gap; nothing in this plan attempts to close them in v1.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Compile Time (static)                          │
│                                                                      │
│  ┌────────────────────────┐    ┌─────────────────────────────────┐  │
│  │ Credo check            │    │ @before_compile macro            │  │
│  │ Crank.Check.TurnPurity │    │ - Direct impure calls in turn/3  │  │
│  │ (warning-level early   │    │ - Local module-reference scan    │  │
│  │ signal)                │    │   (raises CompileError)          │  │
│  └────────────────────────┘    └─────────────────────────────────┘  │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Boundary integration (post-compile graph check)              │    │
│  │ - Domain → infrastructure dependency-direction enforcement   │    │
│  │ - Marker propagation (use Crank, use Crank.Domain.Pure)      │    │
│  │ - Wired automatically via Crank.Compiler in :compilers list  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Forward-compatible typespecs                                 │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────────┐
│                       Runtime (dynamic)                              │
│                                                                      │
│  ┌────────────────────────┐    ┌─────────────────────────────────┐  │
│  │ Crank.PurityTrace      │    │ Crank.Server resource limits     │  │
│  │ (test/dev only)        │    │ - max_heap_size                  │  │
│  │ - :trace.session_*     │    │ - turn timeout                   │  │
│  │   (OTP 26+)            │    │ (opt-in, configurable)           │  │
│  │ - Synchronised barrier │    └─────────────────────────────────┘  │
│  │ - Timeout-based bounds │                                          │
│  │   (no system_monitor)  │                                          │
│  └────────────────────────┘                                          │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Crank.PropertyTest helpers                                   │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
                                   │
┌─────────────────────────────────────────────────────────────────────┐
│                        Error system                                   │
│                                                                      │
│  Crank.Errors — single source of truth for violation REPORTING       │
│  (suppression mechanisms are layer-specific, see 3.4)                │
└─────────────────────────────────────────────────────────────────────┘
```

All layers funnel through `Crank.Errors` for consistent **reporting**. **Suppression** is layer-specific (3.4): comment annotations for AST checks, Boundary config entries for topology, programmatic opts for runtime traces.

## Decisions resolved

1. **Dependency-direction default = strict, conditional on Boundary wiring.** The wiring is made automatic for new projects via `mix crank.gen.config` (4.5) and the `Crank.Compiler` Mix compiler. Existing projects that haven't run the generator get a hard error from `mix crank.check` (`CRANK_SETUP_001`) telling them to wire Boundary. There is no path where a Crank project silently runs without strict topology checks.
2. **Ship `mix crank.check` and `mix crank.gen.config`.** The first wraps the CI gates; the second performs the one-time setup that wires Boundary, the OTP guard, and the `.credo.exs` check.
3. **Topology layer = Boundary.** Crank takes Boundary as a hard library dependency (so it's always available), defines a `Crank.Compiler` that wraps Boundary's, and translates Boundary diagnostics into `Crank.Errors.Violation` structs. The call-site checks (1.1, 1.3) remain Crank-specific because they walk `turn/3` body content.
6. **`Crank.Compiler` lives inside Crank, not as a separate package.** This is a one-way door (changes the dependency surface for everyone using Crank), so resolving it now per the standing-rules guidance on closed-door decisions. The compiler is small (~50 LOC), exists only to translate Boundary diagnostics into `Crank.Errors.Violation` structs, and has no users outside Crank's own enforcement story. A separate `boundary_for_crank` package would be reinvention of release-coupling overhead with no upside: there are no external consumers wanting to use the compiler without Crank, and pre-1.x Crank has no migration burden that would make a future split painful. If a future need emerges (e.g., Boundary's API changes faster than Crank's release cadence can absorb), splitting at that point is straightforward.
4. **No reduction-budget tracing in v1.** Timeout and heap-size cover the threats. A per-process polling variant is on the ROADMAP; ships only after a concurrency-safe design exists.
5. **Suppression is layer-specific, not unified.** All three layers report through `Crank.Errors`, but the *mechanism* by which a developer marks a violation as deliberate differs by layer. See 3.4.

## Components

### Phase 0 — Boundary feasibility spike

**Path:** `test/spike/boundary_integration/` (deleted after Phase 1.4 completes).

**Role:** Prove the Boundary integration seams *before* committing to the Phase 1.4 design. The plan has been assuming two specific seams:

1. Auto-tagging a module with a Boundary attribute via the `use Crank` macro.
2. Translating Boundary's diagnostic output into `Crank.Errors.Violation` structs without losing information.

If either fails the spike — for example, if Boundary's macro mechanism doesn't compose with `use Crank`, or if Boundary's diagnostics don't expose enough information for the translation — Phase 1.4's design changes before code lands rather than after.

**Spike scope:**
- Three-module fixture: one `use Crank` domain module, one helper marked via `use Crank.Domain.Pure`, one infrastructure module.
- Working `boundary` config that classifies them correctly.
- Working violation: domain module aliases the infrastructure module; Boundary fires; the diagnostic is translated to a `Crank.Errors.Violation` with the expected `CRANK_DEP_001` code, file, line, and offending-call info.
- Working clean case: domain module calls the marked helper; Boundary passes.

**Pass criteria:**
- The spike produces a `CRANK_DEP_001` violation with all required fields populated.
- The spike's Boundary config is reusable as the Phase 1.4 starter template (or the deltas are small and documented).
- The `use Crank` → Boundary tag mechanism is compatible with both `use Crank` and `use Crank.Domain.Pure` without rewrites.

**If the spike fails:** Phase 1.4 redesigns. Possible alternatives include shipping a Crank-managed Boundary config rather than auto-tagging via `use`, or implementing a thin Crank-specific graph check rather than relying on Boundary's diagnostic surface. The spike's output is what determines which path to take.

**Complexity:** ~150 LOC spike code + investigation. Output is the Phase 1.4 starter template plus a `boundary-spike.md` write-up archiving the design decisions.

### Phase 1 — Static layer

#### 1.1 Credo check: `Crank.Check.TurnPurity`

**Path:** `lib/crank/check/turn_purity.ex` (file exists; needs completion).

**Status:** Skeleton committed. Needs taxonomy alignment, full blacklist, tests.

**Role:** Early-signal call-site check. Warning-level. Walks `turn/3` clause bodies looking for calls to a configurable blacklist of impure-module prefixes.

**Default blacklist** (every entry has a documented canonical fix):
- Database / external services: `Repo`, `Ecto.*`, `HTTPoison`, `Tesla`, `Finch`, `Req`, `Swoosh`, `Bamboo`, `Mailer`, `Oban`
- Logging: `Logger.*` (use telemetry-as-want)
- Stdlib non-determinism: `DateTime.utc_now`, `Date.utc_today`, `Time.utc_now`, `NaiveDateTime.utc_now`, `:rand.*`, `:random.*`, `System.os_time`, `System.system_time`, `:erlang.system_time`, `:erlang.monotonic_time`, `:erlang.unique_integer`
- Process / ambient state: `Process.put`, `Process.get`, `Process.delete`, `:ets.*`, `:persistent_term.*`, `:atomics.*`, `:counters.*`
- Configuration: `Application.get_env`, `Application.fetch_env`, `Application.fetch_env!`
- Filesystem / OS: `:os.*`, `File.*`, `:file.*`
- Code evaluation: `Code.eval_string`, `Code.eval_quoted`, `Code.compile_string`
- Atom table: `String.to_atom`, `:erlang.list_to_atom`, `:erlang.binary_to_atom`
- Identity reads: `make_ref/0`, `self/0`, `node/0`
- Process communication: `send/2`, `Process.send_after/3`, `GenServer.cast/2`, `GenServer.call/2`, `Task.start/1`, `Task.async/1`, `spawn/1`, `spawn_link/1`

**Verification (quantitative gates):**
- 100% true-positive rate on a fixture suite covering one violation per blacklist entry.
- 0 false positives on a fixture suite of 50+ pure modules across realistic patterns.
- Each violation has correct line and column information (asserted, not visually checked).
- Each violation message contains the canonical fix snippet (asserted).

**Complexity:** ~250 LOC including tests.

#### 1.2 `.credo.exs` configuration (amend existing)

**Path:** `.credo.exs` (file already exists at repo root; the v2 plan incorrectly described it as a new file to generate).

**Role:** Wires `Crank.Check.TurnPurity` into the standard Credo run.

**Implementation:** Amend the existing `.credo.exs`. Add the check to the existing `:checks` list under a new `:design` group with `severity: :high`. Preserve all existing enabled/disabled checks; do not regenerate from `mix credo gen.config` (which would clobber custom configuration).

**Verification:** `mix credo --strict` runs cleanly on Crank's own code; `mix credo` on a synthetic impure fixture reports the expected violation at the expected severity. Diff of `.credo.exs` shows only additions, no removals or modifications to pre-existing checks.

#### 1.3 Compile-time hard-error check via `@before_compile`

**Path:** `lib/crank.ex` (extend the existing `__using__` macro) and `lib/crank/check/compile_time.ex`.

**Role:** Stricter than Credo — produces a `CompileError` rather than a warning. Cannot be ignored without an explicit suppression annotation. Scope is **local-only**: walks the AST of the module being compiled; does *not* attempt transitive helper-module checks (those are handled by 1.4 via Boundary).

**Mechanism:**
1. `use Crank` registers `@before_compile Crank.Check.CompileTime`.
2. The hook walks the module's AST, collecting:
   - Every `def turn(_, _, _) do ... end` clause body.
   - Every alias, import, use, fully-qualified call, and module attribute holding a module name in the module body.
3. For each `turn/3` body, checks for calls to blacklisted prefixes (shared list with 1.1 via `Crank.Check.Blacklist`).
4. For the module as a whole, checks the local references against the same blacklist.
5. Before raising, consults `Crank.Suppressions.suppressed?/2` to honour any `# crank-allow:` annotation (3.4).
6. On unsuppressed violation, raises `CompileError` constructed from a `Crank.Errors.Violation` struct.

**Decision (kept from v2):** Both Credo (1.1) and `@before_compile` (1.3) are retained; they share a blacklist via `Crank.Check.Blacklist`.

**Verification:**
- `assert_raise CompileError` on fixture modules with `Repo.insert!` inside `turn/3`.
- `assert_raise CompileError` on fixture modules with `alias MyApp.Repo` at module level.
- Pure fixture modules compile cleanly.
- Fixture with a valid `# crank-allow:` annotation compiles cleanly.
- Fixture with a malformed `# crank-allow:` annotation raises the appropriate `CRANK_META_*` code.
- Compile-time overhead per module: <50ms additional, measured via `:timer.tc` against a corpus of 20 representative modules. Hard ceiling.

**Complexity:** ~400 LOC including tests.

#### 1.4 Boundary integration for dependency direction

**Path:** `lib/crank/boundary_integration.ex` and `priv/boundary.exs.template`.

**Role:** Project-level graph check. After all modules are compiled, walk the module dependency graph and reject domain-module → infrastructure-module references. This is the post-compile architecture-fitness pattern, executed by Boundary's existing custom Mix compiler.

**Prerequisite:** Phase 0 spike completed and signed off. The implementation here follows whatever design the spike validated.

**Why Boundary:** Already implements module-level dependency rules, ships a custom Mix compiler that runs after the standard compile, walks the graph, has marker syntax for boundaries, and supports strict and check modes. Reimplementing this is reinvention.

**Mechanism:**
1. Crank takes Boundary as a hard dependency (`{:boundary, "~> X.Y"}`) — it is always available wherever Crank is used.
2. Crank ships `Crank.Compiler`, a Mix compiler that wraps Boundary's compiler. Adding `:crank` to `compilers:` in mix.exs activates the entire stack: standard compile → Boundary check → Crank's diagnostic translation.
3. `mix crank.gen.config` (4.5) writes a starter `boundary` config with the `:domain` / `:infrastructure` split and adds `:crank` to `compilers:`.
4. `Crank.BoundaryIntegration` provides:
   - The `use Crank` and `use Crank.Domain.Pure` macros emit Boundary tag attributes (per the Phase 0 spike's chosen mechanism).
   - Translation from Boundary diagnostic structs into `Crank.Errors.Violation` structs (preserving file, line, offending call).
5. Boundary's existing config supports per-rule overrides; those become the suppression mechanism for topology violations (3.4).

**Default mode = strict.** Boundary configuration template defaults to strict. Permissive mode is a config override for projects in mid-migration.

**Helper-module marking:**
- `use Crank` marks the module `:domain` automatically.
- `use Crank.Domain.Pure` (1.5) marks helpers `:domain` without making them Crank FSMs.
- Unmarked **first-party** modules called from `:domain` are rejected by Boundary's strict mode.

**External dependency policy (corrected after Codex v5 review):** Strict-by-default cannot mean "every external call requires explicit allowlisting" — that would reject `Map.put/3`, `Enum.map/2`, `Decimal.add/2`, and produce drowning false positives on first run. But the v4 plan overcommitted on what Boundary could enforce: Boundary's external classification operates at the **OTP-application** level, not the module level. `:elixir` is one app; you cannot say "Map is pure but IO is not" through Boundary's external mechanism. That distinction belongs to function-level checks (1.1 + 1.3 + 2.1), which already enumerate `IO.*`, `File.*`, etc. in the blacklist.

The corrected division of labour:

- **Boundary handles app-level third-party classification.** `:elixir` itself is *not* in the Boundary external list — calls into `Map`, `Enum`, etc. are not flagged by Boundary at all. The starter config classifies actual third-party apps:
  - **`:third_party_pure` (allowed from `:domain`):** apps the user declares as pure. The starter config seeds this with commented-out suggestions for `:decimal`, `:money`, `:typed_struct`, `:nimble_parsec`. Users uncomment what they use.
  - **`:third_party_impure` (rejected from `:domain`):** apps the user declares as infrastructure. Starter config seeds: `:ecto`, `:ecto_sql`, `:postgrex`, `:httpoison`, `:tesla`, `:finch`, `:req`, `:swoosh`, `:bamboo`, `:oban`.
  - **Unclassified third-party app called from `:domain`:** Boundary fires `CRANK_DEP_003` ("unclassified-external-dep") naming the app and pointing at how to classify it.
- **Function-level checks (1.1 + 1.3 + 2.1) handle stdlib purity.** `IO.puts/1` from `turn/3` body is caught by Credo / `@before_compile` AST blacklist. `Map.put/3` and `Enum.map/2` are not on the blacklist and pass. This already works without any Boundary involvement.
- **Runtime tracing (2.1) handles stdlib purity for transitive cases** (a helper module that calls `IO.puts/1`). The trace pattern fires regardless of which app the call lives in.

The verification matrix updates accordingly:

| Scenario | Caught by |
|---|---|
| `IO.puts/1` directly in `turn/3` body | 1.1 / 1.3 (call-site blacklist) |
| `IO.puts/1` in a `Crank.Domain.Pure` helper | 1.1 / 1.3 applied to the helper's body |
| `IO.puts/1` in an unmarked first-party helper | `CRANK_DEP_002` (unmarked helper) — Boundary rejects the *call to the helper*; the helper itself isn't checked but the topology still rejects the route |
| `IO.puts/1` deep in a third-party lib called from `:domain` | `CRANK_DEP_003` if the lib isn't classified, OR runtime trace `CRANK_PURITY_007` for tested paths |
| `Map.put/3` in `turn/3` body | passes (not on blacklist; `:elixir` isn't classified by Boundary) |
| `Decimal.add/2` if `:decimal` is in `:third_party_pure` | passes |
| `Decimal.add/2` if `:decimal` is unclassified | `CRANK_DEP_003` |

This split is the correct division: Boundary is good at app-level topology; the call-site / runtime layers are good at function-level enforcement; combining them gives both.

**Verification (Boundary's responsibilities only — stdlib enforcement is verified separately under 1.1 / 1.3 / 2.1):**
- Fixture project with a domain module aliasing `MyApp.Repo` (a first-party infrastructure module) fails Boundary check with `CRANK_DEP_001`.
- Fixture project with a domain module calling an unmarked first-party helper fails in strict mode with `CRANK_DEP_002`.
- Fixture project with a domain module calling a `Crank.Domain.Pure` helper passes Boundary.
- Fixture project with a `Crank.Domain.Pure` helper that internally references first-party infrastructure fails with `CRANK_DEP_001`.
- Fixture project with a domain module calling `Decimal.add/2` and `:decimal` is in `:third_party_pure` passes.
- Fixture project with a domain module calling `Ecto.Query.from/2` and `:ecto` is in `:third_party_impure` fails with `CRANK_DEP_001`.
- Fixture project with a domain module calling an unclassified third-party app fails with `CRANK_DEP_003`, naming the app and pointing at the classification mechanism.
- Boundary violations surface as Crank-formatted errors with the appropriate `CRANK_DEP_*` code.
- A project lacking `:crank` in `compilers:` fails `mix crank.check` with `CRANK_SETUP_001`.

**Stdlib enforcement verification lives in 1.1 / 1.3 / 2.1, not here:**
- `IO.puts/1` in `turn/3` body → 1.1 / 1.3 fixture, `CRANK_PURITY_005` or similar.
- `Map.put/3` in `turn/3` body → 1.1 / 1.3 fixture, no violation (not on blacklist).
- `:elixir` itself is *not* in the Boundary external classification list. Boundary doesn't fire on stdlib calls.

**Complexity:** ~200 LOC integration glue + ~50 LOC `Crank.Compiler` + the configuration template (third-party app classification only — `:third_party_pure` and `:third_party_impure` buckets with seeded suggestions; no `:elixir` or stdlib classification because Boundary operates at the OTP-app level and stdlib enforcement lives in 1.1 / 1.3 / 2.1) + `mix crank.gen.config` (counted in 4.5). Most logic lives in Boundary.

#### 1.5 `Crank.Domain.Pure` marker module

**Path:** `lib/crank/domain/pure.ex`.

**Role:** A `use Crank.Domain.Pure` form for non-Crank helper modules to opt into domain-pure status. Provides a `__using__` hook that:
- Tags the module with the `:domain` Boundary attribute.
- Registers the module as subject to the same `@before_compile` enforcement as `use Crank` (call-site blacklist applies to the helper's bodies).

**Decision rationale:** Module attributes (`@crank_domain_pure true`) are simpler but less discoverable. `use Crank.Domain.Pure` is parallel to `use Crank` and creates a consistent marker idiom. Both are recognised; `use` is documented as the preferred form.

**Verification:** Same fixtures as 1.4, with `use Crank.Domain.Pure` substituted for the attribute form. Helper modules that internally reference infrastructure fail with `CRANK_DEP_001`.

**Complexity:** ~80 LOC.

#### 1.6 Tight typespec hardening on Crank's own surface

**Path:** `lib/crank.ex` and related modules.

**Role:** Audit and harden every typespec on the public API.

**Specific hardening:**
- `@type t/0` for `%Crank{}`: `engine` as `:running | {:off, term()}`, not `term()`.
- `@type turn_result/0`: closed sum `{:next, term(), term()} | {:stay, term()} | :stay | {:stop, term(), term()}`.
- `@type want/0`: enumerated tuple shapes precisely.
- Callbacks (`turn/3`, `wants/2`, `reading/2`, `start/1`): spec-precise return types.

**Verification:**
- Dialyzer zero warnings on Crank's own code.
- Dialyzer warning on a fixture project where `turn/3` returns `{:not_a_real_shape, ...}`.

**Complexity:** ~50 LOC of typespec changes plus the audit pass.

#### 1.7 Memory and state typing guidance + macro form

**Path:** `lib/crank.ex` (extend `__using__`), `guides/typing-state-and-memory.md`.

**Role:** Make tight typing of state and memory the path of least resistance.

**Macro form:**
```elixir
use Crank,
  states: [Idle, Accepting, Dispensing, MakingChange],
  memory: MyApp.VendingMemory
```

The macro:
- Generates `@type state/0` as the union of the listed state structs.
- Generates `@type memory/0` referencing the named memory struct.
- Adds compile-time checks that all clauses of `turn/3` return states from the declared union.
- Rejects function/module types appearing in state or memory typespecs.

**Decision:** The macro form is opt-in. Manual typespecs continue to work.

**Verification:**
- Fixture using the macro form generates the expected typespecs (verified via `Code.Typespec.fetch_specs/1` on the compiled BEAM file — this is the actual public Elixir API for typespec introspection; the v2 plan referenced `Module.spec_to_callback/2`, which is not the right API for this purpose).
- Fixture where `turn/3` returns a state not in the declared union raises a compile warning.
- Fixture with a function value in memory typespec is rejected at compile time.
- Existing manual-typespec fixtures continue to work.

**Complexity:** ~200 LOC for the macro plus ~100 LOC for the guide.

### Phase 2 — Runtime layer

#### 2.1 `Crank.PurityTrace` module

**Path:** `lib/crank/purity_trace.ex`.

**Role:** Run a function in a sandboxed, isolated-trace process and report any impure calls observed.

**OTP baseline: 26+.** Required for `:trace.session_create/3`, `:trace.session_destroy/1`, and per-session pattern matching. The version constraint is enforced in three places (see 4.6 for the operationalisation):
- `mix.exs` documents the requirement in package metadata.
- `Crank.Application.start/2` checks `:erlang.system_info(:otp_release)` and raises `CRANK_SETUP_002` if < 26.
- CI matrix runs only OTP 26+.

**API:**
```elixir
@spec trace_pure((-> term()), keyword()) ::
        {:ok, result :: term(), trace :: list()}
        | {:impurity, list(violation), partial_trace :: list()}
        | {:resource_exhausted, kind :: :heap | :timeout, partial_trace :: list()}

def trace_pure(fun, opts \\ [])
```

**Reduction-budget enforcement is removed from v1.** The v2 plan named `:erlang.system_monitor/2` as the mechanism for reduction limits. `system_monitor` is VM-global — only one process can be the monitor at a time across the entire BEAM. Parallel `trace_pure/2` calls would race for the slot and corrupt each other's results. There is no clean alternative that works under parallel ExUnit:
- A polling check inside the worker (`Process.info(self(), :reductions)`) requires the worker to cooperate; it can't preempt a tight loop.
- Per-scheduler tracing doesn't bound reductions.
- Async assertion via timeout already covers the threat (non-termination).

So v1 ships **timeout-based bounds only**. The `Crank.PurityTrace` API does not expose `:max_reductions`. ROADMAP entry tracks the per-process polling variant for a follow-up.

**Synchronisation protocol:**
1. **Spawn the worker in a paused state.** Worker waits for `:start` before invoking `fun.()`.
2. **Create a trace session** via `:trace.session_create/3`. Session is local to this call; no global state mutation.
3. **Set the session's trace patterns** for the configured forbidden modules via the session-scoped `:trace.function/4`.
4. **Attach the session to the worker pid** with the `[:call, :return_to]` flags.
5. **Send `:start` to the worker.** All calls are now traced from the very first instruction of `fun.()`.
6. **Wait for completion or timeout** via `Process.monitor/1` and the configured timeout.
7. **Destroy the session** via `:trace.session_destroy/1` in an `ensure_*` block. Cleanup is unconditional.
8. **Return result + trace.**

**Options:**
- `:max_heap_size` — defaults to 10MB; passed to `Process.flag(:max_heap_size, _)`.
- `:timeout` — defaults to 1000ms; bounds wall-clock time.
- `:forbidden_modules` — defaults to the same blacklist as 1.1 / 1.3.
- `:allow` — programmatic suppression list (see 3.4); calls to modules in this list are observed but do not raise.
- `:tracer` — pid of a custom tracer (advanced; defaults to an internal collector).

**Verification:**
- Pure fixture function returns `{:ok, result, []}`.
- Fixture that calls `Repo.insert!` returns `{:impurity, [violation], _trace}` with `Repo.insert!` in the partial trace.
- Fixture that calls an impure helper transitively returns `{:impurity, [violation], _trace}` with the full call path.
- Fixture that infinite-loops returns `{:resource_exhausted, :timeout, _}`.
- Fixture that allocates excessively returns `{:resource_exhausted, :heap, _}`.
- **Concurrency-stress test:** 100 parallel calls to `trace_pure/2` with mixed pure and impure fixtures; assert each call returns the correct verdict for its own fixture and no calls cross-contaminate. Justifies the OTP 26+ session pin.
- **Determinism test:** the same fun + same forbidden_modules produces identical **verdict** (pure / impurity / resource_exhausted) and identical **violating-call set** (deduplicated, normalised — the set of `{module, function, arity}` tuples observed) across 100 sequential runs. The full trace (with timestamps, ordering, intermediate frames) is *not* asserted equal — incidental scheduler-dependent ordering would produce false failures without improving the purity signal.

**Complexity:** ~250 LOC including tests (down from v2's 300 because reduction monitoring is removed).

#### 2.2 `Crank.Server` resource limits

**Path:** `lib/crank/server.ex`.

**Role:** Opt-in process flags for server-mode machines.

**API addition:**
```elixir
Crank.Server.start_link(MyMachine, init_args,
  resource_limits: [max_heap_size: 50_000_000, turn_timeout: 5_000]
)
```

**Implementation:**

There are two execution modes, selected by whether `turn_timeout` is configured:

**Mode A — `turn_timeout: nil` (default).** `turn/3` runs in the gen_statem process (current behaviour, unchanged).
- `:max_heap_size` (if configured) is set on the gen_statem process via `Process.flag/2` in `init/1`. Allocations during `turn/3` count against this cap. The BEAM enforces it; if the process exceeds the limit, the VM kills it.
- No timeout enforcement (consistent with the opt-in design).

**Mode B — `turn_timeout: ms` (opt-in).** `turn/3` runs in a worker task; gen_statem orchestrates and kills on timeout.

A timer in the same process as `turn/3` cannot preempt a non-returning callback — the timer message can only be processed when the callback returns control, which by definition isn't happening. The standard BEAM pattern for preemption is **out-of-process execution with kill-on-timeout** via `Task.Supervisor`.

**Supervisor lifecycle (the Codex v4 gap):** the worker tasks are spawned under a dedicated supervisor with explicit lifecycle:

- **Started by `Crank.Application`** as part of Crank's own supervision tree (Crank itself is an OTP application; this is added in 4.7 alongside the OTP guard). The supervisor spec is `{Task.Supervisor, name: Crank.TaskSupervisor, max_children: 10_000}`.
- **Always available wherever Crank is loaded.** Users do not need to add it to their application supervision tree. The OTP application semantics guarantee it starts before any `Crank.Server` can run.
- **`max_children: 10_000`** is a sanity cap, not a tuning knob. If a host system is running >10k concurrent Crank turns, that's a system-health issue distinct from purity enforcement; saturation falls through to normal supervision.
- **Saturation behaviour:** the precise return contract of `Task.Supervisor.async_nolink/2` under saturation depends on OTP version. On supported OTP releases (26+) the implementation must handle both potential failure modes — a tagged tuple return *and* an `:exit` signal — because the public contract has historically varied across OTP versions and the plan must not depend on which one ships in the target build.

  The implementation wraps the call:
  ```
  try do
    case Task.Supervisor.async_nolink(Crank.TaskSupervisor, fn -> ... end) do
      %Task{} = task -> {:ok, task}
      {:error, :max_children_reached} -> :saturated
      {:error, _other} -> :saturated
    end
  catch
    :exit, {:noproc, _} -> :supervisor_down
    :exit, reason -> if saturation_exit?(reason), do: :saturated, else: reraise(reason)
  end
  ```
  where `saturation_exit?/1` matches the OTP-version-specific saturation reason (verified during implementation against the actual OTP version pinned in CI). Either failure mode produces `{:stop, :crank_supervisor_saturated, data}` from the gen_statem; `:supervisor_down` produces `{:stop, :crank_supervisor_unavailable, data}` (a different system-health failure). Both are restarted by existing `Crank.Server` supervision policy. No new error codes; these are system-health failures, not violations. Documented in the resource-limits guide.

**Per-turn flow when `turn_timeout` is set:**

1. The gen_statem receives the event.
2. It spawns a worker via `Task.Supervisor.async_nolink(Crank.TaskSupervisor, fn -> ... end)`.
3. **Heap limit (the Codex v4 gap):** the worker function sets `Process.flag(:max_heap_size, %{size: max_heap_size, kill: true})` as its **first** action, before invoking `module.turn/3`. The cap applies to where the work happens (the worker), not to the gen_statem (which only orchestrates). `:max_heap_size` is *not* set on the gen_statem in Mode B — it would be enforcing on the wrong process. The plan's resource-exhaustion guarantee in Mode B is "the worker dies if it allocates beyond the cap; the gen_statem then sees the worker death via `Task.yield` returning `{:exit, _}` and crashes with `CRANK_RUNTIME_001`."
4. The gen_statem awaits with `Task.yield(task, turn_timeout) || Task.shutdown(task, :brutal_kill)`.
5. On normal return, the worker's result is consumed and the gen_statem proceeds with the new state.
6. On timeout, `Task.shutdown(task, :brutal_kill)` terminates the worker forcibly. The gen_statem logs `CRANK_RUNTIME_002`, emits `[:crank, :exception]` telemetry, and crashes itself (per the existing "let it crash" policy).
7. On worker heap-exhaustion, `Task.yield` returns `{:exit, :killed}` (the BEAM killed it). The gen_statem logs `CRANK_RUNTIME_001`, emits telemetry, crashes.

Cost: ~10-20μs per-turn overhead in Mode B (process spawn + monitor + message round-trip). Negligible for the typical use case where Mode B is enabled to defend against pathological turns, not for hot paths.

This is the only sound preemption pattern on the BEAM. Same-process timers cannot preempt non-yielding callbacks; the worker must be killable from outside.

**Decision:** Resource limits are opt-in. Defaulting them to "on" risks breaking users whose machines legitimately do heavy work and changes the per-turn process topology.

**Verification:**
- **Mode A heap test:** `start_link` with `max_heap_size` and no timeout, send an event that allocates beyond it, assert gen_statem death.
- **Mode B heap test:** `start_link` with `max_heap_size: 1_000_000, turn_timeout: 5_000`, send an event whose handler builds a 10MB list. Assert worker dies (BEAM kill), gen_statem reports `CRANK_RUNTIME_001`. The cap fires on the worker, not the gen_statem.
- **Mode B timeout-with-yielding test:** `turn_timeout: 50`, send an event that calls `Process.sleep(100)`. Assert `CRANK_RUNTIME_002` after Task.yield timeout.
- **Mode B non-yielding-loop test:** `turn_timeout: 50`, send an event whose handler is a tight CPU loop (`defp tight_loop, do: tight_loop()`). Assert the worker is killed by `Task.shutdown(:brutal_kill)` and the gen_statem crashes with `CRANK_RUNTIME_002`. This is the test that justifies the out-of-process design — a same-process timer would deadlock here.
- **Saturation test:** spin up 10_001 concurrent `Crank.Server` turns with `turn_timeout` set; assert one of them stops with `:crank_supervisor_saturated` and is restarted by its supervisor (verifies the saturation path doesn't silently swallow turns).
- **Supervisor presence test:** `Process.whereis(Crank.TaskSupervisor)` returns a pid as soon as Crank is started; if the supervisor dies, the application restarts it via OTP supervision (verified by `Process.exit/2` and re-checking).
- Without `turn_timeout`, behaviour is unchanged from current `Crank.Server` (Mode A). No worker spawn, no `Task.Supervisor` involvement.

**Complexity:** ~250 LOC including tests (up from v4's 150 because the supervisor lifecycle and Mode A vs Mode B distinction add code paths and verification).

#### 2.3 `Crank.PropertyTest` helpers

**Path:** `lib/crank/property_test.ex`.

**Role:** Bridge `Crank.PurityTrace` with `StreamData` and `ExUnitProperties`.

**API:**
```elixir
defmodule Crank.PropertyTest do
  @doc "Run an event sequence through a machine in pure-mode under purity tracing."
  @spec turn_traced(Crank.t(), [term()], keyword()) :: traced_result()

  @doc "Asserts that no impure calls were observed during the traced run."
  @spec assert_pure_turn(Crank.t(), term() | [term()], keyword()) :: Crank.t()
end
```

`assert_pure_turn/3` accepts an `:allow` option that delegates to `Crank.PurityTrace`'s programmatic suppression — see 3.4 for the layer-specific suppression discussion.

**Verification:**
- Pure-machine fixture: property test passes.
- Impure-machine fixture: property test fails with structured error including the offending event sequence and call path.
- StreamData shrinking produces a minimal failing input. Asserted by snapshot test of the shrunk input for a known-bad fixture.
- Determinism on seed: same StreamData seed produces identical pass/fail verdicts and identical shrunk inputs across runs.
- `:allow` opt: programmatic suppression silences the named calls; unsilenced calls still fail.

**Complexity:** ~150 LOC + ~100 LOC for the guide.

### Phase 3 — Error system

#### 3.1 `Crank.Errors` module

**Path:** `lib/crank/errors.ex`.

**Role:** Single source of truth for violation **reporting**. Every check (Credo, `@before_compile`, Boundary integration, `Crank.PurityTrace`, property tests) funnels through this module for consistent error format.

**Note on scope:** `Crank.Errors` does **not** own suppression. Suppression is layer-specific and lives in `Crank.Suppressions` (3.4) for AST checks, in Boundary config for topology, and in `:allow` opts for runtime traces. The reasons are spelled out in 3.4.

**Data structure:**
```elixir
defmodule Crank.Errors.Violation do
  defstruct [
    :code,           # "CRANK_PURITY_001"
    :severity,       # :error | :warning
    :rule,           # :turn_purity | :dependency_direction | …
    :location,       # %{file: ..., line: ..., column: ..., function: ...}
    :violating_call, # %{module: ..., function: ..., arity: ...} | nil
    :context,        # human-readable
    :fix,            # %{category: ..., before: ..., after: ..., setup: ..., doc_url: ...}
    :metadata        # extension point; used to carry layer-specific suppression info
  ]
end
```

**API:**
```elixir
def format_pretty(%Violation{}) :: String.t()
def format_structured(%Violation{}) :: map()
def to_compile_error(%Violation{}) :: CompileError.t()
def to_credo_issue(%Violation{}, source_file) :: Credo.Issue.t()
def to_property_test_failure(%Violation{}) :: ExUnit.AssertionError.t()
def to_boundary_diagnostic(%Violation{}) :: Boundary.Diagnostic.t()
```

**Pretty-form template:**
- Header line: `error: [CODE] short description`
- File/line: `  path/to/file.ex:line:column`
- Code window: 3 lines around the violation, with a caret under the offending term.
- "Why" section: one paragraph.
- "Fix" section: code block showing the canonical replacement.
- "Suppression" section: shows how to suppress this specific code at this layer (varies — see 3.4).
- "See" section: hexdocs URL.

**Verification:**
- Snapshot tests (one per violation code) of pretty form. Snapshot mismatches force deliberate update.
- JSON schema validation of structured form against a versioned schema.
- Round-trip tests preserving all fields through both formats.

**Complexity:** ~300 LOC including tests.

#### 3.2 Error code catalog (with taxonomy freeze)

**Path:** `lib/crank/errors/catalog.ex`.

**Taxonomy freeze:** Before any check is implemented, the full code namespace is enumerated and frozen. A catalog test fails if any code is referenced anywhere in the codebase but not in the catalog, or vice versa.

**Frozen catalog (v1):**

| Code | Rule | Description |
|------|------|-------------|
| `CRANK_PURITY_001` | turn-purity-direct | Direct impure call inside `turn/3` body |
| `CRANK_PURITY_002` | turn-purity-discarded | Discarded return value (`_ = some_call()`) inside `turn/3` |
| `CRANK_PURITY_003` | turn-purity-logger | `Logger.*` call inside `turn/3` (use telemetry-as-want) |
| `CRANK_PURITY_004` | turn-purity-nondeterminism | Time / randomness call inside `turn/3` |
| `CRANK_PURITY_005` | turn-purity-process-comm | `send/2` / `Task` / `spawn` inside `turn/3` |
| `CRANK_PURITY_006` | turn-purity-ambient-state | ETS / persistent_term / process dict access |
| `CRANK_PURITY_007` | turn-purity-transitive | Runtime trace observed impure call via helper |
| `CRANK_DEP_001` | dependency-direction | Domain module references infrastructure module |
| `CRANK_DEP_002` | unmarked-domain-helper | Strict mode: domain module calls unmarked first-party helper |
| `CRANK_DEP_003` | unclassified-external-dep | Domain module calls a third-party app not classified as `:third_party_pure` or `:third_party_impure` in Boundary config |
| `CRANK_TYPE_001` | memory-field-unknown | Struct-update or struct-literal references a field not declared in the memory struct's `defstruct` (caught natively by Elixir at compile time) |
| `CRANK_TYPE_002` | function-in-memory | Module / function value stored in memory or state |
| `CRANK_TYPE_003` | unknown-state-returned | `turn/3` returns a state not in the declared union |
| `CRANK_RUNTIME_001` | resource-heap | Heap exhaustion observed during traced turn |
| `CRANK_RUNTIME_002` | resource-timeout | Turn exceeded timeout |
| `CRANK_TRACE_001` | atom-table-mutation | New atom created during turn |
| `CRANK_TRACE_002` | process-dict-mutation | Process dictionary modified during turn |
| `CRANK_META_001` | suppression-missing-reason | `# crank-allow:` annotation without `# reason:` follow-up |
| `CRANK_META_002` | suppression-unknown-code | `# crank-allow:` references a code not in the catalog |
| `CRANK_META_003` | suppression-orphaned | `# crank-allow:` annotation with no following code line within 3 lines |
| `CRANK_META_004` | suppression-wrong-layer | `# crank-allow:` references a code that this layer cannot suppress (e.g. `CRANK_DEP_001` in source comment) |
| `CRANK_SETUP_001` | boundary-not-wired | Project lacks `:crank` in `:compilers` (see `mix crank.gen.config`) |
| `CRANK_SETUP_002` | otp-version-too-old | Runtime OTP < 26; `Crank.PurityTrace` requires trace sessions |

**Per-code ownership table (the Codex v3 gap).** Every frozen code must have a concrete detector specified. The catalog test enforces that this table is complete; codes without a detector cannot be added. If the detector for a code isn't known, the code doesn't go in the catalog yet — it goes on the ROADMAP.

| Code | Detection mechanism | Component | Test fixture |
|------|---------------------|-----------|--------------|
| `CRANK_PURITY_001` | AST blacklist match in `turn/3` body | 1.1 (Credo) + 1.3 (`@before_compile`) | `test/fixtures/violations/purity_001_*.exs` |
| `CRANK_PURITY_002` | AST pattern match for `_ = expr` where `expr` is a remote call | 1.3 (`@before_compile`) | `test/fixtures/violations/purity_002_*.exs` |
| `CRANK_PURITY_003` | AST blacklist match for `Logger.*` in `turn/3` | 1.1 + 1.3 | `test/fixtures/violations/purity_003_*.exs` |
| `CRANK_PURITY_004` | AST blacklist match for non-determinism functions | 1.1 + 1.3 | `test/fixtures/violations/purity_004_*.exs` |
| `CRANK_PURITY_005` | AST blacklist match for process-comm functions | 1.1 + 1.3 | `test/fixtures/violations/purity_005_*.exs` |
| `CRANK_PURITY_006` | AST blacklist match for ambient-state functions | 1.1 + 1.3 | `test/fixtures/violations/purity_006_*.exs` |
| `CRANK_PURITY_007` | Trace pattern fires for any blacklisted function during traced turn (transitive case) | 2.1 (`Crank.PurityTrace`) | `test/fixtures/violations/purity_007_*.exs` (helper that calls Repo) |
| `CRANK_DEP_001` | Boundary cross-boundary call diagnostic, translated via `Crank.BoundaryIntegration` | 1.4 (Boundary) | Fixture project under `test/integration/dep_001/` |
| `CRANK_DEP_002` | Boundary unmarked-call-from-strict-boundary diagnostic (first-party only) | 1.4 (Boundary) | Fixture project under `test/integration/dep_002/` |
| `CRANK_DEP_003` | Boundary's external-app classification check fires on a third-party app not in `:third_party_pure` or `:third_party_impure` | 1.4 (Boundary) | Fixture project under `test/integration/dep_003/` (unclassified `:foo_lib` in deps) |
| `CRANK_TYPE_001` | Native Elixir struct-update field-name rejection at compile time. `%{memory \| unknown_field: x}` and `%MyStruct{unknown_field: x}` produce compile errors today via Elixir's struct semantics (not typespecs). Crank verifies detection is active by attempting to compile the negative fixture and confirming the compiler rejects it. Field-*type* mismatches (e.g., string assigned to integer-declared field) are Dialyzer warnings, not compile errors — these are tracked under `CRANK_TYPE_001_DIALYZER` in the ROADMAP, not in this code | 1.6 (typespec audit) + 1.7 (macro form) | `test/fixtures/violations/type_001_*.exs` |
| `CRANK_TYPE_002` | Typespec analysis: `function/0` or `module/0` appearing inside `@type memory/0` or `@type state/0` declarations | 1.7 (macro form) | `test/fixtures/violations/type_002_*.exs` |
| `CRANK_TYPE_003` | `@before_compile` AST analysis: `turn/3` return tuples whose state value is not in the declared state union | 1.7 (macro form) | `test/fixtures/violations/type_003_*.exs` |
| `CRANK_RUNTIME_001` | `Process.flag(:max_heap_size, _)` kill observed by monitor in traced worker | 2.1 (`Crank.PurityTrace`) and 2.2 (`Crank.Server` resource limits) | `test/fixtures/violations/runtime_001_*.exs` |
| `CRANK_RUNTIME_002` | `Task.yield` returns nil → `Task.shutdown(:brutal_kill)` fired (per the 2.2 worker-task pattern) | 2.1 + 2.2 | `test/fixtures/violations/runtime_002_*.exs` (tight loop) |
| `CRANK_TRACE_001` | Before/after diff of `:erlang.system_info(:atom_count)` in traced worker | 2.1 (`Crank.PurityTrace`) | `test/fixtures/violations/trace_001_*.exs` |
| `CRANK_TRACE_002` | Before/after diff of `Process.get_keys/0` snapshot in traced worker | 2.1 (`Crank.PurityTrace`) | `test/fixtures/violations/trace_002_*.exs` |
| `CRANK_META_001..004` | Parser logic in `Crank.Suppressions` (Layer A) and config validators in Boundary integration (Layer B) and `Crank.PropertyTest` (Layer C) | 3.4 (Suppression) | `test/fixtures/violations/meta_*.exs` |
| `CRANK_SETUP_001` | `mix crank.check` checks for `:crank` in project's `:compilers` list | 4.6 (`mix crank.check`) | Fixture project missing the compiler |
| `CRANK_SETUP_002` | `Crank.Application.start/2` checks `:erlang.system_info(:otp_release)` against minimum (26) | 4.7 (OTP guard) | Mocked `:otp_release` in test |

Every row in this table is a concrete, falsifiable specification: a detector mechanism (the actual code path that produces the diagnostic) plus a test fixture path. The catalog test verifies that for every code: (a) the row exists, (b) the named test fixture exists, (c) the named component is present in the codebase. A code without all three is rejected.

**Note on changes from v2/v3:**
- `CRANK_RUNTIME_003` (resource-reductions) removed in v3 — reduction monitoring is not in v1.
- `CRANK_META_004` added in v3 — handles cross-layer suppression attempts (per 3.4).
- `CRANK_SETUP_001` and `CRANK_SETUP_002` added in v3 — operationalise Boundary-wiring and OTP-version requirements.
- v4: per-code ownership table added so every frozen code maps to a concrete detector and test fixture (closes the v3-review gap on "freeze ahead of detectors").

**Decision:** Codes are stable across major versions. Adding new codes is non-breaking; renaming or removing requires a major version bump.

**Verification:**
- Internal test asserts every code in the catalog has: an entry in the per-code ownership table, a fix template, a doc page (3.3), and at least one referencing check at the named component.
- Internal test asserts every code referenced in the codebase (via grep of source) is present in the catalog.
- Internal test asserts the named test fixture path exists for every code.
- Internal test asserts the catalog hasn't shrunk since the previous tagged release.

**Complexity:** ~250 LOC (up from v3's 200 because of the ownership-table verification).

#### 3.3 Per-violation documentation pages

**Path:** `guides/violations/CRANK_PURITY_001.md`, etc. (one per code in the catalog).

**Template (one screen):** What triggers / Why wrong / How to fix (Wrong/Right side-by-side) / How to suppress at this layer / See also.

**Wired into mix.exs:** Add `guides/violations/` to ExDoc extras under a "Violations" group.

**Verification:** CI test fails if a code is added without a corresponding doc, or vice versa.

**Complexity:** 22 short doc files (one screen of markdown each).

#### 3.4 Suppression — layer-specific design

**Path:** `lib/crank/suppressions.ex` (AST-layer parser); Boundary config (topology); `:allow` opts (runtime).

**Role:** Allow opt-out for genuine cases. The v2 plan claimed a single comment-based syntax recognised by all checks. This is unimplementable: Boundary's diagnostics come from the dependency graph (no comment anchor), and `Crank.PurityTrace` reports calls observed in already-compiled code (the source line may live in a transitively-called helper). Different layers need different mechanisms. All layers report through `Crank.Errors`; only the *suppression* mechanism is layer-specific.

**Layer A — AST checks (Credo 1.1, `@before_compile` 1.3): comment-adjacent annotations.**

```elixir
# crank-allow: CRANK_PURITY_004
# reason: dev-only debug timestamp; never reached in production paths
@dev_only_timestamp DateTime.utc_now()
```

Rules:
- Suppression applies to the next non-comment code line within 3 lines. Beyond that, raises `CRANK_META_003`.
- The `reason:` field is required; missing it raises `CRANK_META_001`.
- The referenced code must be in the catalog; an unknown code raises `CRANK_META_002`.
- The referenced code must be suppressible by this layer; a code that only fires at the topology or runtime layer (e.g., `CRANK_DEP_001`, `CRANK_PURITY_007`) raises `CRANK_META_004` with an explanation pointing at the right layer's mechanism.
- Multiple codes can be listed: `# crank-allow: CRANK_PURITY_004, CRANK_PURITY_005`.
- Suppression itself is logged as a `[:crank, :suppression]` telemetry event.

Implementation: `Crank.Suppressions.parse/1` walks the source comments alongside the AST, builds a line-keyed suppression map, and `Crank.Suppressions.suppressed?(violation, map)` is consulted before raising. Both 1.1 and 1.3 use the same parser.

**Layer B — Topology (Boundary 1.4): config-level entries.**

Boundary already supports per-rule overrides in its config. Crank's wrapper preserves this. A topology violation can be suppressed by adding an entry to the Boundary config:

```elixir
boundary [
  ...,
  exceptions: [
    {MyApp.LegacyOrderImporter, MyApp.Repo,
      reason: "legacy import path; will be removed in v2"}
  ]
]
```

Rules:
- The `reason:` field is required; Boundary's wrapper enforces this.
- Each exception is logged as a `[:crank, :suppression]` telemetry event when Boundary runs.
- Source comments cannot suppress topology violations. Attempting to do so raises `CRANK_META_004`.

This mechanism is fundamentally different from Layer A because the violation isn't tied to a single source line — it's a fact about the dependency graph. Putting it in config is the correct location; same idiom Boundary's existing users follow.

**Layer C — Runtime trace (`Crank.PurityTrace` 2.1, `Crank.PropertyTest` 2.3): programmatic opts.**

```elixir
Crank.PropertyTest.assert_pure_turn(machine, events,
  allow: [
    {Decimal, :_, :_, reason: "trusted pure dependency"}
  ]
)
```

Rules:
- The `:allow` list contains `{module, function, arity, opts}` tuples; `:_` matches any.
- Each entry requires a `:reason` opt.
- Each suppression is logged as a `[:crank, :suppression]` telemetry event when the trace runs.
- Source comments cannot suppress runtime-only violations (`CRANK_PURITY_007` in particular). Attempting raises `CRANK_META_004`.

This mechanism reflects that runtime-trace observations don't have a clean source-line anchor (the call may originate in a transitive helper). The opt is at the call site of the test that's doing the verification — exactly the place that knows the test's intent.

**Why three mechanisms, not one:**

- Source-adjacent comments require a source line. Topology and runtime layers don't always have one.
- Boundary already has a config-driven exception mechanism that its existing users know; we don't reinvent.
- Programmatic opts on test-side helpers reflect that test-author intent is what's being expressed at the runtime layer.

The cost is that developers must learn three mechanisms instead of one. Mitigated by:
- Each error message's "Suppression" section shows the *correct mechanism for that layer* with an example.
- The doc page for each code (3.3) includes the suppression syntax in its "How to suppress" section.
- `CRANK_META_004` fires loudly when a developer tries the wrong mechanism, with a pointer to the right one.

**Verification:**
- Layer A: comment suppression silences AST violations; missing `reason:` raises `CRANK_META_001`; wrong-layer code raises `CRANK_META_004`.
- Layer B: Boundary config exception silences topology violations; missing `reason:` raises a setup-time error.
- Layer C: `:allow` opt on `assert_pure_turn/3` silences runtime trace violations; missing `:reason` opt raises.
- Telemetry handler test: each layer's suppression mechanism emits `[:crank, :suppression]` with metadata identifying the layer.
- Cross-layer tests: a comment trying to suppress a topology code raises `CRANK_META_004`; a Boundary exception trying to apply to a runtime-only code is a no-op (logged as warning, not failure, because Boundary doesn't see runtime codes anyway).

**Complexity:** ~250 LOC (Layer A parser ~150, Layer B Boundary integration ~50, Layer C programmatic opt parsing ~50).

### Phase 4 — Documentation, dogfooding, CI task, OTP guard

#### 4.1 ROADMAP.md

**Path:** `ROADMAP.md` (repo root).

**Initial entries:**
- Effect-typed callbacks (aspirational; depends on a hypothetical Elixir effect system).
- Trace-aware property-test shrinking (StreamData integration improvements).
- Compile-time exhaustiveness on `turn/3` (already noted in `DESIGN.md`).
- Internal refactors: `Crank.Turns.apply/1` as a state machine; explicit FSM for `Crank.Server`'s engine field.
- Reduction-budget tracing (per-process polling variant; deferred from v1 because no concurrency-safe design exists yet).
- Strict transitive analysis beyond what Boundary provides (e.g., function-call-graph cuts).

**Complexity:** ~150 lines of markdown.

#### 4.2 New guides

- `guides/typing-state-and-memory.md`
- `guides/property-testing.md`
- `guides/violations/index.md`
- `guides/boundary-setup.md` — explains the auto-wiring path via `mix crank.gen.config` and the manual fallback.
- `guides/suppressions.md` — documents the three layer-specific suppression mechanisms with side-by-side examples.

**Complexity:** ~200 LOC of markdown each.

#### 4.3 Existing-guide updates

- **`README.md`** — add a "Purity enforcement" subsection.
- **`DESIGN.md`** — add a "Layered enforcement" section.
- **`guides/hexagonal-architecture.md`** — replace the existing "Anti-patterns" with a stronger version that references the static and runtime checks.
- **`CHANGELOG.md`** — single entry covering the layered enforcement work, including the OTP 26+ requirement.

#### 4.4 Dogfooding (trimmed scope)

- **`Crank.Examples.*`** — every example FSM has a property test using `Crank.PropertyTest.assert_pure_turn/3`.
- **Negative fixtures** — every violation code has at least one fixture in `test/fixtures/violations/` that triggers it. Used as fixtures for `Crank.Errors` snapshot tests and for the `mix crank.check` integration tests.

**Out of scope** (moved to ROADMAP.md): internal refactors of `Crank.Turns.apply/1` and `Crank.Server`'s engine field.

**Complexity:** ~250 LOC across examples and tests.

#### 4.5 `mix crank.gen.config` task

**Path:** `lib/mix/tasks/crank.gen.config.ex`.

**Role:** One-time setup for new Crank projects. Run once during onboarding; not run repeatedly.

**Behaviour (scope limited to machine-structured config files only — the v3 review flagged README/CI mutation as out-of-scope brittleness):**
1. Adds `boundary` and `crank` to `mix.exs` deps if missing.
2. Adds `:crank` to the `compilers:` list in the project config.
3. Writes a starter `boundary` config defining `:domain` and `:infrastructure`.
4. Amends `.credo.exs` (or creates one if absent) to wire `Crank.Check.TurnPurity` (without clobbering existing checks).
5. **Prints to stdout** a recommended CI snippet (`mix crank.check`) and a recommended README section. Does **not** modify README or CI YAML files. The user copies the snippets manually. This is deliberate: rewriting prose files is brittle (formatting collisions, conflict with existing content, partial overlaps with prior runs) and adds maintenance surface unrelated to purity correctness.

**Idempotent:** running it again on a configured project produces no config changes; the printed instructions are repeated for re-copy convenience.

**Verification:**
- Run on a fresh project with no Boundary; assert all setup steps complete.
- Run on a project already configured; assert no changes.
- Run on a project with conflicting `compilers:` config; assert it merges correctly.

**Complexity:** ~200 LOC.

#### 4.6 `mix crank.check` task

**Path:** `lib/mix/tasks/crank.check.ex`.

**Role:** Canonical CI gate. Wraps `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, the Boundary check, and the property-test suite into a single command.

**Behaviour:**
1. Verifies setup: `:crank` in `compilers:`, OTP >= 26. Fails fast with `CRANK_SETUP_001` / `CRANK_SETUP_002` if not.
2. Runs the underlying tools in sequence, aggregating exit codes.
3. Reports the cumulative pass/fail with structured output.

**Verification:**
- Running on Crank's own repo passes.
- Running on a fixture project with a deliberate violation fails with the expected exit code and structured output.
- Running on a project lacking `:crank` in `compilers:` fails with `CRANK_SETUP_001`.
- Running on OTP 25 fails with `CRANK_SETUP_002`.

**Complexity:** ~150 LOC.

#### 4.7 OTP version guard

**Three-layer enforcement** (the v2 plan declared the requirement but didn't operationalise it):

1. **`mix.exs`** — package metadata documents OTP 26+ in the description and links to the version guide. Elixir 1.15+ already implies recent OTP, but the explicit statement matters for users picking versions.
2. **`Crank.Application.start/2`** — runtime check via `:erlang.system_info(:otp_release)`. Below 26, raises `CRANK_SETUP_002` with a pointer to the version guide. Failure is at boot, not deep into a test.
3. **CI matrix** — Crank's own CI runs Elixir 1.15 / OTP 26, Elixir 1.16 / OTP 26, Elixir 1.16 / OTP 27. No OTP < 26 in matrix.

**Verification:**
- Boot test on OTP 26 succeeds.
- Synthetic OTP-25 simulation (mocked `:erlang.system_info(:otp_release)`) raises `CRANK_SETUP_002`.
- CI configuration tested by triggering an actual matrix run.

**Complexity:** ~50 LOC for the boot check; CI config update is YAML.

## Sequencing

**Recommended order:**

1. **Phase 0 — Boundary feasibility spike.** Must complete and produce the Phase 1.4 starter template before any Boundary-dependent code is written.
2. **Foundation** — 3.1 (Errors), 3.2 (Catalog with taxonomy freeze), 3.4 (Suppression — Layer A first, B and C land alongside their respective checks). 1.6 (Typespec audit) parallel.
3. **OTP guard** — 4.7 lands early so subsequent runtime work has a verified baseline.
4. **Static checks** — 1.1 (Credo) → 1.2 (.credo.exs amendment) → 1.3 (`@before_compile`).
5. **Topology layer** — 1.4 (Boundary integration, using Phase 0's output) → 1.5 (Domain.Pure) → 1.7 (Macro form).
6. **Runtime layer** — 2.2 (Server resource limits) parallel; 2.1 (PurityTrace) → 2.3 (PropertyTest).
7. **Errors completion** — 3.3 (per-code doc pages) lands as each code's check goes in.
8. **CI task and setup task** — 4.5 (`mix crank.gen.config`) → 4.6 (`mix crank.check`).
9. **Documentation and dogfooding** — 4.1 (ROADMAP), 4.4 (dogfooding), 4.2 (new guides), 4.3 (existing-guide updates).

The "single pass" framing is deliberate: not running ship-and-measure milestones between phases. Compile-time overhead is measured continuously; the <50ms/module ceiling is a hard gate.

The Phase 0 spike is the one genuine sequencing constraint. Skipping it risks the kind of "build first, discover the integration doesn't work the way I assumed" rework that the v2 review flagged.

## Verification strategy

### CI gates

1. **`mix test`** —
   - Snapshot tests of every error code's pretty-form output. Snapshots are normalised to exclude unstable fields (timestamps, pids, file-system-absolute paths — replaced with placeholders) before comparison. This prevents CI churn from environmental differences.
   - Round-trip tests for structured-form output.
   - Catalog consistency test.
   - **Concurrency-stress test for `Crank.PurityTrace`:** 100 parallel calls with mixed pure/impure fixtures. **Assertion shape:** verdict (pure/impure/exhausted) is correct for every call; trace contents include the expected forbidden-call entries. No assertion on trace ordering or trace size — only on inclusion of the expected entries — to avoid scheduler-dependent flakiness.
   - **Property-test determinism:** same StreamData seed → identical pass/fail verdict and identical shrunk input across 100 runs. **Assertion shape:** verdict equality and shrunk-input equality are deterministic by StreamData's contract; only these are asserted. Timing, intermediate trace contents, and exception messages are not asserted (those vary by scheduler).
   - **Layer A suppression:** comment-adjacent suppressions silence AST violations; cross-layer attempts raise `CRANK_META_004`.
   - **Layer B suppression:** Boundary config exceptions silence topology violations.
   - **Layer C suppression:** `:allow` opts silence runtime trace violations.

2. **`mix credo --strict`, `mix dialyzer`, `mix compile --warnings-as-errors`** —
   - **Compile-time overhead ceiling:** the `@before_compile` hook adds at most 50ms additional compile time at the **95th percentile** of per-module measurements across the benchmark corpus. **Assertion shape:** measure each module 10 times, take the 95th-percentile sample (not the max — the max is scheduler-dependent), assert it is below 50ms. The benchmark runs in a clean environment via `mix test --only benchmark` so it isn't co-located with other CI load. A harder per-module max (say 100ms) is also asserted as a sanity floor; this catches catastrophic regressions without rejecting environmental jitter. The gate is rerun if any change touches `lib/crank/check/compile_time.ex` or the blacklist module.
   - **False-positive budget:** 0 false positives on a corpus of 50+ pure-module fixtures. Hard gate (deterministic; this assertion is environment-independent because the AST walk is pure).

3. **`mix test --only property`** — every example FSM through StreamData generation under `assert_pure_turn`. Minimum 1000 runs per example.

### End-to-end scenario tests

Located in `test/integration/`:

- **Pure-and-impure mixed fixture project** — uses Crank with both pure and impure modules.
- **Strict-mode dependency-direction fixture** — violates dependency direction; assert Boundary fires with `CRANK_DEP_001`.
- **Trace-detected transitive impurity fixture** — assert the trace catches it and the property test fails with `CRANK_PURITY_007`.
- **Suppression fixtures** — one per layer, each with a valid suppression and an invalid one. Assert the valid suppression silences and the invalid one raises the appropriate `CRANK_META_*` code.
- **Setup fixtures** — project lacking `:crank` in `compilers:` fails `mix crank.check` with `CRANK_SETUP_001`. Project on OTP 25 (mocked) raises `CRANK_SETUP_002` at boot.

## Risks and tradeoffs (correctness-ordered)

1. **Phase 0 spike outcome.** If Boundary's API can't support the integration the plan assumes, Phase 1.4 redesigns. The spike is cheap (~150 LOC throwaway) and the alternative (build, discover, redesign) is what the v2 review flagged.
2. **Compile-time overhead.** AST walking adds per-module time. Hard ceiling: <50ms additional per module. There is no genuine design reason to accept a slower compile; if the ceiling is breached, optimise the AST walk.
3. **OTP 26+ baseline.** Hard requirement; operationalised in three places (4.7).
4. **Boundary as a dependency.** Adopting Boundary means Crank depends on an external library for the topology layer. The standing-rules question — "has this problem already been solved?" — points firmly at Boundary. Risk reduces to API-stability risk; sasa1977's track record answers it.
5. **Three suppression mechanisms.** Slightly higher cognitive load for users than a single mechanism would have been. Mitigated by per-error suppression hints, dedicated guide (4.2), and `CRANK_META_004` for wrong-layer attempts. Trying to force one mechanism would either miss layers or produce a fake-unified system that breaks under real diagnostics.
6. **No reduction-budget tracing in v1.** Timeout substitutes. ROADMAP entry tracks the per-process polling variant for a follow-up; ships only after a concurrency-safe design exists.
7. **False positives in the call-site blacklist.** Hard gate: 0 false positives on the fixture corpus.
8. **Error-code stability.** Catalog test enforces detection of accidental renames.
9. **Compile-time configuration leakage.** `Application.compile_env` can't be detected at runtime; documented in non-detectable classes.

## Open questions (genuinely unresolved)

1. **Should `Crank.PurityTrace` ship a `:strict_atom_table` option?** Default off; revisit after dogfooding shows the rate of legitimate vs. accidental atom creation in real fixtures.
2. **Should the macro form (1.7) be the preferred way to use Crank?** Recommended approach: yes once shipped, with manual typespecs documented as an explicit alternative for advanced cases.
3. **Should `wants/2` grow a fire-and-forget effect type for cases like distributed PubSub broadcasts?** Probably a separate plan.

## Reference

Key reasoning artefacts from the design conversation: hexagonal-discipline framing as the leverage point making module-topology checks tractable; struct-update enforcement insight (tight memory typing produces type errors today); forward-compatibility property of typespecs; static + dynamic + property-test combination achieving high coverage on accidental impurity within the bounded threat model defined in the detection matrix; errors as point-of-need documentation with stable codes; residual gap as the universal floor every static-purity discipline shares.

The narrative argument: Crank's structure (closed unions, marked modules, declared callbacks, the `wants/2` effect channel) creates leverage that generic Elixir code lacks. The architecture is not just *encouraging* hexagonal discipline; it can *check it at compile time and verify it at runtime*, because it knows where its own boundaries are. The work in this plan operationalises that property using established mechanisms (Boundary for topology, Credo for AST checks, OTP 26+ trace sessions for runtime tracing, StreamData for property tests), composed into a coherent enforcement story with a unified error-reporting system and layer-appropriate suppression.
