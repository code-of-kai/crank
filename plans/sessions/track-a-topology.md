# Track A — Topology layer (Stages 3 → 5 → 6)

This brief is for a single Claude Code Desktop session that runs the three Boundary-related stages sequentially. They are tightly coupled — Phase 0's spike outcome shapes Stage 5's design.

## Worktree

This session runs in its own auto-created Claude Code Desktop worktree off the latest `main`. The worktree lives at `.claude/worktrees/<auto-named-branch>/`. No manual git setup needed. When done, commit and push to the worktree's branch (auto-named like `claude/serene-jackson` or whatever the user's prefix produces); merge back via PR or fast-forward; archive the session via the archive icon to clean up the worktree and branch.

If the worktree branch falls behind `main` because Track B or Track C lands first, fetch and rebase before merging back. Track A touches `lib/crank/boundary_integration.ex` (new), `lib/crank/compiler.ex` (new), `lib/crank/domain/pure.ex` (new), `lib/crank.ex` (extended `__using__`), `mix.exs` (new dep), `priv/boundary.exs.template` (new), and tests; conflicts with B or C are unlikely.

## Prerequisites on `main`

- Foundation: `Crank.Errors`, `Crank.Errors.Catalog`, `Crank.Errors.Violation`, `Crank.Check.Blacklist`, `Crank.Suppressions` (commit `0df893d`).
- OTP guard: `Crank.Application` running with `Crank.TaskSupervisor` (commit `0df893d`).
- Static call-site checks: `Crank.Check.TurnPurity` (Credo) and `Crank.Check.CompileTime` (`@before_compile`) hooked into `use Crank` (commit `ecc0618`).
- Server resource limits unrelated to topology but already on `main` (commit `62fd91d`).

Verify before starting: `mix test` shows 245 tests passing.

## What to read first

1. `plans/purity-enforcement.md`, **Phase 0 — Boundary feasibility spike** (the spike contract).
2. **Phase 1.4 — Boundary integration for dependency direction** (the design the spike validates or revises).
3. **Phase 1.5 — `Crank.Domain.Pure` marker module** (depends on 1.4).
4. **Phase 1.7 — Memory and state typing guidance + macro form** (depends on 1.4 and 1.5).
5. The **Decisions resolved** section (decisions are committed; do not re-litigate strict-by-default, Boundary-as-dep, or `Crank.Compiler`-inside-Crank).
6. The detection matrix and per-code ownership table for `CRANK_DEP_001`, `CRANK_DEP_002`, `CRANK_DEP_003`, `CRANK_TYPE_001`, `CRANK_TYPE_002`, `CRANK_TYPE_003`.

## What to build

### Phase 0 — Spike (do first)

- Add `{:boundary, "~> X.Y"}` to `mix.exs` deps. Choose the latest stable version available at session time.
- Create `test/spike/boundary_integration/` with three modules: one `use Crank` domain module, one helper marked via `use Crank.Domain.Pure`, one infrastructure module.
- Working `boundary` config classifying them correctly.
- Working violation: domain module aliases the infrastructure module; Boundary fires; the diagnostic translates to a `Crank.Errors.Violation` with code `CRANK_DEP_001` and the file/line/offending-call info populated.
- Working clean case: domain module calls the marked helper; Boundary passes.

**Pass criteria** (per the plan's Phase 0):
- The spike produces a `CRANK_DEP_001` violation with all required fields populated.
- The spike's Boundary config is reusable as the Phase 1.4 starter template (or the deltas are small and documented).
- The `use Crank` → Boundary tag mechanism is compatible with both `use Crank` and `use Crank.Domain.Pure` without rewrites.

**If the spike fails:** stop. Append a `Phase 0 outcome` section to `plans/purity-enforcement.md` describing what didn't work and proposing a redesign for Phase 1.4 (e.g., a thin Crank-specific graph check rather than relying on Boundary's diagnostic surface). Commit and push the spike + outcome write-up; surface to the user before continuing to Stage 5.

**If the spike passes:** delete the spike fixtures (they're throwaway), record a short "Phase 0 outcome — passed" note in the plan, and proceed to Stage 5.

### Stage 5 — `Crank.BoundaryIntegration` + `Crank.Compiler` + `Crank.Domain.Pure`

- Implement `Crank.BoundaryIntegration` that translates Boundary's diagnostic structs into `Crank.Errors.Violation` structs.
- Implement `Crank.Compiler` (a Mix compiler) that wraps Boundary's compiler and emits Crank-formatted errors.
- Implement `Crank.Domain.Pure` with `__using__` macro that tags the module with the `:domain` Boundary attribute, registers it as subject to the same `@before_compile` enforcement as `use Crank`, and emits a `@__crank_domain_pure__` attribute the existing `Crank.Check.CompileTime.__on_definition__/6` already keys on (every public/private function body becomes subject to the call-site blacklist).
- Update `Crank` macro (`lib/crank.ex`'s `__using__`) to also emit the `:domain` Boundary tag.
- Ship a starter `boundary` config in `priv/boundary.exs.template` matching the **External dependency policy** spec in 1.4. Boundary handles **OTP-app-level third-party classification only**; stdlib enforcement stays in 1.1 / 1.3 / 2.1. Seed `:third_party_pure` and `:third_party_impure` with commented-out suggestions per the plan.
- Verification fixtures match the table in 1.4's verification section. Boundary violations surface as `CRANK_DEP_001` / `CRANK_DEP_002` / `CRANK_DEP_003`.

### Stage 6 — Macro form for state/memory typing

- Extend `Crank.__using__/1` to accept `states: [...]` and `memory: ...` opts.
- Generate `@type state/0` (closed union of the listed structs) and `@type memory/0` (the named memory struct) automatically.
- Add a compile-time check that all `turn/3` clauses return states from the declared union (`CRANK_TYPE_003` warning).
- Reject `function/0` or `module/0` types appearing inside `@type memory/0` or `@type state/0` (`CRANK_TYPE_002` error).
- Verify generated typespecs via `Code.Typespec.fetch_specs/1` (the actual Elixir public API; do **not** use `Module.spec_to_callback/2`, which is not the right API).

## Verification gates

All must pass before merging back to `main`:

1. `mix test` — every existing test plus new fixtures for `CRANK_DEP_001..003`, `CRANK_TYPE_001..003`. Minimum: zero regressions (currently 245 tests).
2. `mix credo --strict` — clean.
3. Compile-time overhead per module ceiling **<50ms additional at the 95th percentile** across the benchmark corpus (10 runs per module). Hard gate.
4. False-positive budget: zero false positives on the 50+ pure-module fixture corpus referenced in the plan.
5. The `mix crank.check` task does not exist yet (Convergence builds it). Skip that gate; manual `mix test` covers the verification.

## Estimated complexity

- Phase 0 spike: ~150 LOC throwaway plus investigation.
- Stage 5: ~200 LOC integration glue + ~50 LOC `Crank.Compiler` + ~150 LOC config template + tests.
- Stage 6: ~200 LOC macro + ~100 LOC tests.

Total session ballpark: ~700 LOC of code + tests, plus the boundary.exs starter template.

## Risks

- The Phase 0 spike could surface integration surprises that change Stage 5's design. The brief is structured to make that visible early — if the spike fails, stop, document, surface to the user before proceeding.
- The `:third_party` classification list in the starter config is judgment work — err on the side of leaving entries commented out rather than over-specifying.
- The macro form (Stage 6) extends `Crank.__using__/1` further; verify the existing `@before_compile` and `@on_definition` hooks still fire correctly when the new opts are present.
