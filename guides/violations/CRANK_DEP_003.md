# CRANK_DEP_003 — Unclassified third-party app

## What triggers this

A domain module calls a function in a third-party OTP application that is not classified in your Boundary config — neither in `:third_party_pure` nor in `:third_party_impure`. Boundary can't decide whether the call is allowed.

```elixir
defmodule MyApp.OrderMachine do
  use Crank
  def turn(:price, %Drafting{}, memory) do
    total = Decimal.add(memory.subtotal, memory.tax)    # CRANK_DEP_003 if :decimal unclassified
    {:next, %Priced{total: total}, memory}
  end
end
```

*(Track A implementation: `Crank.BoundaryIntegration` ships with the starter classification template.)*

## Why it's wrong

Boundary operates at the OTP-application level, not the module level. Calls into `:elixir` itself (`Map`, `Enum`, `String`) are not flagged — those are stdlib and the call-site / runtime layers handle them. But every other dep your project declares — `:decimal`, `:money`, `:ecto`, `:tesla`, anything from Hex — is a discrete app that Boundary needs you to label, once.

The starter config (written by `mix crank.gen.config`) seeds suggestions for common pure libraries (`:decimal`, `:money`, `:typed_struct`, `:nimble_parsec`) and common infrastructure libraries (`:ecto`, `:postgrex`, `:httpoison`, `:tesla`, `:swoosh`, `:oban`). You add your own libraries to the right bucket on first use. This is a one-time, declarative choice — not something Crank can guess for you, because pure-vs-infrastructure is a property of how *you* use the library, not of the library itself.

## How to fix

### Right

```elixir
# In config/config.exs (or wherever your Boundary config lives):
config :my_app, :boundary,
  third_party_pure: [
    :decimal,             # arithmetic only — pure
    :money,
    :typed_struct,
    :nimble_parsec
  ],
  third_party_impure: [
    :ecto,
    :ecto_sql,
    :postgrex,
    :httpoison,
    :tesla,
    :finch,
    :req,
    :swoosh,
    :oban
  ]
```

After that, calls into `Decimal.*` from a domain module are allowed; calls into `Ecto.*` produce `CRANK_DEP_001`.

If a third-party library is *partly* pure — for instance, a JSON library where the encoder is pure but the schema-validation function reads the filesystem — classify the app as `:third_party_impure` and route the genuinely-pure calls through a `Crank.Domain.Pure` wrapper that the Layer A blacklist still polices.

## How to suppress at this layer

Layer B — Boundary configuration. The clean fix is classification, not suppression.

```elixir
# Per-call exception (transitional only):
boundary [
  ...,
  exceptions: [
    {MyApp.OrderMachine, FooLib,
      reason: "evaluating :foo_lib for production use; classify after spike"}
  ]
]
```

## See also

- [Boundary setup](../boundary-setup.md) — the third-party classification mechanism.
- [`CRANK_DEP_001`](CRANK_DEP_001.md), [`CRANK_DEP_002`](CRANK_DEP_002.md) — first-party topology violations.
- [Suppressions](../suppressions.md).
