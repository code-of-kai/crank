# Hexagonal Architecture with Crank

## A persistence adapter in 20 lines

This module saves the vending machine's state to a database after every transition:

```elixir
defmodule MyApp.VendingPersistence do
  def attach do
    :telemetry.attach(
      "vending-persistence",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.VendingMachine, to: state, memory: memory}, _config) do
    snapshot = %{module: MyApp.VendingMachine, state: state, memory: memory}

    MyApp.Repo.insert!(
      %MyApp.MachineSnapshot{
        machine_id: memory.machine_id,
        snapshot: :erlang.term_to_binary(snapshot)
      },
      on_conflict: :replace_all,
      conflict_target: :machine_id
    )
  end

  # Ignore transitions from other machines
  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

The snapshot map — `%{module:, state:, memory:}` — is exactly the shape `Crank.resume/1` and `Crank.Server.resume/2` accept. Write it on every transition, read it back on restart. The README's [Persistence section](https://github.com/code-of-kai/crank#persistence) shows the restore side and compares this pattern to event sourcing and hybrid approaches.

Call `MyApp.VendingPersistence.attach()` in application startup. The vending machine's `turn/3` has no idea this persistence exists. It never imports Ecto. It never calls `Repo`. The persistence adapter listens to domain events and acts on them. The database can be swapped, the schema can change, persistence can be removed entirely — and the domain model doesn't change.

## What just happened

The vending machine module is pure functions. It takes events, applies business rules, returns the next state. It doesn't know about databases.

The persistence module is infrastructure. It listens for state transitions and writes them to a database. It doesn't know about business rules.

They don't import each other. They don't call each other. They communicate through telemetry — every state transition emits a `[:crank, :transition]` event, and adapters listen and react.

This separation has a name: hexagonal architecture (also called ports and adapters). The domain model lives in the centre and knows nothing about infrastructure. Infrastructure plugs in at the boundary as adapters. The domain never reaches out — it declares what happened, and the adapters decide what to do about it.

Crank enforces this boundary automatically. `turn/3` returns data — it cannot execute side effects because the return type has nowhere to put them. `wants/2` returns data too — declared effects, not performed ones. The Server is the one place where declared effects become real. The architecture makes the wrong thing impossible, not merely discouraged.

## How the boundary works

```
                    ┌─────────────────────────────┐
                    │        Domain Model          │
                    │       (Pure Core)            │
                    │                               │
  events ──────►   │  turn/3       (transitions)   │  ──────► new state
                    │  wants/2      (declarations)  │  ──────► wants (data)
                    │  reading/2    (projection)    │  ──────► reading
                    │                               │
                    │  No imports. No side effects. │
                    └─────────────────────────────┘
                              │
                    ┌─────────────────────────────┐
                    │        Adapters              │
                    │     (Process Shell)          │
                    │                               │
  cast/turn ───►   │  Crank.Server  (gen_statem)   │  ──────► executed wants
                    │  Telemetry handlers           │  ──────► persistence
                    │                               │  ──────► notifications
                    │                               │  ──────► audit logs
                    └─────────────────────────────┘
```

The inbound ports are `turn/3` (advance) and `reading/2` (observe). The outbound port is telemetry — every state transition emits `[:crank, :transition]`, and adapters listen and react.

The domain model doesn't know who's listening or what they do. It just declares what happened.

`turn/3` must never contain side effects. The moment `turn/3` calls `Repo.insert!`, the domain model requires a database to run. The moment it calls `Mailer.send`, tests send emails. The boundary is broken. Nothing in the compiler stops you — this is a discipline the architecture requires, not one Elixir enforces. The return type helps as a signal: there is no return shape that admits a declared side effect, so any effect in the body is immediately suspicious. `when` guards are a different story: the BEAM's allowlist rejects database calls and sends at compile time, and contains crashes at runtime — purity there is structurally enforced, not conventional. See the [Transitions and guards guide](transitions-and-guards.md) for the mechanism.

## Every state change emits a domain event

Every state transition emits `[:crank, :transition]` with this metadata:

```elixir
%{
  module: MyApp.VendingMachine,
  from:   :idle,
  to:     :accepting,
  event:  {:coin, 25},
  memory: %{price: 75, balance: 25, stock: 10, machine_id: "vm-001"}
}
```

This is a domain event — a record of what just happened. It tells which module changed, what state it moved from and to, what caused the transition, and what the memory looks like after. Everything an adapter needs to persist, notify, audit, or broadcast — without the domain model knowing any of that happens.

Two other telemetry events complete the picture:

- **`[:crank, :start]`** — emitted in `init` when a machine is freshly started. Metadata: `%{module, state, memory}`.
- **`[:crank, :resume]`** — emitted in `init` when a machine is restored from a snapshot. Metadata: `%{module, state, memory}`.

## When persistence fails

The telemetry handler runs synchronously inside the `gen_statem` process. If `Repo.insert!` raises, the `gen_statem` process crashes. The supervisor restarts it.

This is usually the right behaviour — if a transition can't be persisted, the machine shouldn't continue as if it succeeded.

**A consequence worth naming**: a crashing infrastructure adapter takes the *aggregate process* with it. Crank's port contract prevents the aggregate from importing infrastructure, but telemetry handlers run inline in the aggregate's process, so an adapter crash is NOT isolated from the domain runtime. Keep adapter handlers small, total where possible, and wrap risky work in `try`/`rescue` + logging when a handler failure shouldn't bring the aggregate down.

For non-fatal persistence:

```elixir
def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
  try do
    do_persist(meta)
  rescue
    e ->
      Logger.warning("Failed to persist vending transition: #{Exception.message(e)}")
  end
