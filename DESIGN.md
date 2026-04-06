# Crank -- Design Specification

## Purpose

Crank models finite state machines as pure, testable data structures first,
with an optional thin `:gen_statem` process adapter.

## Core Principles

- **Explicit over implicit** -- every decision is visible in the code.
- **Behaviours + pattern matching**, never DSLs.
- **Pure core** -- business logic lives in pure functions; processes are optional.
- **Function clauses declare the machine** -- no redundant `states/0` callback.
- **Full gen_statem power** preserved in the Server; nothing amputated.
- **Small surface area**, full OTP composability, pipelines first.

## Architecture

### Layer 1: Pure Core (`Crank` + `Crank.Machine`)

100% usable without any process. The `%Crank.Machine{}` struct carries:

- `module` -- the callback module
- `state` -- current state (any term, typically an atom)
- `data` -- arbitrary user data
- `effects` -- effects from the last crank, stored as inert data
- `status` -- `:running` or `{:stopped, reason}`

Effects are **never executed** in the pure core. They are carried as data for
the caller or Server to interpret. Each `crank/2` call replaces (not
appends) `effects`.

### Layer 2: Process Shell (`Crank.Server`)

A thin `:gen_statem` adapter (NOT GenServer). Delegates all crank logic to
the pure callback module, then:

- Executes effects (timeouts, replies, postpone, etc.)
- Emits `[:crank, :transition]` telemetry events
- Integrates with supervision trees, `:sys` debugging, hot code reloading

The internal gen_statem implementation lives in `Crank.Server.Adapter`.

## Behaviour Callbacks

### Required

- `init(args)` -- returns `{:ok, state, data}` or `{:stop, reason}`
- `handle_event(event_type, event_content, state, data)` -- arity 4, same order as gen_statem

### Optional

- `on_enter(old_state, new_state, data)` -- called after state changes

## Callback Signature

`handle_event/4` mirrors `:gen_statem`'s `handle_event_function` mode exactly --
same arguments, same order:

```elixir
@callback handle_event(event_type, event_content, state, data)
```

The `event_type` argument is one of:

- `:internal` -- pure cranks via `Crank.crank/2`, or `{:next_event, :internal, _}`
- `:cast` -- async events via `Crank.Server.cast/2`
- `{:call, from}` -- sync events via `Crank.Server.call/3`
- `:info` -- raw messages from linked processes
- `:timeout` -- event timeouts
- `:state_timeout` -- state timeouts
- `{:timeout, name}` -- named timeouts

In pure code, event_type is always `:internal`. Use `_` to ignore it when
the clause works in both contexts:

```elixir
# Works in both pure and Server
def handle_event(_, :unlock, :locked, data), do: {:next_state, :unlocked, data}

# Server-only: match on {:call, from} to reply
def handle_event({:call, from}, :status, state, data) do
  {:keep_state, data, [{:reply, from, state}]}
end
```

## Return Values

All return values mirror `:gen_statem`:

- `{:next_state, new_state, new_data}`
- `{:next_state, new_state, new_data, actions}`
- `{:keep_state, new_data}`
- `{:keep_state, new_data, actions}`
- `:keep_state_and_data`
- `{:keep_state_and_data, actions}`
- `{:stop, reason, new_data}`

Invalid returns raise `ArgumentError` with a clear message identifying
the callback module and state.

## Key Design Decisions

1. **No `states/0` callback** -- function clauses are the declaration
2. **Identical argument order** -- `handle_event(event_type, event_content, state, data)` matches gen_statem's `handle_event_function` mode verbatim
3. **Arity-4 with explicit event_type** -- no hidden tagging
4. **`:internal` for pure cranks** -- honest about what a programmatic event is
5. **`on_enter/3` receives old_state** -- essential for cleanup and logging
6. **Effects are data** -- stored in `effects`, never executed in pure core
7. **Effects replace, not accumulate** -- each crank starts fresh
8. **Bare `%Machine{}` returns** -- enables pipeline ergonomics without tuple unwrapping
9. **No catch-all defaults** -- unhandled events crash (FunctionClauseError)
10. **No `current_state/1`** -- use `:sys.get_state` for debugging
11. **Telemetry in Server only** -- pure core has zero side effects
12. **Module validation at init** -- `Crank.new/2` and `Crank.Server.Adapter.init/1` verify the module implements `handle_event/4`

## Server Event Type Passthrough

The Server passes gen_statem event types directly to `handle_event/4` with
no translation:

| gen_statem event type | Callback receives |
|---|---|
| `:cast` | `handle_event(:cast, event, state, data)` |
| `{:call, from}` | `handle_event({:call, from}, event, state, data)` |
| `:info` | `handle_event(:info, msg, state, data)` |
| `:timeout` | `handle_event(:timeout, content, state, data)` |
| `:state_timeout` | `handle_event(:state_timeout, content, state, data)` |
| `{:timeout, name}` | `handle_event({:timeout, name}, content, state, data)` |
| `:internal` | `handle_event(:internal, event, state, data)` |
| `:enter` | `on_enter(old_state, new_state, data)` -- separate callback |

No translation, no tagging, no magic. The Server is a pass-through.

## Struct-Per-State (Wlaschin Pattern)

Crank supports Scott Wlaschin's "Making Illegal States Unrepresentable" pattern
without any core changes. `Machine.state` is `term()` — atoms, structs, tagged
tuples all work. The Submission example demonstrates the pattern.

### How It Works

Each state is its own struct. The struct defines exactly what data exists
in that state — no optional fields, no "only set when state is X" comments:

```elixir
defmodule Validating, do: defstruct violations: []
defmodule Quoted,     do: defstruct quotes: [], selected: nil
defmodule Bound,      do: defstruct quote: nil, bound_at: nil
defmodule Declined,   do: defstruct reason: nil
```

A `%Quoted{}` can't have a `violations` field. A `%Bound{}` can't have a
`quotes` list. The struct enforces it.

### State/Data Split

State structs carry state-specific data. The `data` map carries cross-cutting
concerns shared across all states:

```elixir
def init(opts) do
  {:ok, %Validating{}, %{parameters: opts[:parameters] || %{}, audit: []}}
end
```

This maps cleanly to gen_statem's `(state, data)` separation.

### Within-Type Mutations

When a field on the current state struct changes (e.g., adding a violation),
use `{:next_state, ...}` — the state value changed:

```elixir
def handle_event(_, {:violation, v}, %Validating{} = s, data) do
  {:next_state, %Validating{s | violations: [v | s.violations]}, data}
end
```

`:keep_state` is reserved for changes to `data` only. This triggers `on_enter`,
which is correct — the state did change.

### Set-Theoretic Types (Future)

Elixir's set-theoretic type system (v1.17+ with inference expanding through 2026)
will make the compiler verify exhaustiveness:

```elixir
@type arc_state ::
  %Validating{} | %Quoted{} | %Bound{} | %Declined{}
```

The compiler will warn if `handle_event/4` doesn't cover all variants.
The Submission example is designed to be ready for this.
