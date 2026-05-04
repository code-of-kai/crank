# Convergence — Stages 9 + 12 + 13

This brief is for the final session that runs **after** Tracks A, B, and C have all landed on `main`. It builds the Mix tasks, dogfoods the discipline through example FSMs and negative fixtures, and runs the full CI gate suite.

## Worktree

This session runs in its own auto-created Claude Code Desktop worktree off the latest `main`. The worktree lives at `.claude/worktrees/<auto-named-branch>/`. No manual git setup needed. When done, commit and push to the worktree's branch; merge back via PR or fast-forward; archive the session via the archive icon.

This is the convergence session — by the time it starts, Tracks A, B, and C should all be merged to `main`. Verify before starting: `git log --oneline main` shows commits from all three tracks landed.

## Prerequisites on `main`

All four prior shipped stages plus Tracks A, B, C:

- Foundation, OTP guard, static call-site checks, Server resource limits (commits from earlier sessions).
- Track A: `Crank.BoundaryIntegration`, `Crank.Compiler`, `Crank.Domain.Pure`, starter `boundary` config, macro form for state/memory typing.
- Track B: `Crank.PurityTrace`, `Crank.PropertyTest`.
- Track C: 22 violation doc pages, four new guides, `ROADMAP.md`, existing-guide updates.

Verify before starting:

- `mix test` on `main` is green (some 245+N tests as Tracks A, B add fixtures).
- `Process.whereis(Crank.TaskSupervisor)` returns a pid in IEx.
- `Boundary` is in `mix.exs` deps, `Crank.Compiler` exists.
- `Crank.PurityTrace.trace_pure/1` exists and works on a basic pure fixture.
- `guides/violations/CRANK_PURITY_001.md` exists and resolves under `mix docs`.

If any prerequisite is missing, **stop** — that track's session needs to land first. Convergence cannot proceed without all three.

## What to read first

1. `plans/purity-enforcement.md`, **Phase 4.5 — `mix crank.gen.config` task**.
2. **Phase 4.6 — `mix crank.check` task**.
3. **Phase 4.4 — Dogfooding (trimmed scope)**.
4. **Phase 4.7 — OTP version guard** — verify the three-layer enforcement is fully live (mix.exs metadata, runtime check, CI matrix). This was added in earlier shipping; this session confirms.
5. **Verification strategy** — every CI gate listed there must pass at end of session.

## What to build

### Stage 9.1 — `mix crank.gen.config` task

Path: `lib/mix/tasks/crank.gen.config.ex`. One-time setup task for new Crank projects.

Behaviour (limited to machine-structured config files only — README/CI-snippet edits are stdout-printed, **not** auto-edited):

