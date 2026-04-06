<p align="center">
  <img src="assets/logo.jpg" alt="Crank" width="200">
</p>

# Crank

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A state machine that starts simpler than GenServer and scales to full OTP supervision without changing a line of logic.

`Crank.crank(machine, event)` is a pure function call. No process. No mailbox. No `start_link`. When you need timeouts and supervision, promote to `Crank.Server` -- same callback module, same logic, now running as a supervised `gen_statem`. The promotion is a deployment decision, not a rewrite.

```
Write logic ──→ Test pure ──→ Deploy as process
                    ↑                │
                    └─ Change logic ←─┘
```

```elixir
# Pure -- in your tests, LiveView, Oban workers, scripts
machine = Crank.new(MyApp.VendingMachine) |> Crank.crank({:coin, 25}) |> Crank.crank({:select, "A3"})

# Process -- in production, with supervision, timeouts, and telemetry
{:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, [])
Crank.Server.cast(pid, {:coin, 25})
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

1. **Data scoping disappeared.** In `locked/2`, you could only see what `locked/2` was given. In a GenServer with `%{status: :dispensing, balance: 100, selection: nil, change: nil, ...}`, every handler can see every field. Nothing stops you from reading `change` when the status is `:dispensing`.

2. **State machine logic became inseparable from processes.** In the original Erlang model, state machine logic was just functions calling functions. `gen_fsm` (1990s) coupled it to a process. `gen_statem` (2016) continued that coupling. GenServer dropped the state machine primitives entirely. Each step moved further from state machine logic you could call directly.

## What Crank recovers

Crank separates the two concerns that OTP fused together in `gen_fsm`: state machine logic and process lifecycle.

The pure core (`Crank.crank/2`) is a function that takes a machine and an event and returns a new machine. No process, no mailbox, no side effects. The process shell (`Crank.Server`) wraps the same callback module in `gen_statem` when you need timeouts, supervision, and telemetry. Same logic, both modes. Write it once, test it pure, run it in production as a process.

For data scoping, Crank supports struct-per-state -- each state is its own struct with exactly the fields that exist in that state (see [Struct states](#struct-states) below). A `%Dispensing{}` can't have a `change` field because the field doesn't exist on that struct. This is domain modeling where the types enforce the invariants -- making illegal states unrepresentable. It recovers the guarantee that Erlang's function-per-state model provided, but as portable data instead of a running process.

## Why not just use GenServer?

José Valim's consistent advice is: start simple, promote to complex when you need it. GenServer before `gen_statem`. Plain functions before GenServer. Reach for the simpler tool first.

Crank's pure mode is simpler than GenServer. `Crank.crank(machine, event)` is a function call that returns a struct. No `start_link`. No mailbox. No supervision tree. No process lifecycle. It's the simplest tool in the progression:

```
Pure function (Crank.crank/2) → GenServer → gen_statem (Crank.Server)
       simplest                                     most powerful
