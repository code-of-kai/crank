# CRANK_PURITY_006 — Ambient state access inside turn/3

## What triggers this

A read or write of process-wide or VM-wide state from `turn/3`. The blacklist covers `Process.put/2`, `Process.get/0..2`, `Process.delete/1`, `:ets.*`, `:persistent_term.*`, `:atomics.*`, `:counters.*`, `Application.get_env`, `Application.fetch_env`, `Application.fetch_env!`, `:os.*`, `File.*`, `:file.*`, `Code.eval_string`, `Code.eval_quoted`, `Code.compile_string`, `String.to_atom`, `:erlang.list_to_atom`, `:erlang.binary_to_atom`.

```elixir
def turn(:start, %Idle{}, memory) do
  rate = :ets.lookup_element(:config, :rate, 2)    # CRANK_PURITY_006
  {:next, %Running{rate: rate}, memory}
end
```

## Why it's wrong

Ambient state is the antithesis of a pure core. ETS contents change between replays. Application config differs between dev, test, and prod. Process dictionary entries are invisible at the call site. Filesystem reads tie the test suite to whichever working directory the runner happens to launch in. None of these dependencies show up in the function signature — they are *implicit* inputs that make the same `(event, state, memory)` return different results.

The fix is to make the inputs explicit. Whatever the ambient store provided, plumb it through `start/1` into `memory` (so it's part of the snapshot and travels with the machine), or into the event payload (so it's visible per-call). The domain model only depends on its arguments, period.

## How to fix

### Wrong

```elixir
def turn(:start, %Idle{}, memory) do
  rate = :ets.lookup_element(:config, :rate, 2)
  {:next, %Running{rate: rate}, memory}
end
```

### Right

```elixir
# Read at the boundary, carry through start/1:
def start(opts) do
  rate = :ets.lookup_element(:config, :rate, 2)
  {:ok, %Idle{}, %{rate: rate}}
end

# turn/3 sees rate as an explicit input:
def turn(:start, %Idle{}, %{rate: rate} = memory) do
  {:next, %Running{rate: rate}, memory}
end
```

Same recipe for `Application.get_env` (sample at boot), `String.to_atom` (use `String.to_existing_atom/1` if the atom exists, or carry the atom through the event), and file reads (load the contents at start and stash the result).

## How to suppress at this layer

Layer A — source-adjacent comment.

```elixir
# crank-allow: CRANK_PURITY_006
# reason: bootstrap snapshot read-once; replaced by start/1 in v2.0
Application.get_env(:my_app, :default_rate)
```

## See also

- [Typing state and memory](../typing-state-and-memory.md) — making implicit inputs explicit.
- [`CRANK_TRACE_001`](CRANK_TRACE_001.md) — atom-table mutation observed at runtime.
- [Suppressions](../suppressions.md).
