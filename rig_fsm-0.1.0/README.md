# Rig

Pure state machines for Elixir. Testable data structures first, optional `gen_statem` process adapter.

## The idea

Most Elixir state machine libraries force you into a process. Rig doesn't. You write one module with `handle_event/4`, and it works in two contexts:

1. **Pure** -- `Rig.new/2` and `Rig.crank/2` return a plain struct. No process, no side effects, no telemetry. Use it in tests, LiveView reducers, Oban workers, scripts.

2. **Process** -- `Rig.Server` wraps the same module in `:gen_statem`. Supervision, telemetry, timeouts, replies -- the full OTP toolkit.

## Quick start

```elixir
defmodule MyApp.Door do
  use Rig

  @impl true
  def init(_opts), do: {:ok, :locked, %{}}

  @impl true
  def handle_event(:locked, _, :unlock, data), do: {:next_state, :unlocked, data}
  def handle_event(:unlocked, _, :lock, data), do: {:next_state, :locked, data}
  def handle_event(:unlocked, _, :open, data), do: {:next_state, :opened, data}
  def handle_event(:opened, _, :close, data), do: {:next_state, :unlocked, data}
end
```

### Pure usage

```elixir
machine =
  MyApp.Door
  |> Rig.new()
  |> Rig.crank(:unlock)
  |> Rig.crank(:open)

machine.state
#=> :opened

machine.effects
#=> []
```

### Process usage

```elixir
{:ok, pid} = Rig.Server.start_link(MyApp.Door, [])
Rig.Server.cast(pid, :unlock)
```

## Callback signature

`handle_event/4` matches `:gen_statem` exactly:

```elixir
def handle_event(state, event_type, event_content, data)
```

- `state` -- current state, the primary pattern match target
- `event_type` -- `:internal`, `:cast`, `{:call, from}`, `:info`, `:timeout`, `:state_timeout`, `{:timeout, name}`
- `event_content` -- the event payload
- `data` -- accumulated machine data

In pure code, event_type is always `:internal`. Use `_` to write clauses that work in both contexts:

```elixir
# Works everywhere
def handle_event(:idle, _, :activate, data), do: {:next_state, :active, data}

# Server-only: reply to synchronous calls
def handle_event(state, {:call, from}, :status, data) do
  {:keep_state, data, [{:reply, from, state}]}
end

# Server-only: handle timeouts
def handle_event(:waiting, :state_timeout, :expired, data) do
  {:next_state, :timed_out, data}
end
```

## Effects as data

When a callback returns actions (timeouts, replies, postpone, etc.), the pure core stores them in `machine.effects` as inert data. It never executes them. The Server executes them via `:gen_statem`.

```elixir
def handle_event(:paid, _, :ship, data) do
  {:next_state, :shipped, data, [{:state_timeout, 86_400_000, :delivery_timeout}]}
end
```

```elixir
machine = Rig.crank(machine, :ship)
machine.effects
#=> [{:state_timeout, 86_400_000, :delivery_timeout}]
```

Each `crank/2` call replaces `effects` -- they don't accumulate across pipeline stages.

## Enter callbacks

Optional `on_enter/3` fires after state changes:

```elixir
@impl true
def on_enter(old_state, new_state, data) do
  {:keep_state, Map.put(data, :entered_at, System.monotonic_time())}
end
```

## Stopped machines

`{:stop, reason, data}` sets `machine.status` to `{:stopped, reason}`. Further steps raise `Rig.StoppedError`. Use `crank!/2` in tests to raise immediately on stop results.

## Unhandled events

No catch-all. Unhandled events crash with `FunctionClauseError`. This is deliberate -- a state machine that silently ignores events is hiding bugs. Let it crash; let the supervisor handle it.

## Installation

```elixir
def deps do
  [
    {:rig_fsm, "~> 0.1.0"}
  ]
end
```

## Design

See [DESIGN.md](DESIGN.md) for the full specification and rationale behind every decision.

## License

MIT
