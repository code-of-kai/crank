# Hexagonal Architecture with Crank

## The problem: infrastructure leaking into domain logic

When a state machine callback calls `Repo.insert!`, tests need a database. When it calls `Mailer.send`, a LiveView reducer sends emails. When it calls an HTTP client, tests hit the network.

Each infrastructure dependency that leaks into the domain model (the data structures and rules that represent what a system actually does) makes it harder to test, harder to reason about, and harder to change.

Hexagonal architecture (also called ports and adapters) prevents this by enforcing a boundary. The domain model lives in the center and knows nothing about infrastructure. Infrastructure plugs in at the boundary as adapters. The domain never reaches out -- it declares what happened, and the adapters decide what to do about it.

Crank enforces this boundary by construction. There's no discipline required -- the architecture prevents the leak.

## How a Crank module enforces the boundary

A Crank callback module is a pure domain model. `handle/3` takes an event and a state, applies the business rules, and returns the next state. It doesn't import anything. It doesn't call anything. It doesn't know about databases, HTTP, email, or queues:

```
                    ┌─────────────────────────────┐
                    │        Domain Model          │
                    │       (Pure Core)            │
                    │                               │
  events ──────►   │  handle/3                     │  ──────► new state
                    │  on_enter/3                   │  ──────► effects (data)
                    │                               │
                    │  No imports. No side effects. │
                    │  No infrastructure.           │
                    └─────────────────────────────┘
                              │
                    ┌─────────────────────────────┐
                    │        Adapters              │
                    │     (Process Shell)          │
                    │                               │
  cast/call ───►   │  Crank.Server (gen_statem)    │  ──────► executed effects
                    │  Telemetry handlers           │  ──────► persistence
                    │                               │  ──────► notifications
                    │                               │  ──────► audit logs
                    └─────────────────────────────┘
```

