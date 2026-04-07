# Crank -- Design Specification

## What Crank does

`Crank.crank(machine, event)` takes a struct and an event and returns a new struct. That pure function call is the entire core. `Crank.Server` wraps the same logic in a `gen_statem` process when timeouts, supervision, or telemetry are needed.

## Design principles

- **Explicit over implicit.** Every decision is visible in the code.
- **Behaviours and pattern matching.** No DSLs. A behaviour is an interface contract -- define the functions, the framework calls them. Pattern matching is how Elixir dispatches to the right function clause based on the shape of the arguments.
- **Pure core, effectful shell** (sometimes called functional core, imperative shell). Business logic lives in pure functions -- same input, same output, no side effects. Processes are optional.
- **Function clauses declare the machine.** No redundant `states/0` callback. The set of `handle/3` clauses IS the specification.
- **Full `gen_statem` power** preserved in the Server. Nothing amputated.
- **Small surface area.** The API is `new/2`, `crank/2`, and `crank!/2`. Pipelines work naturally because `crank/2` takes and returns the same struct.

## Two layers

### Layer 1: Pure core (`Crank` + `Crank.Machine`)

Works without any process. The `%Crank.Machine{}` struct carries five fields:

- `module` -- the callback module (so the struct knows which functions to call)
- `state` -- current state (any Elixir term -- atoms, structs, tagged tuples)
- `data` -- accumulated data shared across all states
- `effects` -- side effects from the last transition, stored as inert data
- `status` -- `:running` or `{:stopped, reason}`

Effects are never executed in the pure core. They're carried as data for the caller or Server to interpret.

Each `crank/2` call replaces effects. They don't accumulate.

### Layer 2: Process shell (`Crank.Server`)

A thin `gen_statem` adapter (not GenServer). It delegates all transition logic to the pure callback module, then handles what pure functions can't:

- Executes effects (timeouts, replies, postpone)
- Emits `[:crank, :transition]` telemetry events
- Integrates with supervision trees, `:sys` debugging, and hot code reloading

The internal `gen_statem` implementation lives in `Crank.Server.Adapter`.

## Callbacks

### Required

- `init(args)` -- Crank calls this once when the machine is created. Returns `{:ok, state, data}` or `{:stop, reason}`.
- `handle/3` or `handle_event/4` -- at least one must be implemented. Crank calls whichever exists every time an event arrives.

### Optional

- `on_enter(old_state, new_state, data)` -- Crank calls this after a state change. Receives the state the machine just left, the state it just entered, and the data.

## Callback signatures

### `handle/3`

The primary callback. Crank calls it with the event, the current state, and the accumulated data. It returns the next state:

```elixir
@callback handle(event, state, data)
```

This drops the `event_type` argument. In pure usage, event type is always `:internal`. In most process clauses, it's ignored. For the common case -- business logic that works in both pure and process contexts -- `handle/3` is all that's needed:

```elixir
def handle({:coin, amount}, :accepting, data) do
  {:next_state, :accepting, %{data | balance: data.balance + amount}}
end
```

### `handle_event/4`

The full `gen_statem` callback. Crank calls it with the event type, event content, state, and data:

```elixir
@callback handle_event(event_type, event_content, state, data)
```

The event type tells the function how the event was delivered:

- `:internal` -- pure cranks via `Crank.crank/2`, or `{:next_event, :internal, _}`
- `:cast` -- async events via `Crank.Server.cast/2`
- `{:call, from}` -- sync events via `Crank.Server.call/3` (caller is waiting for a reply)
- `:info` -- raw messages from other processes
- `:timeout` -- event timeouts
- `:state_timeout` -- state timeouts
- `{:timeout, name}` -- named timeouts

If a module exports `handle_event/4`, Crank uses it instead of `handle/3`. For modules that need both -- business logic in `handle/3`, replies in `handle_event/4` -- a catch-all delegates everything else:

```elixir
# Reply to synchronous callers
def handle_event({:call, from}, :status, state, data) do
  {:keep_state, data, [{:reply, from, state}]}
end

# Everything else delegates to handle/3
def handle_event(_, event, state, data), do: handle(event, state, data)
```

## Return values

Every `handle/3` (or `handle_event/4`) clause returns a tuple that tells Crank what to do next. These match `gen_statem`'s return values exactly:

- `{:next_state, new_state, new_data}` -- move to a different state
- `{:next_state, new_state, new_data, actions}` -- move and declare side effects
- `{:keep_state, new_data}` -- stay in the same state, update the data
- `{:keep_state, new_data, actions}` -- stay and declare side effects
- `:keep_state_and_data` -- nothing changes
- `{:keep_state_and_data, actions}` -- nothing changes but declare side effects
- `{:stop, reason, new_data}` -- shut down the machine

Invalid returns raise `ArgumentError` with a message identifying the callback module and state.

