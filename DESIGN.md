# Crank — Design Specification

## What Crank does

`Crank.turn(machine, event)` takes a `%Crank{}` struct and an event and returns a new struct. That pure function is the entire core. `Crank.Server` runs the same callbacks inside `:gen_statem` when timeouts, supervision, or telemetry are needed.

## Moore, not Mealy

Crank is opinionated about the shape of its state machines. It is a **Moore machine**: the output of a state depends only on the state itself, not on the edge that arrived there.

- **Moore**: `output = f(state, memory)`. The state arrives; the state speaks.
- **Mealy**: `output = f(event, state, memory)`. The edge fires; the output is a property of the transition.

`:gen_statem`'s default grain is Mealy — you return actions from the transition clause, so every edge can declare a different set of effects. Crank flips this. Transitions (`turn/3`) compute state only; effects (`wants/2`) are declared on arrival at a state. You cannot attach an effect to an edge in Crank. The API does not provide the hook.

The practical consequence: in Crank, reading a module is state-first. You can read *what a state does* by looking at one `wants/2` clause, independent of which transition got you there. In a Mealy machine you have to scan every `handle_event` clause that arrives at that state to assemble the same picture.

## Design principles

- **Explicit over implicit.** Every decision is visible in the code.
- **Behaviours and pattern matching.** No DSLs. Define the callbacks; the framework calls them.
- **Pure core, effectful shell.** Business logic is pure data transformation. Processes are optional.
- **Moore discipline, enforced structurally.** The core API cannot declare effects from a transition. Effects live on states.
- **Function clauses declare the machine.** No redundant `states/0` callback. The set of `turn/3` clauses is the specification.
- **Small surface area.** The pure API is `new/2`, `turn/2`, `turn!/2`, `can_turn?/2`, `can_turn!/2`, `reading/1`, `snapshot/1`, `resume/1`.

## Two layers

### Layer 1: Pure core (`Crank`)

Works without any process. The `%Crank{}` struct carries five fields:

- `module` — the callback module.
- `state` — the current state (any Elixir term: atoms, structs, tagged tuples).
- `memory` — data carried across states.
- `wants` — declarations from the last state entry, stored as inert data.
- `engine` — `:running` or `{:off, reason}`.

Wants are never executed in the pure core. They are carried as data for the Server (or other interpreter) to act on.

`machine.wants` is a materialised cache of the `wants/2` callback. The invariant `machine.wants == module.wants(machine.state, machine.memory)` holds after `new/2`, after every `turn/2` (regardless of whether it returns `:next`, `:stay`, or `:stop`), and after `resume/1`. See Design Decision 2 below.

### Layer 2: Process shell (`Crank.Server`)

A thin `:gen_statem` adapter. It delegates all transition logic to the pure callback module, then does what pure functions can't:

- Executes wants (timeouts, sends, telemetry, internal events).
- Auto-replies to synchronous calls with `reading(state, memory)`.
- Emits `[:crank, :start]`, `[:crank, :resume]`, `[:crank, :transition]`, and `[:crank, :exception]` telemetry.
- Integrates with supervision trees and `:sys` debugging.

The public API is in `Crank.Server`. The `:gen_statem` callback module is `Crank.Server.Adapter` (internal).

### Layer 3: Composition (`Crank.Wants`, `Crank.Turns`, `Crank.Server.Turns`)

Three supplementary modules sit above Layers 1 and 2. They are entirely optional — every v1.0 machine keeps working without them — but they address two composition shapes the atoms don't provide directly:

- **`Crank.Wants`** — a pipe-friendly builder over the want vocabulary. Produces plain `[want()]` lists identical to hand-written tuple literals. Enables shared effect policies to be extracted into reusable helpers rather than hand-copied across every machine's `wants/2` clause.
- **`Crank.Turns`** — a descriptor struct that accumulates named turns against named machines, with function-resolved step dependencies on prior results. `Crank.Turns.apply/1` executes the descriptor against `%Crank{}` structs in pure mode. Best-effort sequential semantics: runs top-to-bottom, halts on the first stop, returns `{:ok, results}` or `{:error, name, reason, advanced_so_far}`.
- **`Crank.Server.Turns`** — the process-mode executor for the same descriptor. Walks the steps through `Crank.Server.turn/2` calls. Uses `Process.monitor/1` + bounded `receive` to detect post-reply termination (because `Process.alive?/1` is unreliable during gen_statem cleanup).

