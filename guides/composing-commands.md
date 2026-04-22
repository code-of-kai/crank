# Composing Commands with Wants and Turns

A single machine, advanced by a single event, is the atom. Real systems want two things the atom doesn't give you directly:

1. **Shared effect policies across machines.** Every machine in your system might declare the same telemetry want or the same health-check timer on entry to any "active" state. Hand-writing tuple literals in every `wants/2` clause duplicates; extracting them needs a builder.
2. **Multiple machines advanced as one unit of work.** An order is placed; that submits a payment and a fulfillment. All three need to advance together, one caller intent, with a coherent failure story. A single `Crank.turn/2` can't express "advance these three machines and tell me what happened."

Crank ships three small modules for this:

- **`Crank.Wants`** — a pipe-friendly builder over the want vocabulary. Produces plain lists; zero wire-format change.
- **`Crank.Turns`** — a descriptor that accumulates named turns against named machines. Pure data, inspectable before execution.
- **`Crank.Server.Turns`** — the process-mode executor for the same descriptor.

Nothing here is new machinery under the hood. `Crank.Wants` builds exactly the tuples you'd have written by hand. `Crank.Turns` folds over pure `%Crank{}` structs via `Crank.turn/2`. `Crank.Server.Turns` walks the same descriptor through `Crank.Server.turn/2` calls. Same atoms, assembled for you.

## `Crank.Wants` — composable effect declarations

Hand-written wants accumulate quickly. This reads fine:

```elixir
def wants(:accepting, memory) do
  [
    {:after, 60_000, :refund_timeout},
    {:telemetry, [:vending, :accepting], %{balance: memory.balance}, %{}}
  ]
end
```

But the moment a condition slips in, or you want to reuse a telemetry policy across five machines, the hand-written form stops being tidy:

```elixir
def wants(:accepting, memory) do
  base = [
    {:after, 60_000, :refund_timeout},
    {:telemetry, [:vending, :accepting], %{balance: memory.balance}, %{}}
  ]

  if memory.balance > 1000 do
    base ++ [{:send, :fraud_monitor, {:big_balance, memory.balance}}]
  else
    base
  end
end
```

With the builder:

```elixir
def wants(:accepting, memory) do
  Crank.Wants.new()
  |> Crank.Wants.timeout(60_000, :refund_timeout)
  |> Crank.Wants.telemetry([:vending, :accepting], %{balance: memory.balance}, %{})
  |> Crank.Wants.only_if(
       memory.balance > 1000,
       &Crank.Wants.send(&1, :fraud_monitor, {:big_balance, memory.balance})
     )
end
```

The real leverage is when shared policies become composable across machines:

```elixir
# In a shared module
defmodule MyApp.Telemetry do
  alias Crank.Wants

  @doc "Standard entry telemetry emitted by every machine on state arrival."
  def entry(state, memory) do
    Wants.new()
    |> Wants.telemetry([:my_app, state], %{}, %{memory: memory})
  end
end

# In every machine's wants/2
def wants(state, memory) do
  MyApp.Telemetry.entry(state, memory)
  |> Crank.Wants.timeout(5_000, :health_check)
end
```

### The full surface

| Function | Produces |
|---|---|
| `new/0` | `[]` |
| `timeout(wants, ms, event)` | `{:after, ms, event}` (anonymous state timeout) |
| `timeout(wants, name, ms, event)` | `{:after, name, ms, event}` (named generic timeout) |
| `cancel(wants, name)` | `{:cancel, name}` |
| `send(wants, dest, message)` | `{:send, dest, message}` |
| `telemetry(wants, event_name, measurements, metadata)` | `{:telemetry, ...}` |
| `next(wants, event)` | `{:next, event}` |
| `only_if(wants, condition, fun)` | conditional; `fun :: (wants -> wants)` |
| `merge(a, b)` | concatenation |

Every function takes `wants` as its first argument and returns a new list — fully pipe-compatible. The output is identical to hand-written tuple literals; the Server doesn't know (or care) that you built them with a helper.

## `Crank.Turns` — the Ecto.Multi for state machines

When one user action advances several machines, you want:

- **All in one place.** The three turns that make up "place an order" live together in one description, not scattered across three call sites.
- **Pure descriptor.** The plan is data; you can inspect it, test it, hand it to a different executor, persist it if you want.
- **Coherent failure.** If the second machine stops, you want to know which one, why, and what the first one's state is.
- **Dependencies.** Step 2 often depends on step 1's result — the payment amount comes from the order total.