## Design decisions and rationale

1. **No `states/0` callback.** Function clauses are the declaration. A separate `states/0` list would duplicate what the clauses already express and inevitably drift.
2. **`handle/3` as primary callback.** Drops event_type, which is noise in the common case. One less argument to pattern match through.
3. **`handle_event/4` for full `gen_statem` power.** Same arguments, same order as `gen_statem`'s `handle_event_function` mode. No translation layer.
4. **`handle_event/4` takes precedence.** If both callbacks exist, `handle_event/4` wins. No ambiguity, no merge.
5. **`:internal` for pure cranks.** Honest about what a programmatic event is.
6. **`on_enter/3` receives `old_state`.** Essential for cleanup and transition logging.
7. **Effects are data.** Stored in `effects`, never executed in the pure core. This makes testing deterministic.
8. **Effects replace, not accumulate.** Each crank starts fresh. No hidden effect history.
9. **Bare `%Machine{}` returns.** Enables pipeline ergonomics without tuple unwrapping.
10. **No catch-all defaults.** Unhandled events crash with `FunctionClauseError`. Silent ignoring hides bugs.
11. **No `current_state/1`.** Use `:sys.get_state` for debugging. No extra API surface.
12. **Telemetry in Server only.** Pure core has zero side effects, by definition.
13. **Module validation at init.** `Crank.new/2` and `Crank.Server.Adapter.init/1` verify the module implements `handle/3` or `handle_event/4` before anything runs.

## How the Server passes event types

The Server passes `gen_statem` event types straight to the callback module. No translation, no tagging.

If the module exports `handle_event/4`, it receives event types directly. If the module only exports `handle/3`, event types are dropped -- the event content, state, and data are passed through:

| `gen_statem` event type | `handle_event/4` receives | `handle/3` receives |
|---|---|---|
| `:cast` | `handle_event(:cast, event, state, data)` | `handle(event, state, data)` |
| `{:call, from}` | `handle_event({:call, from}, event, state, data)` | `handle(event, state, data)` |
| `:info` | `handle_event(:info, msg, state, data)` | `handle(msg, state, data)` |
| `:timeout` | `handle_event(:timeout, content, state, data)` | `handle(content, state, data)` |
| `:state_timeout` | `handle_event(:state_timeout, content, state, data)` | `handle(content, state, data)` |
| `{:timeout, name}` | `handle_event({:timeout, name}, content, state, data)` | `handle(content, state, data)` |
| `:internal` | `handle_event(:internal, event, state, data)` | `handle(event, state, data)` |
| `:enter` | `on_enter(old_state, new_state, data)` | `on_enter(old_state, new_state, data)` |

The Server is a pass-through.

## Struct-per-state

This pattern originates from Scott Wlaschin's "Making Illegal States Unrepresentable." Each state is its own struct, so a `%Dispensing{}` can't have a `change` field -- the struct doesn't define one, and the compiler rejects it. Crank supports this without any core changes because `Machine.state` is `term()` -- atoms, structs, tagged tuples all work.

### How it works

Each state is its own struct. The struct defines exactly what data exists in that state. No optional fields, no "only set when state is X" comments:

```elixir
defmodule Idle,         do: defstruct []
defmodule Accepting,    do: defstruct [:balance]
defmodule Dispensing,   do: defstruct [:balance, :selection]
defmodule MakingChange, do: defstruct [:change]
defmodule OutOfStock,   do: defstruct []
```

A `%Dispensing{}` can't have a `change` field. An `%Idle{}` can't have a `balance`. The struct enforces it.

### State/data split

State structs carry state-specific data. The `data` map carries cross-cutting concerns shared across all states:

```elixir
def init(opts) do
  {:ok, %Idle{}, %{price: opts[:price] || 100, stock: 10, audit: []}}
end
```

This maps cleanly to `gen_statem`'s `(state, data)` separation.

### Within-type mutations

Elixir structs are immutable. `%Accepting{balance: 25}` and `%Accepting{balance: 50}` are two different values. That's a state change -- use `{:next_state, ...}`:

```elixir
def handle({:coin, amount}, %Accepting{balance: bal} = s, data) do
  {:next_state, %Accepting{s | balance: bal + amount}, data}
end
```

`:keep_state` means the state is literally the same value -- only `data` changed. This matters because `{:next_state, ...}` triggers `on_enter/3` and `:keep_state` does not.

## Compiler-checked exhaustiveness (future)

Elixir's set-theoretic type system (introduced in v1.17, with type inference expanding through 2026) lets the compiler reason about union types and warn when a function doesn't handle all variants:

```elixir
@type state ::
  Idle.t() | Accepting.t() | Dispensing.t() | MakingChange.t() | OutOfStock.t()
```

When the compiler can check this, unhandled state variants will produce warnings with zero code changes. The Submission example in `Crank.Examples` is designed to be ready for this.
