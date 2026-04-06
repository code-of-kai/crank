<p align="center">
  <img src="assets/logo.jpg" alt="Crank" width="200">
</p>

# Crank

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Write your state machine logic once. Test it with property tests -- millions of random event sequences, no processes, no setup. Run the exact same code in production as a supervised `gen_statem` process. There's nothing to switch between pure and process -- the callback module is always both.

```
Write logic ──→ Test pure ──→ Deploy as process
                    ↑                │
                    └─ Change logic ←─┘
```

```elixir
# Pure -- in your tests, LiveView, Oban workers, scripts
machine = Crank.new(MyApp.VendingMachine) |> Crank.crank(:insert) |> Crank.crank(:select)

# Process -- in production, with supervision, timeouts, and telemetry
{:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, [])
Crank.Server.cast(pid, :insert)
```

Same callback module. Same logic. Two callers.

## How state machines evolved in Erlang and Elixir

**Plain Erlang (1980s--1990s).** Before OTP existed, Erlang state machines were mutually recursive functions. Each state was a function. The process sat inside that function, waiting for a message. When it transitioned, it tail-called into the next state's function:

```erlang
locked(Event, Data) ->
    case Event of
        unlock -> unlocked(Data);
        _      -> locked(Data)
    end.

unlocked(Event, Data) ->
    case Event of
        lock -> locked(Data);
        open -> opened(Data)
    end.
```

The state was which function the process was executing. The data available in each state was whatever that function received as arguments -- nothing more. You couldn't accidentally read `policy` inside `locked/2` because `locked/2` was never given a policy. The call stack scoped your data. And the logic was just functions -- you could call them directly without a process.

**`gen_fsm` (OTP, late 1990s).** OTP formalized the pattern into a behaviour. Each state was still a callback function -- `locked/2`, `unlocked/2` -- and the framework dispatched to the right one. This preserved the function-per-state model but coupled it to a process. You couldn't use the logic without starting a `gen_fsm`. The state machine was now inseparable from the process running it.

**`gen_statem` (OTP 19, 2016).** Replaced `gen_fsm` entirely. Added two callback modes: `state_functions` (same as `gen_fsm` -- each state is a function name, state must be an atom) and `handle_event_function` (one function, state is a parameter, state can be any term). The second mode was more flexible but moved further from function-per-state -- you're now inside one function with access to everything, regardless of which state you're in. Still coupled to a process.

**Elixir and GenServer (2012--present).** Most Elixir developers never touched `gen_statem`. They came from Ruby and JavaScript, not Erlang. GenServer became the primary OTP abstraction, and GenServer has no concept of states at all -- just `handle_call`, `handle_cast`, `handle_info` with one blob of data. If you needed a state machine, you put a `:status` atom in that blob and pattern-matched on it. The function-per-state idea didn't carry over from Erlang. It was left behind.

Two things changed in this progression:

1. **Data scoping disappeared.** In `locked/2`, you could only see what `locked/2` was given. In a GenServer with `%{status: :vending, balance: 100, selection: nil, error: nil, ...}`, every handler can see every field. Nothing stops you from reading `error` when the status is `:vending`.

2. **State machine logic became inseparable from processes.** In the original Erlang model, state machine logic was just functions calling functions. `gen_fsm` (1990s) coupled it to a process. `gen_statem` (2016) continued that coupling. GenServer dropped the state machine primitives entirely. Each step moved further from state machine logic you could call directly.

## What Crank recovers

Crank separates the two concerns that OTP fused together in `gen_fsm`: state machine logic and process lifecycle.

The pure core (`Crank.crank/2`) is a function that takes a machine and an event and returns a new machine. No process, no mailbox, no side effects. The process shell (`Crank.Server`) wraps the same callback module in `gen_statem` when you need timeouts, supervision, and telemetry. Same logic, both modes. Write it once, test it pure, run it in production as a process.