The inbound port is `handle/3` -- events go in, state transitions come out. The outbound port is telemetry (Erlang's standard library for emitting observable events from running code) -- every state transition emits a `[:crank, :transition]` event, and adapters (infrastructure modules that plug into the telemetry interface) listen and react.

The domain model doesn't know who's listening or what they do. It just declares what happened.

`handle/3` must never contain side effects. The moment `handle/3` calls `Repo.insert!`, the domain model requires a database to run. The moment it calls `Mailer.send`, tests send emails. The boundary is broken.

## Every state change emits a domain event

Every state transition emits `[:crank, :transition]` with this metadata:

```elixir
%{
  module: MyApp.VendingMachine,
  from: :idle,
  to: :accepting,
  event: {:coin, 25},
  data: %{price: 75, balance: 25, stock: 10}
}
```

This is a domain event -- a record of what just happened to the state machine. It tells which module changed, what state it moved from and to, what caused the transition, and what the data looks like after. That's everything an adapter needs to persist, notify, audit, or broadcast -- without the domain model knowing any of that happens.

## Persistence adapter

Save machine state to a database after every transition:

```elixir
defmodule MyApp.VendingPersistence do
  require Logger

  def attach do
    :telemetry.attach(
      "vending-persistence",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
    %{to: state, data: data} = meta

    MyApp.Repo.insert!(
      %MyApp.MachineSnapshot{
        machine_id: data.machine_id,
        state: state,
        data: :erlang.term_to_binary(data)
      },
      on_conflict: :replace_all,
      conflict_target: :machine_id
    )
  end

  # Ignore transitions from other machines
  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

Call `MyApp.VendingPersistence.attach()` in application startup.

The vending machine's `handle/3` has no idea this persistence exists. It never imports Ecto (Elixir's database library). It never calls `Repo`. The persistence adapter listens to domain events and acts on them. The database can be swapped, the schema can change, persistence can be removed entirely -- and the domain model doesn't change.

### When persistence fails

The telemetry handler runs synchronously inside the `gen_statem` process. If `Repo.insert!` raises, the `gen_statem` process crashes. The supervisor restarts it.

This is usually the right behavior -- if a transition can't be persisted, the machine shouldn't continue as if it succeeded.

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
    # Via Oban for guaranteed delivery
    %{machine_id: meta.data.machine_id, location: meta.data.location}
    |> MyApp.Workers.RestockAlert.new()
    |> Oban.insert!()
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

The pattern: match on `to:` to react to specific states. The domain model transitions to `:out_of_stock` because that's what the business rules dictate. The notification adapter decides that this state means "send a restock alert." Two different concerns. Two different modules.

Use `Task.Supervisor` for fire-and-forget. Use Oban (a background job library with persistence and retries) when delivery matters.

## Audit logging adapter

Every regulated industry needs an audit trail. Every transition in a Crank machine is auditable by default -- an adapter writes it down:

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
      machine_id: meta.data.machine_id,
      from: meta.from,
      to: meta.to,
      event: meta.event
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

For compliance, write to an append-only table (a database table where rows are only inserted, never updated or deleted) instead of Logger:

```elixir
def handle(_event, _measurements, %{module: MyApp.VendingMachine} = meta, _config) do
  MyApp.Repo.insert!(%MyApp.AuditEntry{
    entity_type: "vending_machine",
    entity_id: meta.data.machine_id,
    from_state: meta.from,
    to_state: meta.to,
    event: meta.event,
    timestamp: DateTime.utc_now()
  })
end
```

The domain model doesn't know it's being audited. The audit adapter listens to the same domain events as every other adapter. Adding or removing audit logging requires zero changes to the domain model.

## PubSub adapter

PubSub (publish-subscribe) broadcasts transitions to multiple subscribers. A LiveView (Phoenix's server-rendered interactive UI) can update in real time when a machine changes state:

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
      "machine:#{meta.data.machine_id}",
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

Attach adapters before starting servers. The first transition (the initial `:enter` event) fires immediately on process start, so adapters must be listening before any server comes up:

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
      {Crank.Server, {MyApp.VendingMachine, [machine_id: "vm-001", price: 75]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Anti-patterns

### Don't put side effects in handle/3

```elixir
# BAD -- breaks the domain boundary
def handle(:dispense, :dispensing, data) do
  MyApp.Repo.insert!(%MyApp.Transaction{...})  # side effect!
  {:next_state, :idle, %{data | balance: 0}}
end
```

This means `Crank.crank/2` writes to a database. Tests need a database. A LiveView reducer writes to a database. The domain model is no longer pure, and the hexagonal boundary is broken.

The domain model decides *what* happens (state transition). Adapters decide *what to do about it* (persist, notify, audit). Different concerns, different modules.

### Don't block the gen_statem with slow adapters

```elixir
# BAD -- blocks the state machine for 2+ seconds
def handle(_event, _measurements, meta, _config) do
  HTTPoison.post!("https://slow-api.example.com/webhook", Jason.encode!(meta))
end
```

The telemetry handler runs synchronously in the `gen_statem` process. While this HTTP call is in flight, the state machine can't process events.

Dispatch async work to a separate process:

```elixir
# GOOD -- non-blocking
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

### Don't attach adapters inside handle/3

```elixir
# BAD -- attaches a new adapter on every transition
def handle({:coin, amount}, :idle, data) do
  :telemetry.attach("notify-#{data.machine_id}", ...)
  {:next_state, :accepting, %{data | balance: amount}}
end
```

Attach adapters once at application startup. They receive all transitions and filter by module/state using pattern matching.

## Testing without infrastructure

The domain model is pure, so tests need no infrastructure:

```elixir
test "inserting coins and selecting transitions to dispensing" do
  machine =
    MyApp.VendingMachine
    |> Crank.new(price: 75, machine_id: "vm-001")
    |> Crank.crank({:coin, 25})
    |> Crank.crank({:coin, 50})
    |> Crank.crank({:select, "A3"})

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
    data: %{machine_id: "vm-001", price: 75, balance: 25, stock: 10}
  }

  MyApp.VendingPersistence.handle([:crank, :transition], %{}, meta, nil)

  assert MyApp.Repo.get_by(MyApp.MachineSnapshot, machine_id: "vm-001")
end
```

Each concern is tested independently. The domain model doesn't know about persistence. The persistence adapter doesn't know about the domain model's internals. They communicate through domain events -- the `[:crank, :transition]` telemetry contract.

That's hexagonal architecture. The domain model is pure. Infrastructure plugs in at the boundary. Neither knows about the other. The architecture fell out of keeping side effects out of `handle/3`.