end
```

Choose deliberately. Don't rescue by default.

## Notification adapter

Alert the operator when the machine needs attention:

```elixir
defmodule MyApp.VendingNotifications do
  def attach do
    :telemetry.attach(
      "vending-notifications",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.VendingMachine, to: :out_of_stock} = meta, _config) do
    %{machine_id: meta.memory.machine_id, location: meta.memory.location}
    |> MyApp.Workers.RestockAlert.new()
    |> Oban.insert!()
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

Pattern-match on `to:` to react to specific states. The domain model transitions to `:out_of_stock` because that's what the business rules dictate. The notification adapter decides that this state means "send a restock alert." Two concerns, two modules.

Use `Task.Supervisor` for fire-and-forget. Use Oban when delivery matters.

## Audit logging adapter

Every regulated industry needs an audit trail. Every transition in a Crank machine is auditable by default — an adapter writes it down:

```elixir
defmodule MyApp.AuditLog do
  require Logger

  def attach do
    :telemetry.attach(
      "vending-audit",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
    Logger.info("vending transition",
      machine_id: meta.memory.machine_id,
      from: meta.from,
      to: meta.to,
      event: meta.event
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

For compliance, write to an append-only table instead of Logger:

```elixir
def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
  MyApp.Repo.insert!(%MyApp.AuditEntry{
    entity_type: "vending_machine",
    entity_id: meta.memory.machine_id,
    from_state: meta.from,
    to_state: meta.to,
    event: meta.event,
    timestamp: DateTime.utc_now()
  })
