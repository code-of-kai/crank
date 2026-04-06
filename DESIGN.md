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
- `handle/3` or `handle_event/4` -- at least one must be implemented

### Optional

- `handle/3` -- simplified callback: `handle(event, state, data)`
- `handle_event/4` -- full gen_statem callback: `handle_event(event_type, event_content, state, data)`
- `on_enter(old_state, new_state, data)` -- called after state changes

## Callback Signature

The primary callback is `handle/3` -- event, state, data:

```elixir
@callback handle(event, state, data)
```

This drops the `event_type` argument, which is `:internal` in pure usage and
ignored in most process clauses. For the common case -- business logic that
works in both pure and process contexts -- `handle/3` is all you need:

```elixir
def handle({:coin, amount}, :accepting, data) do
  {:next_state, :accepting, %{data | balance: data.balance + amount}}
end
```

When you need event types (replies, timeouts, process messages), use
`handle_event/4` -- it mirrors `:gen_statem`'s `handle_event_function` mode
exactly, same arguments, same order:

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

If a module exports `handle_event/4`, it takes precedence. For mixed usage,
add a catch-all delegation:

```elixir
# Server-only: match on {:call, from} to reply
def handle_event({:call, from}, :status, state, data) do
  {:keep_state, data, [{:reply, from, state}]}
end

# Everything else delegates to handle/3
def handle_event(_, event, state, data), do: handle(event, state, data)
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
2. **`handle/3` as primary callback** -- drops event_type, which is noise in the common case
3. **`handle_event/4` for full gen_statem power** -- same arguments, same order as gen_statem's `handle_event_function` mode
4. **`handle_event/4` takes precedence** -- if both callbacks exist, handle_event/4 wins; no ambiguity
5. **`:internal` for pure cranks** -- honest about what a programmatic event is
6. **`on_enter/3` receives old_state** -- essential for cleanup and logging
7. **Effects are data** -- stored in `effects`, never executed in pure core
8. **Effects replace, not accumulate** -- each crank starts fresh
9. **Bare `%Machine{}` returns** -- enables pipeline ergonomics without tuple unwrapping
10. **No catch-all defaults** -- unhandled events crash (FunctionClauseError)
11. **No `current_state/1`** -- use `:sys.get_state` for debugging
12. **Telemetry in Server only** -- pure core has zero side effects
13. **Module validation at init** -- `Crank.new/2` and `Crank.Server.Adapter.init/1` verify the module implements `handle/3` or `handle_event/4`

## Server Event Type Passthrough

The Server passes gen_statem event types to the callback module. If the module
exports `handle_event/4`, it receives event types directly. If the module only
exports `handle/3`, event types are dropped -- the event content, state, and
data are passed through:

| gen_statem event type | `handle_event/4` receives | `handle/3` receives |
|---|---|---|
| `:cast` | `handle_event(:cast, event, state, data)` | `handle(event, state, data)` |
| `{:call, from}` | `handle_event({:call, from}, event, state, data)` | `handle(event, state, data)` |
| `:info` | `handle_event(:info, msg, state, data)` | `handle(msg, state, data)` |
| `:timeout` | `handle_event(:timeout, content, state, data)` | `handle(content, state, data)` |
| `:state_timeout` | `handle_event(:state_timeout, content, state, data)` | `handle(content, state, data)` |
| `{:timeout, name}` | `handle_event({:timeout, name}, content, state, data)` | `handle(content, state, data)` |
| `:internal` | `handle_event(:internal, event, state, data)` | `handle(event, state, data)` |
| `:enter` | `on_enter(old_state, new_state, data)` | `on_enter(old_state, new_state, data)` |

No translation, no tagging, no magic. The Server is a pass-through.

## Struct-Per-State (Wlaschin Pattern)

Crank supports Scott Wlaschin's "Making Illegal States Unrepresentable" pattern
without any core changes. `Machine.state` is `term()` — atoms, structs, tagged
tuples all work.

### How It Works

Each state is its own struct. The struct defines exactly what data exists
in that state — no optional fields, no "only set when state is X" comments:

```elixir
defmodule Idle,         do: defstruct []
defmodule Accepting,    do: defstruct [:balance]
defmodule Dispensing,   do: defstruct [:balance, :selection]
defmodule MakingChange, do: defstruct [:change]
defmodule OutOfStock,   do: defstruct []
```

A `%Dispensing{}` can't have a `change` field. An `%Idle{}` can't have a
`balance`. The struct enforces it.

### State/Data Split

State structs carry state-specific data. The `data` map carries cross-cutting
concerns shared across all states:

```elixir
def init(opts) do
  {:ok, %Idle{}, %{price: opts[:price] || 100, stock: 10, audit: []}}
end
```

This maps cleanly to gen_statem's `(state, data)` separation.

### Within-Type Mutations

When a field on the current state struct changes (e.g., accumulating balance),
use `{:next_state, ...}` — the state value changed:

```elixir
def handle({:coin, amount}, %Accepting{balance: bal} = s, data) do
  {:next_state, %Accepting{s | balance: bal + amount}, data}
end
```

`:keep_state` is reserved for changes to `data` only. This triggers `on_enter`,
which is correct — the state did change.

### Set-Theoretic Types (Future)

Elixir's set-theoretic type system (v1.17+ with inference expanding through 2026)
will make the compiler verify exhaustiveness:

```elixir
@type state ::
  Idle.t() | Accepting.t() | Dispensing.t() | MakingChange.t() | OutOfStock.t()
```

The compiler will warn if `handle/3` doesn't cover all variants.
The Submission example in `Crank.Examples` is designed to be ready for this.