```

Valim says start simple. Crank's starting point is simpler than what he recommends. And the promotion path is built in: start with `Crank.crank/2` (pure, no process), promote to `Crank.Server` (supervised `gen_statem`) when you need timeouts, supervision, or replies. The promotion is a deployment decision, not a rewrite. Same callback module, same logic, different caller.

Most Elixir developers use GenServer with a `%{status: :accepting}` field and pattern match on it in their `handle_call` and `handle_cast` clauses. That IS a state machine -- it's just not a formal one.

The Elixir ecosystem has spent a decade building out its infrastructure layer: Ecto for persistence, Phoenix for web, Oban for background jobs, Broadway for data pipelines, Bandit for HTTP. Caches, connection pools, pubsub brokers, HTTP clients -- all built, all mature, all excellent. That infrastructure exists to support one thing: your domain. As the infrastructure layer matures and gets solved, what remains is the domain model and its business logic. And a domain model IS states and transitions.

A customer is in a state: prospect, active, churning, dormant. A submission is in a state: received, validating, eligible, declined. A policy is in a state: quoted, bound, active, lapsed, renewed. Business rules ARE transition rules: "you can't bind without quoting first," "when the underwriter approves, move from review to eligible." The states are the domain model. The transitions are the business logic. Together, they're a state machine.

Every business rule is: given this state and this event, what happens next? That's the definition of a finite state machine. The question was never whether your domain has a state machine in it. It always does. The question is whether you make it explicit or implicit.

A GenServer with scattered pattern matches across `handle_call` clauses is a domain model that hides itself. A Crank callback module where each `handle/3` clause declares a state, an event, and a transition is a domain model that's honest about what it is. Both are state machines. One is readable.

The reason people hid their domain models inside GenServers was cost. `gen_statem` added ceremony -- callback modes, process coupling, untestable runtime integration. Crank eliminates that cost. A `handle/3` clause is no more complex than a `handle_call` with pattern matching on `state.status`. Explicit is now as cheap as implicit, so there's no reason to pretend your domain isn't a state machine.

### When you need the process

Crank.Server adds what pure functions can't provide:

**State-dependent timeouts.** "If we're in `:dispensing`, fire a jam timeout after 5 seconds. If we're in `:accepting`, fire an inactivity timeout after 60 seconds." GenServer has one timeout mechanism. `gen_statem` has per-state timeouts.

**State enter callbacks.** "Every time we enter `:dispensing`, emit telemetry and log it." GenServer doesn't have enter callbacks. You can simulate them, but it's manual and error-prone.

**Effect inspection.** When a callback returns `[{:state_timeout, 5_000, :jam_timeout}]`, pure code stores it in `machine.effects` as inert data. You can assert on exactly what effects a transition *would* produce without executing them. `gen_statem` executes effects immediately -- there's no way to inspect intent separately from execution.

**Pure testing at scale.** Crank's test suite runs 26 properties at 10,000 iterations each -- roughly 100 million random event sequences in ~20 seconds. No `start_link`/`stop` per iteration. Pure functions compose with StreamData trivially; processes don't.

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
  def init(opts), do: {:ok, :idle, %{price: opts[:price] || 100, balance: 0, stock: 10}}

  @impl true
  def handle({:coin, amount}, :idle, data) do
    {:next_state, :accepting, %{data | balance: amount}}
  end

  def handle({:coin, amount}, :accepting, data) do
    {:next_state, :accepting, %{data | balance: data.balance + amount}}
  end

  def handle({:select, _item}, :accepting, %{balance: bal, price: price} = data)
      when bal >= price do
    {:next_state, :dispensing, data, [{:state_timeout, 5_000, :jam_timeout}]}
  end

  def handle(:dispensed, :dispensing, %{balance: bal, price: price} = data) do
    remaining = data.stock - 1
    change = bal - price

    cond do
      change > 0 ->
        {:next_state, :making_change, %{data | stock: remaining, balance: change}}
      remaining == 0 ->
        {:next_state, :out_of_stock, %{data | stock: 0, balance: 0}}
      true ->
        {:next_state, :idle, %{data | stock: remaining, balance: 0}}
    end
  end

  def handle(:change_returned, :making_change, data) do
    if data.stock == 0 do
      {:next_state, :out_of_stock, %{data | balance: 0}}
    else
      {:next_state, :idle, %{data | balance: 0}}
    end
  end

  def handle(:restock, :out_of_stock, data) do
    {:next_state, :idle, %{data | stock: 10}}
  end

  def handle(:cancel, :accepting, data) do
    {:next_state, :making_change, data}
  end
end
```

### Pure usage

No process, no setup, no cleanup:

```elixir
machine =
  MyApp.VendingMachine
  |> Crank.new(price: 75)
  |> Crank.crank({:coin, 25})
  |> Crank.crank({:coin, 50})
  |> Crank.crank({:select, "A3"})

machine.state   #=> :dispensing
machine.effects #=> [{:state_timeout, 5_000, :jam_timeout}]
```

