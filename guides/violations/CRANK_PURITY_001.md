# CRANK_PURITY_001 — Impure call inside turn/3

## What triggers this

A direct call to a known-impure module from inside a `turn/3` clause body. The call-site blacklist (`Crank.Check.Blacklist`) flags database, HTTP, mailer, and job-runner modules: `Repo`, `Ecto.*`, `HTTPoison`, `Tesla`, `Finch`, `Req`, `Swoosh.*`, `Bamboo.*`, `Mailer`, `Oban`.

```elixir
def turn(:place, %Pending{} = state, memory) do
  MyApp.Repo.insert!(%Order{...})    # CRANK_PURITY_001
  {:next, %Confirmed{}, memory}
end
```

## Why it's wrong

`turn/3` is the pure core of the hexagonal architecture. The moment it calls `Repo.insert!`, the domain model needs a database to run; tests need a database; a LiveView reducer hits a database. The boundary the architecture relies on is broken, and the value of the rest of the design — pure tests, no mocking, snapshot-and-resume — collapses with it.

The fix is structural, not cosmetic: declare the effect, don't perform it. `wants/2` returns effects as data. A telemetry adapter listens for `[:crank, :transition]` and decides whether and how to write. Adapters can be swapped, removed, or stubbed; the domain model never knows.

## How to fix

### Wrong

```elixir
def turn(:place, %Pending{} = state, memory) do
  MyApp.Repo.insert!(%Order{id: memory.id, total: memory.total})
  {:next, %Confirmed{}, memory}
end
```

### Right

```elixir
def turn(:place, %Pending{} = state, memory) do
  {:next, %Confirmed{}, memory}
end

# Persistence is an adapter on [:crank, :transition]:
def handle(_event, _measurements, %{module: __MODULE__, to: %Confirmed{}, memory: m}, _) do
  MyApp.Repo.insert!(%Order{id: m.id, total: m.total})
end
```

For sends, use `wants/2` with `{:send, dest, message}`. For named jobs, emit telemetry and let an Oban adapter pick them up. See [Hexagonal Architecture](../hexagonal-architecture.md) for the full pattern.

## How to suppress at this layer

Layer A — source-adjacent comment. Place directly above the offending line; `# reason:` is required.

```elixir
# crank-allow: CRANK_PURITY_001
# reason: legacy export path; will be removed in v2.0 alongside the migration
@legacy_warm_cache MyApp.Repo.all(...)
```

See [`Crank.Suppressions`](../suppressions.md).

## See also

- [Hexagonal Architecture](../hexagonal-architecture.md) — the boundary `turn/3` must respect.
- [Transitions and guards](../transitions-and-guards.md) — what `turn/3` clauses should contain.
- [Suppressions](../suppressions.md) — the three layer-specific suppression mechanisms.
