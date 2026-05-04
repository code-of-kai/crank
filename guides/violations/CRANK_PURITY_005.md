# CRANK_PURITY_005 — Process communication inside turn/3

## What triggers this

A call from `turn/3` to anything that sends, spawns, or talks to another process. The blacklist covers `send/2`, `Process.send_after/3`, `GenServer.cast/2`, `GenServer.call/2`, `Task.start/1`, `Task.async/1`, `spawn/1`, `spawn_link/1`.

```elixir
def turn({:coin, n}, %Accepting{} = state, memory) do
  send(memory.dispatcher, {:notify, n})    # CRANK_PURITY_005
  {:stay, %{memory | balance: memory.balance + n}}
end
```

## Why it's wrong

`turn/3` runs in pure mode without any process at all — `Crank.new(MyMachine) |> Crank.turn(event)` is a function call that returns a struct. There is no mailbox, no `self()`, no peer to send to. A `send/2` call there either crashes immediately or, worse, references whichever pid the test happened to set up — making the domain model depend on the surrounding process topology.

`wants/2` is the effect channel. `{:send, dest, message}` is data; `Crank.Server` interprets it on `{:next, ...}` arrivals and performs the actual send. Because the want is data, two replays produce identical sends, snapshots round-trip cleanly, and tests can assert on `machine.wants` without spinning up a process tree.

## How to fix

### Wrong

```elixir
def turn({:coin, n}, %Accepting{} = state, memory) do
  send(memory.dispatcher, {:notify, n})
  {:stay, %{memory | balance: memory.balance + n}}
end
```

### Right

```elixir
def turn({:coin, n}, %Accepting{}, memory) do
  {:stay, %{memory | balance: memory.balance + n}}
end

def wants(%Accepting{} = state, memory) do
  [{:send, memory.dispatcher, {:balance_changed, memory.balance}}]
end
```

For timers, use `{:after, ms, event}`. For internal events, use `{:next, event}`. For Task work, emit telemetry and let a Task.Supervisor adapter pick it up. The complete vocabulary lives in [DESIGN.md](../../DESIGN.md).

## How to suppress at this layer

Layer A — source-adjacent comment.

```elixir
# crank-allow: CRANK_PURITY_005
# reason: ad-hoc trace ping in test fixture; not reachable in :prod
send(self(), :diagnostic)
```

## See also

- [Hexagonal Architecture](../hexagonal-architecture.md) — sends as declared wants.
- [Composing Work](../composing-work.md) — multi-machine coordination.
- [Suppressions](../suppressions.md).
