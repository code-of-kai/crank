# Crank — Roadmap

Entries here are ideas with clear direction but no committed timeline. Each records what the goal is, why it matters, and what is blocking or gating it.

---

## Structural enforcement of `turn/3` purity via Elixir effect types

**What.** Today, `turn/3` purity is conventional — nothing in the compiler stops a developer from calling `Repo.insert!` inside a `turn/3` clause. The `Crank.Check.TurnPurity` Credo check catches the obvious violations statically, but it works from a configurable blacklist and cannot detect indirect calls or calls to unknown infrastructure modules.

A true solution would be a language-level effect discipline: a type annotation or inference system that marks functions as pure or impure, and rejects impure calls inside a callback declared pure. Elixir's `when` guards already have exactly this property — the BEAM's allowlist enforces it at compile time and contains crashes at runtime. `turn/3` does not.

**Why it matters.** The hexagonal architecture guarantee Crank makes — *"the domain model cannot reach infrastructure"* — is currently enforced by convention and tooling, not by the type system. Structural enforcement would make violations impossible, not merely detectable.

**What would enable it.** Elixir's set-theoretic type system (introduced experimentally in v1.17, expanding through 2026) tracks value shapes — union types, intersection types, type inference across function boundaries. It does not currently track effects. A genuine effect discipline would require either:

- An effect system layered on top of the set-theoretic types (analogous to Koka's algebraic effects or Haskell's IO monad), or
- A restricted-callback mechanism in the BEAM similar to the guard allowlist, applied to user-declared pure callbacks.

Neither is on the Elixir or BEAM roadmap as of 2026. This entry is aspirational: if the language moves in this direction, Crank should adopt it immediately. Until then, `Crank.Check.TurnPurity` is the practical enforcement path.

**Current mitigation.** `Crank.Check.TurnPurity` — a Credo check shipped with the library that warns on calls to known-impure module prefixes inside `turn/3` bodies. Configurable, zero runtime cost, catches the common cases.
