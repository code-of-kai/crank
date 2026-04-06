# Hexagonal Architecture with Crank

## Why this matters

The hardest problem in software architecture isn't building features. It's keeping the domain model — the states, transitions, and business rules that define what your system actually does — separate from the infrastructure that supports it.

When domain logic imports Ecto, it can't run without a database. When it imports Phoenix, it can't run without a web server. When it calls a mailer, your tests send emails. Every infrastructure dependency that leaks into the domain model makes it harder to test, harder to reason about, and harder to change.

Hexagonal architecture (ports and adapters) solves this by enforcing a boundary: the domain model lives in the center, knows nothing about infrastructure, and communicates with the outside world through ports. Infrastructure plugs in at the boundary as adapters. The domain never reaches out — it declares what happened, and the adapters decide what to do about it.

Crank is hexagonal by construction, not by convention. You don't have to discipline yourself into the pattern — the architecture enforces it.

## The architecture you already have

A Crank callback module is a pure domain model. `handle/3` takes an event and a state, applies the business rules, and returns the next state. It doesn't import anything. It doesn't call anything. It doesn't know about databases, HTTP, email, or queues. It's pure functions operating on plain data.

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

The inbound port is `handle/3` — events go in, state transitions come out. The outbound port is telemetry — every state transition emits a `[:crank, :transition]` event, and adapters listen and react. The domain model doesn't know who's listening or what they do. It just declares what happened.

This is why `handle/3` must never contain side effects. The moment you call `Repo.insert!` or `Mailer.send` inside a `handle/3` clause, the domain model is no longer pure. It can't run without infrastructure. Your tests need a database. Your LiveView reducer sends emails. The boundary is broken.

## What telemetry gives you

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

This is a domain event. It tells you which aggregate changed, what state it moved from and to, what caused it, and what the data looks like after. That's everything an adapter needs to persist, notify, audit, or broadcast — without the domain model knowing any of that happens.

## Persistence

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

Call `MyApp.VendingPersistence.attach()` in your application startup.

Notice what's happening: the vending machine's `handle/3` has no idea this persistence exists. It never imports Ecto. It never calls `Repo`. The persistence adapter listens to domain events and acts on them. You can swap the database, change the schema, or remove persistence entirely — and the domain model doesn't change.

### When persistence fails

The telemetry handler runs synchronously inside the gen_statem process. If `Repo.insert!` raises, the gen_statem process crashes. The supervisor restarts it. This is usually what you want — if you can't persist a transition, the machine shouldn't continue as if it succeeded.

If you want persistence failure to be non-fatal:

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

## Notifications

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

The pattern: match on `to:` to react to specific states. The domain model transitions to `:out_of_stock` because that's what the business rules dictate. The notification adapter decides that this state means "send a restock alert." Those are two different concerns, and they live in two different modules.

Use `Task.Supervisor` for fire-and-forget. Use Oban when delivery matters.

## Audit logging

Every regulated industry needs an audit trail. Every transition in a Crank machine is auditable by default — you just need an adapter to write it down:

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

For compliance, write to an append-only table instead of Logger:

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

The domain model doesn't know it's being audited. It doesn't need to. The audit adapter listens to the same domain events as every other adapter. Adding or removing audit logging requires zero changes to the domain model.

## PubSub fan-out

Broadcast transitions to multiple subscribers (LiveView, WebSocket, etc.):

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

## Wiring it together

In your application supervisor:

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
      # Start your Crank servers
      {Crank.Server, {MyApp.VendingMachine, [machine_id: "vm-001", price: 75]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Attach adapters first. Then start servers. Order matters because the first transition (the initial `:enter` event) fires immediately on process start.

## Anti-patterns

### Don't put side effects in handle/3

```elixir
# BAD -- breaks the domain boundary
def handle(:dispense, :dispensing, data) do
  MyApp.Repo.insert!(%MyApp.Transaction{...})  # side effect!
  {:next_state, :idle, %{data | balance: 0}}
end
```

This means `Crank.crank/2` writes to a database. Your tests need a database. Your LiveView reducer writes to a database. The domain model is no longer pure, and the hexagonal boundary is broken.

The domain model decides *what* happens (state transition). Adapters decide *what to do about it* (persist, notify, audit). These are different concerns and they belong in different modules.

### Don't block the gen_statem with slow adapters

```elixir
# BAD -- blocks the domain model for 2+ seconds
def handle(_event, _measurements, meta, _config) do
  HTTPoison.post!("https://slow-api.example.com/webhook", Jason.encode!(meta))
end
```

The telemetry handler runs synchronously in the gen_statem process. While this HTTP call is in flight, the domain model can't process any events.

Fix: dispatch async work to a separate process.

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

## Testing

This is the payoff. The whole point of keeping the domain model pure is that you test it without any infrastructure:

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

No database. No mailer. No PubSub. No mocking. Just pure functions. The domain model doesn't know about persistence, so you don't need to set up persistence to test it. It doesn't know about notifications, so you don't need to mock a mailer.

Test your adapters separately:

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

Each concern is tested independently. The domain model doesn't know about persistence. The persistence adapter doesn't know about the domain model's internals. They communicate through domain events — the `[:crank, :transition]` telemetry contract.

That's hexagonal architecture. The domain model is pure. Infrastructure plugs in at the boundary. Neither knows about the other. And you didn't need a framework to get there — the architecture fell out of keeping side effects out of `handle/3`.