For data scoping, Crank supports struct-per-state -- each state is its own struct with exactly the fields that exist in that state (see [Struct states](#struct-states) below). A `%Vending{}` can't have a `receipt` field because the field doesn't exist on that struct. This recovers the guarantee that Erlang's function-per-state model provided, but as portable data instead of a running process.

## Why not just use gen_statem?

You can. Crank's `handle_event/4` callback is `:gen_statem`'s `handle_event_function` mode verbatim, and the Server is a ~100-line pass-through. If your machine will always live in a process, gen_statem alone is fine.

Crank exists for the cases where that's not enough:

**Property testing.** Crank's test suite runs 26 properties at 10,000 iterations each -- roughly 100 million random cranks in ~20 seconds. That's feasible because `crank/2` returns a struct. No `start_link`/`stop` per iteration, no `:sys.get_state`, no process lifecycle noise. Pure functions compose with StreamData trivially; processes don't.

**Non-process hosts.** LiveView reducers, Oban workers, Phoenix.Channel assigns, ETS-backed workflows -- these are real contexts where you need FSM logic but spawning a gen_statem would be architecturally wrong. With Crank, the same callback module works in both contexts without adaptation.

**Effect inspection.** When a callback returns `[{:state_timeout, 10_000, :vend_timeout}]`, pure code stores it in `machine.effects` as inert data. You can assert on exactly what effects a transition *would* produce without executing them. gen_statem executes effects immediately -- there's no way to inspect intent separately from execution.

**When Crank probably isn't worth it:** If your machine is always supervised, never tested with random sequences, and you don't need the logic outside a process, the pure layer is overhead. Use gen_statem directly.

## How it works

You write one callback module. That module is always both pure and process-ready -- there's nothing to switch on or off. `Crank.crank/2` calls your callback directly as a pure function. `Crank.Server` calls the same callback through `:gen_statem`. Same function, two callers.

| | Pure | Process |
|---|---|---|
| **API** | `Crank.new/2` + `Crank.crank/2` | `Crank.Server.start_link/3` |
| **What you get** | A plain `%Crank.Machine{}` struct | A supervised `:gen_statem` process |
| **Side effects** | None -- effects stored as inert data | Executed by `:gen_statem` |
| **Telemetry** | None | `[:crank, :transition]` on every state change |
| **Good for** | Tests, LiveView reducers, Oban workers, scripts | Production supervision, timeouts, replies |

This means your development workflow is: write the logic, test it purely with property tests (thousands or millions of random event sequences), and deploy it as a supervised process. When you need to change a state or add a transition, you change the callback module and run the property tests again. If they pass, the process version works too -- because it's the same code. The only difference between pure and process is who calls your function and what happens to the effects afterward.

## Quick start

Define a state machine by implementing the `Crank` behaviour:

```elixir
defmodule MyApp.VendingMachine do
  use Crank

  @impl true
  def init(_opts), do: {:ok, :idle, %{balance: 0}}

  @impl true
  def handle(:insert, :idle, data) do
    {:next_state, :ready, %{data | balance: data.balance + 100}}
  end

  def handle(:select, :ready, data), do: {:next_state, :vending, data}
  def handle(:dispense, :vending, data), do: {:next_state, :idle, %{data | balance: 0}}
  def handle(:refund, :ready, data), do: {:stop, :refunded, %{data | balance: 0}}
end
```

### Pure usage

No process, no setup, no cleanup:

```elixir
machine =
  MyApp.VendingMachine
  |> Crank.new()
  |> Crank.crank(:insert)
  |> Crank.crank(:select)

machine.state   #=> :vending
machine.effects #=> []
```

### Process usage

Full OTP supervision and `:gen_statem` power:

```elixir
{:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, [])
Crank.Server.cast(pid, :insert)
Crank.Server.call(pid, :status)  # when you have a {:call, from} clause
```

### Callback signature

The primary callback is `handle/3` -- event, state, data:

```elixir
def handle(event, state, data)
```

| Argument | Description |
|---|---|
| `event` | The event payload |
| `state` | Current state |
| `data` | Accumulated machine data |

```elixir
def handle(:insert, :idle, data) do
  {:next_state, :ready, %{data | balance: data.balance + 100}}
end
```

When you need the event type (replies, timeouts, process messages), use `handle_event/4` -- it matches `:gen_statem`'s `handle_event_function` callback mode exactly:

```elixir
def handle_event(event_type, event_content, state, data)
```

| `event_type` | `:internal`, `:cast`, `{:call, from}`, `:info`, `:timeout`, `:state_timeout`, `{:timeout, name}` |
|---|---|

If a module exports `handle_event/4`, it takes precedence. For mixed usage, add a catch-all delegation:

```elixir
# Server-only: reply to synchronous calls
def handle_event({:call, from}, :status, state, data) do
  {:keep_state, data, [{:reply, from, state}]}
end

# Everything else delegates to handle/3
def handle_event(_, event, state, data), do: handle(event, state, data)
```

### Return values

All `:gen_statem` return values are supported:

- `{:next_state, new_state, new_data}`
- `{:next_state, new_state, new_data, actions}`
- `{:keep_state, new_data}`
- `{:keep_state, new_data, actions}`
- `:keep_state_and_data`
- `{:keep_state_and_data, actions}`
- `{:stop, reason, new_data}`

### Effects as data

When a callback returns actions (timeouts, replies, postpone, etc.), the pure core stores them in `machine.effects` as inert data. It never executes them. The Server executes them via `:gen_statem`.

```elixir
def handle(:select, :ready, data) do
  {:next_state, :vending, data, [{:state_timeout, 10_000, :vend_timeout}]}
end
```

```elixir
machine = Crank.crank(machine, :select)
machine.effects
#=> [{:state_timeout, 10_000, :vend_timeout}]
```

Each `crank/2` call replaces `effects` -- they don't accumulate across pipeline stages.

### Enter callbacks

Optional `on_enter/3` fires after state changes:

```elixir
@impl true
def on_enter(_old_state, _new_state, data) do
  {:keep_state, Map.put(data, :transitioned_at, System.monotonic_time())}
end
```

### Stopped machines

`{:stop, reason, data}` sets `machine.status` to `{:stopped, reason}`. Further cranks raise `Crank.StoppedError`. Use `crank!/2` in tests to raise immediately on stop results.

### Unhandled events

No catch-all. Unhandled events crash with `FunctionClauseError`. This is deliberate -- a state machine that silently ignores events is hiding bugs. Let it crash; let the supervisor handle it.

## Telemetry

`Crank.Server` emits a `[:crank, :transition]` event on every state change with the following metadata:

```elixir
%{
  module: MyApp.VendingMachine,
  from: :idle,         # nil on initial enter
  to: :ready,
  event: :insert,      # nil on enter
  data: %{balance: 100}
}
```

Attach handlers for persistence, notifications, audit logging, PubSub -- see the [Hexagonal Architecture guide](guides/hexagonal-architecture.md) for patterns.

## Struct states

The standard Elixir approach is one struct with a `:status` atom and every field present in every state:

```elixir
%VendingMachine{status: :vending, balance: 100, selection: "A3", dispensed_at: nil, error: nil}
# dispensed_at shouldn't be here. error shouldn't be here.
# But nothing stops it. You have to know which fields matter.
```

Crank supports an alternative: each state is its own struct. The struct defines exactly what data exists in that state. No optional fields, no "only set when the state is X" comments:

```elixir
defmodule Idle,      do: defstruct []
defmodule Ready,     do: defstruct [:balance]
defmodule Vending,   do: defstruct [:balance, :selection]
defmodule Dispensed, do: defstruct [:receipt]
```

This works today because `Crank.Machine.state` is `term()` -- atoms, structs, tagged tuples all work. Pattern matching on the struct type gives you the state and its data in one destructure:

```elixir
def handle(:select, %Ready{balance: bal}, data) when bal >= 100 do
  {:next_state, %Vending{balance: bal, selection: data.selection}, data}
end
```

State-specific data lives in the struct. Cross-cutting concerns (machine location, audit logs) live in `data`. When a field changes on the current state struct, use `{:next_state, %SameType{updated}, data}` -- the state value changed, so it's a transition. `:keep_state` is reserved for `data`-only changes.

The type annotations are written for Elixir's set-theoretic type system:

```elixir
@type state :: Idle.t() | Ready.t() | Vending.t() | Dispensed.t()
```

When the compiler can check this (expected mid-2026+), unhandled state variants will produce compiler warnings with zero code changes. Until then, property tests enforce the same guarantee dynamically -- see `Crank.Examples.Submission` for the full example.

## Design principles

- **Pure core, effectful shell.** Business logic is pure data transformation. Side effects live at the boundary.
- **No magic.** Crank passes `:gen_statem` types and return values through unchanged. If you know `:gen_statem`, you know Crank.
- **No hidden state.** No `states/0` callback, no registered names, no catch-all defaults. Function clauses declare the machine.
- **Let it crash.** Unhandled events are bugs. Crank surfaces them immediately.
- **~400 lines.** Small enough to read in one sitting. No framework, just a library.

See [DESIGN.md](DESIGN.md) for the full specification and rationale behind every decision.

## Installation

```elixir
def deps do
  [
    {:crank, "~> 0.1.0"}
  ]
end
```

## Documentation

- [DESIGN.md](DESIGN.md) -- Full specification and design rationale
- [Hexagonal Architecture guide](guides/hexagonal-architecture.md) -- Integration patterns for persistence, notifications, and audit logging
- [CHANGELOG.md](CHANGELOG.md) -- Version history

## License

MIT