1. Adds `boundary` and `crank` to `mix.exs` deps if missing.
2. Adds `:crank` to the `compilers:` list in the project config.
3. Writes a starter `boundary` config defining `:domain` and `:infrastructure` (the template Track A's Stage 5 produced).
4. Amends `.credo.exs` (or creates one if absent) to wire `Crank.Check.TurnPurity` without clobbering existing checks.
5. Prints to stdout the recommended CI snippet (`mix crank.check`) and a recommended README section. Does **not** modify README or CI YAML files.
6. Reports what it did and what's left for the user to verify.

Idempotent — re-running on a configured project produces no config changes.

Verification:

- Fresh fixture project with no Boundary → all setup steps complete.
- Already-configured fixture → no changes (asserted by file-content diff).
- Project with conflicting `compilers:` config → merges correctly.

### Stage 9.2 — `mix crank.check` task

Path: `lib/mix/tasks/crank.check.ex`. Canonical CI gate. Wraps `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, the Boundary check (via `mix compile`'s compiler chain when `:crank` is in `:compilers`), and the property-test suite.

Behaviour:

1. Verifies setup: `:crank` in `compilers:`, OTP >= 26. Fails fast with `CRANK_SETUP_001` / `CRANK_SETUP_002` if not.
2. Runs the underlying tools in sequence, aggregating exit codes.
3. Reports cumulative pass/fail with structured output.

Verification:

- Running on Crank's own repo passes.
- Running on a fixture project with a deliberate violation fails with the expected exit code and structured output.
- Running on a project lacking `:crank` in `compilers:` fails with `CRANK_SETUP_001`.
- Running on OTP 25 (mocked via `:erlang.system_info/1` overrides if needed) fails with `CRANK_SETUP_002`.

### Stage 12 — Dogfooding (trimmed scope)

In scope:

- **`Crank.Examples.*`** — every example FSM gets a property test using `Crank.PropertyTest.assert_pure_turn/3`. Examples already exist (`Crank.Examples.Door`, etc. — see `test/support/examples.ex`); add a property test per example.
- **Negative fixtures** — every catalog code gets at least one fixture in `test/fixtures/violations/` that triggers it. Already partially built by earlier tracks; Convergence completes coverage. Used as fixtures for `Crank.Errors` snapshot tests and for the `mix crank.check` integration tests.

Out of scope (kept on ROADMAP per the plan):

- `Crank.Turns.apply/1` refactor as a state machine.
- Documenting `Crank.Server`'s engine field as an FSM in disguise.

Verification:

- All example FSMs pass property tests with `assert_pure_turn`.
- Every catalog code has a triggering negative fixture; the test confirms the expected error code surfaces.

### Stage 13 — Final CI verification

Run every quantitative gate from the plan's verification strategy:

1. **`mix test`**: every existing test plus the new fixtures and property tests. **Hard gate**: zero failures.
2. **Snapshot tests for every error code**: pretty-form output. Snapshots normalised to exclude unstable fields (timestamps, pids, file-system-absolute paths replaced with placeholders).
3. **Round-trip tests for structured-form output**: deterministic.
4. **Catalog consistency test**: every code has a doc, every code is referenced by a check, no codes referenced in source are missing from catalog.
5. **Concurrency-stress test for `Crank.PurityTrace`**: 100 parallel calls; verdict + violating-call set match expectations; no cross-contamination.
6. **Property-test determinism**: same StreamData seed → identical verdict and identical shrunk input across 100 sequential runs.
7. **`mix credo --strict`**: clean.
8. **`mix dialyzer`**: zero warnings on Crank's own code; warning fires on a fixture project that returns an obviously-wrong shape from `turn/3`.
9. **`mix compile --warnings-as-errors`**: clean.
10. **Compile-time overhead ceiling**: `<50ms additional per-module compile time at the 95th percentile** across the benchmark corpus (10 runs per module). **Hard gate.**
11. **False-positive budget**: zero false positives on a corpus of 50+ pure-module fixtures. **Hard gate.**
12. **`mix test --only property`**: every example FSM through StreamData generation under `assert_pure_turn`. Minimum 1000 runs per example.

End-to-end scenario tests in `test/integration/`:

- **Pure-and-impure mixed fixture project**: uses Crank with both pure and impure modules; CI compiles and asserts each impure module fails with the expected error code.
- **Strict-mode dependency-direction fixture**: fails Boundary check with `CRANK_DEP_001`.
- **Trace-detected transitive impurity fixture**: trace catches it, property test fails with `CRANK_PURITY_007`.
- **Suppression fixtures** (one per layer): valid suppression silences; invalid suppression raises the appropriate `CRANK_META_*` code.
- **Setup fixtures**: project lacking `:crank` in `compilers:` fails `mix crank.check` with `CRANK_SETUP_001`. Project on OTP 25 (mocked) raises `CRANK_SETUP_002` at boot.

When everything is green:

- Bump version in `mix.exs` (this is a major-feature release; either 1.2.0 or 2.0.0 depending on whether `use Crank` semantics changed in user-visible ways — Track A's macro-form opts probably make this 2.0.0).
- Update `CHANGELOG.md` with the release entry.
- Commit, push, tag, and (if releasing) publish to hex.

## Verification gates (the convergence's own pass/fail)

The session is done when `mix crank.check` runs cleanly on Crank's own repo and all 12 verification gates above pass. This **is** the v1 release-readiness gate.

If any gate fails, it should produce an actionable failure pointing at a specific commit / file / catalog code. Don't merge a session that papers over a failing gate.

## Estimated complexity

- `mix crank.gen.config`: ~200 LOC including tests.
- `mix crank.check`: ~150 LOC including tests.
- Dogfooding: ~250 LOC across examples and tests.
- Integration test scenarios: ~200 LOC across `test/integration/`.
- Final CI verification, version bump, CHANGELOG, hex publication: ~50 lines edited + manual review.

Total session ballpark: ~850 LOC of code + tests, plus the release ceremony.

## Risks

- **Track-merge conflicts.** Tracks A, B, C should merge cleanly because they touch disjoint files. If conflicts arise, this session resolves them; rerun gates after each merge.
- **Hidden cross-track dependencies.** Track C may have written doc-page content that no longer matches Tracks A or B's actual implementation — fix the docs (lower-cost change) rather than the code, unless the implementation diverged from the plan.
- **CI flakiness on the concurrency-stress test.** The plan specifies "no assertion on trace ordering, only inclusion of expected entries" precisely to avoid this. If the test still flakes, increase repeat count rather than relaxing assertions; flakiness usually points at a real bug.
- **The compile-time ceiling could be tight on slower CI runners.** The 95th-percentile-of-10-runs design is meant to absorb noise; if runs systematically exceed 50ms, profile the AST walk and optimise (cache prefix-matching tries, skip irrelevant subtrees) rather than relaxing the gate.
- **OTP 26+ pinning is now load-bearing.** Confirm CI matrix runs only on OTP 26+; the runtime guard catches accidents but the CI matrix is what stops them in the first place.
