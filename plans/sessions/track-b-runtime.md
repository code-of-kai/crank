# Track B — Runtime layer (Stage 7)

This brief is for a single Claude Code Desktop session that builds the runtime tracing layer. **This is the riskiest single piece in the plan** — OTP 26 trace sessions are relatively new, the synchronization protocol is delicate, and the concurrency-stress test is the load-bearing verification gate. Use a fresh context window.

## Worktree

This session runs in its own auto-created Claude Code Desktop worktree off the latest `main`. The worktree lives at `.claude/worktrees/<auto-named-branch>/`. No manual git setup needed. When done, commit and push to the worktree's branch; merge back via PR or fast-forward; archive the session via the archive icon.

If the worktree branch falls behind `main` because Track A or Track C lands first, fetch and rebase before merging back. Track B touches `lib/crank/purity_trace.ex` (new), `lib/crank/property_test.ex` (new), and tests; conflicts with A or C are unlikely.

## Prerequisites on `main`

- Foundation: `Crank.Errors`, `Crank.Errors.Catalog`, `Crank.Errors.Violation`, `Crank.Check.Blacklist`, `Crank.Suppressions` (commit `0df893d`).
- OTP guard: `Crank.Application` running with `Crank.TaskSupervisor`. The trace work also benefits from the Application's OTP-26 boot check (commit `0df893d`).
- Static call-site checks: not strictly required, but the same blacklist that the static checks use is the source of trace patterns (commit `ecc0618`).

Verify before starting: `mix test` shows 245 tests passing. Verify OTP version is 26+ via `:erlang.system_info(:otp_release)` (the Application boot check enforces this; should already be satisfied wherever Crank tests run).

## What to read first

1. `plans/purity-enforcement.md`, **Phase 2.1 — `Crank.PurityTrace` module** (the load-bearing implementation, including the synchronisation protocol).
2. **Phase 2.3 — `Crank.PropertyTest` helpers** (the StreamData bridge).
3. **Non-goals section** — note that reduction-budget enforcement is **not in v1**; do not try to add it. `:erlang.system_monitor/2` is VM-global and incompatible with parallel ExUnit; the per-process polling variant is on the ROADMAP. Timeout-only and heap cap are the v1 mechanisms.
4. The **detection matrix** for `CRANK_PURITY_007`, `CRANK_RUNTIME_001`, `CRANK_RUNTIME_002`, `CRANK_TRACE_001`, `CRANK_TRACE_002`.

## What to build

### `Crank.PurityTrace` (the load-bearing piece)

Path: `lib/crank/purity_trace.ex`.

Public API (per the plan):

```elixir
@spec trace_pure((-> term()), keyword()) ::
        {:ok, result :: term(), trace :: list()}
        | {:impurity, list(violation), partial_trace :: list()}
        | {:resource_exhausted, kind :: :heap | :timeout, partial_trace :: list()}

def trace_pure(fun, opts \\ [])
```

Options: `:max_heap_size` (default 10MB), `:timeout` (default 1000ms), `:forbidden_modules` (default `Crank.Check.Blacklist.all()`-derived), `:tracer` (advanced; defaults to internal collector). **Do not expose `:max_reductions`** — see non-goals.

**Synchronisation protocol** (the plan's 8-step barrier, must be followed exactly to avoid the observation race that v3 review caught):

1. Spawn the worker in a paused state; worker waits for `:start` before invoking `fun.()`.
2. Create a trace session via `:trace.session_create(name, tracer, []) :: {:ok, ref}`. Session-local; no global state mutation.
3. Set the session's trace patterns for forbidden modules via `:trace.function/4` (session-scoped).
4. Attach the session to the worker pid via `:trace.process/4` with `[:call, :return_to]` flags.
5. Send `:start` to the worker. All calls are now traced from the very first instruction of `fun.()`.
6. Wait for completion or timeout via `Process.monitor/1` and the configured timeout.
7. **Destroy the session** via `:trace.session_destroy/1` in an `after`/`ensure_*` block. Cleanup is unconditional.
8. Return result + trace.

Read OTP 26 docs for `:trace.session_create/3`, `:trace.function/4`, `:trace.process/4`, `:trace.session_destroy/1`. The session API is the reason for the OTP 26+ baseline — pre-26 trace patterns are module-global and break under parallel ExUnit.

### `Crank.PropertyTest` helpers

Path: `lib/crank/property_test.ex`.

```elixir
@spec turn_traced(Crank.t(), [term()], keyword()) :: traced_result()
@spec assert_pure_turn(Crank.t(), term() | [term()], keyword()) :: Crank.t()
```

`assert_pure_turn/3` accepts an `:allow` opt (Layer C suppression) — list of `{module, function, arity, opts}` tuples with required `:reason`. Suppressions emit `[:crank, :suppression]` telemetry with `layer: :c`.

## Verification gates (these are the load-bearing tests)

All must pass before merging back to `main`:

1. **Pure-fixture test**: pure function returns `{:ok, result, []}`.
2. **Direct-impurity test**: function calling `Repo.insert!` returns `{:impurity, [violation], _trace}` with the expected catalog code in the partial trace.
3. **Transitive-impurity test**: function calling a helper that internally calls an impure module returns `{:impurity, [violation], _trace}` with the full call path. This is `CRANK_PURITY_007`'s detector.
4. **Non-termination test**: function with a tight CPU loop returns `{:resource_exhausted, :timeout, _}` (`CRANK_RUNTIME_002`).
5. **Heap-exhaustion test**: function building an exponentially large data structure returns `{:resource_exhausted, :heap, _}` (`CRANK_RUNTIME_001`).
6. **Concurrency-stress test (the v2 Codex blocker — must pass)**: 100 parallel calls to `trace_pure/2` with mixed pure and impure fixtures. **Assertion shape:** verdict (pure/impurity/exhausted) is correct for every call; trace contents include the expected forbidden-call entries. **Do not assert on trace ordering or trace size** — only inclusion of expected entries — to avoid scheduler-dependent flakiness.
7. **Determinism test (loosened per Codex v5)**: same fun + same forbidden_modules produces identical **verdict** and identical **violating-call set** (deduplicated, normalised — the set of `{module, function, arity}` tuples observed) across 100 sequential runs. **Do not assert trace identity** (incidental scheduler-dependent ordering would produce false failures).
8. **Property-test integration**: pure-machine fixture passes `assert_pure_turn`; impure-machine fixture fails with structured error including offending event sequence and call path. StreamData shrinking produces a minimal failing input (asserted by snapshot test of the shrunk input for a known-bad fixture).

The concurrency-stress test (#6) is the test that justifies the OTP 26+ session pin. Without it the v1 design is unverified.

## Estimated complexity

- `Crank.PurityTrace`: ~250 LOC including tests.
- `Crank.PropertyTest`: ~150 LOC + ~100 LOC for `guides/property-testing.md` (note: that guide is owned by Track C, not this session — Track B writes the module, Track C documents it).

Total session ballpark: ~400 LOC of code + tests.

## Risks

- The trace-session API is delicate; cleanup-on-failure path must be unconditional. Use `try/after` or `:ensure_*` semantics.
- The reduction-poll variant is **explicitly not in v1**. Resist any urge to add it; it goes on the ROADMAP. The trade-off rationale is in the plan's non-goals.
- The 8-step synchronisation protocol exists specifically to close the observation race that v3 Codex review caught. Skipping the barrier produces false negatives that the verification tests may not catch under low load.
- `:trace.session_*` APIs may have subtle differences across OTP 26.x point releases. Pin tests to the version available at session time; if behaviour shifts, document and surface.
