# CRANK_TRACE_001 — Atom-table mutation during turn

## What triggers this

A traced `turn/3` created a new atom that did not exist before the turn began. `Crank.PurityTrace` snapshots `:erlang.system_info(:atom_count)` before and after the turn; any positive delta fires this code.

The static-call-site checks (`CRANK_PURITY_006`) catch the obvious culprits — `String.to_atom`, `:erlang.list_to_atom`, `:erlang.binary_to_atom`. `CRANK_TRACE_001` is the runtime backstop that catches transitive cases the AST walk missed: a helper that builds atoms, a pattern from third-party code, an inadvertent `String.to_atom/1` deep in a serialiser. Severity is `:warning` rather than `:error` because some legitimate libraries do this — see the suppression mechanism below.

```elixir
def turn({:lookup, key_string}, %Idle{}, memory) do
  key = String.to_atom(key_string)        # caught statically; also fires the trace
  {:next, %Looking{key: key}, memory}
end
```

## Why it's wrong

The atom table is global, finite, and never garbage-collected. Every atom you create lives forever. A `turn/3` that consumes user input and converts it to an atom — even via a deep helper that "just hashes the input" — is a slow-motion DoS waiting for the right input shape to fill the table. Once full, the entire BEAM crashes; not just your machine, the whole node.

The fix is `String.to_existing_atom/1` (which raises rather than mutating), or carrying the atom through the event payload (so the boundary, not `turn/3`, is the place where atom creation can be audited).

## How to fix

### Wrong

```elixir
def turn({:lookup, key_string}, %Idle{}, memory) do
  key = String.to_atom(key_string)
  {:next, %Looking{key: key}, memory}
end
```

### Right

```elixir
# Use the bounded variant — raises on unknown atoms instead of creating them.
def turn({:lookup, key_string}, %Idle{}, memory) do
  key = String.to_existing_atom(key_string)
  {:next, %Looking{key: key}, memory}
end

# Or carry the atom through the event:
def turn({:lookup, key}, %Idle{}, memory) when is_atom(key) do
  {:next, %Looking{key: key}, memory}
end
```

## How to suppress at this layer

Layer C — programmatic `:allow` opt. Source comments cannot suppress runtime trace observations; attempting raises `CRANK_META_004`.

```elixir
test "machine that legitimately creates atoms during config load" do
  Crank.PropertyTest.assert_pure_turn(machine, events,
    allow: [
      {:erlang, :binary_to_atom, :_, reason: "config keys parsed once at boot"}
    ]
  )
end
```

If you also want to *gate* this strictly — turn the warning into an error — use `Crank.PurityTrace`'s `:strict_atom_table` opt (when shipped; see open questions in the plan).

## See also

- [`CRANK_PURITY_006`](CRANK_PURITY_006.md) — call-site detection.
- [Property testing](../property-testing.md).
- [Suppressions](../suppressions.md).
