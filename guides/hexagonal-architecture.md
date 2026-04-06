# Hexagonal Architecture with Crank

Crank is already hexagonal. This guide shows you how to see it and use it.

## The architecture you already have

Crank has two layers:

```
                    ┌─────────────────────────┐
                    │      Pure Core           │
                    │                           │
  events ──────►   │  handle/3                 │  ──────► new state
                    │  on_enter/3               │  ──────► effects (data)
                    │                           │
                    └─────────────────────────┘
                              │
                    ┌─────────────────────────┐
                    │      Process Shell       │
                    │                           │
  cast/call ───►   │  Crank.Server (gen_statem)  │  ──────► executed effects
                    │                           │  ──────► telemetry events
                    └─────────────────────────┘
```

The pure core is the domain. `handle/3` is the inbound port -- events
go in, state transitions come out. Telemetry is the outbound port -- the
Server broadcasts what happened, and anyone can listen.

The hexagonal question is: how do you plug in persistence, notifications,
and external API calls without touching the pure core?

Answer: telemetry handlers. The Server already emits everything you need.

## What telemetry gives you

Every state transition emits `[:crank, :transition]` with this metadata:

```elixir
%{
  module: MyApp.Order,     # which state machine
  from: :pending,          # previous state (nil on initial enter)
  to: :paid,               # new state
  event: :pay,             # the event that caused it (nil on enter)
  data: %{order_id: 123}   # the machine's data after the transition
}
```

This is the complete picture. You have the module, the transition, and the
data. That's enough to persist, notify, audit, or do anything else.

## Persistence

Save machine state to a database after every transition:

```elixir
defmodule MyApp.OrderPersistence do
  require Logger

  def attach do
    :telemetry.attach(
      "order-persistence",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.Order} = meta, _config) do
    %{to: state, data: data} = meta

    MyApp.Repo.insert!(
      %MyApp.OrderSnapshot{
        order_id: data.order_id,
        state: state,
        data: :erlang.term_to_binary(data)
      },
      on_conflict: :replace_all,
      conflict_target: :order_id
    )
  end

  # Ignore transitions from other machines
  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

Call `MyApp.OrderPersistence.attach()` in your application startup.

### When persistence fails

The telemetry handler runs synchronously inside the gen_statem process.
If `Repo.insert!` raises, the gen_statem process crashes. The supervisor
restarts it. This is usually what you want -- if you can't persist a
transition, the machine shouldn't continue as if it succeeded.

If you want persistence failure to be non-fatal:

```elixir
def handle(_event, _measurements, %{module: MyApp.Order} = meta, _config) do
  try do
    do_persist(meta)
  rescue
    e ->
      Logger.warning("Failed to persist order transition: #{Exception.message(e)}")
  end
end
```

Choose deliberately. Don't rescue by default.

## Notifications

Send an email, broadcast to a channel, enqueue a background job:

```elixir
defmodule MyApp.OrderNotifications do
  def attach do
    :telemetry.attach(
      "order-notifications",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.Order, to: :shipped} = meta, _config) do
    # Async -- don't block the state machine
    Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
      MyApp.Mailer.send_shipped_email(meta.data.customer_email, meta.data.order_id)
    end)
  end

  def handle(_event, _measurements, %{module: MyApp.Order, to: :cancelled} = meta, _config) do
    # Via Oban for guaranteed delivery
    %{order_id: meta.data.order_id, reason: "cancelled"}
    |> MyApp.Workers.SendCancellationEmail.new()
    |> Oban.insert!()
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

Notice the pattern: match on `to:` to react to specific states. Use
`Task.Supervisor` for fire-and-forget. Use Oban when delivery matters.

## Audit logging

Append-only log of every transition:

```elixir
defmodule MyApp.AuditLog do
  require Logger

  def attach do
    :telemetry.attach(
      "order-audit",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.Order} = meta, _config) do
    Logger.info("order transition",
      order_id: meta.data.order_id,
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
def handle(_event, _measurements, %{module: MyApp.Order} = meta, _config) do
  MyApp.Repo.insert!(%MyApp.AuditEntry{
    entity_type: "order",
    entity_id: meta.data.order_id,
    from_state: meta.from,
    to_state: meta.to,
    event: meta.event,
    timestamp: DateTime.utc_now()
  })
end
```

