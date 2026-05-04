# CRANK_SETUP_001 — Boundary not wired

## What triggers this

`mix crank.check` (the canonical CI gate) ran and found that `:crank` is not present in the project's `:compilers` list in `mix.exs`. The Boundary topology layer is therefore not active.

```elixir
# mix.exs — missing :crank in compilers list
def project do
  [
    app: :my_app,
    compilers: [:elixir, :app]   # CRANK_SETUP_001 — :crank not wired
  ]
end
```

## Why it's wrong

Crank ships its layered enforcement by composing several existing tools (Credo for early signal, the `@before_compile` hook for hard errors, Boundary for topology). Without `:crank` in `:compilers`, the topology layer never runs — domain modules can reference infrastructure modules and no diagnostic fires. This is the only setup gap that lets a Crank project silently run without strict topology checks; closing it is non-negotiable.

The error fires fast at `mix crank.check` time so missing wiring is caught at CI, not at code-review time. The fix is one command (`mix crank.gen.config`) that writes the necessary config without touching anything else.

## How to fix

Run the setup task. It is idempotent — running on an already-configured project produces no changes.

```sh
mix crank.gen.config
```

The task adds `:crank` to `:compilers` in `mix.exs`, writes a starter Boundary config with the `:domain` / `:infrastructure` split and the third-party classification template, and amends `.credo.exs` to wire `Crank.Check.TurnPurity`. It prints (but does not modify) recommended README and CI snippets for you to copy.

If you need to do this manually:

```elixir
# mix.exs
def project do
  [
    app: :my_app,
    compilers: Mix.compilers() ++ [:crank]   # add :crank
  ]
end

defp deps do
  [
    {:crank, "~> 1.2"},
    {:boundary, "~> 0.10"}
  ]
end
```

Then create `config/boundary.exs` (or wherever your Boundary config lives) following the [Boundary setup guide](../boundary-setup.md).

## How to suppress at this layer

`CRANK_SETUP_001` is not suppressible. The point of the rule is that there is no path where Crank silently runs without its topology layer. The fix is to wire Boundary, not to silence the warning.

## See also

- [Boundary setup](../boundary-setup.md) — full wiring story.
- [`CRANK_SETUP_002`](CRANK_SETUP_002.md) — OTP version guard.
