# Decidable -- Design Specification

## Purpose

Decidable models finite state machines as pure, testable data structures first,
with an optional thin `:gen_statem` process adapter.

## Core Principles

- **Explicit over implicit** -- every decision is visible in the code.
- **Behaviours + pattern matching**, never DSLs.
- **Pure core** -- business logic lives in pure functions; processes are optional.
- **Function clauses declare the machine** -- no redundant `states/0` callback.
- **Full gen_statem power** preserved in the Server; nothing amputated.
- **Small surface area**, full OTP composability, pipelines first.

## Architecture

### Layer 1: Pure Core (`Decidable` + `Decidable.Machine`)

100% usable without any process. The `%Decidable.Machine{}` struct carries:

- `module` -- the callback module
- `state` -- current state (any term, typically an atom)
- `data` -- arbitrary user data
- `pending_actions` -- actions from the last transition, stored as inert data
- `status` -- `:running` or `{:stopped, reason}`

Actions are **never executed** in the pure core. They are carried as data for
the caller or Server to interpret. Each `transition/2` call replaces (not
appends) `pending_actions`.

### Layer 2: Process Shell (`Decidable.Server`)

A thin `:gen_statem` adapter (NOT GenServer). Delegates all transition logic to
the pure callback module, then:

- Executes pending actions (timeouts, replies, postpone, etc.)
- Emits `[:decidable, :transition]` telemetry events
- Integrates with supervision trees, `:sys` debugging, hot code reloading

## Behaviour Callbacks

### Required

- `init(args)` -- returns `{:ok, state, data}` or `{:stop, reason}`
- `handle_event(state, event_type, event_content, data)` -- arity 4

### Optional

- `on_enter(old_state, new_state, data)` -- called after state changes

## Callback Signature

`handle_event/4` mirrors `:gen_statem` exactly:

```elixir
@callback handle_event(state, event_type, event_content, data)
```

The `event_type` argument is one of:

- `:internal` -- pure transitions via `Decidable.transition/2`, or `{:next_event, :internal, _}`
- `:cast` -- async events via `Decidable.Server.cast/2`
- `{:call, from}` -- sync events via `Decidable.Server.call/3`
- `:info` -- raw messages from linked processes
- `:timeout` -- event timeouts
- `:state_timeout` -- state timeouts
- `{:timeout, name}` -- named timeouts

In pure code, event_type is always `:internal`. Use `_` to ignore it when
the clause works in both contexts:

```elixir
# Works in both pure and Server
def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}

# Server-only: match on {:call, from} to reply
def handle_event(state, {:call, from}, :status, data) do
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

## Key Design Decisions

1. **No `states/0` callback** -- function clauses are the declaration
2. **State-first in `handle_event/4`** -- the primary discriminator
3. **Arity-4 with explicit event_type** -- matches gen_statem exactly, no hidden tagging
4. **`:internal` for pure transitions** -- honest about what a programmatic event is
5. **`on_enter/3` receives old_state** -- essential for cleanup and logging
6. **Actions are data** -- stored in `pending_actions`, never executed in pure core
7. **pending_actions replace, not accumulate** -- each transition starts fresh
8. **Bare `%Machine{}` returns** -- enables pipeline ergonomics without tuple unwrapping
9. **No catch-all defaults** -- unhandled events crash (FunctionClauseError)
10. **No `current_state/1`** -- use `:sys.get_state` for debugging
11. **Telemetry in Server only** -- pure core has zero side effects

## Server Event Type Passthrough

The Server passes gen_statem event types directly to `handle_event/4` with
no translation. The callback receives the exact same event_type that
`:gen_statem` provides:

| gen_statem event type | Callback receives |
|---|---|
| `:cast` | `handle_event(state, :cast, event, data)` |
| `{:call, from}` | `handle_event(state, {:call, from}, event, data)` |
| `:info` | `handle_event(state, :info, msg, data)` |
| `:timeout` | `handle_event(state, :timeout, content, data)` |
| `:state_timeout` | `handle_event(state, :state_timeout, content, data)` |
| `{:timeout, name}` | `handle_event(state, {:timeout, name}, content, data)` |
| `:internal` | `handle_event(state, :internal, event, data)` |
| `:enter` | `on_enter(old_state, new_state, data)` -- separate callback |

No translation, no tagging, no magic. The Server is a pass-through.