The pure/process split is symmetric with Layer 1/2: the descriptor is pure data that either executor can consume. Build once; inspect in tests; run pure or supervised.

None of these provide atomicity across machines. `Crank.Turns` is not a transaction. If step 2 stops after step 1 succeeded, step 1's advance stands. Compensation belongs in a saga — a separate Crank module that observes results and emits compensating commands. See the [Composing Work guide](guides/composing-work.md) for the full treatment.

## Callbacks

### Required

- `start(args)` — called once by `new/2` or `Crank.Server.start_link/3`. Returns `{:ok, state, memory}` or `{:stop, reason}`.
- `turn(event, state, memory)` — called on every event. Pure state computation. Returns where the machine should be next.

### Optional

- `wants(state, memory)` — called on every state change. Returns a list of `want` tuples. Defaults to `[]` if not implemented.
- `reading(state, memory)` — called by `Crank.reading/1` and by `Crank.Server.turn/2` to form the reply. Defaults to the raw state if not implemented.

## Return values

### From `turn/3`

- `{:next, new_state, new_memory}` — move to a different state. Fires `wants/2`.
- `{:stay, new_memory}` — same state, updated memory. Clears `wants`.
- `:stay` — no change at all.
- `{:stop, reason, new_memory}` — shut down the machine. `engine` becomes `{:off, reason}`.

No actions list. No effects. `turn/3` is pure state computation, period.

### From `wants/2`

A list of want tuples. Each describes one effect the state declares on arrival:

| Want | Meaning |
|---|---|
| `{:after, ms, event}` | Anonymous state timeout. One per state; auto-cancels on state-value change. |
| `{:after, name, ms, event}` | Named generic timeout. Multiple may run concurrently. Not auto-cancelled on state change. |
| `{:cancel, name}` | Cancel a named timeout. No-op if no such timer runs. |
| `{:next, event}` | Enqueue an internal event to be handled before any queued external event. |
| `{:send, dest, message}` | Send `message` to `dest` (pid, registered name, or `{name, node}`). Fire-and-forget. |
| `{:telemetry, name, measurements, metadata}` | Emit a telemetry event. |

The pure core stores these as data in `machine.wants`. `Crank.Server` interprets them.

### From `reading/2`

Any term. Typically a map projecting the parts of `(state, memory)` that external observers care about.

## Design decisions and rationale

1. **No actions on transitions.** The return from `turn/3` carries no effects. This is the structural enforcement of Moore discipline. Users cannot accidentally write Mealy code because there is no syntax for it.

2. **`machine.wants` is always `module.wants(state, memory)`.** In the pure core, the `wants` field is a materialised cache of the `wants/2` callback. `new/2`, every `turn/2`, and `resume/1` populate it; even `{:stop, reason, memory}` preserves it (a stopped machine still declares what its state would want — whether the engine can act is answered by the `engine` field, not by `wants`). The invariant `machine.wants == module.wants(machine.state, machine.memory)` is enforced by the library, not by convention.

3. **Server effect execution is separate from field semantics.** The Server executes effects (arms timers, performs sends, emits telemetry) on `{:next, ...}` arrivals only. Returning `{:stay, new_memory}` updates memory and recomputes `machine.wants` in the pure struct, but does *not* cause the Server to re-arm timers. To refresh the Server's active effects, return `{:next, same_state, new_memory}` — same-state re-entry cancels pending state timeouts and re-runs wants as new actions. The split: `:stay` is the silent-memory-update return; `:next` is the lifecycle-event return.