end
```

The domain model doesn't know it's being audited. The audit adapter listens to the same domain events as every other adapter. Adding or removing audit logging requires zero changes to the domain model.

## PubSub adapter

PubSub broadcasts transitions to multiple subscribers. A LiveView can update in real time when a machine changes state:

```elixir
defmodule MyApp.VendingBroadcast do
  def attach do
    :telemetry.attach(
      "vending-pubsub",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "machine:#{meta.memory.machine_id}",
      {:machine_transition, meta.from, meta.to}
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

In a LiveView:

```elixir
def mount(%{"id" => machine_id}, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "machine:#{machine_id}")
  {:ok, assign(socket, machine_id: machine_id)}
end

def handle_info({:machine_transition, _from, new_state}, socket) do
  {:noreply, assign(socket, state: new_state)}
end
```

## Wiring adapters at startup

Attach adapters before starting servers. The `[:crank, :start]` event fires when a server boots, so adapters must be listening before any server comes up:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Attach adapters before starting any servers
    MyApp.VendingPersistence.attach()
    MyApp.VendingNotifications.attach()
    MyApp.AuditLog.attach()
    MyApp.VendingBroadcast.attach()

    children = [
      MyApp.Repo,
      {Task.Supervisor, name: MyApp.TaskSupervisor},
      {Oban, oban_config()},
      {Phoenix.PubSub, name: MyApp.PubSub},
      # Start Crank servers after adapters are attached
      {MyApp.VendingMachine, [machine_id: "vm-001", price: 75]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Anti-patterns

### Don't put side effects in turn/3

```elixir
# BAD — breaks the domain boundary
def turn(:dispense, :dispensing, memory) do
  MyApp.Repo.insert!(%MyApp.Transaction{...})  # CRANK_PURITY_001
  {:next, :idle, %{memory | balance: 0}}
end
```

This means `Crank.turn/2` writes to a database. Tests need a database. A LiveView reducer writes to a database. The domain model is no longer pure, and the hexagonal boundary is broken.

Crank surfaces this exact pattern as a hard `CompileError` via the `@before_compile` static check (`CRANK_PURITY_001`). The Credo check (`Crank.Check.TurnPurity`) flags the same pattern at editor-save time, and the runtime trace (`Crank.PurityTrace`) catches it via property tests when the call lives transitively in a helper. See the [violations index](violations/index.md) for the full catalog and [property testing](property-testing.md) for the runtime layer.

The fix is structural: declare the effect, don't perform it. `wants/2` returns effects as data; an adapter on `[:crank, :transition]` performs them. Different concerns, different modules.

### Don't block the gen_statem with slow adapters

```elixir
# BAD — blocks the state machine for 2+ seconds
def handle(_event, _measurements, meta, _config) do
  HTTPoison.post!("https://slow-api.example.com/webhook", Jason.encode!(meta))
end
```

The telemetry handler runs synchronously in the `gen_statem` process. While this HTTP call is in flight, the state machine can't process events.

Dispatch async work to a separate process:

```elixir
# GOOD — non-blocking
def handle(_event, _measurements, meta, _config) do
  Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
    HTTPoison.post!("https://slow-api.example.com/webhook", Jason.encode!(meta))
  end)
end
```

Or use Oban for retries and persistence:

```elixir
def handle(_event, _measurements, meta, _config) do
  %{url: "https://slow-api.example.com/webhook", payload: meta}
  |> MyApp.Workers.WebhookWorker.new()
  |> Oban.insert!()
end
```

### Don't reach for infrastructure from a domain helper

```elixir
# BAD — domain module aliases infrastructure  (CRANK_DEP_001)
defmodule MyApp.OrderMachine do
  use Crank
  alias MyApp.Repo
  ...
end
```

Even if `Repo` is never *called* in this module, the alias declares a dependency on the persistence layer. The architecture's promise that the domain can be tested without a database is gone the moment the dependency exists. Boundary's post-compile graph check rejects this with `CRANK_DEP_001` whether or not the alias is dereferenced.

For unmarked first-party helpers in strict mode (`CRANK_DEP_002`), the fix is one line: `use Crank.Domain.Pure` on the helper. That tags the module as part of the domain at the topology level *and* subjects its bodies to the same call-site blacklist as `turn/3`. See the [Boundary setup guide](boundary-setup.md).

### Don't attach adapters inside turn/3

```elixir
# BAD — attaches a new adapter on every transition  (CRANK_PURITY_005)
def turn({:coin, amount}, :idle, memory) do
  :telemetry.attach("notify-#{memory.machine_id}", ...)
  {:next, :accepting, %{memory | balance: amount}}
end
```

Attach adapters once at application startup. They receive all transitions and filter by module/state using pattern matching. The `:telemetry.attach/4` call is itself a side effect — it mutates the global telemetry handler table — so it falls under `CRANK_PURITY_005` (process communication / global mutation).

## Verification of the boundary at compile and runtime

The anti-patterns above used to be enforced by convention. They are now enforced mechanically:

- **Compile time.** The `@before_compile` hook walks every `turn/3` body and the module's local references. Calls to `Repo`, `Logger`, `:rand`, time functions, ETS, file IO, etc. become hard `CompileError`s. The static call-site checks live in `Crank.Check.Blacklist` and `Crank.Check.CompileTime`.
- **Topology.** Boundary's post-compile graph check rejects every domain → infrastructure reference (`CRANK_DEP_001..003`). `mix crank.gen.config` writes the starter Boundary config; `mix crank.check` is the canonical CI gate.
- **Runtime.** `Crank.PurityTrace` runs `turn/3` in an isolated trace session and reports any blacklist match anywhere in the dynamic call graph. Combined with `StreamData` and `Crank.PropertyTest.assert_pure_turn/3`, every property test becomes a purity test for hundreds or thousands of generated event sequences.

The discipline this guide describes is what the static and runtime layers enforce. If you write a domain module that breaks any of the rules, the build fails or the test fails — the boundary stops being a convention and becomes a property of the code. See the [property testing guide](property-testing.md) for the canonical pattern, the [violations index](violations/index.md) for the codes each layer can raise, and the [suppressions guide](suppressions.md) for the three layer-specific opt-out mechanisms when an exception is genuinely needed.

## Testing without infrastructure

The domain model is pure, so tests need no infrastructure:

```elixir
test "inserting coins and selecting transitions to dispensing" do
  machine =
    MyApp.VendingMachine
    |> Crank.new(price: 75, machine_id: "vm-001")
    |> Crank.turn({:coin, 25})
    |> Crank.turn({:coin, 50})
    |> Crank.turn({:select, "A3"})

  assert machine.state == :dispensing
end
```

No database. No mailer. No PubSub. No mocking. The domain model doesn't know about persistence, so tests don't set up persistence. It doesn't know about notifications, so tests don't mock a mailer.

Test adapters separately:

```elixir
test "persistence adapter saves machine snapshot" do
  meta = %{
    module: MyApp.VendingMachine,
    from: :idle,
    to: :accepting,
    event: {:coin, 25},
    memory: %{machine_id: "vm-001", price: 75, balance: 25, stock: 10}
  }

  MyApp.VendingPersistence.handle([:crank, :transition], %{}, meta, nil)

  assert MyApp.Repo.get_by(MyApp.MachineSnapshot, machine_id: "vm-001")
end
```

Each concern is tested independently. The domain model doesn't know about persistence. The persistence adapter doesn't know about the domain model's internals. They communicate through domain events — the `[:crank, :transition]` telemetry contract.

That's hexagonal architecture. The domain model is pure. Infrastructure plugs in at the boundary. Neither knows about the other. The architecture fell out of keeping side effects out of `turn/3`.