That's what `Crank.Turns` gives you. The analogy to `Ecto.Multi` is deliberate: accumulate named operations, execute at one boundary, get back a results map or a structured error.

```elixir
order    = Crank.new(MyApp.Order)
payment  = Crank.new(MyApp.Payment)
shipping = Crank.new(MyApp.Shipping)

Crank.Turns.new()
|> Crank.Turns.turn(:order, order, :submit)
|> Crank.Turns.turn(:payment, payment,
     fn %{order: o} -> {:charge, o.memory.total} end)
|> Crank.Turns.turn(:shipping, shipping,
     fn %{payment: p} -> {:queue, p.memory.txn_id} end)
|> Crank.Turns.apply()
#=> {:ok, %{order: %Crank{...}, payment: %Crank{...}, shipping: %Crank{...}}}
```

### Dependencies

Either the machine or the event argument may be a function of arity 1 taking the prior-results map:

```elixir
Crank.Turns.new()
|> Crank.Turns.turn(:charged, payment, :charge)
|> Crank.Turns.turn(:notified,
     fn %{charged: c} -> notifier_machine(c.memory.user) end,
     fn %{charged: c} -> {:send_receipt, c.memory.txn_id} end)
```

Any term passed as the event argument that is NOT an arity-1 function is used literally. If you need to pass a literal function as an event, wrap it (e.g., `{:call, &handler/1}`).

### Execution semantics: best-effort sequential

Steps run in insertion order. Each step sees prior successful results by name. On the first stop, execution aborts.

**Not atomic.** `Crank.Turns` is not a transaction. No rollback, no compensation, no two-phase commit. If step 2 stops after step 1 succeeded, step 1's advance stands — the machine's state has already changed.

This is deliberate. The mental model equals the implementation: a fold over turns, halting on the first stop. Atomicity across multiple domain aggregates is a distributed-systems problem; Crank stays out of it. If you need compensation, model it as a saga — a separate Crank module that observes the result and emits compensating commands.

### Failure shapes

`Crank.Turns.apply/1` returns one of:

- **`{:ok, results}`** — every step succeeded. `results` maps step names to advanced `%Crank{}` structs.
- **`{:error, name, reason, advanced_so_far}`** — step `name` stopped the machine. `reason` is the stop reason. `advanced_so_far` includes prior successes *and* the stopped machine itself (with `engine: {:off, reason}`).
- **`{:error, name, {:stopped_input, reason}, prior_results}`** — step `name`'s input machine was already stopped before this apply began. No turn ran; the step isn't in the results map. The wrapper disambiguates "we couldn't start" from "our turn stopped us."

The stopped machine being present in `advanced_so_far` is an intentional difference from `Ecto.Multi`. `Multi` rolls back; `Turns` doesn't. The caller gets access to the final state and memory of the stopped machine, which is often diagnostic information.

### Exceptions propagate

If `turn/3` or a dependency function raises, the exception is not caught. `Crank.Turns` honestly reports business stops (which are a return-value concern); exceptions are bugs, and bugs propagate.

## `Crank.Server.Turns` — the process-mode executor

Same descriptor, different executor. Operates on running `Crank.Server` processes via `Crank.Server.turn/2`.

```elixir
{:ok, order_pid}    = Crank.Server.start_link(MyApp.Order, ...)
{:ok, payment_pid}  = Crank.Server.start_link(MyApp.Payment, ...)
{:ok, shipping_pid} = Crank.Server.start_link(MyApp.Shipping, ...)

Crank.Turns.new()
|> Crank.Turns.turn(:order, order_pid, :submit)
|> Crank.Turns.turn(:payment, payment_pid,
     fn %{order: reading} -> {:charge, reading.total} end)
|> Crank.Turns.turn(:shipping, shipping_pid,
     fn %{payment: reading} -> {:queue, reading.txn_id} end)
|> Crank.Server.Turns.apply()
#=> {:ok, %{order: %{...reading}, payment: %{...reading}, shipping: %{...reading}}}
```

Targets can be pids, registered names, or `{name, node}` tuples — anything `Crank.Server.turn/2` accepts.

### Result shape differs from pure mode

Each entry in `results` is the **reading** returned by `Crank.Server.turn/2`, not a `%Crank{}` struct. Process mode has no access to the internal `%Crank{}`; the reply contract is the reading only. This matches the single-turn process-mode contract — if `reading/2` is defined, you get its projection; otherwise you get the raw state.

### How stops are detected

`Crank.Server.turn/2` returns a reading whether the turn advanced the machine normally or stopped it. A stopped machine replies then terminates — the caller sees the reading and has to infer the stop separately.

