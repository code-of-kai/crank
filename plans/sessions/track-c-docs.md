# Track C — Documentation (Stages 10 + 11)

This brief is for a single Claude Code Desktop session that writes all the markdown deliverables: 22 per-violation doc pages, `ROADMAP.md`, four new guides, and updates to existing guides. **No Elixir code in this track.** Pure markdown, fully independent of Tracks A and B.

## Worktree

This session runs in its own auto-created Claude Code Desktop worktree off the latest `main`. The worktree lives at `.claude/worktrees/<auto-named-branch>/`. No manual git setup needed. When done, commit and push to the worktree's branch; merge back via PR or fast-forward; archive the session via the archive icon.

If `main` advances during the session (Track A or Track B lands), fetch and rebase before merging back. Track C touches only markdown files (`guides/*.md`, `guides/violations/*.md`, `ROADMAP.md`, `README.md`, `DESIGN.md`, `CHANGELOG.md`, `mix.exs` for ExDoc extras); conflicts with A or B are unlikely.

## Prerequisites on `main`

- Foundation: the catalog (`Crank.Errors.Catalog`) is on `main` and frozen — every code's stable identifier and rule are settled (commit `0df893d`).
- Static call-site checks shipped (`ecc0618`).
- Server resource limits shipped (`62fd91d`).

You don't need Tracks A or B to be done. The doc pages reference the catalog codes (which are frozen) and the architectural layers (whose names are committed), not the implementation details. Code examples in the docs can describe the intended behaviour even if the corresponding code lands later.

Verify before starting: `cat lib/crank/errors/catalog.ex` shows all 22 codes; `mix test test/crank/errors/catalog_test.exs` passes.

## What to read first

1. `plans/purity-enforcement.md`, **Phase 3.3 — Per-violation documentation pages** (template + per-code coverage requirement).
2. **Phase 4.1 — `ROADMAP.md`** (entries spec).
3. **Phase 4.2 — New guides** (four guides with their roles).
4. **Phase 4.3 — Existing-guide updates** (README, DESIGN, hexagonal-architecture, CHANGELOG).
5. The full **Frozen catalog** table in 3.2 — every code listed here gets a doc page.
6. The **Per-code ownership table** for the detection mechanism details (the "What triggers this" section of each doc page comes from this).
7. The **Detection matrix** for context on which layer catches what.
8. The **Non-detectable classes** section (informs the `ROADMAP.md` "future work" entries).
9. `~/.claude/writing-rules.md` — cross-project writing conventions.

## What to build

### 22 per-violation doc pages (`guides/violations/CRANK_*.md`)

One file per code in `Crank.Errors.Catalog`. Use the plan's template (Phase 3.3):

```markdown
# CRANK_PURITY_001 — Impure call inside turn/3

## What triggers this
[Code example showing the violation. Use the actual blacklist entries
from lib/crank/check/blacklist.ex.]

## Why it's wrong
[Two paragraphs maximum. The architectural concern: hexagonal boundary,
testability, error kernel, etc. Pull from existing guides for consistent
voice.]

## How to fix

### Wrong
[Side-by-side wrong code]

### Right
[Side-by-side right code with telemetry-as-want or wants/2 alternative]

## How to suppress at this layer
[Layer-specific syntax — A, B, or C — per the code's catalog layer.
Source comments for static_call_site/type/meta; Boundary config for
static_topology; :allow opt for runtime. Catalog.suppressible_by/1 in
the codebase resolves this.]

## See also
- [Hexagonal architecture guide]
- [Transitions and guards guide]
```

Each page is one screen of markdown. Don't pad. The codes are:

- `CRANK_PURITY_001..007` (turn-purity-direct, discarded, logger, nondeterminism, process-comm, ambient-state, transitive)
- `CRANK_DEP_001..003` (dependency-direction, unmarked-domain-helper, unclassified-external-dep)
- `CRANK_TYPE_001..003` (memory-field-unknown, function-in-memory, unknown-state-returned)
- `CRANK_RUNTIME_001..002` (resource-heap, resource-timeout)
- `CRANK_TRACE_001..002` (atom-table-mutation, process-dict-mutation)
- `CRANK_META_001..004` (suppression-missing-reason, suppression-unknown-code, suppression-orphaned, suppression-wrong-layer)
- `CRANK_SETUP_001..002` (boundary-not-wired, otp-version-too-old)

Verify each page references the correct layer's suppression mechanism (Layer A / B / C). `CRANK_DEP_*` codes are Layer B (Boundary config). `CRANK_PURITY_007`, `CRANK_RUNTIME_*`, `CRANK_TRACE_*` are Layer C (`:allow` opt). Everything else is Layer A (source comment).

Add a `guides/violations/index.md` landing page listing every code with its one-line description from the catalog (drives discoverability from hexdocs).