4. **`reading/2` is the reply contract.** `Crank.Server.turn/2` always replies with `reading(new_state, new_memory)`. User code cannot declare a reply. The reply is a property of arrival, not of the edge. `reading/2` is part of the error kernel — if it raises, the gen_statem terminates mid-transition.

5. **No `handle_event/4`.** The event type (`:cast`, `{:call, from}`, `:info`, `:timeout`) is not visible to `turn/3`. All events route through the same signature. If a machine needs to distinguish sources, the event *content* should carry that information. Raw `:info` messages (including monitor `:DOWN`, `:EXIT` when trapping) route through `turn/3`; modules that establish monitors must add matching clauses or tolerate a crash-and-restart.

6. **`engine` is separate from `state`.** `state` is the domain position. `engine` is the lifecycle flag. They vary independently — a stopped machine preserves the state it was in when it stopped, which is diagnostic information. Merging would lose that.

7. **Snapshots are plain maps.** Portable, serializable, no struct-tag dependency. Callers can construct one by hand.

8. **Pure resume populates the `wants` cache but executes nothing.** Pure mode never executes wants anyway, so "firing" is meaningless here — the cache is just data and must be consistent with decision 2's invariant. **Server resume re-executes wants** (re-arms timers, re-emits sends) because the fresh process needs its timers set. Recipients of `{:send, ...}` effects must be idempotent, or the effect belongs in a saga with durable delivery state.

9. **Same-state `{:next, ...}` re-entry cancels pending state timeouts.** Gen_statem auto-cancels state timeouts only on state-value changes. Crank's Server injects an explicit `{:state_timeout, :cancel}` when `{:next, ...}` returns the same state value, so re-entering with an empty `wants/2` correctly clears pending timers.

10. **Let it crash.** Unhandled events in `turn/3` raise `FunctionClauseError`. No catch-all defaults. If the module wants total-function behaviour (e.g., for property testing), it adds its own catch-all clause explicitly — and should not ship that clause to production.

11. **`child_spec/1` generated by `use Crank`.** Modules drop into supervision trees without boilerplate.

12. **Telemetry baked into the Server.** Four events ship with the process shell: `[:crank, :start]`, `[:crank, :resume]`, `[:crank, :transition]`, `[:crank, :exception]`. The exception event fires when `turn/3` raises/throws/exits, before the error re-raises and terminates the process.

13. **`can_turn?/2` only reports `false` for FCEs raised from `module.turn/3` itself.** An FCE raised by a helper called from `turn/3` is a genuine bug and is re-raised, not silently swallowed. The predicate's accuracy is guaranteed by checking the exception's `:module`, `:function`, and `:arity` fields against the machine's module.

## Struct-per-state

Each state can be its own struct, carrying only the fields that exist in that state. A `%Dispensing{}` can't have a `change` field because the struct doesn't define one. The compiler rejects it.

```elixir
defmodule Idle, do: defstruct []
defmodule Accepting, do: defstruct [:balance]
defmodule Dispensing, do: defstruct [:balance, :selection]
```

This works because `state` is `term()` — atoms, structs, tagged tuples are all valid. Pattern-matching on the struct type gives the state and its data in one destructure:

```elixir
def turn({:select, item}, %Accepting{balance: bal}, memory)
    when bal >= memory.price do
  {:next, %Dispensing{balance: bal, selection: item}, memory}
end
```

State-specific data lives in the struct. Cross-cutting memory (price, stock count) lives in `memory`.

Structs are immutable. `%Accepting{balance: 25}` and `%Accepting{balance: 50}` are two different values. That's a state change — use `{:next, ...}`. `{:stay, ...}` means the struct value is literally identical.

## Compiler-checked exhaustiveness (future)

Elixir's set-theoretic type system (introduced in v1.17, with inference expanding through 2026) lets the compiler reason about union types and warn when a function doesn't handle all variants:

```elixir
@type state ::
  Idle.t() | Accepting.t() | Dispensing.t() | MakingChange.t() | OutOfStock.t()
```

When the compiler can check this, unhandled variants in `turn/3` will produce warnings with zero code changes. `Crank.Examples.Submission` is written with this in mind.