## PubSub fan-out

Broadcast transitions to multiple subscribers (LiveView, WebSocket, etc.):

```elixir
defmodule MyApp.OrderBroadcast do
  def attach do
    :telemetry.attach(
      "order-pubsub",
      [:crank, :transition],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(_event, _measurements, %{module: MyApp.Order} = meta, _config) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "order:#{meta.data.order_id}",
      {:order_transition, meta.from, meta.to}
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
```

In a LiveView:

```elixir
def mount(%{"id" => order_id}, _session, socket) do
  Phoenix.PubSub.subscribe(MyApp.PubSub, "order:#{order_id}")
  {:ok, assign(socket, order_id: order_id)}
end

def handle_info({:order_transition, _from, new_state}, socket) do
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
    # Attach telemetry handlers before starting any servers
    MyApp.OrderPersistence.attach()
    MyApp.OrderNotifications.attach()
    MyApp.AuditLog.attach()
    MyApp.OrderBroadcast.attach()

    children = [
      MyApp.Repo,
      {Task.Supervisor, name: MyApp.TaskSupervisor},
      {Oban, oban_config()},
      {Phoenix.PubSub, name: MyApp.PubSub},
      # Start your Crank servers
      {Crank.Server, {MyApp.Order, [order_id: "order-1"]}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Attach handlers first. Then start servers. Order matters because the first
transition (the initial `:enter` event) fires immediately on process start.

## Anti-patterns

### Don't put side effects in handle/3

```elixir
# BAD -- breaks pure core
def handle(:ship, :paid, data) do
  MyApp.Mailer.send_shipped_email(data.email)  # side effect!
  {:next_state, :shipped, data}
end
```

This means `Crank.crank/2` sends an email. Your tests send emails. Your
LiveView reducer sends emails. The pure core is no longer pure.

Put side effects in telemetry handlers. The state machine decides *what*
happens (state transition). Telemetry handlers decide *what to do about it*.

### Don't block the gen_statem with slow handlers

```elixir
# BAD -- blocks state machine for 2+ seconds
def handle(_event, _measurements, meta, _config) do
  HTTPoison.post!("https://slow-api.example.com/webhook", Jason.encode!(meta))
end
```

The telemetry handler runs synchronously in the gen_statem process. While
this HTTP call is in flight, the state machine can't process any events.

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

### Don't attach handlers inside handle/3

```elixir
# BAD -- attaches a new handler on every transition
def handle(:pay, :pending, data) do
  :telemetry.attach("notify-#{data.order_id}", ...)
  {:next_state, :paid, data}
end
```

Attach handlers once at application startup. They receive all transitions
and filter by module/state using pattern matching.

## Testing

The whole point of the pure core is that you test without any of this.
Your telemetry handlers, persistence, and notifications are *not attached*
during `Crank.crank/2` tests. The state machine logic is tested in isolation:

```elixir
test "paying an order transitions to paid" do
  machine =
    MyApp.Order
    |> Crank.new(order_id: 123)
    |> Crank.crank(:pay)

  assert machine.state == :paid
end
```

No database. No mailer. No PubSub. No mocking. Just pure functions.

Test your telemetry handlers separately:

```elixir
test "persistence handler saves order snapshot" do
  meta = %{
    module: MyApp.Order,
    from: :pending,
    to: :paid,
    event: :pay,
    data: %{order_id: 123}
  }

  MyApp.OrderPersistence.handle([:crank, :transition], %{}, meta, nil)

  assert MyApp.Repo.get_by(MyApp.OrderSnapshot, order_id: 123)
end
```

Each concern is tested independently. The state machine doesn't know about
persistence. The persistence handler doesn't know about the state machine's
internals. They communicate through a well-defined telemetry contract.

That's hexagonal architecture. No framework required.
