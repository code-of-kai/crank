# Transitions and guards

## What a transition contains

UML statechart theory gives every transition a standard form, written on the arrow between two states:

```
trigger [guard] / effect
```

Read it as: *when the machine is in some source state and the **trigger** event arrives, if the **guard** is true, perform the **effect** and move to the target state*. Four components — source state, trigger, guard, effect — plus the target state declared by the arrow itself. These are conceptually distinct, and good statechart design treats them as such.

Crank encodes all of this in a single function clause. Each statechart component lands in a specific syntactic position:

```elixir
def turn({:select, item}, %Accepting{balance: bal}, %{price: price} = memory)
#          ─── trigger ───  ── source state ──        ── extended state ──
    when bal >= price do
#   ────── guard ──────
  {:next, %Dispensing{selection: item}, memory}
# ──────────── effect + target state declared here ────────────
end
```

The mapping is direct and one-to-one. The first argument's pattern matches the **trigger**. The second argument's pattern matches the **source state**. The `when` expression is the **guard**. The return tuple declares the **effect** (as data, for the Server to execute) and names the **target state**. There's no construct missing and no construct doing double duty — each part of the UML transition arrow has its own home in the clause.

## Why no `guard` keyword

A DSL-based state machine library typically introduces a `guard` keyword that wraps a predicate, evaluates it before transitioning, and falls through to some default behaviour if it returns false. Crank refuses that whole apparatus, because Elixir's own `when` clause already is exactly the statechart guard: a boolean predicate evaluated after the trigger has arrived and the source state has been confirmed, gating whether the transition fires.

Elixir's vocabulary is precise here. The official docs define guards narrowly: a guard is a boolean expression introduced by `when` that augments pattern matching, drawn from a restricted set of operations the compiler allows. Patterns are a separate thing — they assert on shape and bind variables, and they live in argument positions, on the left of `=`, in `case` branches, and so on.

So Elixir's technical use of "guard" is the same as UML's. Both mean a boolean predicate evaluated after the event has arrived and the state has been confirmed. They map directly onto each other.

## Three things gate a clause

This is the subtle point worth being explicit about. Three different statechart concepts gate whether a Crank clause fires: trigger-matching, source-state-matching, and guard evaluation. Elixir's dispatcher runs all three together, which makes them feel like one mechanism at runtime, but they're three concepts wearing the same syntactic clothing:

- **Patterns** gate on shape and exact values. The state argument's struct (`%Accepting{}` vs `%Dispensing{}`) is source-state-matching. The event argument's pattern (`{:select, item}` vs `:cancel`) is trigger-matching. Neither is a guard.
- **`when` clauses** gate on relationships, ranges, and computed predicates — anything pattern matching can't express because it requires comparing bound variables. This is the guard, in both Elixir's and UML's sense of the word.

Conflating these three loses the distinction the statechart literature has spent decades sharpening. Patterns and `when` are doing different work; both happen to live in the clause head, but they correspond to different parts of the UML transition arrow.

## Two flavours of gating logic in practice

In Crank's idiom, you'll see both forms, often combined.

**Pattern-only**, when the gating logic is purely structural:

```elixir
def turn(:cancel, %Accepting{balance: bal}, memory) do
  {:next, %MakingChange{change: bal}, memory}
end
```

Source-state-match plus trigger-match. No guard needed.

**Pattern plus `when`**, when the gating logic includes a relationship between bound values:

```elixir
def turn({:select, item}, %Accepting{balance: bal}, %{price: price} = memory)
    when bal >= price do
  {:next, %Dispensing{selection: item}, memory}
end

def turn({:select, _item}, %Accepting{balance: bal}, %{price: price})
    when bal < price do
  :stay
end
```

Two clauses, two complementary guards, complete coverage. The dispatcher picks the matching clause; whichever one runs has, by definition, passed its guard. There is no "guard failed" branch to handle separately — failure means a different clause matched (or none did, which crashes loudly, exactly as `DESIGN.md` intends: *"No catch-all defaults. Unhandled events crash with `FunctionClauseError`. Silent ignoring hides bugs."*).

## Translating from XState or UML

If you come from XState or a UML statechart background, the rule is: *every place you'd attach a guard, write another function clause instead.* A complete UML transition arrow — `trigger [guard] / effect` between two states — becomes a complete function clause: trigger and source state in the patterns, guard in the `when`, effect and target state in the return tuple. Multiple transitions on the same event become multiple clauses, ordered by specificity (Elixir picks the first match, so put the more specific clauses first).

What you give up is the ability to inspect transitions as data — you can't iterate over a list of registered transitions at runtime, because there is no list. What you gain is that the entire state machine is the same kind of thing as every other piece of conditional logic in Elixir, with the same tooling, the same compiler checks, and the same purity guarantees Elixir builds into `when` clauses.

Those purity guarantees are stronger than they might first appear. The Elixir compiler restricts guard expressions to a small allow-list of side-effect-free operations — comparison operators, boolean operators, type-check functions like `is_integer/1`, arithmetic, and a handful of others. Anything not on the list is rejected at compile time. But the BEAM goes further: guards aren't allowed to crash either. If a guard expression raises (say, `map_size/1` is called on a tuple), the guard silently fails and the dispatcher tries the next clause. A crash is itself a kind of side effect — if guards could crash, you'd have to specify when and in what order they execute, which would defeat the dispatch optimisations that pattern matching depends on. So the BEAM turns guards into total pure functions by removing both side effects and exceptions.

This connects directly to the [hexagonal architecture guide](hexagonal-architecture.md): because guards are just `when` expressions, you cannot accidentally write one that hits a database, sends a message, or crashes the process. The compiler rejects the first two at compile time, because those operations aren't on the allow-list. The BEAM contains the third at runtime — even allowed operations that happen to raise (a type mismatch, a division by zero) silently fail the guard rather than crashing the dispatch. Compile-time rejection plus runtime containment together guarantee what the architecture requires.