`Crank.Server.Turns` handles this with monitors:

1. Before each turn, monitor the target server (memoized; one `Process.monitor/1` per unique target).
2. After the turn, yield the scheduler and wait briefly for `:DOWN` on that monitor.
3. If `:DOWN` arrives, the turn succeeded at reply-time but the process stopped; report it.
4. On completion, demonitor everything with `[:flush]` so no `:DOWN` messages leak into the caller's mailbox.

`Process.alive?/1` is intentionally not used: it returns `true` during gen_statem termination cleanup, reporting "alive" for a process that has already replied-then-stopped. Monitor + brief wait is the reliable shape.

### Failure shapes

- **`{:ok, results}`** — every step's server replied and remained alive.
- **`{:error, name, reason, advanced_so_far}`** — the server stopped after replying. The step's reading IS in the map.
- **`{:error, name, {:server_exit, exit_reason}, prior_results}`** — the call exited without a reply (pre-existing death, timeout, crash during routing). The step's entry is NOT in the map. The wrapper disambiguates "no reading" from "reading-then-stopped."

Symmetric with pure mode's `{:stopped_input, reason}`: both wrap the no-reading case distinctly from the stop-with-reading case.

### Latency note

The monitor-wait pattern adds roughly 10ms per step on the happy path (`:erlang.yield/0` plus a bounded `receive`). A 5-step Turns adds ~50ms. Acceptable for user-facing commands, well inside a typical database transaction budget. For latency-critical paths, advance machines individually with `Crank.Server.turn/2`.

### Trap-exit note for tests

`Crank.Server.start_link/3` links the server to the caller. If a Turns apply causes a stop, the linked caller would crash. Tests that intentionally exercise stops should `Process.flag(:trap_exit, true)` and drain the resulting `:EXIT` messages. Real use cases put servers under supervisors — the supervisor owns the link, not the caller of `Turns.apply/1`.

## Pure/process symmetry

The same `%Crank.Turns{}` descriptor runs in either executor. The difference is the machine value at each step:

- Pure: `%Crank{}` struct.
- Process: pid, registered name, or `{name, node}`.

`Crank.Turns.turn/4` accepts any value as the machine argument (build-time only validates arity for function resolvers). Each executor does its own shape check at apply time:

- `Crank.Turns.apply/1` requires a `%Crank{}` after resolution.
- `Crank.Server.Turns.apply/1` requires a pid/name/tuple after resolution.

This means one descriptor can be built, inspected, and handed to whichever executor is appropriate for the caller's context — tests and dry runs use the pure executor; live commands use the process executor.

## Composition

Descriptors compose with `Crank.Turns.append/2`:

```elixir
payment_phase =
  Crank.Turns.new()
  |> Crank.Turns.turn(:charged, payment, :charge)

fulfillment_phase =
  Crank.Turns.new()
  |> Crank.Turns.turn(:shipped, shipping, :queue)

Crank.Turns.append(payment_phase, fulfillment_phase)
|> Crank.Turns.apply()
```

Name overlaps raise at composition time — the same discipline as `turn/4`'s duplicate-name check. Fail at build, not at apply.

## Not a saga

Both `Crank.Turns` and `{:next, event}` wants are synchronous and bounded. They express a *command* — one caller intent advancing machines now. A *saga* is a workflow unfolding over real time, possibly days, with compensation if intermediate steps fail.

In Crank, sagas are their own machine modules. The saga's states are the workflow stages (awaiting payment, awaiting fulfillment, etc.), its events are the outcomes of other machines, and its transitions orchestrate them. A saga *uses* `Crank.Turns` internally for each synchronous sub-step, but the saga itself is a regular Crank module — durable, persistable, observable, restartable under a supervisor.

Don't chain `{:next, event}` wants to build a workflow. If the coordination has a lifecycle (a "pending" state, a "completed" state, a "failed" state), it's a saga, not a Turns.

## When to reach for what

- **Single machine, single event** → `Crank.turn/2` or `Crank.Server.turn/2`. Most of the time.
- **Multi-machine command, one caller intent** → `Crank.Turns` / `Crank.Server.Turns`. The command form.
- **Shared effect policies across machines** → `Crank.Wants` in each `wants/2` clause.
- **Long-running coordination with its own lifecycle** → a saga module (a regular Crank machine).
- **Atomic-across-machines-or-nothing semantics** → not Crank. Use a transaction manager (`Ecto.Multi` for DB ops, or a proper saga with compensations).