### `ROADMAP.md`

Path: `ROADMAP.md` (repo root). Forward-looking entries per Phase 4.1:

- Effect-typed callbacks (aspirational; depends on a hypothetical Elixir effect system).
- Trace-aware property-test shrinking improvements.
- Compile-time exhaustiveness on `turn/3` (cross-reference the existing note in `DESIGN.md`).
- Internal refactors: `Crank.Turns.apply/1` as a state machine; explicit FSM for `Crank.Server`'s engine field.
- Per-process polling reduction-budget enforcement in `Crank.PurityTrace` (deferred from v1 because no concurrency-safe design exists yet — `:erlang.system_monitor/2` is VM-global).
- `CRANK_TYPE_001_DIALYZER` — Dialyzer-warning-level detection of memory field-type mismatches (the catalog's `CRANK_TYPE_001` covers field-name validation only).
- Strict transitive analysis beyond what Boundary provides (function-call-graph cuts).

Each entry: one-sentence description plus 2-3 sentences of rationale and current blockers.

### Four new guides

- **`guides/typing-state-and-memory.md`** — the discipline of tight typing for state unions and memory structs; how it activates type-system enforcement progressively (the struct-field-rejection insight from the design conversation).
- **`guides/property-testing.md`** — pure-mode + property tests + tracing as the canonical purity-verification pattern. Code examples reference `Crank.PropertyTest.assert_pure_turn/3` (Track B may not have shipped this yet — note that explicitly in the guide, framed as "the API documented here lands with Track B").
- **`guides/boundary-setup.md`** — how to add Boundary as a dependency, copy the Crank starter config, and integrate `mix crank.check` into CI. Note that `mix crank.gen.config` automates this (lands in Convergence).
- **`guides/suppressions.md`** — documents the three layer-specific suppression mechanisms with side-by-side examples. Read `Crank.Suppressions` source on `main` for the Layer A syntax; quote the plan's Phase 3.4 for Layers B and C.

### Existing-guide updates

- **`README.md`** — add a "Purity enforcement" subsection in the Documentation index pointing at the new guides and the violations index.
- **`DESIGN.md`** — add a "Layered enforcement" section (one paragraph) referencing the new guides and ROADMAP. Cross-link from "Compiler-checked exhaustiveness."
- **`guides/hexagonal-architecture.md`** — replace the existing "Anti-patterns" with a stronger version that references the static and runtime checks. Add a section "Verification of the boundary at compile and runtime" pointing at the property-testing guide.
- **`CHANGELOG.md`** — single entry covering the layered enforcement work, by stage. Include the OTP 26+ requirement and the `Boundary` dependency addition (these affect users picking versions).

### `mix.exs` ExDoc updates

Add to the `extras:` list under `docs/0`:

```elixir
extras: [
  # ... existing ...
  "guides/typing-state-and-memory.md",
  "guides/property-testing.md",
  "guides/boundary-setup.md",
  "guides/suppressions.md",
  "guides/violations/index.md",
  # 22 per-violation pages — see groups_for_extras below for grouping
  "ROADMAP.md"
]
```

Add `groups_for_extras` entries grouping the violation pages under "Violations".

## Verification gates

All must pass before merging back to `main`:

1. `mix docs` builds without warnings or broken links.
2. Every catalog code in `Crank.Errors.Catalog` has a corresponding `guides/violations/CRANK_*.md` file (verify by listing the directory and comparing to `Catalog.codes() |> MapSet.to_list()`).
3. `guides/violations/index.md` lists every code with its one-line description.
4. The four new guides resolve cross-links to existing guides correctly.
5. `mix test` continues to pass on existing tests (this track shouldn't change any code).

## Estimated complexity

- 22 doc pages × ~30 lines each = ~660 lines of markdown.
- Index page: ~50 lines.
- ROADMAP.md: ~150 lines.
- Four new guides × ~200 lines each = ~800 lines.
- Existing-guide updates: ~150 lines total.
- mix.exs additions: ~30 lines.

Total session ballpark: ~1,800 lines of markdown, no Elixir code.

## Risks

- Some doc-page content depends on details that Tracks A and B haven't finalised. Where this comes up, write the page describing the **intended behaviour per the plan**, and note in the page that "the implementation lands with Track A/B". Do not block on Tracks A and B.
- Cross-link names matter — use the page titles ExDoc generates from the file names (`Crank.PurityTrace`, etc.) rather than guessing. Run `mix docs` early and often to catch broken links.
- The `guides/suppressions.md` guide is the place that documents three different mechanisms in one place; getting the cross-references right (which code goes with which layer, and what fires `CRANK_META_004`) is fiddly. Pull truth from `Crank.Errors.Catalog.suppressible_by/1` in the codebase rather than reasoning from memory.
