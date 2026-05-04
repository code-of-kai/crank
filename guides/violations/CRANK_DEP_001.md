# CRANK_DEP_001 — Domain references infrastructure

## What triggers this

Boundary's post-compile graph check found a module marked `:domain` (via `use Crank` or `use Crank.Domain.Pure`) that aliases, imports, or calls a module classified as `:infrastructure` — or a third-party app classified as `:third_party_impure` in the Boundary configuration.

```elixir
defmodule MyApp.OrderMachine do
  use Crank
  alias MyApp.Repo                # CRANK_DEP_001 — Repo is :infrastructure
  ...
end
```

*(Track A implementation: `Crank.BoundaryIntegration` and the starter Boundary template ship in the Stage 5 work.)*

## Why it's wrong

The hexagonal boundary requires the domain model to know nothing about adapters. `CRANK_PURITY_001` catches the call inside `turn/3`; `CRANK_DEP_001` catches the *reference itself*, even if the call lives in a private helper or never fires at runtime. A module that aliases `MyApp.Repo` declares a dependency on the persistence layer; once that dependency exists, the architecture's promise that the domain can be tested without a database is gone, regardless of whether any particular line of code dereferences the alias.

Boundary works on the module dependency graph after compile. It's a static, total check: every domain module's references are walked, and every reference into the infrastructure side of the cut is reported. The cut is named in the Boundary config; `mix crank.gen.config` writes a starter version.

## How to fix

### Wrong

```elixir
defmodule MyApp.OrderMachine do
  use Crank
  alias MyApp.Repo

  def turn(:place, %Pending{}, memory) do
    Repo.insert!(%Order{...})                          # also CRANK_PURITY_001
    {:next, %Confirmed{}, memory}
  end
end
```

### Right

```elixir
# Domain model: knows nothing about Repo.
defmodule MyApp.OrderMachine do
  use Crank
  def turn(:place, %Pending{}, memory) do
    {:next, %Confirmed{}, memory}
  end
end

# Adapter (in the :infrastructure cut): reacts to telemetry.
defmodule MyApp.OrderPersistence do
  alias MyApp.Repo
  def attach, do: :telemetry.attach("order-p", [:crank, :transition], &handle/4, nil)
  def handle(_e, _m, %{module: MyApp.OrderMachine, to: %Confirmed{}, memory: m}, _),
    do: Repo.insert!(%Order{id: m.id, total: m.total})
  def handle(_, _, _, _), do: :ok
end
```

## How to suppress at this layer

Layer B — Boundary configuration `:exceptions` entry. Source comments cannot suppress this code; attempting raises `CRANK_META_004`.

```elixir
# In your Boundary config:
boundary [
  ...,
  exceptions: [
    {MyApp.LegacyOrderImporter, MyApp.Repo,
      reason: "legacy import path; will be removed in v2.0"}
  ]
]
```

## See also

- [Boundary setup](../boundary-setup.md) — wiring the topology layer.
- [Hexagonal Architecture](../hexagonal-architecture.md).
- [`CRANK_PURITY_001`](CRANK_PURITY_001.md) — the call-site cousin.
- [Suppressions](../suppressions.md) — Layer B details.