### Process usage

Full OTP supervision and `:gen_statem` power:

```elixir
{:ok, pid} = Crank.Server.start_link(MyApp.VendingMachine, price: 75)
Crank.Server.cast(pid, {:coin, 25})
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
def handle({:coin, amount}, :accepting, data) do
  {:next_state, :accepting, %{data | balance: data.balance + amount}}
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
def handle({:select, _item}, :accepting, %{balance: bal, price: price} = data)
    when bal >= price do
  {:next_state, :dispensing, data, [{:state_timeout, 5_000, :jam_timeout}]}
end
```

```elixir
machine = Crank.crank(machine, {:select, "A3"})
machine.effects
#=> [{:state_timeout, 5_000, :jam_timeout}]
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
  from: :idle,             # nil on initial enter
  to: :accepting,
  event: {:coin, 25},      # nil on enter
  data: %{price: 75, balance: 25, stock: 10}
}
```

Attach handlers for persistence, notifications, audit logging, PubSub -- see the [Hexagonal Architecture guide](guides/hexagonal-architecture.md) for patterns.

## Struct states

Domain-driven design says: make illegal states unrepresentable. The standard Elixir approach does the opposite -- one struct with a `:status` atom and every field present in every state:

```elixir
%VendingMachine{status: :dispensing, balance: 100, selection: "A3", change: nil, error: nil}
# change shouldn't be here. error shouldn't be here.
# But nothing stops it. You have to know which fields matter.
```

This is an anemic domain model. The shape doesn't encode the rules. Any field is accessible in any state, and nothing in the type system prevents you from reading `change` during `:dispensing` or setting `error` during `:idle`.

Crank supports an alternative: each state is its own struct. The struct defines exactly what data exists in that state. No optional fields, no "only set when the state is X" comments:

```elixir
defmodule Idle,         do: defstruct []
defmodule Accepting,    do: defstruct [:balance]
defmodule Dispensing,   do: defstruct [:balance, :selection]
defmodule MakingChange, do: defstruct [:change]
defmodule OutOfStock,   do: defstruct []
```

This works today because `Crank.Machine.state` is `term()` -- atoms, structs, tagged tuples all work. Pattern matching on the struct type gives you the state and its data in one destructure:

```elixir
def handle({:select, item}, %Accepting{balance: bal}, data) when bal >= data.price do
  {:next_state, %Dispensing{balance: bal, selection: item}, data}
end
```

State-specific data lives in the struct. Cross-cutting concerns (price, stock count, machine location) live in `data`. When a field changes on the current state struct, use `{:next_state, %SameType{updated}, data}` -- the state value changed, so it's a transition. `:keep_state` is reserved for `data`-only changes.

The type annotations are written for Elixir's set-theoretic type system:

```elixir
@type state :: Idle.t() | Accepting.t() | Dispensing.t() | MakingChange.t() | OutOfStock.t()
```

When the compiler can check this (expected mid-2026+), unhandled state variants will produce compiler warnings with zero code changes. Until then, property tests enforce the same guarantee dynamically -- see `Crank.Examples.Submission` for the full example.

## Design principles

- **Pure core, effectful shell.** Domain logic is pure data transformation. Side effects live at the boundary. This is [hexagonal architecture](guides/hexagonal-architecture.md) by construction, not by convention.
- **No magic.** Crank passes `:gen_statem` types and return values through unchanged. If you know `:gen_statem`, you know Crank.
- **No hidden state.** No `states/0` callback, no registered names, no catch-all defaults. Function clauses declare the machine.
- **Let it crash.** Unhandled events are bugs. Crank surfaces them immediately.
- **Auditable.** ~400 lines. You can read every line of Crank in one sitting and verify exactly what it does. No framework, just a library.

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
