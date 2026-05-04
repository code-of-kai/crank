# Crank — Roadmap

Entries here are ideas with clear direction but no committed timeline. Each records what the goal is, why it matters, and what is blocking or gating it.

The current enforcement story (compile-time call-site checks, Boundary topology, runtime tracing under property tests) is the practical answer to all of these for v1.x. The roadmap names what would be needed to push the story further.

---

## Effect-typed callbacks via a hypothetical Elixir effect system

**What.** A type annotation or inference system that marks functions as pure or impure and rejects impure calls inside a callback declared pure. `turn/3` would carry an effect annotation; transitive purity would propagate through the type checker; helpers would be checked at definition rather than at trace time. The `Crank.Check.Blacklist` and runtime trace would become belt-and-braces complements to a structurally-enforced rule.

**Why it matters.** Today's enforcement is bounded — strong on the categories named in the detection matrix, silent outside them. A genuine effect discipline would reduce the gap to "trust in third-party libraries" plus "deliberate sabotage" — the same residual every static-purity discipline shares.

**Blocker.** Elixir's set-theoretic type system (introduced experimentally in v1.17, expanding through 2026) tracks value shapes — union types, intersection types, type inference across function boundaries. It does not currently track effects. Adding effects would require either an effect system layered on the set-theoretic types (analogous to Koka or Haskell), or a restricted-callback mechanism in the BEAM similar to the guard allowlist applied to user-declared pure callbacks. Neither is on the Elixir or BEAM roadmap as of 2026. Crank should adopt either the moment it lands.

---

## Trace-aware property-test shrinking

**What.** When a property test under `Crank.PropertyTest.assert_pure_turn/3` fails on an impure-call observation, StreamData should shrink toward the *minimal* event sequence that still triggers the impure call — using the trace-call set, not just the test-failure boolean, as the shrink target.

**Why it matters.** Today's shrinking treats the property as opaque-pass-or-fail. A failing trace produces a 30-event sequence; the user has to manually reduce it to find the trigger. A shrink that knew which call was the cause could shrink toward removing all events that don't reach that call.

**Blocker.** Requires changes to `StreamData`'s shrinking interface to expose richer failure context, or a Crank-side wrapper that re-runs the shrink loop with custom termination conditions. The right design is unclear; needs prototyping against a real shrink target before locking in an API.

---

## Compile-time exhaustiveness on `turn/3`

**What.** When the declared state union (`use Crank, states: [...]`) is closed, the compiler should warn on `turn/3` clauses that don't cover every (event, state) combination — the same way Rust's `match` exhaustiveness check warns on missing variants.

**Why it matters.** This closes the "unhandled event" gap that currently surfaces as `FunctionClauseError` at runtime. With closed state and closed event unions, the compiler can prove totality.

**Blocker.** Elixir's set-theoretic types (v1.17+) have the foundations but exhaustiveness checking on `def`-clauses is not yet there. Cross-referenced in `DESIGN.md` as "Compiler-checked exhaustiveness (future)." Crank's macro form already produces the type declarations the future check would consume; no Crank-side changes are needed when the language work lands.

---

## Internal refactor: `Crank.Turns.apply/1` as a state machine

**What.** Today `Crank.Turns.apply/1` is a fold over the descriptor's step list. It is a state machine in disguise — pre-flight validation, sequential execution, halt-on-stop, error tagging. Restating it as an explicit Crank machine would dogfood the library on its own internals and would surface the implicit state transitions in the API.

**Why it matters.** Runs as a self-test for whether Crank is ergonomic enough for serious internal use. Probable secondary benefit: the descriptor surface gets clearer because the states have names.

**Blocker.** None — this is an internal-only change. Deferred from v1 to keep the dogfooding scope tight; ships when the work has somewhere to slot in.

---

## Internal refactor: explicit FSM for `Crank.Server`'s `engine` field

**What.** `Crank.Server`'s `engine` field tracks `:running | {:off, reason}`. Today it's an enum tag manipulated directly. Modelling it as an explicit Crank machine clarifies the lifecycle (boot → running → stopping → stopped) and makes future additions (e.g., `:paused`) regular extensions.

**Why it matters.** Same dogfooding rationale as `Crank.Turns.apply/1`. The lifecycle is currently spread across `init/1`, `terminate/2`, and assorted callback returns; a single FSM would localise it.

**Blocker.** None. Deferred to keep v1 surface area stable.

---

## Per-process polling reduction-budget enforcement in `Crank.PurityTrace`

**What.** A fourth resource bound (alongside heap and timeout): cap the number of reductions a `turn/3` is allowed to consume during a traced run.

**Why it matters.** Reduction budgets catch a class of cases that timeout doesn't — turns that yield often enough to avoid the wall-clock cap but consume disproportionate scheduler time. Useful in CI where the clock varies but reduction counts are stable.

**Blocker.** The only mechanism that fits the threat model — `:erlang.system_monitor/2` — is VM-global. Only one process can be the monitor at a time across the entire BEAM. Parallel `trace_pure/2` calls would race for the slot and corrupt each other's results. A per-process polling variant (`Process.info(self(), :reductions)` from inside the worker) requires the worker to cooperate; it can't preempt a tight loop. There is no clean alternative that works under parallel ExUnit. Ships only after a concurrency-safe design exists.

---

## `CRANK_TYPE_001_DIALYZER` — Dialyzer-warning-level field-type detection

**What.** Today's `CRANK_TYPE_001` covers field-*name* validation only — Elixir's compiler rejects `%{memory | unknown_field: x}` natively. A separate code would track Dialyzer's field-*type* warnings: `memory.balance` declared as `non_neg_integer()` but receiving a `String.t()`.

**Why it matters.** Closes the type-mismatch gap that requires running Dialyzer to detect. Most users do run Dialyzer; Crank should surface the diagnostic with the same code/rule taxonomy as the rest of the catalog so the failure routes through `Crank.Errors`.

**Blocker.** Dialyzer warnings are not part of the compile pipeline by default. Wiring them into `mix crank.check` is straightforward; the design question is whether Dialyzer warnings should be hard errors or stay at warning level in CI. Needs a default-mode decision before shipping.

---

## Strict transitive analysis beyond Boundary

**What.** Boundary works at the OTP-application level for third-party deps and at the module level for first-party code. A stricter analysis would walk the function call graph and reject calls into infrastructure even when they go through several layers of pure-looking helpers — what `CRANK_PURITY_007` catches at runtime, but at compile time.

**Why it matters.** Pushes the static-detection coverage closer to soundness for the categories where the call graph is statically resolvable. Combined with effect typing (top of this list), this would close most of the residual gap.

**Blocker.** Function-call-graph cuts are a known-hard problem in dynamic languages. Boundary's authors looked at this and chose module-level granularity for reachability and stability. A Crank-side function-call-graph cut would need to handle dynamic dispatch (`apply/3`), behaviours, and protocol implementations without false-positive explosion. Not impossible, but a substantial body of work; ships only with a detailed design that has been validated against representative codebases.
